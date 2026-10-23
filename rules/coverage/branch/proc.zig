//! proc: run one command, wait for it and report how it ended (the process step of cov_branch).
//!
//! The command:
//!   - `argv[0]` is a path, run with execve: no PATH search, so a tool runs exactly the program it was given;
//!   - `env` is the whole environment it gets (nothing is inherited);
//!   - `cwd`, when given, is the directory it starts in;
//!   - stdin is inherited; stdout and stderr are inherited, or a file each (created or truncated). `stderr_to_stdout` gives stderr
//!     the stdout descriptor, so the two interleave in one file as `>f 2>&1`.
//!
//! It waits for the command alone: a process the command left running is not waited for and not killed. There is no time limit; a
//! command that hangs holds its build action until the executor's own timeout, which reaches it because it stays in the caller's
//! process group.
//!
//! An execve (or chdir) that fails is reported by the child on its stderr (`proc: cannot run <argv0>: errno <n>`) with exit status
//! 127, as a shell reports a command it cannot run.
//!
//! No import of its own: a pure std module.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const Spec = struct {
    /// argv[0] is the program's path.
    argv: []const []const u8,
    /// NAME=VALUE entries: the command's whole environment.
    env: []const []const u8,
    cwd: ?[]const u8 = null,
    stdout_path: ?[]const u8 = null,
    /// Ignored when `stderr_to_stdout` is set (the file is still created).
    stderr_path: ?[]const u8 = null,
    /// stderr gets the stdout descriptor; it wins over `stderr_path`.
    stderr_to_stdout: bool = false,
};

pub const Status = union(enum) {
    exited: u8,
    signaled: u8,
};

pub const Outcome = struct {
    status: Status,

    /// The status a shell gives it: the exit code, or 128 + the signal.
    pub fn shellStatus(self: Outcome) u8 {
        return switch (self.status) {
            .exited => |c| c,
            .signaled => |s| 128 +% s,
        };
    }
};

pub const Error = error{Unexpected} || std.mem.Allocator.Error || posix.OpenError || posix.ForkError;

/// NAME=VALUE entries of `map`, sorted by name (a fixed order, so a command's environment does not depend on the map's).
pub fn envFromMap(alloc: std.mem.Allocator, map: *const std.process.EnvMap) ![]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    var it = map.iterator();
    while (it.next()) |e| try names.append(alloc, e.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, lessThan);
    const out = try alloc.alloc([]const u8, names.items.len);
    for (names.items, 0..) |n, i| out[i] = try std.fmt.allocPrint(alloc, "{s}={s}", .{ n, map.get(n).? });
    return out;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn zArray(alloc: std.mem.Allocator, items: []const []const u8) ![:null]?[*:0]const u8 {
    const out = try alloc.allocSentinel(?[*:0]const u8, items.len, null);
    for (items, 0..) |s, i| out[i] = (try alloc.dupeZ(u8, s)).ptr;
    return out;
}

fn openForWrite(path: []const u8) posix.OpenError!posix.fd_t {
    return posix.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
}

/// Runs `spec` (module comment). Allocations are `alloc`'s: give it an arena.
pub fn run(alloc: std.mem.Allocator, spec: Spec) Error!Outcome {
    std.debug.assert(spec.argv.len > 0);
    const argv = try zArray(alloc, spec.argv);
    const envp = try zArray(alloc, spec.env);
    const msg = try std.fmt.allocPrint(alloc, "proc: cannot run {s}: ", .{spec.argv[0]});
    const dir: ?[:0]const u8 = if (spec.cwd) |d| try alloc.dupeZ(u8, d) else null;

    // Opened before the fork: the child only moves descriptors and execs.
    const out_fd: ?posix.fd_t = if (spec.stdout_path) |p| try openForWrite(p) else null;
    defer if (out_fd) |fd| posix.close(fd);
    const err_fd: ?posix.fd_t = if (spec.stderr_path) |p| try openForWrite(p) else null;
    defer if (err_fd) |fd| posix.close(fd);

    const pid = try posix.fork();
    if (pid == 0) child(argv, envp, dir, msg, out_fd, err_fd, spec.stderr_to_stdout);
    return .{ .status = reap(pid) };
}

fn child(
    argv: [:null]?[*:0]const u8,
    envp: [:null]?[*:0]const u8,
    dir: ?[:0]const u8,
    msg: []const u8,
    out_fd: ?posix.fd_t,
    err_fd: ?posix.fd_t,
    err_to_out: bool,
) noreturn {
    if (out_fd) |fd| _ = linux.dup2(fd, 1);
    if (err_to_out) {
        _ = linux.dup2(1, 2);
    } else if (err_fd) |fd| _ = linux.dup2(fd, 2);
    var rc: usize = 0;
    if (dir) |d| rc = linux.chdir(d.ptr);
    if (rc == 0) rc = linux.execve(argv[0].?, argv.ptr, envp.ptr);
    // No allocation after the fork: the number is formatted on the stack.
    var buf: [32]u8 = undefined;
    const tail = std.fmt.bufPrint(&buf, "errno {d}\n", .{@intFromEnum(linux.E.init(rc))}) catch "errno ?\n";
    _ = linux.write(2, msg.ptr, msg.len);
    _ = linux.write(2, tail.ptr, tail.len);
    linux.exit_group(127);
}

fn reap(pid: i32) Status {
    while (true) {
        var st: u32 = 0;
        const rc = linux.wait4(pid, &st, 0, null);
        switch (linux.E.init(rc)) {
            .SUCCESS => return decode(st),
            .INTR => continue,
            // Cannot happen for our own child; read as SIGKILL, never as a pass.
            else => return .{ .signaled = linux.SIG.KILL },
        }
    }
}

pub fn decode(st: u32) Status {
    if (linux.W.IFEXITED(st)) return .{ .exited = linux.W.EXITSTATUS(st) };
    return .{ .signaled = @intCast(linux.W.TERMSIG(st)) };
}
