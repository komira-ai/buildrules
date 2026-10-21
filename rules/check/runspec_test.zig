//! The cases of runspec.zig: the options of `run`, `marker` and `expect`, and how a program is started from them: its environment (built step by
//! step), its working directory, the private scratch directory, and what happens when it cannot be started. The program is the toolbox
//! (`printenv NAME` reads one variable back through `marker --capture --stamp-log`, `mkdir -p` and `cat` read the working directory back).

const std = @import("std");
const t = std.testing;
const kit = @import("checkkit.zig");
const common = @import("common.zig");
const rs = @import("runspec.zig");

// ---- the command line -------------------------------------------------------------------------------------------

fn parseOk(c: *kit.Case, kind: rs.Kind, args: kit.Args) !rs.Spec {
    var s = kit.Streams.init(c.alloc());
    return rs.parse(s.io(c), "x", kind, args) orelse {
        std.debug.print("refused: {s}\n", .{s.err.written()});
        return error.TestUnexpectedResult;
    };
}

fn parseRefused(c: *kit.Case, kind: rs.Kind, args: kit.Args, message: []const u8) !void {
    var s = kit.Streams.init(c.alloc());
    if (rs.parse(s.io(c), "x", kind, args) != null) {
        std.debug.print("accepted: {any}\n", .{args});
        return error.TestUnexpectedResult;
    }
    if (!std.mem.eql(u8, s.err.written(), message)) {
        std.debug.print("said '{s}', want '{s}'\n", .{ s.err.written(), message });
        return error.TestUnexpectedResult;
    }
}

test "parse: every option of `run` lands in its field, and what follows `--` is the program" {
    var c = try kit.Case.init();
    defer c.deinit();
    const s = try parseOk(&c, .run, &.{
        "--refuse",       "no such tool",
        "--clear-env",    "--tmpdir",
        "--scratch",      "scr",
        "--ld-library-path", "lib",
        "--cwd",          "work",
        "--cwd-env",      "WORKDIR",
        "--env",          "A=1",
        "--env",          "B=2",
        "--dir",          "D=sub",
        "--dir",          "E=.",
        "--abs",          "P",
        "--abs",          "Q",
        "--abs-prefix",   "PFX_",
        "--mkdir-env",    "M",
        "--",             "/bin/prog",
        "--out",          "x",
    });
    try t.expectEqualStrings("no such tool", s.refuse.?);
    try t.expect(s.clear_env and s.tmpdir);
    try t.expectEqualStrings("scr", s.scratch.?);
    try t.expectEqualStrings("lib", s.ld_library_path.?);
    try t.expectEqualStrings("work", s.cwd.?);
    try t.expectEqualStrings("WORKDIR", s.cwd_env.?);
    try t.expectEqual(@as(usize, 2), s.sets.len);
    try t.expectEqualStrings("A=1", s.sets[0]);
    try t.expectEqualStrings("B=2", s.sets[1]);
    try t.expectEqual(@as(usize, 2), s.dirs.len);
    try t.expectEqualStrings("D=sub", s.dirs[0]);
    try t.expectEqualStrings("E=.", s.dirs[1]);
    try t.expectEqual(@as(usize, 2), s.abs.len);
    try t.expectEqualStrings("Q", s.abs[1]);
    try t.expectEqualStrings("PFX_", s.abs_prefix[0]);
    try t.expectEqualStrings("M", s.mkdir_env[0]);
    // everything after `--` is the program's, options included
    try t.expectEqual(@as(usize, 3), s.argv.len);
    try t.expectEqualStrings("/bin/prog", s.argv[0]);
    try t.expectEqualStrings("--out", s.argv[1]);
}

test "parse: the options of `marker` and `expect` land in their fields" {
    var c = try kit.Case.init();
    defer c.deinit();
    const m = try parseOk(&c, .marker, &.{ "--out", "o", "--capture", "--stamp", "ok\n", "--stamp-log", "--", "/p" });
    try t.expectEqualStrings("o", m.out.?);
    try t.expect(m.capture and m.stamp_log);
    try t.expectEqualStrings("ok\n", m.stamp.?);
    const e = try parseOk(&c, .expect, &.{ "--out", "o", "--want", "w", "--prefix", "--name", "label", "--clear-env", "--", "/p", "a" });
    try t.expectEqualStrings("w", e.want.?);
    try t.expect(e.prefix and e.clear_env);
    try t.expectEqualStrings("label", e.name.?);
    try t.expectEqualStrings("o", e.out.?);
    try t.expectEqual(@as(usize, 2), e.argv.len);
    // no `--`: no program (prepare refuses it)
    const none = try parseOk(&c, .run, &.{"--clear-env"});
    try t.expectEqual(@as(usize, 0), none.argv.len);
}

