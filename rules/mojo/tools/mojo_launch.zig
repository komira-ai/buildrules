//! mojo_launch: the `mojo_compile` of a toolchain directory.
//!
//! `mopm unit build` executes `<toolchain>/mojo_compile --source-root=... -- <mojo arguments>` with an empty
//! environment and knows nothing else about the compiler (spec/unit-graph.md in the mopm repository). The
//! wrapper that really runs the compiler (`mojo_compile`, `wrapper` beside this file) needs to be told
//! where the compiler closure and the zig are. This program is that telling: it reads `toolchain.cfg` from its own
//! directory, puts the wrapper's options in front of mopm's, and executes the wrapper. It runs no compiler and
//! owns no policy; the closure check, the environment the compiler sees, zig as `cc` and the watchdog are the
//! wrapper's.
//!
//! toolchain.cfg, one `key=value` per line (`#` lines and empty lines are skipped); paths are relative to the
//! directory the file is in:
//!
//!     wrapper=wrapper
//!     compiler=compiler
//!     zig=zig
//!     cc_target=x86_64-linux-gnu.2.34
//!     watchdog_idle_secs=300
//!     watchdog_sample_secs=30
//!     build_arg=--target-cpu          (repeatable: placed right after `build`, i.e. the ISA flags of a test)
//!     build_arg=x86-64-v3
//!     link_tail=-lc++                 (repeatable: given to the wrapper as --link-tail, the arguments that end the link line, after the archives; a program
//!                                      whose native libraries include C++ gets the C++ runtime this way, once)
//!
//! A toolchain for macOS (the wrapper is mojo_compile_macos.zig) has no zig and no cc_target: it names the deployment target and the host
//! identities a compile may run on instead, and the file is refused if it names both kinds of key.
//!
//!     wrapper=wrapper
//!     compiler=compiler
//!     deployment_target=11.0
//!     macos_host=27.0-0123456789abcdef   (repeatable, at least one)

const std = @import("std");

pub const Cfg = struct {
    wrapper: []const u8 = "",
    compiler: []const u8 = "",
    zig: []const u8 = "",
    cc_target: []const u8 = "",
    deployment_target: []const u8 = "",
    macos_hosts: []const []const u8 = &.{},
    watchdog_idle_secs: []const u8 = "300",
    watchdog_sample_secs: []const u8 = "30",
    build_args: []const []const u8 = &.{},
    link_tail: []const []const u8 = &.{},
};

pub const CfgError = error{ BadLine, UnknownKey, Missing, OutOfMemory };

pub fn parseCfg(a: std.mem.Allocator, text: []const u8, why: *[]const u8) CfgError!Cfg {
    var cfg = Cfg{};
    var build_args = std.ArrayList([]const u8).empty;
    var link_tail = std.ArrayList([]const u8).empty;
    var macos_hosts = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            why.* = try std.fmt.allocPrint(a, "not `key=value`: {s}", .{line});
            return error.BadLine;
        };
        const key = line[0..eq];
        const val = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "wrapper")) {
            cfg.wrapper = val;
        } else if (std.mem.eql(u8, key, "compiler")) {
            cfg.compiler = val;
        } else if (std.mem.eql(u8, key, "zig")) {
            cfg.zig = val;
        } else if (std.mem.eql(u8, key, "cc_target")) {
            cfg.cc_target = val;
        } else if (std.mem.eql(u8, key, "deployment_target")) {
            cfg.deployment_target = val;
        } else if (std.mem.eql(u8, key, "macos_host")) {
            try macos_hosts.append(a, val);
        } else if (std.mem.eql(u8, key, "watchdog_idle_secs")) {
            cfg.watchdog_idle_secs = val;
        } else if (std.mem.eql(u8, key, "watchdog_sample_secs")) {
            cfg.watchdog_sample_secs = val;
        } else if (std.mem.eql(u8, key, "build_arg")) {
            try build_args.append(a, val);
        } else if (std.mem.eql(u8, key, "link_tail")) {
            try link_tail.append(a, val);
        } else {
            why.* = try std.fmt.allocPrint(a, "unknown key {s}", .{key});
            return error.UnknownKey;
        }
    }
    cfg.macos_hosts = try macos_hosts.toOwnedSlice(a);
    const macos = cfg.deployment_target.len != 0 or cfg.macos_hosts.len != 0;
    if (macos and (cfg.zig.len != 0 or cfg.cc_target.len != 0)) {
        why.* = "a macOS toolchain (deployment_target, macos_host) names no zig and no cc_target";
        return error.BadLine;
    }
    const required: []const []const u8 = if (macos) &.{ "wrapper", "compiler", "deployment_target" } else &.{ "wrapper", "compiler", "zig", "cc_target" };
    inline for (.{ "wrapper", "compiler", "zig", "cc_target", "deployment_target" }) |k| {
        for (required) |r| {
            if (std.mem.eql(u8, r, k) and @field(cfg, k).len == 0) {
                why.* = try std.fmt.allocPrint(a, "{s} is not set", .{k});
                return error.Missing;
            }
        }
    }
    if (macos and cfg.macos_hosts.len == 0) {
        why.* = "macos_host is not set: a macOS compile names the hosts it may run on";
        return error.Missing;
    }
    cfg.build_args = try build_args.toOwnedSlice(a);
    cfg.link_tail = try link_tail.toOwnedSlice(a);
    return cfg;
}

