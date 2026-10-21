//! inflate.zig: DEFLATE and gzip. The streams are written by testkit.zig's own encoder (stored, fixed and dynamic blocks with run-length coded code lengths, matches
//! at every distance and length), so a decoder defect is a mismatch with what the encoder meant, and every refusal is a hand-built stream.
const std = @import("std");
const kit = @import("testkit.zig");
const inflate = @import("inflate.zig");
const stream = @import("stream.zig");
const t = std.testing;
const a = kit.a;

const Collect = struct {
    list: std.ArrayList(u8) = .empty,

    pub fn write(self: *Collect, bytes: []const u8) !void {
        try self.list.appendSlice(a, bytes);
    }
};

/// What the gzip file decodes to; the caller frees.
fn gunzip(gz: []const u8) ![]u8 {
    var c = Collect{};
    errdefer c.list.deinit(a);
    try inflate.gunzip(a, gz, stream.sinkOf(Collect, &c));
    return c.list.toOwnedSlice(a);
}

fn gunzipFails(gz: []const u8) anyerror!void {
    const out = try gunzip(gz);
    a.free(out);
}

fn expectDecodes(gz: []const u8, want: []const u8) !void {
    const got = try gunzip(gz);
    defer a.free(got);
    try t.expectEqualSlices(u8, want, got);
}

/// A raw DEFLATE stream's output.
fn rawInflate(body: []const u8) !inflate.Result {
    var c = Collect{};
    defer c.list.deinit(a);
    return inflate.inflate(a, body, stream.sinkOf(Collect, &c));
}

test "stored blocks: empty, small, and several of the largest size" {
    try expectStored("");
    try expectStored("hello");
    var big: [150_000]u8 = undefined;
    for (&big, 0..) |*c, i| c.* = @truncate(i *% 31 +% (i >> 8));
    try expectStored(&big);
}

fn expectStored(plain: []const u8) !void {
    const gz = try kit.gzipStored(plain);
    defer a.free(gz);
    try expectDecodes(gz, plain);
}

/// Random tokens and the bytes they decode to: literals from a small alphabet and matches of every length, at distances up to the whole window.
fn randomTokens(seed: u64, size: usize, expected: *std.ArrayList(u8)) ![]kit.Tok {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var toks = std.ArrayList(kit.Tok).empty;
    while (expected.items.len < size) {
        const have = expected.items.len;
        if (have > 0 and r.uintLessThan(u8, 3) == 0) {
            const max_dist: u16 = @intCast(@min(have, 32768));
            const dist: u16 = if (r.uintLessThan(u8, 8) == 0) max_dist else r.intRangeAtMost(u16, 1, max_dist);
            const len: u16 = r.intRangeAtMost(u16, 3, 258);
            var i: usize = 0;
            while (i < len) : (i += 1) try expected.append(a, expected.items[expected.items.len - dist]);
            try toks.append(a, .{ .match = .{ .len = len, .dist = dist } });
        } else {
            const c: u8 = 'a' + r.uintLessThan(u8, 20);
            try expected.append(a, c);
            try toks.append(a, .{ .lit = c });
        }
    }
    return toks.toOwnedSlice(a);
}

const full_lit = blk: {
    var l: [286]u8 = undefined;
    for (&l, 0..) |*x, i| x.* = if (i < 144) 8 else if (i < 256) 9 else if (i < 280) 7 else if (i < 284) 8 else 7;
    break :blk l;
};
const full_dist = [_]u8{ 4, 4 } ++ [_]u8{5} ** 28;

