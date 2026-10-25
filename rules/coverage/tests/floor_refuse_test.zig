//! The refusals of the coverage tools as a user meets them: `zig test` of this file, run as a build action by `:coverage_tools_refuse`. cov_floor and cov_summary are
//! run as the processes the public targets hand out (their paths in the environment as COV_FLOOR and COV_SUMMARY, the zig_test's `env_tools`), over files the test
//! writes, and each case holds the exit status and the message on stderr to what the tool must say. The cases in cov_floor_test.zig and cov_summary_test.zig call the
//! parsers in-process and read error codes; these read the sentence a person is shown, which says what to write instead.
//!
//! The first case is the control: a floor the coverage meets is accepted, so a tool that refuses everything is red.

const std = @import("std");
const proc = @import("refusal_proc");

/// A coverage.txt of cov_summary: the line total and, when given, the branch total.
const COV = "total 95/100 95%\n";
const COV_BRANCHES = "total 95/100 95%\nbranches total 60/100 60%\n";
/// A package with code and no decision (a re-export, a table): its branch rows are all 0/0.
const COV_NO_DECISIONS = "total 95/100 95%\nbranches rules/pkg/a.zig 0/0 0%\nbranches total 0/0 0%\n";

const Case = struct { name: []const u8, coverage: ?[]const u8 = COV, floor: ?[]const u8, code: u8, msgs: []const []const u8 };

fn floorRun(a: std.mem.Allocator, tmp: *std.testing.TmpDir, coverage: ?[]const u8, floor: ?[]const u8, extra: []const []const u8) !proc.Run {
    if (coverage) |c| try tmp.dir.writeFile(.{ .sub_path = "coverage.txt", .data = c });
    if (floor) |f| try tmp.dir.writeFile(.{ .sub_path = "coverage_floor.txt", .data = f });
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(a, try proc.tool(a, "COV_FLOOR"));
    try argv.appendSlice(a, &.{ "--coverage", "coverage.txt", "--floor", "coverage_floor.txt", "--label", "rules/pkg", "--out", "report.txt" });
    try argv.appendSlice(a, extra);
    return proc.run(a, tmp.dir, argv.items);
}

test "a floor the coverage meets is accepted, and the report says what the 99% target still needs" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try proc.expectOk("held", try floorRun(a, &tmp, COV, "lines 95.00\n", &.{}));
    const report = try tmp.dir.readFileAlloc(a, "report.txt", 1 << 16);
    try std.testing.expect(std.mem.indexOf(u8, report, "rules/pkg lines 95.00% (95/100); 4 more to 99%") != null);
}

test "a lines floor holds a package whose code has no decision" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try proc.expectOk("held", try floorRun(a, &tmp, COV_NO_DECISIONS, "lines 95.00\n", &.{}));
    const report = try tmp.dir.readFileAlloc(a, "report.txt", 1 << 16);
    try std.testing.expect(std.mem.indexOf(u8, report, "rules/pkg lines 95.00% (95/100); 4 more to 99%") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "branches") == null);
}

test "a floor below the coverage is accepted with a hint, in the report and on stderr; at the coverage, with none" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const run = try floorRun(a, &tmp, COV_BRANCHES, "lines 90.00\nbranches 60.00\n", &.{});
        try proc.expectOk("floor lags the tests", run);
        try std.testing.expect(std.mem.indexOf(u8, run.stderr, "rules/pkg: line coverage is 95.00% (95/100), above its floor 90.00%: you may raise the floor to 95.00") != null);
        const report = try tmp.dir.readFileAlloc(a, "report.txt", 1 << 16);
        try std.testing.expect(std.mem.indexOf(u8, report, "rules/pkg: line coverage is 95.00% (95/100), above its floor 90.00%: you may raise the floor to 95.00") != null);
        try std.testing.expect(std.mem.indexOf(u8, report, "branch coverage is 60.00%") == null);
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try proc.expectOk("floor equals the tests", try floorRun(a, &tmp, COV_BRANCHES, "lines 95.00\nbranches 60.00\n", &.{}));
        const report = try tmp.dir.readFileAlloc(a, "report.txt", 1 << 16);
        try std.testing.expect(std.mem.indexOf(u8, report, "you may raise") == null);
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try proc.expectOk("branches floor lags", try floorRun(a, &tmp, COV_BRANCHES, "lines 95.00\nbranches 50.00\n", &.{}));
        const report = try tmp.dir.readFileAlloc(a, "report.txt", 1 << 16);
        try std.testing.expect(std.mem.indexOf(u8, report, "branch coverage is 60.00% (60/100), above its floor 50.00%: you may raise the floor to 60.00") != null);
    }
}

