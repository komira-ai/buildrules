//! The real platform of blackbox_run (io.zig, `Plat`): the driver run by std.process.Child with the streams inherited, and its status in the shell's
//! form.

const std = @import("std");
const posix = std.posix;
const io_mod = @import("io.zig");

var anchor: u8 = 0;

/// The shell's form of how a process ended: its exit code, 128+N for a death by signal N, 255 for anything else (a stop, which `wait` does not give).
pub fn statusOf(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| @intCast((128 + (s & 0x7f)) & 0xff),
        else => 255,
    };
}

/// Runs `argv` with exactly `env` and the streams inherited, and waits for it.
fn runInherit(_: *anyopaque, a: std.mem.Allocator, argv: []const []const u8, env: *const std.process.EnvMap) anyerror!u8 {
    // The refusals exec reports to nobody (a forked child that cannot exec just exits) are found here, before the fork: not there, not executable.
    try posix.access(argv[0], posix.X_OK);
    var child = std.process.Child.init(argv, a);
    child.env_map = env;
    return statusOf(try child.spawnAndWait());
}

pub fn real() io_mod.Plat {
    return .{ .ctx = &anchor, .runInherit = runInherit };
}
