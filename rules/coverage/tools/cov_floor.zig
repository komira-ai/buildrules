//! cov_floor: holds a package's measured coverage to its floor file: it may not fall below it.
//!
//!   cov_floor (--coverage <coverage.txt> | --jest-summary <coverage-summary.json>) --floor <coverage_floor.txt> --label <package> --out <file>
//!
//! A Node package's figures come from jest: `--jest-summary` is the `coverage-summary.json` of `jest --coverage` (the `total` object: its `lines`
//! and `branches`, istanbul's), and a package with no branch at all has no `branches` figure.
//!
//! `coverage.txt` is cov_summary's output: the line `total <hit>/<total> <n>%` and, when the package's tests were built with branch counters,
//! the line `branches total <hit>/<total> <n>%`. The floor file holds the percentages the package has now, to two decimals, one per line:
//!
//!   lines 87.31
//!   branches 61.20
//!   lines 95.51 slack 1.00     (the hint to raise the floor is given only above the floor plus the slack)
//!
//! (`#` starts a comment.) The floor is a minimum. A measured percentage below its floor fails: coverage fell. A measured percentage at or
//! above it passes; above it, the check also says that the floor may be raised, and to what (raising it is optional). The percentage is
//! hit/total rounded down to a hundredth, so the number is the same on every run of the same tests. `slack` is accepted in the file and
//! only moves the point above which the hint is given (floor plus slack). A figure the file has and the coverage lacks (or the other way
//! round) fails: a package does not lose its branch figure by dropping the instrumentation.
//!
//! On success `--out` holds one line per figure: the percentage, the counts and how many more hits the 99% target needs, then a line
//! for each figure above its floor saying it may be raised (the same line goes to stderr).
//!
//! Exit status: 0 held; 1 not held, or an unreadable file; 2 for a usage error.

const std = @import("std");

/// The target the repository's coverage rule sets: lines and branches, per package.
pub const target_bp: u64 = 9900;

pub const Measure = struct { hit: u64, total: u64 };

pub const Coverage = struct { lines: Measure, branches: ?Measure };

/// The floors, in hundredths of a percent, each with the slack above it that is not a rise (0 unless the file gives one).
pub const Floor = struct { lines: u64, branches: ?u64, lines_slack: u64 = 0, branches_slack: u64 = 0 };

pub const ParseError = error{ BadCoverage, BadFloor, Nothing };

/// The percentage in hundredths (basis points), rounded down.
pub fn bp(m: Measure) !u64 {
    if (m.total == 0) return error.Nothing;
    return m.hit * 10000 / m.total;
}

fn measureOf(rest: []const u8) ParseError!Measure {
    // `<hit>/<total> <n>%`, and `(not counted)` never follows a total.
    var parts = std.mem.splitScalar(u8, rest, ' ');
    const frac = parts.next() orelse return error.BadCoverage;
    const slash = std.mem.indexOfScalar(u8, frac, '/') orelse return error.BadCoverage;
    const hit = std.fmt.parseInt(u64, frac[0..slash], 10) catch return error.BadCoverage;
    const total = std.fmt.parseInt(u64, frac[slash + 1 ..], 10) catch return error.BadCoverage;
    const pct = parts.next() orelse return error.BadCoverage;
    if (pct.len < 2 or pct[pct.len - 1] != '%') return error.BadCoverage;
    if (parts.next() != null) return error.BadCoverage;
    if (hit > total) return error.BadCoverage;
    return .{ .hit = hit, .total = total };
}

/// The two totals of cov_summary's text. A total given twice is refused.
pub fn parseCoverage(text: []const u8) ParseError!Coverage {
    var lines: ?Measure = null;
    var branches: ?Measure = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |row| {
        if (std.mem.startsWith(u8, row, "total ")) {
            if (lines != null) return error.BadCoverage;
            lines = try measureOf(row["total ".len..]);
        } else if (std.mem.startsWith(u8, row, "branches total ")) {
            if (branches != null) return error.BadCoverage;
            branches = try measureOf(row["branches total ".len..]);
        }
    }
    return .{ .lines = lines orelse return error.BadCoverage, .branches = branches };
}

pub const JestError = error{ BadSummary, OutOfMemory };

/// The `total` of a jest `coverage-summary.json`: lines, and branches unless the code has none.
pub fn parseJestSummary(a: std.mem.Allocator, text: []const u8) JestError!Coverage {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadSummary,
    };
    const total = jsonField(root, "total") orelse return error.BadSummary;
    const lines = try jestMeasure(total, "lines");
    const branches = try jestMeasure(total, "branches");
    return .{ .lines = lines, .branches = if (branches.total == 0) null else branches };
}

