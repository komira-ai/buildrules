//! The shipped toolbox executable as a process, `zig test` of this file run as a build action by `:toolbox_exe_test` (its path is in the
//! environment as TOOLBOX, the `zig_test`'s `env_tools`). toolbox_test.zig calls `entry` in-process; these run what `main` adds around it: the
//! applet chosen by the name of a link, the real clock, the real stdin, stdout and environment, a stdout that is flushed (or fails to be) at
//! the end, and the real start of a child by `env`. Without TOOLBOX every case fails: none passes without running the executable.

const std = @import("std");
const t = std.testing;
const tk = @import("testkit.zig");

const Run = struct { code: u8, stdout: []const u8, stderr: []const u8 };

const Var = [2][]const u8;

/// Runs `argv` in `dir` with exactly `env` as its environment.
fn run(a: std.mem.Allocator, dir: std.fs.Dir, argv: []const []const u8, env: []const Var) !Run {
    var map = std.process.EnvMap.init(a);
    for (env) |kv| try map.put(kv[0], kv[1]);
    const r = try std.process.Child.run(.{
        .allocator = a,
        .argv = argv,
        .cwd_dir = dir,
        .env_map = &map,
        .max_output_bytes = 1 << 22,
    });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => {
            std.debug.print("the toolbox did not exit: {any}\n", .{r.term});
            return error.TestUnexpectedResult;
        },
    };
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
}

fn expectRun(r: Run, code: u8, stdout: []const u8) !void {
    if (r.code != code or !std.mem.eql(u8, r.stdout, stdout)) {
        std.debug.print("exit {d} (want {d}), stdout '{s}' (want '{s}'), stderr '{s}'\n", .{ r.code, code, r.stdout, stdout, r.stderr });
        return error.TestUnexpectedResult;
    }
}

/// A link to the executable in `dir`, named `name`; its absolute path.
fn link(c: *tk.Case, exe: []const u8, name: []const u8) ![]const u8 {
    try c.tmp.dir.symLink(exe, name, .{});
    return c.at(name);
}

test "by name: `toolbox <applet>`, and a link named for the applet; an unknown one is 127; none is usage" {
    var c = tk.Case.init();
    defer c.deinit();
    const a = c.alloc();
    const exe = try tk.exe(a);
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "echo", "hi", "there" }, &.{}), 0, "hi there\n");
    try expectRun(try run(a, c.tmp.dir, &.{ try link(&c, exe, "echo"), "-n", "x" }, &.{}), 0, "x");
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "nosuch" }, &.{}), 127, "");
    try expectRun(try run(a, c.tmp.dir, &.{try link(&c, exe, "nosuch")}, &.{}), 127, "");
    try expectRun(try run(a, c.tmp.dir, &.{exe}, &.{}), 1, "");
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "--list" }, &.{}), 0, "rm\nmkdir\nln\nsleep\necho\ncat\nenv\nprintenv\ntrue\nfalse\n");
    try expectRun(try run(a, c.tmp.dir, &.{try link(&c, exe, "true")}, &.{}), 0, "");
    try expectRun(try run(a, c.tmp.dir, &.{try link(&c, exe, "false")}, &.{}), 1, "");
}

test "rm -rf and mkdir -p through links: they act on the file system, in the working directory, and are quiet about a missing or an existing path" {
    var c = tk.Case.init();
    defer c.deinit();
    const a = c.alloc();
    const exe = try tk.exe(a);
    const rm = try link(&c, exe, "rm");
    const mkdir = try link(&c, exe, "mkdir");
    try expectRun(try run(a, c.tmp.dir, &.{ mkdir, "-p", "d/e/f" }, &.{}), 0, "");
    try expectRun(try run(a, c.tmp.dir, &.{ mkdir, "-p", "d/e/f" }, &.{}), 0, "");
    try t.expect(c.exists("d/e/f"));
    try expectRun(try run(a, c.tmp.dir, &.{ rm, "-rf", "d", "never-there" }, &.{}), 0, "");
    try t.expect(!c.exists("d"));
    try expectRun(try run(a, c.tmp.dir, &.{ rm, "-rf", "never-there" }, &.{}), 0, "");
    const r = try run(a, c.tmp.dir, &.{ rm, "never-there" }, &.{});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("rm: cannot remove 'never-there': No such file or directory\n", r.stderr);
}

test "sleep really waits: 0.3 seconds is at least 0.25, and 0 does not wait" {
    var c = tk.Case.init();
    defer c.deinit();
    const a = c.alloc();
    const exe = try tk.exe(a);
    var timer = try std.time.Timer.start();
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "sleep", "0.3" }, &.{}), 0, "");
    const waited = timer.read();
    if (waited < 250 * std.time.ns_per_ms or waited > 20 * std.time.ns_per_s) {
        std.debug.print("sleep 0.3 took {d} ms\n", .{waited / std.time.ns_per_ms});
        return error.TestUnexpectedResult;
    }
    timer.reset();
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "sleep", "0" }, &.{}), 0, "");
    try t.expect(timer.read() < 5 * std.time.ns_per_s);
}

test "sleep 30 blocks until it is killed" {
    var c = tk.Case.init();
    defer c.deinit();
    const a = c.alloc();
    const exe = try tk.exe(a);
    var child = std.process.Child.init(&.{ exe, "sleep", "30" }, a);
    try child.spawn();
    std.Thread.sleep(300 * std.time.ns_per_ms);
    // After 0.3 s it is still waiting: killed, it ends by the signal, not by its own exit.
    const term = try child.kill();
    try t.expect(term == .Signal);
}

