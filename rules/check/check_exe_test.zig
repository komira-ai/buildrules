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
