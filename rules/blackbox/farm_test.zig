//! farm.zig: an Action and a Command encoded here, field by field from the REAPI schema, decoded back; and the reading of a job's root.

const std = @import("std");
const farm = @import("farm.zig");
const kit = @import("testkit.zig");
const pbkit = @import("pbkit.zig");
const Pb = pbkit.Pb;
const action = pbkit.action;
const command = pbkit.command;
const t = std.testing;

const base = [_][2][]const u8{ .{ "OSFamily", "Linux" }, .{ "ISA", "x86-64" }, .{ "container-image", "docker://repo@sha256:" ++ "0" ** 64 } };

test "a job whose Action has no platform: the Command's properties, the digest of the Action's bytes, the Command's arguments" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const act = action(a, &.{});
    const job = try farm.decode(a, act, command(a, &.{ "buck-out/x/blackbox_run", "probe" }, &base));
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(act, &d, .{});
    try t.expectEqualStrings(&std.fmt.bytesToHex(d, .lower), &job.hash);
    try t.expectEqual(act.len, job.size);
    try t.expectEqual(farm.From.command, job.from);
    try t.expectEqualStrings("OSFamily=Linux,ISA=x86-64,container-image=docker://repo@sha256:" ++ "0" ** 64, try farm.render(a, job.properties));
    try t.expectEqual(@as(usize, 2), job.arguments.len);
    try t.expectEqualStrings("probe", job.arguments[1]);
}

test "a job with no platform in the Action or the Command: no properties, read from the Command" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const job = try farm.decode(a, action(a, &.{}), command(a, &.{"p"}, &.{}));
    try t.expectEqual(farm.From.command, job.from);
    try t.expectEqual(@as(usize, 0), job.properties.len);
}

test "a job whose Action has a platform: the Action's, whatever the Command says" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const job = try farm.decode(a, action(a, &.{.{ "OSFamily", "Linux" }}), command(a, &.{"p"}, &base));
    try t.expectEqual(farm.From.action, job.from);
    try t.expectEqualStrings("OSFamily=Linux", try farm.render(a, job.properties));
}

test "fixed-width fields are stepped over, a property with no name or value reads as empty, and the last of a field wins" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prop = Pb{ .a = a };
    var plat = Pb{ .a = a };
    var second = Pb{ .a = a };
    _ = plat.bytes(1, prop.fixed32(3).done()).bytes(1, second.bytes(1, "k").bytes(1, "key").bytes(2, "v").done());
    var act = Pb{ .a = a };
    _ = act.fixed64(6).bytes(1, "d").bytes(10, plat.done());
    const job = try farm.decode(a, act.done(), "");
    try t.expectEqualStrings("=,key=v", try farm.render(a, job.properties));
    try t.expectEqual(@as(usize, 0), job.arguments.len);
}

test "an Action that is not one: no command digest, a cut-off varint or field, a group, a varint of more than ten bytes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.Malformed, farm.decode(a, "", ""));
    var no_digest = Pb{ .a = a };
    try t.expectError(error.Malformed, farm.decode(a, no_digest.bytes(10, "").done(), ""));
    const act = action(a, &.{});
    try t.expectError(error.Malformed, farm.decode(a, act[0 .. act.len - 1], ""));
    try t.expectError(error.Malformed, farm.decode(a, &.{0x0a}, ""));
    try t.expectError(error.Malformed, farm.decode(a, &.{0x0b}, ""));
    try t.expectError(error.Malformed, farm.decode(a, &.{ 0x09, 0, 0 }, ""));
    try t.expectError(error.Malformed, farm.decode(a, &.{ 0x0d, 0 }, ""));
    try t.expectError(error.Malformed, farm.decode(a, &.{ 0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 }, ""));
    try t.expectError(error.Malformed, farm.decode(a, act, &.{0x0a}));
    // A varint field with no value; a length beyond the message.
    try t.expectError(error.Malformed, farm.decode(a, &.{0x08}, ""));
    try t.expectError(error.Malformed, farm.decode(a, &.{ 0x0a, 0x05, 'a' }, ""));
}

