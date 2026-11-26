//! The tests of the `farm` tool (//tools/farm:farm_unit). `farm run` and `farm connect` are driven with a runner that plays recorded buck2
//! output (fixtures/) and a wait that returns what the case needs, so no case reaches a farm, resolves a name or waits for time to pass. The
//! real runner runs applets of the pinned busybox (on PATH in the test action), and the real probe connects to a listener on 127.0.0.1 with
//! port 0.
const std = @import("std");
const t = std.testing;
const remote = @import("remote.zig");
const wait = @import("wait.zig");
const args_mod = @import("args.zig");
const connect = @import("connect.zig");
const run = @import("run.zig");
const farm = @import("farm.zig");

test {
    _ = @import("classify_test.zig");
    _ = @import("action_test.zig");
}

const build_remote = @embedFile("fixtures/build_remote.log");
const build_cached = @embedFile("fixtures/build_cached.log");
const bxl_cached = @embedFile("fixtures/bxl_cached.log");
const bxl_remote = @embedFile("fixtures/bxl_remote.log");
const test_cached_remote = @embedFile("fixtures/test_cached_remote.log");
const test_none_ran = @embedFile("fixtures/test_none_ran.log");
const build_cut = @embedFile("fixtures/build_cut.log");
const test_cut = @embedFile("fixtures/test_cut.log");
const build_mixed = @embedFile("fixtures/build_cut_and_compile_error.log");
const cut_chunk_connect = @embedFile("fixtures/cut_chunk_connect.log");
const cut_skipped = @embedFile("fixtures/cut_skipped.log");
const clippy = @embedFile("fixtures/clippy.log");

fn edit(a: std.mem.Allocator, log: []const u8, from: []const u8, to: []const u8) ![]u8 {
    try t.expect(std.mem.indexOf(u8, log, from) != null); // the recorded log has the text the case changes
    return std.mem.replaceOwned(u8, a, log, from, to);
}

// ---- remote.zig: local 0 -----------------------------------------------------------------------------------------------------------

test "a recorded run that ran on the farm or touched no action passes the local-0 check" {
    for ([_][]const u8{ build_remote, build_cached, bxl_cached, bxl_remote, test_cached_remote, test_none_ran }) |log| {
        try t.expectEqual(remote.Verdict.ok, remote.verdict(log));
    }
    try t.expectEqual(@as(u64, 0), remote.localActions(build_remote));
}

test "a run with an action on the runner, an unreadable or missing summary, or a failure does not pass" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualDeep(remote.Verdict{ .local_execution = 2 }, remote.verdict(try edit(a, build_remote, "local: 0", "local: 2")));
    // the counts of two summary lines add up
    const two = try std.mem.concat(a, u8, &.{ try edit(a, build_remote, "local: 0", "local: 1"), "[x] Commands: 2 (cached: 0, remote: 0, local: 2)\n" });
    try t.expectEqualDeep(remote.Verdict{ .local_execution = 3 }, remote.verdict(two));
    try t.expectEqual(@as(u64, 3), remote.localActions(two));
    try t.expectEqual(remote.Verdict.unreadable_summary, remote.verdict(try edit(a, build_remote, ", local: 0)", ")")));
    try t.expectEqual(remote.Verdict.unreadable_summary, remote.verdict(try edit(a, build_remote, "local: 0", "local: x")));
    // a cache-hit line, or traffic on the network, with no summary
    try t.expectEqual(remote.Verdict.missing_summary, remote.verdict(try edit(a, build_remote, "[2026-10-21T14:05:55.945-05:00] Commands: 4 (cached: 3, remote: 1, local: 0)\n", "")));
    try t.expectEqual(remote.Verdict.missing_summary, remote.verdict(try edit(a, build_cached, "down 0B", "down 0Bx")));
    try t.expectEqual(remote.Verdict.missing_summary, remote.verdict(try edit(a, test_cached_remote, "Tests finished", "Tests: finished")));
    try t.expectEqual(remote.Verdict.missing_summary, remote.verdict("BUILD SUCCEEDED\n"));
    // a zero-network line with more after it, as buck2 prints it with a session
    try t.expectEqual(remote.Verdict.ok, remote.verdict(try edit(a, build_cached, "down 0B", "down 0B  session GRPC-SESSION-ID")));
    try t.expectEqual(remote.Verdict.run_failed, remote.verdict(build_cut));
    try t.expectEqual(remote.Verdict.run_failed, remote.verdict("BXL FAILED\r\n"));
}

test "the local-0 verdict says why, for the job log" {
    const cases = [_]struct { v: remote.Verdict, s: []const u8 }{
        .{ .v = .ok, .s = "every action ran on the farm or came from its cache (`local: 0`)" },
        .{ .v = .{ .local_execution = 2 }, .s = "2 action(s) ran on this runner (`local: 2` in the Commands summary); a farm build runs every action on the farm" },
        .{ .v = .unreadable_summary, .s = "a `Commands:` line has no `local: N` field; buck2's summary changed shape" },
        .{ .v = .missing_summary, .s = "no `Commands:` summary line, and the log does not show that no build action ran; it cannot show the build was on the farm" },
        .{ .v = .run_failed, .s = "the log ends a failed buck2 run (BUILD FAILED / BXL FAILED)" },
    };
    for (cases) |c| {
        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try remote.describe(c.v, &w);
        try t.expectEqualStrings(c.s, w.buffered());
    }
}

// ---- wait.zig ----------------------------------------------------------------------------------------------------------------------

test "the farm's host and port are read from its address, and an address without them is refused" {
    const ok = [_]struct { in: []const u8, host: []const u8, port: u16 }{
        .{ .in = "grpc://192.0.2.1:8980", .host = "192.0.2.1", .port = 8980 },
        .{ .in = "grpcs://farm.example:443/instance", .host = "farm.example", .port = 443 },
        .{ .in = "farm.example:1", .host = "farm.example", .port = 1 },
        .{ .in = "grpc://[::1]:65535", .host = "::1", .port = 65535 },
    };
    for (ok) |c| {
        const hp = wait.hostPort(c.in).?;
        try t.expectEqualStrings(c.host, hp.host);
        try t.expectEqual(c.port, hp.port);
    }
    for ([_][]const u8{ "grpc://farm.example", "farm.example:0", "farm.example:65536", ":80", "grpc://:80", "farm.example:x", "[]:5", "farm example:5", "grpc://a]b:5", "" }) |bad| {
        try t.expect(wait.hostPort(bad) == null);
    }
}

