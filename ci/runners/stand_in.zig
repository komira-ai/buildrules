//! A stand-in for the pinned zig, so a rule that runs zig can be built against it: it accepts exactly the command line and the environment the rule is
//! meant to give, and fails, saying what differs, on anything else. It compiles nothing; it writes `ok <shape>` to the output the command line names.
//!
//! Five shapes, told apart by the command line (the rules are in rules/zig/zig.bzl, rules/cxx/defs.bzl, rules/node/defs.bzl and rules/rust/toolchain.bzl):
//!   zig_exe     build-exe -OReleaseSafe -target x86_64-linux-musl -fstrip SRC -femit-bin=OUT
//!   rust        build-exe SRC -O ReleaseSafe -fstrip -target x86_64-linux-musl -femit-bin=OUT --name rustc_launch
//!   c_exe       cc -target x86_64-linux-musl -O2 -static -Wall -Werror SRC -o OUT
//!   c_shared    cc -target x86_64-linux-gnu.2.34 -O2 -g0 -fPIC -shared -Wall -Werror -Wl,-soname,libstand_in.so.1 -Wl,--build-id=none SRC -o OUT
//!   node        cc -target x86_64-linux-gnu.2.34 -shared -fPIC -O2 -fvisibility=hidden -Wall -Werror -Wl,-z,undefs -o OUT -I<dir> -DSTAND_IN=1 SRC
//! The environment is the one `check run` makes: the cache directories and HOME inside a private scratch directory of the action's
//! `$BUCK_SCRATCH_PATH`, made absolute, named for the rule (`buildrules`, `c_exe`, `c_shared`, `buildrules`, `br`), and the action's working directory.

const std = @import("std");

const Shape = enum { zig_exe, rust, c_exe, c_shared, node };

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writer().print("stand-in zig: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(1);
}

fn has(argv: []const []const u8, word: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, word)) return true;
    }
    return false;
}

fn shapeOf(argv: []const []const u8) Shape {
    if (argv.len < 2) fail("no command: {d} argument(s)", .{argv.len});
    if (std.mem.eql(u8, argv[1], "build-exe")) {
        if (argv.len > 2 and std.mem.startsWith(u8, argv[2], "-O")) return .zig_exe;
        return .rust;
    }
    if (std.mem.eql(u8, argv[1], "cc")) {
        if (has(argv, "-static")) return .c_exe;
        if (has(argv, "-fvisibility=hidden")) return .node;
        return .c_shared;
    }
    fail("unknown command {s}", .{argv[1]});
}

/// The arguments after the program's name must be `want`, one for one; a want that starts with `*` is only a prefix of the argument (`*-femit-bin=`).
fn expectArgs(shape: Shape, args: []const []const u8, want: []const []const u8) void {
    if (args.len != want.len) fail("{s}: {d} arguments, expected {d}: {s}", .{ @tagName(shape), args.len, want.len, args[0] });
    for (want, 0..) |w, i| {
        const ok = if (w[0] == '*') std.mem.startsWith(u8, args[i], w[1..]) else std.mem.eql(u8, args[i], w);
        if (!ok) fail("{s}: argument {d} is `{s}`, expected `{s}`", .{ @tagName(shape), i + 1, args[i], w });
    }
}

/// The path the command line names for its output, and the checks of the arguments of the shape.
fn checkArgs(shape: Shape, argv: []const []const u8) []const u8 {
    const args = argv[1..];
    switch (shape) {
        .zig_exe => {
            expectArgs(shape, args, &.{ "build-exe", "-OReleaseSafe", "-target", "x86_64-linux-musl", "-fstrip", "*", "*-femit-bin=" });
            return args[6]["-femit-bin=".len..];
        },
        .rust => {
            expectArgs(shape, args, &.{ "build-exe", "*", "-O", "ReleaseSafe", "-fstrip", "-target", "x86_64-linux-musl", "*-femit-bin=", "--name", "rustc_launch" });
            return args[7]["-femit-bin=".len..];
        },
        .c_exe => {
            expectArgs(shape, args, &.{ "cc", "-target", "x86_64-linux-musl", "-O2", "-static", "-Wall", "-Werror", "*", "-o", "*" });
            return args[9];
        },
        .c_shared => {
            expectArgs(shape, args, &.{ "cc", "-target", "x86_64-linux-gnu.2.34", "-O2", "-g0", "-fPIC", "-shared", "-Wall", "-Werror", "-Wl,-soname,libstand_in.so.1", "-Wl,--build-id=none", "*", "-o", "*" });
            return args[13];
        },
        .node => {
            expectArgs(shape, args, &.{ "cc", "-target", "x86_64-linux-gnu.2.34", "-shared", "-fPIC", "-O2", "-fvisibility=hidden", "-Wall", "-Werror", "-Wl,-z,undefs", "-o", "*", "*-I", "-DSTAND_IN=1", "*" });
            if (!std.mem.endsWith(u8, args[14], "stand_in.c")) fail("node: the source is `{s}`, expected stand_in.c", .{args[14]});
            return args[11];
        },
    }
}

fn scratchName(shape: Shape) []const u8 {
    return switch (shape) {
        .zig_exe, .node => "buildrules",
        .c_exe => "c_exe",
        .c_shared => "c_shared",
        .rust => "br",
    };
}

fn env(a: std.mem.Allocator, name: []const u8) []const u8 {
    return std.process.getEnvVarOwned(a, name) catch fail("{s} is not set", .{name});
}

fn checkEnv(a: std.mem.Allocator, shape: Shape) void {
    const here = std.process.getCwdAlloc(a) catch |e| fail("no working directory: {s}", .{@errorName(e)});
    const bs = env(a, "BUCK_SCRATCH_PATH");
    const base = if (bs.len > 0 and bs[0] == '/') bs else std.fmt.allocPrint(a, "{s}/{s}", .{ here, bs }) catch fail("out of memory", .{});
    const scratch = std.fmt.allocPrint(a, "{s}/{s}", .{ base, scratchName(shape) }) catch fail("out of memory", .{});
    const rust = shape == .rust;
    const want = [_][2][]const u8{
        .{ "ZIG_GLOBAL_CACHE_DIR", if (rust) "g" else "zig-global" },
        .{ "ZIG_LOCAL_CACHE_DIR", if (rust) "l" else "zig-local" },
        .{ "HOME", if (rust) "" else "home" },
    };
    for (want) |pair| {
        const got = env(a, pair[0]);
        const expected = if (pair[1].len == 0) scratch else std.fmt.allocPrint(a, "{s}/{s}", .{ scratch, pair[1] }) catch fail("out of memory", .{});
        if (!std.mem.eql(u8, got, expected)) fail("{s}: {s} is `{s}`, expected `{s}`", .{ @tagName(shape), pair[0], got, expected });
        std.fs.accessAbsolute(got, .{}) catch |e| fail("{s}: the directory {s} names ({s}) is not there: {s}", .{ @tagName(shape), pair[0], got, @errorName(e) });
    }
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = std.process.argsAlloc(a) catch fail("out of memory", .{});
    const shape = shapeOf(argv);
    const out = checkArgs(shape, argv);
    checkEnv(a, shape);
    const file = std.fs.cwd().createFile(out, .{}) catch |e| fail("cannot write {s} (the working directory is not the action's): {s}", .{ out, @errorName(e) });
    defer file.close();
    file.writer().print("ok {s}\n", .{@tagName(shape)}) catch fail("cannot write {s}", .{out});
}
