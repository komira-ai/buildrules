//! The shipped cov_branch executable's `run` as a process: `zig test` of this file, run as a build action by `:cov_branch_run_exe_test`,
//! a validation of `:cov_branch_tool`. The cases in cov_branch_run_test.zig call the subcommand in-process with stand-in steps; these run
//! the executable the public target hands out (its path in the environment as COV_BRANCH, the `zig_test`'s `env_tools`) as a child, with
//! an environment built here, over a stand-in test binary and llvm-profdata (cov_branch_run_stub.zig, its path as COV_BRANCH_RUN_STUB;
//! each a symbolic link to it that records its arguments, environment and working directory), and check what only a process shows: the
//! command line taken from argv, the working directory the test starts in, the scratch directory taken from BUCK_SCRATCH_PATH, the exact
//! environment of the test (what this tool was given is not passed on) and of llvm-profdata, the profile file the test writes (the
//! process id in its name), the test's own exit status, messages on stderr and none on stdout. Without COV_BRANCH or COV_BRANCH_RUN_STUB
//! every case fails: none passes without running the executable.

const std = @import("std");
const testing = std.testing;

fn tool(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, name) catch {
        std.debug.print("the test target does not pass {s} (env_tools), so the executable cannot be run\n", .{name});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

const SHOW_OK = "Instrumentation level: IR  entry_first = 0\nTotal functions: 1\n";

const Run = struct {
    code: u8,
    stdout: []const u8,
    stderr: []const u8,
};

const Box = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8 = "",

    /// What a run action is given: the stand-ins bin/test_one and llvm/bin/llvm-profdata, the compiler's directory and the tree the test
    /// runs in. The test writes a raw profile that passes every check; llvm-profdata merges and shows an IR profile of one function.
    fn init() !Box {
        var b = Box{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .tmp = testing.tmpDir(.{}) };
        const al = b.arena.allocator();
        b.root = try b.tmp.dir.realpathAlloc(al, ".");
        const stub = try tool(al, "COV_BRANCH_RUN_STUB");
        for ([_][]const u8{ "bin/test_one", "llvm/bin/llvm-profdata" }) |s| {
            try b.tmp.dir.makePath(std.fs.path.dirname(s).?);
            try b.tmp.dir.symLink(stub, s, .{});
        }
        try b.put("tc/lib/libKGENCompilerRTShared.so", "so");
        try b.put("share/tests/test_one.mojo", "def main(): pass\n");
        var raw: [16]u8 = undefined;
        std.mem.writeInt(u64, raw[0..8], 0xff6c70726f667281, .little);
        std.mem.writeInt(u32, raw[8..12], 11, .little);
        std.mem.writeInt(u32, raw[12..16], 0x01000000, .little);
        try b.put("bin/raw", &raw);
        try b.put("llvm/bin/merged", "indexed");
        try b.put("llvm/bin/show", SHOW_OK);
        return b;
    }

    fn deinit(self: *Box) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn a(self: *Box) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn put(self: *Box, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |d| try self.tmp.dir.makePath(d);
        try self.tmp.dir.writeFile(.{ .sub_path = path, .data = data });
    }

    fn p(self: *Box, rel: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a(), "{s}/{s}", .{ self.root, rel }) catch unreachable;
    }

    fn read(self: *Box, rel: []const u8) ?[]const u8 {
        return self.tmp.dir.readFileAlloc(self.a(), rel, 1 << 20) catch null;
    }

    fn exists(self: *Box, rel: []const u8) bool {
        self.tmp.dir.access(rel, .{}) catch return false;
        return true;
    }

    /// `cov_branch run` with the box's inputs, relative to the box, as the rule gives them, then `extra`.
    fn runArgs(self: *Box, extra: []const []const u8) ![]const []const u8 {
        const al = self.arena.allocator();
        var v = std.ArrayList([]const u8).empty;
        try v.appendSlice(al, &.{ "run", "--compiler", "tc", "--share", "share", "--label", "//pkg:test_one", "--profdata", "llvm/bin/llvm-profdata", "--raw-version", "11", "--binary", "bin/test_one", "--out", "out/test_one.profdata" });
        try v.appendSlice(al, extra);
        return v.toOwnedSlice(al);
    }

    /// Runs the shipped executable in the box with `args` and the environment `env` (NAME, VALUE pairs; nothing else is inherited).
    fn run(self: *Box, args: []const []const u8, env: []const [2][]const u8) !Run {
        const al = self.a();
        try self.tmp.dir.makePath("out");
        var argv = std.ArrayList([]const u8).empty;
        try argv.append(al, try tool(al, "COV_BRANCH"));
        try argv.appendSlice(al, args);
        var map = std.process.EnvMap.init(al);
        for (env) |e| try map.put(e[0], e[1]);
        const r = try std.process.Child.run(.{ .allocator = al, .argv = argv.items, .cwd_dir = self.tmp.dir, .env_map = &map, .max_output_bytes = 1 << 20 });
        const code: u8 = switch (r.term) {
            .Exited => |c| c,
            else => {
                std.debug.print("cov_branch did not exit: {any}; stderr:\n{s}\n", .{ r.term, r.stderr });
                return error.TestUnexpectedResult;
            },
        };
        return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
    }
};