test "the engine address is read from a buckconfig, and a buckconfig without one has none" {
    try t.expectEqualStrings("grpc://192.0.2.1:8980", wait.engineAddress("[buck2_re_client]\n  engine_address = grpc://192.0.2.1:8980\r\n  cas_address = x\n").?);
    try t.expectEqualStrings("a:1", wait.engineAddress("engine_address_v2 = b:2\nengine_address=a:1\n").?);
    try t.expect(wait.engineAddress("") == null);
    try t.expect(wait.engineAddress("  engine_address =  \n  engine_address\n  cas_address = a:1\n") == null);
}

/// A clock, a probe and a sleep in one: the clock moves only when the wait sleeps, and the farm answers from `answers_at` on.
const Fake = struct {
    now: u64 = 1000,
    answers_at: ?u64,
    probes: usize = 0,
    sleeps: [16]u64 = undefined,
    n_sleeps: usize = 0,

    fn nowFn(ctx: *anyopaque) u64 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.now;
    }
    fn answersFn(ctx: *anyopaque) bool {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.probes += 1;
        return if (self.answers_at) |at| self.now >= at else false;
    }
    fn sleepFn(ctx: *anyopaque, ms: u64) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (self.n_sleeps < self.sleeps.len) self.sleeps[self.n_sleeps] = ms;
        self.n_sleeps += 1;
        self.now += ms;
    }
    fn waitFor(self: *Fake, b: wait.Bounds, log: *std.Io.Writer) !wait.Waited {
        return wait.wait(.{ .ctx = self, .answers_fn = answersFn }, .{ .ctx = self, .now_fn = nowFn }, .{ .ctx = self, .sleep_fn = sleepFn }, b, log);
    }
};

const min = std.time.ms_per_min;

test "a farm that answers at once is not waited for" {
    var log = std.Io.Writer.Allocating.init(t.allocator);
    defer log.deinit();
    var f = Fake{ .answers_at = 0 };
    try t.expectEqualDeep(wait.Waited{ .answered = 0 }, try f.waitFor(.{ .limit_ms = 20 * min }, &log.writer));
    try t.expectEqual(@as(usize, 1), f.probes);
    try t.expectEqual(@as(usize, 0), f.n_sleeps);
    try t.expectEqualStrings("", log.written());
}

test "a farm that answers after three minutes is probed every 5 seconds, with a line each minute, and the wait says how long" {
    var log = std.Io.Writer.Allocating.init(t.allocator);
    defer log.deinit();
    var f = Fake{ .answers_at = 1000 + 3 * min };
    try t.expectEqualDeep(wait.Waited{ .answered = 3 * min }, try f.waitFor(.{ .limit_ms = 20 * min }, &log.writer));
    try t.expectEqual(@as(usize, 37), f.probes);
    try t.expectEqual(@as(usize, 36), f.n_sleeps);
    for (f.sleeps) |ms| try t.expectEqual(@as(u64, 5000), ms);
    try t.expectEqualStrings("farm: the farm does not answer yet; waited 1m00s of 20m00s\nfarm: the farm does not answer yet; waited 2m00s of 20m00s\n", log.written());
}

test "a farm that never answers is given up at the limit, and the last pause stops at the limit" {
    var log = std.Io.Writer.Allocating.init(t.allocator);
    defer log.deinit();
    var f = Fake{ .answers_at = null };
    try t.expectEqualDeep(wait.Waited{ .gave_up = 12_000 }, try f.waitFor(.{ .limit_ms = 12_000 }, &log.writer));
    try t.expectEqual(@as(usize, 3), f.n_sleeps);
    try t.expectEqualSlices(u64, &.{ 5000, 5000, 2000 }, f.sleeps[0..3]);
    try t.expectEqual(@as(usize, 4), f.probes);
    // a limit of zero is one probe
    var z = Fake{ .answers_at = null };
    try t.expectEqualDeep(wait.Waited{ .gave_up = 0 }, try z.waitFor(.{ .limit_ms = 0 }, &log.writer));
    try t.expectEqual(@as(usize, 1), z.probes);
    try t.expectEqual(@as(usize, 0), z.n_sleeps);
}

test "a duration reads to the second" {
    const cases = [_]struct { ms: u64, s: []const u8 }{
        .{ .ms = 0, .s = "0s" },       .{ .ms = 59_999, .s = "59s" },          .{ .ms = 60_000, .s = "1m00s" },
        .{ .ms = 245_000, .s = "4m05s" }, .{ .ms = 20 * min, .s = "20m00s" }, .{ .ms = 125 * min + 9000, .s = "125m09s" },
    };
    for (cases) |c| {
        var buf: [32]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try wait.duration(&w, c.ms);
        try t.expectEqualStrings(c.s, w.buffered());
    }
}

test "the real probe connects to a listening port on 127.0.0.1, and a closed port does not answer" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    const port = server.listen_address.getPort();
    try t.expect(wait.tcpAnswers(t.allocator, .{ .host = "127.0.0.1", .port = port }, 5000));
    var probe = wait.TcpProbe{ .a = t.allocator, .target = .{ .host = "127.0.0.1", .port = port } };
    try t.expect(probe.probe().answers_fn(&probe));
    server.deinit();
    // the port is closed now: the connection is refused
    try t.expect(!wait.tcpAnswers(t.allocator, .{ .host = "127.0.0.1", .port = port }, 5000));
}

test "the real clock does not go back, and a pause of nothing returns" {
    const a = wait.system_clock.now_fn(wait.system_clock.ctx);
    wait.system_sleep.sleep_fn(wait.system_sleep.ctx, 0);
    try t.expect(wait.system_clock.now_fn(wait.system_clock.ctx) >= a);
}

// ---- args.zig ----------------------------------------------------------------------------------------------------------------------

