//! tar.zig: what a tar extracts to, and every refusal. The archives are written by testkit.zig; the destination is a temporary directory.
const std = @import("std");
const kit = @import("testkit.zig");
const tar = @import("tar.zig");
const extract = @import("extract.zig");
const t = std.testing;
const a = kit.a;

fn expectListing(d: *kit.Dest, want: []const u8) !void {
    const got = try d.listing();
    defer a.free(got);
    try t.expectEqualStrings(want, got);
}

fn expectFile(d: *kit.Dest, path: []const u8, want: []const u8) !void {
    const got = try d.read(path);
    defer a.free(got);
    try t.expectEqualStrings(want, got);
}

/// A tar with a few ordinary entries.
fn sample() !kit.Tar {
    var b = kit.Tar{};
    errdefer b.deinit();
    try b.dir("pkg/");
    try b.file("pkg/bin/tool", 0o755, "#!tool\n");
    try b.file("pkg/README", 0o644, "read me\n");
    try b.file("pkg/empty", 0o644, "");
    try b.end();
    return b;
}

test "files, directories and their bytes" {
    var b = try sample();
    defer b.deinit();
    var d = kit.Dest.init();
    defer d.deinit();
    const stats = try d.unpack(b.bytes(), .tar, 0);
    try t.expectEqual(@as(u64, 3), stats.files);
    try t.expectEqual(@as(u64, 1), stats.dirs);
    try t.expectEqual(@as(u64, 7 + 8), stats.bytes);
    try expectFile(&d, "pkg/bin/tool", "#!tool\n");
    try expectFile(&d, "pkg/README", "read me\n");
    try expectFile(&d, "pkg/empty", "");
    try expectListing(&d, "pkg/\npkg/README\npkg/bin/\npkg/bin/tool\npkg/empty\n");
}

test "strip-components drops the leading directories, and entries with none left are skipped with their data" {
    var b = try sample();
    defer b.deinit();
    var d = kit.Dest.init();
    defer d.deinit();
    const stats = try d.unpack(b.bytes(), .tar, 1);
    try t.expectEqual(@as(u64, 3), stats.files);
    try expectListing(&d, "README\nbin/\nbin/tool\nempty\n");
    var d2 = kit.Dest.init();
    defer d2.deinit();
    // two stripped: only bin/tool's name has two components, so only `tool` remains
    _ = try d2.unpack(b.bytes(), .tar, 2);
    try expectListing(&d2, "tool\n");
    // a file with data that is stripped away must leave the stream in step with the next entry
    var s = kit.Tar{};
    defer s.deinit();
    try s.file("top", 0o644, "x" ** 700);
    try s.file("keep/inner", 0o644, "kept");
    try s.end();
    var d3 = kit.Dest.init();
    defer d3.deinit();
    _ = try d3.unpack(s.bytes(), .tar, 1);
    try expectListing(&d3, "inner\n");
    try expectFile(&d3, "inner", "kept");
}

test "permission bits are kept: executables stay executable, and set-uid is dropped" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.file("run", 0o755, "x");
    try b.file("plain", 0o644, "x");
    try b.file("private", 0o600, "x");
    try b.file("readonly", 0o444, "data");
    try b.file("group_x", 0o710, "x");
    try b.file("setuid", 0o4755, "x");
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(b.bytes(), .tar, 0);
    try t.expectEqual(@as(u32, 0o755), try d.mode("run"));
    try t.expectEqual(@as(u32, 0o644), try d.mode("plain"));
    try t.expectEqual(@as(u32, 0o600), try d.mode("private"));
    try t.expectEqual(@as(u32, 0o444), try d.mode("readonly"));
    try t.expectEqual(@as(u32, 0o710), try d.mode("group_x"));
    try t.expectEqual(@as(u32, 0o755), try d.mode("setuid"));
    try expectFile(&d, "readonly", "data");
}

test "symbolic links are kept as links, with their targets" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.dir("lib/");
    try b.file("lib/libz.so.1.3", 0o755, "ELF");
    try b.symlink("lib/libz.so.1", "libz.so.1.3");
    try b.symlink("lib/libz.so", "libz.so.1");
    try b.symlink("current", "lib");
    try b.dir("lib/sub/");
    try b.symlink("lib/sub/up", "../libz.so.1.3");
    try b.symlink("dangling", "nowhere/at/all");
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    const stats = try d.unpack(b.bytes(), .tar, 0);
    try t.expectEqual(@as(u64, 5), stats.links);
    try expectListing(&d, "current -> lib\ndangling -> nowhere/at/all\nlib/\nlib/libz.so -> libz.so.1\nlib/libz.so.1 -> libz.so.1.3\nlib/libz.so.1.3\nlib/sub/\nlib/sub/up -> ../libz.so.1.3\n");
    try t.expect(d.isLink("lib/libz.so"));
    try expectFile(&d, "lib/libz.so", "ELF");
}