test "fixed and dynamic blocks decode to what the tokens say, across the 64 KiB buffer and the 32 KiB window" {
    for ([_]u64{ 1, 2, 3 }) |seed| {
        var expected = std.ArrayList(u8).empty;
        defer expected.deinit(a);
        const toks = try randomTokens(seed, 300_000, &expected);
        defer a.free(toks);
        const fixed = try kit.deflateFixed(toks);
        defer a.free(fixed);
        const dynamic = try kit.deflateDynamic(toks, &full_lit, &full_dist);
        defer a.free(dynamic);
        for ([_][]const u8{ fixed, dynamic }) |body| {
            const gz = try kit.gzipOf(body, expected.items);
            defer a.free(gz);
            const got = try gunzip(gz);
            defer a.free(got);
            try t.expectEqualSlices(u8, expected.items, got);
        }
    }
}

test "a match of every length and of every distance symbol" {
    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(a);
    var toks = std.ArrayList(kit.Tok).empty;
    defer toks.deinit(a);
    var i: usize = 0;
    while (i < 40000) : (i += 1) {
        const c: u8 = @truncate((i *% 2654435761) >> 7);
        try expected.append(a, c);
        try toks.append(a, .{ .lit = c });
    }
    var len: u16 = 3;
    while (len <= 258) : (len += 1) {
        const dist: u16 = 1 + (len * 127) % 32768;
        var k: usize = 0;
        while (k < len) : (k += 1) try expected.append(a, expected.items[expected.items.len - dist]);
        try toks.append(a, .{ .match = .{ .len = len, .dist = dist } });
    }
    for ([_]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577, 32768 }) |dist| {
        var k: usize = 0;
        while (k < 5) : (k += 1) try expected.append(a, expected.items[expected.items.len - dist]);
        try toks.append(a, .{ .match = .{ .len = 5, .dist = dist } });
    }
    const body = try kit.deflateFixed(toks.items);
    defer a.free(body);
    const gz = try kit.gzipOf(body, expected.items);
    defer a.free(gz);
    try expectDecodes(gz, expected.items);
}

test "an overlapping match repeats its own output" {
    const body = try kit.deflateFixed(&.{ .{ .lit = 'x' }, .{ .match = .{ .len = 258, .dist = 1 } } });
    defer a.free(body);
    const gz = try kit.gzipOf(body, "x" ** 259);
    defer a.free(gz);
    try expectDecodes(gz, "x" ** 259);
}

test "dynamic blocks with sparse codes: runs of zero lengths (symbols 17 and 18) and a distance code of one symbol" {
    var lit = [_]u8{0} ** 286;
    lit['a'] = 2;
    lit['b'] = 2;
    lit['h'] = 3; // five zero lengths before it: symbol 17
    lit[256] = 3;
    lit[257] = 2; // length 3: with the others, a complete code (3 x 1/4 + 2 x 1/8)
    var dist = [_]u8{0} ** 30;
    dist[0] = 1;
    const body = try kit.deflateDynamic(&.{ .{ .lit = 'a' }, .{ .lit = 'b' }, .{ .lit = 'h' }, .{ .match = .{ .len = 3, .dist = 1 } } }, &lit, &dist);
    defer a.free(body);
    const gz = try kit.gzipOf(body, "abhhhh");
    defer a.free(gz);
    try expectDecodes(gz, "abhhhh");
}

test "consumed says how far the stream read, and a trailer follows it" {
    const body = try kit.deflateFixed(&.{ .{ .lit = 'q' }, .{ .lit = 'r' } });
    defer a.free(body);
    var padded = std.ArrayList(u8).empty;
    defer padded.deinit(a);
    try padded.appendSlice(a, body);
    try padded.appendSlice(a, "TRAILER!");
    const r = try rawInflate(padded.items);
    try t.expectEqual(body.len, r.consumed);
    try t.expectEqual(@as(u64, 2), r.len);
    try t.expectEqual(std.hash.Crc32.hash("qr"), r.crc);
}

test "gzip: concatenated members decode to the concatenation" {
    const x = try kit.gzipStored("first ");
    defer a.free(x);
    const y = try kit.gzipStored("second");
    defer a.free(y);
    const both = try std.mem.concat(a, u8, &.{ x, y });
    defer a.free(both);
    try expectDecodes(both, "first second");
}