test "the wait is 20 minutes unless given, a whole number of minutes up to 120" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try t.expectEqual(@as(?u64, 20 * min), try args_mod.waitMs(null, "farm run", &w));
    try t.expectEqual(@as(?u64, 0), try args_mod.waitMs("0", "farm run", &w));
    try t.expectEqual(@as(?u64, 120 * min), try args_mod.waitMs("120", "farm run", &w));
    try t.expectEqualStrings("", w.buffered());
    try t.expectEqual(@as(?u64, null), try args_mod.waitMs("121", "farm run", &w));
    try t.expectEqualStrings("farm run: --wait-minutes is 121, more than 120: the job's own timeout would end it first\n", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try t.expectEqual(@as(?u64, null), try args_mod.waitMs("1.5", "farm connect", &w));
    try t.expectEqualStrings("farm connect: --wait-minutes is 1.5, not a whole number of minutes\n", w.buffered());
}

// ---- farm run ----------------------------------------------------------------------------------------------------------------------

const Play = struct {
    /// What the run prints, written to its log; null writes no log.
    out: ?[]const u8,
    end: run.End,
};

const FakeRunner = struct {
    plays: []const Play,
    calls: usize = 0,
    /// The call (0, 1) that fails to start.
    fail_at: ?usize = null,
    argv: []const []const u8 = &.{},

    fn runFn(ctx: *anyopaque, _: std.mem.Allocator, argv: []const []const u8, log: []const u8) anyerror!run.End {
        const self: *FakeRunner = @ptrCast(@alignCast(ctx));
        defer self.calls += 1;
        if (self.fail_at) |n| {
            if (n == self.calls) return error.FileNotFound;
        }
        self.argv = argv;
        const p = self.plays[self.calls];
        if (p.out) |o| try std.fs.cwd().writeFile(.{ .sub_path = log, .data = o });
        return p.end;
    }

    fn runner(self: *FakeRunner) run.Runner {
        return .{ .ctx = self, .run_fn = runFn };
    }
};

const FakeWaiter = struct {
    result: wait.Waited = .{ .answered = 0 },
    calls: usize = 0,
    /// The host it was given, copied: the caller's text is freed when its command returns.
    host_buf: [64]u8 = undefined,
    host_len: usize = 0,
    port: u16 = 0,
    limit_ms: u64 = 0,

    fn host(self: *const FakeWaiter) []const u8 {
        return self.host_buf[0..self.host_len];
    }

    fn waitFn(ctx: *anyopaque, target: wait.HostPort, limit_ms: u64, _: *std.Io.Writer) anyerror!wait.Waited {
        const self: *FakeWaiter = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        const n = @min(target.host.len, self.host_buf.len);
        @memcpy(self.host_buf[0..n], target.host[0..n]);
        self.host_len = n;
        self.port = target.port;
        self.limit_ms = limit_ms;
        return self.result;
    }

    fn waiter(self: *FakeWaiter) connect.Waiter {
        return .{ .ctx = self, .wait_fn = waitFn };
    }
};

const farm_config = "[buck2_re_client]\n  engine_address = grpc://192.0.2.1:8980\n[buildrules_re]\n  linux_x86_64_properties = a=b\n";

/// One `farm run` in a scratch directory: its config, log and summary there.
const RunCase = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    dir: []const u8,
    config: []const u8,
    log: []const u8,
    summary: []const u8,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,

    fn init() !*RunCase {
        const c = try t.allocator.create(RunCase);
        c.arena = std.heap.ArenaAllocator.init(t.allocator);
        const a = c.arena.allocator();
        c.tmp = t.tmpDir(.{});
        c.dir = try c.tmp.dir.realpathAlloc(a, ".");
        c.config = try std.fs.path.join(a, &.{ c.dir, "farm.buckconfig" });
        c.log = try std.fs.path.join(a, &.{ c.dir, "build.log" });
        c.summary = try std.fs.path.join(a, &.{ c.dir, "summary.md" });
        try c.tmp.dir.writeFile(.{ .sub_path = "farm.buckconfig", .data = farm_config });
        try c.tmp.dir.writeFile(.{ .sub_path = "summary.md", .data = "" });
        c.out = std.Io.Writer.Allocating.init(a);
        c.err = std.Io.Writer.Allocating.init(a);
        return c;
    }

    fn deinit(c: *RunCase) void {
        c.tmp.cleanup();
        c.arena.deinit();
        t.allocator.destroy(c);
    }

    /// `farm run --config --log --summary <extra> -- buck2 <command>`.
    fn go(c: *RunCase, r: *FakeRunner, w: *FakeWaiter, extra: []const []const u8, command: []const []const u8) !u8 {
        const a = c.arena.allocator();
        var args = std.ArrayList([]const u8).empty;
        try args.appendSlice(a, &.{ "--config", c.config, "--log", c.log, "--summary", c.summary });
        try args.appendSlice(a, extra);
        try args.append(a, "--");
        try args.appendSlice(a, command);
        return run.main(t.allocator, args.items, r.runner(), w.waiter(), &c.out.writer, &c.err.writer);
    }

    fn read(c: *RunCase, name: []const u8) ![]u8 {
        return c.tmp.dir.readFileAlloc(c.arena.allocator(), name, 1 << 24);
    }
};

const build_cmd = [_][]const u8{ "buck2", "build", "//:ci" };

test "farm run: a run on the farm that passes is run once, and the summary is left alone" {
    const c = try RunCase.init();
    defer c.deinit();
    var r = FakeRunner{ .plays = &.{.{ .out = build_remote, .end = .{ .exited = 0 } }} };
    var w = FakeWaiter{};
    try t.expectEqual(@as(u8, 0), try c.go(&r, &w, &.{}, &build_cmd));
    try t.expectEqual(@as(usize, 1), r.calls);
    try t.expectEqual(build_cmd.len, r.argv.len);
    for (build_cmd, r.argv) |want, got| try t.expectEqualStrings(want, got);
    try t.expectEqual(@as(usize, 0), w.calls);
    try t.expectEqualStrings("", try c.read("summary.md"));
    try t.expectEqualStrings(build_remote, try c.read("build.log"));
    try t.expectEqualStrings("", c.err.written());
}

