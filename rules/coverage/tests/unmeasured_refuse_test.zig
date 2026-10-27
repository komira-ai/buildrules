//! `cov_summary --unmeasured` as the process the public target hands out (its path in the environment as COV_SUMMARY, the zig_test's `env_tools`), over files the
//! test writes: the sentence a person is shown for each entry the file may not hold, and the output for one it may. The first case is the control: a listed
//! source in no report is accepted, listed with its reason and out of the totals, so a tool that refuses every file is red; the last holds that without the file the
//! same source is refused as it always was.

const std = @import("std");
const proc = @import("refusal_proc");

const REPORT =
    \\<coverage>
    \\<class name="a" filename="pkg/src/p/a.mojo">
    \\<line number="1" hits="1"/>
    \\<line number="2" hits="0"/>
    \\</class>
    \\<class name="t" filename="pkg/tests/test_a.mojo">
    \\<line number="1" hits="1"/>
    \\</class>
    \\</coverage>
    \\
;

const CODE = "def f(x: Int) -> Int:\n    return x + 1\n";
const INLINED = "@always_inline(\"nodebug\")\ndef g(x: Int) -> Int:\n    return x\n";
const EXPECT = [_][]const u8{ "--expect", "pkg/src/p/a.mojo", "--expect", "pkg/src/p/b.mojo", "--src", "pkg/src/p/a.mojo=a.mojo", "--src", "pkg/src/p/b.mojo=b.mojo", "--src", "pkg/tests/test_a.mojo=test_a.mojo" };

fn run(a: std.mem.Allocator, tmp: *std.testing.TmpDir, list: ?[]const u8, b_source: []const u8) !proc.Run {
    try tmp.dir.writeFile(.{ .sub_path = "report.xml", .data = REPORT });
    try tmp.dir.writeFile(.{ .sub_path = "a.mojo", .data = CODE });
    try tmp.dir.writeFile(.{ .sub_path = "b.mojo", .data = b_source });
    try tmp.dir.writeFile(.{ .sub_path = "test_a.mojo", .data = "from p import f\n\ndef main():\n    _ = f(1)\n" });
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(a, try proc.tool(a, "COV_SUMMARY"));
    try argv.appendSlice(a, &.{ "--out", "coverage.txt" });
    try argv.appendSlice(a, &EXPECT);
    if (list) |l| {
        try tmp.dir.writeFile(.{ .sub_path = "coverage_unmeasured.txt", .data = l });
        try argv.appendSlice(a, &.{ "--unmeasured", "pkg=coverage_unmeasured.txt" });
    }
    try argv.append(a, "report.xml");
    return proc.run(a, tmp.dir, argv.items);
}

fn refused(name: []const u8, list: []const u8, b_source: []const u8, msg: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try proc.expectRefusal(name, try run(a, &tmp, list, b_source), 1, &.{msg});
    // A refusal writes nothing: no figure is left behind to be read as a pass.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("coverage.txt", .{}));
}

test "a listed source in no report is accepted, listed with its reason, and counted in no total" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try proc.expectOk("a listed source", try run(a, &tmp, "# kcov records no line of b\nsrc/p/b.mojo\tevery function is always_inline nodebug\n", INLINED));
    try std.testing.expectEqualStrings(
        "pkg/src/p/a.mojo 1/2 50%\npkg/tests/test_a.mojo 1/1 100% (not counted)\ntotal 1/2 50%\n" ++
            "unmeasured: pkg/src/p/b.mojo: every function is always_inline nodebug\nunmeasured total 1 files: left out of the line and branch totals and the floors\n",
        try tmp.dir.readFileAlloc(a, "coverage.txt", 1 << 16),
    );
}

test "a file that lists nothing leaves the unlisted source refused, and no file at all is as it was" {
    try refused("an empty list", "# nothing\n", INLINED, "cov_summary: pkg/src/p/b.mojo is in no report: no test compiled it, or kcov could not open it");
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try proc.expectRefusal("no list", try run(a, &tmp, null, INLINED), 1, &.{"cov_summary: pkg/src/p/b.mojo is in no report: no test compiled it, or kcov could not open it"});
}

test "an entry for a source a report names is refused as stale" {
    try refused("stale", "src/p/a.mojo\tinlined\n", CODE, "cov_summary: coverage_unmeasured.txt: src/p/a.mojo listed as unmeasured but measured: remove the entry");
}

test "an entry for a file that is not there, a test, or another file is refused" {
    try refused("missing", "src/p/gone.mojo\twhy\n", INLINED, "coverage_unmeasured.txt: src/p/gone.mojo is not a library source of the package");
    try refused("a test", "tests/test_a.mojo\twhy\n", INLINED, "coverage_unmeasured.txt: tests/test_a.mojo is not a library source of the package");
}

test "a path listed twice and an entry without a reason are refused" {
    try refused("duplicate", "src/p/b.mojo\tone\nsrc/p/b.mojo\ttwo\n", INLINED, "coverage_unmeasured.txt:2: src/p/b.mojo is listed twice");
    try refused("no reason", "src/p/b.mojo\n", INLINED, "coverage_unmeasured.txt:1: `src/p/b.mojo` has no reason");
    try refused("blank reason", "src/p/b.mojo\t  \n", INLINED, "coverage_unmeasured.txt:1: `src/p/b.mojo` has no reason");
}

test "an entry for a source with no statement is refused: it is listed 0/0 already" {
    try refused("a re-export", "src/p/b.mojo\twhy\n", "from .a import f\n", "coverage_unmeasured.txt: src/p/b.mojo has no statement");
}

test "--unmeasured wants a directory and a file" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "report.xml", .data = REPORT });
    try proc.expectRefusal("no equals", try proc.run(a, tmp.dir, &.{ try proc.tool(a, "COV_SUMMARY"), "--out", "c.txt", "--unmeasured", "oops", "report.xml" }), 2, &.{"cov_summary: --unmeasured wants <package directory>=<file>, got oops"});
    try proc.expectRefusal("no file", try proc.run(a, tmp.dir, &.{ try proc.tool(a, "COV_SUMMARY"), "--out", "c.txt", "--unmeasured", "pkg=nope.txt", "report.xml" }), 1, &.{"cov_summary: cannot read nope.txt: FileNotFound"});
}
