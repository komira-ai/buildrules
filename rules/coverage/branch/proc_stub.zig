//! A stand-in program for the process tests of proc.zig (cov_branch_proc_test.zig). It does what its first argument says:
//!
//!   env            write every NAME=VALUE of its environment to stdout, one per line, sorted
//!   cwd            write its working directory to stdout
//!   argv           write its arguments after `argv`, one per line, to stdout
//!   say OUT ERR    write OUT to stdout and ERR to stderr
//!   exit N         exit with status N
//!   kill           kill itself with SIGKILL

const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    const out = std.fs.File.stdout();
    const err = std.fs.File.stderr();
    if (args.len < 2) std.process.exit(64);
    const mode = args[1];
    if (std.mem.eql(u8, mode, "env")) {
        var env = try std.process.getEnvMap(a);
        var lines = std.ArrayList([]const u8).empty;
        var it = env.iterator();
        while (it.next()) |e| try lines.append(a, try std.fmt.allocPrint(a, "{s}={s}\n", .{ e.key_ptr.*, e.value_ptr.* }));
        std.mem.sort([]const u8, lines.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (lines.items) |l| try out.writeAll(l);
    } else if (std.mem.eql(u8, mode, "cwd")) {
        try out.writeAll(try std.process.getCwdAlloc(a));
    } else if (std.mem.eql(u8, mode, "argv")) {
        for (args[2..]) |x| {
            try out.writeAll(x);
            try out.writeAll("\n");
        }
    } else if (std.mem.eql(u8, mode, "say") and args.len == 4) {
        try out.writeAll(args[2]);
        try err.writeAll(args[3]);
    } else if (std.mem.eql(u8, mode, "exit") and args.len == 3) {
        std.process.exit(try std.fmt.parseInt(u8, args[2], 10));
    } else if (std.mem.eql(u8, mode, "kill")) {
        std.posix.raise(std.posix.SIG.KILL) catch {};
    } else std.process.exit(64);
}
