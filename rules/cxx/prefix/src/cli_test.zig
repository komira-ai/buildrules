//! The cases of cli.zig: each mode's flags, and the exit code and output of a
//! command that cannot run.

const std = @import("std");
const P = @import("prefix.zig");
const M = @import("cli.zig");

const eqs = std.testing.expectEqualStrings;
const expect = std.testing.expect;

fn expectFail(r: anytype, want: []const u8) !void {
    if (r) |_| {
        std.debug.print("want the refusal: {s}\n", .{want});
        return error.TestUnexpectedResult;
    } else |_| try eqs(want, P.msg);
}

const header_ok = [_][]const u8{ "prefix_tool", "header", "--elfsyms", "e", "--archive", "l.a", "--header", "h", "--symbols", "s", "--style", "strip", "--prefix", "k_", "--min", "5" };
const check_ok = [_][]const u8{ "prefix_tool", "check", "--elfsyms", "./no-such-elfsyms", "--archive", "l.a", "--result", "r", "--prefix", "k_", "--min", "5" };

fn with(base: []const []const u8, more: []const []const u8) []const []const u8 {
    return std.mem.concat(P.a(), []const u8, &.{ base, more }) catch unreachable;
}

test "args: header and check, repeated flags kept in order" {
    const h = try M.Args.parse(with(&header_ok, &.{ "--extra", "b", "--strip", "s_", "--extra", "a" }));
    try eqs("header", h.mode);
    try eqs("s_", h.get("--strip"));
    try expect(h.list("--extra").len == 2);
    try eqs("b", h.list("--extra")[0]);
    try eqs("a", h.list("--extra")[1]);
    try expect((try h.min()) == 5);
    const c = try M.Args.parse(with(&check_ok, &.{ "--names", "n1", "--allow", "_Z*", "--names", "n2" }));
    try eqs("n2", c.list("--names")[1]);
    try eqs("_Z*", c.list("--allow")[0]);
    try expect(c.list("--extra").len == 0);
}

test "args: refusals" {
    try expectFail(M.Args.parse(&.{"prefix_tool"}), "prefix_tool: no mode");
    try expectFail(M.Args.parse(&.{ "prefix_tool", "nm" }), "prefix_tool: unknown mode nm");
    try expectFail(M.Args.parse(header_ok[0 .. header_ok.len - 2]), "prefix_tool header: --min is required");
    try expectFail(M.Args.parse(with(&header_ok, &.{"--extra"})), "prefix_tool: --extra needs a value");
    try expectFail(M.Args.parse(with(&header_ok, &.{ "--prefix", "j_" })), "prefix_tool: --prefix given twice");
    // Each mode takes only its own flags.
    try expectFail(M.Args.parse(with(&header_ok, &.{ "--allow", "x" })), "prefix_tool header: unknown flag --allow");
    try expectFail(M.Args.parse(with(&check_ok, &.{ "--extra", "x" })), "prefix_tool check: unknown flag --extra");
    try expectFail(M.Args.parse(with(&check_ok, &.{ "--strip", "x" })), "prefix_tool check: unknown flag --strip");
    const m = try M.Args.parse(with(header_ok[0 .. header_ok.len - 2], &.{ "--min", "-1" }));
    try expectFail(m.min(), "prefix_tool: --min -1 is not a number");
}

test "outcome: bad arguments exit 2 with the usage; a refusal exits 1" {
    const o = M.outcome(&.{ "prefix_tool", "nm" }, "/w");
    try expect(o.code == 2);
    try eqs("prefix_tool: unknown mode nm\n" ++ M.usage, o.stderr);
    const s = M.outcome(with(header_ok[0 .. header_ok.len - 6], &.{ "--style", "nope", "--prefix", "k_", "--min", "1" }), "/w");
    try expect(s.code == 1);
    try eqs("prefix_tool: unknown style nope\n", s.stderr);
    // elfsyms that cannot be run fails the command, before anything is written.
    const e = M.outcome(&check_ok, "/w");
    try expect(e.code == 1);
    try expect(std.mem.startsWith(u8, e.stderr, "prefix_tool: "));
}

test "outcome: messages name the archive by its absolute path" {
    try eqs("/w/buck-out/l.a", M.shown("/w", "buck-out/l.a"));
    try eqs("/abs/l.a", M.shown("/w", "/abs/l.a"));
    // an empty path is the working directory's own, not an absolute one
    try eqs("/w/", M.shown("/w", ""));
}

