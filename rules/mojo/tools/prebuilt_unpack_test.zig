//! Unit tests of prebuilt_unpack.zig on a `.conda` built in memory: a stored zip holding `pkg-*.tar.zst`, a zstd
//! frame of one raw block, a tar. (The real thing, a package `mopm pack` wrote, is unpacked by the examples' actions.)
const std = @import("std");
const U = @import("prebuilt_unpack.zig");
const t = std.testing;

fn octal(buf: []u8, v: usize) void {
    _ = std.fmt.bufPrint(buf, "{o:0>[1]}", .{ v, buf.len - 1 }) catch unreachable;
    buf[buf.len - 1] = 0;
}

/// A ustar archive of regular files.
fn tar(a: std.mem.Allocator, files: []const struct { []const u8, []const u8 }) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (files) |f| {
        var h = [_]u8{0} ** 512;
        @memcpy(h[0..f[0].len], f[0]);
        octal(h[100..108], 0o644);
        octal(h[108..116], 0);
        octal(h[116..124], 0);
        octal(h[124..136], f[1].len);
        octal(h[136..148], 0);
        @memset(h[148..156], ' ');
        h[156] = '0';
        @memcpy(h[257..262], "ustar");
        h[262] = 0;
        @memcpy(h[263..265], "00");
        var sum: usize = 0;
        for (h) |c| sum += c;
        octal(h[148..155], sum);
        h[154] = 0;
        h[155] = ' ';
        try out.appendSlice(a, &h);
        try out.appendSlice(a, f[1]);
        try out.appendNTimes(a, 0, (512 - f[1].len % 512) % 512);
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

fn conda(a: std.mem.Allocator, files: []const struct { []const u8, []const u8 }) ![]u8 {
    return zipStored(a, "pkg-mojo-p-1.0.0-mojo1.0.0_0.tar.zst", try zstdRaw(a, try tar(a, files)));
}

test "the .mojoc of a package comes out byte for byte" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try conda(a, &.{ .{ "lib/mojo/p.mopm.json", "{}" }, .{ "lib/mojo/p.mojoc", "MOJOC-BYTES" } });
    const got = try U.member(a, try U.payload(c), "lib/mojo/p.mojoc");
    try t.expectEqualStrings("MOJOC-BYTES", got);
}

test "a package without the member, with an empty one, and a zip without a payload are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const other = try conda(a, &.{.{ "lib/mojo/q.mojoc", "X" }});
    try t.expectError(error.NoMember, U.member(a, try U.payload(other), "lib/mojo/p.mojoc"));
    const empty = try conda(a, &.{.{ "lib/mojo/p.mojoc", "" }});
    try t.expectError(error.EmptyMember, U.member(a, try U.payload(empty), "lib/mojo/p.mojoc"));
    const nopkg = try zipStored(a, "info-x.tar.zst", "abc");
    try t.expectError(error.NoPayload, U.payload(nopkg));
    try t.expectError(error.NoPayload, U.payload("not a zip"));
}
