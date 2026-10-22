//! The publish-unpack workflow (.github/workflows/publish-unpack.yml) is what its header says it is: the dispatch job that publishes the release of the `unpack` programs
//! with the release bot's token, because the tag ruleset lets nobody else create the tag. A pure function of the text, so each rule is tested against edited copies of the text as well as
//! against the real files (the zig_test's `data`, under BUILDRULES_TEST_WORK). The rules shared with the other workflows (actions pinned by commit, no `continue-on-error`,
//! no inline expansion of `vars.` or `github.event.` in a `run:`, the pinned buck2) are workflow_check.zig's; the job parser is release_check.zig's.
//!
//! What the rules catch:
//!  - a trigger that is not a person's: the triggers are exactly `workflow_dispatch` (no push, pull request, schedule, workflow_run or call), with one boolean input `apply`
//!    whose default is false;
//!  - a run from another branch: the one job is `if: github.ref == 'refs/heads/main'` and declares `environment: release`, where the bot's key lives;
//!  - a token with more than it needs: the top level and the job grant `contents: read` alone, and the only `write` in the file is the bot token's
//!    `permission-contents: write`;
//!  - the bot's token anywhere but the apply: the mint step is the one release.yml's `tag` job uses (the same action, variables, secret, owner, repository and scope,
//!    compared with that file's text), it runs `if: inputs.apply` and is immediately followed by the one step that runs `--apply`, which is also `if: inputs.apply` and is
//!    the only step that reads the token; the build and the dry run come before the mint and are not conditional;
//!  - a write that replaces or removes: no `--force`, `--clobber`, `gh` command or release edit/delete in the workflow (the tool alone talks to `gh`);
//!  - a release of something other than the commit the programs are built from: the install of the pinned buck2 removes its download (an untracked file makes
//!    publish_unpack refuse --apply), and the three commands (build, dry run, apply) are exactly the ones this file expects, in local mode.
const std = @import("std");
const wc = @import("workflow_check.zig");
const rc = @import("release_check.zig");
const t = std.testing;

const Findings = wc.Findings;
const add = wc.add;

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

const file = "publish-unpack.yml";

const guard = "github.ref == 'refs/heads/main'";
const apply_if = "if: inputs.apply";
const tool = "\"$RUNNER_TEMP/publish_unpack\"";
const common = " --root \"$GITHUB_WORKSPACE\" --buck2 \"$GITHUB_WORKSPACE/buck2\" --buck2-config buildrules_re.mode=local";
const dry_cmd = tool ++ common;
const apply_cmd = tool ++ " --apply --work \"$RUNNER_TEMP/unpack-work\"" ++ common;
const build_cmd = "./buck2 build --console simple -c buildrules_re.mode=local --out \"$RUNNER_TEMP/publish_unpack\" //tools/held:publish_unpack";
const mode_flag = "buildrules_re.mode=local";

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

/// The steps of the first `steps:` block (job level, four spaces), each as the text from its `      - ` line to the next one's.
fn steps(a: std.mem.Allocator, wf: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    const open = "\n    steps:\n";
    const at = std.mem.indexOf(u8, wf, open) orelse return try out.toOwnedSlice();
    const rest = wf[at + open.len ..];
    var start: ?usize = null;
    var pos: usize = 0;
    var it = std.mem.splitScalar(u8, rest, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "      - ")) {
            if (start) |s| try out.append(rest[s..pos]);
            start = pos;
        }
        pos += line.len + 1;
    }
    if (start) |s| try out.append(rest[s..@min(pos, rest.len)]);
    return try out.toOwnedSlice();
}

/// The `uses:` line of the first `create-github-app-token` step and the lines under it that are indented as its keys (`with:` and its entries): the text the step
/// is compared on, in this file and in release.yml.
fn mintBlock(a: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const marker = "        uses: actions/create-github-app-token@";
    const s = std.mem.indexOf(u8, text, marker) orelse return null;
    var out = std.ArrayList(u8).init(a);
    var it = std.mem.splitScalar(u8, text[s..], '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "        ")) break;
        try out.appendSlice(line);
        try out.append('\n');
    }
    return try out.toOwnedSlice();
}

/// `GH_TOKEN` followed by an optional quote, optional blanks and a colon: a plain, a double-quoted and a single-quoted key (also in a flow map).
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

