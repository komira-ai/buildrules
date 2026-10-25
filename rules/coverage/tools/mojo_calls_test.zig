//! Unit tests of mojo_calls.zig: which hit lines are calls, whom a call is evidence for, and which lines of the code no test compiled the evidence
//! leaves out. Every rule has the case that applies it and the near-miss that must not (inlined but uncalled counts; a call that cannot reach the
//! function counts; no caller counts).
const std = @import("std");
const C = @import("mojo_calls.zig");
const M = @import("mojo_src.zig");
const t = std.testing;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

fn hits(a: std.mem.Allocator, lines: []const usize) !M.LineSet {
    var s: M.LineSet = .empty;
    for (lines) |l| try s.put(a, l, {});
    return s;
}

fn keysOf(a: std.mem.Allocator, line: []const u8) !C.Keys {
    var k: C.Keys = .empty;
    try C.callKeys(a, line, &k);
    return k;
}

fn expectKeys(want: []const []const u8, got: C.Keys) !void {
    try t.expectEqual(want.len, got.count());
    for (want) |w| try t.expect(got.contains(w));
}

test "a call is an identifier followed by ( or [; a method call is .name and Receiver.name" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectKeys(
        &.{ "foo", ".bar", "a.bar", "T", ".baz", "T.baz", ".qux", "T.qux", "arr" },
        try keysOf(a, "    x = foo(1) + a.bar(2) + T(a).baz(3) + T.qux(4) + arr[0]"),
    );
}

test "a comment and the inside of a string are not code, and a quote ends where it started" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectKeys(&.{"real"}, try keysOf(a, "x = real(1) + \"skip(1)\" + 'also(2)' # comment(3)"));
    // An escaped quote does not end the string; a call after the string is one.
    try expectKeys(&.{"after"}, try keysOf(a, "x = \"a \\\" hidden(1)\" + after(2)"));
    // A string right after an identifier: the identifier is no call.
    try expectKeys(&.{}, try keysOf(a, "x = name\"(1)\""));
}

test "a declaration calls nothing; a word that only starts like one is a call" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectKeys(&.{}, try keysOf(a, "def f(x: Int) -> Int:"));
    try expectKeys(&.{}, try keysOf(a, "\t  fn g[T: A](x: T):"));
    try expectKeys(&.{"defer"}, try keysOf(a, "defer(1)"));
    try expectKeys(&.{"define"}, try keysOf(a, "    define(1)"));
    // `def` with nothing after it is no declaration either.
    try expectKeys(&.{}, try keysOf(a, "def"));
}

test "a receiver is a name or a constructor call; anything else names no type" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectKeys(&.{ ".foo", "T.foo" }, try keysOf(a, "T.foo(1)"));
    try expectKeys(&.{ "T", "f", ".foo", "T.foo" }, try keysOf(a, "T(a, f(b)).foo(1)"));
    // Not a receiver name: a parenthesis with nothing before it, an unbalanced one, a literal, a bracket.
    try expectKeys(&.{".foo"}, try keysOf(a, "(a).foo(1)"));
    try expectKeys(&.{".foo"}, try keysOf(a, "x).foo(1)"));
    try expectKeys(&.{".foo"}, try keysOf(a, "x = (1).foo(2)"));
    try expectKeys(&.{ "xs", ".foo" }, try keysOf(a, "xs[0].foo(1)"));
    try expectKeys(&.{".foo"}, try keysOf(a, ".foo(1)"));
}

const inl_src =
    \\@always_inline
    \\def f(x: Int) -> Int:
    \\    return x
    \\
    \\@always_inline
    \\def g(x: Int) -> Int:
    \\    return x
    \\
    \\def d(x: Int) -> Int:
    \\    return f(x)
;

fn unreliable(a: std.mem.Allocator, ev: *const C.Evidence, text: []const u8, path: []const u8) ![]const usize {
    const dups = try C.declaredTwice(a, &.{.{ .path = path, .text = text }});
    const set = try C.unreliableLines(a, text, path, ev, &dups);
    return set.keys();
}

