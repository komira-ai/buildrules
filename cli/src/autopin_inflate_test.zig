//! The deflate decoder: golden streams of all three block types, its output limit at the byte, and streams that are
//! wrong in each way it names.

const std = @import("std");
const inflate = @import("autopin_inflate.zig");
const t = std.testing;
const oom = @import("autopin_oom_test.zig");

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

/// Like `expectError`, but a stream that unexpectedly inflates is reported by its length, not printed.
fn failsWith(expected: anyerror, actual: anyerror![]u8) !void {
    if (actual) |got| {
        std.debug.print("expected {s}, inflated {d} bytes\n", .{ @errorName(expected), got.len });
        return error.TestUnexpectedResult;
    } else |e| {
        if (e != expected) {
            std.debug.print("expected {s}, found {s}\n", .{ @errorName(expected), @errorName(e) });
            return error.TestUnexpectedResult;
        }
    }
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

test "the limit holds to the byte: a stored block" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqual(@as(usize, 12), (try inflate.inflate(a, &stored_hello, 12)).len);
    try failsWith(error.TooLong, inf(a, &stored_hello, 11));
    try failsWith(error.TooLong, inf(a, &stored_hello, 0));
}

test "the limit holds to the byte: the literals of a fixed block" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqual(@as(usize, 12), (try inflate.inflate(a, &fixed_hello, 12)).len);
    try failsWith(error.TooLong, inf(a, &fixed_hello, 11));
    try failsWith(error.TooLong, inf(a, &fixed_hello, 0));
}

test "the limit holds to the byte: a dynamic block" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqual(@as(usize, 19), (try inflate.inflate(a, &dynamic_abc, 19)).len);
    try failsWith(error.TooLong, inf(a, &dynamic_abc, 18));
}

test "the limit holds to the byte: a match that would run past it by one byte is refused before any of it is written" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const run = try runOfA(a, 3);
    try t.expectEqual(@as(usize, 775), (try inflate.inflate(a, run, 775)).len);
    try failsWith(error.TooLong, inf(a, run, 774));
    try failsWith(error.TooLong, inf(a, run, 100));
}

test "huffman: an over-subscribed code is refused, a complete or an incomplete one is accepted" {
    var h = inflate.Huffman{};
    try t.expectError(error.Invalid, h.build(&.{ 1, 1, 1 }, .any));
    try t.expectError(error.Invalid, h.build(&.{ 1, 1, 2 }, .any));
    try h.build(&.{ 1, 2, 2 }, .complete);
    try h.build(&.{1}, .puff);
    try h.build(&.{ 0, 0, 0 }, .puff);
}

test "a bomb is cut off at the limit however small the stream is" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const bomb = try runOfA(a, 20000);
    try t.expect(bomb.len < 40000);
    try failsWith(error.TooLong, inf(a, bomb, 100));
    try failsWith(error.TooLong, inf(a, bomb, 1 << 20));
    try t.expectEqual(@as(usize, 1 + 258 * 20000), (try inflate.inflate(a, bomb, 1 + 258 * 20000)).len);
}

test "every proper prefix of a stream is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const streams = [_][]const u8{ &stored_hello, &fixed_hello, &dynamic_abc };
    for (streams) |s| {
        var n: usize = 0;
        while (n < s.len) : (n += 1) try failsWith(error.Invalid, inf(a, s[0..n], 1000));
    }
}

test "bytes after the last block are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const streams = [_][]const u8{ &stored_hello, &fixed_hello, &dynamic_abc };
    for (streams) |s| {
        const longer = try std.mem.concat(a, u8, &.{ s, "x" });
        try failsWith(error.TrailingData, inf(a, longer, 1000));
    }
}

test "a stored block whose length is not the complement of its check is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var bad = stored_hello;
    bad[3] = 0xf4;
    try failsWith(error.Invalid, inf(a, &bad, 1000));
}

test "block type 3 is refused" {
    var ar = arena();
    defer ar.deinit();
    try failsWith(error.Invalid, inf(ar.allocator(), &.{0b0000_0111}, 1000));
}

test "a distance before the start of the output is refused" {
    var ar = arena();
    defer ar.deinit();
    // BFINAL, fixed; length code 257 (7 bits 0000001); distance code 0 (5 bits 00000); end of block.
    // Bits, low first: 1,1,0 | 0,0,0,0,0,0,1 | 0,0,0,0,0 | 0,0,0,0,0,0,0
    const bad = [_]u8{ 0b0000_0011, 0b0000_0010, 0b0000_0000, 0b0000_0000 };
    try failsWith(error.Invalid, inf(ar.allocator(), &bad, 1000));
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

test "huffman: an incomplete code is refused, except a lone length-1 code or no code where puff allows it" {
    var h = inflate.Huffman{};
    try t.expectError(error.Invalid, h.build(&.{ 2, 2 }, .complete));
    try t.expectError(error.Invalid, h.build(&.{ 2, 2 }, .puff));
    try t.expectError(error.Invalid, h.build(&.{ 1, 2 }, .puff));
    try t.expectError(error.Invalid, h.build(&.{1}, .complete));
    try t.expectError(error.Invalid, h.build(&.{ 0, 0 }, .complete));
    try t.expectError(error.Invalid, h.build(&.{2}, .puff));
    try h.build(&.{ 2, 2 }, .any);
    try h.build(&.{ 1, 1 }, .complete);
    try h.build(&.{ 1, 0 }, .puff);
}

/// Bits of a header, least significant first.
fn bitsOf(a: std.mem.Allocator, fields: []const [2]u32) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var cur: u8 = 0;
    var n: u4 = 0;
    for (fields) |f| {
        var i: u32 = 0;
        while (i < f[1]) : (i += 1) {
            cur |= @as(u8, @intCast((f[0] >> @as(u5, @intCast(@min(i, 31)))) & 1)) << @intCast(n);
            n += 1;
            if (n == 8) {
                try out.append(a, cur);
                cur = 0;
                n = 0;
            }
        }
    }
    if (n > 0) try out.append(a, cur);
    return out.items;
}

