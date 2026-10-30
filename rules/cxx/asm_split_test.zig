const std = @import("std");
const S = @import("asm_split.zig");
const t = std.testing;

test "splitSemicolons: every semicolon is a line break, nothing else changes" {
    const got = try S.splitSemicolons(t.allocator, "mov x0,#7; mov x0,#9\n  ret;\n");
    defer t.allocator.free(got);
    try t.expectEqualStrings("mov x0,#7\n mov x0,#9\n  ret\n\n", got);
    const same = try S.splitSemicolons(t.allocator, "nop\n");
    defer t.allocator.free(same);
    try t.expectEqualStrings("nop\n", same);
}

test "parseArgs: --out, a file, --, and a command" {
    const c = S.parseArgs(&.{ "--out", "o.s", "--", "cc", "-E", "a.S" }).?;
    try t.expectEqualStrings("o.s", c.out);
    try t.expectEqual(@as(usize, 3), c.argv.len);
    try t.expectEqualStrings("cc", c.argv[0]);
    try t.expect(S.parseArgs(&.{ "--out", "o.s", "--" }) == null);
    try t.expect(S.parseArgs(&.{ "--out", "o.s", "cc", "-E" }) == null);
    try t.expect(S.parseArgs(&.{ "-o", "o.s", "--", "cc" }) == null);
    try t.expect(S.parseArgs(&.{}) == null);
}

test "finish: a compiler that exited 0 has its output written, split; one that failed has its status returned and nothing written; one that did not exit is 2" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &dir_buf);
    const ok_path = try std.fs.path.join(a, &.{ dir, "ok.s" });
    const bad_path = try std.fs.path.join(a, &.{ dir, "bad.s" });
    var sink = std.ArrayList(u8).init(a);

    try t.expectEqual(@as(u8, 0), try S.finish(a, ok_path, .{ .term = .{ .Exited = 0 }, .stdout = "mov x0,#7; add x0,x0,#35\nret\n", .stderr = "a warning\n" }, sink.writer()));
    try t.expectEqualStrings("a warning\n", sink.items);
    const got = try tmp.dir.readFileAlloc(a, "ok.s", 1024);
    try t.expectEqualStrings("mov x0,#7\n add x0,x0,#35\nret\n", got);

    sink.clearRetainingCapacity();
    try t.expectEqual(@as(u8, 3), try S.finish(a, bad_path, .{ .term = .{ .Exited = 3 }, .stdout = "partial;", .stderr = "error: no such file\n" }, sink.writer()));
    try t.expectEqualStrings("error: no such file\n", sink.items);
    try t.expectError(error.FileNotFound, tmp.dir.access("bad.s", .{}));

    sink.clearRetainingCapacity();
    try t.expectEqual(@as(u8, 2), try S.finish(a, bad_path, .{ .term = .{ .Signal = 9 }, .stdout = "", .stderr = "" }, sink.writer()));
    try t.expect(std.mem.indexOf(u8, sink.items, "did not exit") != null);
}

test "run: a program that cannot be started is status 2 with a message that names it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sink = std.ArrayList(u8).init(a);
    try t.expectEqual(@as(u8, 2), try S.run(a, .{ .out = "never.s", .argv = &.{"/definitely/not/a/program"} }, sink.writer()));
    try t.expect(std.mem.indexOf(u8, sink.items, "/definitely/not/a/program") != null);
}