test "hard links become copies of the file they name, with its mode" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.file("pkg/bin/real", 0o755, "program");
    try b.hardlink("pkg/bin/alias", "pkg/bin/real");
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(b.bytes(), .tar, 0);
    try expectFile(&d, "pkg/bin/alias", "program");
    try t.expectEqual(@as(u32, 0o755), try d.mode("pkg/bin/alias"));
    // under strip, the link's target is stripped as its name is
    var d2 = kit.Dest.init();
    defer d2.deinit();
    _ = try d2.unpack(b.bytes(), .tar, 1);
    try expectFile(&d2, "bin/alias", "program");
}

test "hard links: a missing target, a link as target and a directory as target are refused" {
    var missing = kit.Tar{};
    defer missing.deinit();
    try missing.hardlink("alias", "real");
    try missing.end();
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.FileNotFound, d.unpack(missing.bytes(), .tar, 0));

    var viasym = kit.Tar{};
    defer viasym.deinit();
    try viasym.file("real", 0o644, "x");
    try viasym.symlink("sym", "real");
    try viasym.hardlink("alias", "sym");
    try viasym.end();
    var d2 = kit.Dest.init();
    defer d2.deinit();
    try t.expectError(error.LinkToLink, d2.unpack(viasym.bytes(), .tar, 0));

    var viadir = kit.Tar{};
    defer viadir.deinit();
    try viadir.dir("sub/");
    try viadir.hardlink("alias", "sub");
    try viadir.end();
    var d3 = kit.Dest.init();
    defer d3.deinit();
    try t.expectError(error.NotAFile, d3.unpack(viadir.bytes(), .tar, 0));

    var gone = kit.Tar{};
    defer gone.deinit();
    try gone.file("only", 0o644, "x");
    try gone.hardlink("d/alias", "only");
    try gone.end();
    var d4 = kit.Dest.init();
    defer d4.deinit();
    // the target is stripped away: nothing is left to link to
    try t.expectError(error.EmptyName, d4.unpack(gone.bytes(), .tar, 1));
}

/// That `slip` extracts nothing and is refused with `err`, and that nothing appeared above the destination.
fn expectSlip(err: anyerror, slip: []const u8, strip: usize) !void {
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(err, d.unpack(slip, .tar, strip));
    try t.expect(!d.has("evil"));
    try t.expect(!d.has("../evil"));
    try t.expectError(error.FileNotFound, d.tmp.parent_dir.access("evil", .{}));
}

test "tar-slip: a name with .. is refused wherever it is" {
    for ([_][]const u8{ "../evil", "a/../../evil", "pkg/../../evil", "a/b/../../../evil", "./../evil" }) |name| {
        var b = kit.Tar{};
        defer b.deinit();
        try b.file(name, 0o644, "pwned");
        try b.end();
        try expectSlip(error.ParentComponent, b.bytes(), 0);
    }
}

test "tar-slip: stripping components does not launder a .. name" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.file("../evil", 0o644, "pwned");
    try b.end();
    try expectSlip(error.ParentComponent, b.bytes(), 1);
    var c = kit.Tar{};
    defer c.deinit();
    try c.file("pkg/../../evil", 0o644, "pwned");
    try c.end();
    try expectSlip(error.ParentComponent, c.bytes(), 2);
}

test "tar-slip: an absolute name is refused" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.file("/tmp/evil_from_unpack_test", 0o644, "pwned");
    try b.end();
    try expectSlip(error.AbsolutePath, b.bytes(), 0);
    try expectSlip(error.AbsolutePath, b.bytes(), 1);
    var dir = kit.Tar{};
    defer dir.deinit();
    try dir.dir("/etc/");
    try dir.end();
    try expectSlip(error.AbsolutePath, dir.bytes(), 0);
}

