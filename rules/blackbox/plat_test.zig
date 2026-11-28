//! plat.zig, the real platform, with real processes: the toolbox (rules/toolbox) for a program that only has a status or reads its environment back, and the
//! toy (toy/) for one that listens. Nothing here asserts a time: a wait is for a process's end or for a port that takes a connection.

const std = @import("std");
const plat_mod = @import("plat.zig");
const io_mod = @import("io.zig");
const kit = @import("testkit.zig");
const t = std.testing;

const plat = plat_mod.real();

fn env(a: std.mem.Allocator, pairs: []const [2][]const u8) !*std.process.EnvMap {
    const m = try a.create(std.process.EnvMap);
    m.* = std.process.EnvMap.init(a);
    for (pairs) |kv| try m.put(kv[0], kv[1]);
    return m;
}

test "a program's status, its environment exactly, and its output in its log" {
    var c = try kit.Case.init();
    defer c.deinit();
    const toolbox = try kit.tool(c.a, "TOOLBOX");
    const e = try env(c.a, &.{.{ "GREETING", "hello" }});
    const log = c.path("printenv.log");
    const pid = try plat.spawn(plat.ctx, c.a, &.{ toolbox, "printenv" }, e, log);
    try t.expectEqual(@as(u8, 0), plat.wait(plat.ctx, pid));
    try t.expectEqualStrings("GREETING=hello\n", try c.tmp.dir.readFileAlloc(c.a, "printenv.log", 100));
    const no = try plat.spawn(plat.ctx, c.a, &.{ toolbox, "false" }, e, c.path("false.log"));
    try t.expectEqual(@as(u8, 1), plat.wait(plat.ctx, no));
    // A log is appended to, never truncated.
    const again = try plat.spawn(plat.ctx, c.a, &.{ toolbox, "printenv", "GREETING" }, e, log);
    try t.expectEqual(@as(u8, 0), plat.wait(plat.ctx, again));
    try t.expectEqualStrings("GREETING=hello\nhello\n", try c.tmp.dir.readFileAlloc(c.a, "printenv.log", 100));
}

test "a program that is not there, or not executable, is refused before anything is started" {
    var c = try kit.Case.init();
    defer c.deinit();
    const e = try env(c.a, &.{});
    try t.expectError(error.FileNotFound, plat.spawn(plat.ctx, c.a, &.{c.path("absent")}, e, c.path("x.log")));
    c.put("data", "not a program");
    try t.expectError(error.AccessDenied, plat.spawn(plat.ctx, c.a, &.{c.path("data")}, e, c.path("x.log")));
    try t.expectError(error.FileNotFound, plat.runInherit(plat.ctx, c.a, &.{c.path("absent")}, e));
    try t.expectError(error.FileNotFound, plat.spawn(plat.ctx, c.a, &.{try kit.tool(c.a, "TOOLBOX")}, e, c.path("no/such/dir.log")));
}

test "a listening process: its port takes a connection; SIGTERM to its group ends it, and a look then reaps it" {
    var c = try kit.Case.init();
    defer c.deinit();
    const toy = try kit.tool(c.a, "TOY");
    const port = plat.reservePort(plat.ctx);
    try t.expect(port != 0);
    try t.expect(!plat.accepts(plat.ctx, port));
    const addr = try std.fmt.allocPrint(c.a, "127.0.0.1:{d}", .{port});
    const pid = try plat.spawn(plat.ctx, c.a, &.{ toy, "fake", "--listen", addr, "--answer", "x" }, try env(c.a, &.{}), c.path("fake.log"));
    // The event waited for is the port taking a connection, not a time.
    while (!plat.accepts(plat.ctx, port)) {
        try t.expectEqual(@as(?u8, null), plat.poll(plat.ctx, pid));
        plat.sleepMs(plat.ctx, 1);
    }
    try t.expectEqual(@as(?u8, null), plat.poll(plat.ctx, pid));
    plat.kill(plat.ctx, pid, io_mod.sigterm);
    try t.expectEqual(@as(u8, 128 + 15), plat.wait(plat.ctx, pid));
    try kit.expectHas(try c.tmp.dir.readFileAlloc(c.a, "fake.log", 1000), try std.fmt.allocPrint(c.a, "listening on {s}\n", .{addr}));
    // A signal to a group that is gone is not an error.
    plat.kill(plat.ctx, pid, io_mod.sigterm);
    const done = try plat.spawn(plat.ctx, c.a, &.{ try kit.tool(c.a, "TOOLBOX"), "true" }, try env(c.a, &.{}), c.path("true.log"));
    while (true) {
        if (plat.poll(plat.ctx, done)) |status| {
            try t.expectEqual(@as(u8, 0), status);
            break;
        }
        plat.sleepMs(plat.ctx, 1);
    }
}

test "runInherit: the status of a program run with the streams inherited" {
    var c = try kit.Case.init();
    defer c.deinit();
    const toolbox = try kit.tool(c.a, "TOOLBOX");
    try t.expectEqual(@as(u8, 0), try plat.runInherit(plat.ctx, c.a, &.{ toolbox, "true" }, try env(c.a, &.{})));
    try t.expectEqual(@as(u8, 1), try plat.runInherit(plat.ctx, c.a, &.{ toolbox, "false" }, try env(c.a, &.{})));
}

test "the shell's form of a status, the clock, the random hex" {
    try t.expectEqual(@as(u8, 3), plat_mod.shellStatus(3 << 8));
    try t.expectEqual(@as(u8, 128 + 9), plat_mod.shellStatus(9));
    const before = plat.nowMs(plat.ctx);
    try t.expect(plat.nowMs(plat.ctx) >= before);
    var hex: [8]u8 = undefined;
    plat.randomHex(plat.ctx, &hex);
    for (hex) |ch| try t.expect(std.ascii.isHex(ch) and !std.ascii.isUpper(ch));
}
