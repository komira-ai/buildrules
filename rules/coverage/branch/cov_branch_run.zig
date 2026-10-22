//! cov_branch run: runs one test's instrumented binary in a build action (`mojo_cov_branch_run`, rules/mojo/unit.bzl) and merges
//! the raw profiles it writes into an indexed profile (README.md, "cov_branch run").
//!
//! usage: cov_branch run --compiler <compiler_dir> --share <dir> --label <label> --profdata <llvm-profdata>
//!            --raw-version <N> --binary <test_binary> --out <profdata_out> [--env NAME=VALUE]...
//!
//!   --compiler     the Mojo compiler closure; its lib/ is on LD_LIBRARY_PATH (the binary loads libKGENCompilerRTShared.so from it)
//!   --share        the tree the test runs in (its working directory): the test source and the library's sources at the relative
//!                  names the line tables use, as `cov_run` gives kcov
//!   --profdata     the pinned llvm-profdata
//!   --raw-version  the raw profile version every profile must have
//!   --binary       the instrumented test (`cov_branch link`)
//!   --env          one more variable of the test's environment
//!
//! Steps:
//!   1. The test runs in <share> with exactly this environment: PATH=/usr/bin:/bin, LD_LIBRARY_PATH=<compiler>/lib, the --env
//!      entries and LLVM_PROFILE_FILE=<scratch>/prof/%p.profraw (an absolute path; %p is the pid, so a child the test starts writes
//!      a profile of its own). The test must pass: when it fails, so does this action, with the test's output and this tool's message.
//!   2. At least one raw profile was written there; none (the runtime was not linked, the variable did not reach the test, the test
//!      left without running its exit handlers) fails the action.
//!   3. Each raw profile starts with the 64-bit raw magic, its version is <raw_version>, and its variant flags carry the
//!      IR-instrumentation bit (0x01000000), which only the instrumenter's definition of __llvm_profile_raw_version sets: the
//!      little-endian words at bytes 0, 8 and 12.
//!   4. llvm-profdata merges them into <profdata_out>; a refusal that is LLVM's `raw profile version mismatch` says which version it
//!      expected. `llvm-profdata show` must then report IR instrumentation and exactly one `Total functions:` count, above 0.
//!      llvm-profdata runs with LC_ALL=C and nothing else in its environment.
//!
//! It waits for the test alone: a child still running when the test exits writes its profile after the merge, or never, and its
//! counts are not in <profdata_out>. It has no time limit of its own: a test that hangs holds the action until the executor's timeout.
//!
//! The scratch directory is $BUCK_SCRATCH_PATH/cov_branch_run (relative to the working directory when it is relative), or
//! .cov_branch_run in the working directory without one; it is removed after a success.
//!
//! Exit status: the test's when it fails (128 + N when signal N killed it); 1 when no profile was written or one is refused; 2 for a
//! usage error, or a program this tool cannot start.

const std = @import("std");
const proc = @import("proc.zig");
const common = @import("cov_branch_common.zig");

const RULE = "==================================================================";

pub const Args = struct {
    compiler: []const u8,
    share: []const u8,
    label: []const u8,
    profdata: []const u8,
    raw_version: u32,
    binary: []const u8,
    out: []const u8,
    /// "NAME=VALUE" of each --env, in order.
    env: []const []const u8,
};

pub const USAGE = "usage: cov_branch run --compiler DIR --share DIR --label L --profdata P --raw-version N --binary F --out F [--env NAME=VALUE]...";

const NAMES = [_][]const u8{ "--compiler", "--share", "--label", "--profdata", "--raw-version", "--binary", "--out" };

