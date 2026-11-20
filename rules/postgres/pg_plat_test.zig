//! Tests of the real platform of pg_run (pg_plat.zig) on real processes: the toolbox's `true`, `false` and `sleep` (TOOLBOX) and fake_pg's `check-env`
//! (FAKE_PG): the environment a program is started with, a program that is not there or not runnable, a status read when the process has ended or not yet,
//! a wait, a kill (also of a process that is gone), the clock, the sleep and the random digits. Nothing here asserts a time.

const std = @import("std");
const plat_mod = @import("pg_plat.zig");
const t = std.testing;

fn tool(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, name) catch {
        std.debug.print("the test target does not pass {s} (env_tools)\n", .{name});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

test "spawn starts the program with exactly the environment it is given, and wait gives its exit status" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const p = plat_mod.real();
    const fake = try tool(a, "FAKE_PG");
    const toolbox = try tool(a, "TOOLBOX");
    var env = std.process.EnvMap.init(a);
    try env.put("PG_PLAT_TEST", "value");
    try t.expectEqual(@as(u8, 0), p.wait(p.ctx, try p.spawn(p.ctx, a, &.{ fake, "check-env", "PG_PLAT_TEST", "value" }, &env, true)));
    try t.expectEqual(@as(u8, 1), p.wait(p.ctx, try p.spawn(p.ctx, a, &.{ fake, "check-env", "PG_PLAT_TEST", "other" }, &env, true)));
    // the process's own variables are not passed on
    try t.expectEqual(@as(u8, 1), p.wait(p.ctx, try p.spawn(p.ctx, a, &.{ fake, "check-env", "PATH", "x" }, &env, false)));
    try t.expectEqual(@as(u8, 7), p.wait(p.ctx, try p.spawn(p.ctx, a, &.{ fake, "exit", "7" }, &env, true)));
    try t.expectEqual(@as(u8, 0), p.wait(p.ctx, try p.spawn(p.ctx, a, &.{ toolbox, "true" }, &env, false)));
    try t.expectEqual(@as(u8, 1), p.wait(p.ctx, try p.spawn(p.ctx, a, &.{ toolbox, "false" }, &env, true)));
}

test "spawn says why a program cannot be started: FileNotFound for a missing one, AccessDenied for one that is not executable" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const p = plat_mod.real();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "plain", .data = "#!/nonexistent\n" });
    var env = std.process.EnvMap.init(a);
    try t.expectError(error.FileNotFound, p.spawn(p.ctx, a, &.{"/no/such/program"}, &env, true));
    try t.expectError(error.AccessDenied, p.spawn(p.ctx, a, &.{try tmp.dir.realpathAlloc(a, "plain")}, &env, true));
    // any other reason the program cannot be reached is passed on as it is
    try t.expectError(error.NameTooLong, p.spawn(p.ctx, a, &.{"/" ++ "a" ** 300}, &env, true));
}

test "poll is null while the process runs and its status once it has ended; kill ends it, wait reports the signal as 128+N, and a kill of a gone process is nothing" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const p = plat_mod.real();
    const toolbox = try tool(a, "TOOLBOX");
    var env = std.process.EnvMap.init(a);
    const sleeper = try p.spawn(p.ctx, a, &.{ toolbox, "sleep", "1d" }, &env, true);
    try t.expectEqual(@as(?u8, null), p.poll(p.ctx, sleeper));
    p.kill(p.ctx, sleeper, 9);
    try t.expectEqual(@as(u8, 137), p.wait(p.ctx, sleeper));
    p.kill(p.ctx, sleeper, 9);
    // a process that ends by itself is seen by poll, with no wait (it is taken as soon as it is a zombie)
    const quick = try p.spawn(p.ctx, a, &.{ toolbox, "false" }, &env, true);
    const status = while (true) {
        if (p.poll(p.ctx, quick)) |s| break s;
        std.Thread.yield() catch {};
    };
    try t.expectEqual(@as(u8, 1), status);
}

test "shellStatus is the exit code, or 128 and the signal for a death by signal" {
    try t.expectEqual(@as(u8, 0), plat_mod.shellStatus(0));
    try t.expectEqual(@as(u8, 3), plat_mod.shellStatus(3 << 8));
    try t.expectEqual(@as(u8, 255), plat_mod.shellStatus(255 << 8));
    try t.expectEqual(@as(u8, 137), plat_mod.shellStatus(9));
    try t.expectEqual(@as(u8, 143), plat_mod.shellStatus(15));
}

test "the clock never goes back, the sleep returns, and the random digits are eight lowercase hexadecimal digits that differ between calls" {
    const p = plat_mod.real();
    const before = p.nowMs(p.ctx);
    p.sleepMs(p.ctx, 0);
    p.sleepMs(p.ctx, 1);
    try t.expect(p.nowMs(p.ctx) >= before);
    var one: [8]u8 = undefined;
    var two: [8]u8 = undefined;
    p.randomHex(p.ctx, &one);
    p.randomHex(p.ctx, &two);
    for (one) |c| try t.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    for (two) |c| try t.expect(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'));
    try t.expect(!std.mem.eql(u8, &one, &two));
}