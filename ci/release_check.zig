//! The release workflow (.github/workflows/release.yml) is what RELEASING.md says it is. A pure function of the text, so each rule is tested
//! against planted text as well as against the real files (the zig_test's `data`, under BUILDRULES_TEST_WORK). The rules that release.yml
//! shares with ci.yml (actions pinned by commit, local mode on every buck2 command, the pinned buck2 install) are the ones in
//! workflow_check.zig; what is here is what only the release has:
//!
//!  - the triggers: a push to main and nothing else (no pull request, no dispatch, no schedule, no workflow_run): a pull request runs ci.yml alone (build and
//!    unit tests), and the beta, the gamma, the signing, the attestation and the verification are this workflow's, after the merge; the workflow-level
//!    concurrency is one group for every push, which never cancels a run;
//!  - the token: `permissions: {}` at the top, every job states its own, and a write scope only where it belongs: `contents: write` in the job
//!    `publish` (and nowhere else; `tag` holds `contents: read` and writes with the release bot's token, minted by one step with exact inputs and used by the tag step alone), `id-token: write` and `attestations: write` in `attest` (and `id-token` in `gamma`, in the call of `beta`, for the farm, and in the `apt-deploy-*` jobs, for the cloud role), each of
//!    `attest`, `verify`, `tag`, `publish` and `bump` under its exact `if:` (a push to main, not a fork, a commit the plan released) so that no pull request signs, attests, tags or publishes, and every `: write` of the file accounted for by a job's permissions block;
//!  - the order gate -> plan -> build-cli -> beta -> gamma -> archive -> attest -> verify -> tag -> publish, with no job before the tag waiting for it (a failure
//!    before the tag leaves no tag behind), a release made only when the plan released, and no status function (`always()`, `failure()`, `cancelled()`) or
//!    `continue-on-error` that would let a job run or pass after a red one;
//!  - RELEASE_FREEZE is read in `plan` and nowhere else, and the plan is never a dry run (`--dry false`);
//!  - the binaries: the stamped build of `//cli:release_binaries` and its three tarballs in `build-cli`, the very file the beta runs handed on as `release-cli-bin`
//!    and checked against the tarball in `archive`, the second build in `verify` that must give the same tarballs, and `release-dist` as the one set of files
//!    that `verify`, `publish` and `site` read;
//!  - `tap` (the Homebrew formula as a pull request in the tap): `contents: read`, the exact `if:` of `publish`, a wait for the plan, the tag, the publish and the tool, nothing
//!    waiting for it, the environment `release`, the formula rendered by one exact command before any token exists, the release bot's token minted for the tap
//!    repository alone in the second to last step (exact inputs) and given to the last step alone, and the arguments the tap's guard depends on;
//!  - the apt repository (`apt-deploy-read`, `apt-index`, `apt-deploy-write`, in three attempts): the signing key (environment `apt-signing`, secrets `APT_GPG_*`) is read
//!    by the `apt-index` jobs alone, in the signing step, and the cloud role (environment `apt-publish`, `id-token: write`, `APT_PUBLISH_ROLE_ARN`) by the
//!    `apt-deploy-*` jobs alone, so no job holds both; every step that reads, signs or writes is behind the gate that makes a job without the settings end
//!    green and do nothing; the last attempt writes with `--last`; nothing waits for these jobs but themselves;
//!  - `bump`, the last step (the pull request that moves the internal repository's submodule to the release): `contents: read` for its own token, the exact
//!    `if:` of `tag` and `publish`, a wait for the plan, the tag, the publish and the tool, nothing waiting for it, the release bot's token minted for the internal
//!    repository alone (a second mint, exact inputs, after a step that refuses an unnamed repository) and used by the bump step alone, and the arguments the
//!    internal repository's bump guard depends on;
//!  - the jobs that write run no buck2 and only the checkout and download actions (`attest` also the upload, cosign and attestation actions): the tool they run was built before any token existed;
//!  - the attestation action is in `attest` only, every checkout drops its credentials, `run:` lines are single invocations (the
//!    install of buck2 aside), a cosign bundle is only ever named `<file>.sigstore.json` for `SHA256SUMS`, the source archive, a CLI tarball or a .deb (the names `release sign` writes), no asset is ever replaced (`--clobber`), no secret is read but the release bot's private key (in `tag`, `bump` and `tap`, once each) and the apt signing key (in the signing step of each `apt-index` job).
const std = @import("std");
const wc = @import("workflow_check.zig");
const t = std.testing;

const Findings = wc.Findings;
const add = wc.add;

pub const tag_if = "${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork }}";
/// publish and bump also skip a run the tag job ended as superseded (a release made meanwhile contains its commit): they are not the plan's alone.
pub const publish_if = "${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork && needs.tag.outputs.superseded != 'true' }}";
const superseded_clause = "needs.tag.outputs.superseded != 'true'";
/// The tag job's outputs, which publish, site and bump use in place of the plan's: the plan ran before the build, and a push that landed meanwhile may have taken the number.
const tag_outputs =
    "    outputs:\n" ++
    "      superseded: ${{ steps.settle.outputs.superseded }}\n" ++
    "      tag: ${{ steps.settle.outputs.tag }}\n" ++
    "      number: ${{ steps.settle.outputs.number }}\n";
const tag_env_final = "      TAG: ${{ needs.tag.outputs.tag }}\n";
/// The `if:` of the jobs that build and test a commit the plan released: not one whose release is already complete (the plan checked that the release holds every
/// file with the digests of its SHA256SUMS), which has nothing left to build. Every job after them waits for them (the order below), so a skipped build skips the
/// archive, the signing, the verification, the tag, the publish and the channels with it: none of those has a status function that would run it anyway.
pub const released_if = "${{ needs.plan.outputs.released == 'true' && needs.plan.outputs.complete != 'true' }}";
/// build-cli, beta, gamma, archive, attest, verify, tag, publish and site run only for a commit the plan released.
const released_clause = "needs.plan.outputs.released == 'true'";
const ci_call = "./.github/workflows/ci.yml";
const beta_call = "./.github/workflows/beta.yml";
/// The farm-connect action, checked out of the repository a variable names at the commit another names, then used from the checkout.
const farm_action = "./farm-action/.github/actions/farm-connect";
const tool_target = "//tools/release:release";
const stage_target = "//tools/stage:stage";
/// The tools of the channels, built by `tool` and handed on as the artifact `channel-tools`.
const channel_targets = [_][2][]const u8{
    .{ "//tools/channels:channels", "--out channels " },
    .{ "//tools/deploy:tap", "--out tap " },
    .{ "//tools/deploy:apt_publish", "--out apt-publish " },
};

/// The jobs, and the job each one must wait for (`needs`): gate -> plan -> build-cli -> beta -> gamma -> archive -> attest -> verify -> tag -> publish
/// (tool beside gate; site after tag and verify).
const order = [_][2][]const u8{
    .{ "plan", "gate" },
    .{ "plan", "tool" },
    .{ "build-cli", "plan" },
    .{ "build-cli", "tool" },
    .{ "beta", "plan" },
    .{ "beta", "build-cli" },
    .{ "gamma", "plan" },
    .{ "gamma", "beta" },
    .{ "gamma", "tool" },
    .{ "archive", "plan" },
    .{ "archive", "build-cli" },
    .{ "archive", "beta" },
    .{ "archive", "gamma" },
    .{ "archive", "tool" },
    .{ "attest", "plan" },
    .{ "attest", "archive" },
    .{ "attest", "tool" },
    .{ "verify", "plan" },
    .{ "verify", "attest" },
    .{ "verify", "tool" },
    .{ "tag", "plan" },
    .{ "tag", "verify" },
    .{ "publish", "plan" },
    .{ "publish", "tag" },
    .{ "publish", "verify" },
    .{ "site", "tag" },
    .{ "site", "verify" },
    .{ "tap", "plan" },
    .{ "tap", "tag" },
    .{ "tap", "publish" },
    .{ "tap", "tool" },
    .{ "apt-deploy-read", "plan" },
    .{ "apt-deploy-read", "tag" },
    .{ "apt-deploy-read", "publish" },
    .{ "apt-deploy-read", "tool" },
    .{ "apt-index", "apt-deploy-read" },
    .{ "apt-deploy-write", "apt-deploy-read" },
    .{ "apt-deploy-write", "apt-index" },
    .{ "apt-deploy-read-2", "apt-deploy-write" },
    .{ "apt-index-2", "apt-deploy-read-2" },
    .{ "apt-deploy-write-2", "apt-deploy-read-2" },
    .{ "apt-deploy-write-2", "apt-index-2" },
    .{ "apt-deploy-read-3", "apt-deploy-write-2" },
    .{ "apt-index-3", "apt-deploy-read-3" },
    .{ "apt-deploy-write-3", "apt-deploy-read-3" },
    .{ "apt-deploy-write-3", "apt-index-3" },
};
/// The jobs that run before the tag exists: none of them may wait for it, or a failure there could not be told from one after the tag.
const before_tag = [_][]const u8{ "gate", "tool", "plan", "build-cli", "beta", "gamma", "archive", "attest", "verify" };
const all_jobs = [_][]const u8{
    "gate", "tool", "plan", "build-cli", "beta", "gamma", "archive", "attest", "verify", "tag", "site", "publish", "bump", "tap",
    "apt-deploy-read", "apt-index", "apt-deploy-write", "apt-deploy-read-2", "apt-index-2", "apt-deploy-write-2", "apt-deploy-read-3", "apt-index-3", "apt-deploy-write-3",
};
/// The three attempts of the apt publish: the jobs of each, in order, and the suffix of its artifacts. A lost write hands over to the next attempt.
const AptAttempt = struct { read: []const u8, index: []const u8, write: []const u8, suffix: []const u8, prev_write: ?[]const u8, last: bool };
const apt_attempts = [_]AptAttempt{
    .{ .read = "apt-deploy-read", .index = "apt-index", .write = "apt-deploy-write", .suffix = "", .prev_write = null, .last = false },
    .{ .read = "apt-deploy-read-2", .index = "apt-index-2", .write = "apt-deploy-write-2", .suffix = "-2", .prev_write = "apt-deploy-write", .last = false },
    .{ .read = "apt-deploy-read-3", .index = "apt-index-3", .write = "apt-deploy-write-3", .suffix = "-3", .prev_write = "apt-deploy-write-2", .last = true },
};
const apt_publish_environment = "apt-publish";
const apt_signing_environment = "apt-signing";
/// The guard of every step that reads, signs or writes in an apt job: the gate step said the settings are made.
const apt_guard = "        if: steps.gate.outputs.enabled == 'true'\n";
/// What the gate of each kind of apt job requires. A job whose settings are not made ends green with a notice and runs nothing behind the gate.
const apt_read_gate = "tool/apt-publish gate --label \"apt publish (read)\" --out \"$GITHUB_OUTPUT\" --env APT_PUBLISH_ROLE_ARN --env APT_BUCKET --env APT_DISTRIBUTION_ID --env APT_HOSTNAME";
const apt_index_gate = "tool/apt-publish gate --label \"apt index\" --out \"$GITHUB_OUTPUT\" --true READ_ENABLED --true HAVE_KEY --env APT_GPG_FINGERPRINT";
const apt_write_gate = "tool/apt-publish gate --label \"apt publish (write)\" --out \"$GITHUB_OUTPUT\" --true READ_ENABLED --true INDEX_SIGNED --env APT_PUBLISH_ROLE_ARN --env APT_BUCKET --env APT_DISTRIBUTION_ID --env APT_HOSTNAME";
/// What `bump` waits for: the plan (the tag it opens the pull request for), the tag and the publish (the guard of the internal repository reads the
/// tag, and the release exists before anything points at it), and the tool. Nothing waits for `bump`. `tap` and the first apt read wait for the same four.
const bump_needs = [_][]const u8{ "plan", "tag", "publish", "tool" };
/// What each job runs of the tool.
const tool_runs = [_][2][]const u8{
    .{ "gamma", "tool/stage gamma-vars " },
    .{ "gamma", "tool/stage action-ref " },
    .{ "gamma", "tool/stage gamma " },
    .{ "plan", "tool/release plan " },
    .{ "build-cli", "tool/release package-all " },
    .{ "build-cli", "tool/release debs " },
    .{ "archive", "tool/release archive " },
    .{ "archive", "tool/release record " },
    .{ "archive", "tool/release tested " },
    .{ "archive", "tool/release sums " },
    .{ "attest", "tool/release sign " },
    .{ "verify", "tool/release package-all " },
    .{ "verify", "tool/release debs " },
    .{ "verify", "tool/release verify " },
    .{ "tag", "tool/release tag " },
    .{ "site", "tool/release site " },
    .{ "publish", "tool/release publish " },
    .{ "bump", "tool/release bump-check " },
    .{ "bump", "tool/release bump-internal " },
    .{ "tap", "tool/channels formula " },
    .{ "tap", "tool/tap " },
};
/// The actions a job that writes may use; `tag` also mints the release bot's token.
const write_job_actions = [_][]const u8{ "actions/checkout", "actions/download-artifact" };
/// What `attest`, which signs and attests, may use besides the download: the upload of what it signed, the installer of cosign and the attestation. It runs no buck2.
const attest_actions = [_][]const u8{ "actions/download-artifact", "actions/upload-artifact", "sigstore/cosign-installer", "actions/attest-build-provenance" };
const cosign_action = "sigstore/cosign-installer";
/// The cosign that the release installs: the retry of `release verify` reads its stderr, so the installer names the version and does not take the action's default.
const cosign_release = "v3.0.6";
/// The install of cosign as the workflow spells it: the pinned action and the version it is told.
const cosign_step = "      - uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2\n        with:\n          cosign-release: '" ++ cosign_release ++ "'\n";
const app_token_action = "actions/create-github-app-token";
/// The environment that holds the release bot's key (the owner restricts it to main as a setup step; nothing here checks that); declared by the jobs that read `RELEASE_BOT_*` and by no other.
const release_environment = "release";

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

/// The step of `bump` that checks the internal repository is named, before any token exists: the token is minted for the repository the variable
/// names, and an empty `repositories` list would reach every repository the App is installed on.
const bump_check_step = "      - name: The internal repository is named\n        run: tool/release bump-check --internal-repo \"$INTERNAL_REPO\"\n";
/// The step of `bump` that mints the release bot's token for the internal repository alone: every input exact. The organisation is the repository's
/// own owner, the repository a variable, the scopes contents and pull requests (a branch to push, a pull request to open and merge on).
const bump_mint =
    "      - name: The token of the release bot, for the internal repository alone\n" ++
    "        id: bump_bot\n" ++
    "        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n" ++
    "        with:\n" ++
    "          app-id: ${{ vars.RELEASE_BOT_APP_ID }}\n" ++
    "          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n" ++
    "          owner: ${{ github.repository_owner }}\n" ++
    "          repositories: ${{ vars.BUMP_REPOSITORY }}\n" ++
    "          permission-contents: write\n" ++
    "          permission-pull-requests: write\n" ++
    "      - name: The pull request that moves the submodule to this release, with auto-merge\n"; // the next step: no input may follow the last one
/// The bump step: the internal bot's token is its GH_TOKEN, here and nowhere else.
const bump_step_env = "        env:\n          GH_TOKEN: ${{ steps.bump_bot.outputs.token }}\n        run: tool/release bump-internal ";
/// The arguments of the bump step that the guard of the internal repository depends on: the released repository, its tag and commit, the internal
/// repository (the owner's own, with the variable's name), and the submodule path.
const bump_args = [_][]const u8{
    "--repo \"$GITHUB_REPOSITORY\"",
    "--tag \"$TAG\"",
    "--sha \"$GITHUB_SHA\"",
    "--internal-repo \"$INTERNAL_REPO\"",
    "--submodule buildrules",
};
const bump_internal_env = "      INTERNAL_REPO: ${{ github.repository_owner }}/${{ vars.BUMP_REPOSITORY }}\n";

/// The render step of `tap`: the formula from the verified SHA256SUMS with the flags the tap's guard expects (no version line, the asset stem of the tarballs,
/// this repository's release urls). tools/channels/channels_cli_test.zig runs this very line and compares the file with the formula the guard is to accept.
const tap_render = "tool/channels formula --sums dist/SHA256SUMS --name buildrules --asset buildrules-cli --version \"$NUMBER\" --desc \"Hermetic Buck2 rules and toolchains\" --homepage \"https://buildrules.dev\" --license \"Apache-2.0\" --repo \"$GITHUB_REPOSITORY\" --no-explicit-version --out tap/buildrules.rb";
/// The step of `tap` that mints the release bot's token for the tap repository alone: every input exact, the organisation the repository's own.
const tap_mint =
    "      - name: The token of the release bot, for the tap repository alone\n" ++
    "        id: tap_bot\n" ++
    "        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n" ++
    "        with:\n" ++
    "          app-id: ${{ vars.RELEASE_BOT_APP_ID }}\n" ++
    "          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n" ++
    "          owner: ${{ github.repository_owner }}\n" ++
    "          repositories: homebrew-tap\n" ++
    "          permission-contents: write\n" ++
    "          permission-pull-requests: write\n" ++
    "      - name: The pull request that adds the formula of this release to the tap, with auto-merge when the tap allows it\n"; // the next step: no input may follow the last one
/// The tap step: the tap bot's token is its GH_TOKEN, here and nowhere else.
const tap_step_env = "        env:\n          GH_TOKEN: ${{ steps.tap_bot.outputs.token }}\n        run: tool/tap ";
/// The arguments of the tap step that the tap's guard depends on: the released repository, the version of the tag job, the formula file the render step wrote,
/// the tap (the owner's own `homebrew-tap`), the formula and the asset stem.
const tap_args = [_][]const u8{
    "--repo \"$GITHUB_REPOSITORY\"",
    "--version \"$NUMBER\"",
    "--formula-file tap/buildrules.rb",
    "--tap-repo \"$OWNER/homebrew-tap\"",
    "--formula buildrules",
    "--asset buildrules-cli",
};
const tap_env = "      NUMBER: ${{ needs.tag.outputs.number }}\n      OWNER: ${{ github.repository_owner }}\n";

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
    environment: ?[]const u8 = null,

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
            } else if (std.mem.eql(u8, key, "environment")) {
                j.environment = stripComment(val);
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

/// Whether a job may hold `scope: write`: `contents` in publish (tag, bump and tap write with the release bot's token, not their own); `id-token` in attest (the
/// signature and the attestation), in gamma (the farm's network), in beta (the call of beta.yml, whose farm leg joins the farm's network) and in the apt-deploy jobs
/// (the OIDC exchange for the publish role); `attestations` in attest.
fn writeAllowed(job: []const u8, scope: []const u8) bool {
    if (std.mem.eql(u8, scope, "contents")) return std.mem.eql(u8, job, "publish");
    if (std.mem.eql(u8, scope, "id-token")) return std.mem.eql(u8, job, "attest") or std.mem.eql(u8, job, "gamma") or std.mem.eql(u8, job, "beta") or isAptDeploy(job);
    if (std.mem.eql(u8, scope, "attestations")) return std.mem.eql(u8, job, "attest");
    return false;
}

/// The jobs that assume the apt publish role through OIDC: the reads and the writes of the three attempts (the index jobs hold the key and no role).
fn isAptDeploy(job: []const u8) bool {
    return std.mem.startsWith(u8, job, "apt-deploy-");
}

fn isAptIndex(job: []const u8) bool {
    return std.mem.startsWith(u8, job, "apt-index");
}

fn writeOwners(scope: []const u8) []const u8 {
    if (std.mem.eql(u8, scope, "contents")) return "publish";
    if (std.mem.eql(u8, scope, "id-token")) return "attest, gamma, beta and the apt-deploy jobs";
    if (std.mem.eql(u8, scope, "attestations")) return "attest";
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

const release_targets = [_][]const u8{ "linux-x86_64", "linux-aarch64", "macos-arm64" };

/// An expression `${{ ... }}` and nothing else: the variable that stands for a version or a target.
fn isExpression(s: []const u8) bool {
    return s.len > 5 and std.mem.startsWith(u8, s, "${{") and std.mem.endsWith(u8, s, "}}") and std.mem.count(u8, s, "${{") == 1 and std.mem.count(u8, s, "}}") == 1;
}

/// `MAJOR.MINOR.PATCH` written out (digits, no leading zero but `0` itself), or a variable that stands for one.
fn isVersionWord(s: []const u8) bool {
    if (isExpression(s)) return true;
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |p| : (parts += 1) {
        if (p.len == 0 or p.len > 9 or (p.len > 1 and p[0] == '0')) return false;
        for (p) |c| {
            if (c < '0' or c > '9') return false;
        }
    }
    return parts == 3;
}

/// `<version>-<target>`: the version and the release target (`linux-x86_64`...) each written out or as a variable. The target is the last piece, so a version
/// that is a variable may hold a hyphen of its own.
fn isVersionTarget(s: []const u8) bool {
    for (release_targets) |tg| {
        if (!std.mem.endsWith(u8, s, tg) or s.len < tg.len + 2 or s[s.len - tg.len - 1] != '-') continue;
        return isVersionWord(s[0 .. s.len - tg.len - 1]);
    }
    // the target is a variable: the last expression, after a hyphen
    if (!std.mem.endsWith(u8, s, "}}")) return false;
    const at = std.mem.lastIndexOf(u8, s, "${{") orelse return false;
    if (at < 2 or s[at - 1] != '-') return false;
    return isVersionWord(s[0 .. at - 1]);
}

/// The one spelling of a cosign bundle's name: `<file>.sigstore.json` for exactly the files `release sign` signs (tools/release/binaries.zig): `SHA256SUMS`, the
/// source archive `buildrules-<V>.tar.gz`, the three tarballs `buildrules-cli-<V>-<target>.tar.gz` and the two .debs `buildrules_<V>_<arch>.deb`, with `V` a version
/// written out or as a variable and `<target>` one of the three release targets (`<arch>` amd64 or arm64) or a variable. Every word of the workflow that mentions `sigstore` (but the install of cosign, which is not a file) must be one
/// of those shapes, so a bundle a step uploads or verifies by another name (`.sigstore`, `.bundle`, `.sigstore.json.json`, a glob, a stem that is no release file)
/// is not one `sign` wrote.
pub fn sigstoreName(word: []const u8) bool {
    const suffix = ".sigstore.json";
    if (!std.mem.endsWith(u8, word, suffix)) return false;
    const stem = word[0 .. word.len - suffix.len];
    if (std.mem.indexOf(u8, stem, "sigstore") != null) return false;
    const base = if (std.mem.lastIndexOfScalar(u8, stem, '/')) |i| stem[i + 1 ..] else stem;
    if (std.mem.eql(u8, base, "SHA256SUMS")) return true;
    if (std.mem.endsWith(u8, base, ".deb") and std.mem.indexOfAny(u8, base, "*?[") == null) {
        const deb = base[0 .. base.len - ".deb".len];
        if (!std.mem.startsWith(u8, deb, "buildrules_")) return false;
        const rest = deb["buildrules_".len..];
        const us = std.mem.lastIndexOfScalar(u8, rest, '_') orelse return false;
        const arch = rest[us + 1 ..];
        if (!(std.mem.eql(u8, arch, "amd64") or std.mem.eql(u8, arch, "arm64") or isExpression(arch))) return false;
        return isVersionWord(rest[0..us]);
    }
    if (!std.mem.endsWith(u8, base, ".tar.gz") or std.mem.indexOfAny(u8, base, "*?[") != null) return false;
    const name = base[0 .. base.len - ".tar.gz".len];
    if (std.mem.startsWith(u8, name, "buildrules-cli-")) return isVersionTarget(name["buildrules-cli-".len..]);
    if (std.mem.startsWith(u8, name, "buildrules-")) return isVersionWord(name["buildrules-".len..]);
    return false;
}

fn sigstoreNames(a: std.mem.Allocator, f: *Findings, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // the installer of cosign is an action to run, not a bundle: `uses: sigstore/cosign-installer@<commit>` alone is exempt (another sigstore action is not)
        if (usesRepo(line)) |repo| {
            if (std.mem.eql(u8, repo, cosign_action)) continue;
        }
        var it = std.mem.tokenizeAny(u8, line, " \t\r\n\"'`,()=:;|<>");
        while (it.next()) |word| {
            if (std.mem.indexOf(u8, word, "sigstore") == null) continue;
            if (!sigstoreName(word)) try add(a, f, "`{s}` names a cosign bundle other than `<file>.sigstore.json` of SHA256SUMS, `buildrules-<V>.tar.gz`, `buildrules-cli-<V>-<target>.tar.gz` or `buildrules_<V>_<arch>.deb` (what `release sign` writes)", .{word});
        }
    }
}

/// The candidate commit: the pushed commit (no pull request runs this workflow). The jobs that test it name it this way, and the jobs that write name `$GITHUB_SHA`.
const candidate_expr = "${{ github.sha }}";
const candidate_env = "      CANDIDATE: " ++ candidate_expr ++ "\n";
const candidate_ref = "          ref: " ++ candidate_expr ++ "\n";
/// Jobs that check the candidate out and name it.
const candidate_jobs = [_][]const u8{ "plan", "archive", "verify" };

/// Whether `text` holds `needle` at the end of a line: a command is held to its exact arguments, and one with more after them is another command.
fn hasLineEnd(text: []const u8, needle: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, needle)) |at| : (from = at + 1) {
        const end = at + needle.len;
        if (end == text.len or text[end] == '\n') return true;
    }
    return false;
}

