//! DEFLATE (RFC 1951) and gzip (RFC 1952), decoded from a slice in memory into a `Sink`.
//!
//! Written here and not taken from the standard library: the standard library's windowed decoder mishandles a fixed-Huffman match at the end of its
//! window, and its decoder without a window holds the whole output. This one keeps a 32 KiB window and hands the output on in chunks, checks every
//! length, distance and code, and reports a stream that ends early as `error.Truncated` and not as a short result: a cut-off archive is never a smaller one.
//! A gzip file is checked to its trailer (the CRC-32 and the length of what it held) and to its end: bytes after the last member are refused.
const std = @import("std");
const Sink = @import("stream.zig").Sink;

pub const Error = error{
    /// The input ends inside a header, a block, or before the trailer.
    Truncated,
    /// A code, length, distance or header field that no encoder writes.
    Corrupt,
    /// The gzip trailer's CRC-32 is not that of the output.
    BadChecksum,
    /// The gzip trailer's length is not that of the output (modulo 2^32).
    BadLength,
    /// The input does not begin with the gzip magic.
    NotGzip,
    /// Bytes after the last gzip member.
    TrailingData,
};

const window = 32768;
const buf_len = 2 * window;
const table_bits = 15;

const len_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [29]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };
const clen_order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// The bits of the input, least significant first.
const Bits = struct {
    in: []const u8,
    pos: usize = 0,
    acc: u64 = 0,
    n: u7 = 0,

    fn refill(self: *Bits) void {
        while (self.n <= 56 and self.pos < self.in.len) {
            self.acc |= @as(u64, self.in[self.pos]) << @intCast(self.n);
            self.pos += 1;
            self.n += 8;
        }
    }

    fn take(self: *Bits, k: u6) error{Truncated}!u32 {
        if (self.n < k) {
            self.refill();
            if (self.n < k) return error.Truncated;
        }
        const v: u32 = @intCast(self.acc & ((@as(u64, 1) << k) - 1));
        self.acc >>= k;
        self.n -= k;
        return v;
    }

    /// Drops the bits of a partly read byte.
    fn alignByte(self: *Bits) void {
        const drop: u6 = @intCast(self.n % 8);
        self.acc >>= drop;
        self.n -= drop;
    }
};

/// A canonical Huffman code as a lookup table indexed by the next `bits` bits of input: each entry is `(symbol << 4) | length`, 0 where no code lives.
const Table = struct {
    entries: [1 << table_bits]u16 = undefined,
    bits: u5 = 0,

    fn build(self: *Table, lengths: []const u8) error{Corrupt}!void {
        var count = [_]u16{0} ** 16;
        for (lengths) |l| count[l] += 1;
        count[0] = 0;
        var maxbits: u5 = 0;
        var left: i32 = 1;
        for (1..16) |l| {
            if (count[l] != 0) maxbits = @intCast(l);
            left = (left << 1) - count[l];
            if (left < 0) return error.Corrupt; // more codes of a length than there are bit strings
        }
        var next = [_]u16{0} ** 17;
        var code: u16 = 0;
        for (1..16) |l| {
            code = (code + count[l - 1]) << 1;
            next[l] = code;
        }
        self.bits = maxbits;
        const size = @as(usize, 1) << maxbits;
        @memset(self.entries[0..size], 0);
        for (lengths, 0..) |l, sym| {
            if (l == 0) continue;
            const c = next[l];
            next[l] += 1;
            var rev: usize = 0;
            var i: u5 = 0;
            while (i < l) : (i += 1) rev |= @as(usize, (c >> @intCast(i)) & 1) << @intCast(l - 1 - i);
            const entry: u16 = @intCast((sym << 4) | l);
            const step = @as(usize, 1) << @intCast(l);
            var idx = rev;
            while (idx < size) : (idx += step) self.entries[idx] = entry;
        }
    }

    fn decode(self: *const Table, b: *Bits) error{ Truncated, Corrupt }!u16 {
        if (b.n < table_bits) b.refill();
        const mask = (@as(u64, 1) << self.bits) - 1;
        const e = self.entries[@intCast(b.acc & mask)];
        const l: u7 = @intCast(e & 15);
        if (l == 0) return if (b.n == 0) error.Truncated else error.Corrupt;
        if (l > b.n) return error.Truncated;
        b.acc >>= @intCast(l);
        b.n -= l;
        return e >> 4;
    }
};