/// Everything wrong with `raw`, given release.yml (the mint step is read from it) and the dotslash file of the pinned buck2.
pub fn check(a: std.mem.Allocator, raw: []const u8, release_raw: []const u8, dotslash: []const u8) !Findings {
    var f = Findings.init(a);
    const wf = try rc.body(a, raw);
    const release = try rc.body(a, release_raw);

    try wc.noContinueOnError(a, &f, wf);
    try wc.noInlineContext(a, &f, wf);
    const uses = try wc.pinnedUses(a, &f, wf, &.{});
    if (uses != 2) try add(a, &f, "{s}: {d} `uses:` lines (exactly two: the checkout and the mint step)", .{ file, uses });
    var uit = std.mem.splitScalar(u8, wf, '\n');
    while (uit.next()) |line| {
        if (rc.usesRepo(line)) |repo| {
            if (!std.mem.startsWith(u8, repo, "actions/")) try add(a, &f, "{s}: the action `{s}` is not allowed (only GitHub's own `actions/` actions run here)", .{ file, repo });
        }
    }

    // Triggers: a person, by hand.
    const trig = try rc.triggers(a, wf);
    if (trig.len != 1 or !std.mem.eql(u8, trig[0], "workflow_dispatch")) try add(a, &f, "{s}: the triggers are not exactly `workflow_dispatch` (got {d}): this workflow must never run on a push, a pull request or a schedule", .{ file, trig.len });
    for ([_][]const u8{ "pull_request", "schedule", "workflow_run", "workflow_call", "repository_dispatch" }) |word| {
        if (has(wf, word)) try add(a, &f, "{s}: the trigger word `{s}` is present", .{ file, word });
    }
    if (!wc.hasLine(wf, "      apply:") or !wc.hasLine(wf, "        type: boolean") or !wc.hasLine(wf, "        default: false"))
        try add(a, &f, "{s}: the input `apply` is not a boolean with the default `false` (a dispatch without it must be a dry run)", .{file});
    if (count(wf, "default:") != 1 or count(wf, "type:") != 1) try add(a, &f, "{s}: more than one input (the only input is `apply`)", .{file});

    // Permissions: read everywhere; the one write is the bot token's scope.
    const top = try topLines(a, wf, "permissions:");
    if (top == null or top.?.len != 1 or !std.mem.eql(u8, top.?[0], "contents: read")) try add(a, &f, "{s}: the top-level permissions are not exactly `contents: read`", .{file});
    if (has(wf, "write-all")) try add(a, &f, "{s}: `write-all` is granted", .{file});
    var wit = std.mem.splitScalar(u8, wf, '\n');
    var writes: usize = 0;
    while (wit.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (has(line, ": write")) {
            writes += 1;
            if (!std.mem.eql(u8, line, "permission-contents: write")) try add(a, &f, "{s}: the write permission `{s}` (the only write is the bot token's `permission-contents: write`)", .{ file, line });
        }
    }
    if (writes != 1) try add(a, &f, "{s}: {d} write permissions (exactly one: the bot token's `permission-contents: write`)", .{ file, writes });

    // The job: from main only, in the environment that holds the key.
    const jobs = try rc.parseJobs(a, wf);
    if (jobs.len != 1) try add(a, &f, "{s}: the workflow has {d} jobs, not exactly one", .{ file, jobs.len });
    if (rc.jobNamed(jobs, "publish")) |j| {
        if (j.if_expr == null or !std.mem.eql(u8, j.if_expr.?, guard)) try add(a, &f, "{s}: the job `publish` is not guarded by exactly `if: {s}`", .{ file, guard });
        if (j.environment == null or !std.mem.eql(u8, j.environment.?, "release")) try add(a, &f, "{s}: the job `publish` does not declare `environment: release` (where the bot's key lives)", .{file});
        if (!j.has_perms or j.perms.items.len != 1 or !std.mem.eql(u8, rc.permLevel(j, "contents") orelse "", "read")) try add(a, &f, "{s}: the job `publish` permissions are not exactly `contents: read`", .{file});
    } else try add(a, &f, "{s}: no job `publish`", .{file});
    if (count(wf, "environment:") != 1) try add(a, &f, "{s}: `environment:` is not declared exactly once", .{file});

    // The key and the app: read by the mint step alone.
    if (count(wf, "secrets.") != 1 or count(wf, "secrets.RELEASE_BOT_PRIVATE_KEY }}") != 1) try add(a, &f, "{s}: the workflow reads a secret other than `secrets.RELEASE_BOT_PRIVATE_KEY`, or reads it other than once", .{file});
    if (count(wf, "vars.") != 1 or count(wf, "vars.RELEASE_BOT_APP_ID }}") != 1) try add(a, &f, "{s}: the workflow reads a variable other than `vars.RELEASE_BOT_APP_ID`, or reads it other than once", .{file});
    if (has(wf, "secrets: inherit") or has(wf, "toJSON(secrets") or has(wf, "toJson(secrets")) try add(a, &f, "{s}: the secrets are passed on as a whole", .{file});

    const sts = try steps(a, wf);
    if (sts.len == 0) try add(a, &f, "{s}: no steps found (this parser is blind)", .{file});
    var mint_at: ?usize = null;
    var apply_at: ?usize = null;
    var dry_at: ?usize = null;
    var build_at: ?usize = null;
    var mints: usize = 0;
    var applies: usize = 0;
    for (sts, 0..) |s, i| {
        if (has(s, "create-github-app-token")) {
            mints += 1;
            mint_at = i;
        }
        if (has(s, "--apply")) {
            applies += 1;
            apply_at = i;
        }
        if (has(s, dry_cmd) and !has(s, "--apply")) dry_at = i;
        if (has(s, "//tools/held:publish_unpack")) build_at = i;
    }
    if (mints != 1) try add(a, &f, "{s}: {d} steps mint a token (exactly one)", .{ file, mints });
    if (applies != 1 or count(wf, "--apply") != 1) try add(a, &f, "{s}: `--apply` is in {d} steps and {d} places (exactly one step, one place)", .{ file, applies, count(wf, "--apply") });
    if (mint_at) |m| {
        const s = sts[m];
        if (!has(s, "\n        id: bot\n")) try add(a, &f, "{s}: the mint step is not `id: bot`", .{file});
        if (!has(s, "\n        " ++ apply_if ++ "\n")) try add(a, &f, "{s}: the mint step is not `{s}` (the token is minted only for an apply)", .{ file, apply_if });
        const mine = try mintBlock(a, s);
        const theirs = try mintBlock(a, release);
        if (theirs == null) {
            try add(a, &f, "release.yml has no `create-github-app-token` step (this parser is blind)", .{});
        } else if (mine == null or !std.mem.eql(u8, mine.?, theirs.?)) {
            try add(a, &f, "{s}: the mint step differs from release.yml's `tag` job (the same action, app, key, owner, repository and `permission-contents: write`, nothing more)", .{file});
        }
        if (!has(s, "repositories: buildrules\n")) try add(a, &f, "{s}: the token is not restricted to `repositories: buildrules`", .{file});
        if (apply_at == null or apply_at.? != m + 1) try add(a, &f, "{s}: the apply step does not immediately follow the mint step (no other step may hold the token)", .{file});
    }
    if (apply_at) |p| {
        const s = sts[p];
        if (!has(s, "\n        " ++ apply_if ++ "\n")) try add(a, &f, "{s}: the apply step is not `{s}`", .{ file, apply_if });
        if (!has(s, "\n          GH_TOKEN: ${{ steps.bot.outputs.token }}\n")) try add(a, &f, "{s}: the apply step does not run with `GH_TOKEN: ${{{{ steps.bot.outputs.token }}}}` as a step env", .{file});
        if (!has(s, "\n          " ++ apply_cmd ++ "\n")) try add(a, &f, "{s}: the apply command is not exactly `{s}`", .{ file, apply_cmd });
    }
    if (dry_at) |d| {
        const s = sts[d];
        if (!has(s, "\n          GH_TOKEN: ${{ github.token }}\n")) try add(a, &f, "{s}: the dry run does not run with the job's own `GH_TOKEN: ${{{{ github.token }}}}`", .{file});
        if (has(s, "\n        if:")) try add(a, &f, "{s}: the dry run is conditional", .{file});
        if (mint_at != null and d >= mint_at.?) try add(a, &f, "{s}: the dry run does not come before the mint step", .{file});
    } else try add(a, &f, "{s}: no dry run step with the command `{s}`", .{ file, dry_cmd });
    if (build_at) |b| {
        if (!has(sts[b], "\n        run: " ++ build_cmd ++ "\n")) try add(a, &f, "{s}: the build of the tool is not exactly `{s}`", .{ file, build_cmd });
        if (dry_at != null and b >= dry_at.?) try add(a, &f, "{s}: the build of the tool does not come before the dry run", .{file});
    } else try add(a, &f, "{s}: no step builds //tools/held:publish_unpack", .{file});

    // The token is the bot's on the apply step alone and the job's own on the dry run alone; nowhere else, and not at job or workflow level.
    if (ghTokenKeys(wf) != 2) try add(a, &f, "{s}: `GH_TOKEN:` is set {d} times, in any spelling (exactly twice: the dry run's `github.token` and the apply step's bot token)", .{ file, ghTokenKeys(wf) });
    if (count(wf, "steps.bot.outputs.token") != 1) try add(a, &f, "{s}: the bot token is read {d} times (exactly once, by the apply step)", .{ file, count(wf, "steps.bot.outputs.token") });
    if (count(wf, "github.token") != 1) try add(a, &f, "{s}: `github.token` is read {d} times (exactly once, by the dry run)", .{ file, count(wf, "github.token") });
    var lit = std.mem.splitScalar(u8, wf, '\n');
    while (lit.next()) |line| {
        if (has(line, "GH_TOKEN") and has(line, ":") and !std.mem.startsWith(u8, line, "          GH_TOKEN: "))
            try add(a, &f, "{s}: `{s}`: GH_TOKEN is set other than as a step env (ten spaces)", .{ file, std.mem.trim(u8, line, " ") });
    }
    if (count(wf, "\nenv:") != 0 or count(wf, "\n    env:") != 0) try add(a, &f, "{s}: `env:` at workflow or job level (every step but one would hold what it sets)", .{file});

    // Nothing but the apply and the mint can be switched off: a skipped dry run or build is a release of programs nobody checked.
    var ifs: usize = 0;
    var iflines = std.mem.splitScalar(u8, wf, '\n');
    while (iflines.next()) |raw_line| {
        const line = std.mem.trimLeft(u8, std.mem.trim(u8, raw_line, " \r"), "- ");
        if (std.mem.startsWith(u8, line, "if:")) {
            ifs += 1;
            if (!std.mem.eql(u8, line, apply_if) and !std.mem.eql(u8, line, "if: " ++ guard)) try add(a, &f, "{s}: `{s}`: the only conditions are the main guard and `{s}`", .{ file, line, apply_if });
        }
    }
    if (ifs != 3) try add(a, &f, "{s}: {d} `if:` lines (exactly three: the job's main guard, the mint step and the apply step)", .{ file, ifs });

    // No replacing, no deleting, no second tool talking to GitHub.
    for ([_][]const u8{ "--force", "--clobber", "release delete", "release edit", "release upload", "release create", "--no-remote-cache", "-f apply", "git push", "git tag" }) |bad| {
        if (has(wf, bad)) try add(a, &f, "{s}: the workflow mentions `{s}` (publish_unpack never replaces or deletes, and is the only thing that writes)", .{ file, bad });
    }
    // A one-line `run: cmd` is the command `cmd`.
    const lines_cmds = try wc.commands(a, wf);
    const cmds = try a.alloc([]const u8, lines_cmds.len);
    for (lines_cmds, 0..) |c0, i| {
        var c = c0;
        if (std.mem.startsWith(u8, c, "- ")) c = c[2..];
        if (std.mem.startsWith(u8, c, "run: ")) c = c["run: ".len..];
        cmds[i] = c;
    }
    var tools: usize = 0;
    for (cmds) |c| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, c, from, "gh ")) |i| : (from = i + 1) {
            if (i == 0 or has(" (;\"|&", c[i - 1 .. i])) {
                try add(a, &f, "{s}: `{s}`: a `gh` command (only publish_unpack talks to GitHub)", .{ file, c });
                break;
            }
        }
        if (std.mem.startsWith(u8, c, tool)) {
            tools += 1;
            if (!std.mem.eql(u8, c, dry_cmd) and !std.mem.eql(u8, c, apply_cmd)) try add(a, &f, "{s}: `{s}` is neither the dry run nor the apply command this check expects", .{ file, c });
        }
    }
    if (tools != 2) try add(a, &f, "{s}: publish_unpack runs {d} times (exactly twice: the dry run, the apply)", .{ file, tools });

    // Local mode on a hosted runner: every command that loads the graph says so, nothing names a farm.
    if (count(wf, "buildrules_re.mode") != count(wf, "buildrules_re.mode=local")) try add(a, &f, "{s}: `buildrules_re.mode` is set to something other than `local`", .{file});
    var graph_cmds: usize = 0;
    for (cmds) |c| {
        if (std.mem.startsWith(u8, c, "./buck2 ") and !std.mem.startsWith(u8, c, "./buck2 kill") and !std.mem.startsWith(u8, c, "./buck2 --version")) {
            graph_cmds += 1;
            if (!has(c, " -c " ++ mode_flag ++ " ")) try add(a, &f, "{s}: a `./buck2` command that loads the graph does not pass `-c {s}`: {s}", .{ file, mode_flag, c });
        }
    }
    if (graph_cmds != 1) try add(a, &f, "{s}: {d} `./buck2` commands that load the graph (exactly one, the build of the tool)", .{ file, graph_cmds });
    for ([_][]const u8{ "engine_address", "cas_address", "action_cache_address", "linux_x86_64_properties" }) |bad| {
        if (has(wf, bad)) try add(a, &f, "{s}: the workflow mentions `{s}`", .{ file, bad });
    }

    // The pinned buck2, and an untracked file left behind would make the apply refuse (or, worse, a release of a tree that is not the commit).
    try wc.buck2Install(a, &f, wf, dotslash);
    var checked: ?usize = null;
    var removed: ?usize = null;
    var first_tool: ?usize = null;
    for (cmds, 0..) |c, i| {
        if (has(c, "sha256sum --check --strict -")) checked = i;
        if (std.mem.eql(u8, c, "rm buck2.zst")) removed = i;
        if (first_tool == null and has(c, "publish_unpack")) first_tool = i;
    }
    if (checked == null) try add(a, &f, "{s}: the download of buck2 is not checked with `sha256sum --check --strict -` (the sha256 of tools/buck2, before it runs)", .{file});
    if (removed == null) {
        try add(a, &f, "{s}: `rm buck2.zst` is missing (an untracked download makes the tree differ from the commit)", .{file});
    } else if (checked == null or removed.? < checked.? or (first_tool != null and removed.? > first_tool.?)) {
        try add(a, &f, "{s}: `rm buck2.zst` is not after the sha256 check and before the build of the tool", .{file});
    }
    return f;
}

