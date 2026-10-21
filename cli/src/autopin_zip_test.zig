//! The zip reader against hostile archives. Each test builds a zip that is valid except for one defect and names
//! the error that defect must give; the first tests are the valid forms that must be accepted (the layout
//! `upload-artifact` writes: deflate or stored members, a data descriptor after each, zeros in the local header).

const std = @import("std");
const zip = @import("autopin_zip.zig");
const t = std.testing;

const names = [_][]const u8{ "manifest.json", "site/buildrules.lock.bzl", "a.txt", "b.txt" };

fn put16(b: []u8, o: usize, v: u16) void {
    std.mem.writeInt(u16, b[o..][0..2], v, .little);
}
fn put32(b: []u8, o: usize, v: u32) void {
    std.mem.writeInt(u32, b[o..][0..4], v, .little);
}
fn get32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}

const Part = struct {
    name: []const u8,
    data: []const u8 = "hello\n",
    /// 0 stored; 8 deflate (a stored block, unless `comp` is given)
    method: u16 = 8,
    comp: ?[]const u8 = null,
    /// flag bit 3: zeros in the local header, a descriptor after the data
    descriptor: bool = true,
    /// descriptor signature present
    desc_sig: bool = true,
    made_by: u16 = 0x031e,
    eattr: u32 = 0o100644 << 16,
    cd_extra: []const u8 = "",
    declared_usize: ?u32 = null,
};

const Z = struct {
    bytes: []u8,
    lfh: [16]usize = undefined,
    cd: [16]usize = undefined,
    data: [16]usize = undefined,
    desc: [16]usize = undefined,
    cd_off: usize = 0,
    eocd: usize = 0,
};

/// A deflate stream made of one stored block.
fn storedBlock(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(a, 0x01);
    const n: u16 = @intCast(data.len);
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, n)));
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~n)));
    try out.appendSlice(a, data);
    return out.items;
}

/// A fixed-Huffman deflate stream: the byte 'a' and then `count` copies of a 258-byte match at distance 1, so it
/// inflates to 1 + 258 * count bytes of 'a' in about 13 bits per 258 bytes.
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
        // A Huffman code is packed starting from its most significant bit.
        fn code(o: *std.ArrayList(u8), al: std.mem.Allocator, c: *u8, n: *u4, v: u16, len: u4) !void {
            var i: u4 = len;
            while (i > 0) {
                i -= 1;
                try bit(o, al, c, n, @intCast((v >> i) & 1));
            }
        }
    };
    try W.bit(&out, a, &cur, &nbits, 1); // BFINAL
    try W.bit(&out, a, &cur, &nbits, 1); // BTYPE 01, low bit first
    try W.bit(&out, a, &cur, &nbits, 0);
    try W.code(&out, a, &cur, &nbits, 0x30 + 'a', 8);
    var k: usize = 0;
    while (k < count) : (k += 1) {
        try W.code(&out, a, &cur, &nbits, 0xC0 + 5, 8); // length code 285 = 258
        try W.code(&out, a, &cur, &nbits, 0, 5); // distance code 0 = 1
    }
    try W.code(&out, a, &cur, &nbits, 0, 7); // end of block
    if (nbits > 0) try out.append(a, cur);
    return out.items;
}