test "a dynamic header that asks for more than 286 length codes is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // BFINAL 1, BTYPE 2, HLIT 29 (286 + 2 = 288 codes), HDIST 0, HCLEN 0, then plenty of bytes
    const s = try bitsOf(a, &.{ .{ 1, 1 }, .{ 2, 2 }, .{ 31, 5 }, .{ 0, 5 }, .{ 0, 4 }, .{ 0, 64 } });
    try failsWith(error.Invalid, inf(a, s, 100));
}

test "a dynamic header that asks for more than 30 distance codes is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const s = try bitsOf(a, &.{ .{ 1, 1 }, .{ 2, 2 }, .{ 0, 5 }, .{ 31, 5 }, .{ 0, 4 }, .{ 0, 64 } });
    try failsWith(error.Invalid, inf(a, s, 100));
}

test "a dynamic block whose code lengths run past the number it announced is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // HLIT 0 (257) and HDIST 0 (1): 258 lengths. The code-length code has two symbols, 0 and 18, each of length 1 (0 is "0", 18 is "1").
    // Order of the three-bit lengths: 16, 17, 18, 0 (HCLEN 0 = four of them). Then symbol 18 with 138 repeats twice: 276 > 258.
    const s = try bitsOf(a, &.{ .{ 1, 1 }, .{ 2, 2 }, .{ 0, 5 }, .{ 0, 5 }, .{ 0, 4 }, .{ 0, 3 }, .{ 0, 3 }, .{ 1, 3 }, .{ 1, 3 }, .{ 1, 1 }, .{ 127, 7 }, .{ 1, 1 }, .{ 127, 7 }, .{ 0, 32 } });
    try failsWith(error.Invalid, inf(a, s, 100));
}

test "a dynamic block with an incomplete code-length code is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // HCLEN 0: lengths for 16, 17, 18, 0 are 0, 0, 0, 1: one code of length 1 is incomplete for the code-length code.
    const s = try bitsOf(a, &.{ .{ 1, 1 }, .{ 2, 2 }, .{ 0, 5 }, .{ 0, 5 }, .{ 0, 4 }, .{ 0, 3 }, .{ 0, 3 }, .{ 0, 3 }, .{ 1, 3 }, .{ 0, 64 } });
    try failsWith(error.Invalid, inf(a, s, 100));
}

test "fuzz: random and mutated streams never write past the limit and never crash" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    const maxes = [_]usize{ 0, 1, 2, 5, 100, 1 << 16 };
    var n: usize = 0;
    while (n < 20000) : (n += 1) {
        const len = r.intRangeAtMost(usize, 1, 80);
        const buf = try a.alloc(u8, len);
        r.bytes(buf);
        if (n % 3 == 0) buf[0] = (buf[0] & 0xf8) | 0b101;
        if (n % 3 == 1) buf[0] = (buf[0] & 0xf8) | 0b011;
        for (maxes) |m| {
            if (inflate.inflate(a, buf, m)) |out| try t.expect(out.len <= m) else |_| {}
        }
    }
}



test "oom: inflating each kind of block fails closed at every allocation" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const run = struct {
        fn f(al: std.mem.Allocator, args: anytype) !bool {
            _ = inflate.inflate(al, args.bytes, 1 << 20) catch return true;
            return false;
        }
    }.f;
    try oom.sweep(run, .{ .bytes = @as([]const u8, &stored_hello) });
    try oom.sweep(run, .{ .bytes = @as([]const u8, &fixed_hello) });
    try oom.sweep(run, .{ .bytes = @as([]const u8, &dynamic_abc) });
    try oom.sweep(run, .{ .bytes = try runOfA(a, 3) });
}

/// `inflate.inflate`, after running it under the allocation-failure sweep.
fn inf(a: std.mem.Allocator, src: []const u8, max: usize) inflate.Error![]u8 {
    oom.mustSweep(struct {
        fn f(al: std.mem.Allocator, args: anytype) !bool {
            _ = inflate.inflate(al, args.src, args.max) catch return true;
            return false;
        }
    }.f, .{ .src = src, .max = max });
    return inflate.inflate(a, src, max);
}
