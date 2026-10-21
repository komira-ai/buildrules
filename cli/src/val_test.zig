//! val.zig: the values the generator builds and the text it writes them as. The committed tables are byte for byte what this writes, so every
//! escape and every layout rule has its own expectation, written out here rather than computed by the code under test.

const std = @import("std");
const kit = @import("testkit.zig");
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

test "truthy: Python's rules for every kind of value" {
    var e = Env.init();
    defer e.deinit();
    try t.expect(!val.truthy(null));
    try t.expect(!val.truthy(.null));
    try t.expect(val.truthy(val.boolean(true)));
    try t.expect(!val.truthy(val.boolean(false)));
    try t.expect(val.truthy(val.int(-1)));
    try t.expect(!val.truthy(val.int(0)));
    try t.expect(val.truthy(.{ .float = 0.5 }));
    try t.expect(!val.truthy(.{ .float = 0 }));
    try t.expect(val.truthy(.{ .number_string = "0" }));
    try t.expect(val.truthy(val.str("x")));
    try t.expect(!val.truthy(val.str("")));
    try t.expect(val.truthy(try val.strList(e.a(), &.{"x"})));
    try t.expect(!val.truthy(val.newArray(e.a())));
    var o = val.newObject(e.a());
    try t.expect(!val.truthy(o));
    try val.put(&o, "k", val.int(1));
    try t.expect(val.truthy(o));
}

test "eql: same kind and same content; a different kind is never equal, even for 1 and 1.0 and \"1\"" {
    var e = Env.init();
    defer e.deinit();
    try t.expect(val.eql(.null, .null));
    try t.expect(val.eql(val.boolean(true), val.boolean(true)));
    try t.expect(!val.eql(val.boolean(true), val.boolean(false)));
    try t.expect(val.eql(val.int(3), val.int(3)));
    try t.expect(!val.eql(val.int(3), val.int(4)));
    try t.expect(val.eql(.{ .float = 1.5 }, .{ .float = 1.5 }));
    try t.expect(!val.eql(.{ .float = 1.5 }, .{ .float = 2.5 }));
    try t.expect(val.eql(.{ .number_string = "12" }, .{ .number_string = "12" }));
    try t.expect(!val.eql(.{ .number_string = "12" }, .{ .number_string = "13" }));
    try t.expect(val.eql(val.str("a"), val.str("a")));
    try t.expect(!val.eql(val.str("a"), val.str("b")));
    try t.expect(!val.eql(val.int(1), .{ .float = 1 }));
    try t.expect(!val.eql(val.int(1), val.str("1")));
    const ab = try val.strList(e.a(), &.{ "a", "b" });
    try t.expect(val.eql(ab, try val.strList(e.a(), &.{ "a", "b" })));
    try t.expect(!val.eql(ab, try val.strList(e.a(), &.{ "a", "c" })));
    try t.expect(!val.eql(ab, try val.strList(e.a(), &.{"a"})));
    var o1 = val.newObject(e.a());
    try val.put(&o1, "k", val.int(1));
    try val.put(&o1, "j", ab);
    var o2 = val.newObject(e.a());
    try val.put(&o2, "j", ab);
    try val.put(&o2, "k", val.int(1));
    try t.expect(val.eql(o1, o2));
    var o3 = val.newObject(e.a());
    try val.put(&o3, "j", ab);
    try val.put(&o3, "k", val.int(2));
    try t.expect(!val.eql(o1, o3));
    var o4 = val.newObject(e.a());
    try val.put(&o4, "j", ab);
    try val.put(&o4, "other", val.int(1));
    try t.expect(!val.eql(o1, o4));
    try t.expect(!val.eql(o1, val.newObject(e.a())));
}

test "pyStr: None, True, False, numbers and strings as Python's str prints them; a list or dict is refused" {
    var e = Env.init();
    defer e.deinit();
    try t.expectEqualStrings("None", try val.pyStr(e.a(), .null));
    try t.expectEqualStrings("True", try val.pyStr(e.a(), val.boolean(true)));
    try t.expectEqualStrings("False", try val.pyStr(e.a(), val.boolean(false)));
    try t.expectEqualStrings("-12", try val.pyStr(e.a(), val.int(-12)));
    try t.expectEqualStrings("s", try val.pyStr(e.a(), val.str("s")));
    try t.expectEqualStrings("007", try val.pyStr(e.a(), .{ .number_string = "007" }));
    try t.expectEqualStrings("2.5", try val.pyStr(e.a(), .{ .float = 2.5 }));
    try t.expectError(error.NotAScalar, val.pyStr(e.a(), val.newArray(e.a())));
    try t.expectError(error.NotAScalar, val.pyStr(e.a(), val.newObject(e.a())));
}

