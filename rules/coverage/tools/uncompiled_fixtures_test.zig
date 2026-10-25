//! The inputs of the full-source checker's own tests of the classification of the code no test compiled (its test_uncompiled.mojo and
//! test_platform_gate.mojo), run through cov_summary's report of the same code, and held to the figures those tests assert.
//!
//! The checker is given a report of the uncompiled lines (the file this rule set writes) and the test reports; cov_summary writes that report from
//! the source and the test reports, so each case here is the same source and the same test reports, and the report is the one cov_summary computes. The
//! checker's `_uncompiled_lines()` is asserted to be what the source gives, so the two start from the same lines. Every figure asserted below is the
//! number the checker's test asserts for the case; where a figure differs it is said why, in the case (the gate cases: the checker's hand-written report
//! lists one line of each function, cov_summary lists the `def` line as well).
//!
//! Fixtures are Mojo sources and Cobertura reports: no Mojo is compiled here. What a real compiler does with `@always_inline` and `comptime if` is
//! the reports' business; this holds what is done with the reports.

const std = @import("std");
const S = @import("cov_summary.zig");
const M = @import("mojo_src.zig");
const G = @import("mojo_gate.zig");
const branch_lcov = @import("branch_lcov.zig");
const t = std.testing;

const Files = std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool));

const LIB = "src/mp/src/mp/lib.mojo";
const OTHER = "src/mp/src/mp/other.mojo";

// ---- the harness ----------------------------------------------------------------------------------------------------------------------

var table: []const [2][]const u8 = &.{};

fn readTable(_: std.mem.Allocator, name: []const u8) []const u8 {
    for (table) |e| {
        if (std.mem.eql(u8, e[0], name)) return e[1];
    }
    return "";
}

/// A Cobertura class of `path` with the `lines`, each with `hits`.
fn rep(a: std.mem.Allocator, path: []const u8, lines: []const usize, hits: usize) ![]const u8 {
    var o = std.ArrayList(u8).empty;
    try o.print(a, "<class name=\"{s}\" filename=\"{s}\">\n<lines>\n", .{ path, path });
    for (lines) |ln| try o.print(a, "<line number=\"{d}\" hits=\"{d}\"/>\n", .{ ln, hits });
    try o.appendSlice(a, "</lines>\n</class>\n");
    return o.toOwnedSlice(a);
}

const Result = struct {
    unc: S.Uncompiled,
    files: Files,
    /// The lines found and hit over every file of the reports, as the checker's package figures.
    found: usize,
    hit: usize,
    /// The arms of the report of the uncompiled decisions (all unhit).
    arms: usize,

    fn has(self: Result, path: []const u8, ln: usize) bool {
        return if (self.files.get(path)) |f| f.contains(ln) else false;
    }
};

/// What cov_summary does with the test reports `reports`, the sources `srcs` (path, text; the paths of `expect` are the library's, the others are
/// read for calls only), with branch records on.
fn run(a: std.mem.Allocator, reports: []const []const u8, srcs: []const [2][]const u8, expect: []const []const u8) !Result {
    return runWith(a, reports, srcs, expect, true);
}

fn runWith(a: std.mem.Allocator, reports: []const []const u8, srcs: []const [2][]const u8, expect: []const []const u8, with_branches: bool) !Result {
    // `addUncompiled` is given (repository path, file to read); here the file is read by its path, out of `table`.
    table = srcs;
    const named = try a.alloc([2][]const u8, srcs.len);
    for (srcs, named) |s, *n| n.* = .{ s[0], s[0] };
    var files: Files = .empty;
    for (reports) |r| try S.addReport(a, &files, r);
    const none: S.BranchLines = .empty;
    const unc = try S.addUncompiled(a, &files, &none, with_branches, expect, named, readTable);
    var found: usize = 0;
    var hit: usize = 0;
    for (try S.summarize(a, &files)) |row| {
        found += row.total;
        hit += row.hit;
    }
    var arms: usize = 0;
    if (unc.branches.len != 0) {
        var sum = branch_lcov.Sum{};
        var diag = branch_lcov.Diag{};
        try sum.add(a, &diag, unc.branches, "uncompiled");
        for (try sum.counts(a)) |c| {
            try t.expectEqual(@as(usize, 0), c.hit);
            arms += c.total;
        }
    }
    return .{ .unc = unc, .files = files, .found = found, .hit = hit, .arms = arms };
}

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