/// A gzip file with the optional header parts the flags name.
fn gzipWith(flags: u8, parts: []const u8, plain: []const u8) ![]u8 {
    const body = try kit.deflateStored(plain);
    defer a.free(body);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, &.{ 0x1f, 0x8b, 8, flags, 1, 2, 3, 4, 0, 3 });
    try out.appendSlice(a, parts);
    try out.appendSlice(a, body);
    var tr: [8]u8 = undefined;
    std.mem.writeInt(u32, tr[0..4], std.hash.Crc32.hash(plain), .little);
    std.mem.writeInt(u32, tr[4..8], @intCast(plain.len), .little);
    try out.appendSlice(a, &tr);
    return out.toOwnedSlice(a);
}

test "gzip: the optional header parts are skipped (extra field, name, comment, header CRC)" {
    const extra = try gzipWith(4, "\x03\x00abc", "payload");
    defer a.free(extra);
    try expectDecodes(extra, "payload");
    const name = try gzipWith(8, "file.tar\x00", "payload");
    defer a.free(name);
    try expectDecodes(name, "payload");
    const comment = try gzipWith(16, "a comment\x00", "payload");
    defer a.free(comment);
    try expectDecodes(comment, "payload");
    // the header CRC is the low 16 bits of the CRC-32 of the header up to it
    const hdr = [_]u8{ 0x1f, 0x8b, 8, 2, 1, 2, 3, 4, 0, 3 };
    var crc: [2]u8 = undefined;
    std.mem.writeInt(u16, &crc, @truncate(std.hash.Crc32.hash(&hdr)), .little);
    const hcrc = try gzipWith(2, &crc, "payload");
    defer a.free(hcrc);
    try expectDecodes(hcrc, "payload");
    const all = try gzipWith(4 | 8 | 16, "\x01\x00z" ++ "n\x00" ++ "c\x00", "payload");
    defer a.free(all);
    try expectDecodes(all, "payload");
}

test "gzip: a wrong header CRC is refused" {
    const bad = try gzipWith(2, "\x00\x00", "payload");
    defer a.free(bad);
    try t.expectError(error.Corrupt, gunzipFails(bad));
}

test "gzip: not gzip, not deflate, reserved flags" {
    try t.expectError(error.NotGzip, gunzipFails(""));
    try t.expectError(error.NotGzip, gunzipFails("\x1f"));
    try t.expectError(error.NotGzip, gunzipFails("PK\x03\x04 and more bytes"));
    try t.expectError(error.Truncated, gunzipFails("\x1f\x8b\x08\x00\x00"));
    const method = try kit.gzipStored("x");
    defer a.free(method);
    method[2] = 9;
    try t.expectError(error.Corrupt, gunzipFails(method));
    const flags = try kit.gzipStored("x");
    defer a.free(flags);
    flags[3] = 0x20;
    try t.expectError(error.Corrupt, gunzipFails(flags));
}

test "gzip: a header that ends inside an optional part is truncated" {
    const gz = try gzipWith(4 | 8 | 16 | 2, "\x02\x00zz" ++ "name\x00" ++ "comment\x00" ++ "\x00\x00", "payload");
    defer a.free(gz);
    // cut inside the extra field length, the extra field, the name, the comment, and the header CRC
    for ([_]usize{ 10, 11, 13, 14, 20, 28 }) |cut| {
        try t.expectError(error.Truncated, gunzipFails(gz[0..cut]));
    }
    // a name or comment never terminated
    var open = [_]u8{ 0x1f, 0x8b, 8, 8, 0, 0, 0, 0, 0, 3, 'n', 'a', 'm', 'e' };
    try t.expectError(error.Truncated, gunzipFails(&open));
    // an extra field longer than the file
    const long = [_]u8{ 0x1f, 0x8b, 8, 4, 0, 0, 0, 0, 0, 3, 0xff, 0xff, 'x' };
    try t.expectError(error.Truncated, gunzipFails(&long));
}

