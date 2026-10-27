//! Unit tests of archive_check over Mach-O objects in BSD-style archives (a library built for macOS arm64). Each rule has a case that breaks only it, and the
//! cases that decide which C library a symbol is looked up in compare the two formats on the same name.

const std = @import("std");
const A = @import("archive.zig");
const E = @import("archive_test.zig");

const t = std.testing;

const Kind = enum { def, undef, weak_undef, local, common, stab };
const Sym = struct { name: []const u8, kind: Kind };

fn put(comptime T: type, b: []u8, off: usize, v: T) void {
    std.mem.writeInt(T, b[off..][0..@sizeOf(T)], v, .little);
}

/// A Mach-O 64-bit object (arm64): one LC_SEGMENT_64 with one section per `sections` entry (`"__DWARF,__debug_info"`), then LC_SYMTAB over `syms`.
/// A symbol's name is the C name; the compiler's underscore is added here, except for a debug-map entry.
fn object(a: std.mem.Allocator, syms: []const Sym, sections: []const []const u8, filetype: u32) ![]u8 {
    var str = std.ArrayList(u8).empty;
    try str.append(a, 0);
    var tab = std.ArrayList(u8).empty;
    for (syms) |s| {
        var e: [16]u8 = [_]u8{0} ** 16;
        put(u32, &e, 0, @intCast(str.items.len));
        if (s.kind != .stab) try str.append(a, '_');
        try str.appendSlice(a, s.name);
        try str.append(a, 0);
        switch (s.kind) {
            .def => {
                e[4] = 0x0f;
                e[5] = 1;
            },
            .undef => e[4] = 0x01,
            .weak_undef => {
                e[4] = 0x01;
                put(u16, e[6..8], 0, 0x40);
            },
            .local => {
                e[4] = 0x0e;
                e[5] = 1;
            },
            .common => {
                e[4] = 0x01;
                put(u64, &e, 8, 8);
            },
            .stab => e[4] = 0x64,
        }
        try tab.appendSlice(a, &e);
    }
    const seg_size = 72 + 80 * sections.len;
    const cmds = seg_size + 24;
    const sym_off = 32 + cmds;
    const str_off = sym_off + tab.items.len;
    const b = try a.alloc(u8, str_off + str.items.len);
    @memset(b, 0);
    put(u32, b, 0, 0xfeedfacf);
    put(u32, b, 4, 0x0100000c);
    put(u32, b, 12, filetype);
    put(u32, b, 16, 2);
    put(u32, b, 20, @intCast(cmds));
    put(u32, b, 32, 0x19);
    put(u32, b, 36, @intCast(seg_size));
    put(u32, b, 32 + 64, @intCast(sections.len));
    for (sections, 0..) |sec, i| {
        const at = 32 + 72 + i * 80;
        const comma = std.mem.indexOfScalar(u8, sec, ',').?;
        // The section's name first, then the name of its segment.
        @memcpy(b[at..][0 .. sec.len - comma - 1], sec[comma + 1 ..]);
        @memcpy(b[at + 16 ..][0..comma], sec[0..comma]);
    }
    const st = 32 + seg_size;
    put(u32, b, st, 0x2);
    put(u32, b, st + 4, 24);
    put(u32, b, st + 8, @intCast(sym_off));
    put(u32, b, st + 12, @intCast(syms.len));
    put(u32, b, st + 16, @intCast(str_off));
    put(u32, b, st + 20, @intCast(str.items.len));
    @memcpy(b[sym_off..][0..tab.items.len], tab.items);
    @memcpy(b[str_off..][0..str.items.len], str.items);
    return b;
}

fn clean(a: std.mem.Allocator, syms: []const Sym) ![]u8 {
    return object(a, syms, &.{"__TEXT,__text"}, 1);
}

const Entry = struct { name: []const u8, data: []const u8, time: []const u8 = "0" };

fn field(o: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8, width: usize) !void {
    try o.appendSlice(a, s);
    try o.appendNTimes(a, ' ', width - s.len);
}

