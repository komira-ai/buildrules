//! The release workflow (.github/workflows/release.yml) is what RELEASING.md says it is. A pure function of the text, so each rule is tested
//! against planted text as well as against the real files (the zig_test's `data`, under BUILDRULES_TEST_WORK). The rules that release.yml
//! shares with ci.yml (actions pinned by commit, local mode on every buck2 command, the pinned buck2 install) are the ones in
//! workflow_check.zig; what is here is what only the release has:
//!
//!  - the triggers: a push to main and nothing else (no pull request, no dispatch, no schedule, no workflow_run);
//!  - the token: `permissions: {}` at the top, every job states its own, and a write scope only where it belongs: `contents: write` in the job
//!    `publish` (and nowhere else; `tag` holds `contents: read` and writes with the release bot's token, minted by one step with exact inputs and used by the tag step alone), `id-token: write` and `attestations: write` in `archive` (and nowhere else), each of
//!    `tag` and `publish` under its exact `if:`, and every `: write` of the file accounted for by a job's permissions block;
//!  - the order gate -> beta -> gamma -> plan -> archive -> verify -> tag -> publish, with gate a call of ci.yml that nothing can skip, no job before
//!    the tag waiting for it (a failure before the tag leaves no tag), a release made only when the plan released, and no status function
//!    (`always()`, `failure()`, `cancelled()`) or `continue-on-error` that would let a job run or pass after a red one;
//!  - the jobs that write run no buck2 and only the checkout and download actions: the tool they run was built before any token existed;
//!  - the attestation action is in `archive` only, every checkout drops its credentials, `run:` lines are single invocations (the
//!    install of buck2 aside), no asset is ever replaced (`--clobber`), no secret is read but the release bot's private key (once, in `tag`).
const std = @import("std");
const wc = @import("workflow_check.zig");
const t = std.testing;

const Findings = wc.Findings;
const add = wc.add;

pub const tag_if = "${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork }}";
pub const publish_if = tag_if;
/// archive, verify, tag, publish and site run only for a commit the plan released.
const released_clause = "needs.plan.outputs.released == 'true'";
const ci_call = "./.github/workflows/ci.yml";
const beta_call = "./.github/workflows/beta.yml";
/// The farm-connect action, checked out of the repository a variable names at the commit another names, then used from the checkout.
const farm_action = "./farm-action/.github/actions/farm-connect";
const tool_target = "//tools/release:release";
const stage_target = "//tools/stage:stage";

/// The jobs, and the job each one must wait for (`needs`): gate -> beta -> gamma -> plan -> archive -> verify -> tag -> publish (site after tag and verify).
const order = [_][2][]const u8{
    .{ "beta", "gate" },
    .{ "gamma", "beta" },
    .{ "plan", "gamma" },
    .{ "archive", "plan" },
    .{ "cli", "plan" },
    .{ "verify", "cli" },
    .{ "verify", "archive" },
    .{ "tag", "plan" },
    .{ "tag", "verify" },
    .{ "publish", "plan" },
    .{ "publish", "tag" },
    .{ "publish", "verify" },
    .{ "site", "tag" },
    .{ "site", "verify" },
};
/// The jobs that run before the tag exists: none of them may wait for it, or a failure there could not be told from one after the tag.
const before_tag = [_][]const u8{ "gate", "beta", "gamma", "plan", "cli", "archive", "verify" };
const all_jobs = [_][]const u8{ "gate", "beta", "gamma", "tool", "plan", "cli", "archive", "verify", "tag", "site", "publish" };
/// What each job runs of the tool.
const tool_runs = [_][2][]const u8{
    .{ "gamma", "tool/stage gamma-vars " },
    .{ "gamma", "tool/stage action-ref " },
    .{ "gamma", "tool/stage gamma " },
    .{ "plan", "tool/release plan " },
    .{ "tag", "tool/release tag " },
    .{ "archive", "tool/release archive " },
    .{ "verify", "tool/release verify " },
    .{ "site", "tool/release site " },
    .{ "publish", "tool/release publish " },
};
/// The actions a job that writes may use; `tag` also mints the release bot's token.
const write_job_actions = [_][]const u8{ "actions/checkout", "actions/download-artifact" };
const app_token_action = "actions/create-github-app-token";

/// The step of `tag` that mints the release bot's token: every input exact. The v* tag ruleset lets only that App create a tag, so the tag
/// is made with this token and not with GITHUB_TOKEN; the token is for this repository alone and for contents.
const bot_step =
    "      - name: The token of the release bot, for this repository alone\n" ++
    "        id: bot\n" ++
    "        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n" ++
    "        with:\n" ++
    "          app-id: ${{ vars.RELEASE_BOT_APP_ID }}\n" ++
    "          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n" ++
    "          owner: ${{ github.repository_owner }}\n" ++
    "          repositories: buildrules\n" ++
    "          permission-contents: write\n" ++
    "      - name: The annotated tag of the verified commit\n"; // the next step: no input may follow the last one
/// The tag step: the bot's token is its GH_TOKEN, here and nowhere else.
const tag_step_env = "        env:\n          GH_TOKEN: ${{ steps.bot.outputs.token }}\n        run: tool/release tag ";

const Perm = struct { scope: []const u8, level: []const u8 };

