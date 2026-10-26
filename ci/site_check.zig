//! The site workflows (.github/workflows/site.yml, the caller, and site-publish.yml, the reusable workflow the AWS role trusts) are what RELEASING.md "The site" and
//! infra/site/README.md say they are. A pure function of the text per file, so each rule is tested against faulty text as well as against the real files (the
//! zig_test's `data`, under BUILDRULES_TEST_WORK). The rules shared with the other workflows (actions pinned by commit, local mode, the pinned buck2 install, no
//! `continue-on-error`, no inline expansion of `vars.` or `github.event.` in a `run:`) are workflow_check.zig's.
//!
//! What the rules catch:
//!  - the callers: only a finished `release` run on main (green, for a push, not from a fork) and a manual run trigger the caller; no pull request or push;
//!  - the deploy only of the tip of main, and only once the environment `prod` exists: the plan job reads both and every other job waits for its answer;
//!  - the token: `id-token: write` in the call of site-publish.yml and in the one job of that file, nowhere else, and no other write scope anywhere;
//!  - the call of site-publish.yml is the local path of the file that infra/site/lib/config.ts makes the role trust, and the job declares the environment
//!    that file names (a different file or environment is a token the role refuses, or one that skips the branch policy of the environment);
//!  - no third-party action: the caller uses the checkout and the upload of artifacts, the reusable workflow the download of artifacts, all pinned by commit; the
//!    token exchange is the two hand-rolled calls, with the audience and the one-hour session of the role;
//!  - the fail-safe: with a variable of the environment empty the job gives a notice and ends green with every later step skipped, and no step that holds
//!    or uses the cloud's credentials runs unless the first step said `publish`;
//!  - the three values are masked before their first use, the claims step prints the named claims and never the token, and no step traces its commands;
//!  - the uploads: the hashed stylesheet first and immutable, the pages pruned without touching the hashed stylesheets or the release pages, the release
//!    pages never pruned, then the invalidation and the smoke test, with `--delete` on the one command that may prune.
const std = @import("std");
const wc = @import("workflow_check.zig");
const t = std.testing;

const Findings = wc.Findings;
const add = wc.add;

// ---- reading the text ----------------------------------------------------------------------------------------------------------------------

fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// `wf` without the lines that are only a comment, so a rule is never satisfied (or tripped) by what a comment says.
fn code(a: std.mem.Allocator, wf: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var it = std.mem.splitScalar(u8, wf, '\n');
    var first = true;
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " "), "#")) continue;
        if (!first) try out.append('\n');
        first = false;
        try out.appendSlice(line);
    }
    return out.toOwnedSlice();
}

/// The text under the top-level key `key` (`on`, `jobs`): up to the next line that starts in column 0.
fn topBlock(wf: []const u8, key: []const u8, buf: []u8) ?[]const u8 {
    const open = std.fmt.bufPrint(buf, "\n{s}:", .{key}) catch return null;
    const at = std.mem.indexOf(u8, wf, open) orelse return null;
    const from = std.mem.indexOfScalarPos(u8, wf, at + 1, '\n') orelse return wf[at..];
    var pos = from + 1;
    while (pos < wf.len) {
        const c = wf[pos];
        if (c != ' ' and c != '\n') return wf[from..pos];
        pos = (std.mem.indexOfScalarPos(u8, wf, pos, '\n') orelse return wf[from..]) + 1;
    }
    return wf[from..];
}

/// The keys written at two spaces of indent inside `block` (the triggers under `on:`, the jobs under `jobs:`).
fn keys(a: std.mem.Allocator, block: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, block, '\n');
    while (it.next()) |line| {
        if (line.len < 4 or line[0] != ' ' or line[1] != ' ' or line[2] == ' ' or line[2] == '-') continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        try out.append(line[2..colon]);
    }
    return out.toOwnedSlice();
}

/// The text of job `name`: from its key to the next job key.
fn jobText(wf: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const key = std.fmt.bufPrint(buf, "\n  {s}:\n", .{name}) catch return null;
    const at = std.mem.indexOf(u8, wf, key) orelse return null;
    var pos = at + key.len;
    var end = wf.len;
    while (pos < wf.len) {
        const nl = std.mem.indexOfScalarPos(u8, wf, pos, '\n') orelse wf.len;
        const line = wf[pos..nl];
        if (line.len > 2 and line[0] == ' ' and line[1] == ' ' and line[2] != ' ') {
            end = pos;
            break;
        }
        pos = nl + 1;
    }
    return wf[at + 1 .. end];
}

/// The steps of a job: each from its `      - ` line to the next.
fn steps(a: std.mem.Allocator, job: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var starts = std.ArrayList(usize).init(a);
    var pos: usize = 0;
    while (pos < job.len) {
        const nl = std.mem.indexOfScalarPos(u8, job, pos, '\n') orelse job.len;
        if (std.mem.startsWith(u8, job[pos..nl], "      - ")) try starts.append(pos);
        pos = nl + 1;
    }
    for (starts.items, 0..) |s, i| {
        const e = if (i + 1 < starts.items.len) starts.items[i + 1] else job.len;
        try out.append(job[s..e]);
    }
    return out.toOwnedSlice();
}

/// The value of the first line of `text` that starts (after its indent) with `key`, trimmed (`if: ` -> the expression).
fn lineValue(text: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimLeft(u8, std.mem.trimLeft(u8, raw, " "), "- ");
        if (std.mem.startsWith(u8, line, key)) return std.mem.trim(u8, line[key.len..], " \r");
    }
    return null;
}

/// The `'...'` value of `export const NAME = '...'` in infra/site/lib/config.ts.
fn configValue(config: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const open = std.fmt.bufPrint(buf, "export const {s} = '", .{name}) catch return null;
    return wc.between(config, open, "'");
}

/// Every `uses:` value of `wf` up to its `@`, and whether it is a local path.
fn usedActions(a: std.mem.Allocator, wf: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, wf, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " -");
        if (!std.mem.startsWith(u8, line, "uses:")) continue;
        var v = std.mem.trim(u8, line["uses:".len..], " ");
        if (std.mem.indexOfScalar(u8, v, '@')) |at| v = v[0..at] else if (std.mem.indexOfScalar(u8, v, ' ')) |sp| v = v[0..sp];
        try out.append(v);
    }
    return out.toOwnedSlice();
}

fn onlyActions(a: std.mem.Allocator, f: *Findings, wf: []const u8, allowed: []const []const u8, file: []const u8) !void {
    for (try usedActions(a, wf)) |u| {
        var ok = false;
        for (allowed) |x| {
            if (std.mem.eql(u8, x, u)) ok = true;
        }
        if (!ok) try add(a, f, "{s}: the action `{s}` is not allowed (no third-party action runs here; the allowed ones are pinned and few)", .{ file, u });
    }
}

