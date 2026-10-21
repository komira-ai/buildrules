//! Unit tests of prebuilt_unpack.zig on a `.conda` built in memory: a stored zip holding `pkg-*.tar.zst`, a zstd
//! frame of one raw block, a tar. (The real thing, a package `mopm pack` wrote, is unpacked by the examples' actions.)
//!
//! What is held, and the defect each test would catch:
//!   - the `.mojoc` and the natives come out byte for byte, each native hashed against the lock's value, in the order asked for;
//!   - a hash that differs, a member that is missing, doubled, empty, a symlink or a hard link, or too large is refused, and
//!     when anything is refused nothing at all is written (not the `.mojoc` either);
//!   - a soname that could leave the output directory, or is not `lib<stem>.a`, is refused before it is a path, and a member
//!     whose name only looks like the wanted one (`lib/../libx.a`, a name with a suffix) is not it;
//!   - the command line's refusals; and every allocation failing in turn is an error, never a leak.
const std = @import("std");
const U = @import("prebuilt_unpack.zig");
const t = std.testing;

fn octal(buf: []u8, v: usize) void {
    _ = std.fmt.bufPrint(buf, "{o:0>[1]}", .{ v, buf.len - 1 }) catch unreachable;
    buf[buf.len - 1] = 0;
}

const Ent = struct {
    name: []const u8,
    body: []const u8 = "",
    /// The tar type flag: '0' file, '2' symlink, '1' hard link, '5' directory.
    flag: u8 = '0',
    link: []const u8 = "",
    /// What the header claims for the size, when it is not the body's.
    claim: ?usize = null,
};

/// A ustar archive.
fn tar(a: std.mem.Allocator, files: []const Ent) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (files) |f| {
        var h = [_]u8{0} ** 512;
        @memcpy(h[0..f.name.len], f.name);
        octal(h[100..108], 0o644);
        octal(h[108..116], 0);
        octal(h[116..124], 0);
        octal(h[124..136], f.claim orelse f.body.len);
        octal(h[136..148], 0);
        @memset(h[148..156], ' ');
        h[156] = f.flag;
        @memcpy(h[157..][0..f.link.len], f.link);
        @memcpy(h[257..262], "ustar");
        h[262] = 0;
        @memcpy(h[263..265], "00");
        var sum: usize = 0;
        for (h) |c| sum += c;
        octal(h[148..155], sum);
        h[154] = 0;
        h[155] = ' ';
        try out.appendSlice(a, &h);
        try out.appendSlice(a, f.body);
        try out.appendNTimes(a, 0, (512 - f.body.len % 512) % 512);
    }
    try out.appendNTimes(a, 0, 1024);
    return out.toOwnedSlice(a);
}

/// One zstd frame holding `data` in a single raw block (no checksum, single-segment).
fn zstdRaw(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, &.{ 0x28, 0xb5, 0x2f, 0xfd });
    // Frame header descriptor: single segment, 4-byte content size (flag 2).
    try out.append(a, 0b10100000);
    var sz: [4]u8 = undefined;
    std.mem.writeInt(u32, &sz, @intCast(data.len), .little);
    try out.appendSlice(a, &sz);
    // Block header: last block, type raw (0), size.
    var bh: [3]u8 = undefined;
    const v: u32 = 1 | (@as(u32, @intCast(data.len)) << 3);
    bh[0] = @truncate(v);
    bh[1] = @truncate(v >> 8);
    bh[2] = @truncate(v >> 16);
    try out.appendSlice(a, &bh);
    try out.appendSlice(a, data);
    return out.toOwnedSlice(a);
}

fn zipStored(a: std.mem.Allocator, name: []const u8, body: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var h = [_]u8{0} ** 30;
    std.mem.writeInt(u32, h[0..4], 0x04034b50, .little);
    std.mem.writeInt(u16, h[4..6], 20, .little);
    std.mem.writeInt(u32, h[18..22], @intCast(body.len), .little);
    std.mem.writeInt(u32, h[22..26], @intCast(body.len), .little);
    std.mem.writeInt(u16, h[26..28], @intCast(name.len), .little);
    try out.appendSlice(a, &h);
    try out.appendSlice(a, name);
    try out.appendSlice(a, body);
    return out.toOwnedSlice(a);
}

const Zip = struct { flags: u16 = 0, method: u16 = 0, csize: ?u32 = null, usize32: ?u32 = null, extra: []const u8 = "", name_len: ?u16 = null };

