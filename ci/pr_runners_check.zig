//! Every workflow a pull request starts runs on linux x86_64 alone. The owner's rule: x86_64 linux tests are the pull-request checks (there are many such machines), and every
//! other platform (macOS, linux aarch64) is a beta stage of the release (.github/workflows/beta.yml, called by release.yml after the merge). A pull request that started a job on
//! a macOS runner for each push once used up the organisation's hosted macOS runners and held a release for fourteen hours.
//!
//! The rule is `workflow_check.zig`'s `prRunners`, applied here to every workflow of the repository that has a `pull_request` trigger and to the workflows those call
//! (`uses: ./.github/workflows/x.yml`): each `runs-on:` of such a workflow is `ubuntu-latest`, `ubuntu-24.04` or `ubuntu-22.04`. A pure function of the text, so the rule is
//! tested against faulty text (a pull-request workflow with a macOS, arm, windows, self-hosted, list or expression runner must be refused) as well as against the real files
//! (the zig_test's `data`, under BUILDRULES_TEST_WORK).
const std = @import("std");
const wc = @import("workflow_check.zig");
const rc = @import("release_check.zig");
const t = std.testing;

const Findings = wc.Findings;

/// Every workflow of the repository, as the zig_test's `data` lists them (ci/BUCK).
const workflows = [_][]const u8{
    "advisories.yml",
    "apt-rotation.yml",
    "beta.yml",
    "ci.yml",
    "lintian.yml",
    "mopm-pin.yml",
    "publish-unpack.yml",
    "release.yml",
    "site-publish.yml",
    "site.yml",
};

const Named = struct { name: []const u8, text: []const u8 };

fn hasTrigger(a: std.mem.Allocator, text: []const u8, trigger: []const u8) !bool {
    for (try rc.triggers(a, text)) |k| {
        if (std.mem.eql(u8, k, trigger)) return true;
    }
    return false;
}

/// The name of the workflow that `uses: ./.github/workflows/<name>` on `line` calls, if the line is such a call.
fn calledWorkflow(line: []const u8) ?[]const u8 {
    const l = std.mem.trim(u8, line, " -");
    const prefix = "uses: ./.github/workflows/";
    if (!std.mem.startsWith(u8, l, prefix)) return null;
    const rest = l[prefix.len..];
    const end = std.mem.indexOfAny(u8, rest, " #") orelse rest.len;
    return rest[0..end];
}

/// The names of the workflows a pull request starts: those with a `pull_request` trigger, and the ones they call.
fn pullRequestWorkflows(a: std.mem.Allocator, all: []const Named) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    for (all) |w| {
        if (!try hasTrigger(a, w.text, "pull_request")) continue;
        try out.append(w.name);
        var lines = std.mem.splitScalar(u8, w.text, '\n');
        while (lines.next()) |line| {
            if (calledWorkflow(line)) |callee| try out.append(callee);
        }
    }
    return out.toOwnedSlice();
}

/// Everything wrong with the workflows `all`: a runner other than linux x86_64 in a workflow a pull request starts.
fn check(a: std.mem.Allocator, all: []const Named) !Findings {
    var f = Findings.init(a);
    for (try pullRequestWorkflows(a, all)) |name| {
        for (all) |w| {
            if (!std.mem.eql(u8, w.name, name)) continue;
            var one = Findings.init(a);
            try wc.prRunners(a, &one, w.text);
            for (one.items) |m| try wc.add(a, &f, "{s}: {s}", .{ name, m });
        }
    }
    return f;
}

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

fn realWorkflows(a: std.mem.Allocator) ![]const Named {
    var out = std.ArrayList(Named).init(a);
    for (workflows) |name| {
        const p = try std.fmt.allocPrint(a, ".github/workflows/{s}", .{name});
        try out.append(.{ .name = name, .text = try work(a, p) });
    }
    return out.toOwnedSlice();
}

fn expectFinding(a: std.mem.Allocator, all: []const Named, needle: []const u8) !void {
    const f = try check(a, all);
    for (f.items) |m| {
        if (std.mem.indexOf(u8, m, needle) != null) return;
    }
    std.debug.print("expected a finding with `{s}`, got {d}:\n", .{ needle, f.items.len });
    for (f.items) |m| std.debug.print("  {s}\n", .{m});
    return error.DefectSurvived;
}

