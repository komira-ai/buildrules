//! A deterministic gzip, written here so the archive's bytes depend on this file and the pinned compiler, and on nothing a runner brings (no
//! `gzip`, no zlib version, no `git archive --format=tar.gz` of some git release).
//!
//! The stream is: the fixed 10-byte gzip header (no name, modification time 0, operating system 3), one DEFLATE block with the fixed Huffman
//! codes (RFC 1951, section 3.2.6) holding a greedy LZ77 parse over a 32 KiB window (hash chains of 3-byte prefixes, at most `max_chain`
//! candidates, the nearest of the longest wins), and the CRC-32 and length trailer. Nothing in it depends on time, memory addresses, the
//! allocator or the number of threads. The tests decode every stream with the standard library's decoder and pin the digest of a fixed input.
const std = @import("std");

const window = 32768;
const min_match = 3;
const max_match = 258;
const max_chain = 64;
const hash_bits = 15;
const nil: u32 = 0;

const len_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [29]u4{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u4{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

/// Bits are packed from the least significant bit of each byte; a Huffman code is written from its most significant bit.
const Bits = struct {
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    acc: u64 = 0,
    n: u6 = 0,

    fn put(self: *Bits, value: u32, count: u6) !void {
        self.acc |= @as(u64, value) << self.n;
        self.n += count;
        while (self.n >= 8) {
            try self.out.append(self.a, @truncate(self.acc));
            self.acc >>= 8;
            self.n -= 8;
        }
    }

    /// A Huffman code of `count` bits, most significant bit first.
    fn code(self: *Bits, value: u32, count: u6) !void {
        var rev: u32 = 0;
        var i: u6 = 0;
        while (i < count) : (i += 1) {
            rev = (rev << 1) | ((value >> @intCast(i)) & 1);
        }
        try self.put(rev, count);
    }

    fn finish(self: *Bits) !void {
        if (self.n > 0) try self.out.append(self.a, @truncate(self.acc));
        self.acc = 0;
        self.n = 0;
    }
};

/// A literal/length symbol in the fixed code (RFC 1951, section 3.2.6).
fn putSymbol(b: *Bits, sym: u32) !void {
    if (sym < 144) return b.code(0x30 + sym, 8);
    if (sym < 256) return b.code(0x190 + (sym - 144), 9);
    if (sym < 280) return b.code(sym - 256, 7);
    return b.code(0xC0 + (sym - 280), 8);
}

fn putMatch(b: *Bits, length: usize, dist: usize) !void {
    var li: usize = len_base.len - 1;
    while (len_base[li] > length) li -= 1;
    try putSymbol(b, @intCast(257 + li));
    if (len_extra[li] != 0) try b.put(@intCast(length - len_base[li]), len_extra[li]);
    var di: usize = dist_base.len - 1;
    while (dist_base[di] > dist) di -= 1;
    try b.code(@intCast(di), 5);
    if (dist_extra[di] != 0) try b.put(@intCast(dist - dist_base[di]), dist_extra[di]);
}

fn hash3(d: []const u8, i: usize) usize {
    const h = (@as(u32, d[i]) << 10) ^ (@as(u32, d[i + 1]) << 5) ^ @as(u32, d[i + 2]);
    return h & ((1 << hash_bits) - 1);
}

/// The DEFLATE stream of `data`: one final block, fixed Huffman codes.
fn deflate(a: std.mem.Allocator, data: []const u8, out: *std.ArrayList(u8)) !void {
    var b = Bits{ .out = out, .a = a };
    try b.put(1, 1); // BFINAL
    try b.put(1, 2); // BTYPE 01: fixed Huffman codes
    const n = data.len;
    const head = try a.alloc(u32, 1 << hash_bits);
    defer a.free(head);
    @memset(head, nil);
    const prev = try a.alloc(u32, n);
    defer a.free(prev);
    var i: usize = 0;
    while (i < n) {
        var best_len: usize = 0;
        var best_dist: usize = 0;
        if (i + min_match <= n) {
            const h = hash3(data, i);
            var cand = head[h];
            var chain: usize = 0;
            const limit = @min(max_match, n - i);
            while (cand != nil and chain < max_chain) : (chain += 1) {
                const p: usize = cand - 1;
                if (i - p > window) break;
                var l: usize = 0;
                while (l < limit and data[p + l] == data[i + l]) l += 1;
                // the nearest of the longest: a later (farther) candidate must be strictly longer
                if (l > best_len) {
                    best_len = l;
                    best_dist = i - p;
                    if (l == limit) break;
                }
                cand = prev[p];
            }
        }
        // a 3-byte match from far away costs more bits than its three literals
        const take = best_len >= min_match and !(best_len == min_match and best_dist > 4096);
        const step: usize = if (take) best_len else 1;
        if (take) try putMatch(&b, best_len, best_dist) else try putSymbol(&b, data[i]);
        var k: usize = 0;
        while (k < step) : (k += 1) {
            const at = i + k;
            if (at + min_match <= n) {
                const h = hash3(data, at);
                prev[at] = head[h];
                head[h] = @intCast(at + 1);
            }
        }
        i += step;
    }
    try putSymbol(&b, 256);
    try b.finish();
}

/// `data` as a gzip file. Caller frees.
pub fn gzip(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    // magic, deflate, no flags, mtime 0, no extra flags, OS 3 (unix)
    try out.appendSlice(a, &[_]u8{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 });
    try deflate(a, data, &out);
    var trailer: [8]u8 = undefined;
    std.mem.writeInt(u32, trailer[0..4], std.hash.Crc32.hash(data), .little);
    std.mem.writeInt(u32, trailer[4..8], @truncate(data.len), .little);
    try out.appendSlice(a, &trailer);
    return out.toOwnedSlice(a);
}

/// The bytes a gzip file holds (the standard library's decoder). Caller frees.
pub fn gunzip(a: std.mem.Allocator, gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var aw: std.Io.Writer.Allocating = .init(a);
    errdefer aw.deinit();
    var d: std.compress.flate.Decompress = .init(&in, .gzip, &.{});
    _ = try d.reader.streamRemaining(&aw.writer);
    return aw.toOwnedSlice();
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;

fn roundTrip(data: []const u8) !void {
    const gz = try gzip(t.allocator, data);
    defer t.allocator.free(gz);
    const back = try gunzip(t.allocator, gz);
    defer t.allocator.free(back);
    try t.expectEqualSlices(u8, data, back);
}

/// A fixed pseudo-random text-like input: words from a small vocabulary, so there are matches at every distance up to the window.
fn sample(a: std.mem.Allocator, size: usize, seed: u64) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const words = [_][]const u8{ "load(", "\"@buildrules//rules/zig:zig.bzl\"", ", ", "zig_test(", "name = ", "src = ", "\n", "    ", "exec_compatible_with", "LINUX_X86_64", ")\n\n", "# the pinned toolchain" };
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    while (out.items.len < size) {
        if (r.uintLessThan(u8, 10) == 0) {
            var k: usize = 0;
            while (k < 20) : (k += 1) try out.append(a, r.int(u8));
        } else {
            try out.appendSlice(a, words[r.uintLessThan(usize, words.len)]);
        }
    }
    out.shrinkRetainingCapacity(size);
    return out.toOwnedSlice(a);
}

test "every stream decodes to its input (the standard library's decoder)" {
    try roundTrip("");
    try roundTrip("a");
    try roundTrip("ab");
    try roundTrip("abc");
    try roundTrip("abcabcabcabcabc");
    try roundTrip("the quick brown fox jumps over the lazy dog");
    // a run longer than one match: lengths 258 and the remainder
    try roundTrip("x" ** 1000);
    try roundTrip("0123456789" ** 100);
    // every byte value, including the 9-bit literals 144..255
    var all: [256]u8 = undefined;
    for (&all, 0..) |*c, i| c.* = @intCast(i);
    try roundTrip(&all);
    var three: [768]u8 = undefined;
    for (&three, 0..) |*c, i| c.* = @intCast(i % 256);
    try roundTrip(&three);
    for ([_]usize{ 1, 2, 3, 4, 257, 258, 259, 4095, 4096, 4097, 32767, 32768, 32769, 65536, 100000 }) |size| {
        const d = try sample(t.allocator, size, size);
        defer t.allocator.free(d);
        try roundTrip(d);
    }
}

test "a match from exactly the window's distance, and one past it" {
    // the same 40 bytes at distance 32768 (the farthest a match may reach) and at 32769 (a literal run only)
    var buf: [32768 + 40]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(&buf);
    @memcpy(buf[32768..], buf[0..40]);
    try roundTrip(&buf);
    var buf2: [32769 + 40]u8 = undefined;
    prng.random().bytes(&buf2);
    @memcpy(buf2[32769..], buf2[0..40]);
    try roundTrip(&buf2);
}

test "the nearest of two equally long matches wins, and a longer one beats a nearer one" {
    try roundTrip("abcdXXXXabcdYYYYabcdZZZZabcd");
    try roundTrip("abcdefgh--abcd--abcdefgh");
}

test "text compresses" {
    const d = try sample(t.allocator, 200_000, 3);
    defer t.allocator.free(d);
    const gz = try gzip(t.allocator, d);
    defer t.allocator.free(gz);
    try t.expect(gz.len < d.len / 2);
}

test "the header is fixed: no name, no time, and the trailer is the CRC and the length" {
    const gz = try gzip(t.allocator, "hello");
    defer t.allocator.free(gz);
    try t.expectEqualSlices(u8, &[_]u8{ 0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 3 }, gz[0..10]);
    try t.expectEqual(std.hash.Crc32.hash("hello"), std.mem.readInt(u32, gz[gz.len - 8 ..][0..4], .little));
    try t.expectEqual(@as(u32, 5), std.mem.readInt(u32, gz[gz.len - 4 ..][0..4], .little));
}

test "the same input gives the same bytes, however often and whatever the allocator" {
    const d = try sample(t.allocator, 300_000, 11);
    defer t.allocator.free(d);
    const one = try gzip(t.allocator, d);
    defer t.allocator.free(one);
    const two = try gzip(std.heap.page_allocator, d);
    defer std.heap.page_allocator.free(two);
    try t.expectEqualSlices(u8, one, two);
    var h1: [32]u8 = undefined;
    var h2: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(one, &h1, .{});
    std.crypto.hash.sha2.Sha256.hash(two, &h2, .{});
    try t.expectEqualSlices(u8, &h1, &h2);
}

test "the digest of a fixed input is pinned: a change of the encoder is a change of every archive" {
    const d = try sample(t.allocator, 300_000, 11);
    defer t.allocator.free(d);
    const gz = try gzip(t.allocator, d);
    defer t.allocator.free(gz);
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(gz, &h, .{});
    const hex = std.fmt.bytesToHex(h, .lower);
    try t.expectEqualStrings("81b608c12155057e7b4b6151a2e9ddda3e84a172ab960fc6ac4005ec1ec17c76", &hex);
}

/// What `gzip -dc` (the pinned busybox, a decoder that shares no code with the standard library's) prints for the gzip file `gz`.
fn busyboxGunzip(a: std.mem.Allocator, gz: []const u8) ![]u8 {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "x.gz", .data = gz });
    const dir = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dir);
    const path = try std.fs.path.join(a, &.{ dir, "x.gz" });
    defer a.free(path);
    const r = try std.process.Child.run(.{ .allocator = a, .argv = &.{ "gzip", "-dc", path }, .max_output_bytes = 1 << 28 });
    defer a.free(r.stderr);
    errdefer a.free(r.stdout);
    switch (r.term) {
        .Exited => |c| if (c != 0) {
            std.debug.print("gzip -dc exited {d}: {s}\n", .{ c, r.stderr });
            return error.GzipRefused;
        },
        else => return error.GzipRefused,
    }
    return r.stdout;
}

