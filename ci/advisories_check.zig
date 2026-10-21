//! The advisory workflow (.github/workflows/advisories.yml) is what its header says it is: a daily scan of the lockfiles that REPORTS and never gates. A pure
//! function of the text, so each rule is tested against planted text as well as against the real file (the zig_test's `data`, under BUILDRULES_TEST_WORK). The
//! rules shared with the other workflows (actions pinned by commit, no `continue-on-error`, no inline expansion of `vars.` or `github.event.` in a `run:`) are
//! workflow_check.zig's; the job parser is release_check.zig's.
//!
//! What the rules catch:
//!  - a trigger that can block a change or touch a release: the triggers are exactly `schedule` (daily) and `workflow_dispatch`; no pull request, push or other;
//!  - a token with more than it needs: the top level grants `contents: read` alone, the one job `contents: read` and `issues: write` alone, and no other write
//!    scope or `write-all` appears anywhere;
//!  - a third-party action: every `uses:` is an `actions/` action pinned by commit;
//!  - an unpinned or unverified tool: the OSV-Scanner url is the one in rules/pins/pins.bzl, downloaded once, checked with `sha256sum --check --strict` against
//!    the sha256 of that row before it is made executable and run, and the file the farm fetched for that row hashes to the workflow's sha256;
//!  - a scan that gates: the scanner's exit code 1 (a finding) is absorbed, any other code fails the job (the scan could not run), and no other `exit` exists,
//!    so a finding can never turn the run red;
//!  - the report: findings go to the job summary and to ONE issue titled `Advisories` (found in any state, created once, edited, reopened; closed when there
//!    are none), and the workflow runs no other `gh` command.
const std = @import("std");
const wc = @import("workflow_check.zig");
const rc = @import("release_check.zig");
const t = std.testing;

const Findings = wc.Findings;
const add = wc.add;

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

const file = "advisories.yml";

const scan_prefix = "./osv-scanner scan ";
const scan_suffix = " || rc=$?";
const scan_guard = "if [ \"$rc\" -gt 1 ]; then exit \"$rc\"; fi";
const install_check = "sha256sum --check --strict -";
const tool_name = "osv-scanner";

/// The lines of the top-level block `key:` (column 0), trimmed, up to the next line in column 0.
fn topLines(a: std.mem.Allocator, wf: []const u8, key: []const u8) !?[]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var found = false;
    var seen = false;
    var it = std.mem.splitScalar(u8, wf, '\n');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \r");
        if (trimmed.len == 0) continue;
        if (raw[0] != ' ') {
            found = std.mem.eql(u8, std.mem.trimRight(u8, raw, " \r"), key);
            if (found) seen = true;
            continue;
        }
        if (found) try out.append(trimmed);
    }
    if (!seen) return null;
    return try out.toOwnedSlice();
}

/// Whether `want` is exactly the set of lines `got`.
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

/// The `url` and `sha256` of the `osv_scanner` row of rules/pins/pins.bzl.
pub const Row = struct { url: []const u8, sha256: []const u8 };

pub fn pinRow(pins: []const u8) ?Row {
    const at = std.mem.indexOf(u8, pins, "\"osv_scanner\": {") orelse return null;
    const rest = pins[at..];
    const end = std.mem.indexOf(u8, rest, "\n    },") orelse rest.len;
    const block = rest[0..end];
    const url = wc.between(block, "\"url\": \"", "\"") orelse return null;
    const sha = wc.between(block, "\"sha256\": \"", "\"") orelse return null;
    return .{ .url = url, .sha256 = sha };
}

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

/// The lowercase hex sha256 of `bytes`.
pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Every `gh` command inside `c` (at its start, or after a space, `(`, `;` or a quote) is one of the issue subcommands this workflow uses.
fn ghUses(a: std.mem.Allocator, f: *Findings, c: []const u8) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, c, pos, "gh ")) |i| {
        pos = i + 1;
        if (i > 0 and !has(" (;\"", c[i - 1 .. i])) continue;
        var ok = false;
        for ([_][]const u8{ "gh issue list ", "gh issue view ", "gh issue create ", "gh issue edit ", "gh issue reopen ", "gh issue close " }) |p| {
            if (std.mem.startsWith(u8, c[i..], p)) ok = true;
        }
        if (!ok) try add(a, f, "{s}: `{s}`: only `gh issue list|view|create|edit|reopen|close` may run", .{ file, c });
    }
}

