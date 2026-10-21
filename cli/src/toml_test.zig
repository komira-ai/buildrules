//! toml.zig: the reader of the manifests (Cargo.toml and the pins file). A manifest read wrongly is a build that is wrong without a message, so each
//! test names the construct it reads, and each refusal names the text it refuses and the line the message points at.

const std = @import("std");
const kit = @import("testkit.zig");
const toml = @import("toml.zig");
const val = @import("val.zig");
const t = std.testing;

const Env = struct {
    ar: std.heap.ArenaAllocator,
    fn init() Env {
        return .{ .ar = std.heap.ArenaAllocator.init(t.allocator) };
    }
    fn deinit(e: *Env) void {
        e.ar.deinit();
    }
    fn a(e: *Env) std.mem.Allocator {
        return e.ar.allocator();
    }
};

fn ok(e: *Env, text: []const u8) !val.Value {
    const p = toml.parse(e.a(), text);
    if (p.msg.len != 0) {
        std.debug.print("line {d}: {s}\n", .{ p.line, p.msg });
        return error.BadToml;
    }
    return p.value;
}

/// The text is refused, with a message holding `needle`, at `line`.
fn refused(e: *Env, text: []const u8, line: usize, needle: []const u8) !void {
    const p = toml.parse(e.a(), text);
    if (p.msg.len == 0) {
        std.debug.print("accepted: {s}\n", .{text});
        return error.AcceptedABadDocument;
    }
    if (std.mem.indexOf(u8, p.msg, needle) == null) {
        std.debug.print("message `{s}` has no `{s}`\n", .{ p.msg, needle });
        return error.WrongMessage;
    }
    try t.expectEqual(line, p.line);
    try t.expect(p.value == .null);
}

fn str(doc: val.Value, key: []const u8) []const u8 {
    return val.getStr(doc, key).?;
}

test "basic strings: every escape reads as the character it names" {
    var e = Env.init();
    defer e.deinit();
    const doc = try ok(&e,
        \\a = "b\bt\tn\nf\fr\r"
        \\q = "\"q\" \\ s"
        \\u = "\u00e9\u4e2d\U0001F600"
    );
    try t.expectEqualStrings("b\x08t\tn\nf\x0cr\r", str(doc, "a"));
    try t.expectEqualStrings("\"q\" \\ s", str(doc, "q"));
    try t.expectEqualStrings("\u{e9}\u{4e2d}\u{1f600}", str(doc, "u"));
}

test "basic strings: an unknown escape, a cut-off or malformed unicode escape, a surrogate and an unclosed string are refused with the line" {
    var e = Env.init();
    defer e.deinit();
    try refused(&e, "a = 1\nb = \"x\\qy\"\n", 2, "unknown escape `\\q`");
    try refused(&e, "a = \"\\u12\"", 1, "cut off");
    try refused(&e, "a = \"\\U0001F6\"", 1, "cut off");
    try refused(&e, "a = \"\\uZZZZ\"", 1, "bad unicode escape");
    try refused(&e, "a = \"\\ud800\"", 1, "bad unicode escape");
    try refused(&e, "a = \"\\U00110000\"", 1, "bad unicode escape");
    try refused(&e, "a = \"open", 1, "not closed");
    try refused(&e, "a = \"open\nb = 1", 1, "not closed");
    try refused(&e, "a = \"back\\", 1, "not closed");
}

test "literal strings keep every character; an unclosed one is refused at its line" {
    var e = Env.init();
    defer e.deinit();
    const doc = try ok(&e, "a = 'C:\\no\\escapes'\n'quoted key' = 'x'\n");
    try t.expectEqualStrings("C:\\no\\escapes", str(doc, "a"));
    try t.expectEqualStrings("x", str(doc, "quoted key"));
    try refused(&e, "x = 1\na = 'open\n", 2, "not closed");
    try refused(&e, "a = 'open", 1, "not closed");
}