test "getters: get, getStr, asStr, items on a missing key, a wrong kind and a non-object" {
    var e = Env.init();
    defer e.deinit();
    var o = val.newObject(e.a());
    try val.put(&o, "s", val.str("v"));
    try val.put(&o, "n", val.int(1));
    try val.put(&o, "l", try val.strList(e.a(), &.{"x"}));
    try t.expectEqualStrings("v", val.getStr(o, "s").?);
    try t.expect(val.getStr(o, "n") == null);
    try t.expect(val.getStr(o, "missing") == null);
    try t.expect(val.get(val.str("x"), "s") == null);
    try t.expect(val.asStr(null) == null);
    try t.expect(val.asStr(val.int(1)) == null);
    try t.expectEqualStrings("v", val.asStr(val.str("v")).?);
    try t.expectEqual(@as(usize, 1), val.items(val.get(o, "l")).len);
    try t.expectEqual(@as(usize, 0), val.items(val.get(o, "s")).len);
    try t.expectEqual(@as(usize, 0), val.items(null).len);
    var arr = val.newArray(e.a());
    try val.push(&arr, val.int(1));
    try t.expectEqual(@as(usize, 1), arr.array.items.len);
    // An existing key keeps its place.
    try val.put(&o, "s", val.str("w"));
    try t.expectEqualStrings("s", o.object.keys()[0]);
    try t.expectEqualStrings("w", val.getStr(o, "s").?);
}

test "quote: every class of byte is written as Python's json.dumps writes it" {
    var e = Env.init();
    defer e.deinit();
    try t.expectEqualStrings("\"\\\"\\\\\\n\\r\\t\\b\\f\"", try val.quoted(e.a(), "\"\\\n\r\t\x08\x0c"));
    try t.expectEqualStrings("\"\\u0000\\u0001\\u0007\\u000b\\u000e\\u001f\\u007f\"", try val.quoted(e.a(), "\x00\x01\x07\x0b\x0e\x1f\x7f"));
    try t.expectEqualStrings("\" !#[]~\"", try val.quoted(e.a(), " !#[]~"));
    try t.expectEqualStrings("\"\\u00e9\"", try val.quoted(e.a(), "\u{e9}"));
    try t.expectEqualStrings("\"\\u07ff\\uffff\"", try val.quoted(e.a(), "\u{7ff}\u{ffff}"));
    try t.expectEqualStrings("\"\\ud800\\udc00\\udbff\\udfff\"", try val.quoted(e.a(), "\u{10000}\u{10ffff}"));
    // Bytes that are not UTF-8 are written as the Latin-1 character of the byte, and the text after them goes on.
    try t.expectEqualStrings("\"\\u00ffa\"", try val.quoted(e.a(), "\xffa"));
    try t.expectEqualStrings("\"\\u00c3(\"", try val.quoted(e.a(), "\xc3("));
    try t.expectEqualStrings("\"a\\u00c3\"", try val.quoted(e.a(), "a\xc3"));
    try t.expectEqualStrings("\"\\u0080\"", try val.quoted(e.a(), "\x80"));
    try t.expectEqualStrings("\"\"", try val.quoted(e.a(), ""));
}

test "quote and parseLiteral are inverses on text, and parseLiteral reads every escape" {
    var e = Env.init();
    defer e.deinit();
    const texts = [_][]const u8{ "", "plain", "a\"b\\c\n\r\t\x08\x0c", "\x01\x1f\x7f", "caf\u{e9} \u{4e2d} \u{1f600}", "/ and ' too" };
    for (texts) |s| {
        const q = try val.quoted(e.a(), s);
        const back = try val.parseLiteral(e.a(), q);
        try t.expectEqualStrings(s, back.string);
    }
    const v = try val.parseLiteral(e.a(), "'a\\n\\t\\r\\b\\f\\\\\\\"\\'\\/\\u00e9\\ud83d\\ude00'");
    try t.expectEqualStrings("a\n\t\r\x08\x0c\\\"'/\u{e9}\u{1f600}", v.string);
    try t.expectEqualStrings("é", (try val.parseLiteral(e.a(), "\"\\u00E9\"")).string);
}

