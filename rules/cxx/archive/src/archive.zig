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
//!
//! Allocation: the lists are built with `Acc` and `Set`, which note a failed allocation in one flag instead of returning it from each of the
//! many places that add to them; the function that owns the flag returns `OutOfMemory` once, at its end. What they return stays with the
//! allocator, which is an arena in the program.

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

/// A list whose failed allocation is noted in `oom` (shared by the lists of one function) and not returned.
fn Acc(comptime T: type) type {
    return struct {
        a: std.mem.Allocator,
        oom: *bool,
        items: std.ArrayList(T) = .empty,

        const Self = @This();

        fn push(self: *Self, item: T) void {
            self.items.append(self.a, item) catch {
                self.oom.* = true;
            };
        }

        fn pushAll(self: *Self, more: []const T) void {
            self.items.appendSlice(self.a, more) catch {
                self.oom.* = true;
            };
        }
    };
}

/// A set of strings whose failed allocation is noted in `oom`.
const Set = struct {
    m: std.StringHashMap(void),
    oom: *bool,

    fn init(a: std.mem.Allocator, oom: *bool) Set {
        return .{ .m = std.StringHashMap(void).init(a), .oom = oom };
    }

    fn add(self: *Set, k: []const u8) void {
        self.m.put(k, {}) catch {
            self.oom.* = true;
        };
    }
};

/// Adds the formatted finding to `f`.
fn say(f: *Acc([]const u8), comptime fmt: []const u8, args: anytype) void {
    if (std.fmt.allocPrint(f.a, fmt, args)) |s| {
        f.push(s);
    } else |_| {
        f.oom.* = true;
    }
}

/// Adds the finding for the error `e`, which is the failure of the whole check when it is `OutOfMemory`.
fn blame(f: *Acc([]const u8), e: anyerror, comptime fmt: []const u8, args: anytype) void {
    if (e == error.OutOfMemory) {
        f.oom.* = true;
    } else {
        say(f, fmt, args);
    }
}

/// Notes `OutOfMemory` and nothing else.
fn lost(e: anyerror, oom: *bool) void {
    if (e == error.OutOfMemory) oom.* = true;
}

fn get(comptime T: type, b: []const u8, off: usize) T {
    return std.mem.readInt(T, b[off..][0..@sizeOf(T)], .little);
}

fn rd(comptime T: type, b: []const u8, off: usize) Error!T {
    if (off > b.len or b.len - off < @sizeOf(T)) return error.Truncated;
    return get(T, b, off);
}

/// The object members of an `ar` archive, in file order. The symbol table (`/`, `/SYM64/`) and the long-name table (`//`) are not members.
/// BSD-style names (`#1/N`) are refused: the C++ toolchain writes the GNU format.
pub fn members(a: std.mem.Allocator, b: []const u8) (Error || std.mem.Allocator.Error)![]const Member {
    if (!std.mem.startsWith(u8, b, "!<arch>\n")) return error.NotArchive;
    var oom = false;
    var out = Acc(Member){ .a = a, .oom = &oom };
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
        if (std.mem.eql(u8, raw, "//")) {
            long = data;
        } else if (!std.mem.eql(u8, raw, "/") and !std.mem.eql(u8, raw, "/SYM64/")) {
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
            out.push(.{ .name = name, .data = data, .time = trim(h[16..28]), .owner = trim(h[28..34]), .group = trim(h[34..40]) });
        }
    }
    if (oom) return error.OutOfMemory;
    return out.items.items;
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
    // The header is 64 bytes, which the test above has: its fields are read without a bound.
    if (get(u16, b, 0x10) != 1) return error.NotRelocatable;
    const shoff: usize = @intCast(get(u64, b, 0x28));
    const shentsize: usize = get(u16, b, 0x3A);
    const shnum: usize = get(u16, b, 0x3C);
    var oom = false;
    var def = Acc([]const u8){ .a = a, .oom = &oom };
    var und = Acc([]const u8){ .a = a, .oom = &oom };
    var i: usize = 0;
    while (i < shnum) : (i += 1) {
        const sh = shoff + i * shentsize;
        if (try rd(u32, b, sh + 4) == 2) { // SHT_SYMTAB
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
                // A symbol lies inside the section, which the tests above keep inside the file.
                const at = off + k * 24;
                const info = b[at + 4];
                const bind = info >> 4;
                const typ = info & 0xf;
                const name_off: usize = get(u32, b, at);
                const shndx = get(u16, b, at + 6);
                // Not a local, section or file symbol, and one that has a name.
                if (bind != 0 and typ != 3 and typ != 4 and name_off < strs.len) {
                    const name = std.mem.sliceTo(strs[name_off..], 0);
                    if (name.len != 0 and shndx != 0) {
                        def.push(name);
                    } else if (name.len != 0 and bind != 2) {
                        und.push(name);
                    }
                }
            }
        }
    }
    if (oom) return error.OutOfMemory;
    return .{ .defined = def.items.items, .undef = und.items.items };
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

