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
        // alias declarations emit no code
        "alias A = Int\n",
        "comptime B: UInt8 = 255  # a byte\n",
        "comptime Vec[T: AnyType] = List[T]\n", // a parameter list
        "alias P[T: AnyType = Int, n: Int = 2] = SIMD[T, n]\n", // defaults inside the list are not the declaration's `=`
        "comptime M = Dict[\n    String,\n    Int,\n]\n", // the value over several lines inside brackets
        "comptime D = (1,\n    # a note\n    2,\n\n    3)\n",
        "comptime S = 1 + \\\n    2\n", // or after a backslash
        "comptime T = \"a;b#c\"\ncomptime U = 'it\\'s'\n", // `;` and `#` inside a string, an escaped quote
        "comptime E = 1 == 1\n",
        "\"\"\"The types.\"\"\"\n\nfrom .a import f\n\ncomptime X = f\n# end\n",
    }) |case| t.expect(S.hasNoStatements(case)) catch |e| {
        std.debug.print("refused, should be accepted: {s}\n", .{case});
        return e;
    };
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
        // an alias is not every `alias` or `comptime` line
        "alias A = 1\ndef f(): pass\n", // an alias followed by a function
        "comptime A = Dict[\n    String,\n    Int,\n]\ndef f() -> Int:\n    return 1\n",
        "alias A = 1\nfn f(): pass\n",
        "alias A = 1\nstruct S:\n    pass\n",
        "alias A = 1\ntrait T:\n    def f(self) -> Int:\n        return 1\n",
        "alias A = 1\n@always_inline\n",
        "var A = 1\n",
        "alias A = 1\nvar B = 2\n",
        "alias A\n", // no value
        "comptime A: Int\n",
        "comptime Vec[T: AnyType = Int]\n", // an `=` only inside the parameter list
        "comptime A == 1\n",
        "comptime assert A == 1\n",
        "comptime assert A == 1, \"message\"\n",
        "comptime if X:\n    pass\n",
        "comptime if X == 1:\n    alias A = 1\n",
        "comptime for i in range(3):\n    pass\n",
        "comptime (1)\n",
        "comptime = 1\n",
        "aliasing = 3\n",
        "alias A = 1; pass\n", // `;` after a declaration
        "alias A = (1,\n    2); pass\n",
        "alias A = 1\n  x = 2\n", // an indented line outside a continuation
        "alias A = 1\n    alias B = 2\n",
        "alias A = Dict[\n    String,\n", // unclosed
        "alias A = (1,\n",
        "alias A = 1 \\\n", // a backslash with nothing after it
        "alias A = 1 \\\n\ndef f(): pass\n",
        "alias A = 1 \\ x\n",
        "alias A = ]\n",
        "alias A = \"open\n", // a string that does not end on its line
        "alias A = \"\"\"doc\"\"\"\n",
        "alias A = 1\r\n\rx\n", // a lone carriage return
        "alias A = 1\x0c\n",
        "alias A = (1,\n\x0b2)\n",
        "\"\"\"a\"\"\" # k\x0cx = 1\n", // after a one-line docstring, in a comment
        "\"\"\"a\nb\"\"\" # k\x0bx = 1\n", // after a block docstring closes, in a comment
    }) |case| t.expect(!S.hasNoStatements(case)) catch |e| {
        std.debug.print("accepted, should be refused: {s}\n", .{case});
        return e;
    };
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

fn readAliasOnly(_: std.mem.Allocator, p: []const u8) []const u8 {
    if (std.mem.eql(u8, p, "alias")) return "\"\"\"doc\"\"\"\nfrom .a import A\ncomptime Count = Int\ncomptime Ints = List[\n    Count\n]\n";
    return "comptime Count = Int\ndef f():\n    pass\n";
}