test "parseLiteral: scalars, lists, tuples, dicts, comments and blanks; the literal that starts the text" {
    var e = Env.init();
    defer e.deinit();
    try t.expect((try val.parseLiteral(e.a(), "True")).bool);
    try t.expect(!(try val.parseLiteral(e.a(), "  False")).bool);
    try t.expect((try val.parseLiteral(e.a(), "None")) == .null);
    try t.expectEqual(@as(i64, 42), (try val.parseLiteral(e.a(), "42")).integer);
    try t.expectEqual(@as(i64, -42), (try val.parseLiteral(e.a(), "-42")).integer);
    try t.expectEqual(@as(i64, 7), (try val.parseLiteral(e.a(), "+7")).integer);
    try t.expectEqual(@as(i64, 5), (try val.parseLiteral(e.a(), "5 trailing text is not read")).integer);
    const l = try val.parseLiteral(e.a(), "[1, # one\n  (2, 3),\n  \"x\",]");
    try t.expectEqual(@as(usize, 3), l.array.items.len);
    try t.expectEqual(@as(usize, 2), l.array.items[1].array.items.len);
    const d = try val.parseLiteral(e.a(), "{\"a\": 1, \"b\": {\"c\": [True]},\n # c\n \"d\": None}");
    try t.expectEqual(@as(usize, 3), d.object.count());
    try t.expect(val.get(val.get(d, "b").?, "c").?.array.items[0].bool);
    try t.expectEqual(@as(usize, 0), (try val.parseLiteral(e.a(), "[]")).array.items.len);
    try t.expectEqual(@as(usize, 0), (try val.parseLiteral(e.a(), "()")).array.items.len);
    try t.expectEqual(@as(usize, 0), (try val.parseLiteral(e.a(), "{}")).object.count());
}

test "parseLiteral: every malformed literal is BadLiteral, never half of a value" {
    var e = Env.init();
    defer e.deinit();
    const bad = [_][]const u8{
        "",
        "   ",
        "# only a comment",
        "\"open",
        "'open",
        "\"back\\",
        "\"\\q\"",
        "\"\\u12\"",
        "\"\\uZZZZ\"",
        "\"\\ud800\"",
        "\"\\ud800\\u0041\"",
        "\"\\ud800\\uZZZZ\"",
        "[1, 2",
        "[",
        "(1",
        "{",
        "{\"a\"",
        "{\"a\": }",
        "{\"a\" 1}",
        "{\"a\": 1",
        "{1: 2}",
        "{\"a\": 1 \"b\": 2",
        "Truex",
        "Nonesuch",
        "nope",
        "-",
        "+",
        "99999999999999999999",
        "@",
    };
    for (bad) |text| {
        if (val.parseLiteral(e.a(), text)) |v| {
            std.debug.print("accepted `{s}` as {s}\n", .{ text, @tagName(v) });
            return error.AcceptedABadLiteral;
        } else |err| try t.expectEqual(error.BadLiteral, err);
    }
}

test "readNamed: the statement ends with the literal, at a comment or the end of the line or of the text" {
    var e = Env.init();
    defer e.deinit();
    try t.expectEqual(@as(i64, 1), (try val.readNamed(e.a(), "A = 1", "A")).?.integer);
    try t.expectEqual(@as(i64, 1), (try val.readNamed(e.a(), "A = 1 # c\nB = 2\n", "A")).?.integer);
    try t.expectEqual(@as(i64, 2), (try val.readNamed(e.a(), "A = 1\r\nB = 2\r\n", "B")).?.integer);
    try t.expectEqual(@as(i64, 1), (try val.readNamed(e.a(), "A = 1  \t\r\n", "A")).?.integer);
    // A name that is the start of a longer name, or has no ` = ` after it, is not the name.
    try t.expect((try val.readNamed(e.a(), "AB = 1\nA= 2\nA == 3\n", "A")) == null);
    try t.expect((try val.readNamed(e.a(), "", "A")) == null);
    try t.expectError(error.BadLiteral, val.readNamed(e.a(), "A = 1 + 2\n", "A"));
    try t.expectError(error.BadLiteral, val.readNamed(e.a(), "A = \n", "A"));
}

test "canonical and contentId: sorted keys at every depth, no spaces, every kind of scalar" {
    var e = Env.init();
    defer e.deinit();
    var o = val.newObject(e.a());
    try val.put(&o, "z", .{ .float = 2.5 });
    try val.put(&o, "y", .{ .number_string = "12" });
    try val.put(&o, "x", .null);
    try val.put(&o, "w", try val.strList(e.a(), &.{ "b", "a" }));
    var inner = val.newObject(e.a());
    try val.put(&inner, "q", val.boolean(false));
    try val.put(&inner, "p", val.int(-1));
    try val.put(&o, "v", inner);
    var aw = std.Io.Writer.Allocating.init(e.a());
    try val.canonical(&aw.writer, e.a(), o);
    try t.expectEqualStrings("{\"v\":{\"p\":-1,\"q\":false},\"w\":[\"b\",\"a\"],\"x\":null,\"y\":12,\"z\":2.5}", aw.written());
    const id = try val.contentId(e.a(), o, 64);
    try t.expectEqual(@as(usize, 64), id.len);
    try t.expectEqualStrings(id[0..8], try val.contentId(e.a(), o, 8));
    // The id is the sha256 of the text above.
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(aw.written(), &d, .{});
    try t.expectEqualStrings(&std.fmt.bytesToHex(d, .lower), id);
}

