//! The known defect of ci/negative stays a known defect: this holds the files that make it one to each other, in //ci:all, and the bxl check
//! (ci/negative.bzl, run by the public CI as a part of ci/completeness.bxl) holds the build itself. A pure function per rule, each tested against faulty
//! text as well as against the real files (the zig_test's `data`, under BUILDRULES_TEST_WORK).
//!
//! What the rules catch:
//!  - the fixture gaining the line it leaves out (`exec_compatible_with`), losing the platform it is compatible with, or the control losing the line it
//!    has: either way the pair no longer shows that one line is what the rule refuses on;
//!  - the control and the fixture running different tests;
//!  - ci/negative.bzl naming a target that is not in the BUCK file, a platform that is not the ISA one, or a reason the rule no longer gives;
//!  - ci/completeness.bxl (the step of the public CI) not running the check;
//!  - a fixture of ci/negative.bzl's CASES that is not in ci/negative/BUCK, lacks the platform it is compatible with, or is not excluded in ci/all.bzl, and a fixture
//!    of ci/negative/BUCK (compatible only with that platform) that CASES does not assert: either way a known defect would not be held red.
const std = @import("std");
const t = std.testing;

const fixture_name = "v3_test_without_isa_property";
const control_name = "v3_test_with_isa_property";
const compat = "target_compatible_with = [\"buildrules//platforms:isa_x86_64_v3\"]";

pub const Findings = std.ArrayList([]const u8);

fn add(a: std.mem.Allocator, f: *Findings, comptime fmt: []const u8, args: anytype) !void {
    try f.append(a, try std.fmt.allocPrint(a, fmt, args));
}

/// The text of the `test_run(` call whose name is `name`: from the call to the closing `)` at the start of a line.
pub fn block(text: []const u8, name: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "    name = \"{s}\",", .{name}) catch return null;
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    const start = std.mem.lastIndexOf(u8, text[0..at], "test_run(") orelse return null;
    const end = std.mem.indexOfPos(u8, text, at, "\n)") orelse return null;
    return text[start .. end + 2];
}

fn field(b: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "    {s} = ", .{key}) catch return null;
    const at = std.mem.indexOf(u8, b, needle) orelse return null;
    const rest = b[at + needle.len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
}

/// The findings about ci/negative/BUCK.
pub fn buckFindings(a: std.mem.Allocator, buck: []const u8) ![]const []const u8 {
    var f = Findings.empty;
    const bad = block(buck, fixture_name) orelse {
        try add(a, &f, "ci/negative/BUCK has no test_run named {s}", .{fixture_name});
        return f.toOwnedSlice(a);
    };
    const good = block(buck, control_name) orelse {
        try add(a, &f, "ci/negative/BUCK has no test_run named {s}, the control", .{control_name});
        return f.toOwnedSlice(a);
    };
    if (std.mem.indexOf(u8, bad, "exec_compatible_with") != null)
        try add(a, &f, "{s} has exec_compatible_with: it is the valid test run, and the known defect is gone", .{fixture_name});
    if (std.mem.indexOf(u8, bad, compat) == null)
        try add(a, &f, "{s} lacks `{s}`: a wildcard build would not skip it", .{ fixture_name, compat });
    if (std.mem.indexOf(u8, good, "exec_compatible_with = test_exec_compatible_with()") == null)
        try add(a, &f, "{s} (the control) lacks `exec_compatible_with = test_exec_compatible_with()`: it is not the fixture with the one line", .{control_name});
    if (std.mem.indexOf(u8, good, compat) == null)
        try add(a, &f, "{s} (the control) lacks `{s}`", .{ control_name, compat });
    const unit_bad = field(bad, "unit");
    const unit_good = field(good, "unit");
    if (unit_bad == null or unit_good == null or !std.mem.eql(u8, unit_bad.?, unit_good.?))
        try add(a, &f, "the fixture and its control run different tests (unit = {s} / {s})", .{ unit_bad orelse "none", unit_good orelse "none" });
    const r1 = field(bad, "required_isa");
    const r2 = field(good, "required_isa");
    if (r1 == null or r2 == null or !std.mem.eql(u8, r1.?, r2.?))
        try add(a, &f, "the fixture and its control are built for different ISA levels (required_isa = {s} / {s})", .{ r1 orelse "none", r2 orelse "none" });
    return f.toOwnedSlice(a);
}