// ---- tests -----------------------------------------------------------------------------------------------------------------------------

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

const Real = struct { wf: []const u8, release: []const u8, ds: []const u8 };

fn real(a: std.mem.Allocator) !Real {
    return .{ .wf = try work(a, ".github/workflows/publish-unpack.yml"), .release = try work(a, ".github/workflows/release.yml"), .ds = try work(a, "tools/buck2") };
}

/// `text` with the first `from` replaced by `to`; fails the test if `from` is absent (an edit that changes nothing proves nothing).
fn edited(a: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const i = std.mem.indexOf(u8, text, from) orelse return error.TextNotFound;
    return std.mem.concat(a, u8, &.{ text[0..i], to, text[i + from.len ..] });
}

fn expectFinding(a: std.mem.Allocator, wf: []const u8, r: Real, needle: []const u8) !void {
    const f = try check(a, wf, r.release, r.ds);
    for (f.items) |m| {
        if (has(m, needle)) return;
    }
    std.debug.print("publish-unpack.yml: expected a finding with `{s}`, got {d}:\n", .{ needle, f.items.len });
    for (f.items) |m| std.debug.print("  {s}\n", .{m});
    return error.NotRefused;
}

fn expectRefused(a: std.mem.Allocator, r: Real, from: []const u8, to: []const u8, needle: []const u8) !void {
    try expectFinding(a, try edited(a, r.wf, from, to), r, needle);
}

