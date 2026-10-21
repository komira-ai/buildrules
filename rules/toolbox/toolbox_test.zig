//! The cases of the toolbox's applets, run in-process as main runs them (`entry`): the arguments, a directory of its own, the streams as
//! buffers, a clock that only records and a spawner that only records. Each case reads back the exit status and the exact bytes of stdout
//! and stderr. The process itself (a link named for the applet, the real clock, stdin, the real environment) is toolbox_exe_test.zig.

const std = @import("std");
const t = std.testing;
const tk = @import("testkit.zig");
const io_mod = @import("io.zig");
const text = @import("text.zig");

const Args = []const []const u8;

fn expectRun(c: *tk.Case, args: Args, status: u8, out: []const u8, err: []const u8) !void {
    const r = try c.run(args);
    if (r.status != status or !std.mem.eql(u8, r.out, out) or !std.mem.eql(u8, r.err, err)) {
        std.debug.print("{s}: status {d} (want {d}), stdout '{s}' (want '{s}'), stderr '{s}' (want '{s}')\n", .{ args[0], r.status, status, r.out, out, r.err, err });
        return error.TestUnexpectedResult;
    }
}

// ---- dispatch ---------------------------------------------------------------------------------------------------

test "dispatch: by the last component of the program's name, and by the first argument of `toolbox`" {
    var c = tk.Case.init();
    defer c.deinit();
    try expectRun(&c, &.{ "echo", "a" }, 0, "a\n", "");
    try expectRun(&c, &.{ "/some/dir/echo", "a", "b" }, 0, "a b\n", "");
    try expectRun(&c, &.{ "toolbox", "echo", "a" }, 0, "a\n", "");
    try expectRun(&c, &.{ "/x/toolbox", "true" }, 0, "", "");
    try expectRun(&c, &.{ "toolbox", "false" }, 1, "", "");
}

test "dispatch: an unknown applet is not found (127), by either route; no applet at all is usage (1)" {
    var c = tk.Case.init();
    defer c.deinit();
    try expectRun(&c, &.{"nosuch"}, 127, "", "toolbox: applet not found: nosuch\n");
    try expectRun(&c, &.{ "toolbox", "nosuch", "x" }, 127, "", "toolbox: applet not found: nosuch\n");
    try expectRun(&c, &.{"toolbox"}, 1, "", "toolbox: usage: toolbox APPLET [ARG]... (or run through a link named for the applet); --list names them\n");
    const none: Args = &.{};
    const r = try c.run(none);
    try t.expectEqual(@as(u8, 1), r.status);
}

test "dispatch: --list names the nine applets, in order, one a line; a closed stdout is a failure" {
    var c = tk.Case.init();
    defer c.deinit();
    try expectRun(&c, &.{ "toolbox", "--list" }, 0, "rm\nmkdir\nsleep\necho\ncat\nenv\nprintenv\ntrue\nfalse\n", "");
    c.stdout_closed = true;
    try expectRun(&c, &.{ "toolbox", "--list" }, 1, "", "");
}

test "true and false ignore their arguments" {
    var c = tk.Case.init();
    defer c.deinit();
    try expectRun(&c, &.{ "true", "--bogus", "x" }, 0, "", "");
    try expectRun(&c, &.{ "false", "--bogus", "x" }, 1, "", "");
}

// ---- echo -------------------------------------------------------------------------------------------------------

test "echo: the arguments joined by one space and a newline; no argument is an empty line" {
    var c = tk.Case.init();
    defer c.deinit();
    try expectRun(&c, &.{ "echo", "hello", "big", "world" }, 0, "hello big world\n", "");
    try expectRun(&c, &.{"echo"}, 0, "\n", "");
    try expectRun(&c, &.{ "echo", "" }, 0, "\n", "");
    try expectRun(&c, &.{ "echo", "", "" }, 0, " \n", "");
    try expectRun(&c, &.{ "echo", "a  b" }, 0, "a  b\n", "");
}

