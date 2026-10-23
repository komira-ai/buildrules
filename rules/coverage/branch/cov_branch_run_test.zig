//! Unit tests of `cov_branch run` (cov_branch_run.zig), run by `zig test` as a build action (`:cov_branch_unit`). The test binary and
//! llvm-profdata are a stand-in (`Fake`, a Runner) that writes what the real program would (raw profiles, the merged profile, `show`'s
//! listing, an exit status), so every decision of the subcommand is reached without a test or LLVM. The shipped executable is run as a
//! process by cov_branch_run_exe_test.zig; what a real run does end to end is the branch records of examples/mojo/branches.

const std = @import("std");
const proc = @import("proc.zig");
const common = @import("cov_branch_common.zig");
const r = @import("cov_branch_run.zig");
const testing = std.testing;

const SHOW_OK = "Counters:\n  main:\n    Hash: 0x1\n    Counters: 2\n    Block counts: [1, 0]\nInstrumentation level: IR  entry_first = 0\nFunction count: 1\nTotal number of blocks: 2\nTotal count: 1\nTotal functions: 1\n";

/// A raw profile header: the 64-bit magic, the version and the variant flags.
fn raw(version: u32, flags: u32) [16]u8 {
    var b: [16]u8 = undefined;
    std.mem.writeInt(u64, b[0..8], r.RAW_MAGIC, .little);
    std.mem.writeInt(u32, b[8..12], version, .little);
    std.mem.writeInt(u32, b[12..16], flags, .little);
    return b;
}

const Fake = struct {
    /// The test binary's exit status, and the raw profiles it writes (name -> bytes) under LLVM_PROFILE_FILE's directory.
    test_status: proc.Status = .{ .exited = 0 },
    raws: []const []const u8 = &.{"a.profraw"},
    raw_bytes: []const u8 = "",
    merge_status: proc.Status = .{ .exited = 0 },
    merge_log: []const u8 = "",
    show_status: proc.Status = .{ .exited = 0 },
    show_text: []const u8 = SHOW_OK,
    /// The step whose start fails (error.ForkFailed), or none.
    fail_start: ?[]const u8 = null,
    calls: std.ArrayList(proc.Spec),

    fn init() Fake {
        return .{ .calls = std.ArrayList(proc.Spec).empty };
    }

    fn runner(self: *Fake) common.Runner {
        return .{ .ptr = self, .runFn = &run };
    }

    fn write(path: []const u8, data: []const u8) !void {
        var f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(data);
    }

    fn envValue(env: []const []const u8, name: []const u8) ?[]const u8 {
        for (env) |e| if (std.mem.startsWith(u8, e, name) and e.len > name.len and e[name.len] == '=') return e[name.len + 1 ..];
        return null;
    }

    fn run(ptr: *anyopaque, alloc: std.mem.Allocator, spec: proc.Spec) anyerror!proc.Outcome {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        var copy = spec;
        copy.argv = try alloc.dupe([]const u8, spec.argv);
        copy.env = try alloc.dupe([]const u8, spec.env);
        try self.calls.append(alloc, copy);
        const is_test = spec.argv.len == 1;
        const step: []const u8 = if (is_test) "test" else spec.argv[1];
        if (self.fail_start) |f| if (std.mem.eql(u8, f, step)) return error.ForkFailed;
        if (is_test) {
            // The profile file name template, as the runtime expands %p.
            const tmpl = envValue(spec.env, "LLVM_PROFILE_FILE").?;
            const dir = std.fs.path.dirname(tmpl).?;
            for (self.raws) |name| {
                const path = try std.fs.path.join(alloc, &.{ dir, name });
                if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
                try write(path, self.raw_bytes);
            }
            return .{ .status = self.test_status };
        }
        if (std.mem.eql(u8, step, "merge")) {
            try write(spec.stdout_path.?, self.merge_log);
            if (self.merge_status == .exited and self.merge_status.exited == 0) try write(spec.argv[3], "indexed");
            return .{ .status = self.merge_status };
        }
        try write(spec.stdout_path.?, self.show_text);
        return .{ .status = self.show_status };
    }
};

