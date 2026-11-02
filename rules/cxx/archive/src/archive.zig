//! archive_check: the validation of a native static library (`native_archive`, rules/cxx/native.bzl).
//!
//!   archive_check <lib.a> <result.json> [--needs <lib.a>]... [--allow <symbol>]... [--symbols <out.txt>] [--max-glibc <x.y>]
//!       [--prefix <p> [--min-prefixed <n>] [--original <names.txt>]...]
//!       [--cxx-namespace <ns>]...
//!       [--runtime c++]
//!
//! A static library a Mojo package ships is linked into other people's programs, so it is held to what a library must be:
//!
//!  - an archive of 64-bit little-endian ELF relocatable objects, or of 64-bit little-endian Mach-O relocatable objects (a library built for macOS arm64:
//!    BSD-style member names, `__.SYMDEF` as the symbol table), nothing else and not both;
//!  - deterministic: every member header has time, owner and group 0, and the members are in the order of their names (with `--members any` they may be in any order: a library
//!    whose sources are a `select()` of lists has them in the order the target lists them, which is fixed for a target but not sorted by name);
//!  - hermetic: no object has a `.debug_*` section (a Mach-O object: a `__DWARF` section or a debug-map symbol) and no byte of the archive holds the absolute path of the directory it was built in
//!    (`hermetic.zig`, the check of the C++ rules, applied to each member);
//!  - at the glibc floor: no object needs a glibc symbol version newer than `--max-glibc` (`floor.zig`, applied to each member). A relocatable
//!    object records no version of its own, so the floor of an archive is mostly held by the next rule. A Mach-O object has no such floor;
//!  - closed: every undefined global symbol is defined by the archive itself, by a `--needs` archive, by the C library at the floor or by the
//!    compiler runtime (`floor_symbols.txt`; for Mach-O objects `floor_symbols_macos.txt`, libSystem, by the C name: the symbol's leading underscore is
//!    removed), or is named by an `--allow`. A weak undefined symbol resolves to zero and is not a defect.
//!    Whatever else is undefined is named: it is a symbol the final link will not find.
//!
//! Writes a validation result (`{"version":1,"data":{"status",...}}`) and exits 0 when every rule holds; exits 1 after writing "failure" when
//! one does not, and prints every finding. With `--symbols`, writes the sorted defined global symbols, one per line.
//!
//! With `--prefix`, the library is a renamed one (rules/cxx/prefix, `native_static(prefix = ...)`): every defined global symbol must start with the prefix, at least
//! `--min-prefixed` of them must (a library the renaming missed is not empty by accident), and no undefined symbol may be one of the names in the `--original`
//! files (the library's own names before the renaming, one per line): a reference the renaming missed would resolve to another copy of the library at the final link.
//!
//! With `--cxx-namespace <ns>` (repeatable, only with `--prefix`), a defined C++ name in that namespace is not a leak: a header of macros cannot rename a mangled name, and a library may
//! rename only its C API. A namespace is an identifier (letters, digits and `_`, not starting with a digit) and not `std`; another is refused with exit 2. The names taken are those whose nested
//! name has the namespace as its first component, whole (`_ZN7snappyx` is the namespace `snappyx`): the name itself (`_ZN6snappy...`), the vtable, type information, type name, VTT and construction
//! vtable of a class (`_ZTV`, `_ZTI`, `_ZTS`, `_ZTT`, `_ZTC` followed by `N`), the guard of a static (`_ZGVN`), the local names of a function (`_ZZN`, `_ZGVZN`), and non-virtual and virtual thunks
//! (`_ZTh`, `_ZTv`, followed by `N`). Not taken, so a finding: a class that is not a nested name (`_ZTV6snappy`), covariant thunks (`_ZTc`), a namespace that is not the first component, and any
//! name cut short.
//!
//! With `--runtime c++`, the library is C++ and the final link brings the C++ runtime: the undefined names of libc++, libc++abi and the unwinder (`cxxRuntime`: `_ZNSt*`, `_Znw*`, `__cxa_*`,
//! `_Unwind_*`, `__dso_handle`, ...) are not findings. Any other undefined name still is.
//!
//! Allocation: the lists are built with `Acc` and `Set`, which note a failed allocation in one flag instead of returning it from each of the
//! many places that add to them; the function that owns the flag returns `OutOfMemory` once, at its end. What they return stays with the
//! allocator, which is an arena in the program.

