//! Unit tests of mojo_gate.zig: a function is platform-gated when it has a use and every use is dropped (in an arm no report records, or in a gated
//! function). Each case that gates has the near-miss that must not: a live use, no use, an arm with a record, a cycle, a use that is no use.
const std = @import("std");
const G = @import("mojo_gate.zig");
const C = @import("mojo_calls.zig");
const M = @import("mojo_src.zig");
const t = std.testing;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

const File = struct { path: []const u8, text: []const u8, recorded: []const usize };

/// The gate flags of `cands` over `files` (their texts and the lines a report records in each).
fn flags(a: std.mem.Allocator, files: []const File, cands: []const G.Cand) ![]bool {
    var texts = std.ArrayList(C.Source).empty;
    var recorded: G.Recorded = .empty;
    for (files) |f| {
        try texts.append(a, .{ .path = f.path, .text = f.text });
        var set: M.LineSet = .empty;
        for (f.recorded) |ln| try set.put(a, ln, {});
        try recorded.put(a, f.path, set);
    }
    return G.platformGated(a, texts.items, &recorded, cands);
}

fn cand(name: []const u8, line: usize) G.Cand {
    return .{ .path = "a.mojo", .name = name, .line = line, .lines = 2 };
}

const two_arms =
    \\def driver(x: Int) -> Int:
    \\    comptime if A:
    \\        return helper(x)
    \\    comptime else:
    \\        return 0
    \\    return 1
    \\
    \\def helper(x: Int) -> Int:
    \\    return x
;

test "a function whose only use is in an arm no report records is gated; in the arm that was compiled it is live" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // The `else` arm (line 5) ran; the `if` arm (line 3) has no record.
    try t.expectEqualSlices(bool, &.{true}, try flags(a, &.{.{ .path = "a.mojo", .text = two_arms, .recorded = &.{ 1, 5, 6 } }}, &.{cand("helper", 8)}));
    // The `if` arm ran instead: the call is live.
    try t.expectEqualSlices(bool, &.{false}, try flags(a, &.{.{ .path = "a.mojo", .text = two_arms, .recorded = &.{ 1, 3, 6 } }}, &.{cand("helper", 8)}));
}

test "a function with no use is not gated, and neither is one used only by itself" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\def driver(x: Int) -> Int:
        \\    return x
        \\
        \\def orphan(x: Int) -> Int:
        \\    return x
        \\
        \\def self_only(x: Int) -> Int:
        \\    return self_only(x)
    ;
    const got = try flags(a, &.{.{ .path = "a.mojo", .text = src, .recorded = &.{ 1, 2 } }}, &.{ cand("orphan", 4), cand("self_only", 7) });
    try t.expectEqualSlices(bool, &.{ false, false }, got);
}

test "a recursive function whose every outside use is dropped is gated" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\def driver(x: Int) -> Int:
        \\    comptime if A:
        \\        return rec(x)
        \\    return 0
        \\
        \\def rec(x: Int) -> Int:
        \\    return rec(x - 1)
    ;
    try t.expectEqualSlices(bool, &.{true}, try flags(a, &.{.{ .path = "a.mojo", .text = src, .recorded = &.{ 1, 4 } }}, &.{cand("rec", 6)}));
}

test "a chain of gated functions is gated, whatever order the candidates come in" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\def driver(x: Int) -> Int:
        \\    comptime if A:
        \\        return top(x)
        \\    return 0
        \\
        \\def top(x: Int) -> Int:
        \\    return middle(x)
        \\
        \\def middle(x: Int) -> Int:
        \\    return leaf(x)
        \\
        \\def leaf(x: Int) -> Int:
        \\    return x
    ;
    const file = File{ .path = "a.mojo", .text = src, .recorded = &.{ 1, 4 } };
    try t.expectEqualSlices(bool, &.{ true, true, true }, try flags(a, &.{file}, &.{ cand("top", 6), cand("middle", 9), cand("leaf", 12) }));
    // The deepest first: each only becomes gated on a pass after the one above it, so it takes the fixpoint's further passes.
    try t.expectEqualSlices(bool, &.{ true, true, true }, try flags(a, &.{file}, &.{ cand("leaf", 12), cand("middle", 9), cand("top", 6) }));
}