/// A zip entry with the fields of the header set as asked.
fn zipEntry(a: std.mem.Allocator, name: []const u8, body: []const u8, z: Zip) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var h = [_]u8{0} ** 30;
    std.mem.writeInt(u32, h[0..4], 0x04034b50, .little);
    std.mem.writeInt(u16, h[4..6], 20, .little);
    std.mem.writeInt(u16, h[6..8], z.flags, .little);
    std.mem.writeInt(u16, h[8..10], z.method, .little);
    std.mem.writeInt(u32, h[18..22], z.csize orelse @as(u32, @intCast(body.len)), .little);
    std.mem.writeInt(u32, h[22..26], z.usize32 orelse @as(u32, @intCast(body.len)), .little);
    std.mem.writeInt(u16, h[26..28], z.name_len orelse @as(u16, @intCast(name.len)), .little);
    std.mem.writeInt(u16, h[28..30], @intCast(z.extra.len), .little);
    try out.appendSlice(a, &h);
    try out.appendSlice(a, name);
    try out.appendSlice(a, z.extra);
    try out.appendSlice(a, body);
    return out.toOwnedSlice(a);
}

fn extraField(a: std.mem.Allocator, id: u16, data: []const u8, claimed_len: ?u16) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var h: [4]u8 = undefined;
    std.mem.writeInt(u16, h[0..2], id, .little);
    std.mem.writeInt(u16, h[2..4], claimed_len orelse @as(u16, @intCast(data.len)), .little);
    try out.appendSlice(a, &h);
    try out.appendSlice(a, data);
    return out.toOwnedSlice(a);
}

fn le64bytes(v: u64) [8]u8 {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    return b;
}

const pkg_name = "pkg-mojo-p-1.0.0-mojo1.0.0_0.tar.zst";

test "payload: a zip64 entry (sizes in the extra field) is read, with either one or both sizes there" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "TAR-ZST-BYTES";
    // both sizes in the extra field: the uncompressed one first, then the compressed one
    const both = try extraField(a, 1, &(le64bytes(body.len) ++ le64bytes(body.len)), null);
    const e1 = try zipEntry(a, pkg_name, body, .{ .csize = 0xffffffff, .usize32 = 0xffffffff, .extra = both });
    try t.expectEqualStrings(body, try U.payload(e1));
    // only the compressed size is there; another field comes first
    const other = try extraField(a, 0x5455, "x", null);
    const one = try extraField(a, 1, &le64bytes(body.len), null);
    const e2 = try zipEntry(a, pkg_name, body, .{ .csize = 0xffffffff, .extra = try std.mem.concat(a, u8, &.{ other, one }) });
    try t.expectEqualStrings(body, try U.payload(e2));
}

test "payload: a zip64 entry without its size, or with a field that does not fit, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "TAR-ZST-BYTES";
    const none = try zipEntry(a, pkg_name, body, .{ .csize = 0xffffffff });
    try t.expectError(error.BadZip, U.payload(none));
    // a field that is not the zip64 one, and nothing else
    const e3 = try zipEntry(a, pkg_name, body, .{ .csize = 0xffffffff, .extra = try extraField(a, 0x5455, "x", null) });
    try t.expectError(error.BadZip, U.payload(e3));
    // the zip64 field too short for the compressed size (the uncompressed one is also there, so 8 more bytes are wanted)
    const short = try zipEntry(a, pkg_name, body, .{ .csize = 0xffffffff, .usize32 = 0xffffffff, .extra = try extraField(a, 1, &le64bytes(body.len), null) });
    try t.expectError(error.BadZip, U.payload(short));
    // a field whose length runs past the extra data
    const long = try zipEntry(a, pkg_name, body, .{ .csize = 0xffffffff, .extra = try extraField(a, 1, &le64bytes(body.len), 40) });
    try t.expectError(error.BadZip, U.payload(long));
    // an extra field shorter than a field header
    const tiny = try zipEntry(a, pkg_name, body, .{ .csize = 0xffffffff, .extra = "abc" });
    try t.expectError(error.BadZip, U.payload(tiny));
}

