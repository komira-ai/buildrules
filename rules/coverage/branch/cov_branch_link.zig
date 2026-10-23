//! cov_branch link: links one test's LLVM bitcode into a test binary with IR profile counters, in a build action
//! (`mojo_cov_pgo_link`, rules/mojo/unit.bzl; README.md, "cov_branch link").
//!
//! usage: cov_branch link --compiler <compiler_dir> --zig <zig_dir> --target <cc_target> --lld <lld>
//!            --runtime <profile_runtime> --bitcode <bitcode> --out <out>
//!
//!   --compiler  the Mojo compiler closure: lib/libKGENCompilerRTShared.so
//!   --zig       the Mojo toolchain's own zig directory, the one a release test links through
//!   --target    the zig target of the toolchain (`x86_64-linux-gnu.2.34`)
//!   --lld       bin/lld of the Mojo compiler package (LLD 24), the LLVM the compiler is built on
//!   --runtime   libclang_rt.profile-x86_64.a, the LLVM profile runtime
//!   --bitcode   the test's LLVM bitcode (`mojo build --emit llvm-bitcode`)
//!
//! Steps:
//!   0. The scratch directories home, tmp and the zig caches are made. Then lld, the runtime, the compiler's
//!      libKGENCompilerRTShared.so, zig and the bitcode, in this order, must be files that are not empty (a usage error, exit 2),
//!      and the bitcode must start with the bitcode magic `BC 0xC0DE`.
//!   1. lld instruments the bitcode: an LTO link with -r at -O0 whose pass pipeline is `pgo-instr-gen,instrprof,default<O0>` and
//!      `-mllvm -instrprof-atomic-counter-update-all`: a relocatable object with IR profile counters, each updated atomically.
//!      lld is the LLVM the Mojo compiler is built on, so the bitcode is read by its own LLVM.
//!   2. zig links that object as a release test is linked (the line zig is given when `mojo build` links through mojo_compile's `cc`
//!      shim, rules/mojo/tools/cc_shim.zig: the compiler's runtime library, `--gc-sections`, `-lm`, `--strip-debug`, the one run
//!      path `$ORIGIN/lib` as DT_RUNPATH), with the profile runtime as a whole archive.
//!   3. The binary must be an ELF file and hold no path of this action (its working directory, then its scratch directory).
//!
//! When one input has several faults, the first check above that refuses it is the one named.
//!
//! lld and zig run with this tool's environment but for PATH (an empty directory of the scratch), HOME, TMPDIR, ZIG_GLOBAL_CACHE_DIR
//! and ZIG_LOCAL_CACHE_DIR (directories of the scratch) and LC_ALL=C; their output goes to <scratch>/log, whose last 40 lines a
//! failure prints.
//!
//! Why --strip-debug: nothing reads the binary's debug info. What a branch was in the source is read from the bitcode (the IR the
//! profile is applied to, which keeps its line tables), never from the binary; and zig's C runtime objects record this action's
//! directory as their compilation directory, which the strip removes with the rest, as in a release link. Step 3 shows it: with
//! `--strip-debug` left out, the link fails with `the binary holds this action's directory`.
//!
//! The scratch directory is $BUCK_SCRATCH_PATH/cov_branch_link (relative to the working directory when it is relative), or
//! .cov_branch_link in the working directory without one; it is removed after a success and kept after a failure.
//!
//! Exit status: 1 when a step fails, naming it; 2 for a usage error, a missing or empty input, or a scratch directory or program this
//! tool cannot set up or start.

const std = @import("std");
const proc = @import("proc.zig");
const common = @import("cov_branch_common.zig");

pub const USAGE = "usage: cov_branch link --compiler DIR --zig DIR --target T --lld F --runtime F --bitcode F --out F";

pub const Args = struct {
    compiler: []const u8,
    zig: []const u8,
    target: []const u8,
    lld: []const u8,
    runtime: []const u8,
    bitcode: []const u8,
    out: []const u8,
};

const NAMES = [_][]const u8{ "--compiler", "--zig", "--target", "--lld", "--runtime", "--bitcode", "--out" };

/// The arguments after `link`, or the reason they are refused (a usage error).
pub fn parseArgs(alloc: std.mem.Allocator, argv: []const []const u8, why: *[]const u8) !?Args {
    const vals = (try common.parseFlags(alloc, &NAMES, argv, why)) orelse return null;
    return .{ .compiler = vals[0], .zig = vals[1], .target = vals[2], .lld = vals[3], .runtime = vals[4], .bitcode = vals[5], .out = vals[6] };
}

pub const BITCODE_MAGIC = [4]u8{ 0x42, 0x43, 0xc0, 0xde };
pub const ELF_MAGIC = [4]u8{ 0x7f, 'E', 'L', 'F' };