test "a floor file that is malformed is refused with the shape it must have" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shape = [_][]const u8{ "cov_floor: ", "coverage_floor.txt: expected `lines NN.NN` and optionally `branches NN.NN` (two decimals, 0.00 to 100.00), one per line" };
    const bad = [_]struct { name: []const u8, floor: []const u8 }{
        .{ .name = "empty file", .floor = "" },
        .{ .name = "comments only", .floor = "# lines 95.00\n" },
        .{ .name = "one decimal", .floor = "lines 95.0\n" },
        .{ .name = "three decimals", .floor = "lines 95.000\n" },
        .{ .name = "no decimals", .floor = "lines 95\n" },
        .{ .name = "a percent sign", .floor = "lines 95.00%\n" },
        .{ .name = "above 100", .floor = "lines 100.01\n" },
        .{ .name = "a sign", .floor = "lines +95.00\n" },
        .{ .name = "a figure with no value", .floor = "lines\n" },
        .{ .name = "an unknown key", .floor = "lines 95.00\nfunctions 80.00\n" },
        .{ .name = "a line figure given twice", .floor = "lines 95.00\nlines 96.00\n" },
        .{ .name = "branches without lines", .floor = "branches 60.00\n" },
        .{ .name = "a slack of zero", .floor = "lines 95.00 slack 0.00\n" },
        .{ .name = "a slack with no value", .floor = "lines 95.00 slack\n" },
        .{ .name = "a word after the figure that is not slack", .floor = "lines 95.00 about\n" },
        .{ .name = "text after the slack", .floor = "lines 95.00 slack 1.00 more\n" },
    };
    for (bad) |c| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try proc.expectRefusal(c.name, try floorRun(a, &tmp, COV, c.floor, &.{}), 1, &shape);
        // nothing is reported for a floor that could not be read
        try std.testing.expectError(error.FileNotFound, tmp.dir.access("report.txt", .{}));
    }
}

test "a floor above the coverage is refused, with the figures" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Bad = struct { name: []const u8, coverage: []const u8, floor: []const u8, msgs: []const []const u8 };
    const bad = [_]Bad{
        .{ .name = "coverage fell", .coverage = COV, .floor = "lines 96.00\n", .msgs = &.{ "rules/pkg: line coverage is 95.00% (95/100), below its floor 96.00%: coverage fell" } },
        .{ .name = "a branch figure the tests lost", .coverage = COV, .floor = "lines 95.00\nbranches 60.00\n", .msgs = &.{ "the floor file has a `branches` figure and the coverage has no branches to hold (the code has no decision, or the branch instrumentation was dropped)" } },
        .{ .name = "a branches line for code with no decision", .coverage = COV_NO_DECISIONS, .floor = "lines 95.00\nbranches 0.00\n", .msgs = &.{ "the coverage has no branches to hold" } },
        .{ .name = "a branch figure the floor lacks", .coverage = COV_BRANCHES, .floor = "lines 95.00\n", .msgs = &.{ "the floor file has no `branches` figure: add `branches 60.00`" } },
        .{ .name = "branches fell", .coverage = COV_BRANCHES, .floor = "lines 95.00\nbranches 61.00\n", .msgs = &.{ "branch coverage is 60.00% (60/100), below its floor 61.00%: coverage fell" } },
    };
    for (bad) |c| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try proc.expectRefusal(c.name, try floorRun(a, &tmp, c.coverage, c.floor, &.{}), 1, c.msgs);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access("report.txt", .{}));
    }
}