test "a platform, a property or a Command that is not one, inside an Action that is" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bad_platform = Pb{ .a = a };
    _ = bad_platform.bytes(1, "d").bytes(10, "\x0a");
    try t.expectError(error.Malformed, farm.decode(a, bad_platform.done(), ""));
    var plat = Pb{ .a = a };
    var bad_property = Pb{ .a = a };
    _ = bad_property.bytes(1, "d").bytes(10, plat.bytes(1, "\x0a").done());
    try t.expectError(error.Malformed, farm.decode(a, bad_property.done(), ""));
    // With a platform in the Action, the Command is read for its arguments alone; without one, for its platform too.
    try t.expectError(error.Malformed, farm.decode(a, action(a, &.{.{ "k", "v" }}), "\x0a"));
    var cmd = Pb{ .a = a };
    try t.expectError(error.Malformed, farm.decode(a, action(a, &.{}), cmd.bytes(5, "\x0a").done()));
}

test "read: the job directory is found by what it holds; anything else at the top is not one, and two are refused" {
    var c = try kit.Case.init();
    defer c.deinit();
    // Not job directories: a hidden directory without an Action, a hidden file, a directory whose name does not start with `.`, a one-letter one.
    c.put(".cache/command", "x");
    c.put(".hidden", "x");
    c.put("work/action", "x");
    c.put("w/action", "x");
    try t.expectEqual(@as(?farm.Job, null), try farm.read(c.a, c.tmp.dir));
    c.put(".job/action", action(c.a, &.{}));
    c.put(".job/command", command(c.a, &.{"only"}, &base));
    try t.expectEqualStrings("only", (try farm.read(c.a, c.tmp.dir)).?.arguments[0]);
    c.put(".other/action", action(c.a, &.{}));
    try t.expectError(error.TwoJobDirectories, farm.read(c.a, c.tmp.dir));
}

test "read: no job directory is no farm job; an Action without its Command, or a directory in its place, cannot be read" {
    var c = try kit.Case.init();
    defer c.deinit();
    try t.expectEqual(@as(?farm.Job, null), try farm.read(c.a, c.tmp.dir));
    c.put(".job/action", action(c.a, &.{}));
    try t.expectError(error.Unreadable, farm.read(c.a, c.tmp.dir));
    c.put(".job/command", command(c.a, &.{"p"}, &base));
    const job = (try farm.read(c.a, c.tmp.dir)).?;
    try t.expectEqual(farm.From.command, job.from);
    try c.tmp.dir.deleteFile(".job/action");
    try c.tmp.dir.makePath(".job/action");
    try t.expectError(error.Unreadable, farm.read(c.a, c.tmp.dir));
}

test "value: the exact spelling; matchesArgv: the program by its base name, then every argument" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const job = try farm.decode(a, action(a, &.{}), command(a, &.{ "buck-out/v2/blackbox_run", "probe", "--expect", "x=y" }, &base));
    try t.expectEqualStrings("Linux", farm.value(job.properties, "OSFamily").?);
    try t.expectEqual(@as(?[]const u8, null), farm.value(job.properties, "Container-Image"));
    try t.expect(farm.matchesArgv(job, &.{ "/job-work/buck-out/v2/blackbox_run", "probe", "--expect", "x=y" }));
    try t.expect(!farm.matchesArgv(job, &.{ "/job-work/buck-out/v2/blackbox_run", "probe", "--expect", "x=z" }));
    try t.expect(!farm.matchesArgv(job, &.{ "/job-work/buck-out/v2/other", "probe", "--expect", "x=y" }));
    try t.expect(!farm.matchesArgv(job, &.{ "/job-work/buck-out/v2/blackbox_run", "probe" }));
    try t.expect(!farm.matchesArgv(job, &.{}));
    try t.expectEqualStrings("", try farm.render(a, &.{}));
}