test "tar-slip: directories and links are named by the same rule" {
    var d1 = kit.Tar{};
    defer d1.deinit();
    try d1.dir("../evil/");
    try d1.end();
    try expectSlip(error.ParentComponent, d1.bytes(), 0);
    var l1 = kit.Tar{};
    defer l1.deinit();
    try l1.symlink("../evil", "x");
    try l1.end();
    try expectSlip(error.ParentComponent, l1.bytes(), 0);
    var h1 = kit.Tar{};
    defer h1.deinit();
    try h1.file("ok", 0o644, "x");
    try h1.hardlink("copy", "../../etc/passwd");
    try h1.end();
    try expectSlip(error.ParentComponent, h1.bytes(), 0);
}

test "tar-slip: a long name (GNU or pax) is checked as well" {
    var g = kit.Tar{};
    defer g.deinit();
    try g.gnuLong('L', "../evil");
    try g.file("short", 0o644, "pwned");
    try g.end();
    try expectSlip(error.ParentComponent, g.bytes(), 0);
    var p = kit.Tar{};
    defer p.deinit();
    try p.pax(&.{.{ "path", "/evil" }});
    try p.file("short", 0o644, "pwned");
    try p.end();
    try expectSlip(error.AbsolutePath, p.bytes(), 0);
}

test "tar-slip: a symbolic link that points out of the destination is refused" {
    for ([_][]const u8{ "/etc", "../..", "../outside", "sub/../../x" }) |target| {
        var b = kit.Tar{};
        defer b.deinit();
        try b.symlink("link", target);
        try b.end();
        try expectSlip(error.LinkEscapes, b.bytes(), 0);
    }
    var deep = kit.Tar{};
    defer deep.deinit();
    try deep.symlink("a/b/link", "../../../x");
    try deep.end();
    try expectSlip(error.LinkEscapes, deep.bytes(), 0);
}

test "tar-slip: a link to . and a name through it cannot reach above the destination" {
    // `s -> .` then `t -> s/..` would be the destination's parent
    var b = kit.Tar{};
    defer b.deinit();
    try b.symlink("s", ".");
    try b.symlink("t", "s/..");
    try b.end();
    try expectSlip(error.LinkEscapes, b.bytes(), 0);
}

test "tar-slip: an entry is never written through a symbolic link an earlier entry made" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.dir("real/");
    try b.symlink("alias", "real");
    try b.file("alias/evil", 0o644, "pwned");
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.ThroughSymlink, d.unpack(b.bytes(), .tar, 0));
    try t.expect(!d.has("real/evil"));
    // and a directory entry the same
    var c = kit.Tar{};
    defer c.deinit();
    try c.dir("real/");
    try c.symlink("alias", "real");
    try c.dir("alias/inner/");
    try c.end();
    var d2 = kit.Dest.init();
    defer d2.deinit();
    try t.expectError(error.ThroughSymlink, d2.unpack(c.bytes(), .tar, 0));
}

test "a file that replaces a symbolic link replaces the link, and does not write through it" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.file("target", 0o644, "original");
    try b.symlink("name", "target");
    try b.file("name", 0o644, "replacement");
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(b.bytes(), .tar, 0);
    try expectFile(&d, "target", "original");
    try expectFile(&d, "name", "replacement");
    try t.expect(!d.isLink("name"));
}

test "a later entry of the same name replaces an earlier one; a file cannot replace a directory" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.file("f", 0o755, "first");
    try b.file("f", 0o644, "second");
    try b.symlink("l", "f");
    try b.symlink("l", "g");
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(b.bytes(), .tar, 0);
    try expectFile(&d, "f", "second");
    try t.expectEqual(@as(u32, 0o644), try d.mode("f"));
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("g", try d.link("l", &buf));

    var c = kit.Tar{};
    defer c.deinit();
    try c.dir("d/");
    try c.file("d", 0o644, "x");
    try c.end();
    var d2 = kit.Dest.init();
    defer d2.deinit();
    try t.expectError(error.IsDir, d2.unpack(c.bytes(), .tar, 0));
}

test "GNU long names and long link targets" {
    const long = "very/" ** 40 ++ "deep/name";
    var b = kit.Tar{};
    defer b.deinit();
    try b.gnuLong('L', long);
    try b.file("truncated-name-in-header", 0o644, "long file");
    try b.gnuLong('L', long ++ "-link");
    try b.gnuLong('K', "very/" ** 30 ++ "target");
    try b.add(.{ .name = "ignored", .typeflag = '2', .link = "ignored" });
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(b.bytes(), .tar, 0);
    try expectFile(&d, long, "long file");
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("very/" ** 30 ++ "target", try d.link(long ++ "-link", &buf));
    try t.expect(!d.has("truncated-name-in-header"));
    try t.expect(!d.has("ignored"));
}