/// One BSD-style member: the name `#1/N` and the name (NUL padded to a multiple of 8, as ar writes it for Mach-O) ahead of the data.
fn member(o: *std.ArrayList(u8), a: std.mem.Allocator, name: []const u8, data: []const u8, time: []const u8) !void {
    const padded = (name.len + 7) / 8 * 8;
    var n: [16]u8 = undefined;
    try field(o, a, try std.fmt.bufPrint(&n, "#1/{d}", .{padded}), 16);
    try field(o, a, time, 12);
    try field(o, a, "0", 6);
    try field(o, a, "0", 6);
    try field(o, a, "644", 8);
    var size: [10]u8 = undefined;
    try field(o, a, try std.fmt.bufPrint(&size, "{d}", .{padded + data.len}), 10);
    try o.appendSlice(a, "`\n");
    try o.appendSlice(a, name);
    try o.appendNTimes(a, 0, padded - name.len);
    try o.appendSlice(a, data);
    if ((padded + data.len) & 1 == 1) try o.append(a, '\n');
}

/// A BSD archive: the `__.SYMDEF` symbol table member first (four bytes of table, the content does not matter), then `entries`.
fn archive(a: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var o = std.ArrayList(u8).empty;
    try o.appendSlice(a, "!<arch>\n");
    try member(&o, a, "__.SYMDEF", "\x00\x00\x00\x00", "0");
    for (entries) |e| try member(&o, a, e.name, e.data, e.time);
    return o.toOwnedSlice(a);
}

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

fn hasFinding(r: A.Report, needle: []const u8) bool {
    for (r.findings) |f| if (std.mem.indexOf(u8, f, needle) != null) return true;
    return false;
}

fn has(list: []const []const u8, name: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

test "members: BSD names are read, the symbol tables are not members, and the data starts after the name" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try clean(a, &.{.{ .name = "f", .kind = .def }});
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, "!<arch>\n");
    try member(&out, a, "__.SYMDEF SORTED", "\x00\x00\x00\x00", "0");
    try member(&out, a, "a.c.o", o, "0");
    try member(&out, a, "a_member_with_a_longer_name.o", "xyz", "0");
    const ms = try A.members(a, out.items);
    try t.expectEqual(@as(usize, 2), ms.len);
    try t.expectEqualStrings("a.c.o", ms[0].name);
    try t.expectEqualSlices(u8, o, ms[0].data);
    try t.expectEqualStrings("a_member_with_a_longer_name.o", ms[1].name);
    try t.expectEqualStrings("xyz", ms[1].data);
    try t.expectEqualStrings("0", ms[1].owner);
}

test "members: a BSD name longer than its member, or not a number, is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const good = try archive(a, &.{.{ .name = "a.o", .data = "0123456789" }});
    // The name field of the first member (the symbol table's) is bytes 8 to 24.
    const long = try a.dupe(u8, good);
    @memcpy(long[8..24], "#1/99           ");
    try t.expectError(error.BadHeader, A.members(a, long));
    const word = try a.dupe(u8, good);
    @memcpy(word[8..24], "#1/zz           ");
    try t.expectError(error.BadHeader, A.members(a, word));
}

test "machoSymbols: external definitions and undefined names by their C names; a weak reference, a local and a debug-map entry are neither" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try clean(a, &.{
        .{ .name = "defined_fn", .kind = .def },
        .{ .name = "memcpy", .kind = .undef },
        .{ .name = "weak_ref", .kind = .weak_undef },
        .{ .name = "file_local", .kind = .local },
        .{ .name = "tentative", .kind = .common },
        .{ .name = "debug_entry", .kind = .stab },
    });
    const s = try A.machoSymbols(a, o);
    try t.expectEqual(@as(usize, 2), s.defined.len);
    try t.expect(has(s.defined, "defined_fn"));
    try t.expect(has(s.defined, "tentative"));
    try t.expectEqual(@as(usize, 1), s.undef.len);
    try t.expectEqualStrings("memcpy", s.undef[0]);
    // A name the string table does not reach and the empty name are skipped. The symbols start at 32 + 72 + 80 + 24.
    const odd = try a.dupe(u8, o);
    put(u32, odd, 208, 1 << 20);
    put(u32, odd, 208 + 16, 0);
    const s2 = try A.machoSymbols(a, odd);
    try t.expectEqual(@as(usize, 1), s2.defined.len);
    try t.expectEqual(@as(usize, 0), s2.undef.len);
}