test "a chain with one live use anywhere is counted from there down" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\def driver(x: Int) -> Int:
        \\    comptime if A:
        \\        return top(x)
        \\    return middle(x)
        \\
        \\def top(x: Int) -> Int:
        \\    return middle(x)
        \\
        \\def middle(x: Int) -> Int:
        \\    return leaf(x)
        \\
        \\def leaf(x: Int) -> Int:
        \\    return x
    ;
    // `top` is used only in the dropped arm; `middle` is used live by `driver` as well, so it is counted, and `leaf` is used by a function that is.
    const got = try flags(a, &.{.{ .path = "a.mojo", .text = src, .recorded = &.{ 1, 4 } }}, &.{ cand("top", 6), cand("middle", 9), cand("leaf", 12) });
    try t.expectEqualSlices(bool, &.{ true, false, false }, got);
}

test "functions that call only each other are not gated even from a dropped arm" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\def driver(x: Int) -> Int:
        \\    comptime if A:
        \\        return ping(x)
        \\    return 0
        \\
        \\def ping(x: Int) -> Int:
        \\    return pong(x)
        \\
        \\def pong(x: Int) -> Int:
        \\    return ping(x)
    ;
    const got = try flags(a, &.{.{ .path = "a.mojo", .text = src, .recorded = &.{ 1, 4 } }}, &.{ cand("ping", 6), cand("pong", 9) });
    try t.expectEqualSlices(bool, &.{ false, false }, got);
}

test "a use that is no use: a comment, a string, an import line, the declaration, a number" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\from lib import helper
        \\def driver(x: Int) -> Int:
        \\    var s = "helper"  # helper
        \\    var n = 12 + 0x1F
        \\    comptime if A:
        \\        return helper(x)
        \\    return 0
        \\
        \\def helper(x: Int) -> Int:
        \\    return x
        \\
        \\def doc() -> String:
        \\    return """
        \\helper
        \\"""
    ;
    try t.expectEqualSlices(bool, &.{true}, try flags(a, &.{.{ .path = "a.mojo", .text = src, .recorded = &.{ 2, 3, 4, 7 } }}, &.{cand("helper", 9)}));
}

test "a use that is not a call keeps a function counted: a value, a qualified name, an alias" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\from lib import target as t
        \\def driver(x: Int) -> Int:
        \\    var cb = value
        \\    var q = mod.qual(x)
        \\    var r = t(x)
        \\    comptime if A:
        \\        return value(x) + qual(x) + target(x)
        \\    return 0
        \\
        \\def value(x: Int) -> Int:
        \\    return x
        \\
        \\def qual(x: Int) -> Int:
        \\    return x
        \\
        \\def target(x: Int) -> Int:
        \\    return x
    ;
    const file = File{ .path = "a.mojo", .text = src, .recorded = &.{ 2, 3, 4, 5, 8 } };
    try t.expectEqualSlices(bool, &.{ false, false, false }, try flags(a, &.{file}, &.{ cand("value", 10), cand("qual", 13), cand("target", 16) }));
    // The alias alone, used only in the dropped arm: gated through the name it stands for.
    const only =
        \\from lib import target as t
        \\def driver(x: Int) -> Int:
        \\    comptime if A:
        \\        return t(x)
        \\    return 0
        \\
        \\def target(x: Int) -> Int:
        \\    return x
    ;
    try t.expectEqualSlices(bool, &.{true}, try flags(a, &.{.{ .path = "a.mojo", .text = only, .recorded = &.{ 2, 5 } }}, &.{cand("target", 7)}));
}

