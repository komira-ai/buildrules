//! blackbox_run as a process, with the real platform: the toy service's and the toy fake's packages (toy/) put onto a root of the case's own, then the
//! toy's driver run there. A run that passes, and a run made red each way a black-box test fails: a driver that fails (the case a `blackbox_test` target
//! turns red for), a package that is not the pinned one, and a driver that is not there. Nothing here asserts a time: the driver waits for ports and exits.

const std = @import("std");
const debkit = @import("debkit");
const t = std.testing;

const Run = struct { code: u8, stdout: []const u8, stderr: []const u8 };

fn tool(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, name) catch {
        std.debug.print("the test target does not pass {s} (env_tools), so that program cannot be run\n", .{name});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    dir: []const u8,
    runner: []const u8,
    service: []const u8,
    fake: []const u8,
    sha256: []const u8,
    size: []const u8,

    fn init() !Case {
        var c: Case = undefined;
        c.arena = std.heap.ArenaAllocator.init(t.allocator);
        const a = c.arena.allocator();
        c.tmp = std.testing.tmpDir(.{});
        c.dir = try c.tmp.dir.realpathAlloc(a, ".");
        try c.tmp.dir.makePath("root");
        c.runner = try tool(a, "BLACKBOX_RUN");
        const toy = try std.fs.cwd().readFileAlloc(a, try tool(a, "TOY"), 1 << 26);
        const service = try debkit.packageOf(a, &.{.{ .name = "usr/bin/toy-service", .mode = 0o755, .data = toy }});
        try c.tmp.dir.writeFile(.{ .sub_path = "service.deb", .data = service });
        try c.tmp.dir.writeFile(.{ .sub_path = "fake.deb", .data = try debkit.packageOf(a, &.{.{ .name = "usr/bin/toy-fake", .mode = 0o755, .data = toy }}) });
        c.service = try std.fs.path.join(a, &.{ c.dir, "service.deb" });
        c.fake = try std.fs.path.join(a, &.{ c.dir, "fake.deb" });
        var d: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(service, &d, .{});
        c.sha256 = try a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
        c.size = try std.fmt.allocPrint(a, "{d}", .{service.len});
        return c;
    }

    fn deinit(c: *Case) void {
        c.tmp.cleanup();
        c.arena.deinit();
    }

    /// `blackbox_run run` of the toy's two packages (the service's pinned by `sha256`) and `driver`.
    fn run(c: *Case, driver: []const u8, sha256: []const u8) !Run {
        const a = c.arena.allocator();
        const argv = [_][]const u8{
            c.runner,    "run",
            "--image",   "docker://repo@sha256:" ++ "1" ** 64,
            "--root",    try std.fs.path.join(a, &.{ c.dir, "root" }),
            "--package", c.service,
            "--sha256",  sha256,
            "--size",    c.size,
            "--package", c.fake,
            "--driver",  driver,
        };
        const r = try std.process.Child.run(.{ .allocator = a, .argv = &argv, .cwd = c.dir, .max_output_bytes = 1 << 22 });
        const code: u8 = switch (r.term) {
            .Exited => |x| x,
            else => {
                std.debug.print("blackbox_run did not exit: {any}\n{s}\n", .{ r.term, r.stderr });
                return error.TestUnexpectedResult;
            },
        };
        return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
    }
};

fn has(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find\n  {s}\nin\n{s}\n", .{ needle, haystack });
        return error.TestExpectedText;
    }
}

test "the toy's packages on a root, and its driver run there: the service's answer went through the fake, and the run passes" {
    var c = try Case.init();
    defer c.deinit();
    const r = try c.run(try tool(c.arena.allocator(), "TOY_DRIVER"), c.sha256);
    if (r.code != 0) std.debug.print("{s}\n{s}\n", .{ r.stdout, r.stderr });
    try t.expectEqual(@as(u8, 0), r.code);
    try has(r.stdout, "got `ask`, answered `from the fake`\n");
    try has(r.stdout, "got `hello`, answered `service saw: from the fake`\n");
    try has(r.stdout, "driver: the service answered `service saw: from the fake`\n");
    try has(r.stderr, "blackbox_run: run: passed: 2 package(s) put onto ");
}

test "a driver that fails turns the run red, with what the service and the fake said" {
    var c = try Case.init();
    defer c.deinit();
    const r = try c.run(try tool(c.arena.allocator(), "TOY_DRIVER_WRONG"), c.sha256);
    try t.expectEqual(@as(u8, 1), r.code);
    try has(r.stderr, "blackbox_run: run: the driver exited 1\n");
    try has(r.stdout, "got `hello`, answered `service saw: from the fake`\n");
    try has(r.stdout, "driver: the service answered `service saw: from the fake`, not `service saw: another answer`\n");
}

test "a package that is not the pinned one turns the run red before anything is put onto the root" {
    var c = try Case.init();
    defer c.deinit();
    const r = try c.run(try tool(c.arena.allocator(), "TOY_DRIVER"), "0" ** 64);
    try t.expectEqual(@as(u8, 1), r.code);
    try has(r.stderr, "not the pinned ");
    try t.expectError(error.FileNotFound, c.tmp.dir.access("root/usr/bin/toy-service", .{}));
}

test "a driver that is not there turns the run red, naming it" {
    var c = try Case.init();
    defer c.deinit();
    const r = try c.run(try std.fs.path.join(c.arena.allocator(), &.{ c.dir, "no-driver" }), c.sha256);
    try t.expectEqual(@as(u8, 1), r.code);
    try has(r.stderr, "cannot run the driver ");
}