test "payload: a data descriptor, a compressed member, and sizes that run past the file are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "TAR-ZST-BYTES";
    try t.expectError(error.BadZip, U.payload(try zipEntry(a, pkg_name, body, .{ .flags = 8 })));
    try t.expectError(error.BadZip, U.payload(try zipEntry(a, pkg_name, body, .{ .method = 8 })));
    // the name and extra lengths put the data past the end of the file
    try t.expectError(error.BadZip, U.payload(try zipEntry(a, pkg_name, "", .{ .name_len = 60000 })));
    // the compressed size is more than the file holds
    try t.expectError(error.BadZip, U.payload(try zipEntry(a, pkg_name, body, .{ .csize = 4000 })));
    // two payloads: neither wins (the second used to)
    const p1 = try zipStored(a, pkg_name, body);
    const p2 = try zipStored(a, "pkg-mojo-p-1.0.0-mojo1.0.0_1.tar.zst", "OTHER");
    try t.expectError(error.DuplicatePayload, U.payload(try std.mem.concat(a, u8, &.{ p1, p2 })));
    // a good entry of another name before the payload is skipped
    const first = try zipStored(a, "info-x.tar.zst", "abc");
    const second = try zipStored(a, pkg_name, body);
    try t.expectEqualStrings(body, try U.payload(try std.mem.concat(a, u8, &.{ first, second })));
}

fn conda(a: std.mem.Allocator, files: []const Ent) ![]u8 {
    return zipStored(a, "pkg-mojo-p-1.0.0-mojo1.0.0_0.tar.zst", try zstdRaw(a, try tar(a, files)));
}

fn sha(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

/// `--native libX.a=<sha of body>`.
fn nativeArg(a: std.mem.Allocator, soname: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}={s}", .{ soname, sha(body) });
}

const Run = struct { err: ?anyerror, why: []const u8 };

/// `prebuilt_unpack p.conda p out.mojoc <extra...>` in `dir`, the conda being `bytes`.
fn runWith(a: std.mem.Allocator, dir: std.fs.Dir, bytes: []const u8, extra: []const []const u8) !Run {
    try dir.writeFile(.{ .sub_path = "p.conda", .data = bytes });
    var args = std.ArrayList([]const u8).empty;
    try args.appendSlice(a, &.{ "p.conda", "p", "out.mojoc" });
    try args.appendSlice(a, extra);
    var why: []const u8 = "";
    U.run(a, dir, args.items, &why) catch |e| return .{ .err = e, .why = why };
    return .{ .err = null, .why = why };
}

fn absent(dir: std.fs.Dir, path: []const u8) bool {
    dir.access(path, .{}) catch return true;
    return false;
}

fn read(a: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(a, path, 1 << 20);
}

const m1 = "MOJOC-BYTES";
const libb = "!<arch>\nBASE-ARCHIVE";
const libp = "!<arch>\nPROBE-ARCHIVE";

test "the .mojoc of a package comes out byte for byte" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try conda(a, &.{ .{ .name = "lib/mojo/p.mopm.json", .body = "{}" }, .{ .name = "lib/mojo/p.mojoc", .body = m1 } });
    var bad: []const u8 = "";
    const got = try U.members(a, try U.payload(c), &.{"lib/mojo/p.mojoc"}, &bad);
    try t.expectEqualStrings(m1, got[0]);
}

test "members come back in the order asked for, not the order of the archive" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // In the archive: probe, mojoc, base. Asked for: base, probe, mojoc (and the same asked the other way round).
    const c = try conda(a, &.{ .{ .name = "lib/libprobe_sys.a", .body = libp }, .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/libbase_sys.a", .body = libb } });
    var bad: []const u8 = "";
    const got = try U.members(a, try U.payload(c), &.{ "lib/libbase_sys.a", "lib/libprobe_sys.a", "lib/mojo/p.mojoc" }, &bad);
    try t.expectEqualStrings(libb, got[0]);
    try t.expectEqualStrings(libp, got[1]);
    try t.expectEqualStrings(m1, got[2]);
    const rev = try U.members(a, try U.payload(c), &.{ "lib/mojo/p.mojoc", "lib/libprobe_sys.a", "lib/libbase_sys.a" }, &bad);
    try t.expectEqualStrings(m1, rev[0]);
    try t.expectEqualStrings(libp, rev[1]);
    try t.expectEqualStrings(libb, rev[2]);
}

test "a package without the member, with an empty one, and a zip without a payload are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bad: []const u8 = "";
    const other = try conda(a, &.{.{ .name = "lib/mojo/q.mojoc", .body = "X" }});
    try t.expectError(error.NoMember, U.members(a, try U.payload(other), &.{"lib/mojo/p.mojoc"}, &bad));
    try t.expectEqualStrings("lib/mojo/p.mojoc", bad);
    const empty = try conda(a, &.{.{ .name = "lib/mojo/p.mojoc" }});
    try t.expectError(error.EmptyMember, U.members(a, try U.payload(empty), &.{"lib/mojo/p.mojoc"}, &bad));
    const nopkg = try zipStored(a, "info-x.tar.zst", "abc");
    try t.expectError(error.NoPayload, U.payload(nopkg));
    try t.expectError(error.NoPayload, U.payload("not a zip"));
}

