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

/// An ELF64 with a dynamic section whose DT_NEEDED entries name `needed` (in order), then one DT_SONAME and a DT_NULL: header, the dynamic string table, the
/// dynamic entries, and section headers for null, .dynstr (index 1) and .dynamic (index 2, linked to the string table).
fn dynImage(a: std.mem.Allocator, needed: []const []const u8, name_off_past_end: bool) ![]u8 {
    var strs = std.ArrayList(u8).empty;
    try strs.append(a, 0);
    var offs = std.ArrayList(u64).empty;
    for (needed) |n| {
        try offs.append(a, strs.items.len);
        try strs.appendSlice(a, n);
        try strs.append(a, 0);
    }
    const soname_off = strs.items.len;
    try strs.appendSlice(a, "libself.so.1");
    try strs.append(a, 0);
    const nent = needed.len + 3 + @as(usize, if (name_off_past_end) 1 else 0);
    const str_off = 64;
    const dyn_off = (str_off + strs.items.len + 7) / 8 * 8;
    const sh_off = dyn_off + nent * 16;
    const b = try a.alloc(u8, sh_off + 3 * 64);
    @memset(b, 0);
    @memcpy(b[0..4], "\x7fELF");
    b[4] = 2;
    b[5] = 1;
    std.mem.writeInt(u64, b[0x28..][0..8], sh_off, .little);
    std.mem.writeInt(u16, b[0x3A..][0..2], 64, .little);
    std.mem.writeInt(u16, b[0x3C..][0..2], 3, .little);
    std.mem.writeInt(u16, b[0x3E..][0..2], 1, .little);
    @memcpy(b[str_off..][0..strs.items.len], strs.items);
    var e: usize = 0;
    for (offs.items) |o| {
        std.mem.writeInt(u64, b[dyn_off + e * 16 ..][0..8], 1, .little);
        std.mem.writeInt(u64, b[dyn_off + e * 16 + 8 ..][0..8], o, .little);
        e += 1;
    }
    if (name_off_past_end) {
        std.mem.writeInt(u64, b[dyn_off + e * 16 ..][0..8], 1, .little);
        std.mem.writeInt(u64, b[dyn_off + e * 16 + 8 ..][0..8], 9999, .little);
        e += 1;
    }
    std.mem.writeInt(u64, b[dyn_off + e * 16 ..][0..8], 14, .little); // DT_SONAME is not a DT_NEEDED
    std.mem.writeInt(u64, b[dyn_off + e * 16 + 8 ..][0..8], soname_off, .little);
    // The last entry is DT_NULL (zeros).
    const dstr = sh_off + 64;
    std.mem.writeInt(u32, b[dstr + 4 ..][0..4], 3, .little);
    std.mem.writeInt(u64, b[dstr + 0x18 ..][0..8], str_off, .little);
    std.mem.writeInt(u64, b[dstr + 0x20 ..][0..8], strs.items.len, .little);
    const dyn = sh_off + 128;
    std.mem.writeInt(u32, b[dyn + 4 ..][0..4], 6, .little);
    std.mem.writeInt(u64, b[dyn + 0x18 ..][0..8], dyn_off, .little);
    std.mem.writeInt(u64, b[dyn + 0x20 ..][0..8], nent * 16, .little);
    std.mem.writeInt(u32, b[dyn + 0x28 ..][0..4], 1, .little);
    return b;
}

// Catches: a binary that asks the loader for the machine's own C++ runtime passing as hermetic, the check reading the wrong tag (DT_SONAME) or only the first
// entry, and a library that merely shares a prefix (`libc++utils.so`, `libunwindx.so`) refused for it.
test "runtimeNeeded: every DT_NEEDED naming a C++ runtime library, versioned or not, and nothing else" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const b = try dynImage(a, &.{ "libc.so.6", "libstdc++.so.6", "libm.so.6", "libgcc_s.so.1", "libc++utils.so", "libunwindx.so.1", "libc++.so", "libc++abi.so.1", "libunwind.so.8" }, false);
    const got = try H.runtimeNeeded(a, b);
    try std.testing.expectEqual(@as(usize, 5), got.len);
    try std.testing.expectEqualStrings("libstdc++.so.6", got[0]);
    try std.testing.expectEqualStrings("libgcc_s.so.1", got[1]);
    try std.testing.expectEqualStrings("libc++.so", got[2]);
    try std.testing.expectEqualStrings("libc++abi.so.1", got[3]);
    try std.testing.expectEqualStrings("libunwind.so.8", got[4]);
    // The same libraries are named in the finding of the whole check, with a reason that says the runtime is static.
    const f = try H.findings(a, b, "/work/root");
    try std.testing.expectEqual(@as(usize, 1), f.len);
    try std.testing.expect(std.mem.indexOf(u8, f[0], "needs the shared library libstdc++.so.6") != null);
}

test "runtimeNeeded: a dynamic section with only the C library, a static image, a name past the string table, a cut file and a non-ELF" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try H.runtimeNeeded(a, try dynImage(a, &.{ "libc.so.6", "libm.so.6" }, false))).len);
    try std.testing.expectEqual(@as(usize, 0), (try H.runtimeNeeded(a, try image(a, &.{ ".text", ".data" }, "x"))).len);
    const past = try dynImage(a, &.{"libstdc++.so.6"}, true);
    try std.testing.expectEqual(@as(usize, 1), (try H.runtimeNeeded(a, past)).len);
    const b = try dynImage(a, &.{"libstdc++.so.6"}, false);
    try std.testing.expectError(error.Truncated, H.runtimeNeeded(a, b[0 .. b.len - 100]));
    try std.testing.expectError(error.NotElf64, H.runtimeNeeded(a, "not an elf, but long enough to pass the first length test of the reader, which wants 64 bytes"));
}

test "isRuntimeLibrary: the stem, then nothing or a version" {
    try std.testing.expect(H.isRuntimeLibrary("libstdc++.so"));
    try std.testing.expect(H.isRuntimeLibrary("libstdc++.so.6.0.33"));
    try std.testing.expect(H.isRuntimeLibrary("libgcc_s.so.1"));
    try std.testing.expect(!H.isRuntimeLibrary("libstdc++.sox"));
    try std.testing.expect(!H.isRuntimeLibrary("libm.so.6"));
    try std.testing.expect(!H.isRuntimeLibrary("libc++"));
}
