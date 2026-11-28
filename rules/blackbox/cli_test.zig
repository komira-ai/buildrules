//! cli.zig: the command chosen by the first argument, an allocation that fails, and streams that cannot be written (a message lost is not a crash).

const std = @import("std");
const cli = @import("cli.zig");
const pb = @import("pbkit.zig");
const kit = @import("testkit.zig");
const t = std.testing;

test "no command, or one that is not `run` or `probe`, is exit 2" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.argv = &.{"blackbox_run"};
    try t.expectEqual(@as(u8, 2), cli.entry(c.a, c.io()));
    c.argv = &.{ "blackbox_run", "test" };
    try t.expectEqual(@as(u8, 2), cli.entry(c.a, c.io()));
    try t.expectEqualStrings("blackbox_run: the commands are `run` and `probe` (README.md), not ``\n" ++
        "blackbox_run: the commands are `run` and `probe` (README.md), not `test`\n", c.stderr());
}

test "`run` and `probe` are run with the arguments after them" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.argv = &.{ "blackbox_run", "run" };
    try t.expectEqual(@as(u8, 2), cli.entry(c.a, c.io()));
    c.argv = &.{ "blackbox_run", "probe" };
    try t.expectEqual(@as(u8, 1), cli.entry(c.a, c.io()));
    try t.expectEqualStrings("blackbox_run: run: `--image` is required\n" ++
        "blackbox_run: probe: not a farm job: the root holds no job directory (a top-level `.<name>/` holding `action` and `command`), so this run is not a job of the farm's executor\n", c.stderr());
}

test "an allocation that fails ends the command: `out of memory`, exit 1" {
    var c = try kit.Case.init();
    defer c.deinit();
    var none = std.testing.FailingAllocator.init(c.a, .{ .fail_index = 0 });
    c.argv = &.{ "blackbox_run", "run", "--flag", "x" };
    try t.expectEqual(@as(u8, 1), cli.entry(none.allocator(), c.io()));
    try t.expectEqualStrings("blackbox_run: out of memory\n", c.stderr());
}

test "a message or a report that cannot be written is lost, and the status is unchanged" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.argv = &.{ "blackbox_run", "probe", "--expect", "OSFamily=Linux" };
    c.put(".job/action", pb.action(c.a, &.{}));
    c.put(".job/command", pb.command(c.a, c.argv, &.{.{ "ISA", "x86-64" }}));
    // A buffer that holds every line, so the write succeeds and the flush after it fails; and none, so the write itself fails.
    var big_out: [4096]u8 = undefined;
    var big_err: [4096]u8 = undefined;
    var none_out: [0]u8 = undefined;
    var none_err: [0]u8 = undefined;
    for ([_][2][]u8{ .{ &big_out, &big_err }, .{ &none_out, &none_err } }) |bufs| {
        var out = kit.failingWriter(bufs[0]);
        var err = kit.failingWriter(bufs[1]);
        var io = c.io();
        io.out = &out;
        io.err = &err;
        try t.expectEqual(@as(u8, 1), cli.entry(c.a, io));
    }
}
