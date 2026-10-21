//! What `check` does when an allocation fails, and when a stream fails, and the program around `entry` (`run`, what `main` calls). Each command line
//! is replayed with the allocator failing at its first allocation, then its second, and so on to the last: the run must end (exit 1, `out of memory`)
//! and not succeed, and must not have written its output file. The streams: a closed stdout or stderr changes no status.

const std = @import("std");
const t = std.testing;
const kit = @import("checkkit.zig");
const check = @import("check.zig");

fn sweepTool(c: *kit.Case, before: kit.Args, program: kit.Args, outputs: []const []const u8) !void {
    try kit.sweep(c, try c.line(before, program), outputs);
}

test "run: every allocation of the option handling and the preparation, failed in turn" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.environ = &.{ "KEEP=1", "NOEQ", "REL=some/dir", "PFX_A=a", "BUCK_SCRATCH_PATH=scratch-root" };
    try c.tmp.dir.makePath("sub");
    const outs: []const []const u8 = &.{};
    try sweepTool(&c, &.{"run"}, &.{"true"}, outs);
    try sweepTool(&c, &.{"run"}, &.{"false"}, outs);
    try sweepTool(&c, &.{ "run", "--clear-env", "--env", "A=1", "--env", "B=2" }, &.{"true"}, outs);
    try sweepTool(&c, &.{ "run", "--scratch", "s", "--dir", "D=sub/x", "--dir", "R=.", "--tmpdir", "--cwd-env", "R" }, &.{"true"}, outs);
    try sweepTool(&c, &.{ "run", "--ld-library-path", "lib", "--abs", "REL", "--abs-prefix", "PFX_", "--mkdir-env", "REL", "--cwd", "sub" }, &.{"true"}, outs);
    try sweepTool(&c, &.{ "run", "--env", "BAD" }, &.{"true"}, outs);
    try sweepTool(&c, &.{ "run", "--dir", "BAD" }, &.{"true"}, outs);
    try sweepTool(&c, &.{ "run", "--bogus" }, &.{"true"}, outs);
    try kit.sweep(&c, &.{ "run", "--refuse", "message" }, outs);
    try kit.sweep(&c, &.{ "run", "--", "true" }, outs);
    try kit.sweep(&c, &.{"run"}, outs);
    try kit.sweep(&c, &.{ "run", "--", "/no/such/program" }, outs);
}

test "marker and expect: every allocation failed in turn, and no output file from a run that failed" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("good", "text\n");
    const o: []const []const u8 = &.{"o"};
    try sweepTool(&c, &.{ "marker", "--out", "o" }, &.{"true"}, o);
    try sweepTool(&c, &.{ "marker", "--out", "o" }, &.{"false"}, o);
    try sweepTool(&c, &.{ "marker", "--out", "o", "--stamp", "x" }, &.{"true"}, o);
    try sweepTool(&c, &.{ "marker", "--out", "o", "--capture", "--stamp-log" }, &.{ "cat", "good" }, o);
    try sweepTool(&c, &.{ "marker", "--out", "o", "--capture" }, &.{ "cat", "good", "missing" }, o);
    try kit.sweep(&c, &.{"marker"}, o);
    try kit.sweep(&c, &.{ "marker", "--out", "o", "--stamp-log" }, o);
    try sweepTool(&c, &.{ "expect", "--out", "o", "--want", "text" }, &.{ "cat", "good" }, o);
    try sweepTool(&c, &.{ "expect", "--out", "o", "--want", "te", "--prefix" }, &.{ "cat", "good" }, o);
    try sweepTool(&c, &.{ "expect", "--out", "o", "--want", "other", "--name", "label" }, &.{ "cat", "good" }, o);
    try sweepTool(&c, &.{ "expect", "--out", "o", "--want", "text" }, &.{ "cat", "good", "missing" }, o);
    try kit.sweep(&c, &.{"expect"}, o);
    try kit.sweep(&c, &.{ "expect", "--want", "x" }, o);
}