/// The wrapper's command line: its executable, its options, then `args` (mopm's) with `build_args` inserted right
/// after the mojo subcommand when that is `build`. `dir` is the toolchain directory.
pub fn buildArgv(a: std.mem.Allocator, dir: []const u8, cfg: Cfg, args: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    try out.append(a, try std.fs.path.join(a, &.{ dir, cfg.wrapper }));
    try out.append(a, try std.fmt.allocPrint(a, "--compiler={s}", .{try std.fs.path.join(a, &.{ dir, cfg.compiler })}));
    if (cfg.deployment_target.len != 0) {
        // The macOS wrapper links with the host's C driver: no zig, no cc target.
        try out.append(a, try std.fmt.allocPrint(a, "--deployment-target={s}", .{cfg.deployment_target}));
        for (cfg.macos_hosts) |h| try out.append(a, try std.fmt.allocPrint(a, "--macos-host={s}", .{h}));
    } else {
        try out.append(a, try std.fmt.allocPrint(a, "--zig={s}", .{try std.fs.path.join(a, &.{ dir, cfg.zig })}));
        try out.append(a, try std.fmt.allocPrint(a, "--cc-target={s}", .{cfg.cc_target}));
    }
    try out.append(a, try std.fmt.allocPrint(a, "--watchdog-idle-secs={s}", .{cfg.watchdog_idle_secs}));
    try out.append(a, try std.fmt.allocPrint(a, "--watchdog-sample-secs={s}", .{cfg.watchdog_sample_secs}));
    for (cfg.link_tail) |t| try out.append(a, try std.fmt.allocPrint(a, "--link-tail={s}", .{t}));
    // mopm gives `precompile` the staged `src/` directory as the source root and the package inside it as the package. The
    // wrapper's precompile contract (compile_args.zig) is that the source root IS the package directory: only then does it run the
    // compiler from the package's parent and give the package by its basename, so the `.mojoc` records `<name>/<file>.mojo`. With
    // mopm's root the compiler gets the absolute staged path and records it, and the same package built at another path is other
    // bytes. So the root is rewritten to the package argument here.
    const package_dir = precompilePackage(args);
    var after_sep: ?usize = null;
    for (args, 0..) |arg, i| {
        if (package_dir) |pd| {
            if (std.mem.startsWith(u8, arg, "--source-root=")) {
                try out.append(a, try std.fmt.allocPrint(a, "--source-root={s}", .{pd}));
                continue;
            }
        }
        try out.append(a, arg);
        if (after_sep == null and std.mem.eql(u8, arg, "--")) after_sep = i;
        if (after_sep) |s| {
            if (i == s + 1 and std.mem.eql(u8, arg, "build")) try out.appendSlice(a, cfg.build_args);
        }
    }
    return out.toOwnedSlice(a);
}

/// The package argument of a `precompile` whose `--source-root` is its parent: the one positional argument (not an option, not the
/// value of `-o` or `-I <dir>`) that sits directly in the root. Null for anything else (a build, or a root that is already the package).
pub fn precompilePackage(args: []const []const u8) ?[]const u8 {
    var root: ?[]const u8 = null;
    var sep: ?usize = null;
    for (args, 0..) |arg, i| {
        if (std.mem.startsWith(u8, arg, "--source-root=")) root = arg["--source-root=".len..];
        if (sep == null and std.mem.eql(u8, arg, "--")) sep = i;
    }
    const r = root orelse return null;
    const s = sep orelse return null;
    if (s + 1 >= args.len or !std.mem.eql(u8, args[s + 1], "precompile")) return null;
    var prev: []const u8 = "";
    for (args[s + 2 ..]) |arg| {
        defer prev = arg;
        if (arg.len == 0 or arg[0] == '-') continue;
        if (std.mem.eql(u8, prev, "-o") or std.mem.eql(u8, prev, "-I")) continue;
        const dn = std.fs.path.dirname(arg) orelse continue;
        if (std.mem.eql(u8, dn, r)) return arg;
    }
    return null;
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("mojo_launch: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    const dir = try std.fs.selfExeDirPathAlloc(a);
    const cfg_path = try std.fs.path.join(a, &.{ dir, "toolchain.cfg" });
    const text = std.fs.cwd().readFileAlloc(a, cfg_path, 1 << 16) catch |e| die("cannot read {s}: {s}", .{ cfg_path, @errorName(e) });
    var why: []const u8 = "";
    const cfg = parseCfg(a, text, &why) catch |e| die("{s}: {s} ({s})", .{ cfg_path, why, @errorName(e) });
    const argv = try buildArgv(a, dir, cfg, args[1..]);
    // The wrapper builds the compiler's environment itself and inherits nothing: an empty one is passed on.
    var env = std.process.EnvMap.init(a);
    const err = std.process.execve(a, argv, &env);
    die("cannot execute {s}: {s}", .{ argv[0], @errorName(err) });
}
