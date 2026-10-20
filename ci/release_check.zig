//! The release workflow (.github/workflows/release.yml) is what RELEASING.md says it is. A pure function of the text, so each rule is tested
//! against planted text as well as against the real files (the zig_test's `data`, under BUILDRULES_TEST_WORK). The rules that release.yml
//! shares with ci.yml (actions pinned by commit, local mode on every buck2 command, the pinned buck2 install) are the ones in
//! workflow_check.zig; what is here is what only the release has:
//!
//!  - the triggers: a push to main and nothing else (no pull request, no dispatch, no schedule, no workflow_run);
//!  - the token: `permissions: {}` at the top, every job states its own, and a write scope only where it belongs: `contents: write` in the
//!    jobs `tag` and `publish` (and nowhere else), `id-token: write` and `attestations: write` in `archive` (and nowhere else), each of
//!    `tag` and `publish` under its exact `if:`, and every `: write` of the file accounted for by a job's permissions block;
//!  - the order publish <- verify <- archive <- tag <- gate, with gate a call of ci.yml that nothing can skip, a release made only when
//!    the tag job released, and no status function (`always()`, `failure()`, `cancelled()`) that would let a job run after a red one;
//!  - the jobs that write run no buck2 and only the checkout and download actions: the tool they run was built before any token existed;
//!  - the attestation action is in `archive` only, every checkout drops its credentials, `run:` lines are single invocations (the
//!    install of buck2 aside), no asset is ever replaced (`--clobber`), no secret is read.
const std = @import("std");
const wc = @import("workflow_check.zig");
const t = std.testing;

const Findings = wc.Findings;
const add = wc.add;

pub const tag_if = "${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork }}";
pub const publish_if = "${{ needs.tag.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork }}";
/// archive and verify run only for a commit the tag job released.
const released_clause = "needs.tag.outputs.released == 'true'";
const ci_call = "./.github/workflows/ci.yml";
const tool_target = "//tools/release:release";

/// The jobs, and the job each one must wait for (`needs`).
const order = [_][2][]const u8{
    .{ "tag", "gate" },
    .{ "archive", "tag" },
    .{ "verify", "archive" },
    .{ "publish", "verify" },
};
const all_jobs = [_][]const u8{ "gate", "tool", "tag", "archive", "verify", "publish" };
/// What each job runs of the tool.
const tool_runs = [_][2][]const u8{
    .{ "tag", "tool/release tag " },
    .{ "archive", "tool/release archive " },
    .{ "verify", "tool/release verify " },
    .{ "publish", "tool/release publish " },
};
/// The actions a job that writes may use.
const write_job_actions = [_][]const u8{ "actions/checkout", "actions/download-artifact" };

const Perm = struct { scope: []const u8, level: []const u8 };

const Job = struct {
    name: []const u8,
    lines: std.ArrayList([]const u8),
    needs: std.ArrayList([]const u8),
    perms: std.ArrayList(Perm),
    has_perms: bool = false,
    if_expr: ?[]const u8 = null,
    uses: ?[]const u8 = null,
    group: ?[]const u8 = null,
    cancel: ?[]const u8 = null,

    fn text(self: Job, a: std.mem.Allocator) ![]u8 {
        return std.mem.join(a, "\n", self.lines.items);
    }
};

fn indentOf(line: []const u8) usize {
    return line.len - std.mem.trimLeft(u8, line, " ").len;
}

fn isComment(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trim(u8, line, " \r"), "#");
}

/// The text without its comment lines: what the rules count in (a header comment names `contents: write` too).
fn body(a: std.mem.Allocator, wf: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var it = std.mem.splitScalar(u8, wf, '\n');
    while (it.next()) |line| {
        if (isComment(line)) continue;
        try out.appendSlice(line);
        try out.append('\n');
    }
    return out.toOwnedSlice();
}

fn stripComment(v: []const u8) []const u8 {
    if (std.mem.indexOf(u8, v, " #")) |i| return std.mem.trim(u8, v[0..i], " ");
    return std.mem.trim(u8, v, " ");
}