test "args: a flag that was not given reads as empty, a list that was not given as no items" {
    const h = try M.Args.parse(&header_ok);
    try eqs("", h.get("--strip"));
    try expect(h.list("--extra").len == 0);
    try eqs("k_", h.get("--prefix"));
}

// ---- the commands, end to end: the real `elfsyms` (the test's env_tools), archives and objects written here, outputs read back ----------------------------------

/// The path of the pinned `elfsyms` the test target hands out.
fn elfsymsPath() ![]const u8 {
    const v = try std.process.getEnvVarOwned(P.a(), "ELFSYMS");
    return std.fs.cwd().realpathAlloc(P.a(), v);
}

/// An ar member: the 60-byte header (name, size, the closing "`\n"), the data, and the padding byte of an odd size.
fn arMember(out: *std.ArrayList(u8), name: []const u8, data: []const u8) !void {
    var hdr: [60]u8 = undefined;
    @memset(&hdr, ' ');
    @memcpy(hdr[0..name.len], name);
    _ = try std.fmt.bufPrint(hdr[48..58], "{d}", .{data.len});
    hdr[58] = '`';
    hdr[59] = '\n';
    try out.appendSlice(P.a(), &hdr);
    try out.appendSlice(P.a(), data);
    if (data.len % 2 == 1) try out.append(P.a(), '\n');
}

/// An archive whose symbol table ("/" member, 32-bit big-endian counts) names `names`.
fn armapArchive(names: []const []const u8) ![]const u8 {
    var data = std.ArrayList(u8).empty;
    var count: [4]u8 = undefined;
    std.mem.writeInt(u32, &count, @intCast(names.len), .big);
    try data.appendSlice(P.a(), &count);
    for (names) |_| try data.appendSlice(P.a(), &[_]u8{ 0, 0, 0, 0 }); // member offsets: elfsyms does not read them
    for (names) |n| {
        try data.appendSlice(P.a(), n);
        try data.append(P.a(), 0);
    }
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(P.a(), "!<arch>\n");
    try arMember(&out, "/", data.items);
    return out.items;
}

const Sym = struct { name: []const u8, bind: u8, defined: bool };
const LOCAL: u8 = 0;
const GLOBAL: u8 = 1;
const WEAK: u8 = 2;

/// An archive of one ELF64 little-endian object with the symbols `syms` (all functions; a defined one is in section 1).
fn objectArchive(syms: []const Sym) ![]const u8 {
    var strtab = std.ArrayList(u8).empty;
    try strtab.append(P.a(), 0);
    var symtab = std.ArrayList(u8).empty;
    try symtab.appendNTimes(P.a(), 0, 24); // the null symbol
    for (syms) |s| {
        var e = [_]u8{0} ** 24;
        std.mem.writeInt(u32, e[0..4], @intCast(strtab.items.len), .little);
        e[4] = (s.bind << 4) | 2; // STT_FUNC
        std.mem.writeInt(u16, e[6..8], if (s.defined) 1 else 0, .little);
        try symtab.appendSlice(P.a(), &e);
        try strtab.appendSlice(P.a(), s.name);
        try strtab.append(P.a(), 0);
    }
    const sym_off = 64;
    const str_off = sym_off + symtab.items.len;
    const sh_off = (str_off + strtab.items.len + 7) / 8 * 8;
    const b = try P.a().alloc(u8, sh_off + 3 * 64);
    @memset(b, 0);
    @memcpy(b[0..4], "\x7fELF");
    b[4] = 2;
    b[5] = 1;
    std.mem.writeInt(u64, b[0x28..][0..8], sh_off, .little);
    std.mem.writeInt(u16, b[0x3A..][0..2], 64, .little);
    std.mem.writeInt(u16, b[0x3C..][0..2], 3, .little);
    @memcpy(b[sym_off..][0..symtab.items.len], symtab.items);
    @memcpy(b[str_off..][0..strtab.items.len], strtab.items);
    const s1 = sh_off + 64; // the symbol table, whose strings are section 2
    std.mem.writeInt(u32, b[s1 + 4 ..][0..4], 2, .little);
    std.mem.writeInt(u64, b[s1 + 0x18 ..][0..8], sym_off, .little);
    std.mem.writeInt(u64, b[s1 + 0x20 ..][0..8], symtab.items.len, .little);
    std.mem.writeInt(u32, b[s1 + 0x28 ..][0..4], 2, .little);
    const s2 = sh_off + 128;
    std.mem.writeInt(u32, b[s2 + 4 ..][0..4], 3, .little);
    std.mem.writeInt(u64, b[s2 + 0x18 ..][0..8], str_off, .little);
    std.mem.writeInt(u64, b[s2 + 0x20 ..][0..8], strtab.items.len, .little);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(P.a(), "!<arch>\n");
    try arMember(&out, "obj.o/", b);
    return out.items;
}