test "echo -n writes no newline; -e and -E choose whether escapes are replaced; flags combine; the last of -e and -E wins" {
    var c = tk.Case.init();
    defer c.deinit();
    try expectRun(&c, &.{ "echo", "-n", "a" }, 0, "a", "");
    try expectRun(&c, &.{ "echo", "-n" }, 0, "", "");
    try expectRun(&c, &.{ "echo", "a\\nb" }, 0, "a\\nb\n", "");
    try expectRun(&c, &.{ "echo", "-e", "a\\nb" }, 0, "a\nb\n", "");
    try expectRun(&c, &.{ "echo", "-E", "a\\nb" }, 0, "a\\nb\n", "");
    try expectRun(&c, &.{ "echo", "-ne", "a\\tb" }, 0, "a\tb", "");
    try expectRun(&c, &.{ "echo", "-n", "-e", "x\\ty" }, 0, "x\ty", "");
    try expectRun(&c, &.{ "echo", "-eE", "a\\nb" }, 0, "a\\nb\n", "");
    try expectRun(&c, &.{ "echo", "-Ee", "a\\nb" }, 0, "a\nb\n", "");
}

test "echo: what is not made of -n, -e, -E is text, and so is any flag after the first word" {
    var c = tk.Case.init();
    defer c.deinit();
    try expectRun(&c, &.{ "echo", "--plan" }, 0, "--plan\n", "");
    try expectRun(&c, &.{ "echo", "-x" }, 0, "-x\n", "");
    try expectRun(&c, &.{ "echo", "-nx" }, 0, "-nx\n", "");
    try expectRun(&c, &.{ "echo", "-" }, 0, "-\n", "");
    try expectRun(&c, &.{ "echo", "--" }, 0, "--\n", "");
    try expectRun(&c, &.{ "echo", "a", "-n" }, 0, "a -n\n", "");
}

test "echo -e: every escape, one by one" {
    var c = tk.Case.init();
    defer c.deinit();
    const cases = [_][2][]const u8{
        .{ "\\\\", "\\" },
        .{ "\\a", "\x07" },
        .{ "\\b", "\x08" },
        .{ "\\e", "\x1b" },
        .{ "\\f", "\x0c" },
        .{ "\\n", "\n" },
        .{ "\\r", "\r" },
        .{ "\\t", "\t" },
        .{ "\\v", "\x0b" },
        .{ "\\0101", "A" },
        .{ "\\0", "\x00" },
        .{ "\\07", "\x07" },
        .{ "\\01234", "S4" },
        .{ "\\0189", "\x018" ++ "9" },
        .{ "\\x41", "A" },
        .{ "\\x4a", "J" },
        .{ "\\x4Az", "Jz" },
        .{ "\\x414", "A4" },
        .{ "\\x", "\\x" },
        .{ "\\xg", "\\xg" },
        .{ "\\q", "\\q" },
        .{ "a\\", "a\\" },
        .{ "\\", "\\" },
        .{ "x\\ty\\nz", "x\ty\nz" },
    };
    for (cases) |case| {
        const r = try c.run(&.{ "echo", "-e", case[0] });
        const want = try std.fmt.allocPrint(c.alloc(), "{s}\n", .{case[1]});
        if (r.status != 0 or !std.mem.eql(u8, r.out, want)) {
            std.debug.print("echo -e '{s}': got '{s}', want '{s}'\n", .{ case[0], r.out, want });
            return error.TestUnexpectedResult;
        }
    }
}

test "echo -e: \\c ends all output, the newline and the later arguments too; a closed stdout is a failure" {
    var c = tk.Case.init();
    defer c.deinit();
    try expectRun(&c, &.{ "echo", "-e", "a\\cb", "c" }, 0, "a", "");
    try expectRun(&c, &.{ "echo", "-e", "x", "y\\c", "z" }, 0, "x y", "");
    c.stdout_closed = true;
    try expectRun(&c, &.{ "echo", "a" }, 1, "", "");
}

