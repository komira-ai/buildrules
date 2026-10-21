//! The cases of cmds.zig: what `check marker` and `check expect` do with the result of the program they start (the toolbox): the file written
//! only on success and whole, the status, the messages, the captured output. How the program is started is runspec_test.zig.

const std = @import("std");
const t = std.testing;
const kit = @import("checkkit.zig");

// ---- marker -----------------------------------------------------------------------------------------------------

test "marker: a program that passed writes the file, `passed` and a newline, and says nothing" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o" }, &.{"true"}), 0, "", "");
    try t.expectEqualStrings("passed\n", try c.read("o"));
}

test "marker --stamp: the file holds that text exactly" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o", "--stamp", "{\"version\": 1}\nline two" }, &.{"true"}), 0, "", "");
    try t.expectEqualStrings("{\"version\": 1}\nline two", try c.read("o"));
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o", "--stamp", "" }, &.{"true"}), 0, "", "");
    try t.expectEqualStrings("", try c.read("o"));
}

test "marker: a program that failed writes nothing, leaves an earlier file as it was, says TEST FAILED, and gives its status" {
    var c = try kit.Case.init();
    defer c.deinit();
    const failed = try std.fmt.allocPrint(c.alloc(), "check marker: TEST FAILED: {s}\n", .{c.toolbox});
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o" }, &.{"false"}), 1, "", failed);
    try t.expect(!c.exists("o"));
    try c.put("o", "from an earlier run");
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o" }, &.{"false"}), 1, "", failed);
    try t.expectEqualStrings("from an earlier run", try c.read("o"));
    // its own status, not always 1
    try kit.expectFailure(try c.runTool(&.{ "marker", "--out", "o" }, &.{"nosuchapplet"}), 127, "TEST FAILED");
    // and a success replaces the earlier file
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o" }, &.{"true"}), 0, "", "");
    try t.expectEqualStrings("passed\n", try c.read("o"));
}

test "marker --capture: a passing test's output is held back; a failing test's is written to stdout, then its stderr, before TEST FAILED" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("good", "what the test printed\n");
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o", "--capture" }, &.{ "cat", "good" }), 0, "", "");
    try t.expectEqualStrings("passed\n", try c.read("o"));
    c.tmp.dir.deleteFile("o") catch {};
    // `cat good missing` prints good on stdout, then fails with a message on stderr
    const r = try c.runTool(&.{ "marker", "--out", "o", "--capture" }, &.{ "cat", "good", "missing" });
    try kit.expectResult(r, 1, "what the test printed\ncat: missing: No such file or directory\n", try std.fmt.allocPrint(c.alloc(), "check marker: TEST FAILED: {s}\n", .{c.toolbox}));
    try t.expect(!c.exists("o"));
}

test "marker --stamp-log: the file is what the test wrote, all of it, however long" {
    var c = try kit.Case.init();
    defer c.deinit();
    const big = try c.alloc().alloc(u8, 400_000);
    for (big, 0..) |*b, i| b.* = @intCast('a' + i % 26);
    try c.put("big", big);
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o", "--capture", "--stamp-log" }, &.{ "cat", "big" }), 0, "", "");
    try t.expectEqualSlices(u8, big, try c.read("o"));
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o", "--capture", "--stamp-log" }, &.{"true"}), 0, "", "");
    try t.expectEqualStrings("", try c.read("o"));
}

test "marker: --out is required; --stamp-log needs --capture and takes no --stamp" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try c.runTool(&.{"marker"}, &.{"true"}), 2, "", "check marker: --out is required\n");
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o", "--stamp-log" }, &.{"true"}), 2, "", "check marker: --stamp-log needs --capture and takes no --stamp\n");
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o", "--capture", "--stamp-log", "--stamp", "x" }, &.{"true"}), 2, "", "check marker: --stamp-log needs --capture and takes no --stamp\n");
    try t.expect(!c.exists("o"));
}