test "farm run: a passing run that ran an action on the runner fails: never a local build" {
    const c = try RunCase.init();
    defer c.deinit();
    const log = try edit(c.arena.allocator(), build_remote, "local: 0", "local: 2");
    var r = FakeRunner{ .plays = &.{.{ .out = log, .end = .{ .exited = 0 } }} };
    var w = FakeWaiter{};
    try t.expectEqual(@as(u8, 1), try c.go(&r, &w, &.{}, &build_cmd));
    try t.expectEqualStrings("farm run: FAILED: buck2 passed, but 2 action(s) ran on this runner (`local: 2` in the Commands summary); a farm build runs every action on the farm\n", c.err.written());
}

test "farm run: a cut build waits for the farm, runs once more, passes, and the job summary names the wait" {
    const c = try RunCase.init();
    defer c.deinit();
    var r = FakeRunner{ .plays = &.{ .{ .out = build_cut, .end = .{ .exited = 3 } }, .{ .out = build_remote, .end = .{ .exited = 0 } } } };
    var w = FakeWaiter{ .result = .{ .answered = 125_000 } };
    try t.expectEqual(@as(u8, 0), try c.go(&r, &w, &.{}, &build_cmd));
    try t.expectEqual(@as(usize, 2), r.calls);
    try t.expectEqual(@as(usize, 1), w.calls);
    try t.expectEqualStrings("192.0.2.1", w.host());
    try t.expectEqual(@as(u16, 8980), w.port);
    try t.expectEqual(@as(u64, 20 * min), w.limit_ms);
    const note = "farm run: `build` ran again after a cut connection to the farm (buck2's `RE channel error` in each of 4 failed block(s)), once the farm answered after a wait of 2m05s; the first run's log is build.first.log";
    try t.expectEqualStrings(note ++ "\n", try c.read("summary.md"));
    try t.expectEqualStrings(build_cut, try c.read("build.first.log"));
    try t.expectEqualStrings(build_remote, try c.read("build.log"));
    try t.expectEqualStrings(note ++ "\nfarm run: the second run passed\n", c.err.written());
    try t.expectEqualStrings("farm run: the connection to the farm was cut (4 failed block(s), each buck2's `RE channel error`); waiting for the farm to answer before running `build` again\n", c.out.written());
}

test "farm run: the recorded cuts of a Rust build and of mopm's build, and a cut test run, each run once more" {
    const cases = [_]struct { cut: []const u8, pass: []const u8, cmd: []const []const u8 }{
        .{ .cut = cut_chunk_connect, .pass = build_remote, .cmd = &build_cmd },
        .{ .cut = cut_skipped, .pass = build_remote, .cmd = &.{ "./buck2", "build", "--skip-incompatible-targets", "@targets" } },
        .{ .cut = test_cut, .pass = test_cached_remote, .cmd = &.{ "buck2", "test", "//..." } },
        .{ .cut = build_cut, .pass = bxl_remote, .cmd = &.{ "buck2", "bxl", "//ci:x.bxl:check" } },
    };
    for (cases) |k| {
        const c = try RunCase.init();
        defer c.deinit();
        var r = FakeRunner{ .plays = &.{ .{ .out = k.cut, .end = .{ .exited = 3 } }, .{ .out = k.pass, .end = .{ .exited = 0 } } } };
        var w = FakeWaiter{};
        try t.expectEqual(@as(u8, 0), try c.go(&r, &w, &.{}, k.cmd));
        try t.expectEqual(@as(usize, 2), r.calls);
        try t.expect(std.mem.indexOf(u8, try c.read("summary.md"), "ran again after a cut connection to the farm") != null);
    }
}

test "farm run: --wait-minutes bounds the wait" {
    const c = try RunCase.init();
    defer c.deinit();
    var r = FakeRunner{ .plays = &.{ .{ .out = build_cut, .end = .{ .exited = 3 } }, .{ .out = build_remote, .end = .{ .exited = 0 } } } };
    var w = FakeWaiter{};
    try t.expectEqual(@as(u8, 0), try c.go(&r, &w, &.{ "--wait-minutes", "5" }, &build_cmd));
    try t.expectEqual(@as(u64, 5 * min), w.limit_ms);
}

test "farm run: a cut build whose farm does not answer within the wait is not run again, and the summary says so" {
    const c = try RunCase.init();
    defer c.deinit();
    var r = FakeRunner{ .plays = &.{.{ .out = build_cut, .end = .{ .exited = 3 } }} };
    var w = FakeWaiter{ .result = .{ .gave_up = 20 * min } };
    try t.expectEqual(@as(u8, 3), try c.go(&r, &w, &.{}, &build_cmd));
    try t.expectEqual(@as(usize, 1), r.calls);
    const note = "farm run: `build` was cut by a lost connection to the farm (4 failed block(s)), and the farm did not answer within a wait of 20m00s: not run again; the run's log is build.first.log";
    try t.expectEqualStrings(note ++ "\n", try c.read("summary.md"));
    try t.expectEqualStrings(note ++ "\nfarm run: FAILED: the farm did not answer again\n", c.err.written());
}

test "farm run: the second run is final: cut again, a real failure, a signal or a local action fail it, and there is no third run" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const local = try edit(arena.allocator(), build_remote, "local: 0", "local: 1");
    const cases = [_]struct { second: Play, code: u8, says: []const u8 }{
        .{ .second = .{ .out = build_cut, .end = .{ .exited = 3 } }, .code = 3, .says = "farm run: FAILED: the second run was cut too: the connection to the farm was cut again (buck2's `RE channel error`); not run a third time\n" },
        .{ .second = .{ .out = clippy, .end = .{ .exited = 3 } }, .code = 3, .says = "farm run: FAILED: the second run failed: a failure that is not a cut connection: [2026-11-26T17:05:08.074+00:00] Action failed: tierstore//crates/tierstore:tierstore-0.3.0_fb2de23c28_lint (buildrules//platforms:linux_x86_64#27db57317ae2fec7) (rustc tierstore-0.3.0_fb2de23c28_lint)\n" },
        .{ .second = .{ .out = "", .end = .{ .signal = 9 } }, .code = 137, .says = "farm run: FAILED: the second run was ended by signal 9\n" },
        .{ .second = .{ .out = local, .end = .{ .exited = 0 } }, .code = 1, .says = "farm run: FAILED: buck2 passed, but 1 action(s) ran on this runner (`local: 1` in the Commands summary); a farm build runs every action on the farm\n" },
    };
    for (cases) |k| {
        const c = try RunCase.init();
        defer c.deinit();
        var r = FakeRunner{ .plays = &.{ .{ .out = build_cut, .end = .{ .exited = 3 } }, k.second } };
        var w = FakeWaiter{};
        try t.expectEqual(k.code, try c.go(&r, &w, &.{}, &build_cmd));
        try t.expectEqual(@as(usize, 2), r.calls);
        try t.expectEqual(@as(usize, 1), w.calls);
        try t.expect(std.mem.endsWith(u8, c.err.written(), k.says));
    }
}

