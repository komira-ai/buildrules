//! Unit tests of conda_libs.zig (`conda_unpack --all-libs`) on a `.conda` built in memory: a stored zip holding `pkg-*.tar.zst` and `info-*.tar.zst`, each a zstd frame
//! of one raw block over a tar.
//!
//! What is held, and the defect each test would catch:
//!   - the shared libraries of `lib/` come out flat, under every name the package gives them, a link as a copy of the file it resolves to, with the executable bit of that
//!     file, and nothing else does (archives, pkg-config files, headers, a library below `lib/<dir>/`): a program that opens a bare name that is only a link finds a file;
//!   - a link that leaves the directory or loops, an empty file, a member named twice, a library with an install-prefix placeholder (named directly or through a link),
//!     a package without `info/paths.json` and an archive that is corrupt or truncated are refused (integrity), and when any is, nothing is written (not even the directory);
//!   - a placeholder in a file that is not copied (a `.pc`) does not refuse the package;
//!   - a package with no shared library (a metapackage, a tool) unpacks to an empty directory and a link to a file the package does not hold is left out, each with a note
//!     naming the package and no error: a pin is never refused for what the package is, so a lock with such a package builds.
const std = @import("std");
const L = @import("conda_libs.zig");
const t = std.testing;

fn octal(buf: []u8, v: usize) void {
    _ = std.fmt.bufPrint(buf, "{o:0>[1]}", .{ v, buf.len - 1 }) catch unreachable;
    buf[buf.len - 1] = 0;
}

const Ent = struct {
    name: []const u8,
    body: []const u8 = "",
    /// The tar type flag: '0' file, '2' symlink, '5' directory.
    flag: u8 = '0',
    link: []const u8 = "",
    mode: usize = 0o644,
};

fn tar(a: std.mem.Allocator, files: []const Ent) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (files) |f| {
        var h = [_]u8{0} ** 512;
        @memcpy(h[0..f.name.len], f.name);
        octal(h[100..108], f.mode);
        octal(h[108..116], 0);
        octal(h[116..124], 0);
        octal(h[124..136], f.body.len);
        octal(h[136..148], 0);
        @memset(h[148..156], ' ');
        h[156] = f.flag;
        @memcpy(h[157..][0..f.link.len], f.link);
        @memcpy(h[257..262], "ustar");
        h[262] = 0;
        @memcpy(h[263..265], "00");
        var sum: usize = 0;
        for (h) |c| sum += c;
        octal(h[148..155], sum);
        h[154] = 0;
        h[155] = ' ';
        try out.appendSlice(a, &h);
        try out.appendSlice(a, f.body);
        try out.appendNTimes(a, 0, (512 - f.body.len % 512) % 512);
    }
    try out.appendNTimes(a, 0, 1024);
    return out.toOwnedSlice(a);
}

fn zstdRaw(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, &.{ 0x28, 0xb5, 0x2f, 0xfd });
    try out.append(a, 0b10100000);
    var sz: [4]u8 = undefined;
    std.mem.writeInt(u32, &sz, @intCast(data.len), .little);
    try out.appendSlice(a, &sz);
    var bh: [3]u8 = undefined;
    const v: u32 = 1 | (@as(u32, @intCast(data.len)) << 3);
    bh[0] = @truncate(v);
    bh[1] = @truncate(v >> 8);
    bh[2] = @truncate(v >> 16);
    try out.appendSlice(a, &bh);
    try out.appendSlice(a, data);
    return out.toOwnedSlice(a);
}

fn zipStored(a: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, body: []const u8) !void {
    var h = [_]u8{0} ** 30;
    std.mem.writeInt(u32, h[0..4], 0x04034b50, .little);
    std.mem.writeInt(u16, h[4..6], 20, .little);
    std.mem.writeInt(u32, h[18..22], @intCast(body.len), .little);
    std.mem.writeInt(u32, h[22..26], @intCast(body.len), .little);
    std.mem.writeInt(u16, h[26..28], @intCast(name.len), .little);
    try out.appendSlice(a, &h);
    try out.appendSlice(a, name);
    try out.appendSlice(a, body);
}