test "coverage that measured nothing, or is not a coverage text, is refused" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const floor = "lines 95.00\n";
    const bad = [_]struct { name: []const u8, coverage: []const u8, msgs: []const []const u8 }{
        .{ .name = "no test measured the package", .coverage = "total 0/0 0%\n", .msgs = &.{"rules/pkg: the coverage counts nothing (0 of 0): no test measured the package"} },
        .{ .name = "no total line", .coverage = "rules/pkg/a.zig 3/4 75%\n", .msgs = &.{ "coverage.txt: no `total` line of the form `total <hit>/<total> <n>%`" } },
        .{ .name = "more hit than recorded", .coverage = "total 101/100 101%\n", .msgs = &.{"no `total` line of the form"} },
        .{ .name = "a total given twice", .coverage = "total 95/100 95%\ntotal 95/100 95%\n", .msgs = &.{"no `total` line of the form"} },
        .{ .name = "an empty file", .coverage = "", .msgs = &.{"no `total` line of the form"} },
    };
    for (bad) |c| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try proc.expectRefusal(c.name, try floorRun(a, &tmp, c.coverage, floor, &.{}), 1, c.msgs);
    }
}

test "a jest summary that is not one is refused" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msg = [_][]const u8{"not a jest coverage-summary.json: no `total` with `lines` and `branches` counts"};
    for ([_][]const u8{ "not json", "{}", "{\"total\":{}}", "{\"total\":{\"lines\":{\"total\":10,\"covered\":11},\"branches\":{\"total\":0,\"covered\":0}}}" }) |text| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "summary.json", .data = text });
        try tmp.dir.writeFile(.{ .sub_path = "coverage_floor.txt", .data = "lines 95.00\n" });
        const argv = [_][]const u8{ try proc.tool(a, "COV_FLOOR"), "--jest-summary", "summary.json", "--floor", "coverage_floor.txt", "--label", "web", "--out", "report.txt" };
        try proc.expectRefusal(text, try proc.run(a, tmp.dir, &argv), 1, &msg);
    }
}

test "a missing input is named, and a bad command line is a usage error" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exe = try proc.tool(a, "COV_FLOOR");
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try proc.expectRefusal("no floor file", try floorRun(a, &tmp, COV, null, &.{}), 1, &.{"cov_floor: cannot read coverage_floor.txt: FileNotFound"});
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try proc.expectRefusal("no coverage file", try floorRun(a, &tmp, null, "lines 95.00\n", &.{}), 1, &.{"cov_floor: cannot read coverage.txt: FileNotFound"});
    }
    const usage = "usage: cov_floor (--coverage <file> | --jest-summary <file>) --floor <file> --label <package> --out <file>";
    const cases = [_]struct { name: []const u8, argv: []const []const u8, msgs: []const []const u8 }{
        .{ .name = "no arguments", .argv = &.{exe}, .msgs = &.{usage} },
        .{ .name = "an unknown option", .argv = &.{ exe, "--bogus", "x" }, .msgs = &.{"cov_floor: unknown option --bogus"} },
        .{ .name = "an option with no value", .argv = &.{ exe, "--floor" }, .msgs = &.{"cov_floor: --floor needs a value"} },
        .{ .name = "both kinds of coverage", .argv = &.{ exe, "--coverage", "c", "--jest-summary", "j", "--floor", "f", "--label", "l", "--out", "o" }, .msgs = &.{usage} },
        .{ .name = "no label", .argv = &.{ exe, "--coverage", "c", "--floor", "f", "--out", "o" }, .msgs = &.{usage} },
        .{ .name = "no output", .argv = &.{ exe, "--coverage", "c", "--floor", "f", "--label", "l" }, .msgs = &.{usage} },
    };
    for (cases) |c| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try proc.expectRefusal(c.name, try proc.run(a, tmp.dir, c.argv), 2, c.msgs);
    }
}

fn summaryRun(a: std.mem.Allocator, tmp: *std.testing.TmpDir, report: ?[]const u8, extra: []const []const u8) !proc.Run {
    if (report) |r| try tmp.dir.writeFile(.{ .sub_path = "report.xml", .data = r });
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(a, try proc.tool(a, "COV_SUMMARY"));
    try argv.appendSlice(a, &.{ "--out", "coverage.txt" });
    try argv.appendSlice(a, extra);
    return proc.run(a, tmp.dir, argv.items);
}

const REPORT =
    \\<coverage>
    \\<class name="a" filename="rules/pkg/a.zig">
    \\<line number="1" hits="1"/>
    \\<line number="2" hits="0"/>
    \\</class>
    \\</coverage>
    \\
;