const ENV = [_][2][]const u8{ .{ "BUCK_SCRATCH_PATH", "scr" }, .{ "FOO", "bar" }, .{ "LC_ALL", "fr_FR.UTF-8" }, .{ "PATH", "/usr/bin" } };

fn expect(name: []const u8, r: Run, code: u8, msg: []const u8) !void {
    if (r.code != code or std.mem.indexOf(u8, r.stderr, msg) == null or r.stdout.len != 0) {
        std.debug.print("{s}: exit {d}, want {d} with '{s}' on stderr and nothing on stdout; stdout:\n{s}\nstderr:\n{s}\n", .{ name, r.code, code, msg, r.stdout, r.stderr });
        return error.TestUnexpectedResult;
    }
}

fn lines(text: ?[]const u8) []const u8 {
    return text orelse "(no file)";
}

fn hasLine(text: ?[]const u8, line: []const u8) !void {
    var it = std.mem.splitScalar(u8, text orelse "", '\n');
    while (it.next()) |l| if (std.mem.eql(u8, l, line)) return;
    std.debug.print("no line '{s}' in:\n{s}\n", .{ line, lines(text) });
    return error.TestUnexpectedResult;
}

test "a run as a process: argv, BUCK_SCRATCH_PATH, the test's working directory and exact environment, the profile merged, silence, exit 0" {
    var b = try Box.init();
    defer b.deinit();
    const r = try b.run(try b.runArgs(&.{ "--env", "A=1" }), &ENV);
    try expect("run", r, 0, "");
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqualStrings("indexed", b.read("out/test_one.profdata").?);
    try testing.expect(!b.exists("scr/cov_branch_run"));

    // The test starts in the tree of its sources and gets exactly the environment of a coverage run: nothing of this tool's own.
    try testing.expectEqualStrings(b.p("share"), b.read("bin/cwd").?);
    const env = b.read("bin/env").?;
    const k = b.p("scr/cov_branch_run");
    try testing.expectEqualStrings(try std.fmt.allocPrint(b.a(), "PATH=/usr/bin:/bin\nLD_LIBRARY_PATH={s}/lib\nA=1\nLLVM_PROFILE_FILE={s}/prof/%p.profraw\n", .{ b.p("tc"), k }), env);
    try testing.expectEqualStrings("", b.read("bin/argv").?);

    // llvm-profdata: merge of the one profile the test wrote (the process id in its name), then show; LC_ALL=C alone.
    const merge_argv = b.read("llvm/bin/argv").?;
    // The last call (show) wrote it; the merge's is gone, so check the environment and show's line.
    try hasLine(merge_argv, "show");
    try hasLine(merge_argv, b.p("out/test_one.profdata"));
    try testing.expectEqualStrings("LC_ALL=C\n", b.read("llvm/bin/env").?);
}

test "the scratch directory: .cov_branch_run without BUCK_SCRATCH_PATH, an absolute one as given" {
    for ([_]?[]const u8{ null, "elsewhere" }) |where| {
        var b = try Box.init();
        defer b.deinit();
        const env: []const [2][]const u8 = if (where) |w| &.{.{ "BUCK_SCRATCH_PATH", b.p(w) }} else &.{};
        const r = try b.run(try b.runArgs(&.{}), env);
        try expect("scratch", r, 0, "");
        const k = if (where) |w| b.p(try std.fmt.allocPrint(b.a(), "{s}/cov_branch_run", .{w})) else b.p(".cov_branch_run");
        try hasLine(b.read("bin/env"), try std.fmt.allocPrint(b.a(), "LLVM_PROFILE_FILE={s}/prof/%p.profraw", .{k}));
    }
}

