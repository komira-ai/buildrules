//! Unit tests of cov_unmeasured.zig and of its place in cov_summary's step: what the file accepts, what it refuses and says, and that an unmeasured source is
//! never counted 0/0 (it leaves the totals) and never silent (it is listed with its reason).
const std = @import("std");
const S = @import("cov_summary.zig");
const U = @import("cov_unmeasured.zig");
const t = std.testing;

fn parsed(a: std.mem.Allocator, text: []const u8) ![]const U.Entry {
    return switch (try U.parse(a, "coverage_unmeasured.txt", text)) {
        .entries => |e| e,
        .refused => |m| {
            std.debug.print("refused: {s}\n", .{m});
            return error.Refused;
        },
    };
}

fn refusedParse(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    return switch (try U.parse(a, "coverage_unmeasured.txt", text)) {
        .entries => error.Accepted,
        .refused => |m| m,
    };
}

test "parse: a TAB or two spaces split the path from the reason; comments and blank lines are skipped" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const es = try parsed(a, "# why this file exists\n\nsrc/p/a.mojo\tall always_inline nodebug\n  # indented comment\nsrc/p/b.mojo  two spaces, then  the reason \r\n");
    try t.expectEqual(@as(usize, 2), es.len);
    try t.expectEqualStrings("src/p/a.mojo", es[0].path);
    try t.expectEqualStrings("all always_inline nodebug", es[0].reason);
    try t.expectEqualStrings("src/p/b.mojo", es[1].path);
    try t.expectEqualStrings("two spaces, then  the reason", es[1].reason);
    try t.expectEqual(@as(usize, 0), (try parsed(a, "")).len);
    try t.expectEqual(@as(usize, 0), (try parsed(a, "# only a comment\n\n")).len);
}

test "parse: a path with one space in it is one path; one space alone is no split" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const es = try parsed(a, "src/my pkg/a.mojo\tbecause\n");
    try t.expectEqualStrings("src/my pkg/a.mojo", es[0].path);
    try t.expectEqualStrings("coverage_unmeasured.txt:1: `src/p/a.mojo because` has no reason: write `<source path>`, a TAB or two spaces, and why kcov cannot record it", try refusedParse(a, "src/p/a.mojo because\n"));
}

test "parse: an entry without a reason is refused, with its line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = "coverage_unmeasured.txt:2: `src/p/a.mojo` has no reason: write `<source path>`, a TAB or two spaces, and why kcov cannot record it";
    try t.expectEqualStrings(want, try refusedParse(a, "# c\nsrc/p/a.mojo\n"));
    // Trailing blanks are not a reason.
    try t.expectEqualStrings(want, try refusedParse(a, "# c\nsrc/p/a.mojo \t  \n"));
    try t.expect(std.mem.indexOf(u8, try refusedParse(a, "ok.mojo\twhy\n  \tno path here\n"), "has no path") != null);
}

test "parse: a path listed twice is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("coverage_unmeasured.txt:3: src/p/a.mojo is listed twice", try refusedParse(a, "src/p/a.mojo\tone\nsrc/p/b.mojo\ttwo\nsrc/p/a.mojo\tthree\n"));
}

test "parse: the first separator of either kind splits, so a TAB inside the reason stays in the reason" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const es = try parsed(a, "src/p/a.mojo  why\tnot a split\nsrc/p/b.mojo\twhy  not a split\nsrc/p/c.mojo \t  mixed\n");
    try t.expectEqualStrings("src/p/a.mojo", es[0].path);
    try t.expectEqualStrings("why\tnot a split", es[0].reason);
    try t.expectEqualStrings("src/p/b.mojo", es[1].path);
    try t.expectEqualStrings("why  not a split", es[1].reason);
    try t.expectEqualStrings("src/p/c.mojo", es[2].path);
    try t.expectEqualStrings("mixed", es[2].reason);
}

const lib_a = "pkg/src/p/a.mojo";
const lib_b = "pkg/src/p/b.mojo";
const expect = [_][]const u8{ lib_a, lib_b };

fn resolved(a: std.mem.Allocator, text: []const u8, root: []const u8, reported: []const []const u8, empty: []const []const u8) !U.Resolved {
    return U.resolve(a, "coverage_unmeasured.txt", try parsed(a, text), root, &expect, reported, empty);
}

