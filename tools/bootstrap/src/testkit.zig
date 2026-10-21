//! Test support: builders of tar, gzip (stored, fixed-Huffman and dynamic-Huffman blocks), xz (uncompressed LZMA2 chunks) and zip files, written independently of
//! the decoders they test (their own tables, their own bit writer), and a temporary directory to extract into.
const std = @import("std");
const archive = @import("archive.zig");
const extract = @import("extract.zig");
const t = std.testing;

pub const a = t.allocator;

fn put16(list: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try list.appendSlice(a, &b);
}

fn put32(list: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try list.appendSlice(a, &b);
}

fn put64(list: *std.ArrayList(u8), v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try list.appendSlice(a, &b);
}

// ---- tar ------------------------------------------------------------------------------------------------------------------------------

pub const Entry = struct {
    name: []const u8,
    typeflag: u8 = '0',
    mode: u32 = 0o644,
    /// The size the header says; the data's length when null.
    size: ?u64 = null,
    link: []const u8 = "",
    prefix: []const u8 = "",
    magic: []const u8 = "ustar\x00" ++ "00",
    data: []const u8 = "",
    /// The size is written in the binary form (high bit set) and not in octal.
    binary_size: bool = false,
    /// The checksum is written wrong.
    bad_sum: bool = false,
    /// The data is left out (a header whose data is cut off or absent).
    no_data: bool = false,
    /// The padding after the data is left out.
    no_pad: bool = false,
};

pub const Tar = struct {
    out: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Tar) void {
        self.out.deinit(a);
    }

    pub fn header(e: Entry) ![512]u8 {
        var h = [_]u8{0} ** 512;
        @memcpy(h[0..e.name.len], e.name);
        _ = try std.fmt.bufPrint(h[100..108], "{o:0>7}", .{e.mode});
        _ = try std.fmt.bufPrint(h[108..116], "{o:0>7}", .{0});
        _ = try std.fmt.bufPrint(h[116..124], "{o:0>7}", .{0});
        const size = e.size orelse e.data.len;
        if (e.binary_size) {
            h[124] = 0x80;
            std.mem.writeInt(u64, h[128..136], size, .big);
        } else {
            _ = try std.fmt.bufPrint(h[124..136], "{o:0>11}", .{size});
        }
        _ = try std.fmt.bufPrint(h[136..148], "{o:0>11}", .{0});
        @memset(h[148..156], ' ');
        h[156] = e.typeflag;
        @memcpy(h[157 .. 157 + e.link.len], e.link);
        @memcpy(h[257 .. 257 + e.magic.len], e.magic);
        @memcpy(h[345 .. 345 + e.prefix.len], e.prefix);
        var sum: u32 = 0;
        for (h) |c| sum += c;
        if (e.bad_sum) sum += 1;
        _ = try std.fmt.bufPrint(h[148..155], "{o:0>6}", .{sum});
        h[154] = 0;
        h[155] = ' ';
        return h;
    }

    pub fn add(self: *Tar, e: Entry) !void {
        const h = try header(e);
        try self.out.appendSlice(a, &h);
        if (e.no_data) return;
        try self.out.appendSlice(a, e.data);
        if (e.no_pad) return;
        const pad = (512 - e.data.len % 512) % 512;
        try self.out.appendNTimes(a, 0, pad);
    }

    pub fn file(self: *Tar, name: []const u8, mode: u32, data: []const u8) !void {
        try self.add(.{ .name = name, .mode = mode, .data = data });
    }

    pub fn dir(self: *Tar, name: []const u8) !void {
        try self.add(.{ .name = name, .typeflag = '5', .mode = 0o755 });
    }

    pub fn symlink(self: *Tar, name: []const u8, target: []const u8) !void {
        try self.add(.{ .name = name, .typeflag = '2', .mode = 0o777, .link = target });
    }

    pub fn hardlink(self: *Tar, name: []const u8, target: []const u8) !void {
        try self.add(.{ .name = name, .typeflag = '1', .link = target });
    }

    /// A GNU long-name (`L`) or long-link (`K`) entry.
    pub fn gnuLong(self: *Tar, kind: u8, value: []const u8) !void {
        var data = std.ArrayList(u8).empty;
        defer data.deinit(a);
        try data.appendSlice(a, value);
        try data.append(a, 0);
        try self.add(.{ .name = "././@LongLink", .typeflag = kind, .data = data.items, .mode = 0 });
    }

    /// A pax extended header with the records `key=value`.
    pub fn pax(self: *Tar, records: []const [2][]const u8) !void {
        var data = std.ArrayList(u8).empty;
        defer data.deinit(a);
        for (records) |r| {
            const body_len = r[0].len + r[1].len + 3; // ' ', '=', '\n'
            var digits: usize = 1;
            while (true) {
                const total = body_len + digits;
                const need = std.fmt.count("{d}", .{total});
                if (need == digits) break;
                digits = need;
            }
            try data.writer(a).print("{d} {s}={s}\n", .{ body_len + digits, r[0], r[1] });
        }
        try self.add(.{ .name = "PaxHeader/x", .typeflag = 'x', .data = data.items, .mode = 0 });
    }

    pub fn end(self: *Tar) !void {
        try self.out.appendNTimes(a, 0, 1024);
    }

    pub fn bytes(self: *const Tar) []const u8 {
        return self.out.items;
    }
};