test "the real workflow has no findings" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const f = try check(a, r.wf, r.release, r.ds);
    for (f.items) |m| std.debug.print("publish-unpack.yml finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "the parsers are not blind: the real file has the trigger, the job, the six steps and the mint step the rules read" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const wf = try rc.body(a, r.wf);
    try t.expectEqual(@as(usize, 1), (try rc.triggers(a, wf)).len);
    const jobs = try rc.parseJobs(a, wf);
    try t.expectEqual(@as(usize, 1), jobs.len);
    try t.expectEqualStrings("release", jobs[0].environment.?);
    try t.expectEqual(@as(usize, 1), (try topLines(a, wf, "permissions:")).?.len);
    try t.expect((try topLines(a, wf, "nothing:")) == null);
    try t.expectEqual(@as(usize, 6), (try steps(a, wf)).len);
    try t.expectEqual(@as(usize, 0), (try steps(a, "name: x\n")).len);
    const mine = (try mintBlock(a, wf)).?;
    try t.expect(has(mine, "permission-contents: write\n"));
    try t.expect((try mintBlock(a, "nothing\n")) == null);
    try t.expectEqual(@as(usize, 2), ghTokenKeys(wf));
}

test "the mint step is the one release.yml's tag job has, and the key is read where release.yml says" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const mine = (try mintBlock(a, try rc.body(a, r.wf))).?;
    const theirs = (try mintBlock(a, try rc.body(a, r.release))).?;
    try t.expectEqualStrings(theirs, mine);
    // release.yml's first mint step is the `tag` job's: it is in the environment `release` and reads the same two names
    const jobs = try rc.parseJobs(a, try rc.body(a, r.release));
    try t.expectEqualStrings("release", rc.jobNamed(jobs, "tag").?.environment.?);
    try t.expect(has(try (rc.jobNamed(jobs, "tag").?.text(a)), "secrets.RELEASE_BOT_PRIVATE_KEY"));
    // the check reads the real file's mint step, so a release.yml that changes it fails this one until both agree
    try expectFinding(a, r.wf, .{ .wf = r.wf, .release = try edited(a, r.release, "permission-contents: write", "permission-contents: write\n          permission-pull-requests: write"), .ds = r.ds }, "differs from release.yml");
}