test "the profile file is written where LLVM_PROFILE_FILE says, one per process id, and merged" {
    var b = try Box.init();
    defer b.deinit();
    // The merge fails here, with its log, so the scratch directory is kept and holds the profile the stand-in test wrote.
    try b.put("llvm/bin/stub_rc", "1");
    try b.put("llvm/bin/say", "merging");
    const r = try b.run(try b.runArgs(&.{}), &ENV);
    try expect("merge fails", r, 1, "BRANCH COVERAGE RUN FAILED: //pkg:test_one\nllvm-profdata merge failed on 1 raw profile(s): stdout: merging stderr: merging ");
    var dir = try b.tmp.dir.openDir("scr/cov_branch_run/prof", .{ .iterate = true });
    defer dir.close();
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |e| {
        try testing.expect(std.mem.endsWith(u8, e.name, ".profraw"));
        try testing.expect(std.mem.indexOfScalar(u8, e.name, '%') == null);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 1), n);
}

test "a test that fails: its exit status is the action's, with the label and the reason; nothing is merged" {
    var b = try Box.init();
    defer b.deinit();
    try b.put("bin/stub_rc", "3");
    const r = try b.run(try b.runArgs(&.{}), &ENV);
    try expect("test fails", r, 3, "BRANCH COVERAGE RUN FAILED: //pkg:test_one\nThe test failed instrumented for branch coverage (exit 3).");
    try testing.expect(!b.exists("llvm/bin/argv"));
    try testing.expect(!b.exists("out/test_one.profdata"));
}

test "a test that writes no profile, a profile of another version, an IR flag missing: exit 1, each named" {
    {
        var b = try Box.init();
        defer b.deinit();
        try b.tmp.dir.deleteFile("bin/raw");
        const r = try b.run(try b.runArgs(&.{}), &ENV);
        try expect("no profile", r, 1, "The test passed but wrote no .profraw under ");
    }
    {
        var b = try Box.init();
        defer b.deinit();
        var raw: [16]u8 = undefined;
        std.mem.writeInt(u64, raw[0..8], 0xff6c70726f667281, .little);
        std.mem.writeInt(u32, raw[8..12], 12, .little);
        std.mem.writeInt(u32, raw[12..16], 0x01000000, .little);
        try b.put("bin/raw", &raw);
        const r = try b.run(try b.runArgs(&.{}), &ENV);
        try expect("version", r, 1, ".profraw has raw profile version 12, not 11");
    }
    {
        var b = try Box.init();
        defer b.deinit();
        var raw: [16]u8 = undefined;
        std.mem.writeInt(u64, raw[0..8], 0xff6c70726f667281, .little);
        std.mem.writeInt(u32, raw[8..12], 11, .little);
        std.mem.writeInt(u32, raw[12..16], 0, .little);
        try b.put("bin/raw", &raw);
        const r = try b.run(try b.runArgs(&.{}), &ENV);
        try expect("flags", r, 1, ".profraw has variant flags 0x00000000, without the IR-instrumentation bit");
    }
}

test "a profile that is not an IR profile of a function: exit 1" {
    var b = try Box.init();
    defer b.deinit();
    try b.put("llvm/bin/show", "Instrumentation level: Front-end\nTotal functions: 1\n");
    const r = try b.run(try b.runArgs(&.{}), &ENV);
    try expect("front-end", r, 1, "the merged profile is not an IR-instrumentation profile: Instrumentation level: Front-end");
}

test "usage errors and a missing llvm-profdata: exit 2, the test never runs" {
    var b = try Box.init();
    defer b.deinit();
    try expect("no flags", try b.run(&.{"run"}, &ENV), 2, "cov_branch run: usage error: --compiler is missing");
    try expect("LLVM_PROFILE_FILE", try b.run(try b.runArgs(&.{ "--env", "LLVM_PROFILE_FILE=/x" }), &ENV), 2, "cov_branch run: usage error: --env LLVM_PROFILE_FILE");
    try b.tmp.dir.deleteFile("llvm/bin/llvm-profdata");
    try expect("no profdata", try b.run(try b.runArgs(&.{}), &ENV), 2, "cov_branch run: llvm/bin/llvm-profdata is missing");
    try testing.expect(!b.exists("bin/argv"));
}