test "machoSymbols and machoDebug: a file that is not a Mach-O object, not relocatable, or cut anywhere is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectError(error.NotMacho64, A.machoSymbols(a, "\x7fELF and more bytes of text"));
    try t.expectError(error.NotMacho64, A.machoDebug(""));
    const exe = try object(a, &.{.{ .name = "f", .kind = .def }}, &.{"__TEXT,__text"}, 2);
    try t.expectError(error.NotRelocatable, A.machoSymbols(a, exe));
    try t.expectError(error.NotRelocatable, A.machoDebug(exe));
    const o = try object(a, &.{ .{ .name = "f", .kind = .def }, .{ .name = "g", .kind = .undef }, .{ .name = "s", .kind = .stab } }, &.{ "__TEXT,__text", "__DWARF,__debug_info" }, 1);
    var refused: usize = 0;
    var n: usize = 0;
    while (n < o.len) : (n += 1) {
        if (A.machoSymbols(a, o[0..n])) |_| {} else |_| refused += 1;
        if (A.machoDebug(o[0..n])) |_| {} else |_| refused += 1;
    }
    // Every cut is refused by both functions: the string table is the last thing in the file and is checked whole.
    try t.expectEqual(2 * o.len, refused);
    const s = try A.machoSymbols(a, o);
    try t.expectEqual(@as(usize, 1), s.defined.len);
}

test "machoCommands: a command that runs past the commands, or is smaller than its header, and a table past the end are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try clean(a, &.{.{ .name = "f", .kind = .def }});
    const big = try a.dupe(u8, o);
    put(u32, big, 36, 1 << 20);
    try t.expectError(error.Truncated, A.machoSymbols(a, big));
    const tiny = try a.dupe(u8, o);
    put(u32, tiny, 36, 4);
    try t.expectError(error.Truncated, A.machoSymbols(a, tiny));
    const st = 32 + 72 + 80;
    const syms = try a.dupe(u8, o);
    put(u32, syms, st + 12, 1 << 20);
    try t.expectError(error.Truncated, A.machoSymbols(a, syms));
    const strs = try a.dupe(u8, o);
    put(u32, strs, st + 20, 1 << 20);
    try t.expectError(error.Truncated, A.machoSymbols(a, strs));
    const nsects = try a.dupe(u8, o);
    put(u32, nsects, 32 + 64, 1 << 20);
    try t.expectError(error.Truncated, A.machoDebug(nsects));
    const ncmds = try a.dupe(u8, o);
    put(u32, ncmds, 16, 9);
    try t.expectError(error.Truncated, A.machoSymbols(a, ncmds));
}

test "a clean Mach-O library has no finding and lists its defined symbols by C name, sorted" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o1 = try clean(a, &.{ .{ .name = "zeta", .kind = .def }, .{ .name = "memcpy", .kind = .undef }, .{ .name = "strlen", .kind = .undef } });
    const o2 = try clean(a, &.{ .{ .name = "alpha", .kind = .def }, .{ .name = "zeta", .kind = .undef }, .{ .name = "__error", .kind = .undef }, .{ .name = "utimensat", .kind = .undef }, .{ .name = "futimens", .kind = .undef } });
    const b = try archive(a, &.{ .{ .name = "a.o", .data = o1 }, .{ .name = "b.o", .data = o2 } });
    const r = try A.check(a, "libx.a", b, .{});
    try t.expectEqual(@as(usize, 0), r.findings.len);
    try t.expectEqual(@as(usize, 2), r.defined.len);
    try t.expectEqualStrings("alpha", r.defined[0]);
    try t.expectEqualStrings("zeta", r.defined[1]);
}