const std = @import("std");
const hermetic = @import("cxx_hermetic");
const floor = @import("cxx_floor");
const builtins = @import("cxx_builtins");

pub const floor_symbols = @embedFile("floor_symbols.txt");
pub const floor_symbols_macos = @embedFile("floor_symbols_macos.txt");

pub const Error = error{ NotArchive, Truncated, BadHeader, NotElf64, NotMacho64, NotRelocatable };

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
/// BSD-style names (`#1/N`: the name is the first N bytes of the member's data, padded with NULs) are read, and the BSD symbol tables (`__.SYMDEF`,
/// `__.SYMDEF SORTED`, `__.SYMDEF_64`) are not members: the toolchain writes the GNU format for ELF objects and the BSD one for Mach-O.
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
        var body = data;
        var bsd_name: ?[]const u8 = null;
        if (std.mem.startsWith(u8, raw, "#1/")) {
            const n = std.fmt.parseInt(usize, raw[3..], 10) catch return error.BadHeader;
            if (n > data.len) return error.BadHeader;
            bsd_name = std.mem.sliceTo(data[0..n], 0);
            body = data[n..];
        }
        if (bsd_name) |bn| {
            if (!isSymdef(bn))
                out.push(.{ .name = bn, .data = body, .time = trim(h[16..28]), .owner = trim(h[28..34]), .group = trim(h[34..40]) });
        } else if (isSymdef(raw)) {
            // A BSD symbol table whose name fits the field is written without `#1/N`.
        } else if (std.mem.eql(u8, raw, "//")) {
            long = data;
        } else if (!std.mem.eql(u8, raw, "/") and !std.mem.eql(u8, raw, "/SYM64/")) {
            var name = raw;
            if (raw.len > 1 and raw[0] == '/') {
                const at = std.fmt.parseInt(usize, raw[1..], 10) catch return error.BadHeader;
                if (at >= long.len) return error.BadHeader;
                const end = std.mem.indexOfScalarPos(u8, long, at, '\n') orelse long.len;
                name = std.mem.trimRight(u8, long[at..end], "/");
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
    /// Weak undefined symbols: not a defect by themselves (they resolve to zero), but a reference to a name a renaming replaced.
    weak_undef: []const []const u8 = &.{},
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
    var weak = Acc([]const u8){ .a = a, .oom = &oom };
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
                    } else if (name.len != 0) {
                        weak.push(name);
                    }
                }
            }
        }
    }
    if (oom) return error.OutOfMemory;
    return .{ .defined = def.items.items, .undef = und.items.items, .weak_undef = weak.items.items };
}

const macho_magic: u32 = 0xfeedfacf;

/// True when `b` starts as a 64-bit little-endian Mach-O file.
pub fn isMacho(b: []const u8) bool {
    return b.len >= 4 and get(u32, b, 0) == macho_magic;
}

/// What a Mach-O relocatable object holds that a native library must not: the first debug section or debug-map symbol, and how many there are.
pub const MachoDebug = struct { count: usize, first: []const u8 };

/// The load commands of the Mach-O object `b`, checked to lie inside the file; `cmd` and `at` of each go to `visit`.
fn machoCommands(b: []const u8, ctx: anytype, comptime visit: fn (@TypeOf(ctx), u32, usize, u32) Error!void) Error!void {
    if (!isMacho(b) or b.len < 32) return error.NotMacho64;
    if (get(u32, b, 12) != 1) return error.NotRelocatable; // MH_OBJECT
    const ncmds: usize = get(u32, b, 16);
    const sizeofcmds: usize = get(u32, b, 20);
    if (b.len - 32 < sizeofcmds) return error.Truncated;
    var at: usize = 32;
    var i: usize = 0;
    while (i < ncmds) : (i += 1) {
        if (at + 8 > 32 + sizeofcmds) return error.Truncated;
        const cmd = get(u32, b, at);
        const size: usize = get(u32, b, at + 4);
        if (size < 8 or at + size > 32 + sizeofcmds) return error.Truncated;
        try visit(ctx, cmd, at, @intCast(size));
        at += size;
    }
}