test "a member that is a symlink, a directory, a hard link, doubled, or too large is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bad: []const u8 = "";
    const want = [_][]const u8{"lib/libx.a"};
    const sym = try conda(a, &.{.{ .name = "lib/libx.a", .flag = '2', .link = "/etc/passwd" }});
    try t.expectError(error.NotAFile, U.members(a, try U.payload(sym), &want, &bad));
    try t.expectEqualStrings("lib/libx.a", bad);
    const dir = try conda(a, &.{.{ .name = "lib/libx.a", .flag = '5' }});
    try t.expectError(error.NotAFile, U.members(a, try U.payload(dir), &want, &bad));
    // A hard link is not a header the tar reader takes at all.
    const hard = try conda(a, &.{.{ .name = "lib/libx.a", .flag = '1', .link = "lib/liby.a" }});
    try t.expectError(error.TarUnsupportedHeader, U.members(a, try U.payload(hard), &want, &bad));
    try t.expectEqualStrings("(the tar)", bad);
    const twice = try conda(a, &.{ .{ .name = "lib/libx.a", .body = libb }, .{ .name = "lib/libx.a", .body = libp } });
    try t.expectError(error.DuplicateMember, U.members(a, try U.payload(twice), &want, &bad));
    try t.expectEqualStrings("lib/libx.a", bad);
    // The header claims two gigabytes (the most its field holds is eight); the archive does not hold them. The size is refused before anything is read or allocated for it.
    const huge = try conda(a, &.{.{ .name = "lib/libx.a", .body = "x", .claim = 1 << 31 }});
    try t.expectError(error.TooLarge, U.members(a, try U.payload(huge), &want, &bad));
    // The bound is on one member's declared size: one byte over is refused; exactly the bound is not (the archive does not hold that many bytes,
    // so it fails reading them, with anything but TooLarge).
    const over = try conda(a, &.{.{ .name = "lib/libx.a", .body = "x", .claim = U.max_member + 1 }});
    try t.expectError(error.TooLarge, U.members(a, try U.payload(over), &want, &bad));
    const exact = try conda(a, &.{.{ .name = "lib/libx.a", .body = "x", .claim = U.max_member }});
    if (U.members(a, try U.payload(exact), &want, &bad)) |_| return error.ShouldHaveFailed else |e| try t.expect(e != error.TooLarge);
}

test "a member whose name only looks like the wanted one is not it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bad: []const u8 = "";
    const c = try conda(a, &.{
        .{ .name = "lib/../libx.a", .body = libp },
        .{ .name = "./lib/libx.a", .body = libp },
        .{ .name = "lib/libx.a.bak", .body = libp },
        .{ .name = "xlib/libx.a", .body = libp },
        .{ .name = "lib/sub/libx.a", .body = libp },
        .{ .name = "lib/libx.a", .body = libb },
    });
    const got = try U.members(a, try U.payload(c), &.{"lib/libx.a"}, &bad);
    try t.expectEqualStrings(libb, got[0]);
    const only_decoys = try conda(a, &.{ .{ .name = "lib/../libx.a", .body = libp }, .{ .name = "lib/libx.a.bak", .body = libp } });
    try t.expectError(error.NoMember, U.members(a, try U.payload(only_decoys), &.{"lib/libx.a"}, &bad));
}

