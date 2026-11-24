//! The commands a stage runs, behind an interface, so the tests drive the steps with a fake that records the calls and writes the files a real
//! build would. The files a stage reads and writes are real files (the tests use a temporary directory).
const std = @import("std");

pub const Out = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
    /// Set when the command was still running at the runner's limit and was stopped (bounded.zig): how long it had run, in milliseconds.
    stopped_ms: ?u64 = null,
};

pub const Io = struct {
    ctx: *anyopaque,
    run_fn: *const fn (ctx: *anyopaque, a: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) anyerror!Out,

    /// How a wait is made (the retry back-off). The real one sleeps the thread; the tests pass one that records the milliseconds asked and returns at once,
    /// so no test depends on, or waits for, the clock.
    sleep_fn: *const fn (ctx: *anyopaque, ms: u64) void = realSleep,

    /// Runs `argv` in `cwd`. A command the runner stopped at its limit is `error.CommandHung`, after a line that names it, says how long it ran,
    /// and shows the last lines it wrote: a stopped command is never read as a result (not as a cut connection to rerun, nor as a failed build).
    pub fn run(self: Io, a: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !Out {
        const r = try self.run_fn(self.ctx, a, cwd, argv);
        if (r.stopped_ms) |ms| {
            std.debug.print("{s}", .{try hungMessage(a, argv, ms, r)});
            return error.CommandHung;
        }
        return r;
    }

    pub fn sleep(self: Io, ms: u64) void {
        self.sleep_fn(self.ctx, ms);
    }

    fn realSleep(_: *anyopaque, ms: u64) void {
        std.Thread.sleep(ms * std.time.ns_per_ms);
    }
};

/// What a stopped command says: the command, how long it ran, and the last lines of what it wrote.
pub fn hungMessage(a: std.mem.Allocator, argv: []const []const u8, ms: u64, r: Out) ![]const u8 {
    return std.fmt.allocPrint(a, "stage: `{s}` was still running after {d} min, the limit of one command of a stage, and was stopped with its process group. The last lines it wrote:\n{s}\n{s}\n", .{ try std.mem.join(a, " ", argv), ms / std.time.ms_per_min, tail(r.stderr, 30), tail(r.stdout, 10) });
}

/// The last `n` lines of `text`: what a failure shows of a long output.
pub fn tail(text: []const u8, n: usize) []const u8 {
    var end = text.len;
    var seen: usize = 0;
    while (end > 0) {
        end -= 1;
        if (text[end] == '\n' and end + 1 != text.len) {
            seen += 1;
            if (seen == n) return text[end + 1 ..];
        }
    }
    return text;
}

pub fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stdout().writeAll(s) catch {};
}

const t = std.testing;

fn noRun(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const []const u8) anyerror!Out {
    return error.NotRun;
}

test "an Io with no sleep given waits through the real one, and a wait of nothing returns at once" {
    var unused: u8 = 0;
    const io = Io{ .ctx = &unused, .run_fn = noRun };
    io.sleep(0);
    try t.expectError(error.NotRun, io.run(t.allocator, "/", &.{"x"}));
}

test "an Io given a sleep calls it with the milliseconds asked, and waits for nothing" {
    const Rec = struct {
        asked: u64 = 0,
        fn sleepFn(ctx: *anyopaque, ms: u64) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.asked = ms;
        }
    };
    var rec = Rec{};
    const io = Io{ .ctx = &rec, .run_fn = noRun, .sleep_fn = Rec.sleepFn };
    io.sleep(20_000);
    try t.expectEqual(@as(u64, 20_000), rec.asked);
}

test "tail keeps the last lines, and the whole text when it is shorter" {
    try t.expectEqualStrings("c\nd\n", tail("a\nb\nc\nd\n", 2));
    try t.expectEqualStrings("a\nb\n", tail("a\nb\n", 5));
    try t.expectEqualStrings("d", tail("a\nb\nc\nd", 1));
    try t.expectEqualStrings("", tail("", 3));
}

// Catches: a stopped command read as a result (a cut to rerun, or a build that failed), or its line missing the command, the time, or its output.
test "a command the runner stopped is CommandHung, and its line names it, the time it ran, and the last lines it wrote" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Stopped = struct {
        fn run(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const []const u8) anyerror!Out {
            return .{ .code = 255, .stdout = "", .stderr = "Error: (RE channel error: code: 'Unknown error')\n", .stopped_ms = 30 * std.time.ms_per_min };
        }
    };
    var unused: u8 = 0;
    const io = Io{ .ctx = &unused, .run_fn = Stopped.run };
    try t.expectError(error.CommandHung, io.run(a, "/", &.{ "buck2", "build", "//:a" }));
    const r = Out{ .code = 255, .stdout = "out\n", .stderr = "a\nb\n", .stopped_ms = 31 * std.time.ms_per_min + 59_999 };
    try t.expectEqualStrings(
        "stage: `buck2 build //:a` was still running after 31 min, the limit of one command of a stage, and was stopped with its process group. The last lines it wrote:\na\nb\n\nout\n\n",
        try hungMessage(a, &.{ "buck2", "build", "//:a" }, r.stopped_ms.?, r),
    );
}

test "a command that was not stopped is its result, whatever its status" {
    const Failed = struct {
        fn run(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const []const u8) anyerror!Out {
            return .{ .code = 1, .stdout = "", .stderr = "BUILD FAILED\n" };
        }
    };
    var unused: u8 = 0;
    const io = Io{ .ctx = &unused, .run_fn = Failed.run };
    const r = try io.run(t.allocator, "/", &.{"x"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("BUILD FAILED\n", r.stderr);
}
