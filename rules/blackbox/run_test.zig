//! run.zig on the scripted platform (testkit.zig): which processes start, with which command lines, in which order; what is waited for; what is
//! stopped and how; the status and every message, exactly. The package is a real one (debkit.zig), unpacked into the case's directory (`--work-dir`).

const std = @import("std");
const run = @import("run.zig");
const pb = @import("pbkit.zig");
const kit = @import("testkit.zig");
const t = std.testing;

const image = kit.image;
const args = kit.runArgs;

fn expectSignals(c: *kit.Case, want: []const []const u8) !void {
    const got = try std.mem.join(c.a, ", ", c.plat.signals.items);
    try t.expectEqualStrings(try std.mem.join(c.a, ", ", want), got);
}

fn work(c: *kit.Case) []const u8 {
    return c.path("tmp/blackbox.0badc0de");
}

test "a run that passes: the fake, then the service from the package, then the driver, each command line filled in; stopped last first" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    c.plat.behave("drv", .{ .says = "driver: all good\n" });
    try t.expectEqual(@as(u8, 0), try run.run(c.a, c.io(), args(&c, &.{})));
    const w = work(&c);
    const want = [_][]const u8{
        "/fakes/upfake --listen 127.0.0.1:40001",
        try std.fmt.allocPrint(c.a, "{s}/root/usr/bin/svc --listen 127.0.0.1:40002 --up=http://127.0.0.1:40001/", .{w}),
        try std.fmt.allocPrint(c.a, "/d/drv 127.0.0.1:40002 {s}/root/etc {s} 40001 {{literal}}", .{ w, w }),
    };
    try t.expectEqual(want.len, c.plat.started.items.len);
    for (want, c.plat.started.items) |x, y| try t.expectEqualStrings(x, y);
    // Each is stopped by SIGTERM to its group, then what is left of the group is killed.
    try expectSignals(&c, &.{ "svc 15", "svc 9", "upfake 15", "upfake 9" });
    try t.expectEqualStrings("---- the log of the driver ----\ndriver: all good\n", c.stdout());
    try t.expectEqualStrings("blackbox_run: run: passed: the driver exited 0 and the 1 fake(s) and the service lived through it\n", c.stderr());
    // The run's directory is gone, and the processes had the run's environment.
    try t.expectError(error.FileNotFound, c.tmp.dir.access("tmp/blackbox.0badc0de", .{}));
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a, "{s}/tmp", .{c.dir}), c.plat.last_tmpdir.?);
}

test "a driver that fails: its status, and every log, each under its name" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    c.plat.behave("upfake", .{ .says = "fake: listening\n" });
    c.plat.behave("svc", .{ .says = "service: no newline at the end" });
    c.plat.behave("drv", .{ .status = 3, .says = "driver: wrong answer\n" });
    try t.expectEqual(@as(u8, 3), try run.run(c.a, c.io(), args(&c, &.{})));
    try t.expectEqualStrings("---- the log of the up ----\nfake: listening\n" ++
        "---- the log of the service ----\nservice: no newline at the end\n" ++
        "---- the log of the driver ----\ndriver: wrong answer\n", c.stdout());
    try t.expectEqualStrings("blackbox_run: run: the driver exited 3\n", c.stderr());
}

test "a fake that exits before it is ready: the run fails, the service never starts" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    c.plat.behave("upfake", .{ .ready_at = null, .exits_early = 7 });
    try t.expectEqual(@as(u8, 1), try run.run(c.a, c.io(), args(&c, &.{})));
    try t.expectEqual(@as(usize, 1), c.plat.started.items.len);
    try t.expectEqual(@as(usize, 0), c.plat.signals.items.len);
    try t.expectEqualStrings("blackbox_run: run: the up exited 7 before it took a connection on 127.0.0.1:40001\n", c.stderr());
    try t.expectEqualStrings("---- the log of the up ----\n(empty)\n" ++
        "---- the log of the service ----\n(no log: FileNotFound)\n" ++
        "---- the log of the driver ----\n(no log: FileNotFound)\n", c.stdout());
}

