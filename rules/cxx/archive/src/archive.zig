//! archive_check: the validation of a native static library (`native_archive`, rules/cxx/native.bzl).
//!
//!   archive_check <lib.a> <result.json> [--needs <lib.a>]... [--allow <symbol>]... [--symbols <out.txt>] [--max-glibc <x.y>]
//!
//! A static library a Mojo package ships is linked into other people's programs, so it is held to what a library must be:
//!
//!  - an archive of 64-bit little-endian ELF relocatable objects, nothing else;
//!  - deterministic: every member header has time, owner and group 0, and the members are in the order of their names;
//!  - hermetic: no object has a `.debug_*` section and no byte of the archive holds the absolute path of the directory it was built in
//!    (`hermetic.zig`, the check of the C++ rules, applied to each member);
//!  - at the glibc floor: no object needs a glibc symbol version newer than `--max-glibc` (`floor.zig`, applied to each member). A relocatable
//!    object records no version of its own, so the floor of an archive is mostly held by the next rule;
//!  - closed: every undefined global symbol is defined by the archive itself, by a `--needs` archive, by the C library at the floor or by the
//!    compiler runtime (`floor_symbols.txt`), or is named by an `--allow`. A weak undefined symbol resolves to zero and is not a defect.
//!    Whatever else is undefined is named: it is a symbol the final link will not find.
//!
//! Writes a validation result (`{"version":1,"data":{"status",...}}`) and exits 0 when every rule holds; exits 1 after writing "failure" when
//! one does not, and prints every finding. With `--symbols`, writes the sorted defined global symbols, one per line.

const std = @import("std");
const hermetic = @import("cxx_hermetic");
const floor = @import("cxx_floor");

pub const floor_symbols = @embedFile("floor_symbols.txt");

pub const Error = error{ NotArchive, Truncated, BadHeader, NotElf64, NotRelocatable };

pub const Member = struct {
    name: []const u8,
    data: []const u8,
    time: []const u8,
    owner: []const u8,
    group: []const u8,
};

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " ");
}

/// The object members of an `ar` archive, in file order. The symbol table (`/`, `/SYM64/`) and the long-name table (`//`) are not members.
/// BSD-style names (`#1/N`) are refused: the C++ toolchain writes the GNU format.
pub fn members(a: std.mem.Allocator, b: []const u8) (Error || std.mem.Allocator.Error)![]const Member {
    if (!std.mem.startsWith(u8, b, "!<arch>\n")) return error.NotArchive;
    var out = std.ArrayList(Member).empty;
    var long: []const u8 = "";
    var off: usize = 8;
    while (off < b.len) {
        if (b.len - off < 60) return error.Truncated;
        const h = b[off..][0..60];
        if (h[58] != '`' or h[59] != '\n') return error.BadHeader;
        const size = std.fmt.parseInt(usize, trim(h[48..58]), 10) catch return error.BadHeader;
        const start = off + 60;
        if (b.len - start < size) return error.Truncated;
        const data = b[start..][0..size];
        off = start + size;
        if (size & 1 == 1 and off < b.len) off += 1;
        const raw = trim(h[0..16]);
        if (std.mem.eql(u8, raw, "/") or std.mem.eql(u8, raw, "/SYM64/")) continue;
        if (std.mem.eql(u8, raw, "//")) {
            long = data;
            continue;
        }
        var name = raw;
        if (raw.len > 1 and raw[0] == '/') {
            const at = std.fmt.parseInt(usize, raw[1..], 10) catch return error.BadHeader;
            if (at >= long.len) return error.BadHeader;
            const end = std.mem.indexOfScalarPos(u8, long, at, '\n') orelse long.len;
            name = std.mem.trimRight(u8, long[at..end], "/");
        } else if (std.mem.startsWith(u8, raw, "#1/")) {
            return error.BadHeader;
        } else {
            name = std.mem.trimRight(u8, raw, "/");
        }
        try out.append(a, .{ .name = name, .data = data, .time = trim(h[16..28]), .owner = trim(h[28..34]), .group = trim(h[34..40]) });
    }
    return out.toOwnedSlice(a);
}

