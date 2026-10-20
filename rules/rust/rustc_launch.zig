//! rustc_launch: runs the pinned rustc inside a build action, and doubles as its linker.
//!
//! usage: rustc_launch <sysroot> <zig_dir> <cc_target> -- <rustc arguments...>
//!
//! rustc runs from <sysroot>/bin/rustc with --sysroot <sysroot>, the working directory
//! remapped to `.`, `-C linker-features=-lld` (since 1.90 rustc links x86_64 linux with its
//! own rust-lld unless told not to; older compilers do not know the option, so it is passed only when
//! `<sysroot>/.rustc_version`, written by the sysroot action, names 1.90 or newer) and `-C linker=<scratch>/cc/cc`. The environment is
//! rebuilt from nothing (plus `CARGO_*`, `OUT_DIR` and `BR_PASSTHROUGH` names, see `passThrough`): an empty PATH, and HOME, TMPDIR and the zig caches private to the
//! action. Nothing is searched for on the worker.
//!
//! The linker is this same program under the name `cc` (a symlink in the action's scratch
//! directory): it reads `cc.cfg` beside itself (zig directory, target, cache directory, execution root, one
//! per line) and runs `zig cc -target <target> -Wl,--strip-debug <args>`. `--strip-debug`
//! because zig's C runtime objects record the directory they were built in. Under the names `c++`, `ar` and
//! `ranlib` it is the C++ driver, the archiver and the archive indexer of a build script's `cc` crate
//! (`zig c++`, `zig ar`, `zig ranlib`), so a build script sees one pinned toolchain and no host cc.
//! A compile step also gets `-ffile-prefix-map=<execution root>=.` (no worker path in an object) and
//! `-fno-sanitize=undefined` (zig's default UBSan-trap instrumentation is not what a C library's authors tested).
//!
//! A build script's outputs reach rustc through `--br-run <dir>` as the first arguments after `--`: the
//! launcher reads `<dir>/rustc_args` (one argument per line) and `<dir>/rustc_env` (KEY=VALUE lines), expands
//! `{OUT_DIR}` (to the absolute `<dir>/OUT_DIR`) and `{MANIFEST_DIR}` (to CARGO_MANIFEST_DIR) in both, passes the
//! arguments to rustc and the variables, plus OUT_DIR, in its environment.
//!
//! `BR_DRIVER=<path>` in the environment runs that program (clippy-driver) instead of the sysroot's rustc.
//!
//! Exit status: rustc's (128 + N for signal N); 2 for a refusal of the launcher itself.

const std = @import("std");

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("rustc_launch: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn absPath(a: std.mem.Allocator, cwd: []const u8, p: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(p)) return p;
    return std.fs.path.join(a, &.{ cwd, p }) catch die("out of memory", .{});
}

fn privateEnv(a: std.mem.Allocator, dir: []const u8) !std.process.EnvMap {
    var env = std.process.EnvMap.init(a);
    try env.put("PATH", "");
    try env.put("HOME", dir);
    try env.put("TMPDIR", dir);
    try env.put("ZIG_GLOBAL_CACHE_DIR", try std.fs.path.join(a, &.{ dir, "zig-global" }));
    try env.put("ZIG_LOCAL_CACHE_DIR", try std.fs.path.join(a, &.{ dir, "zig-local" }));
    return env;
}

/// The environment a crate sees at compile time comes from the action, not the worker: `CARGO_*` (package
/// metadata for `env!`), `OUT_DIR` (build-script output) and every name listed in `BR_PASSTHROUGH` (colon
/// separated; a build script's `rustc-env` directives). Nothing else crosses.
fn passThrough(a: std.mem.Allocator, env: *std.process.EnvMap) !void {
    var mine = try std.process.getEnvMap(a);
    const extra = mine.get("BR_PASSTHROUGH") orelse "";
    var it = mine.iterator();
    while (it.next()) |kv| {
        var keep = std.mem.startsWith(u8, kv.key_ptr.*, "CARGO_") or std.mem.eql(u8, kv.key_ptr.*, "OUT_DIR") or std.mem.eql(u8, kv.key_ptr.*, "CLIPPY_CONF_DIR");
        if (!keep) {
            var names = std.mem.splitScalar(u8, extra, ':');
            while (names.next()) |n| {
                if (n.len > 0 and std.mem.eql(u8, n, kv.key_ptr.*)) keep = true;
            }
        }
        if (keep) try env.put(kv.key_ptr.*, kv.value_ptr.*);
    }
}