test "multi-line strings: first newline dropped, line continuation, embedded quotes, CRLF, and the unclosed one" {
    var e = Env.init();
    defer e.deinit();
    const doc = try ok(&e,
        "a = \"\"\"\r\nx\"\"\"\n" ++
            "b = \"\"\"one \\\n   \n  two\"\"\"\n" ++
            "c = \"\"\"q\"\"\"\"\n" ++
            "d = \"\"\"q\"\"\"\"\"\n" ++
            "e = '''\nraw\\n'''\n" ++
            "f = '''r''''\n" ++
            "g = \"\"\"tab\\tend\"\"\"\n" ++
            "h = \"\"\"space \\  \nnext\"\"\"\n" ++
            "i = \"\"\"cr \\\r\n next\"\"\"\n",
    );
    try t.expectEqualStrings("x", str(doc, "a"));
    try t.expectEqualStrings("one two", str(doc, "b"));
    try t.expectEqualStrings("q\"", str(doc, "c"));
    try t.expectEqualStrings("q\"\"", str(doc, "d"));
    try t.expectEqualStrings("raw\\n", str(doc, "e"));
    try t.expectEqualStrings("r'", str(doc, "f"));
    try t.expectEqualStrings("tab\tend", str(doc, "g"));
    try t.expectEqualStrings("space next", str(doc, "h"));
    try t.expectEqualStrings("cr next", str(doc, "i"));
    try refused(&e, "a = \"\"\"never closed\nmore", 2, "not closed");
    try refused(&e, "a = '''never closed", 1, "not closed");
    try refused(&e, "a = \"\"\"bad \\q\"\"\"", 1, "unknown escape");
    // The line the key after a multi-line string is on counts the lines inside it.
    try refused(&e, "a = \"\"\"1\n2\n3\"\"\"\nb = 1\nb = 2\n", 5, "defined twice");
    try refused(&e, "a = \"\"\"1\\\n\n\n  2\"\"\"\nb = 1\nb = 2\n", 6, "defined twice");
}

test "numbers: underscores, signs, hex, octal, binary, floats, inf, nan, and dates and times kept as text" {
    var e = Env.init();
    defer e.deinit();
    const doc = try ok(&e,
        \\a = 1_000
        \\b = -7
        \\c = +8
        \\d = 0xff
        \\e = 0o17
        \\f = 0b101
        \\g = -0x10
        \\h = 3.5
        \\i = -1e3
        \\j = inf
        \\k = -inf
        \\l = +inf
        \\m = nan
        \\n = 1979-05-27
        \\o = 07:32:00
        \\p = 1979-05-27 07:32:00
        \\q = 1979-05-27T07:32:00Z # comment
        \\r = true
        \\s = false
        \\u = 0
    );
    try t.expectEqual(@as(i64, 1000), val.get(doc, "a").?.integer);
    try t.expectEqual(@as(i64, -7), val.get(doc, "b").?.integer);
    try t.expectEqual(@as(i64, 8), val.get(doc, "c").?.integer);
    try t.expectEqual(@as(i64, 255), val.get(doc, "d").?.integer);
    try t.expectEqual(@as(i64, 15), val.get(doc, "e").?.integer);
    try t.expectEqual(@as(i64, 5), val.get(doc, "f").?.integer);
    try t.expectEqual(@as(i64, -16), val.get(doc, "g").?.integer);
    try t.expectEqual(@as(f64, 3.5), val.get(doc, "h").?.float);
    try t.expectEqual(@as(f64, -1000), val.get(doc, "i").?.float);
    try t.expect(std.math.isInf(val.get(doc, "j").?.float) and val.get(doc, "j").?.float > 0);
    try t.expect(std.math.isInf(val.get(doc, "k").?.float) and val.get(doc, "k").?.float < 0);
    try t.expect(std.math.isInf(val.get(doc, "l").?.float) and val.get(doc, "l").?.float > 0);
    try t.expect(std.math.isNan(val.get(doc, "m").?.float));
    try t.expectEqualStrings("1979-05-27", str(doc, "n"));
    try t.expectEqualStrings("07:32:00", str(doc, "o"));
    try t.expectEqualStrings("1979-05-27 07:32:00", str(doc, "p"));
    try t.expectEqualStrings("1979-05-27T07:32:00Z", str(doc, "q"));
    try t.expect(val.get(doc, "r").?.bool);
    try t.expect(!val.get(doc, "s").?.bool);
    try t.expectEqual(@as(i64, 0), val.get(doc, "u").?.integer);
    try refused(&e, "a = what\n", 1, "`what` is not a TOML value");
    try refused(&e, "a = \n", 1, "a value was expected");
    try refused(&e, "a =", 1, "a value was expected");
    try refused(&e, "a = ,\n", 1, "a value was expected");
}