/// A `.conda` holding `files` as its payload and, unless `paths_json` is null, that text as `info/paths.json`.
fn conda(a: std.mem.Allocator, files: []const Ent, paths_json: ?[]const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try zipStored(a, &out, "pkg-x-1-0.tar.zst", try zstdRaw(a, try tar(a, files)));
    const with = [_]Ent{.{ .name = "info/paths.json", .body = paths_json orelse "" }};
    const without = [_]Ent{.{ .name = "info/index.json", .body = "{}" }};
    const info: []const Ent = if (paths_json != null) &with else &without;
    try zipStored(a, &out, "info-x-1-0.tar.zst", try zstdRaw(a, try tar(a, info)));
    return out.toOwnedSlice(a);
}

const plain_paths = "{\"paths_version\": 1, \"paths\": []}";

fn refused(a: std.mem.Allocator, pkg: []const u8, want: anyerror, words: []const u8) !void {
    var why: []const u8 = "";
    try t.expectError(want, L.collect(a, pkg, &why));
    try t.expect(std.mem.indexOf(u8, why, words) != null);
}

test "isSharedLib: the names of shared objects and dynamic libraries, and nothing a build leaves beside them" {
    for ([_][]const u8{ "libsqlite3.so", "libsqlite3.so.0", "libsqlite3.so.3.54.1", "libz.so.1", "libsqlite3.dylib", "libsqlite3.0.dylib", "libsqlite3.3.54.1.dylib", "libx.dylib.2" }) |n| try t.expect(L.isSharedLib(n));
    for ([_][]const u8{ "libsqlite3.a", "sqlite3.pc", "libx.solution", "libx.so-gdb.py", "libx.dylibs", "x.so", "readme", "libx" }) |n| try t.expect(!L.isSharedLib(n));
}

test "collect: Linux layout: the file and both of its links come out under their own names, as copies, sorted; archives, pkg-config, headers and subdirectories stay out" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pkg = try conda(a, &.{
        .{ .name = "lib/libsqlite3.so.3.54.1", .body = "ELF-BYTES", .mode = 0o755 },
        .{ .name = "lib/libsqlite3.so", .flag = '2', .link = "libsqlite3.so.3.54.1", .mode = 0o777 },
        .{ .name = "lib/libsqlite3.so.0", .flag = '2', .link = "libsqlite3.so.3.54.1", .mode = 0o777 },
        .{ .name = "lib/libsqlite3.a", .body = "archive" },
        .{ .name = "lib/pkgconfig/sqlite3.pc", .body = "prefix=/opt" },
        .{ .name = "lib/cmake/x/plugin.so", .body = "in a subdirectory" },
        .{ .name = "include/sqlite3.h", .body = "header" },
        .{ .name = "lib/", .flag = '5' },
    }, plain_paths);
    var why: []const u8 = "";
    const libs = (try L.collect(a, pkg, &why)).libs;
    try t.expectEqual(@as(usize, 3), libs.len);
    try t.expectEqualStrings("libsqlite3.so", libs[0].name);
    try t.expectEqualStrings("libsqlite3.so.0", libs[1].name);
    try t.expectEqualStrings("libsqlite3.so.3.54.1", libs[2].name);
    for (libs) |l| {
        try t.expectEqualStrings("ELF-BYTES", l.bytes);
        try t.expect(l.executable);
    }
}

test "collect: macOS layout, and a file that is not executable stays so" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pkg = try conda(a, &.{
        .{ .name = "lib/libsqlite3.dylib", .flag = '2', .link = "libsqlite3.3.54.1.dylib" },
        .{ .name = "lib/libsqlite3.3.54.1.dylib", .body = "MACHO", .mode = 0o644 },
        .{ .name = "lib/libsqlite3.0.dylib", .flag = '2', .link = "libsqlite3.3.54.1.dylib" },
    }, plain_paths);
    var why: []const u8 = "";
    const libs = (try L.collect(a, pkg, &why)).libs;
    try t.expectEqual(@as(usize, 3), libs.len);
    for (libs) |l| {
        try t.expectEqualStrings("MACHO", l.bytes);
        try t.expect(!l.executable);
    }
    try t.expectEqualStrings("libsqlite3.0.dylib", libs[0].name);
}