/// Everything wrong with `raw`, given rules/pins/pins.bzl.
pub fn check(a: std.mem.Allocator, raw: []const u8, pins: []const u8) !Findings {
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

    // Permissions: the top level reads contents; the one job also writes issues; nothing else writes.
    const top = try topLines(a, wf, "permissions:");
    if (top == null or !sameSet(top.?, &.{"contents: read"})) try add(a, &f, "{s}: the top-level permissions are not exactly `contents: read`", .{file});
    if (has(wf, "write-all")) try add(a, &f, "{s}: `write-all` is granted", .{file});
    const jobs = try rc.parseJobs(a, wf);
    if (jobs.len != 1) try add(a, &f, "{s}: the workflow has {d} jobs, not exactly one", .{ file, jobs.len });
    if (rc.jobNamed(jobs, "scan")) |j| {
        if (j.perms.items.len != 2 or !std.mem.eql(u8, rc.permLevel(j, "contents") orelse "", "read") or !std.mem.eql(u8, rc.permLevel(j, "issues") orelse "", "write"))
            try add(a, &f, "{s}: job `scan` permissions are not exactly `contents: read` and `issues: write`", .{file});
    } else try add(a, &f, "{s}: no job `scan`", .{file});
    var wit = std.mem.splitScalar(u8, wf, '\n');
    while (wit.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (has(line, ": write") and !std.mem.eql(u8, line, "issues: write")) try add(a, &f, "{s}: the write permission `{s}` (only `issues: write` in the job)", .{ file, line });
    }
    if (count(wf, "issues: write") != 1) try add(a, &f, "{s}: `issues: write` is not granted exactly once", .{file});
    if (has(wf, "secrets.")) try add(a, &f, "{s}: the workflow reads a secret (it uses the job's own token)", .{file});

    // The tool: the pinned release, hashed before it runs.
    const row = pinRow(pins) orelse {
        try add(a, &f, "{s}: no `osv_scanner` row in rules/pins/pins.bzl", .{file});
        return f;
    };
    if (!isHex64(row.sha256)) try add(a, &f, "{s}: the sha256 of the `osv_scanner` row is not 64 lowercase hex digits", .{file});
    const cmds = try wc.commands(a, wf);
    var curls: usize = 0;
    var fetched: ?usize = null;
    var checked: ?usize = null;
    var scans: usize = 0;
    var scan_at: ?usize = null;
    var chmod_at: ?usize = null;
    for (cmds, 0..) |c, i| {
        if (std.mem.startsWith(u8, c, "curl ")) {
            curls += 1;
            fetched = i;
            if (!has(c, " --output osv-scanner ")) try add(a, &f, "{s}: the download is not written to `osv-scanner`", .{file});
            if (!has(c, row.url) or !std.mem.endsWith(u8, c, row.url)) try add(a, &f, "{s}: the download url is not the `osv_scanner` url of rules/pins/pins.bzl", .{file});
        }
        if (has(c, install_check)) {
            checked = i;
            const want = try std.fmt.allocPrint(a, "echo \"{s}  {s}\" | {s}", .{ row.sha256, tool_name, install_check });
            if (!std.mem.eql(u8, c, want)) try add(a, &f, "{s}: the check is not `{s}` (the sha256 of the pins.bzl row, strict)", .{ file, want });
        }
        if (std.mem.eql(u8, c, "chmod +x osv-scanner")) chmod_at = i;
        if (std.mem.startsWith(u8, c, scan_prefix)) {
            scans += 1;
            scan_at = i;
            if (!std.mem.endsWith(u8, c, scan_suffix)) try add(a, &f, "{s}: the scan command does not absorb its exit code (`{s}`): a finding would fail the job", .{ file, scan_suffix });
            if (i == 0 or !std.mem.eql(u8, cmds[i - 1], "rc=0")) try add(a, &f, "{s}: `rc=0` does not precede the scan", .{file});
            if (i + 1 >= cmds.len or !std.mem.eql(u8, cmds[i + 1], scan_guard)) try add(a, &f, "{s}: the scan is not followed by `{s}` (only a scan that could not run fails the job)", .{ file, scan_guard });
        }
        if (has(c, "exit") and !std.mem.eql(u8, c, scan_guard)) try add(a, &f, "{s}: `exit` in `{s}` (the only exit is the scan guard; a finding must never fail the run)", .{ file, c });
        try ghUses(a, &f, c);
    }
    if (curls != 1) try add(a, &f, "{s}: {d} downloads (exactly one, the pinned scanner)", .{ file, curls });
    if (checked == null) try add(a, &f, "{s}: the downloaded scanner is never checked with `{s}`", .{ file, install_check });
    if (scans != 1) try add(a, &f, "{s}: {d} scan commands (exactly one `{s}...`)", .{ file, scans, scan_prefix });
    if (fetched != null and checked != null and scan_at != null and chmod_at != null) {
        if (!(fetched.? < checked.? and checked.? < chmod_at.? and chmod_at.? < scan_at.?))
            try add(a, &f, "{s}: the order is not download, check, `chmod +x`, scan (the hash is checked before the file can run)", .{file});
    } else try add(a, &f, "{s}: the download, the check, `chmod +x osv-scanner` or the scan is missing", .{file});

    // What it scans, and where it reports.
    if (!has(wf, "git ls-files -z -- ':(glob)**/package-lock.json' ':(glob)**/Cargo.lock'")) try add(a, &f, "{s}: the scan does not list every `package-lock.json` and `Cargo.lock` of the tree", .{file});
    // A fixture directory is a test input: an advisory in one could never be fixed by a change here, and the issue would stay open for good. The beta templates are repos users copy and their lockfiles are ours to bump, so they are scanned: no exclusion of beta/ is allowed.
    if (!has(wf, "':(exclude,glob)**/fixture/**'")) try add(a, &f, "{s}: the scan does not exclude test inputs with ':(exclude,glob)**/fixture/**'", .{file});
    if (has(wf, "exclude,glob)beta") or has(wf, "exclude)beta")) try add(a, &f, "{s}: the scan excludes the beta templates (their lockfiles are ours to bump: scan them)", .{file});

    // The job token is on the report step alone: not at workflow or job level, where the downloaded scanner would run with it.
    const tokens = ghTokenKeys(wf);
    if (tokens != 1) try add(a, &f, "{s}: `GH_TOKEN:` is set {d} times, in any spelling (exactly once, on the Report step)", .{ file, tokens });
    if (std.mem.indexOf(u8, wf, "\n          GH_TOKEN: ${{ github.token }}\n")) |at| {
        const report = std.mem.indexOf(u8, wf, "      - name: Report\n        env:\n") orelse wf.len;
        if (at < report or at > report + 40) try add(a, &f, "{s}: `GH_TOKEN` is not in the env of the Report step", .{file});
    } else try add(a, &f, "{s}: `GH_TOKEN: ${{{{ github.token }}}}` is not set in a step env (10 spaces: step level, not job or workflow level)", .{file});

    // Nothing can switch the job or a step off: a skipped scan is a green run that scanned nothing.
    var iflines = std.mem.splitScalar(u8, wf, '\n');
    while (iflines.next()) |raw_line| {
        const line = std.mem.trimLeft(u8, std.mem.trim(u8, raw_line, " \r"), "- ");
        if (std.mem.startsWith(u8, line, "if:")) try add(a, &f, "{s}: `{s}`: no `if:` on the job or a step (the scan must always run)", .{ file, line });
    }
    for ([_][]const u8{
        "title=Advisories",
        "gh issue list --state all",
        "gh issue create --title \"$title\" --body-file body.md",
        "gh issue edit \"$number\" --body-file body.md",
        "gh issue reopen \"$number\"",
        "gh issue close \"$number\"",
        "cat body.md >> \"$GITHUB_STEP_SUMMARY\"",
    }) |need| {
        if (!has(wf, need)) try add(a, &f, "{s}: missing `{s}`", .{ file, need });
    }
    if (count(wf, "gh issue create") != 1) try add(a, &f, "{s}: `gh issue create` is not used exactly once (one issue, ever)", .{file});
    return f;
}

