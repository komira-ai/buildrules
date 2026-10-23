//! Unit tests of cov_floor.zig: the floor is held both ways, each way named, and a malformed file or a missing figure is refused.
const std = @import("std");
const F = @import("cov_floor.zig");
const t = std.testing;

const SUMMARY =
    \\pkg/a.zig 80/100 80%
    \\pkg/a_test.zig 10/10 100% (not counted)
    \\total 80/100 80%
    \\branches pkg/a.zig 30/50 60%
    \\branches total 30/50 60%
    \\
;

fn arenaCheck(a: std.mem.Allocator, cov: F.Coverage, floor: F.Floor) ![]const []const u8 {
    return F.check(a, "pkg", cov, floor);
}

test "parseCoverage: the line total and the branch total, and nothing else counts" {
    const c = try F.parseCoverage(SUMMARY);
    try t.expectEqual(@as(u64, 80), c.lines.hit);
    try t.expectEqual(@as(u64, 100), c.lines.total);
    try t.expectEqual(@as(u64, 30), c.branches.?.hit);
    try t.expectEqual(@as(u64, 50), c.branches.?.total);
    // No branch total: a package built without the counters.
    const only = try F.parseCoverage("pkg/a.mojo 1/2 50%\ntotal 1/2 50%\n");
    try t.expect(only.branches == null);
}

test "parseCoverage: a branch total of 0/0 is no branch figure, and a lines floor holds such a package" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "pkg/__init__.mojo 0/0 0%\npkg/ops.mojo 4/4 100%\ntotal 4/4 100%\nbranches pkg/ops.mojo 0/0 0%\nbranches total 0/0 0%\n";
    const c = try F.parseCoverage(text);
    try t.expect(c.branches == null);
    const held = try arenaCheck(a, c, try F.parseFloor("lines 100.00\n"));
    try t.expectEqual(@as(usize, 0), held.len);
    // A `branches` line has nothing to hold there, and the message says so.
    const bad = try arenaCheck(a, c, try F.parseFloor("lines 100.00\nbranches 0.00\n"));
    try t.expectEqual(@as(usize, 1), bad.len);
    try t.expect(std.mem.indexOf(u8, bad[0], "has no branches to hold (the code has no decision") != null);
}

test "parseCoverage: malformed text is refused" {
    for ([_][]const u8{
        "",
        "branches total 1/2 50%\n", // no line total
        "total 1/2 50%\ntotal 1/2 50%\n", // twice
        "total 1/2 50%\nbranches total 1/2 50%\nbranches total 1/2 50%\n",
        "total 3/2 150%\n", // more hit than recorded
        "total x/2 50%\n",
        "total 1-2 50%\n",
        "total 1/2\n",
        "total 1/2 50\n",
        "total 1/2 50% extra\n",
    }) |text| {
        try t.expectError(error.BadCoverage, F.parseCoverage(text));
    }
}

test "parseHundredths and parseFloor: two decimals, 0.00 to 100.00" {
    try t.expectEqual(@as(?u64, 8731), F.parseHundredths("87.31"));
    try t.expectEqual(@as(?u64, 0), F.parseHundredths("0.00"));
    try t.expectEqual(@as(?u64, 10000), F.parseHundredths("100.00"));
    try t.expectEqual(@as(?u64, 905), F.parseHundredths("9.05"));
    for ([_][]const u8{ "", "87", "87.3", "87.311", ".31", "100.01", "1000.00", "-1.00", "+1.00", "8_.00", "a.00", "1.0a", "87,31" }) |bad| {
        try t.expectEqual(@as(?u64, null), F.parseHundredths(bad));
    }
    const f = try F.parseFloor("# today's numbers\nlines 87.31  # the tests of 3 files\n\nbranches 61.20\n");
    try t.expectEqual(@as(u64, 8731), f.lines);
    try t.expectEqual(@as(u64, 6120), f.branches.?);
    const g = try F.parseFloor("lines 100.00\n");
    try t.expect(g.branches == null);
}

test "parseFloor: a missing, repeated, unknown or malformed figure is refused" {
    for ([_][]const u8{ "", "branches 61.20\n", "lines 87.31\nlines 87.31\n", "lines 87.31\nblocks 1.00\n", "lines 87\n", "lines\n", "lines 87.31 88.00\n" }) |text| {
        try t.expectError(error.BadFloor, F.parseFloor(text));
    }
}

test "parseFloor: a figure may name the slack above its floor that is not a rise" {
    const f = try F.parseFloor("lines 95.51 slack 1.00\nbranches 15.56\n");
    try t.expectEqual(@as(u64, 9551), f.lines);
    try t.expectEqual(@as(u64, 100), f.lines_slack);
    try t.expectEqual(@as(u64, 0), f.branches_slack);
    const g = try F.parseFloor("lines 95.51\nbranches 15.56 slack 0.25  # a race\n");
    try t.expectEqual(@as(u64, 0), g.lines_slack);
    try t.expectEqual(@as(u64, 25), g.branches_slack);
    for ([_][]const u8{ "lines 95.51 slack\n", "lines 95.51 slack 0.00\n", "lines 95.51 slack 1.00 extra\n", "lines 95.51 margin 1.00\n", "lines 95.51 slack 1\n" }) |text| {
        try t.expectError(error.BadFloor, F.parseFloor(text));
    }
}

