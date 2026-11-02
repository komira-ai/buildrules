//! A stand-in for the pinned multi-call binary (the applets `archive_files` runs), for the rows of ci/faulty/BUCK that need `stat -c %h` to print no number.
//!
//! The rule (ci/faulty/applets.bzl) puts three files in one directory: this program as `applets`, the pinned binary under its own name, and `stat_output`. Called as `applets` it does what
//! the pinned binary does, except that `--install -s <dir>` links every applet of the pinned binary to this program and not to it. Called under the name of an applet it runs that applet
//! of the pinned binary with the same arguments, except `stat -c %h`: that prints the text of `stat_output` and a line break, and succeeds.

const std = @import("std");

/// The file name of the pinned binary in `dir`: the one entry that is neither this program nor the text. A multi-call binary runs applets by the name it is called by, and this
/// one is called by its own.
fn pinned(a: std.mem.Allocator, dir: []const u8) ![]const u8 {
    var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    while (try it.next()) |e| {
        if (!std.mem.eql(u8, e.name, "applets") and !std.mem.eql(u8, e.name, "stat_output")) return a.dupe(u8, e.name);
    }
    return error.NoPinnedBinary;
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    const args = try std.process.argsAlloc(a);
    const self = try std.fs.selfExePathAlloc(a);
    const dir = std.fs.path.dirname(self) orelse return error.NoDirectory;
    const real = try std.fs.path.join(a, &.{ dir, try pinned(a, dir) });
    const name = std.fs.path.basename(args[0]);

    if (std.mem.eql(u8, name, "applets")) {
        if (args.len == 4 and std.mem.eql(u8, args[1], "--install") and std.mem.eql(u8, args[2], "-s")) {
            const listed = try std.process.Child.run(.{ .allocator = a, .argv = &.{ real, "--list" } });
            var lines = std.mem.tokenizeScalar(u8, listed.stdout, '\n');
            while (lines.next()) |applet| {
                const link = try std.fs.path.join(a, &.{ args[3], applet });
                try std.fs.cwd().symLink(self, link, .{});
            }
            return;
        }
        var argv = try a.alloc([]const u8, args.len);
        argv[0] = real;
        for (args[1..], 1..) |arg, i| argv[i] = arg;
        return std.process.execv(a, argv);
    }

    if (std.mem.eql(u8, name, "stat") and args.len == 4 and std.mem.eql(u8, args[1], "-c") and std.mem.eql(u8, args[2], "%h")) {
        const text = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ dir, "stat_output" }), 1 << 16);
        _ = try std.posix.write(1, text);
        _ = try std.posix.write(1, "\n");
        return;
    }

    var argv = try a.alloc([]const u8, args.len + 1);
    argv[0] = real;
    argv[1] = name;
    for (args[1..], 2..) |arg, i| argv[i] = arg;
    return std.process.execv(a, argv);
}