test "rule:a trigger a change or a clock can start" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectRefused(a, r, "on:\n  workflow_dispatch:", "on:\n  push:\n  workflow_dispatch:", "triggers are not exactly");
    try expectRefused(a, r, "on:\n  workflow_dispatch:", "on:\n  pull_request:\n  workflow_dispatch:", "triggers are not exactly");
    try expectRefused(a, r, "on:\n  workflow_dispatch:", "on:\n  pull_request:\n  workflow_dispatch:", "`pull_request` is present");
    try expectRefused(a, r, "on:\n  workflow_dispatch:", "on:\n  schedule:\n    - cron: \"0 0 * * *\"\n  workflow_dispatch:", "triggers are not exactly");
    try expectRefused(a, r, "on:\n  workflow_dispatch:", "on:\n  workflow_run:\n    workflows: [ci]\n  workflow_dispatch:", "triggers are not exactly");
    try expectRefused(a, r, "on:\n  workflow_dispatch:", "on:\n  workflow_call:\n  workflow_dispatch:", "triggers are not exactly");
    try expectRefused(a, r, "on:\n  workflow_dispatch:", "on:\n  repository_dispatch:\n  workflow_dispatch:", "triggers are not exactly");
    try expectRefused(a, r, "on:\n  workflow_dispatch:", "on:\n  push:\n    branches: [main]\n  workflow_dispatch:", "triggers are not exactly");
    try expectRefused(a, r, "        default: false\n", "        default: true\n", "default `false`");
    try expectRefused(a, r, "        default: false\n", "", "default `false`");
    try expectRefused(a, r, "        type: boolean\n", "        type: string\n", "default `false`");
    try expectRefused(a, r, "        default: false\n", "        default: false\n      other:\n        type: boolean\n        default: false\n", "more than one input");
}

