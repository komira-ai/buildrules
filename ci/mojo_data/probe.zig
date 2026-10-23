//! data_probe: a stand-in for a compiled Mojo test that reads what `mojo_package(test_data = ..., test_env = ..., test_layout = ...)` gives it (docs/contract.md,
//! section 12.9). The fixtures of ci/mojo_data run it as the test, so the staging is proven without a Mojo compiler. It passes only when all of these hold, and
//! says which one did not (the build is red with that line):
//!
//! always (the scratch the runner owns):
//!   1. TMPDIR, TEST_TMPDIR and HOME are set, absolute, directories that exist and are empty, TMPDIR and TEST_TMPDIR are the same one and HOME is another, and
//!      a file can be written in each;
//! the default layout (PROBE_LAYOUT is not set):
//!   2. BUILDRULES_TEST_DATA is an absolute path, and it is the working directory;
//!   3. `greeting.txt`, opened by a relative path, holds `staged data` and a newline;
//! the installed layout (PROBE_LAYOUT is `installed`):
//!   2. the running executable is `<root>/bin/<name>` and the working directory is `<root>`;
//!   3. BUILDRULES_TEST_DATA is `<root>/share`, and `share/greeting.txt` (relative) holds `staged data` and a newline;
//! and in both:
//!   4. PROBE_MODE is `strict`;
//!   5. `bin/hello` (a program staged as data, at `share/bin/hello` in the installed layout) starts, which needs the executable bit, exits 0 and prints
//!      `hello from zig` and a newline.

const std = @import("std");

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    // Standard output, which a failed run shows (the standard error of a test run is not part of what the failure reports).
    const line = std.fmt.allocPrint(std.heap.page_allocator, "data_probe: " ++ fmt ++ "\n", args) catch std.process.exit(1);
    _ = std.posix.write(1, line) catch {};
    std.process.exit(1);
}

/// The private directory `name` names: set, absolute, there and empty; a file is written in it (and stays: the runner removes the directory with the run).
fn scratch(a: std.mem.Allocator, name: []const u8) []const u8 {
    const dir = std.process.getEnvVarOwned(a, name) catch fail("{s} is not set", .{name});
    if (dir.len == 0 or dir[0] != '/') fail("{s} is not an absolute path: {s}", .{ name, dir });
    var d = std.fs.openDirAbsolute(dir, .{ .iterate = true }) catch |e| fail("{s} {s} cannot be opened: {s}", .{ name, dir, @errorName(e) });
    defer d.close();
    var it = d.iterate();
    if (it.next() catch |e| fail("{s} {s} cannot be read: {s}", .{ name, dir, @errorName(e) })) |entry| fail("{s} {s} is not empty: it holds {s}", .{ name, dir, entry.name });
    d.writeFile(.{ .sub_path = "probe.txt", .data = "x" }) catch |e| fail("cannot write in {s} {s}: {s}", .{ name, dir, @errorName(e) });
    return dir;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();

    const tmp = scratch(a, "TMPDIR");
    const test_tmp = std.process.getEnvVarOwned(a, "TEST_TMPDIR") catch fail("TEST_TMPDIR is not set", .{});
    if (!std.mem.eql(u8, tmp, test_tmp)) fail("TEST_TMPDIR {s} is not TMPDIR {s}", .{ test_tmp, tmp });
    const home = scratch(a, "HOME");
    if (std.mem.eql(u8, tmp, home)) fail("HOME and TMPDIR are the same directory: {s}", .{home});

    const installed = if (std.process.getEnvVarOwned(a, "PROBE_LAYOUT")) |layout| std.mem.eql(u8, layout, "installed") else |_| false;
    const here = try std.fs.cwd().realpathAlloc(a, ".");
    const dir = std.process.getEnvVarOwned(a, "BUILDRULES_TEST_DATA") catch fail("BUILDRULES_TEST_DATA is not set", .{});
    if (dir.len == 0 or dir[0] != '/') fail("BUILDRULES_TEST_DATA is not an absolute path: {s}", .{dir});
    const named = std.fs.cwd().realpathAlloc(a, dir) catch |e| fail("BUILDRULES_TEST_DATA {s} cannot be opened: {s}", .{ dir, @errorName(e) });
    var data: []const u8 = "greeting.txt";
    var hello: []const u8 = "bin/hello";
    if (installed) {
        const exe = try std.fs.selfExePathAlloc(a);
        const bin = std.fs.path.dirname(exe) orelse fail("the executable {s} has no directory", .{exe});
        if (!std.mem.eql(u8, std.fs.path.basename(bin), "bin")) fail("the executable {s} is not in a bin/ directory", .{exe});
        const root = std.fs.path.dirname(bin) orelse fail("the executable {s} has no root", .{exe});
        if (!std.mem.eql(u8, here, root)) fail("the working directory {s} is not the root {s} of the executable {s}", .{ here, root, exe });
        const share = try std.fs.path.join(a, &.{ root, "share" });
        if (!std.mem.eql(u8, named, share)) fail("BUILDRULES_TEST_DATA {s} is not {s}", .{ named, share });
        data = "share/greeting.txt";
        hello = "share/bin/hello";
    } else if (!std.mem.eql(u8, here, named)) {
        fail("the working directory {s} is not BUILDRULES_TEST_DATA {s}", .{ here, named });
    }

    const greeting = std.fs.cwd().readFileAlloc(a, data, 1 << 16) catch |e| fail("cannot read {s}: {s}", .{ data, @errorName(e) });
    if (!std.mem.eql(u8, greeting, "staged data\n")) fail("{s} holds {s}", .{ data, greeting });

    const mode = std.process.getEnvVarOwned(a, "PROBE_MODE") catch fail("PROBE_MODE is not set", .{});
    if (!std.mem.eql(u8, mode, "strict")) fail("PROBE_MODE is {s}, not strict", .{mode});

    const ran = std.process.Child.run(.{ .allocator = a, .argv = &.{hello} }) catch |e| fail("cannot start {s}: {s}", .{ hello, @errorName(e) });
    switch (ran.term) {
        .Exited => |code| if (code != 0) fail("{s} exited {d}", .{ hello, code }),
        else => fail("{s} did not exit", .{hello}),
    }
    if (!std.mem.eql(u8, ran.stdout, "hello from zig\n")) fail("{s} printed {s}", .{ hello, ran.stdout });
}