test "parse: an option that is not one, an option of another command, and an option without its value are refused" {
    var c = try kit.Case.init();
    defer c.deinit();
    try parseRefused(&c, .run, &.{ "--bogus", "--", "/p" }, "check x: unknown option --bogus\n");
    try parseRefused(&c, .run, &.{ "positional", "--", "/p" }, "check x: unknown option positional\n");
    try parseRefused(&c, .run, &.{ "--env", "A=1", "--env" }, "check x: --env needs a value\n");
    // `run` writes no file, and so takes none of these
    for ([_][]const u8{ "--out", "--stamp", "--want", "--name" }) |opt| {
        const msg = try std.fmt.allocPrint(c.alloc(), "check x: {s} is not an option of this command\n", .{opt});
        try parseRefused(&c, .run, &.{ opt, "v", "--", "/p" }, msg);
    }
    for ([_][]const u8{ "--capture", "--stamp-log", "--prefix" }) |opt| {
        const msg = try std.fmt.allocPrint(c.alloc(), "check x: {s} is not an option of this command\n", .{opt});
        try parseRefused(&c, .run, &.{ opt, "--", "/p" }, msg);
    }
    try parseRefused(&c, .marker, &.{ "--want", "w", "--", "/p" }, "check x: --want is not an option of this command\n");
    try parseRefused(&c, .marker, &.{ "--prefix", "--", "/p" }, "check x: --prefix is not an option of this command\n");
    try parseRefused(&c, .marker, &.{ "--refuse", "m", "--", "/p" }, "check x: --refuse is not an option of this command\n");
    try parseRefused(&c, .expect, &.{ "--capture", "--", "/p" }, "check x: --capture is not an option of this command\n");
    try parseRefused(&c, .expect, &.{ "--stamp", "s", "--", "/p" }, "check x: --stamp is not an option of this command\n");
    try parseRefused(&c, .expect, &.{ "--stamp-log", "--", "/p" }, "check x: --stamp-log is not an option of this command\n");
    try parseRefused(&c, .expect, &.{ "--refuse", "m", "--", "/p" }, "check x: --refuse is not an option of this command\n");
}

// ---- refusals before anything is started ------------------------------------------------------------------------

test "run --refuse: starts nothing, writes the message as it is to stderr, exits 2" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try c.run(&.{ "run", "--refuse", "cxx toolchain: ar is not provided (see rules/cxx/toolchain.bzl)" }), 2, "", "cxx toolchain: ar is not provided (see rules/cxx/toolchain.bzl)\n");
    try kit.expectResult(try c.run(&.{ "run", "--refuse", "m", "--", c.toolbox, "true" }), 2, "", "m\n");
}

test "a program: there must be one, it must be a path, and it is never looked for in a PATH" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try c.run(&.{ "run", "--clear-env" }), 2, "", "check run: no program: it follows `--`\n");
    try kit.expectResult(try c.run(&.{ "run", "--" }), 2, "", "check run: no program: it follows `--`\n");
    c.environ = &.{"PATH=/bin:/usr/bin"};
    try kit.expectResult(try c.run(&.{ "run", "--", "true" }), 2, "", "check run: true is not a path: a program is never looked for in a PATH, give its path\n");
    try kit.expectResult(try c.run(&.{ "marker", "--out", "o", "--", "true" }), 2, "", "check marker: true is not a path: a program is never looked for in a PATH, give its path\n");
    try t.expect(!c.exists("o"));
}