test "withEmptySources: a package of alias-only files is listed 0/0 and a file with code and no coverage stays missing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    const rows = try S.summarize(a, &files);
    const only = [_][]const u8{ "p/src/aliases.mojo", "p/src/types.mojo" };
    const srcs = [_][2][]const u8{ .{ "p/src/aliases.mojo", "alias" }, .{ "p/src/types.mojo", "alias" } };
    const out = try S.withEmptySources(a, rows, &only, &srcs, readAliasOnly);
    try t.expect(S.missing(out, &only) == null);
    try t.expectEqualStrings("p/src/aliases.mojo 0/0 0%\np/src/types.mojo 0/0 0%\ntotal 0/0 0%\n", try S.render(a, out, &only));
    // an alias beside a function is code: with no coverage the file is reported missing
    const mixed = [_][]const u8{ "p/src/aliases.mojo", "p/src/code.mojo" };
    const msrcs = [_][2][]const u8{ .{ "p/src/aliases.mojo", "alias" }, .{ "p/src/code.mojo", "code" } };
    const out2 = try S.withEmptySources(a, rows, &mixed, &msrcs, readAliasOnly);
    try t.expectEqualStrings("p/src/code.mojo", S.missing(out2, &mixed).?);
}

test "hasNoStatements: a trait declaration with signatures and empty default bodies has none" {
    for ([_][]const u8{
        "trait T:\n    def f(self) -> Int: ...\n",
        "trait T: ...\n",
        "trait T:\n    pass\n",
        "trait T(Copyable, Movable):\n    \"\"\"Doc.\"\"\"\n    def f(self) -> Int: ...\n    def g(mut self):\n        pass\n",
        "# header\n\ntrait T:\n    \"\"\"One.\n\n    More.\n    \"\"\"\n    def f(self):\n        \"\"\"Default.\"\"\"\n        pass\n    def g(self): pass # empty\n",
        "trait T[n: Int]:\n    def f[\n        In: Movable, P: Movable\n    ](\n        self,\n        n: Int,\n        ref input: In,\n    ) raises:\n        ...\n",
        "trait A:\n    def a(self): ...\n\n# between\n\ntrait B(A):\n    @staticmethod\n    def b() -> Int: ...\n",
        "from .x import Y\ncomptime Z = Y\ntrait T:\n    def f(self): ...\n",
    }) |case| t.expect(S.hasNoStatements(case)) catch |e| {
        std.debug.print("refused, should be accepted: {s}\n", .{case});
        return e;
    };
    for ([_][]const u8{
        "trait T:\n    def f(self) -> Int:\n        return 1\n",
        "trait T:\n    def f(self) -> Int: return 1\n",
        "trait T:\n    def f(self):\n        pass\n        x = 1\n",
        "trait T:\n    def f(self): ...\n\ndef g():\n    pass\n",
        "trait T:\n    x = 1\n",
        "trait T:\n    comptime N: Int\n",
        "trait T: x = 1\n",
        "trait T\n",
        "trait :\n    pass\n",
        "trait T(\n    A,\n):\n    pass\n",
        "trait T:\n    def f(self,\n",
        "trait T:\n    def f(self)\n",
        "trait T:\n    def f(self) -> Int: ...; g()\n",
        "trait T:\n    @deco(1)\n    def f(self): ...\n",
        "trait T:\n    def f(self, s: String = \"a\"): ...\n",
        "trait T:\n    \"\"\"Doc.\"\"\" x = 1\n",
        "trait T:\n    def f(self): ...\n@always_inline\n",
    }) |case| t.expect(!S.hasNoStatements(case)) catch |e| {
        std.debug.print("accepted, should be refused: {s}\n", .{case});
        return e;
    };
}

fn readTraits(_: std.mem.Allocator, p: []const u8) []const u8 {
    if (std.mem.eql(u8, p, "only")) return "trait T(Copyable):\n    \"\"\"Doc.\"\"\"\n    def f(self) -> Int: ...\n    def g(mut self):\n        pass\n";
    if (std.mem.eql(u8, p, "body")) return "trait T:\n    def f(self) -> Int:\n        return 1\n";
    return "trait T:\n    def f(self) -> Int: ...\n\ndef g() -> Int:\n    return 1\n";
}