fn build(a: std.mem.Allocator, parts: []const Part) !Z {
    var out = std.ArrayList(u8).empty;
    var z = Z{ .bytes = &.{} };
    var cds = std.ArrayList(u8).empty;
    for (parts, 0..) |p, i| {
        const comp: []const u8 = if (p.method == 0) p.data else p.comp orelse try storedBlock(a, p.data);
        const crc = std.hash.Crc32.hash(p.data);
        const usize_: u32 = p.declared_usize orelse @intCast(p.data.len);
        z.lfh[i] = out.items.len;
        var h: [30]u8 = undefined;
        @memset(&h, 0);
        put32(&h, 0, 0x04034b50);
        put16(&h, 4, 20);
        put16(&h, 6, if (p.descriptor) 0x0008 else 0);
        put16(&h, 8, p.method);
        if (!p.descriptor) {
            put32(&h, 14, crc);
            put32(&h, 18, @intCast(comp.len));
            put32(&h, 22, usize_);
        }
        put16(&h, 26, @intCast(p.name.len));
        try out.appendSlice(a, &h);
        try out.appendSlice(a, p.name);
        z.data[i] = out.items.len;
        try out.appendSlice(a, comp);
        z.desc[i] = out.items.len;
        if (p.descriptor) {
            var d: [16]u8 = undefined;
            put32(&d, 0, 0x08074b50);
            put32(&d, 4, crc);
            put32(&d, 8, @intCast(comp.len));
            put32(&d, 12, usize_);
            const written: []const u8 = if (p.desc_sig) d[0..] else d[4..];
            try out.appendSlice(a, written);
        }
        var c: [46]u8 = undefined;
        @memset(&c, 0);
        put32(&c, 0, 0x02014b50);
        put16(&c, 4, p.made_by);
        put16(&c, 6, 20);
        put16(&c, 8, if (p.descriptor) 0x0008 else 0);
        put16(&c, 10, p.method);
        put32(&c, 16, crc);
        put32(&c, 20, @intCast(comp.len));
        put32(&c, 24, usize_);
        put16(&c, 28, @intCast(p.name.len));
        put16(&c, 30, @intCast(p.cd_extra.len));
        put32(&c, 38, p.eattr);
        put32(&c, 42, @intCast(z.lfh[i]));
        z.cd[i] = cds.items.len;
        try cds.appendSlice(a, &c);
        try cds.appendSlice(a, p.name);
        try cds.appendSlice(a, p.cd_extra);
    }
    z.cd_off = out.items.len;
    for (parts, 0..) |_, i| z.cd[i] += z.cd_off;
    try out.appendSlice(a, cds.items);
    z.eocd = out.items.len;
    var e: [22]u8 = undefined;
    @memset(&e, 0);
    put32(&e, 0, 0x06054b50);
    put16(&e, 8, @intCast(parts.len));
    put16(&e, 10, @intCast(parts.len));
    put32(&e, 12, @intCast(cds.items.len));
    put32(&e, 16, @intCast(z.cd_off));
    try out.appendSlice(a, &e);
    z.bytes = out.items;
    return z;
}

fn two(a: std.mem.Allocator) !Z {
    return build(a, &.{ .{ .name = "manifest.json", .data = "{}\n" }, .{ .name = "a.txt" } });
}

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

fn readIt(a: std.mem.Allocator, z: Z) zip.Error![]zip.Entry {
    return zip.read(a, z.bytes, &names, .{});
}

test "accepts the upload-artifact layout: deflate members, a descriptor after each, zeros in the local header" {
    var ar = arena();
    defer ar.deinit();
    const z = try two(ar.allocator());
    const got = try readIt(ar.allocator(), z);
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("manifest.json", got[0].name);
    try t.expectEqualStrings("{}\n", got[0].data);
    try t.expectEqualStrings("hello\n", got[1].data);
}

test "accepts a descriptor without its signature, a stored member, and sizes in the local header" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const z = try build(a, &.{
        .{ .name = "manifest.json", .data = "{}\n", .desc_sig = false },
        .{ .name = "a.txt", .method = 0, .descriptor = false },
        .{ .name = "b.txt", .method = 0, .data = "" },
    });
    const got = try readIt(a, z);
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqualStrings("hello\n", got[1].data);
    try t.expectEqualStrings("", got[2].data);
}

test "inflates a real compressed stream (fixed Huffman, a long match)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const comp = try runOfA(a, 2);
    const want = "a" ** 517;
    const z = try build(a, &.{.{ .name = "a.txt", .data = want, .comp = comp }});
    const got = try readIt(a, z);
    try t.expectEqualStrings(want, got[0].data);
}