const LC_SYMTAB: u32 = 0x2;
const LC_SEGMENT_64: u32 = 0x19;

const DebugScan = struct {
    b: []const u8,
    out: *MachoDebug,

    fn visit(self: DebugScan, cmd: u32, at: usize, size: u32) Error!void {
        const b = self.b;
        if (cmd == LC_SEGMENT_64) {
            if (size < 72) return error.Truncated;
            const nsects: usize = get(u32, b, at + 64);
            if (nsects > (size - 72) / 80) return error.Truncated;
            var k: usize = 0;
            while (k < nsects) : (k += 1) {
                const sec = at + 72 + k * 80;
                if (std.mem.eql(u8, std.mem.sliceTo(b[sec + 16 ..][0..16], 0), "__DWARF")) {
                    if (self.out.count == 0) self.out.first = std.mem.sliceTo(b[sec..][0..16], 0);
                    self.out.count += 1;
                }
            }
        } else if (cmd == LC_SYMTAB) {
            const t = try symtabOf(b, at, size);
            var k: usize = 0;
            while (k < t.nsyms) : (k += 1) {
                // N_STAB: a debug-map entry, which names the object file and the directory the compiler ran in.
                if (b[t.off + k * 16 + 4] & 0xe0 != 0) {
                    if (self.out.count == 0) self.out.first = "(a debug-map symbol)";
                    self.out.count += 1;
                }
            }
        }
    }
};

const Symtab = struct { off: usize, nsyms: usize, strs: []const u8 };

/// The symbol table and the string table that `LC_SYMTAB` at `at` names, both checked to lie inside the file.
fn symtabOf(b: []const u8, at: usize, size: u32) Error!Symtab {
    if (size < 24) return error.Truncated;
    const off: usize = get(u32, b, at + 8);
    const nsyms: usize = get(u32, b, at + 12);
    const str_off: usize = get(u32, b, at + 16);
    const str_size: usize = get(u32, b, at + 20);
    if (off > b.len or (b.len - off) / 16 < nsyms) return error.Truncated;
    if (str_off > b.len or b.len - str_off < str_size) return error.Truncated;
    return .{ .off = off, .nsyms = nsyms, .strs = b[str_off..][0..str_size] };
}

/// The debug sections and debug-map symbols of a Mach-O relocatable object (`count` 0: none).
pub fn machoDebug(b: []const u8) Error!MachoDebug {
    var d = MachoDebug{ .count = 0, .first = "" };
    try machoCommands(b, DebugScan{ .b = b, .out = &d }, DebugScan.visit);
    return d;
}

const SymScan = struct {
    b: []const u8,
    def: *Acc([]const u8),
    und: *Acc([]const u8),
    weak: *Acc([]const u8),

    fn visit(self: SymScan, cmd: u32, at: usize, size: u32) Error!void {
        if (cmd != LC_SYMTAB) return;
        const b = self.b;
        const t = try symtabOf(b, at, size);
        var k: usize = 0;
        while (k < t.nsyms) : (k += 1) {
            const e = t.off + k * 16;
            const typ = b[e + 4];
            // Not a debug-map entry, and an external one (a local symbol is not visible to the final link).
            if (typ & 0xe0 != 0 or typ & 0x01 == 0) continue;
            const strx: usize = get(u32, b, e);
            if (strx >= t.strs.len) continue;
            var name = std.mem.sliceTo(t.strs[strx..], 0);
            // The C name: Mach-O puts one underscore before it.
            if (name.len != 0 and name[0] == '_') name = name[1..];
            if (name.len == 0) continue;
            const kind = typ & 0x0e;
            const desc = get(u16, b, e + 6);
            const value = get(u64, b, e + 8);
            // N_UNDF with a value is a common symbol: a definition. N_ABS, N_SECT and N_INDR define the name.
            if (kind != 0 or value != 0) {
                self.def.push(name);
            } else if (desc & 0x40 == 0) {
                self.und.push(name);
            } else {
                self.weak.push(name); // N_WEAK_REF: resolves to zero, not a defect by itself
            }
        }
    }
};