// ---- cat --------------------------------------------------------------------------------------------------------

test "cat: files in order, each whole; an empty file adds nothing" {
    var c = tk.Case.init();
    defer c.deinit();
    try c.put("a", "alpha\n");
    try c.put("b", "beta");
    try c.put("empty", "");
    try expectRun(&c, &.{ "cat", "a", "empty", "b", "a" }, 0, "alpha\nbetaalpha\n", "");
}

test "cat: a file longer than its read buffer comes out whole" {
    var c = tk.Case.init();
    defer c.deinit();
    const big = try c.alloc().alloc(u8, 40000);
    for (big, 0..) |*b, i| b.* = @intCast('a' + i % 26);
    try c.put("big", big);
    const r = try c.run(&.{ "cat", "big" });
    try t.expectEqual(@as(u8, 0), r.status);
    try t.expectEqualSlices(u8, big, r.out);
}

test "cat: no operand, and `-`, read stdin; they mix with files" {
    var c = tk.Case.init();
    defer c.deinit();
    c.stdin = "from stdin\n";
    try c.put("f", "file\n");
    try expectRun(&c, &.{"cat"}, 0, "from stdin\n", "");
    try expectRun(&c, &.{ "cat", "f", "-", "f" }, 0, "file\nfrom stdin\nfile\n", "");
}

test "cat: a missing file or a directory is said and is status 1, and the other files are still written" {
    var c = tk.Case.init();
    defer c.deinit();
    try c.put("f", "ok\n");
    try c.tmp.dir.makeDir("d");
    try expectRun(&c, &.{ "cat", "nope", "f" }, 1, "ok\n", "cat: nope: No such file or directory\n");
    try expectRun(&c, &.{ "cat", "d", "f" }, 1, "ok\n", "cat: d: Is a directory\n");
    try expectRun(&c, &.{ "cat", "f/x" }, 1, "", "cat: f/x: Not a directory\n");
}

test "cat: a stdout that cannot be written is status 1 and stops, for a file and for stdin" {
    var c = tk.Case.init();
    defer c.deinit();
    try c.put("f", "ok\n");
    c.stdin = "in\n";
    c.stdout_closed = true;
    try expectRun(&c, &.{ "cat", "f", "f" }, 1, "", "");
    try expectRun(&c, &.{"cat"}, 1, "", "");
    try expectRun(&c, &.{ "cat", "-", "f" }, 1, "", "");
}

// ---- sleep ------------------------------------------------------------------------------------------------------

test "parseInterval: whole and fractional seconds, the four units, and nothing else" {
    const s = std.time.ns_per_s;
    const ok = [_]struct { []const u8, u64 }{
        .{ "0", 0 },
        .{ "30", 30 * s },
        .{ "0.3", 300_000_000 },
        .{ ".5", 500_000_000 },
        .{ "2.", 2 * s },
        .{ "1.25", 1_250_000_000 },
        .{ "0.000000001", 1 },
        .{ "0.0000000019", 1 },
        .{ "0.0000000009", 0 },
        .{ "10s", 10 * s },
        .{ "2m", 120 * s },
        .{ "1.5m", 90 * s },
        .{ "1h", 3600 * s },
        .{ "1d", 86400 * s },
        .{ "007", 7 * s },
        .{ "99999999999999999999", std.math.maxInt(u64) },
        .{ "99999999999d", std.math.maxInt(u64) },
    };
    for (ok) |case| {
        const got = text.parseInterval(case[0]);
        if (got == null or got.? != case[1]) {
            std.debug.print("parseInterval '{s}': got {any}, want {d}\n", .{ case[0], got, case[1] });
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "", "s", ".", ".s", "abc", "-1", "+1", "1.2.3", "1e3", "1x", "1 ", " 1", "1ss", "0x10" }) |bad| {
        if (text.parseInterval(bad) != null) {
            std.debug.print("parseInterval '{s}' should be refused\n", .{bad});
            return error.TestUnexpectedResult;
        }
    }
}

