//! cov_branch link: links one test's LLVM bitcode into a test binary with IR profile counters, in a build action
//! (`mojo_cov_pgo_link`, rules/mojo/unit.bzl; README.md, "cov_branch link").
//!
//! usage: cov_branch link --compiler <compiler_dir> --zig <zig_dir> --target <cc_target> --lld <lld>
//!            --runtime <profile_runtime> --bitcode <bitcode> --out <out> --nm <llvm-nm> [--native <library>]...
//!
//!   --compiler  the Mojo compiler closure: lib/libKGENCompilerRTShared.so
//!   --zig       the Mojo toolchain's own zig directory, the one a release test links through
//!   --target    the zig target of the toolchain (`x86_64-linux-gnu.2.34`)
//!   --lld       bin/lld of the Mojo compiler package (LLD 24), the LLVM the compiler is built on
//!   --runtime   libclang_rt.profile-x86_64.a, the LLVM profile runtime
//!   --bitcode   the test's LLVM bitcode (`mojo build --emit llvm-bitcode`)
//!   --nm        llvm-nm, which lists the symbols a native library defines
//!   --native    a native library (a static archive or a shared object) of the test's unit, given as the ordinary test link gets it:
//!               one flag each, in the order of the unit graph (a library before every library it needs); repeatable
//!
//! Steps:
//!   0. The scratch directories home, tmp and the zig caches are made. Then lld, the runtime, the compiler's
//!      libKGENCompilerRTShared.so, zig, the bitcode, llvm-nm and each native library, in this order, must be files that are not
//!      empty (a usage error, exit 2), and the bitcode must start with the bitcode magic `BC 0xC0DE`.
//!   1. lld instruments the bitcode: an LTO link with -r at -O0 whose pass pipeline is `pgo-instr-gen,instrprof,default<O0>` and
//!      `-mllvm -instrprof-atomic-counter-update-all`: a relocatable object with IR profile counters, each updated atomically.
//!      lld is the LLVM the Mojo compiler is built on, so the bitcode is read by its own LLVM.
//!   1b. With native libraries: llvm-nm lists the global symbols that are defined, and not weakly, in the instrumented object and in each
//!      native library (a shared object by its dynamic table). A native that defines one the object defines too fails the link, naming
//!      both: the linker would keep one of the two definitions and say nothing, and the binary would not be the program the test links.
//!   2. zig links that object as a release test is linked (the line zig is given when `mojo build` links through mojo_compile's `cc`
//!      shim, rules/mojo/tools/cc_shim.zig: the compiler's runtime library, `--gc-sections`, `-lm`, `--strip-debug`, the one run
//!      path `$ORIGIN/lib` as DT_RUNPATH), with the profile runtime as a whole archive. The native libraries follow the object, each
//!      by path and in the order given: a static archive resolves what the libraries before it left undefined, so one comes before
//!      every archive it needs.
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

pub const USAGE = "usage: cov_branch link --compiler DIR --zig DIR --target T --lld F --runtime F --bitcode F --out F --nm F [--native F]...";

pub const Args = struct {
    compiler: []const u8,
    zig: []const u8,
    target: []const u8,
    lld: []const u8,
    runtime: []const u8,
    bitcode: []const u8,
    out: []const u8,
    nm: []const u8,
    /// The native libraries, in the order of the flags.
    natives: []const []const u8 = &.{},
};

const NAMES = [_][]const u8{ "--compiler", "--zig", "--target", "--lld", "--runtime", "--bitcode", "--out", "--nm" };