fn gatedNames(a: std.mem.Allocator, r: Result) ![]const u8 {
    var o = std.ArrayList(u8).empty;
    for (r.unc.gated) |g| try o.print(a, "{s}:{d};", .{ g.name, g.lines });
    return o.toOwnedSlice(a);
}

// ---- test_uncompiled.mojo: the shared source -----------------------------------------------------------------------------------------

const lib_source =
    \\def driver(x: Int) -> Int:
    \\    return inl_called(x) + gated_called(x) + outer(x)
    \\
    \\def plain(x: Int) -> Int:
    \\    if x < 0:
    \\        return 0
    \\    return x
    \\
    \\@always_inline
    \\def inl_called(x: Int) -> Int:
    \\    return x + 1
    \\
    \\@always_inline
    \\def inl_uncalled(x: Int) -> Int:
    \\    return x + 2
    \\
    \\def gated_called(x: Int) -> Int:
    \\    var y = x
    \\    comptime if True:
    \\        y = x and x
    \\    comptime else:
    \\        y = 0
    \\    return y
    \\
    \\def gated_uncalled(x: Int) -> Int:
    \\    comptime if True:
    \\        return x
    \\    return 0
    \\
    \\def outer(x: Int) -> Int:
    \\    @parameter
    \\    def inner() -> Int:
    \\        comptime if True:
    \\            return x
    \\        return 0
    \\    return inner()
;

/// The checker's `_uncompiled_lines()`: the own executable lines of every function no test compiled.
const checker_uncompiled_lines = [_]usize{ 4, 5, 6, 7, 10, 11, 14, 15, 17, 18, 19, 20, 21, 22, 23, 25, 26, 27, 28, 30, 31, 32, 33, 34, 35, 36 };

/// The checker's `_inputs`: `driver` (line 1) ran, and line 2 (the calls) is recorded by a second test, hit only when `driver_hit`.
fn uncompiledRun(a: std.mem.Allocator, driver_hit: bool) !Result {
    const reports = [_][]const u8{ try rep(a, LIB, &.{1}, 1), try rep(a, LIB, &.{2}, if (driver_hit) 1 else 0) };
    return run(a, &reports, &.{.{ LIB, lib_source }}, &.{LIB});
}

test "fixture: the source gives the checker's uncompiled lines" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var rec: M.LineSet = .empty;
    try rec.put(a, 1, {});
    try rec.put(a, 2, {});
    const u = try M.uncompiled(a, lib_source, &rec);
    try t.expectEqualSlices(usize, &checker_uncompiled_lines, u.lines);
}

test "fixture: a function a test called is left out and the rest is counted (checker: test_a_function_a_test_called_is_left_out_and_the_rest_is_counted)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const r = try uncompiledRun(a, true);
    // The checker: line_found 22, line_hit 2, branch_found 2, branch_hit 0, excluded_lines 6, excluded_arms 2, one excluded file with 6 lines and 2 arms.
    try t.expectEqual(@as(usize, 22), r.found);
    try t.expectEqual(@as(usize, 2), r.hit);
    try t.expectEqual(@as(usize, 2), r.arms);
    try t.expectEqual(@as(usize, 1), r.unc.excluded.len);
    try t.expectEqualStrings(LIB, r.unc.excluded[0].path);
    try t.expectEqual(@as(usize, 6), r.unc.excluded[0].lines);
    try t.expectEqual(@as(usize, 2), r.unc.excluded[0].arms);
    try t.expectEqual(@as(usize, 0), r.unc.gated.len);
}

test "fixture: a function nobody calls is counted whatever its class (checker: test_a_function_nobody_calls_is_counted_whatever_its_class)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const r = try uncompiledRun(a, true);
    for ([_]usize{ 4, 5, 6, 7, 14, 15, 25, 26, 27, 28 }) |ln| try t.expect(r.has(LIB, ln));
}

