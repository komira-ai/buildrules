//! The generator's one data type: `std.json.Value`, whose objects keep insertion order, so the order a table entry is
//! built in is the order it is written in. Here: constructors and getters, structural equality, the canonical JSON
//! the content id of a unit is the hash of, the Starlark literals the table is written in, and the reader for the
//! literals of a `.bzl` file (a pins file, a table).
//!
//! Strings are written as Python's `json.dumps` writes them (ASCII only, `\uXXXX` escapes): the committed tables of
//! the Python generator this one replaced stay byte for byte what a sync writes.

const std = @import("std");

pub const Value = std.json.Value;
pub const Object = std.json.ObjectMap;
pub const Array = std.json.Array;

pub fn newObject(a: std.mem.Allocator) Value {
    return .{ .object = Object.init(a) };
}

pub fn newArray(a: std.mem.Allocator) Value {
    return .{ .array = Array.init(a) };
}

pub fn str(s: []const u8) Value {
    return .{ .string = s };
}

pub fn int(n: i64) Value {
    return .{ .integer = n };
}

pub fn boolean(b: bool) Value {
    return .{ .bool = b };
}

/// `obj[key] = v` (an existing key keeps its position).
pub fn put(obj: *Value, key: []const u8, v: Value) !void {
    try obj.object.put(key, v);
}

pub fn push(arr: *Value, v: Value) !void {
    try arr.array.append(v);
}

pub fn strList(a: std.mem.Allocator, xs: []const []const u8) !Value {
    var v = newArray(a);
    for (xs) |s| try push(&v, str(s));
    return v;
}

/// `v[key]`, or null when `v` is not an object or has no such key.
pub fn get(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

pub fn getStr(v: Value, key: []const u8) ?[]const u8 {
    const x = get(v, key) orelse return null;
    return if (x == .string) x.string else null;
}

pub fn asStr(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

pub fn items(v: ?Value) []const Value {
    const x = v orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

/// Python truthiness of a TOML or JSON value.
pub fn truthy(v: ?Value) bool {
    const x = v orelse return false;
    return switch (x) {
        .null => false,
        .bool => |b| b,
        .integer => |n| n != 0,
        .float => |f| f != 0,
        .number_string => true,
        .string => |s| s.len != 0,
        .array => |l| l.items.len != 0,
        .object => |o| o.count() != 0,
    };
}

pub fn eql(x: Value, y: Value) bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    switch (x) {
        .null => return true,
        .bool => |b| return b == y.bool,
        .integer => |n| return n == y.integer,
        .float => |f| return f == y.float,
        .number_string => |s| return std.mem.eql(u8, s, y.number_string),
        .string => |s| return std.mem.eql(u8, s, y.string),
        .array => |l| {
            if (l.items.len != y.array.items.len) return false;
            for (l.items, y.array.items) |p, q| if (!eql(p, q)) return false;
            return true;
        },
        .object => |o| {
            if (o.count() != y.object.count()) return false;
            var it = o.iterator();
            while (it.next()) |e| {
                const other = y.object.get(e.key_ptr.*) orelse return false;
                if (!eql(e.value_ptr.*, other)) return false;
            }
            return true;
        },
    }
}

/// Python's `str(v)` for a scalar: `None`, `True`, `2`, the string itself.
pub fn pyStr(a: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .null => "None",
        .bool => |b| if (b) "True" else "False",
        .integer => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
        .string => |s| s,
        .number_string => |s| s,
        .float => |f| try std.fmt.allocPrint(a, "{d}", .{f}),
        else => error.NotAScalar,
    };
}

// ---- strings and canonical JSON ---------------------------------------------------------------------------------

/// A JSON string literal as Python's `json.dumps` writes it: ASCII only, everything else `\uXXXX` (lower-case hex, surrogate
/// pairs above the BMP). A Starlark string literal for the characters that occur.
pub fn quote(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try w.writeByte(c),
            0x00...0x07, 0x0b, 0x0e...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{c}),
            else => {
                const n = std.unicode.utf8ByteSequenceLength(c) catch 1;
                const cp: ?u21 = if (n > 1 and i + n <= s.len) (std.unicode.utf8Decode(s[i .. i + n]) catch null) else null;
                if (cp) |u| {
                    if (u >= 0x10000) {
                        const v = u - 0x10000;
                        try w.print("\\u{x:0>4}\\u{x:0>4}", .{ 0xd800 + (v >> 10), 0xdc00 + (v & 0x3ff) });
                    } else {
                        try w.print("\\u{x:0>4}", .{u});
                    }
                    i += n;
                    continue;
                }
                try w.print("\\u{x:0>4}", .{c});
            },
        }
        i += 1;
    }
    try w.writeByte('"');
}