test "sleep: waits for the sum of its operands, fractions included" {
    var c = tk.Case.init();
    defer c.deinit();
    try expectRun(&c, &.{ "sleep", "0.3" }, 0, "", "");
    try t.expectEqual(@as(u64, 300_000_000), tk.slept);
    try t.expectEqual(@as(u32, 1), tk.sleeps);
    try expectRun(&c, &.{ "sleep", "30" }, 0, "", "");
    try t.expectEqual(@as(u64, 30_000_000_000), tk.slept);
    try expectRun(&c, &.{ "sleep", "1", "0.5", "1m" }, 0, "", "");
    try t.expectEqual(@as(u64, 61_500_000_000), tk.slept);
    try expectRun(&c, &.{ "sleep", "99999999999999999999", "5" }, 0, "", "");
    try t.expectEqual(@as(u64, std.math.maxInt(u64)), tk.slept);
}

test "sleep: no operand or a bad one is status 1 and waits for nothing, even if an earlier operand was good" {
    var c = tk.Case.init();
    defer c.deinit();
    try expectRun(&c, &.{"sleep"}, 1, "", "sleep: missing operand\n");
    try t.expectEqual(@as(u32, 0), tk.sleeps);
    try expectRun(&c, &.{ "sleep", "abc" }, 1, "", "sleep: invalid time interval 'abc'\n");
    try expectRun(&c, &.{ "sleep", "5", "-1" }, 1, "", "sleep: invalid time interval '-1'\n");
    try t.expectEqual(@as(u32, 0), tk.sleeps);
}

// ---- rm ---------------------------------------------------------------------------------------------------------

test "rm: removes files; the paths are relative to the working directory" {
    var c = tk.Case.init();
    defer c.deinit();
    try c.put("a", "1");
    try c.put("b", "2");
    try expectRun(&c, &.{ "rm", "a", "b" }, 0, "", "");
    try t.expect(!c.exists("a") and !c.exists("b"));
}

test "rm: a missing path is an error and the others are still removed; -f makes it silent" {
    var c = tk.Case.init();
    defer c.deinit();
    try c.put("a", "1");
    try c.put("b", "2");
    try expectRun(&c, &.{ "rm", "a", "nope", "b" }, 1, "", "rm: cannot remove 'nope': No such file or directory\n");
    try t.expect(!c.exists("a") and !c.exists("b"));
    try expectRun(&c, &.{ "rm", "-f", "nope" }, 0, "", "");
    try expectRun(&c, &.{ "rm", "-f" }, 0, "", "");
}

test "rm -rf: a tree, a missing path (not an error), a trailing slash, several operands" {
    var c = tk.Case.init();
    defer c.deinit();
    try c.tmp.dir.makePath("t/x/y");
    try c.put("t/x/y/f", "deep");
    try c.put("t/g", "g");
    try c.tmp.dir.makePath("u");
    try expectRun(&c, &.{ "rm", "-rf", "t", "missing", "u/" }, 0, "", "");
    try t.expect(!c.exists("t") and !c.exists("u"));
    try expectRun(&c, &.{ "rm", "-rf", "missing" }, 0, "", "");
    try expectRun(&c, &.{ "rm", "-fr", "missing" }, 0, "", "");
    try expectRun(&c, &.{ "rm", "-r", "-f", "missing" }, 0, "", "");
}

test "rm -r of a missing path without -f is an error; -R is -r" {
    var c = tk.Case.init();
    defer c.deinit();
    try expectRun(&c, &.{ "rm", "-r", "missing" }, 1, "", "rm: cannot remove 'missing': No such file or directory\n");
    try c.tmp.dir.makePath("d/e");
    try expectRun(&c, &.{ "rm", "-R", "d" }, 0, "", "");
    try t.expect(!c.exists("d"));
}