fn report(oom: bool, findings: []const []const u8, defined: []const []const u8) std.mem.Allocator.Error!Report {
    if (oom) return error.OutOfMemory;
    return .{ .findings = findings, .defined = defined };
}

/// Every finding about the archive `b` (named `name` in messages), empty when it is as a native library must be.
pub fn check(a: std.mem.Allocator, name: []const u8, b: []const u8, o: Options) std.mem.Allocator.Error!Report {
    var oom = false;
    var f = Acc([]const u8){ .a = a, .oom = &oom };
    const ms = members(a, b) catch |e| {
        blame(&f, e, "{s} is not an archive of objects I can read: {s}", .{ name, @errorName(e) });
        return report(oom, f.items.items, &.{});
    };
    if (ms.len == 0) say(&f, "{s} has no object: an empty library", .{name});
    const max = floor.Version.parse(o.max_glibc);
    if (max == null) say(&f, "{s} is not a glibc version", .{o.max_glibc});

    var defined = Set.init(a, &oom);
    var undef = Acc([]const u8){ .a = a, .oom = &oom };
    var prev: []const u8 = "";
    for (ms) |m| {
        if (!std.mem.eql(u8, m.time, "0") or !std.mem.eql(u8, m.owner, "0") or !std.mem.eql(u8, m.group, "0"))
            say(&f, "{s}: member {s} records a time or an owner (time {s}, owner {s}, group {s}): the archive is not deterministic", .{ name, m.name, m.time, m.owner, m.group });
        if (prev.len != 0 and std.mem.lessThan(u8, m.name, prev))
            say(&f, "{s}: member {s} comes after {s}: the members are not in the order of their names", .{ name, m.name, prev });
        prev = m.name;
        if (hermetic.debugSections(a, m.data)) |dbg| {
            if (dbg.len != 0)
                say(&f, "{s}: member {s} has {d} debug section(s), first {s}: the compile directory is in them (compile with -g0)", .{ name, m.name, dbg.len, dbg[0] });
            if (floor.newest(m.data)) |v| {
                if (v != null and max != null and floor.Version.order(v.?, max.?) == .gt)
                    say(&f, "{s}: member {s} needs GLIBC_{d}.{d}, newer than the floor {s}", .{ name, m.name, v.?.major, v.?.minor, o.max_glibc });
            } else |_| {}
            if (symbols(a, m.data)) |s| {
                for (s.defined) |d| defined.add(d);
                for (s.undef) |u| undef.push(u);
            } else |e| {
                blame(&f, e, "{s}: member {s} is not a relocatable object: {s}", .{ name, m.name, @errorName(e) });
            }
        } else |e| {
            blame(&f, e, "{s}: member {s} is not a 64-bit little-endian ELF object: {s}", .{ name, m.name, @errorName(e) });
        }
    }
    if (o.dir.len != 0 and hermetic.mentions(b, o.dir))
        say(&f, "{s} contains the absolute path of the directory it was built in ({s})", .{ name, o.dir });

    // What the library may leave to the final link.
    var known = Set.init(a, &oom);
    var lines = std.mem.splitScalar(u8, floor_symbols, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \r");
        if (t.len != 0 and t[0] != '#') known.add(t);
    }
    for (o.allow) |s| known.add(s);
    for (o.needs) |nb| {
        if (members(a, nb)) |nms| {
            for (nms) |m| {
                if (symbols(a, m.data)) |s| {
                    for (s.defined) |d| known.add(d);
                } else |e| lost(e, &oom);
            }
        } else |e| lost(e, &oom);
    }
    var seen = Set.init(a, &oom);
    for (undef.items.items) |u| {
        if (!(defined.m.contains(u) or known.m.contains(u) or seen.m.contains(u))) {
            seen.add(u);
            say(&f, "{s}: undefined symbol: {s} (not defined by this library, a `needs` library, the C library at the floor or the compiler runtime)", .{ name, u });
        }
    }

    var all = Acc([]const u8){ .a = a, .oom = &oom };
    var it = defined.m.keyIterator();
    while (it.next()) |k| all.push(k.*);
    std.mem.sort([]const u8, all.items.items, {}, lessThan);
    return report(oom, f.items.items, all.items.items);
}