test "farm run: a real failure, a signal, another subcommand, or a cut run with a local action is final at once, with no wait" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const local_cut = try edit(arena.allocator(), build_cut, "local: 0", "local: 3");
    const cases = [_]struct { play: Play, cmd: []const []const u8, code: u8, says: []const u8 }{
        .{ .play = .{ .out = clippy, .end = .{ .exited = 3 } }, .cmd = &build_cmd, .code = 3, .says = "farm run: not run again: a failure that is not a cut connection: [2026-11-26T17:05:08.074+00:00] Action failed: tierstore//crates/tierstore:tierstore-0.3.0_fb2de23c28_lint (buildrules//platforms:linux_x86_64#27db57317ae2fec7) (rustc tierstore-0.3.0_fb2de23c28_lint)\n" },
        .{ .play = .{ .out = build_mixed, .end = .{ .exited = 3 } }, .cmd = &build_cmd, .code = 3, .says = "farm run: not run again: a failure that is not a cut connection: [2026-11-21T13:40:17.627+00:00] Action failed: app//tools/build/examples/cshim:add (app//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (c_compile add_files/add.c (pic))\n" },
        .{ .play = .{ .out = "", .end = .{ .signal = 15 } }, .cmd = &build_cmd, .code = 143, .says = "farm run: not run again: buck2 was ended by signal 15\n" },
        .{ .play = .{ .out = build_cut, .end = .{ .exited = 3 } }, .cmd = &.{ "buck2", "run", "//:publish" }, .code = 3, .says = "farm run: not run again: `run` is not build, test or bxl\n" },
        .{ .play = .{ .out = local_cut, .end = .{ .exited = 3 } }, .cmd = &build_cmd, .code = 3, .says = "farm run: not run again: the cut run also ran 3 action(s) on this runner (`local: 3`); a farm build runs every action on the farm\n" },
    };
    for (cases) |k| {
        const c = try RunCase.init();
        defer c.deinit();
        var r = FakeRunner{ .plays = &.{k.play} };
        var w = FakeWaiter{};
        try t.expectEqual(k.code, try c.go(&r, &w, &.{}, k.cmd));
        try t.expectEqual(@as(usize, 1), r.calls);
        try t.expectEqual(@as(usize, 0), w.calls);
        try t.expectEqualStrings(k.says, c.err.written());
        try t.expectEqualStrings("", try c.read("summary.md"));
    }
}

test "farm run: a command that cannot start, a log that cannot be read or kept, and a summary that cannot be written exit 2" {
    const Case = struct { plays: []const Play, fail_at: ?usize = null, summary_dir: bool = false, first_is_dir: bool = false, says: []const u8 };
    const cut_then_pass = [_]Play{ .{ .out = build_cut, .end = .{ .exited = 3 } }, .{ .out = build_remote, .end = .{ .exited = 0 } } };
    const cases = [_]Case{
        .{ .plays = &cut_then_pass, .fail_at = 0, .says = "farm run: cannot run the command or write " },
        .{ .plays = &cut_then_pass, .fail_at = 1, .says = "farm run: cannot run the command again or write " },
        .{ .plays = &.{.{ .out = null, .end = .{ .exited = 3 } }}, .says = "farm run: cannot read " },
        .{ .plays = &.{.{ .out = null, .end = .{ .exited = 0 } }}, .says = "farm run: cannot read " },
        .{ .plays = &.{ .{ .out = build_cut, .end = .{ .exited = 3 } }, .{ .out = null, .end = .{ .exited = 3 } } }, .says = "farm run: cannot read " },
        .{ .plays = &cut_then_pass, .summary_dir = true, .says = "farm run: cannot write the job summary " },
        .{ .plays = &cut_then_pass, .first_is_dir = true, .says = "farm run: cannot keep the first log as " },
    };
    for (cases) |k| {
        const c = try RunCase.init();
        defer c.deinit();
        if (k.summary_dir) {
            try c.tmp.dir.deleteFile("summary.md");
            try c.tmp.dir.makeDir("summary.md");
        }
        if (k.first_is_dir) {
            try c.tmp.dir.makeDir("build.first.log");
            try c.tmp.dir.writeFile(.{ .sub_path = "build.first.log/keep", .data = "" });
        }
        var r = FakeRunner{ .plays = k.plays, .fail_at = k.fail_at };
        var w = FakeWaiter{};
        try t.expectEqual(@as(u8, 2), try c.go(&r, &w, &.{}, &build_cmd));
        try t.expect(std.mem.indexOf(u8, c.err.written(), k.says) != null);
    }
}

test "farm run: a buckconfig that cannot be read or names no farm is refused before anything runs" {
    for ([_]?[]const u8{ null, "[buck2_re_client]\n  cas_address = grpc://192.0.2.1:8980\n", "[buck2_re_client]\n  engine_address = grpc://192.0.2.1\n" }) |cfg| {
        const c = try RunCase.init();
        defer c.deinit();
        if (cfg) |text| {
            try c.tmp.dir.writeFile(.{ .sub_path = "farm.buckconfig", .data = text });
        } else {
            try c.tmp.dir.deleteFile("farm.buckconfig");
        }
        var r = FakeRunner{ .plays = &.{} };
        var w = FakeWaiter{};
        try t.expectEqual(@as(u8, 2), try c.go(&r, &w, &.{}, &build_cmd));
        try t.expectEqual(@as(usize, 0), r.calls);
        const says = if (cfg == null) "farm run: cannot read the farm's buckconfig " else "names no engine_address with a host and port: there is no farm to build on\n";
        try t.expect(std.mem.indexOf(u8, c.err.written(), says) != null);
    }
}