test "symlink attributes are refused" {
    var ar = arena();
    defer ar.deinit();
    const z = try build(ar.allocator(), &.{.{ .name = "a.txt", .eattr = 0o120777 << 16 }});
    try t.expectError(error.SymlinkOrSpecial, readIt(ar.allocator(), z));
}

test "a directory entry is refused (by trailing slash and by attribute)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectError(error.DirectoryEntry, readIt(a, try build(a, &.{.{ .name = "site/", .data = "", .method = 0, .descriptor = false }})));
    try t.expectError(error.DirectoryEntry, readIt(a, try build(a, &.{.{ .name = "a.txt", .eattr = 0o040755 << 16 }})));
    try t.expectError(error.DirectoryEntry, readIt(a, try build(a, &.{.{ .name = "a.txt", .made_by = 0, .eattr = 0x10 }})));
}

test "names: .., backslash, NUL, absolute, drive, empty and dot components are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const cases = [_]struct { name: []const u8, err: zip.Error }{
        .{ .name = "../a.txt", .err = error.DotDotName },
        .{ .name = "site/../../a.txt", .err = error.DotDotName },
        .{ .name = "site\\a.txt", .err = error.BackslashInName },
        .{ .name = "a\x00.txt", .err = error.NulInName },
        .{ .name = "/etc/a.txt", .err = error.AbsoluteName },
        .{ .name = "C:a.txt", .err = error.AbsoluteName },
        .{ .name = "site//a.txt", .err = error.BadName },
        .{ .name = "./a.txt", .err = error.BadName },
        .{ .name = "a\x01.txt", .err = error.BadName },
    };
    for (cases) |c| {
        const z = try build(a, &.{.{ .name = c.name }});
        try t.expectError(c.err, readIt(a, z));
    }
}

test "two members with one name, and two that differ only by case, are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectError(error.DuplicateName, readIt(a, try build(a, &.{ .{ .name = "a.txt" }, .{ .name = "a.txt" } })));
    try t.expectError(error.CaseFoldTwin, readIt(a, try build(a, &.{ .{ .name = "a.txt" }, .{ .name = "A.txt" } })));
}

test "names that are one name in two Unicode normalizations (NFC and NFD) are refused: no non-ASCII name is accepted" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const nfc = try build(a, &.{.{ .name = "caf\xc3\xa9.txt" }});
    const nfd = try build(a, &.{.{ .name = "cafe\xcc\x81.txt" }});
    try t.expectError(error.NonAsciiName, readIt(a, nfc));
    try t.expectError(error.NonAsciiName, readIt(a, nfd));
    try t.expectError(error.NonAsciiName, readIt(a, try build(a, &.{ .{ .name = "a.txt" }, .{ .name = "caf\xc3\xa9.txt" }, .{ .name = "cafe\xcc\x81.txt" } })));
}

test "a member whose name is not in the list is refused" {
    var ar = arena();
    defer ar.deinit();
    const z = try build(ar.allocator(), &.{ .{ .name = "a.txt" }, .{ .name = ".github/workflows/x.yml" } });
    try t.expectError(error.UnexpectedMember, readIt(ar.allocator(), z));
}

test "overlapping entries are refused (a second entry whose local header is inside the first one's data)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const inner = try build(a, &.{.{ .name = "a.txt", .method = 0, .descriptor = false }});
    const embedded = inner.bytes[0..inner.cd_off];
    const z = try build(a, &.{
        .{ .name = "manifest.json", .method = 0, .descriptor = false, .data = embedded },
        .{ .name = "a.txt", .method = 0, .descriptor = false },
    });
    // The central entry of a.txt now points into the middle of manifest.json's data, where a whole local entry lies.
    put32(z.bytes, z.cd[1] + 42, @intCast(z.data[0]));
    try t.expectError(error.OverlappingEntries, readIt(a, z));
}

