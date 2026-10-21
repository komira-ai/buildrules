//! extract.zig: the rules about what is written and where, on the Extractor itself (the archive formats exercise them through tar.zig and zip.zig).
const std = @import("std");
const kit = @import("testkit.zig");
const extract = @import("extract.zig");
const t = std.testing;
const a = kit.a;

test "a directory the destination already holds as a link is not written through" {
    var d = kit.Dest.init();
    defer d.deinit();
    try d.tmp.dir.makeDir("outside");
    try d.tmp.dir.symLink("outside", "up", .{});
    var ex = extract.Extractor.init(a, d.tmp.dir, 0);
    defer ex.deinit();
    try t.expectError(error.ThroughSymlink, ex.createFile("up/evil", 0o644));
    try t.expectError(error.ThroughSymlink, ex.mkdir("up/sub"));
    try t.expect(!d.has("outside/evil"));
}

test "a file where a directory is needed is refused; a directory already there is used" {
    var d = kit.Dest.init();
    defer d.deinit();
    try d.tmp.dir.writeFile(.{ .sub_path = "file", .data = "x" });
    try d.tmp.dir.makeDir("dir");
    var ex = extract.Extractor.init(a, d.tmp.dir, 0);
    defer ex.deinit();
    try t.expectError(error.NotADirectory, ex.mkdir("file/inner"));
    try ex.mkdir("dir");
    var out = try ex.createFile("dir/new", 0o640);
    try out.write("abc");
    out.close();
    out.close();
    const got = try d.read("dir/new");
    defer a.free(got);
    try t.expectEqualStrings("abc", got);
    try t.expectEqual(@as(u32, 0o640), try d.mode("dir/new"));
}

test "a file cannot replace a directory, and an entry's parents are made once" {
    var d = kit.Dest.init();
    defer d.deinit();
    var ex = extract.Extractor.init(a, d.tmp.dir, 0);
    defer ex.deinit();
    try ex.mkdir("a/b/c");
    try t.expectError(error.IsDir, ex.createFile("a/b", 0o644));
    var one = try ex.createFile("a/b/c/f1", 0o644);
    one.close();
    var two = try ex.createFile("a/b/c/f2", 0o644);
    two.close();
    try t.expectEqual(@as(u64, 2), ex.stats.files);
    try t.expectEqual(@as(u64, 1), ex.stats.dirs);
}

test "a dry run applies the name and link rules and writes nothing" {
    var ex = extract.Extractor.init(a, null, 0);
    defer ex.deinit();
    try ex.mkdir("a/b");
    var out = try ex.createFile("a/b/f", 0o644);
    try out.write("ignored");
    out.close();
    try ex.symlink("a/l", "b");
    try t.expectError(error.LinkEscapes, ex.symlink("a/l2", "../../x"));
    try ex.hardlink("a/h", "a/b/f");
    try t.expectEqual(@as(u64, 2), ex.stats.files);
    try t.expectEqual(@as(u64, 1), ex.stats.links);
    try t.expectEqual(@as(u64, 1), ex.stats.dirs);
}

test "the name of the entry in hand is kept for the message, cut to 200 bytes" {
    var ex = extract.Extractor.init(a, null, 0);
    defer ex.deinit();
    ex.note("short/name");
    try t.expectEqualStrings("short/name", ex.lastName());
    const long = "x" ** 300;
    ex.note(long);
    try t.expectEqual(@as(usize, 200), ex.lastName().len);
    try t.expectEqual(@as(u64, 2), ex.entries);
}

test "a component too long for the file system is the file system's refusal" {
    var d = kit.Dest.init();
    defer d.deinit();
    var ex = extract.Extractor.init(a, d.tmp.dir, 0);
    defer ex.deinit();
    try t.expectError(error.NameTooLong, ex.mkdir("x" ** 300));
}
