//! Unit tests of cov_summary.zig: hits fold across reports, a file nobody compiled is refused, the text is fixed.
const std = @import("std");
const S = @import("cov_summary.zig");
const t = std.testing;

const report_a =
    \\<?xml version="1.0" ?>
    \\<coverage timestamp="0">
    \\    <packages>
    \\        <package name="">
    \\            <classes>
    \\                <class name="p/src/a.mojo" filename="p/src/a.mojo">
    \\                    <lines>
    \\                        <line number="3" hits="1"/>
    \\                        <line number="4" hits="0"/>
    \\                        <line number="5" hits="0"/>
    \\                    </lines>
    \\                </class>
    \\                <class name="p/tests/test_a.mojo" filename="p/tests/test_a.mojo">
    \\                    <lines>
    \\                        <line number="1" hits="1"/>
    \\                    </lines>
    \\                </class>
    \\            </classes>
    \\        </package>
    \\    </packages>
    \\</coverage>
    \\
;

const report_b =
    \\<class name="p/src/a.mojo" filename="p/src/a.mojo">
    \\<lines>
    \\<line number="4" hits="1"/>
    \\<line number="5" hits="0"/>
    \\</lines>
    \\</class>
    \\
;

test "a line is hit when any report hit it, and the files are listed sorted with the total" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    try S.addReport(a, &files, report_a);
    try S.addReport(a, &files, report_b);
    const rows = try S.summarize(a, &files);
    try t.expectEqual(@as(usize, 2), rows.len);
    try t.expectEqualStrings("p/src/a.mojo", rows[0].path);
    try t.expectEqual(@as(usize, 2), rows[0].hit);
    try t.expectEqual(@as(usize, 3), rows[0].total);
    try t.expectEqualStrings("p/src/a.mojo 2/3 66%\np/tests/test_a.mojo 1/1 100%\ntotal 3/4 75%\n", try S.render(a, rows, &.{}));
    // With the package's own sources named, the test's lines are listed and not counted.
    try t.expectEqualStrings("p/src/a.mojo 2/3 66%\np/tests/test_a.mojo 1/1 100% (not counted)\ntotal 2/3 66%\n", try S.render(a, rows, &.{"p/src/a.mojo"}));
}

test "one report alone leaves the unhit lines unhit" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    try S.addReport(a, &files, report_a);
    const rows = try S.summarize(a, &files);
    try t.expectEqual(@as(usize, 1), rows[0].hit);
}

test "expect: a source no report names is found by name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    try S.addReport(a, &files, report_a);
    const rows = try S.summarize(a, &files);
    try t.expect(S.missing(rows, &.{"p/src/a.mojo"}) == null);
    try t.expectEqualStrings("p/src/b.mojo", S.missing(rows, &.{ "p/src/a.mojo", "p/src/b.mojo" }).?);
}

test "a line outside a class and a malformed line are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    try t.expectError(error.BadReport, S.addReport(a, &files, "<line number=\"1\" hits=\"1\"/>\n"));
    try t.expectError(error.BadReport, S.addReport(a, &files, "<class name=\"x\" filename=\"x\">\n<line number=\"x\" hits=\"1\"/>\n"));
}

const blocks_a = "# blocks v2\np/src/a.zig\t3\t1\t1\t1\np/src/a.zig\t4\t5\t0\t2\np/src/a.zig\t4\t9\t0\t1\np/tests/a_test.zig\t1\t1\t1\t1\n";
const blocks_b = "# blocks v2\np/src/a.zig\t4\t5\t1\t2\np/src/a.zig\t4\t9\t0\t1\n";

test "blocks: the blocks of a position that ran are the most any report hit; the listing follows the lines' and counts the expected files only" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(S.BlockPositions) = .empty;
    try S.addBlocks(a, &files, blocks_a);
    try S.addBlocks(a, &files, blocks_b);
    const rows = try S.summarizeBlocks(a, &files);
    try t.expectEqual(@as(usize, 2), rows.len);
    // a.zig: position 3:1 ran (1/1), 4:5 ran one of its two blocks in the second report (1/2), 4:9 never (0/1).
    try t.expectEqual(@as(usize, 2), rows[0].hit);
    try t.expectEqual(@as(usize, 4), rows[0].total);
    try t.expectEqualStrings(
        "branches p/src/a.zig 2/4 50%\nbranches p/tests/a_test.zig 1/1 100% (not counted)\nbranches total 2/4 50%\n",
        try S.renderWith(a, rows, &.{"p/src/a.zig"}, "branches "),
    );
    try t.expect(S.missing(rows, &.{ "p/src/a.zig", "p/src/b.zig" }) != null);
}

test "blocks: two blocks at one position are two blocks, and the same position in two reports is not summed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(S.BlockPositions) = .empty;
    try S.addBlocks(a, &files, "# blocks v2\np/a.zig\t5\t5\t1\t2\n");
    try S.addBlocks(a, &files, "# blocks v2\np/a.zig\t5\t5\t1\t2\n");
    const rows = try S.summarizeBlocks(a, &files);
    try t.expectEqual(@as(usize, 1), rows[0].hit);
    try t.expectEqual(@as(usize, 2), rows[0].total);
}

