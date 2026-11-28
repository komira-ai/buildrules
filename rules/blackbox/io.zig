//! What every command of blackbox_run is given: its streams, its arguments, the root of the file system, its environment, and the platform (`Plat`) that
//! starts and stops processes, keeps the time and reserves ports. The program passes the real ones (main.zig, plat.zig); the tests pass buffers, a
//! directory of their own and a scripted platform, so every command runs in-process and its exact messages are read back.

const std = @import("std");

pub const Alloc = std.mem.Allocator;
pub const Oom = error{OutOfMemory};
pub const Pid = std.posix.pid_t;

/// The signals the runner sends (Linux numbers: the runner is a linux program).
pub const sigterm: u8 = 15;
pub const sigkill: u8 = 9;

pub const Plat = struct {
    ctx: *anyopaque,
    /// Starts `argv[0]` (a path, never looked for in PATH) in a process group of its own, with exactly `env` as its environment, stdin /dev/null, and
    /// stdout and stderr appended to the file `log`; its pid, or why it could not be started (`FileNotFound`: it is not there).
    spawn: *const fn (ctx: *anyopaque, a: Alloc, argv: []const []const u8, env: *const std.process.EnvMap, log: []const u8) anyerror!Pid,
    /// Runs `argv` with exactly `env`, the streams inherited, and gives its exit status (shell form); an error when it cannot be started.
    runInherit: *const fn (ctx: *anyopaque, a: Alloc, argv: []const []const u8, env: *const std.process.EnvMap) anyerror!u8,
    /// The exit status (shell form: 128+N for signal N) of the process if it has ended, else null; reaps it.
    poll: *const fn (ctx: *anyopaque, pid: Pid) ?u8,
    /// Waits for the process to end and gives its exit status.
    wait: *const fn (ctx: *anyopaque, pid: Pid) u8,
    /// Sends `sig` to the process group the process leads (what it started goes with it).
    kill: *const fn (ctx: *anyopaque, pid: Pid, sig: u8) void,
    sleepMs: *const fn (ctx: *anyopaque, ms: u64) void,
    nowMs: *const fn (ctx: *anyopaque) u64,
    /// Eight random lower-case hexadecimal digits.
    randomHex: *const fn (ctx: *anyopaque, out: *[8]u8) void,
    /// A loopback TCP port nothing listens on now: bound with port 0, read back and released, so the process it is handed to can listen on it; 0
    /// when none could be bound.
    reservePort: *const fn (ctx: *anyopaque) u16,
    /// True when a TCP connection to 127.0.0.1 at `port` is taken (the connection is closed at once).
    accepts: *const fn (ctx: *anyopaque, port: u16) bool,
};

fn writeBytes(p: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const bytes: *const []const u8 = @ptrCast(@alignCast(p));
    return w.writeAll(bytes.*);
}

/// Writes with `write` and flushes; a failure of either is dropped (a message that cannot be written has nowhere else to go).
fn emit(w: *std.Io.Writer, line: *const anyopaque, write: *const fn (*const anyopaque, *std.Io.Writer) std.Io.Writer.Error!void) void {
    write(line, w) catch {};
    w.flush() catch {};
}

pub const Io = struct {
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    /// The root of the file system: where a farm job's Action is read (farm.zig). The tests pass a directory of their own.
    root: std.fs.Dir,
    /// The process's whole argument list, its program first.
    argv: []const []const u8,
    /// The environment, `NAME=VALUE` entries in the order the process was given them: what the processes the runner starts are given.
    environ: []const []const u8,
    /// The working directory, absolute.
    cwd: []const u8,
    /// The user and group the process runs as (what a docker run is started as).
    uid: u32,
    gid: u32,
    plat: Plat,

    /// One message line on stderr, `blackbox_run: <message>`. A failed write of it is not reported anywhere. (The formatting is generic and has no error
    /// path of its own, so the one place a failed write is dropped, `emit`, is one block however many messages there are.)
    pub fn say(io: Io, comptime fmt: []const u8, args: anytype) void {
        const Line = struct {
            args: @TypeOf(args),
            fn write(p: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void {
                const self: *const @This() = @ptrCast(@alignCast(p));
                return w.print("blackbox_run: " ++ fmt ++ "\n", self.args);
            }
        };
        const line = Line{ .args = args };
        emit(io.err, &line, Line.write);
    }

    /// Bytes on stdout, as they are.
    pub fn put(io: Io, bytes: []const u8) void {
        emit(io.out, @ptrCast(&bytes), writeBytes);
    }
};
