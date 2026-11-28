//! Every allocation sweep of the package, in one file that runs before the others (all_test.zig imports it first): a case of each part run again with its
//! N-th allocation failing, for every N until it passes, so each error arm of an allocation runs. A sweep runs the common blocks hundreds of times, and
//! the coverage counters are one byte that wraps; the cases of the other files, which run after, run those blocks again.

const std = @import("std");
const deb = @import("deb.zig");
const farm = @import("farm.zig");
const probe = @import("probe.zig");
const run = @import("run.zig");
const plat_mod = @import("plat.zig");
const debkit = @import("debkit");
const pb = @import("pbkit.zig");
const kit = @import("testkit.zig");
const t = std.testing;

const action = pb.action;
const command = pb.command;
const image = kit.image;
const args = kit.runArgs;
const plat = plat_mod.real();

const base = [_][2][]const u8{ .{ "OSFamily", "Linux" }, .{ "ISA", "x86-64" }, .{ "container-image", "docker://repo@sha256:" ++ "0" ** 64 } };
const props = [_][2][]const u8{ .{ "OSFamily", "Linux" }, .{ "container-image", "docker://repo@sha256:" ++ "1" ** 64 } };
const argv = [_][]const u8{ "blackbox_run", "probe", "--expect", "OSFamily=Linux", "--expect", "container-image=docker://repo@sha256:" ++ "1" ** 64 };

fn farmCase(ran: []const []const u8, received: []const [2][]const u8) !kit.Case {
    var c = try kit.Case.init();
    c.argv = ran;
    c.put(".job/action", pb.action(c.a, &.{}));
    c.put(".job/command", pb.command(c.a, ran, received));
    return c;
}

fn env(a: std.mem.Allocator, pairs: []const [2][]const u8) !*std.process.EnvMap {
    const m = try a.create(std.process.EnvMap);
    m.* = std.process.EnvMap.init(a);
    for (pairs) |kv| try m.put(kv[0], kv[1]);
    return m;
}

test "an allocation that fails is the error, at every allocation of an unpack and of a refusal" {
    var c = try kit.Case.init();
    defer c.deinit();
    const cases = [_][]const u8{
        try debkit.packageOf(c.a, &.{.{ .name = "usr/bin/svc", .data = "x" }}),
        try debkit.package(c.a, "data.tar.zst", ""),
        try debkit.package(c.a, "data.tar", "not a tar"),
    };
    for (cases, 0..) |bytes, n| {
        const dir_name = try std.fmt.allocPrint(c.a, "oom{d}", .{n});
        var i: usize = 0;
        while (true) : (i += 1) {
            try c.tmp.dir.deleteTree(dir_name);
            try c.tmp.dir.makePath(dir_name);
            var dir = try c.tmp.dir.openDir(dir_name, .{});
            defer dir.close();
            var failing = std.testing.FailingAllocator.init(c.a, .{ .fail_index = i });
            if (deb.unpack(failing.allocator(), bytes, dir)) |_| break else |e| try t.expectEqual(error.OutOfMemory, e);
        }
    }
}


test "decode: an allocation that fails is the error, at every allocation" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const act = action(a, &.{.{ "OSFamily", "Linux" }});
    const cmd = command(a, &.{ "p", "q" }, &.{});
    const bare = action(a, &.{});
    const with_platform = command(a, &.{"p"}, &.{.{ "ISA", "x86-64" }});
    for ([_][2][]const u8{ .{ act, cmd }, .{ bare, with_platform } }) |pair| {
        var i: usize = 0;
        while (true) : (i += 1) {
            var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = i });
            if (farm.decode(failing.allocator(), pair[0], pair[1])) |job| {
                try t.expect(job.properties.len == 1);
                break;
            } else |e| try t.expectEqual(error.OutOfMemory, e);
        }
    }
    var j: usize = 0;
    while (true) : (j += 1) {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = j });
        if (farm.render(failing.allocator(), &.{.{ .name = "a", .value = "b" }})) |text| {
            try t.expectEqualStrings("a=b", text);
            break;
        } else |e| try t.expectEqual(error.OutOfMemory, e);
    }
}