test "collect: a chain of links resolves to the file at its end" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pkg = try conda(a, &.{
        .{ .name = "lib/libx.so", .flag = '2', .link = "libx.so.1" },
        .{ .name = "lib/libx.so.1", .flag = '2', .link = "libx.so.1.2.3" },
        .{ .name = "lib/libx.so.1.2.3", .body = "REAL" },
    }, plain_paths);
    var why: []const u8 = "";
    const libs = (try L.collect(a, pkg, &why)).libs;
    try t.expectEqual(@as(usize, 3), libs.len);
    for (libs) |l| try t.expectEqualStrings("REAL", l.bytes);
}

test "collect: refusals (integrity and a path that escapes), each with its words" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try refused(a, try conda(a, &.{.{ .name = "lib/libx.so", .flag = '2', .link = "../other/libx.so.1" }}, plain_paths), error.LinkLeavesDirectory, "not a file beside it");
    try refused(a, try conda(a, &.{.{ .name = "lib/libx.so", .flag = '2', .link = "/usr/lib/libx.so.1" }}, plain_paths), error.LinkLeavesDirectory, "not a file beside it");
    try refused(a, try conda(a, &.{
        .{ .name = "lib/libx.so", .flag = '2', .link = "libx.so.1" },
        .{ .name = "lib/libx.so.1", .flag = '2', .link = "libx.so" },
    }, plain_paths), error.LinkLoop, "too many links");
    try refused(a, try conda(a, &.{.{ .name = "lib/libx.so", .body = "" }}, plain_paths), error.EmptyMember, "is empty");
    try refused(a, try conda(a, &.{
        .{ .name = "lib/libx.so", .body = "one" },
        .{ .name = "lib/libx.so", .body = "two" },
    }, plain_paths), error.DuplicateMember, "twice");
    try refused(a, try conda(a, &.{.{ .name = "lib/libx.so", .body = "x" }}, null), error.NoMember, "info/paths.json");
    try refused(a, try conda(a, &.{.{ .name = "lib/libx.so", .body = "x" }}, "not json"), error.BadPathsJson, "not JSON");
    try refused(a, try conda(a, &.{.{ .name = "lib/libx.so", .body = "x" }}, "{\"paths_version\": 1}"), error.BadPathsJson, "no `paths` list");
}

test "collect: an install-prefix placeholder refuses the library, named directly or through a link; one in a file that is not copied does not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const direct = "{\"paths\": [{\"_path\": \"lib/libx.so.1\", \"prefix_placeholder\": \"/opt/placeholder\", \"file_mode\": \"binary\"}]}";
    try refused(a, try conda(a, &.{.{ .name = "lib/libx.so.1", .body = "x" }}, direct), error.PrefixPlaceholder, "install-prefix placeholder");
    // the link is clean, the file it resolves to is not
    const through = "{\"paths\": [{\"_path\": \"lib/libx.so\", \"path_type\": \"softlink\"}, {\"_path\": \"lib/libx.so.1\", \"prefix_placeholder\": \"/p\"}]}";
    try refused(a, try conda(a, &.{
        .{ .name = "lib/libx.so", .flag = '2', .link = "libx.so.1" },
        .{ .name = "lib/libx.so.1", .body = "x" },
    }, through), error.PrefixPlaceholder, "lib/libx.so.1");
    const on_pc = "{\"paths\": [{\"_path\": \"lib/pkgconfig/x.pc\", \"prefix_placeholder\": \"/p\"}, {\"_path\": \"lib/libx.so.1\"}]}";
    var why: []const u8 = "";
    const libs = (try L.collect(a, try conda(a, &.{
        .{ .name = "lib/libx.so.1", .body = "x" },
        .{ .name = "lib/pkgconfig/x.pc", .body = "prefix=/p" },
    }, on_pc), &why)).libs;
    try t.expectEqual(@as(usize, 1), libs.len);
}

fn writeConda(dir: std.fs.Dir, name: []const u8, bytes: []const u8) !void {
    try dir.writeFile(.{ .sub_path = name, .data = bytes });
}