test "digest, same, copy: every allocation failed in turn" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("abc", "abc");
    try c.put("abd", "abd");
    try c.put("abc2", "abc");
    try c.put("longer", "abcd");
    const o: []const []const u8 = &.{"o"};
    const abc = "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    try kit.sweepNone(&c, &.{ "digest", "--out", "o", abc, "abc", "n" }, o);
    try kit.sweep(&c, &.{ "digest", abc, "abd", "n", "sha512:" ++ "00" ** 64, "abd", "m" }, o);
    try kit.sweep(&c, &.{ "digest", "md5:x", "abc", "n" }, o);
    try kit.sweep(&c, &.{ "digest", abc, "missing", "n" }, o);
    try kit.sweep(&c, &.{"digest"}, o);
    try kit.sweepNone(&c, &.{ "same", "--out", "o", "abc", "abc2" }, o);
    try kit.sweep(&c, &.{ "same", "--out", "o", "abc", "abd" }, o);
    try kit.sweep(&c, &.{ "same", "--out", "o", "abc", "longer" }, o);
    try kit.sweep(&c, &.{ "same", "--out", "o", "longer", "abc" }, o);
    try kit.sweep(&c, &.{ "same", "--out", "o", "abc", "missing" }, o);
    try kit.sweep(&c, &.{ "same", "--out", "o", "abc" }, o);
    try kit.sweepNone(&c, &.{ "copy", "abc", "o" }, o);
    try kit.sweep(&c, &.{ "copy", "missing", "o" }, o);
    try kit.sweep(&c, &.{"copy"}, o);
}

test "isa and the dispatch: every allocation failed in turn" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.tmp.dir.symLink(c.toolbox, "echo", .{});
    const o: []const []const u8 = &.{"r"};
    const with = "x\n  401000:\tvpaddd\t%ymm1, %ymm1, %ymm1\n  401004:\tmovaps\t%xmm0, %xmm1";
    const without = "x\n  401000:\tpushq\t%rbp";
    try kit.sweep(&c, &.{ "isa", "--objdump", "./echo", "--binary", with, "--expect", "avx2", "--label", "l", "--out", "r" }, o);
    try kit.sweep(&c, &.{ "isa", "--objdump", "./echo", "--binary", without, "--expect", "none", "--label", "l", "--out", "r" }, o);
    try kit.sweep(&c, &.{ "isa", "--objdump", "./echo", "--binary", with, "--expect", "none", "--label", "l", "--out", "r" }, o);
    try kit.sweep(&c, &.{ "isa", "--objdump", "./echo", "--binary", without, "--expect", "avx2", "--label", "l", "--out", "r" }, o);
    try kit.sweep(&c, &.{ "isa", "--objdump", "./echo", "--binary", with, "--expect", "sse", "--label", "l", "--out", "r" }, o);
    try kit.sweep(&c, &.{ "isa", "--objdump", "/no/such/objdump", "--binary", with, "--expect", "none", "--label", "l", "--out", "r" }, o);
    try kit.sweep(&c, &.{ "isa", "--objdump", c.toolbox, "--binary", with, "--expect", "none", "--label", "l", "--out", "r" }, o);
    try kit.sweep(&c, &.{"isa"}, o);
    try kit.sweep(&c, &.{ "isa", "--bogus", "x" }, o);
    try kit.sweepNone(&c, &.{}, o);
    try kit.sweepNone(&c, &.{"--help"}, o);
    try kit.sweep(&c, &.{"frobnicate"}, o);
}

test "a stream that fails changes no status: stdout and stderr closed, for each kind of message and replay" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("good", "text\n");
    const lines = [_]kit.Args{
        &.{ "run", "--refuse", "m" },
        &.{"frobnicate"},
        &.{},
        &.{"marker"},
        &.{ "same", "--out" },
        &.{ "copy", "missing", "x" },
        &.{ "digest", "md5:x", "good", "n" },
        &.{ "isa", "--bogus", "x" },
        &.{ "isa", "--objdump", "/no/objdump", "--binary", "b", "--expect", "sse", "--label", "l", "--out", "r" },
    };
    for (lines) |line| {
        const plain = try c.run(line);
        c.stdout_closed = true;
        c.stderr_closed = true;
        defer {
            c.stdout_closed = false;
            c.stderr_closed = false;
        }
        const closed = try c.run(line);
        try t.expectEqual(plain.status, closed.status);
    }
    // a failing test whose output is replayed to a closed stdout, an expect that passes on a program's stderr to a closed stderr, a message nobody can read
    c.stdout_closed = true;
    try t.expectEqual(@as(u8, 1), (try c.runTool(&.{ "marker", "--out", "o", "--capture" }, &.{ "cat", "missing" })).status);
    c.stdout_closed = false;
    c.stderr_closed = true;
    try t.expectEqual(@as(u8, 1), (try c.runTool(&.{ "expect", "--out", "o", "--want", "x" }, &.{ "cat", "missing" })).status);
    try t.expectEqual(@as(u8, 1), (try c.runTool(&.{ "expect", "--out", "o", "--want", "x" }, &.{ "echo", "y" })).status);
    try t.expectEqual(@as(u8, 127), (try c.run(&.{ "run", "--", "/no/such/program" })).status);
}