test "gzip: a trailer that is wrong, missing, or followed by more" {
    const gz = try kit.gzipStored("hello world");
    defer a.free(gz);
    const crc = try a.dupe(u8, gz);
    defer a.free(crc);
    crc[crc.len - 8] ^= 1;
    try t.expectError(error.BadChecksum, gunzipFails(crc));
    const len = try a.dupe(u8, gz);
    defer a.free(len);
    len[len.len - 4] ^= 1;
    try t.expectError(error.BadLength, gunzipFails(len));
    try t.expectError(error.Truncated, gunzipFails(gz[0 .. gz.len - 1]));
    try t.expectError(error.Truncated, gunzipFails(gz[0 .. gz.len - 8]));
    const more = try std.mem.concat(a, u8, &.{ gz, "x" });
    defer a.free(more);
    try t.expectError(error.TrailingData, gunzipFails(more));
    const zeros = try std.mem.concat(a, u8, &.{ gz, &[_]u8{ 0, 0, 0, 0 } });
    defer a.free(zeros);
    try t.expectError(error.TrailingData, gunzipFails(zeros));
}

test "truncated gzip: no proper prefix of a stream is accepted, whatever the block type" {
    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(a);
    const toks = try randomTokens(9, 3000, &expected);
    defer a.free(toks);
    const fixed = try kit.deflateFixed(toks);
    defer a.free(fixed);
    const dynamic = try kit.deflateDynamic(toks, &full_lit, &full_dist);
    defer a.free(dynamic);
    const stored = try kit.deflateStored(expected.items);
    defer a.free(stored);
    for ([_][]const u8{ fixed, dynamic, stored }) |body| {
        const gz = try kit.gzipOf(body, expected.items);
        defer a.free(gz);
        var cut: usize = 0;
        while (cut < gz.len) : (cut += 1) {
            gunzipFails(gz[0..cut]) catch continue;
            std.debug.print("a gzip file cut at {d} of {d} bytes was accepted\n", .{ cut, gz.len });
            return error.TestUnexpectedResult;
        }
        try expectDecodes(gz, expected.items);
    }
}

test "truncated gzip: the cut is Truncated in the stream and in the trailer" {
    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(a);
    const toks = try randomTokens(5, 2000, &expected);
    defer a.free(toks);
    const fixed = try kit.deflateFixed(toks);
    defer a.free(fixed);
    const gz = try kit.gzipOf(fixed, expected.items);
    defer a.free(gz);
    try t.expectError(error.Truncated, gunzipFails(gz[0 .. gz.len / 2]));
    try t.expectError(error.Truncated, gunzipFails(gz[0 .. gz.len - 5]));
}

fn rawBits(build: *const fn (b: *kit.Bits) anyerror!void) !void {
    var b = kit.Bits{};
    try build(&b);
    const body = try b.finish();
    defer a.free(body);
    const r = rawInflate(body);
    try t.expectError(error.Corrupt, r);
}

fn blockType3(b: *kit.Bits) anyerror!void {
    try b.put(1, 1);
    try b.put(3, 2);
}

fn storedMismatch(b: *kit.Bits) anyerror!void {
    try b.put(1, 1);
    try b.put(0, 2);
    try b.put(0, 5); // to the byte boundary
    try b.put(3, 16);
    try b.put(3, 16); // NLEN should be 0xfffc
}

fn fixedSymbol286(b: *kit.Bits) anyerror!void {
    try b.put(1, 1);
    try b.put(1, 2);
    try b.code(0xc0 + 6, 8);
}

fn fixedDistance30(b: *kit.Bits) anyerror!void {
    try b.put(1, 1);
    try b.put(1, 2);
    try b.code(0x30 + 'a', 8);
    try b.code(1, 7); // symbol 257, length 3
    try b.code(30, 5); // distance symbol 30
}

