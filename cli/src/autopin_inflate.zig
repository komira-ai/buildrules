//! Raw deflate (RFC 1951) with an output limit that is exact. The artifact's members are inflated by this and not by
//! the standard library: the limit has to hold for any stream, including a fixed-Huffman stream whose last match
//! would run past it (the library's reader takes its limit as a count it subtracts a whole match length from).
//! Here no byte is written that would take the output past `max`: the stream is refused with `error.TooLong`
//! first. The decoder is the one of zlib's `puff.c` (Mark Adler, public domain) in Zig: canonical Huffman codes
//! decoded bit by bit, which is slow and small, and enough for members of 2 MiB.
//!
//! Refused: a stream that ends early, a stored block whose length and its complement disagree, an over-subscribed
//! code, a length or distance code outside the tables, a distance before the start of the output, a dynamic header
//! without an end-of-block code, and bytes after the last block.

const std = @import("std");

pub const Error = error{ Invalid, TooLong, TrailingData, OutOfMemory };

const max_bits = 15;

const Bits = struct {
    src: []const u8,
    pos: usize = 0,
    buf: u32 = 0,
    cnt: u8 = 0,

    /// The next `n` (at most 16) bits, least significant first.
    fn need(self: *Bits, n: u8) Error!u32 {
        while (self.cnt < n) {
            if (self.pos >= self.src.len) return error.Invalid;
            self.buf |= @as(u32, self.src[self.pos]) << @intCast(self.cnt);
            self.pos += 1;
            self.cnt += 8;
        }
        const v = self.buf & ((@as(u32, 1) << @intCast(n)) - 1);
        self.buf >>= @intCast(n);
        self.cnt -= n;
        return v;
    }
};