test "a service that takes no connection within --ready-s (on the platform's clock): the run fails, and what started is stopped" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    c.plat.behave("svc", .{ .ready_at = null });
    try t.expectEqual(@as(u8, 1), try run.run(c.a, c.io(), args(&c, &.{})));
    try t.expectEqualStrings("blackbox_run: run: the service took no connection on 127.0.0.1:40002 within 2 s\n", c.stderr());
    try expectSignals(&c, &.{ "svc 15", "svc 9", "upfake 15", "upfake 9" });
    // Ready at the third look: the run waits for it.
    var d = try kit.Case.init();
    defer d.deinit();
    _ = d.toyPackage();
    d.plat.behave("svc", .{ .ready_at = 3 });
    try t.expectEqual(@as(u8, 0), try run.run(d.a, d.io(), args(&d, &.{})));
    try t.expectEqual(@as(u64, 2 * run.poll_ms), d.plat.now);
}

test "a fake or the service gone while the driver ran fails a run whose driver passed, and the driver's failure wins over it" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    c.plat.behave("svc", .{ .dies = 9 });
    try t.expectEqual(@as(u8, 1), try run.run(c.a, c.io(), args(&c, &.{})));
    try t.expectEqualStrings("blackbox_run: run: the service exited 9 while the driver ran\n", c.stderr());
    try expectSignals(&c, &.{ "upfake 15", "upfake 9" });
    var d = try kit.Case.init();
    defer d.deinit();
    _ = d.toyPackage();
    d.plat.behave("upfake", .{ .dies = 1 });
    d.plat.behave("drv", .{ .status = 4 });
    try t.expectEqual(@as(u8, 4), try run.run(d.a, d.io(), args(&d, &.{})));
    try t.expectEqualStrings("blackbox_run: run: the up exited 1 while the driver ran\nblackbox_run: run: the driver exited 4\n", d.stderr());
}

test "a process still there stop_ms after SIGTERM is killed" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    c.plat.behave("svc", .{ .stays = true });
    try t.expectEqual(@as(u8, 0), try run.run(c.a, c.io(), args(&c, &.{})));
    try expectSignals(&c, &.{ "svc 15", "svc 9", "upfake 15", "upfake 9" });
    try kit.expectHas(c.stderr(), "blackbox_run: run: the service was still there 30 s after SIGTERM; it was killed\n");
}

test "a process that cannot be started fails the run, naming it; what started before it is stopped" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    c.plat.behave("upfake", .{ .refuse = error.FileNotFound });
    try t.expectEqual(@as(u8, 1), try run.run(c.a, c.io(), args(&c, &.{})));
    try t.expectEqualStrings("blackbox_run: run: cannot start the up `/fakes/upfake`: FileNotFound\n", c.stderr());
    var d = try kit.Case.init();
    defer d.deinit();
    _ = d.toyPackage();
    d.plat.behave("drv", .{ .refuse = error.AccessDenied });
    try t.expectEqual(@as(u8, 1), try run.run(d.a, d.io(), args(&d, &.{})));
    try t.expectEqualStrings("blackbox_run: run: cannot start the driver `/d/drv`: AccessDenied\n", d.stderr());
    try expectSignals(&d, &.{ "svc 15", "svc 9", "upfake 15", "upfake 9" });
}

test "no loopback port to give: the run fails before anything starts" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    c.plat.reserve_fails = true;
    try t.expectEqual(@as(u8, 1), try run.run(c.a, c.io(), args(&c, &.{})));
    try t.expectEqualStrings("blackbox_run: run: no loopback port could be bound for the up\n", c.stderr());
    try t.expectEqual(@as(usize, 0), c.plat.started.items.len);
}

test "a port already given to another process of the run is asked for again; one never distinct fails the run" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    c.plat.port_script = &.{ 41000, 41000, 41000, 41001 };
    try t.expectEqual(@as(u8, 0), try run.run(c.a, c.io(), args(&c, &.{})));
    try t.expectEqualStrings("/fakes/upfake --listen 127.0.0.1:41000", c.plat.started.items[0]);
    try kit.expectHas(c.plat.started.items[1], "--listen 127.0.0.1:41001 --up=http://127.0.0.1:41000/");
    var d = try kit.Case.init();
    defer d.deinit();
    _ = d.toyPackage();
    d.plat.port_script = &([_]u16{41000} ** (1 + run.max_port_tries));
    try t.expectEqual(@as(u8, 1), try run.run(d.a, d.io(), args(&d, &.{})));
    try t.expectEqualStrings("blackbox_run: run: the loopback ports given for the service were those of the run's other processes 16 times\n", d.stderr());
    try t.expectEqual(@as(usize, 0), d.plat.started.items.len);
}