/// The jobs of the `jobs:` block, with what the rules read of each (its direct keys, its permissions and concurrency blocks).
fn parseJobs(a: std.mem.Allocator, wf: []const u8) ![]Job {
    var jobs = std.ArrayList(Job).init(a);
    var in_jobs = false;
    const Mode = enum { none, perms, conc };
    var mode: Mode = .none;
    var it = std.mem.splitScalar(u8, wf, '\n');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const ind = indentOf(raw);
        if (ind == 0) {
            in_jobs = std.mem.eql(u8, trimmed, "jobs:");
            continue;
        }
        if (!in_jobs) continue;
        if (ind == 2 and std.mem.endsWith(u8, trimmed, ":") and std.mem.indexOfScalar(u8, trimmed, ' ') == null) {
            try jobs.append(.{
                .name = trimmed[0 .. trimmed.len - 1],
                .lines = std.ArrayList([]const u8).init(a),
                .needs = std.ArrayList([]const u8).init(a),
                .perms = std.ArrayList(Perm).init(a),
            });
            mode = .none;
            continue;
        }
        if (jobs.items.len == 0) continue;
        var j = &jobs.items[jobs.items.len - 1];
        try j.lines.append(trimmed);
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse continue;
        const key = trimmed[0..colon];
        const val = std.mem.trim(u8, trimmed[colon + 1 ..], " ");
        if (ind == 4) {
            mode = .none;
            if (std.mem.eql(u8, key, "needs")) {
                var names = std.mem.tokenizeAny(u8, std.mem.trim(u8, val, "[]"), ", ");
                while (names.next()) |n| try j.needs.append(n);
            } else if (std.mem.eql(u8, key, "if")) {
                j.if_expr = val;
            } else if (std.mem.eql(u8, key, "uses")) {
                j.uses = stripComment(val);
            } else if (std.mem.eql(u8, key, "permissions")) {
                j.has_perms = true;
                mode = .perms;
            } else if (std.mem.eql(u8, key, "concurrency")) {
                mode = .conc;
            }
        } else if (ind == 6) {
            switch (mode) {
                .perms => try j.perms.append(.{ .scope = key, .level = stripComment(val) }),
                .conc => {
                    if (std.mem.eql(u8, key, "group")) j.group = stripComment(val);
                    if (std.mem.eql(u8, key, "cancel-in-progress")) j.cancel = stripComment(val);
                },
                .none => {},
            }
        }
    }
    return jobs.toOwnedSlice();
}

fn jobNamed(jobs: []Job, name: []const u8) ?*Job {
    for (jobs) |*j| {
        if (std.mem.eql(u8, j.name, name)) return j;
    }
    return null;
}

fn hasNeed(j: *const Job, name: []const u8) bool {
    for (j.needs.items) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn permLevel(j: *const Job, scope: []const u8) ?[]const u8 {
    for (j.perms.items) |p| {
        if (std.mem.eql(u8, p.scope, scope)) return p.level;
    }
    return null;
}

/// Whether a job may hold `scope: write`.
fn writeAllowed(job: []const u8, scope: []const u8) bool {
    if (std.mem.eql(u8, scope, "contents")) return std.mem.eql(u8, job, "tag") or std.mem.eql(u8, job, "publish");
    if (std.mem.eql(u8, scope, "id-token") or std.mem.eql(u8, scope, "attestations")) return std.mem.eql(u8, job, "archive");
    return false;
}

/// The keys of the `on:` block (its direct children).
fn triggers(a: std.mem.Allocator, wf: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var in_on = false;
    var it = std.mem.splitScalar(u8, wf, '\n');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const ind = indentOf(raw);
        if (ind == 0) {
            in_on = std.mem.eql(u8, trimmed, "on:");
            continue;
        }
        if (in_on and ind == 2) try out.append(std.mem.trimRight(u8, trimmed, ":"));
    }
    return out.toOwnedSlice();
}

fn usesRepo(line: []const u8) ?[]const u8 {
    const l = std.mem.trim(u8, line, " -");
    if (!std.mem.startsWith(u8, l, "uses:")) return null;
    const v = stripComment(l["uses:".len..]);
    return v[0 .. std.mem.indexOfScalar(u8, v, '@') orelse v.len];
}