pub const Job = struct {
    name: []const u8,
    lines: std.ArrayList([]const u8),
    needs: std.ArrayList([]const u8),
    perms: std.ArrayList(Perm),
    has_perms: bool = false,
    if_expr: ?[]const u8 = null,
    uses: ?[]const u8 = null,
    group: ?[]const u8 = null,
    cancel: ?[]const u8 = null,

    pub fn text(self: Job, a: std.mem.Allocator) ![]u8 {
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
pub fn body(a: std.mem.Allocator, wf: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var it = std.mem.splitScalar(u8, wf, '\n');
    while (it.next()) |line| {
        if (isComment(line)) continue;
        try out.appendSlice(line);
        try out.append('\n');
    }
    return out.toOwnedSlice();
}

pub fn stripComment(v: []const u8) []const u8 {
    if (std.mem.indexOf(u8, v, " #")) |i| return std.mem.trim(u8, v[0..i], " ");
    return std.mem.trim(u8, v, " ");
}

/// The text of one job as written (indentation kept, comments gone): from its `  name:` line to the next job's. Empty when there is no such job.
fn jobBlock(text: []const u8, name: []const u8) []const u8 {
    var buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "\n  {s}:\n", .{name}) catch return "";
    const at = std.mem.indexOf(u8, text, header) orelse return "";
    var i = at + header.len;
    while (std.mem.indexOfPos(u8, text, i, "\n  ")) |p| {
        const c = text[p + 3];
        if (c != ' ' and c != '\n') return text[at..p];
        i = p + 3;
    }
    return text[at..];
}

/// The jobs of the `jobs:` block, with what the rules read of each (its direct keys, its permissions and concurrency blocks).
pub fn parseJobs(a: std.mem.Allocator, wf: []const u8) ![]Job {
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

pub fn jobNamed(jobs: []Job, name: []const u8) ?*Job {
    for (jobs) |*j| {
        if (std.mem.eql(u8, j.name, name)) return j;
    }
    return null;
}

pub fn hasNeed(j: *const Job, name: []const u8) bool {
    for (j.needs.items) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

pub fn permLevel(j: *const Job, scope: []const u8) ?[]const u8 {
    for (j.perms.items) |p| {
        if (std.mem.eql(u8, p.scope, scope)) return p.level;
    }
    return null;
}

/// Whether a job may hold `scope: write`: `contents` in publish (tag writes with the release bot's token, not its own); `id-token` in archive (the attestation), in gamma (the farm's network) and in
/// beta (the call of beta.yml, whose farm leg joins the farm's network); `attestations` in archive.
fn writeAllowed(job: []const u8, scope: []const u8) bool {
    if (std.mem.eql(u8, scope, "contents")) return std.mem.eql(u8, job, "publish");
    if (std.mem.eql(u8, scope, "id-token")) return std.mem.eql(u8, job, "archive") or std.mem.eql(u8, job, "gamma") or std.mem.eql(u8, job, "beta");
    if (std.mem.eql(u8, scope, "attestations")) return std.mem.eql(u8, job, "archive");
    return false;
}

fn writeOwners(scope: []const u8) []const u8 {
    if (std.mem.eql(u8, scope, "contents")) return "publish";
    if (std.mem.eql(u8, scope, "id-token")) return "archive, gamma and beta";
    if (std.mem.eql(u8, scope, "attestations")) return "archive";
    return "no job";
}

/// The keys of the `on:` block (its direct children).
pub fn triggers(a: std.mem.Allocator, wf: []const u8) ![]const []const u8 {
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

pub fn usesRepo(line: []const u8) ?[]const u8 {
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
    try wc.noContinueOnError(a, &f, text);
    try wc.noInlineContext(a, &f, text);
    const uses = try wc.pinnedUses(a, &f, text, &.{ ci_call, beta_call, farm_action });
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
    // The one secret: the release bot's private key, read once, by the step of `tag` that mints the token. Any other `secrets.` is refused.
    if (std.mem.count(u8, text, "secrets.") != std.mem.count(u8, text, "secrets.RELEASE_BOT_PRIVATE_KEY }}")) try add(a, &f, "the workflow reads a secret", .{});
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
                if (!writeAllowed(j.name, p.scope)) try add(a, &f, "the job `{s}` holds `{s}: write`, which only {s} may", .{ j.name, p.scope, writeOwners(p.scope) });
            } else if (!std.mem.eql(u8, p.level, "read") and !std.mem.eql(u8, p.level, "none")) {
                try add(a, &f, "the job `{s}` has `{s}: {s}`, which is not read, write or none", .{ j.name, p.scope, p.level });
            }
        }
    }
    // `permission-contents: write` is an input of the App-token action, not a grant of the job's token: it is counted by its own rule below.
    if (std.mem.count(u8, text, ": write") - std.mem.count(u8, text, "permission-contents: write") != writes) try add(a, &f, "a `: write` is granted outside a job's `permissions:` block", .{});
    if (jobNamed(jobs, "tag")) |j| {
        // The job's own token only reads; the write is the release bot's token, minted by one step with exact inputs and used by one step.
        if (j.perms.items.len != 1 or permLevel(j, "contents") == null or !std.mem.eql(u8, permLevel(j, "contents").?, "read"))
            try add(a, &f, "the job `tag` is not `contents: read` alone: it writes with the release bot's token, not its own", .{});
        const jt = jobBlock(text, "tag"); // with its indentation: the bot steps are matched as written
        const mint = std.mem.indexOf(u8, jt, bot_step);
        if (mint == null) try add(a, &f, "the job `tag` does not mint the release bot's token with exactly the pinned inputs of `actions/create-github-app-token` (app-id, private-key, owner, repositories, permission-contents)", .{});
        const use = std.mem.indexOf(u8, jt, tag_step_env);
        if (use == null) try add(a, &f, "the step of `tag` that runs `tool/release tag` does not take the bot's token as its GH_TOKEN (`steps.bot.outputs.token`)", .{});
        if (mint != null and use != null and mint.? > use.?) try add(a, &f, "the job `tag` uses the bot's token before the step that mints it", .{});
        if (std.mem.count(u8, jt, "steps.bot.outputs.token") != 1) try add(a, &f, "the job `tag` uses the bot's token other than once, in the tag step", .{});
        if (std.mem.indexOf(u8, jt, "github.token") != null or std.mem.indexOf(u8, jt, "secrets.GITHUB_TOKEN") != null) try add(a, &f, "the job `tag` uses GITHUB_TOKEN, which the ruleset refuses for a tag", .{});
        if (std.mem.count(u8, jt, "secrets.") != 1) try add(a, &f, "the job `tag` reads other than the one secret of the release bot's key", .{});
    }
    // The token is minted in `tag` and nowhere else, once; the key and the token output appear nowhere else.
    if (std.mem.count(u8, text, app_token_action ++ "@") != 1) try add(a, &f, "`actions/create-github-app-token` is used other than once, in `tag`", .{});
    if (std.mem.count(u8, text, "secrets.RELEASE_BOT_PRIVATE_KEY") != 1 or std.mem.count(u8, text, "steps.bot.outputs.token") != 1 or std.mem.count(u8, text, "permission-") != 1)
        try add(a, &f, "the release bot's key, token or permission input appears other than once, in `tag`", .{});
    if (jobNamed(jobs, "tag")) |j| {
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

    // The order: gate -> beta -> gamma -> plan -> archive -> verify -> tag -> publish, and a release only for a commit the plan released.
    for (order) |pair| {
        if (jobNamed(jobs, pair[0])) |j| {
            if (!hasNeed(j, pair[1])) try add(a, &f, "the job `{s}` does not wait for `{s}` (order: gate -> beta -> gamma -> plan -> archive -> verify -> tag -> publish)", .{ pair[0], pair[1] });
        }
    }
    for ([_][]const u8{ "cli", "archive", "verify", "site" }) |name| {
        if (jobNamed(jobs, name)) |j| {
            if (j.if_expr == null or std.mem.indexOf(u8, j.if_expr.?, released_clause) == null) try add(a, &f, "the job `{s}` runs even when the plan released nothing (its `if:` lacks `{s}`)", .{ name, released_clause });
        }
    }
    if (jobNamed(jobs, "publish")) |j| {
        if (j.if_expr == null or std.mem.indexOf(u8, j.if_expr.?, released_clause) == null) try add(a, &f, "the job `publish` runs even when the plan released nothing", .{});
    }
    // Nothing before the tag waits for it: the tag is made after the archive is verified, so a failure up to there leaves no tag behind.
    for (before_tag) |name| {
        if (jobNamed(jobs, name)) |j| {
            if (hasNeed(j, "tag") or hasNeed(j, "publish")) try add(a, &f, "the job `{s}` waits for `tag` or `publish`: the tag is made after the archive is verified, not before", .{name});
        }
    }
    // The plan only reads: it decides, and creates nothing.
    if (jobNamed(jobs, "plan")) |j| {
        if (j.perms.items.len != 1 or permLevel(j, "contents") == null or !std.mem.eql(u8, permLevel(j, "contents").?, "read")) try add(a, &f, "the job `plan` is not `contents: read` alone", .{});
        if (j.if_expr != null) try add(a, &f, "the job `plan` has an `if:`", .{});
    }
    // The archive is of the tested commit, and no step of the jobs before the tag names the tag by a ref.
    for ([_][]const u8{ "archive", "verify" }) |name| {
        if (jobNamed(jobs, name)) |j| {
            const jt = try j.text(a);
            if (std.mem.indexOf(u8, jt, "refs/tags/") != null) try add(a, &f, "the job `{s}` reads a tag by ref (`refs/tags/`): the tag does not exist yet, the archive is of the commit", .{name});
            if (std.mem.indexOf(u8, jt, "--sha \"$GITHUB_SHA\"") == null) try add(a, &f, "the job `{s}` does not pass `--sha \"$GITHUB_SHA\"` (the archive is of the tested commit)", .{name});
        }
    }
    if (jobNamed(jobs, "gate")) |j| {
        if (j.uses == null or !std.mem.eql(u8, j.uses.?, ci_call)) try add(a, &f, "the job `gate` does not call {s}", .{ci_call});
        if (j.if_expr != null) try add(a, &f, "the job `gate` has an `if:`: the stage that gates the release can be skipped", .{});
        if (j.perms.items.len != 1 or !std.mem.eql(u8, j.perms.items[0].scope, "contents") or !std.mem.eql(u8, j.perms.items[0].level, "read"))
            try add(a, &f, "the job `gate` is not `contents: read` alone", .{});
    }
    // beta: the call of beta.yml, which nothing can skip, with read access and the farm leg's token only.
    if (jobNamed(jobs, "beta")) |j| {
        if (j.uses == null or !std.mem.eql(u8, j.uses.?, beta_call)) try add(a, &f, "the job `beta` does not call {s}", .{beta_call});
        if (j.if_expr != null) try add(a, &f, "the job `beta` has an `if:`: the stage that proves the candidate for a user can be skipped", .{});
        if (j.perms.items.len != 2 or permLevel(j, "contents") == null or !std.mem.eql(u8, permLevel(j, "contents").?, "read") or permLevel(j, "id-token") == null or !std.mem.eql(u8, permLevel(j, "id-token").?, "write"))
            try add(a, &f, "the job `beta` is not `contents: read` and `id-token: write` alone", .{});
    }
    // gamma: our own repositories on the farm. It holds the farm's token and no write access to the repository, cannot be skipped, takes the farm-connect
    // action from the repository and commit that variables name (the checkout is verified before the action runs), and runs no buck2 itself.
    if (jobNamed(jobs, "gamma")) |j| {
        if (j.if_expr != null) try add(a, &f, "the job `gamma` has an `if:`: the stage that builds our own repositories with the candidate can be skipped", .{});
        if (j.perms.items.len != 2 or permLevel(j, "contents") == null or !std.mem.eql(u8, permLevel(j, "contents").?, "read") or permLevel(j, "id-token") == null or !std.mem.eql(u8, permLevel(j, "id-token").?, "write"))
            try add(a, &f, "the job `gamma` is not `contents: read` and `id-token: write` alone", .{});
        if (!hasNeed(j, "tool")) try add(a, &f, "the job `gamma` does not wait for `tool`, which builds the stage tool it runs", .{});
        const jt = try j.text(a);
        if (std.mem.indexOf(u8, jt, "repository: ${{ vars.FARM_CONNECT_REPO }}") == null or std.mem.indexOf(u8, jt, "ref: ${{ vars.FARM_CONNECT_REF }}") == null)
            try add(a, &f, "the job `gamma` does not check the farm-connect action out of the repository and commit that FARM_CONNECT_REPO and FARM_CONNECT_REF name", .{});
        // the order of the steps: the variables, the checkout of the action, its verification, then the action, then the build
        const markers = [_][]const u8{ "tool/stage gamma-vars ", "repository: ${{ vars.FARM_CONNECT_REPO }}", "tool/stage action-ref ", "uses: " ++ farm_action, "tool/stage gamma --work" };
        var at: usize = 0;
        for (markers) |m| {
            const i = std.mem.indexOfPos(u8, jt, at, m);
            if (i == null) {
                try add(a, &f, "the job `gamma` has no `{s}` after the step before it (order: variables, checkout of the action, action-ref, farm-connect, build)", .{m});
                break;
            }
            at = i.?;
        }
        for (j.lines.items) |l| {
            if (std.mem.indexOf(u8, l, "./buck2") != null)
                try add(a, &f, "the job `gamma` holds the farm's token and runs buck2 itself: {s}", .{l});
        }
    }
    // cli: the command line, built from the tested commit with the planned version stamped in (`-c buildrules.release_version`, read by cli/BUCK), and
    // `verify` runs it and compares what it prints with the release. Read-only; it runs the buck2 that `tool` handed on, as the literal `./buck2`.
    if (jobNamed(jobs, "cli")) |j| {
        if (j.perms.items.len != 1 or permLevel(j, "contents") == null or !std.mem.eql(u8, permLevel(j, "contents").?, "read"))
            try add(a, &f, "the job `cli` is not `contents: read` alone", .{});
        if (!hasNeed(j, "tool")) try add(a, &f, "the job `cli` does not wait for `tool`, which hands on the buck2 it runs", .{});
        const jt = try j.text(a);
        if (std.mem.indexOf(u8, jt, "NUMBER: ${{ needs.plan.outputs.number }}") == null) try add(a, &f, "the job `cli` does not take the planned version from the plan (`NUMBER: ${{{{ needs.plan.outputs.number }}}}`)", .{});
        if (std.mem.indexOf(u8, jt, "-c \"buildrules.release_version=$NUMBER\"") == null) try add(a, &f, "the job `cli` does not stamp the planned version into the program (`-c \"buildrules.release_version=$NUMBER\"`)", .{});
        if (std.mem.indexOf(u8, jt, " //cli:buildrules") == null) try add(a, &f, "the job `cli` does not build //cli:buildrules", .{});
        if (std.mem.indexOf(u8, jt, "name: release-cli") == null) try add(a, &f, "the job `cli` does not upload the artifact `release-cli`", .{});
    }
    if (jobNamed(jobs, "verify")) |j| {
        const jt = try j.text(a);
        if (std.mem.indexOf(u8, jt, "name: release-cli") == null) try add(a, &f, "the job `verify` does not download the artifact `release-cli`", .{});
        if (std.mem.indexOf(u8, jt, " --cli built-cli/buildrules") == null) try add(a, &f, "the job `verify` does not pass `--cli built-cli/buildrules`, so the program's version is not checked", .{});
    }
    if (jobNamed(jobs, "plan")) |j| {
        const jt = try j.text(a);
        if (std.mem.indexOf(u8, jt, "number: ${{ steps.version.outputs.number }}") == null) try add(a, &f, "the job `plan` does not output the version number (`number: ${{{{ steps.version.outputs.number }}}}`), which `cli` stamps", .{});
    }
    if (jobNamed(jobs, "site")) |j| {
        if (j.perms.items.len != 1 or permLevel(j, "contents") == null or !std.mem.eql(u8, permLevel(j, "contents").?, "read")) try add(a, &f, "the job `site` is not `contents: read` alone", .{});
        if (!hasNeed(j, "tag") or !hasNeed(j, "tool")) try add(a, &f, "the job `site` does not wait for `tag` and `tool`", .{});
        const jt = try j.text(a);
        if (std.mem.indexOf(u8, jt, "name: release-site") == null) try add(a, &f, "the job `site` does not upload the artifact `release-site`", .{});
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
                if (std.mem.eql(u8, name, "tag") and std.mem.eql(u8, repo, app_token_action)) ok = true;
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
    var stage_built = false;
    for (try wc.commands(a, text)) |cmd| {
        if (std.mem.indexOf(u8, cmd, "./buck2 build ") != null and std.mem.indexOf(u8, cmd, tool_target) != null) built = true;
        if (std.mem.indexOf(u8, cmd, "./buck2 build ") != null and std.mem.indexOf(u8, cmd, stage_target) != null) stage_built = true;
    }
    if (!built) try add(a, &f, "the workflow does not build {s}", .{tool_target});
    if (!stage_built) try add(a, &f, "the workflow does not build {s}, which gamma runs", .{stage_target});
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


// ---- synthetic fixtures -------------------------------------------------------------------------------------------------------------------
//
// The planted-defect tests run on this text and not on the real release.yml: every mutant anchors on text this file itself holds, so it cannot fail with
// `MutantDidNotApply` because the real workflow was reworded, and each red run is the rule under test. It is the shape of release.yml (every job, its
// needs, permissions and conditions) with the comments left out and the buck2 install pointed at a synthetic release; "the synthetic workflow has no finding" requires it clean first. The real file
// is checked by "the real release workflow has no findings" alone.

const fixture_wf =
    \\name: release
    \\
    \\on:
    \\  push:
    \\    branches: [main]
    \\
    \\permissions: {}
    \\
    \\jobs:
    \\  gate:
    \\    permissions:
    \\      contents: read
    \\    uses: ./.github/workflows/ci.yml
    \\
    \\  beta:
    \\    needs: [gate]
    \\    permissions:
    \\      contents: read
    \\      id-token: write
    \\    uses: ./.github/workflows/beta.yml
    \\
    \\  gamma:
    \\    needs: [beta, tool]
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 240
    \\    permissions:
    \\      contents: read
    \\      id-token: write
    \\    env:
    \\      CONNECT_REF: ${{ vars.FARM_CONNECT_REF }}
    \\      CONNECT_REPO: ${{ vars.FARM_CONNECT_REPO }}
    \\      HAS_ADDRESS: ${{ vars.FARM_ADDRESS != '' }}
    \\      HAS_INSTANCE: ${{ vars.FARM_INSTANCE != '' }}
    \\      HAS_PROPERTIES: ${{ vars.FARM_LINUX_X86_64_PROPERTIES != '' }}
    \\      HAS_TS_CLIENT_ID: ${{ vars.TS_CLIENT_ID != '' }}
    \\      HAS_TS_AUDIENCE: ${{ vars.TS_AUDIENCE != '' }}
    \\      GAMMA_REPOS: ${{ vars.GAMMA_REPOS }}
    \\      GAMMA_TARGETS: ${{ vars.GAMMA_TARGETS || '//...' }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: stage-tool
    \\          path: tool
    \\      - run: chmod +x tool/stage tool/buck2
    \\      - name: every repository variable gamma needs is set
    \\        run: tool/stage gamma-vars --farm-address "$HAS_ADDRESS" --farm-instance "$HAS_INSTANCE" --farm-properties "$HAS_PROPERTIES" --ts-client-id "$HAS_TS_CLIENT_ID" --ts-audience "$HAS_TS_AUDIENCE" --connect-repo "$CONNECT_REPO" --connect-ref "$CONNECT_REF" --repos "$GAMMA_REPOS"
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          repository: ${{ vars.FARM_CONNECT_REPO }}
    \\          ref: ${{ vars.FARM_CONNECT_REF }}
    \\          path: farm-action
    \\          persist-credentials: false
    \\      - name: the action that joins the farm is at the commit the variable names
    \\        run: tool/stage action-ref --dir farm-action --ref "$CONNECT_REF"
    \\      - name: connect to the farm
    \\        uses: ./farm-action/.github/actions/farm-connect
    \\        with:
    \\          ts-client-id: ${{ vars.TS_CLIENT_ID }}
    \\          ts-audience: ${{ vars.TS_AUDIENCE }}
    \\          farm-address: ${{ vars.FARM_ADDRESS }}
    \\          farm-instance: ${{ vars.FARM_INSTANCE }}
    \\          farm-properties: ${{ vars.FARM_LINUX_X86_64_PROPERTIES }}
    \\          tls: ${{ vars.FARM_TLS || 'false' }}
    \\      - name: Build our repositories with the candidate on the farm
    \\        run: tool/stage gamma --work "$RUNNER_TEMP/gamma" --candidate "$GITHUB_SHA" --repos "$GAMMA_REPOS" --targets "$GAMMA_TARGETS" --buck2 "$GITHUB_WORKSPACE/tool/buck2" --farm-config "$HOME/.buckconfig.d/farm.buckconfig"
    \\
    \\  tool:
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 120
    \\    permissions:
    \\      contents: read
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          persist-credentials: false
    \\
    \\      - name: Install buck2
    \\        run: |
    \\          curl --fail --silent --show-error --location --retry 3 \
    \\            --output buck2.zst \
    \\            https://example.invalid/2026-09-15/buck2-x86_64-unknown-linux-gnu.zst
    \\          echo "1268fce33fb600000000000000000000000000000000000000000000000000ff  buck2.zst" | sha256sum --check --strict -
    \\          zstd --decompress --quiet buck2.zst -o buck2
    \\          chmod +x buck2
    \\          ./buck2 --version
    \\
    \\      - name: Build the release tool
    \\        run: ./buck2 build --console simple -c buildrules_re.mode=local --out release //tools/release:release
    \\
    \\      - name: Build the stage tool
    \\        run: ./buck2 build --console simple -c buildrules_re.mode=local --out stage //tools/stage:stage
    \\
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        with:
    \\          name: release-tool
    \\          path: release
    \\          retention-days: 7
    \\          if-no-files-found: error
    \\
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        with:
    \\          name: stage-tool
    \\          path: |
    \\            ./stage
    \\            ./buck2
    \\          retention-days: 7
    \\          if-no-files-found: error
    \\
    \\  plan:
    \\    needs: [gamma, tool]
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    permissions:
    \\      contents: read
    \\    outputs:
    \\      released: ${{ steps.version.outputs.released }}
    \\      tag: ${{ steps.version.outputs.tag }}
    \\      number: ${{ steps.version.outputs.number }}
    \\      previous: ${{ steps.version.outputs.previous }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          fetch-depth: 0
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-tool
    \\          path: tool
    \\      - run: chmod +x tool/release
    \\      - name: The version of this commit, if it is released
    \\        id: version
    \\        run: tool/release plan --root "$GITHUB_WORKSPACE" --sha "$GITHUB_SHA" --output "$GITHUB_OUTPUT"
    \\
    \\  archive:
    \\    needs: [plan, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    permissions:
    \\      contents: read
    \\      id-token: write
    \\      attestations: write
    \\    env:
    \\      TAG: ${{ needs.plan.outputs.tag }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-tool
    \\          path: tool
    \\      - run: chmod +x tool/release
    \\      - name: The deterministic source archive of the tested commit, and its SHA256SUMS
    \\        run: tool/release archive --root "$GITHUB_WORKSPACE" --tag "$TAG" --sha "$GITHUB_SHA" --out dist
    \\      - name: Attest the archive and SHA256SUMS
    \\        uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2
    \\        with:
    \\          subject-path: |
    \\            dist/buildrules-*.tar.gz
    \\            dist/SHA256SUMS
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        with:
    \\          name: release-assets
    \\          path: dist
    \\          retention-days: 7
    \\          if-no-files-found: error
    \\
    \\  cli:
    \\    needs: [plan, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 60
    \\    permissions:
    \\      contents: read
    \\    env:
    \\      NUMBER: ${{ needs.plan.outputs.number }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: stage-tool
    \\          path: .
    \\      - run: chmod +x buck2
    \\      - name: Build the command line with the release version stamped in
    \\        run: ./buck2 build --console simple -c buildrules_re.mode=local -c "buildrules.release_version=$NUMBER" --out buildrules //cli:buildrules
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        with:
    \\          name: release-cli
    \\          path: buildrules
    \\          retention-days: 7
    \\          if-no-files-found: error
    \\
    \\  verify:
    \\    needs: [plan, archive, cli, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    permissions:
    \\      contents: read
    \\      attestations: read
    \\    env:
    \\      TAG: ${{ needs.plan.outputs.tag }}
    \\      GH_TOKEN: ${{ github.token }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-tool
    \\          path: tool
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-assets
    \\          path: dist
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-cli
    \\          path: built-cli
    \\      - run: chmod +x tool/release built-cli/buildrules
    \\      - name: The archive, its sums, attestations, file list and scrub, and the command line's version
    \\        run: tool/release verify --root "$GITHUB_WORKSPACE" --repo "$GITHUB_REPOSITORY" --tag "$TAG" --sha "$GITHUB_SHA" --dist dist --workflow .github/workflows/release.yml --cli built-cli/buildrules
    \\
    \\  tag:
    \\    needs: [plan, verify, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    concurrency:
    \\      group: release
    \\      cancel-in-progress: false
    \\    permissions:
    \\      contents: read
    \\    env:
    \\      TAG: ${{ needs.plan.outputs.tag }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          fetch-depth: 0
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-tool
    \\          path: tool
    \\      - run: chmod +x tool/release
    \\      - name: The token of the release bot, for this repository alone
    \\        id: bot
    \\        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
    \\        with:
    \\          app-id: ${{ vars.RELEASE_BOT_APP_ID }}
    \\          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
    \\          owner: ${{ github.repository_owner }}
    \\          repositories: buildrules
    \\          permission-contents: write
    \\      - name: The annotated tag of the verified commit
    \\        env:
    \\          GH_TOKEN: ${{ steps.bot.outputs.token }}
    \\        run: tool/release tag --root "$GITHUB_WORKSPACE" --repo "$GITHUB_REPOSITORY" --tag "$TAG" --sha "$GITHUB_SHA"
    \\
    \\  publish:
    \\    needs: [plan, tag, verify, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    permissions:
    \\      contents: write
    \\    env:
    \\      TAG: ${{ needs.plan.outputs.tag }}
    \\      PREVIOUS: ${{ needs.plan.outputs.previous }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          fetch-depth: 0
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-tool
    \\          path: tool
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-assets
    \\          path: dist
    \\      - run: chmod +x tool/release
    \\      - name: Create the release, or add the file it lacks
    \\        env:
    \\          GH_TOKEN: ${{ github.token }}
    \\        run: tool/release publish --root "$GITHUB_WORKSPACE" --repo "$GITHUB_REPOSITORY" --tag "$TAG" --sha "$GITHUB_SHA" --previous "$PREVIOUS" --dist dist
    \\
    \\  site:
    \\    needs: [plan, tag, verify, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    permissions:
    \\      contents: read
    \\    env:
    \\      TAG: ${{ needs.plan.outputs.tag }}
    \\    steps:
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-tool
    \\          path: tool
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-assets
    \\          path: dist
    \\      - run: chmod +x tool/release
    \\      - name: The page of the release
    \\        run: tool/release site --repo "$GITHUB_REPOSITORY" --tag "$TAG" --sha "$GITHUB_SHA" --dist dist --out site
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        with:
    \\          name: release-site
    \\          path: site
    \\          retention-days: 30
    \\          if-no-files-found: error
    \\
;

const fixture_ds =
    \\{
    \\  "platform": {
    \\    "linux-x86_64": {
    \\      "digest": "1268fce33fb600000000000000000000000000000000000000000000000000ff",
    \\      "providers": [{"url": "https://example.invalid/2026-09-15/buck2-x86_64-unknown-linux-gnu.zst"}]
    \\    },
    \\    "macos-x86_64": {}
    \\  }
    \\}
    \\
;

/// The synthetic fixture; the real files are `real`.
fn fx(a: std.mem.Allocator) !Real {
    _ = a;
    return .{ .wf = fixture_wf, .ds = fixture_ds, .ci = "on:\n  workflow_call:\n" };
}

test "the synthetic workflow has no finding, so every mutant below is red for its own rule" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const f = try checkRelease(a, r.wf, r.ds, r.ci);
    for (f.items) |m| std.debug.print("finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
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
    const r = try fx(a);
    const jobs = try parseJobs(a, try body(a, r.wf));
    try t.expectEqual(@as(usize, 11), jobs.len);
    const tg = jobNamed(jobs, "tag").?;
    try t.expect(hasNeed(tg, "plan") and hasNeed(tg, "verify") and hasNeed(tg, "tool"));
    try t.expectEqualStrings(tag_if, tg.if_expr.?);
    try t.expectEqualStrings("read", permLevel(tg, "contents").?);
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
    const r = try fx(a);
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
    const r = try fx(a);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "          persist-credentials: false\n", ""), "persist-credentials");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "          persist-credentials: false\n", "          persist-credentials: true\n"), "persist-credentials");
}

test "rule: only a push to main triggers it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
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
    const r = try fx(a);
    // contents: write only in tag and publish
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "      contents: read\n", "      contents: write\n"), "job `archive` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      contents: read\n", "      contents: write\n"), "job `verify` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tool", "      contents: read\n", "      contents: write\n"), "job `tool` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gate", "      contents: read\n", "      contents: write\n"), "job `gate` holds `contents: write`");
    // id-token and attestations write only in archive
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      contents: read\n", "      contents: read\n      id-token: write\n"), "job `tag` holds `id-token: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      contents: write\n", "      contents: write\n      attestations: write\n"), "job `publish` holds `attestations: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      attestations: read\n", "      attestations: write\n"), "job `verify` holds `attestations: write`");
    // any other scope
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      contents: read\n", "      contents: read\n      packages: write\n"), "job `verify` holds `packages: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      contents: read\n", "      contents: read\n      actions: write\n"), "job `tag` holds `actions: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      contents: read\n", "      contents: read\n      issues: admin\n"), "not read, write or none");
    // a write granted at the top, or by write-all, or outside any permissions block
    try expectFinding(a, r, try mutate(a, r.wf, "permissions: {}", "permissions:\n  contents: write"), "permissions: {}");
    try expectFinding(a, r, try mutate(a, r.wf, "permissions: {}", "permissions:\n  contents: write"), "outside a job's");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      contents: read\n", "      contents: read-all\n      x: write-all\n"), "write-all");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "    timeout-minutes: 15\n", "    timeout-minutes: 15\n    env:\n      P: contents: write\n"), "outside a job's");
    // a job with no permissions of its own would inherit the top
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "    permissions:\n      contents: read\n      attestations: read\n", ""), "states no `permissions:`");
    // the jobs that need their scope have it
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      contents: read\n", "      contents: write\n"), "job `tag` holds `contents: write`, which only publish may");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      contents: write\n", "      contents: read\n"), "`publish` does not hold `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "      id-token: write\n", "      id-token: read\n"), "`archive` does not hold `id-token: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "      attestations: write\n", ""), "`archive` does not hold `attestations: write`");
}

test "rule: the tag is made with the release bot's token, minted by `tag` alone with exact inputs, and used by the tag step alone" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const mint = "does not mint the release bot's token";
    // the job's own token only reads
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      contents: read\n", "      contents: read\n      packages: read\n"), "`tag` is not `contents: read` alone");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      contents: read\n", "      contents: write\n"), "`tag` is not `contents: read` alone");
    // each input of the mint is exact
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "app-id: ${{ vars.RELEASE_BOT_APP_ID }}", "app-id: 5395718"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "app-id: ${{ vars.RELEASE_BOT_APP_ID }}", "app-id: ${{ vars.RELEASE_TAGGER_APP_ID }}"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "owner: ${{ github.repository_owner }}\n", ""), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "owner: ${{ github.repository_owner }}\n", "owner: other\n"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "repositories: buildrules\n", ""), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "repositories: buildrules\n", "repositories: buildrules,mopm\n"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "permission-contents: write\n", "permission-contents: write\n          permission-actions: write\n"), "release bot's key, token or permission input appears other than once");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "permission-contents: write\n", "permission-contents: write\n          permission-actions: write\n"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "permission-contents: write\n", "permission-contents: read\n"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0", "v3.2.0"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0", "0000000000000000000000000000000000000000 # v3.2.0"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}", "private-key: ${{ secrets.OTHER_KEY }}"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}", "private-key: ${{ secrets.OTHER_KEY }}"), "reads a secret");
    // the tag step takes the bot's token and not GITHUB_TOKEN
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "GH_TOKEN: ${{ steps.bot.outputs.token }}", "GH_TOKEN: ${{ github.token }}"), "does not take the bot's token as its GH_TOKEN");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "GH_TOKEN: ${{ steps.bot.outputs.token }}", "GH_TOKEN: ${{ github.token }}"), "uses GITHUB_TOKEN");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      TAG: ${{ needs.plan.outputs.tag }}\n", "      TAG: ${{ needs.plan.outputs.tag }}\n      GH_TOKEN: ${{ github.token }}\n"), "uses GITHUB_TOKEN");
    // the minted token reaches no other step of `tag` and no other job
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      TAG: ${{ needs.plan.outputs.tag }}\n", "      TAG: ${{ needs.plan.outputs.tag }}\n      GH_TOKEN: ${{ steps.bot.outputs.token }}\n"), "other than once");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "GH_TOKEN: ${{ github.token }}", "GH_TOKEN: ${{ steps.bot.outputs.token }}"), "other than once");
    // nor is the key read, or the token minted, in any other job
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "GH_TOKEN: ${{ github.token }}", "GH_TOKEN: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}"), "appears other than once");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      - run: chmod +x tool/release\n", "      - uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n        with:\n          app-id: 1\n"), "used other than once, in `tag`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      - run: chmod +x tool/release\n", "      - uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n        with:\n          app-id: 1\n"), "used other than once, in `tag`");
    // and publish still holds the job token's write, which creates no tag
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      contents: write\n", "      contents: read\n"), "`publish` does not hold `contents: write`");
}

test "rule: tag and publish run under their exact if" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const exact_tag = "the job `tag` is not under its exact `if:`";
    const exact_pub = "the job `publish` is not under its exact `if:`";
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", " && github.ref == 'refs/heads/main'", ""), exact_tag);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", " && !github.event.repository.fork", ""), exact_tag);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "github.event_name == 'push' &&", "github.event_name == 'push' ||"), exact_tag);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "needs.plan.outputs.released == 'true' && ", ""), exact_tag);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "    if: ${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork }}\n", ""), exact_tag);
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", " && github.ref == 'refs/heads/main'", ""), exact_pub);
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "github.event_name == 'push'", "true"), exact_pub);
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "needs.plan.outputs.released == 'true' && ", ""), exact_pub);
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "    if: ${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork }}\n", ""), exact_pub);
}

test "rule: the order gate -> beta -> gamma -> plan -> archive -> verify -> tag -> publish, and nothing before the tag waits for it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    // gamma waits for beta, and beta for gate
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "needs: [beta, tool]", "needs: [tool]"), "`gamma` does not wait for `beta`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "needs: [beta, tool]", "needs: [beta]"), "`gamma` does not wait for `tool`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "    needs: [gate]\n", ""), "`beta` does not wait for `gate`");
    // the chain after the stages: plan after gamma, archive after plan, verify after archive, tag after verify, publish after tag
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "needs: [gamma, tool]", "needs: [tool]"), "`plan` does not wait for `gamma`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "needs: [plan, tool]", "needs: [tool]"), "`archive` does not wait for `plan`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "needs: [plan, archive, cli, tool]", "needs: [plan, tool]"), "`verify` does not wait for `archive`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "needs: [plan, verify, tool]", "needs: [plan, tool]"), "`tag` does not wait for `verify`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "needs: [plan, verify, tool]", "needs: [verify, tool]"), "`tag` does not wait for `plan`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "needs: [plan, tag, verify, tool]", "needs: [plan, verify, tool]"), "`publish` does not wait for `tag`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "needs: [plan, tag, verify, tool]", "needs: [plan, tag, tool]"), "`publish` does not wait for `verify`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "needs: [plan, tag, verify, tool]", "needs: [plan, tag, tool]"), "`site` does not wait for `verify`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "needs: [plan, tag, verify, tool]", "needs: [plan, verify, tool]"), "`site` does not wait for `tag`");
    // nothing before the tag waits for it: a failure there must leave no tag (the old order, archive after tag, is red)
    const waits = "waits for `tag` or `publish`";
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "needs: [plan, tool]", "needs: [plan, tag, tool]"), waits);
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "needs: [plan, archive, cli, tool]", "needs: [plan, archive, cli, tag, tool]"), waits);
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "needs: [gamma, tool]", "needs: [gamma, tag, tool]"), waits);
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "needs: [beta, tool]", "needs: [beta, tool, tag]"), waits);
    // the plan only reads and cannot be skipped
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "      contents: read\n", "      contents: write\n"), "job `plan` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "    timeout-minutes: 15\n", "    timeout-minutes: 15\n    if: ${{ vars.X == '' }}\n"), "`plan` has an `if:`");
    // the archive and verify are of the commit: no ref of a tag (it does not exist yet), and the sha is passed
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n", "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          ref: refs/tags/${{ needs.plan.outputs.tag }}\n"), "reads a tag by ref");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "--sha \"$GITHUB_SHA\" ", ""), "`verify` does not pass `--sha");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "--sha \"$GITHUB_SHA\" ", ""), "`archive` does not pass `--sha");
    // the command line is stamped with the planned version and verify runs it: each link of that chain is held
    try expectFinding(a, r, try mutateIn(a, r.wf, "cli", " -c \"buildrules.release_version=$NUMBER\"", ""), "`cli` does not stamp the planned version");
    try expectFinding(a, r, try mutateIn(a, r.wf, "cli", "needs.plan.outputs.number", "needs.plan.outputs.tag"), "`cli` does not take the planned version from the plan");
    try expectFinding(a, r, try mutateIn(a, r.wf, "cli", " //cli:buildrules", " //tools/release:release"), "`cli` does not build //cli:buildrules");
    try expectFinding(a, r, try mutateIn(a, r.wf, "cli", "name: release-cli", "name: other"), "`cli` does not upload the artifact `release-cli`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "cli", " -c buildrules_re.mode=local", ""), "does not pass `-c buildrules_re.mode=local`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "cli", "      contents: read\n", "      contents: write\n"), "job `cli` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "cli", "needs: [plan, tool]", "needs: [plan]"), "`cli` does not wait for `tool`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "cli", "needs: [plan, tool]", "needs: [tool]"), "`cli` does not wait for `plan`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "cli", "needs: [plan, tool]", "needs: [plan, tag, tool]"), "`cli` waits for `tag` or `publish`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "cli", "    if: ${{ needs.plan.outputs.released == 'true' }}\n", ""), "`cli` runs even when the plan released nothing");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "needs: [plan, archive, cli, tool]", "needs: [plan, archive, tool]"), "`verify` does not wait for `cli`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", " --cli built-cli/buildrules", ""), "`verify` does not pass `--cli");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "name: release-cli", "name: other"), "`verify` does not download the artifact `release-cli`");
    try expectFinding(a, r, try mutate(a, r.wf, "      number: ${{ steps.version.outputs.number }}\n", ""), "`plan` does not output the version number");
    // gate is a call of ci.yml that cannot be skipped, with read access only
    try expectFinding(a, r, try mutate(a, r.wf, "    uses: ./.github/workflows/ci.yml\n", "    runs-on: ubuntu-latest\n"), "`gate` does not call");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gate", "    permissions:\n", "    if: ${{ github.event_name == 'push' }}\n    permissions:\n"), "`gate` has an `if:`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gate", "      contents: read\n", "      contents: read\n      packages: read\n"), "`gate` is not `contents: read` alone");
    // ci.yml must be callable
    try expectFinding(a, .{ .wf = r.wf, .ds = r.ds, .ci = "on:\n  pull_request:\n" }, r.wf, "no `workflow_call:` trigger");
    // a missing job
    for ([_][]const u8{ "publish", "verify", "beta", "gamma", "site", "plan", "tag" }) |name| {
        const from = try std.fmt.allocPrint(a, "\n  {s}:\n", .{name});
        const to = try std.fmt.allocPrint(a, "\n  {s}_x:\n", .{name});
        const want = try std.fmt.allocPrint(a, "the job `{s}` is missing", .{name});
        try expectFinding(a, r, try mutate(a, r.wf, from, to), want);
    }
}