/// Every `: write` of `wf` is `id-token: write` inside job `token_job`; `write-all` is refused; the top level grants nothing (`permissions: {}`).
fn writeScopes(a: std.mem.Allocator, f: *Findings, wf: []const u8, token_job: []const u8, file: []const u8) !void {
    if (!wc.hasLine(wf, "permissions: {}")) try add(a, f, "{s}: the top-level `permissions: {{}}` is missing (every job names what it needs)", .{file});
    if (has(wf, "write-all")) try add(a, f, "{s}: `write-all` is granted", .{file});
    var jb: [64]u8 = undefined;
    var blk: [16]u8 = undefined;
    const jobs_block = topBlock(wf, "jobs", &blk) orelse "";
    const all_keys = try keys(a, jobs_block);
    const jobs_at = std.mem.indexOf(u8, wf, "\njobs:") orelse wf.len;
    if (has(wf[0..jobs_at], ": write")) try add(a, f, "{s}: a write permission above the jobs", .{file});
    for (all_keys) |name| {
        const jt = jobText(wf, name, &jb) orelse continue;
        var it = std.mem.splitScalar(u8, jt, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r");
            if (!has(line, ": write")) continue;
            if (!(std.mem.eql(u8, line, "id-token: write") and std.mem.eql(u8, name, token_job)))
                try add(a, f, "{s}: job `{s}` holds the write permission `{s}` (only `id-token: write` in `{s}`)", .{ file, name, line, token_job });
        }
    }
}

/// The triggers (`on:`) of `wf` are exactly `want`, and no pull request or push appears in the file's code.
fn triggerSet(a: std.mem.Allocator, f: *Findings, wf: []const u8, want: []const []const u8, file: []const u8) !void {
    var buf: [8]u8 = undefined;
    const block = topBlock(wf, "on", &buf) orelse {
        try add(a, f, "{s}: no `on:` block", .{file});
        return;
    };
    const got = try keys(a, block);
    var ok = got.len == want.len;
    for (want) |w| {
        var found = false;
        for (got) |g| {
            if (std.mem.eql(u8, g, w)) found = true;
        }
        if (!found) ok = false;
    }
    if (!ok) try add(a, f, "{s}: the triggers are not exactly {d} ({s} ...): got {d}", .{ file, want.len, want[0], got.len });
    if (has(wf, "pull_request")) try add(a, f, "{s}: a pull request trigger (or the word) is present: this workflow holds a cloud token and must never run fork code", .{file});
}

/// Whether a `set -<flags>` line of `text` has the `x` flag (or `-o xtrace` is used).
fn traces(text: []const u8) bool {
    if (has(text, "xtrace")) return true;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, "set -")) |i| {
        var j = i + "set -".len;
        while (j < text.len and std.ascii.isAlphabetic(text[j])) : (j += 1) {
            if (text[j] == 'x') return true;
        }
        pos = i + 1;
    }
    return false;
}

fn expectLines(a: std.mem.Allocator, f: *Findings, text: []const u8, file: []const u8, wants: []const []const u8) !void {
    for (wants) |w| {
        if (!has(text, w)) try add(a, f, "{s}: missing `{s}`", .{ file, w });
    }
}

// ---- site.yml ----------------------------------------------------------------------------------------------------------------------------

const call_event_clauses = [_][]const u8{
    "github.event.workflow_run.conclusion == 'success'",
    "github.event.workflow_run.event == 'push'",
    "github.event.workflow_run.head_branch == 'main'",
    "github.event.workflow_run.head_repository.full_name == github.repository",
};

const actions_caller = [_][]const u8{ "actions/checkout", "actions/upload-artifact" };
const actions_publish = [_][]const u8{"actions/download-artifact"};