const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8 = "",
    err: std.ArrayList(u8) = undefined,

    fn init() !Case {
        var c = Case{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .tmp = testing.tmpDir(.{}) };
        c.root = try c.tmp.dir.realpathAlloc(c.arena.allocator(), ".");
        c.err = std.ArrayList(u8).empty;
        try c.put("tc/compiler/lib/libKGENCompilerRTShared.so", "so");
        try c.put("share/tests/test_one.mojo", "def main(): pass\n");
        try c.put("bin/test_one", "binary");
        try c.tmp.dir.makePath("llvm/bin");
        try c.tmp.dir.writeFile(.{ .sub_path = "llvm/bin/llvm-profdata", .data = "#!", .flags = .{ .mode = 0o755 } });
        try c.tmp.dir.makePath("out");
        return c;
    }

    fn put(self: *Case, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |d| try self.tmp.dir.makePath(d);
        try self.tmp.dir.writeFile(.{ .sub_path = path, .data = data });
    }

    fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn a(self: *Case) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn p(self: *Case, rel: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a(), "{s}/{s}", .{ self.root, rel }) catch unreachable;
    }

    fn where(self: *Case) common.Where {
        return .{ .cwd = self.root, .k = self.p("scratch/cov_branch_run"), .env = &.{ "HOME=/h/user", "PATH=/usr/bin:/bin", "ZED=1" } };
    }

    /// The flags, every path absolute (the access check on llvm-profdata reads the process's own working directory).
    fn argv(self: *Case) []const []const u8 {
        return self.a().dupe([]const u8, &.{ "--compiler", self.p("tc/compiler"), "--share", self.p("share"), "--label", "//pkg:test_one", "--profdata", self.p("llvm/bin/llvm-profdata"), "--raw-version", "11", "--binary", self.p("bin/test_one"), "--out", self.p("out/test_one.profdata") }) catch unreachable;
    }

    fn go(self: *Case, fake: *Fake) !u8 {
        return r.cli(self.a(), self.argv(), self.where(), fake.runner(), &self.err);
    }

    fn has(self: *Case, s: []const u8) !void {
        if (std.mem.indexOf(u8, self.err.items, s) == null) {
            std.debug.print("message does not hold '{s}':\n{s}\n", .{ s, self.err.items });
            return error.TestUnexpectedResult;
        }
    }

    fn exists(self: *Case, rel: []const u8) bool {
        self.tmp.dir.access(rel, .{}) catch return false;
        return true;
    }
};

fn good() [16]u8 {
    return raw(11, r.IR_BIT);
}

test "a run: the test in its tree with exactly its environment, then merge and show; the profile written, no message, the scratch removed" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    const b = good();
    fake.raw_bytes = &b;
    try testing.expectEqual(@as(u8, 0), try c.go(&fake));
    try testing.expectEqualStrings("", c.err.items);
    try testing.expectEqual(@as(usize, 3), fake.calls.items.len);
    const k = c.p("scratch/cov_branch_run");

    const t = fake.calls.items[0];
    try testing.expectEqual(@as(usize, 1), t.argv.len);
    try testing.expectEqualStrings(c.p("bin/test_one"), t.argv[0]);
    try testing.expectEqualStrings(c.p("share"), t.cwd.?);
    // Nothing of this tool's own environment reaches the test.
    try testing.expectEqual(@as(usize, 3), t.env.len);
    try testing.expectEqualStrings("PATH=/usr/bin:/bin", t.env[0]);
    try testing.expectEqualStrings(try std.fmt.allocPrint(c.a(), "LD_LIBRARY_PATH={s}/lib", .{c.p("tc/compiler")}), t.env[1]);
    try testing.expectEqualStrings(try std.fmt.allocPrint(c.a(), "LLVM_PROFILE_FILE={s}/prof/%p.profraw", .{k}), t.env[2]);

    const m = fake.calls.items[1];
    try testing.expectEqual(@as(usize, 5), m.argv.len);
    try testing.expectEqualStrings(c.p("llvm/bin/llvm-profdata"), m.argv[0]);
    try testing.expectEqualStrings("merge", m.argv[1]);
    try testing.expectEqualStrings("-o", m.argv[2]);
    try testing.expectEqualStrings(c.p("out/test_one.profdata"), m.argv[3]);
    try testing.expectEqualStrings(try std.fmt.allocPrint(c.a(), "{s}/prof/a.profraw", .{k}), m.argv[4]);
    try testing.expectEqual(@as(usize, 1), m.env.len);
    try testing.expectEqualStrings("LC_ALL=C", m.env[0]);
    try testing.expect(m.stderr_to_stdout);

    const s = fake.calls.items[2];
    try testing.expectEqualStrings("show", s.argv[1]);
    try testing.expectEqualStrings(c.p("out/test_one.profdata"), s.argv[2]);

    try testing.expectEqualStrings("indexed", try c.tmp.dir.readFileAlloc(c.a(), "out/test_one.profdata", 100));
    try testing.expect(!c.exists("scratch/cov_branch_run"));
}

