//! The in-memory `.conda` of the tests (conda_test.zig, pg_prefix_test.zig): a stored zip holding `pkg-*.tar.zst` and `info-*.tar.zst`, each a zstd frame
//! of one raw block holding a ustar archive.

const std = @import("std");

fn octal(buf: []u8, v: usize) void {
    _ = std.fmt.bufPrint(buf, "{o:0>[1]}", .{ v, buf.len - 1 }) catch unreachable;
    buf[buf.len - 1] = 0;
}

pub const Ent = struct {
    name: []const u8,
    body: []const u8 = "",
    /// The tar type flag: '0' file, '2' symlink, '1' hard link, '5' directory.
    flag: u8 = '0',
    link: []const u8 = "",
    mode: usize = 0o644,
    /// What the header claims for the size, when it is not the body's.
    claim: ?usize = null,
};

/// A ustar archive.
pub fn tar(a: std.mem.Allocator, files: []const Ent) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (files) |f| {
        var h = [_]u8{0} ** 512;
        @memcpy(h[0..f.name.len], f.name);
        octal(h[100..108], f.mode);
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

/// A zip local header with the fields set as asked, then the name, the extra field and the body.
pub const Zip = struct { flags: u16 = 0, method: u16 = 0, csize: ?u32 = null, usize32: ?u32 = null, extra: []const u8 = "", name_len: ?u16 = null };

pub fn zipEntry(a: std.mem.Allocator, name: []const u8, body: []const u8, z: Zip) ![]u8 {
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

pub fn zipStored(a: std.mem.Allocator, name: []const u8, body: []const u8) ![]u8 {
    return zipEntry(a, name, body, .{});
}

/// A `.conda` whose info and payload tars hold `info` and `files`.
pub fn conda(a: std.mem.Allocator, files: []const Ent, meta: []const Ent) ![]u8 {
    const i = try zipStored(a, "info-p-1.0-0.tar.zst", try zstdRaw(a, try tar(a, meta)));
    const p = try zipStored(a, "pkg-p-1.0-0.tar.zst", try zstdRaw(a, try tar(a, files)));
    return std.mem.concat(a, u8, &.{ i, p });
}

/// The text of an `info/paths.json` listing `bin/postgres` and `bin/initdb` as binary files with the placeholder `ph`.
pub fn pathsJson(a: std.mem.Allocator, ph: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\{{"paths_version": 1, "paths": [{{"_path": "lib/libx.so", "path_type": "hardlink"}}, {{"_path": "bin/postgres", "file_mode": "binary", "prefix_placeholder": "{s}"}}, {{"_path": "bin/initdb", "file_mode": "binary", "prefix_placeholder": "{s}"}}]}}
    , .{ ph, ph });
}

/// The info tar of a package with that `paths.json` text.
pub fn info(a: std.mem.Allocator, paths: []const u8) ![]const Ent {
    const list = try a.alloc(Ent, 2);
    list[0] = .{ .name = "info/index.json", .body = "{}" };
    list[1] = .{ .name = "info/paths.json", .body = paths };
    return list;
}