fn constant(text: []const u8, name: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "\n{s} = \"", .{name}) catch return null;
    const at = std.mem.indexOf(u8, text, needle) orelse return null;
    const rest = text[at + needle.len ..];
    return rest[0..(std.mem.indexOfScalar(u8, rest, '"') orelse return null)];
}

/// The findings about ci/negative.bzl, against ci/negative/BUCK's names and the rule's own message (rules/rust/test_run.bzl).
pub fn bzlFindings(a: std.mem.Allocator, text: []const u8, test_run_bzl: []const u8) ![]const []const u8 {
    var f = Findings.empty;
    const want = [_]struct { name: []const u8, label: []const u8 }{
        .{ .name = "FIXTURE", .label = "//ci/negative:" ++ fixture_name },
        .{ .name = "CONTROL", .label = "//ci/negative:" ++ control_name },
        .{ .name = "PLATFORM", .label = "buildrules//platforms:linux_x86_64_v3" },
    };
    for (want) |w| {
        const got = constant(text, w.name) orelse "";
        if (!std.mem.eql(u8, got, w.label)) try add(a, &f, "ci/negative.bzl: {s} is `{s}`, it must be `{s}`", .{ w.name, got, w.label });
    }
    // The reason is the rule's message with the level and the platform's level filled in; both halves of the message must still be the rule's.
    const reason = constant(text, "REASON") orelse "";
    const level = "x86-64-v3";
    if (std.mem.indexOf(u8, reason, level)) |at| {
        const before = reason[0..at];
        const after = reason[at + level.len ..];
        if (std.mem.indexOf(u8, test_run_bzl, before) == null or std.mem.indexOf(u8, test_run_bzl, after) == null)
            try add(a, &f, "ci/negative.bzl: REASON `{s}` is not what rules/rust/test_run.bzl says any more", .{reason});
    } else try add(a, &f, "ci/negative.bzl: REASON `{s}` does not name {s}", .{ reason, level });
    return f.toOwnedSlice(a);
}

/// The findings about ci/completeness.bxl, the step of the public CI that runs the check.
pub fn wiringFindings(a: std.mem.Allocator, completeness: []const u8) ![]const []const u8 {
    var f = Findings.empty;
    for ([_][]const u8{
        "load(\"@buildrules//ci:negative.bzl\", \"negative_problems\")",
        "negative = negative_problems(ctx)",
        "if problems or negative:",
    }) |need| {
        if (std.mem.indexOf(u8, completeness, need) == null) try add(a, &f, "ci/completeness.bxl lacks `{s}`: the CI does not run the check", .{need});
    }
    return f.toOwnedSlice(a);
}

/// The id after `//ci/negative:` on each line of `text` that has one in quotes, in order.
fn caseIds(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    const marker = "(\"//ci/negative:";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const at = std.mem.indexOf(u8, l, marker) orelse continue;
        const rest = l[at + marker.len ..];
        try out.append(a, rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse continue]);
    }
    return out.toOwnedSlice(a);
}

/// The ids of the BUCK file's calls that carry the compatibility line: the `name` before each occurrence of it.
fn compatIds(a: std.mem.Allocator, buck: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, buck, from, compat)) |at| : (from = at + compat.len) {
        const head = buck[0..at];
        const n = std.mem.lastIndexOf(u8, head, "    name = \"") orelse continue;
        const rest = head[n + "    name = \"".len ..];
        try out.append(a, rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse continue]);
    }
    return out.toOwnedSlice(a);
}

