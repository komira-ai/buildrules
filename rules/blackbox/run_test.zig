//! run.zig on the scripted platform (testkit.zig): which packages are checked and put onto the root, in which order; the driver's command line and
//! environment; the status and every message, exactly. The packages are real ones (debkit.zig), unpacked into the case's directory.

const std = @import("std");
const run = @import("run.zig");
const debkit = @import("debkit");
const pb = @import("pbkit.zig");
const kit = @import("testkit.zig");
const t = std.testing;

const image = kit.image;
const args = kit.runArgs;

test "a run that passes: the package's files are on the root when the driver runs, with the root as its argument and this process's environment" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    try t.expectEqual(@as(u8, 0), try run.run(c.a, c.io(), args(&c, &.{})));
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a, "/d/drv {s}", .{c.path("root")}), c.plat.ran.?);
    try t.expectEqualStrings("#!svc\n", c.plat.service.?);
    try t.expectEqualStrings("/nonexistent", c.plat.home.?);
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a, "blackbox_run: run: passed: 1 package(s) put onto {s}, and the driver exited 0\n", .{c.path("root")}), c.stderr());
    try t.expectEqualStrings("", c.stdout());
}

test "two packages are both put onto the root, each file at the path its package ships it, replacing the image's own file there" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.put("svc.deb", try debkit.packageOf(c.a, &.{ .{ .name = "usr/bin/svc", .mode = 0o755, .data = "service" }, .{ .name = "etc/svc.toml", .data = "x" } }));
    c.put("fake.deb", try debkit.packageOf(c.a, &.{.{ .name = "usr/bin/fake", .mode = 0o755, .data = "f" }}));
    // The image's own files: one a package replaces, one no package holds.
    c.put("root/usr/bin/svc", "image");
    c.put("root/etc/hostname", "image");
    const argv = [_][]const u8{ "--image", image, "--root", c.path("root"), "--package", c.path("svc.deb"), "--package", c.path("fake.deb"), "--driver", "/d/drv" };
    try t.expectEqual(@as(u8, 0), try run.run(c.a, c.io(), &argv));
    try t.expectEqualStrings("service", c.plat.service.?);
    try t.expectEqualStrings("x", try c.tmp.dir.readFileAlloc(c.a, "root/etc/svc.toml", 10));
    try t.expectEqualStrings("f", try c.tmp.dir.readFileAlloc(c.a, "root/usr/bin/fake", 10));
    try t.expectEqualStrings("image", try c.tmp.dir.readFileAlloc(c.a, "root/etc/hostname", 10));
}

test "two packages that ship the same path fail the test before anything is written, naming the path and both packages" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.put("svc.deb", try debkit.packageOf(c.a, &.{ .{ .name = "usr/bin/svc", .mode = 0o755, .data = "service" }, .{ .name = "usr/share/doc/x", .data = "d" } }));
    c.put("fake.deb", try debkit.packageOf(c.a, &.{ .{ .name = "usr/bin/fake", .mode = 0o755, .data = "f" }, .{ .name = "usr/share/doc/x", .data = "other" } }));
    const argv = [_][]const u8{ "--image", image, "--root", c.path("root"), "--package", c.path("svc.deb"), "--package", c.path("fake.deb"), "--driver", "/d/drv" };
    try t.expectEqual(@as(u8, 1), try run.run(c.a, c.io(), &argv));
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a, "blackbox_run: run: the packages {s} and {s} both ship /usr/share/doc/x: a test puts each file onto the image from one package\n", .{ c.path("svc.deb"), c.path("fake.deb") }), c.stderr());
    try t.expectEqual(@as(?[]const u8, null), c.plat.ran);
    try t.expectError(error.FileNotFound, c.tmp.dir.access("root/usr/bin/svc", .{}));
}
test "a driver that fails is the run's status; one that cannot be started fails the run, naming it" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    c.plat.answer = 3;
    try t.expectEqual(@as(u8, 3), try run.run(c.a, c.io(), args(&c, &.{})));
    try t.expectEqualStrings("blackbox_run: run: the driver exited 3\n", c.stderr());
    var d = try kit.Case.init();
    defer d.deinit();
    _ = d.toyPackage();
    d.plat.answer = error.FileNotFound;
    try t.expectEqual(@as(u8, 1), try run.run(d.a, d.io(), args(&d, &.{})));
    try t.expectEqualStrings("blackbox_run: run: cannot run the driver /d/drv: FileNotFound\n", d.stderr());
}

