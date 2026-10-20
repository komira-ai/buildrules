//! TOML (1.0) into a `val.Value` tree, for the manifests the generator reads (Cargo.toml: `[package] links`, `[lints]`,
//! `[features]`, dependencies, `[*.metadata.buildrules]`). Tables, arrays of tables, dotted and quoted keys, basic, literal
//! and multi-line strings, integers, floats, booleans, arrays and inline tables. Dates and times are kept as their text.
//! A table keeps its keys in file order. A syntax error is reported with its line.

const std = @import("std");
const val = @import("val.zig");

const Value = val.Value;

pub const Error = error{ Syntax, OutOfMemory };

pub const Parsed = struct { value: Value, line: usize = 0, msg: []const u8 = "" };

const P = struct {
    a: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,
    line: usize = 1,
    msg: []const u8 = "",

    fn fail(p: *P, comptime fmt: []const u8, args: anytype) Error {
        p.msg = std.fmt.allocPrint(p.a, fmt, args) catch "out of memory";
        return error.Syntax;
    }

    fn peek(p: *P) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    fn blanks(p: *P) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t')) p.i += 1;
    }

    fn comment(p: *P) void {
        if (p.peek() != '#') return;
        while (p.i < p.s.len and p.s[p.i] != '\n') p.i += 1;
    }

    /// Blanks, comments and newlines (inside an array).
    fn space(p: *P) void {
        while (p.i < p.s.len) {
            switch (p.s[p.i]) {
                ' ', '\t', '\r' => p.i += 1,
                '\n' => {
                    p.i += 1;
                    p.line += 1;
                },
                '#' => p.comment(),
                else => return,
            }
        }
    }

    fn endOfLine(p: *P) Error!void {
        p.blanks();
        p.comment();
        if (p.i < p.s.len and p.s[p.i] == '\r') p.i += 1;
        if (p.i >= p.s.len) return;
        if (p.s[p.i] != '\n') return p.fail("unexpected `{c}`", .{p.s[p.i]});
        p.i += 1;
        p.line += 1;
    }

    fn bareChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
    }

    fn key(p: *P) Error![]const u8 {
        p.blanks();
        const c = p.peek() orelse return p.fail("a key was expected", .{});
        if (c == '"') return p.basicString();
        if (c == '\'') return p.literalString();
        const start = p.i;
        while (p.i < p.s.len and bareChar(p.s[p.i])) p.i += 1;
        if (p.i == start) return p.fail("a key was expected, found `{c}`", .{c});
        return p.s[start..p.i];
    }

    fn dottedKey(p: *P) Error![]const []const u8 {
        var parts = std.ArrayList([]const u8).empty;
        while (true) {
            try parts.append(p.a, try p.key());
            p.blanks();
            if (p.peek() == '.') {
                p.i += 1;
                continue;
            }
            return parts.toOwnedSlice(p.a);
        }
    }

    fn literalString(p: *P) Error![]const u8 {
        if (std.mem.startsWith(u8, p.s[p.i..], "'''")) return p.multiLine('\'');
        p.i += 1;
        const start = p.i;
        while (p.i < p.s.len and p.s[p.i] != '\'' and p.s[p.i] != '\n') p.i += 1;
        if (p.peek() != '\'') return p.fail("a string is not closed", .{});
        const out = p.s[start..p.i];
        p.i += 1;
        return out;
    }

    fn escape(p: *P, out: *std.ArrayList(u8)) Error!void {
        p.i += 1; // the backslash
        const e = p.peek() orelse return p.fail("a string is not closed", .{});
        p.i += 1;
        switch (e) {
            'b' => try out.append(p.a, 0x08),
            't' => try out.append(p.a, '\t'),
            'n' => try out.append(p.a, '\n'),
            'f' => try out.append(p.a, 0x0c),
            'r' => try out.append(p.a, '\r'),
            '"' => try out.append(p.a, '"'),
            '\\' => try out.append(p.a, '\\'),
            'u', 'U' => {
                const n: usize = if (e == 'u') 4 else 8;
                if (p.i + n > p.s.len) return p.fail("a unicode escape is cut off", .{});
                const cp = std.fmt.parseInt(u21, p.s[p.i .. p.i + n], 16) catch return p.fail("a bad unicode escape", .{});
                p.i += n;
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cp, &buf) catch return p.fail("a bad unicode escape", .{});
                try out.appendSlice(p.a, buf[0..len]);
            },
            else => return p.fail("an unknown escape `\\{c}`", .{e}),
        }
    }

    fn basicString(p: *P) Error![]const u8 {
        if (std.mem.startsWith(u8, p.s[p.i..], "\"\"\"")) return p.multiLine('"');
        p.i += 1;
        var out = std.ArrayList(u8).empty;
        while (true) {
            const c = p.peek() orelse return p.fail("a string is not closed", .{});
            if (c == '\n') return p.fail("a string is not closed", .{});
            if (c == '"') {
                p.i += 1;
                return out.toOwnedSlice(p.a);
            }
            if (c == '\\') {
                try p.escape(&out);
            } else {
                try out.append(p.a, c);
                p.i += 1;
            }
        }
    }

    /// `"""..."""` and `'''...'''`: a newline right after the opening quotes is dropped; in a basic string a backslash at the end
    /// of a line drops the whitespace up to the next character.
    fn multiLine(p: *P, q: u8) Error![]const u8 {
        p.i += 3;
        if (p.peek() == '\r') p.i += 1;
        if (p.peek() == '\n') {
            p.i += 1;
            p.line += 1;
        }
        var out = std.ArrayList(u8).empty;
        while (true) {
            if (p.i >= p.s.len) return p.fail("a string is not closed", .{});
            const c = p.s[p.i];
            if (c == q and p.i + 2 < p.s.len and p.s[p.i + 1] == q and p.s[p.i + 2] == q) {
                // up to two more quotes may belong to the string
                var extra: usize = 0;
                while (extra < 2 and p.i + 3 + extra < p.s.len and p.s[p.i + 3 + extra] == q) extra += 1;
                var k: usize = 0;
                while (k < extra) : (k += 1) try out.append(p.a, q);
                p.i += 3 + extra;
                return out.toOwnedSlice(p.a);
            }
            if (c == '\\' and q == '"') {
                var j = p.i + 1;
                while (j < p.s.len and (p.s[j] == ' ' or p.s[j] == '\t' or p.s[j] == '\r')) j += 1;
                if (j < p.s.len and p.s[j] == '\n') {
                    while (j < p.s.len and (p.s[j] == ' ' or p.s[j] == '\t' or p.s[j] == '\n' or p.s[j] == '\r')) : (j += 1) {
                        if (p.s[j] == '\n') p.line += 1;
                    }
                    p.i = j;
                    continue;
                }
                try p.escape(&out);
                continue;
            }
            if (c == '\n') p.line += 1;
            try out.append(p.a, c);
            p.i += 1;
        }
    }

    fn scalarWord(p: *P) []const u8 {
        const start = p.i;
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == ',' or c == ']' or c == '}' or c == '\n' or c == '#' or c == '\r') break;
            if ((c == ' ' or c == '\t')) {
                // a date-time has a space between the date and the time
                const rest = p.s[p.i + 1 ..];
                if (!(rest.len >= 2 and std.ascii.isDigit(rest[0]) and std.ascii.isDigit(rest[1]) and p.i - start == 10)) break;
            }
            p.i += 1;
        }
        return std.mem.trimRight(u8, p.s[start..p.i], " \t");
    }

    fn number(p: *P, w: []const u8) ?Value {
        var buf = std.ArrayList(u8).empty;
        for (w) |c| {
            if (c != '_') buf.append(p.a, c) catch return null;
        }
        const t = buf.items;
        if (t.len == 0) return null;
        const neg = t[0] == '-';
        const body = if (t[0] == '-' or t[0] == '+') t[1..] else t;
        if (body.len > 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'o' or body[1] == 'b')) {
            const base: u8 = switch (body[1]) {
                'x' => 16,
                'o' => 8,
                else => 2,
            };
            const n = std.fmt.parseInt(i64, body[2..], base) catch return null;
            return .{ .integer = if (neg) -n else n };
        }
        if (std.fmt.parseInt(i64, t, 10)) |n| return .{ .integer = n } else |_| {}
        if (std.mem.eql(u8, body, "inf")) return .{ .float = if (neg) -std.math.inf(f64) else std.math.inf(f64) };
        if (std.mem.eql(u8, body, "nan")) return .{ .float = std.math.nan(f64) };
        if (std.fmt.parseFloat(f64, t)) |f| return .{ .float = f } else |_| {}
        return null;
    }

    fn value(p: *P) Error!Value {
        p.blanks();
        const c = p.peek() orelse return p.fail("a value was expected", .{});
        switch (c) {
            '"' => return .{ .string = try p.basicString() },
            '\'' => return .{ .string = try p.literalString() },
            '[' => {
                p.i += 1;
                var arr = val.newArray(p.a);
                while (true) {
                    p.space();
                    if (p.peek() == ']') {
                        p.i += 1;
                        return arr;
                    }
                    try arr.array.append(try p.value());
                    p.space();
                    if (p.peek() == ',') {
                        p.i += 1;
                    } else if (p.peek() != ']') return p.fail("`,` or `]` was expected in an array", .{});
                }
            },
            '{' => {
                p.i += 1;
                var obj = val.newObject(p.a);
                p.blanks();
                if (p.peek() == '}') {
                    p.i += 1;
                    return obj;
                }
                while (true) {
                    const path = try p.dottedKey();
                    p.blanks();
                    if (p.peek() != '=') return p.fail("`=` was expected", .{});
                    p.i += 1;
                    const v = try p.value();
                    try p.assign(&obj, path, v);
                    p.blanks();
                    if (p.peek() == ',') {
                        p.i += 1;
                        continue;
                    }
                    if (p.peek() == '}') {
                        p.i += 1;
                        return obj;
                    }
                    return p.fail("`,` or `}}` was expected in an inline table", .{});
                }
            },
            else => {
                const w = p.scalarWord();
                if (std.mem.eql(u8, w, "true")) return .{ .bool = true };
                if (std.mem.eql(u8, w, "false")) return .{ .bool = false };
                if (w.len == 0) return p.fail("a value was expected", .{});
                if (p.number(w)) |n| return n;
                if (std.ascii.isDigit(w[0])) return .{ .string = w }; // a date or time
                return p.fail("`{s}` is not a TOML value", .{w});
            },
        }
    }

    /// The table `path` below `root`, made on the way; an array of tables is entered at its last element.
    fn descend(p: *P, root: *Value, path: []const []const u8) Error!*Value {
        var cur = root;
        for (path) |k| {
            const gop = cur.object.getOrPut(k) catch return error.OutOfMemory;
            if (!gop.found_existing) gop.value_ptr.* = val.newObject(p.a);
            cur = gop.value_ptr;
            if (cur.* == .array) {
                if (cur.array.items.len == 0) return p.fail("`{s}` is an empty array, not a table", .{k});
                cur = &cur.array.items[cur.array.items.len - 1];
            }
            if (cur.* != .object) return p.fail("`{s}` is not a table", .{k});
        }
        return cur;
    }

    fn assign(p: *P, table: *Value, path: []const []const u8, v: Value) Error!void {
        const t = try p.descend(table, path[0 .. path.len - 1]);
        const last = path[path.len - 1];
        if (t.object.contains(last)) return p.fail("the key `{s}` is defined twice", .{last});
        t.object.put(last, v) catch return error.OutOfMemory;
    }
};