test "--env, --dir and --cwd-env: a malformed one is refused, and a --dir needs a scratch directory" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectFailure(try c.runTool(&.{ "run", "--env", "NOEQUALS" }, &.{"true"}), 2, "--env NOEQUALS: expected NAME=VALUE");
    try kit.expectFailure(try c.runTool(&.{ "run", "--env", "=value" }, &.{"true"}), 2, "--env =value: expected NAME=VALUE");
    try kit.expectFailure(try c.runTool(&.{ "run", "--scratch", "s", "--dir", "NODIR" }, &.{"true"}), 2, "--dir NODIR: expected NAME=SUBDIRECTORY");
    try kit.expectFailure(try c.runTool(&.{ "run", "--dir", "X=sub" }, &.{"true"}), 2, "--dir X=sub needs --scratch");
    try kit.expectFailure(try c.runTool(&.{ "run", "--cwd-env", "NOT_SET" }, &.{"true"}), 2, "--cwd-env NOT_SET: the variable is not set");
    try kit.expectFailure(try c.runTool(&.{ "run", "--env", "EMPTY=", "--cwd-env", "EMPTY" }, &.{"true"}), 2, "--cwd-env EMPTY: the variable is not set");
}

// ---- the environment --------------------------------------------------------------------------------------------

test "the environment is the process's own, entries that are not NAME=VALUE left out; --clear-env starts empty" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.environ = &.{ "INH=yes", "NOEQUALS", "=nameless", "WITH=eq=in=value" };
    try t.expectEqualStrings("yes", (try kit.valueOf(&c, &.{}, "INH")).?);
    try t.expectEqualStrings("eq=in=value", (try kit.valueOf(&c, &.{}, "WITH")).?);
    try t.expect((try kit.valueOf(&c, &.{}, "NOEQUALS")) == null);
    try t.expect((try kit.valueOf(&c, &.{ "--clear-env" }, "INH")) == null);
    // nothing at all: the listing is empty
    try kit.expectResult(try c.runTool(&.{ "marker", "--capture", "--stamp-log", "--out", "all", "--clear-env" }, &.{"env"}), 0, "", "");
    try t.expectEqual(@as(usize, 0), (try c.read("all")).len);
    // and with an --env, exactly that
    try kit.expectResult(try c.runTool(&.{ "marker", "--capture", "--stamp-log", "--out", "all", "--clear-env", "--env", "ONLY=1" }, &.{"env"}), 0, "", "");
    try t.expectEqualStrings("ONLY=1\n", try c.read("all"));
}

test "--env sets, replaces what the process had, and may be empty or hold `=`" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.environ = &.{ "INH=old", "KEEP=kept" };
    const before: kit.Args = &.{ "--env", "INH=new", "--env", "A=x=y", "--env", "E=", "--env", "A=again" };
    try t.expectEqualStrings("new", (try kit.valueOf(&c, before, "INH")).?);
    try t.expectEqualStrings("kept", (try kit.valueOf(&c, before, "KEEP")).?);
    try t.expectEqualStrings("again", (try kit.valueOf(&c, before, "A")).?);
    try t.expectEqualStrings("", (try kit.valueOf(&c, before, "E")).?);
}

test "--abs and --abs-prefix make a relative value absolute, whatever the order of the options; an absolute, an empty or an unset one stay" {
    var c = try kit.Case.init();
    defer c.deinit();
    const here = try c.path(".");
    const before: kit.Args = &.{ "--abs", "REL", "--abs", "ABS", "--abs", "EMPTY", "--abs", "UNSET", "--env", "REL=some/dir", "--env", "ABS=/already/abs", "--env", "EMPTY=", "--env", "PFX_A=a", "--env", "PFX_B=/b", "--env", "PFX_C=", "--env", "OTHER=o", "--abs-prefix", "PFX_" };
    try t.expectEqualStrings(try std.fmt.allocPrint(c.alloc(), "{s}/some/dir", .{here}), (try kit.valueOf(&c, before, "REL")).?);
    try t.expectEqualStrings("/already/abs", (try kit.valueOf(&c, before, "ABS")).?);
    try t.expectEqualStrings("", (try kit.valueOf(&c, before, "EMPTY")).?);
    try t.expect((try kit.valueOf(&c, before, "UNSET")) == null);
    try t.expectEqualStrings(try std.fmt.allocPrint(c.alloc(), "{s}/a", .{here}), (try kit.valueOf(&c, before, "PFX_A")).?);
    try t.expectEqualStrings("/b", (try kit.valueOf(&c, before, "PFX_B")).?);
    try t.expectEqualStrings("", (try kit.valueOf(&c, before, "PFX_C")).?);
    try t.expectEqualStrings("o", (try kit.valueOf(&c, before, "OTHER")).?);
    // a variable the process had (not set by --env) is made absolute too
    c.environ = &.{"FROM_PROCESS=rel/x"};
    try t.expectEqualStrings(try std.fmt.allocPrint(c.alloc(), "{s}/rel/x", .{here}), (try kit.valueOf(&c, &.{ "--abs", "FROM_PROCESS" }, "FROM_PROCESS")).?);
}

