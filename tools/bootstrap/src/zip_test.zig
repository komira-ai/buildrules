//! zip.zig: members stored and deflated, zip64, Unix modes and links, and every refusal. The files are written by testkit.zig.
const std = @import("std");
const kit = @import("testkit.zig");
const t = std.testing;
const a = kit.a;

const S_IFREG = 0o100000;
const S_IFLNK = 0o120000;
const S_IFDIR = 0o040000;

fn expectFile(d: *kit.Dest, path: []const u8, want: []const u8) !void {
    const got = try d.read(path);
    defer a.free(got);
    try t.expectEqualStrings(want, got);
}

fn expectListing(d: *kit.Dest, want: []const u8) !void {
    const got = try d.listing();
    defer a.free(got);
    try t.expectEqualStrings(want, got);
}

fn build(members: []const kit.Member, zip64_end: bool) ![]u8 {
    var z = kit.Zip{};
    defer z.deinit();
    for (members) |m| try z.add(m);
    return z.finish(zip64_end);
}

test "stored and deflated members, directories, and the bytes of each" {
    const text = "deflated content, deflated content, deflated content";
    const body = try kit.deflateText(text);
    const file = try build(&.{
        .{ .name = "pkg/", .data = "" },
        .{ .name = "pkg/stored.txt", .data = "stored" },
        .{ .name = "pkg/deflated.txt", .data = text, .body = body },
        .{ .name = "pkg/empty", .data = "" },
    }, false);
    defer a.free(file);
    defer a.free(body);
    var d = kit.Dest.init();
    defer d.deinit();
    const stats = try d.unpack(file, .zip, 0);
    try t.expectEqual(@as(u64, 3), stats.files);
    try t.expectEqual(@as(u64, 1), stats.dirs);
    try expectFile(&d, "pkg/stored.txt", "stored");
    try expectFile(&d, "pkg/deflated.txt", text);
    try expectFile(&d, "pkg/empty", "");
    try expectListing(&d, "pkg/\npkg/deflated.txt\npkg/empty\npkg/stored.txt\n");
}

test "strip-components drops leading components; a member with none left is skipped" {
    const file = try build(&.{
        .{ .name = "top/", .data = "" },
        .{ .name = "top/a/b", .data = "kept" },
        .{ .name = "loose", .data = "skipped" },
    }, false);
    defer a.free(file);
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(file, .zip, 1);
    try expectListing(&d, "a/\na/b\n");
    try expectFile(&d, "a/b", "kept");
}

test "Unix members keep their permission bits, and a link is a link" {
    const file = try build(&.{
        .{ .name = "bin/run", .data = "program", .unix_mode = S_IFREG | 0o755 },
        .{ .name = "bin/plain", .data = "text", .unix_mode = S_IFREG | 0o644 },
        .{ .name = "bin/alias", .data = "run", .unix_mode = S_IFLNK | 0o777 },
        .{ .name = "bin/sub", .data = "", .unix_mode = S_IFDIR | 0o755 },
        .{ .name = "bin/untyped", .data = "u", .unix_mode = 0o700 },
    }, false);
    defer a.free(file);
    var d = kit.Dest.init();
    defer d.deinit();
    const stats = try d.unpack(file, .zip, 0);
    try t.expectEqual(@as(u64, 1), stats.links);
    try t.expectEqual(@as(u32, 0o755), try d.mode("bin/run"));
    try t.expectEqual(@as(u32, 0o644), try d.mode("bin/plain"));
    try t.expectEqual(@as(u32, 0o700), try d.mode("bin/untyped"));
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("run", try d.link("bin/alias", &buf));
    try t.expect(d.has("bin/sub"));
}

test "members of another host are files of mode 0644" {
    const file = try build(&.{.{ .name = "dos.txt", .data = "x", .host = 0 }}, false);
    defer a.free(file);
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(file, .zip, 0);
    try t.expectEqual(@as(u32, 0o644), try d.mode("dos.txt"));
}

