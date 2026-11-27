//! The entry point of sync_patch (sync_patch.zig, whose `run` is the whole command): the process's arguments, its working directory, a
//! real run of the sync and real paths, then what `run` said and its status. Nothing else is here, so the tests of the library are the
//! tests of the command.

const std = @import("std");
const P = @import("sync_patch.zig");

fn realPath(a: std.mem.Allocator, p: []const u8) anyerror![]u8 {
    return std.fs.cwd().realpathAlloc(a, p);
}

/// The sync, with this process's standard error, so its message is the build's.
fn spawn(a: std.mem.Allocator, argv: []const []const u8) anyerror!u8 {
    var child = std.process.Child.init(argv, a);
    return switch (try child.spawnAndWait()) {
        .Exited => |c| c,
        else => 1,
    };
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    // The action's scratch directory, which buck2 sets and discards (sync_stage's too).
    const scratch = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch ".br_scratch";
    var out = std.ArrayList(u8).empty;
    var err = std.ArrayList(u8).empty;
    const code = try P.run(a, std.fs.cwd(), argv[1..], .{ .scratch = scratch, .real = &realPath, .run = &spawn }, &out, &err);
    std.fs.File.stdout().writeAll(out.items) catch {};
    std.fs.File.stderr().writeAll(err.items) catch {};
    return code;
}
