//! Unit tests of busybox_macos.zig: which applet a command line asks for, which are refused, where one is looked for, and the links `--install` makes. Whether the
//! operating system's tools run is what a build on a Mac shows; these hold the dispatch that stands between a script and them.
const std = @import("std");
const B = @import("busybox_macos.zig");
const t = std.testing;

// Catches: a list that is out of order or repeats a name (a second `--install` link of one name would replace the first), or an entry that is a path (an applet
// outside /bin and /usr/bin smuggled in by name).
test "applets: sorted, unique, plain names" {
    for (B.applets, 0..) |a, i| {
        try t.expect(a.len > 0);
        try t.expect(std.mem.indexOfScalar(u8, a, '/') == null);
        if (i > 0) try t.expect(std.mem.order(u8, B.applets[i - 1], a) == .lt);
    }
}

// Catches: an applet a script of the Zig rules runs missing from the list (the action would die with exit 127 on a Mac only).
test "applets: the ones the rules' scripts use are there" {
    for ([_][]const u8{ "sh", "mkdir", "rm", "mv", "tar", "cat", "chmod", "env", "test" }) |a| try t.expect(B.isApplet(a));
    try t.expect(!B.isApplet("busybox"));
    try t.expect(!B.isApplet("curl"));
    try t.expect(!B.isApplet(""));
}

test "plan: the program's own name takes an applet and its arguments" {
    const p = B.plan("busybox", &.{ "sh", "-euc", "true" });
    try t.expectEqualStrings("sh", p.run.applet);
    try t.expectEqual(@as(usize, 2), p.run.args.len);
    try t.expectEqualStrings("-euc", p.run.args[0]);
}

// Catches: a link's own name ignored (a PATH directory of links would run the first argument as the applet).
test "plan: a link named for an applet runs it with every argument" {
    const p = B.plan("mkdir", &.{ "-p", "x" });
    try t.expectEqualStrings("mkdir", p.run.applet);
    try t.expectEqual(@as(usize, 2), p.run.args.len);
    try t.expectEqualStrings("-p", p.run.args[0]);
}

// Catches: an applet outside the list run anyway. The refusal names it.
test "plan: an applet outside the list is refused" {
    try t.expectEqualStrings("curl", B.plan("busybox", &.{ "curl", "http://x" }).refuse);
    try t.expectEqualStrings("../bin/sh", B.plan("busybox", &.{"../bin/sh"}).refuse);
}

test "plan: --install -s <dir> and nothing else of that shape" {
    try t.expectEqualStrings("d", B.plan("busybox", &.{ "--install", "-s", "d" }).install);
    try t.expect(B.plan("busybox", &.{ "--install", "d" }) == .usage);
    try t.expect(B.plan("busybox", &.{ "--install", "-s" }) == .usage);
    try t.expect(B.plan("busybox", &.{ "--install", "-c", "d" }) == .usage);
    try t.expect(B.plan("busybox", &.{ "--install", "-s", "d", "e" }) == .usage);
    try t.expect(B.plan("busybox", &.{}) == .usage);
}

fn existsOnlyUsr(p: []const u8) bool {
    return std.mem.eql(u8, p, "/usr/bin/tar");
}

fn existsBoth(p: []const u8) bool {
    return std.mem.eql(u8, p, "/usr/bin/sed") or std.mem.eql(u8, p, "/bin/sed");
}

// Catches: a search order other than /bin first, or a host path (a developer tool directory) consulted.
test "resolve: /bin before /usr/bin, nothing else" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("/usr/bin/tar", B.resolve(&buf, "tar", &B.dirs, &existsOnlyUsr).?);
    try t.expect(B.resolve(&buf, "sh", &B.dirs, &existsOnlyUsr) == null);
    try t.expectEqualStrings("/bin/sed", B.resolve(&buf, "sed", &B.dirs, &existsBoth).?);
    var small: [4]u8 = undefined;
    try t.expect(B.resolve(&small, "tar", &B.dirs, &existsOnlyUsr) == null);
}

// Catches: --install leaving an old link (a second install into one directory fails), or linking something other than the whole list to the given program.
test "install: every applet is a link to the program, and a second install replaces them" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile("sh", "stale");
    try B.install(tmp.dir, "/x/busybox");
    try B.install(tmp.dir, "/y/busybox");
    var buf: [64]u8 = undefined;
    for (B.applets) |a| {
        const to = try tmp.dir.readLink(a, &buf);
        try t.expectEqualStrings("/y/busybox", to);
    }
}