/// The external symbols of one Mach-O relocatable object, by their C names (the leading underscore removed): `defined` and `undef` as `symbols` does.
pub fn machoSymbols(a: std.mem.Allocator, b: []const u8) (Error || std.mem.Allocator.Error)!Syms {
    var oom = false;
    var def = Acc([]const u8){ .a = a, .oom = &oom };
    var und = Acc([]const u8){ .a = a, .oom = &oom };
    var weak = Acc([]const u8){ .a = a, .oom = &oom };
    try machoCommands(b, SymScan{ .b = b, .def = &def, .und = &und, .weak = &weak }, SymScan.visit);
    if (oom) return error.OutOfMemory;
    return .{ .defined = def.items.items, .undef = und.items.items, .weak_undef = weak.items.items };
}

/// The symbols of one object of either format.
fn objectSymbols(a: std.mem.Allocator, b: []const u8) (Error || std.mem.Allocator.Error)!Syms {
    return if (isMacho(b)) machoSymbols(a, b) else symbols(a, b);
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

pub const Options = struct {
    /// The members may be in any order (`--members any`); by default they are in the order of their names.
    any_order: bool = false,
    /// The archives of the libraries this one needs (`needs`): what they define may be left undefined here.
    needs: []const []const u8 = &.{},
    /// Symbols the author names as provided by something the check cannot see.
    allow: []const []const u8 = &.{},
    max_glibc: []const u8 = "2.34",
    /// The library is C++ (`--runtime c++`): the names of the C++ runtime (libc++, libc++abi, the unwinder) may stay undefined, the final link brings the runtime.
    runtime_cxx: bool = false,
    /// The absolute path of the directory the archive was built in ("" skips the test: a unit test has none).
    dir: []const u8 = "",
    /// A renamed library (`--prefix`): every defined global symbol starts with this ("" skips the rule and the two below).
    prefix: []const u8 = "",
    /// At least this many defined symbols start with `prefix`.
    min_prefixed: usize = 0,
    /// The names the renaming replaced: none of them may be left undefined.
    original: []const []const u8 = &.{},
    /// C++ namespaces whose mangled names (`_ZN6snappy...`) a renamed library may define without the prefix: a header of macros cannot rename them.
    cxx_namespaces: []const []const u8 = &.{},
};

/// The prefixes of the names the C++ runtime defines (Itanium ABI: libc++'s `std`, `operator new` and `delete`, the vtables and type information of the ABI's own classes,
/// `__cxa_*`, the unwinder) and the names the link's start-up object defines. A prefix match, so it allows more than the runtime has: the link is the real check.
const cxx_runtime_prefixes = [_][]const u8{ "_ZNSt", "_ZNKSt", "_ZSt", "_ZTVSt", "_ZTISt", "_ZTSSt", "_ZTVN10__cxxabiv", "_ZTIN10__cxxabiv", "_ZTSN10__cxxabiv", "_Znw", "_Zna", "_Zdl", "_Zda", "__cxa_", "__gxx_", "__dynamic_cast", "_Unwind_", "__dso_handle" };

/// Whether `name` (the C name: a Mach-O symbol's leading underscore removed) belongs to the C++ runtime.
pub fn cxxRuntime(name: []const u8) bool {
    for (cxx_runtime_prefixes) |p| {
        if (std.mem.startsWith(u8, name, p)) return true;
    }
    return false;
}

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
    var undef_macho = Acc([]const u8){ .a = a, .oom = &oom };
    var weak = Acc([]const u8){ .a = a, .oom = &oom };
    // The object format of the library is the one of its first object: a member of the other is a finding.
    var macho_lib: ?bool = null;
    var prev: []const u8 = "";
    for (ms) |m| {
        if (!std.mem.eql(u8, m.time, "0") or !std.mem.eql(u8, m.owner, "0") or !std.mem.eql(u8, m.group, "0"))
            say(&f, "{s}: member {s} records a time or an owner (time {s}, owner {s}, group {s}): the archive is not deterministic", .{ name, m.name, m.time, m.owner, m.group });
        if (!o.any_order and prev.len != 0 and std.mem.lessThan(u8, m.name, prev))
            say(&f, "{s}: member {s} comes after {s}: the members are not in the order of their names", .{ name, m.name, prev });
        prev = m.name;
        if (isMacho(m.data)) {
            if (macho_lib == null) macho_lib = true;
            if (macho_lib.? == false) say(&f, "{s}: member {s} is a Mach-O object in a library of ELF objects", .{ name, m.name });
            if (machoDebug(m.data)) |dbg| {
                if (dbg.count != 0)
                    say(&f, "{s}: member {s} has {d} debug section(s), first {s}: the compile directory is in them (compile with -g0)", .{ name, m.name, dbg.count, dbg.first });
            } else |e| {
                blame(&f, e, "{s}: member {s} is not a relocatable Mach-O object: {s}", .{ name, m.name, @errorName(e) });
            }
            if (machoSymbols(a, m.data)) |s| {
                for (s.defined) |d| defined.add(d);
                for (s.undef) |u| undef_macho.push(u);
                for (s.weak_undef) |u| weak.push(u);
            } else |e| {
                blame(&f, e, "{s}: member {s} is not a relocatable Mach-O object: {s}", .{ name, m.name, @errorName(e) });
            }
        } else if (hermetic.debugSections(a, m.data)) |dbg| {
            if (macho_lib == null) macho_lib = false;
            if (macho_lib.? == true) say(&f, "{s}: member {s} is an ELF object in a library of Mach-O objects", .{ name, m.name });
            if (dbg.len != 0)
                say(&f, "{s}: member {s} has {d} debug section(s), first {s}: the compile directory is in them (compile with -g0)", .{ name, m.name, dbg.len, dbg[0] });
            if (floor.newest(m.data)) |v| {
                if (v != null and max != null and floor.Version.order(v.?, max.?) == .gt)
                    say(&f, "{s}: member {s} needs GLIBC_{d}.{d}, newer than the floor {s}", .{ name, m.name, v.?.major, v.?.minor, o.max_glibc });
            } else |_| {}
            if (symbols(a, m.data)) |s| {
                for (s.defined) |d| defined.add(d);
                for (s.undef) |u| undef.push(u);
                for (s.weak_undef) |u| weak.push(u);
            } else |e| {
                blame(&f, e, "{s}: member {s} is not a relocatable object: {s}", .{ name, m.name, @errorName(e) });
            }
        } else |e| {
            blame(&f, e, "{s}: member {s} is not a 64-bit little-endian ELF or Mach-O object: {s}", .{ name, m.name, @errorName(e) });
        }
    }
    if (o.dir.len != 0 and hermetic.mentions(b, o.dir))
        say(&f, "{s} contains the absolute path of the directory it was built in ({s})", .{ name, o.dir });

    // What the library may leave to the final link: the C library of the platform its objects are for, the compiler runtime, and what the author allows
    // or a `needs` library defines.
    var known = Set.init(a, &oom);
    var known_macho = Set.init(a, &oom);
    var lines = std.mem.splitScalar(u8, floor_symbols, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \r");
        if (t.len != 0 and t[0] != '#') known.add(t);
    }
    lines = std.mem.splitScalar(u8, floor_symbols_macos, '\n');
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \r");
        if (t.len != 0 and t[0] != '#') known_macho.add(t);
    }
    for (o.allow) |s| {
        known.add(s);
        known_macho.add(s);
    }
    for (o.needs) |nb| {
        if (members(a, nb)) |nms| {
            for (nms) |m| {
                if (objectSymbols(a, m.data)) |s| {
                    for (s.defined) |d| {
                        known.add(d);
                        known_macho.add(d);
                    }
                } else |e| lost(e, &oom);
            }
        } else |e| lost(e, &oom);
    }
    var seen = Set.init(a, &oom);
    for (undef.items.items) |u| {
        if (!(defined.m.contains(u) or known.m.contains(u) or seen.m.contains(u) or (o.runtime_cxx and cxxRuntime(u)))) {
            seen.add(u);
            say(&f, "{s}: undefined symbol: {s} (not defined by this library, a `needs` library, the C library at the floor or the compiler runtime)", .{ name, u });
        }
    }
    for (undef_macho.items.items) |u| {
        if (!(defined.m.contains(u) or known_macho.m.contains(u) or seen.m.contains(u) or (o.runtime_cxx and cxxRuntime(u)))) {
            seen.add(u);
            say(&f, "{s}: undefined symbol: {s} (not defined by this library, a `needs` library, libSystem or the compiler runtime)", .{ name, u });
        }
    }

    var all = Acc([]const u8){ .a = a, .oom = &oom };
    var it = defined.m.keyIterator();
    while (it.next()) |k| all.push(k.*);
    std.mem.sort([]const u8, all.items.items, {}, lessThan);
    if (o.prefix.len != 0) prefixFindings(a, &f, &oom, name, o, all.items.items, &.{ undef.items.items, undef_macho.items.items, weak.items.items });
    return report(oom, f.items.items, all.items.items);
}