test "cov_summary: a source no report names is refused, and so is a report that is not one" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try proc.expectOk("a report that names the source", try summaryRun(a, &tmp, REPORT, &.{ "--expect", "rules/pkg/a.zig", "report.xml" }));
    }
    {
        // kcov drops a file it cannot open without an error: a source no test compiled must not read as covered.
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try proc.expectRefusal("a source in no report", try summaryRun(a, &tmp, REPORT, &.{ "--expect", "rules/pkg/b.zig", "report.xml" }), 1, &.{"cov_summary: rules/pkg/b.zig is in no report: no test compiled it, or kcov could not open it"});
        try std.testing.expectError(error.FileNotFound, tmp.dir.access("coverage.txt", .{}));
    }
    {
        // The Mojo report omits a source with no executable line: a re-export file is listed 0/0, and a file with a function the report lacks is refused.
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "init.mojo", .data = "\"\"\"The package.\"\"\"\nfrom .a import f\n" });
        try tmp.dir.writeFile(.{ .sub_path = "real.mojo", .data = "from .a import f\n\nfn g():\n    pass\n" });
        try proc.expectOk("a re-export-only source", try summaryRun(a, &tmp, REPORT, &.{ "--expect", "rules/pkg/a.zig", "--expect", "rules/pkg/__init__.mojo", "--src", "rules/pkg/__init__.mojo=init.mojo", "--src", "rules/pkg/real.mojo=real.mojo", "report.xml" }));
        const text = try tmp.dir.readFileAlloc(a, "coverage.txt", 1 << 16);
        try std.testing.expectEqualStrings("rules/pkg/__init__.mojo 0/0 0%\nrules/pkg/a.zig 1/2 50%\ntotal 1/2 50%\n", text);
        try tmp.dir.deleteFile("coverage.txt");
        try proc.expectRefusal("a source with a function that no report names", try summaryRun(a, &tmp, REPORT, &.{ "--expect", "rules/pkg/real.mojo", "--src", "rules/pkg/real.mojo=real.mojo", "report.xml" }), 1, &.{"cov_summary: rules/pkg/real.mojo is in no report: no test compiled it, or kcov could not open it"});
        try std.testing.expectError(error.FileNotFound, tmp.dir.access("coverage.txt", .{}));
        try proc.expectRefusal("a re-export source with no --src", try summaryRun(a, &tmp, REPORT, &.{ "--expect", "rules/pkg/__init__.mojo", "report.xml" }), 1, &.{"cov_summary: rules/pkg/__init__.mojo is in no report: no test compiled it, or kcov could not open it"});
        try proc.expectRefusal("a --src without a path", try summaryRun(a, &tmp, REPORT, &.{ "--src", "oops", "report.xml" }), 2, &.{"cov_summary: --src wants <expected path>=<file>, got oops"});
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try proc.expectRefusal("a class with no filename", try summaryRun(a, &tmp, "<class name=\"a\">\n", &.{"report.xml"}), 1, &.{"cov_summary: report.xml is not a normalized Cobertura report"});
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try proc.expectRefusal("a report that is not there", try summaryRun(a, &tmp, null, &.{"missing.xml"}), 1, &.{"cov_summary: cannot read missing.xml: FileNotFound"});
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try proc.expectRefusal("a block report that is not one", try summaryRun(a, &tmp, REPORT, &.{ "--blocks", "report.xml", "report.xml" }), 1, &.{"cov_summary: report.xml is not a block report"});
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "blocks", .data = "# blocks v2\nrules/pkg/other.zig\t1\t1\t1\t1\n" });
        try proc.expectRefusal("a source with no block report", try summaryRun(a, &tmp, REPORT, &.{ "--expect", "rules/pkg/a.zig", "--blocks", "blocks", "report.xml" }), 1, &.{"cov_summary: rules/pkg/a.zig is in no block report: no test compiled it with block counters"});
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try proc.expectRefusal("no arguments", try summaryRun(a, &tmp, null, &.{}), 2, &.{"usage: cov_summary --out <file> [--expect <path>]... [--blocks <file>]... [--branch-lcov <file>]... [--src <path>=<file>]... [--uncompiled-lines <file>] [--uncompiled-branches <file>] [--uncompiled-report <file>] <report.xml>..."});
        try proc.expectRefusal("an unknown option", try summaryRun(a, &tmp, REPORT, &.{ "--bogus", "report.xml" }), 2, &.{"cov_summary: unknown option --bogus"});
    }
}

