//! Unit tests of archive_check over objects and archives built in the test. Each rule has a case that breaks only it, so a tool that dropped one
//! rule, read the wrong symbol kind or skipped the last member fails one of them.

const std = @import("std");
const A = @import("archive.zig");

const t = std.testing;

pub const Sym = struct { name: []const u8, kind: enum { def, undef, weak_undef, local } };

/// A relocatable ELF64 object: .symtab (null symbol, then `syms`), .strtab, .shstrtab, and one empty section per `sections` name.
pub fn object(a: std.mem.Allocator, syms: []const Sym, sections: []const []const u8) ![]u8 {
    var str = std.ArrayList(u8).empty;
    try str.append(a, 0);
    var tab = std.ArrayList(u8).empty;
    try tab.appendNTimes(a, 0, 24);
    for (syms) |s| {
        var e: [24]u8 = [_]u8{0} ** 24;
        std.mem.writeInt(u32, e[0..4], @intCast(str.items.len), .little);
        try str.appendSlice(a, s.name);
        try str.append(a, 0);
        switch (s.kind) {
            .def => {
                e[4] = (1 << 4) | 2;
                std.mem.writeInt(u16, e[6..8], 1, .little);
            },
            .undef => e[4] = 1 << 4,
            .weak_undef => e[4] = 2 << 4,
            .local => {
                e[4] = 2;
                std.mem.writeInt(u16, e[6..8], 1, .little);
            },
        }
        try tab.appendSlice(a, &e);
    }
    var shstr = std.ArrayList(u8).empty;
    try shstr.append(a, 0);
    const n_symtab: u32 = @intCast(shstr.items.len);
    try shstr.appendSlice(a, ".symtab\x00");
    const n_strtab: u32 = @intCast(shstr.items.len);
    try shstr.appendSlice(a, ".strtab\x00");
    const n_shstr: u32 = @intCast(shstr.items.len);
    try shstr.appendSlice(a, ".shstrtab\x00");
    var extra = std.ArrayList(u32).empty;
    for (sections) |n| {
        try extra.append(a, @intCast(shstr.items.len));
        try shstr.appendSlice(a, n);
        try shstr.append(a, 0);
    }
    const nsec = 4 + sections.len;
    const tab_off = 64;
    const str_off = tab_off + tab.items.len;
    const shstr_off = str_off + str.items.len;
    const sh_off = (shstr_off + shstr.items.len + 7) / 8 * 8;
    const b = try a.alloc(u8, sh_off + nsec * 64);
    @memset(b, 0);
    @memcpy(b[0..4], "\x7fELF");
    b[4] = 2;
    b[5] = 1;
    std.mem.writeInt(u16, b[0x10..][0..2], 1, .little);
    std.mem.writeInt(u64, b[0x28..][0..8], sh_off, .little);
    std.mem.writeInt(u16, b[0x3A..][0..2], 64, .little);
    std.mem.writeInt(u16, b[0x3C..][0..2], @intCast(nsec), .little);
    std.mem.writeInt(u16, b[0x3E..][0..2], 3, .little);
    @memcpy(b[tab_off..][0..tab.items.len], tab.items);
    @memcpy(b[str_off..][0..str.items.len], str.items);
    @memcpy(b[shstr_off..][0..shstr.items.len], shstr.items);
    const secs = [_]struct { name: u32, typ: u32, off: usize, size: usize, link: u32 }{
        .{ .name = n_symtab, .typ = 2, .off = tab_off, .size = tab.items.len, .link = 2 },
        .{ .name = n_strtab, .typ = 3, .off = str_off, .size = str.items.len, .link = 0 },
        .{ .name = n_shstr, .typ = 3, .off = shstr_off, .size = shstr.items.len, .link = 0 },
    };
    for (secs, 1..) |s, i| {
        const sh = sh_off + i * 64;
        std.mem.writeInt(u32, b[sh..][0..4], s.name, .little);
        std.mem.writeInt(u32, b[sh + 4 ..][0..4], s.typ, .little);
        std.mem.writeInt(u64, b[sh + 0x18 ..][0..8], s.off, .little);
        std.mem.writeInt(u64, b[sh + 0x20 ..][0..8], s.size, .little);
        std.mem.writeInt(u32, b[sh + 0x28 ..][0..4], s.link, .little);
    }
    for (extra.items, 0..) |n, i| {
        const sh = sh_off + (4 + i) * 64;
        std.mem.writeInt(u32, b[sh..][0..4], n, .little);
        std.mem.writeInt(u32, b[sh + 4 ..][0..4], 1, .little);
    }
    return b;
}

pub const Entry = struct { name: []const u8, data: []const u8, time: []const u8 = "0" };

fn field(o: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8, width: usize) !void {
    try o.appendSlice(a, s);
    try o.appendNTimes(a, ' ', width - s.len);
}

/// A GNU `ar` archive: a symbol table member, a long-name table when a name needs one, and `entries`.
pub fn archive(a: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var o = std.ArrayList(u8).empty;
    try o.appendSlice(a, "!<arch>\n");
    try member(&o, a, "/", "\x00\x00\x00\x00", "0");
    var long = std.ArrayList(u8).empty;
    for (entries) |e| {
        if (e.name.len > 15) {
            try long.appendSlice(a, e.name);
            try long.appendSlice(a, "/\n");
        }
    }
    if (long.items.len != 0) try member(&o, a, "//", long.items, "0");
    var at: usize = 0;
    for (entries) |e| {
        if (e.name.len > 15) {
            const n = try std.fmt.allocPrint(a, "/{d}", .{at});
            at += e.name.len + 2;
            try member(&o, a, n, e.data, e.time);
        } else {
            const n = try std.fmt.allocPrint(a, "{s}/", .{e.name});
            try member(&o, a, n, e.data, e.time);
        }
    }
    return o.toOwnedSlice(a);
}