test "check: with a slack, at or above the floor passes (the hint waits for the slack to be passed); below the floor fails whatever the slack" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cov = try F.parseCoverage(SUMMARY); // lines 80.00, branches 60.00
    const within = try F.parseFloor("lines 79.50 slack 0.50\nbranches 60.00\n");
    try t.expectEqual(@as(usize, 0), (try arenaCheck(a, cov, within)).len);
    try t.expectEqualStrings("", try F.hints(a, "pkg", cov, within));
    const past = try F.parseFloor("lines 79.00 slack 0.50\nbranches 60.00\n");
    try t.expectEqual(@as(usize, 0), (try arenaCheck(a, cov, past)).len);
    const h = try F.hints(a, "pkg", cov, past);
    try t.expectEqualStrings("pkg: line coverage is 80.00% (80/100), above its floor 79.00%: you may raise the floor to 80.00\n", h);
    const fall = try arenaCheck(a, cov, try F.parseFloor("lines 80.50 slack 1.00\nbranches 60.00\n"));
    try t.expectEqual(@as(usize, 1), fall.len);
    try t.expect(std.mem.indexOf(u8, fall[0], "below its floor 80.50%: coverage fell") != null);
}

test "bp: hit over total, rounded down to a hundredth; 0 of 0 counts nothing" {
    try t.expectEqual(@as(u64, 6666), try F.bp(.{ .hit = 2, .total = 3 }));
    try t.expectEqual(@as(u64, 10000), try F.bp(.{ .hit = 5, .total = 5 }));
    try t.expectEqual(@as(u64, 0), try F.bp(.{ .hit = 0, .total = 5 }));
    try t.expectError(error.Nothing, F.bp(.{ .hit = 0, .total = 0 }));
}

test "check: the floor held is silent" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const bad = try arenaCheck(arena.allocator(), try F.parseCoverage(SUMMARY), try F.parseFloor("lines 80.00\nbranches 60.00\n"));
    try t.expectEqual(@as(usize, 0), bad.len);
}

test "check: coverage below the floor is named, per figure" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = try arenaCheck(a, try F.parseCoverage(SUMMARY), try F.parseFloor("lines 81.00\nbranches 60.01\n"));
    try t.expectEqual(@as(usize, 2), bad.len);
    try t.expectEqualStrings("pkg: line coverage is 80.00% (80/100), below its floor 81.00%: coverage fell", bad[0]);
    try t.expect(std.mem.indexOf(u8, bad[1], "branch coverage is 60.00% (30/50), below its floor 60.01%") != null);
    // One figure fine, the other not.
    const one = try arenaCheck(a, try F.parseCoverage(SUMMARY), try F.parseFloor("lines 80.00\nbranches 61.00\n"));
    try t.expectEqual(@as(usize, 1), one.len);
    try t.expect(std.mem.indexOf(u8, one[0], "branch coverage") != null);
}

test "check: coverage above the floor passes, and hints at the figure the floor may be raised to" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cov = try F.parseCoverage(SUMMARY);
    const floor = try F.parseFloor("lines 79.99\nbranches 60.00\n");
    try t.expectEqual(@as(usize, 0), (try arenaCheck(a, cov, floor)).len);
    const h = try F.hints(a, "pkg", cov, floor);
    try t.expectEqualStrings("pkg: line coverage is 80.00% (80/100), above its floor 79.99%: you may raise the floor to 80.00\n", h);
}

test "check: coverage equal to the floor passes with no hint" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cov = try F.parseCoverage(SUMMARY);
    const floor = try F.parseFloor("lines 80.00\nbranches 60.00\n");
    try t.expectEqual(@as(usize, 0), (try arenaCheck(a, cov, floor)).len);
    try t.expectEqualStrings("", try F.hints(a, "pkg", cov, floor));
}

test "check: branches follow the same rule: below fails, equal passes, above passes with a hint" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cov = try F.parseCoverage(SUMMARY); // branches 60.00
    const below = try arenaCheck(a, cov, try F.parseFloor("lines 80.00\nbranches 60.01\n"));
    try t.expectEqual(@as(usize, 1), below.len);
    try t.expect(std.mem.indexOf(u8, below[0], "branch coverage is 60.00% (30/50), below its floor 60.01%: coverage fell") != null);
    const equal = try F.parseFloor("lines 80.00\nbranches 60.00\n");
    try t.expectEqual(@as(usize, 0), (try arenaCheck(a, cov, equal)).len);
    try t.expectEqualStrings("", try F.hints(a, "pkg", cov, equal));
    const above = try F.parseFloor("lines 80.00\nbranches 55.00\n");
    try t.expectEqual(@as(usize, 0), (try arenaCheck(a, cov, above)).len);
    const h = try F.hints(a, "pkg", cov, above);
    try t.expectEqualStrings("pkg: branch coverage is 60.00% (30/50), above its floor 55.00%: you may raise the floor to 60.00\n", h);
}

