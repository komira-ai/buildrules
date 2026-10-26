//! The commands a stage runs, behind an interface, so the tests drive the steps with a fake that records the calls and writes the files a real
//! build would. The files a stage reads and writes are real files (the tests use a temporary directory).
const std = @import("std");

pub const Out = struct { code: u8, stdout: []const u8, stderr: []const u8 };

pub const Io = struct {
    ctx: *anyopaque,
    run_fn: *const fn (ctx: *anyopaque, a: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) anyerror!Out,

    /// How a wait is made (the retry back-off). The real one sleeps the thread; the tests pass one that records the milliseconds asked and returns at once,
    /// so no test depends on, or waits for, the clock.
    sleep_fn: *const fn (ctx: *anyopaque, ms: u64) void = realSleep,

    pub fn run(self: Io, a: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !Out {
        return self.run_fn(self.ctx, a, cwd, argv);
    }

    pub fn sleep(self: Io, ms: u64) void {
        self.sleep_fn(self.ctx, ms);
    }

    fn realSleep(_: *anyopaque, ms: u64) void {
        std.Thread.sleep(ms * std.time.ns_per_ms);
    }
};

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