test "run: the libraries are regular files of the output directory, with the bytes and the mode of the file they resolve to" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeConda(tmp.dir, "p.conda", try conda(a, &.{
        .{ .name = "lib/libx.so.1.2", .body = "REAL", .mode = 0o755 },
        .{ .name = "lib/libx.so.1", .flag = '2', .link = "libx.so.1.2" },
        .{ .name = "lib/libx.so", .flag = '2', .link = "libx.so.1" },
        .{ .name = "lib/libx.a", .body = "archive" },
    }, plain_paths));
    var why: []const u8 = "";
    var notes: []const []const u8 = &.{};
    try L.run(a, tmp.dir, &.{ "p.conda", "out/libs" }, &why, &notes);
    var d = try tmp.dir.openDir("out/libs", .{ .iterate = true });
    defer d.close();
    var seen: usize = 0;
    var it = d.iterate();
    while (try it.next()) |e| {
        try t.expect(e.kind == .file);
        seen += 1;
    }
    try t.expectEqual(@as(usize, 3), seen);
    for ([_][]const u8{ "libx.so", "libx.so.1", "libx.so.1.2" }) |n| {
        const f = try d.openFile(n, .{});
        defer f.close();
        const st = try f.stat();
        try t.expect(st.mode & 0o100 != 0);
        try t.expectEqualStrings("REAL", try f.readToEndAlloc(a, 64));
    }
    try t.expectError(error.FileNotFound, d.access("libx.a", .{}));
    try t.expectEqual(@as(usize, 0), notes.len);
}

test "run: a refused package writes nothing, not even the directory; a missing package and the wrong arguments are said" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeConda(tmp.dir, "bad.conda", try conda(a, &.{
        .{ .name = "lib/libx.so.1", .body = "fine" },
        .{ .name = "lib/libx.so", .body = "" },
    }, plain_paths));
    var why: []const u8 = "";
    var notes: []const []const u8 = &.{};
    try t.expectError(error.EmptyMember, L.run(a, tmp.dir, &.{ "bad.conda", "out" }, &why, &notes));
    try t.expect(std.mem.indexOf(u8, why, "bad.conda") != null);
    try t.expectError(error.FileNotFound, tmp.dir.access("out", .{}));
    why = "";
    try t.expectError(error.FileNotFound, L.run(a, tmp.dir, &.{ "nothing.conda", "out" }, &why, &notes));
    try t.expect(std.mem.indexOf(u8, why, "cannot read nothing.conda") != null);
    why = "";
    try t.expectError(error.Usage, L.run(a, tmp.dir, &.{"only-one"}, &why, &notes));
    try t.expect(std.mem.indexOf(u8, why, "usage: conda_unpack --all-libs") != null);
}

fn entryCount(dir: std.fs.Dir, sub: []const u8) !usize {
    var d = try dir.openDir(sub, .{ .iterate = true });
    defer d.close();
    var n: usize = 0;
    var it = d.iterate();
    while (try it.next()) |_| n += 1;
    return n;
}

fn noteHas(notes: []const []const u8, words: []const u8) bool {
    for (notes) |n| if (std.mem.indexOf(u8, n, words) != null) return true;
    return false;
}

test "collect: a package with no shared library gives none and a note, not an error (a metapackage, headers and archives only)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const got = try L.collect(a, try conda(a, &.{
        .{ .name = "lib/libx.a", .body = "archive" },
        .{ .name = "lib/pkgconfig/x.pc", .body = "pc" },
        .{ .name = "include/x.h", .body = "header" },
    }, plain_paths), &why);
    try t.expectEqual(@as(usize, 0), got.libs.len);
    try t.expectEqual(@as(usize, 1), got.notes.len);
    try t.expect(noteHas(got.notes, "no shared library"));
    // nothing at all in the package, not even a lib/: the same
    const bare = try L.collect(a, try conda(a, &.{.{ .name = "info/about.json", .body = "{}" }}, plain_paths), &why);
    try t.expectEqual(@as(usize, 0), bare.libs.len);
    try t.expect(noteHas(bare.notes, "no shared library"));
}

