//! The character sets of valid.zig. The lock is Starlark that Buck2 executes, so each check is the line between a registry's text and code in the
//! build graph. Every test says which byte or length it moves the line over; the allowed sets are written out again here, as strings, so a changed
//! range or a dropped character in valid.zig is a failing byte, not a test that follows the code.

const std = @import("std");
const valid = @import("valid.zig");
const t = std.testing;

const digits = "0123456789";
const lower = "abcdefghijklmnopqrstuvwxyz";
const upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
const alnum = digits ++ lower ++ upper;

fn inSet(set: []const u8, b: u8) bool {
    return std.mem.indexOfScalar(u8, set, b) != null;
}

/// `f` over the one-byte string of every byte, against the set it must accept.
fn oneByte(comptime f: fn ([]const u8) bool, set: []const u8, what: []const u8) !void {
    var c: usize = 0;
    while (c < 256) : (c += 1) {
        const b: u8 = @intCast(c);
        const s = [_]u8{b};
        if (f(&s) != inSet(set, b)) {
            std.debug.print("{s}: byte {d} is {s}\n", .{ what, b, if (inSet(set, b)) "refused" else "accepted" });
            return error.WrongClass;
        }
    }
}

/// `f` over a letter, every byte, a letter: the check reaches the bytes after the first and before the last.
fn insideBytes(comptime f: fn ([]const u8) bool, set: []const u8, what: []const u8) !void {
    var c: usize = 0;
    while (c < 256) : (c += 1) {
        const b: u8 = @intCast(c);
        const s = [_]u8{ 'a', b, 'a' };
        if (f(&s) != inSet(set, b)) {
            std.debug.print("{s}: byte {d} inside a name is {s}\n", .{ what, b, if (inSet(set, b)) "refused" else "accepted" });
            return error.WrongClass;
        }
    }
}

test "isToken, isVersion, isPinName: each byte is in or out of its set" {
    const token = alnum ++ "-_.+";
    try oneByte(valid.isToken, token, "isToken");
    try insideBytes(valid.isToken, token, "isToken");
    // A version starts with a letter or digit; a token may start with any of its characters.
    try oneByte(valid.isVersion, alnum, "isVersion");
    try insideBytes(valid.isVersion, token, "isVersion");
    try oneByte(valid.isPinName, digits ++ lower, "isPinName");
    try insideBytes(valid.isPinName, digits ++ lower ++ "-_", "isPinName");
    try t.expect(valid.isToken("-"));
    try t.expect(!valid.isVersion("-1"));
    try t.expect(!valid.isVersion("_1"));
    try t.expect(!valid.isPinName("-a"));
    try t.expect(!valid.isPinName("_a"));
    try t.expect(valid.isPinName("a-b_c1"));
}

fn repeat(a: std.mem.Allocator, ch: u8, n: usize) ![]u8 {
    const s = try a.alloc(u8, n);
    @memset(s, ch);
    return s;
}

test "the length limits are inclusive: 64, 64, 64, 128, 214 and 2048 pass and one more fails" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const fns = .{
        .{ valid.isToken, 64 },
        .{ valid.isVersion, 64 },
        .{ valid.isPinName, 64 },
        .{ valid.isJsonPath, 128 },
        .{ valid.isPackageName, 214 },
    };
    inline for (fns) |entry| {
        try t.expect(entry[0](try repeat(a, 'a', entry[1])));
        try t.expect(!entry[0](try repeat(a, 'a', entry[1] + 1)));
        try t.expect(!entry[0](""));
    }
    const url_ok = try std.mem.concat(a, u8, &.{ "https://", try repeat(a, 'a', 2048 - 8) });
    try t.expect(valid.isUrl(url_ok));
    try t.expect(!valid.isUrl(try std.mem.concat(a, u8, &.{ url_ok, "a" })));
}

test "isPackageName: the scope and slash rules" {
    try t.expectEqual(true, valid.isPackageName("left-pad"));
    try t.expectEqual(true, valid.isPackageName("@scope/name"));
    try t.expectEqual(true, valid.isPackageName("a.b+c@d_e"));
    try t.expectEqual(false, valid.isPackageName("/abs"));
    try t.expectEqual(false, valid.isPackageName(".hidden"));
    try t.expectEqual(false, valid.isPackageName("trailing/"));
    try t.expectEqual(false, valid.isPackageName("a/../b"));
    try t.expectEqual(false, valid.isPackageName("a//b"));
    try t.expectEqual(false, valid.isPackageName("quo\"te"));
    try t.expectEqual(false, valid.isPackageName("with space"));
    try insideBytes(valid.isPackageName, alnum ++ "-_.@/+", "isPackageName");
}

test "isUrl: scheme, host and the character set" {
    try t.expect(valid.isUrl("https://registry.example/a-b/c?x=1&y=2#f"));
    try t.expect(valid.isUrl("http://registry.example"));
    try t.expect(!valid.isUrl("ftp://registry.example"));
    try t.expect(!valid.isUrl("https://"));
    try t.expect(!valid.isUrl("http://"));
    try t.expect(!valid.isUrl("https:///etc/passwd"));
    try t.expect(!valid.isUrl("http:///x"));
    try t.expect(!valid.isUrl(""));
    try t.expect(!valid.isUrl("https://a\"b"));
    var c: usize = 0;
    const set = alnum ++ "-._~:/?#@&+,;=%";
    while (c < 256) : (c += 1) {
        const b: u8 = @intCast(c);
        const s = [_]u8{ 'h', 't', 't', 'p', 's', ':', '/', '/', 'a', b };
        try t.expectEqual(inSet(set, b), valid.isUrl(&s));
    }
}

test "isSha256 and isSri512: lower-case hex of 64 digits; sha512- and 64 bytes of base64" {
    const hex64 = "0123456789abcdef" ** 4;
    try t.expect(valid.isSha256(hex64));
    try t.expect(!valid.isSha256(hex64[1..]));
    try t.expect(!valid.isSha256(hex64 ++ "0"));
    var buf: [64]u8 = hex64.*;
    var c: usize = 0;
    while (c < 256) : (c += 1) {
        const b: u8 = @intCast(c);
        buf[17] = b;
        try t.expectEqual(inSet(digits ++ "abcdef", b), valid.isSha256(&buf));
    }
    var raw: [64]u8 = undefined;
    for (&raw, 0..) |*r, i| r.* = @intCast(i * 3);
    var enc: [88]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&enc, &raw);
    var sri: [95]u8 = undefined;
    @memcpy(sri[0..7], "sha512-");
    @memcpy(sri[7..], &enc);
    try t.expect(valid.isSri512(&sri));
    try t.expect(!valid.isSri512(sri[0..94]));
    try t.expect(!valid.isSri512(""));
    var wrong = sri;
    @memcpy(wrong[0..7], "sha256-");
    try t.expect(!valid.isSri512(&wrong));
    // 88 characters of the right length, one of them not base64: the length is not the whole check.
    var bad = sri;
    bad[20] = '*';
    try t.expect(!valid.isSri512(&bad));
}

test "isJsonPath: dotted segments, no empty one" {
    try t.expect(valid.isJsonPath("a.b-c_d.e1"));
    try t.expect(valid.isJsonPath("tag_name"));
    try t.expect(!valid.isJsonPath(".a"));
    try t.expect(!valid.isJsonPath("a."));
    try t.expect(!valid.isJsonPath("a..b"));
    try t.expect(!valid.isJsonPath("a/b"));
    try insideBytes(valid.isJsonPath, alnum ++ "_-.", "isJsonPath");
}
