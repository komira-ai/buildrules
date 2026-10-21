//! The two guards for text from a pull request: one-line printing and the nesting bound.

const std = @import("std");
const safe = @import("autopin_safe.zig");
const t = std.testing;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

test "oneLine: every byte outside printable ASCII becomes a question mark" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("a?::b?c?d", try safe.oneLine(a, "a\n::b\rc\x7fd"));
    try t.expectEqualStrings("e?f??g", try safe.oneLine(a, "e\x1bf\xc3\xa9g"));
    try t.expectEqualStrings("plain/path@1.0.0 ~", try safe.oneLine(a, "plain/path@1.0.0 ~"));
    try t.expectEqualStrings("", try safe.oneLine(a, ""));
}

test "oneLine: a long string is cut at the bound and says so" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const exact = "x" ** safe.max_line;
    try t.expectEqualStrings(exact, try safe.oneLine(a, exact));
    const over = try safe.oneLine(a, exact ++ "y");
    try t.expectEqual(safe.max_line + 3, over.len);
    try t.expectEqualStrings("...", over[safe.max_line..]);
}

test "jsonDepthOk: 32 levels are fine and 33 are not" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var ok = std.ArrayList(u8).empty;
    try ok.appendNTimes(a, '[', safe.max_json_depth);
    try ok.appendNTimes(a, ']', safe.max_json_depth);
    try t.expect(safe.jsonDepthOk(ok.items));
    var deep = std.ArrayList(u8).empty;
    try deep.appendNTimes(a, '{', safe.max_json_depth + 1);
    try t.expect(!safe.jsonDepthOk(deep.items));
}

test "jsonDepthOk: brackets inside a string do not count" {
    try t.expect(safe.jsonDepthOk("{\"a\":\"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[\"}"));
}

test "jsonDepthOk: an escaped quote does not end the string" {
    try t.expect(safe.jsonDepthOk("{\"a\":\"\\\"[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[\"}"));
}

test "jsonDepthOk: a closing bracket lowers the depth, and an unmatched one does not underflow" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expect(safe.jsonDepthOk("]]]]][[["));
    var after_close = std.ArrayList(u8).empty;
    try after_close.appendNTimes(a, '[', safe.max_json_depth);
    try after_close.appendNTimes(a, ']', safe.max_json_depth);
    try after_close.appendNTimes(a, '[', safe.max_json_depth);
    try t.expect(safe.jsonDepthOk(after_close.items));
}