/// A canonical Huffman code (public for its test).
pub const Huffman = struct {
    count: [max_bits + 1]u16 = [_]u16{0} ** (max_bits + 1),
    symbol: [320]u16 = [_]u16{0} ** 320,

    /// A canonical code from the code lengths of the symbols (0 = unused). Over-subscribed codes are refused;
    /// an incomplete code is accepted (a symbol that is not in it is refused when it is read).
    pub fn build(h: *Huffman, lengths: []const u8) Error!void {
        h.count = [_]u16{0} ** (max_bits + 1);
        for (lengths) |l| h.count[l] += 1;
        var left: i32 = 1;
        var len: usize = 1;
        while (len <= max_bits) : (len += 1) {
            left <<= 1;
            left -= h.count[len];
            if (left < 0) return error.Invalid;
        }
        var offs: [max_bits + 2]u16 = undefined;
        offs[1] = 0;
        len = 1;
        while (len < max_bits) : (len += 1) offs[len + 1] = offs[len] + h.count[len];
        for (lengths, 0..) |l, sym| {
            if (l != 0) {
                h.symbol[offs[l]] = @intCast(sym);
                offs[l] += 1;
            }
        }
    }

    fn decode(h: *const Huffman, bits: *Bits) Error!u16 {
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        var len: usize = 1;
        while (len <= max_bits) : (len += 1) {
            code |= @intCast(try bits.need(1));
            const count: i32 = h.count[len];
            if (code - count < first) return h.symbol[@intCast(index + (code - first))];
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        return error.Invalid;
    }
};

const len_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [29]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const clen_order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

const State = struct {
    a: std.mem.Allocator,
    bits: Bits,
    out: std.ArrayList(u8) = .empty,
    max: usize,

    fn push(self: *State, b: u8) Error!void {
        if (self.out.items.len >= self.max) return error.TooLong;
        try self.out.append(self.a, b);
    }

    fn stored(self: *State) Error!void {
        // Drop the rest of the current byte.
        self.bits.buf = 0;
        self.bits.cnt = 0;
        const p = self.bits.pos;
        if (p + 4 > self.bits.src.len) return error.Invalid;
        const len = std.mem.readInt(u16, self.bits.src[p..][0..2], .little);
        const nlen = std.mem.readInt(u16, self.bits.src[p + 2 ..][0..2], .little);
        if (len != ~nlen) return error.Invalid;
        if (p + 4 + len > self.bits.src.len) return error.Invalid;
        if (self.out.items.len + len > self.max) return error.TooLong;
        try self.out.appendSlice(self.a, self.bits.src[p + 4 ..][0..len]);
        self.bits.pos = p + 4 + len;
    }

    fn codes(self: *State, lit: *const Huffman, dist: *const Huffman) Error!void {
        while (true) {
            var sym = try lit.decode(&self.bits);
            if (sym < 256) {
                try self.push(@intCast(sym));
            } else if (sym == 256) {
                return;
            } else {
                sym -= 257;
                if (sym >= 29) return error.Invalid;
                const len: usize = len_base[sym] + try self.bits.need(len_extra[sym]);
                const dsym = try dist.decode(&self.bits);
                if (dsym >= 30) return error.Invalid;
                const d: usize = dist_base[dsym] + try self.bits.need(dist_extra[dsym]);
                if (d > self.out.items.len) return error.Invalid;
                if (self.out.items.len + len > self.max) return error.TooLong;
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    const b = self.out.items[self.out.items.len - d];
                    try self.out.append(self.a, b);
                }
            }
        }
    }

    fn fixed(self: *State) Error!void {
        var lengths: [288]u8 = undefined;
        for (&lengths, 0..) |*l, i| l.* = if (i < 144) 8 else if (i < 256) 9 else if (i < 280) 7 else 8;
        var lit = Huffman{};
        try lit.build(&lengths);
        var dist = Huffman{};
        try dist.build(&([_]u8{5} ** 30));
        try self.codes(&lit, &dist);
    }

    fn dynamic(self: *State) Error!void {
        const nlen = (try self.bits.need(5)) + 257;
        const ndist = (try self.bits.need(5)) + 1;
        const ncode = (try self.bits.need(4)) + 4;
        if (nlen > 286 or ndist > 30) return error.Invalid;
        var lengths = [_]u8{0} ** 320;
        var idx: usize = 0;
        while (idx < ncode) : (idx += 1) lengths[clen_order[idx]] = @intCast(try self.bits.need(3));
        var lencode = Huffman{};
        try lencode.build(lengths[0..19]);
        idx = 0;
        lengths = [_]u8{0} ** 320;
        while (idx < nlen + ndist) {
            const sym = try lencode.decode(&self.bits);
            if (sym < 16) {
                lengths[idx] = @intCast(sym);
                idx += 1;
            } else {
                var prev: u8 = 0;
                var rep: usize = 0;
                if (sym == 16) {
                    if (idx == 0) return error.Invalid;
                    prev = lengths[idx - 1];
                    rep = 3 + try self.bits.need(2);
                } else if (sym == 17) {
                    rep = 3 + try self.bits.need(3);
                } else {
                    rep = 11 + try self.bits.need(7);
                }
                if (idx + rep > nlen + ndist) return error.Invalid;
                while (rep > 0) : (rep -= 1) {
                    lengths[idx] = prev;
                    idx += 1;
                }
            }
        }
        if (lengths[256] == 0) return error.Invalid;
        var lit = Huffman{};
        try lit.build(lengths[0..nlen]);
        var dist = Huffman{};
        try dist.build(lengths[nlen .. nlen + ndist]);
        try self.codes(&lit, &dist);
    }
};

/// The inflated bytes of the raw deflate stream `src`, at most `max` of them. The stream must end at the end of
/// `src`.
pub fn inflate(a: std.mem.Allocator, src: []const u8, max: usize) Error![]u8 {
    var st = State{ .a = a, .bits = .{ .src = src }, .max = max };
    while (true) {
        const last = try st.bits.need(1);
        const kind = try st.bits.need(2);
        switch (kind) {
            0 => try st.stored(),
            1 => try st.fixed(),
            2 => try st.dynamic(),
            else => return error.Invalid,
        }
        if (last == 1) break;
    }
    if (st.bits.pos != src.len) return error.TrailingData;
    return st.out.items;
}