test "rule: beta is a call of beta.yml that cannot be skipped, with the farm leg's token and nothing else" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, try mutate(a, r.wf, "    uses: ./.github/workflows/beta.yml\n", "    runs-on: ubuntu-latest\n"), "`beta` does not call");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "    needs: [gate]\n", "    needs: [gate]\n    if: ${{ vars.FARM_ADDRESS != '' }}\n"), "`beta` has an `if:`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "      id-token: write\n", ""), "`beta` is not `contents: read` and `id-token: write` alone");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "      id-token: write\n", "      id-token: write\n      packages: read\n"), "`beta` is not `contents: read` and `id-token: write` alone");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "      contents: read\n", "      contents: write\n"), "job `beta` holds `contents: write`");
    // the workflow it calls must be pinned like any other local reference: only these three are allowed
    try expectFinding(a, r, try mutate(a, r.wf, "uses: ./.github/workflows/beta.yml", "uses: ./.github/workflows/beta2.yml"), "not pinned");
}

test "rule: gamma holds the farm's token and no more, cannot be skipped, and checks the action it uses before it uses it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    // the token
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "      contents: read\n      id-token: write\n", "      contents: write\n      id-token: write\n"), "job `gamma` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "      contents: read\n      id-token: write\n", "      contents: read\n"), "`gamma` is not `contents: read` and `id-token: write` alone");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "      id-token: write\n", "      id-token: write\n      attestations: write\n"), "job `gamma` holds `attestations: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tool", "      contents: read\n", "      contents: read\n      id-token: write\n"), "job `tool` holds `id-token: write`");
    // it cannot be skipped
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "    timeout-minutes: 240\n", "    timeout-minutes: 240\n    if: ${{ vars.FARM_ADDRESS != '' }}\n"), "`gamma` has an `if:`");
    // the action comes from the variables, is verified, then used, then the build runs
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "repository: ${{ vars.FARM_CONNECT_REPO }}", "repository: some/where"), "does not check the farm-connect action out");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "ref: ${{ vars.FARM_CONNECT_REF }}", "ref: main"), "does not check the farm-connect action out");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "        run: tool/stage action-ref --dir farm-action --ref \"$CONNECT_REF\"\n", "        run: echo skipped\n"), "`gamma` does not run `tool/stage action-ref");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "        run: tool/stage action-ref --dir farm-action --ref \"$CONNECT_REF\"\n", "        run: echo skipped\n"), "has no `tool/stage action-ref ");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "        run: tool/stage gamma-vars", "        run: echo gamma-vars"), "`gamma` does not run `tool/stage gamma-vars");
    // the action reference is the checked-out one; a pinned third party is fine, an unpinned one or another local path is not
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "uses: ./farm-action/.github/actions/farm-connect", "uses: ./other/.github/actions/farm-connect"), "not pinned");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "uses: ./farm-action/.github/actions/farm-connect", "uses: org/connect@main"), "not pinned");
    // the verification after the action is not a verification
    {
        const wf = try mutateIn(a, r.wf, "gamma", "      - name: the action that joins the farm is at the commit the variable names\n        run: tool/stage action-ref --dir farm-action --ref \"$CONNECT_REF\"\n", "");
        const wf2 = try mutateIn(a, wf, "gamma", "      - name: Build our repositories with the candidate on the farm\n", "      - run: tool/stage action-ref --dir farm-action --ref \"$CONNECT_REF\"\n      - name: Build our repositories with the candidate on the farm\n");
        try expectFinding(a, r, wf2, "has no `uses: ./farm-action/.github/actions/farm-connect` after the step before it");
    }
    // it runs no buck2 itself
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "      - run: chmod +x tool/stage tool/buck2\n", "      - run: ./buck2 build -c buildrules_re.mode=local //x:y\n"), "holds the farm's token and runs buck2 itself");
    // a checkout of the action that keeps credentials
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "          path: farm-action\n          persist-credentials: false\n", "          path: farm-action\n"), "persist-credentials");
    // the stage tool is built by the workflow
    try expectFinding(a, r, try mutate(a, r.wf, "--out stage //tools/stage:stage", "--out stage //tools/other:stage"), "does not build //tools/stage:stage");
}