test "run: the mojoc and the natives are written, flat, and each native was hashed against the lock" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const c = try conda(a, &.{ .{ .name = "lib/libprobe_sys.a", .body = libp }, .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/libbase_sys.a", .body = libb }, .{ .name = "lib/mojo/p.mopm.json", .body = "{}" } });
    const r = try runWith(a, tmp.dir, c, &.{ "--natives", "deep/natives", "--native", try nativeArg(a, "libprobe_sys.a", libp), "--native", try nativeArg(a, "libbase_sys.a", libb) });
    try t.expect(r.err == null);
    try t.expectEqualStrings(m1, try read(a, tmp.dir, "out.mojoc"));
    try t.expectEqualStrings(libp, try read(a, tmp.dir, "deep/natives/libprobe_sys.a"));
    try t.expectEqualStrings(libb, try read(a, tmp.dir, "deep/natives/libbase_sys.a"));
    // Only what was asked for: the metadata member is not written.
    try t.expect(absent(tmp.dir, "deep/natives/p.mopm.json"));
}

test "run: a package with no natives writes the mojoc only; --natives alone makes an empty directory" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const c = try conda(a, &.{.{ .name = "lib/mojo/p.mojoc", .body = m1 }});
    try t.expect((try runWith(a, tmp.dir, c, &.{})).err == null);
    try t.expectEqualStrings(m1, try read(a, tmp.dir, "out.mojoc"));
    try t.expect((try runWith(a, tmp.dir, c, &.{ "--natives", "n" })).err == null);
    var d = try tmp.dir.openDir("n", .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    try t.expect((try it.next()) == null);
}

test "run: a native whose bytes are not the lock's is refused, naming both hashes, and nothing is written" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const c = try conda(a, &.{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/libbase_sys.a", .body = libb }, .{ .name = "lib/libprobe_sys.a", .body = libp } });
    // The second native is the one that differs: the first, correct one must not have been written either.
    const r = try runWith(a, tmp.dir, c, &.{ "--natives", "n", "--native", try nativeArg(a, "libbase_sys.a", libb), "--native", try nativeArg(a, "libprobe_sys.a", "some other archive") });
    try t.expect(r.err.? == error.Sha256Mismatch);
    try t.expect(std.mem.indexOf(u8, r.why, "lib/libprobe_sys.a hashes to ") != null);
    try t.expect(std.mem.indexOf(u8, r.why, &sha(libp)) != null);
    try t.expect(std.mem.indexOf(u8, r.why, &sha("some other archive")) != null);
    try t.expect(absent(tmp.dir, "out.mojoc"));
    try t.expect(absent(tmp.dir, "n"));
}

test "run: one flipped nibble of the lock's hash is a mismatch" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const c = try conda(a, &.{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/libbase_sys.a", .body = libb } });
    const good = try nativeArg(a, "libbase_sys.a", libb);
    const flipped = try a.dupe(u8, good);
    flipped[flipped.len - 1] = if (flipped[flipped.len - 1] == '0') '1' else '0';
    const r = try runWith(a, tmp.dir, c, &.{ "--natives", "n", "--native", flipped });
    try t.expect(r.err.? == error.Sha256Mismatch);
    try t.expect(absent(tmp.dir, "out.mojoc"));
}

test "run: a native the package does not hold, or holds as a symlink, an empty file or twice, is refused and nothing is written" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const arg = try nativeArg(a, "libx.a", libb);
    const Case = struct { files: []const Ent, want: anyerror };
    const cases = [_]Case{
        .{ .files = &.{.{ .name = "lib/mojo/p.mojoc", .body = m1 }}, .want = error.NoMember },
        .{ .files = &.{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/libx.a", .flag = '2', .link = "libother.a" } }, .want = error.NotAFile },
        .{ .files = &.{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/libx.a" } }, .want = error.EmptyMember },
        .{ .files = &.{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/libx.a", .body = libb }, .{ .name = "lib/libx.a", .body = libb } }, .want = error.DuplicateMember },
        .{ .files = &.{.{ .name = "lib/libx.a", .body = libb }}, .want = error.NoMember },
    };
    for (cases) |cs| {
        const r = try runWith(a, tmp.dir, try conda(a, cs.files), &.{ "--natives", "n", "--native", arg });
        try t.expect(r.err.? == cs.want);
        try t.expect(absent(tmp.dir, "out.mojoc"));
        try t.expect(absent(tmp.dir, "n"));
    }
    // The message names the archive member.
    const r = try runWith(a, tmp.dir, try conda(a, cases[0].files), &.{ "--natives", "n", "--native", arg });
    try t.expect(std.mem.indexOf(u8, r.why, "lib/libx.a: NoMember") != null);
}

test "run: a soname that could leave the output directory is refused before anything is read" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("sub");
    var sub = try tmp.dir.openDir("sub", .{});
    defer sub.close();
    // The package holds a member of exactly the evil name, and the lock would pin it: the soname is still refused.
    const evil = [_][]const u8{ "../libevil.a", "lib/../libevil.a", "libevil/../../x.a", "/abs/libevil.a", "sub/libevil.a", "libevil.so", "evil.a", "lib.a", "libev il.a", "libe..vil.a", "lib\\evil.a", "" };
    for (evil) |soname| {
        const c = try conda(a, &.{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = try std.fmt.allocPrint(a, "lib/{s}", .{soname}), .body = libb } });
        const r = try runWith(a, sub, c, &.{ "--natives", "n", "--native", try nativeArg(a, soname, libb) });
        try t.expect(r.err != null);
        try t.expect(r.err.? == error.BadSoname or r.err.? == error.BadNative);
    }
    try t.expect(absent(tmp.dir, "libevil.a"));
    try t.expect(absent(tmp.dir, "sub/out.mojoc"));
    try t.expect(absent(tmp.dir, "sub/n"));
    // A plain name next to them is accepted.
    for ([_][]const u8{ "libc++abi.a", "libbase_sys.a", "libz-ng.a", "liba.a" }) |ok| try U.checkSoname(ok);
}

test "run: the unpacker writes inside the output directory only" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // The tar holds a member that reads as a path out of lib/; the wanted one is plain. Only the plain one is written, inside `n`.
    const c = try conda(a, &.{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/../../libevil.a", .body = libp }, .{ .name = "lib/libok.a", .body = libb } });
    const r = try runWith(a, tmp.dir, c, &.{ "--natives", "n", "--native", try nativeArg(a, "libok.a", libb) });
    try t.expect(r.err == null);
    try t.expect(absent(tmp.dir, "libevil.a"));
    try t.expect(absent(tmp.dir, "n/libevil.a"));
    try t.expectEqualStrings(libb, try read(a, tmp.dir, "n/libok.a"));
}

test "run: a file that is not a .conda, one with no payload, and one that cannot be read are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const r = try runWith(a, tmp.dir, "not a zip", &.{});
    try t.expect(r.err.? == error.NoPayload);
    try t.expect(std.mem.indexOf(u8, r.why, "p.conda: NoPayload") != null);
    var why: []const u8 = "";
    try t.expectError(error.FileNotFound, U.run(a, tmp.dir, &.{ "missing.conda", "p", "out.mojoc" }, &why));
    try t.expect(std.mem.indexOf(u8, why, "cannot read missing.conda") != null);
}

test "run: an output that cannot be written is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const c = try conda(a, &.{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/libx.a", .body = libb } });
    try tmp.dir.writeFile(.{ .sub_path = "p.conda", .data = c });
    var why: []const u8 = "";
    // out.mojoc is a directory
    try tmp.dir.makePath("out.mojoc");
    try t.expectError(error.IsDir, U.run(a, tmp.dir, &.{ "p.conda", "p", "out.mojoc" }, &why));
    try t.expect(std.mem.indexOf(u8, why, "cannot write out.mojoc") != null);
    // the natives directory is a file
    try tmp.dir.writeFile(.{ .sub_path = "f", .data = "x" });
    try t.expectError(error.NotDir, U.run(a, tmp.dir, &.{ "p.conda", "p", "o2.mojoc", "--natives", "f/d", "--native", try nativeArg(a, "libx.a", libb) }, &why));
    try t.expect(std.mem.indexOf(u8, why, "cannot create f/d") != null);
    // a native's own path is a directory
    try tmp.dir.makePath("g/libx.a");
    try t.expectError(error.IsDir, U.run(a, tmp.dir, &.{ "p.conda", "p", "o3.mojoc", "--natives", "g", "--native", try nativeArg(a, "libx.a", libb) }, &why));
    try t.expect(std.mem.indexOf(u8, why, "cannot write g/libx.a") != null);
}

test "the command line: usage, malformed natives and repeated flags are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const h = sha(libb);
    const upper_native = try std.fmt.allocPrint(a, "libx.a={s}", .{try std.ascii.allocUpperString(a, &h)});
    const upper_args = [_][]const u8{ "p.conda", "p", "o", "--natives", "n", "--native", upper_native };
    const bad = [_]struct { args: []const []const u8, want: anyerror }{
        .{ .args = &.{}, .want = error.BadUsage },
        .{ .args = &.{ "p.conda", "p" }, .want = error.BadUsage },
        .{ .args = &.{ "p.conda", "p", "o", "--bogus", "x" }, .want = error.BadUsage },
        .{ .args = &.{ "p.conda", "p", "o", "--natives" }, .want = error.BadUsage },
        .{ .args = &.{ "p.conda", "p", "o", "--natives", "a", "--natives", "b" }, .want = error.BadUsage },
        .{ .args = &.{ "p.conda", "p", "o", "--native", "libx.a=" ++ ("0" ** 64) }, .want = error.BadUsage },
        .{ .args = &.{ "p.conda", "p", "o", "--natives", "n", "--native", "libx.a" }, .want = error.BadNative },
        .{ .args = &.{ "p.conda", "p", "o", "--natives", "n", "--native", "libx.a=abc" }, .want = error.BadNative },
        .{ .args = &.{ "p.conda", "p", "o", "--natives", "n", "--native", "libx.a=" ++ ("g" ** 64) }, .want = error.BadNative },
        .{ .args = &upper_args, .want = error.BadNative },
        .{ .args = &.{ "p.conda", "p", "o", "--natives", "n", "--native", "x.a=" ++ ("0" ** 64) }, .want = error.BadSoname },
        .{ .args = &.{ "p.conda", "p", "o", "--natives", "n", "--native", "libx.a=" ++ ("0" ** 64), "--native", "libx.a=" ++ ("1" ** 64) }, .want = error.DuplicateNative },
    };
    for (bad) |c| {
        try t.expectError(c.want, U.parseArgs(a, c.args, &why));
        try t.expect(why.len != 0);
        why = "";
    }
    const ok = try U.parseArgs(a, &.{ "p.conda", "p", "o", "--natives", "n", "--native", "liba.a=" ++ ("0" ** 64), "--native", "libb.a=" ++ ("1" ** 64) }, &why);
    try t.expectEqual(@as(usize, 2), ok.natives.len);
    try t.expectEqualStrings("liba.a", ok.natives[0].soname);
    try t.expectEqualStrings("libb.a", ok.natives[1].soname);
    try t.expectEqualStrings("n", ok.natives_dir.?);
}

test "the order of --native is the order of the options, kept" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    // needer first: libprobe_sys.a before libbase_sys.a, which is not the sorted order
    const o = try U.parseArgs(a, &.{ "p.conda", "p", "o", "--natives", "n", "--native", "libprobe_sys.a=" ++ ("0" ** 64), "--native", "libbase_sys.a=" ++ ("1" ** 64) }, &why);
    try t.expectEqualStrings("libprobe_sys.a", o.natives[0].soname);
    try t.expectEqualStrings("libbase_sys.a", o.natives[1].soname);
}