test "collect: a link to a file the package does not hold is left out with a note; the libraries beside it are kept" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    // the -devel case: the unversioned name links to the library the runtime package holds
    const devel = try L.collect(a, try conda(a, &.{
        .{ .name = "lib/liblzma.so", .flag = '2', .link = "liblzma.so.5" },
        .{ .name = "lib/liblzma.a", .body = "archive" },
    }, plain_paths), &why);
    try t.expectEqual(@as(usize, 0), devel.libs.len);
    try t.expect(noteHas(devel.notes, "lib/liblzma.so is a link to liblzma.so.5, which the package does not hold"));
    try t.expect(noteHas(devel.notes, "no shared library"));
    // a chain that ends in nothing is left out whole; a file of the same package stays
    const mixed = try L.collect(a, try conda(a, &.{
        .{ .name = "lib/libx.so", .flag = '2', .link = "libx.so.1" },
        .{ .name = "lib/libx.so.1", .flag = '2', .link = "libx.so.1.2" },
        .{ .name = "lib/liby.so.3", .body = "Y" },
    }, plain_paths), &why);
    try t.expectEqual(@as(usize, 1), mixed.libs.len);
    try t.expectEqualStrings("liby.so.3", mixed.libs[0].name);
    try t.expect(noteHas(mixed.notes, "lib/libx.so is a link to libx.so.1.2"));
    try t.expect(noteHas(mixed.notes, "lib/libx.so.1 is a link to libx.so.1.2"));
    try t.expect(!noteHas(mixed.notes, "liby"));
}

test "collect: a placeholder in a library still refuses when another link of the package is left out" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const direct = "{\"paths\": [{\"_path\": \"lib/liby.so.3\", \"prefix_placeholder\": \"/opt/p\"}]}";
    try refused(a, try conda(a, &.{
        .{ .name = "lib/libx.so", .flag = '2', .link = "missing" },
        .{ .name = "lib/liby.so.3", .body = "Y" },
    }, direct), error.PrefixPlaceholder, "lib/liby.so.3");
}

test "collect: a corrupt or truncated archive is refused, not noted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const good = try conda(a, &.{.{ .name = "lib/libx.so", .body = "x" }}, plain_paths);
    if (L.collect(a, good[0 .. good.len / 2], &why)) |_| return error.TestExpectedAnError else |_| {}
    if (L.collect(a, "this is not a conda package", &why)) |_| return error.TestExpectedAnError else |_| {}
    if (L.collect(a, "", &why)) |_| return error.TestExpectedAnError else |_| {}
}

test "run: a package with no library leaves an empty output directory and a note naming the package; a dangling link leaves the rest" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try writeConda(tmp.dir, "meta.conda", try conda(a, &.{.{ .name = "bin/xz", .body = "tool" }}, plain_paths));
    var why: []const u8 = "";
    var notes: []const []const u8 = &.{};
    try L.run(a, tmp.dir, &.{ "--package", "xz", "meta.conda", "out/xz" }, &why, &notes);
    try t.expectEqual(@as(usize, 0), try entryCount(tmp.dir, "out/xz"));
    try t.expectEqual(@as(usize, 1), notes.len);
    try t.expect(std.mem.startsWith(u8, notes[0], "xz: "));
    try t.expect(noteHas(notes, "no shared library"));

    // without the name the file is named
    notes = &.{};
    try L.run(a, tmp.dir, &.{ "meta.conda", "out/bare" }, &why, &notes);
    try t.expect(std.mem.startsWith(u8, notes[0], "meta.conda: "));

    try writeConda(tmp.dir, "part.conda", try conda(a, &.{
        .{ .name = "lib/liby.so.3", .body = "Y" },
        .{ .name = "lib/liby.so", .flag = '2', .link = "liby.so.3" },
        .{ .name = "lib/libz.so", .flag = '2', .link = "libz.so.1" },
    }, plain_paths));
    notes = &.{};
    try L.run(a, tmp.dir, &.{ "--package", "part", "part.conda", "out/part" }, &why, &notes);
    try t.expectEqual(@as(usize, 2), try entryCount(tmp.dir, "out/part"));
    try t.expectError(error.FileNotFound, tmp.dir.access("out/part/libz.so", .{}));
    try t.expectEqual(@as(usize, 1), notes.len);
    try t.expect(std.mem.startsWith(u8, notes[0], "part: lib/libz.so is a link to libz.so.1"));
}

test "run: a truncated archive writes nothing, not even the directory" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const good = try conda(a, &.{.{ .name = "lib/libx.so", .body = "x" }}, plain_paths);
    try writeConda(tmp.dir, "cut.conda", good[0 .. good.len / 2]);
    var why: []const u8 = "";
    var notes: []const []const u8 = &.{};
    if (L.run(a, tmp.dir, &.{ "--package", "cut", "cut.conda", "out" }, &why, &notes)) |_| return error.TestExpectedAnError else |_| {}
    try t.expectError(error.FileNotFound, tmp.dir.access("out", .{}));
    try t.expectEqual(@as(usize, 0), notes.len);
}