/// The arguments after `run`, or the reason they are refused (a usage error).
pub fn parseArgs(alloc: std.mem.Allocator, argv: []const []const u8, why: *[]const u8) !?Args {
    // The --env pairs first: the flag repeats, the others do not.
    var env = std.ArrayList([]const u8).empty;
    var rest = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        if (std.mem.eql(u8, argv[i], "--env") and i + 1 < argv.len) {
            try env.append(alloc, argv[i + 1]);
        } else {
            try rest.append(alloc, argv[i]);
            if (i + 1 < argv.len) try rest.append(alloc, argv[i + 1]);
        }
    }
    const v = (try common.parseFlags(alloc, &NAMES, rest.items, why)) orelse return null;
    const raw = parseVersion(v[4]) orelse {
        why.* = try std.fmt.allocPrint(alloc, "--raw-version is '{s}', not a version", .{v[4]});
        return null;
    };
    for (env.items) |e| {
        const eq = std.mem.indexOfScalar(u8, e, '=') orelse 0;
        if (eq == 0) {
            why.* = try std.fmt.allocPrint(alloc, "--env '{s}' is not NAME=VALUE", .{e});
            return null;
        }
        if (std.mem.eql(u8, e[0..eq], "LLVM_PROFILE_FILE")) {
            why.* = "--env LLVM_PROFILE_FILE: a branch coverage run sets it itself (where the test's profile is written)";
            return null;
        }
    }
    return .{
        .compiler = v[0],
        .share = v[1],
        .label = v[2],
        .profdata = v[3],
        .raw_version = raw,
        .binary = v[5],
        .out = v[6],
        .env = try env.toOwnedSlice(alloc),
    };
}

/// A positive decimal with no leading zero.
fn parseVersion(s: []const u8) ?u32 {
    if (s.len == 0 or s[0] == '0') return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// The test's environment (step 1). Paths are absolute (`k` is).
pub fn testEnv(alloc: std.mem.Allocator, a: Args, cwd: []const u8, k: []const u8) ![]const []const u8 {
    var v = std.ArrayList([]const u8).empty;
    try v.append(alloc, "PATH=/usr/bin:/bin");
    try v.append(alloc, try std.fmt.allocPrint(alloc, "LD_LIBRARY_PATH={s}/lib", .{try common.abs(alloc, cwd, a.compiler)}));
    try v.appendSlice(alloc, a.env);
    try v.append(alloc, try std.fmt.allocPrint(alloc, "LLVM_PROFILE_FILE={s}/prof/%p.profraw", .{k}));
    return v.toOwnedSlice(alloc);
}

fn banner(alloc: std.mem.Allocator, out: *std.ArrayList(u8), label: []const u8, msg: []const u8) !void {
    const w = out.writer(alloc);
    try w.print("{s}\nBRANCH COVERAGE RUN FAILED: {s}\n{s}\n{s}\n", .{ RULE, label, msg, RULE });
}

pub const RAW_MAGIC: u64 = 0xff6c70726f667281;
pub const IR_BIT: u32 = 0x01000000;

/// Why the raw profile `name` with first bytes `head` is refused, or null.
pub fn checkRaw(alloc: std.mem.Allocator, name: []const u8, head: []const u8, raw: u32) !?[]const u8 {
    var b = [_]u8{0} ** 16;
    @memcpy(b[0..@min(head.len, 16)], head[0..@min(head.len, 16)]);
    const magic = std.mem.readInt(u64, b[0..8], .little);
    if (head.len < 8 or magic != RAW_MAGIC) {
        return try std.fmt.allocPrint(alloc, "{s} does not start with the 64-bit raw profile magic (got '{x:0>16}')", .{ name, magic });
    }
    const v = std.mem.readInt(u32, b[8..12], .little);
    if (head.len < 12 or v != raw) {
        return try std.fmt.allocPrint(alloc, "{s} has raw profile version {d}, not {d}, the version the pinned llvm-profdata reads (README.md, \"The version coupling\").", .{ name, v, raw });
    }
    const flags = std.mem.readInt(u32, b[12..16], .little);
    if (head.len < 16 or flags & IR_BIT == 0) {
        return try std.fmt.allocPrint(alloc, "{s} has variant flags 0x{x:0>8}, without the IR-instrumentation bit 0x01000000: its version word is the profile runtime's default, not the instrumenter's (README.md, \"The version coupling\").", .{ name, flags });
    }
    return null;
}

/// The first `n` lines of `text`, each that ended in a newline followed by a space.
pub fn headJoined(alloc: std.mem.Allocator, text: []const u8, n: usize) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var rest = text;
    var k: usize = 0;
    while (k < n and rest.len > 0) : (k += 1) {
        if (std.mem.indexOfScalar(u8, rest, '\n')) |e| {
            try out.appendSlice(alloc, rest[0..e]);
            try out.append(alloc, ' ');
            rest = rest[e + 1 ..];
        } else {
            try out.appendSlice(alloc, rest);
            rest = "";
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Why a failed merge failed, from its log.
pub fn mergeRefusal(alloc: std.mem.Allocator, log: []const u8, raw: u32, n: usize) ![]const u8 {
    if (std.mem.indexOf(u8, log, "raw profile version mismatch") != null) {
        var seen = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, log, '\n');
        while (it.next()) |l| {
            const v = expectedVersion(l) orelse continue;
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, v)) break;
            } else try seen.append(alloc, v);
        }
        std.mem.sort([]const u8, seen.items, {}, strLess);
        const ev = try std.mem.join(alloc, " ", seen.items);
        return std.fmt.allocPrint(alloc, "llvm-profdata refused a raw profile of version {d}: it expects {s}: {s}", .{ raw, ev, try headJoined(alloc, log, 2) });
    }
    return std.fmt.allocPrint(alloc, "llvm-profdata merge failed on {d} raw profile(s): {s}", .{ n, try headJoined(alloc, log, 3) });
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The digits after the last "; expected version = " of a line that has digits after it.
fn expectedVersion(line: []const u8) ?[]const u8 {
    const key = "; expected version = ";
    var end = line.len;
    while (std.mem.lastIndexOf(u8, line[0..end], key)) |at| {
        const s = at + key.len;
        var e = s;
        while (e < line.len and std.ascii.isDigit(line[e])) e += 1;
        if (e > s) return line[s..e];
        if (at == 0) break;
        end = at + key.len - 1;
    }
    return null;
}