// ---- the program around entry -----------------------------------------------------------------------------------

fn viaFiles(c: *kit.Case, args: kit.Args, out_mode: std.fs.File.OpenMode) !struct { status: u8, out: []u8, err: []u8 } {
    try c.put("out", "");
    try c.put("err", "");
    var fout = try c.tmp.dir.openFile("out", .{ .mode = out_mode });
    defer fout.close();
    var ferr = try c.tmp.dir.openFile("err", .{ .mode = .read_write });
    defer ferr.close();
    const status = check.run(c.alloc(), args, c.environ, fout, ferr);
    return .{ .status = status, .out = try c.read("out"), .err = try c.read("err") };
}

test "run (main without the process): the arguments, the environment, stdout and stderr it is given" {
    var c = try kit.Case.init();
    defer c.deinit();
    const help = try viaFiles(&c, &.{"--help"}, .read_write);
    try t.expectEqual(@as(u8, 0), help.status);
    try t.expectEqualStrings("usage: check run|expect|marker|digest|same|copy|isa [ARGUMENT]...\n", help.out);
    const bad = try viaFiles(&c, &.{"nope"}, .read_write);
    try t.expectEqual(@as(u8, 2), bad.status);
    try t.expect(std.mem.startsWith(u8, bad.err, "check: unknown command nope\n"));
    // the environment it is given reaches the program, and the working directory is the process's own
    c.environ = &.{"FROM_MAIN=yes"};
    const out_path = try c.at("expected");
    const r = try viaFiles(&c, try c.line(&.{ "expect", "--want", "yes", "--out", out_path }, &.{ "printenv", "FROM_MAIN" }), .read_write);
    try t.expectEqual(@as(u8, 0), r.status);
    try t.expectEqualStrings("yes\n", try c.read("expected"));
}

test "run: a stdout that cannot be flushed makes a success a failure, and does not hide a failure" {
    var c = try kit.Case.init();
    defer c.deinit();
    try t.expectEqual(@as(u8, 1), (try viaFiles(&c, &.{"--help"}, .read_only)).status);
    try t.expectEqual(@as(u8, 2), (try viaFiles(&c, &.{"nope"}, .read_only)).status);
}

test "the scratch directory is named without a BUCK_SCRATCH_PATH, with allocations failing; a closed stderr does not change an out-of-memory exit" {
    var c = try kit.Case.init();
    defer c.deinit();
    const outs: []const []const u8 = &.{};
    try sweepTool(&c, &.{ "run", "--scratch", "s", "--dir", "D=sub" }, &.{"true"}, outs);
    c.stderr_closed = true;
    try sweepTool(&c, &.{ "run", "--scratch", "s", "--dir", "D=sub" }, &.{"true"}, outs);
    try kit.sweep(&c, &.{"frobnicate"}, outs);
}

test "more of the preparation under a failing allocator: TMPDIR default, a working directory from a variable, an empty one, a relative program" {
    var c = try kit.Case.init();
    defer c.deinit();
    const outs: []const []const u8 = &.{};
    try c.tmp.dir.makePath("sub");
    try c.tmp.dir.symLink(c.toolbox, "toolbox", .{});
    try kit.sweep(&c, &.{ "run", "--tmpdir", "--", c.toolbox, "true" }, outs);
    try kit.sweep(&c, &.{ "run", "--env", "W=sub", "--cwd-env", "W", "--", c.toolbox, "true" }, outs);
    try kit.sweep(&c, &.{ "run", "--cwd", "", "--", c.toolbox, "true" }, outs);
    try kit.sweep(&c, &.{ "run", "--", "./toolbox", "true" }, outs);
    try kit.sweep(&c, &.{ "run", "--cwd-env", "UNSET", "--", c.toolbox, "true" }, outs);
    for ([_][]const u8{ "run", "marker", "expect" }) |command| {
        try kit.expectFailure(try c.run(&.{ command, "--bogus" }), 2, "unknown option --bogus");
        try kit.sweep(&c, &.{ command, "--bogus" }, outs);
    }
}