pub fn checkCaller(a: std.mem.Allocator, raw: []const u8, dotslash: []const u8, config: []const u8) !Findings {
    var f = Findings.init(a);
    const wf = try code(a, raw);
    const file = "site.yml";
    var cb: [64]u8 = undefined;

    try wc.noContinueOnError(a, &f, wf);
    try wc.noInlineContext(a, &f, wf);
    try wc.buck2Install(a, &f, wf, dotslash);
    const call_path = try std.fmt.allocPrint(a, "./{s}", .{configValue(config, "PUBLISH_WORKFLOW", &cb) orelse "?"});
    const uses = try wc.pinnedUses(a, &f, wf, &.{call_path});
    if (uses == 0) try add(a, &f, "{s}: no `uses:` line found (this parser is blind)", .{file});
    const allowed = try std.mem.concat(a, []const u8, &.{ &actions_caller, &.{call_path} });
    try onlyActions(a, &f, wf, allowed, file);
    try writeScopes(a, &f, wf, "publish", file);
    try triggerSet(a, &f, wf, &.{ "workflow_run", "workflow_dispatch" }, file);
    try expectLines(a, &f, wf, file, &.{
        "    workflows: [release]",
        "    types: [completed]",
        "    branches: [main]",
        "      claims_only:",
        "        type: boolean",
    });
    if (has(wf, "secrets.")) try add(a, &f, "{s}: the workflow reads a secret (it has none; the cloud is reached by OIDC in site-publish.yml)", .{file});
    if (has(wf, "aws ") or has(wf, "AWS_")) try add(a, &f, "{s}: the caller touches the cloud (only site-publish.yml does)", .{file});

    // One deploy at a time and none cancelled.
    if (!has(wf, "concurrency:\n  group: site\n  cancel-in-progress: false")) try add(a, &f, "{s}: the concurrency group `site` with `cancel-in-progress: false` is missing (a deploy cancelled half way leaves a mixed site)", .{file});

    // The jobs.
    var jb: [16]u8 = undefined;
    const jobs_block = topBlock(wf, "jobs", &jb) orelse "";
    const names = try keys(a, jobs_block);
    const want_jobs = [_][]const u8{ "plan", "build", "publish" };
    if (names.len != want_jobs.len) try add(a, &f, "{s}: the jobs are not exactly plan, build, publish", .{file});
    var buf: [16]u8 = undefined;
    const plan = jobText(wf, "plan", &buf) orelse "";
    const build = jobText(wf, "build", &buf) orelse "";
    const publish = jobText(wf, "publish", &buf) orelse "";
    if (plan.len == 0 or build.len == 0 or publish.len == 0) {
        try add(a, &f, "{s}: a job of plan, build, publish is missing", .{file});
        return f;
    }

    // plan: which runs may deploy.
    const plan_if = lineValue(plan, "if: ") orelse "";
    if (!has(plan_if, "github.event_name == 'workflow_dispatch'")) try add(a, &f, "{s}: the plan job's `if` does not admit the manual run", .{file});
    for (call_event_clauses) |c| {
        if (!has(plan_if, c)) try add(a, &f, "{s}: the plan job's `if` lacks `{s}` (a red, a non-push, a non-main or a fork run of the release would deploy)", .{ file, c });
    }
    if (has(plan, "id-token")) try add(a, &f, "{s}: the plan job names an id-token", .{file});
    try expectLines(a, &f, plan, file, &.{
        "      contents: read\n      actions: read\n    outputs:",
        "tip=$(gh api \"repos/$GITHUB_REPOSITORY/commits/main\" --jq .sha)",
        "if [ \"$tip\" != \"$sha\" ]; then",
        "if [ \"$REF\" != refs/heads/main ]; then",
        "gh api \"repos/$GITHUB_REPOSITORY/environments/prod\" --silent",
        "echo \"deploy=true\" >> \"$GITHUB_OUTPUT\"",
        "::notice title=site not published::",
    });
    if (count(plan, "echo \"deploy=false\" >> \"$GITHUB_OUTPUT\"") != 3) try add(a, &f, "{s}: the plan job must answer `deploy=false` (with a notice, and green) for a non-main run, a superseded commit and a missing environment", .{file});
    if (has(plan, "exit 1") or has(plan, "::error")) try add(a, &f, "{s}: the plan job fails where it must say no deploy and end green", .{file});

    // build: waits for the plan, builds the planned commit in local mode, holds no token.
    const build_if = lineValue(build, "if: ") orelse "";
    if (!has(build_if, "needs.plan.outputs.deploy == 'true'")) try add(a, &f, "{s}: the build job does not wait for the plan's `deploy == 'true'`", .{file});
    if (!has(build, "    needs: [plan]\n")) try add(a, &f, "{s}: the build job does not `needs: [plan]`", .{file});
    if (!has(build_if, "!(github.event_name == 'workflow_dispatch' && inputs.claims_only)")) try add(a, &f, "{s}: the build job runs for a claims-only run", .{file});
    if (has(build, "id-token")) try add(a, &f, "{s}: the build job names an id-token", .{file});
    try expectLines(a, &f, build, file, &.{
        "      contents: read\n      actions: read\n    env:",
        "          ref: ${{ needs.plan.outputs.sha }}\n          persist-credentials: false",
        "./buck2 build --console simple -c buildrules_re.mode=local --show-full-output //site:test //site:dist > ",
        "name: site-dist",
        "if-no-files-found: error",
        "cp -rL --no-preserve=mode \"$dist\" site-out/tree",
        "test -z \"$(find site-out -type l)\"",
        "test -f site-out/tree/index.html",
    });
    // Buck2 prints a relative symlink for a directory output; copied as a link it dangles from site-out/ and upload-artifact leaves it out.
    if (has(build, "cp -r ") or has(build, "cp -R ") or has(build, "cp -a ") or has(build, "cp -P")) try add(a, &f, "{s}: a `cp` in the build job does not follow symlinks (Buck2's directory output is a relative symlink: copied as a link it dangles and upload-artifact omits it; use `cp -rL`)", .{file});
    if (count(build, "actions/checkout@") != count(build, "persist-credentials: false")) try add(a, &f, "{s}: a checkout keeps its credentials (`persist-credentials: false` is missing)", .{file});
    const builds = try wc.localMode(a, &f, wf);
    if (builds == 0) try add(a, &f, "{s}: no `./buck2 build` found (the site is not built, or this parser is blind)", .{file});

    // publish: the call, with the token, once the plan said so.
    const publish_if = lineValue(publish, "if: ") orelse "";
    if (!has(publish_if, "needs.plan.outputs.deploy == 'true'")) try add(a, &f, "{s}: the publish call does not wait for the plan's `deploy == 'true'`", .{file});
    if (!has(publish_if, "needs.build.result == 'success'")) try add(a, &f, "{s}: the publish call does not wait for a green build", .{file});
    if (!has(publish_if, "!cancelled()")) try add(a, &f, "{s}: the publish call's `if` lacks `!cancelled()`, so a skipped build (claims only) would skip it too", .{file});
    if (!has(publish, "    needs: [plan, build]\n")) try add(a, &f, "{s}: the publish call does not `needs: [plan, build]`", .{file});
    const want_uses = try std.fmt.allocPrint(a, "    uses: {s}\n", .{call_path});
    if (!has(publish, want_uses)) try add(a, &f, "{s}: the publish call is not `uses: {s}` (the role trusts that file from refs/heads/main; a call by a name or ref of another form is a token the role may refuse)", .{ file, call_path });
    if (count(wf, "site-publish") != 1) try add(a, &f, "{s}: site-publish is named other than by the one call", .{file});
    try expectLines(a, &f, publish, file, &.{
        "      contents: read\n      id-token: write\n    uses:",
        "      claims_only: ${{ github.event_name == 'workflow_dispatch' && inputs.claims_only }}",
    });
    // The main-only guard must match the ref the role trusts.
    var cb2: [64]u8 = undefined;
    const ref = configValue(config, "WORKFLOW_REF", &cb2) orelse "?";
    if (!std.mem.eql(u8, ref, "refs/heads/main")) try add(a, &f, "{s}: infra/site/lib/config.ts trusts the ref `{s}`, not refs/heads/main (the plan job deploys only main)", .{ file, ref });
    return f;
}

// ---- site-publish.yml ----------------------------------------------------------------------------------------------------------------------

const publish_gate = "if: ${{ steps.vars.outputs.mode == 'publish' }}";
const claims_gate = "if: ${{ steps.vars.outputs.mode == 'claims' }}";

const assets_cmd = "aws s3 sync site-out/tree/assets \"s3://$SITE_BUCKET/assets\" --no-progress --exclude 'icon.svg' --cache-control 'public, max-age=31536000, immutable'";
const pages_cmd = "aws s3 sync site-out/tree \"s3://$SITE_BUCKET/\" --no-progress --delete --exclude 'assets/site.*.css' --exclude 'releases/*' --cache-control 'public, max-age=60, s-maxage=300'";
const releases_cmd = "aws s3 sync site-out/release/releases \"s3://$SITE_BUCKET/releases\" --no-progress --cache-control 'public, max-age=60, s-maxage=300'";
const invalidate_cmd = "aws cloudfront create-invalidation --distribution-id \"$SITE_DISTRIBUTION_ID\" --paths '/*'";

const claims_filter = "jq '{sub, job_workflow_ref, environment, repository_id, repository_owner_id, ref, aud}'";

const var_env = [_][2][]const u8{
    .{ "SITE_BUCKET", "BUILDRULES_SITE_BUCKET" },
    .{ "SITE_DISTRIBUTION_ID", "BUILDRULES_SITE_DISTRIBUTION_ID" },
    .{ "SITE_ROLE_ARN", "BUILDRULES_SITE_PUBLISH_ROLE_ARN" },
};