/// Everything wrong with `wf` (release.yml), given the dotslash file of the pinned buck2 and ci.yml.
pub fn checkRelease(a: std.mem.Allocator, wf: []const u8, dotslash: []const u8, ci_yml: []const u8) !Findings {
    var f = Findings.init(a);
    const text = try body(a, wf);

    // Actions: every `uses:` pinned to a commit, but the call of ci.yml; a checkout drops its credentials.
    const uses = try wc.pinnedUses(a, &f, text, ci_call);
    if (uses == 0) try add(a, &f, "no `uses:` line found (this parser is blind)", .{});
    if (std.mem.count(u8, text, "actions/checkout@") != std.mem.count(u8, text, "persist-credentials: false"))
        try add(a, &f, "a checkout keeps the token in the checkout (`persist-credentials: false` is missing)", .{});

    // Triggers: a push to main.
    const on = try triggers(a, text);
    if (on.len != 1 or !std.mem.eql(u8, on[0], "push") or !wc.hasLine(text, "    branches: [main]"))
        try add(a, &f, "the workflow is triggered by something other than a push to main (`on:` must be `push: branches: [main]` alone)", .{});
    for ([_][]const u8{ "pull_request_target", "workflow_run", "workflow_dispatch" }) |bad| {
        if (std.mem.indexOf(u8, text, bad) != null) try add(a, &f, "`{s}` appears in the workflow", .{bad});
    }
    if (std.mem.indexOf(u8, text, "secrets.") != null) try add(a, &f, "the workflow reads a secret", .{});
    if (std.mem.indexOf(u8, text, "--clobber") != null or std.mem.indexOf(u8, text, "release delete") != null)
        try add(a, &f, "the workflow replaces or deletes a release asset (`--clobber`, `release delete`): a release is never changed", .{});
    for ([_][]const u8{ "always()", "failure()", "cancelled()" }) |fun| {
        if (std.mem.indexOf(u8, text, fun) != null) try add(a, &f, "`{s}` in the workflow lets a job run after a red one", .{fun});
    }

    // The token.
    if (!wc.hasLine(text, "permissions: {}")) try add(a, &f, "top-level `permissions: {{}}` is missing", .{});
    if (std.mem.indexOf(u8, text, "write-all") != null) try add(a, &f, "`write-all` is granted", .{});
    const jobs = try parseJobs(a, text);
    for (all_jobs) |name| {
        if (jobNamed(jobs, name) == null) try add(a, &f, "the job `{s}` is missing", .{name});
    }
    var writes: usize = 0;
    for (jobs) |*j| {
        if (!j.has_perms) try add(a, &f, "the job `{s}` states no `permissions:` of its own", .{j.name});
        for (j.perms.items) |p| {
            if (std.mem.eql(u8, p.level, "write")) {
                writes += 1;
                if (!writeAllowed(j.name, p.scope)) try add(a, &f, "the job `{s}` holds `{s}: write`, which only {s} may", .{ j.name, p.scope, if (std.mem.eql(u8, p.scope, "contents")) "tag and publish" else if (std.mem.eql(u8, p.scope, "id-token") or std.mem.eql(u8, p.scope, "attestations")) "archive" else "no job" });
            } else if (!std.mem.eql(u8, p.level, "read") and !std.mem.eql(u8, p.level, "none")) {
                try add(a, &f, "the job `{s}` has `{s}: {s}`, which is not read, write or none", .{ j.name, p.scope, p.level });
            }
        }
    }
    if (std.mem.count(u8, text, ": write") != writes) try add(a, &f, "a `: write` is granted outside a job's `permissions:` block", .{});
    if (jobNamed(jobs, "tag")) |j| {
        const l = permLevel(j, "contents");
        if (l == null or !std.mem.eql(u8, l.?, "write")) try add(a, &f, "the job `tag` does not hold `contents: write`", .{});
        if (j.if_expr == null or !std.mem.eql(u8, j.if_expr.?, tag_if)) try add(a, &f, "the job `tag` is not under its exact `if:` ({s})", .{tag_if});
        if (j.group == null or !std.mem.eql(u8, j.group.?, "release") or j.cancel == null or !std.mem.eql(u8, j.cancel.?, "false"))
            try add(a, &f, "the job `tag` is not in the concurrency group `release` with `cancel-in-progress: false`", .{});
    }
    if (jobNamed(jobs, "publish")) |j| {
        const l = permLevel(j, "contents");
        if (l == null or !std.mem.eql(u8, l.?, "write")) try add(a, &f, "the job `publish` does not hold `contents: write`", .{});
        if (j.if_expr == null or !std.mem.eql(u8, j.if_expr.?, publish_if)) try add(a, &f, "the job `publish` is not under its exact `if:` ({s})", .{publish_if});
    }
    if (jobNamed(jobs, "archive")) |j| {
        for ([_][]const u8{ "id-token", "attestations" }) |scope| {
            const l = permLevel(j, scope);
            if (l == null or !std.mem.eql(u8, l.?, "write")) try add(a, &f, "the job `archive` does not hold `{s}: write`, which the attestation needs", .{scope});
        }
        const jt = try j.text(a);
        if (std.mem.count(u8, jt, "actions/attest-build-provenance@") != 1) try add(a, &f, "the job `archive` does not attest (`actions/attest-build-provenance` once)", .{});
    }
    if (std.mem.count(u8, text, "actions/attest-build-provenance@") != 1) try add(a, &f, "`actions/attest-build-provenance` is used other than once, in `archive`", .{});

    // The order: publish <- verify <- archive <- tag <- gate, and a release only for a commit the tag job released.
    for (order) |pair| {
        if (jobNamed(jobs, pair[0])) |j| {
            if (!hasNeed(j, pair[1])) try add(a, &f, "the job `{s}` does not wait for `{s}` (order: publish <- verify <- archive <- tag <- gate)", .{ pair[0], pair[1] });
        }
    }
    for ([_][]const u8{ "archive", "verify" }) |name| {
        if (jobNamed(jobs, name)) |j| {
            if (j.if_expr == null or std.mem.indexOf(u8, j.if_expr.?, released_clause) == null) try add(a, &f, "the job `{s}` runs even when the tag job released nothing (its `if:` lacks `{s}`)", .{ name, released_clause });
        }
    }
    if (jobNamed(jobs, "publish")) |j| {
        if (j.if_expr == null or std.mem.indexOf(u8, j.if_expr.?, released_clause) == null) try add(a, &f, "the job `publish` runs even when the tag job released nothing", .{});
    }
    if (jobNamed(jobs, "gate")) |j| {
        if (j.uses == null or !std.mem.eql(u8, j.uses.?, ci_call)) try add(a, &f, "the job `gate` does not call {s}", .{ci_call});
        if (j.if_expr != null) try add(a, &f, "the job `gate` has an `if:`: the stage that gates the release can be skipped", .{});
        if (j.perms.items.len != 1 or !std.mem.eql(u8, j.perms.items[0].scope, "contents") or !std.mem.eql(u8, j.perms.items[0].level, "read"))
            try add(a, &f, "the job `gate` is not `contents: read` alone", .{});
    }
    if (!wc.hasLine(ci_yml, "  workflow_call:")) try add(a, &f, "ci.yml has no `workflow_call:` trigger, so the job `gate` cannot call it", .{});
    // The tool: built in `tool`, run by each step from the artifact.
    for (tool_runs) |pair| {
        if (jobNamed(jobs, pair[0])) |j| {
            const jt = try j.text(a);
            if (std.mem.indexOf(u8, jt, pair[1]) == null) try add(a, &f, "the job `{s}` does not run `{s}...`", .{ pair[0], pair[1] });
        }
    }

    // The jobs that write run no buck2 and use only the checkout and download actions.
    for ([_][]const u8{ "tag", "publish" }) |name| {
        const j = jobNamed(jobs, name) orelse continue;
        for (j.lines.items) |l| {
            if (usesRepo(l)) |repo| {
                var ok = false;
                for (write_job_actions) |w| {
                    if (std.mem.eql(u8, repo, w)) ok = true;
                }
                if (!ok) try add(a, &f, "the job `{s}` holds a write scope and uses {s}", .{ name, repo });
            }
            if (std.mem.indexOf(u8, l, "buck2") != null and !std.mem.startsWith(u8, l, "#")) try add(a, &f, "the job `{s}` holds a write scope and runs buck2: {s}", .{ name, l });
        }
    }

    // `run:` lines are one invocation each; the buck2 install of the tool job is the one block.
    for (jobs) |*j| {
        if (std.mem.eql(u8, j.name, "tool")) continue;
        for (j.lines.items) |l| {
            const s = std.mem.trimLeft(u8, std.mem.trimLeft(u8, l, "- "), " ");
            if (!std.mem.startsWith(u8, s, "run:")) continue;
            const v = std.mem.trim(u8, s["run:".len..], " ");
            if (v.len == 0 or v[0] == '|' or v[0] == '>') {
                try add(a, &f, "a `run:` block in the job `{s}`: one-line invocations only", .{j.name});
            } else if (std.mem.indexOf(u8, v, " && ") != null or std.mem.indexOf(u8, v, " || ") != null or std.mem.indexOfScalar(u8, v, ';') != null or std.mem.indexOf(u8, v, " | ") != null) {
                try add(a, &f, "a `run:` line in the job `{s}` is more than one invocation: {s}", .{ j.name, v });
            }
        }
    }

    // buck2: local mode on every command, the pinned install, and the tool is built.
    const builds = try wc.localMode(a, &f, text);
    if (builds == 0) try add(a, &f, "no `./buck2 build` command found (the tool is not built; or this parser is blind)", .{});
    var built = false;
    for (try wc.commands(a, text)) |cmd| {
        if (std.mem.indexOf(u8, cmd, "./buck2 build ") != null and std.mem.indexOf(u8, cmd, tool_target) != null) built = true;
    }
    if (!built) try add(a, &f, "the workflow does not build {s}", .{tool_target});
    try wc.buck2Install(a, &f, text, dotslash);
    return f;
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

const Real = struct { wf: []const u8, ds: []const u8, ci: []const u8 };

fn real(a: std.mem.Allocator) !Real {
    return .{ .wf = try work(a, ".github/workflows/release.yml"), .ds = try work(a, "tools/buck2"), .ci = try work(a, ".github/workflows/ci.yml") };
}

fn mutate(a: std.mem.Allocator, wf: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const i = std.mem.indexOf(u8, wf, from) orelse return error.MutantDidNotApply;
    return std.mem.concat(a, u8, &.{ wf[0..i], to, wf[i + from.len ..] });
}

/// As `mutate`, within the job `job` (the first `from` after its header).
fn mutateIn(a: std.mem.Allocator, wf: []const u8, job: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const header = try std.fmt.allocPrint(a, "\n  {s}:\n", .{job});
    const at = std.mem.indexOf(u8, wf, header) orelse return error.MutantDidNotApply;
    const i = std.mem.indexOfPos(u8, wf, at, from) orelse return error.MutantDidNotApply;
    return std.mem.concat(a, u8, &.{ wf[0..i], to, wf[i + from.len ..] });
}

fn expectFinding(a: std.mem.Allocator, r: Real, wf: []const u8, needle: []const u8) !void {
    const f = try checkRelease(a, wf, r.ds, r.ci);
    for (f.items) |m| {
        if (std.mem.indexOf(u8, m, needle) != null) return;
    }
    std.debug.print("expected a finding with `{s}`, got {d}:\n", .{ needle, f.items.len });
    for (f.items) |m| std.debug.print("  {s}\n", .{m});
    return error.MutantSurvived;
}

test "the real release workflow has no findings" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const f = try checkRelease(a, r.wf, r.ds, r.ci);
    for (f.items) |m| std.debug.print("finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "the jobs are parsed as the rules read them" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const jobs = try parseJobs(a, try body(a, r.wf));
    try t.expectEqual(@as(usize, 6), jobs.len);
    const tg = jobNamed(jobs, "tag").?;
    try t.expect(hasNeed(tg, "gate") and hasNeed(tg, "tool"));
    try t.expectEqualStrings(tag_if, tg.if_expr.?);
    try t.expectEqualStrings("write", permLevel(tg, "contents").?);
    try t.expectEqualStrings("release", tg.group.?);
    try t.expectEqualStrings("false", tg.cancel.?);
    const ar_job = jobNamed(jobs, "archive").?;
    try t.expectEqualStrings("write", permLevel(ar_job, "id-token").?);
    try t.expectEqualStrings("write", permLevel(ar_job, "attestations").?);
    try t.expectEqualStrings("read", permLevel(ar_job, "contents").?);
    try t.expectEqualStrings(ci_call, jobNamed(jobs, "gate").?.uses.?);
    try t.expectEqualStrings(publish_if, jobNamed(jobs, "publish").?.if_expr.?);
}

test "rule: every action is pinned by commit (a tag, a branch, a short sha, or a local action is found)" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const sha = "cf430e030ddbb5b0abf93d22962f4752f3646cd9";
    try expectFinding(a, r, try mutate(a, r.wf, "actions/upload-artifact@" ++ sha, "actions/upload-artifact@v7"), "not pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "actions/upload-artifact@" ++ sha, "actions/upload-artifact@main"), "not pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "actions/upload-artifact@" ++ sha, "actions/upload-artifact@cf430e0"), "not pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8", "actions/attest-build-provenance@v4"), "not pinned");
    // the one local reference is ci.yml; another is not pinned
    try expectFinding(a, r, try mutate(a, r.wf, "uses: ./.github/workflows/ci.yml", "uses: ./.github/workflows/other.yml"), "not pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "      - run: chmod +x tool/release\n", "      - uses: ./.github/actions/x\n"), "not pinned");
}