fn dynamicHlit287(b: *kit.Bits) anyerror!void {
    try b.put(1, 1);
    try b.put(2, 2);
    try b.put(30, 5); // HLIT = 287
    try b.put(0, 5);
    try b.put(0, 4);
}

fn dynamicHdist32(b: *kit.Bits) anyerror!void {
    try b.put(1, 1);
    try b.put(2, 2);
    try b.put(0, 5);
    try b.put(31, 5); // HDIST = 32
    try b.put(0, 4);
}

/// The start of a dynamic block with 257 literal and 1 distance lengths, whose code-length code gives symbols 16, 17 and 18 the lengths in `three`.
fn dynamicStart(b: *kit.Bits, three: [3]u3) !void {
    try b.put(1, 1);
    try b.put(2, 2);
    try b.put(0, 5);
    try b.put(0, 5);
    try b.put(15, 4);
    for (three) |l| try b.put(l, 3);
    var i: usize = 0;
    while (i < 16) : (i += 1) try b.put(0, 3);
}

fn clOversubscribed(b: *kit.Bits) anyerror!void {
    try dynamicStart(b, .{ 1, 1, 1 });
}

fn clRepeatFirst(b: *kit.Bits) anyerror!void {
    try dynamicStart(b, .{ 1, 2, 2 });
    try b.put(0, 1); // symbol 16 with nothing before it
    try b.put(0, 2);
}

fn clRepeatOverflow(b: *kit.Bits) anyerror!void {
    try dynamicStart(b, .{ 2, 2, 1 });
    try b.put(0, 1); // symbol 18
    try b.put(127, 7); // 138 zeros
    try b.put(0, 1);
    try b.put(127, 7); // 138 more: past the 258 lengths
}

fn clNoEndOfBlock(b: *kit.Bits) anyerror!void {
    try dynamicStart(b, .{ 2, 2, 1 });
    try b.put(0, 1);
    try b.put(127, 7);
    try b.put(0, 1);
    try b.put(109, 7); // 258 zero lengths in all: no code for the end of block
}

fn unassignedCode(b: *kit.Bits) anyerror!void {
    // a literal code that is complete (a: 0, end of block: 10, symbol 257: 11) and a distance code of one symbol of length 1: the bit `1` is no distance
    var lit = [_]u8{0} ** 286;
    lit['a'] = 1;
    lit[256] = 2;
    lit[257] = 2;
    var dist = [_]u8{0} ** 30;
    dist[0] = 1;
    try kit.dynamicHeader(b, &lit, &dist);
    try b.code(0, 1); // a
    try b.code(3, 2); // 257: a match of length 3
    try b.put(1, 1); // its distance: the bit no code starts with
    try b.put(0, 16);
}

fn oversubscribedLiterals(b: *kit.Bits) anyerror!void {
    // a dynamic block whose literal code has three codes of length 1
    var lit = [_]u8{0} ** 286;
    lit['a'] = 1;
    lit['b'] = 1;
    lit[256] = 1;
    var dist = [_]u8{0} ** 30;
    dist[0] = 1;
    try kit.dynamicHeader(b, &lit, &dist);
}

test "corrupt streams are refused, each in its own way" {
    try rawBits(&blockType3);
    try rawBits(&storedMismatch);
    try rawBits(&fixedSymbol286);
    try rawBits(&fixedDistance30);
    try rawBits(&dynamicHlit287);
    try rawBits(&dynamicHdist32);
    try rawBits(&clOversubscribed);
    try rawBits(&clRepeatFirst);
    try rawBits(&clRepeatOverflow);
    try rawBits(&clNoEndOfBlock);
    try rawBits(&unassignedCode);
    try rawBits(&oversubscribedLiterals);
}

test "a match that reaches back before the start of the output is refused" {
    const body = try kit.deflateFixed(&.{ .{ .lit = 'a' }, .{ .match = .{ .len = 3, .dist = 2 } } });
    defer a.free(body);
    try t.expectError(error.Corrupt, rawInflate(body));
}

