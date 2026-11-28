//! blackbox_run as a process, with the real platform: the toy service (toy/) packaged as a Debian package, run against the toy's fake and driver. A run
//! that passes, and a run made red each way a black-box test fails: a driver that fails (the case a `blackbox_test` target turns red for), a fake that
//! exits before it is ready, a package that is not the pinned one, and a local run with no docker. Nothing here asserts a time: the processes are waited
//! for by their ports and their exits.

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
    toy: []const u8,
    package: []const u8,
    sha256: []const u8,
    size: []const u8,

    fn init() !Case {
        var c: Case = undefined;
        c.arena = std.heap.ArenaAllocator.init(t.allocator);
        const a = c.arena.allocator();
        c.tmp = std.testing.tmpDir(.{});
        c.dir = try c.tmp.dir.realpathAlloc(a, ".");
        try c.tmp.dir.makePath("tmp");
        c.runner = try tool(a, "BLACKBOX_RUN");
        c.toy = try tool(a, "TOY");
        const program = try std.fs.cwd().readFileAlloc(a, c.toy, 1 << 26);
        const bytes = try debkit.packageOf(a, &.{.{ .name = "usr/bin/toy", .mode = 0o755, .data = program }});
        try c.tmp.dir.writeFile(.{ .sub_path = "toy.deb", .data = bytes });
        c.package = try std.fs.path.join(a, &.{ c.dir, "toy.deb" });
        var d: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
        c.sha256 = try a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
        c.size = try std.fmt.allocPrint(a, "{d}", .{bytes.len});
        return c;
    }

    fn deinit(c: *Case) void {
        c.tmp.cleanup();
        c.arena.deinit();
    }

    /// `blackbox_run run` of the toy: the service asks the fake `upstream`, the driver expects `expect`; `extra` follows.
    fn run(c: *Case, expect: []const u8, fake: []const []const u8, extra: []const []const u8) !Run {
        const a = c.arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{
            c.runner,        "run",
            "--image",       "docker://repo@sha256:" ++ "1" ** 64,
            "--package",     c.package,
            "--sha256",      c.sha256,
            "--size",        c.size,
            "--service",     "usr/bin/toy",
            "--flag",        "service",
            "--flag",        "--listen",
            "--flag",        "{addr:service}",
            "--flag",        "--upstream",
            "--flag",        "{addr:upstream}",
        });
        try argv.appendSlice(a, fake);
        try argv.appendSlice(a, &.{ "--driver", c.toy, "--driver-flag", "driver", "--driver-flag", "--service", "--driver-flag", "{addr:service}", "--driver-flag", "--expect", "--driver-flag", expect });
        try argv.appendSlice(a, extra);
        var env = std.process.EnvMap.init(a);
        try env.put("TMPDIR", try std.fs.path.join(a, &.{ c.dir, "tmp" }));
        const r = try std.process.Child.run(.{ .allocator = a, .argv = argv.items, .cwd = c.dir, .env_map = &env, .max_output_bytes = 1 << 22 });
        const code: u8 = switch (r.term) {
            .Exited => |x| x,
            else => {
                std.debug.print("blackbox_run did not exit: {any}\n{s}\n", .{ r.term, r.stderr });
                return error.TestUnexpectedResult;
            },
        };
        return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
    }

    fn toyFake(c: *Case, answer: []const u8) ![]const []const u8 {
        const a = c.arena.allocator();
        return a.dupe([]const u8, &.{ "--fake", try std.fmt.allocPrint(a, "upstream={s}", .{c.toy}), "--fake-flag", "upstream=fake", "--fake-flag", "upstream=--listen", "--fake-flag", "upstream={addr:upstream}", "--fake-flag", "upstream=--answer", "--fake-flag", try std.fmt.allocPrint(a, "upstream={s}", .{answer}) });
    }
};

fn has(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find\n  {s}\nin\n{s}\n", .{ needle, haystack });
        return error.TestExpectedText;
    }
}

test "the toy's package, run against its fake: the driver gets the fake's answer through the service, and the run passes" {
    var c = try Case.init();
    defer c.deinit();
    const r = try c.run("service saw: from the fake", try c.toyFake("from the fake"), &.{});
    if (r.code != 0) std.debug.print("{s}\n{s}\n", .{ r.stdout, r.stderr });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("---- the log of the driver ----\ndriver: the service answered `service saw: from the fake`\n", r.stdout);
    try has(r.stderr, "blackbox_run: run: passed: the driver exited 0 and the 1 fake(s) and the service lived through it\n");
    // The run's directory is gone.
    var tmp = try c.tmp.dir.openDir("tmp", .{ .iterate = true });
    defer tmp.close();
    var it = tmp.iterate();
    try t.expectEqual(@as(?std.fs.Dir.Entry, null), try it.next());
}

test "a driver that fails turns the run red: its status, and every log, the fake's and the service's included" {
    var c = try Case.init();
    defer c.deinit();
    const r = try c.run("service saw: something else", try c.toyFake("from the fake"), &.{});
    try t.expectEqual(@as(u8, 1), r.code);
    try has(r.stderr, "blackbox_run: run: the driver exited 1\n");
    try has(r.stdout, "---- the log of the upstream ----\n");
    try has(r.stdout, "got `ask`, answered `from the fake`\n");
    try has(r.stdout, "---- the log of the service ----\n");
    try has(r.stdout, "got `hello`, answered `service saw: from the fake`\n");
    try has(r.stdout, "---- the log of the driver ----\ndriver: the service answered `service saw: from the fake`, not `service saw: something else`\n");
}

test "a fake that exits before it takes a connection turns the run red, and the service is never started" {
    var c = try Case.init();
    defer c.deinit();
    const a = c.arena.allocator();
    const fake = try a.dupe([]const u8, &.{ "--fake", try std.fmt.allocPrint(a, "upstream={s}", .{try tool(a, "TOOLBOX")}), "--fake-flag", "upstream=false" });
    const r = try c.run("x", fake, &.{});
    try t.expectEqual(@as(u8, 1), r.code);
    try has(r.stderr, "blackbox_run: run: the upstream exited 1 before it took a connection on 127.0.0.1:");
    try has(r.stdout, "---- the log of the service ----\n(no log: FileNotFound)\n");
}

test "a package that is not the pinned one turns the run red before anything starts" {
    var c = try Case.init();
    defer c.deinit();
    c.sha256 = "0" ** 64;
    const r = try c.run("x", try c.toyFake("y"), &.{});
    try t.expectEqual(@as(u8, 1), r.code);
    try has(r.stderr, "not the pinned ");
    try t.expectEqualStrings("", r.stdout);
}

test "a local run that names no docker fails, naming the key" {
    var c = try Case.init();
    defer c.deinit();
    const r = try c.run("x", try c.toyFake("y"), &.{ "--docker", "" });
    try t.expectEqual(@as(u8, 2), r.code);
    try has(r.stderr, "`-c blackbox.docker=<path>`");
}
