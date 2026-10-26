//! The lintian workflow (.github/workflows/lintian.yml) is what its header says it is: a daily run of lintian over the .deb of the command line that REPORTS and
//! never gates. lintian is a Perl program with dozens of distribution packages under it, none fetched by digest, so it cannot be a gate (ci.yml refuses an install
//! without an exact version, workflow_check.zig `aptInstalls`). A pure function of the text, so each rule is tested against an edited copy of the text as well as against the
//! real files (the zig_test's `data`, under BUILDRULES_TEST_WORK). The rules shared with the other workflows are workflow_check.zig's.
//!
//! What the rules catch:
//!  - a trigger that can block a change or touch a release: the triggers are exactly `schedule` (daily) and `workflow_dispatch`;
//!  - a token with more than it needs: `contents: read` alone, no other write scope, no secret, no environment, no id-token;
//!  - an action not pinned by commit or not GitHub's own; a buck2 that is not the release pinned in tools/buck2; a buck2 command not in local mode;
//!  - a lintian that no longer fails the run on an error (`--fail-on error`), or a second job;
//!  - the gate back: a `lintian` command in ci.yml or release.yml, or a call of lintian.yml in release.yml, would make the unpinned tool gate a pull request or a release.
const std = @import("std");
const wc = @import("workflow_check.zig");
const rc = @import("release_check.zig");
const t = std.testing;

const Findings = wc.Findings;
const add = wc.add;

const file = "lintian.yml";
const lintian_cmd = "lintian --fail-on error --tag-display-limit 0 ci-debs/buildrules_0.0.0_amd64.deb";

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn sameSet(got: []const []const u8, want: []const []const u8) bool {
    if (got.len != want.len) return false;
    for (want) |w| {
        var seen = false;
        for (got) |g| {
            if (std.mem.eql(u8, g, w)) seen = true;
        }
        if (!seen) return false;
    }
    return true;
}

/// Whether some command of `text` runs `lintian` (as a word, at the start of the command or after `sudo `, `&&` or `;`).
fn runsLintian(a: std.mem.Allocator, text: []const u8) !bool {
    for (try wc.commands(a, text)) |c| {
        var words = std.mem.tokenizeAny(u8, c, " \t");
        while (words.next()) |w| {
            if (std.mem.eql(u8, w, "lintian")) return true;
        }
    }
    return false;
}