test "a flag whose placeholder names nothing, or is not one, is exit 2 before anything starts" {
    const bad = [_][2][]const u8{
        .{ "{addr:nobody}", "blackbox_run: run: the flag `{addr:nobody}` says `{addr:nobody}`, which is not {addr:NAME}, {port:NAME}, {root} or {work} of a fake or the service\n" },
        .{ "{addr}", "blackbox_run: run: the flag `{addr}` says `{addr}`, which is not {addr:NAME}, {port:NAME}, {root} or {work} of a fake or the service\n" },
        .{ "{home}", "blackbox_run: run: the flag `{home}` says `{home}`, which is not {addr:NAME}, {port:NAME}, {root} or {work} of a fake or the service\n" },
        .{ "x{addr:up", "blackbox_run: run: the flag `x{addr:up` opens a `{` it does not close (`{{` is a `{`)\n" },
        .{ "x{", "blackbox_run: run: the flag `x{` opens a `{` it does not close (`{{` is a `{`)\n" },
    };
    for (bad) |case| {
        var c = try kit.Case.init();
        defer c.deinit();
        _ = c.toyPackage();
        try t.expectEqual(@as(u8, 2), try run.run(c.a, c.io(), args(&c, &.{ "--driver-flag", case[0] })));
        try t.expectEqualStrings(case[1], c.stderr());
        try t.expectEqual(@as(usize, 0), c.plat.started.items.len);
    }
    // The same in a flag of the service and of a fake.
    for ([_][]const u8{ "--flag", "--fake-flag" }) |option| {
        var c = try kit.Case.init();
        defer c.deinit();
        _ = c.toyPackage();
        const value: []const u8 = if (std.mem.eql(u8, option, "--flag")) "{port:nobody}" else "up={port:nobody}";
        try t.expectEqual(@as(u8, 2), try run.run(c.a, c.io(), args(&c, &.{ option, value })));
        try t.expectEqualStrings("blackbox_run: run: the flag `{port:nobody}` says `{port:nobody}`, which is not {addr:NAME}, {port:NAME}, {root} or {work} of a fake or the service\n", c.stderr());
        try t.expectEqual(@as(usize, 0), c.plat.started.items.len);
    }
}

test "the package: pinned and right, not there, not of the pinned size or sha256, not a package" {
    var c = try kit.Case.init();
    defer c.deinit();
    const bytes = c.toyPackage();
    const size = try std.fmt.allocPrint(c.a, "{d}", .{bytes.len});
    try t.expectEqual(@as(u8, 0), try run.run(c.a, c.io(), args(&c, &.{ "--sha256", c.sha256(bytes), "--size", size })));
    const cases = [_][2][]const u8{
        .{ "--sha256", "0" ** 64 },
        .{ "--size", "1" },
    };
    for (cases) |case| {
        var d = try kit.Case.init();
        defer d.deinit();
        _ = d.toyPackage();
        const extra: []const []const u8 = if (std.mem.eql(u8, case[0], "--sha256")) &.{ "--sha256", case[1], "--size", size } else &.{ "--sha256", d.sha256(bytes), "--size", case[1] };
        try t.expectEqual(@as(u8, 1), try run.run(d.a, d.io(), args(&d, extra)));
        try kit.expectHas(d.stderr(), try std.fmt.allocPrint(d.a, "blackbox_run: run: the package {s} is {d} bytes of sha256 {s}, not the pinned ", .{ d.path("pkg.deb"), bytes.len, d.sha256(bytes) }));
        try t.expectEqual(@as(usize, 0), d.plat.started.items.len);
    }
    var e = try kit.Case.init();
    defer e.deinit();
    e.put("pkg.deb", "not a package");
    try t.expectEqual(@as(u8, 1), try run.run(e.a, e.io(), args(&e, &.{})));
    try t.expectEqualStrings(try std.fmt.allocPrint(e.a, "blackbox_run: run: the package {s} cannot be unpacked: it is not an ar archive (a .deb starts with `!<arch>`)\n", .{e.path("pkg.deb")}), e.stderr());
    // A package that is not there fails before anything is made; and the run's directory is relative to the working directory when it is given so.
    var f = try kit.Case.init();
    defer f.deinit();
    f.environ = &.{"NOT_AN_ASSIGNMENT"};
    try t.expectEqual(@as(u8, 1), try run.run(f.a, f.io(), args(&f, &.{})));
    try t.expectEqualStrings(try std.fmt.allocPrint(f.a, "blackbox_run: run: cannot read the package {s}: FileNotFound\n", .{f.path("pkg.deb")}), f.stderr());
    var g = try kit.Case.init();
    defer g.deinit();
    _ = g.toyPackage();
    const relative = try g.a.dupe([]const u8, args(&g, &.{}));
    relative[5] = "tmp";
    try t.expectEqual(@as(u8, 0), try run.run(g.a, g.io(), relative));
    try kit.expectHas(g.plat.started.items[1], try std.fmt.allocPrint(g.a, "{s}/tmp/blackbox.0badc0de/root/usr/bin/svc", .{g.dir}));
}