/// A scratch directory holding `lib.a` (the bytes `archive`), and its absolute path.
const Work = struct {
    tmp: std.testing.TmpDir,
    dir: []const u8,

    fn init(archive: []const u8) !Work {
        var tmp = std.testing.tmpDir(.{});
        try tmp.dir.writeFile(.{ .sub_path = "lib.a", .data = archive });
        return .{ .tmp = tmp, .dir = try tmp.dir.realpathAlloc(P.a(), ".") };
    }
    fn path(self: Work, name: []const u8) []const u8 {
        return P.fmt("{s}/{s}", .{ self.dir, name });
    }
    fn read(self: Work, name: []const u8) ![]const u8 {
        return self.tmp.dir.readFileAlloc(P.a(), name, 1 << 20);
    }
    fn exists(self: Work, name: []const u8) bool {
        self.tmp.dir.access(name, .{}) catch return false;
        return true;
    }
};

test "header: writes the symbols file and the header from the archive's symbol table, less what is never renamed" {
    var w = try Work.init(try armapArchive(&.{ "zeta", "alpha", "sscanf", "alpha" }));
    defer w.tmp.cleanup();
    const argv = [_][]const u8{ "prefix_tool", "header", "--elfsyms", try elfsymsPath(), "--archive", w.path("lib.a"), "--header", w.path("h.h"), "--symbols", w.path("s.txt"), "--style", "boringssl", "--prefix", "p", "--min", "2", "--extra", "mid" };
    const o = M.outcome(&argv, "/w");
    try expect(o.code == 0);
    try eqs("", o.stdout);
    try eqs("", o.stderr);
    // sorted by bytes, each once, sscanf (on the skip list) left out, the extra merged in
    try eqs("alpha\nmid\nzeta\n", try w.read("s.txt"));
    const h = try w.read("h.h");
    try expect(std.mem.indexOf(u8, h, "boringssl_prefix_symbols.h for the prefix p, 3 names. */\n") != null);
    try expect(std.mem.indexOf(u8, h, "#define mid BORINGSSL_ADD_PREFIX(BORINGSSL_PREFIX, mid)\n") != null);
    try expect(std.mem.indexOf(u8, h, "sscanf") == null);
}

test "header: fewer names than --min is a refusal that names the archive, and writes nothing" {
    var w = try Work.init(try armapArchive(&.{ "alpha", "beta" }));
    defer w.tmp.cleanup();
    const argv = [_][]const u8{ "prefix_tool", "header", "--elfsyms", try elfsymsPath(), "--archive", w.path("lib.a"), "--header", w.path("h.h"), "--symbols", w.path("s.txt"), "--style", "strip", "--strip", "s", "--prefix", "p", "--min", "3" };
    const o = M.outcome(&argv, "/w");
    try expect(o.code == 1);
    try eqs(P.fmt("prefix_header: only 2 names read from {s} (at least 3 expected)\n", .{w.path("lib.a")}), o.stderr);
    try expect(!w.exists("h.h") and !w.exists("s.txt"));
}

test "header: a file that is not an archive is refused with elfsyms' own words and the command that failed" {
    var w = try Work.init("this is not an archive\n");
    defer w.tmp.cleanup();
    const argv = [_][]const u8{ "prefix_tool", "header", "--elfsyms", try elfsymsPath(), "--archive", w.path("lib.a"), "--header", w.path("h.h"), "--symbols", w.path("s.txt"), "--style", "strip", "--strip", "s", "--prefix", "p", "--min", "1" };
    const o = M.outcome(&argv, "/w");
    try expect(o.code == 1);
    try expect(std.mem.indexOf(u8, o.stderr, "is not an ar archive") != null);
    try expect(std.mem.indexOf(u8, o.stderr, P.fmt("prefix_tool: elfsyms armap {s} failed (", .{w.path("lib.a")})) != null);
    try expect(!w.exists("h.h") and !w.exists("s.txt"));
}