test "--ld-library-path replaces LD_LIBRARY_PATH with the directory, made absolute" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.environ = &.{"LD_LIBRARY_PATH=/old/lib"};
    const here = try c.path(".");
    try t.expectEqualStrings(try std.fmt.allocPrint(c.alloc(), "{s}/compiler/lib", .{here}), (try kit.valueOf(&c, &.{ "--ld-library-path", "compiler/lib" }, "LD_LIBRARY_PATH")).?);
    try t.expectEqualStrings("/abs/lib", (try kit.valueOf(&c, &.{ "--ld-library-path", "/abs/lib" }, "LD_LIBRARY_PATH")).?);
    try t.expectEqualStrings("/old/lib", (try kit.valueOf(&c, &.{}, "LD_LIBRARY_PATH")).?);
}

test "--mkdir-env makes the directory the variable names, parents too; an unset or an empty one is skipped; one that cannot be made is refused" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try c.runTool(&.{ "run", "--env", "D=made/a/b", "--env", "EMPTY=", "--mkdir-env", "D", "--mkdir-env", "EMPTY", "--mkdir-env", "UNSET" }, &.{"true"}), 0, "", "");
    try t.expect(c.exists("made/a/b"));
    // an absolute directory, and one that is there already
    const abs = try c.at("abs/dir");
    const arg = try std.fmt.allocPrint(c.alloc(), "D={s}", .{abs});
    try kit.expectResult(try c.runTool(&.{ "run", "--env", arg, "--mkdir-env", "D" }, &.{"true"}), 0, "", "");
    try kit.expectResult(try c.runTool(&.{ "run", "--env", arg, "--mkdir-env", "D" }, &.{"true"}), 0, "", "");
    try t.expect(c.exists("abs/dir"));
    // a file is in the way
    try c.put("file", "x");
    try kit.expectFailure(try c.runTool(&.{ "run", "--env", "D=file/sub", "--mkdir-env", "D" }, &.{"true"}), 1, "cannot make file/sub (named by D): NotDir");
}

// ---- the scratch directory --------------------------------------------------------------------------------------

test "--scratch NAME: BUCK_SCRATCH_PATH/NAME when it is absolute, relative to the working directory when it is not, `.buildrules_NAME` in it without one" {
    var c = try kit.Case.init();
    defer c.deinit();
    const here = try c.path(".");
    const dir: kit.Args = &.{ "--scratch", "scr", "--dir", "S=." };
    // no BUCK_SCRATCH_PATH
    try t.expectEqualStrings(try std.fmt.allocPrint(c.alloc(), "{s}/.buildrules_scr", .{here}), (try kit.valueOf(&c, dir, "S")).?);
    // empty is the same as not set
    c.environ = &.{"BUCK_SCRATCH_PATH="};
    try t.expectEqualStrings(try std.fmt.allocPrint(c.alloc(), "{s}/.buildrules_scr", .{here}), (try kit.valueOf(&c, dir, "S")).?);
    // relative
    c.environ = &.{"BUCK_SCRATCH_PATH=buck-out/tmp/act"};
    try t.expectEqualStrings(try std.fmt.allocPrint(c.alloc(), "{s}/buck-out/tmp/act/scr", .{here}), (try kit.valueOf(&c, dir, "S")).?);
    // absolute
    const abs = try std.fmt.allocPrint(c.alloc(), "BUCK_SCRATCH_PATH={s}/elsewhere", .{here});
    c.environ = &.{abs};
    try t.expectEqualStrings(try std.fmt.allocPrint(c.alloc(), "{s}/elsewhere/scr", .{here}), (try kit.valueOf(&c, dir, "S")).?);
}

test "--dir NAME=SUB: SUB of the scratch directory, made, absolute; `.` is the scratch directory; the program runs inside it with --cwd-env" {
    var c = try kit.Case.init();
    defer c.deinit();
    const here = try c.path(".");
    const before: kit.Args = &.{ "--scratch", "scr", "--dir", "CACHE=cache/deep", "--dir", "ROOT=." };
    try t.expectEqualStrings(try std.fmt.allocPrint(c.alloc(), "{s}/.buildrules_scr/cache/deep", .{here}), (try kit.valueOf(&c, before, "CACHE")).?);
    // the directories exist while the program runs: it is started inside one (a start in a directory that is not there fails)
    try kit.expectResult(try c.runTool(&.{ "run", "--scratch", "scr", "--dir", "ROOT=.", "--dir", "CACHE=cache/deep", "--cwd-env", "CACHE" }, &.{ "mkdir", "-p", "made-inside" }), 0, "", "");
    try t.expect(!c.exists(".buildrules_scr"));
}