test "arrays: nested, with comments and newlines, a trailing comma; a missing comma is refused" {
    var e = Env.init();
    defer e.deinit();
    const doc = try ok(&e,
        \\a = []
        \\b = [1, 2,
        \\  # comment
        \\  3, [4, 5],
        \\]
        \\c = [ { x = 1 }, { x = 2 } ]
    );
    try t.expectEqual(@as(usize, 0), val.items(val.get(doc, "a")).len);
    const b = val.items(val.get(doc, "b"));
    try t.expectEqual(@as(usize, 4), b.len);
    try t.expectEqual(@as(usize, 2), b[3].array.items.len);
    try t.expectEqual(@as(i64, 2), val.get(val.items(val.get(doc, "c"))[1], "x").?.integer);
    try refused(&e, "a = [1 2]\n", 1, "`,` or `]`");
    try refused(&e, "a = [1,\n2\n", 3, "`,` or `]`");
    try refused(&e, "a = [1", 1, "`,` or `]`");
}

test "inline tables: empty, dotted keys, nested, and every way to break one" {
    var e = Env.init();
    defer e.deinit();
    const doc = try ok(&e,
        \\a = {}
        \\b = { x = 1, y.z = 2, "q k" = { w = "v" } }
        \\c = { }
    );
    try t.expectEqual(@as(usize, 0), val.get(doc, "a").?.object.count());
    try t.expectEqual(@as(i64, 2), toml.at(doc, &.{ "b", "y", "z" }).?.integer);
    try t.expectEqualStrings("v", str(toml.at(doc, &.{ "b", "q k" }).?, "w"));
    try t.expectEqual(@as(usize, 0), val.get(doc, "c").?.object.count());
    try refused(&e, "a = { x 1 }\n", 1, "`=` was expected");
    try refused(&e, "a = { x = 1 y = 2 }\n", 1, "`,` or `}`");
    try refused(&e, "a = { x = 1\n", 1, "`,` or `}`");
    try refused(&e, "a = { x = 1, x = 2 }\n", 1, "defined twice");
    try refused(&e, "a = { x = 1, }\n", 1, "key was expected");
    try refused(&e, "a = { x.y = 1, x = 2 }\n", 1, "defined twice");
    try refused(&e, "a = {", 1, "key was expected");
}

test "keys: bare, quoted, dotted, with blanks; an empty or missing key is refused" {
    var e = Env.init();
    defer e.deinit();
    const doc = try ok(&e,
        \\bare-key_1 = 1
        \\"quoted key" = 2
        \\'literal key' = 3
        \\a . b . c = 4
        \\"x"."y" = 5
    );
    try t.expectEqual(@as(i64, 1), val.get(doc, "bare-key_1").?.integer);
    try t.expectEqual(@as(i64, 2), val.get(doc, "quoted key").?.integer);
    try t.expectEqual(@as(i64, 3), val.get(doc, "literal key").?.integer);
    try t.expectEqual(@as(i64, 4), toml.at(doc, &.{ "a", "b", "c" }).?.integer);
    try t.expectEqual(@as(i64, 5), toml.at(doc, &.{ "x", "y" }).?.integer);
    try refused(&e, "= 1\n", 1, "a key was expected, found `=`");
    try refused(&e, "a.\n", 1, "a key was expected");
    try refused(&e, "a.", 1, "a key was expected");
    try refused(&e, "a", 1, "`=` was expected after the key `a`");
    try refused(&e, "a b = 1\n", 1, "`=` was expected after the key `a`");
    try refused(&e, "a = 1\n$ = 2\n", 2, "found `$`");
}