fn member(o: *std.ArrayList(u8), a: std.mem.Allocator, name: []const u8, data: []const u8, time: []const u8) !void {
    try field(o, a, name, 16);
    try field(o, a, time, 12);
    try field(o, a, "0", 6);
    try field(o, a, "0", 6);
    try field(o, a, "644", 8);
    var size: [10]u8 = undefined;
    try field(o, a, try std.fmt.bufPrint(&size, "{d}", .{data.len}), 10);
    try o.appendSlice(a, "`\n");
    try o.appendSlice(a, data);
    if (data.len & 1 == 1) try o.append(a, '\n');
}

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

fn hasFinding(r: A.Report, needle: []const u8) bool {
    for (r.findings) |f| if (std.mem.indexOf(u8, f, needle) != null) return true;
    return false;
}

test "members: names in file order, the symbol table skipped, a long name read from the table, an odd size padded" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o1 = try object(a, &.{.{ .name = "f", .kind = .def }}, &.{});
    const b = try archive(a, &.{
        .{ .name = "a.o", .data = o1 },
        .{ .name = "a_member_with_a_long_name.o", .data = "xyz" },
        .{ .name = "z.o", .data = o1 },
    });
    const ms = try A.members(a, b);
    try t.expectEqual(@as(usize, 3), ms.len);
    try t.expectEqualStrings("a.o", ms[0].name);
    try t.expectEqualStrings("a_member_with_a_long_name.o", ms[1].name);
    try t.expectEqualStrings("xyz", ms[1].data);
    try t.expectEqualStrings("z.o", ms[2].name);
    try t.expectEqualStrings("0", ms[2].time);
}

test "members: a file that is not an archive, a cut header, a cut body, a bad header and a BSD name are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectError(error.NotArchive, A.members(a, "not an archive"));
    const good = try archive(a, &.{.{ .name = "a.o", .data = "0123456789" }});
    try t.expectError(error.Truncated, A.members(a, good[0 .. good.len - 3]));
    try t.expectError(error.Truncated, A.members(a, good[0 .. good.len - 10 - 55]));
    // The magic is 8 bytes and the symbol table member 60 + 4: the header of "a.o" starts at 72.
    const h = 8 + 64;
    const bad = try a.dupe(u8, good);
    bad[8 + 58] = 'x';
    try t.expectError(error.BadHeader, A.members(a, bad));
    const bsd = try a.dupe(u8, good);
    @memcpy(bsd[h..][0..3], "#1/");
    try t.expectError(error.BadHeader, A.members(a, bsd));
    const size = try a.dupe(u8, good);
    @memcpy(size[h + 48 ..][0..3], "zzz");
    try t.expectError(error.BadHeader, A.members(a, size));
    const lname = try a.dupe(u8, good);
    @memcpy(lname[h..][0..4], "/999");
    try t.expectError(error.BadHeader, A.members(a, lname));
    const lbad = try a.dupe(u8, good);
    @memcpy(lbad[h..][0..3], "/zz");
    try t.expectError(error.BadHeader, A.members(a, lbad));
}

test "symbols: defined, undefined; a weak undefined, a local, and the null symbol are neither" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try object(a, &.{
        .{ .name = "mine", .kind = .def },
        .{ .name = "theirs", .kind = .undef },
        .{ .name = "maybe", .kind = .weak_undef },
        .{ .name = "hidden_local", .kind = .local },
    }, &.{});
    const s = try A.symbols(a, o);
    try t.expectEqual(@as(usize, 1), s.defined.len);
    try t.expectEqualStrings("mine", s.defined[0]);
    try t.expectEqual(@as(usize, 1), s.undef.len);
    try t.expectEqualStrings("theirs", s.undef[0]);
}

test "symbols: a section or file symbol and a nameless one are skipped; what is not a relocatable ELF is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try object(a, &.{ .{ .name = "sec", .kind = .def }, .{ .name = "file", .kind = .def }, .{ .name = "", .kind = .def }, .{ .name = "ok", .kind = .def } }, &.{});
    o[64 + 24 + 4] = (1 << 4) | 3; // the first symbol is a section symbol
    o[64 + 48 + 4] = (1 << 4) | 4; // the second is a file symbol
    const s = try A.symbols(a, o);
    try t.expectEqual(@as(usize, 1), s.defined.len);
    try t.expectEqualStrings("ok", s.defined[0]);
    try t.expectError(error.NotElf64, A.symbols(a, "plain text, not an object"));
    const exe = try a.dupe(u8, o);
    exe[0x10] = 2; // ET_EXEC
    try t.expectError(error.NotRelocatable, A.symbols(a, exe));
    try t.expectError(error.Truncated, A.symbols(a, o[0 .. o.len - 100]));
}

test "a clean library has no finding and lists its defined symbols sorted" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o1 = try object(a, &.{ .{ .name = "zeta", .kind = .def }, .{ .name = "memcpy", .kind = .undef } }, &.{".text"});
    const o2 = try object(a, &.{ .{ .name = "alpha", .kind = .def }, .{ .name = "zeta", .kind = .undef } }, &.{".text"});
    const b = try archive(a, &.{ .{ .name = "a.o", .data = o1 }, .{ .name = "b.o", .data = o2 } });
    const r = try A.check(a, "libx.a", b, .{});
    try t.expectEqual(@as(usize, 0), r.findings.len);
    try t.expectEqual(@as(usize, 2), r.defined.len);
    try t.expectEqualStrings("alpha", r.defined[0]);
    try t.expectEqualStrings("zeta", r.defined[1]);
}

test "an undefined symbol that nothing defines is named, once, however many members use it" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o1 = try object(a, &.{.{ .name = "shim_open_helper", .kind = .undef }}, &.{});
    const o2 = try object(a, &.{.{ .name = "shim_open_helper", .kind = .undef }}, &.{});
    const b = try archive(a, &.{ .{ .name = "a.o", .data = o1 }, .{ .name = "b.o", .data = o2 } });
    const r = try A.check(a, "libx.a", b, .{});
    try t.expectEqual(@as(usize, 1), r.findings.len);
    try t.expect(hasFinding(r, "undefined symbol: shim_open_helper"));
}