test "every allocation failing in turn is an error and leaks nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try conda(a, &.{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/libbase_sys.a", .body = libb }, .{ .name = "lib/other", .body = "o" } });
    const pkg = try U.payload(c);
    var bad: []const u8 = "";
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var fa = t.FailingAllocator.init(t.allocator, .{ .fail_index = i });
        if (U.members(fa.allocator(), pkg, &.{ "lib/mojo/p.mojoc", "lib/libbase_sys.a" }, &bad)) |got| {
            // Past the last allocation: it succeeded, and the caller owns the bytes.
            try t.expect(!fa.has_induced_failure);
            try t.expectEqualStrings(libb, got[1]);
            for (got) |g| fa.allocator().free(g);
            fa.allocator().free(got);
            try t.expect(i > 2);
            break;
        } else |e| try t.expectEqual(error.OutOfMemory, e);
    } else return error.SweepDidNotEnd;
    // The same for a package that lacks the second member: the failure after the first was read frees it.
    i = 0;
    while (i < 1000) : (i += 1) {
        var fa = t.FailingAllocator.init(t.allocator, .{ .fail_index = i });
        if (U.members(fa.allocator(), pkg, &.{ "lib/mojo/p.mojoc", "lib/missing.a" }, &bad)) |_| {
            return error.ShouldHaveFailed;
        } else |e| if (e == error.NoMember) break else try t.expectEqual(error.OutOfMemory, e);
    } else return error.SweepDidNotEnd;
}