test "rule: a checkout keeps no credentials" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "          persist-credentials: false\n", ""), "persist-credentials");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "          persist-credentials: false\n", "          persist-credentials: true\n"), "persist-credentials");
}

test "rule: only a push to main triggers it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const need = "triggered by something other than a push to main";
    try expectFinding(a, r, try mutate(a, r.wf, "on:\n  push:", "on:\n  pull_request:\n  push:"), need);
    try expectFinding(a, r, try mutate(a, r.wf, "on:\n  push:", "on:\n  workflow_dispatch:\n  push:"), need);
    try expectFinding(a, r, try mutate(a, r.wf, "on:\n  push:", "on:\n  schedule:\n  push:"), need);
    try expectFinding(a, r, try mutate(a, r.wf, "branches: [main]", "branches: [main, dev]"), need);
    try expectFinding(a, r, try mutate(a, r.wf, "branches: [main]", "branches: [dev]"), need);
    try expectFinding(a, r, try mutate(a, r.wf, "  push:\n    branches: [main]\n", "  workflow_run:\n    workflows: [ci]\n"), "workflow_run");
}

test "rule: write scopes only where they belong" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    // contents: write only in tag and publish
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "      contents: read\n", "      contents: write\n"), "job `archive` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      contents: read\n", "      contents: write\n"), "job `verify` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tool", "      contents: read\n", "      contents: write\n"), "job `tool` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gate", "      contents: read\n", "      contents: write\n"), "job `gate` holds `contents: write`");
    // id-token and attestations write only in archive
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      contents: write\n", "      contents: write\n      id-token: write\n"), "job `tag` holds `id-token: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      contents: write\n", "      contents: write\n      attestations: write\n"), "job `publish` holds `attestations: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      attestations: read\n", "      attestations: write\n"), "job `verify` holds `attestations: write`");
    // any other scope
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      contents: read\n", "      contents: read\n      packages: write\n"), "job `verify` holds `packages: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      contents: write\n", "      contents: write\n      actions: write\n"), "job `tag` holds `actions: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      contents: read\n", "      contents: read\n      issues: admin\n"), "not read, write or none");
    // a write granted at the top, or by write-all, or outside any permissions block
    try expectFinding(a, r, try mutate(a, r.wf, "permissions: {}", "permissions:\n  contents: write"), "permissions: {}");
    try expectFinding(a, r, try mutate(a, r.wf, "permissions: {}", "permissions:\n  contents: write"), "outside a job's");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      contents: read\n", "      contents: read-all\n      x: write-all\n"), "write-all");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "    timeout-minutes: 15\n", "    timeout-minutes: 15\n    env:\n      P: contents: write\n"), "outside a job's");
    // a job with no permissions of its own would inherit the top
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "    permissions:\n      contents: read\n      attestations: read\n", ""), "states no `permissions:`");
    // the jobs that need their scope have it
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      contents: write\n", "      contents: read\n"), "`tag` does not hold `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      contents: write\n", "      contents: read\n"), "`publish` does not hold `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "      id-token: write\n", "      id-token: read\n"), "`archive` does not hold `id-token: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "      attestations: write\n", ""), "`archive` does not hold `attestations: write`");
}