test "zip64: sizes and offsets in the extra field, and the zip64 end of directory" {
    const file = try build(&.{
        .{ .name = "big.bin", .data = "zip64 member", .zip64 = true },
        .{ .name = "next.bin", .data = "after it" },
    }, true);
    defer a.free(file);
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(file, .zip, 0);
    try expectFile(&d, "big.bin", "zip64 member");
    try expectFile(&d, "next.bin", "after it");
    // the extra field is cut short: it has no room for the three values
    const cut = try a.dupe(u8, file);
    defer a.free(cut);
    const at = std.mem.indexOf(u8, cut, "\x01\x00\x18\x00").?;
    cut[at + 2] = 8; // the field says it is eight bytes: the first value only
    var d2 = kit.Dest.init();
    defer d2.deinit();
    try t.expectError(error.BadZip, d2.unpack(cut, .zip, 0));
}

test "zip-slip: the names tar-slip refuses are refused" {
    for ([_][]const u8{ "../evil", "a/../../evil", "pkg/../evil" }) |name| {
        const file = try build(&.{.{ .name = name, .data = "pwned" }}, false);
        defer a.free(file);
        var d = kit.Dest.init();
        defer d.deinit();
        try t.expectError(error.ParentComponent, d.unpack(file, .zip, 0));
        try t.expectError(error.FileNotFound, d.tmp.parent_dir.access("evil", .{}));
    }
    const abs = try build(&.{.{ .name = "/tmp/evil_from_unpack_zip_test", .data = "pwned" }}, false);
    defer a.free(abs);
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.AbsolutePath, d.unpack(abs, .zip, 0));
    try t.expectError(error.AbsolutePath, d.unpack(abs, .zip, 1));
    const dir = try build(&.{.{ .name = "../evil/", .data = "" }}, false);
    defer a.free(dir);
    try t.expectError(error.ParentComponent, d.unpack(dir, .zip, 0));
}

test "zip-slip: a symbolic link out of the destination, and a write through a link, are refused" {
    for ([_][]const u8{ "/etc", "../outside", "a/../../b" }) |target| {
        const file = try build(&.{.{ .name = "l", .data = target, .unix_mode = S_IFLNK | 0o777 }}, false);
        defer a.free(file);
        var d = kit.Dest.init();
        defer d.deinit();
        try t.expectError(error.LinkEscapes, d.unpack(file, .zip, 0));
    }
    const through = try build(&.{
        .{ .name = "real/", .data = "" },
        .{ .name = "alias", .data = "real", .unix_mode = S_IFLNK | 0o777 },
        .{ .name = "alias/evil", .data = "pwned" },
    }, false);
    defer a.free(through);
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.ThroughSymlink, d.unpack(through, .zip, 0));
    try t.expect(!d.has("real/evil"));
}

test "a link target longer than a path is refused" {
    const long = "a" ** 5000;
    const file = try build(&.{.{ .name = "l", .data = long, .unix_mode = S_IFLNK | 0o777 }}, false);
    defer a.free(file);
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.NameTooLong, d.unpack(file, .zip, 0));
}

test "members that are refused: encrypted, other methods, backslashes, devices, empty names" {
    const enc = try build(&.{.{ .name = "f", .data = "x", .flags = 1 }}, false);
    defer a.free(enc);
    const strong = try build(&.{.{ .name = "f", .data = "x", .flags = 0x40 }}, false);
    defer a.free(strong);
    const bz = try build(&.{.{ .name = "f", .data = "x", .method = 12 }}, false);
    defer a.free(bz);
    const bs = try build(&.{.{ .name = "dir\\f", .data = "x" }}, false);
    defer a.free(bs);
    const fifo = try build(&.{.{ .name = "f", .data = "x", .unix_mode = 0o010000 | 0o644 }}, false);
    defer a.free(fifo);
    const noname = try build(&.{.{ .name = "", .data = "x" }}, false);
    defer a.free(noname);
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.Encrypted, d.unpack(enc, .zip, 0));
    try t.expectError(error.Encrypted, d.unpack(strong, .zip, 0));
    try t.expectError(error.UnsupportedMethod, d.unpack(bz, .zip, 0));
    try t.expectError(error.BackslashInName, d.unpack(bs, .zip, 0));
    try t.expectError(error.UnsupportedType, d.unpack(fifo, .zip, 0));
    try t.expectError(error.EmptyName, d.unpack(noname, .zip, 0));
}

