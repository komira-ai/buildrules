//! probe.zig: the farm job's root written by the case (farm_test.zig's encoder), and the probe's verdict and exact messages.

const std = @import("std");
const probe = @import("probe.zig");
const pb = @import("pbkit.zig");
const kit = @import("testkit.zig");
const t = std.testing;

const props = [_][2][]const u8{ .{ "OSFamily", "Linux" }, .{ "container-image", "docker://repo@sha256:" ++ "1" ** 64 } };

/// A case whose root is a farm job that ran `argv` and received `received`.
fn farmCase(ran: []const []const u8, received: []const [2][]const u8) !kit.Case {
    var c = try kit.Case.init();
    c.argv = ran;
    c.put(".job/action", pb.action(c.a, &.{}));
    c.put(".job/command", pb.command(c.a, ran, received));
    return c;
}

const argv = [_][]const u8{ "blackbox_run", "probe", "--expect", "OSFamily=Linux", "--expect", "container-image=docker://repo@sha256:" ++ "1" ** 64 };

test "a farm job that received exactly the expected set passes, and says its digest and the set" {
    var c = try farmCase(&argv, &props);
    defer c.deinit();
    try t.expectEqual(@as(u8, 0), try probe.probe(c.a, c.io(), argv[2..]));
    const act = pb.action(c.a, &.{});
    const want = try std.fmt.allocPrint(c.a, "farm job: action {s}:{d}\nproperties the frontend received (from the command): OSFamily=Linux,container-image=docker://repo@sha256:" ++ "1" ** 64 ++ "\n", .{ c.sha256(act), act.len });
    try t.expectEqualStrings(want, c.stdout());
    try t.expectEqualStrings("", c.stderr());
}

test "a job whose Action holds the platform says it was read from the Action" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.argv = &.{ "blackbox_run", "probe", "--expect", "OSFamily=Linux" };
    c.put(".job/action", pb.action(c.a, &.{.{ "OSFamily", "Linux" }}));
    c.put(".job/command", pb.command(c.a, c.argv, &.{}));
    try t.expectEqual(@as(u8, 0), try probe.probe(c.a, c.io(), c.argv[2..]));
    try kit.expectHas(c.stdout(), "properties the frontend received (from the action): OSFamily=Linux\n");
}

test "a property missing, one with another value, and one the test did not set are each said" {
    const got = [_][2][]const u8{ .{ "container-image", "docker://repo@sha256:" ++ "2" ** 64 }, .{ "ISA", "x86-64" } };
    var c = try farmCase(&argv, &got);
    defer c.deinit();
    try t.expectEqual(@as(u8, 1), try probe.probe(c.a, c.io(), argv[2..]));
    try t.expectEqualStrings("blackbox_run: probe: the property `OSFamily` did not reach the frontend\n" ++
        "blackbox_run: probe: the property `container-image` reached the frontend as `docker://repo@sha256:" ++ "2" ** 64 ++ "`, not `docker://repo@sha256:" ++ "1" ** 64 ++ "`\n" ++
        "blackbox_run: probe: the frontend received the property `ISA=x86-64`, which the test did not set\n", c.stderr());
}

test "a farm job that ran another command is not this run" {
    var c = try farmCase(&argv, &props);
    defer c.deinit();
    c.put(".job/command", pb.command(c.a, &.{ "other", "x" }, &props));
    try t.expectEqual(@as(u8, 1), try probe.probe(c.a, c.io(), argv[2..]));
    try t.expectEqualStrings("blackbox_run: probe: the job's Command is not this run: it ran 2 arguments, starting `other`\n", c.stderr());
    c.err.clearRetainingCapacity();
    c.put(".job/command", pb.command(c.a, &.{}, &props));
    try t.expectEqual(@as(u8, 1), try probe.probe(c.a, c.io(), argv[2..]));
    try t.expectEqualStrings("blackbox_run: probe: the job's Command is not this run: it ran 0 arguments, starting ``\n", c.stderr());
}

test "off the farm, and on a job whose Command cannot be read, the probe fails saying so" {
    var c = try kit.Case.init();
    defer c.deinit();
    try t.expectEqual(@as(u8, 1), try probe.probe(c.a, c.io(), &.{}));
    try t.expectEqualStrings("blackbox_run: probe: not a farm job: the root holds no job directory (a top-level `.<name>/` holding `action` and `command`), so this run is not a job of the farm's executor\n", c.stderr());
    c.err.clearRetainingCapacity();
    c.put(".job/action", pb.action(c.a, &.{}));
    try t.expectEqual(@as(u8, 1), try probe.probe(c.a, c.io(), &.{}));
    try t.expectEqualStrings("blackbox_run: probe: the farm job's Action or Command cannot be read: Unreadable\n", c.stderr());
    c.err.clearRetainingCapacity();
    c.put(".job/command", "\x0a");
    try t.expectEqual(@as(u8, 1), try probe.probe(c.a, c.io(), &.{}));
    try t.expectEqualStrings("blackbox_run: probe: the farm job's Action or Command cannot be read: Malformed\n", c.stderr());
}

test "a wrong command line is exit 2" {
    var c = try kit.Case.init();
    defer c.deinit();
    try t.expectEqual(@as(u8, 2), try probe.probe(c.a, c.io(), &.{"--other"}));
    try t.expectEqual(@as(u8, 2), try probe.probe(c.a, c.io(), &.{"--expect"}));
    try t.expectEqual(@as(u8, 2), try probe.probe(c.a, c.io(), &.{ "--expect", "novalue" }));
    try t.expectEqualStrings("blackbox_run: probe: unknown argument `--other`: the arguments are `--expect NAME=VALUE`, any number of times\n" ++
        "blackbox_run: probe: unknown argument `--expect`: the arguments are `--expect NAME=VALUE`, any number of times\n" ++
        "blackbox_run: probe: `--expect novalue` is not NAME=VALUE\n", c.stderr());
}