test "rule: tag and publish run under their exact if" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const exact_tag = "the job `tag` is not under its exact `if:`";
    const exact_pub = "the job `publish` is not under its exact `if:`";
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", " && github.ref == 'refs/heads/main'", ""), exact_tag);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", " && !github.event.repository.fork", ""), exact_tag);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "github.event_name == 'push' &&", "github.event_name == 'push' ||"), exact_tag);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "    if: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork }}\n", ""), exact_tag);
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", " && github.ref == 'refs/heads/main'", ""), exact_pub);
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "github.event_name == 'push'", "true"), exact_pub);
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "needs.tag.outputs.released == 'true' && ", ""), exact_pub);
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "    if: ${{ needs.tag.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork }}\n", ""), exact_pub);
}

test "rule: the order publish <- verify <- archive <- tag <- gate" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "needs: [gate, tool]", "needs: [tool]"), "`tag` does not wait for `gate`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "    needs: [gate, tool]\n", ""), "`tag` does not wait for `gate`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "needs: [tag, tool]", "needs: [tool]"), "`archive` does not wait for `tag`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "needs: [tag, archive, tool]", "needs: [tag, tool]"), "`verify` does not wait for `archive`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "needs: [tag, verify, tool]", "needs: [tag, tool]"), "`publish` does not wait for `verify`");
    // gate is a call of ci.yml that cannot be skipped, with read access only
    try expectFinding(a, r, try mutate(a, r.wf, "    uses: ./.github/workflows/ci.yml\n", "    runs-on: ubuntu-latest\n"), "`gate` does not call");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gate", "    permissions:\n", "    if: ${{ github.event_name == 'push' }}\n    permissions:\n"), "`gate` has an `if:`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gate", "      contents: read\n", "      contents: read\n      packages: read\n"), "`gate` is not `contents: read` alone");
    // ci.yml must be callable
    try expectFinding(a, .{ .wf = r.wf, .ds = r.ds, .ci = try mutate(a, r.ci, "  workflow_call:\n", "") }, r.wf, "no `workflow_call:` trigger");
    // a missing job
    try expectFinding(a, r, try mutate(a, r.wf, "\n  publish:\n", "\n  publish_x:\n"), "the job `publish` is missing");
    try expectFinding(a, r, try mutate(a, r.wf, "\n  verify:\n", "\n  verify_x:\n"), "the job `verify` is missing");
}