/// Why `llvm-profdata show`'s output is refused, or null.
pub fn checkShow(alloc: std.mem.Allocator, show: []const u8) !?[]const u8 {
    if (std.mem.indexOf(u8, show, "Instrumentation level: IR") == null) {
        const first = if (std.mem.indexOfScalar(u8, show, '\n')) |e| show[0..e] else show;
        return try std.fmt.allocPrint(alloc, "the merged profile is not an IR-instrumentation profile: {s}", .{first});
    }
    var count: usize = 0;
    var positive = false;
    var it = std.mem.splitScalar(u8, show, '\n');
    while (it.next()) |l| {
        const key = "Total functions: ";
        if (!std.mem.startsWith(u8, l, key) or l.len == key.len) continue;
        const d = l[key.len..];
        for (d) |c| {
            if (!std.ascii.isDigit(c)) break;
        } else {
            count += 1;
            positive = std.mem.trimLeft(u8, d, "0").len > 0;
        }
    }
    if (count != 1 or !positive) {
        const flat = try alloc.dupe(u8, show);
        for (flat) |*c| {
            if (c.* == '\n') c.* = ' ';
        }
        return try std.fmt.allocPrint(alloc, "the merged profile has no function: {s}", .{flat});
    }
    return null;
}

fn readAll(alloc: std.mem.Allocator, path: []const u8) []const u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, 64 << 20) catch "";
}

fn readHead(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const buf = try alloc.alloc(u8, 16);
    const n = try f.readAll(buf);
    return buf[0..n];
}

/// The .profraw files under `dir`, at any depth, sorted by path.
pub fn listRaws(alloc: std.mem.Allocator, dir: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer d.close();
    var w = try d.walk(alloc);
    defer w.deinit();
    while (try w.next()) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.basename, ".profraw")) continue;
        try out.append(alloc, try std.fs.path.join(alloc, &.{ dir, e.path }));
    }
    std.mem.sort([]const u8, out.items, {}, strLess);
    return out.toOwnedSlice(alloc);
}

