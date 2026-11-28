//! deb.zig: packages written by debkit.zig, unpacked into the case's directory; every way a file is not a package it can unpack, with its exact reason.

const std = @import("std");
const deb = @import("deb.zig");
const debkit = @import("debkit");
const kit = @import("testkit.zig");
const t = std.testing;

fn unpackInto(c: *kit.Case, bytes: []const u8) !?[]const u8 {
    try c.tmp.dir.makePath("root");
    var dir = try c.tmp.dir.openDir("root", .{});
    defer dir.close();
    return deb.unpack(c.a, bytes, dir);
}

fn expectRefused(c: *kit.Case, bytes: []const u8, why: []const u8) !void {
    const got = (try unpackInto(c, bytes)) orelse {
        std.debug.print("unpacked, but should be refused with: {s}\n", .{why});
        return error.TestUnexpectedResult;
    };
    try t.expectEqualStrings(why, got);
}

test "a package as dpkg-deb writes it: its files at their paths, an executable kept executable, set-uid dropped" {
    var c = try kit.Case.init();
    defer c.deinit();
    const bytes = try debkit.packageOf(c.a, &.{
        .{ .name = "usr/bin/svc", .mode = 0o4755, .data = "program" },
        .{ .name = "etc/svc/config.toml", .data = "x = 1\n" },
        .{ .name = "usr/bin/svc-alias", .typeflag = '2', .link = "svc" },
    });
    try t.expectEqual(@as(?[]const u8, null), try unpackInto(&c, bytes));
    const got = try c.tmp.dir.readFileAlloc(c.a, "root/usr/bin/svc", 100);
    try t.expectEqualStrings("program", got);
    const st = try c.tmp.dir.statFile("root/usr/bin/svc");
    try t.expectEqual(@as(std.fs.File.Mode, 0o755), st.mode & 0o7777);
    try t.expectEqualStrings("x = 1\n", try c.tmp.dir.readFileAlloc(c.a, "root/etc/svc/config.toml", 100));
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("svc", try c.tmp.dir.readLink("root/usr/bin/svc-alias", &buf));
}

test "a data member that is a plain tar, and an odd-sized member before it (the ar padding)" {
    var c = try kit.Case.init();
    defer c.deinit();
    const data = try debkit.tar(c.a, &.{.{ .name = "./a", .data = "plain" }});
    const bytes = try debkit.ar(c.a, &.{ .{ .name = "debian-binary", .data = "2.0\n" }, .{ .name = "control.tar.gz", .data = "odd" }, .{ .name = "data.tar", .data = data } });
    try t.expectEqual(@as(?[]const u8, null), try unpackInto(&c, bytes));
    try t.expectEqualStrings("plain", try c.tmp.dir.readFileAlloc(c.a, "root/a", 100));
}

test "an entry that would land outside the directory is refused, naming it" {
    var c = try kit.Case.init();
    defer c.deinit();
    const abs = try debkit.package(c.a, "data.tar.gz", try debkit.gzip(c.a, try debkit.tar(c.a, &.{.{ .name = "/etc/passwd", .data = "x" }})));
    try expectRefused(&c, abs, "its `data.tar.gz` cannot be unpacked: AbsolutePath (at the entry `/etc/passwd`)");
    const up = try debkit.package(c.a, "data.tar", try debkit.tar(c.a, &.{.{ .name = "./../escape", .data = "x" }}));
    try expectRefused(&c, up, "its `data.tar` cannot be unpacked: ParentComponent (at the entry `./../escape`)");
}

test "a data member in a form the runner does not read, or one that is not what its name says" {
    var c = try kit.Case.init();
    defer c.deinit();
    try expectRefused(&c, try debkit.package(c.a, "data.tar.zst", "zstd"), "its data member is `data.tar.zst`: the runner reads data.tar, data.tar.gz and data.tar.xz");
    try expectRefused(&c, try debkit.package(c.a, "data.tar.xz", "not xz"), "its `data.tar.xz` cannot be unpacked: Corrupt (at the entry ``)");
}

test "a file that is not a Debian package, each way, with its reason" {
    var c = try kit.Case.init();
    defer c.deinit();
    const good = try debkit.packageOf(c.a, &.{.{ .name = "a", .data = "x" }});
    try expectRefused(&c, "PK\x03\x04", "it is not an ar archive (a .deb starts with `!<arch>`)");
    try expectRefused(&c, "!<arch>\n", "it is not a Debian package: its first member is not `debian-binary` holding a version 2 format");
    try expectRefused(&c, good[0 .. 8 + 30], "it ends inside a member's header");
    try expectRefused(&c, good[0 .. 8 + 60 + 2], "it ends inside a member");
    var bad_end = try c.a.dupe(u8, good);
    bad_end[8 + 58] = 'x';
    try expectRefused(&c, bad_end, "a member's header does not end as an ar header ends");
    var bad_size = try c.a.dupe(u8, good);
    bad_size[8 + 48] = 'z';
    try expectRefused(&c, bad_size, "a member's size is not a number");
    try expectRefused(&c, try debkit.ar(c.a, &.{.{ .name = "debian-binary", .data = "3.0\n" }}), "it is not a Debian package: its first member is not `debian-binary` holding a version 2 format");
    try expectRefused(&c, try debkit.ar(c.a, &.{ .{ .name = "control.tar.gz", .data = "" }, .{ .name = "debian-binary", .data = "2.0\n" } }), "it is not a Debian package: its first member is not `debian-binary` holding a version 2 format");
    try expectRefused(&c, try debkit.ar(c.a, &.{ .{ .name = "debian-binary", .data = "2.0\n" }, .{ .name = "control.tar.gz", .data = "" } }), "it has no data member (data.tar, data.tar.gz or data.tar.xz)");
}

