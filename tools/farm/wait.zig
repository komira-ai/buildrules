//! The bounded wait for the farm to answer: `farm connect` (connect.zig) waits before it writes the farm's buckconfig, and `farm run`
//! (run.zig) waits after a run cut by a lost connection, before it runs the command again.
//!
//! "Answers" is a TCP connection to the remote-execution service's port that opens within `connect_timeout_ms`; one try is a probe. The
//! farm is probed at once, then every `interval_ms` until it answers or `limit_ms` has passed since the first probe. A line goes to the job
//! log each `note_ms` while it does not answer, so a quiet wait is seen to be a wait. Nothing here falls back to anything: a farm that does
//! not answer within the limit is the caller's failure.
//!
//! The clock, the probe and the sleep are parameters: the tests pass ones they move by hand, so no case waits for time to pass.
const std = @import("std");
const posix = std.posix;

/// The remote-execution service's host and port, from its address.
pub const HostPort = struct { host: []const u8, port: u16 };

/// `grpc://host:port`, `grpcs://host:port/...` or `host:port` (an IPv6 host in brackets) as its host and port, or null when there is no
/// host or no port from 1 to 65535.
pub fn hostPort(address: []const u8) ?HostPort {
    var rest = address;
    if (std.mem.indexOf(u8, rest, "://")) |at| rest = rest[at + 3 ..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |at| rest = rest[0..at];
    const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return null;
    var host = rest[0..colon];
    const port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return null;
    if (port == 0) return null;
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host = host[1 .. host.len - 1];
    if (host.len == 0 or std.mem.indexOfAny(u8, host, " []") != null) return null;
    return .{ .host = host, .port = port };
}

/// The value of `engine_address` in a buckconfig (the one `farm connect` wrote), or null when it has none.
pub fn engineAddress(config: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, config, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        const key = "engine_address";
        if (!std.mem.startsWith(u8, l, key)) continue;
        const rest = std.mem.trimLeft(u8, l[key.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        const value = std.mem.trim(u8, rest[1..], " \t");
        if (value.len > 0) return value;
    }
    return null;
}

/// A clock in milliseconds; only differences between two readings are used.
pub const Clock = struct {
    ctx: *anyopaque,
    now_fn: *const fn (ctx: *anyopaque) u64,

    fn now(self: Clock) u64 {
        return self.now_fn(self.ctx);
    }
};

/// One probe of the farm: true when it answers.
pub const Probe = struct {
    ctx: *anyopaque,
    answers_fn: *const fn (ctx: *anyopaque) bool,

    fn answers(self: Probe) bool {
        return self.answers_fn(self.ctx);
    }
};

/// A pause of `ms` milliseconds between two probes.
pub const Sleep = struct {
    ctx: *anyopaque,
    sleep_fn: *const fn (ctx: *anyopaque, ms: u64) void,

    fn sleep(self: Sleep, ms: u64) void {
        self.sleep_fn(self.ctx, ms);
    }
};

pub const Bounds = struct {
    /// The longest wait from the first probe.
    limit_ms: u64,
    /// The pause between two probes.
    interval_ms: u64 = 5 * std.time.ms_per_s,
    /// A line says the wait goes on each time this much more has passed.
    note_ms: u64 = std.time.ms_per_min,
};

/// How a wait ended, and how long it took from the first probe.
pub const Waited = union(enum) {
    answered: u64,
    gave_up: u64,
};

/// Probes the farm until it answers or `b.limit_ms` has passed; the notes go to `log` (the job log).
pub fn wait(probe: Probe, clock: Clock, pause: Sleep, b: Bounds, log: *std.Io.Writer) !Waited {
    const start = clock.now();
    var next_note = start +| b.note_ms;
    while (true) {
        if (probe.answers()) return .{ .answered = clock.now() -| start };
        const now = clock.now();
        const spent = now -| start;
        if (spent >= b.limit_ms) return .{ .gave_up = spent };
        if (now >= next_note) {
            try log.writeAll("farm: the farm does not answer yet; waited ");
            try duration(log, spent);
            try log.writeAll(" of ");
            try duration(log, b.limit_ms);
            try log.writeAll("\n");
            try log.flush();
            next_note = now +| b.note_ms;
        }
        pause.sleep(@min(b.interval_ms, b.limit_ms - spent));
    }
}

/// `4m05s`, `12s`, `20m00s`: a duration for a person, to the second.
pub fn duration(w: *std.Io.Writer, ms: u64) std.Io.Writer.Error!void {
    const s = ms / std.time.ms_per_s;
    if (s < 60) return w.print("{d}s", .{s});
    try w.print("{d}m{d:0>2}s", .{ s / 60, s % 60 });
}

// ---- the real clock, probe and sleep --------------------------------------------------------------------------------------------------

fn monotonicMs(_: *anyopaque) u64 {
    // CLOCK_MONOTONIC exists on every host this runs on; without it no limit could be kept, so its absence is loud.
    const ts = posix.clock_gettime(.MONOTONIC) catch @panic("farm: the monotonic clock cannot be read");
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

var no_state: u8 = 0;

/// The system's monotonic clock: a change of the time of day does not move the limit.
pub const system_clock = Clock{ .ctx = &no_state, .now_fn = monotonicMs };

fn threadSleep(_: *anyopaque, ms: u64) void {
    std.Thread.sleep(ms * std.time.ns_per_ms);
}

/// The real pause.
pub const system_sleep = Sleep{ .ctx = &no_state, .sleep_fn = threadSleep };

/// A probe that opens a TCP connection to `target` within `connect_timeout_ms`, and closes it.
pub const TcpProbe = struct {
    a: std.mem.Allocator,
    target: HostPort,
    connect_timeout_ms: i32 = 5000,

    fn answersFn(ctx: *anyopaque) bool {
        const self: *TcpProbe = @ptrCast(@alignCast(ctx));
        return tcpAnswers(self.a, self.target, self.connect_timeout_ms);
    }

    pub fn probe(self: *TcpProbe) Probe {
        return .{ .ctx = self, .answers_fn = answersFn };
    }
};

/// True when a TCP connection to one of the addresses of `target` opens within `timeout_ms`. A name that does not resolve does not answer.
pub fn tcpAnswers(a: std.mem.Allocator, target: HostPort, timeout_ms: i32) bool {
    const list = std.net.getAddressList(a, target.host, target.port) catch return false;
    defer list.deinit();
    for (list.addrs) |addr| {
        if (connectWithin(addr, timeout_ms)) return true;
    }
    return false;
}

fn connectWithin(addr: std.net.Address, timeout_ms: i32) bool {
    const fd = posix.socket(addr.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP) catch return false;
    defer posix.close(fd);
    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch |e| switch (e) {
        // In progress: the answer comes when the socket is writable.
        error.WouldBlock => {
            var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
            const n = posix.poll(&fds, timeout_ms) catch return false;
            if (n == 0) return false;
            posix.getsockoptError(fd) catch return false;
            return true;
        },
        else => return false,
    };
    return true;
}