test "rule: a release is made only for a commit the tag job released, and no job runs after a red one" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "    if: ${{ needs.tag.outputs.released == 'true' }}\n", ""), "`archive` runs even when the tag job released nothing");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "needs.tag.outputs.released == 'true'", "true"), "`verify` runs even when the tag job released nothing");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "if: ${{ needs.tag.outputs.released == 'true' }}", "if: ${{ always() && needs.tag.outputs.released == 'true' }}"), "`always()`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "if: ${{ needs.tag.outputs.released", "if: ${{ failure() || needs.tag.outputs.released"), "`failure()`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "if: ${{ needs.tag.outputs.released == 'true' }}", "if: ${{ cancelled() || needs.tag.outputs.released == 'true' }}"), "`cancelled()`");
}

test "rule: the tag job is in the release concurrency group and none is cancelled" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const need = "concurrency group `release` with `cancel-in-progress: false`";
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "cancel-in-progress: false", "cancel-in-progress: true"), need);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "group: release", "group: release-${{ github.sha }}"), need);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "    concurrency:\n      group: release\n      cancel-in-progress: false\n", ""), need);
}

test "rule: the attestation is made in archive, once" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectFinding(a, r, try mutate(a, r.wf, "actions/attest-build-provenance@", "actions/attest-sbom@"), "does not attest");
    // a second attestation elsewhere
    const second = "      - uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2\n        with:\n          subject-path: x\n      - run: chmod +x tool/release\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      - run: chmod +x tool/release\n", second), "used other than once");
}