test "a symbol newer than the glibc floor is undefined here, and a needs library or an allow makes it known" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const user = try object(a, &.{.{ .name = "arc4random", .kind = .undef }}, &.{});
    const b = try archive(a, &.{.{ .name = "a.o", .data = user }});
    try t.expect(hasFinding(try A.check(a, "libx.a", b, .{}), "undefined symbol: arc4random"));
    const lib = try object(a, &.{.{ .name = "arc4random", .kind = .def }}, &.{});
    const needs = try archive(a, &.{.{ .name = "n.o", .data = lib }});
    try t.expectEqual(@as(usize, 0), (try A.check(a, "libx.a", b, .{ .needs = &.{needs} })).findings.len);
    try t.expectEqual(@as(usize, 0), (try A.check(a, "libx.a", b, .{ .allow = &.{"arc4random"} })).findings.len);
    // A needs archive that cannot be read defines nothing.
    try t.expect(hasFinding(try A.check(a, "libx.a", b, .{ .needs = &.{"junk"} }), "arc4random"));
}

test "a weak undefined symbol is not a finding" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try object(a, &.{.{ .name = "optional_hook", .kind = .weak_undef }}, &.{});
    const b = try archive(a, &.{.{ .name = "a.o", .data = o }});
    try t.expectEqual(@as(usize, 0), (try A.check(a, "libx.a", b, .{})).findings.len);
}

test "a time, owner or group in a member header is a finding" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try object(a, &.{.{ .name = "f", .kind = .def }}, &.{});
    const b = try archive(a, &.{.{ .name = "a.o", .data = o, .time = "1700000000" }});
    try t.expect(hasFinding(try A.check(a, "libx.a", b, .{}), "not deterministic"));
    const owner = try archive(a, &.{.{ .name = "a.o", .data = o }});
    const at = std.mem.indexOf(u8, owner, "a.o/").?;
    owner[at + 28] = '5'; // uid
    try t.expect(hasFinding(try A.check(a, "libx.a", owner, .{}), "not deterministic"));
    const group = try archive(a, &.{.{ .name = "a.o", .data = o }});
    group[std.mem.indexOf(u8, group, "a.o/").? + 34] = '5'; // gid
    try t.expect(hasFinding(try A.check(a, "libx.a", group, .{}), "not deterministic"));
}

test "members out of the order of their names are a finding; equal names are not" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try object(a, &.{.{ .name = "f", .kind = .def }}, &.{});
    const out = try archive(a, &.{ .{ .name = "b.o", .data = o }, .{ .name = "a.o", .data = o } });
    try t.expect(hasFinding(try A.check(a, "libx.a", out, .{}), "not in the order of their names"));
    const same = try archive(a, &.{ .{ .name = "a.o", .data = o }, .{ .name = "a.o", .data = o } });
    try t.expect(!hasFinding(try A.check(a, "libx.a", same, .{}), "order"));
}

test "a debug section is a finding, naming the member and the section" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try object(a, &.{.{ .name = "f", .kind = .def }}, &.{ ".text", ".debug_info" });
    const b = try archive(a, &.{.{ .name = "a.o", .data = o }});
    const r = try A.check(a, "libx.a", b, .{});
    try t.expect(hasFinding(r, "member a.o has 1 debug section(s), first .debug_info"));
}

test "the path of the build directory anywhere in the archive is a finding" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try object(a, &.{.{ .name = "/work/exec/root/f", .kind = .def }}, &.{});
    const b = try archive(a, &.{.{ .name = "a.o", .data = o }});
    try t.expect(hasFinding(try A.check(a, "libx.a", b, .{ .dir = "/work/exec/root" }), "absolute path of the directory it was built in (/work/exec/root)"));
    try t.expectEqual(@as(usize, 0), (try A.check(a, "libx.a", b, .{ .dir = "/elsewhere" })).findings.len);
}

test "an archive of no object, a member that is not an object, a file that is not an archive and a bad floor are findings" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const empty = try archive(a, &.{});
    try t.expect(hasFinding(try A.check(a, "libx.a", empty, .{}), "an empty library"));
    const text = try archive(a, &.{.{ .name = "a.o", .data = "just text" }});
    const r = try A.check(a, "libx.a", text, .{});
    try t.expect(hasFinding(r, "member a.o is not a 64-bit little-endian ELF or Mach-O object"));
    try t.expect(hasFinding(try A.check(a, "libx.a", "plain", .{}), "is not an archive of objects I can read: NotArchive"));
    const o = try object(a, &.{.{ .name = "f", .kind = .def }}, &.{});
    const b = try archive(a, &.{.{ .name = "a.o", .data = o }});
    try t.expect(hasFinding(try A.check(a, "libx.a", b, .{ .max_glibc = "two" }), "two is not a glibc version"));
    const exe = try a.dupe(u8, o);
    exe[0x10] = 2;
    const not_rel = try archive(a, &.{.{ .name = "a.o", .data = exe }});
    try t.expect(hasFinding(try A.check(a, "libx.a", not_rel, .{}), "is not a relocatable object: NotRelocatable"));
}

test "resultJson: the status and a message with a quote, a backslash and a newline" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"ok\"}}\n", try A.resultJson(a, true, "ok"));
    try t.expectEqualStrings("{\"version\": 1, \"data\": {\"status\": \"failure\", \"message\": \"a\\\"b\\\\c\\nd\"}}\n", try A.resultJson(a, false, "a\"b\\c\nd"));
}

test "parseArgs: the options, and the command lines that are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const c = (try A.parseArgs(a, &.{ "l.a", "r.json", "--needs", "n.a", "--allow", "sym", "--symbols", "s.txt", "--max-glibc", "2.31", "--needs", "m.a" })).?;
    try t.expectEqualStrings("l.a", c.archive);
    try t.expectEqualStrings("r.json", c.result);
    try t.expectEqual(@as(usize, 2), c.needs.len);
    try t.expectEqualStrings("sym", c.allow[0]);
    try t.expectEqualStrings("s.txt", c.symbols.?);
    try t.expectEqualStrings("2.31", c.max_glibc);
    try t.expect((try A.parseArgs(a, &.{"l.a"})) == null);
    try t.expect((try A.parseArgs(a, &.{ "l.a", "r.json", "--needs" })) == null);
    try t.expect((try A.parseArgs(a, &.{ "l.a", "r.json", "--other", "x" })) == null);
    const d = (try A.parseArgs(a, &.{ "l.a", "r.json" })).?;
    try t.expectEqualStrings("2.34", d.max_glibc);
}