/// Whether `name` is the name of a BSD symbol table member (not a member of the library): exactly one of the four the toolchains write.
fn isSymdef(name: []const u8) bool {
    for ([_][]const u8{ "__.SYMDEF", "__.SYMDEF SORTED", "__.SYMDEF_64", "__.SYMDEF_64 SORTED" }) |t| {
        if (std.mem.eql(u8, name, t)) return true;
    }
    return false;
}

/// Skips `[n]<digits>` (a thunk's offset, at least one digit) and the `_` after it; null when it is not there.
fn skipOffset(s: []const u8) ?[]const u8 {
    var i: usize = 0;
    if (i < s.len and s[i] == 'n') i += 1;
    const from = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == from or i >= s.len or s[i] != '_') return null;
    return s[i + 1 ..];
}

/// The text after the `N` that opens the nested name an Itanium-mangled C name is about, or null when the name has none of the forms below.
fn afterNestedOpen(name: []const u8) ?[]const u8 {
    // The nested name itself, the table, type information and type name of a class, its VTT and construction vtables, the guard of a static, and a local name (`_ZZ`:
    // a function's encoding, then the entity in it) or the guard of a function-local static (`_ZGVZ`), whose function is a nested name.
    for ([_][]const u8{ "_ZN", "_ZTVN", "_ZTIN", "_ZTSN", "_ZTTN", "_ZTCN", "_ZGVN", "_ZZN", "_ZGVZN" }) |p| {
        if (std.mem.startsWith(u8, name, p)) return name[p.len..];
    }
    // A non-virtual thunk (`_ZTh <offset> _ <encoding>`) and a virtual thunk (`_ZTv <offset> _ <offset> _ <encoding>`) of a function that is a nested name.
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, name, "_ZTh")) {
        rest = skipOffset(name[4..]) orelse return null;
    } else if (std.mem.startsWith(u8, name, "_ZTv")) {
        rest = skipOffset(name[4..]) orelse return null;
        rest = skipOffset(rest) orelse return null;
    } else return null;
    if (rest.len == 0 or rest[0] != 'N') return null;
    return rest[1..];
}