test "busybox gzip, an independent decoder, reads the streams too" {
    for ([_]usize{ 0, 1, 300, 5000, 70000, 400_000 }) |size| {
        const d = try sample(t.allocator, size, size + 5);
        defer t.allocator.free(d);
        const g = try gzip(t.allocator, d);
        defer t.allocator.free(g);
        const back = try busyboxGunzip(t.allocator, g);
        defer t.allocator.free(back);
        try t.expectEqualSlices(u8, d, back);
    }
}

/// Random content of a given kind: all random bytes, long runs, a short period repeated (matches at every distance, including past the
/// 32 KiB window), text from the vocabulary of `sample`, and a random mix of those.
fn propertyInput(a: std.mem.Allocator, r: std.Random, size: usize, kind: u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    switch (kind % 5) {
        0 => {
            while (out.items.len < size) try out.append(a, r.int(u8));
        },
        1 => {
            while (out.items.len < size) {
                const byte = r.int(u8);
                const run = 1 + r.uintLessThan(usize, 600);
                var k: usize = 0;
                while (k < run) : (k += 1) try out.append(a, byte);
            }
        },
        2 => {
            // a third of the periods are around the window, where a match of exactly that distance is, or is not, allowed
            const period = switch (r.uintLessThan(u8, 3)) {
                0 => 1 + r.uintLessThan(usize, 300),
                1 => 1 + r.uintLessThan(usize, 40_000),
                else => 32_767 + r.uintLessThan(usize, 4),
            };
            const unit = try a.alloc(u8, period);
            defer a.free(unit);
            for (unit) |*b| b.* = r.int(u8);
            // a period near the window needs the data to repeat at least once for a match at that distance to exist
            const total = if (period > 30_000) @max(size, period * 2 + 5) else size;
            while (out.items.len < total) try out.appendSlice(a, unit);
            out.shrinkRetainingCapacity(total);
            return out.toOwnedSlice(a);
        },
        3 => {
            const text = try sample(a, size, r.int(u64));
            defer a.free(text);
            try out.appendSlice(a, text);
        },
        else => {
            while (out.items.len < size) {
                const piece = try propertyInput(a, r, 1 + r.uintLessThan(usize, 3000), r.int(u8) % 4);
                defer a.free(piece);
                try out.appendSlice(a, piece);
            }
        },
    }
    out.shrinkRetainingCapacity(size);
    return out.toOwnedSlice(a);
}

test "property: random lengths and contents round-trip through the standard library's decoder (fixed seed)" {
    var prng = std.Random.DefaultPrng.init(0x62756c64);
    const r = prng.random();
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        // mostly small sizes, where the edge cases of the block and the matcher are, and some past the 32 KiB window
        const size: usize = switch (r.uintLessThan(u8, 8)) {
            0 => r.uintLessThan(usize, 4),
            1, 2, 3 => r.uintLessThan(usize, 600),
            4, 5 => r.uintLessThan(usize, 20_000),
            6 => 30_000 + r.uintLessThan(usize, 6000),
            else => r.uintLessThan(usize, 150_000),
        };
        const data = try propertyInput(t.allocator, r, size, r.int(u8));
        defer t.allocator.free(data);
        roundTrip(data) catch |e| {
            std.debug.print("property failed at case {d}: size {d}\n", .{ i, size });
            return e;
        };
    }
}