test "a stored block whose data is cut off is truncated, and its length is checked" {
    const body = try kit.deflateStored("0123456789");
    defer a.free(body);
    try t.expectError(error.Truncated, rawInflate(body[0 .. body.len - 1]));
    try t.expectError(error.Truncated, rawInflate(body[0..3]));
}

const Failing = struct {
    left: usize,

    pub fn write(self: *Failing, bytes: []const u8) !void {
        if (bytes.len > self.left) return error.DiskFull;
        self.left -= bytes.len;
    }
};

test "an error of the sink is the decoder's error" {
    const gz = try kit.gzipStored("some bytes that go nowhere");
    defer a.free(gz);
    var f = Failing{ .left = 3 };
    try t.expectError(error.DiskFull, inflate.gunzip(a, gz, stream.sinkOf(Failing, &f)));
}

test "an error of the sink is the decoder's error when the buffer fills, too" {
    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(a);
    const toks = try randomTokens(4, 100_000, &expected);
    defer a.free(toks);
    const body = try kit.deflateFixed(toks);
    defer a.free(body);
    const gz = try kit.gzipOf(body, expected.items);
    defer a.free(gz);
    var f = Failing{ .left = 70_000 };
    try t.expectError(error.DiskFull, inflate.gunzip(a, gz, stream.sinkOf(Failing, &f)));
}

fn lens(comptime n: usize, comptime spec: []const [2]usize) [n]u8 {
    var l = [_]u8{0} ** n;
    for (spec) |s| l[s[0]] = @intCast(s[1]);
    return l;
}

test "Table.build: a complete code is built; one symbol too many is not, at the very boundary" {
    var tab: inflate.Table = .{};
    try tab.build(&[_]u8{ 1, 2, 2 }, false);
    try tab.build(&[_]u8{ 2, 2, 2, 2 }, false);
    try tab.build(&[_]u8{ 1, 2, 3, 3 }, false);
    // over-subscribed by exactly one code of the longest length, and by a whole level
    try t.expectError(error.Corrupt, tab.build(&[_]u8{ 1, 2, 2, 2 }, true));
    try t.expectError(error.Corrupt, tab.build(&[_]u8{ 2, 2, 2, 2, 2 }, true));
    try t.expectError(error.Corrupt, tab.build(&[_]u8{ 1, 1, 1 }, true));
    try t.expectError(error.Corrupt, tab.build(&([_]u8{15} ** 32769), true));
    try t.expectError(error.Corrupt, tab.build(&[_]u8{ 1, 2, 3, 3, 15 }, true));
}

test "Table.build: an incomplete code is refused, but a single code of length 1 or none at all may be allowed" {
    var tab: inflate.Table = .{};
    try t.expectError(error.Corrupt, tab.build(&[_]u8{ 2, 2, 2 }, true));
    try t.expectError(error.Corrupt, tab.build(&[_]u8{ 2, 2, 2 }, false));
    try t.expectError(error.Corrupt, tab.build(&[_]u8{ 1, 2 }, true));
    try t.expectError(error.Corrupt, tab.build(&[_]u8{2}, true));
    try t.expectError(error.Corrupt, tab.build(&[_]u8{0}, false));
    try tab.build(&[_]u8{ 0, 1, 0 }, true);
    try tab.build(&[_]u8{ 0, 0, 0 }, true);
    try t.expectError(error.Corrupt, tab.build(&[_]u8{ 0, 1, 0 }, false));
}

/// A raw DEFLATE stream of one dynamic block with the given lengths, followed by the bits of `tail`.
fn dynamicWith(lit: []const u8, dist: []const u8, toks: []const kit.Tok) ![]u8 {
    return kit.deflateDynamic(toks, lit, dist);
}