test "fixture: a gated function is left out by arm, not whole (checker: test_a_gated_function_is_left_out_by_arm_not_whole)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const r = try uncompiledRun(a, true);
    for ([_]usize{ 19, 20, 21, 22, 10, 11 }) |ln| try t.expect(!r.has(LIB, ln));
    for ([_]usize{ 17, 18, 23 }) |ln| try t.expect(r.has(LIB, ln));
}

test "fixture: a closure is a function of its own and does not reclassify the outer (checker: test_a_closure_is_a_function_of_its_own_and_does_not_reclassify_the_outer)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const r = try uncompiledRun(a, true);
    for ([_]usize{ 30, 31, 36, 32, 33, 34, 35 }) |ln| try t.expect(r.has(LIB, ln));
}

test "fixture: without a hit line that calls them nothing is left out (checker: test_without_a_hit_line_that_calls_them_nothing_is_left_out)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const r = try uncompiledRun(a, false);
    // The checker: line_found 1 + 1 + 26, branch_found 4, no excluded line, no excluded file.
    try t.expectEqual(@as(usize, 28), r.found);
    try t.expectEqual(@as(usize, 1), r.hit);
    try t.expectEqual(@as(usize, 4), r.arms);
    try t.expectEqual(@as(usize, 0), r.unc.excluded.len);
    try t.expectEqual(@as(usize, 0), r.unc.gated.len);
}

test "fixture: what is left out is in the listing (checker: test_what_is_left_out_is_in_the_result_and_the_summary)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // The checker's result says excluded_lines 6, excluded_arms 2 and the file `src/mp/src/mp/lib.mojo` with 6 and 2; nothing left out says 0.
    const r = try uncompiledRun(a, true);
    try t.expectEqualStrings(
        "excluded src/mp/src/mp/lib.mojo 6 lines 2 arms\nexcluded total 6 lines 2 arms\ngated total 0 functions 0 lines 0 arms\n",
        r.unc.listing,
    );
    const b = try uncompiledRun(a, false);
    try t.expectEqualStrings("excluded total 0 lines 0 arms\ngated total 0 functions 0 lines 0 arms\n", b.unc.listing);
}

test "fixture: a declaration is no evidence that a function is called (checker: test_a_declaration_is_no_evidence_that_a_function_is_called)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // The hit line is the `def` line of another function of the same name: a declaration calls nothing. Line 2 of the library is not hit.
    const reports = [_][]const u8{ try rep(a, LIB, &.{1}, 1), try rep(a, OTHER, &.{1}, 1) };
    const r = try run(a, &reports, &.{ .{ LIB, lib_source }, .{ OTHER, "  def inl_called(x: Int) -> Int:  # declared, not called\n" } }, &.{LIB});
    try t.expectEqual(@as(usize, 0), r.unc.excluded.len);
}

test "fixture: a method call is evidence for a method and a bare call for a free function (checker: test_a_method_call_is_evidence_for_a_method_and_a_bare_call_for_a_free_function)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\def driver(v: Int) -> Int:
        \\    return v.free() + S(v).meth()
        \\
        \\@always_inline
        \\def free(v: Int) -> Int:
        \\    return v
        \\
        \\struct S:
        \\    @always_inline
        \\    def meth(self) -> Int:
        \\        pass
        \\
        \\def driver2(v: Int) -> Int:
        \\    return free(v)
    ;
    // Lines 1 and 2 hit: `v.free()` is a method call of another type's `free`, no evidence for the free function; `S(v).meth()` names the type.
    const one = [_][]const u8{try rep(a, LIB, &.{ 1, 2 }, 1)};
    const r = try run(a, &one, &.{.{ LIB, src }}, &.{LIB});
    try t.expect(!r.has(LIB, 10));
    try t.expect(r.has(LIB, 5));
    try t.expect(r.has(LIB, 6));
    // With the bare call (line 14) hit too, `free` is left out as well.
    const two = [_][]const u8{try rep(a, LIB, &.{ 1, 2, 14 }, 1)};
    const b = try run(a, &two, &.{.{ LIB, src }}, &.{LIB});
    try t.expect(!b.has(LIB, 5));
    try t.expect(!b.has(LIB, 10));
}

const foo_src =
    \\@always_inline
    \\def foo(x: Int) -> Int:
    \\    return x
    \\
    \\def driver(x: Int) -> Int:
    \\    return x
