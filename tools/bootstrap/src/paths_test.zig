//! paths.zig: the cleaned path of an entry, and the refusals that keep it inside the destination.
const std = @import("std");
const paths = @import("paths.zig");
const t = std.testing;

fn clean(name: []const u8, strip: usize) !?[]const u8 {
    const S = struct {
        var buf: [paths.max_path]u8 = undefined;
    };
    return paths.clean(name, strip, &S.buf);
}

test "a plain relative path is kept" {
    try t.expectEqualStrings("a/b/c", (try clean("a/b/c", 0)).?);
}

test "empty components are not counted and . is not kept" {
    try t.expectEqualStrings("a/b", (try clean("./a//b/./", 0)).?);
}

test "a . counts as a component under strip, as in GNU tar" {
    try t.expectEqualStrings("a/b", (try clean("./a/b", 1)).?);
    try t.expectEqualStrings("b", (try clean("./a/b", 2)).?);
    try t.expectEqualStrings("b", (try clean("a/./b", 2)).?);
    try t.expectEqualStrings("a/b", (try clean("a//b", 0)).?);
    try t.expect((try clean("./a", 2)) == null);
    try t.expect((try clean("./", 1)) == null);
}

test "strip drops leading components; nothing left is null" {
    try t.expectEqualStrings("b/c", (try clean("a/b/c", 1)).?);
    try t.expectEqualStrings("b/c", (try clean("./a/b/c", 2)).?);
    try t.expect((try clean("a/b", 2)) == null);
    try t.expect((try clean("a/", 1)) == null);
    try t.expect((try clean("./", 0)) == null);
}

test "tar-slip: a .. component is refused anywhere, whatever strip drops" {
    try t.expectError(error.ParentComponent, clean("../x", 0));
    try t.expectError(error.ParentComponent, clean("a/../../x", 0));
    try t.expectError(error.ParentComponent, clean("a/b/..", 0));
    // the dropped part is checked too: stripping one component of ../x would leave a harmless x
    try t.expectError(error.ParentComponent, clean("../x", 1));
    try t.expectError(error.ParentComponent, clean("a/../b", 1));
}

test "tar-slip: an absolute name is refused, also under strip" {
    try t.expectError(error.AbsolutePath, clean("/etc/passwd", 0));
    try t.expectError(error.AbsolutePath, clean("/a/b", 1));
}

test "a name with a dot-dot inside a longer component is a name" {
    try t.expectEqualStrings("a..b/..c/d..", (try clean("a..b/..c/d..", 0)).?);
}

test "empty names and NUL bytes are refused" {
    try t.expectError(error.EmptyName, clean("", 0));
    try t.expectError(error.NulInName, clean("a\x00b", 0));
}

test "a name longer than the buffer or the limit is refused" {
    var small: [4]u8 = undefined;
    try t.expectError(error.NameTooLong, paths.clean("abcdef", 0, &small));
    var big: [paths.max_path + 10]u8 = undefined;
    const long = "a/" ** (paths.max_path / 2 + 2);
    try t.expectError(error.NameTooLong, paths.clean(long, 0, &big));
    // exactly fitting names are fine
    try t.expectEqualStrings("abcd", (try paths.clean("abcd", 0, &small)).?);
}

test "link targets: relative, inside the destination" {
    try paths.checkLinkTarget("lib/libz.so", "libz.so.1");
    try paths.checkLinkTarget("lib/libz.so", "./libz.so.1");
    try paths.checkLinkTarget("lib/x/libz.so", "../libz.so.1");
    try paths.checkLinkTarget("a/b/c", "../../d/e");
    try paths.checkLinkTarget("link", "dir/file");
    try paths.checkLinkTarget("link", ".");
}

test "link targets: absolute, empty and NUL targets are refused" {
    try t.expectError(error.LinkEscapes, paths.checkLinkTarget("l", "/etc/passwd"));
    try t.expectError(error.LinkEscapes, paths.checkLinkTarget("l", ""));
    try t.expectError(error.NulInName, paths.checkLinkTarget("l", "a\x00b"));
}

test "link targets: a climb above the destination is refused" {
    try t.expectError(error.LinkEscapes, paths.checkLinkTarget("link", "../x"));
    try t.expectError(error.LinkEscapes, paths.checkLinkTarget("a/link", "../../x"));
    try t.expectError(error.LinkEscapes, paths.checkLinkTarget("a/b/link", "../../../x"));
}

test "link targets: .. after a name is refused, since a link in the path could make it climb" {
    // `s -> .` makes `s/..` the parent of the destination
    try t.expectError(error.LinkEscapes, paths.checkLinkTarget("t", "s/.."));
    try t.expectError(error.LinkEscapes, paths.checkLinkTarget("a/t", "../s/../.."));
    try t.expectError(error.LinkEscapes, paths.checkLinkTarget("a/b/t", "x/../y"));
}