pub fn checkPublish(a: std.mem.Allocator, raw: []const u8, config: []const u8) !Findings {
    var f = Findings.init(a);
    const wf = try code(a, raw);
    const file = "site-publish.yml";

    try wc.noContinueOnError(a, &f, wf);
    try wc.noInlineContext(a, &f, wf);
    _ = try wc.pinnedUses(a, &f, wf, &.{});
    try onlyActions(a, &f, wf, &actions_publish, file);
    try writeScopes(a, &f, wf, "publish", file);
    try triggerSet(a, &f, wf, &.{"workflow_call"}, file);
    // the called workflow has no concurrency of its own: site.yml's group `site` already holds the deploy, and a group of the same name here would make the call wait for itself
    if (std.mem.indexOf(u8, wf, "concurrency:") != null) try add(a, &f, "{s}: the reusable workflow declares a concurrency group (the caller's group `site` serializes it; the same name here would deadlock the call)", .{file});
    try expectLines(a, &f, wf, file, &.{
        "      claims_only:\n        type: boolean",
        "      AWS_DEFAULT_REGION: us-east-1",
        "      SITE_URL: https://buildrules.dev",
    });
    if (has(wf, "secrets.")) try add(a, &f, "{s}: the workflow reads a secret (the role is assumed by OIDC; nothing else is needed)", .{file});
    if (has(wf, "buck2")) try add(a, &f, "{s}: the job that holds the cloud's token runs nothing of the repository (it uploads the artifact the caller built)", .{file});
    if (traces(wf)) try add(a, &f, "{s}: a step traces its commands (`set -x`, `set -euxo ...`), which prints the credentials", .{file});

    // What the role trusts (infra/site/lib/config.ts): this file, from main, in this environment, with this audience.
    var b1: [64]u8 = undefined;
    var b2: [64]u8 = undefined;
    var b3: [64]u8 = undefined;
    var b4: [64]u8 = undefined;
    const cfg_env = configValue(config, "GITHUB_ENVIRONMENT", &b1) orelse "?";
    const cfg_file = configValue(config, "PUBLISH_WORKFLOW", &b2) orelse "?";
    const cfg_aud = configValue(config, "OIDC_AUDIENCE", &b3) orelse "?";
    const cfg_ref = configValue(config, "WORKFLOW_REF", &b4) orelse "?";
    if (!std.mem.eql(u8, cfg_file, ".github/workflows/site-publish.yml")) try add(a, &f, "{s}: infra/site/lib/config.ts trusts the workflow `{s}`, not this file", .{ file, cfg_file });
    if (!std.mem.eql(u8, cfg_ref, "refs/heads/main")) try add(a, &f, "{s}: infra/site/lib/config.ts trusts the ref `{s}`, not refs/heads/main", .{ file, cfg_ref });
    if (!std.mem.eql(u8, cfg_env, "prod")) try add(a, &f, "{s}: infra/site/lib/config.ts trusts the environment `{s}`, and the held steps create `prod`", .{ file, cfg_env });

    var jb: [16]u8 = undefined;
    var kb: [16]u8 = undefined;
    const names = try keys(a, topBlock(wf, "jobs", &kb) orelse "");
    if (names.len != 1 or !std.mem.eql(u8, names[0], "publish")) try add(a, &f, "{s}: the jobs are not exactly `publish`", .{file});
    const job = jobText(wf, "publish", &jb) orelse {
        try add(a, &f, "{s}: the `publish` job is missing", .{file});
        return f;
    };
    const env_line = try std.fmt.allocPrint(a, "    environment: {s}\n", .{cfg_env});
    if (!has(job, env_line)) try add(a, &f, "{s}: the job does not declare `environment: {s}` (the role's `sub` carries it, and the environment's branch policy is what keeps a feature branch from the role)", .{ file, cfg_env });
    if (count(job, "environment:") != 1) try add(a, &f, "{s}: the job must declare exactly one environment", .{file});
    if (!has(job, "    permissions:\n      contents: read\n      id-token: write\n")) try add(a, &f, "{s}: the job's permissions are not exactly `contents: read` and `id-token: write`", .{file});
    for (var_env) |p| {
        const want = try std.fmt.allocPrint(a, "      {s}: ${{{{ vars.{s} }}}}\n", .{ p[0], p[1] });
        if (!has(job, want)) try add(a, &f, "{s}: `{s}` is not read from the variable {s}", .{ file, p[0], p[1] });
    }
    if (count(wf, "{{ vars.") != var_env.len) try add(a, &f, "{s}: the workflow reads a variable besides the three of the environment", .{file});

    // The steps: the first decides, every later one is gated on its answer.
    const all = try steps(a, job);
    if (all.len < 2 or !has(all[0], "id: vars\n")) {
        try add(a, &f, "{s}: the first step is not the `vars` step that decides (id: vars)", .{file});
        return f;
    }
    const first = all[0];
    if (!has(first, "::notice title=site not published::")) try add(a, &f, "{s}: the vars step gives no notice when a variable is missing", .{file});
    if (!has(first, "echo \"mode=skip\" >> \"$GITHUB_OUTPUT\"\n            exit 0")) try add(a, &f, "{s}: the vars step does not answer `mode=skip` and end green (exit 0) when a variable is missing: a release would go red before the setup", .{file});
    if (has(first, "exit 1") or has(first, "::error")) try add(a, &f, "{s}: the vars step fails where it must end green", .{file});
    if (!has(first, "echo \"mode=claims\" >> \"$GITHUB_OUTPUT\"") or !has(first, "echo \"mode=publish\" >> \"$GITHUB_OUTPUT\"")) try add(a, &f, "{s}: the vars step does not answer both `claims` and `publish`", .{file});
    // each of the three values is tested for emptiness, and a missing one is named
    for (var_env) |p| {
        const probe = try std.fmt.allocPrint(a, "[ -n \"${s}\" ] || missing=\"$missing {s}\"", .{ p[0], p[1] });
        if (!has(first, probe)) try add(a, &f, "{s}: the vars step does not test `{s}` for emptiness (missing `{s}`)", .{ file, p[0], probe });
    }
    if (!has(first, "if [ -n \"$missing\" ]; then")) try add(a, &f, "{s}: the vars step does not act on a missing value (`if [ -n \"$missing\" ]`)", .{file});
    // masks come before the answer `publish`, for each value
    const pub_at = std.mem.indexOf(u8, first, "echo \"mode=publish\"") orelse first.len;
    for (var_env) |p| {
        const mask = try std.fmt.allocPrint(a, "echo \"::add-mask::${s}\"", .{p[0]});
        const m_at = std.mem.indexOf(u8, first, mask);
        if (m_at == null or m_at.? > pub_at) try add(a, &f, "{s}: `{s}` is not masked before it is used (the log of a public repository is public)", .{ file, p[0] });
    }
    for (all[1..]) |step| {
        const g = lineValue(step, "if: ") orelse "";
        const head = step[0 .. std.mem.indexOfScalar(u8, step, '\n') orelse step.len];
        if (!has(g, "steps.vars.outputs.mode == '")) {
            try add(a, &f, "{s}: the step `{s}` is not gated on the answer of the vars step, so it runs when the setup was not done", .{ file, head });
            continue;
        }
        const touches_cloud = has(step, "aws ") or has(step, "assume-role") or has(step, "$SITE_") or has(step, "AWS_") or has(step, "download-artifact") or has(step, "curl -s");
        if (touches_cloud and !has(g, "mode == 'publish'") and !has(step, claims_filter)) try add(a, &f, "{s}: the step `{s}` touches the cloud or the site outside mode `publish`", .{ file, head });
        if (has(step, claims_filter) and !has(g, "mode == 'claims'")) try add(a, &f, "{s}: the claims step runs outside mode `claims`", .{file});
    }

    // The claims step prints named claims, never the token; the assume step is the one exchange.
    var claims_n: usize = 0;
    var assume_n: usize = 0;
    for (all[1..]) |step| {
        if (has(step, claims_filter)) claims_n += 1;
        if (has(step, "assume-role-with-web-identity")) assume_n += 1;
        if (has(step, "echo \"$jwt\"") or has(step, "echo \"$resp\"") or has(step, "printf '%s\\n' \"$jwt\"") or has(step, "cat \"$jwt\"")) try add(a, &f, "{s}: a step prints the token", .{file});
        if (has(step, "ACTIONS_ID_TOKEN_REQUEST_TOKEN")) {
            const aud = try std.fmt.allocPrint(a, "&audience={s}\")", .{cfg_aud});
            if (!has(step, aud)) try add(a, &f, "{s}: the token is not requested with the audience `{s}` that the role trusts", .{ file, cfg_aud });
            if (!has(step, "echo \"::add-mask::$jwt\"")) try add(a, &f, "{s}: the token is not masked", .{file});
        }
    }
    if (claims_n != 1) try add(a, &f, "{s}: there must be one claims step, printing only the named claims ({s})", .{ file, claims_filter });
    if (assume_n != 1) try add(a, &f, "{s}: there must be exactly one exchange of the token for the role", .{file});
    try expectLines(a, &f, job, file, &.{
        "--role-arn \"$SITE_ROLE_ARN\"",
        "--duration-seconds 3600",
        "echo \"::add-mask::$(printf '%s' \"$creds\" | jq -r \".$k\")\"",
        "} >> \"$GITHUB_ENV\"",
    });
    if (has(job, "--duration-seconds") and count(job, "--duration-seconds 3600") != 1) try add(a, &f, "{s}: the session is not the role's one hour", .{file});

    // The download is the artifact the caller built.
    if (!has(job, "      - uses: actions/download-artifact@")) try add(a, &f, "{s}: the artifact `site-dist` is not downloaded", .{file});
    try expectLines(a, &f, job, file, &.{ "          name: site-dist\n          path: site-out" });

    // The uploads, in their order, and the one `--delete`.
    var last: usize = 0;
    for ([_][]const u8{ assets_cmd, pages_cmd, releases_cmd, invalidate_cmd }) |want| {
        const at = std.mem.indexOf(u8, job, want);
        if (at == null) {
            try add(a, &f, "{s}: the command `{s}` is missing or changed", .{ file, want });
            continue;
        }
        if (at.? < last) try add(a, &f, "{s}: the command `{s}` is out of order (stylesheet, pages, release pages, invalidation)", .{ file, want });
        last = at.?;
    }
    if (count(job, "--delete") != 1) try add(a, &f, "{s}: `--delete` must appear once, on the pages command (it would erase the release pages or the hashed stylesheets elsewhere)", .{file});
    for ([_][]const u8{ "s3 rm", "s3 rb", "s3 mv", "s3 cp", "--acl", "s3api", "put-bucket", "delete-" }) |bad| {
        if (has(job, bad)) try add(a, &f, "{s}: the job runs `{s}`, beyond sync and one invalidation", .{ file, bad });
    }
    if (count(job, "aws s3 sync") != 3 or count(job, "aws cloudfront") != 1) try add(a, &f, "{s}: the job must run exactly three syncs and one invalidation", .{file});

    // The smoke test, last, gated like the uploads.
    const smoke = all[all.len - 1];
    if (!has(smoke, "name: Smoke test")) try add(a, &f, "{s}: the last step is not the smoke test", .{file});
    try expectLines(a, &f, smoke, file, &.{
        publish_gate,
        "want \"$SITE_URL/\" 200 site-out/tree/index.html",
        "want \"$SITE_URL/no-such-page-$GITHUB_RUN_ID/\" 404 site-out/tree/404.html",
        "grep -i '^content-security-policy: default-src'",
        "cmp -s \"$RUNNER_TEMP/body\" \"$3\"",
        "want \"$SITE_URL/releases/$tag/\" 200",
        "for i in $(seq 1 20)",
        "              sleep 15\n",
        "            return 1\n",
    });
    return f;
}