fn jsonField(v: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(name),
        else => null,
    };
}

fn jestMeasure(total: std.json.Value, name: []const u8) JestError!Measure {
    const m = jsonField(total, name) orelse return error.BadSummary;
    const t = jsonField(m, "total") orelse return error.BadSummary;
    const c = jsonField(m, "covered") orelse return error.BadSummary;
    if (t != .integer or c != .integer or t.integer < 0 or c.integer < 0 or c.integer > t.integer) return error.BadSummary;
    return .{ .hit = @intCast(c.integer), .total = @intCast(t.integer) };
}

/// `87.31` (exactly two decimals, 0.00 to 100.00) as 8731.
pub fn parseHundredths(s: []const u8) ?u64 {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return null;
    if (s.len - dot - 1 != 2 or dot == 0 or dot > 3) return null;
    const whole = std.fmt.parseInt(u64, s[0..dot], 10) catch return null;
    const frac = std.fmt.parseInt(u64, s[dot + 1 ..], 10) catch return null;
    // `parseInt` takes a sign and underscores; the text is digits only.
    for (s[0..dot]) |c| if (c < '0' or c > '9') return null;
    for (s[dot + 1 ..]) |c| if (c < '0' or c > '9') return null;
    const v = whole * 100 + frac;
    return if (v > 10000) null else v;
}

pub fn parseFloor(text: []const u8) ParseError!Floor {
    var lines: ?u64 = null;
    var branches: ?u64 = null;
    var lines_slack: u64 = 0;
    var branches_slack: u64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const row = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, raw, '#')) |h| raw[0..h] else raw, " \t\r");
        if (row.len == 0) continue;
        // `<key> <NN.NN>` or `<key> <NN.NN> slack <NN.NN>`
        var words = std.mem.tokenizeAny(u8, row, " \t");
        const key = words.next() orelse return error.BadFloor;
        const v = parseHundredths(words.next() orelse return error.BadFloor) orelse return error.BadFloor;
        var slack: u64 = 0;
        if (words.next()) |w| {
            if (!std.mem.eql(u8, w, "slack")) return error.BadFloor;
            slack = parseHundredths(words.next() orelse return error.BadFloor) orelse return error.BadFloor;
            if (slack == 0 or words.next() != null) return error.BadFloor;
        }
        const is_lines = std.mem.eql(u8, key, "lines");
        if (!is_lines and !std.mem.eql(u8, key, "branches")) return error.BadFloor;
        const slot: *?u64 = if (is_lines) &lines else &branches;
        if (slot.* != null) return error.BadFloor;
        slot.* = v;
        if (is_lines) lines_slack = slack else branches_slack = slack;
    }
    return .{ .lines = lines orelse return error.BadFloor, .branches = branches, .lines_slack = lines_slack, .branches_slack = branches_slack };
}

fn fmtHundredths(a: std.mem.Allocator, v: u64) ![]u8 {
    return std.fmt.allocPrint(a, "{d}.{d:0>2}", .{ v / 100, v % 100 });
}

/// What is wrong with one figure, or null when it is at or above its floor.
fn judge(a: std.mem.Allocator, label: []const u8, what: []const u8, m: Measure, floor: u64) !?[]u8 {
    const now = try bp(m);
    if (now >= floor) return null;
    return try std.fmt.allocPrint(a, "{s}: {s} coverage is {d}.{d:0>2}% ({d}/{d}), below its floor {d}.{d:0>2}%: coverage fell", .{ label, what, now / 100, now % 100, m.hit, m.total, floor / 100, floor % 100 });
}

/// Adds the line for one figure above its floor (and its slack), if it is.
fn addHint(a: std.mem.Allocator, o: *std.ArrayList(u8), label: []const u8, what: []const u8, m: Measure, floor: u64, slack: u64) !void {
    const now = try bp(m);
    if (now <= floor + slack) return;
    try o.print(a, "{s}: {s} coverage is {d}.{d:0>2}% ({d}/{d}), above its floor {d}.{d:0>2}%: you may raise the floor to {d}.{d:0>2}\n", .{ label, what, now / 100, now % 100, m.hit, m.total, floor / 100, floor % 100, now / 100, now % 100 });
}

/// The informational lines (one per figure above its floor) for coverage that `check` passed; empty when there are none.
pub fn hints(a: std.mem.Allocator, label: []const u8, cov: Coverage, floor: Floor) ![]u8 {
    var o = std.ArrayList(u8).empty;
    try addHint(a, &o, label, "line", cov.lines, floor.lines, floor.lines_slack);
    if (cov.branches) |b| if (floor.branches) |f| try addHint(a, &o, label, "branch", b, f, floor.branches_slack);
    return o.toOwnedSlice(a);
}