test "rule:a run from any branch" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectRefused(a, r, "    if: github.ref == 'refs/heads/main'\n", "", "is not guarded by exactly");
    try expectRefused(a, r, "github.ref == 'refs/heads/main'", "github.ref != 'refs/heads/main'", "is not guarded by exactly");
    try expectRefused(a, r, "github.ref == 'refs/heads/main'", "github.ref == 'refs/heads/main' || true", "is not guarded by exactly");
    try expectRefused(a, r, "github.ref == 'refs/heads/main'", "startsWith(github.ref, 'refs/heads/')", "is not guarded by exactly");
    try expectRefused(a, r, "    environment: release\n", "", "does not declare `environment: release`");
    try expectRefused(a, r, "    environment: release\n", "    environment: gamma\n", "does not declare `environment: release`");
    try expectRefused(a, r, "  publish:\n", "  other:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n  publish:\n", "not exactly one");
}

test "rule:a token with more than it needs" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectRefused(a, r, "permissions:\n  contents: read\n\nconcurrency", "permissions:\n  contents: write\n\nconcurrency", "top-level permissions are not exactly");
    try expectRefused(a, r, "permissions:\n  contents: read\n\nconcurrency", "permissions: write-all\n\nconcurrency", "`write-all`");
    try expectRefused(a, r, "permissions:\n  contents: read\n\nconcurrency", "concurrency", "top-level permissions are not exactly");
    try expectRefused(a, r, "    permissions:\n      contents: read\n", "    permissions:\n      contents: write\n", "job `publish` permissions are not exactly");
    try expectRefused(a, r, "    permissions:\n      contents: read\n", "", "job `publish` permissions are not exactly");
    try expectRefused(a, r, "    permissions:\n      contents: read\n", "    permissions:\n      contents: read\n      id-token: write\n", "the write permission `id-token: write`");
    try expectRefused(a, r, "          permission-contents: write\n", "          permission-contents: write\n          permission-pull-requests: write\n", "the write permission `permission-pull-requests: write`");
    try expectRefused(a, r, "          permission-contents: write\n", "          permission-contents: write\n          permission-workflows: write\n", "differs from release.yml");
    try expectRefused(a, r, "          repositories: buildrules\n", "          repositories: buildrules,homebrew-tap\n", "differs from release.yml");
    try expectRefused(a, r, "          repositories: buildrules\n", "", "differs from release.yml");
    try expectRefused(a, r, "          owner: ${{ github.repository_owner }}\n", "", "differs from release.yml");
    try expectRefused(a, r, "private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}", "private-key: ${{ secrets.OTHER_KEY }}", "secret other than");
    try expectRefused(a, r, "private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}", "private-key: ${{ secrets.OTHER_KEY }}", "differs from release.yml");
    try expectRefused(a, r, "app-id: ${{ vars.RELEASE_BOT_APP_ID }}", "app-id: 5395718", "differs from release.yml");
    try expectRefused(a, r, "    permissions:\n      contents: read\n", "    permissions:\n      contents: read\n    env:\n      KEY: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n", "reads a secret other than");
}