// The branch records of a Mojo package's tests (--branch-lcov), as the process the public target hands out: the rows follow the line rows, an arm is hit when any test took it, a
// source with lines and no record is refused, and so is a record file that is not one or a mix of the two kinds of branch figure.
const RECORDS_ONE =
    \\SF:rules/pkg/a.zig
    \\BRDA:5,9:br:0/1,0,3
    \\BRDA:5,9:br:0/1,1,0
    \\end_of_record
    \\
;

const RECORDS_TWO =
    \\SF:rules/pkg/a.zig
    \\BRDA:5,9:br:0/1,0,0
    \\BRDA:5,9:br:0/1,1,1
    \\end_of_record
    \\
;

test "cov_summary: branch records are summed over the tests, listed after the lines, and a source with lines and none is refused" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        // Each test takes one arm of the one decision: the package has both.
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "one.info", .data = RECORDS_ONE });
        try tmp.dir.writeFile(.{ .sub_path = "two.info", .data = RECORDS_TWO });
        try proc.expectOk("two tests", try summaryRun(a, &tmp, REPORT, &.{ "--expect", "rules/pkg/a.zig", "--branch-lcov", "one.info", "--branch-lcov", "two.info", "report.xml" }));
        try std.testing.expectEqualStrings("rules/pkg/a.zig 1/2 50%\ntotal 1/2 50%\nbranches rules/pkg/a.zig 2/2 100%\nbranches total 2/2 100%\n", try tmp.dir.readFileAlloc(a, "coverage.txt", 1 << 16));
    }
    {
        // One test that took one arm: half.
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "one.info", .data = RECORDS_ONE });
        try proc.expectOk("one test", try summaryRun(a, &tmp, REPORT, &.{ "--expect", "rules/pkg/a.zig", "--branch-lcov", "one.info", "report.xml" }));
        try std.testing.expectEqualStrings("rules/pkg/a.zig 1/2 50%\ntotal 1/2 50%\nbranches rules/pkg/a.zig 1/2 50%\nbranches total 1/2 50%\n", try tmp.dir.readFileAlloc(a, "coverage.txt", 1 << 16));
    }
    {
        // A source the line report names with lines and the records do not.
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "empty.info", .data = "" });
        try proc.expectRefusal("a source with lines and no record", try summaryRun(a, &tmp, REPORT, &.{ "--expect", "rules/pkg/a.zig", "--branch-lcov", "empty.info", "report.xml" }), 1, &.{"cov_summary: rules/pkg/a.zig is in no branch record: its tests ran no code of it, or the classifier found none"});
        try std.testing.expectError(error.FileNotFound, tmp.dir.access("coverage.txt", .{}));
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "bad.info", .data = "SF:rules/pkg/a.zig\nDA:1,1\nend_of_record\n" });
        try proc.expectRefusal("a record file that holds a line record", try summaryRun(a, &tmp, REPORT, &.{ "--branch-lcov", "bad.info", "report.xml" }), 1, &.{"cov_summary: bad.info:2: 'DA' record in a branch record file"});
        try proc.expectRefusal("a record file that is not there", try summaryRun(a, &tmp, REPORT, &.{ "--branch-lcov", "missing.info", "report.xml" }), 1, &.{"cov_summary: cannot read missing.info: FileNotFound"});
        try tmp.dir.writeFile(.{ .sub_path = "blocks", .data = "# blocks v2\nrules/pkg/a.zig\t1\t1\t1\t1\n" });
        try tmp.dir.writeFile(.{ .sub_path = "one.info", .data = RECORDS_ONE });
        try proc.expectRefusal("both kinds of branch figure", try summaryRun(a, &tmp, REPORT, &.{ "--blocks", "blocks", "--branch-lcov", "one.info", "report.xml" }), 2, &.{"cov_summary: --blocks (Zig) and --branch-lcov (Mojo) are two kinds of branch figure: a package has one"});
    }
}

// The code no test compiled (--src with --uncompiled-lines / --uncompiled-branches), as the process the public target hands out: the report names `f` and no
// test compiled `g`, so `g`'s lines and the arms of its `if` are found and not hit, written as the two files a consumer adds to the reports.
const MOJO_REPORT =
    \\<coverage>
    \\<class name="a" filename="rules/pkg/a.mojo">
    \\<line number="1" hits="1"/>
    \\<line number="2" hits="1"/>
    \\</class>
    \\</coverage>
    \\
