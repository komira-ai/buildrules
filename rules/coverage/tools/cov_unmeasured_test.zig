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
    try t.expectEqualStrings("accepted", try listed(a, "@deprecated\n" ++ NB ++ "@register_passable(\"trivial\")\ndef f(x: Int) -> Int:\n    return x\n"));
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

const P = "@always_inline(\"nodebug\")\ndef a(): return 1\n";

const source_cases = [_]Case{
    .{ .name = "comment_nodebug", .src = "# @always_inline(\"nodebug\")\ndef f(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "docstring_nodebug", .src = "\"\"\"\n@always_inline(\"nodebug\")\n\"\"\"\ndef f(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "string_var_nodebug", .src = "comptime S = \"@always_inline(\\\"nodebug\\\")\"\ndef f(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "decor_before_struct", .src = "@always_inline(\"nodebug\")\nstruct S:\n    var x: Int\n\ndef f(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "decor_before_comptime", .src = "@always_inline(\"nodebug\")\ncomptime X = 1\ndef f(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "nested_plain", .src = "@always_inline(\"nodebug\")\ndef f(x: Int) -> Int:\n    def g(y: Int) -> Int:\n        return y\n    return g(x)\n", .accept = false },
    .{ .name = "nested_nodebug_in_plain", .src = "def f(x: Int) -> Int:\n    @always_inline(\"nodebug\")\n    def g(y: Int) -> Int:\n        return y\n    return g(x)\n", .accept = false },
    .{ .name = "blank_between", .src = "@always_inline(\"nodebug\")\n\ndef f(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "comment_between", .src = "@always_inline(\"nodebug\")\n# hi\ndef f(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "inline_body_plain", .src = "def f(x: Int) -> Int: return x\n", .accept = false },
    .{ .name = "inline_body_after_nodebug", .src = "@always_inline(\"nodebug\")\ndef f(x: Int) -> Int: return x\ndef g(x: Int) -> Int: return x\n", .accept = false },
    .{ .name = "trailing_comment_ok", .src = "@always_inline(\"nodebug\")  # why\ndef f(x: Int) -> Int:\n    return x\n", .accept = true },
    .{ .name = "crlf_ok", .src = "@always_inline(\"nodebug\")\r\ndef f(x: Int) -> Int:\r\n    return x\r\n", .accept = true },
    .{ .name = "crlf_plain", .src = "def f(x: Int) -> Int:\r\n    return x\r\n", .accept = false },
    .{ .name = "paren_in_comment_sig", .src = "@always_inline(\"nodebug\")\ndef f(  # (\n    x: Int,\n) -> Int:\n    return x\n\ndef g(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "paren_in_string_default", .src = "@always_inline(\"nodebug\")\ndef f(x: String = \"(\") -> Int:\n    return 1\n\ndef g(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "brace_default", .src = "@always_inline(\"nodebug\")\ndef f(x: Int = 1) -> Int:\n    return 1\n\ndef g(x: Dict[Int, Int] = {1: 2}) -> Int:\n    return 1\n", .accept = false },
    .{ .name = "tab_def", .src = "@always_inline(\"nodebug\")\ndef f(x: Int) -> Int:\n    return x\ndef\tg(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "double_space_def", .src = "@always_inline(\"nodebug\")\ndef f(x: Int) -> Int:\n    return x\ndef   g(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "indented_def_in_comptime_if", .src = "@always_inline(\"nodebug\")\ndef f(x: Int) -> Int:\n    return x\ncomptime if True:\n    def g(x: Int) -> Int:\n        return x\n", .accept = false },
    .{ .name = "decorated_tab_indent", .src = "struct S:\n\t@always_inline(\"nodebug\")\n\tdef m(self) -> Int:\n\t\treturn 1\n\tdef n(self) -> Int:\n\t\treturn 2\n", .accept = false },
    .{ .name = "raises_sig", .src = "@always_inline(\"nodebug\")\ndef f(x: Int) raises -> Int:\n    return x\ndef g(x: Int) raises -> Int:\n    raise Error(\"x\")\n", .accept = false },
    .{ .name = "body_ellipsis_with_code", .src = "def f(x: Int) -> Int:\n    ...\n    return x\n", .accept = false },
    .{ .name = "trait_plain_nobody_only", .src = "@always_inline(\"nodebug\")\ndef f() -> Int:\n    return 1\ndef g(x: Int):\n    ...\n", .accept = true },
    .{ .name = "statements_outside_fn", .src = "@always_inline(\"nodebug\")\ndef f() -> Int:\n    return 1\n\ncomptime if True:\n    print(\"x\")\n", .accept = false },
    .{ .name = "decor_same_line_def", .src = "@always_inline(\"nodebug\") def f(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "nodebug_with_extra_arg", .src = "@always_inline(\"nodebug\", \"x\")\ndef f(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "nodebug_single_quote", .src = "@always_inline('nodebug')\ndef f(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "nodebug_upper", .src = "@always_inline(\"NODEBUG\")\ndef f(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "nodebug_wrong_deco", .src = "@always_inline_x(\"nodebug\")\ndef f(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "nodebug_other_deco_with_arg", .src = "@foo(\"nodebug\")\ndef f(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "unlisted_decorator_beside_nodebug", .src = "@always_inline(\"nodebug\")\n@foo\ndef f(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "lambda_like_fn_value", .src = "@always_inline(\"nodebug\")\ndef f(x: Int) -> Int:\n    var g = fn(y: Int) -> Int: return y\n    return g(x)\n", .accept = false },
    .{ .name = "empty", .src = "", .accept = false },
    .{ .name = "only_comment", .src = "# nothing\n", .accept = false },
    .{ .name = "struct_init_plain", .src = "@always_inline(\"nodebug\")\ndef f() -> Int:\n    return 1\nstruct S:\n    def __init__(out self):\n        pass\n", .accept = false },
    .{ .name = "multiline_string_def_hides", .src = "@always_inline(\"nodebug\")\ndef f() -> Int:\n    return 1\n\ncomptime D = \"\"\"\ndef g(x):\n  return x\n\"\"\"\n", .accept = true },
    .{ .name = "def_after_unterminated_docstring_quote", .src = "@always_inline(\"nodebug\")\ndef f() -> Int:\n    \"\"\"doc\"\"\"\n    return 1\ndef g() -> Int:\n    return 2\n", .accept = false },
    .{ .name = "single_line_triple_then_def", .src = "comptime S = \"\"\"a\"\"\"\ndef g() -> Int:\n    return 2\n", .accept = false },
    .{ .name = "raw_string_prefix", .src = "comptime S = r\"\\\"\ndef g() -> Int:\n    return 2\n", .accept = false },
    .{ .name = "apostrophe_in_comment", .src = "@always_inline(\"nodebug\")\ndef f() -> Int:\n    return 1  # it's\ndef g() -> Int:\n    return 2\n", .accept = false },
    .{ .name = "char_quote_str", .src = "@always_inline(\"nodebug\")\ndef f() -> String:\n    return \"'\"\ndef g() -> Int:\n    return 2\n", .accept = false },
    .{ .name = "backslash_quote_str", .src = "@always_inline(\"nodebug\")\ndef f() -> String:\n    return \"\\\\\"\ndef g() -> Int:\n    return 2\n", .accept = false },
};

const D1 = NB ++ "def a(): return 1\n";

const reviewed_cases = [_]Case{
    .{ .name = "01_plain_fn_only", .src = "def f(): return 1\n", .accept = false },
    .{ .name = "02_plain_method_beside_nodebug", .src = D1 ++ "struct S:\n    def m(self): return 2\n", .accept = false },
    .{ .name = "03_plain_init", .src = "struct S:\n    var x: Int\n    def __init__(out self): self.x = 1\n    " ++ NB ++ "    def g(self): return 1\n", .accept = false },
    .{ .name = "04_plain_del", .src = D1 ++ "struct S:\n    def __del__(deinit self): print(1)\n", .accept = false },
    .{ .name = "05_stacked_staticmethod_is_refused", .src = NB ++ "@staticmethod\ndef a(): return 1\n", .accept = false },
    .{ .name = "06_single_quote_nodebug", .src = "@always_inline('nodebug')\ndef a(): return 1\n", .accept = false },
    .{ .name = "07_spacing_nodebug", .src = "@always_inline ( \"nodebug\" )\ndef a(): return 1\n", .accept = true },
    .{ .name = "08_multi_line_sig", .src = NB ++ "def a(\n    x: Int,\n) -> Int:\n    return x\n", .accept = true },
    .{ .name = "09_semicolon_in_body", .src = NB ++ "def a() -> Int:\n    return 1; print(2)\n", .accept = false },
    .{ .name = "10_semi_after_alias", .src = D1 ++ "alias N = 3; print(N)\n", .accept = false },
    .{ .name = "11_semi_after_var", .src = D1 ++ "var g: Int; print(g)\n", .accept = false },
    .{ .name = "12_semi_after_string", .src = D1 ++ "\"x\"; print(1)\n", .accept = false },
    .{ .name = "13_backslash_def", .src = D1 ++ "def \\\n b(x): return x + 1\n", .accept = false },
    .{ .name = "14_string_fn_in_body", .src = NB ++ "def a() -> String:\n    return \"fn x\"\n", .accept = true },
    .{ .name = "15_nested_struct_plain_method_in_fn", .src = NB ++ "def a():\n    struct T:\n        def m(self): return 1\n    return 1\n", .accept = false },
    .{ .name = "16_comptime_var", .src = D1 ++ "comptime var x = 1\n", .accept = false },
    .{ .name = "17_global_var_call", .src = D1 ++ "var g = a()\n", .accept = false },
    .{ .name = "18_field_default_call", .src = "struct S:\n    var x: Int = side()\n    " ++ NB ++ "    def a(self): return 1\n", .accept = false },
    .{ .name = "19_extension", .src = D1 ++ "extension Int:\n    def m(self): return 1\n", .accept = false },
    .{ .name = "20_tab_nodebug_method", .src = "struct S:\n\t@always_inline(\"nodebug\")\n\tdef m(self): return 1\n", .accept = true },
    .{ .name = "21_tab_def_space_stray", .src = "struct S:\n\t@always_inline(\"nodebug\")\n\tdef m(self): return 1\n    comptime if True:\n        print(1)\n", .accept = false },
    .{ .name = "22_crlf_ok", .src = "@always_inline(\"nodebug\")\r\ndef a() -> Int:\r\n    return 1\r\n", .accept = true },
    .{ .name = "23_crlf_stray", .src = "@always_inline(\"nodebug\")\r\ndef a() -> Int:\r\n    return 1\r\nprint(1)\r\n", .accept = false },
    .{ .name = "24_lambda_one_line_body", .src = NB ++ "def a(x: Int) -> Int: return (lambda y: y)(x)\n", .accept = false },
    .{ .name = "25_fn_value_on_sig_close_line", .src = NB ++ "def a(\n    x: Int,\n) -> Int: return (fn(y: Int) -> Int: return y)(x)\n", .accept = false },
    .{ .name = "26_stray_after_docstring_close", .src = D1 ++ "\"\"\"\ndoc\n\"\"\"; print(1)\n", .accept = false },
    .{ .name = "27_top_level_call", .src = D1 ++ "a()\n", .accept = false },
    .{ .name = "28_string_method_call", .src = D1 ++ "\"x\".format(a())\n", .accept = false },
    .{ .name = "29_one_line_struct_method", .src = D1 ++ "struct S: def m(self): return 1\n", .accept = false },
    .{ .name = "30_nested_plain_def_in_nodebug", .src = NB ++ "def a():\n    def g(): return 1\n    return g()\n", .accept = false },
    .{ .name = "31_backslash_call", .src = D1 ++ "print( \\\n 1)\n", .accept = false },
    .{ .name = "32_comptime_if_else", .src = D1 ++ "comptime if True:\n    pass\nelse:\n    pass\n", .accept = false },
    .{ .name = "33_comptime_assert_is_refused", .src = D1 ++ "comptime assert True\n", .accept = false },
    .{ .name = "34_imports", .src = "from std.sys import size_of\nimport std.os\n" ++ D1, .accept = true },
    .{ .name = "35_import_semi_call", .src = "import std.os; print(1)\n" ++ D1, .accept = false },
    .{ .name = "36_lone_cr", .src = "@always_inline(\"nodebug\")\rdef a(): return 1\rprint(1)\r", .accept = false },
    .{ .name = "37_blank_between_decorator_and_def", .src = "@always_inline(\"nodebug\")\n\ndef a(): return 1\n", .accept = false },
    .{ .name = "38_comment_between_decorator_and_def", .src = "@always_inline(\"nodebug\")\n# c\ndef a(): return 1\n", .accept = false },
    .{ .name = "39_trait_bodiless_nodebug_default", .src = "trait T:\n    def r(self): ...\n    " ++ NB ++ "    def d(self): return 1\n", .accept = true },
    .{ .name = "40_docstring_raises", .src = NB ++ "def a() raises -> Int:\n    \"\"\"doc\"\"\"\n    return 1\n", .accept = true },
    .{ .name = "41_var_call_multi_line", .src = D1 ++ "var g = foo(\n  1)\n", .accept = false },
    .{ .name = "42_undef_in_body", .src = NB ++ "def a() -> String:\n    return \"undef\"\n", .accept = true },
    .{ .name = "43_triple_string_call", .src = D1 ++ "'''x''' + a()\n", .accept = false },
    .{ .name = "44_for", .src = D1 ++ "for i in range(2): a()\n", .accept = false },
    .{ .name = "45_parameter_for", .src = D1 ++ "@parameter\nfor i in range(2): a()\n", .accept = false },
    .{ .name = "46_decorator_semi", .src = D1 ++ "@foo; print(1)\n", .accept = false },
    .{ .name = "47_struct_semi", .src = D1 ++ "struct S: pass; print(1)\n", .accept = false },
    .{ .name = "48_def_tab_name", .src = D1 ++ "def\tb(): return 2\n", .accept = false },
    .{ .name = "49_fn_backslash_name", .src = D1 ++ "fn \\\n  b(): return 2\n", .accept = false },
    .{ .name = "50_unicode_ident_call_starting_with_import", .src = D1 ++ "import\xC3\xA9(1)\n", .accept = false },
    .{ .name = "51_import_nbsp_call", .src = D1 ++ "import\xC2\xA0side()\n", .accept = false },
    .{ .name = "52_lambda_inside_f_string_in_body", .src = NB ++ "def a() -> String:\n    return f\"{(lambda y: y)(1)}\"\n", .accept = false },
    .{ .name = "53_alias_subscript_no_paren", .src = D1 ++ "alias X = Foo[1]\n", .accept = true },
    .{ .name = "54_alias_call_in", .src = D1 ++ "alias X = Foo[side()]\n", .accept = false },
    .{ .name = "55_struct_header_trailing_comment", .src = "struct S: # note\n    var x: Int\n    " ++ NB ++ "    def a(self): return 1\n", .accept = true },
    .{ .name = "56_decorator_non_string_arg", .src = D1 ++ "@register_passable(x)\nstruct S:\n    var x: Int\n", .accept = false },
    .{ .name = "57_deprecated_two_args_is_refused", .src = D1 ++ "@deprecated(\"a\", \"b\")\nstruct S:\n    var x: Int\n", .accept = false },
    .{ .name = "58_zero_width_after_struct_colon", .src = D1 ++ "struct S:\xE2\x80\x8B\n    var x: Int\n", .accept = false },
    .{ .name = "59_semicolon_inside_string_in_body", .src = NB ++ "def a() -> String:\n    return \"a\\\" ; b\"\n", .accept = true },
    .{ .name = "60_raw_string_backslash_end", .src = NB ++ "def a(): return r\"\\\"\nprint(1)\n", .accept = false },
    .{ .name = "61_docstring_plus_call", .src = D1 ++ "\"doc\" + side()\n", .accept = false },
    .{ .name = "62_ellipsis_body_then_code", .src = D1 ++ "def f():\n    ...\n    print(1)\n", .accept = false },
    .{ .name = "63_inline_ellipsis_then_code", .src = D1 ++ "def f(): ...\nprint(1)\n", .accept = false },
    .{ .name = "64_ellipsis_def_default_call", .src = D1 ++ "def f(x: Int = side()): ...\n", .accept = false },
    .{ .name = "65_trait_plain_default_body", .src = D1 ++ "trait T:\n    def d(self): return 1\n", .accept = false },
    .{ .name = "66_field_walrus", .src = D1 ++ "struct S:\n    var x: Int := 3\n", .accept = false },
    .{ .name = "67_field_default", .src = D1 ++ "struct S:\n    var x: Int = 3\n", .accept = false },
    .{ .name = "68_multi_line_alias_list", .src = D1 ++ "alias X = [\n  1,\n  2\n]\n", .accept = true },
    .{ .name = "69_bracket_never_closes", .src = D1 ++ "alias X = [1\n", .accept = false },
    .{ .name = "70_import_comma_call", .src = D1 ++ "import x, side()\n", .accept = false },
    .{ .name = "71_fn_typed_parameter_is_refused", .src = NB ++ "def a(f: fn(Int) -> Int, x: Int) -> Int:\n    return f(x)\n", .accept = false },
    .{ .name = "72_empty_struct_body_is_refused", .src = D1 ++ "struct S:\n    ...\n", .accept = false },
    .{ .name = "73_fieldwise_init_struct", .src = D1 ++ "@fieldwise_init\nstruct S:\n    var x: Int\n", .accept = true },
    .{ .name = "74_comptime_call_after_subscript", .src = D1 ++ "comptime X = Foo[1](2)\n", .accept = false },
    .{ .name = "75_alias_operator", .src = D1 ++ "alias X = a + b\n", .accept = true },
    .{ .name = "76_nodebug_deprecated_stacked", .src = NB ++ "@deprecated\ndef a(): return 1\n", .accept = true },
    .{ .name = "77_name_containing_fn", .src = NB ++ "def fnx(): return 1\n", .accept = true },
    .{ .name = "78_nested_nodebug_in_body", .src = NB ++ "def a():\n    " ++ NB ++ "    def g(): return 1\n    return g()\n", .accept = true },
    .{ .name = "79_top_level_field", .src = D1 ++ "var x: Int\n", .accept = true },
    .{ .name = "80_pass", .src = D1 ++ "pass\n", .accept = true },
    .{ .name = "81_implicit_string_concat_docstring_is_refused", .src = D1 ++ "\"a\" \"b\"\n", .accept = false },
    .{ .name = "82_over_indented_stray_after_body", .src = NB ++ "def a() -> Int:\n    return 1\n  print(2)\n", .accept = false },
    .{ .name = "83_stray_after_nested_nodebug_at_same_indent_as_outer_body", .src = NB ++ "def a():\n    return 1\n    print(2)\nprint(3)\n", .accept = false },
    .{ .name = "84_decorator_fieldwise_init_on_def", .src = "@fieldwise_init\ndef a(): return 1\n" ++ D1, .accept = false },
    .{ .name = "85_nodebug_on_struct_then_plain_method", .src = NB ++ "struct S:\n    def m(self): return 1\n" ++ D1, .accept = false },
    .{ .name = "86_form_feed_import", .src = D1 ++ "import\x0cx\n", .accept = true },
    .{ .name = "87_tab_inside_alias", .src = D1 ++ "alias\tX = 1\n", .accept = true },
    .{ .name = "88_comment_only_trailing_no_newline", .src = NB ++ "def a(): return 1 # c", .accept = true },
    .{ .name = "89_dedented_stmt_in_struct_after_method", .src = "struct S:\n    " ++ NB ++ "    def m(self): return 1\n    print(1)\n", .accept = false },
    .{ .name = "90_call_in_body_of_nodebug_via_decorator_arg", .src = D1 ++ "@foo(side())\nstruct S:\n    var x: Int\n", .accept = false },
};

const joined_cases = [_]Case{
    .{ .name = "semicolon_after_alias", .src = P ++ "alias N = 3; print(N)\n", .accept = false },
    .{ .name = "semicolon_after_var", .src = P ++ "var g = 1; print(g)\n", .accept = false },
    .{ .name = "semicolon_after_docstring", .src = P ++ "\"x\"; print(1)\n", .accept = false },
    .{ .name = "semicolon_after_decorator", .src = P ++ "@foo; print(1)\n", .accept = false },
    .{ .name = "semicolon_after_listed_decorator", .src = P ++ "@value; print(1)\n", .accept = false },
    .{ .name = "semicolon_after_struct_header", .src = P ++ "struct S: pass; print(1)\n", .accept = false },
    .{ .name = "semicolon_after_import", .src = P ++ "import os; print(1)\n", .accept = false },
    .{ .name = "semicolon_in_body", .src = P ++ "@always_inline(\"nodebug\")\ndef b():\n    var x = 1; return x\n", .accept = false },
    .{ .name = "semicolon_in_header_line", .src = P ++ "@always_inline(\"nodebug\")\ndef b(): var x = 1; return x\n", .accept = false },
    .{ .name = "semicolon_in_comment_is_a_comment", .src = P ++ "alias N = 3  # a; b\n", .accept = true },
    .{ .name = "semicolon_in_string_is_a_string", .src = P ++ "alias S = \";\"\n", .accept = true },
    .{ .name = "def_backslash_continued_name", .src = P ++ "def \\\n b(x): return x + 1\n", .accept = false },
    .{ .name = "fn_backslash_continued_name", .src = P ++ "fn \\\n b(x): return x + 1\n", .accept = false },
    .{ .name = "nodebug_def_backslash_continued_name", .src = P ++ "@always_inline(\"nodebug\")\ndef \\\n b(x): return x + 1\n", .accept = false },
    .{ .name = "backslash_in_constant", .src = P ++ "alias N = 1 + \\\n 2\n", .accept = false },
    .{ .name = "backslash_inside_string_is_a_string", .src = P ++ "alias S = \"a\\\\nb\"\n", .accept = true },
    .{ .name = "lambda_on_signature_line", .src = P ++ "@always_inline(\"nodebug\")\ndef b(x: Int) -> Int: return (lambda y: y)(x)\n", .accept = false },
    .{ .name = "lambda_after_multiline_signature", .src = P ++ "@always_inline(\"nodebug\")\ndef b(\n    x: Int,\n) -> Int: return (lambda y: y)(x)\n", .accept = false },
    .{ .name = "function_value_after_closing_bracket", .src = P ++ "@always_inline(\"nodebug\")\ndef b(\n    x: Int,\n) -> Int:\n    var g = fn(y: Int) -> Int: return y\n    return g(x)\n", .accept = false },
    .{ .name = "lambda_in_body", .src = P ++ "@always_inline(\"nodebug\")\ndef b(x: Int) -> Int:\n    var g = lambda y: y\n    return g(x)\n", .accept = false },
    .{ .name = "function_type_in_signature", .src = P ++ "@always_inline(\"nodebug\")\ndef b(f: fn(Int) -> Int) -> Int:\n    return 1\n", .accept = false },
    .{ .name = "plain_nested_def_in_body", .src = P ++ "@always_inline(\"nodebug\")\ndef b(x: Int) -> Int:\n    def g(y: Int) -> Int:\n        return y\n    return g(x)\n", .accept = false },
    .{ .name = "nested_nodebug_def_in_body", .src = P ++ "@always_inline(\"nodebug\")\ndef b(x: Int) -> Int:\n    @always_inline(\"nodebug\")\n    def g(y: Int) -> Int:\n        return y\n    return g(x)\n", .accept = true },
    .{ .name = "nested_def_after_other_decorator", .src = P ++ "@always_inline(\"nodebug\")\ndef b(x: Int) -> Int:\n    @parameter\n    def g(y: Int) -> Int:\n        return y\n    return g(x)\n", .accept = false },
    .{ .name = "triple_string_closes_then_semicolon", .src = P ++ "\"\"\"doc\n\"\"\"; print(1)\n", .accept = false },
    .{ .name = "triple_string_closes_then_call", .src = P ++ "\"\"\"doc\n\"\"\" + a()\n", .accept = false },
    .{ .name = "quote_led_call", .src = P ++ "\"x\".format(a())\n", .accept = false },
    .{ .name = "triple_quoted_concatenation", .src = P ++ "'''x''' + a()\n", .accept = false },
    .{ .name = "variable_initialized_by_call", .src = P ++ "var g = a()\n", .accept = false },
    .{ .name = "variable_initialized_by_multiline_call", .src = P ++ "var g = foo(\n    1)\n", .accept = false },
    .{ .name = "field_initialized_by_call", .src = P ++ "struct S:\n    var x: Int = side()\n", .accept = false },
    .{ .name = "field_initialized_by_literal", .src = P ++ "struct S:\n    var x: Int = 1\n", .accept = false },
    .{ .name = "field_without_type", .src = P ++ "struct S:\n    var x\n", .accept = false },
    .{ .name = "one_line_struct_with_method", .src = P ++ "struct S: def m(self): return 1\n", .accept = false },
    .{ .name = "one_line_struct_with_pass", .src = P ++ "struct S: pass\n", .accept = false },
    .{ .name = "constant_with_call", .src = P ++ "alias N = f(1)\n", .accept = false },
    .{ .name = "constant_with_lambda", .src = P ++ "alias N = lambda x: x\n", .accept = false },
    .{ .name = "comptime_if_block", .src = P ++ "comptime if True:\n    print(\"x\")\n", .accept = false },
    .{ .name = "comptime_for_block", .src = P ++ "comptime for i in range(3):\n    print(i)\n", .accept = false },
    .{ .name = "top_level_call", .src = P ++ "print(1)\n", .accept = false },
    .{ .name = "top_level_assignment", .src = P ++ "x = 1\n", .accept = false },
    .{ .name = "top_level_if", .src = P ++ "if True:\n    pass\n", .accept = false },
    .{ .name = "top_level_for", .src = P ++ "for i in range(3):\n    print(i)\n", .accept = false },
    .{ .name = "top_level_return_value", .src = P ++ "return 1\n", .accept = false },
    .{ .name = "ellipsis_alone", .src = P ++ "...\n", .accept = false },
    .{ .name = "plain_def_with_body", .src = P ++ "def b(x: Int) -> Int:\n    return x\n", .accept = false },
    .{ .name = "unlisted_decorator_on_nodebug_def", .src = P ++ "@staticmethod\n@always_inline(\"nodebug\")\ndef b() -> Int:\n    return 1\n", .accept = false },
    .{ .name = "parameter_decorator_outside_body", .src = P ++ "@parameter\n@always_inline(\"nodebug\")\ndef b() -> Int:\n    return 1\n", .accept = false },
    .{ .name = "unterminated_bracket", .src = P ++ "alias N = [1,\n", .accept = false },
    .{ .name = "unterminated_string", .src = P ++ "alias S = \"abc\n", .accept = false },
    .{ .name = "struct_header_with_body_after_colon", .src = P ++ "struct S: var x: Int\n", .accept = false },
    .{ .name = "trait_header_with_statement_after_colon", .src = P ++ "trait T: pass\n", .accept = false },
    .{ .name = "bodiless_def_with_code_after_ellipsis", .src = P ++ "def b(): ...; print(1)\n", .accept = false },
    .{ .name = "bodiless_def_then_code_at_same_depth", .src = P ++ "def b():\n    ...\n    print(1)\n", .accept = false },
    .{ .name = "imports_and_constants", .src = P ++ "from std.sys import size_of\nimport os\nalias N = 3\ncomptime M: Int = 4\nalias T = List[Int]\n", .accept = true },
    .{ .name = "struct_fields_docstring_pass", .src = P ++ "struct S:\n    \"\"\"doc.\"\"\"\n    var x: Int\n    var y: Optional[Int]\n", .accept = true },
    .{ .name = "struct_with_pass", .src = P ++ "struct S:\n    pass\n", .accept = true },
    .{ .name = "struct_header_with_parameters_and_bases", .src = P ++ "struct S[T: AnyType](Copyable):\n    var x: T\n", .accept = true },
    .{ .name = "bodiless_def_inline_ellipsis", .src = P ++ "def b(): ...\n", .accept = true },
    .{ .name = "bodiless_def_ellipsis_next_line", .src = P ++ "def b():\n    ...\n", .accept = true },
    .{ .name = "trait_requirements", .src = P ++ "trait T:\n    def f(self) -> Int: ...\n    def g(self):\n        ...\n", .accept = true },
    .{ .name = "fieldwise_init_struct_is_accepted", .src = P ++ "@fieldwise_init\nstruct P:\n    var x: Int\n    var y: Int\n", .accept = true },
    .{ .name = "value_struct_is_accepted", .src = P ++ "@value\nstruct P:\n    var x: Int\n", .accept = true },
    .{ .name = "register_passable_struct_is_accepted", .src = P ++ "@register_passable(\"trivial\")\nstruct P:\n    var x: Int\n", .accept = true },
    .{ .name = "struct_with_nodebug_method", .src = P ++ "struct S:\n    var x: Int\n\n    @always_inline(\"nodebug\")\n    def m(self) -> Int:\n        return 1\n", .accept = true },
    .{ .name = "single_quoted_nodebug_is_refused", .src = P ++ "@always_inline('nodebug')\ndef b() -> Int:\n    return 1\n", .accept = false },
    .{ .name = "spaced_nodebug_decorator", .src = P ++ "@always_inline( \"nodebug\" )\ndef b() -> Int:\n    return 1\n", .accept = true },
    .{ .name = "multiline_nodebug_signature", .src = P ++ "@always_inline(\"nodebug\")\ndef b(\n    x: Int,\n    y: Int,\n) -> Int:\n    return x + y\n", .accept = true },
    .{ .name = "comments_and_blank_lines", .src = P ++ "# a comment\n\nalias N = 3  # trailing\n\n# another\n", .accept = true },
    .{ .name = "multiline_docstring_with_code_words", .src = P ++ "\"\"\"\nprint(1); x = a()\n\\ \n\"\"\"\n", .accept = true },
};

const Case = struct { name: []const u8, src: []const u8, accept: bool };

/// Runs every case of `cases` and fails, naming each that went the wrong way, so one run shows all of them.
fn runCases(cases: []const Case) !void {
    var wrong: usize = 0;
    for (cases) |c| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const r = try listed(arena.allocator(), c.src);
        const accepted = std.mem.eql(u8, r, "accepted");
        if (accepted != c.accept) {
            wrong += 1;
            std.debug.print("case {s}: {s}, expected {s}: {s}\n", .{ c.name, if (accepted) "accepted" else "refused", if (c.accept) "accepted" else "refused", r });
        }
    }
    try t.expectEqual(@as(usize, 0), wrong);
}

// Sources of the nodebug-only rule. The rule outside the body of every @always_inline("nodebug") function: no `;` and no backslash anywhere; each statement is an
// import, an alias or comptime constant without a call, a struct or trait header with nothing after its colon, a field without a value, a listed decorator
// (@always_inline("nodebug"), @fieldwise_init, @value, @register_passable, @deprecated), a docstring, a def whose whole body is `...`, or pass. Inside a body no
// fn, def or lambda word unless it starts a nested nodebug function the lister found. A struct with @fieldwise_init or @value is accepted: the methods the
// compiler writes for it have no source line for kcov to record.
test "load: shapes of source a test could reach outside the nodebug functions are refused, and the declarations beside them are accepted" {
    try runCases(&source_cases);
}

test "load: statements joined to a declaration, backslash continuations, function values and lines that start inside a string are refused" {
    try runCases(&joined_cases);
}

test "load: names, blanks of other scripts, format strings, defaults of bodiless defs, mixed indentation and dedents are held by the reviewed cases" {
    try runCases(&reviewed_cases);
}

test "load: a refusal names the first line of the statement and says which rule it broke" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pre = "list.txt: src/p/b.mojo listed as unmeasured but line ";
    const post = ": kcov can record it; test it instead";
    try t.expectEqualStrings(pre ++ "4 has a `;`" ++ post, try listed(a, P ++ "\nalias N = 3; print(N)\n"));
    try t.expectEqualStrings(pre ++ "3 continues with a backslash or has one outside a string" ++ post, try listed(a, P ++ "alias N = 1 + \\\n 2\n"));
    try t.expectEqualStrings(pre ++ "3 makes a function value inside a nodebug function" ++ post, try listed(a, NB ++ "def b(x: Int) -> Int:\n    var g = lambda y: y\n    return g(x)\n"));
    try t.expectEqualStrings(pre ++ "3 is not one of the declarations a nodebug-only source may hold outside its functions (import, alias or comptime constant without a call, struct or trait header, field without a value, listed decorator, docstring, bodiless def, pass)" ++ post, try listed(a, P ++ "print(1)\n"));
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