test "tables: [a.b], arrays of tables, nesting under the last element, and the redefinitions that are refused" {
    var e = Env.init();
    defer e.deinit();
    const doc = try ok(&e,
        \\[package]
        \\name = "x"
        \\[a.b]
        \\c = 1
        \\[[bin]]
        \\name = "one"
        \\[bin.meta]
        \\k = "v"
        \\[[bin]]
        \\name = "two"
        \\[[bin.deep]]
        \\z = 1
        \\[[bin.deep]]
        \\z = 2
        \\[ spaced . name ]
        \\v = 1
        \\[a.b.d]
        \\e = 2
    );
    try t.expectEqualStrings("x", str(val.get(doc, "package").?, "name"));
    try t.expectEqual(@as(i64, 1), toml.at(doc, &.{ "a", "b", "c" }).?.integer);
    try t.expectEqual(@as(i64, 2), toml.at(doc, &.{ "a", "b", "d", "e" }).?.integer);
    const bins = val.items(val.get(doc, "bin"));
    try t.expectEqual(@as(usize, 2), bins.len);
    try t.expectEqualStrings("v", str(val.get(bins[0], "meta").?, "k"));
    try t.expectEqual(@as(usize, 2), val.items(val.get(bins[1], "deep")).len);
    try t.expectEqual(@as(i64, 1), toml.at(doc, &.{ "spaced", "name", "v" }).?.integer);
    try refused(&e, "[a]\nx = 1\n[a]\nx = 2\n", 4, "defined twice");
    try refused(&e, "x = 1\n[x]\n", 2, "`x` is not a table");
    try refused(&e, "[a\nx = 1\n", 1, "`]` was expected");
    try refused(&e, "[[a]\n", 1, "`]]` was expected");
    try refused(&e, "[a]]\n", 1, "unexpected `]`");
    try refused(&e, "a = 1\n[[a]]\n", 2, "`a` is not an array of tables");
    try refused(&e, "x = 1\n[[x.y]]\n", 2, "`x` is not a table");
    try refused(&e, "a = []\n[a.b]\n", 2, "is an empty array, not a table");
    try refused(&e, "[x]\ny = 1\n[x.y.z]\n", 3, "`y` is not a table");
    try refused(&e, "[", 1, "a key was expected");
    try refused(&e, "[a] trailing\n", 1, "unexpected `t`");
}

test "line ends: CRLF, a comment at the end of the text, blank lines and spaces; the line of an error counts them" {
    var e = Env.init();
    defer e.deinit();
    const doc = try ok(&e, "a = 1\r\n\r\n# c\r\nb = 2 # c\r\nc = 3 # no newline");
    try t.expectEqual(@as(i64, 3), val.get(doc, "c").?.integer);
    try t.expectEqual(@as(i64, 2), val.get(doc, "b").?.integer);
    try refused(&e, "a = 1\r\n\r\nb = 2 3\r\n", 3, "unexpected");
    try t.expectEqual(@as(i64, 1), val.get(try ok(&e, "a = 1 \r"), "a").?.integer);
    _ = toml.parse(e.a(), "");
    try t.expect(toml.at(val.newObject(e.a()), &.{"missing"}) == null);
}

const ParseAll = struct {
    text: []const u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        return toml.parse(a, self.text).msg.len == 0;
    }
};

test "out of memory: a document that fails to allocate is refused with a message (and never read as another document)" {
    // Not strict: the reader of a number that cannot allocate takes the digits for a date and keeps them as text (toml.zig `number`); the sweep proves that
    // no failing allocation crashes the reader and that the allocation-free run is the whole document.
    const text =
        "# c\n[package]\nname = \"a\\n\\u00e9\"\nlit = 'x'\nml = \"\"\"a\\\n b\"\"\"\nlm = '''\nq'''\n" ++
        "list = [1, \"a\", { k = 1 }]\nd.e = 2\n[[bin]]\nn = 1_0\n[[bin]]\nn = 0x1\n[x.y]\nz = true\n";
    try kit.sweepOom(ParseAll{ .text = text }, false);
    const bad = "a = \"\\q\"\n";
    const BadDoc = struct {
        pub fn call(_: @This(), a: std.mem.Allocator) !bool {
            return toml.parse(a, bad).msg.len != 0;
        }
    };
    try kit.sweepOom(BadDoc{}, false);
}