/// The JSON a validation result is: only the first finding is the message.
pub fn resultJson(a: std.mem.Allocator, ok: bool, msg: []const u8) std.mem.Allocator.Error![]const u8 {
    var oom = false;
    var o = Acc(u8){ .a = a, .oom = &oom };
    o.pushAll("{\"version\": 1, \"data\": {\"status\": \"");
    o.pushAll(if (ok) "success" else "failure");
    o.pushAll("\", \"message\": \"");
    for (msg) |c| switch (c) {
        '"' => o.pushAll("\\\""),
        '\\' => o.pushAll("\\\\"),
        '\n' => o.pushAll("\\n"),
        else => o.push(c),
    };
    o.pushAll("\"}}\n");
    if (oom) return error.OutOfMemory;
    return o.items.items;
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
    var oom = false;
    var needs = Acc([]const u8){ .a = a, .oom = &oom };
    var allow = Acc([]const u8){ .a = a, .oom = &oom };
    var c = Cli{ .archive = args[0], .result = args[1], .needs = &.{}, .allow = &.{}, .symbols = null, .max_glibc = "2.34" };
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return null;
        const flag = args[i];
        const val = args[i + 1];
        if (std.mem.eql(u8, flag, "--needs")) {
            needs.push(val);
        } else if (std.mem.eql(u8, flag, "--allow")) {
            allow.push(val);
        } else if (std.mem.eql(u8, flag, "--symbols")) {
            c.symbols = val;
        } else if (std.mem.eql(u8, flag, "--max-glibc")) {
            c.max_glibc = val;
        } else return null;
    }
    if (oom) return error.OutOfMemory;
    c.needs = needs.items.items;
    c.allow = allow.items.items;
    return c;
}

fn tell(a: std.mem.Allocator, err: *std.ArrayList(u8), oom: *bool, comptime fmt: []const u8, args: anytype) void {
    err.print(a, fmt, args) catch {
        oom.* = true;
    };
}

fn exit(oom: bool, code: u8) !u8 {
    if (oom) return error.OutOfMemory;
    return code;
}

/// Exit 2 with the reason a file could not be read, which is the failure of the program when it is `OutOfMemory`.
fn unreadable(a: std.mem.Allocator, err: *std.ArrayList(u8), path: []const u8, e: anyerror) !u8 {
    var oom = e == error.OutOfMemory;
    tell(a, err, &oom, "archive_check: cannot read {s}: {s}\n", .{ path, @errorName(e) });
    return exit(oom, 2);
}

fn writeResult(a: std.mem.Allocator, cwd: std.fs.Dir, path: []const u8, ok: bool, msg: []const u8) !void {
    const json = try resultJson(a, ok, msg);
    try cwd.writeFile(.{ .sub_path = path, .data = json });
}

/// The program: 0 when the archive is as a native library must be, 1 (after writing a failing result) when it is not, 2 for a bad command line.
pub fn run(a: std.mem.Allocator, cwd: std.fs.Dir, dir: []const u8, args: []const []const u8, err: *std.ArrayList(u8)) !u8 {
    var oom = false;
    const c = (try parseArgs(a, args)) orelse {
        tell(a, err, &oom, "{s}\n", .{usage});
        return exit(oom, 2);
    };
    const bytes = cwd.readFileAlloc(a, c.archive, 1 << 30) catch |e| return unreadable(a, err, c.archive, e);
    var needs = Acc([]const u8){ .a = a, .oom = &oom };
    for (c.needs) |n| {
        const nb = cwd.readFileAlloc(a, n, 1 << 30) catch |e| return unreadable(a, err, n, e);
        needs.push(nb);
    }
    const name = std.fs.path.basename(c.archive);
    const rep = try check(a, name, bytes, .{ .needs = needs.items.items, .allow = c.allow, .max_glibc = c.max_glibc, .dir = dir });
    var out = Acc(u8){ .a = a, .oom = &oom };
    for (rep.defined) |s| {
        out.pushAll(s);
        out.push('\n');
    }
    const ok = rep.findings.len == 0;
    const msg = if (ok)
        try std.fmt.allocPrint(a, "{s}: {d} global symbols defined; deterministic, no debug section, no build path, nothing undefined that the link will lack", .{ name, rep.defined.len })
    else
        rep.findings[0];
    for (rep.findings) |f| tell(a, err, &oom, "archive_check: {s}\n", .{f});
    if (oom) return error.OutOfMemory;
    if (c.symbols) |sp| try cwd.writeFile(.{ .sub_path = sp, .data = out.items.items });
    try writeResult(a, cwd, c.result, ok, msg);
    return if (ok) 0 else 1;
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