test "bytes between two entries are refused (an entry hidden in a gap)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const z = try two(a);
    // Move the second local header one byte later and pad: the first entry no longer ends where the second starts.
    var padded = std.ArrayList(u8).empty;
    try padded.appendSlice(a, z.bytes[0..z.lfh[1]]);
    try padded.append(a, 0);
    try padded.appendSlice(a, z.bytes[z.lfh[1]..]);
    const bytes = padded.items;
    const shift: u32 = 1;
    put32(bytes, z.eocd + 1 + 16, @intCast(z.cd_off + shift));
    put32(bytes, z.cd[1] + 1 + 42, @intCast(z.lfh[1] + shift));
    try t.expectError(error.GapBetweenEntries, zip.read(a, bytes, &names, .{}));
}

test "a local header that disagrees with the central directory is refused (name, flags, method, crc, sizes)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    {
        const z = try build(a, &.{.{ .name = "a.txt" }});
        z.bytes[z.lfh[0] + 30] = 'b'; // name
        try t.expectError(error.LocalHeaderMismatch, readIt(a, z));
    }
    {
        const z = try build(a, &.{.{ .name = "a.txt" }});
        put16(z.bytes, z.lfh[0] + 6, 0x0808); // flags
        try t.expectError(error.LocalHeaderMismatch, readIt(a, z));
    }
    {
        const z = try build(a, &.{.{ .name = "a.txt" }});
        put16(z.bytes, z.lfh[0] + 8, 0); // method
        try t.expectError(error.LocalHeaderMismatch, readIt(a, z));
    }
    {
        const z = try build(a, &.{.{ .name = "a.txt", .descriptor = false }});
        put32(z.bytes, z.lfh[0] + 14, 1); // crc
        try t.expectError(error.LocalHeaderMismatch, readIt(a, z));
    }
    {
        const z = try build(a, &.{.{ .name = "a.txt", .descriptor = false }});
        put32(z.bytes, z.lfh[0] + 22, 99); // usize
        try t.expectError(error.LocalHeaderMismatch, readIt(a, z));
    }
    {
        // With the descriptor bit a NON-zero local value must still agree.
        const z = try build(a, &.{.{ .name = "a.txt" }});
        put32(z.bytes, z.lfh[0] + 14, 77);
        try t.expectError(error.LocalHeaderMismatch, readIt(a, z));
    }
}

test "zip64 is refused: a sentinel in the end record, in a central entry, a locator, a zip64 extra field" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    {
        const z = try two(a);
        put16(z.bytes, z.eocd + 10, 0xFFFF);
        put16(z.bytes, z.eocd + 8, 0xFFFF);
        try t.expectError(error.Zip64, readIt(a, z));
    }
    {
        const z = try two(a);
        put32(z.bytes, z.cd[0] + 20, 0xFFFFFFFF);
        try t.expectError(error.Zip64, readIt(a, z));
    }
    {
        // A zip64 end-record locator in the 20 bytes before the end record.
        const z = try two(a);
        var b = std.ArrayList(u8).empty;
        try b.appendSlice(a, z.bytes[0..z.eocd]);
        var loc = [_]u8{0} ** 20;
        put32(&loc, 0, 0x07064b50);
        try b.appendSlice(a, &loc);
        try b.appendSlice(a, z.bytes[z.eocd..]);
        put32(b.items, z.eocd + 20 + 12, @intCast(z.eocd - z.cd_off + 20));
        try t.expectError(error.Zip64, zip.read(a, b.items, &names, .{}));
    }
    {
        const extra = [_]u8{ 0x01, 0x00, 0x08, 0x00, 0, 0, 0, 0, 0, 0, 0, 0 };
        const z = try build(a, &.{.{ .name = "a.txt", .cd_extra = &extra }});
        try t.expectError(error.Zip64, readIt(a, z));
    }
}

test "encryption flags and unknown flag bits are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    {
        const z = try build(a, &.{.{ .name = "a.txt" }});
        put16(z.bytes, z.cd[0] + 8, 0x0009);
        try t.expectError(error.Encrypted, readIt(a, z));
    }
    {
        const z = try build(a, &.{.{ .name = "a.txt" }});
        put16(z.bytes, z.cd[0] + 8, 0x0048);
        try t.expectError(error.Encrypted, readIt(a, z));
    }
    {
        const z = try build(a, &.{.{ .name = "a.txt" }});
        put16(z.bytes, z.cd[0] + 8, 0x0018);
        try t.expectError(error.BadFlags, readIt(a, z));
    }
}