test "marker: a file that cannot be written is status 1 with the reason, though the test passed, and no temporary file is left" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectFailure(try c.runTool(&.{ "marker", "--out", "no-such-dir/o" }, &.{"true"}), 1, "check marker: cannot write no-such-dir/o: temporary file: FileNotFound");
    // a directory where the file goes: the rename fails after the write
    try c.tmp.dir.makePath("d");
    try kit.expectFailure(try c.runTool(&.{ "marker", "--out", "d" }, &.{"true"}), 1, "cannot write d: rename");
    var seen: usize = 0;
    var it = c.tmp.dir.iterate();
    while (try it.next()) |entry| {
        seen += 1;
        try t.expectEqualStrings("d", entry.name);
    }
    try t.expectEqual(@as(usize, 1), seen);
}

// ---- expect -----------------------------------------------------------------------------------------------------

fn expectCmd(c: *kit.Case, extra: kit.Args, program: kit.Args) !kit.Result {
    var all = std.ArrayList([]const u8).empty;
    try all.appendSlice(c.alloc(), &.{ "expect", "--out", "o" });
    try all.appendSlice(c.alloc(), extra);
    return c.runTool(all.items, program);
}

test "expect: the output equal to the text writes the file (what was printed, and a newline) and exits 0" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try expectCmd(&c, &.{ "--want", "hi there" }, &.{ "echo", "hi", "there" }), 0, "", "");
    try t.expectEqualStrings("hi there\n", try c.read("o"));
}

test "expect: only the trailing newlines are dropped before the comparison" {
    var c = try kit.Case.init();
    defer c.deinit();
    // the program prints "a\n\n\n" (echo adds one to the two in the text)
    try kit.expectResult(try expectCmd(&c, &.{ "--want", "a" }, &.{ "echo", "-e", "a\\n\\n" }), 0, "", "");
    try t.expectEqualStrings("a\n", try c.read("o"));
    // an inner newline stays, and so does a leading one
    try kit.expectResult(try expectCmd(&c, &.{ "--want", "a\nb" }, &.{ "echo", "-e", "a\\nb" }), 0, "", "");
    try t.expectEqualStrings("a\nb\n", try c.read("o"));
    try kit.expectFailure(try expectCmd(&c, &.{ "--want", "a" }, &.{ "echo", "-e", "\\na" }), 1, "printed '\na'");
    // nothing printed is the empty text
    try kit.expectResult(try expectCmd(&c, &.{ "--want", "" }, &.{"true"}), 0, "", "");
    try t.expectEqualStrings("\n", try c.read("o"));
}

test "expect: another output is exit 1 with both texts in the message, and the file is not written, nor an earlier one changed" {
    var c = try kit.Case.init();
    defer c.deinit();
    const msg = try std.fmt.allocPrint(c.alloc(), "check expect: expected output equal to 'hx' but {s} printed 'hi'\n", .{c.toolbox});
    try kit.expectResult(try expectCmd(&c, &.{ "--want", "hx" }, &.{ "echo", "hi" }), 1, "", msg);
    try t.expect(!c.exists("o"));
    try c.put("o", "earlier");
    try kit.expectResult(try expectCmd(&c, &.{ "--want", "hx" }, &.{ "echo", "hi" }), 1, "", msg);
    try t.expectEqualStrings("earlier", try c.read("o"));
    // equal means equal: what the program printed has more after the text
    try kit.expectFailure(try expectCmd(&c, &.{ "--want", "hi" }, &.{ "echo", "hi there" }), 1, "equal to 'hi' but");
    try kit.expectFailure(try expectCmd(&c, &.{ "--want", "x" }, &.{"true"}), 1, "printed ''");
    try kit.expectFailure(try expectCmd(&c, &.{ "--want", "" }, &.{ "echo", "x" }), 1, "equal to '' but");
}