test "the real workflows: a pull request runs on linux x86_64 alone" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const all = try realWorkflows(a);
    // the parser is not blind: the workflows known to start on a pull request are found, and the ones that do not are not
    const started = try pullRequestWorkflows(a, all);
    var seen = [_]bool{ false, false, false };
    for (started) |n| {
        for ([_][]const u8{ "ci.yml", "mopm-pin.yml", "apt-rotation.yml" }, 0..) |want, i| {
            if (std.mem.eql(u8, n, want)) seen[i] = true;
        }
        try t.expect(!std.mem.eql(u8, n, "release.yml"));
        try t.expect(!std.mem.eql(u8, n, "beta.yml"));
    }
    for (seen) |s| try t.expect(s);
    const f = try check(a, all);
    for (f.items) |m| std.debug.print("finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "the real beta stage is where the other platforms are: its macOS and arm runners are not a pull request's" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const all = try realWorkflows(a);
    for (all) |w| {
        if (!std.mem.eql(u8, w.name, "beta.yml")) continue;
        try t.expect(!try hasTrigger(a, w.text, "pull_request"));
        // beta.yml does name them, and check() does not look at it because no pull request starts it
        var one = Findings.init(a);
        try wc.prRunners(a, &one, w.text);
        try t.expect(one.items.len > 0);
    }
}

const pr_ci =
    \\name: ci
    \\on:
    \\  pull_request:
    \\  workflow_call:
    \\jobs:
    \\  build:
    \\    runs-on: ubuntu-latest
    \\    steps:
    \\      - run: true
    \\
;

const push_only =
    \\name: release
    \\on:
    \\  push:
    \\    branches: [main]
    \\jobs:
    \\  gate:
    \\    uses: ./.github/workflows/ci.yml
    \\  beta:
    \\    runs-on: macos-15
    \\    steps:
    \\      - run: true
    \\
;

test "a pull-request workflow on ubuntu runners has no finding, and a push-only workflow may name another platform" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const f = try check(a, &.{ .{ .name = "ci.yml", .text = pr_ci }, .{ .name = "release.yml", .text = push_only } });
    for (f.items) |m| std.debug.print("finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "a workflow a pull request starts that names macOS, arm, windows, a self-hosted runner, a list or an expression is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for ([_][]const u8{ "macos-15", "macos-latest", "ubuntu-24.04-arm", "ubuntu-latest-arm", "windows-latest", "self-hosted", "[self-hosted, linux]", "${{ matrix.os }}", "" }) |bad| {
        const wf = try std.mem.replaceOwned(u8, a, pr_ci, "runs-on: ubuntu-latest", try std.fmt.allocPrint(a, "runs-on: {s}", .{bad}));
        try expectFinding(a, &.{.{ .name = "ci.yml", .text = wf }}, "ci.yml: a job a pull request runs names the runner");
    }
    // a second job beside the ubuntu one
    const two = try std.mem.concat(a, u8, &.{ pr_ci, "  mac:\n    runs-on: macos-15\n    steps:\n      - run: true\n" });
    try expectFinding(a, &.{.{ .name = "ci.yml", .text = two }}, "`macos-15`");
}

test "a workflow that a pull request's workflow calls is held to the same rule, and a trigger of another event is not a pull request" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const caller =
        \\name: gate
        \\on:
        \\  pull_request:
        \\jobs:
        \\  call:
        \\    uses: ./.github/workflows/leg.yml # the leg
        \\
    ;
    const leg = "name: leg\non:\n  workflow_call:\njobs:\n  mac:\n    runs-on: macos-15\n";
    try expectFinding(a, &.{ .{ .name = "gate.yml", .text = caller }, .{ .name = "leg.yml", .text = leg } }, "leg.yml: a job a pull request runs names the runner `macos-15`");
    // the same leg, called by a workflow that is not started by a pull request, is the beta stage's business
    const push_caller = "name: gate\non:\n  push:\njobs:\n  call:\n    uses: ./.github/workflows/leg.yml\n";
    const f = try check(a, &.{ .{ .name = "gate.yml", .text = push_caller }, .{ .name = "leg.yml", .text = leg } });
    try t.expectEqual(@as(usize, 0), f.items.len);
    // a line that is not a local call names no workflow
    try t.expect(calledWorkflow("      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1") == null);
    try t.expectEqualStrings("leg.yml", calledWorkflow("    uses: ./.github/workflows/leg.yml").?);
}
