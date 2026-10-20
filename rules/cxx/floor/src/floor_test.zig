//! Unit tests of glibc_floor over ELF images built in the test: each version string is put in a Vernaux of a
//! .gnu.version_r section, so a tool that read the wrong field, took the first version instead of the newest,
//! compared strings instead of numbers, or counted GLIBC_PRIVATE would fail one of them.

const std = @import("std");
const F = @import("floor.zig");

/// A minimal ELF64: header, a verneed section (one Verneed, one Vernaux per name), its string table, and the section headers.
fn image(a: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var strs = std.ArrayList(u8){};
    try strs.append(a, 0);
    var name_offs = std.ArrayList(u32){};
    for (names) |n| {
        try name_offs.append(a, @intCast(strs.items.len));
        try strs.appendSlice(a, n);
        try strs.append(a, 0);
    }
    const hdr = 64;
    const vn_off = hdr;
    const vn_size = 16 + 16 * names.len;
    const str_off = vn_off + vn_size;
    const sh_off = (str_off + strs.items.len + 7) / 8 * 8;
    const total = sh_off + 3 * 64;
    const b = try a.alloc(u8, total);
    @memset(b, 0);
    @memcpy(b[0..4], "\x7fELF");
    b[4] = 2;
    b[5] = 1;
    std.mem.writeInt(u64, b[0x28..][0..8], sh_off, .little);
    std.mem.writeInt(u16, b[0x3A..][0..2], 64, .little);
    std.mem.writeInt(u16, b[0x3C..][0..2], 3, .little);
    // Verneed
    std.mem.writeInt(u16, b[vn_off + 2 ..][0..2], @intCast(names.len), .little); // vn_cnt
    std.mem.writeInt(u32, b[vn_off + 8 ..][0..4], 16, .little); // vn_aux
    std.mem.writeInt(u32, b[vn_off + 12 ..][0..4], 0, .little); // vn_next
    for (names, 0..) |_, i| {
        const au = vn_off + 16 + 16 * i;
        std.mem.writeInt(u32, b[au + 8 ..][0..4], name_offs.items[i], .little);
        std.mem.writeInt(u32, b[au + 12 ..][0..4], if (i + 1 < names.len) 16 else 0, .little);
    }
    @memcpy(b[str_off..][0..strs.items.len], strs.items);
    // Section 1: verneed (link 2, info 1). Section 2: its strings.
    const s1 = sh_off + 64;
    std.mem.writeInt(u32, b[s1 + 4 ..][0..4], 0x6ffffffe, .little);
    std.mem.writeInt(u64, b[s1 + 0x18 ..][0..8], vn_off, .little);
    std.mem.writeInt(u64, b[s1 + 0x20 ..][0..8], vn_size, .little);
    std.mem.writeInt(u32, b[s1 + 0x28 ..][0..4], 2, .little);
    std.mem.writeInt(u32, b[s1 + 0x2C ..][0..4], 1, .little);
    const s2 = sh_off + 128;
    std.mem.writeInt(u32, b[s2 + 4 ..][0..4], 3, .little);
    std.mem.writeInt(u64, b[s2 + 0x18 ..][0..8], str_off, .little);
    std.mem.writeInt(u64, b[s2 + 0x20 ..][0..8], strs.items.len, .little);
    return b;
}

fn expectNewest(names: []const []const u8, major: u32, minor: u32) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = (try F.newest(try image(arena.allocator(), names))).?;
    try std.testing.expectEqual(major, v.major);
    try std.testing.expectEqual(minor, v.minor);
}

test "the newest of several versions, not the first or the last" {
    try expectNewest(&.{ "GLIBC_2.2.5", "GLIBC_2.34", "GLIBC_2.7" }, 2, 34);
}

test "versions compare as numbers, not strings (2.9 is older than 2.34)" {
    try expectNewest(&.{ "GLIBC_2.34", "GLIBC_2.9" }, 2, 34);
}

test "GLIBC_PRIVATE and other libraries' versions are not glibc versions" {
    try expectNewest(&.{ "GLIBC_PRIVATE", "GLIBCXX_3.4.30", "GLIBC_2.17" }, 2, 17);
}

test "no glibc version at all" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try F.newest(try image(arena.allocator(), &.{"GCC_3.3"}))) == null);
}

test "the floor comparison: 2.34 is not newer than 2.34, 2.35 is" {
    const f = F.Version.parse("2.34").?;
    try std.testing.expect(F.Version.order(F.Version.parse("2.34").?, f) != .gt);
    try std.testing.expect(F.Version.order(F.Version.parse("2.35").?, f) == .gt);
    try std.testing.expect(F.Version.order(F.Version.parse("2.34.1").?, f) == .gt);
}

test "not an ELF, and a truncated one, are errors" {
    try std.testing.expectError(error.NotElf64, F.newest("hello"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = try image(arena.allocator(), &.{"GLIBC_2.34"});
    try std.testing.expectError(error.Truncated, F.newest(b[0 .. b.len - 100]));
}