test "resolve: a listed source in no report is accepted, listed with its reason and taken out of the expected set" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = (try resolved(a, "src/p/b.mojo\talways_inline nodebug\n", "pkg", &.{lib_a}, &.{})).ok;
    try t.expectEqual(@as(usize, 1), r.expect.len);
    try t.expectEqualStrings(lib_a, r.expect[0]);
    try t.expectEqualStrings("unmeasured: pkg/src/p/b.mojo: always_inline nodebug\nunmeasured total 1 files: left out of the line and branch totals and the floors\n", r.listing);
    // At the repository root the entry is the repository path.
    const at_root = try U.resolve(a, "f", try parsed(a, "pkg/src/p/b.mojo\twhy\n"), "", &expect, &.{lib_a}, &.{});
    try t.expectEqualStrings(lib_a, at_root.ok.expect[0]);
}

test "resolve: no entry changes nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = (try resolved(a, "# nothing unmeasured\n", "pkg", &.{ lib_a, lib_b }, &.{})).ok;
    try t.expectEqual(@as(usize, 2), r.expect.len);
    try t.expectEqualStrings("", r.listing);
}

fn refusal(r: U.Resolved) []const u8 {
    return switch (r) {
        .ok => "accepted",
        .refused => |m| m,
    };
}

test "resolve: an entry whose file a report names is refused as stale" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("coverage_unmeasured.txt: src/p/b.mojo listed as unmeasured but measured: remove the entry", refusal(try resolved(a, "src/p/b.mojo\twhy\n", "pkg", &.{ lib_a, lib_b }, &.{})));
}

test "resolve: an entry that is no library source of the package is refused (missing file, a test, another file)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "src/p/gone.mojo", "tests/test_a.mojo", "README.md" }) |p| {
        const text = try std.fmt.allocPrint(a, "{s}\twhy\n", .{p});
        const m = refusal(try resolved(a, text, "pkg", &.{lib_a}, &.{}));
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "coverage_unmeasured.txt: {s} is not a library source of the package (no such file, or a test or another file): remove the entry", .{p}), m);
    }
}

test "resolve: a source with no statement is refused: it is 0/0 already" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = refusal(try resolved(a, "src/p/b.mojo\twhy\n", "pkg", &.{lib_a}, &.{lib_b}));
    try t.expectEqualStrings("coverage_unmeasured.txt: src/p/b.mojo has no statement, so `:coverage` lists it 0/0 and there is nothing to be unmeasured: remove the entry", m);
}

test "resolve: a path that starts with a slash is refused before it is joined" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = refusal(try resolved(a, "/src/p/b.mojo\twhy\n", "pkg", &.{lib_a}, &.{}));
    try t.expectEqualStrings("coverage_unmeasured.txt: /src/p/b.mojo is an absolute path: write it relative to the package", m);
    // At the repository root too, where the join would have passed it through unchanged.
    try t.expectEqualStrings("coverage_unmeasured.txt: /pkg/src/p/b.mojo is an absolute path: write it relative to the package", refusal(try U.resolve(a, "coverage_unmeasured.txt", try parsed(a, "/pkg/src/p/b.mojo\twhy\n"), "", &expect, &.{lib_a}, &.{})));
}

// ---- only a source kcov cannot record is accepted: every function is @always_inline("nodebug") ----

const NB = "@always_inline(\"nodebug\")\n";

var source_of_b: []const u8 = "";

fn readB(_: std.mem.Allocator, p: []const u8) []const u8 {
    return if (std.mem.eql(u8, p, "list.txt")) "src/p/b.mojo  reason\n" else source_of_b;
}

fn noStmts(_: []const u8) bool {
    return false;
}

/// The refusal of listing `src/p/b.mojo` with this source, or "accepted".
fn listed(a: std.mem.Allocator, src: []const u8) ![]const u8 {
    source_of_b = src;
    const srcs = [_][2][]const u8{ .{ lib_a, "a" }, .{ lib_b, "b" } };
    return refusal(try U.load(a, "pkg", "list.txt", &expect, &.{lib_a}, &srcs, readB, noStmts));
}

fn nodebugRefusal(a: std.mem.Allocator, name: []const u8, line: usize) ![]const u8 {
    return std.fmt.allocPrint(a, "list.txt: src/p/b.mojo listed as unmeasured but {s} at line {d} is not @always_inline(\"nodebug\"): kcov can record it; test it instead", .{ name, line });
}

test "load: an ordinary function is refused: kcov can record it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(try nodebugRefusal(a, "f", 1), try listed(a, "def f(x: Int) -> Int:\n    return x\n"));
}