// ---- tests -------------------------------------------------------------------------------------------------------------------------------

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

const Real = struct { caller: []const u8, publish: []const u8, config: []const u8, ds: []const u8 };

fn real(a: std.mem.Allocator) !Real {
    return .{
        .caller = try work(a, ".github/workflows/site.yml"),
        .publish = try work(a, ".github/workflows/site-publish.yml"),
        .config = try work(a, "infra/site/lib/config.ts"),
        .ds = try work(a, "tools/buck2"),
    };
}

/// `text` with the first `from` replaced by `to`; fails the test if `from` is absent (a variant that changes nothing proves nothing).
fn mutate(a: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const i = std.mem.indexOf(u8, text, from) orelse return error.DefectDidNotApply;
    return std.mem.concat(a, u8, &.{ text[0..i], to, text[i + from.len ..] });
}

fn expectCaller(a: std.mem.Allocator, r: Real, wf: []const u8, needle: []const u8) !void {
    const f = try checkCaller(a, wf, r.ds, r.config);
    for (f.items) |m| {
        if (has(m, needle)) return;
    }
    std.debug.print("site.yml: expected a finding with `{s}`, got {d}:\n", .{ needle, f.items.len });
    for (f.items) |m| std.debug.print("  {s}\n", .{m});
    return error.DefectSurvived;
}

fn expectPublish(a: std.mem.Allocator, r: Real, wf: []const u8, config: []const u8, needle: []const u8) !void {
    const f = try checkPublish(a, wf, config);
    for (f.items) |m| {
        if (has(m, needle)) return;
    }
    std.debug.print("site-publish.yml: expected a finding with `{s}`, got {d}:\n", .{ needle, f.items.len });
    for (f.items) |m| std.debug.print("  {s}\n", .{m});
    _ = r;
    return error.DefectSurvived;
}

test "the real workflows have no findings" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const c = try checkCaller(a, r.caller, r.ds, r.config);
    for (c.items) |m| std.debug.print("site.yml finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), c.items.len);
    const p = try checkPublish(a, r.publish, r.config);
    for (p.items) |m| std.debug.print("site-publish.yml finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), p.items.len);
}

test "the parsers are not blind: the real files have the jobs, steps and triggers the rules read" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const c = try code(a, r.caller);
    var buf: [16]u8 = undefined;
    var jb: [16]u8 = undefined;
    try t.expectEqual(@as(usize, 2), (try keys(a, topBlock(c, "on", &buf).?)).len);
    try t.expectEqual(@as(usize, 3), (try keys(a, topBlock(c, "jobs", &jb).?)).len);
    const p = try code(a, r.publish);
    try t.expectEqual(@as(usize, 1), (try keys(a, topBlock(p, "jobs", &jb).?)).len);
    const job = jobText(p, "publish", &buf).?;
    try t.expectEqual(@as(usize, 9), (try steps(a, job)).len);
    var bb: [64]u8 = undefined;
    try t.expectEqualStrings("prod", configValue(r.config, "GITHUB_ENVIRONMENT", &bb).?);
}

test "site.yml: the triggers" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectCaller(a, r, try mutate(a, r.caller, "  workflow_dispatch:\n", "  pull_request:\n  workflow_dispatch:\n"), "pull request");
    try expectCaller(a, r, try mutate(a, r.caller, "  workflow_dispatch:\n", "  push:\n    branches: [main]\n  workflow_dispatch:\n"), "triggers");
    try expectCaller(a, r, try mutate(a, r.caller, "    branches: [main]\n", "    branches: [main, dev]\n"), "branches: [main]");
    try expectCaller(a, r, try mutate(a, r.caller, "    workflows: [release]\n", "    workflows: [ci]\n"), "workflows: [release]");
    try expectCaller(a, r, try mutate(a, r.caller, "        type: boolean\n", "        type: string\n"), "type: boolean");
}