test "header: an output that cannot be written is a refusal that names it" {
    var w = try Work.init(try armapArchive(&.{ "alpha", "beta" }));
    defer w.tmp.cleanup();
    const elfsyms = try elfsymsPath();
    const no_symbols = [_][]const u8{ "prefix_tool", "header", "--elfsyms", elfsyms, "--archive", w.path("lib.a"), "--header", w.path("h.h"), "--symbols", w.path("nodir/s.txt"), "--style", "strip", "--strip", "s", "--prefix", "p", "--min", "1" };
    const a = M.outcome(&no_symbols, "/w");
    try expect(a.code == 1);
    try eqs(P.fmt("prefix_tool: cannot write {s}: FileNotFound\n", .{w.path("nodir/s.txt")}), a.stderr);
    const no_header = [_][]const u8{ "prefix_tool", "header", "--elfsyms", elfsyms, "--archive", w.path("lib.a"), "--header", w.path("nodir/h.h"), "--symbols", w.path("s.txt"), "--style", "strip", "--strip", "s", "--prefix", "p", "--min", "1" };
    const b = M.outcome(&no_header, "/w");
    try expect(b.code == 1);
    try eqs(P.fmt("prefix_tool: cannot write {s}: FileNotFound\n", .{w.path("nodir/h.h")}), b.stderr);
}

test "header and check: a --min that is not a number is refused by the command, before any archive is read" {
    const h = M.outcome(with(header_ok[0 .. header_ok.len - 2], &.{ "--min", "many" }), "/w");
    try expect(h.code == 1);
    try eqs("prefix_tool: --min many is not a number\n", h.stderr);
    const c = M.outcome(with(check_ok[0 .. check_ok.len - 2], &.{ "--min", "-3" }), "/w");
    try expect(c.code == 1);
    try eqs("prefix_tool: --min -3 is not a number\n", c.stderr);
}

test "header: a strip style without a strip, and a prefix that is not an identifier, are refused and write nothing" {
    var w = try Work.init(try armapArchive(&.{ "alpha", "beta" }));
    defer w.tmp.cleanup();
    const elfsyms = try elfsymsPath();
    const no_strip = [_][]const u8{ "prefix_tool", "header", "--elfsyms", elfsyms, "--archive", w.path("lib.a"), "--header", w.path("h.h"), "--symbols", w.path("s.txt"), "--style", "strip", "--prefix", "p", "--min", "1" };
    const a = M.outcome(&no_strip, "/w");
    try expect(a.code == 1);
    try eqs("prefix_header: style strip needs a non-empty strip\n", a.stderr);
    const bad_prefix = [_][]const u8{ "prefix_tool", "header", "--elfsyms", elfsyms, "--archive", w.path("lib.a"), "--header", w.path("h.h"), "--symbols", w.path("s.txt"), "--style", "boringssl", "--prefix", "p-q", "--min", "1" };
    const b = M.outcome(&bad_prefix, "/w");
    try expect(b.code == 1);
    try eqs("prefix_tool: prefix p-q: only letters, digits and _ may be in it\n", b.stderr);
    try expect(!w.exists("h.h") and !w.exists("s.txt"));
}

const green_symbols = [_]Sym{
    .{ .name = "k_one", .bind = GLOBAL, .defined = true },
    .{ .name = "k_two", .bind = GLOBAL, .defined = true },
    .{ .name = "hidden_helper", .bind = LOCAL, .defined = true }, // a local symbol is not the archive's interface
    .{ .name = "memcpy", .bind = GLOBAL, .defined = false },
};

test "check: a prefixed archive is green, and the result and the message say what was found" {
    var w = try Work.init(try objectArchive(&green_symbols));
    defer w.tmp.cleanup();
    try w.tmp.dir.writeFile(.{ .sub_path = "names.txt", .data = "unrelated\n" });
    const argv = [_][]const u8{ "prefix_tool", "check", "--elfsyms", try elfsymsPath(), "--archive", w.path("lib.a"), "--result", w.path("r.json"), "--prefix", "k_", "--min", "2", "--names", w.path("names.txt") };
    const o = M.outcome(&argv, "/w");
    const m = "2 defined symbols start with k_, 2 defined in all (the rest allowed); 0 weak undefined, each prefixed or allowed; no undefined reference among 1 unprefixed names";
    try expect(o.code == 0);
    try eqs("archive_check GREEN: " ++ m ++ " (allowed without the prefix: -)\n", o.stdout);
    try eqs("", o.stderr);
    try eqs("{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"" ++ m ++ "\"}}\n", try w.read("r.json"));
}