test "pax headers: path, linkpath and size; other records are ignored" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.pax(&.{ .{ "path", "dir/from_pax" }, .{ "mtime", "1234.5" }, .{ "uid", "1000" } });
    try b.add(.{ .name = "short", .data = "pax data" });
    try b.pax(&.{ .{ "linkpath", "from_pax" }, .{ "path", "dir/the_link" } });
    try b.add(.{ .name = "x", .typeflag = '2', .link = "no" });
    // the header says 0 bytes, the pax record says 9
    try b.pax(&.{ .{ "size", "9" }, .{ "path", "dir/sized" } });
    try b.add(.{ .name = "y", .size = 0, .data = "nine byte", .no_data = true });
    try b.out.appendSlice(a, "nine byte" ++ "\x00" ** 503);
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(b.bytes(), .tar, 0);
    try expectFile(&d, "dir/from_pax", "pax data");
    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("from_pax", try d.link("dir/the_link", &buf));
    try expectFile(&d, "dir/sized", "nine byte");
    try t.expect(!d.has("short"));
}

test "a pax global header is skipped" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.add(.{ .name = "pax_global_header", .typeflag = 'g', .data = "52 comment=2b5b6a1c19fd41d8b6dcd5bc8c0f8e0ac8b2d0c0\n" });
    try b.file("f", 0o644, "x");
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(b.bytes(), .tar, 0);
    try expectFile(&d, "f", "x");
}

test "pax headers that are malformed are refused" {
    for ([_][]const u8{
        "nolength\n",
        "99 path=x\n",
        "3 a\n",
        "xx path=y\n",
        "11 pathxyz\n",
        "11 path=abc",
        "12 size=abc\n",
    }) |rec| {
        var b = kit.Tar{};
        defer b.deinit();
        try b.add(.{ .name = "PaxHeader", .typeflag = 'x', .data = rec });
        try b.file("f", 0o644, "x");
        try b.end();
        var d = kit.Dest.init();
        defer d.deinit();
        try t.expectError(error.BadPax, d.unpack(b.bytes(), .tar, 0));
    }
}

test "the ustar prefix field is joined to the name; a GNU header's is not" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.add(.{ .name = "leaf", .prefix = "some/long/dir", .data = "ustar" });
    try b.add(.{ .name = "gnu_leaf", .prefix = "ignored", .magic = "ustar  \x00", .data = "gnu" });
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(b.bytes(), .tar, 0);
    try expectFile(&d, "some/long/dir/leaf", "ustar");
    try expectFile(&d, "gnu_leaf", "gnu");
}

test "a size in the binary form, and a directory named by a trailing slash" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.add(.{ .name = "big", .data = "binary size", .binary_size = true });
    try b.add(.{ .name = "old_dir/", .typeflag = 0 });
    try b.add(.{ .name = "old_dir/file", .typeflag = 0, .data = "v7" });
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(b.bytes(), .tar, 0);
    try expectFile(&d, "big", "binary size");
    try expectFile(&d, "old_dir/file", "v7");
}

test "a name the same as a directory's made earlier is fine; directories repeat" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.dir("d/");
    try b.dir("d/");
    try b.file("d/f", 0o644, "x");
    try b.dir("d/sub/");
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    const stats = try d.unpack(b.bytes(), .tar, 0);
    try t.expectEqual(@as(u64, 3), stats.dirs);
    try expectListing(&d, "d/\nd/f\nd/sub/\n");
}

test "entries are refused by type: devices, FIFOs, sparse files and unknown types" {
    for ([_]u8{ '3', '4', '6', 'S', 'A', 'V', 'M', 'z' }) |kind| {
        var b = kit.Tar{};
        defer b.deinit();
        try b.add(.{ .name = "node", .typeflag = kind });
        try b.end();
        var d = kit.Dest.init();
        defer d.deinit();
        try t.expectError(error.UnsupportedType, d.unpack(b.bytes(), .tar, 0));
    }
}