test "rule: the page of the release is made from the verified files by a job that only reads" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "      contents: read\n", "      contents: write\n"), "job `site` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "      contents: read\n", "      contents: read\n      id-token: write\n"), "job `site` holds `id-token: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "if: ${{ needs.plan.outputs.released == 'true' }}", "if: ${{ true }}"), "`site` runs even when the plan released nothing");
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "tool/release site ", "echo site "), "`site` does not run `tool/release site");
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "name: release-site", "name: other"), "does not upload the artifact `release-site`");
}

test "rule: a release is made only for a commit the plan released, and no job runs after a red one" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "    if: ${{ needs.plan.outputs.released == 'true' }}\n", ""), "`archive` runs even when the plan released nothing");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "needs.plan.outputs.released == 'true'", "true"), "`verify` runs even when the plan released nothing");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "if: ${{ needs.plan.outputs.released == 'true' }}", "if: ${{ always() && needs.plan.outputs.released == 'true' }}"), "`always()`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "if: ${{ needs.plan.outputs.released", "if: ${{ failure() || needs.plan.outputs.released"), "`failure()`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "if: ${{ needs.plan.outputs.released == 'true' }}", "if: ${{ cancelled() || needs.plan.outputs.released == 'true' }}"), "`cancelled()`");
}

test "rule: the tag job is in the release concurrency group and none is cancelled" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const need = "concurrency group `release` with `cancel-in-progress: false`";
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "cancel-in-progress: false", "cancel-in-progress: true"), need);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "group: release", "group: release-${{ github.sha }}"), need);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "    concurrency:\n      group: release\n      cancel-in-progress: false\n", ""), need);
}