test "run: exit 0 and a success result for a clean library, with the symbols written" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const o = try object(a, &.{ .{ .name = "shim_add", .kind = .def }, .{ .name = "memcpy", .kind = .undef } }, &.{});
    try tmp.dir.writeFile(.{ .sub_path = "libx.a", .data = try archive(a, &.{.{ .name = "a.o", .data = o }}) });
    var err = std.ArrayList(u8).empty;
    const code = try A.run(a, tmp.dir, "", &.{ "libx.a", "r.json", "--symbols", "s.txt" }, &err);
    try t.expectEqual(@as(u8, 0), code);
    const res = try tmp.dir.readFileAlloc(a, "r.json", 1 << 20);
    try t.expect(std.mem.indexOf(u8, res, "\"status\": \"success\"") != null);
    try t.expectEqualStrings("shim_add\n", try tmp.dir.readFileAlloc(a, "s.txt", 1 << 20));
    try t.expectEqual(@as(usize, 0), err.items.len);
}

test "run: exit 1, a failure result and every finding printed for a library with an undefined symbol" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const o = try object(a, &.{ .{ .name = "first_missing", .kind = .undef }, .{ .name = "second_missing", .kind = .undef } }, &.{});
    try tmp.dir.writeFile(.{ .sub_path = "libx.a", .data = try archive(a, &.{.{ .name = "a.o", .data = o }}) });
    var err = std.ArrayList(u8).empty;
    const code = try A.run(a, tmp.dir, "", &.{ "libx.a", "r.json" }, &err);
    try t.expectEqual(@as(u8, 1), code);
    const res = try tmp.dir.readFileAlloc(a, "r.json", 1 << 20);
    try t.expect(std.mem.indexOf(u8, res, "\"status\": \"failure\"") != null);
    try t.expect(std.mem.indexOf(u8, res, "first_missing") != null);
    try t.expect(std.mem.indexOf(u8, err.items, "undefined symbol: first_missing") != null);
    try t.expect(std.mem.indexOf(u8, err.items, "undefined symbol: second_missing") != null);
}

test "run: a needs archive satisfies the symbol; an unreadable archive or needs file and a bad command line exit 2" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const user = try object(a, &.{.{ .name = "base_value", .kind = .undef }}, &.{});
    const base = try object(a, &.{.{ .name = "base_value", .kind = .def }}, &.{});
    try tmp.dir.writeFile(.{ .sub_path = "libuser.a", .data = try archive(a, &.{.{ .name = "u.o", .data = user }}) });
    try tmp.dir.writeFile(.{ .sub_path = "libbase.a", .data = try archive(a, &.{.{ .name = "b.o", .data = base }}) });
    var err = std.ArrayList(u8).empty;
    try t.expectEqual(@as(u8, 1), try A.run(a, tmp.dir, "", &.{ "libuser.a", "r1.json" }, &err));
    try t.expectEqual(@as(u8, 0), try A.run(a, tmp.dir, "", &.{ "libuser.a", "r2.json", "--needs", "libbase.a" }, &err));
    err.clearRetainingCapacity();
    try t.expectEqual(@as(u8, 2), try A.run(a, tmp.dir, "", &.{ "missing.a", "r3.json" }, &err));
    try t.expect(std.mem.indexOf(u8, err.items, "cannot read missing.a") != null);
    err.clearRetainingCapacity();
    try t.expectEqual(@as(u8, 2), try A.run(a, tmp.dir, "", &.{ "libuser.a", "r4.json", "--needs", "missing.a" }, &err));
    try t.expect(std.mem.indexOf(u8, err.items, "cannot read missing.a") != null);
    err.clearRetainingCapacity();
    try t.expectEqual(@as(u8, 2), try A.run(a, tmp.dir, "", &.{"only_one"}, &err));
    try t.expect(std.mem.indexOf(u8, err.items, "usage: archive_check") != null);
}

test "an object or an archive cut at any length is read or refused, never trusted past its end" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try object(a, &.{ .{ .name = "f", .kind = .def }, .{ .name = "g", .kind = .undef }, .{ .name = "w", .kind = .weak_undef } }, &.{ ".text", ".debug_line" });
    var refused: usize = 0;
    var n: usize = 0;
    while (n < o.len) : (n += 1) {
        if (A.symbols(a, o[0..n])) |_| {} else |_| refused += 1;
    }
    try t.expect(refused > o.len / 2);
    const b = try archive(a, &.{ .{ .name = "a.o", .data = o }, .{ .name = "a_member_with_a_long_name.o", .data = o } });
    refused = 0;
    n = 0;
    while (n < b.len) : (n += 1) {
        if (A.members(a, b[0..n])) |_| {} else |_| refused += 1;
        const r = try A.check(a, "libx.a", b[0..n], .{});
        // Whatever the cut, the verdict is a finding or a clean library; a cut archive is never a clean one with objects it did not read.
        if (n < 8) try t.expect(r.findings.len != 0);
    }
    try t.expect(refused > 0);
}

/// `ctx.call(allocator)` with every allocation failing in turn: each is `OutOfMemory`, nothing else, until one runs through with no allocation failed.
fn sweepOom(ctx: anytype) !void {
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        var fa = t.FailingAllocator.init(t.allocator, .{ .fail_index = i });
        var ar = std.heap.ArenaAllocator.init(fa.allocator());
        defer ar.deinit();
        ctx.call(ar.allocator()) catch |e| {
            try t.expectEqual(error.OutOfMemory, e);
            continue;
        };
        try t.expect(!fa.has_induced_failure);
        return;
    }
    return error.SweepDidNotEnd;
}