test "a method other than stored and deflate is refused (method 12, bzip2)" {
    var ar = arena();
    defer ar.deinit();
    const z = try build(ar.allocator(), &.{.{ .name = "a.txt" }});
    put16(z.bytes, z.cd[0] + 10, 12);
    put16(z.bytes, z.lfh[0] + 8, 12);
    try t.expectError(error.BadMethod, readIt(ar.allocator(), z));
}

test "a data descriptor that lies is refused (crc, compressed size, size)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const fields = [_]usize{ 4, 8, 12 };
    for (fields) |f| {
        const z = try build(a, &.{.{ .name = "a.txt" }});
        put32(z.bytes, z.desc[0] + f, get32(z.bytes, z.desc[0] + f) +% 1);
        try t.expectError(error.DescriptorMismatch, readIt(a, z));
    }
    {
        const z = try build(a, &.{.{ .name = "a.txt", .desc_sig = false }});
        put32(z.bytes, z.desc[0] + 8, 1234);
        try t.expectError(error.DescriptorMismatch, readIt(a, z));
    }
}

test "bytes after the end record, and a comment, are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const z = try two(a);
    const longer = try std.mem.concat(a, u8, &.{ z.bytes, "tail" });
    try t.expectError(error.TrailingBytes, zip.read(a, longer, &names, .{}));
    const z2 = try two(a);
    put16(z2.bytes, z2.eocd + 20, 4);
    const commented = try std.mem.concat(a, u8, &.{ z2.bytes, "note" });
    try t.expectError(error.TrailingBytes, zip.read(a, commented, &names, .{}));
    put16(z2.bytes, z2.eocd + 20, 4);
    try t.expectError(error.CommentPresent, readIt(a, z2));
}

test "a second end record is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const z = try two(a);
    const doubled = try std.mem.concat(a, u8, &.{ z.bytes, z.bytes[z.eocd..] });
    try t.expectError(error.MultipleEocd, zip.read(a, doubled, &names, .{}));
}

test "something that is not a zip, or is too short, is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectError(error.TooShort, zip.read(a, "PK", &names, .{}));
    try t.expectError(error.NotAZip, zip.read(a, "x" ** 64, &names, .{}));
}

test "an inflated bomb under a small declared size is cut off at the declared size" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const bomb = try runOfA(a, 20000); // inflates to 5.1 MB
    const z = try build(a, &.{.{ .name = "a.txt", .data = "a" ** 100, .comp = bomb, .declared_usize = 100 }});
    try t.expectError(error.InflatedBeyondDeclared, readIt(a, z));
}

test "a member that inflates to less than it declared is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const z = try build(a, &.{.{ .name = "a.txt", .data = "hello\n", .declared_usize = 9 }});
    try t.expectError(error.SizeMismatch, readIt(a, z));
}

test "more entries than the limit are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var parts: [13]Part = undefined;
    var allowed: [13][]const u8 = undefined;
    for (&parts, 0..) |*p, i| {
        const n = try std.fmt.allocPrint(a, "f{d}.txt", .{i});
        p.* = .{ .name = n };
        allowed[i] = n;
    }
    const z = try build(a, &parts);
    try t.expectError(error.TooManyEntries, zip.read(a, z.bytes, &allowed, .{}));
    // Twelve are fine.
    const z12 = try build(a, parts[0..12]);
    try t.expectEqual(@as(usize, 12), (try zip.read(a, z12.bytes, &allowed, .{})).len);
}

test "a wrong crc is refused" {
    var ar = arena();
    defer ar.deinit();
    const z = try build(ar.allocator(), &.{.{ .name = "a.txt", .descriptor = false }});
    put32(z.bytes, z.cd[0] + 16, 5);
    put32(z.bytes, z.lfh[0] + 14, 5);
    try t.expectError(error.CrcMismatch, readIt(ar.allocator(), z));
}