// Every `GH_TOKEN` followed by an optional quote, optional blanks and a colon: a plain, a double-quoted and a single-quoted key (also in a flow map). `$GH_TOKEN` in a script has no colon.
fn ghTokenKeys(wf: []const u8) usize {
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, wf, from, "GH_TOKEN")) |at| {
        from = at + "GH_TOKEN".len;
        var i = from;
        if (i < wf.len and (wf[i] == '"' or wf[i] == '\'')) i += 1;
        while (i < wf.len and (wf[i] == ' ' or wf[i] == '\t')) i += 1;
        if (i < wf.len and wf[i] == ':') n += 1;
    }
    return n;
}

fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

// ---- tests -----------------------------------------------------------------------------------------------------------------------------

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

const Real = struct { wf: []const u8, pins: []const u8 };

fn real(a: std.mem.Allocator) !Real {
    return .{ .wf = try work(a, ".github/workflows/advisories.yml"), .pins = try work(a, "rules/pins/pins.bzl") };
}

/// `text` with the first `from` replaced by `to`; fails the test if `from` is absent (a mutant that changes nothing proves nothing).
fn mutate(a: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const i = std.mem.indexOf(u8, text, from) orelse return error.MutantDidNotApply;
    return std.mem.concat(a, u8, &.{ text[0..i], to, text[i + from.len ..] });
}