test "rm: a directory without -r is an error and stays, with what is in it" {
    var c = tk.Case.init();
    defer c.deinit();
    try c.tmp.dir.makePath("d");
    try c.put("d/f", "x");
    try expectRun(&c, &.{ "rm", "d" }, 1, "", "rm: cannot remove 'd': Is a directory\n");
    try t.expect(c.exists("d/f"));
}

test "rm: a link is removed and not what it names; a dangling link is removed, with -f and with -r" {
    var c = tk.Case.init();
    defer c.deinit();
    try c.tmp.dir.makePath("target");
    try c.put("target/keep", "k");
    try c.tmp.dir.symLink("target", "link", .{ .is_directory = true });
    try expectRun(&c, &.{ "rm", "-rf", "link" }, 0, "", "");
    try t.expect(!c.exists("link"));
    try t.expect(c.exists("target/keep"));
    try c.tmp.dir.symLink("nowhere", "dangling", .{});
    try expectRun(&c, &.{ "rm", "dangling" }, 0, "", "");
    try c.tmp.dir.symLink("nowhere", "dangling2", .{});
    try expectRun(&c, &.{ "rm", "-r", "dangling2" }, 0, "", "");
    try c.tmp.dir.symLink("nowhere", "dangling3", .{});
    try expectRun(&c, &.{ "rm", "-f", "dangling3" }, 0, "", "");
    try t.expect(!c.exists("dangling3"));
}

test "rm: `--` ends the options; an unknown option and no operand are refused" {
    var c = tk.Case.init();
    defer c.deinit();
    try c.put("-r", "odd name");
    try expectRun(&c, &.{ "rm", "--", "-r" }, 0, "", "");
    try t.expect(!c.exists("-r"));
    try c.put("-", "dash");
    try expectRun(&c, &.{ "rm", "-" }, 0, "", "");
    try expectRun(&c, &.{ "rm", "-x", "a" }, 1, "", "rm: invalid option -- 'x'\n");
    try expectRun(&c, &.{ "rm", "-rx", "a" }, 1, "", "rm: invalid option -- 'x'\n");
    try expectRun(&c, &.{"rm"}, 1, "", "rm: missing operand\n");
    try expectRun(&c, &.{ "rm", "-r" }, 1, "", "rm: missing operand\n");
}

test "rm: `.`, `..`, the root and an empty name are refused whatever the options, and nothing is removed" {
    var c = tk.Case.init();
    defer c.deinit();
    try c.put("keep", "k");
    for ([_][]const u8{ ".", "..", "./", "a/..", "a/.", "/", "//", "" }) |p| {
        const r = try c.run(&.{ "rm", "-rf", p });
        if (r.status != 1 or !std.mem.startsWith(u8, r.err, "rm: refusing to remove '")) {
            std.debug.print("rm -rf '{s}': status {d}, stderr '{s}'\n", .{ p, r.status, r.err });
            return error.TestUnexpectedResult;
        }
    }
    const r = try c.run(&.{ "rm", "-f", "..", "keep" });
    try t.expectEqual(@as(u8, 1), r.status);
    try t.expect(!c.exists("keep"));
}

// ---- mkdir ------------------------------------------------------------------------------------------------------

test "mkdir -p: a chain, one that is there already (not an error), slashes doubled and trailing" {
    var c = tk.Case.init();
    defer c.deinit();
    try expectRun(&c, &.{ "mkdir", "-p", "a/b/c" }, 0, "", "");
    try t.expect(c.exists("a/b/c"));
    try expectRun(&c, &.{ "mkdir", "-p", "a/b/c" }, 0, "", "");
    try expectRun(&c, &.{ "mkdir", "-p", "a" }, 0, "", "");
    try expectRun(&c, &.{ "mkdir", "-p", "x//y/", "z" }, 0, "", "");
    try t.expect(c.exists("x/y") and c.exists("z"));
}