test "read: an allocation that fails is not an unreadable file, at every allocation" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.put(".job/action", action(c.a, &.{}));
    c.put(".job/command", command(c.a, &.{"p"}, &base));
    var i: usize = 0;
    while (true) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(c.a, .{ .fail_index = i });
        if (farm.read(failing.allocator(), c.tmp.dir)) |job| {
            try t.expect(job != null);
            break;
        } else |e| try t.expectEqual(error.OutOfMemory, e);
    }
}


test "an allocation that fails ends the probe with the error, at every allocation" {
    var c = try farmCase(&argv, &props);
    defer c.deinit();
    var i: usize = 0;
    while (true) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(c.a, .{ .fail_index = i });
        c.out.clearRetainingCapacity();
        if (probe.probe(failing.allocator(), c.io(), argv[2..])) |status| {
            try t.expectEqual(@as(u8, 0), status);
            break;
        } else |e| try t.expectEqual(error.OutOfMemory, e);
    }
}


test "an allocation that fails is the error, at every allocation, in a run that passes and in each way one fails" {
    const scenarios = [_]struct { name: []const u8, b: kit.Behave, status: u8 }{
        .{ .name = "drv", .b = .{ .says = "x" }, .status = 0 },
        .{ .name = "drv", .b = .{ .status = 3, .says = "x" }, .status = 3 },
        .{ .name = "drv", .b = .{ .refuse = error.AccessDenied }, .status = 1 },
        .{ .name = "upfake", .b = .{ .ready_at = null, .exits_early = 7 }, .status = 1 },
        .{ .name = "svc", .b = .{ .dies = 9 }, .status = 1 },
    };
    for (scenarios) |sc| {
        var c = try kit.Case.init();
        defer c.deinit();
        _ = c.toyPackage();
        var i: usize = 0;
        while (true) : (i += 1) {
            c.plat.* = .{ .a = c.a };
            c.plat.behave(sc.name, sc.b);
            var failing = std.testing.FailingAllocator.init(c.a, .{ .fail_index = i });
            if (run.run(failing.allocator(), c.io(), args(&c, &.{}))) |status| {
                try t.expectEqual(sc.status, status);
                break;
            } else |e| try t.expectEqual(error.OutOfMemory, e);
        }
    }
    var f = try kit.Case.init();
    defer f.deinit();
    _ = f.toyPackage();
    f.put(".job/action", pb.action(f.a, &.{}));
    f.put(".job/command", pb.command(f.a, &.{"x"}, &.{.{ "container-image", image }}));
    var k: usize = 0;
    while (true) : (k += 1) {
        f.plat.* = .{ .a = f.a };
        var failing = std.testing.FailingAllocator.init(f.a, .{ .fail_index = k });
        if (run.run(failing.allocator(), f.io(), args(&f, &.{"--farm"}))) |status| {
            try t.expectEqual(@as(u8, 0), status);
            break;
        } else |e| try t.expectEqual(error.OutOfMemory, e);
    }
    var d = try kit.Case.init();
    defer d.deinit();
    var j: usize = 0;
    while (true) : (j += 1) {
        var failing = std.testing.FailingAllocator.init(d.a, .{ .fail_index = j });
        if (run.run(failing.allocator(), d.io(), args(&d, &.{ "--docker", "/usr/bin/docker" }))) |_| break else |e| try t.expectEqual(error.OutOfMemory, e);
    }
}


test "spawn: an allocation that fails is the error, at every allocation, and nothing is started" {
    var c = try kit.Case.init();
    defer c.deinit();
    const toolbox = try kit.tool(c.a, "TOOLBOX");
    const e = try env(c.a, &.{ .{ "A", "1" }, .{ "B", "2" } });
    var i: usize = 0;
    while (true) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(c.a, .{ .fail_index = i });
        if (plat.spawn(plat.ctx, failing.allocator(), &.{ toolbox, "true" }, e, c.path("t.log"))) |pid| {
            try t.expectEqual(@as(u8, 0), plat.wait(plat.ctx, pid));
            break;
        } else |err| try t.expectEqual(error.OutOfMemory, err);
    }
}
