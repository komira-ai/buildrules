//! node_stub: stands in for the pinned node in the tests of runner.zig, so that what `run` does around a program (the copy of
//! the tree, the environment, the exit status, the out directory) can be seen without node and without a shell.
//!
//! It adds one line to the file named by STUB_LOG: its own name (the last component of argv[0]), its arguments, each variable
//! named in STUB_SHOW (comma-separated) as ` NAME=value` or ` NAME=unset`, and with STUB_SEEN (comma-separated paths) ` seen=yes`
//! when every one of them exists in the working directory, else ` seen=no`. Then, in this order:
//!
//!   STUB_CHANGE=path    replaces the file at path with `changed`
//!   STUB_WRITE=path     writes `built` to path, making its directories
//!   STUB_KILL=1         kills itself with SIGKILL
//!   STUB_EXIT_ON=a:n    exits n when its first argument ends with `a`
//!   STUB_EXIT=n         exits n
//!
//! and otherwise exits 0.
const std = @import("std");

fn get(a: std.mem.Allocator, name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(a, name) catch null;
}

fn logLine(a: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var line = std.ArrayList(u8).empty;
    try line.appendSlice(a, std.fs.path.basename(args[0]));
    for (args[1..]) |x| {
        try line.append(a, ' ');
        try line.appendSlice(a, x);
    }
    if (get(a, "STUB_SHOW")) |names| {
        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |n| try line.writer(a).print(" {s}={s}", .{ n, get(a, n) orelse "unset" });
    }
    if (get(a, "STUB_SEEN")) |paths| {
        var all = true;
        var it = std.mem.splitScalar(u8, paths, ',');
        while (it.next()) |p| std.fs.cwd().access(p, .{}) catch {
            all = false;
        };
        try line.appendSlice(a, if (all) " seen=yes" else " seen=no");
    }
    try line.append(a, '\n');
    return line.items;
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (get(a, "STUB_LOG")) |path| {
        const f = try std.fs.cwd().createFile(path, .{ .truncate = false });
        defer f.close();
        try f.seekFromEnd(0);
        try f.writeAll(try logLine(a, args));
    }
    if (get(a, "STUB_CHANGE")) |p| try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "changed\n" });
    if (get(a, "STUB_WRITE")) |p| {
        if (std.fs.path.dirname(p)) |d| try std.fs.cwd().makePath(d);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "built\n" });
    }
    if (get(a, "STUB_KILL") != null) try std.posix.raise(std.posix.SIG.KILL);
    if (get(a, "STUB_EXIT_ON")) |rule| {
        const colon = std.mem.lastIndexOfScalar(u8, rule, ':') orelse return error.BadRule;
        if (args.len > 1 and std.mem.endsWith(u8, args[1], rule[0..colon])) return try std.fmt.parseInt(u8, rule[colon + 1 ..], 10);
    }
    if (get(a, "STUB_EXIT")) |n| return try std.fmt.parseInt(u8, n, 10);
    return 0;
}