test "mkdir: without -p the parent must be there and the directory must not" {
    var c = tk.Case.init();
    defer c.deinit();
    try expectRun(&c, &.{ "mkdir", "d" }, 0, "", "");
    try expectRun(&c, &.{ "mkdir", "d" }, 1, "", "mkdir: cannot create directory 'd': File exists\n");
    try expectRun(&c, &.{ "mkdir", "p/q" }, 1, "", "mkdir: cannot create directory 'p/q': No such file or directory\n");
    try t.expect(!c.exists("p"));
}

test "mkdir -p over a file is an error; the other operands are still made" {
    var c = tk.Case.init();
    defer c.deinit();
    try c.put("f", "x");
    try expectRun(&c, &.{ "mkdir", "-p", "f", "ok1", "f/sub", "ok2" }, 1, "", "mkdir: cannot create directory 'f': Not a directory\nmkdir: cannot create directory 'f/sub': Not a directory\n");
    try t.expect(c.exists("ok1") and c.exists("ok2"));
}

test "mkdir: `--` ends the options; an unknown option, no operand and an empty name are refused" {
    var c = tk.Case.init();
    defer c.deinit();
    try expectRun(&c, &.{ "mkdir", "-p", "--", "-odd" }, 0, "", "");
    try t.expect(c.exists("-odd"));
    try expectRun(&c, &.{ "mkdir", "-m", "755", "d" }, 1, "", "mkdir: invalid option '-m'\n");
    try expectRun(&c, &.{"mkdir"}, 1, "", "mkdir: missing operand\n");
    try expectRun(&c, &.{ "mkdir", "-p" }, 1, "", "mkdir: missing operand\n");
    try expectRun(&c, &.{ "mkdir", "-p", "" }, 1, "", "mkdir: cannot create directory '': No such file or directory\n");
}

// ---- printenv ---------------------------------------------------------------------------------------------------

test "printenv: the value of each name, a line each; a name that is not set is status 1 and the rest are still written" {
    var c = tk.Case.init();
    defer c.deinit();
    c.environ = &.{ "A=1", "AB=2", "EMPTY=", "PATH=/x:/y", "A=again" };
    try expectRun(&c, &.{ "printenv", "A" }, 0, "1\n", "");
    try expectRun(&c, &.{ "printenv", "AB", "A" }, 0, "2\n1\n", "");
    try expectRun(&c, &.{ "printenv", "EMPTY" }, 0, "\n", "");
    try expectRun(&c, &.{ "printenv", "NOPE", "A" }, 1, "1\n", "");
    try expectRun(&c, &.{ "printenv", "AC" }, 1, "", "");
    try expectRun(&c, &.{ "printenv", "A=1" }, 1, "", "");
    try expectRun(&c, &.{ "printenv", "" }, 1, "", "");
}

test "printenv: with no name, the whole environment in the order it came" {
    var c = tk.Case.init();
    defer c.deinit();
    c.environ = &.{ "B=2", "A=1" };
    try expectRun(&c, &.{"printenv"}, 0, "B=2\nA=1\n", "");
    c.environ = &.{};
    try expectRun(&c, &.{"printenv"}, 0, "", "");
    c.stdout_closed = true;
    c.environ = &.{"A=1"};
    try expectRun(&c, &.{"printenv"}, 1, "", "");
    try expectRun(&c, &.{ "printenv", "NOPE" }, 1, "", "");
    try expectRun(&c, &.{ "printenv", "A" }, 1, "", "");
}

// ---- env --------------------------------------------------------------------------------------------------------

