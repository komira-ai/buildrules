//! ctx.zig: what every command runs in. The real child-process seams (`spawn`, `execReal`) are run here against the pinned busybox's applets, which the test
//! action puts on PATH; every other test gives the commands a fake. A seam that runs the child in the wrong directory, loses its output or reports
//! its exit code wrong makes `sync` run cargo somewhere else or call a failed cargo a success.

const std = @import("std");
const ctxm = @import("ctx.zig");
const kit = @import("testkit.zig");
const t = std.testing;

test "execReal: the child runs in the context's directory, with the added variables on top of the inherited ones, and its stdout is captured whole" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try h.tmp.dir.makePath("work");
    var ctx = try h.ctx.into("work");
    defer ctx.dir.close();
    const here = try ctx.dir.realpathAlloc(h.a(), ".");
    const pwd = try ctxm.execReal(&ctx, .{ .argv = &.{"pwd"}, .capture = true });
    try t.expectEqual(@as(u8, 0), pwd.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(h.a(), "{s}\n", .{here}), pwd.stdout);
    const env = try ctxm.execReal(&ctx, .{ .argv = &.{"env"}, .env = &.{ .{ "BUILDRULES_CTX_PROBE", "1" }, .{ "BUILDRULES_CTX_OTHER", "two words" } }, .capture = true });
    try t.expect(kit.contains(env.stdout, "\nBUILDRULES_CTX_PROBE=1\n") or std.mem.startsWith(u8, env.stdout, "BUILDRULES_CTX_PROBE=1\n"));
    try t.expect(kit.contains(env.stdout, "BUILDRULES_CTX_OTHER=two words\n"));
    // The inherited environment is there too: PATH is how the applet was found.
    try t.expect(kit.contains(env.stdout, "PATH="));
    // More output than the reader's buffer holds.
    const long = try h.a().alloc(u8, 10000);
    @memset(long, 'x');
    const echo = try ctxm.execReal(&ctx, .{ .argv = &.{ "echo", long }, .capture = true });
    try t.expectEqual(@as(usize, 10001), echo.stdout.len);
    // Not captured: the output goes where the program's does, and the result holds none.
    const quiet = try ctxm.execReal(&ctx, .{ .argv = &.{ "true" } });
    try t.expectEqual(@as(u8, 0), quiet.code);
    try t.expectEqualStrings("", quiet.stdout);
}

test "execReal: a child that exits non-zero is that code, and one that cannot be started is an error" {
    const h = try kit.Harness.create();
    defer h.destroy();
    const failed = try ctxm.execReal(&h.ctx, .{ .argv = &.{"false"}, .capture = true });
    try t.expectEqual(@as(u8, 1), failed.code);
    try t.expectError(error.FileNotFound, ctxm.execReal(&h.ctx, .{ .argv = &.{"buildrules-no-such-program"}, .capture = true }));
}

test "spawn: the exit code of the child is returned, and the context's streams are flushed first" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), try ctxm.spawn(&h.ctx, &.{"true"}));
    try t.expectEqual(@as(u8, 1), try ctxm.spawn(&h.ctx, &.{"false"}));
    try t.expectError(error.FileNotFound, ctxm.spawn(&h.ctx, &.{"buildrules-no-such-program"}));
}

test "the helpers: missingLines, sha256Hex, flagValue, readOpt, write and into" {
    const h = try kit.Harness.create();
    defer h.destroy();
    const a = h.a();
    const missing = try ctxm.missingLines(a, "a\n b \r\nc", &.{ "a", "b", "d", "c", "e" });
    try t.expectEqual(@as(usize, 2), missing.len);
    try t.expectEqualStrings("d", missing[0]);
    try t.expectEqualStrings("e", missing[1]);
    try t.expectEqual(@as(usize, 0), (try ctxm.missingLines(a, "", &.{})).len);
    try t.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", try ctxm.sha256Hex(a, "abc"));
    const args = [_][]const u8{ "--flag", "value", "last" };
    var i: usize = 0;
    try t.expectEqualStrings("value", ctxm.flagValue(&args, &i).?);
    try t.expectEqual(@as(usize, 1), i);
    i = 2;
    try t.expect(ctxm.flagValue(&args, &i) == null);
    try t.expectEqual(@as(usize, 2), i);
    // readOpt: a file, no file, and something that is not readable as one (a directory) is the error and not "no file".
    try h.put("f.txt", "data");
    try t.expectEqualStrings("data", (try h.ctx.readOpt("f.txt")).?);
    try t.expect((try h.ctx.readOpt("nope.txt")) == null);
    try h.tmp.dir.makePath("adir");
    try t.expectError(error.IsDir, h.ctx.readOpt("adir"));
    // write: makes the parents, leaves no temporary file, replaces what is there.
    try h.ctx.write("x/y/z.txt", "one");
    try h.ctx.write("x/y/z.txt", "two");
    try h.ctx.write("top.txt", "t");
    try t.expectEqualStrings("two", h.read("x/y/z.txt"));
    try t.expect(!h.has("x/y/z.txt.buildrules-tmp"));
    try t.expect(!h.has("top.txt.buildrules-tmp"));
    try t.expect(h.ctx.exists("top.txt"));
    try t.expect(!h.ctx.exists("nothing"));
    // into: a subdirectory is a context of its own, a missing one is an error.
    var sub = try h.ctx.into("x");
    defer sub.dir.close();
    try t.expect(sub.exists("y/z.txt"));
    try t.expectError(error.FileNotFound, h.ctx.into("absent"));
    // exit codes and the printers
    try t.expectEqual(ctxm.exit_fail, h.ctx.fail("a {s}", .{"failure"}));
    try t.expectEqual(ctxm.exit_usage, h.ctx.usage("a {s}", .{"usage"}));
    h.ctx.say("said {d}", .{1});
}

test "write: a parent that is a file, a temporary name that is a directory and a destination that is a directory are each an error, and the destination is not damaged" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try h.put("afile", "x");
    try t.expectError(error.NotDir, h.ctx.write("afile/inside.txt", "data"));
    try h.tmp.dir.makePath("blocked.txt.buildrules-tmp");
    try t.expectError(error.IsDir, h.ctx.write("blocked.txt", "data"));
    try t.expect(!h.has("blocked.txt"));
    try h.put("full/dir/file", "x");
    if (h.ctx.write("full", "data")) |_| return error.WroteOverADirectory else |_| {}
    // The directory is as it was.
    try t.expectEqualStrings("x", h.read("full/dir/file"));
}