/// Everything wrong with `raw`, given tools/buck2 (the dotslash file), ci.yml and release.yml.
pub fn check(a: std.mem.Allocator, raw: []const u8, dotslash: []const u8, ci: []const u8, release: []const u8) !Findings {
    var f = Findings.init(a);
    const wf = try rc.body(a, raw);

    try wc.noContinueOnError(a, &f, wf);
    try wc.noInlineContext(a, &f, wf);
    const uses = try wc.pinnedUses(a, &f, wf, &.{});
    if (uses == 0) try add(a, &f, "{s}: no `uses:` line found (this parser is blind)", .{file});
    var uit = std.mem.splitScalar(u8, wf, '\n');
    while (uit.next()) |line| {
        if (rc.usesRepo(line)) |repo| {
            if (!std.mem.startsWith(u8, repo, "actions/")) try add(a, &f, "{s}: the action `{s}` is not allowed (only GitHub's own `actions/` actions run here)", .{ file, repo });
        }
    }

    // Triggers: a schedule and a manual run, nothing that a change can start.
    const trig = try rc.triggers(a, wf);
    if (!sameSet(trig, &.{ "schedule", "workflow_dispatch" })) try add(a, &f, "{s}: the triggers are not exactly `schedule` and `workflow_dispatch` (got {d}): this workflow must never run on a pull request or a push", .{ file, trig.len });
    if (has(wf, "pull_request")) try add(a, &f, "{s}: a pull request trigger (or the word) is present", .{file});
    if (!has(wf, "  schedule:\n    - cron: \"")) {
        try add(a, &f, "{s}: no `schedule` with a cron entry", .{file});
    } else {
        const cron = wc.between(wf, "- cron: \"", "\"") orelse "";
        var fields = std.mem.tokenizeScalar(u8, cron, ' ');
        var n: usize = 0;
        var daily = true;
        while (fields.next()) |fld| : (n += 1) {
            if (n >= 2 and !std.mem.eql(u8, fld, "*")) daily = false;
        }
        if (n != 5 or !daily) try add(a, &f, "{s}: the cron `{s}` is not daily (day of month, month and day of week must be `*`)", .{ file, cron });
    }

    // The token reads the contents and nothing else.
    if (!has(wf, "\npermissions:\n  contents: read\n") or std.mem.count(u8, wf, "permissions:") != 1) try add(a, &f, "{s}: the permissions are not exactly one top-level `contents: read`", .{file});
    for ([_][]const u8{ ": write", "write-all", "secrets.", "environment:", "id-token" }) |bad| {
        if (has(wf, bad)) try add(a, &f, "{s}: `{s}` is present (the token reads the contents and nothing else)", .{ file, bad });
    }

    // One job, on the pinned buck2 in local mode, ending in the lintian run that fails on an error.
    const jobs = try rc.parseJobs(a, wf);
    if (jobs.len != 1) try add(a, &f, "{s}: the workflow has {d} jobs, not exactly one", .{ file, jobs.len });
    if ((try wc.localMode(a, &f, wf)) == 0) try add(a, &f, "{s}: no `./buck2 build` command found", .{file});
    try wc.buck2Install(a, &f, wf, dotslash);
    var runs: usize = 0;
    for (try wc.commands(a, wf)) |line| {
        // the command of a `run:` line, without the key
        var c = std.mem.trimLeft(u8, line, "- ");
        if (std.mem.startsWith(u8, c, "run:")) c = std.mem.trimLeft(u8, c["run:".len..], " ");
        var words = std.mem.tokenizeAny(u8, c, " \t");
        if (words.next()) |first| {
            if (std.mem.eql(u8, first, "lintian")) {
                runs += 1;
                if (!std.mem.eql(u8, c, lintian_cmd)) try add(a, &f, "{s}: the lintian command is not `{s}` (it must fail on an error and print every tag)", .{ file, lintian_cmd });
            }
        }
    }
    if (runs != 1) try add(a, &f, "{s}: lintian is run {d} times (exactly once)", .{ file, runs });

    // The unpinned tool gates nothing else.
    if (try runsLintian(a, ci)) try add(a, &f, "ci.yml runs lintian: an unpinned tool would gate every pull request and the release (it belongs in {s})", .{file});
    if (try runsLintian(a, release)) try add(a, &f, "release.yml runs lintian: an unpinned tool would gate the release (it belongs in {s})", .{file});
    if (has(release, "lintian.yml")) try add(a, &f, "release.yml names lintian.yml: an advisory must not be part of the release", .{});
    return f;
}

// ---- tests -----------------------------------------------------------------------------------------------------------------------------

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

const Real = struct { wf: []const u8, ds: []const u8, ci: []const u8, rel: []const u8 };

fn real(a: std.mem.Allocator) !Real {
    return .{
        .wf = try work(a, ".github/workflows/lintian.yml"),
        .ds = try work(a, "tools/buck2"),
        .ci = try work(a, ".github/workflows/ci.yml"),
        .rel = try work(a, ".github/workflows/release.yml"),
    };
}

fn mutate(a: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const i = std.mem.indexOf(u8, text, from) orelse return error.DefectDidNotApply;
    return std.mem.concat(a, u8, &.{ text[0..i], to, text[i + from.len ..] });
}

fn expectFinding(a: std.mem.Allocator, r: Real, wf: []const u8, ci: []const u8, rel: []const u8, needle: []const u8) !void {
    const f = try check(a, wf, r.ds, ci, rel);
    // a finding that holds the needle, else the test fails and prints the needle against the empty string
    var seen: []const u8 = "";
    for (f.items) |m| {
        if (has(m, needle)) seen = needle;
    }
    try t.expectEqualStrings(needle, seen);
}

fn expectDefect(a: std.mem.Allocator, r: Real, from: []const u8, to: []const u8, needle: []const u8) !void {
    try expectFinding(a, r, try mutate(a, r.wf, from, to), r.ci, r.rel, needle);
}