test "site.yml: only a green push to main of this repository, still the tip, with the environment in place, deploys" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    for (call_event_clauses) |c| {
        const with_and = try std.fmt.allocPrint(a, " && {s}", .{c});
        const bad = if (has(r.caller, with_and)) try mutate(a, r.caller, with_and, "") else try mutate(a, r.caller, c, "true");
        try expectCaller(a, r, bad, c);
    }
    try expectCaller(a, r, try mutate(a, r.caller, "github.event_name == 'workflow_dispatch' || (", "false || ("), "manual run");
    try expectCaller(a, r, try mutate(a, r.caller, "if [ \"$tip\" != \"$sha\" ]; then", "if false; then"), "\"$tip\" != \"$sha\"");
    try expectCaller(a, r, try mutate(a, r.caller, "tip=$(gh api \"repos/$GITHUB_REPOSITORY/commits/main\" --jq .sha)", "tip=$sha"), "commits/main");
    try expectCaller(a, r, try mutate(a, r.caller, "environments/prod\" --silent", "environments/dev\" --silent"), "environments/prod");
    try expectCaller(a, r, try mutate(a, r.caller, "if [ \"$REF\" != refs/heads/main ]; then", "if false; then"), "refs/heads/main");
    // a refusal that fails the run instead of saying no deploy
    try expectCaller(a, r, try mutate(a, r.caller, "nothing is deployed\"\n            echo \"deploy=false\" >> \"$GITHUB_OUTPUT\"\n            exit 0", "nothing is deployed\"\n            exit 1"), "deploy=false");
    try expectCaller(a, r, try mutate(a, r.caller, "::notice title=site not published::this run is for", "::error title=site not published::this run is for"), "plan job fails");
    // the build and the publish do not wait for the plan
    try expectCaller(a, r, try mutate(a, r.caller, "needs.plan.outputs.deploy == 'true' && !(github", "true && !(github"), "build job does not wait");
    try expectCaller(a, r, try mutate(a, r.caller, "needs.plan.outputs.deploy == 'true' && (needs.build", "true && (needs.build"), "publish call does not wait");
    try expectCaller(a, r, try mutate(a, r.caller, "needs.build.result == 'success' || ", ""), "green build");
    try expectCaller(a, r, try mutate(a, r.caller, "!cancelled() && ", ""), "!cancelled()");
    try expectCaller(a, r, try mutate(a, r.caller, "!(github.event_name == 'workflow_dispatch' && inputs.claims_only)", "true"), "claims-only");
}

test "site.yml: the token, the call and the actions" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    // the call must be the local path of the file the role trusts, and be the only mention
    try expectCaller(a, r, try mutate(a, r.caller, "    uses: ./.github/workflows/site-publish.yml\n", "    uses: someone/else/.github/workflows/site-publish.yml@refs/heads/main\n"), "is not `uses:");
    try expectCaller(a, r, try mutate(a, r.caller, "    uses: ./.github/workflows/site-publish.yml\n", "    uses: ./.github/workflows/site-publish.yml@refs/heads/dev\n"), "is not `uses:");
    try expectCaller(a, r, try mutate(a, r.caller, "      id-token: write\n    uses:", "      contents: read\n    uses:"), "id-token: write");
    // a token anywhere else
    try expectCaller(a, r, try mutate(a, r.caller, "      contents: read\n      actions: read\n    env:", "      contents: read\n      actions: read\n      id-token: write\n    env:"), "holds the write permission");
    try expectCaller(a, r, try mutate(a, r.caller, "      contents: read\n      actions: read\n    outputs:", "      contents: write\n      actions: read\n    outputs:"), "holds the write permission");
    try expectCaller(a, r, try mutate(a, r.caller, "permissions: {}\n", "permissions: write-all\n"), "write-all");
    try expectCaller(a, r, try mutate(a, r.caller, "permissions: {}\n", "permissions:\n  contents: write\n"), "above the jobs");
    // a third-party action, unpinned actions, secrets and the cloud in the caller
    try expectCaller(a, r, try mutate(a, r.caller, "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9", "aws-actions/configure-aws-credentials@cf430e030ddbb5b0abf93d22962f4752f3646cd9"), "not allowed");
    try expectCaller(a, r, try mutate(a, r.caller, "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9", "actions/upload-artifact@v7"), "not pinned");
    try expectCaller(a, r, try mutate(a, r.caller, "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "actions/checkout@main"), "not pinned");
    try expectCaller(a, r, try mutate(a, r.caller, "      GH_TOKEN: ${{ github.token }}\n      EVENT", "      GH_TOKEN: ${{ secrets.SITE_TOKEN }}\n      EVENT"), "secret");
    try expectCaller(a, r, try mutate(a, r.caller, "run: ./buck2 kill", "run: aws s3 ls"), "touches the cloud");
}

test "site.yml: the build" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectCaller(a, r, try mutate(a, r.caller, "          persist-credentials: false\n", ""), "keeps its credentials");
    try expectCaller(a, r, try mutate(a, r.caller, "ref: ${{ needs.plan.outputs.sha }}", "ref: ${{ github.sha }}"), "ref: ${{ needs.plan.outputs.sha }}");
    try expectCaller(a, r, try mutate(a, r.caller, "./buck2 build --console simple -c buildrules_re.mode=local --show", "./buck2 build --console simple --show"), "does not pass");
    try expectCaller(a, r, try mutate(a, r.caller, "//site:test //site:dist >", "//site:dist >"), "//site:test");
    try expectCaller(a, r, try mutate(a, r.caller, "echo \"1268fce33fb61273091dd5dd8c60b65de1521a3caa36b88983813e882b7ffd89  buck2.zst\"", "echo \"0000  buck2.zst\""), "sha256");
    try expectCaller(a, r, try mutate(a, r.caller, "if-no-files-found: error", "if-no-files-found: ignore"), "if-no-files-found: error");
    // The defect of site.yml run 39617458648: the plain copy of Buck2's relative-symlink output dangles and upload-artifact finds no file.
    try expectCaller(a, r, try mutate(a, r.caller, "cp -rL --no-preserve=mode", "cp -r --no-preserve=mode"), "does not follow symlinks");
    try expectCaller(a, r, try mutate(a, r.caller, "cp -rL --no-preserve=mode", "cp -a --no-preserve=mode"), "does not follow symlinks");
    try expectCaller(a, r, try mutate(a, r.caller, "          test -z \"$(find site-out -type l)\"\n", ""), "find site-out -type l");
    try expectCaller(a, r, try mutate(a, r.caller, "          test -f site-out/tree/index.html\n", ""), "site-out/tree/index.html");
    try expectCaller(a, r, try mutate(a, r.caller, "  group: site\n  cancel-in-progress: false", "  group: site\n  cancel-in-progress: true"), "concurrency");
    try expectCaller(a, r, try mutate(a, r.caller, "      - name: Stop buck2\n        if: always()\n        run: ./buck2 kill", "      - name: Stop buck2\n        if: always()\n        continue-on-error: true\n        run: ./buck2 kill"), "continue-on-error");
    try expectCaller(a, r, try mutate(a, r.caller, "run: ./buck2 kill", "run: echo ${{ github.event.workflow_run.head_branch }}"), "expands `github.event.`");
}