test "check: an undefined reference to one of the library's own unprefixed names is red, exits 1 and leaves no result" {
    var w = try Work.init(try objectArchive(&green_symbols));
    defer w.tmp.cleanup();
    try w.tmp.dir.writeFile(.{ .sub_path = "names.txt", .data = "memcpy\n" });
    const argv = [_][]const u8{ "prefix_tool", "check", "--elfsyms", try elfsymsPath(), "--archive", w.path("lib.a"), "--result", w.path("r.json"), "--prefix", "k_", "--min", "2", "--names", w.path("names.txt") };
    const o = M.outcome(&argv, "/w");
    try expect(o.code == 1);
    try eqs("", o.stdout);
    try eqs(P.fmt("archive_check RED: 1 undefined references to the library's own unprefixed names in {s}:\n  memcpy\n", .{w.path("lib.a")}), o.stderr);
    try expect(!w.exists("r.json"));
}

test "check: a defined symbol without the prefix is red unless allowed; a weak undefined one is red too" {
    var w = try Work.init(try objectArchive(&.{
        .{ .name = "k_one", .bind = GLOBAL, .defined = true },
        .{ .name = "stray", .bind = GLOBAL, .defined = true },
        .{ .name = "hook", .bind = WEAK, .defined = false },
    }));
    defer w.tmp.cleanup();
    const elfsyms = try elfsymsPath();
    const red = [_][]const u8{ "prefix_tool", "check", "--elfsyms", elfsyms, "--archive", w.path("lib.a"), "--result", w.path("r.json"), "--prefix", "k_", "--min", "1" };
    const o = M.outcome(&red, "/w");
    try expect(o.code == 1);
    try expect(std.mem.indexOf(u8, o.stderr, "1 defined symbols without the prefix k_ in") != null);
    try expect(std.mem.indexOf(u8, o.stderr, "  stray\n") != null);
    try expect(std.mem.indexOf(u8, o.stderr, "1 weak undefined symbols without the prefix k_ in") != null);
    try expect(std.mem.indexOf(u8, o.stderr, "  hook\n") != null);
    const allowed = [_][]const u8{ "prefix_tool", "check", "--elfsyms", elfsyms, "--archive", w.path("lib.a"), "--result", w.path("r.json"), "--prefix", "k_", "--min", "1", "--allow", "stray", "--allow", "hook" };
    const g = M.outcome(&allowed, "/w");
    try expect(g.code == 0);
    try expect(std.mem.indexOf(u8, g.stdout, "(allowed without the prefix: stray|hook)\n") != null);
}

test "check: a names file that cannot be read, an archive that is not one and a result that cannot be written are refusals that name the file" {
    var w = try Work.init(try objectArchive(&green_symbols));
    defer w.tmp.cleanup();
    const elfsyms = try elfsymsPath();
    const no_names = [_][]const u8{ "prefix_tool", "check", "--elfsyms", elfsyms, "--archive", w.path("lib.a"), "--result", w.path("r.json"), "--prefix", "k_", "--min", "1", "--names", w.path("missing.txt") };
    const a = M.outcome(&no_names, "/w");
    try expect(a.code == 1);
    try eqs(P.fmt("prefix_tool: cannot read {s}: FileNotFound\n", .{w.path("missing.txt")}), a.stderr);
    const no_result = [_][]const u8{ "prefix_tool", "check", "--elfsyms", elfsyms, "--archive", w.path("lib.a"), "--result", w.path("nodir/r.json"), "--prefix", "k_", "--min", "1" };
    const b = M.outcome(&no_result, "/w");
    try expect(b.code == 1);
    try eqs(P.fmt("prefix_tool: cannot write {s}: FileNotFound\n", .{w.path("nodir/r.json")}), b.stderr);
    try w.tmp.dir.writeFile(.{ .sub_path = "text.a", .data = "this is not an archive\n" });
    const bad_archive = [_][]const u8{ "prefix_tool", "check", "--elfsyms", elfsyms, "--archive", w.path("text.a"), "--result", w.path("r.json"), "--prefix", "k_", "--min", "1" };
    const c = M.outcome(&bad_archive, "/w");
    try expect(c.code == 1);
    try expect(std.mem.indexOf(u8, c.stderr, P.fmt("prefix_tool: elfsyms symtab {s} failed (", .{w.path("text.a")})) != null);
}