fn expectFinding(a: std.mem.Allocator, wf: []const u8, pins: []const u8, needle: []const u8) !void {
    const f = try check(a, wf, pins);
    for (f.items) |m| {
        if (has(m, needle)) return;
    }
    std.debug.print("advisories.yml: expected a finding with `{s}`, got {d}:\n", .{ needle, f.items.len });
    for (f.items) |m| std.debug.print("  {s}\n", .{m});
    return error.MutantSurvived;
}

fn expectMutant(a: std.mem.Allocator, r: Real, from: []const u8, to: []const u8, needle: []const u8) !void {
    try expectFinding(a, try mutate(a, r.wf, from, to), r.pins, needle);
}

test "the real workflow has no findings" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const f = try check(a, r.wf, r.pins);
    for (f.items) |m| std.debug.print("advisories.yml finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "the parsers are not blind: the real file has the triggers, the job and the commands the rules read" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const wf = try rc.body(a, r.wf);
    try t.expectEqual(@as(usize, 2), (try rc.triggers(a, wf)).len);
    const jobs = try rc.parseJobs(a, wf);
    try t.expectEqual(@as(usize, 1), jobs.len);
    try t.expectEqual(@as(usize, 2), jobs[0].perms.items.len);
    try t.expectEqual(@as(usize, 1), (try topLines(a, wf, "permissions:")).?.len);
    try t.expect((try topLines(a, wf, "nothing:")) == null);
    try t.expect(pinRow(r.pins) != null);
    try t.expect(pinRow("PINS = {}") == null);
    var curls: usize = 0;
    for (try wc.commands(a, wf)) |c| {
        if (std.mem.startsWith(u8, c, "curl ")) curls += 1;
    }
    try t.expectEqual(@as(usize, 1), curls);
}

test "the file the farm fetched for the pins.bzl row hashes to the sha256 the workflow checks" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, "tools/osv-scanner" });
    const bytes = try std.fs.cwd().readFileAlloc(a, p, 200 << 20);
    const got = sha256Hex(bytes);
    const want = wc.between(r.wf, "echo \"", "  osv-scanner\"") orelse return error.WorkflowHasNoHash;
    try t.expectEqualStrings(want, &got);
    try t.expectEqualStrings(pinRow(r.pins).?.sha256, &got);
    // A single changed byte is a different hash: the comparison is not vacuous.
    var other = try a.dupe(u8, bytes[0..4096]);
    other[0] ^= 1;
    try t.expect(!std.mem.eql(u8, want, &sha256Hex(other)));
}