test "an inlined function is left out only when a hit line outside it calls it" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var ev = C.Evidence{};
    // Line 10 calls `f`: its two lines. `g` is inlined too and nothing calls it: it counts.
    try ev.add(a, "p/a.mojo", inl_src, &(try hits(a, &.{10})));
    const got = try unreliable(a, &ev, inl_src, "p/a.mojo");
    try t.expectEqualSlices(usize, &.{ 2, 3 }, got);
    // The same call on a line no test hit is no evidence (line 9, the `def` of its caller, was hit).
    var cold = C.Evidence{};
    try cold.add(a, "p/a.mojo", inl_src, &(try hits(a, &.{9})));
    try t.expectEqual(@as(usize, 0), (try unreliable(a, &cold, inl_src, "p/a.mojo")).len);
    // No hit line at all, and hit line numbers that are no line of the file.
    var none = C.Evidence{};
    try none.add(a, "p/a.mojo", inl_src, &(try hits(a, &.{ 0, 99 })));
    try t.expectEqual(@as(usize, 0), none.callers.count());
    try t.expectEqual(@as(usize, 0), (try unreliable(a, &none, inl_src, "p/a.mojo")).len);
}

test "a plain function is never left out, called or not" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\def f(x: Int) -> Int:
        \\    return x
        \\
        \\def d(x: Int) -> Int:
        \\    return f(x)
    ;
    var ev = C.Evidence{};
    try ev.add(a, "p/a.mojo", src, &(try hits(a, &.{5})));
    try t.expect(ev.callers.contains("f"));
    try t.expectEqual(@as(usize, 0), (try unreliable(a, &ev, src, "p/a.mojo")).len);
}

test "a function with compile-time arms is left out by arm, only with the same evidence" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\def f(x: Int) -> Int:
        \\    var y = x
        \\    comptime if A:
        \\        y = 1
        \\    return y
        \\
        \\def d(x: Int) -> Int:
        \\    return f(x)
    ;
    var ev = C.Evidence{};
    try ev.add(a, "p/a.mojo", src, &(try hits(a, &.{8})));
    // The gate line and its body go; the lines outside the arm (1, 2, 5) are counted.
    try t.expectEqualSlices(usize, &.{ 3, 4 }, try unreliable(a, &ev, src, "p/a.mojo"));
    var cold = C.Evidence{};
    try cold.add(a, "p/a.mojo", src, &(try hits(a, &.{7})));
    try t.expectEqual(@as(usize, 0), (try unreliable(a, &cold, src, "p/a.mojo")).len);
}

test "a free function is reached from its own file, or from a file that imports its name or its module" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const lib = "@always_inline\ndef f(x: Int) -> Int:\n    return x\n";
    const path = "p/src/p/mod.mojo";
    // An importing file: by name (an import line that ends the file, no newline after it), and by module name.
    const importers = [_]struct { text: []const u8, hit: usize }{
        .{ .text = "from p.mod import f\nx = f(1)\n", .hit = 2 },
        .{ .text = "from p.mod import f\nx = f(1)", .hit = 2 },
        .{ .text = "import p.mod\nx = mod.f(1)\ny = f(2)\n", .hit = 3 },
    };
    for (importers) |imp| {
        var ev = C.Evidence{};
        try ev.add(a, "p/test.mojo", imp.text, &(try hits(a, &.{imp.hit})));
        try t.expectEqualSlices(usize, &.{ 2, 3 }, try unreliable(a, &ev, lib, path));
    }
    // A file that imports neither: the call may be another function's.
    var unrelated = C.Evidence{};
    try unrelated.add(a, "p/test.mojo", "from q.other import g\nx = f(1)\n", &(try hits(a, &.{2})));
    try t.expectEqual(@as(usize, 0), (try unreliable(a, &unrelated, lib, path)).len);
    // A method call of the same name is not a call of a free function.
    var method = C.Evidence{};
    try method.add(a, path, "def d(v: Int):\n    v.f()\n", &(try hits(a, &.{2})));
    try t.expectEqual(@as(usize, 0), (try unreliable(a, &method, lib, path)).len);
}