;

const MOJO_SRC =
    \\def f(x: Int) -> Int:
    \\    return x
    \\
    \\def g(x: Int) -> Int:
    \\    if x > 0:
    \\        return 1
    \\    return 0
    \\
;

test "cov_summary: the functions no test compiled are found and not hit, and written as the extra files" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.mojo", .data = MOJO_SRC });
    try tmp.dir.writeFile(.{ .sub_path = "one.info", .data = "SF:rules/pkg/a.mojo\nend_of_record\n" });
    try proc.expectOk("lines and branches", try summaryRun(a, &tmp, MOJO_REPORT, &.{
        "--expect",           "rules/pkg/a.mojo",
        "--src",              "rules/pkg/a.mojo=a.mojo",
        "--branch-lcov",      "one.info",
        "--uncompiled-lines", "u.xml",
        "--uncompiled-branches", "u.info",
        "--uncompiled-report", "u.txt",
        "report.xml",
    }));
    // `g` is nobody's: nothing is left out, and the listing says so.
    try std.testing.expectEqualStrings("excluded total 0 lines 0 arms\ngated total 0 functions 0 lines 0 arms\n", try tmp.dir.readFileAlloc(a, "u.txt", 1 << 16));
    try std.testing.expectEqualStrings("rules/pkg/a.mojo 2/6 33%\ntotal 2/6 33%\nbranches rules/pkg/a.mojo 0/2 0%\nbranches total 0/2 0%\n", try tmp.dir.readFileAlloc(a, "coverage.txt", 1 << 16));
    const xml = try tmp.dir.readFileAlloc(a, "u.xml", 1 << 16);
    for ([_][]const u8{ "4", "5", "6", "7" }) |n| {
        try std.testing.expect(std.mem.indexOf(u8, xml, try std.fmt.allocPrint(a, "<line number=\"{s}\" hits=\"0\"/>", .{n})) != null);
    }
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, xml, "<line "));
    try std.testing.expectEqualStrings("SF:rules/pkg/a.mojo\nBRDA:5,5:br:0/1,0,-\nBRDA:5,5:br:0/1,1,-\nend_of_record\n", try tmp.dir.readFileAlloc(a, "u.info", 1 << 16));
    // Without branch records the lines alone are added, and the branch file is not written.
    try tmp.dir.deleteFile("coverage.txt");
    try proc.expectOk("lines only", try summaryRun(a, &tmp, MOJO_REPORT, &.{ "--expect", "rules/pkg/a.mojo", "--src", "rules/pkg/a.mojo=a.mojo", "report.xml" }));
    try std.testing.expectEqualStrings("rules/pkg/a.mojo 2/6 33%\ntotal 2/6 33%\n", try tmp.dir.readFileAlloc(a, "coverage.txt", 1 << 16));
}

// The calls that tell the code no test compiled from uncovered code, as the process: `inl` is inlined and a hit line of the library calls it; `via_test` is inlined and
// only a hit line of a test source (given with --src, not expected) calls it; `h` is used only in the dropped arm of `f`. All three are left out, and listed; `f` is
// the compiler's. `never` is `@always_inline` too and nothing calls it: it is counted.
const CALLS_REPORT =
    \\<coverage>
    \\<class name="a" filename="rules/pkg/a.mojo">
    \\<line number="1" hits="1"/>
    \\<line number="4" hits="1"/>
    \\</class>
    \\<class name="t" filename="rules/pkg/t_test.mojo">
    \\<line number="2" hits="1"/>
    \\</class>
    \\</coverage>
    \\
;

const CALLS_SRC =
    \\def f(x: Int) -> Int:
    \\    comptime if D:
    \\        return h(x)
    \\    return inl(x)
    \\
    \\@always_inline
    \\def inl(x: Int) -> Int:
    \\    return x
    \\
    \\def h(x: Int) -> Int:
    \\    return x
    \\
    \\@always_inline
    \\def via_test(x: Int) -> Int:
    \\    return x
    \\
    \\@always_inline
    \\def never(x: Int) -> Int:
    \\    return x
    \\
;

