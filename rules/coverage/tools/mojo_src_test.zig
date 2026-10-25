//! Unit tests of mojo_src.zig: which lines of a Mojo source are executable, which functions it declares, and which of them and which decision
//! words are left once the lines the reports record are taken away.
const std = @import("std");
const M = @import("mojo_src.zig");
const t = std.testing;

const src_a =
    \\"""Docstring."""
    \\from std.testing import assert_equal
    \\from a import (
    \\    b,
    \\    c,
    \\)
    \\
    \\# a comment
    \\
    \\@always_inline
    \\def used(x: Int) -> Int:
    \\    """Doc
    \\    string."""
    \\    if x > 0 and x < 10:
    \\        return x
    \\    return 0
    \\
    \\def unused(x: Int) raises -> Int:
    \\    var s = String("if or and")  # for while
    \\    for i in range(x):
    \\        if i == 3 or i == 4:
    \\            raise Error("x")
    \\    return x
;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

fn set(a: std.mem.Allocator, lines: []const usize) !M.LineSet {
    var s: M.LineSet = .empty;
    for (lines) |l| try s.put(a, l, {});
    return s;
}

test "executable lines are the lines with code outside strings, comments and imports" {
    var ar = arena();
    defer ar.deinit();
    const got = try M.executableLines(ar.allocator(), src_a);
    try t.expectEqualSlices(usize, &.{ 10, 11, 14, 15, 16, 18, 19, 20, 21, 22, 23 }, got);
}

test "a function has its own lines from its def line to its last line, its decorator and docstring left out" {
    var ar = arena();
    defer ar.deinit();
    const fns = try M.declaredFunctions(ar.allocator(), src_a);
    try t.expectEqual(@as(usize, 2), fns.len);
    try t.expectEqualStrings("used", fns[0].name);
    try t.expectEqual(@as(usize, 11), fns[0].line);
    try t.expectEqual(@as(usize, 16), fns[0].end);
    try t.expectEqualSlices(usize, &.{ 11, 14, 15, 16 }, fns[0].lines);
    try t.expectEqualStrings("unused", fns[1].name);
    try t.expectEqualSlices(usize, &.{ 18, 19, 20, 21, 22, 23 }, fns[1].lines);
}

test "a function none of whose lines has a record is uncompiled: its lines and decision words count" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const rec = try set(a, &.{ 11, 14, 15, 16 });
    const u = try M.uncompiled(a, src_a, &rec);
    try t.expectEqualSlices(usize, &.{ 18, 19, 20, 21, 22, 23 }, u.lines);
    // The words in the string and the comment of line 19 are no decisions; `for` of line 20, `if` and `or` of line 21 are, and the `or` of an
    // `if` has its right operand counted as well.
    try t.expectEqual(@as(usize, 4), u.decisions.len);
    try t.expectEqual(M.Decision{ .line = 20, .col = 5 }, u.decisions[0]);
    try t.expectEqual(M.Decision{ .line = 21, .col = 9 }, u.decisions[1]);
    try t.expectEqual(M.Decision{ .line = 21, .col = 19 }, u.decisions[2]);
    try t.expectEqual(M.Decision{ .line = 21, .col = 19, .rhs = true }, u.decisions[3]);
}

test "an and / or outside the condition of an if, elif or while has no right operand of its own" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const text =
        \\def f(a: Bool, b: Bool) -> Bool:
        \\    var r = a and b
        \\    while a or b:
        \\        a = False
        \\    return a or b
    ;
    const rec: M.LineSet = .empty;
    const u = try M.uncompiled(a, text, &rec);
    try t.expectEqual(@as(usize, 5), u.decisions.len);
    try t.expectEqual(M.Decision{ .line = 2, .col = 15 }, u.decisions[0]);
    try t.expectEqual(M.Decision{ .line = 3, .col = 5 }, u.decisions[1]);
    try t.expectEqual(M.Decision{ .line = 3, .col = 13 }, u.decisions[2]);
    try t.expectEqual(M.Decision{ .line = 3, .col = 13, .rhs = true }, u.decisions[3]);
    // `return a or b` is the `or` alone.
    try t.expectEqual(M.Decision{ .line = 5, .col = 14 }, u.decisions[4]);
}