/// The findings about ci/negative.bzl's CASES against ci/negative/BUCK and ci/all.bzl: every fixture it names is declared, is compatible only with the platform it breaks
/// on, and is excluded from the wildcard build; and every fixture of the BUCK file with that compatibility line is the pair or in CASES.
pub fn casesFindings(a: std.mem.Allocator, bzl: []const u8, buck: []const u8, all: []const u8) ![]const []const u8 {
    var f = Findings.empty;
    const cases_at = std.mem.indexOf(u8, bzl, "\nCASES = [") orelse {
        try add(a, &f, "ci/negative.bzl has no CASES", .{});
        return f.toOwnedSlice(a);
    };
    const cases_end = std.mem.indexOfPos(u8, bzl, cases_at, "\n]") orelse bzl.len;
    const ids = try caseIds(a, bzl[cases_at..cases_end]);
    if (ids.len == 0) try add(a, &f, "ci/negative.bzl: CASES names no fixture of //ci/negative", .{});
    for (ids) |id| {
        var needle_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "    name = \"{s}\",", .{id}) catch continue;
        const at = std.mem.indexOf(u8, buck, needle) orelse {
            try add(a, &f, "ci/negative.bzl: CASES names //ci/negative:{s}, which ci/negative/BUCK does not declare", .{id});
            continue;
        };
        const end = std.mem.indexOfPos(u8, buck, at, "\n)") orelse buck.len;
        if (std.mem.indexOf(u8, buck[at..end], compat) == null)
            try add(a, &f, "{s} lacks `{s}`: a wildcard build would not skip it", .{ id, compat });
        var label_buf: [160]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "//ci/negative:{s}", .{id}) catch continue;
        if (std.mem.indexOf(u8, all, label) == null)
            try add(a, &f, "ci/all.bzl does not exclude {s}: the completeness check would call it uncovered", .{label});
    }
    for (try compatIds(a, buck)) |id| {
        var label_buf: [160]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "//ci/negative:{s}", .{id}) catch continue;
        if (std.mem.indexOf(u8, bzl, label) == null)
            try add(a, &f, "ci/negative/BUCK declares {s}, which ci/negative.bzl neither asserts red nor names as the pair", .{label});
    }
    return f.toOwnedSlice(a);
}

fn readAll(a: std.mem.Allocator, work: []const u8, rel: []const u8) ![]u8 {
    const path = try std.fs.path.join(a, &.{ work, rel });
    return std.fs.cwd().readFileAlloc(a, path, 1 << 20);
}

fn expectNone(findings: []const []const u8) !void {
    for (findings) |m| std.debug.print("finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), findings.len);
}

fn expectOne(findings: []const []const u8, contains: []const u8) !void {
    if (findings.len != 1 or std.mem.indexOf(u8, findings[0], contains) == null) {
        for (findings) |m| std.debug.print("finding: {s}\n", .{m});
        std.debug.print("wanted exactly one, containing `{s}`\n", .{contains});
        return error.TestUnexpectedResult;
    }
}

// ---- the real files ----

test "the real fixture, control, constants and CI step are as faulty" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const work = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    try expectNone(try buckFindings(a, try readAll(a, work, "ci/negative/BUCK")));
    try expectNone(try bzlFindings(a, try readAll(a, work, "ci/negative.bzl"), try readAll(a, work, "rules/rust/test_run.bzl")));
    try expectNone(try wiringFindings(a, try readAll(a, work, "ci/completeness.bxl")));
    try expectNone(try casesFindings(a, try readAll(a, work, "ci/negative.bzl"), try readAll(a, work, "ci/negative/BUCK"), try readAll(a, work, "ci/all.bzl")));
}

// ---- faulty text ----

const GOOD =
    \\test_run(
    \\    name = "v3_test_without_isa_property",
    \\    unit = "//examples/isa:isa_lib_test__bin",
    \\    required_isa = required_isa(),
    \\    target_compatible_with = ["buildrules//platforms:isa_x86_64_v3"],
    \\)
    \\
    \\test_run(
    \\    name = "v3_test_with_isa_property",
    \\    unit = "//examples/isa:isa_lib_test__bin",
    \\    exec_compatible_with = test_exec_compatible_with(),
    \\    required_isa = required_isa(),
    \\    target_compatible_with = ["buildrules//platforms:isa_x86_64_v3"],
    \\)
    \\
;

fn replaced(a: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, a, text, from, to);
}