/// Every way `cov` is below `floor` or does not match its shape; empty when it is held.
pub fn check(a: std.mem.Allocator, label: []const u8, cov: Coverage, floor: Floor) ![]const []const u8 {
    var bad = std.ArrayList([]const u8).empty;
    if (try judge(a, label, "line", cov.lines, floor.lines)) |m| try bad.append(a, m);
    if (cov.branches) |b| {
        if (floor.branches) |f| {
            if (try judge(a, label, "branch", b, f)) |m| try bad.append(a, m);
        } else try bad.append(a, try std.fmt.allocPrint(a, "{s}: the tests record branches ({d}/{d}) and the floor file has no `branches` figure: add `branches {s}`", .{ label, b.hit, b.total, try fmtHundredths(a, try bp(b)) }));
    } else if (floor.branches != null) {
        try bad.append(a, try std.fmt.allocPrint(a, "{s}: the floor file has a `branches` figure and the tests record no branches: the instrumentation was dropped", .{label}));
    }
    return bad.toOwnedSlice(a);
}

fn needed(m: Measure) u64 {
    const want = (m.total * target_bp + 9999) / 10000;
    return if (want > m.hit) want - m.hit else 0;
}

/// The success line(s) of `--out`.
pub fn report(a: std.mem.Allocator, label: []const u8, cov: Coverage) ![]u8 {
    var o = std.ArrayList(u8).empty;
    try o.print(a, "{s} lines {s}% ({d}/{d}); {d} more to 99%\n", .{ label, try fmtHundredths(a, try bp(cov.lines)), cov.lines.hit, cov.lines.total, needed(cov.lines) });
    if (cov.branches) |b| try o.print(a, "{s} branches {s}% ({d}/{d}); {d} more to 99%\n", .{ label, try fmtHundredths(a, try bp(b)), b.hit, b.total, needed(b) });
    return o.toOwnedSlice(a);
}

fn die(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cov_floor: " ++ fmt ++ "\n", args);
    std.process.exit(code);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    var coverage: ?[]const u8 = null;
    var jest: ?[]const u8 = null;
    var floor: ?[]const u8 = null;
    var label: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) die(2, "{s} needs a value", .{argv[i]});
        const slot: *?[]const u8 = if (std.mem.eql(u8, argv[i], "--coverage")) &coverage else if (std.mem.eql(u8, argv[i], "--jest-summary")) &jest else if (std.mem.eql(u8, argv[i], "--floor")) &floor else if (std.mem.eql(u8, argv[i], "--label")) &label else if (std.mem.eql(u8, argv[i], "--out")) &out else die(2, "unknown option {s}", .{argv[i]});
        slot.* = argv[i + 1];
    }
    if ((coverage == null) == (jest == null) or floor == null or label == null or out == null) die(2, "usage: cov_floor (--coverage <file> | --jest-summary <file>) --floor <file> --label <package> --out <file>", .{});
    const source = coverage orelse jest.?;
    const ctext = std.fs.cwd().readFileAlloc(a, source, 16 << 20) catch |e| die(1, "cannot read {s}: {s}", .{ source, @errorName(e) });
    const ftext = std.fs.cwd().readFileAlloc(a, floor.?, 1 << 20) catch |e| die(1, "cannot read {s}: {s}", .{ floor.?, @errorName(e) });
    const cov = if (jest != null)
        parseJestSummary(a, ctext) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.BadSummary => die(1, "{s}: not a jest coverage-summary.json: no `total` with `lines` and `branches` counts", .{source}),
        }
    else
        parseCoverage(ctext) catch die(1, "{s}: no `total` line of the form `total <hit>/<total> <n>%`", .{source});
    const fl = parseFloor(ftext) catch die(1, "{s}: expected `lines NN.NN` and optionally `branches NN.NN` (two decimals, 0.00 to 100.00), one per line", .{floor.?});
    const bad = check(a, label.?, cov, fl) catch |e| switch (e) {
        error.Nothing => die(1, "{s}: the coverage counts nothing (0 of 0): no test measured the package", .{label.?}),
        else => return e,
    };
    if (bad.len != 0) {
        for (bad) |m| std.debug.print("cov_floor: {s}\n", .{m});
        std.process.exit(1);
    }
    var text = try report(a, label.?, cov);
    const hint_text = try hints(a, label.?, cov, fl);
    std.debug.print("{s}", .{hint_text});
    text = try std.mem.concat(a, u8, &.{ text, hint_text });
    std.fs.cwd().writeFile(.{ .sub_path = out.?, .data = text }) catch |e| die(1, "cannot write {s}: {s}", .{ out.?, @errorName(e) });
}