test "with no record at all every function is uncompiled, and the decisions come sorted" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const rec: M.LineSet = .empty;
    const u = try M.uncompiled(a, src_a, &rec);
    try t.expectEqual(@as(usize, 10), u.lines.len);
    try t.expectEqual(@as(usize, 11), u.lines[0]);
    try t.expectEqual(@as(usize, 7), u.decisions.len);
    try t.expectEqual(M.Decision{ .line = 14, .col = 5 }, u.decisions[0]);
    try t.expectEqual(M.Decision{ .line = 14, .col = 14 }, u.decisions[1]);
    try t.expectEqual(M.Decision{ .line = 14, .col = 14, .rhs = true }, u.decisions[2]);
}

test "one record on any own line makes the function compiled" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // Only the `return 0` of `used` and nothing of `unused`.
    const rec = try set(a, &.{16});
    const u = try M.uncompiled(a, src_a, &rec);
    try t.expectEqualSlices(usize, &.{ 18, 19, 20, 21, 22, 23 }, u.lines);
    // A record on the last line of `unused` makes both compiled.
    const both = try set(a, &.{ 16, 23 });
    try t.expectEqual(@as(usize, 0), (try M.uncompiled(a, src_a, &both)).lines.len);
}

const src_nested =
    \\def outer(x: Int) -> Int:
    \\    def inner(y: Int) -> Int:
    \\        return y + 1
    \\    return inner(x)
    \\
    \\struct S:
    \\    var v: Int
    \\
    \\    def get(self) -> Int:
    \\        return self.v
    \\
    \\    def one_line(self) -> Int: return 1
;

test "a nested function is a function of its own, its lines are not the outer one's" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const fns = try M.declaredFunctions(a, src_nested);
    try t.expectEqual(@as(usize, 4), fns.len);
    try t.expectEqualSlices(usize, &.{ 1, 4 }, fns[0].lines);
    try t.expectEqualSlices(usize, &.{ 2, 3 }, fns[1].lines);
    try t.expectEqualSlices(usize, &.{ 9, 10 }, fns[2].lines);
    try t.expectEqualSlices(usize, &.{12}, fns[3].lines);
    // The outer function is recorded by its own line, the closure is not recorded and is uncompiled.
    const rec = try set(a, &.{ 1, 4, 9, 10, 12 });
    const u = try M.uncompiled(a, src_nested, &rec);
    try t.expectEqualSlices(usize, &.{ 2, 3 }, u.lines);
    // A record inside the closure does not make the outer function compiled.
    const inner = try set(a, &.{ 2, 3, 9, 10, 12 });
    try t.expectEqualSlices(usize, &.{ 1, 4 }, (try M.uncompiled(a, src_nested, &inner)).lines);
}

const src_trait =
    \\trait Shape:
    \\    def area(self) -> Int: ...
    \\    def name(self) -> String:
    \\        ...
    \\    def describe(self) -> String:
    \\        return String("shape")
    \\
    \\def long_signature(
    \\    a: Int,
    \\    b: Int,
    \\) raises -> Int:
    \\    return a + b
;

test "a trait requirement is no function, a default method and a multi-line signature are" {
    var ar = arena();
    defer ar.deinit();
    const fns = try M.declaredFunctions(ar.allocator(), src_trait);
    try t.expectEqual(@as(usize, 2), fns.len);
    try t.expectEqualStrings("describe", fns[0].name);
    try t.expectEqualSlices(usize, &.{ 5, 6 }, fns[0].lines);
    try t.expectEqualStrings("long_signature", fns[1].name);
    try t.expectEqualSlices(usize, &.{ 8, 9, 10, 11, 12 }, fns[1].lines);
}

const src_compile_time =
    \\def pick[W: Int](x: Int) -> Int:
    \\    comptime if W > 4 and W < 9:
    \\        return 1
    \\    @parameter
    \\    if W == 2 or W == 3:
    \\        return 2
    \\    comptime for i in range(W):
    \\        pass
    \\    if x > 0:
    \\        return 3
    \\    return 0
;