test "the real workflow has no findings" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const f = try check(a, r.wf, r.ds, r.ci, r.rel);
    for (f.items) |m| std.debug.print("lintian.yml finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "the parsers are not blind: the real file has the triggers, the job and the lintian command the rules read" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const wf = try rc.body(a, r.wf);
    try t.expectEqual(@as(usize, 2), (try rc.triggers(a, wf)).len);
    try t.expectEqual(@as(usize, 1), (try rc.parseJobs(a, wf)).len);
    try t.expect(try runsLintian(a, r.wf));
    try t.expect(!(try runsLintian(a, r.ci)));
    try t.expect(!(try runsLintian(a, "      # lintian is not run here\n      - run: echo lintian-free\n")));
}

test "a trigger a change can start is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectDefect(a, r, "on:\n  schedule:", "on:\n  pull_request:\n  schedule:", "triggers are not exactly");
    try expectDefect(a, r, "on:\n  schedule:", "on:\n  pull_request:\n  schedule:", "pull request trigger");
    try expectDefect(a, r, "on:\n  schedule:", "on:\n  push:\n  schedule:", "triggers are not exactly");
    try expectDefect(a, r, "  workflow_dispatch:\n", "", "triggers are not exactly");
    try expectDefect(a, r, "\"41 5 * * *\"", "\"41 5 * * 1\"", "is not daily");
    try expectDefect(a, r, "  schedule:\n    - cron: \"41 5 * * *\"\n", "  schedule:\n", "no `schedule` with a cron");
}

test "a token with more than the contents, or a job that is not alone, is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectDefect(a, r, "permissions:\n  contents: read\n\nconcurrency", "permissions:\n  contents: write\n\nconcurrency", "not exactly one top-level");
    try expectDefect(a, r, "    timeout-minutes: 120\n", "    timeout-minutes: 120\n    permissions:\n      id-token: write\n", "`id-token` is present");
    try expectDefect(a, r, "    timeout-minutes: 120\n", "    timeout-minutes: 120\n    environment: release\n", "`environment:` is present");
    try expectDefect(a, r, "\njobs:\n", "\njobs:\n  other:\n    runs-on: ubuntu-latest\n    steps:\n      - run: ./buck2 kill\n", "not exactly one");
}

test "an action not pinned by commit, a buck2 that drifted, or a build outside local mode is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectDefect(a, r, "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "actions/checkout@v4", "not pinned to a full commit");
    try expectDefect(a, r, "uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "uses: someone/else@3d3c42e5aac5ba805825da76410c181273ba90b1", "not allowed");
    try expectDefect(a, r, "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          persist-credentials: false\n", "      - run: true\n", "no `uses:` line found");
    try expectDefect(a, r, "1268fce33fb6", "0268fce33fb6", "sha256 pinned");
    try expectDefect(a, r, "build --console simple -c buildrules_re.mode=local --out ci-channels", "build --console simple --out ci-channels", "does not pass `-c buildrules_re.mode=local`");
}

test "a lintian that cannot fail, or that runs twice, is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectDefect(a, r, "lintian --fail-on error --tag-display-limit 0", "lintian --tag-display-limit 0", "lintian command is not");
    try expectDefect(a, r, "        run: lintian --fail-on error", "        run: lintian --fail-on error --tag-display-limit 0 ci-debs/buildrules_0.0.0_amd64.deb && lintian --fail-on error", "lintian command is not");
    try expectDefect(a, r, "      - name: lintian finds no error, every tag printed\n        run: " ++ lintian_cmd ++ "\n", "", "run 0 times");
}

test "the unpinned tool in the pull-request check or in the release is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const stop = "      - name: Stop buck2\n";
    try expectFinding(a, r, r.wf, try mutate(a, r.ci, stop, "      - run: lintian --fail-on error x.deb\n" ++ stop), r.rel, "ci.yml runs lintian");
    try expectFinding(a, r, r.wf, r.ci, try std.mem.concat(a, u8, &.{ r.rel, "      - run: sudo lintian x.deb\n" }), "release.yml runs lintian");
    try expectFinding(a, r, r.wf, r.ci, try std.mem.concat(a, u8, &.{ r.rel, "  lintian:\n    uses: ./.github/workflows/lintian.yml\n" }), "release.yml names lintian.yml");
}