test "buck: the faulty pair passes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try expectNone(try buckFindings(arena.allocator(), GOOD));
}

test "buck: the fixture made valid is found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const valid = try replaced(a, GOOD, "    name = \"v3_test_without_isa_property\",\n", "    name = \"v3_test_without_isa_property\",\n    exec_compatible_with = test_exec_compatible_with(),\n");
    try expectOne(try buckFindings(a, valid), "the known defect is gone");
}

test "buck: a fixture that a wildcard build would build is found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Only the fixture's line: the control keeps its own.
    const at = std.mem.indexOf(u8, GOOD, "    target_compatible_with").?;
    const end = std.mem.indexOfPos(u8, GOOD, at, "\n").? + 1;
    const without = try std.mem.concat(a, u8, &.{ GOOD[0..at], GOOD[end..] });
    try expectOne(try buckFindings(a, without), "a wildcard build would not skip it");
}

test "buck: a control that lost its line, or runs another test, is found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lost = try replaced(a, GOOD, "    exec_compatible_with = test_exec_compatible_with(),\n", "");
    try expectOne(try buckFindings(a, lost), "the control) lacks `exec_compatible_with");
    const other = try replaced(a, GOOD, "    name = \"v3_test_with_isa_property\",\n    unit = \"//examples/isa:isa_lib_test__bin\"", "    name = \"v3_test_with_isa_property\",\n    unit = \"//examples/isa:other\"");
    try expectOne(try buckFindings(a, other), "run different tests");
    const level = try replaced(a, GOOD, "    required_isa = required_isa(),\n    target_compatible_with = [\"buildrules//platforms:isa_x86_64_v3\"],\n)\n\ntest_run(", "    required_isa = \"x86-64-v2\",\n    target_compatible_with = [\"buildrules//platforms:isa_x86_64_v3\"],\n)\n\ntest_run(");
    try expectOne(try buckFindings(a, level), "different ISA levels");
}

test "buck: a missing target is found by name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectOne(try buckFindings(a, ""), "no test_run named v3_test_without_isa_property");
    const half = GOOD[0 .. std.mem.indexOf(u8, GOOD, "\n\ntest_run(").? + 1];
    try expectOne(try buckFindings(a, half), "no test_run named v3_test_with_isa_property");
}

const BZL =
    \\PLATFORM = "buildrules//platforms:linux_x86_64_v3"
    \\FIXTURE = "//ci/negative:v3_test_without_isa_property"
    \\CONTROL = "//ci/negative:v3_test_with_isa_property"
    \\REASON = "built for ISA x86-64-v3 but its execution platform reports ISA="
    \\
;

const TEST_RUN = "fail((\"{}: built for ISA {} but its execution platform reports ISA={}. A test at an ISA level\"))";

/// BZL with `from` replaced, behind the newline `constant` looks for.
fn withBzl(a: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
    return std.mem.concat(a, u8, &.{ "\n", try replaced(a, BZL, from, to) });
}

test "bzl: the constants pass, and each wrong one is found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectNone(try bzlFindings(a, "\n" ++ BZL, TEST_RUN));
    try expectOne(try bzlFindings(a, try withBzl(a, "v3_test_without_isa_property", "renamed"), TEST_RUN), "FIXTURE is `//ci/negative:renamed`");
    try expectOne(try bzlFindings(a, try withBzl(a, "negative:v3_test_with_isa_property", "negative:gone"), TEST_RUN), "CONTROL is");
    try expectOne(try bzlFindings(a, try withBzl(a, "linux_x86_64_v3", "linux_x86_64"), TEST_RUN), "PLATFORM is");
}