test "rule: the jobs that write run no buck2 and use no action but the checkout and download" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const buck2_run = "      - run: ./buck2 build --console simple -c buildrules_re.mode=local //tools/release:release\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      - run: chmod +x tool/release\n", buck2_run), "job `tag` holds a write scope and runs buck2");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      - run: chmod +x tool/release\n", buck2_run), "job `publish` holds a write scope and runs buck2");
    const cache = "      - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: x\n          key: x\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      - run: chmod +x tool/release\n", cache), "job `publish` holds a write scope and uses actions/cache");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      - run: chmod +x tool/release\n", cache), "job `tag` holds a write scope and uses actions/cache");
    // upload-artifact is not a download: a write job does not publish files of its own
    const up = "      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2\n        with:\n          name: x\n          path: x\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      - run: chmod +x tool/release\n", up), "uses actions/upload-artifact");
}

test "rule: each step runs its command of the tool, and run lines are single invocations" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "tool/release verify ", "echo verify "), "`verify` does not run `tool/release verify");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "tool/release publish ", "echo publish "), "`publish` does not run `tool/release publish");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "tool/release archive ", "echo archive "), "`archive` does not run");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "tool/release tag ", "echo tag "), "`tag` does not run");
    // one invocation per run line: no chain, no pipe, no block
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      - run: chmod +x tool/release\n", "      - run: chmod +x tool/release && echo hi\n"), "more than one invocation");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "      - run: chmod +x tool/release\n", "      - run: echo a; echo b\n"), "more than one invocation");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      - run: chmod +x tool/release\n", "      - run: cat x | wc -l\n"), "more than one invocation");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      - run: chmod +x tool/release\n", "      - run: |\n          echo a\n          echo b\n"), "`run:` block in the job `tag`");
}