test "the test's --env entries come before LLVM_PROFILE_FILE, which is always the run's own" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    const b = good();
    fake.raw_bytes = &b;
    var full = std.ArrayList([]const u8).empty;
    try full.appendSlice(c.a(), c.argv());
    try full.appendSlice(c.a(), &.{ "--env", "A=1", "--env", "B=two words" });
    try testing.expectEqual(@as(u8, 0), try r.cli(c.a(), full.items, c.where(), fake.runner(), &c.err));
    const env = fake.calls.items[0].env;
    try testing.expectEqual(@as(usize, 5), env.len);
    try testing.expectEqualStrings("A=1", env[2]);
    try testing.expectEqualStrings("B=two words", env[3]);
    try testing.expect(std.mem.startsWith(u8, env[4], "LLVM_PROFILE_FILE="));
}

test "each --lib-dir follows the compiler's lib on the library path, in the order given and made absolute; the rest of the environment is as it was" {
    // Defect caught: a shared native library the instrumented binary loads that the run cannot find (an ordinary test finds it in the lib/ beside
    // it), or that shadows the compiler's runtime library (the compiler's directory comes first).
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    const b = good();
    fake.raw_bytes = &b;
    var full = std.ArrayList([]const u8).empty;
    try full.appendSlice(c.a(), c.argv());
    try full.appendSlice(c.a(), &.{ "--lib-dir", c.p("natives"), "--env", "A=1", "--lib-dir", "rel/libs" });
    try testing.expectEqual(@as(u8, 0), try r.cli(c.a(), full.items, c.where(), fake.runner(), &c.err));
    const env = fake.calls.items[0].env;
    try testing.expectEqual(@as(usize, 4), env.len);
    try testing.expectEqualStrings("PATH=/usr/bin:/bin", env[0]);
    try testing.expectEqualStrings(try std.fmt.allocPrint(c.a(), "LD_LIBRARY_PATH={s}/lib:{s}:{s}/rel/libs", .{ c.p("tc/compiler"), c.p("natives"), c.root }), env[1]);
    try testing.expectEqualStrings("A=1", env[2]);
}

test "--lib-dir is repeatable, and an empty one is a usage error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const full = [_][]const u8{ "--compiler", "c", "--share", "s", "--label", "l", "--profdata", "p", "--raw-version", "11", "--binary", "b", "--out", "o" };
    const none =(try r.parseArgs(a, &full, &why)).?;
    try testing.expectEqual(@as(usize, 0), none.lib_dirs.len);
    const two = (try r.parseArgs(a, &([_][]const u8{ "--lib-dir", "x" } ++ full ++ [_][]const u8{ "--lib-dir", "y" }), &why)).?;
    try testing.expectEqual(@as(usize, 2), two.lib_dirs.len);
    try testing.expectEqualStrings("x", two.lib_dirs[0]);
    try testing.expectEqualStrings("y", two.lib_dirs[1]);
    try testing.expect((try r.parseArgs(a, &(full ++ [_][]const u8{ "--lib-dir", "" }), &why)) == null);
    try testing.expectEqualStrings("--lib-dir is empty", why);
    try testing.expect((try r.parseArgs(a, &(full ++ [_][]const u8{"--lib-dir"}), &why)) == null);
    try testing.expectEqualStrings("unknown argument --lib-dir", why);
}

test "--data-env names the tree the test runs in, absolute, after the --env entries and the library path; the test's working directory is that tree" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    const b = good();
    fake.raw_bytes = &b;
    var full = std.ArrayList([]const u8).empty;
    try full.appendSlice(c.a(), c.argv());
    try full.appendSlice(c.a(), &.{ "--lib-dir", c.p("natives"), "--env", "A=1", "--data-env", "BUILDRULES_TEST_DATA" });
    try testing.expectEqual(@as(u8, 0), try r.cli(c.a(), full.items, c.where(), fake.runner(), &c.err));
    const t = fake.calls.items[0];
    try testing.expectEqual(@as(usize, 5), t.env.len);
    try testing.expectEqualStrings("A=1", t.env[2]);
    try testing.expectEqualStrings(try std.fmt.allocPrint(c.a(), "BUILDRULES_TEST_DATA={s}", .{c.p("share")}), t.env[3]);
    try testing.expectEqualStrings(c.p("share"), t.cwd.?);
    try testing.expect(std.mem.startsWith(u8, t.env[4], "LLVM_PROFILE_FILE="));
}