test "blocks: a report that is not zig_cover's is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(S.BlockPositions) = .empty;
    for ([_][]const u8{
        "",
        "p/a.zig\t1\t1\t1\t1\n",
        "# blocks v1\np/a.zig\t1\t1\t1\n", // the old format
        "# blocks v2\np/a.zig\t1\t1\t1\n",
        "# blocks v2\np/a.zig\t1\t1\t2\t1\n", // more ran than there are
        "# blocks v2\np/a.zig\t1\t1\t0\t0\n", // a position with no block
        "# blocks v2\np/a.zig\tx\t1\t1\t1\n",
        "# blocks v2\np/a.zig\t1\t1\t1\t1\tz\n",
    }) |text| {
        try t.expectError(error.BadReport, S.addBlocks(a, &files, text));
    }
}

fn readFake(_: std.mem.Allocator, p: []const u8) []const u8 {
    if (std.mem.eql(u8, p, "init")) return "\"\"\"The package.\"\"\"\n\nfrom .a import f\n";
    return "fn f():\n    pass\n";
}

test "hasNoStatements: a re-export file has none, any other statement is one" {
    // accepted: empty, comments, one-line and block docstrings, plain, aliased, parenthesised and continued imports, a trailing comment
    for ([_][]const u8{
        "",
        "\n\n",
        "# only a comment\n",
        "\"\"\"doc\"\"\"\nfrom .a import f\n",
        "\"\"\"doc\n   with from x import y: inside\n   more\n\"\"\" # tail\nimport os\n",
        "'''doc'''\n",
        "from .a import f, g as h # re-export\nimport .b\n",
        "from .a import (\n    f,\n    g,  # why\n)\n",
        "from .a import f, \\\n    g\n",
        "from .a import (f, g)\r\n",
        "\"\"\"a\x0bb\"\"\"\nfrom .a import f\n", // a vertical tab inside a string is the string's
        "\"\"\"x\ny\x0cz\n\"\"\"\n", // a form feed inside a block docstring
    }) |case| try t.expect(S.hasNoStatements(case));
    // refused: a function, a struct, a decorator, a statement, a call, an indented line, a semicolon, an unclosed docstring or parenthesis
    for ([_][]const u8{
        "fn f():\n    pass\n",
        "from .a import f\nfn g(): pass\n",
        "struct S:\n    pass\n",
        "@always_inline\n",
        "x = 1\n",
        "from .a import f; g()\n",
        "from .a import f\n  g()\n",
        "from .a import (f,\n    g\n",
        "\"\"\"doc\nnever closed\n",
        "\"\"\"doc\"\"\" x = 1\n",
        "\"\"\"doc\nmore\"\"\" x = 1\n",
        "from .a import (\n    f(),\n)\n",
        "from .a import f \\\n    ; g()\n",
        "from .a import f)\n",
        "from .a\n",
        "importing()\n",
        "from a import b; pass\n", // a `;` alone: no call, no parenthesis to refuse it for another reason
        "from a import (b,\n c); pass\n", // and after a parenthesised list
        "# c\rx = 1\n", // a lone carriage return is a line break to some readers
        "from a import b\rx = 1\n",
        "from a import b\r", // ... also at the end of the text
        "from a import b\r\r\n",
        "# c\x0bx = 1\n", // a vertical tab or form feed outside a string likewise
        "# c\x0cx = 1\n",
        "from a import b\x0c\n",
        "\x0cfrom a import b\n",
        "\"\"\"doc\"\"\"\x0b\n",
        "\"\"\"\ndoc\n\"\"\"\x0c\n",
        "from a import (b,\n\x0bc)\n",
        "\"\"\"a\"\"\" # k\x0cx = 1\n", // after a one-line docstring, in a comment
        "\"\"\"a\nb\"\"\" # k\x0bx = 1\n", // after a block docstring closes, in a comment
    }) |case| try t.expect(!S.hasNoStatements(case));
}

test "withEmptySources: only a source with no statement is listed 0/0; the rest stays missing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    try S.addReport(a, &files, report_a);
    const rows = try S.summarize(a, &files);
    const expect = [_][]const u8{ "p/src/a.mojo", "p/src/__init__.mojo", "p/src/b.mojo" };
    const srcs = [_][2][]const u8{ .{ "p/src/__init__.mojo", "init" }, .{ "p/src/b.mojo", "b" } };
    const out = try S.withEmptySources(a, rows, &expect, &srcs, readFake);
    try t.expectEqual(@as(usize, 3), out.len);
    try t.expectEqualStrings("p/src/__init__.mojo", out[0].path);
    try t.expectEqual(@as(usize, 0), out[0].total);
    // b.mojo has a function and the report lacks it: still missing. A source with no --src entry is still missing.
    try t.expectEqualStrings("p/src/b.mojo", S.missing(out, &expect).?);
    try t.expectEqualStrings("p/src/__init__.mojo", S.missing(rows, &expect).?);
    const nosrc = try S.withEmptySources(a, rows, &expect, &.{}, readFake);
    try t.expectEqual(@as(usize, 2), nosrc.len);
    // listed and counted, as 0/0: the total does not move
    try t.expectEqualStrings("p/src/__init__.mojo 0/0 0%\np/src/a.mojo 1/3 33%\np/tests/test_a.mojo 1/1 100% (not counted)\ntotal 1/3 33%\n", try S.render(a, out, &.{ "p/src/a.mojo", "p/src/__init__.mojo" }));
}