test "load: a file of nodebug inline functions only is accepted, other decorators and a stack of them beside the one included" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("accepted", try listed(a, NB ++ "def f(x: Int) -> Int:\n    return x\n"));
    try t.expectEqualStrings("accepted", try listed(a, "@always_inline( \"nodebug\" )\ndef f(x: Int) -> Int:\n    return x\n\n" ++ NB ++ "def g(x: Int) -> Int:\n    return x\n"));
    try t.expectEqualStrings("accepted", try listed(a, "@deprecated\n" ++ NB ++ "@parameter\ndef f(x: Int) -> Int:\n    return x\n"));
    try t.expectEqualStrings("accepted", try listed(a, NB ++ "@deprecated(\"old\")\nfn f(x: Int) -> Int:\n    return x\n"));
    // A method of a struct is a function of the file: this one is inlined too.
    try t.expectEqualStrings("accepted", try listed(a, "struct S:\n    " ++ "@always_inline(\"nodebug\")\n    def m(self) -> Int:\n        return 1\n"));
}

test "load: one ordinary function among nodebug ones refuses the entry, naming it and its line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(try nodebugRefusal(a, "slow", 6), try listed(a, NB ++ "def fast(x: Int) -> Int:\n    return x\n\n\ndef slow(x: Int) -> Int:\n    return x\n"));
    // A method without the decorator in a struct whose other method has it.
    try t.expectEqualStrings(try nodebugRefusal(a, "n", 6), try listed(a, "struct S:\n    @always_inline(\"nodebug\")\n    def m(self) -> Int:\n        return 1\n\n    def n(self) -> Int:\n        return 2\n"));
}

test "load: @always_inline without nodebug is refused, and so is any other argument" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(try nodebugRefusal(a, "f", 2), try listed(a, "@always_inline\ndef f(x: Int) -> Int:\n    return x\n"));
    try t.expectEqualStrings(try nodebugRefusal(a, "f", 2), try listed(a, "@always_inline(\"builtin\")\ndef f(x: Int) -> Int:\n    return x\n"));
    // The decorator above another function's does not carry over.
    try t.expectEqualStrings(try nodebugRefusal(a, "g", 5), try listed(a, NB ++ "def f(x: Int) -> Int:\n    return x\n\ndef g(x: Int) -> Int:\n    return x\n"));
}

test "load: a signature over several lines is read whole" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sig = "def f(\n    x: Int,\n    y: Int,\n) -> Int:\n    return x + y\n";
    try t.expectEqualStrings("accepted", try listed(a, NB ++ sig));
    try t.expectEqualStrings(try nodebugRefusal(a, "f", 1), try listed(a, sig));
}

test "load: a file with statements but no function is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("list.txt: src/p/b.mojo listed as unmeasured but it defines no @always_inline(\"nodebug\") function: kcov can record it; test it instead", try listed(a, "comptime N = 3\nvar x = 1\n"));
}

test "load: a statement outside every nodebug function refuses the entry, a declaration does not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stray = "list.txt: src/p/b.mojo listed as unmeasured but line 5 is a statement outside every @always_inline(\"nodebug\") function: kcov can record it; test it instead";
    try t.expectEqualStrings(stray, try listed(a, NB ++ "def f() -> Int:\n    return 1\n\ncomptime if True:\n    print(\"x\")\n"));
    try t.expectEqualStrings("list.txt: src/p/b.mojo listed as unmeasured but line 5 is a statement outside every @always_inline(\"nodebug\") function: kcov can record it; test it instead", try listed(a, NB ++ "def f() -> Int:\n    return 1\n\nfor i in range(3):\n    print(i)\n"));
    try t.expectEqualStrings("accepted", try listed(a, "from std.sys import size_of\nalias N = 3\ncomptime M = 4\n\n" ++ NB ++ "def f() -> Int:\n    return 1\n"));
    try t.expectEqualStrings("accepted", try listed(a, "struct S:\n    var x: Int\n\n    " ++ "@always_inline(\"nodebug\")\n    def m(self) -> Int:\n        return 1\n"));
}

test "load: a function value made inside a nodebug function refuses the entry, a nested nodebug function does not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const made = "list.txt: src/p/b.mojo listed as unmeasured but line 3 makes a function value inside a function, which may be run without a record: kcov can record it; test it instead";
    try t.expectEqualStrings(made, try listed(a, NB ++ "def f(x: Int) -> Int:\n    var g = fn(y: Int) -> Int: return y\n    return g(x)\n"));
    try t.expectEqualStrings("accepted", try listed(a, NB ++ "def f(x: Int) -> Int:\n    " ++ NB ++ "    def g(y: Int) -> Int:\n        return y\n    return g(x)\n"));
}

// ---- the step as cov_summary runs it: the figure, with and without the file ----

const rep_a =
    \\<class name="a" filename="pkg/src/p/a.mojo">
    \\<line number="3" hits="1"/>
    \\<line number="4" hits="0"/>
    \\</class>
    \\
;

const inlined_src = "@always_inline(\"nodebug\")\ndef f(x: Int) -> Int:\n    return x\n";