test "withEmptySources: a trait-only file is listed 0/0; a trait with a real default body, or beside a function, stays missing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    const rows = try S.summarize(a, &files);
    const only = [_][]const u8{"p/src/traits.mojo"};
    const osrcs = [_][2][]const u8{.{ "p/src/traits.mojo", "only" }};
    const out = try S.withEmptySources(a, rows, &only, &osrcs, readTraits);
    try t.expect(S.missing(out, &only) == null);
    try t.expectEqualStrings("p/src/traits.mojo 0/0 0%\ntotal 0/0 0%\n", try S.render(a, out, &only));
    const body = [_][]const u8{"p/src/body.mojo"};
    const bsrcs = [_][2][]const u8{.{ "p/src/body.mojo", "body" }};
    const out2 = try S.withEmptySources(a, rows, &body, &bsrcs, readTraits);
    try t.expectEqualStrings("p/src/body.mojo", S.missing(out2, &body).?);
    const mixed = [_][]const u8{ "p/src/traits.mojo", "p/src/mixed.mojo" };
    const msrcs = [_][2][]const u8{ .{ "p/src/traits.mojo", "only" }, .{ "p/src/mixed.mojo", "mixed" } };
    const out3 = try S.withEmptySources(a, rows, &mixed, &msrcs, readTraits);
    try t.expectEqualStrings("p/src/mixed.mojo", S.missing(out3, &mixed).?);
}

// ---- what no test compiled: the own lines and decision words of functions the reports lack ---------------------------------------------

const lib_src =
    \\def used(x: Int) -> Int:
    \\    return x
    \\
    \\def other(x: Int) -> Int:
    \\    if x > 0 and x < 3:
    \\        return 1
    \\    return 0
    \\
    \\def never(x: Int) -> Int:
    \\    return x
;
const gen_src =
    \\# @generated
    \\def g() -> Int:
    \\    return 1
;

fn readLib(_: std.mem.Allocator, p: []const u8) []const u8 {
    if (std.mem.eql(u8, p, "gen")) return gen_src;
    return lib_src;
}

const rep_used = "<class name=\"p/a.mojo\" filename=\"p/a.mojo\">\n<lines>\n<line number=\"1\" hits=\"1\"/>\n<line number=\"2\" hits=\"1\"/>\n</lines>\n</class>\n";
const rep_other = "<class name=\"p/a.mojo\" filename=\"p/a.mojo\">\n<lines>\n<line number=\"4\" hits=\"1\"/>\n<line number=\"5\" hits=\"1\"/>\n<line number=\"6\" hits=\"0\"/>\n<line number=\"7\" hits=\"1\"/>\n</lines>\n</class>\n";
const rep_gen = "<class name=\"p/g.mojo\" filename=\"p/g.mojo\">\n<lines>\n<line number=\"2\" hits=\"1\"/>\n<line number=\"3\" hits=\"0\"/>\n</lines>\n</class>\n";
const br_used = "SF:p/a.mojo\nend_of_record\n";
// The records the compiler gives `if x > 0 and x < 3:`: the `if`, the `and`, and the right operand of the `and` that the `if` tests.
const br_other = "SF:p/a.mojo\nBRDA:5,5:select:0/1,0,1\nBRDA:5,5:select:0/1,1,1\nBRDA:5,14:rhs:0/1,0,1\nBRDA:5,14:rhs:0/1,1,-\nBRDA:5,14:select:0/1,0,1\nBRDA:5,14:select:0/1,1,1\nend_of_record\n";

const Flow = struct { lines: []const u8, branches: []const u8, unc: S.Uncompiled, missing: ?[]const u8 };