/// lld's command line (step 1). Paths are absolute.
pub fn lldArgv(alloc: std.mem.Allocator, lld: []const u8, bc: []const u8, k: []const u8) ![]const []const u8 {
    var v = std.ArrayList([]const u8).empty;
    try v.appendSlice(alloc, &.{ lld, "-flavor", "gnu", "-r", "-m", "elf_x86_64", bc, "-o" });
    try v.append(alloc, try std.fmt.allocPrint(alloc, "{s}/pg.o", .{k}));
    try v.appendSlice(alloc, &.{ "--lto-O0", "--lto-newpm-passes=pgo-instr-gen,instrprof,default<O0>" });
    // Atomic counter updates (README.md, "Atomic counters"): `instrprof` lowers each increment to an `atomicrmw add` (a
    // `lock`-prefixed add), so threads that increment one counter at once lose none.
    try v.appendSlice(alloc, &.{ "-mllvm", "-instrprof-atomic-counter-update-all" });
    return v.toOwnedSlice(alloc);
}

/// zig's command line (step 2): `zig`, `kgen`, `rt` and `out` absolute.
pub fn zigArgv(alloc: std.mem.Allocator, zig: []const u8, target: []const u8, k: []const u8, kgen: []const u8, out: []const u8, rt: []const u8) ![]const []const u8 {
    var v = std.ArrayList([]const u8).empty;
    try v.appendSlice(alloc, &.{ zig, "cc", "-target", target, "-Wl,--strip-debug", "-Wl,--enable-new-dtags", "-Wl,-rpath,$ORIGIN/lib" });
    try v.append(alloc, try std.fmt.allocPrint(alloc, "{s}/pg.o", .{k}));
    try v.appendSlice(alloc, &.{ kgen, "-o", out, "-Wl,--gc-sections", "-lm", "-Wl,--whole-archive", rt, "-Wl,--no-whole-archive" });
    return v.toOwnedSlice(alloc);
}

/// `base` with PATH, HOME, TMPDIR, ZIG_GLOBAL_CACHE_DIR, ZIG_LOCAL_CACHE_DIR and LC_ALL replaced by the scratch's (module comment).
pub fn childEnv(alloc: std.mem.Allocator, base: []const []const u8, k: []const u8) ![]const []const u8 {
    const set = [_][]const u8{ "PATH", "HOME", "TMPDIR", "ZIG_GLOBAL_CACHE_DIR", "ZIG_LOCAL_CACHE_DIR", "LC_ALL" };
    const val = [_][]const u8{ "/bin", "/home", "/tmp", "/zig-global", "/zig-local" };
    var v = std.ArrayList([]const u8).empty;
    outer: for (base) |e| {
        for (set) |n| {
            if (e.len > n.len and std.mem.startsWith(u8, e, n) and e[n.len] == '=') continue :outer;
        }
        try v.append(alloc, e);
    }
    for (val, 0..) |s, j| try v.append(alloc, try std.fmt.allocPrint(alloc, "{s}={s}{s}", .{ set[j], k, s }));
    try v.append(alloc, "LC_ALL=C");
    return v.toOwnedSlice(alloc);
}

/// The first three runs of at least 4 printable bytes (0x20 to 0x7e, or a tab) that hold `needle`, each followed by a space.
pub fn stringsWith(alloc: std.mem.Allocator, bytes: []const u8, needle: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var found: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= bytes.len and found < 3) : (i += 1) {
        const printable = i < bytes.len and ((bytes[i] >= 0x20 and bytes[i] < 0x7f) or bytes[i] == '\t');
        if (printable) continue;
        const run = bytes[start..i];
        if (run.len >= 4 and std.mem.indexOf(u8, run, needle) != null) {
            try out.appendSlice(alloc, run);
            try out.append(alloc, ' ');
            found += 1;
        }
        start = i + 1;
    }
    return out.toOwnedSlice(alloc);
}

fn red(alloc: std.mem.Allocator, err: *std.ArrayList(u8), k: []const u8, msg: []const u8) !u8 {
    const w = err.writer(alloc);
    try w.print("BRANCH COVERAGE LINK FAILED: {s}\n", .{msg});
    const log_path = try std.fmt.allocPrint(alloc, "{s}/log", .{k});
    if (std.fs.cwd().readFileAlloc(alloc, log_path, 1 << 30)) |log| {
        try w.writeAll("--- log:\n");
        const last = common.lastLines(log, 40);
        try w.writeAll(last);
        if (last.len > 0 and last[last.len - 1] != '\n') try w.writeByte('\n');
    } else |_| {}
    return 1;
}