test "--data-env: a name the run sets itself, an empty one, one with '=' and a repeat are usage errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const full = [_][]const u8{ "--compiler", "c", "--share", "s", "--label", "l", "--profdata", "p", "--raw-version", "11", "--binary", "b", "--out", "o" };
    for ([_][]const u8{ "PATH", "LD_LIBRARY_PATH", "LLVM_PROFILE_FILE", "", "A=B" }) |n| {
        try testing.expect((try r.parseArgs(a, &(full ++ [_][]const u8{ "--data-env", n }), &why)) == null);
        try testing.expectEqualStrings(try std.fmt.allocPrint(a, "--data-env '{s}' is not a variable name a branch coverage run may set", .{n}), why);
    }
    try testing.expect((try r.parseArgs(a, &(full ++ [_][]const u8{ "--data-env", "X", "--data-env", "Y" }), &why)) == null);
    try testing.expectEqualStrings("--data-env given twice", why);
    const ok = (try r.parseArgs(a, &(full ++ [_][]const u8{ "--data-env", "X" }), &why)).?;
    try testing.expectEqualStrings("X", ok.data_env);
}

test "a test that fails fails the action with its own exit status, the label and the reason; nothing is merged" {
    for ([_]struct { st: proc.Status, rc: u8 }{ .{ .st = .{ .exited = 3 }, .rc = 3 }, .{ .st = .{ .signaled = 11 }, .rc = 139 } }) |cs| {
        var c = try Case.init();
        defer c.deinit();
        var fake = Fake.init();
        fake.test_status = cs.st;
        try testing.expectEqual(cs.rc, try c.go(&fake));
        try c.has("BRANCH COVERAGE RUN FAILED: //pkg:test_one\n");
        try c.has(try std.fmt.allocPrint(c.a(), "The test failed instrumented for branch coverage (exit {d})", .{cs.rc}));
        try testing.expectEqual(@as(usize, 1), fake.calls.items.len);
        try testing.expect(!c.exists("out/test_one.profdata"));
    }
}

test "a test that wrote no profile fails the action, saying where it looked" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    fake.raws = &.{};
    try testing.expectEqual(@as(u8, 1), try c.go(&fake));
    try c.has("The test passed but wrote no .profraw under ");
    try c.has("/prof (LLVM_PROFILE_FILE)");
    try testing.expectEqual(@as(usize, 1), fake.calls.items.len);
}

test "every raw profile is checked, found at any depth and in order; a child's profile counts" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    const b = good();
    fake.raw_bytes = &b;
    fake.raws = &.{ "b.profraw", "sub/a.profraw", "c.txt" };
    try testing.expectEqual(@as(u8, 0), try c.go(&fake));
    const m = fake.calls.items[1];
    // c.txt is no profile; sub/a.profraw sorts after b.profraw by path.
    try testing.expectEqual(@as(usize, 6), m.argv.len);
    try testing.expect(std.mem.endsWith(u8, m.argv[4], "/prof/b.profraw"));
    try testing.expect(std.mem.endsWith(u8, m.argv[5], "/prof/sub/a.profraw"));
}

test "a raw profile of another magic, version or without the IR bit is refused, naming it" {
    const v10 = raw(10, r.IR_BIT);
    const no_ir = raw(11, 0);
    const whole = raw(11, r.IR_BIT);
    const cases = [_]struct { bytes: []const u8, msg: []const u8 }{
        .{ .bytes = "", .msg = "a.profraw does not start with the 64-bit raw profile magic" },
        .{ .bytes = "\x81rpr", .msg = "a.profraw does not start with the 64-bit raw profile magic" },
        .{ .bytes = &v10, .msg = "a.profraw has raw profile version 10, not 11" },
        .{ .bytes = &no_ir, .msg = "a.profraw has variant flags 0x00000000, without the IR-instrumentation bit" },
        // A header cut short is refused at the field it lacks, however its bytes read.
        .{ .bytes = whole[0..12], .msg = "a.profraw has variant flags 0x00000000" },
        .{ .bytes = whole[0..10], .msg = "a.profraw has raw profile version 11, not 11" },
    };
    for (cases) |cs| {
        var c = try Case.init();
        defer c.deinit();
        var fake = Fake.init();
        fake.raw_bytes = cs.bytes;
        try testing.expectEqual(@as(u8, 1), try c.go(&fake));
        try c.has("BRANCH COVERAGE RUN FAILED: //pkg:test_one\n");
        try c.has(cs.msg);
        try testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    }
}

