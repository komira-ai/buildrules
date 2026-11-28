//! The real platform of blackbox_run (io.zig, `Plat`): processes forked into groups of their own with their output in a log (or with the streams
//! inherited, for docker), waited for with waitpid,
//! signals to their groups, the monotonic clock, loopback ports and connections, and random bytes.

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

/// The result of a system call as a descriptor: the descriptor, or a negative number when it failed (which a later call is then refused).
fn fdOf(rc: usize) i32 {
    return @truncate(@as(isize, @bitCast(rc)));
}

/// Forks `argv` with exactly `env`; with `log`, in a process group of its own, stdin /dev/null and stdout and stderr appended to `log`, else in this
/// process's group with the streams inherited. Every choice is made here, before the fork: the child makes the same system calls whatever it was asked
/// (a `dup2` of a descriptor onto itself, a `setpgid` into the group it is in, are nothing), and looks at none of their results, as it has nowhere to
/// report a failure but its status (127: the program could not be run). It runs in a process the tests' coverage does not follow, so it has no branch.
fn forkExec(a: std.mem.Allocator, argv: []const []const u8, env: *const std.process.EnvMap, log: ?[]const u8) anyerror!io_mod.Pid {
    try checkRunnable(argv[0]);
    const argv_z = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, k| argv_z[k] = (try a.dupeZ(u8, arg)).ptr;
    const envp = try std.process.createNullDelimitedEnvMap(a, env);
    // Opened here, so a log that cannot be opened is this call's error. Both descriptors are close-on-exec; their copies on 0, 1 and 2 are not.
    const out_fd: i32 = if (log) |path| try posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644) else 1;
    const in_fd: i32 = if (log != null) fdOf(linux.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0)) else 0;
    const err_fd: i32 = if (log != null) out_fd else 2;
    const group: posix.pid_t = if (log != null) 0 else fdOf(linux.syscall1(.getpgid, 0));
    const pid = posix.fork() catch |e| {
        _ = closeOwn(log, out_fd, in_fd, 0);
        return e;
    };
    if (pid == 0) {
        _ = linux.setpgid(0, group);
        _ = linux.dup2(in_fd, 0);
        _ = linux.dup2(out_fd, 1);
        _ = linux.dup2(err_fd, 2);
        _ = linux.execve(argv_z[0].?, argv_z, envp);
        linux.exit_group(127);
    }
    // Also set from this side, so a signal to the group sent before the child ran its own setpgid reaches it (`0` is the child's own pid; it fails,
    // harmlessly, once the child has run exec, and for a child in this process's group it is nothing).
    _ = linux.setpgid(pid, group);
    return closeOwn(log, out_fd, in_fd, pid);
}

/// Closes the log and /dev/null this process opened for a child (none when the child inherits the streams), and gives back `pid`.
fn closeOwn(log: ?[]const u8, out_fd: i32, in_fd: i32, pid: io_mod.Pid) io_mod.Pid {
    if (log != null) {
        _ = linux.close(out_fd);
        _ = linux.close(in_fd);
    }
    return pid;
}

fn spawn(_: *anyopaque, a: std.mem.Allocator, argv: []const []const u8, env: *const std.process.EnvMap, log: []const u8) anyerror!io_mod.Pid {
    return forkExec(a, argv, env, log);
}

fn runInherit(_: *anyopaque, a: std.mem.Allocator, argv: []const []const u8, env: *const std.process.EnvMap) anyerror!u8 {
    return wait(&anchor, try forkExec(a, argv, env, null));
}

fn poll(_: *anyopaque, pid: io_mod.Pid) ?u8 {
    const r = posix.waitpid(pid, 1);
    if (r.pid != pid) return null;
    return shellStatus(r.status);
}

fn wait(_: *anyopaque, pid: io_mod.Pid) u8 {
    return shellStatus(posix.waitpid(pid, 0).status);
}

fn kill(_: *anyopaque, pid: io_mod.Pid, sig: u8) void {
    posix.kill(-pid, sig) catch {};
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

fn loopback(port: u16) std.net.Address {
    return std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
}

/// System calls whose results are not looked at: a socket that cannot be made or bound has no name, and the port read back stays 0, which the runner
/// refuses (run.zig).
fn reservePort(_: *anyopaque) u16 {
    const fd = fdOf(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    var addr = loopback(0);
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    _ = linux.bind(fd, &addr.any, len);
    _ = linux.getsockname(fd, &addr.any, &len);
    _ = linux.close(fd);
    return addr.getPort();
}

fn accepts(_: *anyopaque, port: u16) bool {
    const stream = std.net.tcpConnectToAddress(loopback(port)) catch return false;
    stream.close();
    return true;
}

pub fn real() io_mod.Plat {
    return .{
        .ctx = &anchor,
        .spawn = spawn,
        .runInherit = runInherit,
        .poll = poll,
        .wait = wait,
        .kill = kill,
        .sleepMs = sleepMs,
        .nowMs = nowMs,
        .randomHex = randomHex,
        .reservePort = reservePort,
        .accepts = accepts,
    };
}