test "a literal, distance or code-length code that is over-subscribed or incomplete is refused even when the data would decode" {
    // over-subscribed distance code, in a block that never uses a distance
    var lit = lens(286, &.{ .{ 'a', 1 }, .{ 256, 2 }, .{ 257, 2 } });
    var dist = lens(30, &.{ .{ 0, 1 }, .{ 1, 1 }, .{ 2, 1 } });
    const bad_dist = try dynamicWith(&lit, &dist, &.{.{ .lit = 'a' }});
    defer a.free(bad_dist);
    try t.expectError(error.Corrupt, rawInflate(bad_dist));
    // the same block with a sound distance code decodes
    dist = lens(30, &.{ .{ 0, 1 } });
    const good = try dynamicWith(&lit, &dist, &.{.{ .lit = 'a' }});
    defer a.free(good);
    try t.expectEqual(@as(u64, 1), (try rawInflate(good)).len);
    // over-subscribed literal code whose first symbols are all the block uses
    var big = lens(286, &.{ .{ 'a', 1 }, .{ 256, 1 }, .{ 257, 1 } });
    dist = lens(30, &.{ .{ 0, 1 } });
    const bad_lit = try dynamicWith(&big, &dist, &.{.{ .lit = 'a' }});
    defer a.free(bad_lit);
    try t.expectError(error.Corrupt, rawInflate(bad_lit));
    // an incomplete literal code
    big = lens(286, &.{ .{ 'a', 2 }, .{ 'b', 2 }, .{ 256, 2 } });
    const incomplete_lit = try dynamicWith(&big, &dist, &.{.{ .lit = 'a' }});
    defer a.free(incomplete_lit);
    try t.expectError(error.Corrupt, rawInflate(incomplete_lit));
    // an incomplete distance code of two symbols
    dist = lens(30, &.{ .{ 0, 2 }, .{ 1, 2 } });
    const incomplete_dist = try dynamicWith(&lit, &dist, &.{.{ .lit = 'a' }});
    defer a.free(incomplete_dist);
    try t.expectError(error.Corrupt, rawInflate(incomplete_dist));
}

test "a block with no distance code at all is a literal-only block, and decodes" {
    const lit = lens(286, &.{ .{ 'a', 1 }, .{ 'b', 2 }, .{ 256, 2 } });
    const dist = lens(30, &.{});
    const body = try dynamicWith(&lit, &dist, &.{ .{ .lit = 'a' }, .{ .lit = 'b' } });
    defer a.free(body);
    try t.expectEqual(@as(u64, 2), (try rawInflate(body)).len);
}

test "the code-length code must be complete: a single code is refused there" {
    // symbol 18 alone with length 1: incomplete
    const body = struct {
        fn f(b: *kit.Bits) anyerror!void {
            try dynamicStart(b, .{ 0, 0, 1 });
            try b.put(0, 1);
            try b.put(127, 7);
        }
    }.f;
    try rawBits(&body);
}

test "a stored block after output that fills the buffer flushes through the window" {
    var b = kit.Bits{};
    // a non-final fixed block of 40000 literals, then a final stored block of 50000 bytes
    try b.put(0, 1);
    try b.put(1, 2);
    var expected = std.ArrayList(u8).empty;
    defer expected.deinit(a);
    var i: usize = 0;
    while (i < 40000) : (i += 1) {
        const c: u8 = @truncate(i *% 7);
        try kit.fixedSym(&b, c);
        try expected.append(a, c);
    }
    try kit.fixedSym(&b, 256);
    try b.put(1, 1);
    try b.put(0, 2);
    const pad: u6 = @intCast((8 - (b.n % 8)) % 8);
    try b.put(0, pad);
    try b.put(50000, 16);
    try b.put(@as(u32, ~@as(u16, 50000)), 16);
    i = 0;
    while (i < 50000) : (i += 1) {
        const c: u8 = @truncate(i *% 13 +% 5);
        try b.put(c, 8);
        try expected.append(a, c);
    }
    const body = try b.finish();
    defer a.free(body);
    const gz = try kit.gzipOf(body, expected.items);
    defer a.free(gz);
    try expectDecodes(gz, expected.items);
}