test "a member whose CRC-32 or length is not its header's is refused" {
    const crc = try build(&.{.{ .name = "f", .data = "payload", .crc = 0x12345678 }}, false);
    defer a.free(crc);
    const len = try build(&.{.{ .name = "f", .data = "payload", .usize_ = 99 }}, false);
    defer a.free(len);
    const body = try kit.deflateText("deflated");
    defer a.free(body);
    const dcrc = try build(&.{.{ .name = "f", .data = "deflated", .body = body, .crc = 1 }}, false);
    defer a.free(dcrc);
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.EntryCorrupt, d.unpack(crc, .zip, 0));
    try t.expectError(error.EntryCorrupt, d.unpack(len, .zip, 0));
    try t.expectError(error.EntryCorrupt, d.unpack(dcrc, .zip, 0));
}

test "a deflated member that is cut off is refused" {
    const full = try kit.deflateText("a deflated member that will be cut");
    defer a.free(full);
    const file = try build(&.{.{ .name = "f", .data = "a deflated member that will be cut", .body = full[0 .. full.len - 3] }}, false);
    defer a.free(file);
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.Truncated, d.unpack(file, .zip, 0));
}

test "the structure: no directory, bad signatures, offsets past the end, split archives" {
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.BadZip, d.unpack("", .zip, 0));
    try t.expectError(error.BadZip, d.unpack("PK\x03\x04 and not much more of a zip file here", .zip, 0));
    const ok = try build(&.{.{ .name = "f", .data = "x" }}, false);
    defer a.free(ok);
    // the end record names a directory offset past the end
    const far = try a.dupe(u8, ok);
    defer a.free(far);
    std.mem.writeInt(u32, far[far.len - 6 ..][0..4], 0x00ffffff, .little);
    try t.expectError(error.BadZip, d.unpack(far, .zip, 0));
    // a central header with a wrong signature
    const sig = try a.dupe(u8, ok);
    defer a.free(sig);
    const cd = std.mem.indexOf(u8, sig, "PK\x01\x02").?;
    sig[cd] = 'X';
    try t.expectError(error.BadZip, d.unpack(sig, .zip, 0));
    // a local header with a wrong signature
    const local = try a.dupe(u8, ok);
    defer a.free(local);
    local[0] = 'X';
    try t.expectError(error.BadZip, d.unpack(local, .zip, 0));
    // a member whose bytes run past the end of the file
    const over = try a.dupe(u8, ok);
    defer a.free(over);
    std.mem.writeInt(u32, over[cd + 20 ..][0..4], 0x00ffffff, .little);
    try t.expectError(error.BadZip, d.unpack(over, .zip, 0));
    // a split archive
    const split = try a.dupe(u8, ok);
    defer a.free(split);
    split[split.len - 22 + 4] = 1;
    try t.expectError(error.SplitArchive, d.unpack(split, .zip, 0));
}

test "zip64 structure: a missing or split locator is refused" {
    const z64 = try build(&.{.{ .name = "f", .data = "x" }}, true);
    defer a.free(z64);
    var d = kit.Dest.init();
    defer d.deinit();
    const nolocator = try a.dupe(u8, z64);
    defer a.free(nolocator);
    const loc = std.mem.indexOf(u8, nolocator, "PK\x06\x07").?;
    nolocator[loc] = 'X';
    try t.expectError(error.BadZip, d.unpack(nolocator, .zip, 0));
    const splitloc = try a.dupe(u8, z64);
    defer a.free(splitloc);
    std.mem.writeInt(u32, splitloc[loc + 16 ..][0..4], 2, .little);
    try t.expectError(error.SplitArchive, d.unpack(splitloc, .zip, 0));
    const badrec = try a.dupe(u8, z64);
    defer a.free(badrec);
    const rec = std.mem.indexOf(u8, badrec, "PK\x06\x06").?;
    badrec[rec] = 'X';
    try t.expectError(error.BadZip, d.unpack(badrec, .zip, 0));
    const splitrec = try a.dupe(u8, z64);
    defer a.free(splitrec);
    splitrec[rec + 16] = 1;
    try t.expectError(error.SplitArchive, d.unpack(splitrec, .zip, 0));
    // a locator in a file too short to hold one
    var tiny = [_]u8{0} ** 22;
    std.mem.writeInt(u32, tiny[0..4], 0x06054b50, .little);
    std.mem.writeInt(u16, tiny[10..12], 0xffff, .little);
    try t.expectError(error.BadZip, d.unpack(&tiny, .zip, 0));
}

