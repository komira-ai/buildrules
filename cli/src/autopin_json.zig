//! A strict JSON reader for the one document `autopin` accepts from an untrusted artifact (the manifest).
//! It exists because `std.json` accepts what a strict reader must refuse: a key twice (the last one wins
//! there), a number that is not the integer it was supposed to be, string escapes, bytes above 0x7f. Here:
//!   - a duplicate key in any object is an error;
//!   - an integer is `-?(0|[1-9][0-9]*)` with at most 15 digits; a number with a fraction or exponent is a
//!     `float` value, kept apart so a caller can name the difference;
//!   - a string has no backslash, no byte below 0x20 and no byte above 0x7e (so no escape, no NUL, no Unicode);
//!   - the only white space is space, tab, newline and carriage return; nesting is at most `max_depth`;
//!   - nothing follows the value.

const std = @import("std");

pub const max_depth = 6;

pub const Member = struct { key: []const u8, value: Value };

pub const Value = union(enum) {
    object: []const Member,
    array: []const Value,
    string: []const u8,
    int: i64,
    float,
    boolean: bool,
    nil,

    pub fn get(self: Value, key: []const u8) ?Value {
        if (self != .object) return null;
        for (self.object) |m| if (std.mem.eql(u8, m.key, key)) return m.value;
        return null;
    }
};

pub const Error = error{
    Syntax,
    DuplicateKey,
    TooDeep,
    TrailingData,
    BadString,
    BadNumber,
    OutOfMemory,
};

const Parser = struct {
    a: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,

    fn skip(self: *Parser) void {
        while (self.i < self.s.len) : (self.i += 1) {
            switch (self.s[self.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return,
            }
        }
    }

    fn peek(self: *Parser) ?u8 {
        self.skip();
        return if (self.i < self.s.len) self.s[self.i] else null;
    }

    fn string(self: *Parser) Error![]const u8 {
        if (self.peek() != '"') return error.Syntax;
        self.i += 1;
        const start = self.i;
        while (self.i < self.s.len and self.s[self.i] != '"') : (self.i += 1) {
            const c = self.s[self.i];
            if (c < 0x20 or c > 0x7e or c == '\\') return error.BadString;
        }
        if (self.i >= self.s.len) return error.Syntax;
        const r = self.s[start..self.i];
        self.i += 1;
        return r;
    }

    fn number(self: *Parser) Error!Value {
        const start = self.i;
        if (self.s[self.i] == '-') self.i += 1;
        const digits_start = self.i;
        while (self.i < self.s.len and self.s[self.i] >= '0' and self.s[self.i] <= '9') self.i += 1;
        const digits = self.s[digits_start..self.i];
        if (digits.len == 0 or digits.len > 15) return error.BadNumber;
        if (digits.len > 1 and digits[0] == '0') return error.BadNumber;
        var is_float = false;
        if (self.i < self.s.len and (self.s[self.i] == '.' or self.s[self.i] == 'e' or self.s[self.i] == 'E')) {
            is_float = true;
            while (self.i < self.s.len and (std.ascii.isDigit(self.s[self.i]) or self.s[self.i] == '.' or self.s[self.i] == 'e' or self.s[self.i] == 'E' or self.s[self.i] == '+' or self.s[self.i] == '-')) self.i += 1;
        }
        if (is_float) return .float;
        return .{ .int = std.fmt.parseInt(i64, self.s[start..self.i], 10) catch return error.BadNumber };
    }

    fn value(self: *Parser, depth: usize) Error!Value {
        if (depth > max_depth) return error.TooDeep;
        const c = self.peek() orelse return error.Syntax;
        switch (c) {
            '"' => return .{ .string = try self.string() },
            '{' => {
                self.i += 1;
                var members = std.ArrayList(Member).empty;
                if (self.peek() == '}') {
                    self.i += 1;
                    return .{ .object = members.items };
                }
                while (true) {
                    const k = try self.string();
                    for (members.items) |m| if (std.mem.eql(u8, m.key, k)) return error.DuplicateKey;
                    if (self.peek() != ':') return error.Syntax;
                    self.i += 1;
                    const v = try self.value(depth + 1);
                    try members.append(self.a, .{ .key = k, .value = v });
                    const n = self.peek() orelse return error.Syntax;
                    self.i += 1;
                    if (n == '}') break;
                    if (n != ',') return error.Syntax;
                }
                return .{ .object = members.items };
            },
            '[' => {
                self.i += 1;
                var items = std.ArrayList(Value).empty;
                if (self.peek() == ']') {
                    self.i += 1;
                    return .{ .array = items.items };
                }
                while (true) {
                    try items.append(self.a, try self.value(depth + 1));
                    const n = self.peek() orelse return error.Syntax;
                    self.i += 1;
                    if (n == ']') break;
                    if (n != ',') return error.Syntax;
                }
                return .{ .array = items.items };
            },
            't' => return self.word("true", .{ .boolean = true }),
            'f' => return self.word("false", .{ .boolean = false }),
            'n' => return self.word("null", .nil),
            '-', '0'...'9' => return self.number(),
            else => return error.Syntax,
        }
    }

    fn word(self: *Parser, comptime w: []const u8, v: Value) Error!Value {
        if (!std.mem.startsWith(u8, self.s[self.i..], w)) return error.Syntax;
        self.i += w.len;
        return v;
    }
};

pub fn parse(a: std.mem.Allocator, text: []const u8) Error!Value {
    var p = Parser{ .a = a, .s = text };
    const v = try p.value(0);
    if (p.peek() != null) return error.TrailingData;
    return v;
}