;

test "fixture: a hit call in another package is no evidence (checker: test_a_hit_call_in_another_package_is_no_evidence)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // The hit `foo(1)` is in a file of the package that imports the name: left out. The checker asserts 1 line: its hand-written report lists line 3
    // alone; cov_summary lists the `def` line (2) as well, so 2.
    const same = [_][]const u8{ try rep(a, LIB, &.{ 5, 6 }, 1), try rep(a, OTHER, &.{2}, 1) };
    const r = try run(a, &same, &.{ .{ LIB, foo_src }, .{ OTHER, "from mp.lib import foo\nx = foo(1)\n" } }, &.{LIB});
    try t.expectEqual(@as(usize, 2), r.unc.excluded[0].lines);
    try t.expect(!r.has(LIB, 2) and !r.has(LIB, 3));
    // In another package the file is not among the package's sources (a package is what cov_summary is given): no evidence, counted.
    const other = [_][]const u8{ try rep(a, LIB, &.{ 5, 6 }, 1), try rep(a, "src/other/src/other/o.mojo", &.{1}, 1) };
    const b = try run(a, &other, &.{.{ LIB, foo_src }}, &.{LIB});
    try t.expectEqual(@as(usize, 0), b.unc.excluded.len);
    try t.expect(b.has(LIB, 3));
}

test "fixture: a name the package declares twice is no evidence for a free function (checker: test_a_name_the_package_declares_twice_is_no_evidence_for_a_free_function)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const reports = [_][]const u8{ try rep(a, LIB, &.{ 5, 6 }, 1), try rep(a, OTHER, &.{2}, 1) };
    const r = try run(a, &reports, &.{ .{ LIB, foo_src }, .{ OTHER, "def foo(x: Int) -> Int:\n    return foo(x)\n" } }, &.{LIB});
    try t.expectEqual(@as(usize, 0), r.unc.excluded.len);
    try t.expect(r.has(LIB, 3));
}

test "fixture: a method is told by the type its call names (checker: test_a_method_is_told_by_the_type_its_call_names)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\struct A:
        \\    @always_inline
        \\    def ne(self, o: Int) -> Bool:
        \\        return o == 1
        \\
        \\struct B:
        \\    @always_inline
        \\    def ne(self, o: Int) -> Bool:
        \\        return o == 2
        \\
        \\def driver(x: Int) -> Bool:
        \\    return A(x).ne(1)
    ;
    const reports = [_][]const u8{try rep(a, LIB, &.{ 11, 12 }, 1)};
    const r = try run(a, &reports, &.{.{ LIB, src }}, &.{LIB});
    try t.expect(!r.has(LIB, 3));
    try t.expect(!r.has(LIB, 4));
    try t.expect(r.has(LIB, 8));
    try t.expect(r.has(LIB, 9));
}

test "fixture: a call named inside a multi-line string is no evidence (checker: test_a_call_named_inside_a_multi_line_string_is_no_evidence)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src = "def driver(x: Int) -> Int:\n    var s = \"\"\"\ninl_called(1)\n\"\"\"\n    return x\n\n@always_inline\ndef inl_called(x: Int) -> Int:\n    return x\n";
    // Line 3 is the interior of a triple-quoted string; a report that marks it hit does not make it a call.
    const reports = [_][]const u8{try rep(a, LIB, &.{ 1, 2, 3, 5 }, 1)};
    const r = try run(a, &reports, &.{.{ LIB, src }}, &.{LIB});
    try t.expectEqual(@as(usize, 0), r.unc.excluded.len);
    try t.expect(r.has(LIB, 9));
}