test "cov_summary: a test source given with --src is read for calls, not counted, and what is left out is listed" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.mojo", .data = CALLS_SRC });
    try tmp.dir.writeFile(.{ .sub_path = "t.mojo", .data = "from pkg.a import via_test\nx = via_test(1)\n" });
    try proc.expectOk("calls", try summaryRun(a, &tmp, CALLS_REPORT, &.{
        "--expect",              "rules/pkg/a.mojo",
        "--src",                 "rules/pkg/a.mojo=a.mojo",
        "--src",                 "rules/pkg/t_test.mojo=t.mojo",
        "--uncompiled-lines",    "u.xml",
        "--uncompiled-report",   "u.txt",
        "report.xml",
    }));
    // Of the library: the compiler's 2 lines, hit, and `never`'s 2 lines, found and not hit. The test's line is listed and not counted.
    try std.testing.expectEqualStrings("rules/pkg/a.mojo 2/4 50%\nrules/pkg/t_test.mojo 1/1 100% (not counted)\ntotal 2/4 50%\n", try tmp.dir.readFileAlloc(a, "coverage.txt", 1 << 16));
    try std.testing.expectEqualStrings(
        "excluded rules/pkg/a.mojo 4 lines 0 arms\nexcluded total 4 lines 0 arms\ngated rules/pkg/a.mojo h 10 2 lines\ngated total 1 functions 2 lines 0 arms\n",
        try tmp.dir.readFileAlloc(a, "u.txt", 1 << 16),
    );
    const xml = try tmp.dir.readFileAlloc(a, "u.xml", 1 << 16);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, xml, "<line "));
    for ([_][]const u8{ "18", "19" }) |n| {
        try std.testing.expect(std.mem.indexOf(u8, xml, try std.fmt.allocPrint(a, "<line number=\"{s}\" hits=\"0\"/>", .{n})) != null);
    }
}

test "cov_summary: a source marked @generated is not asked for and not counted" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.mojo", .data = MOJO_SRC });
    try tmp.dir.writeFile(.{ .sub_path = "gen.mojo", .data = "# @generated\ndef h() -> Int:\n    return 1\n" });
    try proc.expectOk("a generated source no report names", try summaryRun(a, &tmp, MOJO_REPORT, &.{
        "--expect", "rules/pkg/a.mojo",
        "--expect", "rules/pkg/gen.mojo",
        "--src",    "rules/pkg/a.mojo=a.mojo",
        "--src",    "rules/pkg/gen.mojo=gen.mojo",
        "report.xml",
    }));
    try std.testing.expectEqualStrings("rules/pkg/a.mojo 2/6 33%\ntotal 2/6 33%\n", try tmp.dir.readFileAlloc(a, "coverage.txt", 1 << 16));
    // the same source without the marker is a source in no report
    try tmp.dir.writeFile(.{ .sub_path = "gen.mojo", .data = "def h() -> Int:\n    return 1\n" });
    try proc.expectRefusal("the same source, not marked", try summaryRun(a, &tmp, MOJO_REPORT, &.{
        "--expect", "rules/pkg/a.mojo",
        "--expect", "rules/pkg/gen.mojo",
        "--src",    "rules/pkg/a.mojo=a.mojo",
        "--src",    "rules/pkg/gen.mojo=gen.mojo",
        "report.xml",
    }), 1, &.{"cov_summary: rules/pkg/gen.mojo is in no report: no test compiled it, or kcov could not open it"});
    // a hand-written file whose first line only mentions the word, or has a near-miss marker, stays counted
    const near_misses = [_][]const u8{
        "# hand-written, not @generated by anything\ndef h() -> Int:\n    return 1\n",
        "#@generated\ndef h() -> Int:\n    return 1\n",
        " # @generated\ndef h() -> Int:\n    return 1\n",
    };
    for (near_misses) |src| {
        try tmp.dir.writeFile(.{ .sub_path = "gen.mojo", .data = src });
        try proc.expectRefusal("a near-miss marker", try summaryRun(a, &tmp, MOJO_REPORT, &.{
            "--expect", "rules/pkg/a.mojo",
            "--expect", "rules/pkg/gen.mojo",
            "--src",    "rules/pkg/a.mojo=a.mojo",
            "--src",    "rules/pkg/gen.mojo=gen.mojo",
            "report.xml",
        }), 1, &.{"cov_summary: rules/pkg/gen.mojo is in no report: no test compiled it, or kcov could not open it"});
    }
}
