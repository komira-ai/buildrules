//! The in-memory `.conda` of the tests of prebuilt_unpack.zig (prebuilt_unpack_test.zig, prebuilt_unpack_holds_test.zig): a stored zip holding
//! `pkg-*.tar.zst` (and `info-*.tar.zst`), a zstd frame of one raw block, a ustar archive; and the runs of the program on one.
const std = @import("std");
const U = @import("prebuilt_unpack.zig");
const t = std.testing;

pub fn octal(buf: []u8, v: usize) void {
    _ = std.fmt.bufPrint(buf, "{o:0>[1]}", .{ v, buf.len - 1 }) catch unreachable;
    buf[buf.len - 1] = 0;
}

pub const Ent = struct {
    name: []const u8,
    body: []const u8 = "",
    /// The tar type flag: '0' file, '2' symlink, '1' hard link, '5' directory.
    flag: u8 = '0',
    link: []const u8 = "",
    /// What the header claims for the size, when it is not the body's.
    claim: ?usize = null,
};

/// A ustar archive.
pub fn tar(a: std.mem.Allocator, files: []const Ent) ![]u8 {
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
pub fn zstdRaw(a: std.mem.Allocator, data: []const u8) ![]u8 {
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

pub fn zipStored(a: std.mem.Allocator, name: []const u8, body: []const u8) ![]u8 {
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

pub fn conda(a: std.mem.Allocator, files: []const Ent) ![]u8 {
    return zipStored(a, "pkg-mojo-p-1.0.0-mojo1.0.0_0.tar.zst", try zstdRaw(a, try tar(a, files)));
}

pub fn sha(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

/// `--native libX.a=<sha of body>`.
pub fn nativeArg(a: std.mem.Allocator, soname: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}={s}", .{ soname, sha(body) });
}

pub const Run = struct { err: ?anyerror, why: []const u8 };

/// `prebuilt_unpack p.conda p out.mojoc <extra...>` in `dir`, the conda being `bytes`.
pub fn runWith(a: std.mem.Allocator, dir: std.fs.Dir, bytes: []const u8, extra: []const []const u8) !Run {
    try dir.writeFile(.{ .sub_path = "p.conda", .data = bytes });
    var args = std.ArrayList([]const u8).empty;
    try args.appendSlice(a, &.{ "p.conda", "p", "out.mojoc" });
    try args.appendSlice(a, extra);
    var why: []const u8 = "";
    U.run(a, dir, args.items, &why) catch |e| return .{ .err = e, .why = why };
    return .{ .err = null, .why = why };
}

pub fn absent(dir: std.fs.Dir, path: []const u8) bool {
    dir.access(path, .{}) catch return true;
    return false;
}

pub fn read(a: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(a, path, 1 << 20);
}

pub const m1 = "MOJOC-BYTES";
pub const libb = "!<arch>\nBASE-ARCHIVE";
pub const libp = "!<arch>\nPROBE-ARCHIVE";

/// `run` with every allocation failing in turn, until it fails for `want` with no allocation having failed: each arm that reports `want` is then also
/// reached with its own allocation failing, and that is `OutOfMemory`, nothing else.
pub fn sweepError(dir: std.fs.Dir, args: []const []const u8, want: anyerror) !void {
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

/// A `.conda` with an `info-*.tar.zst` holding `info/index.json` = `index` as well as the package tar.
pub fn condaIndexed(a: std.mem.Allocator, files: []const Ent, index: []const u8) ![]u8 {
    const info = try zipStored(a, "info-mojo-p-1.0.0-mojo1.0.0_0.tar.zst", try zstdRaw(a, try tar(a, &.{.{ .name = "info/index.json", .body = index }})));
    return std.mem.concat(a, u8, &.{ info, try conda(a, files) });
}

pub const own_files = [_]Ent{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/mojo/p.mopm.json", .body = "{}" } };
pub const idx_q = "{\"build\":\"mojo1.0.0_0\",\"depends\":[\"mojo-compiler ==1.0.0\",\"mojo-q >=0.1,<0.2\"],\"name\":\"mojo-p\"}";