test "cat copies stdin to stdout through the real streams, and a long file whole (the output is flushed at the end)" {
    var c = tk.Case.init();
    defer c.deinit();
    const a = c.alloc();
    const exe = try tk.exe(a);
    var child = std.process.Child.init(&.{ exe, "cat" }, a);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    try child.stdin.?.writeAll("typed in\nsecond line");
    child.stdin.?.close();
    child.stdin = null;
    const out = try child.stdout.?.readToEndAlloc(a, 1 << 20);
    const term = try child.wait();
    try t.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    try t.expectEqualStrings("typed in\nsecond line", out);
    const big = try a.alloc(u8, 200_000);
    for (big, 0..) |*b, i| b.* = @intCast('a' + i % 26);
    try c.put("big", big);
    const r = try run(a, c.tmp.dir, &.{ exe, "cat", "big" }, &.{});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualSlices(u8, big, r.stdout);
}

test "a stdout that is closed is a failure, whatever the applet said" {
    var c = tk.Case.init();
    defer c.deinit();
    const a = c.alloc();
    const exe = try tk.exe(a);
    var child = std.process.Child.init(&.{ exe, "echo", "lost" }, a);
    child.stdout_behavior = .Close;
    const term = try child.spawnAndWait();
    try t.expectEqual(std.process.Child.Term{ .Exited = 1 }, term);
}

test "printenv and env read the environment the process was started with" {
    var c = tk.Case.init();
    defer c.deinit();
    const a = c.alloc();
    const exe = try tk.exe(a);
    const env = [_]Var{ .{ "FOO", "bar" }, .{ "EMPTY", "" } };
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "printenv", "FOO" }, &env), 0, "bar\n");
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "printenv", "EMPTY" }, &env), 0, "\n");
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "printenv", "UNSET" }, &env), 1, "");
    const listed = try run(a, c.tmp.dir, &.{ exe, "env" }, &env);
    try t.expectEqual(@as(u8, 0), listed.code);
    try t.expect(std.mem.indexOf(u8, listed.stdout, "FOO=bar\n") != null);
    try t.expect(std.mem.indexOf(u8, listed.stdout, "EMPTY=\n") != null);
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, listed.stdout, "\n"));
}

test "env starts a real child with the environment it built, in the working directory, and gives its status back" {
    var c = tk.Case.init();
    defer c.deinit();
    const a = c.alloc();
    const exe = try tk.exe(a);
    const env = [_]Var{ .{ "KEEP", "kept" }, .{ "DROP", "dropped" } };
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "env", "-u", "DROP", "NEW=made", exe, "printenv", "KEEP", "NEW" }, &env), 0, "kept\nmade\n");
    // the unset name is gone from the child
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "env", "-u", "DROP", exe, "printenv", "DROP" }, &env), 1, "");
    // -i: only the assignments
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "env", "-i", "ONLY=1", exe, "env" }, &env), 0, "ONLY=1\n");
    // its status, both ways
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "env", exe, "true" }, &env), 0, "");
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "env", exe, "false" }, &env), 1, "");
    // its working directory is the one env was started in
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "env", exe, "mkdir", "-p", "made/here" }, &env), 0, "");
    try t.expect(c.exists("made/here"));
    // found by name in the PATH given on its command line (a link named for the applet)
    _ = try link(&c, exe, "printenv");
    const bin = try c.path(".");
    const path_var = try std.fmt.allocPrint(a, "PATH={s}", .{bin});
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "env", path_var, "printenv", "PATH" }, &env), 0, try std.fmt.allocPrint(a, "{s}\n", .{bin}));
}

test "env: a command that is not there is 127; one that is there and not executable is 126" {
    var c = tk.Case.init();
    defer c.deinit();
    const a = c.alloc();
    const exe = try tk.exe(a);
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "env", "/no/such/program" }, &.{}), 127, "");
    try expectRun(try run(a, c.tmp.dir, &.{ exe, "env", "-i", "no_such_program_anywhere" }, &.{}), 127, "");
    {
        var f = try c.tmp.dir.createFile("plain", .{ .mode = 0o644 });
        f.close();
    }
    const plain = try c.path("plain");
    const r = try run(a, c.tmp.dir, &.{ exe, "env", plain }, &.{});
    try t.expectEqual(@as(u8, 126), r.code);
    try t.expect(std.mem.indexOf(u8, r.stderr, "Permission denied") != null);
}

test "ln through a link: a symbolic link, a dangling one, and -f over an existing one" {
    var c = tk.Case.init();
    defer c.deinit();
    const a = c.alloc();
    const exe = try tk.exe(a);
    const ln = try link(&c, exe, "ln");
    try expectRun(try run(a, c.tmp.dir, &.{ ln, "-s", "dangling-target", "l1" }, &.{}), 0, "");
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("dangling-target", try c.tmp.dir.readLink("l1", &buf));
    try expectRun(try run(a, c.tmp.dir, &.{ ln, "-s", "other", "l1" }, &.{}), 1, "");
    try expectRun(try run(a, c.tmp.dir, &.{ ln, "-sf", "other", "l1" }, &.{}), 0, "");
    try t.expectEqualStrings("other", try c.tmp.dir.readLink("l1", &buf));
    try expectRun(try run(a, c.tmp.dir, &.{ ln, "-s", "x", "no-dir/l2" }, &.{}), 1, "");
}
