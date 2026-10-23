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
        .{ .name = "a branch figure the tests lost", .coverage = COV, .floor = "lines 95.00\nbranches 60.00\n", .msgs = &.{ "the floor file has a `branches` figure and the tests record no branches: the instrumentation was dropped" } },
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
        try proc.expectRefusal("no arguments", try summaryRun(a, &tmp, null, &.{}), 2, &.{"usage: cov_summary --out <file> [--expect <path>]... [--blocks <file>]... <report.xml>..."});
        try proc.expectRefusal("an unknown option", try summaryRun(a, &tmp, REPORT, &.{ "--bogus", "report.xml" }), 2, &.{"cov_summary: unknown option --bogus"});
    }
}
