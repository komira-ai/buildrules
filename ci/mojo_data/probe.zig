//! data_probe: a stand-in for a compiled Mojo test that reads what `mojo_package(test_data = ..., test_env = ...)` stages (docs/contract.md, section 12.9).
//! The fixtures of ci/mojo_data run it as the test, so the staging is proven without a Mojo compiler. It passes only when all of these hold, and says which one
//! did not (the build is red with that line):
//!
//!   1. BUILDRULES_TEST_DATA is an absolute path, and it is the working directory;
//!   2. `greeting.txt`, opened by a relative path, holds `staged data` and a newline;
//!   3. PROBE_MODE is `strict`;
//!   4. `bin/hello` (a program staged as data) starts, which needs the executable bit, exits 0 and prints `hello from zig` and a newline.

const std = @import("std");

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    // Standard output, which a failed run shows (the standard error of a test run is not part of what the failure reports).
    const line = std.fmt.allocPrint(std.heap.page_allocator, "data_probe: " ++ fmt ++ "\n", args) catch std.process.exit(1);
    _ = std.posix.write(1, line) catch {};
    std.process.exit(1);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();

    const dir = std.process.getEnvVarOwned(a, "BUILDRULES_TEST_DATA") catch fail("BUILDRULES_TEST_DATA is not set", .{});
    if (dir.len == 0 or dir[0] != '/') fail("BUILDRULES_TEST_DATA is not an absolute path: {s}", .{dir});
    const here = try std.fs.cwd().realpathAlloc(a, ".");
    const named = std.fs.cwd().realpathAlloc(a, dir) catch |e| fail("BUILDRULES_TEST_DATA {s} cannot be opened: {s}", .{ dir, @errorName(e) });
    if (!std.mem.eql(u8, here, named)) fail("the working directory {s} is not BUILDRULES_TEST_DATA {s}", .{ here, named });

    const greeting = std.fs.cwd().readFileAlloc(a, "greeting.txt", 1 << 16) catch |e| fail("cannot read greeting.txt: {s}", .{@errorName(e)});
    if (!std.mem.eql(u8, greeting, "staged data\n")) fail("greeting.txt holds {s}", .{greeting});

    const mode = std.process.getEnvVarOwned(a, "PROBE_MODE") catch fail("PROBE_MODE is not set", .{});
    if (!std.mem.eql(u8, mode, "strict")) fail("PROBE_MODE is {s}, not strict", .{mode});

    const ran = std.process.Child.run(.{ .allocator = a, .argv = &.{"bin/hello"} }) catch |e| fail("cannot start bin/hello: {s}", .{@errorName(e)});
    switch (ran.term) {
        .Exited => |code| if (code != 0) fail("bin/hello exited {d}", .{code}),
        else => fail("bin/hello did not exit", .{}),
    }
    if (!std.mem.eql(u8, ran.stdout, "hello from zig\n")) fail("bin/hello printed {s}", .{ran.stdout});
}