test "--scratch: emptied before the run, removed after it, whether the program passed or not" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put(".buildrules_scr/stale", "left by an earlier run");
    // the stale file is gone when the program runs (cat of it fails), and the directory is gone afterwards
    try kit.expectFailure(try c.runTool(&.{ "run", "--scratch", "scr", "--dir", "R=.", "--cwd-env", "R" }, &.{ "cat", "stale" }), 1, "");
    try t.expect(!c.exists(".buildrules_scr"));
    try c.put(".buildrules_scr/stale", "again");
    try kit.expectResult(try c.runTool(&.{ "run", "--scratch", "scr" }, &.{"false"}), 1, "", "");
    try t.expect(!c.exists(".buildrules_scr"));
    // a scratch directory that was never asked for is not made
    try kit.expectResult(try c.runTool(&.{"run"}, &.{"true"}), 0, "", "");
    try t.expect(!c.exists(".buildrules_scr"));
}

test "--scratch that cannot be made, and a --dir that cannot be made, are refused with the reason" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("blocked", "a file where the scratch path goes");
    c.environ = &.{"BUCK_SCRATCH_PATH=blocked/inside"};
    try kit.expectFailure(try c.runTool(&.{ "run", "--scratch", "scr" }, &.{"true"}), 1, "cannot make the scratch directory");
    c.environ = &.{};
    // a name longer than the file system allows cannot be made
    const long = try std.fmt.allocPrint(c.alloc(), "X={s}", .{"a" ** 300});
    try kit.expectFailure(try c.runTool(&.{ "run", "--scratch", "scr", "--dir", long }, &.{"true"}), 1, "cannot make ");
    try t.expect(!c.exists(".buildrules_scr"));
}

// ---- --tmpdir ---------------------------------------------------------------------------------------------------

test "--tmpdir: TMPDIR is the action's scratch path made absolute; with none, TMPDIR is kept, and /tmp when it is empty or not set" {
    var c = try kit.Case.init();
    defer c.deinit();
    const here = try c.path(".");
    c.environ = &.{ "BUCK_SCRATCH_PATH=rel/scratch", "TMPDIR=/old" };
    try t.expectEqualStrings(try std.fmt.allocPrint(c.alloc(), "{s}/rel/scratch", .{here}), (try kit.valueOf(&c, &.{"--tmpdir"}, "TMPDIR")).?);
    c.environ = &.{ "BUCK_SCRATCH_PATH=/abs/scratch", "TMPDIR=/old" };
    try t.expectEqualStrings("/abs/scratch", (try kit.valueOf(&c, &.{"--tmpdir"}, "TMPDIR")).?);
    c.environ = &.{"TMPDIR=/kept"};
    try t.expectEqualStrings("/kept", (try kit.valueOf(&c, &.{"--tmpdir"}, "TMPDIR")).?);
    c.environ = &.{"TMPDIR="};
    try t.expectEqualStrings("/tmp", (try kit.valueOf(&c, &.{"--tmpdir"}, "TMPDIR")).?);
    c.environ = &.{};
    try t.expectEqualStrings("/tmp", (try kit.valueOf(&c, &.{"--tmpdir"}, "TMPDIR")).?);
    // without the option nothing is set
    try t.expect((try kit.valueOf(&c, &.{}, "TMPDIR")) == null);
}

// ---- the working directory and the program ----------------------------------------------------------------------

