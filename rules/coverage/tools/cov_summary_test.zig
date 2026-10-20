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