test "check: a branch figure on one side only fails" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const missing = try arenaCheck(a, try F.parseCoverage(SUMMARY), try F.parseFloor("lines 80.00\n"));
    try t.expectEqual(@as(usize, 1), missing.len);
    try t.expect(std.mem.indexOf(u8, missing[0], "the floor file has no `branches` figure: add `branches 60.00`") != null);
    const dropped = try arenaCheck(a, try F.parseCoverage("total 80/100 80%\n"), try F.parseFloor("lines 80.00\nbranches 60.00\n"));
    try t.expectEqual(@as(usize, 1), dropped.len);
    try t.expect(std.mem.indexOf(u8, dropped[0], "or the branch instrumentation was dropped") != null);
}

test "check: nothing measured is an error, not a pass" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.Nothing, arenaCheck(arena.allocator(), try F.parseCoverage("total 0/0 0%\n"), try F.parseFloor("lines 0.00\n")));
}

test "report: the percentages, the counts and what the 99% target still needs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try F.report(a, "pkg", try F.parseCoverage(SUMMARY));
    try t.expectEqualStrings("pkg lines 80.00% (80/100); 19 more to 99%\npkg branches 60.00% (30/50); 20 more to 99%\n", text);
    // At or above the target nothing is needed.
    const done = try F.report(a, "p", try F.parseCoverage("total 99/100 99%\n"));
    try t.expectEqualStrings("p lines 99.00% (99/100); 0 more to 99%\n", done);
}

const JEST =
    \\{"total": {"lines": {"total": 40, "covered": 30, "skipped": 0, "pct": 75},
    \\  "statements": {"total": 50, "covered": 40, "skipped": 0, "pct": 80},
    \\  "functions": {"total": 5, "covered": 5, "skipped": 0, "pct": 100},
    \\  "branches": {"total": 8, "covered": 6, "skipped": 0, "pct": 75}},
    \\ "/w/site/tools/a.ts": {"lines": {"total": 40, "covered": 30, "skipped": 0, "pct": 75}}}
;

test "parseJestSummary: the total's lines and branches" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const c = try F.parseJestSummary(arena.allocator(), JEST);
    try t.expectEqual(@as(u64, 30), c.lines.hit);
    try t.expectEqual(@as(u64, 40), c.lines.total);
    try t.expectEqual(@as(u64, 6), c.branches.?.hit);
    try t.expectEqual(@as(u64, 8), c.branches.?.total);
    // Code with no branch at all has no branch figure, and the floor file must not have one.
    const none = try F.parseJestSummary(arena.allocator(), "{\"total\": {\"lines\": {\"total\": 4, \"covered\": 4}, \"branches\": {\"total\": 0, \"covered\": 0}}}");
    try t.expect(none.branches == null);
    const bad = try F.check(arena.allocator(), "site", c, try F.parseFloor("lines 75.00\nbranches 75.00\n"));
    try t.expectEqual(@as(usize, 0), bad.len);
}

test "parseJestSummary: anything else is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "",
        "not json",
        "[]",
        "{}",
        "{\"total\": {}}",
        "{\"total\": {\"lines\": {\"total\": 4, \"covered\": 4}}}", // no branches entry
        "{\"total\": {\"lines\": {\"total\": 4, \"covered\": 5}, \"branches\": {\"total\": 1, \"covered\": 1}}}", // more covered than there are
        "{\"total\": {\"lines\": {\"total\": -1, \"covered\": 0}, \"branches\": {\"total\": 1, \"covered\": 1}}}",
        "{\"total\": {\"lines\": {\"total\": \"4\", \"covered\": 4}, \"branches\": {\"total\": 1, \"covered\": 1}}}",
    }) |text| {
        try t.expectError(error.BadSummary, F.parseJestSummary(a, text));
    }
}

test "check: a package whose files are all alias-only counts nothing, so a floor on it is refused, not passed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const listing = "p/src/aliases.mojo 0/0 0%\np/src/types.mojo 0/0 0%\ntotal 0/0 0%\n";
    try t.expectError(error.Nothing, arenaCheck(arena.allocator(), try F.parseCoverage(listing), try F.parseFloor("lines 0.00\n")));
    try t.expectError(error.Nothing, arenaCheck(arena.allocator(), try F.parseCoverage(listing), try F.parseFloor("lines 100.00\n")));
}

test "check: an alias-only file beside measured files leaves the floor judged on the measured lines" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const listing = "p/src/aliases.mojo 0/0 0%\np/src/ops.mojo 3/5 60%\ntotal 3/5 60%\n";
    try t.expectEqual(@as(usize, 0), (try arenaCheck(a, try F.parseCoverage(listing), try F.parseFloor("lines 60.00\n"))).len);
    const low = try arenaCheck(a, try F.parseCoverage(listing), try F.parseFloor("lines 70.00\n"));
    try t.expectEqual(@as(usize, 1), low.len);
    try t.expect(std.mem.indexOf(u8, low[0], "below its floor 70.00%: coverage fell") != null);
}