test "the program runs in the working directory unless --cwd or --cwd-env says another; both are made absolute" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.tmp.dir.makePath("sub/dir");
    try kit.expectResult(try c.runTool(&.{"run"}, &.{ "mkdir", "-p", "from-default" }), 0, "", "");
    try t.expect(c.exists("from-default"));
    try kit.expectResult(try c.runTool(&.{ "run", "--cwd", "sub" }, &.{ "mkdir", "-p", "from-cwd" }), 0, "", "");
    try t.expect(c.exists("sub/from-cwd") and !c.exists("from-cwd"));
    try kit.expectResult(try c.runTool(&.{ "run", "--cwd", try c.at("sub/dir") }, &.{ "mkdir", "-p", "from-abs" }), 0, "", "");
    try t.expect(c.exists("sub/dir/from-abs"));
    try kit.expectResult(try c.runTool(&.{ "run", "--env", "W=sub/dir", "--cwd-env", "W" }, &.{ "mkdir", "-p", "from-env" }), 0, "", "");
    try t.expect(c.exists("sub/dir/from-env"));
    // --cwd-env wins over --cwd, as the later step
    try kit.expectResult(try c.runTool(&.{ "run", "--cwd", "sub", "--env", "W=sub/dir", "--cwd-env", "W" }, &.{ "mkdir", "-p", "from-both" }), 0, "", "");
    try t.expect(c.exists("sub/dir/from-both") and !c.exists("sub/from-both"));
}

test "a relative program is found from the directory check was started in, not from the one it runs in" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.tmp.dir.symLink(c.toolbox, "toolbox", .{});
    try c.tmp.dir.makePath("other");
    try kit.expectResult(try c.run(&.{ "run", "--cwd", "other", "--", "./toolbox", "mkdir", "-p", "made" }), 0, "", "");
    try t.expect(c.exists("other/made"));
    // the program is named by the link, and the applet follows: a link named for an applet runs it
    try c.tmp.dir.symLink(c.toolbox, "mkdir", .{});
    try kit.expectResult(try c.run(&.{ "run", "--cwd", "other", "--", "mkdir", "-p", "x" }), 2, "", null);
    try kit.expectResult(try c.run(&.{ "run", "--cwd", "other", "--", "./mkdir", "-p", "linked" }), 0, "", "");
    try t.expect(c.exists("other/linked"));
}

test "run: the exit status of the program is the exit status, the arguments pass through unchanged" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try c.runTool(&.{"run"}, &.{"true"}), 0, "", "");
    try kit.expectResult(try c.runTool(&.{"run"}, &.{"false"}), 1, "", "");
    try kit.expectResult(try c.runTool(&.{"run"}, &.{ "rm", "never-there" }), 1, "", null);
    try kit.expectResult(try c.runTool(&.{"run"}, &.{"nosuchapplet"}), 127, "", null);
    // arguments with spaces, an option-looking one, an empty one
    try kit.expectResult(try c.runTool(&.{"run"}, &.{ "mkdir", "-p", "--", "a b", "-c" }), 0, "", "");
    try t.expect(c.exists("a b") and c.exists("-c"));
}

test "a program that cannot be started is 127 when it is not there and 126 when it is not executable, with the reason, in both modes" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.put("plain", "not a program");
    const plain = try c.path("plain");
    try kit.expectResult(try c.run(&.{ "run", "--", "/no/such/program" }), 127, "", "check run: cannot run /no/such/program: FileNotFound\n");
    try kit.expectResult(try c.run(&.{ "run", "--", plain }), 126, "", try std.fmt.allocPrint(c.alloc(), "check run: cannot run {s}: AccessDenied\n", .{plain}));
    // captured: the same
    const r = try c.run(&.{ "marker", "--out", "o", "--capture", "--", "/no/such/program" });
    try kit.expectFailure(r, 127, "cannot run /no/such/program: FileNotFound");
    try t.expect(!c.exists("o"));
    const r2 = try c.run(&.{ "marker", "--out", "o", "--capture", "--", plain });
    try kit.expectFailure(r2, 126, "AccessDenied");
    // a working directory that is not there
    try kit.expectFailure(try c.runTool(&.{ "run", "--cwd", "nodir" }, &.{"true"}), 127, "cannot run ");
}

test "statusOf: the exit status, 128 and the signal for a signal, 255 otherwise" {
    try t.expectEqual(@as(u8, 0), common.statusOf(.{ .Exited = 0 }));
    try t.expectEqual(@as(u8, 3), common.statusOf(.{ .Exited = 3 }));
    try t.expectEqual(@as(u8, 137), common.statusOf(.{ .Signal = 9 }));
    try t.expectEqual(@as(u8, 139), common.statusOf(.{ .Signal = 11 }));
    try t.expectEqual(@as(u8, 255), common.statusOf(.{ .Stopped = 19 }));
    try t.expectEqual(@as(u8, 255), common.statusOf(.{ .Unknown = 1 }));
}