test "site-publish.yml: the trust, the environment and the token" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const p = r.publish;
    try expectPublish(a, r, try mutate(a, p, "    environment: prod\n", "    environment: staging\n"), r.config, "environment: prod");
    try expectPublish(a, r, try mutate(a, p, "    environment: prod\n", ""), r.config, "environment: prod");
    try expectPublish(a, r, try mutate(a, p, "      id-token: write\n", ""), r.config, "permissions are not exactly");
    try expectPublish(a, r, try mutate(a, p, "      contents: read\n      id-token: write\n", "      contents: write\n      id-token: write\n"), r.config, "holds the write permission");
    try expectPublish(a, r, try mutate(a, p, "permissions: {}\n", ""), r.config, "permissions: {}");
    try expectPublish(a, r, try mutate(a, p, "permissions: {}\n", "permissions: {}\n\nconcurrency:\n  group: site\n  cancel-in-progress: false\n"), r.config, "declares a concurrency group");
    try expectPublish(a, r, try mutate(a, p, "  workflow_call:\n", "  workflow_call:\n  push:\n"), r.config, "triggers");
    try expectPublish(a, r, try mutate(a, p, "  workflow_call:\n", "  workflow_call:\n  workflow_dispatch:\n"), r.config, "triggers");
    try expectPublish(a, r, try mutate(a, p, "  workflow_call:\n", "  pull_request:\n  workflow_call:\n"), r.config, "pull request");
    try expectPublish(a, r, try mutate(a, p, "      claims_only:\n        type: boolean", "      claims_only:\n        type: string"), r.config, "claims_only");
    // config.ts is what the role trusts: a file, an environment or a ref that the workflow is not
    try expectPublish(a, r, p, try mutate(a, r.config, "'.github/workflows/site-publish.yml'", "'.github/workflows/site.yml'"), "trusts the workflow");
    try expectPublish(a, r, p, try mutate(a, r.config, "GITHUB_ENVIRONMENT = 'prod'", "GITHUB_ENVIRONMENT = 'live'"), "trusts the environment");
    try expectPublish(a, r, p, try mutate(a, r.config, "WORKFLOW_REF = 'refs/heads/main'", "WORKFLOW_REF = 'refs/heads/dev'"), "trusts the ref");
    try expectPublish(a, r, p, try mutate(a, r.config, "OIDC_AUDIENCE = 'sts.amazonaws.com'", "OIDC_AUDIENCE = 'sts.example.com'"), "audience");
}

test "site-publish.yml: no third-party action, no checkout, no secret, no trace" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const p = r.publish;
    const sha = "9000827ccba6bdab643e8b6fd33ac0654aef8333";
    try expectPublish(a, r, try mutate(a, p, "actions/download-artifact@" ++ sha, "aws-actions/configure-aws-credentials@" ++ sha), r.config, "not allowed");
    try expectPublish(a, r, try mutate(a, p, "actions/download-artifact@" ++ sha, "actions/download-artifact@v8"), r.config, "not pinned");
    try expectPublish(a, r, try mutate(a, p, "    steps:\n", "    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n"), r.config, "not allowed");
    try expectPublish(a, r, try mutate(a, p, "      AWS_DEFAULT_REGION: us-east-1\n", "      AWS_DEFAULT_REGION: us-east-1\n      TOKEN: ${{ secrets.AWS_TOKEN }}\n"), r.config, "secret");
    try expectPublish(a, r, try mutate(a, p, "          echo \"::add-mask::$jwt\"\n          creds=", "          echo \"::add-mask::$jwt\"\n          echo \"$jwt\"\n          creds="), r.config, "prints the token");
    try expectPublish(a, r, try mutate(a, p, "set -euo pipefail\n          resp=", "set -x\n          resp="), r.config, "traces");
    try expectPublish(a, r, try mutate(a, p, "set -euo pipefail\n          resp=", "set -euxo pipefail\n          resp="), r.config, "traces");
    try expectPublish(a, r, try mutate(a, p, "      - name: Flush the edge", "      - run: ./buck2 build //site:dist\n      - name: Flush the edge"), r.config, "buck2");
    try expectPublish(a, r, try mutate(a, p, "run: aws cloudfront", "continue-on-error: true\n        run: aws cloudfront"), r.config, "continue-on-error");
    try expectPublish(a, r, try mutate(a, p, "          if [ -d site-out/release/releases ]; then\n            aws s3 sync", "          echo ${{ vars.BUILDRULES_SITE_BUCKET }}\n          if [ -d site-out/release/releases ]; then\n            aws s3 sync"), r.config, "expands `vars.`");
}

test "site-publish.yml: with the setup not done the job ends green and does nothing" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const p = r.publish;
    // the skip answer, and green
    try expectPublish(a, r, try mutate(a, p, "echo \"mode=skip\" >> \"$GITHUB_OUTPUT\"\n            exit 0", "echo \"mode=skip\" >> \"$GITHUB_OUTPUT\"\n            exit 1"), r.config, "end green");
    try expectPublish(a, r, try mutate(a, p, "echo \"mode=skip\" >> \"$GITHUB_OUTPUT\"\n            exit 0", "exit 1"), r.config, "end green");
    try expectPublish(a, r, try mutate(a, p, "::notice title=site not published::the environment", "::error title=site not published::the environment"), r.config, "notice");
    try expectPublish(a, r, try mutate(a, p, "echo \"mode=skip\"", "echo \"mode=publish\""), r.config, "end green");
    // each of the three variables is tested for emptiness
    for (var_env) |v| {
        const probe = try std.fmt.allocPrint(a, "[ -n \"${s}\" ] || missing=\"$missing {s}\"", .{ v[0], v[1] });
        const needle = try std.fmt.allocPrint(a, "test `{s}` for emptiness", .{v[0]});
        try expectPublish(a, r, try mutate(a, p, probe, "true"), r.config, needle);
    }
    try expectPublish(a, r, try mutate(a, p, "if [ -n \"$missing\" ]; then", "if false; then"), r.config, "act on a missing value");
    // every later step is gated on the answer of the vars step; one that is not runs when the setup was not done
    const gated = [_][2][]const u8{
        .{ "The claims of the token", claims_gate },
        .{ "Assume the publish role through OIDC", publish_gate },
        .{ "The hashed stylesheet, first and immutable (a page still cached by a browser keeps its css)", publish_gate },
        .{ "The pages and the unhashed files, pruned", publish_gate },
        .{ "The page of the release, never pruned", publish_gate },
        .{ "Flush the edge", publish_gate },
        .{ "Smoke test", publish_gate },
    };
    for (gated) |g| {
        const from = try std.fmt.allocPrint(a, "      - name: {s}\n        {s}\n", .{ g[0], g[1] });
        const to = try std.fmt.allocPrint(a, "      - name: {s}\n", .{g[0]});
        try expectPublish(a, r, try mutate(a, p, from, to), r.config, "not gated");
    }
    // the download is gated too
    try expectPublish(a, r, try mutate(a, p, "      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2\n        if: ${{ steps.vars.outputs.mode == 'publish' }}\n", "      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2\n"), r.config, "not gated");
    // a step that runs in the wrong mode
    try expectPublish(a, r, try mutate(a, p, "        if: ${{ steps.vars.outputs.mode == 'claims' }}", "        if: ${{ steps.vars.outputs.mode == 'publish' }}"), r.config, "claims step runs outside");
    try expectPublish(a, r, try mutate(a, p, "      - name: Flush the edge\n        if: ${{ steps.vars.outputs.mode == 'publish' }}", "      - name: Flush the edge\n        if: ${{ steps.vars.outputs.mode == 'claims' }}"), r.config, "outside mode");
    try expectPublish(a, r, try mutate(a, p, "      - name: Smoke test\n        if: ${{ steps.vars.outputs.mode == 'publish' }}", "      - name: Smoke test\n        if: ${{ always() }}"), r.config, "not gated");
}

