//! The deflate decoder: golden streams of all three block types, its output limit at the byte, and streams that are
//! wrong in each way it names.

const std = @import("std");
const inflate = @import("autopin_inflate.zig");
const t = std.testing;

const stored_hello = [_]u8{ 0b0000_0001, 0b0000_1100, 0x00, 0b1111_0011, 0xff, 'H', 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd', 0x0a };
const fixed_hello = [_]u8{ 0xf3, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf, 0x2f, 0xca, 0x49, 0xe1, 0x02, 0x00 };
const dynamic_abc = [_]u8{
    0x3d, 0xc6, 0x39, 0x11, 0x00, 0x00, 0x0c, 0x02,
    0x30, 0x2b, 0xb5, 0x52, 0x1e, 0xff, 0x96, 0x38,
    0x16, 0x96, 0x5c, 0x1e, 0x94, 0xcb, 0x6d, 0x01,
};

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

/// A fixed-Huffman stream: the byte 'a', then `count` matches of 258 bytes at distance 1.
fn runOfA(a: std.mem.Allocator, count: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var cur: u8 = 0;
    var nbits: u4 = 0;
    const W = struct {
        fn bit(o: *std.ArrayList(u8), al: std.mem.Allocator, c: *u8, n: *u4, b: u1) !void {
            c.* |= @as(u8, b) << @intCast(n.*);
            n.* += 1;
            if (n.* == 8) {
                try o.append(al, c.*);
                c.* = 0;
                n.* = 0;
            }
        }
        fn code(o: *std.ArrayList(u8), al: std.mem.Allocator, c: *u8, n: *u4, v: u16, len: u4) !void {
            var i: u4 = len;
            while (i > 0) {
                i -= 1;
                try bit(o, al, c, n, @intCast((v >> i) & 1));
            }
        }
    };
    try W.bit(&out, a, &cur, &nbits, 1);
    try W.bit(&out, a, &cur, &nbits, 1);
    try W.bit(&out, a, &cur, &nbits, 0);
    try W.code(&out, a, &cur, &nbits, 0x30 + 'a', 8);
    var k: usize = 0;
    while (k < count) : (k += 1) {
        try W.code(&out, a, &cur, &nbits, 0xC0 + 5, 8);
        try W.code(&out, a, &cur, &nbits, 0, 5);
    }
    try W.code(&out, a, &cur, &nbits, 0, 7);
    if (nbits > 0) try out.append(a, cur);
    return out.items;
}

test "the three block types decode the golden streams" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("Hello world\n", try inflate.inflate(a, &stored_hello, 1000));
    try t.expectEqualStrings("Hello world\n", try inflate.inflate(a, &fixed_hello, 1000));
    try t.expectEqualStrings("ABCDEABCD ABCDEABCD", try inflate.inflate(a, &dynamic_abc, 1000));
}

test "a long run of matches inflates to the run" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const s = try runOfA(a, 5000);
    const got = try inflate.inflate(a, s, 1 << 22);
    try t.expectEqual(@as(usize, 1 + 258 * 5000), got.len);
    for (got) |b| try t.expectEqual(@as(u8, 'a'), b);
}

test "the limit holds to the byte, in every block type" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const streams = [_][]const u8{ &stored_hello, &fixed_hello, &dynamic_abc };
    const sizes = [_]usize{ 12, 12, 19 };
    for (streams, sizes) |s, n| {
        try t.expectEqual(n, (try inflate.inflate(a, s, n)).len);
        try t.expectError(error.TooLong, inflate.inflate(a, s, n - 1));
        try t.expectError(error.TooLong, inflate.inflate(a, s, 0));
    }
    // A match that would run past the limit by one byte is refused before any of it is written.
    const run = try runOfA(a, 3);
    try t.expectEqual(@as(usize, 775), (try inflate.inflate(a, run, 775)).len);
    try t.expectError(error.TooLong, inflate.inflate(a, run, 774));
    try t.expectError(error.TooLong, inflate.inflate(a, run, 100));
}

test "a bomb is cut off at the limit however small the stream is" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const bomb = try runOfA(a, 20000);
    try t.expect(bomb.len < 40000);
    try t.expectError(error.TooLong, inflate.inflate(a, bomb, 100));
    try t.expectError(error.TooLong, inflate.inflate(a, bomb, 1 << 20));
    try t.expectEqual(@as(usize, 1 + 258 * 20000), (try inflate.inflate(a, bomb, 1 + 258 * 20000)).len);
}

test "every proper prefix of a stream is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const streams = [_][]const u8{ &stored_hello, &fixed_hello, &dynamic_abc };
    for (streams) |s| {
        var n: usize = 0;
        while (n < s.len) : (n += 1) try t.expectError(error.Invalid, inflate.inflate(a, s[0..n], 1000));
    }
}

test "bytes after the last block are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const streams = [_][]const u8{ &stored_hello, &fixed_hello, &dynamic_abc };
    for (streams) |s| {
        const longer = try std.mem.concat(a, u8, &.{ s, "x" });
        try t.expectError(error.TrailingData, inflate.inflate(a, longer, 1000));
    }
}

test "a stored block whose length is not the complement of its check is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var bad = stored_hello;
    bad[3] = 0xf4;
    try t.expectError(error.Invalid, inflate.inflate(a, &bad, 1000));
}

test "block type 3 is refused" {
    var ar = arena();
    defer ar.deinit();
    try t.expectError(error.Invalid, inflate.inflate(ar.allocator(), &.{0b0000_0111}, 1000));
}

test "a distance before the start of the output is refused" {
    var ar = arena();
    defer ar.deinit();
    // BFINAL, fixed; length code 257 (7 bits 0000001); distance code 0 (5 bits 00000); end of block.
    // Bits, low first: 1,1,0 | 0,0,0,0,0,0,1 | 0,0,0,0,0 | 0,0,0,0,0,0,0
    const bad = [_]u8{ 0b0000_0011, 0b0000_0010, 0b0000_0000, 0b0000_0000 };
    try t.expectError(error.Invalid, inflate.inflate(ar.allocator(), &bad, 1000));
}

test "no single changed byte or bit of a dynamic stream crashes the decoder (every result is bytes or an error)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var i: usize = 0;
    while (i < dynamic_abc.len) : (i += 1) {
        var bit: u4 = 0;
        while (bit < 8) : (bit += 1) {
            var copy = dynamic_abc;
            copy[i] ^= @as(u8, 1) << @intCast(bit);
            if (inflate.inflate(a, &copy, 1000)) |got| {
                try t.expect(got.len <= 1000);
            } else |_| {}
        }
        var byte: u16 = 0;
        while (byte < 256) : (byte += 1) {
            var copy = dynamic_abc;
            copy[i] = @intCast(byte);
            if (inflate.inflate(a, &copy, 64)) |got| {
                try t.expect(got.len <= 64);
            } else |_| {}
        }
    }
}