pub fn quoted(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(a);
    try quote(&aw.writer, s);
    return aw.toOwnedSlice();
}

fn scalarJson(w: *std.Io.Writer, v: Value) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| try w.print("{d}", .{n}),
        .number_string => |s| try w.writeAll(s),
        .float => |f| try w.print("{d}", .{f}),
        .string => |s| try quote(w, s),
        else => unreachable,
    }
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// `json.dumps(v, sort_keys=True, separators=(",", ":"))`: what the content id of a unit is the hash of.
pub fn canonical(w: *std.Io.Writer, a: std.mem.Allocator, v: Value) anyerror!void {
    switch (v) {
        .array => |l| {
            try w.writeByte('[');
            for (l.items, 0..) |x, i| {
                if (i != 0) try w.writeByte(',');
                try canonical(w, a, x);
            }
            try w.writeByte(']');
        },
        .object => |o| {
            const keys = try a.dupe([]const u8, o.keys());
            std.mem.sort([]const u8, keys, {}, lessStr);
            try w.writeByte('{');
            for (keys, 0..) |k, i| {
                if (i != 0) try w.writeByte(',');
                try quote(w, k);
                try w.writeByte(':');
                try canonical(w, a, o.get(k).?);
            }
            try w.writeByte('}');
        },
        else => try scalarJson(w, v),
    }
}

/// The first `n` hex digits of the sha256 of the canonical JSON of `v`.
pub fn contentId(a: std.mem.Allocator, v: Value, n: usize) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(a);
    try canonical(&aw.writer, a, v);
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(aw.written(), &d, .{});
    const hex = std.fmt.bytesToHex(d, .lower);
    return a.dupe(u8, hex[0..n]);
}

/// `json.dumps(v)` (default separators, ASCII) of a dict or list: only its length matters, to the rule that picks a one-line
/// dict in `lit`.
fn pyDumpsLen(a: std.mem.Allocator, v: Value) !usize {
    var aw = std.Io.Writer.Allocating.init(a);
    try pyDumps(&aw.writer, v);
    return aw.written().len;
}

fn pyDumps(w: *std.Io.Writer, v: Value) anyerror!void {
    switch (v) {
        .array => |l| {
            try w.writeByte('[');
            for (l.items, 0..) |x, i| {
                if (i != 0) try w.writeAll(", ");
                try pyDumps(w, x);
            }
            try w.writeByte(']');
        },
        .object => |o| {
            try w.writeByte('{');
            var first = true;
            var it = o.iterator();
            while (it.next()) |e| {
                if (!first) try w.writeAll(", ");
                first = false;
                try quote(w, e.key_ptr.*);
                try w.writeAll(": ");
                try pyDumps(w, e.value_ptr.*);
            }
            try w.writeByte('}');
        },
        else => try scalarJson(w, v),
    }
}

// ---- Starlark literals -----------------------------------------------------------------------------------------

fn isScalarNoNull(v: Value) bool {
    return v == .string or v == .integer or v == .bool;
}

/// A value on one line (the `deps` and `profile` of a unit: wide, but a unit's own line to diff).
pub fn oneline(w: *std.Io.Writer, a: std.mem.Allocator, v: Value) anyerror!void {
    switch (v) {
        .object => |o| {
            try w.writeByte('{');
            var first = true;
            var it = o.iterator();
            while (it.next()) |e| {
                if (!first) try w.writeAll(", ");
                first = false;
                try quote(w, e.key_ptr.*);
                try w.writeAll(": ");
                try oneline(w, a, e.value_ptr.*);
            }
            try w.writeByte('}');
        },
        .array => |l| {
            try w.writeByte('[');
            for (l.items, 0..) |x, i| {
                if (i != 0) try w.writeAll(", ");
                try oneline(w, a, x);
            }
            try w.writeByte(']');
        },
        else => try lit(w, a, v, 0),
    }
}