test "farm run: a wrong command line prints why and the usage, exits 2 and runs nothing" {
    const cases = [_]struct { args: []const []const u8, says: []const u8 }{
        .{ .args = &.{}, .says = "farm run: no `--` before the command\n" },
        .{ .args = &.{ "--config", "c", "--log", "l", "--summary", "s", "--", "buck2" }, .says = "farm run: the command after `--` is a buck2 and its subcommand at least\n" },
        .{ .args = &.{ "--log", "l", "--summary", "s", "--", "buck2", "build" }, .says = "farm run: --config is required\n" },
        .{ .args = &.{ "--config", "c", "--log", "", "--summary", "s", "--", "buck2", "build" }, .says = "farm run: --log is required\n" },
        .{ .args = &.{ "--config", "c", "--log", "l", "--", "buck2", "build" }, .says = "farm run: --summary is required\n" },
        .{ .args = &.{ "--config", "c", "--other", "x", "--", "buck2", "build" }, .says = "farm: --other is not a flag of this command\n" },
        .{ .args = &.{ "--config", "c", "--config", "d", "--", "buck2", "build" }, .says = "farm: --config is given twice\n" },
        .{ .args = &.{ "--config", "--", "buck2", "build" }, .says = "farm: --config has no value\n" },
        .{ .args = &.{ "config", "c", "--", "buck2", "build" }, .says = "farm: config is not a flag\n" },
        .{ .args = &.{ "--config", "c", "--log", "l", "--summary", "s", "--wait-minutes", "soon", "--", "buck2", "build" }, .says = "farm run: --wait-minutes is soon, not a whole number of minutes\n" },
    };
    for (cases) |k| {
        var out = std.Io.Writer.Allocating.init(t.allocator);
        defer out.deinit();
        var err = std.Io.Writer.Allocating.init(t.allocator);
        defer err.deinit();
        var r = FakeRunner{ .plays = &.{} };
        var w = FakeWaiter{};
        try t.expectEqual(@as(u8, 2), try run.main(t.allocator, k.args, r.runner(), w.waiter(), &out.writer, &err.writer));
        const want = try std.mem.concat(t.allocator, u8, &.{ k.says, run.usage });
        defer t.allocator.free(want);
        try t.expectEqualStrings(want, err.written());
        try t.expectEqual(@as(usize, 0), r.calls);
    }
}

test "farm run: the first log sits beside the log, as <name>.first.log" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("/r/build.first.log", try run.firstLogPath(a, "/r/build.log"));
    try t.expectEqualStrings("/r/out.first", try run.firstLogPath(a, "/r/out"));
}

// ---- farm connect ------------------------------------------------------------------------------------------------------------------

/// One `farm connect` in a scratch directory, the buckconfig written to `out` there.
const ConnectCase = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    out_path: []const u8,
    summary: []const u8,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,

    fn init() !*ConnectCase {
        const c = try t.allocator.create(ConnectCase);
        c.arena = std.heap.ArenaAllocator.init(t.allocator);
        const a = c.arena.allocator();
        c.tmp = t.tmpDir(.{});
        const dir = try c.tmp.dir.realpathAlloc(a, ".");
        c.out_path = try std.fs.path.join(a, &.{ dir, ".buckconfig.local" });
        c.summary = try std.fs.path.join(a, &.{ dir, "summary.md" });
        try c.tmp.dir.writeFile(.{ .sub_path = "summary.md", .data = "" });
        c.out = std.Io.Writer.Allocating.init(a);
        c.err = std.Io.Writer.Allocating.init(a);
        return c;
    }

    fn deinit(c: *ConnectCase) void {
        c.tmp.cleanup();
        c.arena.deinit();
        t.allocator.destroy(c);
    }

    /// `farm connect` with the farm's values, `extra` after them.
    fn go(c: *ConnectCase, w: *FakeWaiter, address: []const u8, extra: []const []const u8) !u8 {
        const a = c.arena.allocator();
        var args = std.ArrayList([]const u8).empty;
        try args.appendSlice(a, &.{ "--address", address, "--instance", "ci", "--properties", "OSFamily=linux", "--out", c.out_path, "--summary", c.summary });
        try args.appendSlice(a, extra);
        return connect.main(a, args.items, w.waiter(), &c.out.writer, &c.err.writer);
    }

    fn read(c: *ConnectCase, name: []const u8) ![]u8 {
        return c.tmp.dir.readFileAlloc(c.arena.allocator(), name, 1 << 20);
    }
};

const masks = "::add-mask::grpc://192.0.2.1:8980\n::add-mask::192.0.2.1\n";

const written_config =
    \\# Written by `farm connect` (buildrules, tools/farm): the farm this job builds on.
    \\[buck2_re_client]
    \\  engine_address = grpc://192.0.2.1:8980
    \\  action_cache_address = grpc://192.0.2.1:8980
    \\  cas_address = grpc://192.0.2.1:8980
    \\  instance_name = ci
    \\  tls = false
    \\  execution_concurrency_limit = 256
    \\  grpc_keepalive_timeout_secs = 60
    \\  max_concurrent_uploads_per_action = 4
    \\[buildrules_re]
    \\  linux_x86_64_properties = OSFamily=linux
    \\
;

test "farm connect: a farm that answers at once gets its buckconfig written, its address masked first, and no summary line" {
    const c = try ConnectCase.init();
    defer c.deinit();
    var w = FakeWaiter{};
    try t.expectEqual(@as(u8, 0), try c.go(&w, "grpc://192.0.2.1:8980", &.{}));
    try t.expectEqualStrings(written_config, try c.read(".buckconfig.local"));
    try t.expectEqual(@as(u64, 20 * min), w.limit_ms);
    try t.expectEqualStrings("192.0.2.1", w.host());
    try t.expectEqual(@as(u16, 8980), w.port);
    const said = try std.fmt.allocPrint(c.arena.allocator(), masks ++ "farm connect: the farm answers; wrote {s}\n", .{c.out_path});
    try t.expectEqualStrings(said, c.out.written());
    try t.expectEqualStrings("", try c.read("summary.md"));
    try t.expectEqualStrings("", c.err.written());
}