test "a use outside every arm of a compiled function, or outside any function, is live" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\var table = helper(1)
        \\
        \\def driver(
        \\    x: Int,
        \\    y: Int = other(1),
        \\) -> Int:
        \\    comptime if A:
        \\        return helper(x) + other(x)
        \\    return 0
        \\
        \\def helper(x: Int) -> Int:
        \\    return x
        \\
        \\def other(x: Int) -> Int:
        \\    return x
    ;
    // Both are used in the dropped arm, but `helper` also at the top level (line 1) and `other` in the signature's second line (5).
    const got = try flags(a, &.{.{ .path = "a.mojo", .text = src, .recorded = &.{ 3, 9 } }}, &.{ cand("helper", 11), cand("other", 14) });
    try t.expectEqualSlices(bool, &.{ false, false }, got);
}

test "a use in a function no report shows compiled, and not gated, is live; in a compiled function's arm it is dropped" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\def never_run(x: Int) -> Int:
        \\    comptime if A:
        \\        return helper(x)
        \\    return 0
        \\
        \\def helper(x: Int) -> Int:
        \\    return x
    ;
    // `never_run` has no record: its arm is not known to be dropped, so the use stands.
    try t.expectEqualSlices(bool, &.{false}, try flags(a, &.{.{ .path = "a.mojo", .text = src, .recorded = &.{} }}, &.{cand("helper", 6)}));
    try t.expectEqualSlices(bool, &.{true}, try flags(a, &.{.{ .path = "a.mojo", .text = src, .recorded = &.{4} }}, &.{cand("helper", 6)}));
}

test "a use in the body of a @parameter statement is in an arm" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\def driver(x: Int) -> Int:
        \\    @parameter
        \\    if x > 0:
        \\        return helper(x)
        \\    return 0
        \\
        \\def helper(x: Int) -> Int:
        \\    return x
    ;
    try t.expectEqualSlices(bool, &.{true}, try flags(a, &.{.{ .path = "a.mojo", .text = src, .recorded = &.{ 1, 5 } }}, &.{cand("helper", 7)}));
    try t.expectEqualSlices(bool, &.{false}, try flags(a, &.{.{ .path = "a.mojo", .text = src, .recorded = &.{ 1, 4, 5 } }}, &.{cand("helper", 7)}));
}

test "a name the package declares twice, and a candidate whose file is not among the sources, are never gated" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const files = [_]File{
        .{ .path = "a.mojo", .text = two_arms, .recorded = &.{ 1, 5, 6 } },
        .{ .path = "b.mojo", .text = "def helper(x: Int) -> Int:\n    return x\n", .recorded = &.{1} },
    };
    try t.expectEqualSlices(bool, &.{false}, try flags(a, &files, &.{cand("helper", 8)}));
    const single = [_]File{.{ .path = "a.mojo", .text = two_arms, .recorded = &.{ 1, 5, 6 } }};
    const elsewhere = G.Cand{ .path = "c.mojo", .name = "helper", .line = 8, .lines = 2 };
    try t.expectEqualSlices(bool, &.{false}, try flags(a, &single, &.{elsewhere}));
}

test "a use in another file of the package counts, and a file with no recorded lines at all has no compiled function" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const lib = "def helper(x: Int) -> Int:\n    return x\n";
    const user = "def driver(x: Int) -> Int:\n    comptime if A:\n        return helper(x)\n    return 0\n";
    const cands = [_]G.Cand{.{ .path = "lib.mojo", .name = "helper", .line = 1, .lines = 2 }};
    // The use is in a dropped arm of a compiled function of the other file.
    try t.expectEqualSlices(bool, &.{true}, try flags(a, &.{ .{ .path = "lib.mojo", .text = lib, .recorded = &.{} }, .{ .path = "user.mojo", .text = user, .recorded = &.{ 1, 4 } } }, &cands));
    // Not compiled there: stands.
    try t.expectEqualSlices(bool, &.{false}, try flags(a, &.{ .{ .path = "lib.mojo", .text = lib, .recorded = &.{} }, .{ .path = "user.mojo", .text = user, .recorded = &.{} } }, &cands));
}