test "the run's directories cannot be made: each is said and the run fails" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    try c.tmp.dir.deleteTree("tmp");
    c.put("tmp", "a file where the run's directory goes");
    try t.expectEqual(@as(u8, 1), try run.run(c.a, c.io(), args(&c, &.{})));
    try t.expectEqualStrings(try std.fmt.allocPrint(c.a, "blackbox_run: run: cannot make the run's directory {s}: NotDir\n", .{work(&c)}), c.stderr());
    for ([_][]const u8{ "root", "logs" }) |sub| {
        var d = try kit.Case.init();
        defer d.deinit();
        _ = d.toyPackage();
        d.put(try std.fmt.allocPrint(d.a, "tmp/blackbox.0badc0de/{s}", .{sub}), "a file in the way");
        try t.expectEqual(@as(u8, 1), try run.run(d.a, d.io(), args(&d, &.{})));
        try kit.expectHas(d.stderr(), try std.fmt.allocPrint(d.a, "blackbox_run: run: cannot make {s}/{s}: ", .{ work(&d), sub }));
    }
}

test "a run's directory that cannot be removed is said, and the run's status is what it was" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    c.plat.behave("drv", .{ .locks = true });
    try t.expectEqual(@as(u8, 0), try run.run(c.a, c.io(), args(&c, &.{})));
    try kit.expectHas(c.stderr(), try std.fmt.allocPrint(c.a, "blackbox_run: run: cannot remove the run's directory {s}: ", .{work(&c)}));
    try std.posix.fchmodat(c.tmp.dir.fd, "tmp/blackbox.0badc0de/locked", 0o755, 0);
}

test "--docker: the same run started inside the image, the checkout mounted read-only at its own path, no network, this user" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.environ = &.{ "PATH=/usr/bin", "NOT_AN_ASSIGNMENT" };
    c.plat.inherit_answer = 5;
    try t.expectEqual(@as(u8, 5), try run.run(c.a, c.io(), args(&c, &.{ "--docker", "/usr/bin/docker" })));
    const mount = try std.fmt.allocPrint(c.a, "{s}:{s}:ro", .{ c.dir, c.dir });
    const self = c.path("buck-out/blackbox_run");
    var want: std.ArrayList([]const u8) = .empty;
    try want.appendSlice(c.a, &.{ "/usr/bin/docker", "run", "--rm", "--network", "none", "--user", "1000:1000", "--volume", mount, "--tmpfs", "/blackbox-work:rw,exec,nosuid", "--workdir", c.dir, "--entrypoint", self, "repo@sha256:" ++ "1" ** 64, "run" });
    try want.appendSlice(c.a, args(&c, &.{}));
    try want.appendSlice(c.a, &.{ "--work-dir", "/blackbox-work" });
    try t.expectEqualStrings(try std.mem.join(c.a, " ", want.items), c.plat.inherited.?);
    try t.expectEqualStrings("blackbox_run: run: running inside repo@sha256:" ++ "1" ** 64 ++ " through /usr/bin/docker\n", c.stderr());
    // A flag whose value is `--docker` is the driver's, and stays.
    var e = try kit.Case.init();
    defer e.deinit();
    try t.expectEqual(@as(u8, 0), try run.run(e.a, e.io(), args(&e, &.{ "--driver-flag", "--docker", "--docker", "/usr/bin/docker" })));
    try t.expect(std.mem.endsWith(u8, e.plat.inherited.?, "--ready-s 2 --driver-flag --docker --work-dir /blackbox-work"));
    var d = try kit.Case.init();
    defer d.deinit();
    d.plat.inherit_answer = error.FileNotFound;
    try t.expectEqual(@as(u8, 1), try run.run(d.a, d.io(), args(&d, &.{ "--docker", "/no/docker" })));
    try kit.expectHas(d.stderr(), "blackbox_run: run: cannot run /no/docker: FileNotFound\n");
}

