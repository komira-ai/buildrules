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

fn put(comptime T: type, b: []u8, off: usize, v: T) void {
    std.mem.writeInt(T, b[off..][0..@sizeOf(T)], v, .little);
}

/// The verneed section header of an `image` (section 1) and its string table's (section 2).
fn verneedHeader(b: []const u8) usize {
    return std.mem.readInt(u64, b[0x28..][0..8], .little) + 64;
}
fn stringsHeader(b: []const u8) usize {
    return std.mem.readInt(u64, b[0x28..][0..8], .little) + 128;
}

test "an ELF header that is not 64-bit little-endian is refused, not read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b32 = try image(a, &.{"GLIBC_2.34"});
    b32[4] = 1; // ELFCLASS32
    try std.testing.expectError(error.NotElf64, F.newest(b32));
    const be = try image(a, &.{"GLIBC_2.34"});
    be[5] = 2; // ELFDATA2MSB
    try std.testing.expectError(error.NotElf64, F.newest(be));
    const magic = try image(a, &.{"GLIBC_2.34"});
    magic[0] = 'X';
    try std.testing.expectError(error.NotElf64, F.newest(magic));
}

test "an offset or size that lies outside the file is Truncated, wherever it is: no read goes past the bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { name: []const u8, poke: *const fn ([]u8) void };
    const cases = [_]Case{
        .{ .name = "section headers start past the end", .poke = struct {
            fn f(b: []u8) void {
                put(u64, b, 0x28, b.len);
            }
        }.f },
        .{ .name = "more sections than the file holds", .poke = struct {
            fn f(b: []u8) void {
                put(u16, b, 0x3C, 4000);
            }
        }.f },
        .{ .name = "the string table is a section that does not exist", .poke = struct {
            fn f(b: []u8) void {
                put(u32, b, verneedHeader(b) + 0x28, 5000);
            }
        }.f },
        .{ .name = "the string table starts past the end", .poke = struct {
            fn f(b: []u8) void {
                put(u64, b, stringsHeader(b) + 0x18, b.len + 1);
            }
        }.f },
        .{ .name = "the string table is longer than the file", .poke = struct {
            fn f(b: []u8) void {
                put(u64, b, stringsHeader(b) + 0x20, b.len);
            }
        }.f },
        .{ .name = "the second Verneed lies past the end", .poke = struct {
            fn f(b: []u8) void {
                put(u32, b, verneedHeader(b) + 0x2C, 2); // two entries
                put(u32, b, 64 + 12, 1 << 20); // the first points far away
            }
        }.f },
        .{ .name = "the Verneed starts in the last bytes (its count is readable, its aux offset is not)", .poke = struct {
            fn f(b: []u8) void {
                put(u64, b, verneedHeader(b) + 0x18, b.len - 10);
            }
        }.f },
        .{ .name = "the Verneed's next link is the last thing in the file", .poke = struct {
            fn f(b: []u8) void {
                put(u64, b, verneedHeader(b) + 0x18, b.len - 12);
            }
        }.f },
        .{ .name = "the first Vernaux lies past the end", .poke = struct {
            fn f(b: []u8) void {
                put(u32, b, 64 + 8, @intCast(b.len));
            }
        }.f },
        .{ .name = "a Vernaux whose next link is unreadable", .poke = struct {
            fn f(b: []u8) void {
                put(u32, b, 64 + 8, @intCast(b.len - 12 - 64));
            }
        }.f },
    };
    for (cases) |c| {
        const b = try image(a, &.{"GLIBC_2.34"});
        c.poke(b);
        std.testing.expectError(error.Truncated, F.newest(b)) catch |e| {
            std.debug.print("case: {s}\n", .{c.name});
            return e;
        };
    }
}

test "a section header cut off inside its fields is Truncated, at each field it is read from" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The only header is the last 0x20 bytes of the file: its type and offset are readable, its link is not.
    const no_link = try image(a, &.{"GLIBC_2.34"});
    put(u64, no_link, 0x28, no_link.len - 0x20);
    put(u16, no_link, 0x3C, 1);
    put(u32, no_link, no_link.len - 0x20 + 4, 0x6ffffffe);
    try std.testing.expectError(error.Truncated, F.newest(no_link));
    // The last 0x2C bytes: the link is readable, the entry count is not.
    const no_count = try image(a, &.{"GLIBC_2.34"});
    put(u64, no_count, 0x28, no_count.len - 0x2C);
    put(u16, no_count, 0x3C, 1);
    put(u32, no_count, no_count.len - 0x2C + 4, 0x6ffffffe);
    try std.testing.expectError(error.Truncated, F.newest(no_count));
    // The string table's header ends before its size field.
    const b = try image(a, &.{"GLIBC_2.34"});
    try std.testing.expectError(error.Truncated, F.newest(b[0 .. b.len - 0x20]));
}

test "a Vernaux name outside the string table names no version; the others still count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try image(a, &.{ "GLIBC_2.34", "GLIBC_2.17" });
    put(u32, b, 64 + 16 + 8, 1 << 20); // the first Vernaux's name offset
    const v = (try F.newest(b)).?;
    try std.testing.expectEqual(@as(u32, 17), v.minor);
}

test "Version.parse: major.minor with an optional patch, digits only" {
    const ok = F.Version.parse("2.34").?;
    try std.testing.expectEqual(@as(u32, 0), ok.patch);
    const p = F.Version.parse("2.34.7").?;
    try std.testing.expectEqual(@as(u32, 7), p.patch);
    for ([_][]const u8{ "", "2", "x.2", "2.x", "2.3.x", "2.3.4.x", "2.3.4.", "2..3", "-1.2", "2.3." }) |bad| {
        std.testing.expect(F.Version.parse(bad) == null) catch |e| {
            std.debug.print("accepted: {s}\n", .{bad});
            return e;
        };
    }
}

test "Version.order: the major decides, then the minor, then the patch" {
    const v = F.Version.parse;
    try std.testing.expect(F.Version.order(v("3.0").?, v("2.99").?) == .gt);
    try std.testing.expect(F.Version.order(v("2.9").?, v("3.0").?) == .lt);
    try std.testing.expect(F.Version.order(v("2.34").?, v("2.35").?) == .lt);
    try std.testing.expect(F.Version.order(v("2.34.1").?, v("2.34.2").?) == .lt);
    try std.testing.expect(F.Version.order(v("2.34").?, v("2.34.0").?) == .eq);
}