const CheckCall = struct {
    archive: []const u8,
    needs: []const []const u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !void {
        _ = try A.check(a, "libx.a", self.archive, .{ .needs = self.needs, .allow = &.{"allowed_one"}, .dir = "/work/dir" });
    }
};

test "check: every allocation failing in turn is an error, for a clean library and for one with every kind of finding" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const base = try object(a, &.{.{ .name = "base_value", .kind = .def }}, &.{});
    const needs = try archive(a, &.{.{ .name = "b.o", .data = base }});
    const clean = try object(a, &.{ .{ .name = "f", .kind = .def }, .{ .name = "g", .kind = .def }, .{ .name = "memcpy", .kind = .undef }, .{ .name = "base_value", .kind = .undef }, .{ .name = "allowed_one", .kind = .undef } }, &.{".text"});
    const bad = try object(a, &.{ .{ .name = "h", .kind = .def }, .{ .name = "missing_one", .kind = .undef }, .{ .name = "missing_two", .kind = .undef } }, &.{".debug_info"});
    try sweepOom(CheckCall{ .archive = try archive(a, &.{ .{ .name = "a.o", .data = clean }, .{ .name = "b.o", .data = clean } }), .needs = &.{needs} });
    try sweepOom(CheckCall{ .archive = try archive(a, &.{ .{ .name = "b.o", .data = bad, .time = "5" }, .{ .name = "a.o", .data = "text" }, .{ .name = "c.o", .data = bad } }), .needs = &.{ needs, "junk" } });
    try sweepOom(CheckCall{ .archive = "not an archive", .needs = &.{} });
    try sweepOom(CheckCall{ .archive = try archive(a, &.{}), .needs = &.{} });
}

const RunCall = struct {
    dir: std.fs.Dir,
    args: []const []const u8,
    want: u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !void {
        var err = std.ArrayList(u8).empty;
        const code = try A.run(a, self.dir, "", self.args, &err);
        try t.expectEqual(self.want, code);
    }
};

test "run and parseArgs: every allocation failing in turn is an error, on every path out of run" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const good = try object(a, &.{.{ .name = "f", .kind = .def }}, &.{});
    const bad = try object(a, &.{.{ .name = "missing_one", .kind = .undef }}, &.{});
    try tmp.dir.writeFile(.{ .sub_path = "good.a", .data = try archive(a, &.{.{ .name = "a.o", .data = good }}) });
    try tmp.dir.writeFile(.{ .sub_path = "bad.a", .data = try archive(a, &.{.{ .name = "a.o", .data = bad }}) });
    try sweepOom(RunCall{ .dir = tmp.dir, .args = &.{ "good.a", "r1.json", "--symbols", "s.txt", "--needs", "bad.a", "--allow", "x", "--max-glibc", "2.34" }, .want = 0 });
    try sweepOom(RunCall{ .dir = tmp.dir, .args = &.{ "bad.a", "r2.json" }, .want = 1 });
    try sweepOom(RunCall{ .dir = tmp.dir, .args = &.{ "missing.a", "r3.json" }, .want = 2 });
    try sweepOom(RunCall{ .dir = tmp.dir, .args = &.{ "good.a", "r4.json", "--needs", "missing.a" }, .want = 2 });
    try sweepOom(RunCall{ .dir = tmp.dir, .args = &.{"good.a"}, .want = 2 });
    const Json = struct {
        pub fn call(_: @This(), x: std.mem.Allocator) !void {
            _ = try A.resultJson(x, false, "a\"b\\c\nd");
        }
    };
    try sweepOom(Json{});
}

/// `obj` (made with one extra section named `version`) with that section made a SHT_GNU_verneed that needs the version of that name from a
/// library; the name is in `.shstrtab`, which the section links to, so the object needs no string table of its own for it.
fn withVerneed(a: std.mem.Allocator, obj: []const u8, version: []const u8) ![]u8 {
    const sh_off: usize = @intCast(std.mem.readInt(u64, obj[0x28..][0..8], .little));
    const shstr_off: usize = @intCast(std.mem.readInt(u64, obj[sh_off + 3 * 64 + 0x18 ..][0..8], .little));
    const name_at = std.mem.indexOf(u8, obj[shstr_off..sh_off], version).?;
    const b = try a.alloc(u8, obj.len + 32);
    @memcpy(b[0..obj.len], obj);
    @memset(b[obj.len..], 0);
    const vn = obj.len;
    std.mem.writeInt(u16, b[vn + 2 ..][0..2], 1, .little); // one Vernaux
    std.mem.writeInt(u32, b[vn + 8 ..][0..4], 16, .little); // at 16 bytes from the Verneed
    std.mem.writeInt(u32, b[vn + 16 + 8 ..][0..4], @intCast(name_at), .little); // vna_name
    const sh = sh_off + 4 * 64;
    std.mem.writeInt(u32, b[sh + 4 ..][0..4], 0x6ffffffe, .little);
    std.mem.writeInt(u64, b[sh + 0x18 ..][0..8], vn, .little);
    std.mem.writeInt(u32, b[sh + 0x28 ..][0..4], 3, .little);
    std.mem.writeInt(u32, b[sh + 0x2C ..][0..4], 1, .little);
    return b;
}

test "a member that needs a glibc version newer than the floor is a finding naming it; at the floor or under it, none" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try withVerneed(a, try object(a, &.{.{ .name = "f", .kind = .def }}, &.{"GLIBC_2.38"}), "GLIBC_2.38");
    const lib = try archive(a, &.{.{ .name = "a.o", .data = o }});
    const over = try A.check(a, "libx.a", lib, .{});
    try t.expectEqual(@as(usize, 1), over.findings.len);
    try t.expect(hasFinding(over, "libx.a: member a.o needs GLIBC_2.38, newer than the floor 2.34"));
    try t.expectEqual(@as(usize, 0), (try A.check(a, "libx.a", lib, .{ .max_glibc = "2.38" })).findings.len);
    try t.expectEqual(@as(usize, 0), (try A.check(a, "libx.a", lib, .{ .max_glibc = "2.39" })).findings.len);
    // A floor that is not a version is its own finding, and compares with nothing.
    const bad = try A.check(a, "libx.a", lib, .{ .max_glibc = "newest" });
    try t.expectEqual(@as(usize, 1), bad.findings.len);
    try t.expect(hasFinding(bad, "newest is not a glibc version"));
}