/// The arguments after `link`, or the reason they are refused (a usage error).
pub fn parseArgs(alloc: std.mem.Allocator, argv: []const []const u8, why: *[]const u8) !?Args {
    // The --native pairs first: the flag repeats, and its order is the link order; the others do not repeat.
    var natives = std.ArrayList([]const u8).empty;
    var rest = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        if (!std.mem.eql(u8, argv[i], "--native")) {
            try rest.append(alloc, argv[i]);
            if (i + 1 < argv.len) try rest.append(alloc, argv[i + 1]);
        } else if (i + 1 >= argv.len) {
            why.* = "--native needs a value";
            return null;
        } else if (argv[i + 1].len == 0) {
            why.* = "--native is empty";
            return null;
        } else {
            try natives.append(alloc, argv[i + 1]);
        }
    }
    const vals = (try common.parseFlags(alloc, &NAMES, rest.items, why)) orelse return null;
    return .{
        .compiler = vals[0],
        .zig = vals[1],
        .target = vals[2],
        .lld = vals[3],
        .runtime = vals[4],
        .bitcode = vals[5],
        .out = vals[6],
        .nm = vals[7],
        .natives = try natives.toOwnedSlice(alloc),
    };
}

pub const BITCODE_MAGIC = [4]u8{ 0x42, 0x43, 0xc0, 0xde };
pub const ELF_MAGIC = [4]u8{ 0x7f, 'E', 'L', 'F' };
/// A static archive starts with `!<arch>`; anything else a native library is, is a shared object.
pub const ARCHIVE_MAGIC = [4]u8{ '!', '<', 'a', 'r' };

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

/// zig's command line (step 2): `zig`, `kgen`, `rt`, `out` and `natives` absolute. The native libraries follow the object, by path, in the order given.
pub fn zigArgv(alloc: std.mem.Allocator, zig: []const u8, target: []const u8, k: []const u8, kgen: []const u8, out: []const u8, rt: []const u8, natives: []const []const u8) ![]const []const u8 {
    var v = std.ArrayList([]const u8).empty;
    try v.appendSlice(alloc, &.{ zig, "cc", "-target", target, "-Wl,--strip-debug", "-Wl,--enable-new-dtags", "-Wl,-rpath,$ORIGIN/lib" });
    try v.append(alloc, try std.fmt.allocPrint(alloc, "{s}/pg.o", .{k}));
    try v.appendSlice(alloc, natives);
    try v.appendSlice(alloc, &.{ kgen, "-o", out, "-Wl,--gc-sections", "-lm", "-Wl,--whole-archive", rt, "-Wl,--no-whole-archive" });
    return v.toOwnedSlice(alloc);
}

/// llvm-nm's command line (step 1b): the global symbols `file` defines, weak ones left out. `shared` reads a shared object's dynamic table.
pub fn nmArgv(alloc: std.mem.Allocator, nm: []const u8, file: []const u8, shared: bool) ![]const []const u8 {
    var v = std.ArrayList([]const u8).empty;
    try v.appendSlice(alloc, &.{ nm, "--format=posix", "--defined-only", "--extern-only", "--no-weak" });
    if (shared) try v.append(alloc, "-D");
    try v.append(alloc, file);
    return v.toOwnedSlice(alloc);
}

/// The symbol names in llvm-nm's `--format=posix` output: the first field of each line. A line that ends in `:` names an archive member and an
/// empty line separates them; neither is a symbol.
pub fn definedSymbols(alloc: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var v = std.ArrayList([]const u8).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[line.len - 1] == ':') continue;
        try v.append(alloc, line[0 .. std.mem.indexOfScalar(u8, line, ' ') orelse line.len]);
    }
    return v.toOwnedSlice(alloc);
}

/// The names in `theirs` that `mine` holds too, in the order of `theirs`.
pub fn namesInBoth(alloc: std.mem.Allocator, mine: []const []const u8, theirs: []const []const u8) ![]const []const u8 {
    var set = std.StringHashMap(void).init(alloc);
    for (mine) |s| try set.put(s, {});
    var v = std.ArrayList([]const u8).empty;
    for (theirs) |s| {
        if (set.contains(s)) try v.append(alloc, s);
    }
    return v.toOwnedSlice(alloc);
}