test "lit: scalars, empty and flat containers on one line, nested ones a line per entry, floats and number strings as they are" {
    var e = Env.init();
    defer e.deinit();
    const lit = struct {
        fn of(a: std.mem.Allocator, v: val.Value, ind: usize) ![]u8 {
            return val.litString(a, v, ind);
        }
    }.of;
    try t.expectEqualStrings("True", try lit(e.a(), val.boolean(true), 0));
    try t.expectEqualStrings("False", try lit(e.a(), val.boolean(false), 0));
    try t.expectEqualStrings("None", try lit(e.a(), .null, 0));
    try t.expectEqualStrings("-3", try lit(e.a(), val.int(-3), 0));
    try t.expectEqualStrings("2.5", try lit(e.a(), .{ .float = 2.5 }, 0));
    try t.expectEqualStrings("0x1F", try lit(e.a(), .{ .number_string = "0x1F" }, 0));
    try t.expectEqualStrings("\"s\"", try lit(e.a(), val.str("s"), 0));
    try t.expectEqualStrings("[1, \"a\", True]", try lit(e.a(), try val.parseLiteral(e.a(), "[1, \"a\", True]"), 0));
    // A list with None (or a float) in it is not flat: one entry per line.
    try t.expectEqualStrings("[\n    None,\n    1,\n]", try lit(e.a(), try val.parseLiteral(e.a(), "[None, 1]"), 0));
    var floats = val.newArray(e.a());
    try val.push(&floats, .{ .float = 1.5 });
    try t.expectEqualStrings("[\n        1.5,\n    ]", try lit(e.a(), floats, 1));
    // A flat dict may hold None; one value that is a list or dict puts every entry on its own line.
    try t.expectEqualStrings("{\"a\": None, \"b\": 2}", try lit(e.a(), try val.parseLiteral(e.a(), "{\"a\": None, \"b\": 2}"), 0));
    try t.expectEqualStrings("{\n    \"a\": [1],\n    \"b\": 2,\n}", try lit(e.a(), try val.parseLiteral(e.a(), "{\"a\": [1], \"b\": 2}"), 0));
    // A flat dict is a line only while it is shorter than 100 characters as Python's json.dumps writes it.
    const ninety = "{\"" ++ "k" ** 40 ++ "\": \"" ++ "v" ** 40 ++ "\"}";
    try t.expectEqualStrings(ninety, try lit(e.a(), try val.parseLiteral(e.a(), ninety), 0));
    const hundred = "{\"" ++ "k" ** 46 ++ "\": \"" ++ "v" ** 46 ++ "\"}";
    try t.expectEqual(@as(usize, 100), hundred.len);
    try t.expectEqualStrings("{\n    \"" ++ "k" ** 46 ++ "\": \"" ++ "v" ** 46 ++ "\",\n}", try lit(e.a(), try val.parseLiteral(e.a(), hundred), 0));
}

test "oneline: dicts and lists nested to any depth stay on one line; a scalar is its literal" {
    var e = Env.init();
    defer e.deinit();
    var aw = std.Io.Writer.Allocating.init(e.a());
    const v = try val.parseLiteral(e.a(), "{\"a\": [1, {\"b\": None}], \"c\": {}, \"d\": []}");
    try val.oneline(&aw.writer, e.a(), v);
    try t.expectEqualStrings("{\"a\": [1, {\"b\": None}], \"c\": {}, \"d\": []}", aw.written());
    var aw2 = std.Io.Writer.Allocating.init(e.a());
    try val.oneline(&aw2.writer, e.a(), val.str("x"));
    try t.expectEqualStrings("\"x\"", aw2.written());
}

const LitCall = struct {
    v: val.Value,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        const s = try val.litString(a, self.v, 0);
        return s.len > 0;
    }
};

const ParseCall = struct {
    text: []const u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        _ = try val.parseLiteral(a, self.text);
        return true;
    }
};

const IdCall = struct {
    v: val.Value,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        const id = try val.contentId(a, self.v, 10);
        const q = try val.quoted(a, "a\u{e9}\"");
        const s = try val.pyStr(a, val.int(5));
        return id.len == 10 and q.len > 0 and s.len == 1;
    }
};

test "out of memory: a failing allocation ends the writers and the reader with an error, never with text" {
    var e = Env.init();
    defer e.deinit();
    const doc = "{\"deps\": [[\"a\", \"b\"]], \"profile\": {\"p\": None}, \"k\": {\"x\": 1}, \"l\": [None, 2], \"s\": \"x\\n\\u00e9\\ud83d\\ude00\", \"f\": True}";
    const v = try val.parseLiteral(e.a(), doc);
    try kit.sweepOom(LitCall{ .v = v }, true);
    try kit.sweepOom(ParseCall{ .text = doc }, true);
    try kit.sweepOom(IdCall{ .v = v }, true);
}