test "an archive with no member is refused" {
    const empty = try build(&.{}, false);
    defer a.free(empty);
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.EmptyArchive, d.unpack(empty, .zip, 0));
}

test "truncated zip: no proper prefix of a file is accepted" {
    const file = try build(&.{
        .{ .name = "a/", .data = "" },
        .{ .name = "a/f", .data = "first member" },
        .{ .name = "a/g", .data = "second member" },
    }, false);
    defer a.free(file);
    var cut: usize = 0;
    while (cut < file.len) : (cut += 1) {
        _ = kit.Dest.check(file[0..cut], .zip, 0) catch continue;
        std.debug.print("a zip file cut at {d} of {d} bytes was accepted\n", .{ cut, file.len });
        return error.TestUnexpectedResult;
    }
    _ = try kit.Dest.check(file, .zip, 0);
}

test "check mode reads every member and writes nothing" {
    const file = try build(&.{
        .{ .name = "x/f", .data = "content" },
        .{ .name = "x/l", .data = "f", .unix_mode = S_IFLNK | 0o777 },
        .{ .name = "skipped", .data = "gone" },
    }, false);
    defer a.free(file);
    const stats = try kit.Dest.check(file, .zip, 1);
    try t.expectEqual(@as(u64, 1), stats.links);
    const bad = try build(&.{.{ .name = "f", .data = "payload", .crc = 5 }}, false);
    defer a.free(bad);
    try t.expectError(error.EntryCorrupt, kit.Dest.check(bad, .zip, 0));
}

test "--max-output: the sizes a zip declares count, and a member cannot hold more than it declared" {
    const file = try build(&.{
        .{ .name = "a", .data = "x" ** 600 },
        .{ .name = "b", .data = "y" ** 600 },
    }, false);
    defer a.free(file);
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpackMax(file, .zip, 1200);
    var d2 = kit.Dest.init();
    defer d2.deinit();
    try t.expectError(error.OutputTooLarge, d2.unpackMax(file, .zip, 1199));
    // a deflate stream that holds more than the header says is corrupt, whatever the limit
    const text = "twenty bytes of text";
    const body = try kit.deflateText(text);
    defer a.free(body);
    const lying = try build(&.{.{ .name = "f", .data = text, .body = body, .usize_ = 5 }}, false);
    defer a.free(lying);
    var d3 = kit.Dest.init();
    defer d3.deinit();
    try t.expectError(error.EntryCorrupt, d3.unpackMax(lying, .zip, 1 << 30));
}

test "zip64 extra fields: values are read in order for the fields that are all ones, and a short field is refused" {
    // only the offset is all ones: the extra field holds one value
    var z = kit.Zip{};
    defer z.deinit();
    try z.add(.{ .name = "a", .data = "first" });
    try z.add(.{ .name = "b", .data = "second member" });
    const plain = try z.finish(false);
    defer a.free(plain);
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(plain, .zip, 0);
    // an extra field of another id is skipped, and a zip64 one after it is found
    const odd = try build(&.{.{ .name = "f", .data = "content", .zip64 = true }}, true);
    defer a.free(odd);
    var d2 = kit.Dest.init();
    defer d2.deinit();
    _ = try d2.unpack(odd, .zip, 0);
    // an extra field whose length runs past the extra data
    const cut = try a.dupe(u8, odd);
    defer a.free(cut);
    const at = std.mem.indexOf(u8, cut, "\x01\x00\x18\x00").?;
    cut[at + 2] = 0xff;
    var d3 = kit.Dest.init();
    defer d3.deinit();
    try t.expectError(error.BadZip, d3.unpack(cut, .zip, 0));
    // an extra field of another id in front of the zip64 one
    const other = try a.dupe(u8, odd);
    defer a.free(other);
    other[at] = 0x07; // id 0x0007: not zip64, 24 bytes of nothing; the sizes stay all ones and nothing supplies them
    var d4 = kit.Dest.init();
    defer d4.deinit();
    try t.expectError(error.BadZip, d4.unpack(other, .zip, 0));
}