/// cov_summary's main after the reading of its inputs, for report texts, branch record texts, the expected sources and their texts.
fn flow(a: std.mem.Allocator, reports: []const []const u8, brs: []const []const u8, expect: []const []const u8, srcs: []const [2][]const u8) !Flow {
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    for (reports) |r| try S.addReport(a, &files, r);
    const origins = try a.alloc([]const u8, brs.len);
    for (origins) |*o| o.* = "branches.info";
    var diag = branch_lcov.Diag{};
    const found = try S.countUncompiled(a, &files, origins, brs, expect, srcs, readLib, &diag);
    const rows = try S.withEmptySources(a, try S.summarize(a, &files), found.counted, srcs, readLib);
    const lines = try S.renderScoped(a, rows, found.counted, "", expect.len != 0);
    var branches: []const u8 = "";
    if (brs.len != 0) {
        const all_origins = try std.mem.concat(a, []const u8, &.{ origins, &.{"uncompiled"} });
        const all_texts = try std.mem.concat(a, []const u8, &.{ brs, &.{found.unc.branches} });
        branches = switch (try S.branchListingScoped(a, all_origins, all_texts, rows, found.counted, expect.len != 0)) {
            .text => |x| x,
            .refused => |m| m,
        };
    }
    return .{ .lines = lines, .branches = branches, .unc = found.unc, .missing = S.missing(rows, found.counted) };
}

const branch_lcov = @import("branch_lcov.zig");
const lib_srcs = [_][2][]const u8{.{ "p/a.mojo", "lib" }};
const lib_expect = [_][]const u8{"p/a.mojo"};

test "uncompiled: with every test the figure counts a function nobody calls as found and not hit" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try flow(a, &.{ rep_used, rep_other }, &.{ br_used, br_other }, &lib_expect, &lib_srcs);
    // 1, 2, 4 to 7 are recorded (5 hit); `never` (9, 10) is found and not hit.
    try t.expectEqualStrings("p/a.mojo 5/8 62%\ntotal 5/8 62%\n", f.lines);
    // The six arms of `other` are the records'; `never` holds no decision.
    try t.expectEqualStrings("branches p/a.mojo 5/6 83%\nbranches total 5/6 83%\n", f.branches);
    try t.expect(f.missing == null);
}

test "uncompiled: deleting a test keeps the denominator and takes the hits, lines and branches" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The test of `other` is gone: its function is no longer compiled. 8 lines were found before and are found now; 5 hit, now 2.
    const f = try flow(a, &.{rep_used}, &.{br_used}, &lib_expect, &lib_srcs);
    try t.expectEqualStrings("p/a.mojo 2/8 25%\ntotal 2/8 25%\n", f.lines);
    // The `if`, the `and` and its right operand of `other` are three decisions of two arms, none taken: the 6 arms there were are 6 arms now.
    try t.expectEqualStrings("branches p/a.mojo 0/6 0%\nbranches total 0/6 0%\n", f.branches);
}

test "uncompiled: a branch record on a line of a function makes it compiled, whatever the line reports say" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `other` is inlined: no line record of its own, branch records at its decisions. Its lines are not counted twice nor as uncompiled.
    const f = try flow(a, &.{rep_used}, &.{br_other}, &lib_expect, &lib_srcs);
    try t.expectEqualStrings("p/a.mojo 2/4 50%\ntotal 2/4 50%\n", f.lines);
    try t.expectEqualStrings("branches p/a.mojo 5/6 83%\nbranches total 5/6 83%\n", f.branches);
}

test "uncompiled: without branch records only the lines are added" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try flow(a, &.{rep_used}, &.{}, &lib_expect, &lib_srcs);
    try t.expectEqualStrings("p/a.mojo 2/8 25%\ntotal 2/8 25%\n", f.lines);
    try t.expectEqualStrings("", f.branches);
    try t.expectEqual(@as(usize, 0), f.unc.branches.len);
}

test "uncompiled: the lines are also a Cobertura report, so the reports plus it count what the summary counted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try flow(a, &.{rep_used}, &.{br_used}, &lib_expect, &lib_srcs);
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    try S.addReport(a, &files, rep_used);
    try S.addReport(a, &files, f.unc.cobertura);
    try t.expectEqualStrings("p/a.mojo 2/8 25%\ntotal 2/8 25%\n", try S.render(a, try S.summarize(a, &files), &lib_expect));
    // The branch records are a file the branch reader takes: the six arms, each as never reached.
    var sum = branch_lcov.Sum{};
    var diag = branch_lcov.Diag{};
    try sum.add(a, &diag, f.unc.branches, "uncompiled");
    const counts = try sum.counts(a);
    try t.expectEqual(@as(usize, 1), counts.len);
    try t.expectEqual(@as(usize, 6), counts[0].total);
    try t.expectEqual(@as(usize, 0), counts[0].hit);
}