test "fixture: a free function needs a call that can reach it (checker: test_a_free_function_needs_a_call_that_can_reach_it)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // A hit `foo(1)` in another file that imports neither `foo` nor its module: counted.
    const none = [_][]const u8{ try rep(a, LIB, &.{ 5, 6 }, 1), try rep(a, OTHER, &.{1}, 1) };
    const n = try run(a, &none, &.{ .{ LIB, foo_src }, .{ OTHER, "x = foo(1)\n" } }, &.{LIB});
    try t.expectEqual(@as(usize, 0), n.unc.excluded.len);
    try t.expect(n.has(LIB, 3));
    // One that imports the module (`import mp.lib`): left out (the checker asserts 1 line, the `return`; with the `def` line, 2).
    const module = [_][]const u8{ try rep(a, LIB, &.{ 5, 6 }, 1), try rep(a, OTHER, &.{3}, 1) };
    const m = try run(a, &module, &.{ .{ LIB, foo_src }, .{ OTHER, "import mp.lib\nx = lib.foo(1)\ny = foo(1)\n" } }, &.{LIB});
    try t.expectEqual(@as(usize, 2), m.unc.excluded[0].lines);
    // A call in the same file is enough: line 6 calls it.
    const own_src = "@always_inline\ndef foo(x: Int) -> Int:\n    return x\n\ndef driver(x: Int) -> Int:\n    return foo(x)\n";
    const own = [_][]const u8{try rep(a, LIB, &.{ 5, 6 }, 1)};
    const o = try run(a, &own, &.{.{ LIB, own_src }}, &.{LIB});
    try t.expectEqual(@as(usize, 2), o.unc.excluded[0].lines);
}

test "fixture: a method needs a call that names its type (checker: test_a_method_needs_a_call_that_names_its_type)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\struct S:
        \\    @always_inline
        \\    def size(self) -> Int:
        \\        return 1
        \\
        \\def driver(b: List[Int]) -> Int:
        \\    return b.size()
        \\
        \\def typed(x: Int) -> Int:
        \\    return S().size()
    ;
    // Only the call on an unknown receiver (line 7) was hit: the method is counted.
    const unknown = [_][]const u8{try rep(a, LIB, &.{ 6, 7 }, 1)};
    const r = try run(a, &unknown, &.{.{ LIB, src }}, &.{LIB});
    try t.expectEqual(@as(usize, 0), r.unc.excluded.len);
    // With the call that names the type (line 10) hit too: left out (the checker: 2 lines).
    const typed = [_][]const u8{try rep(a, LIB, &.{ 6, 7, 9, 10 }, 1)};
    const b = try run(a, &typed, &.{.{ LIB, src }}, &.{LIB});
    try t.expectEqual(@as(usize, 2), b.unc.excluded[0].lines);
}

// ---- test_platform_gate.mojo: the shared sources --------------------------------------------------------------------------------------

const gate_lib =
    \\def compiled(x: Int) -> Int:
    \\    var y = x
    \\    comptime if DROPPED:
    \\        y = gated_a(y) + live_one(y) + chain_top(y) + dup(y)
    \\    comptime else:
    \\        y = arm_callee(x)
    \\    return y + live_one(x)
    \\
    \\def gated_a(x: Int) -> Int:
    \\    return x + 1
    \\
    \\def live_one(x: Int) -> Int:
    \\    return x + 2
    \\
    \\def orphan(x: Int) -> Int:
    \\    return x + 3
    \\
    \\def arm_callee(x: Int) -> Int:
    \\    return x + 4
    \\
    \\def chain_top(x: Int) -> Int:
    \\    return chain_leaf(x)
    \\
    \\def chain_leaf(x: Int) -> Int:
    \\    return x + 5
    \\
    \\def dup(x: Int) -> Int:
    \\    return x + 6
;

const gate_other =
    \\def dup(x: Int) -> Int:
    \\    return x
    \\
    \\def user(x: Int) -> Int:
    \\    return dup(x)
;

fn gateRun(a: std.mem.Allocator) !Result {
    // The tests compiled `compiled` (its `else` arm and its live lines, not the dropped arm's line 4) and the other file.
    const reports = [_][]const u8{
        try rep(a, LIB, &.{ 1, 2, 6, 7 }, 1),
        try rep(a, OTHER, &.{ 1, 2, 4, 5 }, 1),
    };
    return run(a, &reports, &.{ .{ LIB, gate_lib }, .{ OTHER, gate_other } }, &.{LIB});
}