test "symbols: a symbol table or a string table that runs past the end of the file is refused, whichever it is" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try object(a, &.{.{ .name = "f", .kind = .def }}, &.{});
    const sh_off: usize = @intCast(std.mem.readInt(u64, o[0x28..][0..8], .little));
    const symtab = sh_off + 1 * 64;
    const strtab = sh_off + 2 * 64;
    const cases = [_]struct { at: usize, value: u64 }{
        .{ .at = strtab + 0x18, .value = o.len + 10 }, // the string table starts past the end
        .{ .at = strtab + 0x20, .value = o.len }, // it starts inside and is longer than what is left
        .{ .at = symtab + 0x18, .value = o.len + 10 }, // the symbol table starts past the end
        .{ .at = symtab + 0x20, .value = o.len }, // it starts inside and is longer than what is left
    };
    for (cases) |c| {
        const cut = try a.dupe(u8, o);
        std.mem.writeInt(u64, cut[c.at..][0..8], c.value, .little);
        try t.expectError(error.Truncated, A.symbols(a, cut));
    }
}

// ---- a renamed library (`prefix`, `min_prefixed`, `original`): the checks of `native_static(prefix = ...)` ------------------------------------------------------

test "prefix: a library whose every defined symbol starts with the prefix, with the C library undefined, has no finding" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try object(a, &.{ .{ .name = "k_open", .kind = .def }, .{ .name = "k_close", .kind = .def }, .{ .name = "memcpy", .kind = .undef } }, &.{});
    const b = try archive(a, &.{.{ .name = "a.o", .data = o }});
    const r = try A.check(a, "libx.a", b, .{ .prefix = "k_", .min_prefixed = 2, .original = &.{ "open", "close" } });
    try t.expectEqual(@as(usize, 0), r.findings.len);
}

test "prefix: a defined symbol without it is a finding that names it; the same library with no prefix asked for is clean" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try object(a, &.{ .{ .name = "k_open", .kind = .def }, .{ .name = "leaked", .kind = .def } }, &.{});
    const b = try archive(a, &.{.{ .name = "a.o", .data = o }});
    const r = try A.check(a, "libx.a", b, .{ .prefix = "k_" });
    try t.expectEqual(@as(usize, 1), r.findings.len);
    try t.expect(hasFinding(r, "1 defined symbol(s) without the prefix k_: leaked"));
    try t.expectEqual(@as(usize, 0), (try A.check(a, "libx.a", b, .{})).findings.len);
}

test "prefix: a long list of defined symbols without the prefix is cut after twenty names" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var syms = std.ArrayList(Sym).empty;
    for (0..25) |i| try syms.append(a, .{ .name = try std.fmt.allocPrint(a, "bare_{d:0>2}", .{i}), .kind = .def });
    const b = try archive(a, &.{.{ .name = "a.o", .data = try object(a, syms.items, &.{}) }});
    const r = try A.check(a, "libx.a", b, .{ .prefix = "k_" });
    try t.expectEqual(@as(usize, 1), r.findings.len);
    try t.expect(hasFinding(r, "25 defined symbol(s) without the prefix k_: bare_00"));
    try t.expect(hasFinding(r, "bare_19 ..."));
    try t.expect(!hasFinding(r, "bare_20"));
    // Exactly twenty are listed whole, with no ellipsis.
    const twenty = try archive(a, &.{.{ .name = "a.o", .data = try object(a, syms.items[0..20], &.{}) }});
    const r20 = try A.check(a, "libx.a", twenty, .{ .prefix = "k_" });
    try t.expect(hasFinding(r20, "bare_19"));
    try t.expect(!hasFinding(r20, "..."));
}

test "prefix: fewer prefixed symbols than the minimum is a finding, at the minimum it is not" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try object(a, &.{ .{ .name = "k_one", .kind = .def }, .{ .name = "k_two", .kind = .def } }, &.{});
    const b = try archive(a, &.{.{ .name = "a.o", .data = o }});
    try t.expectEqual(@as(usize, 0), (try A.check(a, "libx.a", b, .{ .prefix = "k_", .min_prefixed = 2 })).findings.len);
    const r = try A.check(a, "libx.a", b, .{ .prefix = "k_", .min_prefixed = 3 });
    try t.expectEqual(@as(usize, 1), r.findings.len);
    try t.expect(hasFinding(r, "only 2 defined symbol(s) start with the prefix k_ (at least 3 expected)"));
}

test "prefix: an undefined reference to a name the renaming replaced is a finding, once, from either member; other undefined names are not" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o1 = try object(a, &.{ .{ .name = "k_use", .kind = .def }, .{ .name = "lib_open", .kind = .undef }, .{ .name = "memcpy", .kind = .undef } }, &.{});
    const o2 = try object(a, &.{ .{ .name = "k_use2", .kind = .def }, .{ .name = "lib_open", .kind = .undef } }, &.{});
    const b = try archive(a, &.{ .{ .name = "a.o", .data = o1 }, .{ .name = "b.o", .data = o2 } });
    const r = try A.check(a, "libx.a", b, .{ .prefix = "k_", .original = &.{ "lib_open", "lib_close" }, .allow = &.{"lib_open"} });
    try t.expectEqual(@as(usize, 1), r.findings.len);
    try t.expect(hasFinding(r, "undefined reference to lib_open, a name the prefix header renames"));
    // Without the names, the reference is only an undefined symbol (here allowed): the rule needs them.
    try t.expectEqual(@as(usize, 0), (try A.check(a, "libx.a", b, .{ .prefix = "k_", .allow = &.{"lib_open"} })).findings.len);
}