test "site-publish.yml: the values are masked and the claims step prints the claims, never the token" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const p = r.publish;
    try expectPublish(a, r, try mutate(a, p, "          echo \"::add-mask::$SITE_BUCKET\"\n", ""), r.config, "SITE_BUCKET` is not masked");
    try expectPublish(a, r, try mutate(a, p, "          echo \"::add-mask::$SITE_DISTRIBUTION_ID\"\n", ""), r.config, "SITE_DISTRIBUTION_ID` is not masked");
    try expectPublish(a, r, try mutate(a, p, "          echo \"::add-mask::$SITE_ROLE_ARN\"\n", ""), r.config, "SITE_ROLE_ARN` is not masked");
    // masked, but only after the answer that lets the later steps use them
    try expectPublish(a, r, try mutate(a, p, "          echo \"::add-mask::$SITE_ROLE_ARN\"\n          echo \"mode=publish\" >> \"$GITHUB_OUTPUT\"\n", "          echo \"mode=publish\" >> \"$GITHUB_OUTPUT\"\n          echo \"::add-mask::$SITE_ROLE_ARN\"\n"), r.config, "SITE_ROLE_ARN` is not masked");
    try expectPublish(a, r, try mutate(a, p, "          echo \"::add-mask::$jwt\"\n          payload=", "          payload="), r.config, "token is not masked");
    try expectPublish(a, r, try mutate(a, p, "          echo \"::add-mask::$jwt\"\n          creds=", "          creds="), r.config, "token is not masked");
    try expectPublish(a, r, try mutate(a, p, claims_filter, "cat"), r.config, "claims step");
    try expectPublish(a, r, try mutate(a, p, claims_filter, "jq ."), r.config, "claims step");
    try expectPublish(a, r, try mutate(a, p, "&audience=sts.amazonaws.com\")\n          jwt=$(printf '%s' \"$resp\" | jq -r .value)\n          echo \"::add-mask::$jwt\"\n          payload=", "&audience=sts.example.com\")\n          jwt=$(printf '%s' \"$resp\" | jq -r .value)\n          echo \"::add-mask::$jwt\"\n          payload="), r.config, "audience");
    try expectPublish(a, r, try mutate(a, p, "--duration-seconds 3600", "--duration-seconds 43200"), r.config, "--duration-seconds 3600");
    try expectPublish(a, r, try mutate(a, p, "--role-arn \"$SITE_ROLE_ARN\"", "--role-arn \"arn:aws:iam::123456789012:role/other\""), r.config, "--role-arn");
    try expectPublish(a, r, try mutate(a, p, "      SITE_ROLE_ARN: ${{ vars.BUILDRULES_SITE_PUBLISH_ROLE_ARN }}", "      SITE_ROLE_ARN: ${{ vars.ROLE }}"), r.config, "BUILDRULES_SITE_PUBLISH_ROLE_ARN");
    try expectPublish(a, r, try mutate(a, p, "      SITE_BUCKET: ${{ vars.BUILDRULES_SITE_BUCKET }}\n", "      SITE_BUCKET: ${{ vars.BUILDRULES_SITE_BUCKET }}\n      EXTRA: ${{ vars.OTHER }}\n"), r.config, "besides the three");
}

test "site-publish.yml: the uploads" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const p = r.publish;
    // the hashed stylesheet is immutable and first; the pages command alone prunes and spares the hashed stylesheets and the release pages
    try expectPublish(a, r, try mutate(a, p, "max-age=31536000, immutable", "max-age=60"), r.config, "site-out/tree/assets");
    try expectPublish(a, r, try mutate(a, p, "--exclude 'icon.svg' ", "--delete "), r.config, "--delete");
    try expectPublish(a, r, try mutate(a, p, " --exclude 'releases/*' --cache-control", " --cache-control"), r.config, "aws s3 sync site-out/tree \"s3");
    try expectPublish(a, r, try mutate(a, p, " --exclude 'assets/site.*.css'", ""), r.config, "aws s3 sync site-out/tree \"s3");
    try expectPublish(a, r, try mutate(a, p, " --delete --exclude 'assets/site", " --exclude 'assets/site"), r.config, "aws s3 sync site-out/tree \"s3");
    try expectPublish(a, r, try mutate(a, p, "--no-progress --cache-control 'public, max-age=60, s-maxage=300'\n          else", "--no-progress --delete --cache-control 'public, max-age=60, s-maxage=300'\n          else"), r.config, "--delete");
    try expectPublish(a, r, try mutate(a, p, "--paths '/*'", "--paths '/index.html'"), r.config, "create-invalidation");
    try expectPublish(a, r, try mutate(a, p, "--distribution-id \"$SITE_DISTRIBUTION_ID\"", "--distribution-id \"$SITE_BUCKET\""), r.config, "create-invalidation");
    try expectPublish(a, r, try mutate(a, p, "run: aws cloudfront create-invalidation", "run: aws s3 rm \"s3://$SITE_BUCKET/\" --recursive\n      - name: Again\n        if: ${{ steps.vars.outputs.mode == 'publish' }}\n        run: aws cloudfront create-invalidation"), r.config, "s3 rm");
    try expectPublish(a, r, try mutate(a, p, "\"s3://$SITE_BUCKET/assets\" --no-progress", "\"s3://$SITE_BUCKET/assets\" --acl public-read --no-progress"), r.config, "--acl");
    // the order: stylesheet, pages, release pages, invalidation
    const swapped = try mutate(a, try mutate(a, p, assets_cmd, "@@A@@"), pages_cmd, assets_cmd);
    try expectPublish(a, r, try mutate(a, swapped, "@@A@@", pages_cmd), r.config, "out of order");
    // the smoke test
    try expectPublish(a, r, try mutate(a, p, "          want \"$SITE_URL/no-such-page-$GITHUB_RUN_ID/\" 404 site-out/tree/404.html\n", ""), r.config, "404");
    try expectPublish(a, r, try mutate(a, p, "          curl -sI \"$SITE_URL/\" | grep -i '^content-security-policy: default-src' > /dev/null\n", ""), r.config, "content-security-policy");
    try expectPublish(a, r, try mutate(a, p, "cmp -s \"$RUNNER_TEMP/body\" \"$3\"", "true"), r.config, "cmp -s");
    try expectPublish(a, r, try mutate(a, p, "              sleep 15\n", "              break\n"), r.config, "sleep 15");
}