test "a merge that fails: a version mismatch says which version llvm-profdata expects; any other refusal says how many profiles" {
    {
        var c = try Case.init();
        defer c.deinit();
        var fake = Fake.init();
        const b = good();
        fake.raw_bytes = &b;
        fake.merge_status = .{ .exited = 1 };
        fake.merge_log = "warning: x.profraw: raw profile version mismatch: Profile uses raw profile format version = 12; expected version = 11\nerror: no profile can be merged\n";
        try testing.expectEqual(@as(u8, 1), try c.go(&fake));
        try c.has("llvm-profdata refused a raw profile of version 11: it expects 11: warning: x.profraw: raw profile version mismatch");
        try testing.expectEqual(@as(usize, 2), fake.calls.items.len);
    }
    {
        var c = try Case.init();
        defer c.deinit();
        var fake = Fake.init();
        const b = good();
        fake.raw_bytes = &b;
        fake.merge_status = .{ .signaled = 9 };
        fake.merge_log = "one\ntwo\nthree\nfour\n";
        try testing.expectEqual(@as(u8, 1), try c.go(&fake));
        try c.has("llvm-profdata merge failed on 1 raw profile(s): one two three ");
        try testing.expect(std.mem.indexOf(u8, c.err.items, "four") == null);
    }
}

test "mergeRefusal lists each expected version once, sorted; a trailing mismatch line without digits is skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = "raw profile version mismatch; expected version = 12\nraw profile version mismatch; expected version = 11\nraw profile version mismatch; expected version = 12\nraw profile version mismatch; expected version = \n";
    const got = try r.mergeRefusal(a, log, 13, 2);
    try testing.expect(std.mem.indexOf(u8, got, "refused a raw profile of version 13: it expects 11 12: ") != null);
}

test "a show that fails, or that is not an IR profile with one positive function count, is refused" {
    const cases = [_]struct { st: proc.Status, text: []const u8, msg: []const u8 }{
        .{ .st = .{ .exited = 1 }, .text = "error: bad\nmore\nlast\n", .msg = "llvm-profdata show failed on the merged profile: error: bad more " },
        .{ .st = .{ .exited = 0 }, .text = "Instrumentation level: Front-end\nTotal functions: 1\n", .msg = "the merged profile is not an IR-instrumentation profile: Instrumentation level: Front-end" },
        .{ .st = .{ .exited = 0 }, .text = "Instrumentation level: IR\nTotal functions: 0\n", .msg = "the merged profile has no function: Instrumentation level: IR Total functions: 0 " },
        .{ .st = .{ .exited = 0 }, .text = "Instrumentation level: IR\n", .msg = "the merged profile has no function" },
        .{ .st = .{ .exited = 0 }, .text = "Instrumentation level: IR\nTotal functions: 1\nTotal functions: 2\n", .msg = "the merged profile has no function" },
    };
    for (cases) |cs| {
        var c = try Case.init();
        defer c.deinit();
        var fake = Fake.init();
        const b = good();
        fake.raw_bytes = &b;
        fake.show_status = cs.st;
        fake.show_text = cs.text;
        try testing.expectEqual(@as(u8, 1), try c.go(&fake));
        try c.has(cs.msg);
    }
}

test "a program that cannot start is exit 2, naming it" {
    for ([_][]const u8{ "test", "merge", "show" }) |step| {
        var c = try Case.init();
        defer c.deinit();
        var fake = Fake.init();
        const b = good();
        fake.raw_bytes = &b;
        fake.fail_start = step;
        try testing.expectEqual(@as(u8, 2), try c.go(&fake));
        const who = c.p(if (std.mem.eql(u8, step, "test")) "bin/test_one" else "llvm/bin/llvm-profdata");
        try c.has(try std.fmt.allocPrint(c.a(), "cov_branch run: cannot run {s}: ForkFailed", .{who}));
    }
}

