//! plat.zig, the real platform, with real processes: the toolbox (rules/toolbox), a program that only has a status or reads its environment back.

const std = @import("std");
const plat_mod = @import("plat.zig");
const kit = @import("testkit.zig");
const t = std.testing;

const plat = plat_mod.real();

fn env(a: std.mem.Allocator, pairs: []const [2][]const u8) !*std.process.EnvMap {
    const m = try a.create(std.process.EnvMap);
    m.* = std.process.EnvMap.init(a);
    for (pairs) |kv| try m.put(kv[0], kv[1]);
    return m;
}

test "the status of a program run with the streams inherited, given exactly its environment" {
    var c = try kit.Case.init();
    defer c.deinit();
    const toolbox = try kit.tool(c.a, "TOOLBOX");
    try t.expectEqual(@as(u8, 0), try plat.runInherit(plat.ctx, c.a, &.{ toolbox, "true" }, try env(c.a, &.{})));
    try t.expectEqual(@as(u8, 1), try plat.runInherit(plat.ctx, c.a, &.{ toolbox, "false" }, try env(c.a, &.{})));
    // `env` sees exactly the variables it is given: one set, one not.
    try t.expectEqual(@as(u8, 0), try plat.runInherit(plat.ctx, c.a, &.{ toolbox, "printenv", "GREETING" }, try env(c.a, &.{.{ "GREETING", "hello" }})));
    try t.expectEqual(@as(u8, 1), try plat.runInherit(plat.ctx, c.a, &.{ toolbox, "printenv", "HOME" }, try env(c.a, &.{.{ "GREETING", "hello" }})));
}

test "a program that is not there, or not executable, is refused before anything is started" {
    var c = try kit.Case.init();
    defer c.deinit();
    const e = try env(c.a, &.{});
    try t.expectError(error.FileNotFound, plat.runInherit(plat.ctx, c.a, &.{c.path("absent")}, e));
    c.put("data", "not a program");
    try t.expectError(error.AccessDenied, plat.runInherit(plat.ctx, c.a, &.{c.path("data")}, e));
}

test "the shell's form of a status" {
    try t.expectEqual(@as(u8, 3), plat_mod.shellStatus(3 << 8));
    try t.expectEqual(@as(u8, 128 + 9), plat_mod.shellStatus(9));
}