test "env: with no command it writes the environment; -i empties it; -u removes a name; an assignment sets or replaces one" {
    var c = tk.Case.init();
    defer c.deinit();
    c.environ = &.{ "A=1", "B=2", "C=3" };
    try expectRun(&c, &.{"env"}, 0, "A=1\nB=2\nC=3\n", "");
    try expectRun(&c, &.{ "env", "-i" }, 0, "", "");
    try expectRun(&c, &.{ "env", "-i", "X=9" }, 0, "X=9\n", "");
    try expectRun(&c, &.{ "env", "-u", "B" }, 0, "A=1\nC=3\n", "");
    try expectRun(&c, &.{ "env", "-u", "B", "-u", "A" }, 0, "C=3\n", "");
    try expectRun(&c, &.{ "env", "B=new" }, 0, "A=1\nC=3\nB=new\n", "");
    try expectRun(&c, &.{ "env", "-u", "A", "A=2" }, 0, "B=2\nC=3\nA=2\n", "");
    try expectRun(&c, &.{ "env", "N=x=y", "E=" }, 0, "A=1\nB=2\nC=3\nN=x=y\nE=\n", "");
    try expectRun(&c, &.{ "env", "-u", "NOPE" }, 0, "A=1\nB=2\nC=3\n", "");
    try expectRun(&c, &.{ "env", "-i", "-u", "A" }, 0, "", "");
    c.stdout_closed = true;
    try expectRun(&c, &.{"env"}, 1, "", "");
}

test "env: an unknown option and -u without a name are refused (125)" {
    var c = tk.Case.init();
    defer c.deinit();
    try expectRun(&c, &.{ "env", "-x" }, 125, "", "env: invalid option '-x'\n");
    try expectRun(&c, &.{ "env", "-u" }, 125, "", "env: invalid option '-u'\n");
    try expectRun(&c, &.{ "env", "-i", "-" }, 127, "", "env: can't execute '-': No such file or directory\n");
}

test "env: runs the command with the built environment and its exit status; a program with a `/` is run as it is" {
    var c = tk.Case.init();
    defer c.deinit();
    c.environ = &.{ "A=1", "B=2" };
    tk.spawn_answer = 7;
    defer tk.spawn_answer = 0;
    try expectRun(&c, &.{ "env", "C=3", "-", "x" }, 127, "", "env: can't execute '-': No such file or directory\n");
    try expectRun(&c, &.{ "env", "-u", "A", "C=3", "/bin/prog", "arg one", "-n" }, 7, "", "");
    try t.expectEqual(@as(u32, 1), tk.ran_count);
    try t.expectEqual(@as(usize, 3), tk.ran_argv.len);
    try t.expectEqualStrings("/bin/prog", tk.ran_argv[0]);
    try t.expectEqualStrings("arg one", tk.ran_argv[1]);
    try t.expectEqualStrings("-n", tk.ran_argv[2]);
    try t.expectEqual(@as(usize, 2), tk.ran_env.len);
    try t.expectEqualStrings("B=2", tk.ran_env[0]);
    try t.expectEqualStrings("C=3", tk.ran_env[1]);
    try t.expectEqualStrings(try c.path("."), tk.ran_cwd);
}

test "env -i: the command gets nothing but the assignments" {
    var c = tk.Case.init();
    defer c.deinit();
    c.environ = &.{ "A=1", "B=2" };
    try expectRun(&c, &.{ "env", "-i", "/bin/prog" }, 0, "", "");
    try t.expectEqual(@as(usize, 0), tk.ran_env.len);
    try expectRun(&c, &.{ "env", "-i", "K=v", "/bin/prog" }, 0, "", "");
    try t.expectEqual(@as(usize, 1), tk.ran_env.len);
    try t.expectEqualStrings("K=v", tk.ran_env[0]);
}