test "rule: the attestation is made in archive, once" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, try mutate(a, r.wf, "actions/attest-build-provenance@", "actions/attest-sbom@"), "does not attest");
    // a second attestation elsewhere
    const second = "      - uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2\n        with:\n          subject-path: x\n      - run: chmod +x tool/release\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      - run: chmod +x tool/release\n", second), "used other than once");
}

test "rule: the jobs that write run no buck2 and use no action but the checkout and download" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
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
    const r = try fx(a);
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "tool/release verify ", "echo verify "), "`verify` does not run `tool/release verify");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "tool/release publish ", "echo publish "), "`publish` does not run `tool/release publish");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "tool/release archive ", "echo archive "), "`archive` does not run");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "tool/release tag ", "echo tag "), "`tag` does not run");
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "tool/release plan ", "echo plan "), "`plan` does not run");
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
    const r = try fx(a);
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "--dist dist\n", "--dist dist --clobber\n"), "--clobber");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      - run: chmod +x tool/release\n", "      - run: gh release delete v1\n"), "release delete");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "GH_TOKEN: ${{ github.token }}", "GH_TOKEN: ${{ secrets.X }}"), "reads a secret");
}

test "rule: buck2 runs in local mode, as the literal ./buck2, from the pinned release, and the tool is built" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
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

