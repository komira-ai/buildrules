//! The real platform of pg_run (pg_run.zig, `Plat`): processes started by std.process.Child and waited for with waitpid, signals, the monotonic clock,
//! the C library's sleep, and random bytes.

const std = @import("std");
const posix = std.posix;
const run = @import("pg_run.zig");

var anchor: u8 = 0;

/// The shell's form of a wait status: the exit code, or 128+N for a death by signal N.
pub fn shellStatus(raw: u32) u8 {
    const sig = raw & 0x7f;
    if (sig == 0) return @intCast((raw >> 8) & 0xff);
    return @intCast((128 + sig) & 0xff);
}

fn spawn(_: *anyopaque, a: std.mem.Allocator, argv: []const []const u8, env: *const std.process.EnvMap, stdin_null: bool) anyerror!run.Pid {
    // This release of std reports a failed exec to nobody (the forked child just exits), so the two refusals pg_run names are found here, before the fork.
    posix.access(argv[0], posix.X_OK) catch |e| return switch (e) {
        error.PermissionDenied => error.AccessDenied,
        else => e,
    };
    var child = std.process.Child.init(argv, a);
    child.env_map = env;
    // StdIo is Inherit (0), Ignore (1), ...: no branch to cover, and a false and a true are both run by the tests.
    child.stdin_behavior = @enumFromInt(@intFromBool(stdin_null));
    try child.spawn();
    return child.id;
}

fn poll(_: *anyopaque, pid: run.Pid) ?u8 {
    const r = posix.waitpid(pid, 1);
    if (r.pid != pid) return null;
    return shellStatus(r.status);
}

fn wait(_: *anyopaque, pid: run.Pid) u8 {
    return shellStatus(posix.waitpid(pid, 0).status);
}

fn kill(_: *anyopaque, pid: run.Pid, sig: u8) void {
    posix.kill(pid, sig) catch {};
}

fn sleepMs(_: *anyopaque, ms: u64) void {
    posix.nanosleep(ms / 1000, (ms % 1000) * 1_000_000);
}

fn nowMs(_: *anyopaque) u64 {
    var ts: posix.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn randomHex(_: *anyopaque, out: *[8]u8) void {
    var bytes: [4]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    out.* = std.fmt.bytesToHex(bytes, .lower);
}

pub fn real() run.Plat {
    return .{
        .ctx = &anchor,
        .spawn = spawn,
        .poll = poll,
        .wait = wait,
        .kill = kill,
        .sleepMs = sleepMs,
        .nowMs = nowMs,
        .randomHex = randomHex,
    };
}