fn fileOf(_: std.mem.Allocator, p: []const u8) []const u8 {
    if (std.mem.eql(u8, p, "list.txt")) return "src/p/b.mojo  every function is always_inline nodebug\n";
    if (std.mem.eql(u8, p, "stale.txt")) return "src/p/a.mojo  inlined\n";
    if (std.mem.eql(u8, p, "none.txt")) return "# nothing\n";
    return inlined_src;
}

fn noStatements(_: []const u8) bool {
    return false;
}

/// The summary text of one report and `expect`, with `list` (a name `fileOf` knows) or none.
fn summary(a: std.mem.Allocator, list: ?[]const u8) !union(enum) { text: []const u8, refused: []const u8 } {
    var files: std.StringArrayHashMapUnmanaged(std.AutoArrayHashMapUnmanaged(usize, bool)) = .empty;
    try S.addReport(a, &files, rep_a);
    var exp: []const []const u8 = &expect;
    var listing: []const u8 = "";
    const srcs = [_][2][]const u8{ .{ lib_a, "a" }, .{ lib_b, "b" } };
    if (list) |l| switch (try U.load(a, "pkg", l, &expect, files.keys(), &srcs, fileOf, noStatements)) {
        .refused => |m| return .{ .refused = m },
        .ok => |ok| {
            exp = ok.expect;
            listing = ok.listing;
        },
    };
    const rows = try S.summarize(a, &files);
    if (S.missing(rows, exp)) |m| return .{ .refused = try std.fmt.allocPrint(a, "{s} is in no report", .{m}) };
    return .{ .text = try std.mem.concat(a, u8, &.{ try S.renderScoped(a, rows, exp, "", true), listing }) };
}

test "the figure: the unmeasured source is in no total and is listed; without the file the same source is refused as today" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("pkg/src/p/b.mojo is in no report", (try summary(a, null)).refused);
    const ok = (try summary(a, "list.txt")).text;
    try t.expectEqualStrings("pkg/src/p/a.mojo 1/2 50%\ntotal 1/2 50%\nunmeasured: pkg/src/p/b.mojo: every function is always_inline nodebug\nunmeasured total 1 files: left out of the line and branch totals and the floors\n", ok);
    // A file that lists nothing leaves the refusal of the unlisted source as it was.
    try t.expectEqualStrings("pkg/src/p/b.mojo is in no report", (try summary(a, "none.txt")).refused);
    // A stale entry fails the step, whatever else is in order.
    try t.expectEqualStrings("stale.txt: src/p/a.mojo listed as unmeasured but measured: remove the entry", (try summary(a, "stale.txt")).refused);
}

// ---- every allocation may fail, and fails as OutOfMemory (the rules of this repo's other parsers) ----

fn oomLoad(a: std.mem.Allocator, list: []const u8) !void {
    const Read = struct {
        var text: []const u8 = "";
        fn read(_: std.mem.Allocator, p: []const u8) []const u8 {
            return if (std.mem.eql(u8, p, "list.txt")) text else inlined_src;
        }
    };
    Read.text = list;
    const srcs = [_][2][]const u8{ .{ lib_a, "a" }, .{ lib_b, "b" } };
    switch (try U.load(a, "pkg", "list.txt", &expect, &.{lib_a}, &srcs, Read.read, noStatements)) {
        .ok => |ok| try t.expectEqual(@as(usize, 1), ok.expect.len),
        .refused => return error.Refused,
    }
}

test "load: every allocation of an accepted list, and of each refused one, may fail and fails as OutOfMemory" {
    const lists = [_][]const u8{
        "src/p/b.mojo\twhy\n", // accepted
        "src/p/b.mojo\n", // no reason
        "src/p/b.mojo\tone\nsrc/p/b.mojo\ttwo\n", // duplicate
        "src/p/a.mojo\tstale\n", // measured
        "src/p/gone.mojo\twhy\n", // not a library source
    };
    for (lists, 0..) |list, which| {
        var i: usize = 0;
        var finished = false;
        while (i < 400 and !finished) : (i += 1) {
            var arena = std.heap.ArenaAllocator.init(t.allocator);
            defer arena.deinit();
            var fa = t.FailingAllocator.init(arena.allocator(), .{ .fail_index = i });
            if (oomLoad(fa.allocator(), list)) |_| {
                finished = true;
            } else |e| switch (e) {
                error.OutOfMemory => {},
                error.Refused => finished = true,
                else => return e,
            }
        }
        try t.expect(finished);
        // Only the first list is accepted; the others end in a refusal.
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        if (which == 0) try oomLoad(arena.allocator(), list) else try t.expectError(error.Refused, oomLoad(arena.allocator(), list));
    }
}