test "rule: continue-on-error lets no red stage pass (gamma job E, gamma step F, the beta caller B), and `false` is the one value allowed" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const rule = "`continue-on-error` is set to";
    // E: the gamma job
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "    timeout-minutes: 240\n", "    timeout-minutes: 240\n    continue-on-error: true\n"), rule);
    // F: a step of gamma
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "      - run: chmod +x tool/stage tool/buck2\n", "      - run: chmod +x tool/stage tool/buck2\n        continue-on-error: true\n"), rule);
    // B: the job of release.yml that calls beta
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "    needs: [gate]\n", "    needs: [gate]\n    continue-on-error: true\n"), rule);
    // an expression, a quoted value and a flow mapping are no better than `true`
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "    timeout-minutes: 240\n", "    timeout-minutes: 240\n    continue-on-error: ${{ vars.X == '' }}\n"), rule);
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "    timeout-minutes: 240\n", "    timeout-minutes: 240\n    continue-on-error: \"true\"\n"), rule);
    // `false` is what the default is: no finding
    const ok = try mutateIn(a, r.wf, "gamma", "    timeout-minutes: 240\n", "    timeout-minutes: 240\n    continue-on-error: false # the default, said\n");
    try t.expectEqual(@as(usize, 0), (try checkRelease(a, ok, r.ds, r.ci)).items.len);
}

test "rule: no run line expands vars or github.event inline (the gamma-vars step reads its values from env)" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const rule = "expands `vars.` inline";
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "--connect-repo \"$CONNECT_REPO\"", "--connect-repo \"${{ vars.FARM_CONNECT_REPO }}\""), rule);
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "--farm-address \"$HAS_ADDRESS\"", "--farm-address ${{ vars.FARM_ADDRESS != '' }}"), rule);
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "        run: tool/stage action-ref --dir farm-action --ref \"$CONNECT_REF\"\n", "        run: tool/stage action-ref --ref \"${{ github.event.head_commit.message }}\"\n"), "expands `github.event.` inline");
    // the block form of `run:`
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "      - run: chmod +x tool/stage tool/buck2\n", "      - run: |\n          echo \"${{ vars.X }}\"\n"), rule);
    // an expression in env, in `with:` or in `if:` is the safe place and is not a finding
    const ok = try mutateIn(a, r.wf, "gamma", "    timeout-minutes: 240\n", "    timeout-minutes: 240\n    if: ${{ vars.X == '' }}\n");
    for ((try checkRelease(a, ok, r.ds, r.ci)).items) |m| try t.expect(std.mem.indexOf(u8, m, "inline") == null);
}