test "a pinned package: right, not of the pinned size or sha256 (nothing is put onto the root), not there, not a package" {
    var c = try kit.Case.init();
    defer c.deinit();
    const bytes = c.toyPackage();
    const size = try std.fmt.allocPrint(c.a, "{d}", .{bytes.len});
    try t.expectEqual(@as(u8, 0), try run.run(c.a, c.io(), args(&c, &.{}))); // unpinned: built in the same build
    var right = try kit.Case.init();
    defer right.deinit();
    _ = right.toyPackage();
    try t.expectEqual(@as(u8, 0), try run.run(right.a, right.io(), pinned(&right, right.sha256(bytes), size)));
    for ([_][2][]const u8{ .{ "0" ** 64, size }, .{ "", "1" } }) |case| {
        var d = try kit.Case.init();
        defer d.deinit();
        _ = d.toyPackage();
        const sha = if (case[0].len > 0) case[0] else d.sha256(bytes);
        try t.expectEqual(@as(u8, 1), try run.run(d.a, d.io(), pinned(&d, sha, case[1])));
        try t.expectEqualStrings(try std.fmt.allocPrint(d.a, "blackbox_run: run: the package {s} is {d} bytes of sha256 {s}, not the pinned {s} bytes of sha256 {s}\n", .{ d.path("pkg.deb"), bytes.len, d.sha256(bytes), case[1], sha }), d.stderr());
        try t.expectEqual(@as(?[]const u8, null), d.plat.ran);
        try t.expectError(error.FileNotFound, d.tmp.dir.access("root/usr/bin/svc", .{}));
    }
    var e = try kit.Case.init();
    defer e.deinit();
    try t.expectEqual(@as(u8, 1), try run.run(e.a, e.io(), args(&e, &.{})));
    try t.expectEqualStrings(try std.fmt.allocPrint(e.a, "blackbox_run: run: cannot read the package {s}: FileNotFound\n", .{e.path("pkg.deb")}), e.stderr());
    var f = try kit.Case.init();
    defer f.deinit();
    f.put("pkg.deb", "not a package");
    try t.expectEqual(@as(u8, 1), try run.run(f.a, f.io(), args(&f, &.{})));
    try t.expectEqualStrings(try std.fmt.allocPrint(f.a, "blackbox_run: run: the package {s} cannot be put onto {s}: it is not an ar archive (a .deb starts with `!<arch>`)\n", .{ f.path("pkg.deb"), f.path("root") }), f.stderr());
    try t.expectEqual(@as(?[]const u8, null), f.plat.ran);
}

/// The run's command line with its one package pinned by `sha256` and `size`.
fn pinned(c: *kit.Case, sha256: []const u8, size: []const u8) []const []const u8 {
    return std.mem.concat(c.a, []const u8, &.{ args(c, &.{}), &.{ "--sha256", sha256, "--size", size } }) catch @panic("oom");
}

test "the root: relative to the working directory, and one that is not there fails the run" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    const relative = try c.a.dupe([]const u8, args(&c, &.{}));
    relative[3] = "root";
    try t.expectEqual(@as(u8, 0), try run.run(c.a, c.io(), relative));
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a, "/d/drv {s}/root", .{c.dir}), c.plat.ran.?);
    var d = try kit.Case.init();
    defer d.deinit();
    _ = d.toyPackage();
    try d.tmp.dir.deleteTree("root");
    try t.expectEqual(@as(u8, 1), try run.run(d.a, d.io(), args(&d, &.{})));
    try t.expectEqualStrings(try std.fmt.allocPrint(d.a, "blackbox_run: run: cannot open the root {s}: FileNotFound\n", .{d.path("root")}), d.stderr());
}