test "mutant: a trigger a change can start" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectMutant(a, r, "on:\n  schedule:", "on:\n  pull_request:\n  schedule:", "triggers are not exactly");
    try expectMutant(a, r, "on:\n  schedule:", "on:\n  pull_request:\n  schedule:", "pull request trigger");
    try expectMutant(a, r, "on:\n  schedule:", "on:\n  push:\n  schedule:", "triggers are not exactly");
    try expectMutant(a, r, "on:\n  schedule:", "on:\n  workflow_run:\n  schedule:", "triggers are not exactly");
    try expectMutant(a, r, "  workflow_dispatch:\n", "", "triggers are not exactly");
    try expectMutant(a, r, "  schedule:\n    - cron: \"17 5 * * *\"\n", "", "triggers are not exactly");
    try expectMutant(a, r, "on:\n  schedule:\n    - cron: \"17 5 * * *\"\n  workflow_dispatch:", "on:\n  schedule:\n  workflow_dispatch:", "no `schedule` with a cron");
    try expectMutant(a, r, "\"17 5 * * *\"", "\"17 5 * * 1\"", "is not daily");
    try expectMutant(a, r, "\"17 5 * * *\"", "\"17 5 1 * *\"", "is not daily");
    try expectMutant(a, r, "\"17 5 * * *\"", "\"17 5 * *\"", "is not daily");
}

test "mutant: the token is on the report step alone" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    // GH_TOKEN moved to job level (the original shape), added there, added to the workflow, or put on the scan step.
    try expectMutant(a, r, "    steps:\n", "    env:\n      GH_TOKEN: ${{ github.token }}\n    steps:\n", "is set 2 times");
    try expectMutant(a, r, "    steps:\n      - uses", "    env:\n      GH_TOKEN: ${{ github.token }}\n    steps:\n      - uses", "is set 2 times");
    try expectMutant(a, r, "        env:\n          GH_TOKEN: ${{ github.token }}\n", "", "is not set in a step env");
    try expectMutant(a, r, "name: advisories\n", "name: advisories\nenv:\n  GH_TOKEN: ${{ github.token }}\n", "is set 2 times");
    try expectMutant(a, r, "    steps:\n", "    env:\n      \"GH_TOKEN\": ${{ github.token }}\n    steps:\n", "in any spelling");
    try expectMutant(a, r, "    steps:\n", "    env:\n      'GH_TOKEN': ${{ github.token }}\n    steps:\n", "in any spelling");
    try expectMutant(a, r, "    steps:\n", "    env: { \"GH_TOKEN\" : ${{ github.token }} }\n    steps:\n", "in any spelling");
    try expectMutant(a, r, "      - name: Scan the lockfiles\n        run: |", "      - name: Scan the lockfiles\n        env:\n          GH_TOKEN: ${{ github.token }}\n        run: |", "is set 2 times");
    // The token moved wholesale off the report step onto the scan step.
    try expectMutant(a, r, "      - name: Report\n        env:\n          GH_TOKEN: ${{ github.token }}\n        run: |", "      - name: Report\n        run: |", "is not set in a step env");
}

test "mutant: a token with more than it needs" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectMutant(a, r, "permissions:\n  contents: read\n\nconcurrency", "permissions:\n  contents: write\n\nconcurrency", "top-level permissions are not exactly");
    try expectMutant(a, r, "permissions:\n  contents: read\n\nconcurrency", "permissions:\n  contents: read\n  pull-requests: read\n\nconcurrency", "top-level permissions are not exactly");
    try expectMutant(a, r, "permissions:\n  contents: read\n\nconcurrency", "permissions: write-all\n\nconcurrency", "`write-all`");
    try expectMutant(a, r, "permissions:\n  contents: read\n\nconcurrency", "concurrency", "top-level permissions are not exactly");
    try expectMutant(a, r, "      issues: write\n", "      issues: write\n      contents: write\n", "job `scan` permissions are not exactly");
    try expectMutant(a, r, "      issues: write\n", "      issues: write\n      id-token: write\n", "the write permission `id-token: write`");
    try expectMutant(a, r, "      issues: write\n", "      issues: read\n", "job `scan` permissions are not exactly");
    try expectMutant(a, r, "      issues: write\n", "", "job `scan` permissions are not exactly");
    try expectMutant(a, r, "    permissions:\n      contents: read\n      issues: write\n", "", "job `scan` permissions are not exactly");
    try expectMutant(a, r, "          GH_TOKEN: ${{ github.token }}", "          GH_TOKEN: ${{ secrets.ADVISORIES_TOKEN }}", "reads a secret");
    try expectMutant(a, r, "  scan:\n", "  extra:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n  scan:\n", "not exactly one");
}