test "fixture: every caller in a dropped arm is gated, and a chain of them too (checker: test_every_caller_in_a_dropped_arm_is_gated_and_a_chain_of_them_too)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const r = try gateRun(a);
    // The checker's names and order: gated_a, chain_top, chain_leaf. Its hand-written report lists one line of each function (10, 22, 25) and so asserts 1
    // line each, 3 in all; cov_summary lists the `def` line too (9, 21, 24 as well), so each function has 2 and the total is 6.
    try t.expectEqualStrings("gated_a:2;chain_top:2;chain_leaf:2;", try gatedNames(a, r));
    for ([_]usize{ 9, 10, 21, 22, 24, 25 }) |ln| try t.expect(!r.has(LIB, ln));
}

test "fixture: the gate itself, given the checker's own candidates (one line each), flags what the checker flags" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // The checker's candidates, in its order, with its line counts.
    const cands = [_]G.Cand{
        .{ .path = LIB, .name = "gated_a", .line = 9, .lines = 1 },
        .{ .path = LIB, .name = "live_one", .line = 12, .lines = 1 },
        .{ .path = LIB, .name = "orphan", .line = 15, .lines = 1 },
        .{ .path = LIB, .name = "arm_callee", .line = 18, .lines = 1 },
        .{ .path = LIB, .name = "chain_top", .line = 21, .lines = 1 },
        .{ .path = LIB, .name = "chain_leaf", .line = 24, .lines = 1 },
        .{ .path = LIB, .name = "dup", .line = 27, .lines = 1 },
    };
    var recorded: G.Recorded = .empty;
    var lib_rec: M.LineSet = .empty;
    for ([_]usize{ 1, 2, 6, 7 }) |ln| try lib_rec.put(a, ln, {});
    try recorded.put(a, LIB, lib_rec);
    var other_rec: M.LineSet = .empty;
    for ([_]usize{ 1, 2, 4, 5 }) |ln| try other_rec.put(a, ln, {});
    try recorded.put(a, OTHER, other_rec);
    const flags = try G.platformGated(a, &.{ .{ .path = LIB, .text = gate_lib }, .{ .path = OTHER, .text = gate_other } }, &recorded, &cands);
    try t.expectEqualSlices(bool, &.{ true, false, false, false, true, true, false }, flags);
}

test "fixture: a live caller, a missing caller or a compiled arm keeps a function counted (checker: test_a_live_caller_a_missing_caller_or_a_compiled_arm_keeps_a_function_counted)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const r = try gateRun(a);
    // live_one (callers on lines 4 and 7), orphan (none), arm_callee (line 6, a compiled arm) and dup (a dropped caller, and a live call of the name in
    // another file): each function's two lines are counted. The checker's line_found is 4 + 4 + 4 with one line each; with the `def` lines it is 4 + 8 + 4.
    for ([_]usize{ 12, 13, 15, 16, 18, 19, 27, 28 }) |ln| try t.expect(r.has(LIB, ln));
    try t.expectEqual(@as(usize, 4 + 8 + 4), r.found);
}

test "fixture: what is gated is in the listing (checker: test_what_is_gated_is_in_the_result_and_the_summary)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const r = try gateRun(a);
    // The checker: 3 functions, and `gated_a` in the library at line 9 with its lines.
    try t.expectEqualStrings(
        "excluded total 0 lines 0 arms\n" ++
            "gated src/mp/src/mp/lib.mojo gated_a 9 2 lines\n" ++
            "gated src/mp/src/mp/lib.mojo chain_top 21 2 lines\n" ++
            "gated src/mp/src/mp/lib.mojo chain_leaf 24 2 lines\n" ++
            "gated total 3 functions 6 lines 0 arms\n",
        r.unc.listing,
    );
}

test "fixture: when no function is uncompiled nothing is gated or left out (checker: test_with_no_uncompiled_report_nothing_is_gated)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // The checker gates nothing when it is given no uncompiled report. cov_summary computes that report, so the same fact is a package in which every
    // function has a record.
    const reports = [_][]const u8{ try rep(a, LIB, &.{ 1, 2, 3, 4, 5, 6, 7, 9, 10, 12, 13, 15, 16, 18, 19, 21, 22, 24, 25, 27, 28 }, 1), try rep(a, OTHER, &.{ 1, 2, 4, 5 }, 1) };
    const r = try run(a, &reports, &.{ .{ LIB, gate_lib }, .{ OTHER, gate_other } }, &.{LIB});
    try t.expectEqual(@as(usize, 0), r.unc.gated.len);
    try t.expectEqual(@as(usize, 0), r.unc.excluded.len);
}