test "env: a command with no `/` is looked for in the PATH of the environment it builds, an executable file only" {
    var c = tk.Case.init();
    defer c.deinit();
    try c.tmp.dir.makePath("bin1");
    try c.tmp.dir.makePath("bin2");
    {
        var f = try c.tmp.dir.createFile("bin2/tool", .{ .mode = 0o755 });
        f.close();
        var g = try c.tmp.dir.createFile("bin1/tool", .{ .mode = 0o644 });
        g.close();
    }
    const bin1 = try c.path("bin1");
    const bin2 = try c.path("bin2");
    const path_entry = try std.fmt.allocPrint(c.alloc(), "PATH={s}:{s}", .{ bin1, bin2 });
    // the first directory holds a file that is not executable: the second is the one found
    c.environ = &.{path_entry};
    try expectRun(&c, &.{ "env", "tool", "x" }, 0, "", "");
    try t.expectEqualStrings(try std.fmt.allocPrint(c.alloc(), "{s}/tool", .{bin2}), tk.ran_argv[0]);
    try t.expectEqualStrings("x", tk.ran_argv[1]);
    // an assignment on the command line is the PATH that counts
    c.environ = &.{"PATH=/nonexistent"};
    const only2 = try std.fmt.allocPrint(c.alloc(), "PATH={s}", .{bin2});
    try expectRun(&c, &.{ "env", only2, "tool" }, 0, "", "");
    try t.expectEqualStrings(try std.fmt.allocPrint(c.alloc(), "{s}/tool", .{bin2}), tk.ran_argv[0]);
    // not found anywhere, with an empty element (the current directory) in the way
    c.environ = &.{"PATH=:/nonexistent"};
    try expectRun(&c, &.{ "env", "toolbox_surely_absent" }, 127, "", "env: can't execute 'toolbox_surely_absent': No such file or directory\n");
    // no PATH at all: the default list is searched, and a name in none of it is not found
    c.environ = &.{};
    try expectRun(&c, &.{ "env", "toolbox_surely_absent" }, 127, "", "env: can't execute 'toolbox_surely_absent': No such file or directory\n");
}

test "env: a program that cannot be started is 127 when it is not there and 126 otherwise, with the reason" {
    var c = tk.Case.init();
    defer c.deinit();
    tk.spawn_answer = error.FileNotFound;
    defer tk.spawn_answer = 0;
    try expectRun(&c, &.{ "env", "/x/y" }, 127, "", "env: can't execute '/x/y': No such file or directory\n");
    tk.spawn_answer = error.AccessDenied;
    try expectRun(&c, &.{ "env", "/x/y" }, 126, "", "env: can't execute '/x/y': Permission denied\n");
}

// ---- the shared helpers -----------------------------------------------------------------------------------------

test "describe: the words for the errors the applets meet, the error's name for the others" {
    try t.expectEqualStrings("No such file or directory", io_mod.describe(error.FileNotFound));
    try t.expectEqualStrings("Is a directory", io_mod.describe(error.IsDir));
    try t.expectEqualStrings("Not a directory", io_mod.describe(error.NotDir));
    try t.expectEqualStrings("Permission denied", io_mod.describe(error.AccessDenied));
    try t.expectEqualStrings("File exists", io_mod.describe(error.PathAlreadyExists));
    try t.expectEqualStrings("SystemResources", io_mod.describe(error.SystemResources));
}

test "statusOf: the exit status, 128 and the signal for a signal, 255 otherwise" {
    try t.expectEqual(@as(u8, 0), io_mod.statusOf(.{ .Exited = 0 }));
    try t.expectEqual(@as(u8, 3), io_mod.statusOf(.{ .Exited = 3 }));
    try t.expectEqual(@as(u8, 255), io_mod.statusOf(.{ .Exited = 255 }));
    try t.expectEqual(@as(u8, 137), io_mod.statusOf(.{ .Signal = 9 }));
    try t.expectEqual(@as(u8, 143), io_mod.statusOf(.{ .Signal = 15 }));
    try t.expectEqual(@as(u8, 255), io_mod.statusOf(.{ .Stopped = 19 }));
    try t.expectEqual(@as(u8, 255), io_mod.statusOf(.{ .Unknown = 1 }));
}

test "a message that cannot be written changes nothing: the status is the same" {
    var c = tk.Case.init();
    defer c.deinit();
    c.stderr_closed = true;
    try expectRun(&c, &.{ "rm", "nope" }, 1, "", "");
    try expectRun(&c, &.{ "sleep", "x" }, 1, "", "");
    try expectRun(&c, &.{"nosuch"}, 127, "", "");
}