test "an undefined symbol that neither the library nor libSystem has is named, once, with libSystem as the floor" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o1 = try clean(a, &.{ .{ .name = "f", .kind = .def }, .{ .name = "nowhere_defined", .kind = .undef } });
    const o2 = try clean(a, &.{.{ .name = "nowhere_defined", .kind = .undef }});
    const b = try archive(a, &.{ .{ .name = "a.o", .data = o1 }, .{ .name = "b.o", .data = o2 } });
    const r = try A.check(a, "libx.a", b, .{});
    try t.expectEqual(@as(usize, 1), r.findings.len);
    try t.expect(hasFinding(r, "undefined symbol: nowhere_defined (not defined by this library, a `needs` library, libSystem or the compiler runtime)"));
    // An allow, or a needs library that defines it, makes it known.
    try t.expectEqual(@as(usize, 0), (try A.check(a, "libx.a", b, .{ .allow = &.{"nowhere_defined"} })).findings.len);
    const base = try archive(a, &.{.{ .name = "n.o", .data = try clean(a, &.{.{ .name = "nowhere_defined", .kind = .def }}) }});
    try t.expectEqual(@as(usize, 0), (try A.check(a, "libx.a", b, .{ .needs = &.{base} })).findings.len);
}

test "the C library a symbol is looked up in follows the object format: libSystem for Mach-O, glibc for ELF" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // `__error` is libSystem's errno and glibc has none of that name; `__errno_location` is the other way round.
    const mac_ok = try archive(a, &.{.{ .name = "a.o", .data = try clean(a, &.{ .{ .name = "f", .kind = .def }, .{ .name = "__error", .kind = .undef } }) }});
    try t.expectEqual(@as(usize, 0), (try A.check(a, "libx.a", mac_ok, .{})).findings.len);
    const mac_bad = try archive(a, &.{.{ .name = "a.o", .data = try clean(a, &.{ .{ .name = "f", .kind = .def }, .{ .name = "__errno_location", .kind = .undef } }) }});
    try t.expect(hasFinding(try A.check(a, "libx.a", mac_bad, .{}), "undefined symbol: __errno_location"));
    // The same names keep their ELF meaning: `__error` is not glibc's, so an ELF library that calls it is refused. And epoll_create1 is glibc's and not
    // libSystem's.
    const elf_error = try E.archive(a, &.{.{ .name = "a.o", .data = try E.object(a, &.{ .{ .name = "f", .kind = .def }, .{ .name = "__error", .kind = .undef } }, &.{}) }});
    try t.expect(hasFinding(try A.check(a, "libx.a", elf_error, .{}), "undefined symbol: __error"));
    const mac_epoll = try archive(a, &.{.{ .name = "a.o", .data = try clean(a, &.{ .{ .name = "f", .kind = .def }, .{ .name = "epoll_create1", .kind = .undef } }) }});
    try t.expect(hasFinding(try A.check(a, "libx.a", mac_epoll, .{}), "undefined symbol: epoll_create1"));
}

test "a Mach-O symbol is looked up without its underscore: the name the library defines under its own underscore satisfies a use" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o1 = try clean(a, &.{.{ .name = "_leading", .kind = .def }});
    const o2 = try clean(a, &.{ .{ .name = "g", .kind = .def }, .{ .name = "_leading", .kind = .undef } });
    const b = try archive(a, &.{ .{ .name = "a.o", .data = o1 }, .{ .name = "b.o", .data = o2 } });
    const r = try A.check(a, "libx.a", b, .{});
    try t.expectEqual(@as(usize, 0), r.findings.len);
    try t.expect(has(r.defined, "_leading"));
}

test "a Mach-O debug section or debug-map symbol is a finding, naming the member; a section of another segment is not" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const dwarf = try object(a, &.{.{ .name = "f", .kind = .def }}, &.{ "__TEXT,__text", "__DWARF,__debug_info" }, 1);
    const r = try A.check(a, "libx.a", try archive(a, &.{.{ .name = "a.o", .data = dwarf }}), .{});
    try t.expect(hasFinding(r, "member a.o has 1 debug section(s), first __debug_info"));
    const stab = try clean(a, &.{ .{ .name = "f", .kind = .def }, .{ .name = "/work/dir/a.c", .kind = .stab } });
    const r2 = try A.check(a, "libx.a", try archive(a, &.{.{ .name = "a.o", .data = stab }}), .{});
    try t.expect(hasFinding(r2, "member a.o has 1 debug section(s), first (a debug-map symbol)"));
    const other = try object(a, &.{.{ .name = "f", .kind = .def }}, &.{ "__TEXT,__text", "__DATA,__data", "__TEXT,__debug_like" }, 1);
    try t.expectEqual(@as(usize, 0), (try A.check(a, "libx.a", try archive(a, &.{.{ .name = "a.o", .data = other }}), .{})).findings.len);
}