test "bzl: a reason the rule no longer gives is found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const changed = "fail((\"{}: requires ISA {} but the platform has ISA={}\"))";
    try expectOne(try bzlFindings(a, "\n" ++ BZL, changed), "is not what rules/rust/test_run.bzl says any more");
    try expectOne(try bzlFindings(a, try withBzl(a, "x86-64-v3 but", "but"), TEST_RUN), "does not name x86-64-v3");
}

test "wiring: the CI step passes, and a completeness check that does not run it is found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = "load(\"@buildrules//ci:negative.bzl\", \"negative_problems\")\n    negative = negative_problems(ctx)\n    if problems or negative:\n";
    try expectNone(try wiringFindings(a, ok));
    try expectOne(try wiringFindings(a, "load(\"@buildrules//ci:negative.bzl\", \"negative_problems\")\n    if problems or negative:\n"), "negative = negative_problems(ctx)");
    // The result is computed and never looked at: the check would pass whatever the fixture does.
    try expectOne(try wiringFindings(a, "load(\"@buildrules//ci:negative.bzl\", \"negative_problems\")\n    negative = negative_problems(ctx)\n"), "if problems or negative:");
    try expectOne(try wiringFindings(a, "    negative = negative_problems(ctx)\n    if problems or negative:\n"), "load(\"@buildrules//ci:negative.bzl\"");
    const none = try wiringFindings(a, "");
    try t.expectEqual(@as(usize, 3), none.len);
}

// ---- CASES ----

const CASES_BZL =
    \\PLATFORM = "x"
    \\
    \\CASES = [
    \\    ("//ci/negative:first_fixture", PLATFORM, "one reason"),
    \\    ("//examples/mojo/registry/cnative:coverage", "p", "another reason"),
    \\    ("//ci/negative:second_fixture", PLATFORM, "a third reason"),
    \\]
    \\
;

const CASES_BUCK =
    \\thing(
    \\    name = "first_fixture",
    \\    target_compatible_with = ["buildrules//platforms:isa_x86_64_v3"],
    \\)
    \\
    \\thing(
    \\    name = "second_fixture",
    \\    target_compatible_with = ["buildrules//platforms:isa_x86_64_v3"],
    \\)
    \\
;

const CASES_ALL = "\"//ci/negative:first_fixture + //ci/negative:second_fixture\": \"why\",";

test "cases: fixtures that are declared, incompatible with the wildcard platform and excluded pass" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try expectNone(try casesFindings(arena.allocator(), CASES_BZL, CASES_BUCK, CASES_ALL));
}

test "cases: a fixture the BUCK file does not declare, one a wildcard build would build, and one not excluded are each found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first_only = CASES_BUCK[0 .. std.mem.indexOf(u8, CASES_BUCK, "\nthing(\n    name = \"second_fixture\"").? + 1];
    try expectOne(try casesFindings(a, CASES_BZL, first_only, CASES_ALL), "CASES names //ci/negative:second_fixture, which ci/negative/BUCK does not declare");
    // the second call loses its line: only its own block is searched, not the file
    const second = std.mem.indexOf(u8, CASES_BUCK, "    name = \"second_fixture\"").?;
    const lost = try std.mem.concat(a, u8, &.{ CASES_BUCK[0..second], try replaced(a, CASES_BUCK[second..], "    target_compatible_with = [\"buildrules//platforms:isa_x86_64_v3\"],\n", "") });
    try expectOne(try casesFindings(a, CASES_BZL, lost, CASES_ALL), "second_fixture lacks `target_compatible_with");
    try expectOne(try casesFindings(a, CASES_BZL, CASES_BUCK, "\"//ci/negative:first_fixture\": \"why\","), "does not exclude //ci/negative:second_fixture");
}

test "cases: a faulty fixture that CASES does not assert, and a CASES that is gone, are found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const extra = try std.mem.concat(a, u8, &.{ CASES_BUCK, "thing(\n    name = \"unasserted\",\n    target_compatible_with = [\"buildrules//platforms:isa_x86_64_v3\"],\n)\n" });
    try expectOne(try casesFindings(a, CASES_BZL, extra, CASES_ALL), "declares //ci/negative:unasserted, which ci/negative.bzl neither asserts red nor names as the pair");
    try expectOne(try casesFindings(a, "PLATFORM = \"x\"\n", CASES_BUCK, CASES_ALL), "ci/negative.bzl has no CASES");
    try expectOne(try casesFindings(a, "PLATFORM = \"x\"\n\nCASES = [\n]\n", "", CASES_ALL), "CASES names no fixture");
}