test "parseArgs: --prefix, --min-prefixed and --original, and the combinations that are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const c = (try A.parseArgs(a, &.{ "l.a", "r.json", "--prefix", "k_", "--min-prefixed", "200", "--original", "n1.txt", "--original", "n2.txt" })).?;
    try t.expectEqualStrings("k_", c.prefix);
    try t.expectEqual(@as(usize, 200), c.min_prefixed);
    try t.expectEqual(@as(usize, 2), c.original.len);
    try t.expectEqualStrings("n2.txt", c.original[1]);
    const d = (try A.parseArgs(a, &.{ "l.a", "r.json" })).?;
    try t.expectEqualStrings("", d.prefix);
    try t.expectEqual(@as(usize, 0), d.min_prefixed);
    try t.expectEqual(@as(usize, 0), d.original.len);
    try t.expect((try A.parseArgs(a, &.{ "l.a", "r.json", "--prefix", "" })) == null);
    try t.expect((try A.parseArgs(a, &.{ "l.a", "r.json", "--prefix", "k_", "--min-prefixed", "many" })) == null);
    try t.expect((try A.parseArgs(a, &.{ "l.a", "r.json", "--min-prefixed", "3" })) == null);
    try t.expect((try A.parseArgs(a, &.{ "l.a", "r.json", "--original", "n.txt" })) == null);
}

test "run: --prefix with a names file is green for a renamed library and red, with the findings printed, for one the renaming missed" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const good = try object(a, &.{ .{ .name = "k_open", .kind = .def }, .{ .name = "memcpy", .kind = .undef } }, &.{});
    const bad = try object(a, &.{ .{ .name = "k_open", .kind = .def }, .{ .name = "open", .kind = .def }, .{ .name = "close", .kind = .undef } }, &.{});
    try tmp.dir.writeFile(.{ .sub_path = "good.a", .data = try archive(a, &.{.{ .name = "a.o", .data = good }}) });
    try tmp.dir.writeFile(.{ .sub_path = "bad.a", .data = try archive(a, &.{.{ .name = "a.o", .data = bad }}) });
    try tmp.dir.writeFile(.{ .sub_path = "names.txt", .data = "open\r\n\nclose\n" });
    var err = std.ArrayList(u8).empty;
    try t.expectEqual(@as(u8, 0), try A.run(a, tmp.dir, "", &.{ "good.a", "r1.json", "--prefix", "k_", "--min-prefixed", "1", "--original", "names.txt" }, &err));
    try t.expectEqual(@as(usize, 0), err.items.len);
    // The defined `open` lacks the prefix, and the undefined `close` is a name the header renames.
    try t.expectEqual(@as(u8, 1), try A.run(a, tmp.dir, "", &.{ "bad.a", "r2.json", "--prefix", "k_", "--original", "names.txt" }, &err));
    try t.expect(std.mem.indexOf(u8, err.items, "defined symbol(s) without the prefix k_: open") != null);
    try t.expect(std.mem.indexOf(u8, err.items, "undefined reference to close, a name the prefix header renames") != null);
    err.clearRetainingCapacity();
    try t.expectEqual(@as(u8, 2), try A.run(a, tmp.dir, "", &.{ "good.a", "r3.json", "--prefix", "k_", "--original", "missing.txt" }, &err));
    try t.expect(std.mem.indexOf(u8, err.items, "cannot read missing.txt") != null);
}

test "run and check with a prefix: every allocation failing in turn is an error" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const bad = try object(a, &.{ .{ .name = "k_open", .kind = .def }, .{ .name = "open", .kind = .def }, .{ .name = "close", .kind = .undef } }, &.{});
    const b = try archive(a, &.{.{ .name = "a.o", .data = bad }});
    try tmp.dir.writeFile(.{ .sub_path = "bad.a", .data = b });
    try tmp.dir.writeFile(.{ .sub_path = "names.txt", .data = "open\nclose\n" });
    const Pref = struct {
        archive: []const u8,
        pub fn call(self: @This(), x: std.mem.Allocator) !void {
            _ = try A.check(x, "libx.a", self.archive, .{ .prefix = "k_", .min_prefixed = 5, .original = &.{ "open", "close" }, .allow = &.{"close"} });
        }
    };
    try sweepOom(Pref{ .archive = b });
    try sweepOom(RunCall{ .dir = tmp.dir, .args = &.{ "bad.a", "r.json", "--prefix", "k_", "--original", "names.txt" }, .want = 1 });
}

// ---- a C++ library (`runtime_cxx`, `--runtime c++`): the runtime the final link brings -------------------------------------------------------------------------

test "runtime c++: the names of the C++ runtime may stay undefined, any other may not, and without the option none may" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const runtime = [_][]const u8{ "_ZNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEE6appendEPKc", "_ZNKSt3__16locale2idEv", "_ZSt9terminatev", "_Znwm", "_Znam", "_ZdlPv", "_ZdaPv", "__cxa_atexit", "__gxx_personality_v0", "__dynamic_cast", "_Unwind_Resume", "__dso_handle", "_ZTVN10__cxxabiv117__class_type_infoE", "_ZTISt9exception" };
    var syms = std.ArrayList(Sym).empty;
    for (runtime) |n| try syms.append(a, .{ .name = n, .kind = .undef });
    try syms.append(a, .{ .name = "cxx_entry", .kind = .def });
    const b = try archive(a, &.{.{ .name = "a.o", .data = try object(a, syms.items, &.{}) }});
    const with = try A.check(a, "libx.a", b, .{ .runtime_cxx = true });
    try t.expectEqual(@as(usize, 0), with.findings.len);
    const without = try A.check(a, "libx.a", b, .{});
    // `__cxa_atexit` is in the C library list already, so it is not a finding either way.
    try t.expectEqual(runtime.len - 1, without.findings.len);
    // A name that is not the runtime's is still named, and so is a C++ name of the program's own namespace.
    const other = try object(a, &.{ .{ .name = "_ZN3app5helpEv", .kind = .undef }, .{ .name = "missing_c_helper", .kind = .undef }, .{ .name = "__cxa_atexit", .kind = .undef } }, &.{});
    const bo = try archive(a, &.{.{ .name = "a.o", .data = other }});
    const r = try A.check(a, "libx.a", bo, .{ .runtime_cxx = true });
    try t.expectEqual(@as(usize, 2), r.findings.len);
    try t.expect(hasFinding(r, "undefined symbol: _ZN3app5helpEv"));
    try t.expect(hasFinding(r, "undefined symbol: missing_c_helper"));
}