test "run: every allocation failing in turn is an error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const c = try conda(a, &.{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/libbase_sys.a", .body = libb } });
    try tmp.dir.writeFile(.{ .sub_path = "p.conda", .data = c });
    const args = [_][]const u8{ "p.conda", "p", "out.mojoc", "--natives", "n", "--native", try nativeArg(a, "libbase_sys.a", libb) };
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var inner = std.heap.ArenaAllocator.init(t.allocator);
        defer inner.deinit();
        var fa = t.FailingAllocator.init(inner.allocator(), .{ .fail_index = i });
        var why: []const u8 = "";
        if (U.run(fa.allocator(), tmp.dir, &args, &why)) |_| {
            try t.expect(!fa.has_induced_failure);
            return;
        } else |e| try t.expectEqual(error.OutOfMemory, e);
    }
    return error.SweepDidNotEnd;
}

test "a damaged archive is an error, wherever it is cut" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // An unrelated member of 3000 bytes first, then the wanted one. The zstd frame is cut inside the first member's header, inside its body
    // (the reader that skips it fails), and inside the wanted member's body; each cut is a zip entry whose sizes agree with the bytes it holds.
    const all = try tar(a, &.{ .{ .name = "info/big", .body = "b" ** 3000 }, .{ .name = "lib/mojo/p.mojoc", .body = m1 } });
    const framed = try zstdRaw(a, all);
    const header_len = 4 + 1 + 4 + 3;
    var bad: []const u8 = "";
    for ([_]usize{ header_len + 100, header_len + 512 + 1000, header_len + 512 + 3072 + 512 + 3 }) |cut| {
        // a raw block that is cut short: the frame's block size is more than the bytes there are
        const damaged = try zipStored(a, pkg_name, framed[0..cut]);
        try t.expect(blk: {
            _ = U.members(a, try U.payload(damaged), &.{"lib/mojo/p.mojoc"}, &bad) catch break :blk true;
            break :blk false;
        });
    }
}