test "mutant: a third-party or unpinned action" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectMutant(a, r, "      - name: Report\n", "      - uses: someone/scan@3d3c42e5aac5ba805825da76410c181273ba90b1\n      - name: Report\n", "is not allowed");
    try expectMutant(a, r, "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "actions/checkout@v7", "not pinned to a full commit sha");
    try expectMutant(a, r, "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          persist-credentials: false\n\n", "\n", "no `uses:` line found");
}

test "mutant: an unpinned or unverified tool" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const sha = pinRow(r.pins).?.sha256;
    // The workflow drifts from the table.
    try expectMutant(a, r, "download/v2.7.0/", "download/v2.6.0/", "not the `osv_scanner` url");
    try expectMutant(a, r, "releases/download/v2.7.0/osv-scanner_linux_amd64\n", "releases/latest/download/osv-scanner_linux_amd64\n", "not the `osv_scanner` url");
    try expectMutant(a, r, sha, "0000000000000000000000000000000000000000000000000000000000000000", "the sha256 of the pins.bzl row");
    // The table drifts from the workflow.
    try expectFinding(a, r.wf, try mutate(a, r.pins, sha, "1111111111111111111111111111111111111111111111111111111111111111"), "the sha256 of the pins.bzl row");
    try expectFinding(a, r.wf, try mutate(a, r.pins, "download/v2.7.0/", "download/v2.6.0/"), "not the `osv_scanner` url");
    try expectFinding(a, r.wf, try mutate(a, r.pins, sha, "ABC"), "not 64 lowercase hex");
    try expectFinding(a, r.wf, try mutate(a, r.pins, "\"osv_scanner\"", "\"other\""), "no `osv_scanner` row");
    // The check is weakened or gone.
    try expectMutant(a, r, " | sha256sum --check --strict -", " | sha256sum --check -", "never checked");
    try expectMutant(a, r, "  osv-scanner\" | sha256sum --check --strict -", "  osv-scanner\" | sha256sum --check --strict - # skipped\n          echo \"x\" | sha256sum --check --strict -", "the check is not");
    const check_line = try std.fmt.allocPrint(a, "          echo \"{s}  osv-scanner\" | sha256sum --check --strict -\n", .{sha});
    try expectMutant(a, r, check_line, "", "never checked");
    try expectMutant(a, r, "  osv-scanner\" | sha256sum", "  other\" | sha256sum", "the check is not");
    // A second download, an unnamed output, an order that runs the file before the check.
    try expectMutant(a, r, "          chmod +x osv-scanner\n", "          chmod +x osv-scanner\n          curl --fail --output other https://example.org/x\n", "2 downloads");
    try expectMutant(a, r, "--output osv-scanner \\", "--output scanner \\", "not written to `osv-scanner`");
    try expectMutant(a, r, "          chmod +x osv-scanner\n", "", "missing");
    try expectMutant(a, r, try std.mem.concat(a, u8, &.{ check_line, "          chmod +x osv-scanner\n" }), try std.mem.concat(a, u8, &.{ "          chmod +x osv-scanner\n", check_line }), "the order is not");
}