fn pad(w: *std.Io.Writer, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try w.writeAll("    ");
}

/// A Starlark literal: scalars and short flat lists and dicts on one line, anything else one entry per line (the `deps` and
/// `profile` keys of a dict on one line each), `ind` levels of four spaces deep.
pub fn lit(w: *std.Io.Writer, a: std.mem.Allocator, v: Value, ind: usize) anyerror!void {
    switch (v) {
        .bool => |b| try w.writeAll(if (b) "True" else "False"),
        .null => try w.writeAll("None"),
        .integer => |n| try w.print("{d}", .{n}),
        .string => |s| try quote(w, s),
        .array => |l| {
            if (l.items.len == 0) return w.writeAll("[]");
            var simple = true;
            for (l.items) |x| {
                if (!isScalarNoNull(x)) simple = false;
            }
            if (simple) {
                try w.writeByte('[');
                for (l.items, 0..) |x, i| {
                    if (i != 0) try w.writeAll(", ");
                    try lit(w, a, x, 0);
                }
                try w.writeByte(']');
                return;
            }
            try w.writeAll("[\n");
            for (l.items) |x| {
                try pad(w, ind + 1);
                try lit(w, a, x, ind + 1);
                try w.writeAll(",\n");
            }
            try pad(w, ind);
            try w.writeByte(']');
        },
        .object => |o| {
            if (o.count() == 0) return w.writeAll("{}");
            var simple = true;
            var it = o.iterator();
            while (it.next()) |e| {
                if (!(isScalarNoNull(e.value_ptr.*) or e.value_ptr.* == .null)) simple = false;
            }
            if (simple and (try pyDumpsLen(a, v)) < 100) {
                try w.writeByte('{');
                var first = true;
                var it2 = o.iterator();
                while (it2.next()) |e| {
                    if (!first) try w.writeAll(", ");
                    first = false;
                    try quote(w, e.key_ptr.*);
                    try w.writeAll(": ");
                    try lit(w, a, e.value_ptr.*, 0);
                }
                try w.writeByte('}');
                return;
            }
            try w.writeAll("{\n");
            var it3 = o.iterator();
            while (it3.next()) |e| {
                try pad(w, ind + 1);
                try quote(w, e.key_ptr.*);
                try w.writeAll(": ");
                const k = e.key_ptr.*;
                if (std.mem.eql(u8, k, "deps") or std.mem.eql(u8, k, "profile")) {
                    try oneline(w, a, e.value_ptr.*);
                } else {
                    try lit(w, a, e.value_ptr.*, ind + 1);
                }
                try w.writeAll(",\n");
            }
            try pad(w, ind);
            try w.writeByte('}');
        },
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
    }
}

pub fn litString(a: std.mem.Allocator, v: Value, ind: usize) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(a);
    try lit(&aw.writer, a, v, ind);
    return aw.toOwnedSlice();
}

// ---- reading the literals of a .bzl file ------------------------------------------------------------------------

pub const ParseError = error{ BadLiteral, OutOfMemory };

