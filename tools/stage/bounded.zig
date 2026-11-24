//! The real runner of the commands a stage starts (stage.zig `realRun`): each one in a process group of its own, both streams collected, and a limit on
//! how long it may run. A command still running at the limit is stopped with its process group (a `buildrules sync` and the buck2 client it started;
//! a buck2 daemon has left the group and is ended with the job), and its `Out` says how long it had run (`stopped_ms`); `Io.run` turns that into
//! `error.CommandHung` with a line naming the command. While a command runs, a line says so each time `note_ms` more has passed, so a job's log
//! shows that a quiet command is still running.
//!
//! Why: a build on a farm whose connection stops answering waits without end and prints nothing. Without a limit the step ran in silence until the
//! job's own timeout, or until the hosted runner was lost and the log with it.
//!
//! The end of a command is its own exit, not the end of its streams: a process it left behind that still holds them is waited for `drain_ms` at
//! most, and the command keeps its own status.
//!
//! The clock is a parameter: the tests pass one they move by hand, so a stop never depends on how fast the host is.
const std = @import("std");
const posix = std.posix;
const io_mod = @import("io.zig");

pub const Limit = struct {
    /// A command that has run this long is stopped.
    limit_ms: u64,
    /// A line says the command is still running each time this much more has passed.
    note_ms: u64,
    /// After the command exited or was stopped, how long its streams are still read: what its processes write as they end, and no longer, since a
    /// process that left its group (a daemon) could hold them open.
    drain_ms: u64 = 10_000,
};

/// A clock in milliseconds; only differences between two readings are used.
pub const Clock = struct {
    ctx: *anyopaque,
    now_fn: *const fn (ctx: *anyopaque) u64,

    fn now(self: Clock) u64 {
        return self.now_fn(self.ctx);
    }
};