/// `run` with every allocation failing in turn, until it fails for `want` with no allocation having failed: each arm that reports `want` is then also
/// reached with its own allocation failing, and that is `OutOfMemory`, nothing else.
fn sweepError(dir: std.fs.Dir, args: []const []const u8, want: anyerror) !void {
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        var inner = std.heap.ArenaAllocator.init(t.allocator);
        defer inner.deinit();
        var fa = t.FailingAllocator.init(inner.allocator(), .{ .fail_index = i });
        var why: []const u8 = "";
        if (U.run(fa.allocator(), dir, args, &why)) |_| {
            return error.ShouldHaveFailed;
        } else |e| {
            if (!fa.has_induced_failure) {
                try t.expectEqual(want, e);
                return;
            }
            try t.expectEqual(error.OutOfMemory, e);
        }
    }
    return error.SweepDidNotEnd;
}

test "every refusal of run is still a refusal when the allocation that words it fails" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const c = try conda(a, &.{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/libbase_sys.a", .body = libb } });
    try tmp.dir.writeFile(.{ .sub_path = "p.conda", .data = c });
    try tmp.dir.writeFile(.{ .sub_path = "bad.conda", .data = "not a zip" });
    try tmp.dir.writeFile(.{ .sub_path = "f", .data = "x" });
    try tmp.dir.makePath("isdir");
    try tmp.dir.makePath("g/libbase_sys.a");
    const good = try nativeArg(a, "libbase_sys.a", libb);
    const wrong = try nativeArg(a, "libbase_sys.a", "other");
    try sweepError(tmp.dir, &.{ "p.conda", "p", "o.mojoc", "--natives", "n", "--native", "libbase_sys.a=zz" }, error.BadNative);
    try sweepError(tmp.dir, &.{ "p.conda", "p", "o.mojoc", "--natives", "n", "--native", good, "--native", good }, error.DuplicateNative);
    try sweepError(tmp.dir, &.{ "missing.conda", "p", "o.mojoc" }, error.FileNotFound);
    try sweepError(tmp.dir, &.{ "bad.conda", "p", "o.mojoc" }, error.NoPayload);
    try sweepError(tmp.dir, &.{ "p.conda", "q", "o.mojoc" }, error.NoMember);
    try sweepError(tmp.dir, &.{ "p.conda", "p", "o.mojoc", "--natives", "n", "--native", wrong }, error.Sha256Mismatch);
    try sweepError(tmp.dir, &.{ "p.conda", "p", "isdir" }, error.IsDir);
    try sweepError(tmp.dir, &.{ "p.conda", "p", "o.mojoc", "--natives", "f/d", "--native", good }, error.NotDir);
    try sweepError(tmp.dir, &.{ "p.conda", "p", "o.mojoc", "--natives", "g", "--native", good }, error.IsDir);
}
