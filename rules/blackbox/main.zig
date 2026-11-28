//! blackbox_run: the program a `blackbox_test` target runs (README.md). `main` only forwards to `entry` (cli.zig) with the process's own streams,
//! arguments, environment, working directory and user, the root of the file system, and the real platform (plat.zig).

const std = @import("std");
const cli = @import("cli.zig");

pub fn main() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = std.process.argsAlloc(a) catch return 1;
    const environ = a.alloc([]const u8, std.os.environ.len) catch return 1;
    for (std.os.environ, 0..) |entry_z, k| environ[k] = std.mem.span(entry_z);
    const cwd = std.process.getCwdAlloc(a) catch return 1;
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);
    var err = std.fs.File.stderr().writer(&err_buf);
    var root = std.fs.openDirAbsolute("/", .{ .iterate = true }) catch return 1;
    defer root.close();
    return cli.entry(a, .{
        .out = &out.interface,
        .err = &err.interface,
        .root = root,
        .argv = argv,
        .environ = environ,
        .cwd = cwd,
        .plat = @import("plat.zig").real(),
    });
}