const State = struct {
    bits: Bits,
    sink: Sink,
    out: [buf_len]u8 = undefined,
    pos: usize = 0,
    flushed: usize = 0,
    total: u64 = 0,
    crc: std.hash.Crc32 = std.hash.Crc32.init(),
    lit: Table = .{},
    dist: Table = .{},

    /// Hands on what has not been, and when the buffer is full keeps the last window of it as the history of the matches to come.
    fn flush(self: *State) !void {
        const chunk = self.out[self.flushed..self.pos];
        if (chunk.len > 0) {
            self.crc.update(chunk);
            self.total += chunk.len;
            try self.sink.write(chunk);
        }
        if (self.pos == buf_len) {
            @memcpy(self.out[0..window], self.out[buf_len - window .. buf_len]);
            self.pos = window;
        }
        self.flushed = self.pos;
    }

    fn put(self: *State, byte: u8) !void {
        if (self.pos == buf_len) try self.flush();
        self.out[self.pos] = byte;
        self.pos += 1;
    }

    fn copy(self: *State, dist: usize, len: usize) !void {
        if (dist > self.pos) return error.Corrupt; // before the start of the output
        var n = len;
        while (n > 0) {
            if (self.pos == buf_len) try self.flush();
            const k = @min(n, buf_len - self.pos);
            var i: usize = 0;
            while (i < k) : (i += 1) self.out[self.pos + i] = self.out[self.pos + i - dist];
            self.pos += k;
            n -= k;
        }
    }

    fn stored(self: *State) !void {
        self.bits.alignByte();
        const len = try self.bits.take(16);
        const nlen = try self.bits.take(16);
        if (len != (~nlen & 0xffff)) return error.Corrupt;
        var n: usize = len;
        while (n > 0 and self.bits.n >= 8) : (n -= 1) try self.put(@intCast(try self.bits.take(8)));
        if (self.bits.in.len - self.bits.pos < n) return error.Truncated;
        while (n > 0) {
            if (self.pos == buf_len) try self.flush();
            const k = @min(n, buf_len - self.pos);
            @memcpy(self.out[self.pos .. self.pos + k], self.bits.in[self.bits.pos .. self.bits.pos + k]);
            self.pos += k;
            self.bits.pos += k;
            n -= k;
        }
    }

    fn fixed(self: *State) !void {
        var lens: [288]u8 = undefined;
        @memset(lens[0..144], 8);
        @memset(lens[144..256], 9);
        @memset(lens[256..280], 7);
        @memset(lens[280..288], 8);
        try self.lit.build(&lens);
        try self.dist.build(&([_]u8{5} ** 32));
    }

    fn dynamic(self: *State) !void {
        const hlit = try self.bits.take(5) + 257;
        const hdist = try self.bits.take(5) + 1;
        const hclen = try self.bits.take(4) + 4;
        if (hlit > 286 or hdist > 30) return error.Corrupt;
        var clens = [_]u8{0} ** 19;
        for (clen_order[0..hclen]) |o| clens[o] = @intCast(try self.bits.take(3));
        var clt: Table = .{};
        try clt.build(&clens);
        var lens = [_]u8{0} ** (286 + 30);
        const want = hlit + hdist;
        var i: usize = 0;
        while (i < want) {
            const sym = try clt.decode(&self.bits);
            if (sym < 16) {
                lens[i] = @intCast(sym);
                i += 1;
                continue;
            }
            var value: u8 = 0;
            var rep: usize = undefined;
            if (sym == 16) {
                if (i == 0) return error.Corrupt; // nothing to repeat
                value = lens[i - 1];
                rep = 3 + try self.bits.take(2);
            } else if (sym == 17) {
                rep = 3 + try self.bits.take(3);
            } else {
                rep = 11 + try self.bits.take(7);
            }
            if (i + rep > want) return error.Corrupt;
            @memset(lens[i .. i + rep], value);
            i += rep;
        }
        if (lens[256] == 0) return error.Corrupt; // no end of block
        try self.lit.build(lens[0..hlit]);
        try self.dist.build(lens[hlit..want]);
    }

    fn codes(self: *State) !void {
        while (true) {
            const sym = try self.lit.decode(&self.bits);
            if (sym < 256) {
                try self.put(@intCast(sym));
                continue;
            }
            if (sym == 256) return;
            if (sym > 285) return error.Corrupt;
            const li = sym - 257;
            const len = len_base[li] + try self.bits.take(@intCast(len_extra[li]));
            const ds = try self.dist.decode(&self.bits);
            if (ds > 29) return error.Corrupt;
            const dist = dist_base[ds] + try self.bits.take(@intCast(dist_extra[ds]));
            try self.copy(dist, len);
        }
    }
};