fn monotonicMs(_: *anyopaque) u64 {
    // CLOCK_MONOTONIC exists on every host the stage runs on (Linux, macOS); without it no limit could be kept, so its absence is loud.
    const ts = posix.clock_gettime(.MONOTONIC) catch @panic("stage: the monotonic clock cannot be read");
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

var no_state: u8 = 0;

/// The system's monotonic clock: a change of the time of day does not move the limit.
pub const system_clock = Clock{ .ctx = &no_state, .now_fn = monotonicMs };

/// The longest wait for output before the clock is read again. It is not a sleep: the wait ends as soon as the command writes or its streams close.
const tick_ns: u64 = std.time.ns_per_s;

/// The most either stream may hold (what `std.process.Child.run` was given before).
const max_output_bytes: usize = 1 << 28;

fn codeOf(status: u32) u8 {
    return if (posix.W.IFEXITED(status)) posix.W.EXITSTATUS(status) else 255;
}

/// Runs `argv` in `cwd` with `env`, collecting both streams, under `limit` read from `clock`. The "still running" lines go to `log`.
pub fn run(a: std.mem.Allocator, argv: []const []const u8, cwd: []const u8, env: *const std.process.EnvMap, limit: Limit, clock: Clock, log: *std.Io.Writer) !io_mod.Out {
    var child = std.process.Child.init(argv, a);
    child.cwd = cwd;
    child.env_map = env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    // A group of its own, led by the command: the stop reaches what it started and stays in its group, and nothing else.
    child.pgid = 0;
    try child.spawn();
    // The command's exit status once it has been reaped here (then `child.wait` is not called: the process is gone).
    var exit_status: ?u32 = null;
    errdefer if (exit_status == null) {
        posix.kill(-child.id, posix.SIG.KILL) catch {};
        _ = child.wait() catch {};
    };

    var poller = std.Io.poll(a, enum { stdout, stderr }, .{ .stdout = child.stdout.?, .stderr = child.stderr.? });
    defer poller.deinit();

    const start = clock.now();
    var next_note = start +| limit.note_ms;
    var stopped_ms: ?u64 = null;
    // When the command exited or was stopped: from then on only the drain runs.
    var ended_at: ?u64 = null;
    while (try poller.pollTimeout(tick_ns)) {
        if (poller.reader(.stdout).bufferedLen() > max_output_bytes) return error.StdoutStreamTooLong;
        if (poller.reader(.stderr).bufferedLen() > max_output_bytes) return error.StderrStreamTooLong;
        const now = clock.now();
        if (ended_at == null) {
            const w = posix.waitpid(child.id, posix.W.NOHANG);
            if (w.pid == child.id) {
                exit_status = w.status;
                ended_at = now;
            }
        }
        if (ended_at) |at| {
            if (now -| at >= limit.drain_ms) break;
            continue;
        }
        const ran = now -| start;
        if (ran >= limit.limit_ms) {
            posix.kill(-child.id, posix.SIG.KILL) catch {};
            stopped_ms = ran;
            ended_at = now;
            continue;
        }
        if (now >= next_note) {
            try log.print("stage: `{s}` is still running after {d} min; it is stopped at {d} min\n", .{ std.fs.path.basename(argv[0]), ran / std.time.ms_per_min, limit.limit_ms / std.time.ms_per_min });
            try log.flush();
            next_note = now +| limit.note_ms;
        }
    }
    const stdout = try poller.toOwnedSlice(.stdout);
    const stderr = try poller.toOwnedSlice(.stderr);
    if (exit_status) |st| {
        child.stdout.?.close();
        child.stderr.?.close();
        return .{ .code = codeOf(st), .stdout = stdout, .stderr = stderr, .stopped_ms = stopped_ms };
    }
    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = stdout, .stderr = stderr, .stopped_ms = stopped_ms };
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------
//
// The commands are applets of the pinned busybox, which the test action puts on PATH (rules/zig/zig.bzl, `zig_test`). No case waits for a time to
// pass: the clock is a list of readings, and the last one repeats.

const t = std.testing;

const Readings = struct {
    at: []const u64,
    n: usize = 0,

    fn next(ctx: *anyopaque) u64 {
        const self: *Readings = @ptrCast(@alignCast(ctx));
        const v = self.at[@min(self.n, self.at.len - 1)];
        self.n += 1;
        return v;
    }

    fn clock(self: *Readings) Clock {
        return .{ .ctx = self, .now_fn = next };
    }
};

const min = std.time.ms_per_min;
const thirty = Limit{ .limit_ms = 30 * min, .note_ms = 5 * min };

fn testEnv(a: std.mem.Allocator) !std.process.EnvMap {
    return std.process.getEnvMap(a);
}

// Catches: a command that ends being reported as stopped, its status or a stream lost, or a note written when no time passed.
test "a command that ends within the limit keeps its status and both streams, is not stopped, and says nothing more" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try testEnv(a);
    var log = std.Io.Writer.Allocating.init(a);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realpathAlloc(a, ".");
    var still = Readings{ .at = &.{0} };
    const r = try run(a, &.{ "echo", "Hello, world!" }, cwd, &env, thirty, still.clock(), &log.writer);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("Hello, world!\n", r.stdout);
    try t.expectEqualStrings("", r.stderr);
    try t.expectEqual(@as(?u64, null), r.stopped_ms);
    try t.expectEqualStrings("", log.written());

    // a failing command keeps its own status, and its error stream
    const f = try run(a, &.{ "ls", "no-such-file" }, cwd, &env, thirty, still.clock(), &log.writer);
    try t.expect(f.code != 0);
    try t.expect(std.mem.indexOf(u8, f.stderr, "no-such-file") != null);
    try t.expectEqual(@as(?u64, null), f.stopped_ms);

    // it runs in the directory it is given
    try tmp.dir.writeFile(.{ .sub_path = "here", .data = "" });
    const l = try run(a, &.{"ls"}, cwd, &env, thirty, still.clock(), &log.writer);
    try t.expectEqualStrings("here\n", l.stdout);
}