fn rd(comptime T: type, b: []const u8, off: usize) Error!T {
    const n = @sizeOf(T);
    if (off > b.len or b.len - off < n) return error.Truncated;
    return std.mem.readInt(T, b[off..][0..n], .little);
}

pub const Syms = struct {
    /// Defined global and weak symbols.
    defined: []const []const u8,
    /// Undefined global symbols (a weak undefined one is not listed: it resolves to zero).
    undef: []const []const u8,
};

/// The global symbols of one relocatable ELF64 little-endian object, from its `.symtab`.
pub fn symbols(a: std.mem.Allocator, b: []const u8) (Error || std.mem.Allocator.Error)!Syms {
    if (b.len < 64 or !std.mem.eql(u8, b[0..4], "\x7fELF") or b[4] != 2 or b[5] != 1) return error.NotElf64;
    if (try rd(u16, b, 0x10) != 1) return error.NotRelocatable;
    const shoff: usize = @intCast(try rd(u64, b, 0x28));
    const shentsize: usize = try rd(u16, b, 0x3A);
    const shnum: usize = try rd(u16, b, 0x3C);
    var def = std.ArrayList([]const u8).empty;
    var und = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < shnum) : (i += 1) {
        const sh = shoff + i * shentsize;
        if (try rd(u32, b, sh + 4) != 2) continue; // SHT_SYMTAB
        const off: usize = @intCast(try rd(u64, b, sh + 0x18));
        const size: usize = @intCast(try rd(u64, b, sh + 0x20));
        const link: usize = @intCast(try rd(u32, b, sh + 0x28));
        const str_sh = shoff + link * shentsize;
        const str_off: usize = @intCast(try rd(u64, b, str_sh + 0x18));
        const str_size: usize = @intCast(try rd(u64, b, str_sh + 0x20));
        if (str_off > b.len or b.len - str_off < str_size) return error.Truncated;
        if (off > b.len or b.len - off < size) return error.Truncated;
        const strs = b[str_off .. str_off + str_size];
        var k: usize = 1;
        while ((k + 1) * 24 <= size) : (k += 1) {
            const at = off + k * 24;
            const info = b[at + 4];
            const bind = info >> 4;
            const typ = info & 0xf;
            if (bind == 0 or typ == 3 or typ == 4) continue; // local, section, file
            const name_off: usize = try rd(u32, b, at);
            if (name_off >= strs.len) continue;
            const name = std.mem.sliceTo(strs[name_off..], 0);
            if (name.len == 0) continue;
            const shndx = try rd(u16, b, at + 6);
            if (shndx != 0) {
                try def.append(a, name);
            } else if (bind != 2) {
                try und.append(a, name);
            }
        }
    }
    return .{ .defined = try def.toOwnedSlice(a), .undef = try und.toOwnedSlice(a) };
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

pub const Options = struct {
    /// The archives of the libraries this one needs (`needs`): what they define may be left undefined here.
    needs: []const []const u8 = &.{},
    /// Symbols the author names as provided by something the check cannot see.
    allow: []const []const u8 = &.{},
    max_glibc: []const u8 = "2.34",
    /// The absolute path of the directory the archive was built in ("" skips the test: a unit test has none).
    dir: []const u8 = "",
};

pub const Report = struct {
    findings: []const []const u8,
    /// The sorted defined global symbols of the archive.
    defined: []const []const u8,
};