/// Whether `name` (an Itanium-mangled C name: a Mach-O symbol's leading underscore removed) is in one of the C++ namespaces `spaces`: its nested name (see
/// `afterNestedOpen` for the forms: `_ZN`, `_ZTVN`, `_ZTIN`, `_ZTSN`, `_ZTTN`, `_ZTCN`, `_ZGVN`, `_ZZN`, `_ZGVZN`, `_ZTh`, `_ZTv`; the qualifiers `r V K` and `R O` may follow the `N`)
/// has the namespace as its first component: a length, then that many bytes, compared whole. `_ZN7snappyx` is the namespace `snappyx`, not `snappy`. What follows the first
/// component is not parsed: the Itanium grammar needs a further component or `E`, which no compiler leaves out, so `_ZN6snappyz` (not a name a compiler writes) is accepted as in
/// `snappy`. Not handled, so reported as a name without the prefix: a class that is not a nested name (`_ZTV6snappy...`), covariant thunks (`_ZTc`), templates of a global
/// function over a type of the namespace, and a namespace that is not the first component (`_ZN3foo6snappy...`).
pub fn inCxxNamespace(name: []const u8, spaces: []const []const u8) bool {
    if (spaces.len == 0) return false;
    var rest = afterNestedOpen(name) orelse return false;
    var k: usize = 0;
    while (k < rest.len and std.mem.indexOfScalar(u8, "rVKRO", rest[k]) != null) k += 1;
    rest = rest[k..];
    var n: usize = 0;
    var d: usize = 0;
    while (d < rest.len and rest[d] >= '0' and rest[d] <= '9') : (d += 1) {
        n = std.math.mul(usize, n, 10) catch return false;
        n = std.math.add(usize, n, rest[d] - '0') catch return false;
    }
    if (d == 0 or d > rest.len or n > rest.len - d) return false;
    const comp = rest[d .. d + n];
    for (spaces) |sp| {
        if (std.mem.eql(u8, comp, sp)) return true;
    }
    return false;
}