/// The installed layout a failed run left in `scr/cov_branch_run`: `<dir>/root`, as a path relative to the box. Exactly one run's directory is there.
fn installedRoot(b: *Box) ![]const u8 {
    var dir = try b.tmp.dir.openDir("scr/cov_branch_run", .{ .iterate = true });
    defer dir.close();
    var found: ?[]const u8 = null;
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (!std.mem.startsWith(u8, e.name, "buildrules_test.")) continue;
        try testing.expect(found == null);
        found = try std.fmt.allocPrint(b.a(), "scr/cov_branch_run/{s}/root", .{e.name});
    }
    return found orelse error.TestUnexpectedResult;
}

fn sub(b: *Box, root: []const u8, rel: []const u8) []const u8 {
    return std.fmt.allocPrint(b.a(), "{s}/{s}", .{ root, rel }) catch unreachable;
}

test "an installed run as a process: the test is the copy at <root>/bin, started in <root>, with its sources, its data in <root>/share, and private scratch directories" {
    var b = try Box.init();
    defer b.deinit();
    try b.put("data/golden/greeting.txt", "hello");
    // The stand-in test exits 3 so the layout it ran in is kept in the scratch directory to be read back.
    try b.put("bin/stub_rc", "3");
    const r = try b.run(try b.runArgs(&.{ "--installed", "--data", "data", "--data-env", "BUILDRULES_TEST_DATA", "--env", "A=1" }), &ENV);
    try expect("installed", r, 3, "BRANCH COVERAGE RUN FAILED: //pkg:test_one\nThe test failed instrumented for branch coverage (exit 3).");
    const root = try installedRoot(&b);
    const real = b.p(root);

    // It ran as the installed copy: its working directory is the root, which holds the sources, the data under share/, and the binary under bin/.
    try testing.expectEqualStrings(real, b.read(sub(&b, root, "bin/cwd")).?);
    try testing.expectEqualStrings("def main(): pass\n", b.read(sub(&b, root, "tests/test_one.mojo")).?);
    try testing.expectEqualStrings("hello", b.read(sub(&b, root, "share/golden/greeting.txt")).?);
    try testing.expect(b.exists(sub(&b, root, "bin/test_one")));
    try testing.expectEqualStrings("", b.read(sub(&b, root, "bin/argv")).?);

    // Its environment: exactly the default layout's, the data variable naming the root's share/, and the run's private directories.
    const env = b.read(sub(&b, root, "bin/env")).?;
    const dir = std.fs.path.dirname(real).?;
    try testing.expectEqualStrings(try std.fmt.allocPrint(b.a(), "PATH=/usr/bin:/bin\nLD_LIBRARY_PATH={s}/lib\nA=1\nBUILDRULES_TEST_DATA={s}/share\nTMPDIR={s}/tmp\nTEST_TMPDIR={s}/tmp\nHOME={s}/home\nLLVM_PROFILE_FILE={s}/prof/%p.profraw\n", .{ b.p("tc"), real, dir, dir, dir, b.p("scr/cov_branch_run") }), env);

    // The tree and the binary it was made from were not touched, and the private directories were empty when the test began.
    try testing.expect(!b.exists("share/bin"));
    try testing.expect(!b.exists("share/share"));
    try testing.expect(!b.exists("bin/cwd"));
    try b.tmp.dir.access(sub(&b, std.fs.path.dirname(root).?, "tmp"), .{});
    try b.tmp.dir.access(sub(&b, std.fs.path.dirname(root).?, "home"), .{});
}

test "an installed run that passes: exit 0, the profile merged, silence, and the whole layout taken away with the scratch directory" {
    var b = try Box.init();
    defer b.deinit();
    try b.put("data/golden/greeting.txt", "hello");
    const r = try b.run(try b.runArgs(&.{ "--installed", "--data", "data", "--data-env", "BUILDRULES_TEST_DATA" }), &ENV);
    try expect("installed passes", r, 0, "");
    try testing.expectEqualStrings("", r.stderr);
    try testing.expectEqualStrings("indexed", b.read("out/test_one.profdata").?);
    try testing.expect(!b.exists("scr/cov_branch_run"));
}

test "an installed run of a tree that holds a bin: exit 1 from the tool, the test never starts" {
    var b = try Box.init();
    defer b.deinit();
    try b.put("share/bin/f", "x");
    const r = try b.run(try b.runArgs(&.{"--installed"}), &ENV);
    try expect("tree holds bin", r, 1, "cov_branch run: cannot stage the run in ");
    try testing.expect(!b.exists("bin/cwd"));
}
