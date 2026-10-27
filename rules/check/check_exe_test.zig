//! The shipped check executable as a process, `zig test` of this file run as a build action by `:check_exe_test` (its path is in the environment as
//! CHECK, and the toolbox it starts as TOOLBOX: the `zig_test`'s `env_tools`). The cases in the other files call `entry` in-process; these run what
//! `main` adds around it: the command line from argv, the real environment and working directory, stdout flushed at the end, and the exit status.
//! Without CHECK or TOOLBOX every case fails: none passes without running the executable.

const std = @import("std");
const t = std.testing;
const kit = @import("checkkit.zig");

const Run = struct { code: u8, stdout: []const u8, stderr: []const u8 };

fn tool(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, name) catch {
        std.debug.print("the test target does not pass {s} (env_tools), so the executable cannot be run\n", .{name});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

/// Runs check with `args` in `dir`, with exactly `env` as its environment.
fn run(c: *kit.Case, args: kit.Args, env: []const [2][]const u8) !Run {
    const a = c.alloc();
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(a, try tool(a, "CHECK"));
    try argv.appendSlice(a, args);
    var map = std.process.EnvMap.init(a);
    for (env) |kv| try map.put(kv[0], kv[1]);
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv.items, .cwd_dir = c.tmp.dir, .env_map = &map, .max_output_bytes = 1 << 22 });
    const code: u8 = switch (r.term) {
        .Exited => |x| x,
        else => {
            std.debug.print("check did not exit: {any}\n", .{r.term});
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

test "the usage and the exit status of a refusal: --help on stdout (0), a missing or an unknown command on stderr (2)" {
    var c = try kit.Case.init();
    defer c.deinit();
    try expectRun(try run(&c, &.{"--help"}, &.{}), 0, "usage: check run|expect|marker|digest|same|copy|isa [ARGUMENT]...\n");
    const none = try run(&c, &.{}, &.{});
    try expectRun(none, 2, "");
    try t.expect(std.mem.startsWith(u8, none.stderr, "usage: check "));
    const bad = try run(&c, &.{"nope"}, &.{});
    try expectRun(bad, 2, "");
    try t.expect(std.mem.startsWith(u8, bad.stderr, "check: unknown command nope\n"));
}

test "run starts the program in the process's own environment and working directory and gives its status back" {
    var c = try kit.Case.init();
    defer c.deinit();
    const tb = c.toolbox;
    try expectRun(try run(&c, &.{ "run", "--", tb, "true" }, &.{}), 0, "");
    try expectRun(try run(&c, &.{ "run", "--", tb, "false" }, &.{}), 1, "");
    try expectRun(try run(&c, &.{ "run", "--", tb, "printenv", "FOO" }, &.{.{ "FOO", "from the process" }}), 0, "from the process\n");
    try expectRun(try run(&c, &.{ "run", "--clear-env", "--", tb, "printenv", "FOO" }, &.{.{ "FOO", "x" }}), 1, "");
    try expectRun(try run(&c, &.{ "run", "--env", "FOO=set", "--", tb, "printenv", "FOO" }, &.{}), 0, "set\n");
    // the working directory is the process's: a relative path made by the program is in it
    try expectRun(try run(&c, &.{ "run", "--", tb, "mkdir", "-p", "made/here" }, &.{}), 0, "");
    try t.expect(c.exists("made/here"));
    try expectRun(try run(&c, &.{ "run", "--", "/no/such/program" }, &.{}), 127, "");
    try expectRun(try run(&c, &.{ "run", "--refuse", "not provided" }, &.{}), 2, "");
}

test "the scratch directory is under BUCK_SCRATCH_PATH of the process's environment" {
    var c = try kit.Case.init();
    defer c.deinit();
    const abs = try c.at("scratch-root");
    const var_entry = try std.fmt.allocPrint(c.alloc(), "{s}", .{abs});
    const r = try run(&c, &.{ "run", "--scratch", "s", "--dir", "D=.", "--", c.toolbox, "printenv", "D" }, &.{.{ "BUCK_SCRATCH_PATH", var_entry }});
    try expectRun(r, 0, try std.fmt.allocPrint(c.alloc(), "{s}/s\n", .{abs}));
    try t.expect(!c.exists("scratch-root/s"));
}

test "two processes with --private-scratch have a TMPDIR, a TEST_TMPDIR and a HOME each of their own, in the process's BUCK_SCRATCH_PATH, and the installed layout runs" {
    var c = try kit.Case.init();
    defer c.deinit();
    const env: []const [2][]const u8 = &.{.{ "BUCK_SCRATCH_PATH", try c.at("scratch-root") }};
    const tb = c.toolbox;
    const first = try run(&c, &.{ "run", "--private-scratch", "--", tb, "printenv", "TMPDIR", "TEST_TMPDIR", "HOME" }, env);
    const second = try run(&c, &.{ "run", "--private-scratch", "--", tb, "printenv", "TMPDIR", "TEST_TMPDIR", "HOME" }, env);
    try t.expectEqual(@as(u8, 0), first.code);
    try t.expectEqual(@as(u8, 0), second.code);
    try t.expect(!std.mem.eql(u8, first.stdout, second.stdout));
    var lines = std.mem.splitScalar(u8, first.stdout, '\n');
    const tmp = lines.next().?;
    try t.expectEqualStrings(tmp, lines.next().?);
    try t.expect(std.mem.startsWith(u8, tmp, try c.at("scratch-root/buildrules_test.")));
    try t.expect(std.mem.startsWith(u8, lines.next().?, try c.at("scratch-root/buildrules_test.")));
    // nothing is left in the scratch path
    var d = try c.tmp.dir.openDir("scratch-root", .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    try t.expect((try it.next()) == null);
    // the installed layout: the program is a copy at root/bin, the data is in root/share, the working directory is the root
    try c.put("data/f.txt", "staged\n");
    const r = try run(&c, &.{ "run", "--private-scratch", "--installed", "--install-share", "data", "--", tb, "cat", "share/f.txt" }, env);
    try expectRun(r, 0, "staged\n");
}

test "expect and marker write their file only on success, and say so by their status" {
    var c = try kit.Case.init();
    defer c.deinit();
    const tb = c.toolbox;
    try expectRun(try run(&c, &.{ "expect", "--want", "hi", "--out", "e", "--", tb, "echo", "hi" }, &.{}), 0, "");
    try t.expectEqualStrings("hi\n", try c.read("e"));
    const bad = try run(&c, &.{ "expect", "--want", "ho", "--out", "e2", "--", tb, "echo", "hi" }, &.{});
    try expectRun(bad, 1, "");
    try t.expect(std.mem.indexOf(u8, bad.stderr, "expected output equal to 'ho'") != null);
    try t.expect(!c.exists("e2"));
    try expectRun(try run(&c, &.{ "marker", "--out", "m", "--", tb, "true" }, &.{}), 0, "");
    try t.expectEqualStrings("passed\n", try c.read("m"));
    try expectRun(try run(&c, &.{ "marker", "--out", "m2", "--capture", "--", tb, "cat", "missing" }, &.{}), 1, "cat: missing: No such file or directory\n");
    try t.expect(!c.exists("m2"));
}

test "digest, same and copy work on the process's working directory" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("abc", "abc");
    try expectRun(try run(&c, &.{ "digest", "--out", "d", "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "abc", "n" }, &.{}), 0, "");
    try t.expectEqualStrings("ok\n", try c.read("d"));
    try expectRun(try run(&c, &.{ "copy", "abc", "abc2" }, &.{}), 0, "");
    try expectRun(try run(&c, &.{ "same", "--out", "s", "abc", "abc2" }, &.{}), 0, "");
    try t.expectEqualStrings("same\n", try c.read("s"));
    try c.put("abd", "abd");
    try expectRun(try run(&c, &.{ "same", "--out", "s2", "abc", "abd" }, &.{}), 1, "");
    try t.expect(!c.exists("s2"));
}

test "isa runs the disassembler by its path and reports from what it prints" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.tmp.dir.symLink(c.toolbox, "echo", .{});
    const text = "x\n  401000:\tvpaddd\t%ymm1, %ymm1, %ymm1";
    try expectRun(try run(&c, &.{ "isa", "--objdump", "./echo", "--binary", text, "--expect", "avx2", "--label", "l", "--out", "r" }, &.{}), 0, "");
    try t.expect(std.mem.indexOf(u8, try c.read("r"), "instructions naming ymm (AVX2 width): 1\n") != null);
    const none = try run(&c, &.{ "isa", "--objdump", "./echo", "--binary", text, "--expect", "none", "--label", "l", "--out", "r2" }, &.{});
    try expectRun(none, 1, "");
    try t.expect(std.mem.indexOf(u8, none.stderr, "would die with SIGILL") != null);
    try t.expect(!c.exists("r2"));
}

// The hang limit as the shipped process does it, on the real clock: a program that cannot finish (it sleeps a day) is stopped at a limit of one second. The case
// asserts the verdict only (the status, the two lines, no file), never how long it took; hang_test.zig holds the same verdict in-process with the clock replaced,
// and that the whole group is killed.
test "marker --hang-limit-s stops a program that cannot finish: status 125, no file, TEST FAILED and the hang line" {
    var c = try kit.Case.init();
    defer c.deinit();
    const tb = c.toolbox;
    const r = try run(&c, &.{ "marker", "--out", "h", "--hang-limit-s", "1", "--hang-label", "//pkg:t", "--", tb, "sleep", "1d" }, &.{});
    try expectRun(r, 125, "");
    const want = try std.fmt.allocPrint(c.alloc(), "check marker: TEST FAILED: {s}\nhang limit: //pkg:t did not finish within 1 s and was stopped; a test never waits on time, so this means it hung (an event that never came)\n", .{tb});
    try t.expectEqualStrings(want, r.stderr);
    try t.expect(!c.exists("h"));
    // and one that finishes passes as before
    try expectRun(try run(&c, &.{ "marker", "--out", "m", "--hang-limit-s", "1800", "--hang-label", "//pkg:t", "--", tb, "true" }, &.{}), 0, "");
    try t.expectEqualStrings("passed\n", try c.read("m"));
}