test "a name the package declares more than once is no evidence for a free function" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const lib = "@always_inline\ndef f(x: Int) -> Int:\n    return x\n\ndef d(x: Int) -> Int:\n    return f(x)\n";
    var ev = C.Evidence{};
    try ev.add(a, "p/a.mojo", lib, &(try hits(a, &.{6})));
    const alone = try C.declaredTwice(a, &.{.{ .path = "p/a.mojo", .text = lib }});
    try t.expectEqual(@as(usize, 0), alone.count());
    try t.expectEqualSlices(usize, &.{ 2, 3 }, (try C.unreliableLines(a, lib, "p/a.mojo", &ev, &alone)).keys());
    // The same name in a second file, or twice in one file: both are two declarations.
    const twice = try C.declaredTwice(a, &.{ .{ .path = "p/a.mojo", .text = lib }, .{ .path = "p/b.mojo", .text = "def f():\n    pass\n" } });
    try t.expect(twice.contains("f"));
    try t.expectEqual(@as(usize, 1), twice.count());
    try t.expectEqual(@as(usize, 0), (try C.unreliableLines(a, lib, "p/a.mojo", &ev, &twice)).count());
    const same_file = try C.declaredTwice(a, &.{.{ .path = "p/a.mojo", .text = "def f():\n    pass\ndef f(x: Int):\n    pass\n" }});
    try t.expect(same_file.contains("f"));
}

test "a method is reached only by a call that names its type" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\struct S:
        \\    @always_inline
        \\    def m(self) -> Int:
        \\        return 1
        \\
        \\struct SS:
        \\    @always_inline
        \\    def m(self) -> Int:
        \\        return 2
        \\
        \\def d(v: Int) -> Int:
        \\    var s = S()
        \\    var u = unknown.m()
        \\    return S().m() + s.m()
    ;
    // `unknown.m()` (line 13) names no type, and `S()` alone (line 12) is a call of `S`, not of `m`: nothing is left out.
    var no_type = C.Evidence{};
    try no_type.add(a, "p/a.mojo", src, &(try hits(a, &.{ 12, 13 })));
    try t.expectEqual(@as(usize, 0), (try unreliable(a, &no_type, src, "p/a.mojo")).len);
    // `S().m()` (line 14) names S: S's lines, never SS's, though both are called `m`.
    var typed = C.Evidence{};
    try typed.add(a, "p/a.mojo", src, &(try hits(a, &.{14})));
    const got = try unreliable(a, &typed, src, "p/a.mojo");
    try t.expectEqualSlices(usize, &.{ 3, 4 }, got);
}

test "a closure is its own function: its name is no evidence, and a method of no struct has no owner" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\def outer(x: Int) -> Int:
        \\    @always_inline
        \\    def inner() -> Int:
        \\        return x
        \\    return inner()
    ;
    var ev = C.Evidence{};
    try ev.add(a, "p/a.mojo", src, &(try hits(a, &.{5})));
    try t.expect(ev.callers.contains("inner"));
    try t.expectEqual(@as(usize, 0), (try unreliable(a, &ev, src, "p/a.mojo")).len);
}

test "a path with and without a directory or the .mojo suffix names its module" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const lib = "@always_inline\ndef f(x: Int) -> Int:\n    return x\n";
    // The caller imports the module by the library's file name: a path with no directory, and one with no suffix.
    for ([_][]const u8{ "mod.mojo", "dir/mod", "mod" }) |path| {
        var ev = C.Evidence{};
        try ev.add(a, "t.mojo", "import mod\nx = f(1)\n", &(try hits(a, &.{2})));
        try t.expectEqual(@as(usize, 2), (try unreliable(a, &ev, lib, path)).len);
    }
}