test "a header whose checksum is wrong, or whose number is not one, is refused" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.add(.{ .name = "f", .data = "x", .bad_sum = true });
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.BadChecksum, d.unpack(b.bytes(), .tar, 0));

    // a size field with a letter in it (the checksum is recomputed so only the number is wrong)
    var h = try kit.Tar.header(.{ .name = "f", .data = "x" });
    h[124] = 'z';
    var sum: u32 = 0;
    for (&h, 0..) |c, i| sum += if (i >= 148 and i < 156) ' ' else c;
    _ = try std.fmt.bufPrint(h[148..155], "{o:0>6}", .{sum});
    var d2 = kit.Dest.init();
    defer d2.deinit();
    try t.expectError(error.BadNumber, d2.unpack(&h, .tar, 0));

    // a binary size too big for 64 bits
    var big = try kit.Tar.header(.{ .name = "f", .data = "x", .binary_size = true });
    big[125] = 1; // more than eight bytes of significance
    sum = 0;
    for (&big, 0..) |c, i| sum += if (i >= 148 and i < 156) ' ' else c;
    _ = try std.fmt.bufPrint(big[148..155], "{o:0>6}", .{sum});
    var d3 = kit.Dest.init();
    defer d3.deinit();
    try t.expectError(error.BadNumber, d3.unpack(&big, .tar, 0));
}

test "numbers: octal, padded with spaces or NULs, and refused when anything else follows" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.add(.{ .name = "f", .data = "x" });
    try b.end();
    // size field written as ` 1 ` padded with spaces, mode as `  644 `
    var h = try kit.Tar.header(.{ .name = "f", .data = "x" });
    @memcpy(h[124..136], "          1 ");
    @memcpy(h[100..108], "    644 ");
    var sum: u32 = 0;
    for (&h, 0..) |c, i| sum += if (i >= 148 and i < 156) ' ' else c;
    _ = try std.fmt.bufPrint(h[148..155], "{o:0>6}", .{sum});
    var tarball = std.ArrayList(u8).empty;
    defer tarball.deinit(a);
    try tarball.appendSlice(a, &h);
    try tarball.append(a, 'x');
    try tarball.appendNTimes(a, 0, 511 + 1024);
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(tarball.items, .tar, 0);
    try expectFile(&d, "f", "x");
    try t.expectEqual(@as(u32, 0o644), try d.mode("f"));
    // a trailing letter after the digits
    @memcpy(h[124..136], "1x          ");
    sum = 0;
    for (&h, 0..) |c, i| sum += if (i >= 148 and i < 156) ' ' else c;
    _ = try std.fmt.bufPrint(h[148..155], "{o:0>6}", .{sum});
    var d2 = kit.Dest.init();
    defer d2.deinit();
    try t.expectError(error.BadNumber, d2.unpack(&h, .tar, 0));
}

test "the end of the archive: zero blocks, then only zeros" {
    var b = try sample();
    defer b.deinit();
    var padded = std.ArrayList(u8).empty;
    defer padded.deinit(a);
    try padded.appendSlice(a, b.bytes());
    try padded.appendNTimes(a, 0, 10240);
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(padded.items, .tar, 0);
    // anything but zeros after it is refused
    try padded.append(a, 'x');
    var d2 = kit.Dest.init();
    defer d2.deinit();
    try t.expectError(error.DataAfterEnd, d2.unpack(padded.items, .tar, 0));
}

test "one zero block and then another entry is refused; one zero block and the end is a cut-off" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.file("a", 0o644, "x");
    try b.out.appendNTimes(a, 0, 512);
    try b.file("b", 0o644, "y");
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.LoneZeroBlock, d.unpack(b.bytes(), .tar, 0));

    var c = kit.Tar{};
    defer c.deinit();
    try c.file("a", 0o644, "x");
    try c.out.appendNTimes(a, 0, 512);
    var d2 = kit.Dest.init();
    defer d2.deinit();
    try t.expectError(error.TruncatedArchive, d2.unpack(c.bytes(), .tar, 0));
}

test "an archive with no entry is refused, with or without its zero blocks" {
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.EmptyArchive, d.unpack("", .tar, 0));
    var b = kit.Tar{};
    defer b.deinit();
    try b.end();
    try t.expectError(error.EmptyArchive, d.unpack(b.bytes(), .tar, 0));
}

test "an archive may end after an entry without its zero blocks, as tar allows" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.file("a", 0o644, "x");
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(b.bytes(), .tar, 0);
}