fn shim(a: std.mem.Allocator, args: []const []const u8, tool: []const u8) noreturn {
    const dir = std.fs.path.dirname(args[0]) orelse ".";
    const cfg_path = std.fs.path.join(a, &.{ dir, "cc.cfg" }) catch die("out of memory", .{});
    const cfg = std.fs.cwd().readFileAlloc(a, cfg_path, 1 << 16) catch |e| die("cannot read {s}: {s}", .{ cfg_path, @errorName(e) });
    var it = std.mem.splitScalar(u8, cfg, '\n');
    const zig_dir = it.next() orelse die("{s}: empty", .{cfg_path});
    const target = it.next() orelse die("{s}: no target", .{cfg_path});
    const cache = it.next() orelse die("{s}: no cache dir", .{cfg_path});
    const root = it.next() orelse "";
    var argv = std.ArrayList([]const u8).empty;
    argv.append(a, std.fs.path.join(a, &.{ zig_dir, "zig" }) catch die("oom", .{})) catch die("oom", .{});
    if (std.mem.eql(u8, tool, "ar") or std.mem.eql(u8, tool, "ranlib")) {
        argv.append(a, tool) catch die("oom", .{});
    } else {
        // `cc` and `c++`: a compile (-c, -S, -E) gets the reproducibility flags, a link gets --strip-debug.
        var compile = false;
        for (args[1..]) |x| {
            if (std.mem.eql(u8, x, "-c") or std.mem.eql(u8, x, "-S") or std.mem.eql(u8, x, "-E")) compile = true;
        }
        argv.appendSlice(a, &.{ tool, "-target", target }) catch die("oom", .{});
        if (compile) {
            argv.append(a, "-fno-sanitize=undefined") catch die("oom", .{});
            if (root.len > 0) argv.append(a, std.fmt.allocPrint(a, "-ffile-prefix-map={s}=.", .{root}) catch die("oom", .{})) catch die("oom", .{});
        } else {
            argv.append(a, "-Wl,--strip-debug") catch die("oom", .{});
        }
    }
    // The target is the one in cc.cfg (the zig spelling of the cargo triple, with the glibc floor). The `cc` crate
    // names the cargo triple (`--target=x86_64-unknown-linux-gnu`) and zig cannot parse that spelling: drop it.
    var skip_next = false;
    for (args[1..]) |x| {
        if (skip_next) {
            skip_next = false;
            continue;
        }
        if (std.mem.startsWith(u8, x, "--target=")) continue;
        if (std.mem.eql(u8, x, "-target") or std.mem.eql(u8, x, "--target")) {
            skip_next = true;
            continue;
        }
        argv.append(a, x) catch die("oom", .{});
    }
    var env = privateEnv(a, cache) catch die("oom", .{});
    const e = std.process.execve(a, argv.items, &env);
    die("cannot run zig: {s}", .{@errorName(e)});
}

/// The same program under the name `rustc` (a symlink beside `rustc.cfg`: sysroot, zig directory, cc target, one per
/// line) is the `RUSTC` a build script runs to probe the compiler; it needs no shebang and no PATH.
fn rustcShim(a: std.mem.Allocator, args: []const []const u8) !u8 {
    const dir = std.fs.path.dirname(args[0]) orelse ".";
    const cfg_path = try std.fs.path.join(a, &.{ dir, "rustc.cfg" });
    const cfg = std.fs.cwd().readFileAlloc(a, cfg_path, 1 << 16) catch |e| die("cannot read {s}: {s}", .{ cfg_path, @errorName(e) });
    var it = std.mem.splitScalar(u8, cfg, '\n');
    const sysroot = it.next() orelse die("{s}: empty", .{cfg_path});
    const zig_dir = it.next() orelse die("{s}: no zig", .{cfg_path});
    const target = it.next() orelse die("{s}: no target", .{cfg_path});
    return launchWith(a, sysroot, zig_dir, target, args[1..]);
}

fn launch(a: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len < 5 or !std.mem.eql(u8, args[4], "--")) die("usage: rustc_launch <sysroot> <zig_dir> <cc_target> -- <rustc args>", .{});
    return launchWith(a, args[1], args[2], args[3], args[5..]);
}

/// Replaces `{OUT_DIR}` and `{MANIFEST_DIR}` in one line a build-script run recorded.
fn expandTokens(a: std.mem.Allocator, line: []const u8, out_dir: []const u8, manifest: []const u8) ![]const u8 {
    const x = try std.mem.replaceOwned(u8, a, line, "{OUT_DIR}", out_dir);
    return try std.mem.replaceOwned(u8, a, x, "{MANIFEST_DIR}", manifest);
}

/// `--br-run <dir>`: the arguments and the environment a build script asked for (see the header).
fn applyBuildScript(a: std.mem.Allocator, cwd: []const u8, dir_arg: []const u8, argv: *std.ArrayList([]const u8), env: *std.process.EnvMap) !void {
    const dir = absPath(a, cwd, dir_arg);
    const out_dir = try std.fs.path.join(a, &.{ dir, "OUT_DIR" });
    const manifest = std.process.getEnvVarOwned(a, "CARGO_MANIFEST_DIR") catch "";
    try env.put("OUT_DIR", out_dir);
    const args_text = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ dir, "rustc_args" }), 1 << 24);
    var it = std.mem.splitScalar(u8, args_text, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;
        try argv.append(a, try expandTokens(a, l, out_dir, manifest));
    }
    const env_text = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ dir, "rustc_env" }), 1 << 24);
    var et = std.mem.splitScalar(u8, env_text, '\n');
    while (et.next()) |l| {
        if (l.len == 0) continue;
        const i = std.mem.indexOfScalar(u8, l, '=') orelse die("{s}/rustc_env: no '=' in a line", .{dir});
        try env.put(l[0..i], try expandTokens(a, l[i + 1 ..], out_dir, manifest));
    }
}