test "fixture: a use that is not a plain call keeps a function counted (checker: test_a_use_that_is_not_a_plain_call_keeps_a_function_counted)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\from lib import alias_target as zz
        \\def driver(x: Int) -> Int:
        \\    var cb = value_used
        \\    var r = mod.qual_used(x)
        \\    var q = zz(x)
        \\    comptime if DROPPED:
        \\        q = value_used(q) + qual_used(q) + alias_target(q)
        \\    return x
        \\
        \\def value_used(x: Int) -> Int:
        \\    return x
        \\
        \\def qual_used(x: Int) -> Int:
        \\    return x
        \\
        \\def alias_target(x: Int) -> Int:
        \\    return x
    ;
    const reports = [_][]const u8{try rep(a, LIB, &.{ 2, 3, 4, 5, 8 }, 1)};
    const r = try run(a, &reports, &.{.{ LIB, src }}, &.{LIB});
    try t.expectEqual(@as(usize, 0), r.unc.gated.len);
    for ([_]usize{ 11, 14, 17 }) |ln| try t.expect(r.has(LIB, ln));
}

const arm_src =
    \\def driver(x: Int) -> Int:
    \\    var y = x
    \\    comptime if LIVE:
    \\        y = helper(
    \\            y
    \\        )
    \\    return y
    \\
    \\def helper(x: Int) -> Int:
    \\    return x
;

test "fixture: an arm is dropped only when no line of it has a record (checker: test_an_arm_is_dropped_only_when_no_line_of_it_has_a_record)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // `helper(` is on line 4, which has no record, but line 5, a continuation line of the same call in the same arm, has one: the arm was compiled.
    const live = [_][]const u8{try rep(a, LIB, &.{ 1, 2, 5, 7 }, 1)};
    const r = try run(a, &live, &.{.{ LIB, arm_src }}, &.{LIB});
    try t.expectEqual(@as(usize, 0), r.unc.gated.len);
    try t.expect(r.has(LIB, 10));
    // The same arm with no record on any of its lines is dropped, and `helper` is gated.
    const dropped = [_][]const u8{try rep(a, LIB, &.{ 1, 2, 7 }, 1)};
    const b = try run(a, &dropped, &.{.{ LIB, arm_src }}, &.{LIB});
    try t.expectEqual(@as(usize, 1), b.unc.gated.len);
}

test "fixture: a use in the condition of a comptime if is live (checker: test_a_use_in_the_condition_of_a_comptime_if_is_live)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\def driver(x: Int) -> Int:
        \\    comptime if cond(x):
        \\        return 1
        \\    return 0
        \\
        \\def cond(x: Int) -> Bool:
        \\    return True
    ;
    const reports = [_][]const u8{try rep(a, LIB, &.{ 1, 4 }, 1)};
    const r = try run(a, &reports, &.{.{ LIB, src }}, &.{LIB});
    try t.expectEqual(@as(usize, 0), r.unc.gated.len);
}

test "fixture: functions that call only each other from a dropped arm stay counted (checker: test_functions_that_call_only_each_other_from_a_dropped_arm_stay_counted)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\def driver(x: Int) -> Int:
        \\    comptime if D:
        \\        return ping(x)
        \\    return x
        \\
        \\def ping(x: Int) -> Int:
        \\    return pong(x)
        \\
        \\def pong(x: Int) -> Int:
        \\    return ping(x)
    ;
    const reports = [_][]const u8{try rep(a, LIB, &.{ 1, 4 }, 1)};
    const r = try run(a, &reports, &.{.{ LIB, src }}, &.{LIB});
    try t.expectEqual(@as(usize, 0), r.unc.gated.len);
}

test "fixture: a name declared twice is counted by the gate too (checker: test_a_name_declared_twice_is_counted_by_the_gate_too)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\def driver(x: Int) -> Int:
        \\    var y = x
        \\    comptime if DROPPED:
        \\        y = helper(y)
        \\    return y
        \\
        \\def helper(x: Int) -> Int:
        \\    return x
    ;
    const reports = [_][]const u8{ try rep(a, LIB, &.{ 1, 2, 5 }, 1), try rep(a, OTHER, &.{ 1, 2 }, 1) };
    const r = try run(a, &reports, &.{ .{ LIB, src }, .{ OTHER, "def helper(x: Int) -> Int:\n    return x\n" } }, &.{LIB});
    try t.expectEqual(@as(usize, 0), r.unc.gated.len);
}