const Lit = struct {
    a: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,

    fn skip(p: *Lit) void {
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                p.i += 1;
            } else if (c == '#') {
                while (p.i < p.s.len and p.s[p.i] != '\n') p.i += 1;
            } else break;
        }
    }

    fn word(p: *Lit, w: []const u8) bool {
        if (!std.mem.startsWith(u8, p.s[p.i..], w)) return false;
        const end = p.i + w.len;
        if (end < p.s.len and (std.ascii.isAlphanumeric(p.s[end]) or p.s[end] == '_')) return false;
        p.i = end;
        return true;
    }

    fn string(p: *Lit) ParseError![]const u8 {
        const q = p.s[p.i];
        p.i += 1;
        var out = std.ArrayList(u8).empty;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            p.i += 1;
            if (c == q) return out.toOwnedSlice(p.a);
            if (c != '\\') {
                try out.append(p.a, c);
                continue;
            }
            if (p.i >= p.s.len) return error.BadLiteral;
            const e = p.s[p.i];
            p.i += 1;
            switch (e) {
                'n' => try out.append(p.a, '\n'),
                't' => try out.append(p.a, '\t'),
                'r' => try out.append(p.a, '\r'),
                'b' => try out.append(p.a, 0x08),
                'f' => try out.append(p.a, 0x0c),
                '\\', '"', '\'', '/' => try out.append(p.a, e),
                'u' => {
                    if (p.i + 4 > p.s.len) return error.BadLiteral;
                    var cp = std.fmt.parseInt(u21, p.s[p.i .. p.i + 4], 16) catch return error.BadLiteral;
                    p.i += 4;
                    if (cp >= 0xd800 and cp < 0xdc00 and p.i + 6 <= p.s.len and p.s[p.i] == '\\' and p.s[p.i + 1] == 'u') {
                        const lo = std.fmt.parseInt(u21, p.s[p.i + 2 .. p.i + 6], 16) catch return error.BadLiteral;
                        if (lo >= 0xdc00 and lo < 0xe000) {
                            cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                            p.i += 6;
                        }
                    }
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return error.BadLiteral;
                    try out.appendSlice(p.a, buf[0..n]);
                },
                else => return error.BadLiteral,
            }
        }
        return error.BadLiteral;
    }

    fn value(p: *Lit) ParseError!Value {
        p.skip();
        if (p.i >= p.s.len) return error.BadLiteral;
        const c = p.s[p.i];
        if (c == '"' or c == '\'') return .{ .string = try p.string() };
        if (c == '[' or c == '(') {
            const close: u8 = if (c == '[') ']' else ')';
            p.i += 1;
            var arr = newArray(p.a);
            while (true) {
                p.skip();
                if (p.i >= p.s.len) return error.BadLiteral;
                if (p.s[p.i] == close) {
                    p.i += 1;
                    return arr;
                }
                try arr.array.append(try p.value());
                p.skip();
                if (p.i < p.s.len and p.s[p.i] == ',') p.i += 1;
            }
        }
        if (c == '{') {
            p.i += 1;
            var obj = newObject(p.a);
            while (true) {
                p.skip();
                if (p.i >= p.s.len) return error.BadLiteral;
                if (p.s[p.i] == '}') {
                    p.i += 1;
                    return obj;
                }
                const k = try p.value();
                if (k != .string) return error.BadLiteral;
                p.skip();
                if (p.i >= p.s.len or p.s[p.i] != ':') return error.BadLiteral;
                p.i += 1;
                try obj.object.put(k.string, try p.value());
                p.skip();
                if (p.i < p.s.len and p.s[p.i] == ',') p.i += 1;
            }
        }
        if (p.word("True")) return .{ .bool = true };
        if (p.word("False")) return .{ .bool = false };
        if (p.word("None")) return .null;
        var j = p.i;
        if (j < p.s.len and (p.s[j] == '-' or p.s[j] == '+')) j += 1;
        const digits = j;
        while (j < p.s.len and std.ascii.isDigit(p.s[j])) j += 1;
        if (j == digits) return error.BadLiteral;
        const n = std.fmt.parseInt(i64, p.s[p.i..j], 10) catch return error.BadLiteral;
        p.i = j;
        return .{ .integer = n };
    }
};

/// The literal that starts `text` (strings, numbers, True/False/None, lists, tuples as lists, dicts).
pub fn parseLiteral(a: std.mem.Allocator, text: []const u8) ParseError!Value {
    var p = Lit{ .a = a, .s = text };
    return p.value();
}

/// The value of the top-level assignment `name = <literal>` of a `.bzl` file, null when there is none. Other statements
/// (`def`, `load`, assignments that are not literals) are not read. A malformed literal is `BadLiteral`.
pub fn readNamed(a: std.mem.Allocator, text: []const u8, name: []const u8) ParseError!?Value {
    var at: usize = 0;
    while (at < text.len) {
        const line_end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
        const line = text[at..line_end];
        if (std.mem.startsWith(u8, line, name) and std.mem.startsWith(u8, line[name.len..], " = ")) {
            var p = Lit{ .a = a, .s = text, .i = at + name.len + 3 };
            const v = try p.value();
            // The statement ends with the literal: anything else on its line (`+ "x"`, a call) is not a literal.
            while (p.i < text.len and (text[p.i] == ' ' or text[p.i] == '\t' or text[p.i] == '\r')) p.i += 1;
            if (p.i < text.len and text[p.i] != '\n' and text[p.i] != '#') return error.BadLiteral;
            return v;
        }
        at = line_end + 1;
    }
    return null;
}