/// Why the native library `native` (named as given) fails the link: the first five symbols it shares with the object, and how many more.
pub fn clashMessage(alloc: std.mem.Allocator, native: []const u8, names: []const []const u8) ![]const u8 {
    const shown = @min(names.len, 5);
    const list = try std.mem.join(alloc, ", ", names[0..shown]);
    const more = if (names.len > shown) try std.fmt.allocPrint(alloc, " and {d} more", .{names.len - shown}) else "";
    return std.fmt.allocPrint(alloc, "the native library {s} defines {s}{s}, which the instrumented test object defines too: the linker keeps one of the two definitions and says nothing, so the binary would not be the program the test links", .{ std.fs.path.basename(native), list, more });
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

/// What llvm-nm said about one file: its symbols, or the exit status of the link (its message is in `err`).
const Listing = union(enum) { names: []const []const u8, exit: u8 };

/// Whether `file` is a static archive: it starts with `!<arch>`.
fn isArchive(file: []const u8) bool {
    var magic: [4]u8 = undefined;
    return std.mem.eql(u8, common.head4(file, &magic), &ARCHIVE_MAGIC);
}

/// Step 1b for one file: the global symbols `file` defines, weak ones left out (`dynamic`: those of a shared object's dynamic table). nm's output
/// goes to <k>/nm.out and its errors to the log.
fn listSymbols(alloc: std.mem.Allocator, runner: common.Runner, nm: []const u8, file: []const u8, dynamic: bool, env: []const []const u8, k: []const u8, err: *std.ArrayList(u8)) !Listing {
    const out = try std.fmt.allocPrint(alloc, "{s}/nm.out", .{k});
    const log = try std.fmt.allocPrint(alloc, "{s}/log", .{k});
    const r = runner.runFn(runner.ptr, alloc, .{ .argv = try nmArgv(alloc, nm, file, dynamic), .env = env, .stdout_path = out, .stderr_path = log }) catch |e| {
        try err.writer(alloc).print("cov_branch link: cannot run {s}: {s}\n", .{ nm, @errorName(e) });
        return .{ .exit = 2 };
    };
    if (r.shellStatus() != 0) {
        return .{ .exit = try red(alloc, err, k, try std.fmt.allocPrint(alloc, "llvm-nm could not list the symbols of {s}", .{std.fs.path.basename(file)})) };
    }
    return .{ .names = try definedSymbols(alloc, try std.fs.cwd().readFileAlloc(alloc, out, 1 << 30)) };
}

/// Steps 0 to 3 (module comment). Messages go to `err`; returns the exit status.
pub fn linkAll(alloc: std.mem.Allocator, a: Args, where: common.Where, runner: common.Runner, err: *std.ArrayList(u8)) !u8 {
    const cwd = where.cwd;
    const k = where.k;
    const lld = try common.abs(alloc, cwd, a.lld);
    const nm = try common.abs(alloc, cwd, a.nm);
    const natives = try alloc.alloc([]const u8, a.natives.len);
    for (a.natives, natives) |given, *abs| abs.* = try common.abs(alloc, cwd, given);
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
    var needed = std.ArrayList([]const u8).empty;
    try needed.appendSlice(alloc, &.{ lld, rt, kgen, zig, bc, nm });
    try needed.appendSlice(alloc, natives);
    for (needed.items) |f| {
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

    // 1b. A native library must not define a symbol the instrumented object defines.
    if (natives.len > 0) {
        const pg = try std.fmt.allocPrint(alloc, "{s}/pg.o", .{k});
        const mine = switch (try listSymbols(alloc, runner, nm, pg, false, env, k, err)) {
            .names => |n| n,
            .exit => |code| return code,
        };
        for (natives) |native| {
            const theirs = switch (try listSymbols(alloc, runner, nm, native, !isArchive(native), env, k, err)) {
                .names => |n| n,
                .exit => |code| return code,
            };
            const both = try namesInBoth(alloc, mine, theirs);
            if (both.len > 0) {
                try err.writer(alloc).print("BRANCH COVERAGE LINK FAILED: {s}\n", .{try clashMessage(alloc, native, both)});
                return 1;
            }
        }
    }

    // 2. Link, as mojo_compile's cc shim links a release test.
    const z = runner.runFn(runner.ptr, alloc, .{ .argv = try zigArgv(alloc, zig, a.target, k, kgen, out, rt, natives), .env = env, .stdout_path = log, .stderr_to_stdout = true }) catch |e| {
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