test "a Mach-O library is held to the member rules: time or owner, the order of names, the build path, a member that is not an object" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try clean(a, &.{.{ .name = "f", .kind = .def }});
    const timed = try archive(a, &.{.{ .name = "a.o", .data = o, .time = "7" }});
    try t.expect(hasFinding(try A.check(a, "libx.a", timed, .{}), "member a.o records a time or an owner"));
    const unordered = try archive(a, &.{ .{ .name = "b.o", .data = o }, .{ .name = "a.o", .data = o } });
    try t.expect(hasFinding(try A.check(a, "libx.a", unordered, .{}), "member a.o comes after b.o"));
    const pathy = try clean(a, &.{.{ .name = "/work/exec/root/f", .kind = .def }});
    try t.expect(hasFinding(try A.check(a, "libx.a", try archive(a, &.{.{ .name = "a.o", .data = pathy }}), .{ .dir = "/work/exec/root" }), "absolute path of the directory it was built in"));
    const exe = try object(a, &.{.{ .name = "f", .kind = .def }}, &.{"__TEXT,__text"}, 2);
    try t.expect(hasFinding(try A.check(a, "libx.a", try archive(a, &.{.{ .name = "a.o", .data = exe }}), .{}), "member a.o is not a relocatable Mach-O object: NotRelocatable"));
}

test "a library of both formats is a finding naming the member of the second, whichever format comes first" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const mach = try clean(a, &.{.{ .name = "f", .kind = .def }});
    const elf = try E.object(a, &.{.{ .name = "g", .kind = .def }}, &.{});
    const mach_first = try A.check(a, "libx.a", try archive(a, &.{ .{ .name = "a.o", .data = mach }, .{ .name = "b.o", .data = elf } }), .{});
    try t.expectEqual(@as(usize, 1), mach_first.findings.len);
    try t.expect(hasFinding(mach_first, "member b.o is an ELF object in a library of Mach-O objects"));
    const elf_first = try A.check(a, "libx.a", try archive(a, &.{ .{ .name = "a.o", .data = elf }, .{ .name = "b.o", .data = mach } }), .{});
    try t.expectEqual(@as(usize, 1), elf_first.findings.len);
    try t.expect(hasFinding(elf_first, "member b.o is a Mach-O object in a library of ELF objects"));
}

const CheckCall = struct {
    archive: []const u8,
    needs: []const []const u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !void {
        _ = try A.check(a, "libx.a", self.archive, .{ .needs = self.needs, .allow = &.{"allowed_one"}, .dir = "/work/dir" });
    }
};

test "check: every allocation failing in turn is an error, for a Mach-O library with every kind of finding" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const base = try archive(a, &.{.{ .name = "b.o", .data = try clean(a, &.{.{ .name = "base_value", .kind = .def }}) }});
    const ok = try clean(a, &.{ .{ .name = "f", .kind = .def }, .{ .name = "memcpy", .kind = .undef }, .{ .name = "base_value", .kind = .undef } });
    const bad = try object(a, &.{ .{ .name = "h", .kind = .def }, .{ .name = "missing_one", .kind = .undef }, .{ .name = "s", .kind = .stab } }, &.{"__DWARF,__debug_info"}, 1);
    var i: usize = 0;
    const specs = [_]CheckCall{
        .{ .archive = try archive(a, &.{ .{ .name = "a.o", .data = ok }, .{ .name = "b.o", .data = ok } }), .needs = &.{base} },
        .{ .archive = try archive(a, &.{ .{ .name = "b.o", .data = bad, .time = "5" }, .{ .name = "a.o", .data = "text" } }), .needs = &.{ base, "junk" } },
    };
    for (specs) |spec| {
        i = 0;
        while (i < 5000) : (i += 1) {
            var fa = t.FailingAllocator.init(t.allocator, .{ .fail_index = i });
            var arn = std.heap.ArenaAllocator.init(fa.allocator());
            defer arn.deinit();
            spec.call(arn.allocator()) catch |e| {
                try t.expectEqual(error.OutOfMemory, e);
                continue;
            };
            try t.expect(!fa.has_induced_failure);
            break;
        }
        try t.expect(i < 5000);
    }
}
