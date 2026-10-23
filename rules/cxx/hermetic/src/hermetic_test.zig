//! Unit tests of hermetic over ELF images built in the test: section names are put in a .shstrtab, so a tool that looked at the wrong section, matched
//! `.debug` only exactly, skipped the last section, or looked for the directory only in section names would fail one of them.

const std = @import("std");
const H = @import("hermetic.zig");

/// A minimal ELF64: header, a payload, a .shstrtab holding `names`, and one section header per name (plus the null section and the string table).
fn image(a: std.mem.Allocator, names: []const []const u8, payload: []const u8) ![]u8 {
    var strs = std.ArrayList(u8).empty;
    try strs.append(a, 0);
    var name_offs = std.ArrayList(u32).empty;
    for (names) |n| {
        try name_offs.append(a, @intCast(strs.items.len));
        try strs.appendSlice(a, n);
        try strs.append(a, 0);
    }
    const shstr_name: u32 = @intCast(strs.items.len);
    try strs.appendSlice(a, ".shstrtab");
    try strs.append(a, 0);
    const nsec = names.len + 2; // null, each name, the string table
    const pay_off = 64;
    const str_off = pay_off + payload.len;
    const sh_off = (str_off + strs.items.len + 7) / 8 * 8;
    const b = try a.alloc(u8, sh_off + nsec * 64);
    @memset(b, 0);
    @memcpy(b[0..4], "\x7fELF");
    b[4] = 2;
    b[5] = 1;
    std.mem.writeInt(u64, b[0x28..][0..8], sh_off, .little);
    std.mem.writeInt(u16, b[0x3A..][0..2], 64, .little);
    std.mem.writeInt(u16, b[0x3C..][0..2], @intCast(nsec), .little);
    std.mem.writeInt(u16, b[0x3E..][0..2], @intCast(nsec - 1), .little);
    @memcpy(b[pay_off..][0..payload.len], payload);
    @memcpy(b[str_off..][0..strs.items.len], strs.items);
    for (name_offs.items, 0..) |off, i| {
        const sh = sh_off + (i + 1) * 64;
        std.mem.writeInt(u32, b[sh..][0..4], off, .little);
        std.mem.writeInt(u32, b[sh + 4 ..][0..4], 1, .little);
    }
    const last = sh_off + (nsec - 1) * 64;
    std.mem.writeInt(u32, b[last..][0..4], shstr_name, .little);
    std.mem.writeInt(u32, b[last + 4 ..][0..4], 3, .little);
    std.mem.writeInt(u64, b[last + 0x18 ..][0..8], str_off, .little);
    std.mem.writeInt(u64, b[last + 0x20 ..][0..8], strs.items.len, .little);
    return b;
}

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "an image with only code and data sections has no debug section" {
    var ar = arena();
    defer ar.deinit();
    const b = try image(ar.allocator(), &.{ ".text", ".data", ".comment" }, "x");
    try std.testing.expectEqual(@as(usize, 0), (try H.debugSections(ar.allocator(), b)).len);
}

test "every .debug section is found, whichever its position, and a name that merely contains debug is not one" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const b = try image(a, &.{ ".text", ".debug_info", ".data", ".debug_line", ".debug_str", ".gnu_debuglink" }, "x");
    const got = try H.debugSections(a, b);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings(".debug_info", got[0]);
    try std.testing.expectEqualStrings(".debug_line", got[1]);
    try std.testing.expectEqualStrings(".debug_str", got[2]);
    // the last section before the string table is read too
    const last = try image(a, &.{ ".text", ".debug_abbrev" }, "x");
    try std.testing.expectEqual(@as(usize, 1), (try H.debugSections(a, last)).len);
}

test "the build directory is found in the bytes of the file, not only in a section name" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const dir = "/work/root";
    const dirty = try image(a, &.{".text"}, "xx /work/root/src/start.S yy");
    try std.testing.expect(H.mentions(dirty, dir));
    const clean = try image(a, &.{".text"}, "xx /usr/lib yy");
    try std.testing.expect(!H.mentions(clean, dir));
    // "/" alone (a cwd at the root) would match every path, so it is not a directory to look for
    try std.testing.expect(!H.mentions(dirty, "/"));
    try std.testing.expect(!H.mentions(dirty, ""));
}

test "findings names each reason, and is empty for a binary with neither" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const clean = try image(a, &.{ ".text", ".data" }, "nothing here");
    try std.testing.expectEqual(@as(usize, 0), (try H.findings(a, clean, "/work/root")).len);
    const dbg = try image(a, &.{ ".text", ".debug_info" }, "nothing here");
    const one = try H.findings(a, dbg, "/work/root");
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expect(std.mem.indexOf(u8, one[0], ".debug_info") != null);
    const both = try image(a, &.{ ".text", ".debug_info" }, "/work/root");
    try std.testing.expectEqual(@as(usize, 2), (try H.findings(a, both, "/work/root")).len);
}