test "farm connect: a farm that answered after a wait gets the wait in the job summary; tls and the wait are taken from the command line" {
    const c = try ConnectCase.init();
    defer c.deinit();
    var w = FakeWaiter{ .result = .{ .answered = 185_000 } };
    try t.expectEqual(@as(u8, 0), try c.go(&w, "grpc://192.0.2.1:8980", &.{ "--tls", "true", "--wait-minutes", "30" }));
    try t.expectEqual(@as(u64, 30 * min), w.limit_ms);
    const note = "farm connect: the farm answered after a wait of 3m05s (the connection to it was down when the job joined its network)";
    try t.expectEqualStrings(note ++ "\n", try c.read("summary.md"));
    try t.expect(std.mem.indexOf(u8, c.out.written(), note ++ "\n") != null);
    const cfg = try c.read(".buckconfig.local");
    try t.expect(std.mem.indexOf(u8, cfg, "\n  tls = true\n") != null);
}

test "farm connect: a farm that does not answer within the wait fails the step and writes nothing" {
    const c = try ConnectCase.init();
    defer c.deinit();
    var w = FakeWaiter{ .result = .{ .gave_up = 20 * min } };
    try t.expectEqual(@as(u8, 1), try c.go(&w, "grpc://192.0.2.1:8980", &.{}));
    try t.expectError(error.FileNotFound, c.tmp.dir.access(".buckconfig.local", .{}));
    try t.expectEqualStrings("::error title=farm connect::the farm did not answer on its port within 20m00s of joining its network. Not building: with no farm buck2 would build on this runner. Look at whether the farm is up, the network policy between this job and the farm, and the trust of this job's token.\n", c.err.written());
}

test "farm connect: an empty value, a line break, a tls other than true or false, or an address without a port is refused before any wait" {
    const empty = "::error title=farm connect::the farm's address, instance name or worker property set is empty (a job of a fork's pull request gets no repository variables); refusing, because buck2 would build on the runner instead of the farm\n";
    const line_break = "::error title=farm connect::a value holds a line break; each value must be one line of the buckconfig\n";
    const cases = [_]struct { address: []const u8, extra: []const []const u8, says: []const u8, masked: bool }{
        .{ .address = "", .extra = &.{}, .says = empty, .masked = false },
        .{ .address = "grpc://192.0.2.1:8980", .extra = &.{ "--properties", "" }, .says = empty, .masked = true },
        .{ .address = "grpc://192.0.2.1:8980\n", .extra = &.{}, .says = line_break, .masked = false },
        .{ .address = "grpc://192.0.2.1:8980", .extra = &.{ "--tls", "true\r" }, .says = line_break, .masked = true },
        .{ .address = "grpc://192.0.2.1:8980", .extra = &.{ "--tls", "yes" }, .says = "::error title=farm connect::--tls is neither true nor false\n", .masked = true },
        .{ .address = "grpc://192.0.2.1", .extra = &.{}, .says = "::error title=farm connect::the farm's address has no host and port (host:port, after an optional scheme)\n", .masked = true },
    };
    for (cases) |k| {
        const c = try ConnectCase.init();
        defer c.deinit();
        var w = FakeWaiter{};
        // --properties given twice is a usage error, so the case's own replaces the default by building the line itself
        const a = c.arena.allocator();
        var args = std.ArrayList([]const u8).empty;
        try args.appendSlice(a, &.{ "--address", k.address, "--instance", "ci", "--out", c.out_path, "--summary", c.summary });
        var has_props = false;
        for (k.extra) |e| has_props = has_props or std.mem.eql(u8, e, "--properties");
        if (!has_props) try args.appendSlice(a, &.{ "--properties", "OSFamily=linux" });
        try args.appendSlice(a, k.extra);
        try t.expectEqual(@as(u8, 1), try connect.main(a, args.items, w.waiter(), &c.out.writer, &c.err.writer));
        try t.expectEqualStrings(k.says, c.err.written());
        try t.expectEqual(@as(usize, 0), w.calls);
        try t.expectEqual(k.masked, std.mem.startsWith(u8, c.out.written(), "::add-mask::"));
    }
}

test "farm connect: an existing buckconfig, one that cannot be written, or a summary that cannot be written exits 2" {
    {
        const c = try ConnectCase.init();
        defer c.deinit();
        try c.tmp.dir.writeFile(.{ .sub_path = ".buckconfig.local", .data = "[x]\n" });
        var w = FakeWaiter{};
        try t.expectEqual(@as(u8, 2), try c.go(&w, "grpc://192.0.2.1:8980", &.{}));
        try t.expectEqual(@as(usize, 0), w.calls);
        try t.expectEqualStrings("[x]\n", try c.read(".buckconfig.local"));
        try t.expect(std.mem.indexOf(u8, c.err.written(), " exists already;") != null);
    }
    {
        const c = try ConnectCase.init();
        defer c.deinit();
        c.out_path = try std.fs.path.join(c.arena.allocator(), &.{ std.fs.path.dirname(c.summary).?, "no-such-dir", ".buckconfig.local" });
        var w = FakeWaiter{};
        try t.expectEqual(@as(u8, 2), try c.go(&w, "grpc://192.0.2.1:8980", &.{}));
        try t.expect(std.mem.indexOf(u8, c.err.written(), "farm connect: cannot write ") != null);
    }
    {
        const c = try ConnectCase.init();
        defer c.deinit();
        try c.tmp.dir.deleteFile("summary.md");
        try c.tmp.dir.makeDir("summary.md");
        var w = FakeWaiter{ .result = .{ .answered = 61_000 } };
        try t.expectEqual(@as(u8, 2), try c.go(&w, "grpc://192.0.2.1:8980", &.{}));
        try t.expect(std.mem.indexOf(u8, c.err.written(), "farm connect: cannot write the job summary ") != null);
    }
}