// ---- deflate, gzip ----------------------------------------------------------------------------------------------------------------------

const LenBase = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const LenExtra = [29]u4{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const DistBase = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const DistExtra = [30]u4{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

pub const Tok = union(enum) {
    lit: u8,
    match: struct { len: u16, dist: u16 },
};

/// A raw DEFLATE stream of `data` as literals only (one fixed block).
pub fn deflateText(data: []const u8) ![]u8 {
    const toks = try a.alloc(Tok, data.len);
    defer a.free(toks);
    for (data, 0..) |c, i| toks[i] = .{ .lit = c };
    return deflateFixed(toks);
}

pub const Bits = struct {
    out: std.ArrayList(u8) = .empty,
    acc: u64 = 0,
    n: u6 = 0,

    pub fn put(self: *Bits, v: u32, count: u6) !void {
        self.acc |= @as(u64, v) << self.n;
        self.n += count;
        while (self.n >= 8) {
            try self.out.append(a, @truncate(self.acc));
            self.acc >>= 8;
            self.n -= 8;
        }
    }

    /// A Huffman code: its most significant bit first.
    pub fn code(self: *Bits, v: u32, len: u6) !void {
        var i: u6 = 0;
        while (i < len) : (i += 1) try self.put((v >> @intCast(len - 1 - i)) & 1, 1);
    }

    pub fn finish(self: *Bits) ![]u8 {
        if (self.n > 0) try self.out.append(a, @truncate(self.acc));
        return self.out.toOwnedSlice(a);
    }
};

/// The canonical codes of a table of code lengths (RFC 1951, 3.2.2).
pub fn canonical(lens: []const u8) ![]u32 {
    const codes = try a.alloc(u32, lens.len);
    var count = [_]u32{0} ** 16;
    for (lens) |l| count[l] += 1;
    count[0] = 0;
    var next = [_]u32{0} ** 16;
    var c: u32 = 0;
    var bits: usize = 1;
    while (bits < 16) : (bits += 1) {
        c = (c + count[bits - 1]) << 1;
        next[bits] = c;
    }
    for (lens, 0..) |l, i| {
        if (l == 0) continue;
        codes[i] = next[l];
        next[l] += 1;
    }
    return codes;
}

pub fn lenSymbol(len: u16) usize {
    var i: usize = 28;
    while (LenBase[i] > len) i -= 1;
    return i;
}

pub fn distSymbol(dist: u16) usize {
    var i: usize = 29;
    while (DistBase[i] > dist) i -= 1;
    return i;
}

/// One DEFLATE block of the tokens with the fixed codes of the RFC. `final` marks it the last.
fn blockFixed(b: *Bits, toks: []const Tok, final: bool) !void {
    try b.put(@intFromBool(final), 1);
    try b.put(1, 2);
    for (toks) |tok| switch (tok) {
        .lit => |c| try fixedSym(b, c),
        .match => |m| {
            const ls = lenSymbol(m.len);
            try fixedSym(b, 257 + @as(u32, @intCast(ls)));
            try b.put(m.len - LenBase[ls], LenExtra[ls]);
            const ds = distSymbol(m.dist);
            try b.code(@intCast(ds), 5);
            try b.put(m.dist - DistBase[ds], DistExtra[ds]);
        },
    };
    try fixedSym(b, 256);
}

fn fixedSym(b: *Bits, s: u32) !void {
    if (s < 144) return b.code(0x30 + s, 8);
    if (s < 256) return b.code(0x190 + (s - 144), 9);
    if (s < 280) return b.code(s - 256, 7);
    return b.code(0xc0 + (s - 280), 8);
}

/// A raw DEFLATE stream of one final block with the fixed codes.
pub fn deflateFixed(toks: []const Tok) ![]u8 {
    var b = Bits{};
    try blockFixed(&b, toks, true);
    return b.finish();
}

/// A raw DEFLATE stream of one final block with dynamic codes: the code lengths of the literal/length and distance alphabets are the caller's (every symbol the
/// tokens use must have one), and are written the way an encoder does, run-length coded with symbols 16, 17 and 18.
pub fn deflateDynamic(toks: []const Tok, lit_lens: []const u8, dist_lens: []const u8) ![]u8 {
    var b = Bits{};
    try dynamicHeader(&b, lit_lens, dist_lens);
    try dynamicTokens(&b, toks, lit_lens, dist_lens);
    return b.finish();
}

/// The start of a final dynamic block: its type bits and the code lengths.
pub fn dynamicHeader(b: *Bits, lit_lens: []const u8, dist_lens: []const u8) !void {
    try b.put(1, 1);
    try b.put(2, 2);
    try b.put(@intCast(lit_lens.len - 257), 5);
    try b.put(@intCast(dist_lens.len - 1), 5);
    try b.put(15, 4); // all 19 code-length code lengths
    // The code-length alphabet: every symbol has the length 5.
    const order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    for (order) |_| try b.put(5, 3);
    const clens = [_]u8{5} ** 19;
    const ccodes = try canonical(&clens);
    defer a.free(ccodes);
    var all = std.ArrayList(u8).empty;
    defer all.deinit(a);
    try all.appendSlice(a, lit_lens);
    try all.appendSlice(a, dist_lens);
    var i: usize = 0;
    while (i < all.items.len) {
        const v = all.items[i];
        var run: usize = 1;
        while (i + run < all.items.len and all.items[i + run] == v) run += 1;
        if (v == 0 and run >= 11) {
            const n = @min(run, 138);
            try b.code(ccodes[18], 5);
            try b.put(@intCast(n - 11), 7);
            i += n;
        } else if (v == 0 and run >= 3) {
            const n = @min(run, 10);
            try b.code(ccodes[17], 5);
            try b.put(@intCast(n - 3), 3);
            i += n;
        } else if (i > 0 and all.items[i - 1] == v and run >= 3) {
            const n = @min(run, 6);
            try b.code(ccodes[16], 5);
            try b.put(@intCast(n - 3), 2);
            i += n;
        } else {
            try b.code(ccodes[v], 5);
            i += 1;
        }
    }
}

fn dynamicTokens(b: *Bits, toks: []const Tok, lit_lens: []const u8, dist_lens: []const u8) !void {
    const lcodes = try canonical(lit_lens);
    defer a.free(lcodes);
    const dcodes = try canonical(dist_lens);
    defer a.free(dcodes);
    for (toks) |tok| switch (tok) {
        .lit => |c| try b.code(lcodes[c], @intCast(lit_lens[c])),
        .match => |m| {
            const ls = lenSymbol(m.len);
            try b.code(lcodes[257 + ls], @intCast(lit_lens[257 + ls]));
            try b.put(m.len - LenBase[ls], LenExtra[ls]);
            const ds = distSymbol(m.dist);
            try b.code(dcodes[ds], @intCast(dist_lens[ds]));
            try b.put(m.dist - DistBase[ds], DistExtra[ds]);
        },
    };
    try b.code(lcodes[256], @intCast(lit_lens[256]));
}

/// A raw DEFLATE stream of stored blocks (at most 65535 bytes each).
pub fn deflateStored(data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var rest = data;
    while (true) {
        const n = @min(rest.len, 65535);
        const final = n == rest.len;
        try out.append(a, @intFromBool(final));
        try put16(&out, @intCast(n));
        try put16(&out, @intCast(~@as(u16, @intCast(n))));
        try out.appendSlice(a, rest[0..n]);
        rest = rest[n..];
        if (final) break;
    }
    return out.toOwnedSlice(a);
}

/// A gzip member around the raw DEFLATE stream `body` of `plain` (its CRC-32 and length are written from `plain`).
pub fn gzipOf(body: []const u8, plain: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, &.{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3 });
    try out.appendSlice(a, body);
    try put32(&out, std.hash.Crc32.hash(plain));
    try put32(&out, @truncate(plain.len));
    return out.toOwnedSlice(a);
}

/// A gzip file of stored blocks.
pub fn gzipStored(plain: []const u8) ![]u8 {
    const body = try deflateStored(plain);
    defer a.free(body);
    return gzipOf(body, plain);
}

// ---- xz ---------------------------------------------------------------------------------------------------------------------------------

pub const Check = enum { none, crc32, crc64 };

fn varint(list: *std.ArrayList(u8), v_in: u64) !void {
    var v = v_in;
    while (v >= 0x80) {
        try list.append(a, @as(u8, @truncate(v)) | 0x80);
        v >>= 7;
    }
    try list.append(a, @truncate(v));
}

/// An xz file whose one block holds `data` in uncompressed LZMA2 chunks (the container is the whole of the format but the compression).
pub fn xzOf(data: []const u8, check: Check) ![]u8 {
    var out = std.ArrayList(u8).empty;
    const flags: [2]u8 = .{ 0, switch (check) {
        .none => 0,
        .crc32 => 1,
        .crc64 => 4,
    } };
    try out.appendSlice(a, "\xfd7zXZ\x00");
    try out.appendSlice(a, &flags);
    try put32(&out, std.hash.Crc32.hash(&flags));
    // block header: size byte, flags, filter 0x21 (LZMA2) with one property byte, padding, CRC-32
    const bh = [_]u8{ 2, 0, 0x21, 1, 0x10, 0, 0, 0 };
    try out.appendSlice(a, &bh);
    try put32(&out, std.hash.Crc32.hash(&bh));
    const block_start = out.items.len;
    var rest = data;
    var first = true;
    while (rest.len > 0) {
        const n = @min(rest.len, 65536);
        try out.append(a, if (first) 1 else 2);
        try out.append(a, @intCast((n - 1) >> 8));
        try out.append(a, @intCast((n - 1) & 0xff));
        try out.appendSlice(a, rest[0..n]);
        rest = rest[n..];
        first = false;
    }
    try out.append(a, 0);
    const compressed = out.items.len - block_start;
    try out.appendNTimes(a, 0, (4 - compressed % 4) % 4);
    var check_len: usize = 0;
    switch (check) {
        .none => {},
        .crc32 => {
            try put32(&out, std.hash.Crc32.hash(data));
            check_len = 4;
        },
        .crc64 => {
            try put64(&out, std.hash.crc.Crc64Xz.hash(data));
            check_len = 8;
        },
    }
    // index: one record
    var index = std.ArrayList(u8).empty;
    defer index.deinit(a);
    try index.append(a, 0);
    try varint(&index, 1);
    try varint(&index, bh.len + 4 + compressed + check_len);
    try varint(&index, data.len);
    try index.appendNTimes(a, 0, (4 - index.items.len % 4) % 4);
    try out.appendSlice(a, index.items);
    try put32(&out, std.hash.Crc32.hash(index.items));
    // footer
    var tail: [6]u8 = undefined;
    std.mem.writeInt(u32, tail[0..4], @intCast((index.items.len + 4) / 4 - 1), .little);
    @memcpy(tail[4..6], &flags);
    try put32(&out, std.hash.Crc32.hash(&tail));
    try out.appendSlice(a, &tail);
    try out.appendSlice(a, "YZ");
    return out.toOwnedSlice(a);
}

// ---- zip --------------------------------------------------------------------------------------------------------------------------------

pub const Member = struct {
    name: []const u8,
    /// The plain content; stored as it is, or inside `body` when that is given.
    data: []const u8 = "",
    /// The member's bytes when not stored: a raw DEFLATE stream of `data`.
    body: ?[]const u8 = null,
    unix_mode: ?u32 = null,
    flags: u16 = 0,
    method: ?u16 = null,
    /// The three sizes and the offset are written as 0xffffffff and given in a zip64 extra field.
    zip64: bool = false,
    crc: ?u32 = null,
    usize_: ?u64 = null,
    /// The host of `version made by` when `unix_mode` is not given.
    host: u8 = 0,
};

pub const Zip = struct {
    out: std.ArrayList(u8) = .empty,
    central: std.ArrayList(u8) = .empty,
    count: usize = 0,

    pub fn deinit(self: *Zip) void {
        self.out.deinit(a);
        self.central.deinit(a);
    }

    pub fn add(self: *Zip, m: Member) !void {
        const body = m.body orelse m.data;
        const method: u16 = m.method orelse if (m.body != null) 8 else 0;
        const crc = m.crc orelse std.hash.Crc32.hash(m.data);
        const usize_: u64 = m.usize_ orelse m.data.len;
        const offset = self.out.items.len;
        // local header
        try put32(&self.out, 0x04034b50);
        try put16(&self.out, 20);
        try put16(&self.out, m.flags);
        try put16(&self.out, method);
        try put32(&self.out, 0);
        try put32(&self.out, crc);
        try put32(&self.out, @intCast(body.len));
        try put32(&self.out, @intCast(usize_));
        try put16(&self.out, @intCast(m.name.len));
        try put16(&self.out, 0);
        try self.out.appendSlice(a, m.name);
        try self.out.appendSlice(a, body);
        // central header
        const c = &self.central;
        try put32(c, 0x02014b50);
        try put16(c, (@as(u16, if (m.unix_mode != null) 3 else m.host) << 8) | 20);
        try put16(c, 20);
        try put16(c, m.flags);
        try put16(c, method);
        try put32(c, 0);
        try put32(c, crc);
        if (m.zip64) {
            try put32(c, 0xffffffff);
            try put32(c, 0xffffffff);
        } else {
            try put32(c, @intCast(body.len));
            try put32(c, @intCast(usize_));
        }
        try put16(c, @intCast(m.name.len));
        try put16(c, if (m.zip64) 28 else 0);
        try put16(c, 0);
        try put16(c, 0);
        try put16(c, 0);
        try put32(c, (m.unix_mode orelse 0) << 16);
        try put32(c, if (m.zip64) 0xffffffff else @intCast(offset));
        try c.appendSlice(a, m.name);
        if (m.zip64) {
            try put16(c, 0x0001);
            try put16(c, 24);
            try put64(c, usize_);
            try put64(c, body.len);
            try put64(c, offset);
        }
        self.count += 1;
    }

    /// The whole file. `zip64_end` writes the zip64 end-of-directory record and locator.
    pub fn finish(self: *Zip, zip64_end: bool) ![]u8 {
        const cd_offset = self.out.items.len;
        try self.out.appendSlice(a, self.central.items);
        if (zip64_end) {
            const z64 = self.out.items.len;
            try put32(&self.out, 0x06064b50);
            try put64(&self.out, 44);
            try put16(&self.out, 45);
            try put16(&self.out, 45);
            try put32(&self.out, 0);
            try put32(&self.out, 0);
            try put64(&self.out, self.count);
            try put64(&self.out, self.count);
            try put64(&self.out, self.central.items.len);
            try put64(&self.out, cd_offset);
            try put32(&self.out, 0x07064b50);
            try put32(&self.out, 0);
            try put64(&self.out, z64);
            try put32(&self.out, 1);
        }
        try put32(&self.out, 0x06054b50);
        try put16(&self.out, 0);
        try put16(&self.out, 0);
        try put16(&self.out, if (zip64_end) 0xffff else @intCast(self.count));
        try put16(&self.out, if (zip64_end) 0xffff else @intCast(self.count));
        try put32(&self.out, if (zip64_end) 0xffffffff else @intCast(self.central.items.len));
        try put32(&self.out, if (zip64_end) 0xffffffff else @intCast(cd_offset));
        try put16(&self.out, 0);
        return self.out.toOwnedSlice(a);
    }
};

// ---- extracting -------------------------------------------------------------------------------------------------------------------------

/// A temporary directory to extract into, and readers of what lands there.
pub const Dest = struct {
    tmp: std.testing.TmpDir,

    pub fn init() Dest {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    pub fn deinit(self: *Dest) void {
        self.tmp.cleanup();
    }

    /// Extracts `bytes` as `format` with `strip`, and returns what was counted.
    pub fn unpack(self: *Dest, bytes: []const u8, format: archive.Format, strip: usize) !extract.Stats {
        var ex = extract.Extractor.init(a, self.tmp.dir, strip);
        defer ex.deinit();
        try archive.extractBytes(a, bytes, format, &ex);
        return ex.stats;
    }

    /// The same without writing: what `--check` does.
    pub fn check(bytes: []const u8, format: archive.Format, strip: usize) !extract.Stats {
        var ex = extract.Extractor.init(a, null, strip);
        defer ex.deinit();
        try archive.extractBytes(a, bytes, format, &ex);
        return ex.stats;
    }

    pub fn read(self: *Dest, path: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(a, path, 1 << 24);
    }

    pub fn mode(self: *Dest, path: []const u8) !u32 {
        const st = try self.tmp.dir.statFile(path);
        return @intCast(st.mode & 0o7777);
    }

    pub fn has(self: *Dest, path: []const u8) bool {
        self.tmp.dir.access(path, .{}) catch return false;
        return true;
    }

    /// The target of the symbolic link at `path`, in `buf`.
    pub fn link(self: *Dest, path: []const u8, buf: []u8) ![]u8 {
        return self.tmp.dir.readLink(path, buf);
    }

    pub fn isLink(self: *Dest, path: []const u8) bool {
        var buf: [256]u8 = undefined;
        _ = self.tmp.dir.readLink(path, &buf) catch return false;
        return true;
    }

    /// Every entry below the directory, as sorted `path` lines (`/` after a directory, ` -> target` after a link): the tree's shape in one string.
    pub fn listing(self: *Dest) ![]u8 {
        var out = std.ArrayList(u8).empty;
        var names = std.ArrayList([]u8).empty;
        defer {
            for (names.items) |n| a.free(n);
            names.deinit(a);
        }
        var d = try self.tmp.dir.openDir(".", .{ .iterate = true });
        defer d.close();
        var w = try d.walk(a);
        defer w.deinit();
        while (try w.next()) |e| {
            var line = std.ArrayList(u8).empty;
            try line.appendSlice(a, e.path);
            switch (e.kind) {
                .directory => try line.append(a, '/'),
                .sym_link => {
                    var buf: [256]u8 = undefined;
                    const target = try self.tmp.dir.readLink(e.path, &buf);
                    try line.appendSlice(a, " -> ");
                    try line.appendSlice(a, target);
                },
                else => {},
            }
            try names.append(a, try line.toOwnedSlice(a));
        }
        std.mem.sort([]u8, names.items, {}, struct {
            fn lt(_: void, x: []u8, y: []u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (names.items) |n| {
            try out.appendSlice(a, n);
            try out.append(a, '\n');
        }
        return out.toOwnedSlice(a);
    }
};