test "rule:the bot's token minted or held when it is not an apply" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    // minted unconditionally, or on a condition that is not the input
    try expectRefused(a, r, "        id: bot\n        if: inputs.apply\n", "        id: bot\n", "mint step is not `if: inputs.apply`");
    try expectRefused(a, r, "        id: bot\n        if: inputs.apply\n", "        id: bot\n        if: true\n", "mint step is not `if: inputs.apply`");
    try expectRefused(a, r, "        id: bot\n        if: inputs.apply\n", "        id: bot\n        if: inputs.apply || true\n", "mint step is not `if: inputs.apply`");
    try expectRefused(a, r, "        id: bot\n        if: inputs.apply\n", "        id: bot\n        if: always()\n", "mint step is not `if: inputs.apply`");
    try expectRefused(a, r, "        id: bot\n        if: inputs.apply\n", "        id: bot\n        if: github.event_name == 'workflow_dispatch'\n", "mint step is not `if: inputs.apply`");
    // the apply step runs on a dry dispatch
    try expectRefused(a, r, "        if: inputs.apply\n        env:\n          GH_TOKEN: ${{ steps.bot", "        env:\n          GH_TOKEN: ${{ steps.bot", "apply step is not `if: inputs.apply`");
    // the dry run is conditional (a release of programs nobody checked)
    try expectRefused(a, r, "      - name: Dry run\n", "      - name: Dry run\n        if: inputs.apply\n", "dry run is conditional");
    try expectRefused(a, r, "      - name: Build publish_unpack\n", "      - name: Build publish_unpack\n        if: inputs.apply\n", "`if:` lines");
    // the token moved: on the dry run, on the job, on the workflow, in another spelling
    try expectRefused(a, r, "          GH_TOKEN: ${{ github.token }}\n", "          GH_TOKEN: ${{ steps.bot.outputs.token }}\n", "dry run does not run with");
    try expectRefused(a, r, "          GH_TOKEN: ${{ steps.bot.outputs.token }}\n", "          GH_TOKEN: ${{ github.token }}\n", "apply step does not run with");
    try expectRefused(a, r, "    permissions:\n      contents: read\n", "    permissions:\n      contents: read\n    env:\n      GH_TOKEN: ${{ steps.bot.outputs.token }}\n", "`env:` at workflow or job level");
    try expectRefused(a, r, "name: publish-unpack\n", "name: publish-unpack\nenv:\n  GH_TOKEN: ${{ github.token }}\n", "`env:` at workflow or job level");
    try expectRefused(a, r, "        env:\n          GH_TOKEN: ${{ github.token }}\n", "        env:\n          \"GH_TOKEN\": ${{ github.token }}\n", "set other than as a step env");
    // a step between the mint and the apply, or a second mint before the dry run
    try expectRefused(a, r, "      - name: Create the release, upload", "      - name: Between\n        run: echo hi\n\n      - name: Create the release, upload", "does not immediately follow the mint step");
    try expectRefused(a, r, "      - name: Dry run\n", "      - name: Early\n        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n        with:\n          app-id: ${{ vars.RELEASE_BOT_APP_ID }}\n\n      - name: Dry run\n", "steps mint a token");
    // --apply in the dry run
    try expectRefused(a, r, "          \"$RUNNER_TEMP/publish_unpack\" --root", "          \"$RUNNER_TEMP/publish_unpack\" --apply --work \"$RUNNER_TEMP/unpack-work\" --root", "`--apply` is in");
}