const decided_a =
    \\@always_inline
    \\def fa(x: Int) -> Int:
    \\    if x > 0:
    \\        return 1
    \\    return 0
    \\
    \\def driver_a(x: Int) -> Int:
    \\    comptime if D:
    \\        return ga(x)
    \\    return 0
    \\
    \\def ga(x: Int) -> Int:
    \\    if x < 0 or x > 5:
    \\        return 1
    \\    return 0
;

/// The same source under other names.
const decided_b =
    \\@always_inline
    \\def fb(x: Int) -> Int:
    \\    if x > 0:
    \\        return 1
    \\    return 0
    \\
    \\def driver_b(x: Int) -> Int:
    \\    comptime if D:
    \\        return gb(x)
    \\    return 0
    \\
    \\def gb(x: Int) -> Int:
    \\    if x < 0 or x > 5:
    \\        return 1
    \\    return 0
;

test "the listing is sorted by path and counts the arms of every decision the evidence and the gate took out" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const A = "src/mp/src/mp/a.mojo";
    const B = "src/mp/src/mp/b.mojo";
    const T = "src/mp/tests/test_x.mojo";
    const reports = [_][]const u8{
        try rep(a, A, &.{ 7, 10 }, 1),
        try rep(a, B, &.{ 7, 10 }, 1),
        try rep(a, T, &.{3}, 1),
    };
    const srcs = [_][2][]const u8{
        .{ B, decided_b },
        .{ A, decided_a },
        .{ T, "from mp.a import fa\nfrom mp.b import fb\nx = fa(1) + fb(2)\n" },
    };
    // The library is given as b, a: the listing is by path all the same. In each source `fa` (4 lines, the `if`: 2 arms) is inlined and called by a hit
    // line of the test, and `ga` (4 lines; the `if`, the `or` and its right operand: 6 arms) has one use, in an arm no report records.
    const r = try run(a, &reports, &srcs, &.{ B, A });
    try t.expectEqualStrings(
        "excluded src/mp/src/mp/a.mojo 4 lines 2 arms\n" ++
            "excluded src/mp/src/mp/b.mojo 4 lines 2 arms\n" ++
            "excluded total 8 lines 4 arms\n" ++
            "gated src/mp/src/mp/a.mojo ga 12 4 lines\n" ++
            "gated src/mp/src/mp/b.mojo gb 12 4 lines\n" ++
            "gated total 2 functions 8 lines 12 arms\n",
        r.unc.listing,
    );
    // Nothing is left to count: 2 recorded lines of each driver and of the test, and no arm.
    try t.expectEqual(@as(usize, 2 + 2 + 1), r.found);
    try t.expectEqual(@as(usize, 0), r.arms);
    try t.expectEqualStrings(try emptyReport(a), r.unc.cobertura);
    // Without branch records there are no arms to leave out.
    const lines_only = try runWith(a, &reports, &srcs, &.{ B, A }, false);
    try t.expectEqualStrings(
        "excluded src/mp/src/mp/a.mojo 4 lines 0 arms\n" ++
            "excluded src/mp/src/mp/b.mojo 4 lines 0 arms\n" ++
            "excluded total 8 lines 0 arms\n" ++
            "gated src/mp/src/mp/a.mojo ga 12 4 lines\n" ++
            "gated src/mp/src/mp/b.mojo gb 12 4 lines\n" ++
            "gated total 2 functions 8 lines 0 arms\n",
        lines_only.unc.listing,
    );
    try t.expectEqual(@as(usize, 0), lines_only.unc.branches.len);
}

/// The report `addUncompiled` writes when there is nothing to list.
fn emptyReport(a: std.mem.Allocator) ![]const u8 {
    var files: Files = .empty;
    const none: S.BranchLines = .empty;
    return (try S.addUncompiled(a, &files, &none, true, &.{}, &.{}, readTable)).cobertura;
}