/// The most names one finding lists.
const listed = 20;

/// The findings of a renamed library (`Options.prefix`): defined symbols without the prefix, too few with it, and undefined references to a name the renaming replaced.
/// `defined` is sorted; `undefs` are the undefined symbols of each object format.
fn prefixFindings(a: std.mem.Allocator, f: *Acc([]const u8), oom: *bool, name: []const u8, o: Options, defined: []const []const u8, undefs: []const []const []const u8) void {
    var bare = Acc(u8){ .a = a, .oom = oom };
    var n_bare: usize = 0;
    var n_prefixed: usize = 0;
    for (defined) |d| {
        if (builtins.isBuiltin(d)) continue;
        if (inCxxNamespace(d, o.cxx_namespaces)) continue;
        if (std.mem.startsWith(u8, d, o.prefix)) {
            n_prefixed += 1;
            continue;
        }
        if (n_bare < listed) {
            bare.push(' ');
            bare.pushAll(d);
        }
        n_bare += 1;
    }
    if (n_bare != 0)
        say(f, "{s}: {d} defined symbol(s) without the prefix {s}:{s}{s}", .{ name, n_bare, o.prefix, bare.items.items, if (n_bare > listed) " ..." else "" });
    if (n_prefixed < o.min_prefixed)
        say(f, "{s}: only {d} defined symbol(s) start with the prefix {s} (at least {d} expected): the renaming did not reach the library", .{ name, n_prefixed, o.prefix, o.min_prefixed });
    var original = Set.init(a, oom);
    for (o.original) |n| original.add(n);
    var seen = Set.init(a, oom);
    for (undefs) |list| {
        for (list) |u| {
            if (original.m.contains(u) and !seen.m.contains(u)) {
                seen.add(u);
                say(f, "{s}: undefined reference to {s}, a name the prefix header renames: the renaming missed it, and the final link would resolve it to another copy of the library", .{ name, u });
            }
        }
    }
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
    prefix: []const u8,
    min_prefixed: usize,
    original: []const []const u8,
    runtime_cxx: bool,
    any_order: bool,
    cxx_namespaces: []const []const u8,
};

pub const usage = "usage: archive_check <lib.a> <result.json> [--needs <lib.a>]... [--allow <symbol>]... [--symbols <out.txt>] [--max-glibc <x.y>] [--prefix <p> [--min-prefixed <n>] [--original <names.txt>]...] [--cxx-namespace <ns>]... [--runtime c++]";