/// Steps 0 to 3 (module comment). Messages go to `err`; returns the exit status.
pub fn linkAll(alloc: std.mem.Allocator, a: Args, where: common.Where, runner: common.Runner, err: *std.ArrayList(u8)) !u8 {
    const cwd = where.cwd;
    const k = where.k;
    const lld = try common.abs(alloc, cwd, a.lld);
    const rt = try common.abs(alloc, cwd, a.runtime);
    const kgen = try std.fmt.allocPrint(alloc, "{s}/lib/libKGENCompilerRTShared.so", .{try common.abs(alloc, cwd, a.compiler)});
    const zig = try std.fmt.allocPrint(alloc, "{s}/zig", .{try common.abs(alloc, cwd, a.zig)});
    const bc = try common.abs(alloc, cwd, a.bitcode);
    const out = try common.abs(alloc, cwd, a.out);
    const env = try childEnv(alloc, where.env, k);
    const log = try std.fmt.allocPrint(alloc, "{s}/log", .{k});
    var magic: [4]u8 = undefined;

    // 0a. The scratch directories, each tried; the first that cannot be made is named.
    var cannot: ?[]const u8 = null;
    for ([_][]const u8{ "bin", "home", "tmp" }) |sub| {
        const d = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ k, sub });
        std.fs.cwd().makePath(d) catch |e| {
            if (cannot == null) cannot = try std.fmt.allocPrint(alloc, "{s}: {s}", .{ d, @errorName(e) });
        };
    }
    if (cannot) |c| {
        try err.writer(alloc).print("cov_branch link: cannot make {s}\n", .{c});
        return 2;
    }

    // 0b. The inputs, each a file that is not empty (a symbolic link followed), in this order.
    for ([_][]const u8{ lld, rt, kgen, zig, bc }) |f| {
        if (!common.nonEmpty(f)) {
            try err.writer(alloc).print("cov_branch link: {s} is missing or empty\n", .{f});
            return 2;
        }
    }

    // 0c. The bitcode magic.
    if (!std.mem.eql(u8, common.head4(bc, &magic), &BITCODE_MAGIC)) {
        return red(alloc, err, k, try std.fmt.allocPrint(alloc, "{s} is not LLVM bitcode", .{a.bitcode}));
    }

    // 1. Instrument.
    const l = runner.runFn(runner.ptr, alloc, .{ .argv = try lldArgv(alloc, lld, bc, k), .env = env, .stdout_path = log, .stderr_to_stdout = true }) catch |e| {
        try err.writer(alloc).print("cov_branch link: cannot run {s}: {s}\n", .{ lld, @errorName(e) });
        return 2;
    };
    if (l.shellStatus() != 0) {
        return red(alloc, err, k, try std.fmt.allocPrint(alloc, "lld could not instrument {s} (pgo-instr-gen)", .{a.bitcode}));
    }

    // 2. Link, as mojo_compile's cc shim links a release test.
    const z = runner.runFn(runner.ptr, alloc, .{ .argv = try zigArgv(alloc, zig, a.target, k, kgen, out, rt), .env = env, .stdout_path = log, .stderr_to_stdout = true }) catch |e| {
        try err.writer(alloc).print("cov_branch link: cannot run {s}: {s}\n", .{ zig, @errorName(e) });
        return 2;
    };
    if (z.shellStatus() != 0) {
        return red(alloc, err, k, "zig could not link the instrumented test with the profile runtime");
    }

    // 3a. An ELF file.
    if (!std.mem.eql(u8, common.head4(out, &magic), &ELF_MAGIC)) {
        return red(alloc, err, k, "the link wrote no ELF file");
    }

    // 3b. Holding no path of this action: the working directory first.
    const bytes = std.fs.cwd().readFileAlloc(alloc, out, 1 << 32) catch |e| {
        return red(alloc, err, k, try std.fmt.allocPrint(alloc, "cannot read the binary {s}: {s}", .{ out, @errorName(e) }));
    };
    for ([_][]const u8{ cwd, k }) |d| {
        if (std.mem.indexOf(u8, bytes, d) != null) {
            return red(alloc, err, k, try std.fmt.allocPrint(alloc, "the binary holds this action's directory {s}: {s}", .{ d, try stringsWith(alloc, bytes, d) }));
        }
    }

    // A success removes the scratch directory; a failure keeps it.
    std.fs.cwd().deleteTree(k) catch {};
    return 0;
}

/// `cov_branch link <argv>`: parses, then links. Returns the exit status; messages go to `err`.
pub fn cli(alloc: std.mem.Allocator, argv: []const []const u8, where: common.Where, runner: common.Runner, err: *std.ArrayList(u8)) !u8 {
    var why: []const u8 = "";
    const a = (try parseArgs(alloc, argv, &why)) orelse {
        try err.writer(alloc).print("cov_branch link: usage error: {s}\n{s}\n", .{ why, USAGE });
        return 2;
    };
    return linkAll(alloc, a, where, runner, err);
}