test "runtime c++: cxxRuntime tells the runtime's prefixes from a near miss" {
    for ([_][]const u8{ "_ZNSt3__1foo", "_ZNKSt3foo", "_ZSt4cout", "_ZTVSt9bad_alloc", "_Znwm", "_ZdlPvm", "__cxa_throw", "__gxx_personality_v0", "_Unwind_RaiseException", "__dso_handle" }) |n| try t.expect(A.cxxRuntime(n));
    for ([_][]const u8{ "_ZN3app3fooEv", "_Z3foov", "cxa_atexit", "__cx", "memcpy", "" }) |n| try t.expect(!A.cxxRuntime(n));
}

test "runtime c++: parseArgs takes only c++, and run honours it" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expect((try A.parseArgs(a, &.{ "l.a", "r.json", "--runtime", "c++" })).?.runtime_cxx);
    try t.expect(!(try A.parseArgs(a, &.{ "l.a", "r.json" })).?.runtime_cxx);
    try t.expect((try A.parseArgs(a, &.{ "l.a", "r.json", "--runtime", "rust" })) == null);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const o = try object(a, &.{ .{ .name = "cxx_entry", .kind = .def }, .{ .name = "_Znwm", .kind = .undef } }, &.{});
    try tmp.dir.writeFile(.{ .sub_path = "libx.a", .data = try archive(a, &.{.{ .name = "a.o", .data = o }}) });
    var err = std.ArrayList(u8).empty;
    try t.expectEqual(@as(u8, 1), try A.run(a, tmp.dir, "", &.{ "libx.a", "r1.json" }, &err));
    try t.expect(std.mem.indexOf(u8, err.items, "undefined symbol: _Znwm") != null);
    err.clearRetainingCapacity();
    try t.expectEqual(@as(u8, 0), try A.run(a, tmp.dir, "", &.{ "libx.a", "r2.json", "--runtime", "c++" }, &err));
    try t.expectEqual(@as(usize, 0), err.items.len);
}

test "prefix: the compiler's 128-bit builtins a library defines itself do not count against the prefix, any other bare name does" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try object(a, &.{ .{ .name = "k_one", .kind = .def }, .{ .name = "__umodti3", .kind = .def }, .{ .name = "__udivti3", .kind = .def }, .{ .name = "__divti3", .kind = .def }, .{ .name = "__modti3", .kind = .def }, .{ .name = "__multi3", .kind = .def }, .{ .name = "__udivmodti4", .kind = .def }, .{ .name = "__ashlti3", .kind = .def }, .{ .name = "__ashrti3", .kind = .def }, .{ .name = "__lshrti3", .kind = .def } }, &.{});
    const b = try archive(a, &.{.{ .name = "a.o", .data = o }});
    const r = try A.check(a, "libx.a", b, .{ .prefix = "k_", .min_prefixed = 1 });
    try t.expectEqual(@as(usize, 0), r.findings.len);
    // They are not counted as prefixed either, and a near miss is a finding.
    try t.expect(hasFinding(try A.check(a, "libx.a", b, .{ .prefix = "k_", .min_prefixed = 2 }), "only 1 defined symbol(s)"));
    const near = try object(a, &.{ .{ .name = "k_one", .kind = .def }, .{ .name = "__umodti4", .kind = .def } }, &.{});
    try t.expect(hasFinding(try A.check(a, "libx.a", try archive(a, &.{.{ .name = "a.o", .data = near }}), .{ .prefix = "k_" }), "without the prefix k_: __umodti4"));
    try t.expect(A.compilerBuiltin("__umodti3") and !A.compilerBuiltin("__umodti4") and !A.compilerBuiltin("memcpy"));
}

test "the C library list at the floor holds the names aws-lc needs, and the macOS list the one it calls" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const elf = try object(a, &.{ .{ .name = "fopen64", .kind = .undef }, .{ .name = "__isoc99_sscanf", .kind = .undef }, .{ .name = "getauxval", .kind = .undef }, .{ .name = "sdallocx", .kind = .undef } }, &.{});
    try t.expectEqual(@as(usize, 0), (try A.check(a, "libx.a", try archive(a, &.{.{ .name = "a.o", .data = elf }}), .{})).findings.len);
}

test "--members any: members out of the order of their names are not a finding, and the other rules still hold" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const o = try object(a, &.{.{ .name = "f", .kind = .def }}, &.{});
    const out = try archive(a, &.{ .{ .name = "b.o", .data = o }, .{ .name = "a.o", .data = o } });
    try t.expect(!hasFinding(try A.check(a, "libx.a", out, .{ .any_order = true }), "order"));
    try t.expect(hasFinding(try A.check(a, "libx.a", out, .{ .any_order = false }), "not in the order of their names"));
    // A member that records a time is still a finding, whatever the order.
    const stamped = try archive(a, &.{ .{ .name = "b.o", .data = o, .time = "1700000000" }, .{ .name = "a.o", .data = o } });
    try t.expect(hasFinding(try A.check(a, "libx.a", stamped, .{ .any_order = true }), "not deterministic"));
}

test "parseArgs: --members takes any and nothing else" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expect((try A.parseArgs(a, &.{ "l.a", "r.json", "--members", "any" })).?.any_order);
    try t.expect(!(try A.parseArgs(a, &.{ "l.a", "r.json" })).?.any_order);
    try t.expect((try A.parseArgs(a, &.{ "l.a", "r.json", "--members", "name" })) == null);
    try t.expect((try A.parseArgs(a, &.{ "l.a", "r.json", "--members" })) == null);
}