/// Every finding about the archive `b` (named `name` in messages), empty when it is as a native library must be.
pub fn check(a: std.mem.Allocator, name: []const u8, b: []const u8, o: Options) std.mem.Allocator.Error!Report {
    var f = std.ArrayList([]const u8).empty;
    const none = Report{ .findings = &.{}, .defined = &.{} };
    const ms = members(a, b) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        try f.append(a, try std.fmt.allocPrint(a, "{s} is not an archive of objects I can read: {s}", .{ name, @errorName(e) }));
        return .{ .findings = try f.toOwnedSlice(a), .defined = none.defined };
    };
    if (ms.len == 0) try f.append(a, try std.fmt.allocPrint(a, "{s} has no object: an empty library", .{name}));
    const max = floor.Version.parse(o.max_glibc);
    if (max == null) try f.append(a, try std.fmt.allocPrint(a, "{s} is not a glibc version", .{o.max_glibc}));

    var defined = std.StringHashMap(void).init(a);
    var undef = std.ArrayList([]const u8).empty;
    var prev: []const u8 = "";
    for (ms) |m| {
        if (!std.mem.eql(u8, m.time, "0") or !std.mem.eql(u8, m.owner, "0") or !std.mem.eql(u8, m.group, "0"))
            try f.append(a, try std.fmt.allocPrint(a, "{s}: member {s} records a time or an owner (time {s}, owner {s}, group {s}): the archive is not deterministic", .{ name, m.name, m.time, m.owner, m.group }));
        if (prev.len != 0 and std.mem.lessThan(u8, m.name, prev))
            try f.append(a, try std.fmt.allocPrint(a, "{s}: member {s} comes after {s}: the members are not in the order of their names", .{ name, m.name, prev }));
        prev = m.name;
        const dbg = hermetic.debugSections(a, m.data) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            try f.append(a, try std.fmt.allocPrint(a, "{s}: member {s} is not a 64-bit little-endian ELF object: {s}", .{ name, m.name, @errorName(e) }));
            continue;
        };
        if (dbg.len != 0)
            try f.append(a, try std.fmt.allocPrint(a, "{s}: member {s} has {d} debug section(s), first {s}: the compile directory is in them (compile with -g0)", .{ name, m.name, dbg.len, dbg[0] }));
        if (floor.newest(m.data)) |v| {
            if (v != null and max != null and floor.Version.order(v.?, max.?) == .gt)
                try f.append(a, try std.fmt.allocPrint(a, "{s}: member {s} needs GLIBC_{d}.{d}, newer than the floor {s}", .{ name, m.name, v.?.major, v.?.minor, o.max_glibc }));
        } else |_| {}
        const s = symbols(a, m.data) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            try f.append(a, try std.fmt.allocPrint(a, "{s}: member {s} is not a relocatable object: {s}", .{ name, m.name, @errorName(e) }));
            continue;
        };
        for (s.defined) |d| try defined.put(d, {});
        for (s.undef) |u| try undef.append(a, u);
    }
    if (o.dir.len != 0 and hermetic.mentions(b, o.dir))
        try f.append(a, try std.fmt.allocPrint(a, "{s} contains the absolute path of the directory it was built in ({s})", .{ name, o.dir }));

    // What the library may leave to the final link.
    var known = std.StringHashMap(void).init(a);
    var lines = std.mem.splitScalar(u8, floor_symbols, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \r");
        if (t.len != 0 and t[0] != '#') try known.put(t, {});
    }
    for (o.allow) |s| try known.put(s, {});
    for (o.needs) |nb| {
        const nms = members(a, nb) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            continue;
        };
        for (nms) |m| {
            const s = symbols(a, m.data) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                continue;
            };
            for (s.defined) |d| try known.put(d, {});
        }
    }
    var seen = std.StringHashMap(void).init(a);
    for (undef.items) |u| {
        if (defined.contains(u) or known.contains(u) or seen.contains(u)) continue;
        try seen.put(u, {});
        try f.append(a, try std.fmt.allocPrint(a, "{s}: undefined symbol: {s} (not defined by this library, a `needs` library, the C library at the floor or the compiler runtime)", .{ name, u }));
    }

    var all = std.ArrayList([]const u8).empty;
    var it = defined.keyIterator();
    while (it.next()) |k| try all.append(a, k.*);
    std.mem.sort([]const u8, all.items, {}, lessThan);
    return .{ .findings = try f.toOwnedSlice(a), .defined = try all.toOwnedSlice(a) };
}

/// The JSON a validation result is: only the first finding is the message.
pub fn resultJson(a: std.mem.Allocator, ok: bool, msg: []const u8) std.mem.Allocator.Error![]const u8 {
    var o = std.ArrayList(u8).empty;
    try o.appendSlice(a, "{\"version\": 1, \"data\": {\"status\": \"");
    try o.appendSlice(a, if (ok) "success" else "failure");
    try o.appendSlice(a, "\", \"message\": \"");
    for (msg) |c| switch (c) {
        '"' => try o.appendSlice(a, "\\\""),
        '\\' => try o.appendSlice(a, "\\\\"),
        '\n' => try o.appendSlice(a, "\\n"),
        else => try o.append(a, c),
    };
    try o.appendSlice(a, "\"}}\n");
    return o.toOwnedSlice(a);
}