test "mutant: a scan that gates" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectMutant(a, r, " \"$@\" || rc=$?", " \"$@\"", "does not absorb its exit code");
    try expectMutant(a, r, "if [ \"$rc\" -gt 1 ]; then exit \"$rc\"; fi", "if [ \"$rc\" -gt 0 ]; then exit \"$rc\"; fi", "is not followed by");
    try expectMutant(a, r, "if [ \"$rc\" -gt 1 ]; then exit \"$rc\"; fi\n", "", "is not followed by");
    try expectMutant(a, r, "          rc=0\n", "", "`rc=0` does not precede");
    try expectMutant(a, r, "          echo \"FOUND=$rc\" >> \"$GITHUB_ENV\"\n", "          echo \"FOUND=$rc\" >> \"$GITHUB_ENV\"\n          exit 1\n", "the only exit is the scan guard");
    try expectMutant(a, r, "          set -euo pipefail\n          title=Advisories", "          set -euo pipefail\n          test \"$FOUND\" = 0 || exit 3\n          title=Advisories", "the only exit is the scan guard");
    try expectMutant(a, r, "    timeout-minutes: 20\n", "    timeout-minutes: 20\n    continue-on-error: true\n", "`continue-on-error` is set to `true`");
    try expectMutant(a, r, "      - name: Scan the lockfiles\n", "      - name: Scan the lockfiles\n        continue-on-error: true\n", "`continue-on-error` is set to `true`");
    try expectMutant(a, r, "':(glob)**/package-lock.json' ':(glob)**/Cargo.lock'", "':(glob)**/package-lock.json'", "does not list every");
    try expectMutant(a, r, " ':(exclude,glob)**/fixture/**'", "", "does not exclude test inputs");
    try expectMutant(a, r, " ':(exclude,glob)**/fixture/**'", " ':(exclude,glob)**/fixture/**' ':(exclude,glob)beta/**'", "excludes the beta templates");
    try expectMutant(a, r, "    timeout-minutes: 20\n", "    timeout-minutes: 20\n    continue-on-error: ${{ github.run_attempt }}\n", "`continue-on-error` is set to");
    try expectMutant(a, r, "    timeout-minutes: 20\n", "    timeout-minutes: 20\n    continue-on-error: 'true'\n", "`continue-on-error` is set to");
    try expectMutant(a, r, "    timeout-minutes: 20\n", "    timeout-minutes: 20\n    if: github.event_name == 'schedule'\n", "no `if:` on the job");
    try expectMutant(a, r, "      - name: Scan the lockfiles\n", "      - name: Scan the lockfiles\n        if: false\n", "no `if:` on the job");
    try expectMutant(a, r, "      - name: Report\n        env:", "      - if: always()\n        name: Report\n        env:", "no `if:` on the job");
}

test "mutant: a report that is not one issue" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectMutant(a, r, "title=Advisories", "title=Findings", "missing `title=Advisories`");
    try expectMutant(a, r, "gh issue list --state all", "gh issue list --state open", "missing `gh issue list --state all`");
    try expectMutant(a, r, "gh issue reopen \"$number\"", "true", "missing `gh issue reopen");
    try expectMutant(a, r, "gh issue close \"$number\"", "true", "missing `gh issue close");
    try expectMutant(a, r, "gh issue edit \"$number\" --body-file body.md", "true", "missing `gh issue edit");
    try expectMutant(a, r, "            cat body.md >> \"$GITHUB_STEP_SUMMARY\"\n", "", "missing `cat body.md >> ");
    try expectMutant(a, r, "gh issue edit \"$number\" --body-file body.md", "gh issue create --title \"$title\" --body-file body.md", "not used exactly once");
    try expectMutant(a, r, "gh issue create --title \"$title\" --body-file body.md", "gh issue create --title \"$title\" --body-file body.md; gh issue delete 1", "only `gh issue list");
    try expectMutant(a, r, "gh issue close \"$number\" --comment", "gh pr create --title x --body y; gh issue close \"$number\" --comment", "only `gh issue list");
    try expectMutant(a, r, "          set -euo pipefail\n          title=Advisories", "          set -euo pipefail\n          gh api -X DELETE repos/o/r\n          title=Advisories", "only `gh issue list");
    try expectMutant(a, r, "          set -euo pipefail\n          title=Advisories", "          set -euo pipefail\n          gh workflow run ci.yml\n          title=Advisories", "only `gh issue list");
    try expectMutant(a, r, "            gh issue create", "            gh issue create --repo x", "missing `gh issue create --title");
}

test "mutant: an inline expansion of event data" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectMutant(a, r, "          title=Advisories", "          echo ${{ github.event.inputs.x }}\n          title=Advisories", "expands `github.event.` inline");
}