pub const Result = struct {
    /// How many bytes of the input the stream took.
    consumed: usize,
    /// The CRC-32 and the length of what it held.
    crc: u32,
    len: u64,
};

/// Decodes the raw DEFLATE stream at the start of `input` into `sink` and says how far it read. Errors of the sink are passed on.
pub fn inflate(a: std.mem.Allocator, input: []const u8, sink: Sink) !Result {
    const st = try a.create(State);
    defer a.destroy(st);
    st.bits = .{ .in = input };
    st.sink = sink;
    st.pos = 0;
    st.flushed = 0;
    st.total = 0;
    st.crc = std.hash.Crc32.init();
    while (true) {
        const final = try st.bits.take(1);
        switch (try st.bits.take(2)) {
            0 => try st.stored(),
            1 => {
                try st.fixed();
                try st.codes();
            },
            2 => {
                try st.dynamic();
                try st.codes();
            },
            else => return error.Corrupt,
        }
        if (final == 1) break;
    }
    try st.flush();
    st.bits.alignByte();
    return .{ .consumed = st.bits.pos - st.bits.n / 8, .crc = st.crc.final(), .len = st.total };
}

fn le32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

/// Decodes the gzip file `input` (one member or several) into `sink`, checking each member's CRC-32 and length and that nothing follows the last.
pub fn gunzip(a: std.mem.Allocator, input: []const u8, sink: Sink) !void {
    var pos: usize = 0;
    while (true) {
        const rest = input[pos..];
        if (rest.len < 2 or rest[0] != 0x1f or rest[1] != 0x8b) return if (pos == 0) error.NotGzip else error.TrailingData;
        if (rest.len < 10) return error.Truncated;
        if (rest[2] != 8) return error.Corrupt; // not deflate
        const flags = rest[3];
        if (flags & 0xe0 != 0) return error.Corrupt; // reserved bits
        var at: usize = 10;
        if (flags & 4 != 0) {
            if (rest.len < at + 2) return error.Truncated;
            at += 2 + @as(usize, std.mem.readInt(u16, rest[at..][0..2], .little));
        }
        for ([_]u8{ 8, 16 }) |bit| {
            if (flags & bit == 0) continue;
            const end = std.mem.indexOfScalarPos(u8, rest, @min(at, rest.len), 0) orelse return error.Truncated;
            at = end + 1;
        }
        if (flags & 2 != 0) {
            if (rest.len < at + 2) return error.Truncated;
            const want = std.mem.readInt(u16, rest[at..][0..2], .little);
            if (want != @as(u16, @truncate(std.hash.Crc32.hash(rest[0..at])))) return error.Corrupt;
            at += 2;
        }
        if (at > rest.len) return error.Truncated;
        const r = try inflate(a, rest[at..], sink);
        const trailer = rest[at + r.consumed ..];
        if (trailer.len < 8) return error.Truncated;
        if (le32(trailer[0..4]) != r.crc) return error.BadChecksum;
        if (le32(trailer[4..8]) != @as(u32, @truncate(r.len))) return error.BadLength;
        pos += at + r.consumed + 8;
        if (pos == input.len) return;
    }
}