test "decision words on a compile-time line are not decisions" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const rec: M.LineSet = .empty;
    const u = try M.uncompiled(a, src_compile_time, &rec);
    // Only the `if` of line 9; the lines themselves still count as found.
    try t.expectEqual(@as(usize, 1), u.decisions.len);
    try t.expectEqual(M.Decision{ .line = 9, .col = 5 }, u.decisions[0]);
    try t.expectEqual(@as(usize, 11), u.lines.len);
}

test "words that only contain a decision word are not decisions" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const text =
        \\def f(iffy: Int, order: Int, format: Int) -> Int:
        \\    var android = iffy + order
        \\    return android + format
    ;
    const rec: M.LineSet = .empty;
    const u = try M.uncompiled(a, text, &rec);
    try t.expectEqual(@as(usize, 3), u.lines.len);
    try t.expectEqual(@as(usize, 0), u.decisions.len);
}

test "strings: prefixes, triple quotes over lines, escapes and a continued string keep their words out of the code" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const text =
        \\def f() -> Int:
        \\    var a = r"if \" or"
        \\    var b = f"and {a}"
        \\    var c = """for
        \\    while if or
        \\    """
        \\    var d = "x \
        \\    if y"
        \\    return 1 if a else 2
    ;
    const rec: M.LineSet = .empty;
    const u = try M.uncompiled(a, text, &rec);
    // Lines 5, 6 and 8 are inside strings; line 7 and 9 hold code.
    try t.expectEqualSlices(usize, &.{ 1, 2, 3, 4, 7, 9 }, u.lines);
    try t.expectEqual(@as(usize, 1), u.decisions.len);
    try t.expectEqual(M.Decision{ .line = 9, .col = 14 }, u.decisions[0]);
}

test "imports are not executable, an import with a statement after a semicolon is" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const text =
        \\import a
        \\from b import c; var x = 1
        \\from d import e; import f
        \\from g import \
        \\    h
        \\var y = 2
        \\from h import i; import j; var z = 3
    ;
    try t.expectEqualSlices(usize, &.{ 2, 6, 7 }, try M.executableLines(a, text));
}

test "a colon or a quote inside a string in the signature does not end it or hide the body" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const text =
        \\def g(s: String = "a:\"b") -> String: return s
        \\def h(c: String = 'x:') -> String: return c
    ;
    const fns = try M.declaredFunctions(a, text);
    try t.expectEqual(@as(usize, 2), fns.len);
    try t.expectEqualSlices(usize, &.{1}, fns[0].lines);
    try t.expectEqualSlices(usize, &.{2}, fns[1].lines);
}

test "a carriage return, a byte-order mark and a missing final newline do not change the lines" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const lf = "def f() -> Int:\n    return 1\n";
    const crlf = "\xEF\xBB\xBFdef f() -> Int:\r\n    return 1\r\n";
    const bare = "def f() -> Int:\n    return 1";
    for ([_][]const u8{ lf, crlf, bare }) |text| {
        const fns = try M.declaredFunctions(a, text);
        try t.expectEqual(@as(usize, 1), fns.len);
        try t.expectEqualSlices(usize, &.{ 1, 2 }, fns[0].lines);
    }
    try t.expectEqual(@as(usize, 0), (try M.lexSource(a, "")).len);
}

test "a declaration with no body, or a docstring only, is no function; a one-line body is" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const text =
        \\def a()
        \\def b():
        \\    """only a docstring"""
        \\fn c() -> Int: return 3
        \\def d(x: Int) -> Dict[String, Int]: return {}
        \\def = 4
        \\define x
    ;
    const fns = try M.declaredFunctions(a, text);
    try t.expectEqual(@as(usize, 2), fns.len);
    try t.expectEqualStrings("c", fns[0].name);
    try t.expectEqualStrings("d", fns[1].name);
}

test "the first line marks a generated source" {
    try t.expect(M.isGenerated("# @generated by the protobuf compiler\ndef f(): pass\n"));
    try t.expect(M.isGenerated("\xEF\xBB\xBF  # DO NOT EDIT @generated\n"));
    try t.expect(!M.isGenerated("def f(): pass\n# @generated\n"));
    try t.expect(!M.isGenerated("var s = \"@generated\"\n"));
    try t.expect(!M.isGenerated("# generated\n"));
    try t.expect(!M.isGenerated(""));
}
