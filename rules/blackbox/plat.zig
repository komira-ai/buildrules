//! The real platform of blackbox_run (io.zig, `Plat`): the driver forked with the streams inherited and waited for with waitpid.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const io_mod = @import("io.zig");

var anchor: u8 = 0;

/// The shell's form of a wait status: the exit code, or 128+N for a death by signal N.
pub fn shellStatus(raw: u32) u8 {
    const sig = raw & 0x7f;
    if (sig == 0) return @intCast((raw >> 8) & 0xff);
    return @intCast((128 + sig) & 0xff);
}

/// The refusals std's exec reports to nobody (a forked child that cannot exec just exits), found before the fork.
fn checkRunnable(path: []const u8) !void {
    posix.access(path, posix.X_OK) catch |e| return switch (e) {
        error.PermissionDenied => error.AccessDenied,
        else => e,
    };
}

/// Runs `argv` with exactly `env` and the streams inherited, and waits for it. The child side is system calls whose results are not looked at: it has
/// nowhere to report a failure but its status (127: the program could not be run), and it runs in a process the tests' coverage does not follow, so
/// it has no branch.
fn runInherit(_: *anyopaque, a: std.mem.Allocator, argv: []const []const u8, env: *const std.process.EnvMap) anyerror!u8 {
    try checkRunnable(argv[0]);
    const argv_z = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, k| argv_z[k] = (try a.dupeZ(u8, arg)).ptr;
    const envp = try std.process.createNullDelimitedEnvMap(a, env);
    const pid = try posix.fork();
    if (pid == 0) {
        _ = linux.execve(argv_z[0].?, argv_z, envp);
        linux.exit_group(127);
    }
    return shellStatus(posix.waitpid(pid, 0).status);
}

pub fn real() io_mod.Plat {
    return .{ .ctx = &anchor, .runInherit = runInherit };
}