test "rule: no asset is replaced, no secret is read" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "--dist dist\n", "--dist dist --clobber\n"), "--clobber");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      - run: chmod +x tool/release\n", "      - run: gh release delete v1\n"), "release delete");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "GH_TOKEN: ${{ github.token }}", "GH_TOKEN: ${{ secrets.X }}"), "reads a secret");
}

test "rule: buck2 runs in local mode, as the literal ./buck2, from the pinned release, and the tool is built" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const need = "does not pass `-c buildrules_re.mode=local`";
    try expectFinding(a, r, try mutate(a, r.wf, "build --console simple -c buildrules_re.mode=local --out", "build --console simple --out"), need);
    try expectFinding(a, r, try mutate(a, r.wf, "-c buildrules_re.mode=local", "-c buildrules_re.mode=remote"), "something other than `local`");
    try expectFinding(a, r, try mutate(a, r.wf, "      - uses: actions/upload-artifact@", "      - run: buck2 build //x:y\n      - uses: actions/upload-artifact@"), "not the literal `./buck2`");
    try expectFinding(a, r, try mutate(a, r.wf, "      - uses: actions/upload-artifact@", "      - run: ./buck2 bxl //x:y\n      - uses: actions/upload-artifact@"), need);
    try expectFinding(a, r, try mutate(a, r.wf, "--out release //tools/release:release", "--out release //tools/other:release"), "does not build //tools/release:release");
    try expectFinding(a, r, try mutate(a, r.wf, "--console simple", "--console simple -c buck2_re_client.engine_address=x"), "engine_address");
    try expectFinding(a, r, try mutate(a, r.wf, "2026-09-15/buck2-x86_64", "2026-09-16/buck2-x86_64"), "url pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "1268fce33fb6", "0268fce33fb6"), "sha256 pinned");
    try expectFinding(a, .{ .wf = r.wf, .ds = try mutate(a, r.ds, "1268fce33fb6", "9999fce33fb6"), .ci = r.ci }, r.wf, "sha256 pinned");
    try expectFinding(a, r, "name: x\nuses: a/b@" ++ "0" ** 40 ++ "\n", "no `./buck2 build` command");
}