test "rule:a write that replaces, removes or goes around the tool" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectRefused(a, r, "--buck2-config buildrules_re.mode=local\n", "--buck2-config buildrules_re.mode=local --force\n", "mentions `--force`");
    try expectRefused(a, r, "--buck2-config buildrules_re.mode=local\n", "--buck2-config buildrules_re.mode=local --clobber\n", "mentions `--clobber`");
    try expectRefused(a, r, "--buck2-config buildrules_re.mode=local\n", "--buck2-config buildrules_re.mode=local --clobber\n", "neither the dry run nor the apply command");
    try expectRefused(a, r, "          mkdir \"$RUNNER_TEMP/unpack-work\"\n", "          mkdir \"$RUNNER_TEMP/unpack-work\"\n          gh release upload unpack-1 x --clobber\n", "a `gh` command");
    try expectRefused(a, r, "          mkdir \"$RUNNER_TEMP/unpack-work\"\n", "          mkdir \"$RUNNER_TEMP/unpack-work\"\n          gh release delete unpack-1 --yes\n", "mentions `release delete`");
    try expectRefused(a, r, "          mkdir \"$RUNNER_TEMP/unpack-work\"\n", "          mkdir \"$RUNNER_TEMP/unpack-work\"\n          git push origin HEAD:refs/tags/unpack-1\n", "mentions `git push`");
    try expectRefused(a, r, "          chmod +x \"$RUNNER_TEMP/publish_unpack\"\n", "          chmod +x \"$RUNNER_TEMP/publish_unpack\"\n          gh api -X DELETE repos/o/r/git/refs/tags/unpack-1\n", "a `gh` command");
    try expectRefused(a, r, "--apply --work \"$RUNNER_TEMP/unpack-work\"", "--apply --work \"$RUNNER_TEMP/unpack-work\" --git /bin/true", "neither the dry run nor the apply command");
    try expectRefused(a, r, "mkdir \"$RUNNER_TEMP/unpack-work\"\n", "mkdir \"$RUNNER_TEMP/unpack-work\"\n          \"$RUNNER_TEMP/publish_unpack\" --root x\n", "runs 3 times");
}

test "rule:a third-party or unpinned action" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectRefused(a, r, "      - name: Dry run\n", "      - uses: someone/scan@3d3c42e5aac5ba805825da76410c181273ba90b1\n      - name: Dry run\n", "is not allowed");
    try expectRefused(a, r, "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "actions/checkout@v7", "not pinned to a full commit sha");
    try expectRefused(a, r, "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0", "actions/create-github-app-token@v3", "not pinned to a full commit sha");
    try expectRefused(a, r, "      - name: Dry run\n", "      - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: x\n          key: y\n\n      - name: Dry run\n", "`uses:` lines");
}

test "rule:a build that is not local, an unpinned buck2, a tree that is not the commit" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectRefused(a, r, "./buck2 build --console simple -c buildrules_re.mode=local --out", "./buck2 build --console simple --out", "does not pass `-c buildrules_re.mode=local`");
    try expectRefused(a, r, "--buck2-config buildrules_re.mode=local", "--buck2-config buildrules_re.mode=remote", "something other than `local`");
    try expectRefused(a, r, "      - name: Dry run\n", "      - run: ./buck2 build -c buildrules_re.mode=local //ci:all\n      - name: Dry run\n", "2 `./buck2` commands");
    try expectRefused(a, r, "sha256sum --check --strict -", "sha256sum --check -", "is not checked with `sha256sum --check --strict -`");
    try expectRefused(a, r, "2026-09-15/buck2-x86_64", "latest/buck2-x86_64", "does not download the url pinned");
    try expectRefused(a, r, "1268fce33fb61273091dd5dd8c60b65de1521a3caa36b88983813e882b7ffd89", "0000000000000000000000000000000000000000000000000000000000000000", "does not check the sha256 pinned");
    try expectRefused(a, r, "          rm buck2.zst\n", "", "`rm buck2.zst` is missing");
    // moved after the build of the tool (the tree would still differ from the commit while it builds)
    const moved = try edited(a, try edited(a, r.wf, "          rm buck2.zst\n", ""), "      - name: Dry run\n", "      - run: rm buck2.zst\n      - name: Dry run\n");
    try expectFinding(a, moved, r, "`rm buck2.zst` is not after the sha256 check and before the build of the tool");
    try expectRefused(a, r, "--out \"$RUNNER_TEMP/publish_unpack\"", "--out publish_unpack", "build of the tool is not exactly");
    try expectRefused(a, r, "      - name: Dry run\n", "      - name: Dry run\n        x: engine_address\n", "mentions `engine_address`");
}

test "rule:an inline expansion of event data" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectRefused(a, r, "          chmod +x \"$RUNNER_TEMP/publish_unpack\"\n", "          echo ${{ github.event.inputs.apply }}\n          chmod +x \"$RUNNER_TEMP/publish_unpack\"\n", "expands `github.event.` inline");
    try expectRefused(a, r, "    timeout-minutes: 120\n", "    timeout-minutes: 120\n    continue-on-error: true\n", "`continue-on-error` is set to `true`");
}