test "--farm: a farm job that received the test's image runs, saying its digest; another image, no job, or an unreadable one fails before anything is written" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    const act = pb.action(c.a, &.{});
    c.put(".job/action", act);
    c.put(".job/command", pb.command(c.a, &.{"x"}, &.{.{ "container-image", image }}));
    try t.expectEqual(@as(u8, 0), try run.run(c.a, c.io(), args(&c, &.{"--farm"})));
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a, "farm job: action {s}:{d}\nproperties the frontend received (from the command): container-image={s}\n", .{ c.sha256(act), act.len, image }), c.stdout());
    // The image of the command line may leave out `docker://`; the property never does.
    var plain = try kit.Case.init();
    defer plain.deinit();
    _ = plain.toyPackage();
    plain.put(".job/action", act);
    plain.put(".job/command", pb.command(plain.a, &.{"x"}, &.{.{ "container-image", image }}));
    const bare = try plain.a.dupe([]const u8, args(&plain, &.{"--farm"}));
    bare[1] = image["docker://".len..];
    try t.expectEqual(@as(u8, 0), try run.run(plain.a, plain.io(), bare));

    var d = try kit.Case.init();
    defer d.deinit();
    _ = d.toyPackage();
    d.put(".job/action", act);
    d.put(".job/command", pb.command(d.a, &.{"x"}, &.{.{ "OSFamily", "Linux" }}));
    try t.expectEqual(@as(u8, 1), try run.run(d.a, d.io(), args(&d, &.{"--farm"})));
    try t.expectEqualStrings("blackbox_run: run: the job's container-image is ``, not the test's `" ++ image ++ "`\n", d.stderr());
    try t.expectEqual(@as(?[]const u8, null), d.plat.ran);

    var e = try kit.Case.init();
    defer e.deinit();
    try t.expectEqual(@as(u8, 1), try run.run(e.a, e.io(), args(&e, &.{"--farm"})));
    try t.expectEqualStrings("blackbox_run: run: `--farm`, but this is not a farm job: the root holds no job directory (a top-level `.<name>/` holding `action` and `command`); a black-box test runs on a farm only\n", e.stderr());
    e.err.clearRetainingCapacity();
    e.put(".job/action", act);
    try t.expectEqual(@as(u8, 1), try run.run(e.a, e.io(), args(&e, &.{"--farm"})));
    try t.expectEqualStrings("blackbox_run: run: the farm job's Action or Command cannot be read: Unreadable\n", e.stderr());
}

test "a wrong command line is exit 2, each way, with its message" {
    const P = "blackbox_run: run: ";
    const cases = [_]struct { args: []const []const u8, says: []const u8 }{
        .{ .args = &.{"--image"}, .says = P ++ "`--image` is not an option, or it has no value\n" },
        .{ .args = &.{ "--bogus", "x" }, .says = P ++ "`--bogus` is not an option\n" },
        .{ .args = &.{ "--sha256", "x" }, .says = P ++ "`--sha256` comes before any `--package`: it pins the package given before it\n" },
        .{ .args = &.{ "--package", "p", "--sha256", "x", "--sha256", "y" }, .says = P ++ "the package p is given two sha256\n" },
        .{ .args = &.{ "--package", "p", "--size", "1", "--size", "2" }, .says = P ++ "the package p is given two sizes\n" },
        .{ .args = &.{ "--package", "p", "--size", "ten" }, .says = P ++ "`--size ten` is not a number of bytes\n" },
        .{ .args = &.{}, .says = P ++ "`--image` is required\n" },
        .{ .args = &.{ "--image", "i" }, .says = P ++ "`--root` is required\n" },
        .{ .args = &.{ "--image", "i", "--root", "r" }, .says = P ++ "`--driver` is required\n" },
        .{ .args = &.{ "--image", "i", "--root", "r", "--driver", "d" }, .says = P ++ "no `--package`: a test puts at least one package onto its image\n" },
        .{ .args = &.{ "--image", "i", "--root", "r", "--driver", "d", "--package", "p", "--package", "q", "--sha256", "x" }, .says = P ++ "the package q: `--sha256` and `--size` go together, it is pinned by both or by neither\n" },
    };
    for (cases) |case| {
        var c = try kit.Case.init();
        defer c.deinit();
        try t.expectEqual(@as(u8, 2), try run.run(c.a, c.io(), case.args));
        try t.expectEqualStrings(case.says, c.stderr());
    }
}

test "a package whose files are listed but whose unpacking is refused (an entry outside the root) fails the run, naming it" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.put("pkg.deb", try debkit.package(c.a, "data.tar.gz", try debkit.gzip(c.a, try debkit.tar(c.a, &.{.{ .name = "/etc/passwd", .data = "x" }}))));
    try t.expectEqual(@as(u8, 1), try run.run(c.a, c.io(), args(&c, &.{})));
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a, "blackbox_run: run: the package {s} cannot be put onto {s}: its `data.tar.gz` cannot be unpacked: AbsolutePath (at the entry `/etc/passwd`)\n", .{ c.path("pkg.deb"), c.path("root") }), c.stderr());
    try t.expectEqual(@as(?[]const u8, null), c.plat.ran);
}