test "truncated tar: a cut inside a header, its data or its padding is refused" {
    var b = try sample();
    defer b.deinit();
    const bytes = b.bytes();
    // entry boundaries: pkg/ 0..512, bin/tool 512..1536, README 1536..2560, empty 2560..3072, then the zero blocks
    const boundaries = [_]usize{ 0, 512, 1536, 2560, 3072 };
    var cut: usize = 1;
    while (cut < 3072) : (cut += 1) {
        var on_boundary = false;
        for (boundaries) |bd| on_boundary = on_boundary or bd == cut;
        if (on_boundary) {
            _ = try kit.Dest.check(bytes[0..cut], .tar, 0);
        } else {
            t.expectError(error.TruncatedArchive, kit.Dest.check(bytes[0..cut], .tar, 0)) catch |e| {
                std.debug.print("a tar cut at {d} gave {s}\n", .{ cut, @errorName(e) });
                return e;
            };
        }
    }
}

test "truncated tar: data cut off with no padding is refused as well" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.add(.{ .name = "f", .data = "123", .no_pad = true });
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.TruncatedArchive, d.unpack(b.bytes(), .tar, 0));
    var c = kit.Tar{};
    defer c.deinit();
    try c.add(.{ .name = "f", .size = 600, .no_data = true });
    var d2 = kit.Dest.init();
    defer d2.deinit();
    try t.expectError(error.TruncatedArchive, d2.unpack(c.bytes(), .tar, 0));
}

test "a long-name or pax entry with no entry after it is a cut-off archive" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.gnuLong('L', "name");
    try b.file("x", 0o644, "x");
    try b.gnuLong('L', "dangling");
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.TruncatedArchive, d.unpack(b.bytes(), .tar, 0));
}

test "a long-name or pax header over a mebibyte is refused" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.add(.{ .name = "././@LongLink", .typeflag = 'L', .size = (1 << 20) + 1, .no_data = true });
    var d = kit.Dest.init();
    defer d.deinit();
    try t.expectError(error.HeaderTooLarge, d.unpack(b.bytes(), .tar, 0));
}

test "the stream may be cut anywhere into pieces: the result is the same" {
    var b = try sample();
    defer b.deinit();
    for ([_]usize{ 1, 7, 511, 512, 513, 1000 }) |piece| {
        var d = kit.Dest.init();
        defer d.deinit();
        var ex = extract.Extractor.init(a, d.tmp.dir, 0);
        defer ex.deinit();
        var p = tar.Parser.init(a, &ex);
        defer p.deinit();
        var at: usize = 0;
        while (at < b.bytes().len) : (at += piece) try p.write(b.bytes()[at..@min(at + piece, b.bytes().len)]);
        try p.finish();
        try expectListing(&d, "pkg/\npkg/README\npkg/bin/\npkg/bin/tool\npkg/empty\n");
        try expectFile(&d, "pkg/bin/tool", "#!tool\n");
    }
}

test "check mode applies every rule and writes nothing" {
    var b = try sample();
    defer b.deinit();
    const stats = try kit.Dest.check(b.bytes(), .tar, 0);
    try t.expectEqual(@as(u64, 3), stats.files);
    var slip = kit.Tar{};
    defer slip.deinit();
    try slip.file("../evil", 0o644, "x");
    try slip.end();
    try t.expectError(error.ParentComponent, kit.Dest.check(slip.bytes(), .tar, 0));
    var link = kit.Tar{};
    defer link.deinit();
    try link.symlink("l", "/etc");
    try link.end();
    try t.expectError(error.LinkEscapes, kit.Dest.check(link.bytes(), .tar, 0));
    var hl = kit.Tar{};
    defer hl.deinit();
    try hl.file("a", 0o644, "x");
    try hl.hardlink("b", "a");
    try hl.end();
    _ = try kit.Dest.check(hl.bytes(), .tar, 0);
}

test "a refusal names the entry that caused it" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.file("fine", 0o644, "x");
    try b.file("pkg/../../evil", 0o644, "x");
    try b.end();
    var d = kit.Dest.init();
    defer d.deinit();
    var ex = extract.Extractor.init(a, d.tmp.dir, 0);
    defer ex.deinit();
    var p = tar.Parser.init(a, &ex);
    defer p.deinit();
    try t.expectError(error.ParentComponent, p.write(b.bytes()));
    try t.expectEqualStrings("pkg/../../evil", ex.lastName());
}