test "expect --prefix: the output may go on after the text; the text may be all of it or nothing" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try expectCmd(&c, &.{ "--want", "rustc 1.95.0 (", "--prefix" }, &.{ "echo", "rustc 1.95.0 (abc 2026-10-01)" }), 0, "", "");
    try t.expectEqualStrings("rustc 1.95.0 (abc 2026-10-01)\n", try c.read("o"));
    try kit.expectResult(try expectCmd(&c, &.{ "--want", "same", "--prefix" }, &.{ "echo", "same" }), 0, "", "");
    try kit.expectResult(try expectCmd(&c, &.{ "--want", "", "--prefix" }, &.{ "echo", "anything" }), 0, "", "");
    // not a prefix: the text is longer, or elsewhere in the output
    const msg = try std.fmt.allocPrint(c.alloc(), "check expect: expected output starting with 'hello' but {s} printed 'hi'\n", .{c.toolbox});
    try kit.expectResult(try expectCmd(&c, &.{ "--want", "hello", "--prefix" }, &.{ "echo", "hi" }), 1, "", msg);
    try kit.expectFailure(try expectCmd(&c, &.{ "--want", "there", "--prefix" }, &.{ "echo", "hi there" }), 1, "starting with 'there'");
}

test "expect: a program that exits non-zero fails the check whatever it printed, and its stderr is passed on" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("f", "right text");
    c.tmp.dir.deleteFile("o") catch {};
    // `cat f missing` prints f, fails with a message on stderr
    const r = try expectCmd(&c, &.{ "--want", "right text" }, &.{ "cat", "f", "missing" });
    try t.expectEqual(@as(u8, 1), r.status);
    try t.expectEqualStrings("", r.out);
    const want_err = try std.fmt.allocPrint(c.alloc(), "cat: missing: No such file or directory\ncheck expect: {s} exited with status 1\n", .{c.toolbox});
    try t.expectEqualStrings(want_err, r.err);
    try t.expect(!c.exists("o"));
    // one that cannot be started
    const r2 = try c.run(&.{ "expect", "--out", "o", "--want", "", "--", "/no/such/program" });
    try kit.expectFailure(r2, 1, "check expect: cannot run /no/such/program: FileNotFound\ncheck expect: /no/such/program exited with status 127\n");
}

test "expect --name: the messages begin with it" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectFailure(try expectCmd(&c, &.{ "--want", "x", "--name", "c_check" }, &.{ "echo", "y" }), 1, "c_check: expected output equal to 'x'");
    try kit.expectFailure(try expectCmd(&c, &.{ "--want", "x", "--name", "c_check" }, &.{"false"}), 1, "c_check: ");
}

test "expect: the options that say how the program starts apply to it" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.environ = &.{ "FROM_PROCESS=p", "SHARED=process" };
    try kit.expectResult(try expectCmd(&c, &.{ "--want", "p" }, &.{ "printenv", "FROM_PROCESS" }), 0, "", "");
    try kit.expectResult(try expectCmd(&c, &.{ "--want", "set", "--env", "SHARED=set" }, &.{ "printenv", "SHARED" }), 0, "", "");
    // cleared: the variable is not there, so the program fails
    try kit.expectFailure(try expectCmd(&c, &.{ "--want", "p", "--clear-env" }, &.{ "printenv", "FROM_PROCESS" }), 1, "exited with status 1");
}

test "expect: --want and --out are required, and the options of another command are refused" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try c.runTool(&.{ "expect", "--out", "o" }, &.{"true"}), 2, "", "check expect: --want is required\n");
    try kit.expectResult(try c.runTool(&.{ "expect", "--want", "x" }, &.{"true"}), 2, "", "check expect: --out is required\n");
    try kit.expectResult(try c.runTool(&.{ "expect", "--want", "x", "--out", "o", "--stamp", "s" }, &.{"true"}), 2, "", "check expect: --stamp is not an option of this command\n");
}

test "expect: a file that cannot be written is status 1 with the reason, though the output was right" {
    var c = try kit.Case.init();
    defer c.deinit();
    const r = try c.runTool(&.{ "expect", "--want", "x", "--out", "no-such-dir/o" }, &.{ "echo", "x" });
    try kit.expectFailure(r, 1, "check expect: cannot write no-such-dir/o: temporary file: FileNotFound");
}