pub const Cli = struct {
    archive: []const u8,
    result: []const u8,
    needs: []const []const u8,
    allow: []const []const u8,
    symbols: ?[]const u8,
    max_glibc: []const u8,
};

pub const usage = "usage: archive_check <lib.a> <result.json> [--needs <lib.a>]... [--allow <symbol>]... [--symbols <out.txt>] [--max-glibc <x.y>]";

pub fn parseArgs(a: std.mem.Allocator, args: []const []const u8) std.mem.Allocator.Error!?Cli {
    if (args.len < 2) return null;
    var needs = std.ArrayList([]const u8).empty;
    var allow = std.ArrayList([]const u8).empty;
    var c = Cli{ .archive = args[0], .result = args[1], .needs = &.{}, .allow = &.{}, .symbols = null, .max_glibc = "2.34" };
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return null;
        const flag = args[i];
        const val = args[i + 1];
        if (std.mem.eql(u8, flag, "--needs")) {
            try needs.append(a, val);
        } else if (std.mem.eql(u8, flag, "--allow")) {
            try allow.append(a, val);
        } else if (std.mem.eql(u8, flag, "--symbols")) {
            c.symbols = val;
        } else if (std.mem.eql(u8, flag, "--max-glibc")) {
            c.max_glibc = val;
        } else return null;
    }
    c.needs = try needs.toOwnedSlice(a);
    c.allow = try allow.toOwnedSlice(a);
    return c;
}

/// The program: 0 when the archive is as a native library must be, 1 (after writing a failing result) when it is not, 2 for a bad command line.
pub fn run(a: std.mem.Allocator, cwd: std.fs.Dir, dir: []const u8, args: []const []const u8, err: *std.ArrayList(u8)) !u8 {
    const c = (try parseArgs(a, args)) orelse {
        try err.appendSlice(a, usage);
        try err.append(a, '\n');
        return 2;
    };
    const bytes = cwd.readFileAlloc(a, c.archive, 1 << 30) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        try err.print(a, "archive_check: cannot read {s}: {s}\n", .{ c.archive, @errorName(e) });
        return 2;
    };
    var needs = std.ArrayList([]const u8).empty;
    for (c.needs) |n| {
        const nb = cwd.readFileAlloc(a, n, 1 << 30) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            try err.print(a, "archive_check: cannot read {s}: {s}\n", .{ n, @errorName(e) });
            return 2;
        };
        try needs.append(a, nb);
    }
    const name = std.fs.path.basename(c.archive);
    const rep = try check(a, name, bytes, .{ .needs = needs.items, .allow = c.allow, .max_glibc = c.max_glibc, .dir = dir });
    if (c.symbols) |sp| {
        var o = std.ArrayList(u8).empty;
        for (rep.defined) |s| {
            try o.appendSlice(a, s);
            try o.append(a, '\n');
        }
        try cwd.writeFile(.{ .sub_path = sp, .data = o.items });
    }
    if (rep.findings.len == 0) {
        const msg = try std.fmt.allocPrint(a, "{s}: {d} global symbols defined; deterministic, no debug section, no build path, nothing undefined that the link will lack", .{ name, rep.defined.len });
        try cwd.writeFile(.{ .sub_path = c.result, .data = try resultJson(a, true, msg) });
        return 0;
    }
    try cwd.writeFile(.{ .sub_path = c.result, .data = try resultJson(a, false, rep.findings[0]) });
    for (rep.findings) |f| try err.print(a, "archive_check: {s}\n", .{f});
    return 1;
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    const dir = try std.fs.cwd().realpathAlloc(a, ".");
    var err = std.ArrayList(u8).empty;
    const code = try run(a, std.fs.cwd(), dir, argv[1..], &err);
    std.fs.File.stderr().writeAll(err.items) catch {};
    std.process.exit(code);
}

test {
    _ = @import("archive_test.zig");
}