/// The stamp of the planned version and the build of the three binaries, in `build-cli` (into `cli-bins`) and in the two verifies (into `rebuilt-bins`).
fn buildBinaries(out_dir: []const u8) []const u8 {
    return if (std.mem.eql(u8, out_dir, "cli-bins"))
        "./buck2 build --console simple -c buildrules_re.mode=local -c \"buildrules.release_version=$NUMBER\" --out cli-bins //cli:release_binaries"
    else
        "./buck2 build --console simple -c buildrules_re.mode=local -c \"buildrules.release_version=$NUMBER\" --out rebuilt-bins //cli:release_binaries";
}

/// The step of the job `jb` (indentation kept) that holds `marker`: from its `      - ` line to the next step's, or null when no step holds it.
fn stepWith(jb: []const u8, marker: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, jb, marker) orelse return null;
    const start = if (std.mem.lastIndexOf(u8, jb[0..at], "\n      - ")) |i| i + 1 else 0;
    const end = std.mem.indexOfPos(u8, jb, at, "\n      - ") orelse jb.len;
    return jb[start..end];
}

/// Whether the position of `a_marker` in `jb` is before `b_marker`'s (both present).
fn precedes(jb: []const u8, a_marker: []const u8, b_marker: []const u8) bool {
    const x = std.mem.indexOf(u8, jb, a_marker) orelse return false;
    const y = std.mem.indexOf(u8, jb, b_marker) orelse return false;
    return x < y;
}

/// `tap`: the Homebrew formula as a pull request in the tap, after the release exists. The token is for the tap repository alone, minted in the second to last
/// step with exact inputs and used by the last step alone; the formula is rendered before any token exists, by the one command the tap's guard depends on.
fn checkTap(a: std.mem.Allocator, f: *Findings, jobs: []Job, text: []const u8) !void {
    const j = jobNamed(jobs, "tap") orelse return;
    if (j.if_expr == null or !std.mem.eql(u8, j.if_expr.?, publish_if)) try add(a, f, "the job `tap` is not under its exact `if:` ({s})", .{publish_if});
    for (bump_needs) |need| {
        if (!hasNeed(j, need)) try add(a, f, "the job `tap` does not wait for `{s}` (it opens the pull request after the tag exists and the release is published)", .{need});
    }
    const jb = jobBlock(text, "tap");
    const render_at = std.mem.indexOf(u8, jb, "        run: tool/channels formula ");
    if (!hasLineEnd(jb, "        run: " ++ tap_render)) try add(a, f, "the job `tap` does not render the formula with exactly `{s}` (the flags the tap's guard expects)", .{tap_render});
    const mint = std.mem.indexOf(u8, jb, tap_mint);
    if (mint == null) try add(a, f, "the job `tap` does not mint the release bot's token with exactly the pinned inputs of `actions/create-github-app-token` (app-id, private-key, owner, repositories: homebrew-tap, permission-contents, permission-pull-requests), in the step before the last", .{});
    const use = std.mem.indexOf(u8, jb, tap_step_env);
    if (use == null) try add(a, f, "the step of `tap` that runs `tool/tap` does not take the bot's token as its GH_TOKEN (`steps.tap_bot.outputs.token`)", .{});
    if (mint != null and use != null and mint.? > use.?) try add(a, f, "the job `tap` uses the bot's token before the step that mints it", .{});
    if (render_at != null and mint != null and render_at.? > mint.?) try add(a, f, "the job `tap` mints the bot's token before it has rendered the formula: no token exists while a tool runs but the last", .{});
    if (std.mem.count(u8, jb, "steps.tap_bot.outputs.token") != 1) try add(a, f, "the job `tap` uses the bot's token other than once, in the tap step", .{});
    if (std.mem.indexOf(u8, jb, "github.token") != null or std.mem.indexOf(u8, jb, "secrets.GITHUB_TOKEN") != null) try add(a, f, "the job `tap` uses GITHUB_TOKEN, which holds no write to the tap", .{});
    if (std.mem.count(u8, jb, "secrets.") != 1) try add(a, f, "the job `tap` reads other than the one secret of the release bot's key", .{});
    if (use) |u| {
        // the tap step is the last step of the job: nothing runs after the token is in the environment
        const end = std.mem.indexOfScalarPos(u8, jb, u + tap_step_env.len, '\n') orelse jb.len;
        if (std.mem.indexOf(u8, jb[end..], "\n      - ") != null) try add(a, f, "a step runs after the tap step, which holds the bot's token: it must be the last step of `tap`", .{});
        const run_line = jb[u + tap_step_env.len .. end];
        for (tap_args) |arg| {
            if (std.mem.indexOf(u8, run_line, arg) == null) try add(a, f, "the tap step does not pass {s}", .{arg});
        }
    }
    if (std.mem.indexOf(u8, jb, tap_env) == null) try add(a, f, "the job `tap` does not take the version from the tag job and the owner from the repository (`NUMBER: ${{{{ needs.tag.outputs.number }}}}`, `OWNER: ${{{{ github.repository_owner }}}}`)", .{});
    if (std.mem.indexOf(u8, jb, "needs.plan.outputs.number") != null or std.mem.indexOf(u8, jb, "needs.plan.outputs.tag") != null) try add(a, f, "the job `tap` reads the plan's version, which a push that landed meanwhile may have taken: it uses `needs.tag.outputs.number`", .{});
    if (std.mem.indexOf(u8, jb, "actions/checkout@") != null) try add(a, f, "the job `tap` checks the repository out: it needs the tools and the verified files, not the sources", .{});
    if (std.mem.indexOf(u8, jb, "name: release-dist\n          path: dist\n") == null or std.mem.indexOf(u8, jb, "release-unsigned") != null) try add(a, f, "the job `tap` does not read `release-dist` (the files that were signed and verified) alone", .{});
    if (std.mem.indexOf(u8, jb, "name: channel-tools\n          path: tool\n") == null) try add(a, f, "the job `tap` does not download the tools of the channels (`channel-tools`) into `tool`", .{});
}

/// The apt repository: three attempts of `apt-deploy-read`, `apt-index` and `apt-deploy-write`. No job holds both the signing key and the cloud role; the key is read in
/// the signing step of the index jobs alone; every step that assumes the role, reads, signs or writes is behind the gate that ends a job without the settings green.
fn checkApt(a: std.mem.Allocator, f: *Findings, jobs: []Job, text: []const u8) !void {
    for (jobs) |*j| {
        const jt = try j.text(a);
        const key = std.mem.indexOf(u8, jt, "secrets.APT_GPG_PRIVATE_KEY") != null;
        const names_role = std.mem.indexOf(u8, jt, "APT_PUBLISH_ROLE_ARN") != null;
        const role = names_role or (permLevel(j, "id-token") != null and std.mem.eql(u8, permLevel(j, "id-token").?, "write") and isAptDeploy(j.name)) or (j.environment != null and std.mem.eql(u8, j.environment.?, apt_publish_environment));
        if (key and role) try add(a, f, "the job `{s}` holds both the apt signing key and the cloud role: one job reads the index, another signs it and a third writes it, so that none can sign what it chose to write", .{j.name});
        if (key and !isAptIndex(j.name)) try add(a, f, "the job `{s}` reads the apt signing key: only the `apt-index` jobs may", .{j.name});
        if (names_role and !isAptDeploy(j.name)) try add(a, f, "the job `{s}` names the apt publish role: only the `apt-deploy-*` jobs may", .{j.name});
        if (isAptDeploy(j.name) and std.mem.indexOf(u8, jt, "secrets.") != null) try add(a, f, "the job `{s}` assumes the apt publish role and reads a secret", .{j.name});
        if (isAptIndex(j.name) and (std.mem.indexOf(u8, jt, "id-token") != null or std.mem.indexOf(u8, jt, "AWS_") != null)) try add(a, f, "the job `{s}` holds the apt signing key and is given the means to reach the cloud (`id-token`, `AWS_*`)", .{j.name});
        if (isAptDeploy(j.name) or isAptIndex(j.name)) {
            for (j.lines.items) |l| {
                if (std.mem.indexOf(u8, l, "buck2") != null) try add(a, f, "the job `{s}` holds the apt signing key or role and runs buck2: {s}", .{ j.name, l });
            }
            if (std.mem.indexOf(u8, jt, "actions/checkout@") != null) try add(a, f, "the job `{s}` checks the repository out: it needs the tools and the verified files, not the sources", .{j.name});
            for (j.lines.items) |l| {
                if (usesRepo(l)) |repo| {
                    if (!std.mem.eql(u8, repo, "actions/download-artifact") and !std.mem.eql(u8, repo, "actions/upload-artifact"))
                        try add(a, f, "the job `{s}` holds the apt signing key or role and uses {s}", .{ j.name, repo });
                }
            }
        }
        // nothing but the apt jobs waits for an apt job: a failed one un-releases nothing
        if (!std.mem.startsWith(u8, j.name, "apt-")) {
            for (j.needs.items) |n| {
                if (std.mem.startsWith(u8, n, "apt-")) try add(a, f, "the job `{s}` waits for `{s}`: nothing may, a failed apt job un-releases nothing", .{ j.name, n });
            }
        }
    }
    for (apt_attempts) |at| {
        const rd = jobNamed(jobs, at.read) orelse continue;
        if (jobNamed(jobs, at.index) == null) continue;
        const wr = jobNamed(jobs, at.write) orelse continue;
        const read_b = jobBlock(text, at.read);
        const index_b = jobBlock(text, at.index);
        const write_b = jobBlock(text, at.write);

        // the read: the role, no key; the first attempt after the publish, a later one only after a lost write
        for ([_]*Job{ rd, wr }) |j| {
            const ok_perms = j.perms.items.len == 2 and permLevel(j, "contents") != null and std.mem.eql(u8, permLevel(j, "contents").?, "read") and permLevel(j, "id-token") != null and std.mem.eql(u8, permLevel(j, "id-token").?, "write");
            if (!ok_perms) try add(a, f, "the job `{s}` is not `contents: read` and `id-token: write` alone", .{j.name});
        }
        if (at.prev_write) |prev| {
            const want = try std.fmt.allocPrint(a, "${{{{ needs.{s}.outputs.conflict == 'true' }}}}", .{prev});
            if (rd.if_expr == null or !std.mem.eql(u8, rd.if_expr.?, want)) try add(a, f, "the job `{s}` does not run only when the write before it lost (`if: {s}`)", .{ at.read, want });
            if (!hasNeed(rd, prev)) try add(a, f, "the job `{s}` does not wait for `{s}`", .{ at.read, prev });
        } else {
            if (rd.if_expr == null or !std.mem.eql(u8, rd.if_expr.?, publish_if)) try add(a, f, "the job `{s}` is not under its exact `if:` ({s})", .{ at.read, publish_if });
            for (bump_needs) |need| {
                if (!hasNeed(rd, need)) try add(a, f, "the job `{s}` does not wait for `{s}` (it publishes after the tag exists and the release is published)", .{ at.read, need });
            }
        }
        if (!hasLineEnd(read_b, "        run: " ++ apt_read_gate)) try add(a, f, "the job `{s}` does not gate on the settings with exactly `{s}`", .{ at.read, apt_read_gate });
        if (std.mem.indexOf(u8, read_b, "      enabled: ${{ steps.gate.outputs.enabled }}\n") == null) try add(a, f, "the job `{s}` does not output the gate's `enabled`, which the index and the write wait on", .{at.read});
        try aptGuarded(a, f, at.read, read_b, &.{ "run: tool/apt-publish assume ", "run: tool/apt-publish read ", try std.fmt.allocPrint(a, "name: apt-current{s}\n", .{at.suffix}) });
        if (!precedes(read_b, "tool/apt-publish gate ", "tool/apt-publish assume ") or !precedes(read_b, "tool/apt-publish assume ", "tool/apt-publish read ")) try add(a, f, "the job `{s}` does not gate, then assume the role, then read (in that order)", .{at.read});

        // the index: the key, no role
        if (!hasLineEnd(index_b, "        run: " ++ apt_index_gate)) try add(a, f, "the job `{s}` does not gate on the key and the read with exactly `{s}`", .{ at.index, apt_index_gate });
        const read_env = try std.fmt.allocPrint(a, "          READ_ENABLED: ${{{{ needs.{s}.outputs.enabled }}}}\n", .{at.read});
        if (std.mem.indexOf(u8, index_b, read_env) == null) try add(a, f, "the job `{s}` does not take the read's `enabled` for its gate (`READ_ENABLED: ${{{{ needs.{s}.outputs.enabled }}}}`)", .{ at.index, at.read });
        if (std.mem.indexOf(u8, index_b, "      signed: ${{ steps.sign.outputs.signed }}\n") == null) try add(a, f, "the job `{s}` does not output `signed` of its signing step, which the write waits on", .{at.index});
        if (std.mem.count(u8, index_b, "secrets.APT_GPG_PRIVATE_KEY") != 2 or std.mem.count(u8, index_b, "secrets.APT_GPG_PASSPHRASE") != 1)
            try add(a, f, "the job `{s}` reads the signing key other than twice (the gate's test and the signing step) or the passphrase other than once", .{at.index});
        if (stepWith(index_b, "run: tool/apt-publish sign ")) |sign_step| {
            if (std.mem.indexOf(u8, sign_step, "        id: sign\n") == null) try add(a, f, "the signing step of `{s}` is not `id: sign`, so its `signed` would not reach the write", .{at.index});
            if (std.mem.indexOf(u8, sign_step, "          APT_GPG_PRIVATE_KEY: ${{ secrets.APT_GPG_PRIVATE_KEY }}\n") == null or std.mem.indexOf(u8, sign_step, "          APT_GPG_PASSPHRASE: ${{ secrets.APT_GPG_PASSPHRASE }}\n") == null)
                try add(a, f, "the signing step of `{s}` does not take the key and the passphrase from the secrets (`APT_GPG_PRIVATE_KEY`, `APT_GPG_PASSPHRASE`), in its own environment", .{at.index});
        } else try add(a, f, "the job `{s}` does not sign (`tool/apt-publish sign`)", .{at.index});
        try aptGuarded(a, f, at.index, index_b, &.{ "run: tool/apt-publish index ", "run: tool/apt-publish sign ", try std.fmt.allocPrint(a, "name: apt-current{s}\n", .{at.suffix}), try std.fmt.allocPrint(a, "name: apt-next{s}\n", .{at.suffix}), "name: release-dist\n" });
        if (!precedes(index_b, "tool/apt-publish gate ", "tool/apt-publish index ") or !precedes(index_b, "tool/apt-publish index ", "tool/apt-publish sign ")) try add(a, f, "the job `{s}` does not gate, then merge the .debs into the index, then sign (in that order)", .{at.index});
        if (std.mem.indexOf(u8, index_b, "release-unsigned") != null) try add(a, f, "the job `{s}` reads `release-unsigned`: the .debs it indexes are the signed and verified ones (`release-dist`)", .{at.index});

        // the write: the role, no key
        if (!hasNeed(wr, at.read) or !hasNeed(wr, at.index)) try add(a, f, "the job `{s}` does not wait for `{s}` and `{s}`", .{ at.write, at.read, at.index });
        if (!hasLineEnd(write_b, "        run: " ++ apt_write_gate)) try add(a, f, "the job `{s}` does not gate on the settings and the signed index with exactly `{s}`", .{ at.write, apt_write_gate });
        const signed_env = try std.fmt.allocPrint(a, "          INDEX_SIGNED: ${{{{ needs.{s}.outputs.signed }}}}\n", .{at.index});
        if (std.mem.indexOf(u8, write_b, signed_env) == null) try add(a, f, "the job `{s}` does not take the index's `signed` for its gate (`INDEX_SIGNED: ${{{{ needs.{s}.outputs.signed }}}}`)", .{ at.write, at.index });
        if (std.mem.indexOf(u8, write_b, "      conflict: ${{ steps.put.outputs.conflict }}\n") == null) try add(a, f, "the job `{s}` does not output the `conflict` of its write step, which the next attempt waits on", .{at.write});
        try aptGuarded(a, f, at.write, write_b, &.{ "run: tool/apt-publish assume ", "run: tool/apt-publish write ", try std.fmt.allocPrint(a, "name: apt-next{s}\n", .{at.suffix}), "name: release-dist\n" });
        if (!precedes(write_b, "tool/apt-publish gate ", "tool/apt-publish assume ") or !precedes(write_b, "tool/apt-publish assume ", "tool/apt-publish write ")) try add(a, f, "the job `{s}` does not gate, then assume the role, then write (in that order)", .{at.write});
        const write_end = " --out \"$GITHUB_OUTPUT\"";
        if (at.last) {
            if (!hasLineEnd(write_b, write_end ++ " --last")) try add(a, f, "the last attempt (`{s}`) does not write with `--last`: a lost write there must fail the job, not hand over to an attempt that does not exist", .{at.write});
        } else {
            if (std.mem.indexOf(u8, write_b, "--last") != null) try add(a, f, "the job `{s}` writes with `--last` but another attempt follows it", .{at.write});
            if (!hasLineEnd(write_b, write_end)) try add(a, f, "the job `{s}` does not write with `--out \"$GITHUB_OUTPUT\"`, so its `conflict` would not reach the next attempt", .{at.write});
        }
        if (std.mem.indexOf(u8, write_b, "release-unsigned") != null) try add(a, f, "the job `{s}` reads `release-unsigned`: the .debs it uploads are the signed and verified ones (`release-dist`)", .{at.write});
    }
}

/// Every step of the job `jb` that holds one of `markers` carries the gate's guard: a job whose settings are not made does nothing there.
fn aptGuarded(a: std.mem.Allocator, f: *Findings, job: []const u8, jb: []const u8, markers: []const []const u8) !void {
    for (markers) |m| {
        const step = stepWith(jb, m) orelse {
            try add(a, f, "the job `{s}` has no step with `{s}`", .{ job, std.mem.trim(u8, m, " \n") });
            continue;
        };
        if (std.mem.indexOf(u8, step, apt_guard) == null) try add(a, f, "the step with `{s}` in the job `{s}` does not run only behind the gate (`if: steps.gate.outputs.enabled == 'true'`)", .{ std.mem.trim(u8, m, " \n"), job });
    }
}