test "--docker without a usable docker: exit 2, naming the configuration key" {
    for ([_][2][]const u8{ .{ "", "empty" }, .{ "docker", "not an absolute path" } }) |case| {
        var c = try kit.Case.init();
        defer c.deinit();
        try t.expectEqual(@as(u8, 2), try run.run(c.a, c.io(), args(&c, &.{ "--docker", case[0] })));
        try t.expectEqualStrings(try std.fmt.allocPrint(c.a, "blackbox_run: run: this test runs inside {s}, and off the farm it runs there through docker: pass the absolute path of the docker program as `-c blackbox.docker=<path>` (`--docker` is {s})\n", .{ image, case[1] }), c.stderr());
        try t.expectEqual(@as(?[]const u8, null), c.plat.inherited);
    }
}

test "--farm: a farm job that received the test's image runs, saying its digest; another image, no job, or an unreadable one fails" {
    var c = try kit.Case.init();
    defer c.deinit();
    _ = c.toyPackage();
    const act = pb.action(c.a, &.{});
    c.put(".job/action", act);
    c.put(".job/command", pb.command(c.a, &.{"x"}, &.{.{ "container-image", image }}));
    try t.expectEqual(@as(u8, 0), try run.run(c.a, c.io(), args(&c, &.{"--farm"})));
    try kit.expectHas(c.stdout(), try std.fmt.allocPrint(c.a, "farm job: action {s}:{d}\nproperties the frontend received (from the command): container-image={s}\n", .{ c.sha256(act), act.len, image }));
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
    try t.expectEqual(@as(usize, 0), d.plat.started.items.len);

    var e = try kit.Case.init();
    defer e.deinit();
    try t.expectEqual(@as(u8, 1), try run.run(e.a, e.io(), args(&e, &.{"--farm"})));
    try t.expectEqualStrings("blackbox_run: run: `--farm`, but this is not a farm job: the root holds no job directory (a top-level `.<name>/` holding `action` and `command`)\n", e.stderr());
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
        .{ .args = &.{ "--size", "ten" }, .says = P ++ "`--size ten` is not a number of bytes\n" },
        .{ .args = &.{ "--ready-s", "soon" }, .says = P ++ "`--ready-s soon` is not a number of seconds\n" },
        .{ .args = &.{ "--ready-s", "0" }, .says = P ++ "`--ready-s` must be from 1 to 86400 seconds\n" },
        .{ .args = &.{ "--ready-s", "86401" }, .says = P ++ "`--ready-s` must be from 1 to 86400 seconds\n" },
        .{ .args = &.{ "--fake", "noequals" }, .says = P ++ "`--fake noequals` is not NAME=PROGRAM\n" },
        .{ .args = &.{ "--fake", "up=/x", "--fake", "up=/y" }, .says = P ++ "the fake `up` is named twice, or is named `service`\n" },
        .{ .args = &.{ "--fake", "service=/x" }, .says = P ++ "the fake `service` is named twice, or is named `service`\n" },
        .{ .args = &.{ "--fake-flag", "noequals" }, .says = P ++ "`--fake-flag noequals` is not NAME=ARG\n" },
        .{ .args = &.{ "--fake-flag", "down=x" }, .says = P ++ "`--fake-flag down=x` names no fake given before it\n" },
        .{ .args = &.{}, .says = P ++ "`--image` is required\n" },
        .{ .args = &.{ "--image", "i", "--package", "p", "--service", "s" }, .says = P ++ "`--work-dir` is required\n" },
        .{ .args = &.{ "--image", "i", "--package", "p", "--work-dir", "w", "--service", "s" }, .says = P ++ "`--driver` is required\n" },
        .{ .args = &.{ "--image", "i", "--package", "p", "--work-dir", "w", "--service", "s", "--driver", "d", "--sha256", "x" }, .says = P ++ "`--sha256` and `--size` go together: the package is pinned by both or by neither\n" },
        .{ .args = &.{ "--image", "i", "--package", "p", "--work-dir", "w", "--service", "s", "--driver", "d", "--farm", "--docker", "/d" }, .says = P ++ "`--farm` and `--docker` are two places to run; a run has one\n" },
    };
    for (cases) |case| {
        var c = try kit.Case.init();
        defer c.deinit();
        try t.expectEqual(@as(u8, 2), try run.run(c.a, c.io(), case.args));
        try t.expectEqualStrings(case.says, c.stderr());
    }
}