/// Steps 1 to 4 (module comment). Messages go to `err`; returns the exit status.
pub fn runAll(alloc: std.mem.Allocator, a: Args, where: common.Where, runner: common.Runner, err: *std.ArrayList(u8)) !u8 {
    const k = where.k;
    const prof = try std.fmt.allocPrint(alloc, "{s}/prof", .{k});
    try std.fs.cwd().makePath(prof);

    // 1. The test, in the tree of its sources.
    const test_run = runner.run(alloc, .{
        .argv = &.{try common.abs(alloc, where.cwd, a.binary)},
        .env = try testEnv(alloc, a, where.cwd, k),
        .cwd = try common.abs(alloc, where.cwd, a.share),
    }) catch |e| {
        try err.writer(alloc).print("cov_branch run: cannot run {s}: {s}\n", .{ a.binary, @errorName(e) });
        return 2;
    };
    const rc = test_run.shellStatus();
    if (rc != 0) {
        try banner(alloc, err, a.label, try std.fmt.allocPrint(alloc, "The test failed instrumented for branch coverage (exit {d}). A branch coverage run builds the test at -O0, instruments it with lld and runs it with LLVM_PROFILE_FILE set; a test that passes in its ordinary run and fails here fails this action, and is a bug to fix.", .{rc}));
        return rc;
    }

    // 2. The raw profiles.
    const raws = try listRaws(alloc, prof);
    if (raws.len == 0) {
        try banner(alloc, err, a.label, try std.fmt.allocPrint(alloc, "The test passed but wrote no .profraw under {s} (LLVM_PROFILE_FILE): the profile runtime did not run its exit handler, or the variable did not reach the test.", .{prof}));
        return 1;
    }

    // 3. Each one's magic, version and IR bit.
    for (raws) |f| {
        const head = readHead(alloc, f) catch "";
        if (try checkRaw(alloc, std.fs.path.basename(f), head, a.raw_version)) |why| {
            try banner(alloc, err, a.label, why);
            return 1;
        }
    }

    // 4. Merged; a version refusal named as one; then shown.
    const env: []const []const u8 = &.{"LC_ALL=C"};
    const out = try common.abs(alloc, where.cwd, a.out);
    const profdata = try common.abs(alloc, where.cwd, a.profdata);
    var merge = std.ArrayList([]const u8).empty;
    try merge.appendSlice(alloc, &.{ profdata, "merge", "-o", out });
    try merge.appendSlice(alloc, raws);
    const merge_log = try std.fmt.allocPrint(alloc, "{s}/merge.log", .{k});
    const m = runner.run(alloc, .{ .argv = merge.items, .env = env, .stdout_path = merge_log, .stderr_to_stdout = true }) catch |e| {
        try err.writer(alloc).print("cov_branch run: cannot run {s}: {s}\n", .{ a.profdata, @errorName(e) });
        return 2;
    };
    if (m.shellStatus() != 0) {
        try banner(alloc, err, a.label, try mergeRefusal(alloc, readAll(alloc, merge_log), a.raw_version, raws.len));
        return 1;
    }
    const show_txt = try std.fmt.allocPrint(alloc, "{s}/show.txt", .{k});
    const s = runner.run(alloc, .{ .argv = &.{ profdata, "show", out }, .env = env, .stdout_path = show_txt, .stderr_to_stdout = true }) catch |e| {
        try err.writer(alloc).print("cov_branch run: cannot run {s}: {s}\n", .{ a.profdata, @errorName(e) });
        return 2;
    };
    const show = readAll(alloc, show_txt);
    if (s.shellStatus() != 0) {
        try banner(alloc, err, a.label, try std.fmt.allocPrint(alloc, "llvm-profdata show failed on the merged profile: {s}", .{try headJoined(alloc, show, 2)}));
        return 1;
    }
    if (try checkShow(alloc, show)) |why| {
        try banner(alloc, err, a.label, why);
        return 1;
    }
    std.fs.cwd().deleteTree(k) catch {};
    return 0;
}

/// `cov_branch run <argv>`: parses, checks the tools, runs. Returns the exit status; messages go to `err`.
pub fn cli(alloc: std.mem.Allocator, argv: []const []const u8, where: common.Where, runner: common.Runner, err: *std.ArrayList(u8)) !u8 {
    var why: []const u8 = "";
    const a = (try parseArgs(alloc, argv, &why)) orelse {
        try err.writer(alloc).print("cov_branch run: usage error: {s}\n{s}\n", .{ why, USAGE });
        return 2;
    };
    std.posix.access(a.profdata, std.posix.X_OK) catch {
        try err.writer(alloc).print("cov_branch run: {s} is missing\n", .{a.profdata});
        return 2;
    };
    return runAll(alloc, a, where, runner, err);
}