// Catches: a command that never ends being waited for without end (the silent hour of a cut farm connection), or stopped without saying how long it ran.
test "a command still running at the limit is stopped, with how long it ran, and says it was running on the way" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try testEnv(a);
    var log = std.Io.Writer.Allocating.init(a);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realpathAlloc(a, ".");
    // the start, then 5 and 10 minutes (a note each), 12 (none), then 31: past the limit
    var clk = Readings{ .at = &.{ 0, 5 * min, 10 * min, 12 * min, 31 * min } };
    const r = try run(a, &.{ "sleep", "100000" }, cwd, &env, thirty, clk.clock(), &log.writer);
    try t.expectEqual(@as(?u64, 31 * min), r.stopped_ms);
    try t.expectEqual(@as(u8, 255), r.code);
    try t.expectEqualStrings(
        "stage: `sleep` is still running after 5 min; it is stopped at 30 min\n" ++
            "stage: `sleep` is still running after 10 min; it is stopped at 30 min\n",
        log.written(),
    );
}

// Catches: the limit counted from the wrong reading, or only past it rather than at it.
test "a command is stopped at the limit exactly, and not a reading before" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try testEnv(a);
    var log = std.Io.Writer.Allocating.init(a);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realpathAlloc(a, ".");
    // a clock that starts late: the limit is counted from the start of the command, and a reading at the limit stops it
    var clk = Readings{ .at = &.{ 1000 * min, 1029 * min, 1030 * min, 1031 * min } };
    const r = try run(a, &.{ "sleep", "100000" }, cwd, &env, .{ .limit_ms = 30 * min, .note_ms = 60 * min }, clk.clock(), &log.writer);
    try t.expectEqual(@as(?u64, 30 * min), r.stopped_ms);
    try t.expectEqualStrings("", log.written());
}

// Catches: the stop reaching the command but not what it started (a `buildrules sync` and the buck2 under it).
test "the stop reaches the processes the command started, so the streams close and the run returns" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try testEnv(a);
    var log = std.Io.Writer.Allocating.init(a);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realpathAlloc(a, ".");
    // `time` starts `sleep` as its child and waits for it; both hold the streams. The clock stays at the limit, so the wait after the stop ends
    // only when the streams close: were `sleep` left alive, it would hold them, and this case would not finish.
    var clk = Readings{ .at = &.{ 0, 30 * min } };
    const r = try run(a, &.{ "time", "sleep", "100000" }, cwd, &env, thirty, clk.clock(), &log.writer);
    try t.expectEqual(@as(?u64, 30 * min), r.stopped_ms);
}

// Catches: the end of the streams taken for the end of the command: one that exited, leaving a process that holds its streams (a daemon that kept
// them), reported as hung and failed. `setsid` runs `sleep` in a session of its own and exits at once; the clock passes the limit while `sleep` runs.
test "a command that exited while a process it left behind holds its streams keeps its own status, and is not stopped" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try testEnv(a);
    var log = std.Io.Writer.Allocating.init(a);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realpathAlloc(a, ".");
    // ten readings a second apart under the limit (the command's exit is seen at one of them), then past it, and past the drain
    var clk = Readings{ .at = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 31 * min } };
    const r = try run(a, &.{ "setsid", "sleep", "60" }, cwd, &env, .{ .limit_ms = 30 * min, .note_ms = 60 * min, .drain_ms = 1 }, clk.clock(), &log.writer);
    try t.expectEqual(@as(?u64, null), r.stopped_ms);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("", log.written());
}

test "a program that is not there is an error of the run, not an output" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try testEnv(a);
    var log = std.Io.Writer.Allocating.init(a);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realpathAlloc(a, ".");
    var still = Readings{ .at = &.{0} };
    try t.expectError(error.FileNotFound, run(a, &.{"no-such-program-anywhere"}, cwd, &env, thirty, still.clock(), &log.writer));
}

test "the system clock reads the time, and does not go back between two readings" {
    const x = system_clock.now();
    const y = system_clock.now();
    try t.expect(x > 0);
    try t.expect(y >= x);
}

// Catches: a command ended by a signal read as a success or as some other exit code, or an exit code lost.
test "a command's own exit keeps its code, and an end by a signal is 255" {
    try t.expectEqual(@as(u8, 0), codeOf(0));
    try t.expectEqual(@as(u8, 3), codeOf(3 << 8));
    try t.expectEqual(@as(u8, 255), codeOf(9)); // the status of a process ended by SIGKILL (9)
}