test "farm connect: a missing flag, an unknown one or a wrong wait prints why and the usage and exits 2" {
    const cases = [_]struct { args: []const []const u8, says: []const u8 }{
        .{ .args = &.{}, .says = "farm connect: --address is required\nfarm connect: --instance is required\nfarm connect: --properties is required\nfarm connect: --out is required\nfarm connect: --summary is required\n" },
        .{ .args = &.{ "--address", "a:1", "--instance", "i", "--properties", "p", "--out", "o" }, .says = "farm connect: --summary is required\n" },
        .{ .args = &.{"--port"}, .says = "farm: --port is not a flag of this command\n" },
    };
    for (cases) |k| {
        var out = std.Io.Writer.Allocating.init(t.allocator);
        defer out.deinit();
        var err = std.Io.Writer.Allocating.init(t.allocator);
        defer err.deinit();
        var w = FakeWaiter{};
        try t.expectEqual(@as(u8, 2), try connect.main(t.allocator, k.args, w.waiter(), &out.writer, &err.writer));
        const want = try std.mem.concat(t.allocator, u8, &.{ k.says, connect.usage });
        defer t.allocator.free(want);
        try t.expectEqualStrings(want, err.written());
        try t.expectEqualStrings("", out.written());
    }
    // a wrong wait says only that, with the usage
    var err = std.Io.Writer.Allocating.init(t.allocator);
    defer err.deinit();
    var out = std.Io.Writer.Allocating.init(t.allocator);
    defer out.deinit();
    var w = FakeWaiter{};
    try t.expectEqual(@as(u8, 2), try connect.main(t.allocator, &.{ "--address", "a:1", "--instance", "i", "--properties", "p", "--out", "o", "--summary", "s", "--wait-minutes", "600" }, w.waiter(), &out.writer, &err.writer));
    try t.expectEqualStrings("farm connect: --wait-minutes is 600, more than 120: the job's own timeout would end it first\n" ++ connect.usage, err.written());
}

// ---- the real runner, the real wait, and the verbs ---------------------------------------------------------------------------------

test "the real runner copies what the command prints to its log, keeps its exit code, and fails on a program or log it cannot open" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const log = try std.fs.path.join(a, &.{ dir, "run.log" });
    const src = try std.fs.path.join(a, &.{ dir, "recorded.log" });
    try tmp.dir.writeFile(.{ .sub_path = "recorded.log", .data = build_remote });
    var none: u8 = 0;
    try t.expectEqualDeep(run.End{ .exited = 0 }, try run.runTee(&none, a, &.{ "cat", src }, log));
    try t.expectEqualStrings(build_remote, try tmp.dir.readFileAlloc(a, "run.log", 1 << 20));
    // a failing command keeps its own status, and its error stream is in the log
    const failed = try run.runTee(&none, a, &.{ "ls", "no-such-file" }, log);
    try t.expect(failed == .exited and failed.exited != 0);
    try t.expect(std.mem.indexOf(u8, try tmp.dir.readFileAlloc(a, "run.log", 1 << 20), "no-such-file") != null);
    // a program that does not exist, and a log that cannot be created
    try t.expectError(error.FileNotFound, run.runTee(&none, a, &.{"no-such-program-of-this-test"}, log));
    try t.expectError(error.FileNotFound, run.runTee(&none, a, &.{ "cat", src }, try std.fs.path.join(a, &.{ dir, "no-such-dir", "run.log" })));
}

test "a child's end reads as its exit code, or as the signal or status that ended it" {
    try t.expectEqualDeep(run.End{ .exited = 3 }, run.endOf(.{ .Exited = 3 }));
    try t.expectEqualDeep(run.End{ .signal = 15 }, run.endOf(.{ .Signal = 15 }));
    try t.expectEqualDeep(run.End{ .signal = 19 }, run.endOf(.{ .Stopped = 19 }));
    try t.expectEqualDeep(run.End{ .signal = 7 }, run.endOf(.{ .Unknown = 7 }));
}

test "farm: the verbs are connect and run; anything else is the usage" {
    var out = std.Io.Writer.Allocating.init(t.allocator);
    defer out.deinit();
    var err = std.Io.Writer.Allocating.init(t.allocator);
    defer err.deinit();
    for ([_][]const []const u8{ &.{}, &.{"build"}, &.{"--help"} }) |args| {
        err.clearRetainingCapacity();
        try t.expectEqual(@as(u8, 2), try farm.realDispatch(t.allocator, args, &out.writer, &err.writer));
        try t.expectEqualStrings(farm.usage, err.written());
    }
}

test "farm connect, for real: a farm listening on 127.0.0.1 answers, and its buckconfig is written" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const address = try std.fmt.allocPrint(a, "grpc://127.0.0.1:{d}", .{server.listen_address.getPort()});
    const out_path = try std.fs.path.join(a, &.{ dir, "farm.buckconfig" });
    const summary = try std.fs.path.join(a, &.{ dir, "summary.md" });
    var out = std.Io.Writer.Allocating.init(a);
    var err = std.Io.Writer.Allocating.init(a);
    const args = [_][]const u8{ "connect", "--address", address, "--instance", "ci", "--properties", "p", "--out", out_path, "--summary", summary, "--wait-minutes", "0" };
    try t.expectEqual(@as(u8, 0), try farm.realDispatch(a, &args, &out.writer, &err.writer));
    const cfg = try tmp.dir.readFileAlloc(a, "farm.buckconfig", 1 << 20);
    try t.expect(std.mem.indexOf(u8, cfg, try std.fmt.allocPrint(a, "  engine_address = {s}\n", .{address})) != null);

    // and `farm run` of a command that passes on that farm, through the real runner
    try tmp.dir.writeFile(.{ .sub_path = "recorded.log", .data = build_remote });
    const recorded = try std.fs.path.join(a, &.{ dir, "recorded.log" });
    const log = try std.fs.path.join(a, &.{ dir, "build.log" });
    const run_args = [_][]const u8{ "run", "--config", out_path, "--log", log, "--summary", summary, "--", "cat", recorded };
    try t.expectEqual(@as(u8, 0), try farm.realDispatch(a, &run_args, &out.writer, &err.writer));
    try t.expectEqualStrings(build_remote, try tmp.dir.readFileAlloc(a, "build.log", 1 << 20));
}