test "not an ELF, and a truncated one, are errors" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectError(error.NotElf64, H.debugSections(a, "hello"));
    const b = try image(a, &.{".debug_info"}, "x");
    try std.testing.expectError(error.Truncated, H.debugSections(a, b[0 .. b.len - 100]));
}

fn put(comptime T: type, b: []u8, off: usize, v: T) void {
    std.mem.writeInt(T, b[off..][0..@sizeOf(T)], v, .little);
}

fn shoff(b: []const u8) usize {
    return std.mem.readInt(u64, b[0x28..][0..8], .little);
}

test "an ELF header that is not 64-bit little-endian is refused, not read" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const b32 = try image(a, &.{".text"}, "x");
    b32[4] = 1; // ELFCLASS32
    try std.testing.expectError(error.NotElf64, H.debugSections(a, b32));
    const be = try image(a, &.{".text"}, "x");
    be[5] = 2; // ELFDATA2MSB
    try std.testing.expectError(error.NotElf64, H.debugSections(a, be));
    const magic = try image(a, &.{".text"}, "x");
    magic[3] = 'G';
    try std.testing.expectError(error.NotElf64, H.debugSections(a, magic));
}

test "an ELF with no sections has no debug section" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const b = try image(a, &.{".debug_info"}, "x");
    put(u16, b, 0x3C, 0);
    try std.testing.expectEqual(@as(usize, 0), (try H.debugSections(a, b)).len);
}

test "an offset or count that lies outside the file is Truncated: no read goes past the bytes" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const Case = struct { name: []const u8, poke: *const fn ([]u8) void };
    const cases = [_]Case{
        .{ .name = "section headers start past the end", .poke = struct {
            fn f(b: []u8) void {
                put(u64, b, 0x28, b.len);
            }
        }.f },
        .{ .name = "the section name table is a section that does not exist", .poke = struct {
            fn f(b: []u8) void {
                put(u16, b, 0x3E, 5000);
            }
        }.f },
        .{ .name = "the name table starts past the end", .poke = struct {
            fn f(b: []u8) void {
                const last = shoff(b) + 3 * 64;
                put(u64, b, last + 0x18, b.len + 1);
            }
        }.f },
        .{ .name = "the name table is longer than the file", .poke = struct {
            fn f(b: []u8) void {
                const last = shoff(b) + 3 * 64;
                put(u64, b, last + 0x20, b.len);
            }
        }.f },
        .{ .name = "more sections than the file holds", .poke = struct {
            fn f(b: []u8) void {
                put(u16, b, 0x3C, 4000);
            }
        }.f },
    };
    for (cases) |c| {
        const b = try image(a, &.{ ".text", ".data" }, "x");
        c.poke(b);
        std.testing.expectError(error.Truncated, H.debugSections(a, b)) catch |e| {
            std.debug.print("case: {s}\n", .{c.name});
            return e;
        };
    }
}

test "a name table whose header ends before its size field is Truncated" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const b = try image(a, &.{ ".text", ".data" }, "x");
    try std.testing.expectError(error.Truncated, H.debugSections(a, b[0 .. b.len - 0x20]));
}

test "a section whose name lies outside the name table is not a debug section, and does not stop the others being read" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const b = try image(a, &.{ ".text", ".debug_info" }, "x");
    put(u32, b, shoff(b) + 64, 1 << 20); // .text's name offset
    const got = try H.debugSections(a, b);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings(".debug_info", got[0]);
}

test "findings refuses a file it cannot read, rather than calling it clean" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectError(error.NotElf64, H.findings(a, "hello", "/work/root"));
    const b = try image(a, &.{".debug_info"}, "x");
    try std.testing.expectError(error.Truncated, H.findings(a, b[0 .. b.len - 100], "/work/root"));
}

test "running out of memory is an error of debugSections and findings, whichever allocation it is, and never a wrong answer" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const b = try image(a, &.{ ".text", ".debug_info", ".debug_line" }, "/work/root");
    var failed: usize = 0;
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer scratch.deinit();
        var fa = std.testing.FailingAllocator.init(scratch.allocator(), .{ .fail_index = n });
        if (H.findings(fa.allocator(), b, "/work/root")) |got| {
            // enough allocations were allowed: the answer is the whole one
            try std.testing.expectEqual(@as(usize, 2), got.len);
        } else |e| {
            try std.testing.expectEqual(error.OutOfMemory, e);
            failed += 1;
        }
        var fa2 = std.testing.FailingAllocator.init(scratch.allocator(), .{ .fail_index = n });
        if (H.debugSections(fa2.allocator(), b)) |got| {
            try std.testing.expectEqual(@as(usize, 2), got.len);
        } else |e| try std.testing.expectEqual(error.OutOfMemory, e);
    }
    try std.testing.expect(failed > 0);
    try std.testing.expect(failed < 64);
}