/// `-C linker-features` exists, and rust-lld is the default linker, from Rust 1.90 on. `text` is "MAJOR.MINOR.PATCH" (a newline may follow).
fn needsLinkerFeatures(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t\r\n"), '.');
    const major = std.fmt.parseInt(u32, it.next() orelse return false, 10) catch return false;
    const minor = std.fmt.parseInt(u32, it.next() orelse return false, 10) catch return false;
    return major > 1 or (major == 1 and minor >= 90);
}

test "linker-features is passed from Rust 1.90 on" {
    try std.testing.expect(needsLinkerFeatures("1.95.0\n"));
    try std.testing.expect(needsLinkerFeatures("1.90.0"));
    try std.testing.expect(needsLinkerFeatures("2.0.0"));
    try std.testing.expect(!needsLinkerFeatures("1.89.2"));
    try std.testing.expect(!needsLinkerFeatures("1.85.0\n"));
    try std.testing.expect(!needsLinkerFeatures("1.9.0"));
    try std.testing.expect(!needsLinkerFeatures("nonsense"));
    try std.testing.expect(!needsLinkerFeatures(""));
}

fn launchWith(a: std.mem.Allocator, sysroot_arg: []const u8, zig_arg: []const u8, target: []const u8, rest: []const []const u8) !u8 {
    const cwd = try std.process.getCwdAlloc(a);
    const sysroot = absPath(a, cwd, sysroot_arg);
    const zig_dir = absPath(a, cwd, zig_arg);
    const self_exe = try std.fs.selfExePathAlloc(a);

    const scratch_env = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch "";
    const scratch_base = if (scratch_env.len == 0) ".br_scratch" else scratch_env;
    const scratch = try std.fs.path.join(a, &.{ absPath(a, cwd, scratch_base), "br" });
    const cc_dir = try std.fs.path.join(a, &.{ scratch, "cc" });
    const priv = try std.fs.path.join(a, &.{ scratch, "home" });
    try std.fs.cwd().makePath(cc_dir);
    try std.fs.cwd().makePath(priv);

    const cc = try std.fs.path.join(a, &.{ cc_dir, "cc" });
    std.fs.cwd().deleteFile(cc) catch {};
    try std.fs.cwd().symLink(self_exe, cc, .{});
    const cfg = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n", .{ zig_dir, target, priv });
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(a, &.{ cc_dir, "cc.cfg" }), .data = cfg });

    // BR_DRIVER names another compiler driver (clippy-driver) to run instead of the sysroot's rustc; it is
    // linked against the sysroot's libraries, which it finds through LD_LIBRARY_PATH below.
    const driver = std.process.getEnvVarOwned(a, "BR_DRIVER") catch "";
    const rustc = if (driver.len > 0) absPath(a, cwd, driver) else try std.fs.path.join(a, &.{ sysroot, "bin", "rustc" });
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(a, rustc);
    try argv.appendSlice(a, &.{ "--sysroot", sysroot, "-C" });
    try argv.append(a, try std.fmt.allocPrint(a, "linker={s}", .{cc}));
    const ver_text = std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ sysroot, ".rustc_version" }), 64) catch die("{s}/.rustc_version is missing: the sysroot was not made by rust_sysroot", .{sysroot});
    if (needsLinkerFeatures(ver_text)) try argv.appendSlice(a, &.{ "-C", "linker-features=-lld" });
    try argv.append(a, try std.fmt.allocPrint(a, "--remap-path-prefix={s}=.", .{cwd}));

    var env = try privateEnv(a, priv);
    if (driver.len > 0) try env.put("LD_LIBRARY_PATH", try std.fs.path.join(a, &.{ sysroot, "lib" }));
    try passThrough(a, &env);
    var args_rest = rest;
    if (rest.len >= 2 and std.mem.eql(u8, rest[0], "--br-run")) {
        try applyBuildScript(a, cwd, rest[1], &argv, &env);
        args_rest = rest[2..];
    }
    try argv.appendSlice(a, args_rest);
    var child = std.process.Child.init(argv.items, a);
    child.env_map = &env;
    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| @truncate(128 +% s),
        else => 1,
    };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    const base = std.fs.path.basename(args[0]);
    for ([_][]const u8{ "cc", "ar", "ranlib" }) |t| {
        if (std.mem.eql(u8, base, t)) shim(a, args, t);
    }
    if (std.mem.eql(u8, base, "c++")) shim(a, args, "c++");
    if (std.mem.eql(u8, std.fs.path.basename(args[0]), "rustc")) std.process.exit(try rustcShim(a, args));
    const code = try launch(a, args);
    std.process.exit(code);
}