test "an llvm-profdata that is not there is a usage error, before the test runs" {
    var c = try Case.init();
    defer c.deinit();
    try c.tmp.dir.deleteFile("llvm/bin/llvm-profdata");
    var fake = Fake.init();
    try testing.expectEqual(@as(u8, 2), try c.go(&fake));
    try c.has(try std.fmt.allocPrint(c.a(), "cov_branch run: {s} is missing", .{c.p("llvm/bin/llvm-profdata")}));
    try testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "usage errors: a missing, repeated, empty, unknown or valueless flag, a bad version, a bad --env" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const full = [_][]const u8{ "--compiler", "c", "--share", "s", "--label", "l", "--profdata", "p", "--raw-version", "11", "--binary", "b", "--out", "o" };
    var i: usize = 0;
    while (i < full.len) : (i += 2) {
        var v = std.ArrayList([]const u8).empty;
        try v.appendSlice(a, full[0..i]);
        try v.appendSlice(a, full[i + 2 ..]);
        try testing.expect((try r.parseArgs(a, v.items, &why)) == null);
        try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s} is missing", .{full[i]}), why);
    }
    const cases = [_]struct { argv: []const []const u8, why: []const u8 }{
        .{ .argv = &(full ++ [_][]const u8{ "--out", "p" }), .why = "--out given twice" },
        .{ .argv = &(full ++ [_][]const u8{ "--gate", "g" }), .why = "unknown argument --gate" },
        .{ .argv = &(full ++ [_][]const u8{"--env"}), .why = "unknown argument --env" },
        .{ .argv = &(full ++ [_][]const u8{ "--env", "NOEQUALS" }), .why = "--env 'NOEQUALS' is not NAME=VALUE" },
        .{ .argv = &(full ++ [_][]const u8{ "--env", "=v" }), .why = "--env '=v' is not NAME=VALUE" },
        .{ .argv = &(full ++ [_][]const u8{ "--env", "LLVM_PROFILE_FILE=/x" }), .why = "--env LLVM_PROFILE_FILE: a branch coverage run sets it itself (where the test's profile is written)" },
        .{ .argv = &([_][]const u8{ "--compiler", "c", "--share", "s", "--label", "l", "--profdata", "p", "--raw-version", "0", "--binary", "b", "--out", "o" }), .why = "--raw-version is '0', not a version" },
        .{ .argv = &([_][]const u8{ "--compiler", "c", "--share", "s", "--label", "l", "--profdata", "p", "--raw-version", "011", "--binary", "b", "--out", "o" }), .why = "--raw-version is '011', not a version" },
        .{ .argv = &([_][]const u8{ "--compiler", "c", "--share", "s", "--label", "l", "--profdata", "p", "--raw-version", "1x", "--binary", "b", "--out", "o" }), .why = "--raw-version is '1x', not a version" },
        .{ .argv = &([_][]const u8{ "--compiler", "c", "--share", "s", "--label", "l", "--profdata", "p", "--raw-version", "99999999999", "--binary", "b", "--out", "o" }), .why = "--raw-version is '99999999999', not a version" },
        .{ .argv = &([_][]const u8{ "--compiler", "c", "--share", "s", "--label", "l", "--profdata", "p", "--raw-version", "", "--binary", "b", "--out", "o" }), .why = "--raw-version is empty" },
    };
    for (cases) |cs| {
        try testing.expect((try r.parseArgs(a, cs.argv, &why)) == null);
        try testing.expectEqualStrings(cs.why, why);
    }
    const ok = (try r.parseArgs(a, &(full ++ [_][]const u8{ "--env", "A=1", "--env", "B=" }), &why)).?;
    try testing.expectEqual(@as(u32, 11), ok.raw_version);
    try testing.expectEqual(@as(usize, 2), ok.env.len);
    try testing.expectEqualStrings("B=", ok.env[1]);
    // Through cli: the message and the usage line, exit 2, nothing run.
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    try testing.expectEqual(@as(u8, 2), try r.cli(c.a(), &.{ "--share", "s" }, c.where(), fake.runner(), &c.err));
    try c.has("cov_branch run: usage error: --compiler is missing\n" ++ r.USAGE ++ "\n");
    try testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "headJoined: the first N lines, each that ended in a newline followed by a space; a last line without a newline is kept as it is" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("", try r.headJoined(a, "", 3));
    try testing.expectEqualStrings("a b ", try r.headJoined(a, "a\nb\nc\n", 2));
    try testing.expectEqualStrings("a b", try r.headJoined(a, "a\nb", 3));
    try testing.expectEqualStrings("a ", try r.headJoined(a, "a\n", 3));
}