pub fn parseArgs(a: std.mem.Allocator, args: []const []const u8) std.mem.Allocator.Error!?Cli {
    if (args.len < 2) return null;
    var oom = false;
    var needs = Acc([]const u8){ .a = a, .oom = &oom };
    var allow = Acc([]const u8){ .a = a, .oom = &oom };
    var spaces = Acc([]const u8){ .a = a, .oom = &oom };
    var original = Acc([]const u8){ .a = a, .oom = &oom };
    var c = Cli{ .archive = args[0], .result = args[1], .needs = &.{}, .allow = &.{}, .symbols = null, .max_glibc = "2.34", .prefix = "", .min_prefixed = 0, .original = &.{}, .runtime_cxx = false, .cxx_namespaces = &.{}, .any_order = false };
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
        } else if (std.mem.eql(u8, flag, "--members")) {
            if (!std.mem.eql(u8, val, "any")) return null;
            c.any_order = true;
        } else if (std.mem.eql(u8, flag, "--runtime")) {
            if (!std.mem.eql(u8, val, "c++")) return null;
            c.runtime_cxx = true;
        } else if (std.mem.eql(u8, flag, "--prefix")) {
            if (val.len == 0) return null;
            c.prefix = val;
        } else if (std.mem.eql(u8, flag, "--min-prefixed")) {
            c.min_prefixed = std.fmt.parseUnsigned(usize, val, 10) catch return null;
        } else if (std.mem.eql(u8, flag, "--cxx-namespace")) {
            spaces.push(val);
        } else if (std.mem.eql(u8, flag, "--original")) {
            original.push(val);
        } else return null;
    }
    if (oom) return error.OutOfMemory;
    c.needs = needs.items.items;
    c.allow = allow.items.items;
    c.original = original.items.items;
    c.cxx_namespaces = spaces.items.items;
    // The two options of a renamed library mean nothing without the prefix.
    if (c.prefix.len == 0 and (c.min_prefixed != 0 or c.original.len != 0 or c.cxx_namespaces.len != 0)) return null;
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
    // A namespace is an identifier (not starting with a digit), and not `std`: the standard library's own names are not the library's to keep (and `_ZN3std` is what other languages' symbols look like too).
    for (c.cxx_namespaces) |ns| {
        var ok = ns.len != 0 and !std.mem.eql(u8, ns, "std") and !std.ascii.isDigit(ns[0]);
        for (ns) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) ok = false;
        }
        if (!ok) {
            tell(a, err, &oom, "archive_check: --cxx-namespace {s}: a namespace is an identifier: letters, digits and _, not starting with a digit, and not empty or std\n", .{ns});
            return exit(oom, 2);
        }
    }
    const bytes = cwd.readFileAlloc(a, c.archive, 1 << 30) catch |e| return unreadable(a, err, c.archive, e);
    var needs = Acc([]const u8){ .a = a, .oom = &oom };
    for (c.needs) |n| {
        const nb = cwd.readFileAlloc(a, n, 1 << 30) catch |e| return unreadable(a, err, n, e);
        needs.push(nb);
    }
    // The names the renaming replaced: the lines of each file.
    var original = Acc([]const u8){ .a = a, .oom = &oom };
    for (c.original) |p| {
        const text = cwd.readFileAlloc(a, p, 1 << 28) catch |e| return unreadable(a, err, p, e);
        var ls = std.mem.splitScalar(u8, text, '\n');
        while (ls.next()) |l| {
            const n = std.mem.trim(u8, l, " \r");
            if (n.len != 0) original.push(n);
        }
    }
    const name = std.fs.path.basename(c.archive);
    const rep = try check(a, name, bytes, .{ .needs = needs.items.items, .allow = c.allow, .max_glibc = c.max_glibc, .dir = dir, .prefix = c.prefix, .min_prefixed = c.min_prefixed, .original = original.items.items, .runtime_cxx = c.runtime_cxx, .cxx_namespaces = c.cxx_namespaces, .any_order = c.any_order });
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
    _ = @import("archive_macho_test.zig");
}