test "uncompiled: a path that needs escaping is written escaped, and a source no report names is left alone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    try S.addReport(a, &files, "<class name=\"p/a&b.mojo\" filename=\"p/a&b.mojo\">\n<line number=\"1\" hits=\"1\"/>\n</class>\n");
    const srcs = [_][2][]const u8{ .{ "p/a&b.mojo", "lib" }, .{ "p/b.mojo", "lib" } };
    const blines: S.BranchLines = .empty;
    const unc = try S.addUncompiled(a, &files, &blines, false, &.{ "p/a&b.mojo", "p/b.mojo" }, &srcs, readLib);
    try t.expect(std.mem.indexOf(u8, unc.cobertura, "filename=\"p/a&amp;b.mojo\"") != null);
    // every character XML reserves, and a source with no entry in `srcs` (nothing to read: left alone)
    const odd = [_][2][]const u8{.{ "p/<\"'>&.mojo", "lib" }};
    var files2: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    const put = try files2.getOrPut(a, "p/<\"'>&.mojo");
    put.value_ptr.* = .empty;
    try put.value_ptr.put(a, 1, true);
    const unc2 = try S.addUncompiled(a, &files2, &blines, false, &.{ "p/<\"'>&.mojo", "q" }, &odd, readLib);
    try t.expect(std.mem.indexOf(u8, unc2.cobertura, "filename=\"p/&lt;&quot;&apos;&gt;&amp;.mojo\"") != null);
    try t.expect(std.mem.indexOf(u8, unc.cobertura, "p/b.mojo") == null);
    try t.expect(!files.contains("p/b.mojo"));
    // `used` is recorded by line 1; `other` and `never` are the uncompiled lines 4 to 7, 9, 10.
    try t.expectEqual(@as(usize, 7), files.get("p/a&b.mojo").?.count());
}

test "generated: a source marked @generated is neither required in a report nor counted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const srcs = [_][2][]const u8{ .{ "p/a.mojo", "lib" }, .{ "p/g.mojo", "gen" } };
    const expect = [_][]const u8{ "p/a.mojo", "p/g.mojo" };
    // No report names the generated source: nothing is missing, and its lines are not in the figure.
    const none = try flow(a, &.{rep_used}, &.{}, &expect, &srcs);
    try t.expect(none.missing == null);
    try t.expectEqualStrings("p/a.mojo 2/8 25%\ntotal 2/8 25%\n", none.lines);
    // A report that names it lists it and leaves it out of the total, with its uncompiled functions.
    const named = try flow(a, &.{ rep_used, rep_gen }, &.{}, &expect, &srcs);
    try t.expectEqualStrings("p/a.mojo 2/8 25%\np/g.mojo 1/2 50% (not counted)\ntotal 2/8 25%\n", named.lines);
    // A source not marked is still refused when no report names it.
    const plain = [_][2][]const u8{ .{ "p/a.mojo", "lib" }, .{ "p/g.mojo", "lib" } };
    try t.expectEqualStrings("p/g.mojo", (try flow(a, &.{rep_used}, &.{}, &expect, &plain)).missing.?);
}

test "generated: a package whose sources are all generated counts nothing, whatever its reports name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const srcs = [_][2][]const u8{.{ "p/g.mojo", "gen" }};
    const f = try flow(a, &.{rep_gen}, &.{br_used}, &.{"p/g.mojo"}, &srcs);
    try t.expectEqualStrings("p/g.mojo 1/2 50% (not counted)\ntotal 0/0 0%\n", f.lines);
    try t.expect(std.mem.endsWith(u8, f.branches, "branches total 0/0 0%\n"));
}

test "countUncompiled: a branch record file that cannot be used is refused with its reason" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    var diag = branch_lcov.Diag{};
    try t.expectError(error.Refused, S.countUncompiled(a, &files, &.{"bad.info"}, &.{"BRDA:1\n"}, &lib_expect, &lib_srcs, readLib, &diag));
    try t.expect(std.mem.startsWith(u8, diag.msg, "bad.info:1:"));
}