/// Everything wrong with `wf` (release.yml), given the dotslash file of the pinned buck2 and ci.yml.
pub fn checkRelease(a: std.mem.Allocator, wf: []const u8, dotslash: []const u8, ci_yml: []const u8) !Findings {
    var f = Findings.init(a);
    const text = try body(a, wf);
    try sigstoreNames(a, &f, text);

    // Actions: every `uses:` pinned to a commit, but the call of ci.yml; a checkout drops its credentials.
    try wc.noContinueOnError(a, &f, text);
    try wc.noInlineContext(a, &f, text);
    const uses = try wc.pinnedUses(a, &f, text, &.{ ci_call, beta_call, farm_action });
    if (uses == 0) try add(a, &f, "no `uses:` line found (this parser is blind)", .{});
    if (std.mem.count(u8, text, "actions/checkout@") != std.mem.count(u8, text, "persist-credentials: false"))
        try add(a, &f, "a checkout keeps the token in the checkout (`persist-credentials: false` is missing)", .{});

    // Triggers: a push to main and nothing else. A pull request runs ci.yml alone (build and unit tests); the stages of the release run after the merge.
    // The concurrency is one group for every push (a run waits for the one before it) and nothing cancels a running release.
    const on = try triggers(a, text);
    var has_push = false;
    for (on) |k| {
        if (std.mem.eql(u8, k, "push")) has_push = true else try add(a, &f, "the workflow is triggered by `{s}`: only a push to main is allowed (a pull request runs build and unit tests in ci.yml; the beta, the gamma and the release run after the merge)", .{k});
    }
    if (!has_push or !wc.hasLine(text, "    branches: [main]")) try add(a, &f, "the workflow is not triggered by a push to main (`on: push: branches: [main]`)", .{});
    for ([_][]const u8{ "pull_request_target", "workflow_run", "workflow_dispatch", "schedule:" }) |bad| {
        if (std.mem.indexOf(u8, text, bad) != null) try add(a, &f, "`{s}` appears in the workflow", .{bad});
    }
    if (!wc.hasLine(text, "  group: release-${{ github.event_name == 'push' && 'push' || github.run_id }}") or !wc.hasLine(text, "  cancel-in-progress: false"))
        try add(a, &f, "the workflow's concurrency is not `group: release-${{{{ github.event_name == 'push' && 'push' || github.run_id }}}}` with `cancel-in-progress: false`: the pushes are serialized and a running release is never cancelled", .{});
    // The secrets: the release bot's private key (read by the steps of `tag`, `bump` and `tap` that mint a token) and the apt signing key (read by the signing step of
    // each `apt-index` job). Any other `secrets.` is refused.
    const bot_key_refs = std.mem.count(u8, text, "secrets.RELEASE_BOT_PRIVATE_KEY }}");
    const gpg_refs = std.mem.count(u8, text, "secrets.APT_GPG_");
    if (std.mem.count(u8, text, "secrets.") != bot_key_refs + gpg_refs) try add(a, &f, "the workflow reads a secret other than the release bot's key and the apt signing key", .{});
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
    // The release bot's key is an environment secret of `release_environment` (the owner restricts it to main as a setup step): exactly the jobs that read `RELEASE_BOT_*` declare it. The apt
    // signing key is a secret of `apt_signing_environment`, read by the `apt-index` jobs alone, and the apt publish role is assumed in `apt_publish_environment` by the
    // `apt-deploy-*` jobs alone. No other job declares an environment.
    for (jobs) |*j| {
        const jt = try j.text(a);
        const reads_bot = std.mem.indexOf(u8, jt, "RELEASE_BOT") != null;
        const reads_gpg = std.mem.indexOf(u8, jt, "secrets.APT_GPG_") != null;
        if (reads_bot) {
            if (j.environment == null or !std.mem.eql(u8, j.environment.?, release_environment))
                try add(a, &f, "the job `{s}` reads `RELEASE_BOT_*` but does not declare `environment: {s}` (it has {s})", .{ j.name, release_environment, j.environment orelse "none" });
        } else if (reads_gpg) {
            if (j.environment == null or !std.mem.eql(u8, j.environment.?, apt_signing_environment))
                try add(a, &f, "the job `{s}` reads the apt signing key (`APT_GPG_*`) but does not declare `environment: {s}` (it has {s})", .{ j.name, apt_signing_environment, j.environment orelse "none" });
        } else if (isAptDeploy(j.name)) {
            if (j.environment == null or !std.mem.eql(u8, j.environment.?, apt_publish_environment))
                try add(a, &f, "the job `{s}` assumes the apt publish role but does not declare `environment: {s}` (it has {s})", .{ j.name, apt_publish_environment, j.environment orelse "none" });
        } else if (j.environment) |e| {
            try add(a, &f, "the job `{s}` declares `environment: {s}`; only the jobs that read `RELEASE_BOT_*` (`tag`, `bump`, `tap`), the apt signing key (`apt-index*`) or assume the apt publish role (`apt-deploy-*`) declare one", .{ j.name, e });
        }
    }
    // `permission-contents: write` and `permission-pull-requests: write` are inputs of the App-token action, not grants of a job's token: they are counted by their own rules below.
    if (std.mem.count(u8, text, ": write") - std.mem.count(u8, text, "permission-contents: write") - std.mem.count(u8, text, "permission-pull-requests: write") != writes) try add(a, &f, "a `: write` is granted outside a job's `permissions:` block", .{});
    // Jobs that only read hold `contents: read` alone (verify also reads attestations).
    for ([_][]const u8{ "archive", "build-cli", "plan", "tap", "apt-index", "apt-index-2", "apt-index-3" }) |name| {
        const j = jobNamed(jobs, name) orelse continue;
        if (j.perms.items.len != 1 or permLevel(j, "contents") == null or !std.mem.eql(u8, permLevel(j, "contents").?, "read"))
            try add(a, &f, "the job `{s}` is not `contents: read` alone", .{name});
    }
    if (jobNamed(jobs, "verify")) |j| {
        const ok_perms = j.perms.items.len == 2 and permLevel(j, "contents") != null and std.mem.eql(u8, permLevel(j, "contents").?, "read") and permLevel(j, "attestations") != null and std.mem.eql(u8, permLevel(j, "attestations").?, "read");
        if (!ok_perms) try add(a, &f, "the job `verify` is not `contents: read` and `attestations: read` alone", .{});
    }
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
    // The token is minted in `tag` (for this repository), in `bump` (for the internal one) and in `tap` (for the tap), once each, and nowhere else; the key, the three
    // token outputs and the permission inputs (one in `tag`, two in `bump`, two in `tap`) appear nowhere else.
    if (std.mem.count(u8, text, app_token_action ++ "@") != 3) try add(a, &f, "`actions/create-github-app-token` is used other than three times, in `tag`, `bump` and `tap`", .{});
    if (std.mem.count(u8, text, "secrets.RELEASE_BOT_PRIVATE_KEY") != 3 or std.mem.count(u8, text, "steps.bot.outputs.token") != 1 or std.mem.count(u8, text, "steps.bump_bot.outputs.token") != 1 or std.mem.count(u8, text, "steps.tap_bot.outputs.token") != 1 or std.mem.count(u8, text, "permission-") != 5)
        try add(a, &f, "the release bot's key, token or permission input appears other than in `tag`, `bump` and `tap`", .{});
    try checkTap(a, &f, jobs, text);
    try checkApt(a, &f, jobs, text);
    if (jobNamed(jobs, "bump")) |j| {
        // The job's own token only reads; the write is the release bot's token for the internal repository, minted by one step with exact inputs and used by one step.
        if (j.perms.items.len != 1 or permLevel(j, "contents") == null or !std.mem.eql(u8, permLevel(j, "contents").?, "read"))
            try add(a, &f, "the job `bump` is not `contents: read` alone: it writes to the internal repository with the release bot's token, not its own", .{});
        if (j.if_expr == null or !std.mem.eql(u8, j.if_expr.?, publish_if)) try add(a, &f, "the job `bump` is not under its exact `if:` ({s})", .{publish_if});
        for (bump_needs) |need| {
            if (!hasNeed(j, need)) try add(a, &f, "the job `bump` does not wait for `{s}` (it opens the pull request after the tag exists and the release is published)", .{need});
        }
        const jb = jobBlock(text, "bump");
        const checked = std.mem.indexOf(u8, jb, bump_check_step);
        if (checked == null) try add(a, &f, "the job `bump` does not check, in a step of its own, that the internal repository is named (`tool/release bump-check --internal-repo \"$INTERNAL_REPO\"`)", .{});
        const mint = std.mem.indexOf(u8, jb, bump_mint);
        if (mint == null) try add(a, &f, "the job `bump` does not mint the release bot's token with exactly the pinned inputs of `actions/create-github-app-token` (app-id, private-key, owner, repositories from the BUMP_REPOSITORY variable, permission-contents, permission-pull-requests)", .{});
        const use = std.mem.indexOf(u8, jb, bump_step_env);
        if (use == null) try add(a, &f, "the step of `bump` that runs `tool/release bump-internal` does not take the bot's token as its GH_TOKEN (`steps.bump_bot.outputs.token`)", .{});
        if (mint != null and use != null and mint.? > use.?) try add(a, &f, "the job `bump` uses the bot's token before the step that mints it", .{});
        if (checked != null and mint != null and checked.? > mint.?) try add(a, &f, "the job `bump` mints the bot's token before it checks that the internal repository is named", .{});
        if (std.mem.count(u8, jb, "steps.bump_bot.outputs.token") != 1) try add(a, &f, "the job `bump` uses the bot's token other than once, in the bump step", .{});
        if (std.mem.indexOf(u8, jb, "github.token") != null or std.mem.indexOf(u8, jb, "secrets.GITHUB_TOKEN") != null) try add(a, &f, "the job `bump` uses GITHUB_TOKEN, which holds no write to the internal repository", .{});
        if (std.mem.count(u8, jb, "secrets.") != 1) try add(a, &f, "the job `bump` reads other than the one secret of the release bot's key", .{});
        if (std.mem.indexOf(u8, jb, bump_internal_env) == null) try add(a, &f, "the job `bump` does not name the internal repository as the owner's own and the BUMP_REPOSITORY variable (`INTERNAL_REPO: ${{{{ github.repository_owner }}}}/${{{{ vars.BUMP_REPOSITORY }}}}`)", .{});
        if (use) |u| {
            const end = std.mem.indexOfScalarPos(u8, jb, u + bump_step_env.len, '\n') orelse jb.len;
            const run_line = jb[u + bump_step_env.len .. end];
            for (bump_args) |arg| {
                if (std.mem.indexOf(u8, run_line, arg) == null) try add(a, &f, "the bump step does not pass {s}", .{arg});
            }
        }
    }
    // Nothing waits for `bump` or `tap`: a failed bump or tap is red and un-releases nothing.
    for (jobs) |*j| {
        if (hasNeed(j, "bump")) try add(a, &f, "the job `{s}` waits for `bump`: nothing may, a failed bump un-releases nothing", .{j.name});
        if (hasNeed(j, "tap")) try add(a, &f, "the job `{s}` waits for `tap`: nothing may, a failed tap un-releases nothing", .{j.name});
    }
    // The race of two pushes that plan the same number: the tag job (alone in its concurrency group) settles it, and what comes after takes the tag from its outputs.
    if (jobNamed(jobs, "tag")) |_| {
        const jt = jobBlock(text, "tag");
        if (std.mem.indexOf(u8, jt, tag_outputs) == null) try add(a, &f, "the job `tag` does not output `superseded`, `tag` and `number` of its step `settle`, which publish, site and bump use", .{});
        if (std.mem.indexOf(u8, jt, "        id: settle\n") == null or std.mem.indexOf(u8, jt, " --sha \"$GITHUB_SHA\" --output \"$GITHUB_OUTPUT\"") == null)
            try add(a, &f, "the step of `tag` that runs `tool/release tag` is not `id: settle` with `--output \"$GITHUB_OUTPUT\"`: its outputs would not reach the jobs after it", .{});
    }
    for ([_][]const u8{ "publish", "bump", "site" }) |name| {
        const j = jobNamed(jobs, name) orelse continue;
        const jb = jobBlock(text, name);
        if (std.mem.indexOf(u8, jb, tag_env_final) == null) try add(a, &f, "the job `{s}` does not take its tag from the tag job (`TAG: ${{{{ needs.tag.outputs.tag }}}}`)", .{name});
        if (std.mem.indexOf(u8, jb, "needs.plan.outputs.tag") != null) try add(a, &f, "the job `{s}` reads the plan's tag, which a push that landed meanwhile may have taken: it uses `needs.tag.outputs.tag`", .{name});
        if (j.if_expr == null or std.mem.indexOf(u8, j.if_expr.?, superseded_clause) == null) try add(a, &f, "the job `{s}` does not skip a superseded run (`{s}` in its `if:`)", .{ name, superseded_clause });
    }
    // The jobs that sign, tag, publish or bump run only for a push to main of a commit the plan released, not a fork: a pull request makes none of them.
    if (jobNamed(jobs, "tag")) |j| {
        if (j.if_expr == null or !std.mem.eql(u8, j.if_expr.?, tag_if)) try add(a, &f, "the job `tag` is not under its exact `if:` ({s})", .{tag_if});
        if (j.group == null or !std.mem.eql(u8, j.group.?, "release") or j.cancel == null or !std.mem.eql(u8, j.cancel.?, "false"))
            try add(a, &f, "the job `tag` is not in the concurrency group `release` with `cancel-in-progress: false` (exactly `release`, never the workflow's own group `release-push`: a job in its run's group waits for itself and the run deadlocks)", .{});
    }
    if (jobNamed(jobs, "publish")) |j| {
        const l = permLevel(j, "contents");
        if (l == null or !std.mem.eql(u8, l.?, "write")) try add(a, &f, "the job `publish` does not hold `contents: write`", .{});
        if (j.if_expr == null or !std.mem.eql(u8, j.if_expr.?, publish_if)) try add(a, &f, "the job `publish` is not under its exact `if:` ({s})", .{publish_if});
    }
    for ([_][]const u8{ "attest", "verify" }) |name| {
        if (jobNamed(jobs, name)) |j| {
            if (j.if_expr == null or !std.mem.eql(u8, j.if_expr.?, tag_if)) try add(a, &f, "the job `{s}` is not under its exact `if:` ({s}): it must not run for a pull request", .{ name, tag_if });
        }
    }
    // gate and tool have no `if:`: a skipped job makes the plan, which waits for both, skip too, and a release would then not happen with every check green.
    for ([_][]const u8{ "gate", "tool" }) |name| {
        if (jobNamed(jobs, name)) |j| {
            if (j.if_expr != null) try add(a, &f, "the job `{s}` has an `if:` ({s}): a skipped gate or tool skips the plan and every stage after it, silently", .{ name, j.if_expr.? });
        }
    }
    // attest: the signature and the attestation, the only job with `id-token` and `attestations` write besides the farm's; no buck2, and no action but the few it needs.
    if (jobNamed(jobs, "attest")) |j| {
        for ([_][]const u8{ "id-token", "attestations" }) |scope| {
            const l = permLevel(j, scope);
            if (l == null or !std.mem.eql(u8, l.?, "write")) try add(a, &f, "the job `attest` does not hold `{s}: write`, which the signature and the attestation need", .{scope});
        }
        const jt = try j.text(a);
        if (std.mem.count(u8, jt, "actions/attest-build-provenance@") != 1) try add(a, &f, "the job `attest` does not attest (`actions/attest-build-provenance` once)", .{});
        if (std.mem.count(u8, jt, cosign_action ++ "@") != 1) try add(a, &f, "the job `attest` does not install cosign (`sigstore/cosign-installer` once, before it signs)", .{});
        if (std.mem.indexOf(u8, jt, "tool/release sign --dist dist --dry false") == null) try add(a, &f, "the job `attest` does not sign (`tool/release sign --dist dist --dry false`)", .{});
        if (std.mem.indexOf(u8, jt, "--dry true") != null) try add(a, &f, "the job `attest` runs a dry signing", .{});
        // the attested files are the archive, the tarballs, the .debs and SHA256SUMS: the subject glob names them all
        if (std.mem.indexOf(u8, jt, "subject-path: |\ndist/buildrules-*.tar.gz\ndist/buildrules_*.deb\ndist/SHA256SUMS\n") == null) try add(a, &f, "the job `attest` does not attest `dist/buildrules-*.tar.gz` (the archive and the three tarballs), `dist/buildrules_*.deb` (the two .debs) and `dist/SHA256SUMS`", .{});
        // sign comes before the attestation, and both before the upload of what verify and publish read
        const i_sign = std.mem.indexOf(u8, jt, "tool/release sign ");
        const i_att = std.mem.indexOf(u8, jt, "actions/attest-build-provenance@");
        const i_up = std.mem.indexOf(u8, jt, "name: release-dist");
        if (i_sign == null or i_att == null or i_up == null or i_sign.? > i_att.? or i_att.? > i_up.?) try add(a, &f, "the job `attest` does not sign, then attest, then upload `release-dist` (in that order)", .{});
        for (j.lines.items) |l| {
            if (usesRepo(l)) |repo| {
                var ok = false;
                for (attest_actions) |w| {
                    if (std.mem.eql(u8, repo, w)) ok = true;
                }
                if (!ok) try add(a, &f, "the job `attest` holds a write scope and uses {s}", .{repo});
            }
            if (std.mem.indexOf(u8, l, "buck2") != null) try add(a, &f, "the job `attest` holds a write scope and runs buck2: {s}", .{l});
        }
    }
    if (std.mem.count(u8, text, "actions/attest-build-provenance@") != 1) try add(a, &f, "`actions/attest-build-provenance` is used other than once, in `attest`", .{});
    // cosign is installed twice: to sign in `attest`, to check the signatures in `verify`.
    if (std.mem.count(u8, text, cosign_action ++ "@") != 2) try add(a, &f, "`sigstore/cosign-installer` is used other than twice, in `attest` and in `verify`", .{});
    // every install of cosign names its release: `with:` and `cosign-release: 'v3.0.6'` are the two lines after the `uses:` line
    {
        var lines = std.ArrayList([]const u8).init(a);
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| try lines.append(l);
        for (lines.items, 0..) |l, i| {
            const repo = usesRepo(l) orelse continue;
            if (!std.mem.eql(u8, repo, cosign_action)) continue;
            const named = i + 2 < lines.items.len and std.mem.eql(u8, std.mem.trim(u8, lines.items[i + 1], " "), "with:") and
                std.mem.eql(u8, std.mem.trim(u8, lines.items[i + 2], " "), "cosign-release: '" ++ cosign_release ++ "'");
            if (!named) try add(a, &f, "`sigstore/cosign-installer` does not name `cosign-release: '" ++ cosign_release ++ "'` (the retry of `release verify` depends on the stderr of that release)", .{});
        }
    }
    if (jobNamed(jobs, "verify")) |j| {
        if (std.mem.count(u8, try j.text(a), cosign_action ++ "@") != 1) try add(a, &f, "the job `verify` does not install cosign, which checks the signatures", .{});
    }
    // No dry form of anything remains: the plan, the signing and the verification are each told `--dry false`, and nothing is told `--dry true`.
    if (std.mem.count(u8, text, "--dry false") != 3 or std.mem.count(u8, text, "--dry true") != 0)
        try add(a, &f, "the `--dry` flags are not exactly: false in `plan`, `attest` and `verify`, and none true (a pull request does not run this workflow)", .{});

    // The order: gate -> plan -> build-cli -> beta -> gamma -> archive -> attest -> verify -> tag -> publish, and a release only for a commit the plan released.
    for (order) |pair| {
        if (jobNamed(jobs, pair[0])) |j| {
            if (!hasNeed(j, pair[1])) try add(a, &f, "the job `{s}` does not wait for `{s}` (order: gate -> plan -> build-cli -> beta -> gamma -> archive -> attest -> verify -> tag -> publish)", .{ pair[0], pair[1] });
        }
    }
    for ([_][]const u8{ "build-cli", "archive", "site" }) |name| {
        if (jobNamed(jobs, name)) |j| {
            if (j.if_expr == null or std.mem.indexOf(u8, j.if_expr.?, released_clause) == null) try add(a, &f, "the job `{s}` runs even when the plan released nothing (its `if:` lacks `{s}`)", .{ name, released_clause });
        }
    }
    // beta and gamma run for a released commit only, with that `if:` alone: once the plan has decided, nothing else skips them.
    for ([_][]const u8{ "build-cli", "beta", "gamma", "archive" }) |name| {
        if (jobNamed(jobs, name)) |j| {
            if (j.if_expr == null or !std.mem.eql(u8, j.if_expr.?, released_if)) try add(a, &f, "the job `{s}` is not under the `if:` {s} alone: the stage can be skipped for a commit the plan released", .{ name, released_if });
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
    // The plan only reads: it decides, and creates nothing; it is the one place RELEASE_FREEZE is read, and it is never a dry run.
    if (jobNamed(jobs, "plan")) |j| {
        if (j.if_expr != null) try add(a, &f, "the job `plan` has an `if:`", .{});
        const jt = try j.text(a);
        if (std.mem.indexOf(u8, jt, "FREEZE: ${{ vars.RELEASE_FREEZE }}") == null or std.mem.indexOf(u8, jt, " --freeze \"$FREEZE\"") == null)
            try add(a, &f, "the job `plan` does not pass RELEASE_FREEZE to the plan (`FREEZE: ${{{{ vars.RELEASE_FREEZE }}}}` and `--freeze \"$FREEZE\"`)", .{});
        if (std.mem.indexOf(u8, jt, " --dry false --output") == null or std.mem.indexOf(u8, jt, "DRY") != null)
            try add(a, &f, "the job `plan` is not told it is a real run (`--dry false`, and no `DRY` variable: a pull request does not run this workflow)", .{});
        if (std.mem.indexOf(u8, jt, "number: ${{ steps.version.outputs.number }}") == null) try add(a, &f, "the job `plan` does not output the version number (`number: ${{{{ steps.version.outputs.number }}}}`), which `build-cli` stamps", .{});
        // A commit whose release is complete builds nothing: the plan says so (`complete`), asking GitHub about the release of the repository it runs in, with its own read-only token.
        if (std.mem.indexOf(u8, jt, "complete: ${{ steps.version.outputs.complete }}") == null) try add(a, &f, "the job `plan` does not output `complete` (`complete: ${{{{ steps.version.outputs.complete }}}}`), which build-cli, beta, gamma and archive are gated on", .{});
        if (std.mem.indexOf(u8, jt, " --repo \"$GITHUB_REPOSITORY\" ") == null) try add(a, &f, "the job `plan` is not told the repository (`--repo \"$GITHUB_REPOSITORY\"`), so it cannot tell whether a release is complete", .{});
        if (std.mem.indexOf(u8, jt, "GH_TOKEN: ${{ github.token }}") == null) try add(a, &f, "the job `plan` has no `GH_TOKEN: ${{{{ github.token }}}}` (its own read-only token) for the question it asks GitHub", .{});
    }
    if (std.mem.count(u8, text, "RELEASE_FREEZE") != 1) try add(a, &f, "RELEASE_FREEZE is read other than once, in `plan`: a freeze is decided in one place", .{});
    if (std.mem.indexOf(u8, text, "github.event.pull_request") != null or std.mem.indexOf(u8, text, "'pull_request'") != null)
        try add(a, &f, "the workflow names a pull request (`github.event.pull_request`, `'pull_request'`): only a push to main runs it, and the candidate is `github.sha`", .{});
    // The commit: the jobs that test it check out and name it (CANDIDATE); the jobs that write name $GITHUB_SHA.
    for (candidate_jobs) |name| {
        const j = jobNamed(jobs, name) orelse continue;
        const jb = jobBlock(text, name);
        if (std.mem.indexOf(u8, jb, candidate_env) == null) try add(a, &f, "the job `{s}` does not name the commit as `CANDIDATE: {s}`", .{ name, candidate_expr });
        if (std.mem.indexOf(u8, jb, "actions/checkout@") != null and std.mem.count(u8, jb, "actions/checkout@") != std.mem.count(u8, jb, candidate_ref))
            try add(a, &f, "the checkout of the job `{s}` is not of `ref: {s}`", .{ name, candidate_expr });
        _ = j;
    }
    for ([_][]const u8{ "tool", "build-cli", "gamma" }) |name| {
        if (jobNamed(jobs, name) == null) continue;
        const jb = jobBlock(text, name);
        // gamma has a second checkout, of the farm-connect action
        const checkouts = std.mem.count(u8, jb, "actions/checkout@") - (if (std.mem.eql(u8, name, "gamma")) @as(usize, 1) else 0);
        if (std.mem.count(u8, jb, candidate_ref) != checkouts) try add(a, &f, "the checkout of the job `{s}` is not of `ref: {s}`", .{ name, candidate_expr });
    }
    if (jobNamed(jobs, "gamma")) |_| {
        const jb = jobBlock(text, "gamma");
        if (std.mem.indexOf(u8, jb, candidate_env) == null or std.mem.indexOf(u8, jb, "--candidate \"$CANDIDATE\"") == null) try add(a, &f, "the job `gamma` does not build the pushed commit as the candidate (`--candidate \"$CANDIDATE\"`)", .{});
    }
    for ([_][]const u8{ "tag", "publish", "bump", "site" }) |name| {
        if (jobNamed(jobs, name) == null) continue;
        const jb = jobBlock(text, name);
        if (std.mem.indexOf(u8, jb, "CANDIDATE") != null or std.mem.indexOf(u8, jb, "--sha \"$GITHUB_SHA\"") == null) try add(a, &f, "the job `{s}` must name `--sha \"$GITHUB_SHA\"` and not the candidate variable", .{name});
    }
    // The archive and the verifies are of the commit, and no step of the jobs before the tag names the tag by a ref.
    for ([_][]const u8{ "archive", "verify", "build-cli" }) |name| {
        if (jobNamed(jobs, name)) |j| {
            const jt = try j.text(a);
            if (std.mem.indexOf(u8, jt, "refs/tags/") != null) try add(a, &f, "the job `{s}` reads a tag by ref (`refs/tags/`): the tag does not exist yet, the archive is of the commit", .{name});
        }
    }
    for ([_][]const u8{ "archive", "verify" }) |name| {
        if (jobNamed(jobs, name)) |j| {
            const jt = try j.text(a);
            if (std.mem.indexOf(u8, jt, "--sha \"$CANDIDATE\"") == null) try add(a, &f, "the job `{s}` does not pass `--sha \"$CANDIDATE\"` (the archive is of the tested commit)", .{name});
        }
    }
    if (jobNamed(jobs, "gate")) |j| {
        if (j.uses == null or !std.mem.eql(u8, j.uses.?, ci_call)) try add(a, &f, "the job `gate` does not call {s}", .{ci_call});
        if (j.perms.items.len != 1 or !std.mem.eql(u8, j.perms.items[0].scope, "contents") or !std.mem.eql(u8, j.perms.items[0].level, "read"))
            try add(a, &f, "the job `gate` is not `contents: read` alone", .{});
    }
    // beta: the call of beta.yml with the command line build-cli built, with read access and the farm leg's token only.
    if (jobNamed(jobs, "beta")) |j| {
        if (j.uses == null or !std.mem.eql(u8, j.uses.?, beta_call)) try add(a, &f, "the job `beta` does not call {s}", .{beta_call});
        if (j.perms.items.len != 2 or permLevel(j, "contents") == null or !std.mem.eql(u8, permLevel(j, "contents").?, "read") or permLevel(j, "id-token") == null or !std.mem.eql(u8, permLevel(j, "id-token").?, "write"))
            try add(a, &f, "the job `beta` is not `contents: read` and `id-token: write` alone", .{});
        const jt = try j.text(a);
        if (!std.mem.endsWith(u8, jt, "\nwith:\ncli-bins-artifact: release-cli-bins\ncli-artifact: release-cli-bin")) try add(a, &f, "the job `beta` does not run the command line that `build-cli` built (`with: cli-bins-artifact: release-cli-bins`, `cli-artifact: release-cli-bin`)", .{});
    }
    // gamma: our own repositories on the farm. It holds the farm's token and no write access to the repository, takes the farm-connect
    // action from the repository and commit that variables name (the checkout is verified before the action runs), and runs no buck2 itself.
    if (jobNamed(jobs, "gamma")) |j| {
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
    // build-cli: the three binaries, stamped with the planned version, in one directory, packaged as the three tarballs; the linux-x86_64 binary is handed to the beta as the file it runs.
    if (jobNamed(jobs, "build-cli")) |j| {
        const jt = try j.text(a);
        if (!hasNeed(j, "tool")) try add(a, &f, "the job `build-cli` does not wait for `tool`, which hands on the buck2 it runs", .{});
        if (std.mem.indexOf(u8, jt, "NUMBER: ${{ needs.plan.outputs.number }}") == null) try add(a, &f, "the job `build-cli` does not take the planned version from the plan (`NUMBER: ${{{{ needs.plan.outputs.number }}}}`)", .{});
        if (!hasLineEnd(jt, buildBinaries("cli-bins"))) try add(a, &f, "the job `build-cli` does not build //cli:release_binaries with the planned version stamped in (`-c \"buildrules.release_version=$NUMBER\"`, `--out cli-bins`)", .{});
        if (!hasLineEnd(jt, "tool/release package-all --version \"$NUMBER\" --bins cli-bins --license LICENSE --out cli-dist --native linux-x86_64"))
            try add(a, &f, "the job `build-cli` does not package the three tarballs of the stamped build (`package-all --version \"$NUMBER\" --bins cli-bins`, running only the linux-x86_64 binary)", .{});
        if (!hasLineEnd(jt, "tool/release debs --version \"$NUMBER\" --bins cli-bins --channels tool/channels --packaging packaging/deb --out cli-dist"))
            try add(a, &f, "the job `build-cli` does not package the two .debs from the same binaries (`debs --version \"$NUMBER\" --bins cli-bins --channels tool/channels --packaging packaging/deb --out cli-dist`)", .{});
        if (std.mem.indexOf(u8, jt, "name: channel-tools\npath: tool\n") == null) try add(a, &f, "the job `build-cli` does not download the tools of the channels (`channel-tools`) into `tool`", .{});
        const i_pkg = std.mem.indexOf(u8, jt, "tool/release package-all ");
        const i_deb = std.mem.indexOf(u8, jt, "tool/release debs ");
        if (i_pkg != null and i_deb != null and i_deb.? < i_pkg.?) try add(a, &f, "the job `build-cli` makes the .debs before the tarballs", .{});
        if (std.mem.indexOf(u8, jt, "name: release-cli-tarballs\npath: cli-dist\n") == null) try add(a, &f, "the job `build-cli` does not upload the three tarballs and the two .debs as the artifact `release-cli-tarballs`", .{});
        if (std.mem.indexOf(u8, jt, "name: release-cli-bin\npath: cli-bins/linux-x86_64/buildrules\n") == null) try add(a, &f, "the job `build-cli` does not upload the linux-x86_64 binary it packaged as the artifact `release-cli-bin`", .{});
        if (std.mem.indexOf(u8, jt, "name: release-cli-bins\npath: cli-bins\n") == null) try add(a, &f, "the job `build-cli` does not upload the directory of the three binaries it packaged as the artifact `release-cli-bins` (the native beta legs run two of them)", .{});
    }
    // archive: the tarballs the build made, the file the beta ran, and the check that the tarball holds that very file.
    if (jobNamed(jobs, "archive")) |j| {
        const jt = try j.text(a);
        if (std.mem.indexOf(u8, jt, "name: release-cli-tarballs\npath: dist\n") == null) try add(a, &f, "the job `archive` does not download the tarballs (`release-cli-tarballs`) into `dist`", .{});
        if (std.mem.indexOf(u8, jt, "name: release-cli-bin\npath: ran\n") == null) try add(a, &f, "the job `archive` does not download the file the beta ran (`release-cli-bin`) into `ran`", .{});
        if (!hasLineEnd(jt, "tool/release record --tarball \"dist/buildrules-cli-$NUMBER-linux-x86_64.tar.gz\" --ran-binary ran/buildrules --out tested"))
            try add(a, &f, "the job `archive` does not check that the linux-x86_64 tarball holds the file the beta ran (`record --ran-binary ran/buildrules`)", .{});
        if (!hasLineEnd(jt, "tool/release tested --dist dist --tested tested --targets linux-x86_64")) try add(a, &f, "the job `archive` does not hold the attested tarballs to the ones the beta ran (`tested --targets linux-x86_64`)", .{});
        if (std.mem.indexOf(u8, jt, "name: release-unsigned\npath: dist\n") == null) try add(a, &f, "the job `archive` does not upload `dist` as the artifact `release-unsigned`", .{});
        // the order of its tool: archive, record, tested, sums
        const markers = [_][]const u8{ "tool/release archive ", "tool/release record ", "tool/release tested ", "tool/release sums " };
        var at: usize = 0;
        for (markers) |m| {
            const i = std.mem.indexOfPos(u8, jt, at, m);
            if (i == null) {
                try add(a, &f, "the job `archive` has no `{s}` after the step before it (order: archive, record, tested, sums)", .{m});
                break;
            }
            at = i.?;
        }
    }
    // the second build, in both verifies: the same command as build-cli's but into rebuilt-bins, the tarballs again, and the shipped program run.
    for ([_][]const u8{ "verify" }) |name| {
        const j = jobNamed(jobs, name) orelse continue;
        const jt = try j.text(a);
        if (!hasNeed(j, "tool")) try add(a, &f, "the job `{s}` does not wait for `tool`, which hands on the buck2 it runs", .{name});
        if (std.mem.indexOf(u8, jt, "NUMBER: ${{ needs.plan.outputs.number }}") == null) try add(a, &f, "the job `{s}` does not take the planned version from the plan (`NUMBER: ${{{{ needs.plan.outputs.number }}}}`)", .{name});
        if (!hasLineEnd(jt, buildBinaries("rebuilt-bins"))) try add(a, &f, "the job `{s}` does not build the three binaries again with the planned version stamped in (`--out rebuilt-bins //cli:release_binaries`)", .{name});
        if (!hasLineEnd(jt, "tool/release package-all --version \"$NUMBER\" --bins rebuilt-bins --license LICENSE --out rebuilt-dist --native linux-x86_64")) try add(a, &f, "the job `{s}` does not package the second build's three tarballs", .{name});
        if (!hasLineEnd(jt, "tool/release debs --version \"$NUMBER\" --bins rebuilt-bins --channels tool/channels --packaging packaging/deb --out rebuilt-dist")) try add(a, &f, "the job `{s}` does not package the second build's two .debs", .{name});
        if (std.mem.indexOf(u8, jt, "name: channel-tools\npath: tool\n") == null) try add(a, &f, "the job `{s}` does not download the tools of the channels (`channel-tools`) into `tool`", .{name});
        const i_second = std.mem.indexOf(u8, jt, "tool/release debs ");
        const i_verify = std.mem.indexOf(u8, jt, "tool/release verify ");
        if (i_second != null and i_verify != null and i_second.? > i_verify.?) try add(a, &f, "the job `{s}` verifies before it has made the second build's .debs", .{name});
        if (std.mem.indexOf(u8, jt, " --cli rebuilt-bins/linux-x86_64/buildrules --rebuilt rebuilt-dist --dry ") == null) try add(a, &f, "the job `{s}` does not pass `--cli rebuilt-bins/linux-x86_64/buildrules --rebuilt rebuilt-dist` to verify, so the shipped program's version and the second build are not checked", .{name});
        if (std.mem.indexOf(u8, jt, "name: release-dist") == null or std.mem.indexOf(u8, jt, "release-unsigned") != null) try add(a, &f, "the job `{s}` does not read `release-dist` (what attest made) alone", .{name});
    }
    for ([_][]const u8{ "publish", "site" }) |name| {
        if (jobNamed(jobs, name)) |j| {
            const jt = try j.text(a);
            if (std.mem.indexOf(u8, jt, "name: release-dist\npath: dist\n") == null or std.mem.indexOf(u8, jt, "release-unsigned") != null) try add(a, &f, "the job `{s}` does not read `release-dist` (the files that were signed and verified) alone", .{name});
        }
    }
    if (jobNamed(jobs, "attest")) |j| {
        const jt = try j.text(a);
        if (std.mem.indexOf(u8, jt, "name: release-unsigned\npath: dist\n") == null) try add(a, &f, "the job `attest` does not sign what `archive` made (`release-unsigned`)", .{});
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
    for ([_][]const u8{ "tag", "publish", "bump", "tap" }) |name| {
        const j = jobNamed(jobs, name) orelse continue;
        for (j.lines.items) |l| {
            if (usesRepo(l)) |repo| {
                var ok = false;
                for (write_job_actions) |w| {
                    if (std.mem.eql(u8, repo, w)) ok = true;
                }
                if ((std.mem.eql(u8, name, "tag") or std.mem.eql(u8, name, "bump") or std.mem.eql(u8, name, "tap")) and std.mem.eql(u8, repo, app_token_action)) ok = true;
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
    // The tools of the channels are built in `tool`, before any job holds a token or a role, each into its own file, and handed on as one artifact.
    for (channel_targets) |ct| {
        var channel_built = false;
        for (try wc.commands(a, text)) |cmd| {
            if (std.mem.indexOf(u8, cmd, "./buck2 build ") != null and std.mem.indexOf(u8, cmd, ct[0]) != null and std.mem.indexOf(u8, cmd, ct[1]) != null) channel_built = true;
        }
        if (!channel_built) try add(a, &f, "the workflow does not build {s} into its own file ({s}...)", .{ ct[0], ct[1] });
    }
    if (jobNamed(jobs, "tool")) |j| {
        if (std.mem.indexOf(u8, try j.text(a), "name: channel-tools\npath: |\n./channels\n./tap\n./apt-publish\n") == null) try add(a, &f, "the job `tool` does not hand on the tools of the channels as the artifact `channel-tools` (`./channels`, `./tap`, `./apt-publish`)", .{});
    }
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
    \\concurrency:
    \\  group: release-${{ github.event_name == 'push' && 'push' || github.run_id }}
    \\  cancel-in-progress: false
    \\
    \\jobs:
    \\  gate:
    \\    permissions:
    \\      contents: read
    \\    uses: ./.github/workflows/ci.yml
    \\
    \\  tool:
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 120
    \\    permissions:
    \\      contents: read
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          ref: ${{ github.sha }}
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
    \\      - name: Build the channels tool
    \\        run: ./buck2 build --console simple -c buildrules_re.mode=local --out channels //tools/channels:channels
    \\
    \\      - name: Build the tap tool
    \\        run: ./buck2 build --console simple -c buildrules_re.mode=local --out tap //tools/deploy:tap
    \\
    \\      - name: Build the apt publish tool
    \\        run: ./buck2 build --console simple -c buildrules_re.mode=local --out apt-publish //tools/deploy:apt_publish
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
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        with:
    \\          name: channel-tools
    \\          path: |
    \\            ./channels
    \\            ./tap
    \\            ./apt-publish
    \\          retention-days: 7
    \\          if-no-files-found: error
    \\
    \\  plan:
    \\    needs: [gate, tool]
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    permissions:
    \\      contents: read
    \\    env:
    \\      CANDIDATE: ${{ github.sha }}
    \\      FREEZE: ${{ vars.RELEASE_FREEZE }}
    \\    outputs:
    \\      released: ${{ steps.version.outputs.released }}
    \\      complete: ${{ steps.version.outputs.complete }}
    \\      tag: ${{ steps.version.outputs.tag }}
    \\      number: ${{ steps.version.outputs.number }}
    \\      previous: ${{ steps.version.outputs.previous }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          ref: ${{ github.sha }}
    \\          fetch-depth: 0
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-tool
    \\          path: tool
    \\      - run: chmod +x tool/release
    \\      - name: The version of this commit, if it is released
    \\        id: version
    \\        env:
    \\          GH_TOKEN: ${{ github.token }}
    \\        run: tool/release plan --root "$GITHUB_WORKSPACE" --sha "$CANDIDATE" --repo "$GITHUB_REPOSITORY" --freeze "$FREEZE" --dry false --output "$GITHUB_OUTPUT"
    \\
    \\  build-cli:
    \\    needs: [plan, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' && needs.plan.outputs.complete != 'true' }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 60
    \\    permissions:
    \\      contents: read
    \\    env:
    \\      NUMBER: ${{ needs.plan.outputs.number }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          ref: ${{ github.sha }}
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: stage-tool
    \\          path: .
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-tool
    \\          path: tool
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: channel-tools
    \\          path: tool
    \\      - run: chmod +x buck2 tool/release tool/channels
    \\      - name: Build the command line for the three targets with the release version stamped in
    \\        run: ./buck2 build --console simple -c buildrules_re.mode=local -c "buildrules.release_version=$NUMBER" --out cli-bins //cli:release_binaries
    \\      - name: Package the three tarballs
    \\        run: tool/release package-all --version "$NUMBER" --bins cli-bins --license LICENSE --out cli-dist --native linux-x86_64
    \\      - name: Package the two .debs from the same binaries
    \\        run: tool/release debs --version "$NUMBER" --bins cli-bins --channels tool/channels --packaging packaging/deb --out cli-dist
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        with:
    \\          name: release-cli-tarballs
    \\          path: cli-dist
    \\          retention-days: 7
    \\          if-no-files-found: error
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        with:
    \\          name: release-cli-bin
    \\          path: cli-bins/linux-x86_64/buildrules
    \\          retention-days: 7
    \\          if-no-files-found: error
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        with:
    \\          name: release-cli-bins
    \\          path: cli-bins
    \\          retention-days: 7
    \\          if-no-files-found: error
    \\
    \\  beta:
    \\    needs: [plan, build-cli]
    \\    if: ${{ needs.plan.outputs.released == 'true' && needs.plan.outputs.complete != 'true' }}
    \\    permissions:
    \\      contents: read
    \\      id-token: write
    \\    uses: ./.github/workflows/beta.yml
    \\    with:
    \\      cli-bins-artifact: release-cli-bins
    \\      cli-artifact: release-cli-bin
    \\
    \\  gamma:
    \\    needs: [plan, beta, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' && needs.plan.outputs.complete != 'true' }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 240
    \\    permissions:
    \\      contents: read
    \\      id-token: write
    \\    env:
    \\      CANDIDATE: ${{ github.sha }}
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
    \\          ref: ${{ github.sha }}
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
    \\        run: tool/stage gamma --work "$RUNNER_TEMP/gamma" --candidate "$CANDIDATE" --repos "$GAMMA_REPOS" --targets "$GAMMA_TARGETS" --buck2 "$GITHUB_WORKSPACE/tool/buck2" --farm-config "$HOME/.buckconfig.d/farm.buckconfig"
    \\
    \\  archive:
    \\    needs: [plan, build-cli, beta, gamma, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' && needs.plan.outputs.complete != 'true' }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    permissions:
    \\      contents: read
    \\    env:
    \\      CANDIDATE: ${{ github.sha }}
    \\      TAG: ${{ needs.plan.outputs.tag }}
    \\      NUMBER: ${{ needs.plan.outputs.number }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          ref: ${{ github.sha }}
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-tool
    \\          path: tool
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-cli-tarballs
    \\          path: dist
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-cli-bin
    \\          path: ran
    \\      - run: chmod +x tool/release
    \\      - name: The deterministic source archive of the tested commit, and its SHA256SUMS
    \\        run: tool/release archive --root "$GITHUB_WORKSPACE" --tag "$TAG" --sha "$CANDIDATE" --out dist
    \\      - name: The tarball to attest holds the file the beta ran
    \\        run: tool/release record --tarball "dist/buildrules-cli-$NUMBER-linux-x86_64.tar.gz" --ran-binary ran/buildrules --out tested
    \\      - name: Attest only the tarballs a user beta ran, and the .debs that hold their program
    \\        run: tool/release tested --dist dist --tested tested --targets linux-x86_64
    \\      - name: SHA256SUMS over the archive, the three tarballs and the two .debs
    \\        run: tool/release sums --dist dist
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        with:
    \\          name: release-unsigned
    \\          path: dist
    \\          retention-days: 7
    \\          if-no-files-found: error
    \\
    \\  attest:
    \\    needs: [plan, archive, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    permissions:
    \\      contents: read
    \\      id-token: write
    \\      attestations: write
    \\    steps:
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-tool
    \\          path: tool
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-unsigned
    \\          path: dist
    \\      - run: chmod +x tool/release
    \\      - uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2
    \\        with:
    \\          cosign-release: 'v3.0.6'
    \\      - name: Sign the seven files, keyless
    \\        run: tool/release sign --dist dist --dry false
    \\      - name: Attest the archive, the three tarballs, the two .debs and SHA256SUMS
    \\        uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2
    \\        with:
    \\          subject-path: |
    \\            dist/buildrules-*.tar.gz
    \\            dist/buildrules_*.deb
    \\            dist/SHA256SUMS
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        with:
    \\          name: release-dist
    \\          path: dist
    \\          retention-days: 7
    \\          if-no-files-found: error
    \\
    \\  verify:
    \\    needs: [plan, attest, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 60
    \\    permissions:
    \\      contents: read
    \\      attestations: read
    \\    env:
    \\      CANDIDATE: ${{ github.sha }}
    \\      TAG: ${{ needs.plan.outputs.tag }}
    \\      NUMBER: ${{ needs.plan.outputs.number }}
    \\      GH_TOKEN: ${{ github.token }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          ref: ${{ github.sha }}
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: stage-tool
    \\          path: .
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-tool
    \\          path: tool
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-dist
    \\          path: dist
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: channel-tools
    \\          path: tool
    \\      - run: chmod +x buck2 tool/release tool/channels
    \\      - uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2
    \\        with:
    \\          cosign-release: 'v3.0.6'
    \\      - name: Build the command line again for the three targets
    \\        run: ./buck2 build --console simple -c buildrules_re.mode=local -c "buildrules.release_version=$NUMBER" --out rebuilt-bins //cli:release_binaries
    \\      - name: Package the three tarballs again
    \\        run: tool/release package-all --version "$NUMBER" --bins rebuilt-bins --license LICENSE --out rebuilt-dist --native linux-x86_64
    \\      - name: Package the two .debs again
    \\        run: tool/release debs --version "$NUMBER" --bins rebuilt-bins --channels tool/channels --packaging packaging/deb --out rebuilt-dist
    \\      - name: The archive, the tarballs and the .debs, their sums, the second build, file list and scrub, the command line's version, the attestations and the signatures
    \\        run: tool/release verify --root "$GITHUB_WORKSPACE" --repo "$GITHUB_REPOSITORY" --tag "$TAG" --sha "$CANDIDATE" --dist dist --workflow .github/workflows/release.yml --cli rebuilt-bins/linux-x86_64/buildrules --rebuilt rebuilt-dist --dry false
    \\
    \\  tag:
    \\    needs: [plan, verify, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    environment: release
    \\    concurrency:
    \\      group: release
    \\      cancel-in-progress: false
    \\    permissions:
    \\      contents: read
    \\    outputs:
    \\      superseded: ${{ steps.settle.outputs.superseded }}
    \\      tag: ${{ steps.settle.outputs.tag }}
    \\      number: ${{ steps.settle.outputs.number }}
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
    \\        id: settle
    \\        env:
    \\          GH_TOKEN: ${{ steps.bot.outputs.token }}
    \\        run: tool/release tag --root "$GITHUB_WORKSPACE" --repo "$GITHUB_REPOSITORY" --tag "$TAG" --sha "$GITHUB_SHA" --output "$GITHUB_OUTPUT"
    \\
    \\  publish:
    \\    needs: [plan, tag, verify, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork && needs.tag.outputs.superseded != 'true' }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    permissions:
    \\      contents: write
    \\    env:
    \\      TAG: ${{ needs.tag.outputs.tag }}
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
    \\          name: release-dist
    \\          path: dist
    \\      - run: chmod +x tool/release
    \\      - name: Create the release, or add the file it lacks
    \\        env:
    \\          GH_TOKEN: ${{ github.token }}
    \\        run: tool/release publish --root "$GITHUB_WORKSPACE" --repo "$GITHUB_REPOSITORY" --tag "$TAG" --sha "$GITHUB_SHA" --previous "$PREVIOUS" --dist dist
    \\
    \\  bump:
    \\    needs: [plan, tag, publish, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork && needs.tag.outputs.superseded != 'true' }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    environment: release
    \\    permissions:
    \\      contents: read
    \\    env:
    \\      TAG: ${{ needs.tag.outputs.tag }}
    \\      INTERNAL_REPO: ${{ github.repository_owner }}/${{ vars.BUMP_REPOSITORY }}
    \\    steps:
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-tool
    \\          path: tool
    \\      - run: chmod +x tool/release
    \\      - name: The internal repository is named
    \\        run: tool/release bump-check --internal-repo "$INTERNAL_REPO"
    \\      - name: The token of the release bot, for the internal repository alone
    \\        id: bump_bot
    \\        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
    \\        with:
    \\          app-id: ${{ vars.RELEASE_BOT_APP_ID }}
    \\          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
    \\          owner: ${{ github.repository_owner }}
    \\          repositories: ${{ vars.BUMP_REPOSITORY }}
    \\          permission-contents: write
    \\          permission-pull-requests: write
    \\      - name: The pull request that moves the submodule to this release, with auto-merge
    \\        env:
    \\          GH_TOKEN: ${{ steps.bump_bot.outputs.token }}
    \\        run: tool/release bump-internal --repo "$GITHUB_REPOSITORY" --tag "$TAG" --sha "$GITHUB_SHA" --internal-repo "$INTERNAL_REPO" --submodule buildrules --workdir "$RUNNER_TEMP/bump"
    \\
    \\  site:
    \\    needs: [plan, tag, verify, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' && needs.tag.outputs.superseded != 'true' }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    permissions:
    \\      contents: read
    \\    env:
    \\      TAG: ${{ needs.tag.outputs.tag }}
    \\    steps:
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-tool
    \\          path: tool
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-dist
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
    \\  tap:
    \\    needs: [plan, tag, publish, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork && needs.tag.outputs.superseded != 'true' }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    environment: release
    \\    permissions:
    \\      contents: read
    \\    env:
    \\      NUMBER: ${{ needs.tag.outputs.number }}
    \\      OWNER: ${{ github.repository_owner }}
    \\    steps:
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: channel-tools
    \\          path: tool
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: release-dist
    \\          path: dist
    \\      - run: chmod +x tool/channels tool/tap
    \\      - name: Render Formula/buildrules.rb from the verified SHA256SUMS, with the flags the tap's guard expects
    \\        run: tool/channels formula --sums dist/SHA256SUMS --name buildrules --asset buildrules-cli --version "$NUMBER" --desc "Hermetic Buck2 rules and toolchains" --homepage "https://buildrules.dev" --license "Apache-2.0" --repo "$GITHUB_REPOSITORY" --no-explicit-version --out tap/buildrules.rb
    \\      - name: The token of the release bot, for the tap repository alone
    \\        id: tap_bot
    \\        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
    \\        with:
    \\          app-id: ${{ vars.RELEASE_BOT_APP_ID }}
    \\          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
    \\          owner: ${{ github.repository_owner }}
    \\          repositories: homebrew-tap
    \\          permission-contents: write
    \\          permission-pull-requests: write
    \\      - name: The pull request that adds the formula of this release to the tap, with auto-merge when the tap allows it
    \\        env:
    \\          GH_TOKEN: ${{ steps.tap_bot.outputs.token }}
    \\        run: tool/tap --repo "$GITHUB_REPOSITORY" --version "$NUMBER" --formula-file tap/buildrules.rb --tap-repo "$OWNER/homebrew-tap" --formula buildrules --asset buildrules-cli --workdir "$RUNNER_TEMP/tap-clone"
    \\
    \\  apt-deploy-read:
    \\    needs: [plan, tag, publish, tool]
    \\    if: ${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork && needs.tag.outputs.superseded != 'true' }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    environment: apt-publish
    \\    permissions:
    \\      contents: read
    \\      id-token: write
    \\    outputs:
    \\      enabled: ${{ steps.gate.outputs.enabled }}
    \\    env:
    \\      AWS_DEFAULT_REGION: us-east-1
    \\    steps:
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: channel-tools
    \\          path: tool
    \\      - run: chmod +x tool/apt-publish
    \\      - name: Gate on the settings of the apt repository (a job without them does nothing and ends green)
    \\        id: gate
    \\        env:
    \\          APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}
    \\          APT_BUCKET: ${{ vars.APT_BUCKET }}
    \\          APT_DISTRIBUTION_ID: ${{ vars.APT_DISTRIBUTION_ID }}
    \\          APT_HOSTNAME: ${{ vars.APT_HOSTNAME }}
    \\        run: tool/apt-publish gate --label "apt publish (read)" --out "$GITHUB_OUTPUT" --env APT_PUBLISH_ROLE_ARN --env APT_BUCKET --env APT_DISTRIBUTION_ID --env APT_HOSTNAME
    \\      - name: Assume the publish role through OIDC
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        env:
    \\          APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}
    \\        run: tool/apt-publish assume --env-file "$GITHUB_ENV"
    \\      - name: Read the current index and its ETags from S3 (never through the CDN, which caches the index)
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        env:
    \\          APT_BUCKET: ${{ vars.APT_BUCKET }}
    \\        run: tool/apt-publish read --bucket "$APT_BUCKET" --out "$RUNNER_TEMP/apt-current"
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: apt-current
    \\          path: ${{ runner.temp }}/apt-current
    \\          if-no-files-found: error
    \\          retention-days: 1
    \\          overwrite: true
    \\
    \\  apt-index:
    \\    needs: [apt-deploy-read]
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    environment: apt-signing
    \\    permissions:
    \\      contents: read
    \\    outputs:
    \\      signed: ${{ steps.sign.outputs.signed }}
    \\    env:
    \\      OWNER: ${{ github.repository_owner }}
    \\    steps:
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: channel-tools
    \\          path: tool
    \\      - run: chmod +x tool/apt-publish tool/channels
    \\      - name: Gate on the signing key and on the read (a job without them does nothing and ends green)
    \\        id: gate
    \\        env:
    \\          READ_ENABLED: ${{ needs.apt-deploy-read.outputs.enabled }}
    \\          HAVE_KEY: ${{ secrets.APT_GPG_PRIVATE_KEY != '' }}
    \\          APT_GPG_FINGERPRINT: ${{ secrets.APT_GPG_FINGERPRINT || vars.APT_GPG_FINGERPRINT }}
    \\        run: tool/apt-publish gate --label "apt index" --out "$GITHUB_OUTPUT" --true READ_ENABLED --true HAVE_KEY --env APT_GPG_FINGERPRINT
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: apt-current
    \\          path: ${{ runner.temp }}/apt-current
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: release-dist
    \\          path: ${{ runner.temp }}/apt-debs
    \\      - name: Merge the .debs into the index that was read (the index of every product is kept)
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        run: tool/apt-publish index --channels tool/channels --current "$RUNNER_TEMP/apt-current" --out "$RUNNER_TEMP/apt-next" --debs "$RUNNER_TEMP/apt-debs" --origin "$OWNER" --label "$OWNER" --description "$OWNER packages"
    \\      - name: Sign Release with the signing subkey (InRelease and Release.gpg)
    \\        id: sign
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        env:
    \\          APT_GPG_PRIVATE_KEY: ${{ secrets.APT_GPG_PRIVATE_KEY }}
    \\          APT_GPG_PASSPHRASE: ${{ secrets.APT_GPG_PASSPHRASE }}
    \\          APT_GPG_FINGERPRINT: ${{ secrets.APT_GPG_FINGERPRINT || vars.APT_GPG_FINGERPRINT }}
    \\        run: tool/apt-publish sign --dir "$RUNNER_TEMP/apt-next/dists/stable" --work "$RUNNER_TEMP/apt-sign" --fingerprint "$APT_GPG_FINGERPRINT" --out "$GITHUB_OUTPUT"
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: apt-next
    \\          path: |
    \\            ${{ runner.temp }}/apt-next/dists
    \\            ${{ runner.temp }}/apt-next/etags.txt
    \\          if-no-files-found: error
    \\          retention-days: 1
    \\          overwrite: true
    \\
    \\  apt-deploy-write:
    \\    needs: [apt-deploy-read, apt-index]
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    environment: apt-publish
    \\    permissions:
    \\      contents: read
    \\      id-token: write
    \\    outputs:
    \\      conflict: ${{ steps.put.outputs.conflict }}
    \\    env:
    \\      AWS_DEFAULT_REGION: us-east-1
    \\    steps:
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: channel-tools
    \\          path: tool
    \\      - run: chmod +x tool/apt-publish
    \\      - name: Gate on the settings of the apt repository and on the signed index (a job without them does nothing and ends green)
    \\        id: gate
    \\        env:
    \\          READ_ENABLED: ${{ needs.apt-deploy-read.outputs.enabled }}
    \\          INDEX_SIGNED: ${{ needs.apt-index.outputs.signed }}
    \\          APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}
    \\          APT_BUCKET: ${{ vars.APT_BUCKET }}
    \\          APT_DISTRIBUTION_ID: ${{ vars.APT_DISTRIBUTION_ID }}
    \\          APT_HOSTNAME: ${{ vars.APT_HOSTNAME }}
    \\        run: tool/apt-publish gate --label "apt publish (write)" --out "$GITHUB_OUTPUT" --true READ_ENABLED --true INDEX_SIGNED --env APT_PUBLISH_ROLE_ARN --env APT_BUCKET --env APT_DISTRIBUTION_ID --env APT_HOSTNAME
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: apt-next
    \\          path: ${{ runner.temp }}/apt-next
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: release-dist
    \\          path: ${{ runner.temp }}/apt-debs
    \\      - name: Assume the publish role through OIDC
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        env:
    \\          APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}
    \\        run: tool/apt-publish assume --env-file "$GITHUB_ENV"
    \\      - name: Upload the .debs (If-None-Match), write the signed index (If-Match on the ETag that was read), then invalidate /apt/dists/*
    \\        id: put
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        env:
    \\          APT_BUCKET: ${{ vars.APT_BUCKET }}
    \\          APT_DISTRIBUTION_ID: ${{ vars.APT_DISTRIBUTION_ID }}
    \\          APT_HOSTNAME: ${{ vars.APT_HOSTNAME }}
    \\        run: tool/apt-publish write --bucket "$APT_BUCKET" --distribution "$APT_DISTRIBUTION_ID" --hostname "$APT_HOSTNAME" --next "$RUNNER_TEMP/apt-next" --debs "$RUNNER_TEMP/apt-debs" --out "$GITHUB_OUTPUT"
    \\
    \\  apt-deploy-read-2:
    \\    needs: [apt-deploy-write]
    \\    if: ${{ needs.apt-deploy-write.outputs.conflict == 'true' }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    environment: apt-publish
    \\    permissions:
    \\      contents: read
    \\      id-token: write
    \\    outputs:
    \\      enabled: ${{ steps.gate.outputs.enabled }}
    \\    env:
    \\      AWS_DEFAULT_REGION: us-east-1
    \\    steps:
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: channel-tools
    \\          path: tool
    \\      - run: chmod +x tool/apt-publish
    \\      - name: Gate on the settings of the apt repository (a job without them does nothing and ends green)
    \\        id: gate
    \\        env:
    \\          APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}
    \\          APT_BUCKET: ${{ vars.APT_BUCKET }}
    \\          APT_DISTRIBUTION_ID: ${{ vars.APT_DISTRIBUTION_ID }}
    \\          APT_HOSTNAME: ${{ vars.APT_HOSTNAME }}
    \\        run: tool/apt-publish gate --label "apt publish (read)" --out "$GITHUB_OUTPUT" --env APT_PUBLISH_ROLE_ARN --env APT_BUCKET --env APT_DISTRIBUTION_ID --env APT_HOSTNAME
    \\      - name: Assume the publish role through OIDC
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        env:
    \\          APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}
    \\        run: tool/apt-publish assume --env-file "$GITHUB_ENV"
    \\      - name: Read the current index and its ETags from S3 (never through the CDN, which caches the index)
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        env:
    \\          APT_BUCKET: ${{ vars.APT_BUCKET }}
    \\        run: tool/apt-publish read --bucket "$APT_BUCKET" --out "$RUNNER_TEMP/apt-current"
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: apt-current-2
    \\          path: ${{ runner.temp }}/apt-current
    \\          if-no-files-found: error
    \\          retention-days: 1
    \\          overwrite: true
    \\
    \\  apt-index-2:
    \\    needs: [apt-deploy-read-2]
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    environment: apt-signing
    \\    permissions:
    \\      contents: read
    \\    outputs:
    \\      signed: ${{ steps.sign.outputs.signed }}
    \\    env:
    \\      OWNER: ${{ github.repository_owner }}
    \\    steps:
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: channel-tools
    \\          path: tool
    \\      - run: chmod +x tool/apt-publish tool/channels
    \\      - name: Gate on the signing key and on the read (a job without them does nothing and ends green)
    \\        id: gate
    \\        env:
    \\          READ_ENABLED: ${{ needs.apt-deploy-read-2.outputs.enabled }}
    \\          HAVE_KEY: ${{ secrets.APT_GPG_PRIVATE_KEY != '' }}
    \\          APT_GPG_FINGERPRINT: ${{ secrets.APT_GPG_FINGERPRINT || vars.APT_GPG_FINGERPRINT }}
    \\        run: tool/apt-publish gate --label "apt index" --out "$GITHUB_OUTPUT" --true READ_ENABLED --true HAVE_KEY --env APT_GPG_FINGERPRINT
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: apt-current-2
    \\          path: ${{ runner.temp }}/apt-current
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: release-dist
    \\          path: ${{ runner.temp }}/apt-debs
    \\      - name: Merge the .debs into the index that was read (the index of every product is kept)
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        run: tool/apt-publish index --channels tool/channels --current "$RUNNER_TEMP/apt-current" --out "$RUNNER_TEMP/apt-next" --debs "$RUNNER_TEMP/apt-debs" --origin "$OWNER" --label "$OWNER" --description "$OWNER packages"
    \\      - name: Sign Release with the signing subkey (InRelease and Release.gpg)
    \\        id: sign
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        env:
    \\          APT_GPG_PRIVATE_KEY: ${{ secrets.APT_GPG_PRIVATE_KEY }}
    \\          APT_GPG_PASSPHRASE: ${{ secrets.APT_GPG_PASSPHRASE }}
    \\          APT_GPG_FINGERPRINT: ${{ secrets.APT_GPG_FINGERPRINT || vars.APT_GPG_FINGERPRINT }}
    \\        run: tool/apt-publish sign --dir "$RUNNER_TEMP/apt-next/dists/stable" --work "$RUNNER_TEMP/apt-sign" --fingerprint "$APT_GPG_FINGERPRINT" --out "$GITHUB_OUTPUT"
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: apt-next-2
    \\          path: |
    \\            ${{ runner.temp }}/apt-next/dists
    \\            ${{ runner.temp }}/apt-next/etags.txt
    \\          if-no-files-found: error
    \\          retention-days: 1
    \\          overwrite: true
    \\
    \\  apt-deploy-write-2:
    \\    needs: [apt-deploy-read-2, apt-index-2]
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    environment: apt-publish
    \\    permissions:
    \\      contents: read
    \\      id-token: write
    \\    outputs:
    \\      conflict: ${{ steps.put.outputs.conflict }}
    \\    env:
    \\      AWS_DEFAULT_REGION: us-east-1
    \\    steps:
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: channel-tools
    \\          path: tool
    \\      - run: chmod +x tool/apt-publish
    \\      - name: Gate on the settings of the apt repository and on the signed index (a job without them does nothing and ends green)
    \\        id: gate
    \\        env:
    \\          READ_ENABLED: ${{ needs.apt-deploy-read-2.outputs.enabled }}
    \\          INDEX_SIGNED: ${{ needs.apt-index-2.outputs.signed }}
    \\          APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}
    \\          APT_BUCKET: ${{ vars.APT_BUCKET }}
    \\          APT_DISTRIBUTION_ID: ${{ vars.APT_DISTRIBUTION_ID }}
    \\          APT_HOSTNAME: ${{ vars.APT_HOSTNAME }}
    \\        run: tool/apt-publish gate --label "apt publish (write)" --out "$GITHUB_OUTPUT" --true READ_ENABLED --true INDEX_SIGNED --env APT_PUBLISH_ROLE_ARN --env APT_BUCKET --env APT_DISTRIBUTION_ID --env APT_HOSTNAME
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: apt-next-2
    \\          path: ${{ runner.temp }}/apt-next
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: release-dist
    \\          path: ${{ runner.temp }}/apt-debs
    \\      - name: Assume the publish role through OIDC
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        env:
    \\          APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}
    \\        run: tool/apt-publish assume --env-file "$GITHUB_ENV"
    \\      - name: Upload the .debs (If-None-Match), write the signed index (If-Match on the ETag that was read), then invalidate /apt/dists/*
    \\        id: put
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        env:
    \\          APT_BUCKET: ${{ vars.APT_BUCKET }}
    \\          APT_DISTRIBUTION_ID: ${{ vars.APT_DISTRIBUTION_ID }}
    \\          APT_HOSTNAME: ${{ vars.APT_HOSTNAME }}
    \\        run: tool/apt-publish write --bucket "$APT_BUCKET" --distribution "$APT_DISTRIBUTION_ID" --hostname "$APT_HOSTNAME" --next "$RUNNER_TEMP/apt-next" --debs "$RUNNER_TEMP/apt-debs" --out "$GITHUB_OUTPUT"
    \\
    \\  apt-deploy-read-3:
    \\    needs: [apt-deploy-write-2]
    \\    if: ${{ needs.apt-deploy-write-2.outputs.conflict == 'true' }}
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    environment: apt-publish
    \\    permissions:
    \\      contents: read
    \\      id-token: write
    \\    outputs:
    \\      enabled: ${{ steps.gate.outputs.enabled }}
    \\    env:
    \\      AWS_DEFAULT_REGION: us-east-1
    \\    steps:
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: channel-tools
    \\          path: tool
    \\      - run: chmod +x tool/apt-publish
    \\      - name: Gate on the settings of the apt repository (a job without them does nothing and ends green)
    \\        id: gate
    \\        env:
    \\          APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}
    \\          APT_BUCKET: ${{ vars.APT_BUCKET }}
    \\          APT_DISTRIBUTION_ID: ${{ vars.APT_DISTRIBUTION_ID }}
    \\          APT_HOSTNAME: ${{ vars.APT_HOSTNAME }}
    \\        run: tool/apt-publish gate --label "apt publish (read)" --out "$GITHUB_OUTPUT" --env APT_PUBLISH_ROLE_ARN --env APT_BUCKET --env APT_DISTRIBUTION_ID --env APT_HOSTNAME
    \\      - name: Assume the publish role through OIDC
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        env:
    \\          APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}
    \\        run: tool/apt-publish assume --env-file "$GITHUB_ENV"
    \\      - name: Read the current index and its ETags from S3 (never through the CDN, which caches the index)
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        env:
    \\          APT_BUCKET: ${{ vars.APT_BUCKET }}
    \\        run: tool/apt-publish read --bucket "$APT_BUCKET" --out "$RUNNER_TEMP/apt-current"
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: apt-current-3
    \\          path: ${{ runner.temp }}/apt-current
    \\          if-no-files-found: error
    \\          retention-days: 1
    \\          overwrite: true
    \\
    \\  apt-index-3:
    \\    needs: [apt-deploy-read-3]
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    environment: apt-signing
    \\    permissions:
    \\      contents: read
    \\    outputs:
    \\      signed: ${{ steps.sign.outputs.signed }}
    \\    env:
    \\      OWNER: ${{ github.repository_owner }}
    \\    steps:
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: channel-tools
    \\          path: tool
    \\      - run: chmod +x tool/apt-publish tool/channels
    \\      - name: Gate on the signing key and on the read (a job without them does nothing and ends green)
    \\        id: gate
    \\        env:
    \\          READ_ENABLED: ${{ needs.apt-deploy-read-3.outputs.enabled }}
    \\          HAVE_KEY: ${{ secrets.APT_GPG_PRIVATE_KEY != '' }}
    \\          APT_GPG_FINGERPRINT: ${{ secrets.APT_GPG_FINGERPRINT || vars.APT_GPG_FINGERPRINT }}
    \\        run: tool/apt-publish gate --label "apt index" --out "$GITHUB_OUTPUT" --true READ_ENABLED --true HAVE_KEY --env APT_GPG_FINGERPRINT
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: apt-current-3
    \\          path: ${{ runner.temp }}/apt-current
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: release-dist
    \\          path: ${{ runner.temp }}/apt-debs
    \\      - name: Merge the .debs into the index that was read (the index of every product is kept)
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        run: tool/apt-publish index --channels tool/channels --current "$RUNNER_TEMP/apt-current" --out "$RUNNER_TEMP/apt-next" --debs "$RUNNER_TEMP/apt-debs" --origin "$OWNER" --label "$OWNER" --description "$OWNER packages"
    \\      - name: Sign Release with the signing subkey (InRelease and Release.gpg)
    \\        id: sign
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        env:
    \\          APT_GPG_PRIVATE_KEY: ${{ secrets.APT_GPG_PRIVATE_KEY }}
    \\          APT_GPG_PASSPHRASE: ${{ secrets.APT_GPG_PASSPHRASE }}
    \\          APT_GPG_FINGERPRINT: ${{ secrets.APT_GPG_FINGERPRINT || vars.APT_GPG_FINGERPRINT }}
    \\        run: tool/apt-publish sign --dir "$RUNNER_TEMP/apt-next/dists/stable" --work "$RUNNER_TEMP/apt-sign" --fingerprint "$APT_GPG_FINGERPRINT" --out "$GITHUB_OUTPUT"
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: apt-next-3
    \\          path: |
    \\            ${{ runner.temp }}/apt-next/dists
    \\            ${{ runner.temp }}/apt-next/etags.txt
    \\          if-no-files-found: error
    \\          retention-days: 1
    \\          overwrite: true
    \\
    \\  apt-deploy-write-3:
    \\    needs: [apt-deploy-read-3, apt-index-3]
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 15
    \\    environment: apt-publish
    \\    permissions:
    \\      contents: read
    \\      id-token: write
    \\    outputs:
    \\      conflict: ${{ steps.put.outputs.conflict }}
    \\    env:
    \\      AWS_DEFAULT_REGION: us-east-1
    \\    steps:
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: channel-tools
    \\          path: tool
    \\      - run: chmod +x tool/apt-publish
    \\      - name: Gate on the settings of the apt repository and on the signed index (a job without them does nothing and ends green)
    \\        id: gate
    \\        env:
    \\          READ_ENABLED: ${{ needs.apt-deploy-read-3.outputs.enabled }}
    \\          INDEX_SIGNED: ${{ needs.apt-index-3.outputs.signed }}
    \\          APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}
    \\          APT_BUCKET: ${{ vars.APT_BUCKET }}
    \\          APT_DISTRIBUTION_ID: ${{ vars.APT_DISTRIBUTION_ID }}
    \\          APT_HOSTNAME: ${{ vars.APT_HOSTNAME }}
    \\        run: tool/apt-publish gate --label "apt publish (write)" --out "$GITHUB_OUTPUT" --true READ_ENABLED --true INDEX_SIGNED --env APT_PUBLISH_ROLE_ARN --env APT_BUCKET --env APT_DISTRIBUTION_ID --env APT_HOSTNAME
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: apt-next-3
    \\          path: ${{ runner.temp }}/apt-next
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        with:
    \\          name: release-dist
    \\          path: ${{ runner.temp }}/apt-debs
    \\      - name: Assume the publish role through OIDC
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        env:
    \\          APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}
    \\        run: tool/apt-publish assume --env-file "$GITHUB_ENV"
    \\      - name: Upload the .debs (If-None-Match), write the signed index (If-Match on the ETag that was read), then invalidate /apt/dists/*
    \\        id: put
    \\        if: steps.gate.outputs.enabled == 'true'
    \\        env:
    \\          APT_BUCKET: ${{ vars.APT_BUCKET }}
    \\          APT_DISTRIBUTION_ID: ${{ vars.APT_DISTRIBUTION_ID }}
    \\          APT_HOSTNAME: ${{ vars.APT_HOSTNAME }}
    \\        run: tool/apt-publish write --bucket "$APT_BUCKET" --distribution "$APT_DISTRIBUTION_ID" --hostname "$APT_HOSTNAME" --next "$RUNNER_TEMP/apt-next" --debs "$RUNNER_TEMP/apt-debs" --out "$GITHUB_OUTPUT" --last

;

const fixture_ds =
    \\{
    \\  "platform": {
    \\    "linux-x86_64": {
    \\      "digest": "1268fce33fb600000000000000000000000000000000000000000000000000ff",
    \\      "providers": [{"url": "https://example.invalid/2026-09-15/buck2-x86_64-unknown-linux-gnu.zst"}]
    \\    },
    \\    "macos-aarch64": {}
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

/// As `mutate`, within the job `job` and no further (the first `from` between its header and the next job's). A mutant whose text is not in that job did not
/// apply: it is an error, and not a quiet change of another job.
fn mutateIn(a: std.mem.Allocator, wf: []const u8, job: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const block = jobBlock(wf, job);
    if (block.len == 0) return error.MutantDidNotApply;
    const at = @intFromPtr(block.ptr) - @intFromPtr(wf.ptr);
    const i = std.mem.indexOfPos(u8, wf[0 .. at + block.len], at, from) orelse return error.MutantDidNotApply;
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
    try t.expectEqual(@as(usize, 23), jobs.len);
    const bp = jobNamed(jobs, "bump").?;
    try t.expect(hasNeed(bp, "plan") and hasNeed(bp, "tag") and hasNeed(bp, "publish") and hasNeed(bp, "tool"));
    try t.expectEqualStrings(publish_if, bp.if_expr.?);
    try t.expectEqualStrings("read", permLevel(bp, "contents").?);
    try t.expectEqual(@as(usize, 1), bp.perms.items.len);
    const tg = jobNamed(jobs, "tag").?;
    try t.expect(hasNeed(tg, "plan") and hasNeed(tg, "verify") and hasNeed(tg, "tool"));
    try t.expectEqualStrings(tag_if, tg.if_expr.?);
    try t.expectEqualStrings("read", permLevel(tg, "contents").?);
    try t.expectEqualStrings("release", tg.group.?);
    try t.expectEqualStrings("false", tg.cancel.?);
    const at_job = jobNamed(jobs, "attest").?;
    try t.expectEqualStrings("write", permLevel(at_job, "id-token").?);
    try t.expectEqualStrings("write", permLevel(at_job, "attestations").?);
    try t.expectEqualStrings("read", permLevel(at_job, "contents").?);
    try t.expectEqualStrings(tag_if, at_job.if_expr.?);
    try t.expect(jobNamed(jobs, "gate").?.if_expr == null);
    try t.expect(jobNamed(jobs, "tool").?.if_expr == null);
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

test "rule: only a push to main triggers it, and no pull request does" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    // anything else is refused by name
    try expectFinding(a, r, try mutate(a, r.wf, "on:\n  push:", "on:\n  workflow_dispatch:\n  push:"), "triggered by `workflow_dispatch`");
    try expectFinding(a, r, try mutate(a, r.wf, "on:\n  push:", "on:\n  schedule:\n  push:"), "triggered by `schedule`");
    try expectFinding(a, r, try mutate(a, r.wf, "on:\n  push:", "on:\n  release:\n  push:"), "triggered by `release`");
    try expectFinding(a, r, try mutate(a, r.wf, "on:\n  push:", "on:\n  pull_request_target:\n  push:"), "`pull_request_target` appears");
    try expectFinding(a, r, try mutate(a, r.wf, "    branches: [main]\n\npermissions", "    branches: [main]\n  workflow_run:\n    workflows: [ci]\n\npermissions"), "`workflow_run` appears");
    // the tiers: a pull request runs build and unit tests (ci.yml) and never this workflow; no release-pipeline dry run
    try expectFinding(a, r, try mutate(a, r.wf, "    branches: [main]\n\npermissions", "    branches: [main]\n  pull_request:\n\npermissions"), "triggered by `pull_request`");
    try expectFinding(a, r, try mutate(a, r.wf, "on:\n  push:", "on:\n  pull_request:\n  push:"), "triggered by `pull_request`");
    // the push is to main alone
    try expectFinding(a, r, try mutate(a, r.wf, "branches: [main]", "branches: [main, dev]"), "not triggered by a push to main");
    try expectFinding(a, r, try mutate(a, r.wf, "branches: [main]", "branches: [dev]"), "not triggered by a push to main");
    try expectFinding(a, r, try mutate(a, r.wf, "  push:\n    branches: [main]\n", ""), "not triggered by a push to main");
}

test "rule: write scopes only where they belong" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    // contents: write only in publish
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "      contents: read\n", "      contents: write\n"), "job `archive` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      contents: read\n", "      contents: write\n"), "job `verify` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "      contents: read\n", "      contents: write\n"), "job `attest` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "      contents: read\n", "      contents: write\n"), "job `build-cli` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tool", "      contents: read\n", "      contents: write\n"), "job `tool` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gate", "      contents: read\n", "      contents: write\n"), "job `gate` holds `contents: write`");
    // id-token and attestations write only in attest (and id-token in gamma and the call of beta)
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      contents: read\n", "      contents: read\n      id-token: write\n"), "job `tag` holds `id-token: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "      contents: read\n", "      contents: read\n      id-token: write\n"), "job `archive` holds `id-token: write`");
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
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "    timeout-minutes: 60\n", "    timeout-minutes: 60\n    env:\n      P: contents: write\n"), "outside a job's");
    // a job with no permissions of its own would inherit the top
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "    permissions:\n      contents: read\n      attestations: read\n", ""), "states no `permissions:`");
    // the jobs that read hold nothing more: verify reads attestations, no job but attest holds the signing scopes
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      attestations: read\n", ""), "`verify` is not `contents: read` and `attestations: read` alone");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      attestations: read\n", "      attestations: read\n      packages: read\n"), "`verify` is not `contents: read` and `attestations: read` alone");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "      contents: read\n", "      contents: read\n      packages: read\n"), "`archive` is not `contents: read` alone");
    // the jobs that need their scope have it
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      contents: read\n", "      contents: write\n"), "job `tag` holds `contents: write`, which only publish may");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      contents: write\n", "      contents: read\n"), "`publish` does not hold `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "      id-token: write\n", "      id-token: read\n"), "`attest` does not hold `id-token: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "      attestations: write\n", ""), "`attest` does not hold `attestations: write`");
}

test "rule: exactly the jobs that read the release bot's key declare the environment release, and no other job declares one" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const env = "    environment: release\n";
    const reads = "reads `RELEASE_BOT_*` but does not declare `environment: release`";
    // mutant: tag without it; bump without it
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", env, ""), "the job `tag` " ++ reads);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", env, ""), "the job `bump` " ++ reads);
    // mutant: the wrong name, on either
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", env, "    environment: relase\n"), "the job `tag` " ++ reads);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", env, "    environment: prod\n"), "the job `bump` " ++ reads);
    // mutant: the environment on a job that does not read the key
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "    timeout-minutes: 15\n", "    timeout-minutes: 15\n" ++ env), "the job `publish` declares `environment: release`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "    timeout-minutes: 60\n", "    timeout-minutes: 60\n" ++ env), "the job `verify` declares `environment: release`");
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
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "permission-contents: write\n", "permission-contents: write\n          permission-actions: write\n"), "release bot's key, token or permission input appears other than in `tag`, `bump` and `tap`");
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
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "GH_TOKEN: ${{ github.token }}", "GH_TOKEN: ${{ steps.bot.outputs.token }}"), "other than in `tag`, `bump` and `tap`");
    // nor is the key read, or the token minted, in any other job
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "GH_TOKEN: ${{ github.token }}", "GH_TOKEN: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}"), "appears other than in `tag`, `bump` and `tap`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      - run: chmod +x tool/release\n", "      - uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n        with:\n          app-id: 1\n"), "used other than three times, in `tag`, `bump` and `tap`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      - run: chmod +x buck2 tool/release tool/channels\n", "      - uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n        with:\n          app-id: 1\n"), "used other than three times, in `tag`, `bump` and `tap`");
    // and publish still holds the job token's write, which creates no tag
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      contents: write\n", "      contents: read\n"), "`publish` does not hold `contents: write`");
}

test "rule: the internal repository's submodule bump runs after publish, with the release bot's token for that repository alone, and nothing waits for it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const mint = "does not mint the release bot's token";
    const key_token = "appears other than in `tag`, `bump` and `tap`";
    // the job's own token only reads
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "      contents: read\n", "      contents: write\n"), "`bump` is not `contents: read` alone");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "      contents: read\n", "      contents: write\n"), "job `bump` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "      contents: read\n", "      contents: read\n      pull-requests: write\n"), "job `bump` holds `pull-requests: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "      contents: read\n", "      contents: read\n      id-token: write\n"), "job `bump` holds `id-token: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "    permissions:\n      contents: read\n", ""), "states no `permissions:`");
    // it runs only for a commit the plan released, on a push to main, not on a fork: the exact if of tag and publish
    const exact = "the job `bump` is not under its exact `if:`";
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", " && github.ref == 'refs/heads/main'", ""), exact);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", " && !github.event.repository.fork", ""), exact);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "needs.plan.outputs.released == 'true' && ", ""), exact);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "    if: ${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork && needs.tag.outputs.superseded != 'true' }}\n", ""), exact);
    // it waits for the plan, the tag, the publish and the tool; and nothing waits for it
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "needs: [plan, tag, publish, tool]", "needs: [plan, tag, tool]"), "`bump` does not wait for `publish`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "needs: [plan, tag, publish, tool]", "needs: [plan, publish, tool]"), "`bump` does not wait for `tag`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "needs: [plan, tag, publish, tool]", "needs: [tag, publish, tool]"), "`bump` does not wait for `plan`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "needs: [plan, tag, publish, tool]", "needs: [plan, tag, publish]"), "`bump` does not wait for `tool`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "needs: [plan, tag, verify, tool]", "needs: [plan, tag, verify, tool, bump]"), "`site` waits for `bump`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "needs: [plan, tag, verify, tool]", "needs: [plan, tag, verify, tool, bump]"), "`publish` waits for `bump`");
    // each input of the mint is exact: the repository is the variable's (an empty list would reach every repository of the installation), the scopes are the two
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "repositories: ${{ vars.BUMP_REPOSITORY }}\n", ""), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "repositories: ${{ vars.BUMP_REPOSITORY }}", "repositories: other-repo"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "repositories: ${{ vars.BUMP_REPOSITORY }}", "repositories: buildrules"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "repositories: ${{ vars.BUMP_REPOSITORY }}", "repositories: ${{ vars.BUMP_REPOSITORY }},buildrules"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "owner: ${{ github.repository_owner }}\n", ""), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "owner: ${{ github.repository_owner }}\n", "owner: other\n"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "app-id: ${{ vars.RELEASE_BOT_APP_ID }}", "app-id: 5395718"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "permission-pull-requests: write\n", ""), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "permission-pull-requests: write\n", "permission-pull-requests: read\n"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "permission-contents: write\n", "permission-contents: read\n"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "permission-pull-requests: write\n", "permission-pull-requests: write\n          permission-actions: write\n"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "permission-pull-requests: write\n", "permission-pull-requests: write\n          permission-actions: write\n"), key_token);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0", "v3.2.0"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}", "private-key: ${{ secrets.OTHER_KEY }}"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}", "private-key: ${{ secrets.OTHER_KEY }}"), "reads a secret");
    // the token is the GH_TOKEN of the bump step and nothing else's
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "GH_TOKEN: ${{ steps.bump_bot.outputs.token }}", "GH_TOKEN: ${{ github.token }}"), "does not take the bot's token as its GH_TOKEN");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "GH_TOKEN: ${{ steps.bump_bot.outputs.token }}", "GH_TOKEN: ${{ github.token }}"), "uses GITHUB_TOKEN");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "GH_TOKEN: ${{ steps.bump_bot.outputs.token }}", "GH_TOKEN: ${{ steps.bot.outputs.token }}"), "does not take the bot's token as its GH_TOKEN");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "      TAG: ${{ needs.tag.outputs.tag }}\n", "      TAG: ${{ needs.tag.outputs.tag }}\n      GH_TOKEN: ${{ steps.bump_bot.outputs.token }}\n"), "uses the bot's token other than once, in the bump step");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "GH_TOKEN: ${{ github.token }}", "GH_TOKEN: ${{ steps.bump_bot.outputs.token }}"), key_token);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "GH_TOKEN: ${{ steps.bot.outputs.token }}", "GH_TOKEN: ${{ steps.bump_bot.outputs.token }}"), key_token);
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "GH_TOKEN: ${{ github.token }}", "GH_TOKEN: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}"), key_token);
    // a second mint anywhere else
    const second_mint = "      - uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n        with:\n          app-id: 1\n      - run: chmod +x tool/release\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "      - run: chmod +x tool/release\n", second_mint), "used other than three times, in `tag`, `bump` and `tap`");
    // the repository is named before a token exists, and the name is the owner's own plus the variable
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "      - name: The internal repository is named\n        run: tool/release bump-check --internal-repo \"$INTERNAL_REPO\"\n", ""), "does not check, in a step of its own");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "tool/release bump-check ", "echo bump-check "), "does not check, in a step of its own");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "tool/release bump-check ", "echo bump-check "), "`bump` does not run `tool/release bump-check");
    {
        const moved = try mutateIn(a, r.wf, "bump", "      - name: The internal repository is named\n        run: tool/release bump-check --internal-repo \"$INTERNAL_REPO\"\n", "");
        const after = try mutateIn(a, moved, "bump", "--submodule buildrules --workdir \"$RUNNER_TEMP/bump\"\n", "--submodule buildrules --workdir \"$RUNNER_TEMP/bump\"\n      - name: The internal repository is named\n        run: tool/release bump-check --internal-repo \"$INTERNAL_REPO\"\n");
        try expectFinding(a, r, after, "mints the bot's token before it checks that the internal repository is named");
    }
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "INTERNAL_REPO: ${{ github.repository_owner }}/${{ vars.BUMP_REPOSITORY }}", "INTERNAL_REPO: org/internal-repo"), "does not name the internal repository");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "INTERNAL_REPO: ${{ github.repository_owner }}/${{ vars.BUMP_REPOSITORY }}", "INTERNAL_REPO: ${{ github.repository_owner }}/${{ vars.OTHER }}"), "does not name the internal repository");
    // the arguments the guard of the internal repository depends on
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", " --submodule buildrules", " --submodule other"), "does not pass --submodule buildrules");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "--sha \"$GITHUB_SHA\"", "--sha \"$TAG\""), "does not pass --sha \"$GITHUB_SHA\"");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "--tag \"$TAG\" ", ""), "does not pass --tag \"$TAG\"");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "--repo \"$GITHUB_REPOSITORY\" ", ""), "does not pass --repo \"$GITHUB_REPOSITORY\"");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "--internal-repo \"$INTERNAL_REPO\" --submodule", "--submodule"), "does not pass --internal-repo \"$INTERNAL_REPO\"");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "tool/release bump-internal ", "echo bump-internal "), "`bump` does not run `tool/release bump-internal");
    // it holds a write token: no buck2 and no action but the download and the mint, single invocations
    const buck2_run = "      - run: ./buck2 build --console simple -c buildrules_re.mode=local //tools/release:release\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "      - run: chmod +x tool/release\n", buck2_run), "job `bump` holds a write scope and runs buck2");
    const cache = "      - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: x\n          key: x\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "      - run: chmod +x tool/release\n", cache), "job `bump` holds a write scope and uses actions/cache");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "      - run: chmod +x tool/release\n", "      - run: chmod +x tool/release && echo hi\n"), "more than one invocation");
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
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "    if: ${{ needs.plan.outputs.released == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/main' && !github.event.repository.fork && needs.tag.outputs.superseded != 'true' }}\n", ""), exact_pub);
}

test "rule: the order gate -> plan -> build-cli -> beta -> gamma -> archive -> attest -> verify -> tag -> publish, and nothing before the tag waits for it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    // plan after the gate and the tool; the stages after the plan, each after the one before it
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "needs: [gate, tool]", "needs: [tool]"), "`plan` does not wait for `gate`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "needs: [gate, tool]", "needs: [gate]"), "`plan` does not wait for `tool`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "needs: [plan, tool]", "needs: [tool]"), "`build-cli` does not wait for `plan`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "needs: [plan, tool]", "needs: [plan]"), "`build-cli` does not wait for `tool`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "needs: [plan, build-cli]", "needs: [plan]"), "`beta` does not wait for `build-cli`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "needs: [plan, build-cli]", "needs: [build-cli]"), "`beta` does not wait for `plan`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "needs: [plan, beta, tool]", "needs: [plan, tool]"), "`gamma` does not wait for `beta`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "needs: [plan, beta, tool]", "needs: [plan, beta]"), "`gamma` does not wait for `tool`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "needs: [plan, beta, tool]", "needs: [beta, tool]"), "`gamma` does not wait for `plan`");
    const archive_needs = [_][]const u8{ "plan", "build-cli", "beta", "gamma", "tool" };
    for (archive_needs) |dep| {
        var list = std.ArrayList(u8).init(a);
        try list.appendSlice("needs: [");
        var first = true;
        for (archive_needs) |other| {
            if (std.mem.eql(u8, other, dep)) continue;
            if (!first) try list.appendSlice(", ");
            first = false;
            try list.appendSlice(other);
        }
        try list.appendSlice("]");
        const want = try std.fmt.allocPrint(a, "`archive` does not wait for `{s}`", .{dep});
        try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "needs: [plan, build-cli, beta, gamma, tool]", list.items), want);
    }
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "needs: [plan, archive, tool]", "needs: [plan, tool]"), "`attest` does not wait for `archive`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "needs: [plan, attest, tool]", "needs: [plan, tool]"), "`verify` does not wait for `attest`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "needs: [plan, verify, tool]", "needs: [plan, tool]"), "`tag` does not wait for `verify`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "needs: [plan, verify, tool]", "needs: [verify, tool]"), "`tag` does not wait for `plan`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "needs: [plan, tag, verify, tool]", "needs: [plan, verify, tool]"), "`publish` does not wait for `tag`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "needs: [plan, tag, verify, tool]", "needs: [plan, tag, tool]"), "`publish` does not wait for `verify`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "needs: [plan, tag, verify, tool]", "needs: [plan, tag, tool]"), "`site` does not wait for `verify`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "needs: [plan, tag, verify, tool]", "needs: [plan, verify, tool]"), "`site` does not wait for `tag`");
    // nothing before the tag waits for it: a failure there must leave no tag
    const waits = "waits for `tag` or `publish`";
    for ([_][]const u8{ "plan", "build-cli", "beta", "gamma", "archive", "attest", "verify" }) |name| {
        const header = try std.fmt.allocPrint(a, "\n  {s}:\n    needs: [", .{name});
        const at = std.mem.indexOf(u8, r.wf, header) orelse return error.MutantDidNotApply;
        const inner = at + header.len;
        const wf = try std.mem.concat(a, u8, &.{ r.wf[0..inner], "tag, ", r.wf[inner..] });
        try expectFinding(a, r, wf, waits);
    }
    // the plan only reads and cannot be skipped
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "      contents: read\n", "      contents: write\n"), "job `plan` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "    timeout-minutes: 15\n", "    timeout-minutes: 15\n    if: ${{ vars.X == '' }}\n"), "`plan` has an `if:`");
    // the archive and the verifies are of the commit: no ref of a tag (it does not exist yet), and the sha is passed
    const checkout = "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n";
    for ([_][]const u8{ "archive", "verify", "build-cli" }) |name| {
        try expectFinding(a, r, try mutateIn(a, r.wf, name, checkout, checkout ++ "          ref: refs/tags/${{ needs.plan.outputs.tag }}\n"), "reads a tag by ref");
    }
    for ([_][]const u8{ "archive", "verify" }) |name| {
        const want = try std.fmt.allocPrint(a, "`{s}` does not pass `--sha", .{name});
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "--sha \"$CANDIDATE\" ", ""), want);
    }
    // gate is a call of ci.yml, with read access only
    try expectFinding(a, r, try mutate(a, r.wf, "    uses: ./.github/workflows/ci.yml\n", "    runs-on: ubuntu-latest\n"), "`gate` does not call");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gate", "      contents: read\n", "      contents: read\n      packages: read\n"), "`gate` is not `contents: read` alone");
    // gate and tool are never skipped (a skipped need skips the plan, and a release would silently not happen)
    try expectFinding(a, r, try mutateIn(a, r.wf, "gate", "    permissions:\n", "    if: ${{ github.event_name == 'push' }}\n    permissions:\n"), "`gate` has an `if:`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tool", "    runs-on: ubuntu-latest\n", "    if: ${{ vars.SKIP != 'true' }}\n    runs-on: ubuntu-latest\n"), "`tool` has an `if:`");
    // ci.yml must be callable
    try expectFinding(a, .{ .wf = r.wf, .ds = r.ds, .ci = "on:\n  pull_request:\n" }, r.wf, "no `workflow_call:` trigger");
    // a missing job
    for (all_jobs) |name| {
        const from = try std.fmt.allocPrint(a, "\n  {s}:\n", .{name});
        const to = try std.fmt.allocPrint(a, "\n  {s}_x:\n", .{name});
        const want = try std.fmt.allocPrint(a, "the job `{s}` is missing", .{name});
        try expectFinding(a, r, try mutate(a, r.wf, from, to), want);
    }
}


test "rule: beta is a call of beta.yml with the command line build-cli built, the farm leg's token and nothing else, for a released commit only" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, try mutate(a, r.wf, "    uses: ./.github/workflows/beta.yml\n", "    runs-on: ubuntu-latest\n"), "`beta` does not call");
    // for a released commit alone: no other condition, and not the plain `released` clause gone
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "    if: " ++ released_if ++ "\n", "    if: ${{ vars.FARM_ADDRESS != '' }}\n"), "`beta` is not under the `if:`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "    if: " ++ released_if ++ "\n", ""), "`beta` is not under the `if:`");
    // the token
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "      id-token: write\n", ""), "`beta` is not `contents: read` and `id-token: write` alone");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "      id-token: write\n", "      id-token: write\n      packages: read\n"), "`beta` is not `contents: read` and `id-token: write` alone");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "      contents: read\n", "      contents: write\n"), "job `beta` holds `contents: write`");
    // it walks the file build-cli built, not one it builds itself, and the name is the one build-cli uploads
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "    with:\n      cli-bins-artifact: release-cli-bins\n      cli-artifact: release-cli-bin\n", ""), "`beta` does not run the command line that `build-cli` built");
    // and the two native legs run the files of the other two targets of that same build, not ones the beta builds itself
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "      cli-bins-artifact: release-cli-bins\n", ""), "`beta` does not run the command line that `build-cli` built");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "cli-bins-artifact: release-cli-bins", "cli-bins-artifact: release-cli-bin"), "`beta` does not run the command line that `build-cli` built");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "cli-bins-artifact: release-cli-bins", "cli-bins-artifact: \"\""), "`beta` does not run the command line that `build-cli` built");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "cli-artifact: release-cli-bin", "cli-artifact: release-cli-tarballs"), "`beta` does not run the command line that `build-cli` built");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "cli-artifact: release-cli-bin", "cli-artifact: \"\""), "`beta` does not run the command line that `build-cli` built");
    // the workflow it calls must be pinned like any other local reference: only these three are allowed
    try expectFinding(a, r, try mutate(a, r.wf, "uses: ./.github/workflows/beta.yml", "uses: ./.github/workflows/beta2.yml"), "not pinned");
}

test "rule: gamma holds the farm's token and no more, runs for a released commit only, and checks the action it uses before it uses it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    // the token
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "      contents: read\n      id-token: write\n", "      contents: write\n      id-token: write\n"), "job `gamma` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "      contents: read\n      id-token: write\n", "      contents: read\n"), "`gamma` is not `contents: read` and `id-token: write` alone");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "      id-token: write\n", "      id-token: write\n      attestations: write\n"), "job `gamma` holds `attestations: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tool", "      contents: read\n", "      contents: read\n      id-token: write\n"), "job `tool` holds `id-token: write`");
    // it runs for a released commit and for nothing narrower: a farm variable in the condition would let an unconfigured farm pass
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "    if: " ++ released_if ++ "\n", "    if: ${{ needs.plan.outputs.released == 'true' && vars.FARM_ADDRESS != '' }}\n"), "`gamma` is not under the `if:`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "    if: " ++ released_if ++ "\n", ""), "`gamma` is not under the `if:`");
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
    // it builds the pushed commit as the candidate
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "--candidate \"$CANDIDATE\"", "--candidate \"$GITHUB_SHA\""), "does not build the pushed commit as the candidate");
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
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "if: ${{ needs.plan.outputs.released == 'true' && needs.tag.outputs.superseded != 'true' }}", "if: ${{ needs.tag.outputs.superseded != 'true' }}"), "`site` runs even when the plan released nothing");
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "tool/release site ", "echo site "), "`site` does not run `tool/release site");
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "name: release-site", "name: other"), "does not upload the artifact `release-site`");
}

test "rule: a release is made only for a commit the plan released, and no job runs after a red one" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    for ([_][]const u8{ "build-cli", "archive", "site" }) |name| {
        const want = try std.fmt.allocPrint(a, "`{s}` runs even when the plan released nothing", .{name});
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "needs.plan.outputs.released == 'true'", "true"), want);
    }
    for ([_][]const u8{ "attest", "verify", "tag", "publish", "bump" }) |name| {
        const want = try std.fmt.allocPrint(a, "`{s}` is not under its exact `if:`", .{name});
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "needs.plan.outputs.released == 'true' && ", ""), want);
    }
    // no status function lets a job run after a red one
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "if: ${{ needs.plan.outputs.released == 'true' && needs.plan.outputs.complete != 'true' }}", "if: ${{ always() && needs.plan.outputs.released == 'true' }}"), "`always()`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "if: ${{ needs.plan.outputs.released", "if: ${{ !failure() && needs.plan.outputs.released"), "`failure()`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "if: ${{ needs.plan.outputs.released", "if: ${{ failure() || needs.plan.outputs.released"), "`failure()`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "if: ${{ needs.plan.outputs.released == 'true' && needs.plan.outputs.complete != 'true' }}", "if: ${{ cancelled() || needs.plan.outputs.released == 'true' }}"), "`cancelled()`");
}

test "rule: no job that writes or signs runs for anything but a push to main, and no dry form remains" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    // each job that writes or signs is under a push to main of this repository, whichever part of the condition goes
    for ([_][]const u8{ "attest", "verify", "tag", "publish", "bump" }) |name| {
        const want = try std.fmt.allocPrint(a, "the job `{s}` is not under its exact `if:`", .{name});
        try expectFinding(a, r, try mutateIn(a, r.wf, name, " && github.event_name == 'push'", ""), want);
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "github.event_name == 'push'", "github.event_name != 'pull_request'"), want);
        try expectFinding(a, r, try mutateIn(a, r.wf, name, " && github.ref == 'refs/heads/main'", ""), want);
        try expectFinding(a, r, try mutateIn(a, r.wf, name, " && !github.event.repository.fork", ""), want);
    }
    // the event is tested nowhere else: a job that behaves differently on a pull request would be a stage the release does not have
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "    if: " ++ released_if ++ "\n", "    if: ${{ needs.plan.outputs.released == 'true' && github.event_name == 'pull_request' }}\n"), "the workflow names a pull request");
    // the dry forms are gone: nothing is told `--dry true`, and the plan is a real run
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "--dry false", "--dry true"), "the `--dry` flags are not exactly");
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "--dry false", "--dry \"$DRY\""), "the `--dry` flags are not exactly");
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "    env:\n", "    env:\n      DRY: ${{ vars.DRY_RUN }}\n"), "not told it is a real run");
    // attest signs for real, and never dry
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "tool/release sign --dist dist --dry false", "tool/release sign --dist dist --dry true"), "`attest` does not sign");
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "tool/release sign --dist dist --dry false", "tool/release sign --dist dist"), "`attest` does not sign");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "--dry false", "--dry true"), "the `--dry` flags are not exactly");
    // verify installs cosign to check the signatures; the dry twin has none to check
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", cosign_step, ""), "does not install cosign");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", cosign_step, ""), "used other than twice");
}

test "rule: RELEASE_FREEZE is read in the plan and nowhere else, and the plan is never a dry run" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    // read elsewhere (a freeze that some stages honour and others do not), or not read at all
    try expectFinding(a, r, try mutateIn(a, r.wf, "gamma", "    env:\n", "    env:\n      FROZEN: ${{ vars.RELEASE_FREEZE }}\n"), "RELEASE_FREEZE is read other than once");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "    env:\n", "    env:\n      FROZEN: ${{ vars.RELEASE_FREEZE }}\n"), "RELEASE_FREEZE is read other than once");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "if: ${{ needs.plan.outputs.released == 'true' && needs.plan.outputs.complete != 'true' }}", "if: ${{ needs.plan.outputs.released == 'true' && vars.RELEASE_FREEZE != 'true' }}"), "RELEASE_FREEZE is read other than once");
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "      FREEZE: ${{ vars.RELEASE_FREEZE }}\n", ""), "RELEASE_FREEZE is read other than once");
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "      FREEZE: ${{ vars.RELEASE_FREEZE }}\n", ""), "does not pass RELEASE_FREEZE to the plan");
    // read but not passed, or passed a constant
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", " --freeze \"$FREEZE\"", ""), "does not pass RELEASE_FREEZE to the plan");
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "FREEZE: ${{ vars.RELEASE_FREEZE }}", "FREEZE: false"), "does not pass RELEASE_FREEZE to the plan");
    // the plan is a real run: the flag is the constant `false`, not a variable and not the event
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", " --dry false", " --dry true"), "not told it is a real run");
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", " --dry false", ""), "not told it is a real run");
}

test "rule: the workflow's concurrency is one group for every push and never cancels" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const need = "the workflow's concurrency is not";
    // a push to main that cancels the one before it would stop a release between its stages
    try expectFinding(a, r, try mutate(a, r.wf, "cancel-in-progress: false", "cancel-in-progress: true"), need);
    try expectFinding(a, r, try mutate(a, r.wf, "cancel-in-progress: false", "cancel-in-progress: ${{ github.event_name == 'push' }}"), need);
    const grp = "group: release-${{ github.event_name == 'push' && 'push' || github.run_id }}";
    // the per-commit group (two pushes run in parallel and plan the same number) is the defect this rule exists for
    try expectFinding(a, r, try mutate(a, r.wf, grp, "group: release-${{ github.sha }}"), need);
    try expectFinding(a, r, try mutate(a, r.wf, grp, "group: release"), need);
    try expectFinding(a, r, try mutate(a, r.wf, grp, "group: release-${{ github.ref }}"), need);
    try expectFinding(a, r, try mutate(a, r.wf, "\nconcurrency:\n  " ++ grp ++ "\n  cancel-in-progress: false\n", "\n"), need);
}

test "rule: the jobs that test the commit name the pushed commit, and the jobs that write name GITHUB_SHA" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    for ([_][]const u8{ "plan", "archive", "verify" }) |name| {
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "      CANDIDATE: ${{ github.sha }}\n", "      CANDIDATE: ${{ github.ref }}\n"), "does not name the commit as `CANDIDATE:");
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "          ref: ${{ github.sha }}\n", ""), "is not of `ref:");
    }
    for ([_][]const u8{ "archive", "verify" }) |name| {
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "--sha \"$CANDIDATE\"", "--sha \"$GITHUB_SHA\""), "does not pass `--sha");
    }
    for ([_][]const u8{ "tool", "build-cli", "gamma" }) |name| {
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "          ref: ${{ github.sha }}\n", ""), "is not of `ref:");
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "          ref: ${{ github.sha }}\n", "          ref: ${{ github.ref }}\n"), "is not of `ref:");
    }
    // a pull request's head is named nowhere: no pull request runs this workflow
    for ([_][]const u8{ "plan", "archive", "verify", "tool", "build-cli", "gamma" }) |name| {
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "          ref: ${{ github.sha }}\n", "          ref: ${{ github.event.pull_request.head.sha || github.sha }}\n"), "the workflow names a pull request");
    }
    // a job of the push alone names the pushed commit
    for ([_][]const u8{ "tag", "publish", "bump", "site" }) |name| {
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "--sha \"$GITHUB_SHA\"", "--sha \"$TAG\""), "must name `--sha \"$GITHUB_SHA\"`");
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "    env:\n", "    env:\n      CANDIDATE: ${{ github.sha }}\n"), "must name `--sha \"$GITHUB_SHA\"`");
    }
}

test "rule: the tag job settles the race of two pushes that planned the same number, and publish, site and bump use its outputs, not the plan's" {
    // The defect: the number is taken at the plan, long before the tag; a push that landed meanwhile took it, the tag job went red with TagNamesOtherCommit and
    // the later commit was never released. The job that tags (alone, in group `release`) decides from the tags as they are then; what follows must use its answer.
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const outs = "does not output `superseded`, `tag` and `number` of its step `settle`";
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      superseded: ${{ steps.settle.outputs.superseded }}\n", ""), outs);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      tag: ${{ steps.settle.outputs.tag }}\n", ""), outs);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "      number: ${{ steps.settle.outputs.number }}\n", ""), outs);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "steps.settle.outputs.tag", "steps.bot.outputs.tag"), outs);
    const step = "is not `id: settle` with `--output";
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "        id: settle\n", ""), step);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", " --output \"$GITHUB_OUTPUT\"", ""), step);
    for ([_][]const u8{ "publish", "bump", "site" }) |name| {
        const own = try std.fmt.allocPrint(a, "the job `{s}` does not take its tag from the tag job", .{name});
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "      TAG: ${{ needs.tag.outputs.tag }}\n", "      TAG: ${{ needs.plan.outputs.tag }}\n"), own);
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "      TAG: ${{ needs.tag.outputs.tag }}\n", "      TAG: ${{ needs.plan.outputs.tag }}\n"), "reads the plan's tag");
        // the plan's tag read beside the tag job's is found too
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "    env:\n", "    env:\n      OLD: ${{ needs.plan.outputs.tag }}\n"), "reads the plan's tag");
        const skip = try std.fmt.allocPrint(a, "the job `{s}` does not skip a superseded run", .{name});
        try expectFinding(a, r, try mutateIn(a, r.wf, name, " && needs.tag.outputs.superseded != 'true'", ""), skip);
    }
    // the exact `if:` of publish and bump holds the clause, whatever else it says
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", " && needs.tag.outputs.superseded != 'true'", ""), "`publish` is not under its exact `if:`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", " && needs.tag.outputs.superseded != 'true'", ""), "`bump` is not under its exact `if:`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "needs.tag.outputs.superseded != 'true'", "needs.tag.outputs.superseded == 'true'"), "`publish` is not under its exact `if:`");
}

test "rule: the tag job is in the release concurrency group and none is cancelled" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const need = "concurrency group `release` with `cancel-in-progress: false`";
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "cancel-in-progress: false", "cancel-in-progress: true"), need);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "group: release", "group: release-${{ github.sha }}"), need);
    // the workflow's own group on the tag job: it would wait on its own run
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "group: release", "group: release-push"), need);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "group: release", "group: release-${{ github.event_name == 'push' && 'push' || github.run_id }}"), need);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "    concurrency:\n      group: release\n      cancel-in-progress: false\n", ""), need);
}

test "rule: the signature and the attestation are made in attest, once, in that order, by a job that runs no buck2" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, try mutate(a, r.wf, "actions/attest-build-provenance@", "actions/attest-sbom@"), "does not attest");
    // a second attestation elsewhere
    const second = "      - uses: actions/attest-build-provenance@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2\n        with:\n          subject-path: x\n      - run: chmod +x buck2 tool/release\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      - run: chmod +x buck2 tool/release tool/channels\n", second), "used other than once");
    // the subject: the archive, the three tarballs (one glob), the two .debs (another) and SHA256SUMS; a narrower subject leaves files unattested
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "            dist/buildrules-*.tar.gz\n", "            dist/buildrules-0.0.1.tar.gz\n"), "does not attest `dist/buildrules-*.tar.gz`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "            dist/buildrules_*.deb\n", ""), "`dist/buildrules_*.deb` (the two .debs)");
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "            dist/buildrules_*.deb\n", "            dist/buildrules_0.0.1_amd64.deb\n"), "`dist/buildrules_*.deb` (the two .debs)");
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "            dist/SHA256SUMS\n", ""), "does not attest `dist/buildrules-*.tar.gz`");
    // cosign is installed in attest, and sign comes before the attestation, and both before the upload
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", cosign_step, ""), "does not install cosign");
    // each install names the cosign release, and a different release, a dropped input or a leftover default each turn it red
    const unnamed = "      - uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", cosign_step, unnamed), "does not name `cosign-release: 'v3.0.6'`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", cosign_step, unnamed), "does not name `cosign-release: 'v3.0.6'`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "cosign-release: 'v3.0.6'", "cosign-release: 'v3.0.5'"), "does not name `cosign-release: 'v3.0.6'`");
    {
        const sign_step = "      - name: Sign the seven files, keyless\n        run: tool/release sign --dist dist --dry false\n";
        const moved = try mutateIn(a, r.wf, "attest", sign_step, "");
        const after = try mutateIn(a, moved, "attest", "      - uses: actions/upload-artifact@", sign_step ++ "      - uses: actions/upload-artifact@");
        try expectFinding(a, r, after, "does not sign, then attest, then upload `release-dist`");
    }
    // attest signs what archive made and nothing else
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "name: release-unsigned", "name: release-cli-tarballs"), "does not sign what `archive` made");
    // it runs no buck2 and uses no action but the five it needs
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "      - run: chmod +x tool/release\n", "      - run: ./buck2 build -c buildrules_re.mode=local //x:y\n"), "job `attest` holds a write scope and runs buck2");
    const cache = "      - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: x\n          key: x\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "      - run: chmod +x tool/release\n", cache), "job `attest` holds a write scope and uses actions/cache");
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "      - run: chmod +x tool/release\n", "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          persist-credentials: false\n"), "job `attest` holds a write scope and uses actions/checkout");
}

test "rule: the binaries are built stamped, packaged, run by the beta, checked against their tarball, built again and compared" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    // build-cli: the planned number, the stamp, the one target that builds all three, the packaging, the two artifacts
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", " -c \"buildrules.release_version=$NUMBER\"", ""), "`build-cli` does not build //cli:release_binaries with the planned version stamped in");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "needs.plan.outputs.number", "needs.plan.outputs.tag"), "`build-cli` does not take the planned version from the plan");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "//cli:release_binaries", "//cli:buildrules"), "`build-cli` does not build //cli:release_binaries");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "--out cli-bins //cli", "--out other //cli"), "`build-cli` does not build //cli:release_binaries");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", " -c buildrules_re.mode=local", ""), "does not pass `-c buildrules_re.mode=local`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "tool/release package-all --version \"$NUMBER\"", "tool/release package-all --version \"$TAG\""), "`build-cli` does not package the three tarballs");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", " --native linux-x86_64", " --native linux-x86_64,macos-arm64"), "`build-cli` does not package the three tarballs");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", " --native linux-x86_64", ""), "`build-cli` does not package the three tarballs");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "name: release-cli-tarballs", "name: other"), "`build-cli` does not upload the three tarballs");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "name: release-cli-bin", "name: other"), "`build-cli` does not upload the linux-x86_64 binary");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "name: release-cli-bins\n          path: cli-bins\n", "name: release-cli-bins\n          path: cli-bins/linux-x86_64\n"), "`build-cli` does not upload the directory of the three binaries");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "name: release-cli-bins", "name: other-bins"), "`build-cli` does not upload the directory of the three binaries");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "path: cli-bins/linux-x86_64/buildrules", "path: cli-bins/macos-arm64/buildrules"), "`build-cli` does not upload the linux-x86_64 binary");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "needs: [plan, tool]", "needs: [plan]"), "`build-cli` does not wait for `tool`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "tool/release package-all ", "echo package-all "), "`build-cli` does not run `tool/release package-all");
    // archive: the tarballs and the file the beta ran, the check that the tarball holds that file, only those tested attested, in this order
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "name: release-cli-tarballs\n          path: dist", "name: release-cli-tarballs\n          path: elsewhere"), "does not download the tarballs");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "name: release-cli-bin\n          path: ran", "name: release-cli-tarballs\n          path: ran"), "does not download the file the beta ran");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", " --ran-binary ran/buildrules", ""), "does not check that the linux-x86_64 tarball holds the file the beta ran");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "tool/release record ", "echo record "), "does not check that the linux-x86_64 tarball holds the file the beta ran");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", " --targets linux-x86_64", ""), "does not hold the attested tarballs to the ones the beta ran");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "tool/release tested ", "echo tested "), "does not run `tool/release tested");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "tool/release sums ", "echo sums "), "does not run `tool/release sums");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "name: release-unsigned", "name: release-dist"), "does not upload `dist` as the artifact `release-unsigned`");
    {
        // sums before tested: the order of the tool is archive, record, tested, sums
        const sums = "      - name: SHA256SUMS over the archive, the three tarballs and the two .debs\n        run: tool/release sums --dist dist\n";
        const moved = try mutateIn(a, r.wf, "archive", sums, "");
        const before = try mutateIn(a, moved, "archive", "      - name: The tarball to attest holds the file the beta ran\n", sums ++ "      - name: The tarball to attest holds the file the beta ran\n");
        try expectFinding(a, r, before, "has no `tool/release sums ` after the step before it");
    }
    for ([_][]const u8{ "verify" }) |name| {
        try expectFinding(a, r, try mutateIn(a, r.wf, name, " -c \"buildrules.release_version=$NUMBER\"", ""), "does not build the three binaries again with the planned version stamped in");
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "--out rebuilt-bins //cli:release_binaries", "--out rebuilt-bins //cli:buildrules"), "does not build the three binaries again");
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "--bins rebuilt-bins ", "--bins cli-bins "), "does not package the second build's three tarballs");
        try expectFinding(a, r, try mutateIn(a, r.wf, name, " --rebuilt rebuilt-dist", ""), "does not pass `--cli rebuilt-bins/linux-x86_64/buildrules --rebuilt rebuilt-dist`");
        try expectFinding(a, r, try mutateIn(a, r.wf, name, " --cli rebuilt-bins/linux-x86_64/buildrules", " --cli built-cli/buildrules"), "does not pass `--cli rebuilt-bins/linux-x86_64/buildrules --rebuilt rebuilt-dist`");
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "name: release-dist", "name: release-unsigned"), "does not read `release-dist` (what attest made) alone");
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "needs.plan.outputs.number", "needs.plan.outputs.tag"), "does not take the planned version from the plan");
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "needs: [plan, ", "needs: ["), "does not wait for `plan`");
        const want = try std.fmt.allocPrint(a, "`{s}` does not run `tool/release verify", .{name});
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "tool/release verify ", "echo verify "), want);
    }
    // publish and site read the files that were signed and verified, not those before the signing
    for ([_][]const u8{ "publish", "site" }) |name| {
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "name: release-dist", "name: release-unsigned"), "does not read `release-dist`");
    }
    // the number comes from the plan
    try expectFinding(a, r, try mutate(a, r.wf, "      number: ${{ steps.version.outputs.number }}\n", ""), "`plan` does not output the version number");
}

test "rule: a complete release is not built again, and the stages after the build wait for it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    // the plan says whether the release is complete, and is able to find out
    try expectFinding(a, r, try mutate(a, r.wf, "      complete: ${{ steps.version.outputs.complete }}\n", ""), "`plan` does not output `complete`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", " --repo \"$GITHUB_REPOSITORY\" ", " "), "`plan` is not told the repository");
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "          GH_TOKEN: ${{ github.token }}\n", ""), "`plan` has no `GH_TOKEN");
    // the four stages that build or test the commit are skipped for a complete release, under that `if:` alone
    for ([_][]const u8{ "build-cli", "beta", "gamma", "archive" }) |name| {
        try expectFinding(a, r, try mutateIn(a, r.wf, name, " && needs.plan.outputs.complete != 'true'", ""), "is not under the `if:`");
        try expectFinding(a, r, try mutateIn(a, r.wf, name, "needs.plan.outputs.complete != 'true'", "needs.plan.outputs.complete == 'true'"), "is not under the `if:`");
    }
    // and nothing after them can run without them: each waits for the one before, and none carries a status function that would run it anyway
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "needs: [plan, build-cli, beta, gamma, tool]", "needs: [plan, tool]"), "the job `archive` does not wait for");
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "needs: [plan, archive, tool]", "needs: [plan, tool]"), "the job `attest` does not wait for `archive`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "needs.plan.outputs.released == 'true' &&", "always() && needs.plan.outputs.released == 'true' &&"), "`always()`");
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
    try expectFinding(a, r, try mutateIn(a, r.wf, "attest", "tool/release sign ", "echo sign "), "`attest` does not run");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tag", "tool/release tag ", "echo tag "), "`tag` does not run");
    try expectFinding(a, r, try mutateIn(a, r.wf, "plan", "tool/release plan ", "echo plan "), "`plan` does not run");
    // one invocation per run line: no chain, no pipe, no block
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      - run: chmod +x tool/release\n", "      - run: chmod +x tool/release && echo hi\n"), "more than one invocation");
    try expectFinding(a, r, try mutateIn(a, r.wf, "archive", "      - run: chmod +x tool/release\n", "      - run: echo a; echo b\n"), "more than one invocation");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      - run: chmod +x buck2 tool/release tool/channels\n", "      - run: cat x | wc -l\n"), "more than one invocation");
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
    // the apt signing key is a secret of the index jobs and of no other job
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "GH_TOKEN: ${{ github.token }}", "GH_TOKEN: ${{ secrets.APT_GPG_PASSPHRASE }}"), "reads the apt signing key");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "GH_TOKEN: ${{ github.token }}", "GH_TOKEN: ${{ secrets.APT_GPG_PRIVATE_KEY }}"), "only the `apt-index` jobs may");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index", "APT_GPG_PASSPHRASE: ${{ secrets.APT_GPG_PASSPHRASE }}", "APT_GPG_PASSPHRASE: ${{ secrets.OTHER }}"), "reads a secret");
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
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "    needs: [plan, build-cli]\n", "    needs: [plan, build-cli]\n    continue-on-error: true\n"), rule);
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

test "rule: a cosign bundle is named <file>.sigstore.json, for the files release sign writes and no other spelling" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const step = "      - name: Upload {s}\n        run: chmod +x tool/release\n";
    // The names `release sign` writes are accepted, written out or with the version and target as variables.
    for ([_][]const u8{
        "SHA256SUMS.sigstore.json",
        "dist/SHA256SUMS.sigstore.json",
        "dist/buildrules-0.0.7.tar.gz.sigstore.json",
        "dist/buildrules-${{needs.plan.outputs.number}}.tar.gz.sigstore.json",
        "dist/buildrules-cli-0.0.7-linux-x86_64.tar.gz.sigstore.json",
        "dist/buildrules-cli-0.0.7-linux-aarch64.tar.gz.sigstore.json",
        "dist/buildrules-cli-0.0.7-macos-arm64.tar.gz.sigstore.json",
        "dist/buildrules-cli-${{needs.plan.outputs.number}}-linux-x86_64.tar.gz.sigstore.json",
        "dist/buildrules-cli-${{needs.plan.outputs.number}}-${{matrix.target}}.tar.gz.sigstore.json",
        "dist/buildrules-cli-0.12.345-${{matrix.target}}.tar.gz.sigstore.json",
        "dist/buildrules_0.0.7_amd64.deb.sigstore.json",
        "dist/buildrules_0.0.7_arm64.deb.sigstore.json",
        "dist/buildrules_${{needs.plan.outputs.number}}_amd64.deb.sigstore.json",
        "dist/buildrules_${{needs.plan.outputs.number}}_${{matrix.arch}}.deb.sigstore.json",
    }) |good| {
        const wf = try mutateIn(a, r.wf, "publish", "      - run: chmod +x tool/release\n", try std.fmt.allocPrint(a, step, .{good}));
        const f = try checkRelease(a, wf, r.ds, r.ci);
        for (f.items) |m| std.debug.print("finding: {s}\n", .{m});
        try t.expectEqual(@as(usize, 0), f.items.len);
    }
    // Any other spelling is a finding (each a mutant of a defect a release could ship: a name that `sign` never wrote).
    for ([_][]const u8{
        "SHA256SUMS.sigstore",
        "SHA256SUMS.bundle.sigstore.json",
        "SHA256SUMS.sigstore.json.json",
        "SHA256SUMS-sigstore.json",
        "SHA256SUMS.sigstore.jsn",
        "sha256sums.sigstore.json",
        "dist/*.sigstore.json",
        "dist/buildrules-0.0.7.tgz.sigstore.json",
        "dist/buildrules-0.0.7.tar.gz.sigstore",
        "dist/buildrules-cli-0.0.7-linux-x86.tar.gz.sigstore.json",
        "dist/buildrules-cli-0.0.7-windows-x86_64.tar.gz.sigstore.json",
        // the Intel macOS tarball was dropped from the release: its bundle is no file `release sign` writes
        "dist/buildrules-cli-0.0.7-macos-x86_64.tar.gz.sigstore.json",
        "dist/cli-0.0.7-linux-x86_64.tar.gz.sigstore.json",
        // a stem that is no release file: not a version, not a target, a glob, a missing piece
        "dist/buildrules-foo.tar.gz.sigstore.json",
        "dist/buildrules-0.0.tar.gz.sigstore.json",
        "dist/buildrules-0.0.7-rc1.tar.gz.sigstore.json",
        "dist/buildrules-00.0.7.tar.gz.sigstore.json",
        "dist/buildrules-v0.0.7.tar.gz.sigstore.json",
        "dist/buildrules-.tar.gz.sigstore.json",
        "dist/buildrules-*.tar.gz.sigstore.json",
        "dist/buildrules-cli-foo-linux-x86_64.tar.gz.sigstore.json",
        "dist/buildrules-cli-0.0.7-.tar.gz.sigstore.json",
        "dist/buildrules-cli-0.0.7.tar.gz.sigstore.json",
        "dist/buildrules-cli--linux-x86_64.tar.gz.sigstore.json",
        "dist/buildrules-cli-0.0.7-linux-x86_64-extra.tar.gz.sigstore.json",
        "dist/buildrules-cli-0.0.7-${{matrix.target}}x.tar.gz.sigstore.json",
        "dist/buildrules-cli-${{a}}${{b}}-linux-x86_64.tar.gz.sigstore.json",
        "dist/other.tar.gz.sigstore.json",
        "dist/buildrules-cli-0.0.7-linux-x86_64.zip.sigstore.json",
        // a .deb of an architecture the release has none for, a name with no version or no architecture, a version that is none, a glob
        "dist/buildrules_0.0.7_i386.deb.sigstore.json",
        "dist/buildrules_0.0.7.deb.sigstore.json",
        "dist/buildrules_amd64.deb.sigstore.json",
        "dist/buildrules_0.0_amd64.deb.sigstore.json",
        "dist/buildrules_v0.0.7_amd64.deb.sigstore.json",
        "dist/buildrules_*.deb.sigstore.json",
        "dist/other_0.0.7_amd64.deb.sigstore.json",
        "dist/buildrules_0.0.7_amd64.deb.sigstore",
        "dist/buildrules_0.0.7_amd64.rpm.sigstore.json",
    }) |bad| {
        try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "      - run: chmod +x tool/release\n", try std.fmt.allocPrint(a, step, .{bad})), "names a cosign bundle other than");
    }
    // The same in a job that does not write.
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      - run: chmod +x buck2 tool/release tool/channels\n", try std.fmt.allocPrint(a, step, .{"dist/SHA256SUMS.sig.sigstore.jsn"})), "names a cosign bundle other than");
    // The install of cosign names the word `sigstore` without naming a file: that action, pinned, is exempt, and no other sigstore action is.
    const installer = cosign_step;
    try t.expect(std.mem.indexOf(u8, r.wf, installer) != null);
    {
        const f = try checkRelease(a, r.wf, r.ds, r.ci);
        for (f.items) |m| try t.expect(std.mem.indexOf(u8, m, "cosign bundle") == null);
    }
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", installer, "      - uses: sigstore/gh-action-sigstore-python@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2\n"), "names a cosign bundle other than");
    // the exemption is for the `uses:` line alone: the same word in a run line or an input is checked
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "      - run: chmod +x buck2 tool/release tool/channels\n", "      - run: echo sigstore/cosign-installer\n"), "names a cosign bundle other than");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", installer, "      - uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2\n        with:\n          cosign-release: sigstore\n"), "names a cosign bundle other than");
}


// ---- the channels: tap, apt, and the .debs ---------------------------------------------------------------------------------------------

test "rule: the tap pull request runs after publish, with the release bot's token for the tap repository alone, minted in the second to last step and used by the last, and nothing waits for it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const mint = "does not mint the release bot's token";
    const key_token = "appears other than in `tag`, `bump` and `tap`";
    // the job's own token only reads
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "      contents: read\n", "      contents: write\n"), "`tap` is not `contents: read` alone");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "      contents: read\n", "      contents: write\n"), "job `tap` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "      contents: read\n", "      contents: read\n      pull-requests: write\n"), "job `tap` holds `pull-requests: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "      contents: read\n", "      contents: read\n      id-token: write\n"), "job `tap` holds `id-token: write`");
    // the exact if of publish, and the four jobs it waits for
    const exact = "the job `tap` is not under its exact `if:`";
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", " && github.ref == 'refs/heads/main'", ""), exact);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", " && needs.tag.outputs.superseded != 'true'", ""), exact);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "needs.plan.outputs.released == 'true' && ", ""), exact);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "needs: [plan, tag, publish, tool]", "needs: [plan, tag, tool]"), "`tap` does not wait for `publish`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "needs: [plan, tag, publish, tool]", "needs: [plan, publish, tool]"), "`tap` does not wait for `tag`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "needs: [plan, tag, publish, tool]", "needs: [tag, publish, tool]"), "`tap` does not wait for `plan`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "needs: [plan, tag, publish, tool]", "needs: [plan, tag, publish]"), "`tap` does not wait for `tool`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "needs: [plan, tag, verify, tool]", "needs: [plan, tag, verify, tool, tap]"), "`publish` waits for `tap`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "needs: [plan, tag, publish, tool]", "needs: [plan, tag, publish, tool, tap]"), "`bump` waits for `tap`");
    // it reads the key, so it is in the environment where the key lives
    const reads = "reads `RELEASE_BOT_*` but does not declare `environment: release`";
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "    environment: release\n", ""), "the job `tap` " ++ reads);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "    environment: release\n", "    environment: prod\n"), "the job `tap` " ++ reads);
    // each input of the mint is exact: the repository is the tap alone, the owner the repository's own, the scopes the two
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "repositories: homebrew-tap\n", ""), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "repositories: homebrew-tap\n", "repositories: buildrules\n"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "repositories: homebrew-tap\n", "repositories: homebrew-tap,buildrules\n"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "owner: ${{ github.repository_owner }}\n          repositories", "repositories"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "owner: ${{ github.repository_owner }}\n          repositories", "owner: other\n          repositories"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "app-id: ${{ vars.RELEASE_BOT_APP_ID }}", "app-id: 5395718"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "permission-pull-requests: write\n", ""), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "permission-pull-requests: write\n", "permission-pull-requests: read\n"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "permission-contents: write\n", "permission-contents: read\n"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "permission-pull-requests: write\n", "permission-pull-requests: write\n          permission-actions: write\n"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "permission-pull-requests: write\n", "permission-pull-requests: write\n          permission-actions: write\n"), key_token);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0", "v3.2.0"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}", "private-key: ${{ secrets.OTHER_KEY }}"), mint);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}", "private-key: ${{ secrets.OTHER_KEY }}"), "reads a secret");
    // the token is the GH_TOKEN of the tap step and nothing else's, and no other token stands in
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "GH_TOKEN: ${{ steps.tap_bot.outputs.token }}", "GH_TOKEN: ${{ github.token }}"), "does not take the bot's token as its GH_TOKEN");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "GH_TOKEN: ${{ steps.tap_bot.outputs.token }}", "GH_TOKEN: ${{ github.token }}"), "uses GITHUB_TOKEN");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "GH_TOKEN: ${{ steps.tap_bot.outputs.token }}", "GH_TOKEN: ${{ steps.bot.outputs.token }}"), "does not take the bot's token as its GH_TOKEN");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "      OWNER: ${{ github.repository_owner }}\n", "      OWNER: ${{ github.repository_owner }}\n      GH_TOKEN: ${{ steps.tap_bot.outputs.token }}\n"), "uses the bot's token other than once");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "GH_TOKEN: ${{ github.token }}", "GH_TOKEN: ${{ steps.tap_bot.outputs.token }}"), key_token);
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "GH_TOKEN: ${{ steps.bump_bot.outputs.token }}", "GH_TOKEN: ${{ steps.tap_bot.outputs.token }}"), key_token);
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "GH_TOKEN: ${{ github.token }}", "GH_TOKEN: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}"), key_token);
    // the tap step is the last step, and the formula is rendered before any token exists
    const use_end = "--workdir \"$RUNNER_TEMP/tap-clone\"\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", use_end, use_end ++ "      - run: chmod +x tool/tap\n"), "a step runs after the tap step, which holds the bot's token");
    {
        const render = "      - name: Render Formula/buildrules.rb from the verified SHA256SUMS, with the flags the tap's guard expects\n        run: " ++ tap_render ++ "\n";
        const moved = try mutateIn(a, r.wf, "tap", render, "");
        const after = try mutateIn(a, moved, "tap", use_end, use_end ++ render);
        try expectFinding(a, r, after, "mints the bot's token before it has rendered the formula");
        try expectFinding(a, r, after, "a step runs after the tap step");
    }
    // the render command is exact: every flag the tap's guard depends on
    const bad_render = "does not render the formula with exactly";
    for ([_][2][]const u8{
        .{ " --no-explicit-version", "" },
        .{ " --asset buildrules-cli", "" },
        .{ " --asset buildrules-cli", " --asset buildrules" },
        .{ "--name buildrules ", "--name other " },
        .{ " --license \"Apache-2.0\"", " --license \"MIT\"" },
        .{ " --homepage \"https://buildrules.dev\"", "" },
        .{ " --repo \"$GITHUB_REPOSITORY\"", "" },
        .{ " --version \"$NUMBER\"", " --version \"$TAG\"" },
        .{ "--sums dist/SHA256SUMS", "--sums SHA256SUMS" },
        .{ " --out tap/buildrules.rb", " --out buildrules.rb" },
        .{ " --no-explicit-version", " --url-base https://example.invalid/dl" },
        .{ "tool/channels formula ", "tool/channels formula --verbose " },
    }) |m| {
        try expectFinding(a, r, try mutateIn(a, r.wf, "tap", m[0], m[1]), bad_render);
    }
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "tool/channels formula ", "echo formula "), "`tap` does not run `tool/channels formula");
    // the arguments of the tap step
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", " --asset buildrules-cli --workdir", " --workdir"), "does not pass --asset buildrules-cli");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", " --formula buildrules ", " --formula other "), "does not pass --formula buildrules");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "--tap-repo \"$OWNER/homebrew-tap\"", "--tap-repo other/homebrew-tap"), "does not pass --tap-repo \"$OWNER/homebrew-tap\"");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "--formula-file tap/buildrules.rb", "--formula-file buildrules.rb"), "does not pass --formula-file tap/buildrules.rb");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "--version \"$NUMBER\" --formula-file", "--formula-file"), "does not pass --version \"$NUMBER\"");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "--repo \"$GITHUB_REPOSITORY\" --version", "--version"), "does not pass --repo \"$GITHUB_REPOSITORY\"");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "tool/tap --repo", "echo --repo"), "`tap` does not run `tool/tap ");
    // the version is the tag job's, not the plan's
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "NUMBER: ${{ needs.tag.outputs.number }}", "NUMBER: ${{ needs.plan.outputs.number }}"), "does not take the version from the tag job");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "NUMBER: ${{ needs.tag.outputs.number }}", "NUMBER: ${{ needs.plan.outputs.number }}"), "reads the plan's version");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "OWNER: ${{ github.repository_owner }}", "OWNER: other"), "does not take the version from the tag job");
    // the files are the verified ones, and the tools are the ones `tool` built; no checkout, no buck2, no other action
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "name: release-dist", "name: release-unsigned"), "does not read `release-dist`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "name: channel-tools", "name: other-tools"), "does not download the tools of the channels");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "      - run: chmod +x tool/channels tool/tap\n", "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          persist-credentials: false\n"), "job `tap` checks the repository out");
    const buck2_run = "      - run: ./buck2 build --console simple -c buildrules_re.mode=local //tools/release:release\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "      - run: chmod +x tool/channels tool/tap\n", buck2_run), "job `tap` holds a write scope and runs buck2");
    const cache = "      - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: x\n          key: x\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "tap", "      - run: chmod +x tool/channels tool/tap\n", cache), "job `tap` holds a write scope and uses actions/cache");
    // a fourth mint, or the job missing
    const second_mint = "      - uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n        with:\n          app-id: 1\n      - run: chmod +x tool/release\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "      - run: chmod +x tool/release\n", second_mint), "used other than three times, in `tag`, `bump` and `tap`");
    {
        const f = try checkRelease(a, try mutate(a, r.wf, "\n  tap:\n", "\n  tapped:\n"), r.ds, r.ci);
        var named = false;
        for (f.items) |m| {
            if (std.mem.indexOf(u8, m, "the job `tap` is missing") != null) named = true;
        }
        try t.expect(named);
    }
}

test "rule: the apt repository is published by three jobs per attempt, none holding both the signing key and the cloud role, every step behind the gate, the last attempt writing with --last" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    // no job holds the key and the role: the role named in the index job, the key read in a deploy job, the id-token in the index job
    const both = "holds both the apt signing key and the cloud role";
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index", "    env:\n      OWNER:", "    env:\n      APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}\n      OWNER:"), both);
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index", "    env:\n      OWNER:", "    env:\n      APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}\n      OWNER:"), "names the apt publish role: only the `apt-deploy-*` jobs may");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write", "    env:\n      AWS_DEFAULT_REGION: us-east-1\n", "    env:\n      AWS_DEFAULT_REGION: us-east-1\n      KEY: ${{ secrets.APT_GPG_PRIVATE_KEY }}\n"), both);
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write", "    env:\n      AWS_DEFAULT_REGION: us-east-1\n", "    env:\n      AWS_DEFAULT_REGION: us-east-1\n      KEY: ${{ secrets.APT_GPG_PRIVATE_KEY }}\n"), "only the `apt-index` jobs may");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read-2", "    env:\n      AWS_DEFAULT_REGION: us-east-1\n", "    env:\n      AWS_DEFAULT_REGION: us-east-1\n      KEY: ${{ secrets.APT_GPG_PRIVATE_KEY }}\n"), both);
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read", "    env:\n      AWS_DEFAULT_REGION: us-east-1\n", "    env:\n      AWS_DEFAULT_REGION: us-east-1\n      PASS: ${{ secrets.APT_GPG_PASSPHRASE }}\n"), "assumes the apt publish role and reads a secret");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index-3", "      contents: read\n", "      contents: read\n      id-token: write\n"), "job `apt-index-3` holds `id-token: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index-3", "      contents: read\n", "      contents: read\n      id-token: write\n"), "is given the means to reach the cloud");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index", "    env:\n      OWNER:", "    env:\n      AWS_ACCESS_KEY_ID: x\n      OWNER:"), "is given the means to reach the cloud");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index", "    environment: apt-signing\n", "    environment: apt-publish\n"), "does not declare `environment: apt-signing`");
    // the role named outside the apt-deploy jobs
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "GH_TOKEN: ${{ github.token }}", "GH_TOKEN: ${{ vars.APT_PUBLISH_ROLE_ARN }}"), "names the apt publish role");
    // id-token write: the deploy jobs hold it with contents read and nothing else
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read", "      id-token: write\n", ""), "`apt-deploy-read` is not `contents: read` and `id-token: write` alone");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write-2", "      id-token: write\n", "      id-token: write\n      packages: write\n"), "`apt-deploy-write-2` is not `contents: read` and `id-token: write` alone");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write-2", "      id-token: write\n", "      id-token: write\n      packages: write\n"), "job `apt-deploy-write-2` holds `packages: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index-2", "      contents: read\n", "      contents: write\n"), "`apt-index-2` is not `contents: read` alone");
    // the environments
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read", "    environment: apt-publish\n", ""), "the job `apt-deploy-read` assumes the apt publish role but does not declare `environment: apt-publish`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write-3", "    environment: apt-publish\n", "    environment: release\n"), "the job `apt-deploy-write-3` assumes the apt publish role but does not declare `environment: apt-publish`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index-2", "    environment: apt-signing\n", ""), "the job `apt-index-2` reads the apt signing key (`APT_GPG_*`) but does not declare `environment: apt-signing`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "    timeout-minutes: 15\n", "    timeout-minutes: 15\n    environment: apt-signing\n"), "the job `publish` declares `environment: apt-signing`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "    timeout-minutes: 60\n", "    timeout-minutes: 60\n    environment: apt-publish\n"), "the job `verify` declares `environment: apt-publish`");
    // every step that assumes the role, reads, signs or writes is behind the gate: a job without the settings ends green and does nothing
    const gate_if = "        if: steps.gate.outputs.enabled == 'true'\n";
    const unguarded = "does not run only behind the gate";
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read", "      - name: Assume the publish role through OIDC\n" ++ gate_if, "      - name: Assume the publish role through OIDC\n"), unguarded);
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read-2", "      - name: Read the current index and its ETags from S3 (never through the CDN, which caches the index)\n" ++ gate_if, "      - name: Read the current index and its ETags from S3 (never through the CDN, which caches the index)\n"), unguarded);
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index", "      - name: Merge the .debs into the index that was read (the index of every product is kept)\n" ++ gate_if, "      - name: Merge the .debs into the index that was read (the index of every product is kept)\n"), unguarded);
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index-3", "        id: sign\n" ++ gate_if, "        id: sign\n"), unguarded);
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write", "        id: put\n" ++ gate_if, "        id: put\n"), unguarded);
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write-3", "      - name: Assume the publish role through OIDC\n" ++ gate_if, "      - name: Assume the publish role through OIDC\n"), unguarded);
    // the gate itself is exact: it names the settings, and the key, and the signed index
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read", " --env APT_BUCKET", ""), "does not gate on the settings with exactly");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read-2", " --env APT_PUBLISH_ROLE_ARN", ""), "does not gate on the settings with exactly");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index", " --true HAVE_KEY", ""), "does not gate on the key and the read with exactly");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index-2", " --true READ_ENABLED", ""), "does not gate on the key and the read with exactly");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write", " --true INDEX_SIGNED", ""), "does not gate on the settings and the signed index with exactly");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write-3", " --env APT_HOSTNAME", ""), "does not gate on the settings and the signed index with exactly");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index", "READ_ENABLED: ${{ needs.apt-deploy-read.outputs.enabled }}", "READ_ENABLED: 'true'"), "does not take the read's `enabled` for its gate");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write-2", "INDEX_SIGNED: ${{ needs.apt-index-2.outputs.signed }}", "INDEX_SIGNED: 'true'"), "does not take the index's `signed` for its gate");
    // the order inside a job: gate, assume, read; gate, merge, sign; gate, assume, write
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read", "tool/apt-publish assume ", "tool/apt-publish read-then-assume "), "does not gate, then assume the role, then read");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index", "tool/apt-publish sign ", "tool/apt-publish index-sign "), "does not sign (`tool/apt-publish sign`)");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write-2", "tool/apt-publish write ", "tool/apt-publish put "), "has no step with `run: tool/apt-publish write`");
    // the key is read in the signing step alone, once for the gate's test and once to sign, the passphrase once
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index", "          HAVE_KEY: ${{ secrets.APT_GPG_PRIVATE_KEY != '' }}\n", "          HAVE_KEY: 'true'\n"), "reads the signing key other than twice");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index-2", "          APT_GPG_PASSPHRASE: ${{ secrets.APT_GPG_PASSPHRASE }}\n", ""), "the signing step of `apt-index-2` does not take the key and the passphrase from the secrets");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index-2", "          APT_GPG_PASSPHRASE: ${{ secrets.APT_GPG_PASSPHRASE }}\n", ""), "reads the signing key other than twice (the gate's test and the signing step) or the passphrase other than once");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index-3", "        id: sign\n", "        id: signature\n"), "is not `id: sign`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index", "      signed: ${{ steps.sign.outputs.signed }}\n", ""), "does not output `signed` of its signing step");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read-2", "      enabled: ${{ steps.gate.outputs.enabled }}\n", ""), "does not output the gate's `enabled`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write", "      conflict: ${{ steps.put.outputs.conflict }}\n", ""), "does not output the `conflict` of its write step");
    // the attempts: the first after the publish, the next two only after a lost write, the last writing with --last
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read-2", "needs.apt-deploy-write.outputs.conflict == 'true'", "needs.apt-deploy-write.outputs.conflict != 'false'"), "does not run only when the write before it lost");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read-3", "needs.apt-deploy-write-2.outputs.conflict == 'true'", "needs.apt-deploy-write.outputs.conflict == 'true'"), "does not run only when the write before it lost");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read-3", "needs: [apt-deploy-write-2]", "needs: [apt-deploy-write]"), "`apt-deploy-read-3` does not wait for `apt-deploy-write-2`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write-3", " --out \"$GITHUB_OUTPUT\" --last", " --out \"$GITHUB_OUTPUT\""), "does not write with `--last`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write-2", " --out \"$GITHUB_OUTPUT\"\n", " --out \"$GITHUB_OUTPUT\" --last\n"), "writes with `--last` but another attempt follows it");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write", " --out \"$GITHUB_OUTPUT\"\n", "\n"), "does not write with `--out");
    // the first read: the exact if of publish, the same four jobs
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read", " && github.ref == 'refs/heads/main'", ""), "the job `apt-deploy-read` is not under its exact `if:`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read", " && needs.tag.outputs.superseded != 'true'", ""), "the job `apt-deploy-read` is not under its exact `if:`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read", "needs: [plan, tag, publish, tool]", "needs: [plan, tag, tool]"), "`apt-deploy-read` does not wait for `publish`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read", "needs: [plan, tag, publish, tool]", "needs: [plan, publish, tool]"), "`apt-deploy-read` does not wait for `tag`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index", "needs: [apt-deploy-read]", "needs: [plan]"), "`apt-index` does not wait for `apt-deploy-read`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write-2", "needs: [apt-deploy-read-2, apt-index-2]", "needs: [apt-deploy-read-2]"), "`apt-deploy-write-2` does not wait for `apt-index-2`");
    // nothing but the apt jobs waits for an apt job
    try expectFinding(a, r, try mutateIn(a, r.wf, "bump", "needs: [plan, tag, publish, tool]", "needs: [plan, tag, publish, tool, apt-deploy-write]"), "`bump` waits for `apt-deploy-write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "publish", "needs: [plan, tag, verify, tool]", "needs: [plan, tag, verify, tool, apt-index]"), "`publish` waits for `apt-index`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "site", "needs: [plan, tag, verify, tool]", "needs: [plan, tag, verify, tool, apt-deploy-write-3]"), "`site` waits for `apt-deploy-write-3`");
    // the .debs are the verified ones, the tools the ones tool built
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index", "name: release-dist", "name: release-unsigned"), "reads `release-unsigned`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write-3", "name: release-dist", "name: release-unsigned"), "reads `release-unsigned`");
    // they run no buck2, check nothing out, and use no action but the artifacts'
    const buck2_run = "      - run: ./buck2 build --console simple -c buildrules_re.mode=local //tools/release:release\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-write", "      - run: chmod +x tool/apt-publish\n", buck2_run), "holds the apt signing key or role and runs buck2");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index-2", "      - run: chmod +x tool/apt-publish tool/channels\n", buck2_run), "holds the apt signing key or role and runs buck2");
    const cache = "      - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0\n        with:\n          path: x\n          key: x\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-deploy-read-3", "      - run: chmod +x tool/apt-publish\n", cache), "holds the apt signing key or role and uses actions/cache");
    try expectFinding(a, r, try mutateIn(a, r.wf, "apt-index", "      - run: chmod +x tool/apt-publish tool/channels\n", "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          persist-credentials: false\n"), "job `apt-index` checks the repository out");
    // every job of the three attempts is there
    inline for (.{ "apt-deploy-read", "apt-index", "apt-deploy-write", "apt-deploy-read-2", "apt-index-2", "apt-deploy-write-2", "apt-deploy-read-3", "apt-index-3", "apt-deploy-write-3" }) |name| {
        const header = "\n  " ++ name ++ ":\n";
        const f = try checkRelease(a, try mutate(a, r.wf, header, "\n  not-" ++ name ++ ":\n"), r.ds, r.ci);
        var named = false;
        for (f.items) |m| {
            if (std.mem.indexOf(u8, m, "the job `" ++ name ++ "` is missing") != null) named = true;
        }
        try t.expect(named);
    }
}

test "rule: the .debs are made in build-cli and again in verify, the tools of the channels are built by tool and handed on, and the tool is run from the artifact" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const debs_step = "      - name: Package the two .debs from the same binaries\n        run: tool/release debs --version \"$NUMBER\" --bins cli-bins --channels tool/channels --packaging packaging/deb --out cli-dist\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", debs_step, ""), "`build-cli` does not package the two .debs");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "--bins cli-bins --channels", "--bins rebuilt-bins --channels"), "`build-cli` does not package the two .debs");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "--channels tool/channels --packaging packaging/deb --out cli-dist", "--channels tool/channels --packaging other --out cli-dist"), "`build-cli` does not package the two .debs");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "--packaging packaging/deb --out cli-dist", "--packaging packaging/deb --out elsewhere"), "`build-cli` does not package the two .debs");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "tool/release debs ", "echo debs "), "`build-cli` does not run `tool/release debs");
    {
        // the .debs before the tarballs
        const pkg = "      - name: Package the three tarballs\n        run: tool/release package-all --version \"$NUMBER\" --bins cli-bins --license LICENSE --out cli-dist --native linux-x86_64\n";
        const moved = try mutateIn(a, r.wf, "build-cli", pkg, "");
        const swapped = try mutateIn(a, moved, "build-cli", debs_step, debs_step ++ pkg);
        try expectFinding(a, r, swapped, "`build-cli` makes the .debs before the tarballs");
    }
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "          name: channel-tools\n", "          name: release-tool\n"), "`build-cli` does not download the tools of the channels");
    try expectFinding(a, r, try mutateIn(a, r.wf, "build-cli", "name: release-cli-tarballs", "name: other"), "does not upload the three tarballs and the two .debs");
    // verify: the second build's .debs, with the tools of the channels, before it compares
    const second = "      - name: Package the two .debs again\n        run: tool/release debs --version \"$NUMBER\" --bins rebuilt-bins --channels tool/channels --packaging packaging/deb --out rebuilt-dist\n";
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", second, ""), "`verify` does not package the second build's two .debs");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "--bins rebuilt-bins --channels", "--bins cli-bins --channels"), "`verify` does not package the second build's two .debs");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "--out rebuilt-dist\n", "--out cli-dist\n"), "`verify` does not package the second build's");
    try expectFinding(a, r, try mutateIn(a, r.wf, "verify", "          name: channel-tools\n", "          name: release-tool\n"), "`verify` does not download the tools of the channels");
    {
        // the second build's .debs made after the verify step that compares them
        const moved = try mutateIn(a, r.wf, "verify", second, "");
        const late = try mutateIn(a, moved, "verify", "--cli rebuilt-bins/linux-x86_64/buildrules --rebuilt rebuilt-dist --dry false\n", "--cli rebuilt-bins/linux-x86_64/buildrules --rebuilt rebuilt-dist --dry false\n" ++ second);
        try expectFinding(a, r, late, "verifies before it has made the second build's .debs");
    }
    // tool: each tool of the channels is built into its own file, and handed on as one artifact
    try expectFinding(a, r, try mutateIn(a, r.wf, "tool", "--out channels //tools/channels:channels", "--out other //tools/channels:channels"), "does not build //tools/channels:channels into its own file");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tool", "--out tap //tools/deploy:tap", "--out tap //tools/deploy:other"), "does not build //tools/deploy:tap into its own file");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tool", "--out apt-publish //tools/deploy:apt_publish", "--out apt //tools/deploy:apt_publish"), "does not build //tools/deploy:apt_publish into its own file");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tool", "            ./apt-publish\n", ""), "does not hand on the tools of the channels");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tool", "          name: channel-tools\n", "          name: other\n"), "does not hand on the tools of the channels");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tool", " -c buildrules_re.mode=local --out tap", " --out tap"), "does not pass `-c buildrules_re.mode=local`");
}