/// The document. On a syntax error `Parsed.msg` and `Parsed.line` say where.
pub fn parse(a: std.mem.Allocator, text: []const u8) Parsed {
    var p = P{ .a = a, .s = text };
    const v = run(&p) catch |e| switch (e) {
        error.Syntax => return .{ .value = .null, .line = p.line, .msg = p.msg },
        error.OutOfMemory => return .{ .value = .null, .line = p.line, .msg = "out of memory" },
    };
    return .{ .value = v };
}

fn run(p: *P) Error!Value {
    var root = val.newObject(p.a);
    var cur: *Value = &root;
    while (true) {
        p.space();
        const c = p.peek() orelse break;
        if (c == '[') {
            const array = p.i + 1 < p.s.len and p.s[p.i + 1] == '[';
            p.i += if (array) 2 else 1;
            const path = try p.dottedKey();
            p.blanks();
            const close = if (array) "]]" else "]";
            if (!std.mem.startsWith(u8, p.s[p.i..], close)) return p.fail("`{s}` was expected after a table name", .{close});
            p.i += close.len;
            if (array) {
                const parent = try p.descend(&root, path[0 .. path.len - 1]);
                const last = path[path.len - 1];
                const gop = parent.object.getOrPut(last) catch return error.OutOfMemory;
                if (!gop.found_existing) gop.value_ptr.* = val.newArray(p.a);
                if (gop.value_ptr.* != .array) return p.fail("`{s}` is not an array of tables", .{last});
                gop.value_ptr.array.append(val.newObject(p.a)) catch return error.OutOfMemory;
                cur = &gop.value_ptr.array.items[gop.value_ptr.array.items.len - 1];
            } else {
                cur = try p.descend(&root, path);
            }
            try p.endOfLine();
            continue;
        }
        const path = try p.dottedKey();
        p.blanks();
        if (p.peek() != '=') return p.fail("`=` was expected after the key `{s}`", .{path[path.len - 1]});
        p.i += 1;
        const v = try p.value();
        try p.assign(cur, path, v);
        try p.endOfLine();
    }
    return root;
}

/// The value at the dotted path below `v` (`get(doc, &.{"package", "links"})`).
pub fn at(v: Value, path: []const []const u8) ?Value {
    var cur = v;
    for (path) |k| cur = val.get(cur, k) orelse return null;
    return cur;
}