test "sizes: a member over the file cap, the manifest over its cap, all together over the total, a ratio over 100:1" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const lim = zip.Limits{ .max_file = 64, .max_manifest = 16, .max_total = 100 };
    const big = "x" ** 65;
    try t.expectError(error.FileTooLarge, zip.read(a, (try build(a, &.{.{ .name = "a.txt", .data = big, .method = 0, .descriptor = false }})).bytes, &names, lim));
    try t.expectError(error.ManifestTooLarge, zip.read(a, (try build(a, &.{.{ .name = "manifest.json", .data = "y" ** 17, .method = 0, .descriptor = false }})).bytes, &names, lim));
    const sixty = "z" ** 60;
    try t.expectError(error.TotalTooLarge, zip.read(a, (try build(a, &.{
        .{ .name = "a.txt", .data = sixty, .method = 0, .descriptor = false },
        .{ .name = "b.txt", .data = sixty, .method = 0, .descriptor = false },
    })).bytes, &names, lim));
    // 517 inflated bytes from 6 stored bytes of deflate: over 100:1.
    const comp = try runOfA(a, 100);
    const z = try build(a, &.{.{ .name = "a.txt", .data = "a" ** 25801, .comp = comp }});
    try t.expectError(error.RatioTooHigh, readIt(a, z));
}

test "a local header or data that runs past the central directory is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    {
        const z = try build(a, &.{.{ .name = "a.txt" }});
        put32(z.bytes, z.cd[0] + 20, 5000);
        put32(z.bytes, z.desc[0] + 8, 5000);
        try t.expectError(error.DataOutOfRange, readIt(a, z));
    }
    {
        const z = try build(a, &.{.{ .name = "a.txt" }});
        put32(z.bytes, z.cd[0] + 42, @intCast(z.cd_off));
        try t.expectError(error.DataOutOfRange, readIt(a, z));
    }
    {
        const z = try build(a, &.{.{ .name = "a.txt" }});
        put32(z.bytes, z.lfh[0], 0);
        try t.expectError(error.BadLocalHeader, readIt(a, z));
    }
}

test "a broken central directory is refused (signature, truncation, misplaced)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    {
        const z = try two(a);
        put32(z.bytes, z.cd[1], 0);
        try t.expectError(error.BadCentralHeader, readIt(a, z));
    }
    {
        const z = try two(a);
        put32(z.bytes, z.eocd + 12, 100000);
        try t.expectError(error.CentralDirectoryTruncated, readIt(a, z));
    }
    {
        const z = try two(a);
        put32(z.bytes, z.eocd + 12, @intCast(z.eocd - z.cd_off - 5));
        try t.expectError(error.CentralDirectoryMisplaced, readIt(a, z));
    }
    {
        const z = try two(a);
        put16(z.bytes, z.eocd + 4, 1);
        try t.expectError(error.MultiDisk, readIt(a, z));
    }
    {
        const z = try two(a);
        put16(z.bytes, z.eocd + 8, 0);
        put16(z.bytes, z.eocd + 10, 0);
        try t.expectError(error.Empty, readIt(a, z));
    }
}

test "a malformed extra field is refused" {
    var ar = arena();
    defer ar.deinit();
    const extra = [_]u8{ 0x55, 0x54, 0x20, 0x00, 1 };
    const z = try build(ar.allocator(), &.{.{ .name = "a.txt", .cd_extra = &extra }});
    try t.expectError(error.BadExtra, readIt(ar.allocator(), z));
}

test "a well-formed extra field that is not zip64 is accepted" {
    var ar = arena();
    defer ar.deinit();
    const extra = [_]u8{ 0x55, 0x54, 0x05, 0x00, 1, 0, 0, 0, 0 };
    const z = try build(ar.allocator(), &.{.{ .name = "a.txt", .cd_extra = &extra }});
    try t.expectEqualStrings("hello\n", (try readIt(ar.allocator(), z))[0].data);
}
