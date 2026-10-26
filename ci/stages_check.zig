//! The beta workflow (.github/workflows/beta.yml) is what RELEASING.md says it is. A pure function of the text, so each rule is tested against faulty text
//! (a synthetic copy of the workflow, so a variant is red for its own rule) as well as against the real file (the zig_test's `data`). The rules shared with the
//! other workflows (actions pinned by commit, local mode on every buck2 command, the pinned install) are workflow_check.zig's; the job parser is release_check.zig's.
//!
//!  - the triggers: a call from the release (`workflow_call`) and nothing else, so no pull request runs the beta: it is the beta stage of the release, after the merge; a token with read access, and `id-token: write` in the farm leg alone;
//!  - the legs: the tools job, one job per ubuntu x86_64 language (the matrix is exactly the directories of beta/ but Mojo), the Mojo job that runs only when
//!    the tools job says it is ready, the native arm and macos jobs (the command line the release ships for the host, run on the host, up to the build, and
//!    saying so in their names), and the farm job that runs only when FARM_ADDRESS is set;
//!  - the tools job builds the stage tool and takes the command line of the two other hosts, takes the buck2 pinned for them (url and sha256 of tools/buck2),
//!    says the version of the command line, and hands all of it on as the artifact `beta-native`;
//!  - no mention of a pull request in the file (the candidate is `github.sha` of the caller), and the one fixed concurrency group `beta` that never cancels (one beta at a time);
//!  - local mode on every buck2 command of the workflow, and `--exec local` for every leg but the farm's, which takes the farm's settings and never `--exec local`;
//!  - the farm job takes the farm-connect action from the repository and commit that variables name, verifies the checkout before the action runs, and runs
//!    nothing of the repository's before that;
//!  - the notice that says the farm leg was not run.
const std = @import("std");
const wc = @import("workflow_check.zig");
const rc = @import("release_check.zig");
const t = std.testing;

const Findings = wc.Findings;
const add = wc.add;

const farm_action = "./farm-action/.github/actions/farm-connect";
const stage_target = "//tools/stage:stage";
const cli_target = "//cli:buildrules";

/// The hosts of the native legs: job, runner, the release target (the name of its directory in the artifact `beta-native`), the zig_exe of the stage tool for it, the
/// platform of tools/buck2 whose release it runs.
const Native = struct { job: []const u8, runner: []const u8, host: []const u8, stage_target: []const u8, buck2_platform: []const u8 };
const natives = [_]Native{
    .{ .job = "beta_arm", .runner = "ubuntu-24.04-arm", .host = "linux-aarch64", .stage_target = "//tools/stage:stage_linux_aarch64", .buck2_platform = "linux-aarch64" },
    .{ .job = "beta_macos", .runner = "macos-14", .host = "macos-arm64", .stage_target = "//tools/stage:stage_macos_arm64", .buck2_platform = "macos-aarch64" },
};
/// The languages the native legs walk: the ones whose STEPS need nothing but `buildrules init` and `config` before the first `build` (the others run `cargo new`,
/// `npm sync` or `mojo sync` first, each of which builds a pinned tool, and nothing builds on these hosts yet). `stage native` is red on one that does.
const native_langs = [_][]const u8{ "zig", "cxx" };

fn hasWord(cmd: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, cmd, " \t");
    while (it.next()) |w| {
        if (std.mem.eql(u8, w, word)) return true;
    }
    return false;
}

const all_jobs = [_][]const u8{ "tools", "beta", "beta_mojo", "beta_arm", "beta_macos", "beta_farm" };

/// The words of `lang: [a, b, c]` in the job's text.
fn matrixLangs(a: std.mem.Allocator, job_text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    const open = "lang: [";
    const i = std.mem.indexOf(u8, job_text, open) orelse return out.toOwnedSlice();
    const j = std.mem.indexOfPos(u8, job_text, i, "]") orelse return out.toOwnedSlice();
    var it = std.mem.tokenizeAny(u8, job_text[i + open.len .. j], ", ");
    while (it.next()) |w| try out.append(w);
    return out.toOwnedSlice();
}

/// The names in `expected_langs = [_][]const u8{ "a", "b" }` of beta/check.zig.
pub fn directoryLangs(a: std.mem.Allocator, check_zig: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    const open = "expected_langs = [_][]const u8{";
    const i = std.mem.indexOf(u8, check_zig, open) orelse return out.toOwnedSlice();
    const j = std.mem.indexOfPos(u8, check_zig, i, "}") orelse return out.toOwnedSlice();
    var it = std.mem.tokenizeAny(u8, check_zig[i + open.len .. j], ", \"");
    while (it.next()) |w| try out.append(w);
    return out.toOwnedSlice();
}

fn sameSet(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x) |a| {
        var found = false;
        for (y) |b| {
            if (std.mem.eql(u8, a, b)) found = true;
        }
        if (!found) return false;
    }
    return true;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// Everything wrong with `wf` (beta.yml), given the dotslash file of the pinned buck2 and the languages of beta/ (`dir_langs`).
pub fn checkBeta(a: std.mem.Allocator, wf: []const u8, dotslash: []const u8, dir_langs: []const []const u8) !Findings {
    var f = Findings.init(a);
    const text = try rc.body(a, wf);

    try wc.noContinueOnError(a, &f, text);
    try wc.noInlineContext(a, &f, text);
    const uses = try wc.pinnedUses(a, &f, text, &.{farm_action});
    if (uses == 0) try add(a, &f, "no `uses:` line found (this parser is blind)", .{});
    if (std.mem.count(u8, text, "actions/checkout@") != std.mem.count(u8, text, "persist-credentials: false"))
        try add(a, &f, "a checkout keeps the token in the checkout (`persist-credentials: false` is missing)", .{});

    // Triggers and the token.
    const on = try rc.triggers(a, text);
    var has_call = false;
    for (on) |k| {
        if (std.mem.eql(u8, k, "workflow_call")) has_call = true else try add(a, &f, "the workflow is triggered by `{s}`: only `workflow_call` is allowed (no pull request runs the beta; the release calls it after the merge)", .{k});
    }
    if (!has_call) try add(a, &f, "`on: workflow_call` is missing (release.yml calls this workflow between the gate and the tag)", .{});
    for ([_][]const u8{ "pull_request_target", "workflow_run", "workflow_dispatch", "secrets.", "write-all", "--no-remote-cache" }) |bad| {
        if (contains(text, bad)) try add(a, &f, "`{s}` appears in the workflow", .{bad});
    }
    if (!wc.hasLine(text, "permissions:") or !wc.hasLine(text, "  contents: read")) try add(a, &f, "top-level `permissions:` with `contents: read` is missing", .{});
    if (!wc.hasLine(text, "  cancel-in-progress: false")) try add(a, &f, "`cancel-in-progress` is not `false`: nothing cancels a run of the beta", .{});
    if (!wc.hasLine(text, "  group: beta")) try add(a, &f, "the concurrency group is not the fixed `beta` (one beta at a time, whatever the caller; a name other than the release workflow's group, so caller and callee cannot wait for each other)", .{});
    if (contains(text, "github.event.pull_request") or contains(text, "'pull_request'")) try add(a, &f, "the workflow names a pull request (`github.event.pull_request`): a pull request does not run the beta, and the candidate is `github.sha`", .{});

    const jobs = try rc.parseJobs(a, text);
    for (all_jobs) |name| {
        if (rc.jobNamed(jobs, name) == null) try add(a, &f, "the job `{s}` is missing", .{name});
    }
    var writes: usize = 0;
    for (jobs) |*j| {
        if (!j.has_perms) try add(a, &f, "the job `{s}` states no `permissions:` of its own", .{j.name});
        for (j.perms.items) |p| {
            if (std.mem.eql(u8, p.level, "write")) {
                writes += 1;
                if (!(std.mem.eql(u8, j.name, "beta_farm") and std.mem.eql(u8, p.scope, "id-token")))
                    try add(a, &f, "the job `{s}` holds `{s}: write`, which only the farm job's `id-token` may", .{ j.name, p.scope });
            } else if (!std.mem.eql(u8, p.level, "read") and !std.mem.eql(u8, p.level, "none")) {
                try add(a, &f, "the job `{s}` has `{s}: {s}`, which is not read, write or none", .{ j.name, p.scope, p.level });
            }
        }
    }
    if (std.mem.count(u8, text, ": write") != writes) try add(a, &f, "a `: write` is granted outside a job's `permissions:` block", .{});

    // buck2: local mode on every command, the pinned install, and the two tools are built.
    const builds = try wc.localMode(a, &f, text);
    if (builds < 2) try add(a, &f, "fewer than two `./buck2 build` commands (the stage tool and the command line are built); or this parser is blind", .{});
    var stage_built = false;
    var cli_built = false;
    for (try wc.commands(a, text)) |cmd| {
        // whole words: `//tools/stage:stage_macos_arm64` is not the stage tool of the runner legs
        if (contains(cmd, "./buck2 build ") and hasWord(cmd, stage_target)) stage_built = true;
        if (contains(cmd, "./buck2 build ") and hasWord(cmd, cli_target)) cli_built = true;
    }
    if (!stage_built) try add(a, &f, "the workflow does not build {s}", .{stage_target});
    if (!cli_built) try add(a, &f, "the workflow does not build {s}", .{cli_target});
    try wc.buck2Install(a, &f, text, dotslash);

    // tools: what it hands on, what it says about the legs, and the notice about the farm leg.
    if (rc.jobNamed(jobs, "tools")) |j| {
        const jt = try j.text(a);
        if (!contains(jt, "name: beta-tools") or !contains(jt, "\n./stage\n") or !contains(jt, "\n./buildrules\n") or !contains(jt, "\n./buck2\n"))
            try add(a, &f, "the job `tools` does not upload `stage`, `buildrules` and `buck2` as the artifact `beta-tools`", .{});
        if (!contains(jt, "./stage plan --root") or !contains(jt, "mojo: ${{ steps.plan.outputs.mojo }}")) try add(a, &f, "the job `tools` does not run `stage plan` and output `mojo`", .{});
        if (!contains(jt, "if: ${{ vars.FARM_ADDRESS == '' || vars.FARM_CONNECT_REF == '' }}") or !contains(jt, "::notice")) try add(a, &f, "the job `tools` does not say, with a notice, that the farm leg is not run when FARM_ADDRESS or FARM_CONNECT_REF is not set", .{});
    }

    // The command line the legs run: built from the candidate unless the release names the artifact that holds the one it built (stamped, packaged, and the
    // file its tarball ships); then that file is downloaded and never built again here, or the legs would test bytes the release does not ship.
    if (!contains(text, "      cli-artifact:\n        type: string\n        default: \"\"\n")) try add(a, &f, "`on: workflow_call` has no string input `cli-artifact` that defaults to empty", .{});
    if (rc.jobNamed(jobs, "tools")) |j| {
        const jt = try j.text(a);
        if (!contains(jt, "- name: Build the command line\nif: ${{ inputs.cli-artifact == '' }}\nrun: ./buck2 build "))
            try add(a, &f, "the job `tools` builds the command line even when the release names the one it built (the step `Build the command line` lacks `if: ${{{{ inputs.cli-artifact == '' }}}}`)", .{});
        if (!contains(jt, "- name: The command line the release built\nif: ${{ inputs.cli-artifact != '' }}\nuses: actions/download-artifact@") or !contains(jt, "\nwith:\nname: ${{ inputs.cli-artifact }}\npath: .\n"))
            try add(a, &f, "the job `tools` does not download the artifact `inputs.cli-artifact` into `.` when the release names it", .{});
        if (!contains(jt, "- name: It is executable\nif: ${{ inputs.cli-artifact != '' }}\nrun: chmod +x buildrules\n"))
            try add(a, &f, "the job `tools` does not make the downloaded command line executable", .{});
    }

    // The ubuntu legs: one job per language of beta/ but Mojo, in local mode.
    var want = std.ArrayList([]const u8).init(a);
    var has_mojo = false;
    for (dir_langs) |l| {
        if (std.mem.eql(u8, l, "mojo")) has_mojo = true else try want.append(l);
    }
    if (!has_mojo) try add(a, &f, "beta/ has no mojo directory (the Mojo leg is planned, not dropped)", .{});
    for ([_][]const u8{ "beta", "beta_farm" }) |name| {
        if (rc.jobNamed(jobs, name)) |j| {
            const langs = try matrixLangs(a, try j.text(a));
            if (!sameSet(langs, want.items)) try add(a, &f, "the matrix of the job `{s}` is not the languages of beta/ but mojo ({s})", .{ name, try std.mem.join(a, ", ", want.items) });
        }
    }
    for ([_][]const u8{ "beta", "beta_mojo" }) |name| {
        if (rc.jobNamed(jobs, name)) |j| {
            const jt = try j.text(a);
            if (!rc.hasNeed(j, "tools")) try add(a, &f, "the job `{s}` does not wait for `tools`", .{name});
            if (!contains(jt, "tool/stage beta ")) try add(a, &f, "the job `{s}` does not run `tool/stage beta `", .{name});
            if (!contains(jt, "--exec local")) try add(a, &f, "the job `{s}` does not run in local mode (`--exec local`)", .{name});
            if (contains(jt, "--exec farm") or contains(jt, "id-token")) try add(a, &f, "the job `{s}` is a runner job and uses the farm", .{name});
        }
    }
    if (rc.jobNamed(jobs, "beta_mojo")) |j| {
        const jt = try j.text(a);
        if (j.if_expr == null or !contains(j.if_expr.?, "needs.tools.outputs.mojo == 'ready'")) try add(a, &f, "the job `beta_mojo` does not run only when the tools job says mojo is ready", .{});
        if (!contains(jt, "--lang mojo")) try add(a, &f, "the job `beta_mojo` does not run the mojo leg", .{});
    }

    // The native legs: the command line the release ships for the host, run on the host up to the build, and no more claimed than that.
    for (natives) |n| {
        if (rc.jobNamed(jobs, n.job)) |j| {
            const jt = try j.text(a);
            if (j.if_expr != null) try add(a, &f, "the job `{s}` has an `if:`: the native legs run in every release (a leg that is skipped proves nothing)", .{n.job});
            const runs_on = try std.fmt.allocPrint(a, "runs-on: {s}", .{n.runner});
            if (!contains(jt, runs_on)) try add(a, &f, "the job `{s}` does not run on {s}", .{ n.job, n.runner });
            if (!rc.hasNeed(j, "tools")) try add(a, &f, "the job `{s}` does not wait for `tools`", .{n.job});
            // the name says what the leg is and is not: a green leg is not a green build
            var named = false;
            var lines = std.mem.splitScalar(u8, jt, '\n');
            while (lines.next()) |l| {
                if (std.mem.startsWith(u8, l, "name: ") and contains(l, "native") and contains(l, "no build yet")) named = true;
            }
            if (!named) try add(a, &f, "the job `{s}` does not say in its name that it is native and does not build yet (`native, no build yet`)", .{n.job});
            const langs = try matrixLangs(a, jt);
            if (!sameSet(langs, &native_langs)) try add(a, &f, "the matrix of the job `{s}` is not {s}, the languages that need only `init` before the build", .{ n.job, try std.mem.join(a, ", ", &native_langs) });
            for (langs) |l| {
                var found = false;
                for (dir_langs) |d| {
                    if (std.mem.eql(u8, d, l)) found = true;
                }
                if (!found) try add(a, &f, "the matrix of the job `{s}` names `{s}`, which is not a directory of beta/", .{ n.job, l });
            }
            const stage_cmd = try std.fmt.allocPrint(a, "run: tool/{s}/stage native --root \"$GITHUB_WORKSPACE\" --lang \"$LANG_DIR\" ", .{n.host});
            if (!contains(jt, stage_cmd)) try add(a, &f, "the job `{s}` does not run `tool/{s}/stage native` on the language of the matrix", .{ n.job, n.host });
            const host_flag = try std.fmt.allocPrint(a, " --host {s} ", .{n.host});
            if (!contains(jt, host_flag)) try add(a, &f, "the job `{s}` does not name its host (`--host {s}`): the stage tool refuses another machine", .{ n.job, n.host });
            if (!contains(jt, " --version \"$VERSION\" ") or !contains(jt, "VERSION: ${{ needs.tools.outputs.version }}")) try add(a, &f, "the job `{s}` does not hold the command line to the version the tools job reports (`--version \"$VERSION\"`, `VERSION: ${{{{ needs.tools.outputs.version }}}}`)", .{n.job});
            const bins = try std.fmt.allocPrint(a, "--buck2 \"$GITHUB_WORKSPACE/tool/{s}/buck2\" --buildrules \"$GITHUB_WORKSPACE/tool/{s}/buildrules\"", .{ n.host, n.host });
            if (!contains(jt, bins)) try add(a, &f, "the job `{s}` does not run the buck2 and the command line of its own host (`tool/{s}/`)", .{ n.job, n.host });
            const chmod = try std.fmt.allocPrint(a, "run: chmod +x tool/{s}/stage tool/{s}/buildrules tool/{s}/buck2\n", .{ n.host, n.host, n.host });
            if (!contains(jt, chmod)) try add(a, &f, "the job `{s}` does not make the downloaded files executable", .{n.job});
            if (!contains(jt, "name: beta-native\npath: tool\n")) try add(a, &f, "the job `{s}` does not download the artifact `beta-native` into `tool`", .{n.job});
            if (contains(jt, "--exec") or contains(jt, "id-token") or contains(jt, "stage beta ")) try add(a, &f, "the job `{s}` is a native leg: it does not build (`--exec`), join a farm or run `stage beta`", .{n.job});
        }
    }

    // tools, for the native legs: the stage tool and the command line of each other host, the buck2 pinned for it, the version, and the artifact.
    if (!contains(text, "      cli-bins-artifact:\n        type: string\n        default: \"\"\n")) try add(a, &f, "`on: workflow_call` has no string input `cli-bins-artifact` that defaults to empty", .{});
    if (rc.jobNamed(jobs, "tools")) |j| {
        const jt = try j.text(a);
        if (!contains(jt, "version: ${{ steps.version.outputs.version }}") or !contains(jt, "- name: The version the command line says\nid: version\nrun: ./stage version --buildrules ./buildrules --output \"$GITHUB_OUTPUT\"\n"))
            try add(a, &f, "the job `tools` does not output the version its command line says (`./stage version --buildrules ./buildrules --output \"$GITHUB_OUTPUT\"`, `version: ${{{{ steps.version.outputs.version }}}}`)", .{});
        const built = std.mem.indexOf(u8, jt, "--out buildrules //cli:buildrules");
        const said = std.mem.indexOf(u8, jt, "./stage version ");
        const fetched = std.mem.indexOf(u8, jt, "name: ${{ inputs.cli-artifact }}");
        if (said == null or built == null or fetched == null or said.? < built.? or said.? < fetched.?) try add(a, &f, "the job `tools` asks the command line its version before it has the command line it walks", .{});
        if (!contains(jt, "- name: The command line of every target, built from the commit\nif: ${{ inputs.cli-bins-artifact == '' }}\nrun: ./buck2 build --console simple -c buildrules_re.mode=local --out cli-bins //cli:release_binaries\n"))
            try add(a, &f, "the job `tools` does not build //cli:release_binaries into `cli-bins` when the release names no artifact (`if: ${{{{ inputs.cli-bins-artifact == '' }}}}`)", .{});
        if (!contains(jt, "if: ${{ inputs.cli-bins-artifact != '' }}\nuses: actions/download-artifact@") or !contains(jt, "\nwith:\nname: ${{ inputs.cli-bins-artifact }}\npath: cli-bins\n"))
            try add(a, &f, "the job `tools` does not download the artifact `inputs.cli-bins-artifact` into `cli-bins` when the release names it", .{});
        if (!contains(jt, "run: mkdir -p native/linux-aarch64 native/macos-arm64\n")) try add(a, &f, "the job `tools` does not make a directory for each other host", .{});
        if (!contains(jt, "name: beta-native\npath: native\n")) try add(a, &f, "the job `tools` does not upload the directory `native` as the artifact `beta-native`", .{});
        for (natives) |n| {
            const build = try std.fmt.allocPrint(a, "run: ./buck2 build --console simple -c buildrules_re.mode=local --out native/{s}/stage {s}\n", .{ n.host, n.stage_target });
            if (!contains(jt, build)) try add(a, &f, "the job `tools` does not build the stage tool for {s} (`--out native/{s}/stage {s}`)", .{ n.host, n.host, n.stage_target });
            const cp = try std.fmt.allocPrint(a, "cp cli-bins/{s}/buildrules native/{s}/buildrules\n", .{ n.host, n.host });
            if (!contains(jt, cp)) try add(a, &f, "the job `tools` does not hand on the command line of {s} (`cp cli-bins/{s}/buildrules native/{s}/buildrules`)", .{ n.host, n.host, n.host });
            // the buck2 the host runs is the release tools/buck2 pins for it: its url, its sha256, checked before it is decompressed into place
            if (wc.dotslashPlatform(dotslash, n.buck2_platform)) |p| {
                if (!contains(jt, p.url)) try add(a, &f, "the job `tools` does not download the {s} url pinned in tools/buck2", .{n.buck2_platform});
                const line = try std.fmt.allocPrint(a, "{s}  buck2-{s}.zst\" | sha256sum --check --strict -\n", .{ p.digest, n.host });
                if (!contains(jt, line)) try add(a, &f, "the job `tools` does not check the {s} sha256 pinned in tools/buck2 (`{s}  buck2-{s}.zst`)", .{ n.buck2_platform, "<sha256>", n.host });
                const into = try std.fmt.allocPrint(a, "zstd --decompress --quiet buck2-{s}.zst -o native/{s}/buck2\n", .{ n.host, n.host });
                if (!contains(jt, into)) try add(a, &f, "the job `tools` does not decompress the checked {s} buck2 into `native/{s}/buck2`", .{ n.host, n.host });
            } else try add(a, &f, "tools/buck2 has no {s} digest and url (the job `{s}` runs it)", .{ n.buck2_platform, n.job });
        }
    }

    // The farm leg.
    if (rc.jobNamed(jobs, "beta_farm")) |j| {
        const jt = try j.text(a);
        if (j.if_expr == null or !contains(j.if_expr.?, "vars.FARM_ADDRESS != ''")) try add(a, &f, "the job `beta_farm` runs when FARM_ADDRESS is not set", .{});
        if (j.if_expr == null or !contains(j.if_expr.?, "vars.FARM_CONNECT_REF != ''")) try add(a, &f, "the job `beta_farm` runs when FARM_CONNECT_REF is not set, and would fail on a checkout of no commit", .{});
        if (!rc.hasNeed(j, "tools")) try add(a, &f, "the job `beta_farm` does not wait for `tools`", .{});
        const idt = rc.permLevel(j, "id-token");
        if (idt == null or !std.mem.eql(u8, idt.?, "write")) try add(a, &f, "the job `beta_farm` does not hold `id-token: write`, which joining the farm's network needs", .{});
        if (!contains(jt, "repository: ${{ vars.FARM_CONNECT_REPO }}") or !contains(jt, "ref: ${{ vars.FARM_CONNECT_REF }}"))
            try add(a, &f, "the job `beta_farm` does not check the farm-connect action out of the repository and commit that FARM_CONNECT_REPO and FARM_CONNECT_REF name", .{});
        const markers = [_][]const u8{ "repository: ${{ vars.FARM_CONNECT_REPO }}", "tool/stage action-ref ", "uses: " ++ farm_action, "tool/stage beta " };
        var at: usize = 0;
        for (markers) |m| {
            const i = std.mem.indexOfPos(u8, jt, at, m);
            if (i == null) {
                try add(a, &f, "the job `beta_farm` has no `{s}` after the step before it (order: checkout of the action, action-ref, farm-connect, beta)", .{m});
                break;
            }
            at = i.?;
        }
        if (!contains(jt, "--exec farm") or contains(jt, "--exec local")) try add(a, &f, "the job `beta_farm` is not `--exec farm` alone", .{});
        if (!contains(jt, "--farm-config \"$HOME/.buckconfig.d/farm.buckconfig\"")) try add(a, &f, "the job `beta_farm` does not hand the farm-connect file to the stage tool", .{});
    }

    // `run:` lines are one invocation each; the buck2 install of the tools job is the one block.
    for (jobs) |*j| {
        if (std.mem.eql(u8, j.name, "tools")) continue;
        for (j.lines.items) |l| {
            const s = std.mem.trimLeft(u8, std.mem.trimLeft(u8, l, "- "), " ");
            if (!std.mem.startsWith(u8, s, "run:")) continue;
            const v = std.mem.trim(u8, s["run:".len..], " ");
            if (v.len == 0 or v[0] == '|' or v[0] == '>') {
                try add(a, &f, "a `run:` block in the job `{s}`: one-line invocations only", .{j.name});
            } else if (contains(v, " && ") or contains(v, " || ") or std.mem.indexOfScalar(u8, v, ';') != null or contains(v, " | ")) {
                try add(a, &f, "a `run:` line in the job `{s}` is more than one invocation: {s}", .{ j.name, v });
            }
        }
    }
    return f;
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

const Real = struct { wf: []const u8, ds: []const u8, langs: []const []const u8 };

fn real(a: std.mem.Allocator) !Real {
    return .{ .wf = try work(a, ".github/workflows/beta.yml"), .ds = try work(a, "tools/buck2"), .langs = try directoryLangs(a, try work(a, "beta/check.zig")) };
}

// The faulty-defect tests run on this text and not on the real beta.yml: every variant anchors on text this file itself holds, so it cannot fail with
// `DefectDidNotApply` because the real workflow was reworded, and each red run is the rule under test ("the synthetic workflow has no finding" first).
const fixture_wf =
    \\name: beta
    \\
    \\on:
    \\  workflow_call:
    \\    inputs:
    \\      cli-artifact:
    \\        type: string
    \\        default: ""
    \\      cli-bins-artifact:
    \\        type: string
    \\        default: ""
    \\
    \\permissions:
    \\  contents: read
    \\
    \\concurrency:
    \\  group: beta
    \\  cancel-in-progress: false
    \\
    \\jobs:
    \\  tools:
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 120
    \\    permissions:
    \\      contents: read
    \\    outputs:
    \\      mojo: ${{ steps.plan.outputs.mojo }}
    \\      version: ${{ steps.version.outputs.version }}
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
    \\      - name: Build the stage tool
    \\        run: ./buck2 build --console simple -c buildrules_re.mode=local --out stage //tools/stage:stage
    \\
    \\      - name: Build the command line
    \\        if: ${{ inputs.cli-artifact == '' }}
    \\        run: ./buck2 build --console simple -c buildrules_re.mode=local --out buildrules //cli:buildrules
    \\
    \\      - name: The command line the release built
    \\        if: ${{ inputs.cli-artifact != '' }}
    \\        uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: ${{ inputs.cli-artifact }}
    \\          path: .
    \\
    \\      - name: It is executable
    \\        if: ${{ inputs.cli-artifact != '' }}
    \\        run: chmod +x buildrules
    \\
    \\      - name: Which legs are ready, and which are planned
    \\        id: plan
    \\        run: ./stage plan --root "$GITHUB_WORKSPACE" --output "$GITHUB_OUTPUT"
    \\
    \\      - name: The version the command line says
    \\        id: version
    \\        run: ./stage version --buildrules ./buildrules --output "$GITHUB_OUTPUT"
    \\
    \\      - name: A place for each other host
    \\        run: mkdir -p native/linux-aarch64 native/macos-arm64
    \\
    \\      - name: The stage tool for the other hosts, linux-aarch64
    \\        run: ./buck2 build --console simple -c buildrules_re.mode=local --out native/linux-aarch64/stage //tools/stage:stage_linux_aarch64
    \\
    \\      - name: The stage tool for the other hosts, macos-arm64
    \\        run: ./buck2 build --console simple -c buildrules_re.mode=local --out native/macos-arm64/stage //tools/stage:stage_macos_arm64
    \\
    \\      - name: The command line of every target, built from the commit
    \\        if: ${{ inputs.cli-bins-artifact == '' }}
    \\        run: ./buck2 build --console simple -c buildrules_re.mode=local --out cli-bins //cli:release_binaries
    \\
    \\      - name: The command line of every target, as the release built it
    \\        if: ${{ inputs.cli-bins-artifact != '' }}
    \\        uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: ${{ inputs.cli-bins-artifact }}
    \\          path: cli-bins
    \\
    \\      - name: The command line and buck2 of the other hosts
    \\        run: |
    \\          cp cli-bins/linux-aarch64/buildrules native/linux-aarch64/buildrules
    \\          cp cli-bins/macos-arm64/buildrules native/macos-arm64/buildrules
    \\          curl --fail --silent --show-error --location --retry 3 \
    \\            --output buck2-linux-aarch64.zst \
    \\            https://example.invalid/2026-09-15/buck2-aarch64-unknown-linux-gnu.zst
    \\          echo "e35027a8e3f700000000000000000000000000000000000000000000000000aa  buck2-linux-aarch64.zst" | sha256sum --check --strict -
    \\          zstd --decompress --quiet buck2-linux-aarch64.zst -o native/linux-aarch64/buck2
    \\          curl --fail --silent --show-error --location --retry 3 \
    \\            --output buck2-macos-arm64.zst \
    \\            https://example.invalid/2026-09-15/buck2-aarch64-apple-darwin.zst
    \\          echo "aacdf7cabe34000000000000000000000000000000000000000000000000bbbb  buck2-macos-arm64.zst" | sha256sum --check --strict -
    \\          zstd --decompress --quiet buck2-macos-arm64.zst -o native/macos-arm64/buck2
    \\
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        with:
    \\          name: beta-native
    \\          path: native
    \\          retention-days: 7
    \\          if-no-files-found: error
    \\
    \\      - name: the farm leg is not run (FARM_ADDRESS or FARM_CONNECT_REF is not set)
    \\        if: ${{ vars.FARM_ADDRESS == '' || vars.FARM_CONNECT_REF == '' }}
    \\        run: echo "::notice title=beta farm leg::the repository variable FARM_ADDRESS or FARM_CONNECT_REF is not set, so the beta repositories were not built on a farm. Skipped; RELEASING.md says what to set."
    \\
    \\      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
    \\        with:
    \\          name: beta-tools
    \\          path: |
    \\            ./stage
    \\            ./buildrules
    \\            ./buck2
    \\          retention-days: 7
    \\          if-no-files-found: error
    \\
    \\  beta:
    \\    needs: [tools]
    \\    name: beta ${{ matrix.lang }} (ubuntu x86_64)
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 120
    \\    permissions:
    \\      contents: read
    \\    strategy:
    \\      fail-fast: false
    \\      matrix:
    \\        lang: [rust, cxx, zig, node, mixed]
    \\    env:
    \\      LANG_DIR: ${{ matrix.lang }}
    \\      ORIGIN: https://github.com/${{ github.repository }}
    \\      COMMIT: ${{ github.sha }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          ref: ${{ github.sha }}
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: beta-tools
    \\          path: tool
    \\      - run: chmod +x tool/stage tool/buildrules tool/buck2
    \\      - name: The repository, as a user starts it, built twice
    \\        run: tool/stage beta --root "$GITHUB_WORKSPACE" --lang "$LANG_DIR" --work "$RUNNER_TEMP/beta" --origin "$ORIGIN" --commit "$COMMIT" --buck2 "$GITHUB_WORKSPACE/tool/buck2" --buildrules "$GITHUB_WORKSPACE/tool/buildrules" --exec local --summary "$GITHUB_STEP_SUMMARY"
    \\
    \\  beta_mojo:
    \\    needs: [tools]
    \\    if: ${{ needs.tools.outputs.mojo == 'ready' }}
    \\    name: beta mojo (ubuntu x86_64)
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 120
    \\    permissions:
    \\      contents: read
    \\    env:
    \\      ORIGIN: https://github.com/${{ github.repository }}
    \\      COMMIT: ${{ github.sha }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          ref: ${{ github.sha }}
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: beta-tools
    \\          path: tool
    \\      - run: chmod +x tool/stage tool/buildrules tool/buck2
    \\      - name: The repository, as a user starts it, built twice
    \\        run: tool/stage beta --root "$GITHUB_WORKSPACE" --lang mojo --work "$RUNNER_TEMP/beta" --origin "$ORIGIN" --commit "$COMMIT" --buck2 "$GITHUB_WORKSPACE/tool/buck2" --buildrules "$GITHUB_WORKSPACE/tool/buildrules" --exec local --summary "$GITHUB_STEP_SUMMARY"
    \\
    \\  beta_arm:
    \\    needs: [tools]
    \\    name: beta ${{ matrix.lang }} (ubuntu-24.04-arm) native, no build yet
    \\    runs-on: ubuntu-24.04-arm
    \\    timeout-minutes: 30
    \\    permissions:
    \\      contents: read
    \\    strategy:
    \\      fail-fast: false
    \\      matrix:
    \\        lang: [zig, cxx]
    \\    env:
    \\      LANG_DIR: ${{ matrix.lang }}
    \\      ORIGIN: https://github.com/${{ github.repository }}
    \\      COMMIT: ${{ github.sha }}
    \\      VERSION: ${{ needs.tools.outputs.version }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          ref: ${{ github.sha }}
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: beta-native
    \\          path: tool
    \\      - run: chmod +x tool/linux-aarch64/stage tool/linux-aarch64/buildrules tool/linux-aarch64/buck2
    \\      - name: The command line of this target, natively, up to the build
    \\        run: tool/linux-aarch64/stage native --root "$GITHUB_WORKSPACE" --lang "$LANG_DIR" --work "$RUNNER_TEMP/native" --origin "$ORIGIN" --commit "$COMMIT" --buck2 "$GITHUB_WORKSPACE/tool/linux-aarch64/buck2" --buildrules "$GITHUB_WORKSPACE/tool/linux-aarch64/buildrules" --host linux-aarch64 --version "$VERSION" --summary "$GITHUB_STEP_SUMMARY"
    \\
    \\  beta_macos:
    \\    needs: [tools]
    \\    name: beta ${{ matrix.lang }} (macos-14) native, no build yet
    \\    runs-on: macos-14
    \\    timeout-minutes: 30
    \\    permissions:
    \\      contents: read
    \\    strategy:
    \\      fail-fast: false
    \\      matrix:
    \\        lang: [zig, cxx]
    \\    env:
    \\      LANG_DIR: ${{ matrix.lang }}
    \\      ORIGIN: https://github.com/${{ github.repository }}
    \\      COMMIT: ${{ github.sha }}
    \\      VERSION: ${{ needs.tools.outputs.version }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          ref: ${{ github.sha }}
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: beta-native
    \\          path: tool
    \\      - run: chmod +x tool/macos-arm64/stage tool/macos-arm64/buildrules tool/macos-arm64/buck2
    \\      - name: The command line of this target, natively, up to the build
    \\        run: tool/macos-arm64/stage native --root "$GITHUB_WORKSPACE" --lang "$LANG_DIR" --work "$RUNNER_TEMP/native" --origin "$ORIGIN" --commit "$COMMIT" --buck2 "$GITHUB_WORKSPACE/tool/macos-arm64/buck2" --buildrules "$GITHUB_WORKSPACE/tool/macos-arm64/buildrules" --host macos-arm64 --version "$VERSION" --summary "$GITHUB_STEP_SUMMARY"
    \\
    \\  beta_farm:
    \\    needs: [tools]
    \\    if: ${{ vars.FARM_ADDRESS != '' && vars.FARM_CONNECT_REF != '' }}
    \\    name: beta ${{ matrix.lang }} (farm)
    \\    runs-on: ubuntu-latest
    \\    timeout-minutes: 120
    \\    permissions:
    \\      contents: read
    \\      id-token: write
    \\    strategy:
    \\      fail-fast: false
    \\      matrix:
    \\        lang: [rust, cxx, zig, node, mixed]
    \\    env:
    \\      LANG_DIR: ${{ matrix.lang }}
    \\      ORIGIN: https://github.com/${{ github.repository }}
    \\      COMMIT: ${{ github.sha }}
    \\      CONNECT_REF: ${{ vars.FARM_CONNECT_REF }}
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          ref: ${{ github.sha }}
    \\          persist-credentials: false
    \\      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
    \\        with:
    \\          name: beta-tools
    \\          path: tool
    \\      - run: chmod +x tool/stage tool/buildrules tool/buck2
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
    \\      - name: The repository, as a user starts it, built on the farm
    \\        run: tool/stage beta --root "$GITHUB_WORKSPACE" --lang "$LANG_DIR" --work "$RUNNER_TEMP/beta" --origin "$ORIGIN" --commit "$COMMIT" --buck2 "$GITHUB_WORKSPACE/tool/buck2" --buildrules "$GITHUB_WORKSPACE/tool/buildrules" --exec farm --farm-config "$HOME/.buckconfig.d/farm.buckconfig" --summary "$GITHUB_STEP_SUMMARY"
    \\
;

const fixture_ds =
    \\{
    \\  "platform": {
    \\    "linux-x86_64": {
    \\      "digest": "1268fce33fb600000000000000000000000000000000000000000000000000ff",
    \\      "providers": [{"url": "https://example.invalid/2026-09-15/buck2-x86_64-unknown-linux-gnu.zst"}]
    \\    },
    \\    "linux-aarch64": {
    \\      "digest": "e35027a8e3f700000000000000000000000000000000000000000000000000aa",
    \\      "providers": [{"url": "https://example.invalid/2026-09-15/buck2-aarch64-unknown-linux-gnu.zst"}]
    \\    },
    \\    "macos-aarch64": {
    \\      "digest": "aacdf7cabe34000000000000000000000000000000000000000000000000bbbb",
    \\      "providers": [{"url": "https://example.invalid/2026-09-15/buck2-aarch64-apple-darwin.zst"}]
    \\    }
    \\  }
    \\}
    \\
;

const fixture_langs = [_][]const u8{ "cxx", "mixed", "mojo", "node", "rust", "zig" };

fn fx() Real {
    return .{ .wf = fixture_wf, .ds = fixture_ds, .langs = &fixture_langs };
}

fn mutate(a: std.mem.Allocator, wf: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const i = std.mem.indexOf(u8, wf, from) orelse return error.DefectDidNotApply;
    return std.mem.concat(a, u8, &.{ wf[0..i], to, wf[i + from.len ..] });
}

/// As `mutate`, within the job `job` (the first `from` after its header).
fn mutateIn(a: std.mem.Allocator, wf: []const u8, job: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const header = try std.fmt.allocPrint(a, "\n  {s}:\n", .{job});
    const at = std.mem.indexOf(u8, wf, header) orelse return error.DefectDidNotApply;
    const i = std.mem.indexOfPos(u8, wf, at, from) orelse return error.DefectDidNotApply;
    return std.mem.concat(a, u8, &.{ wf[0..i], to, wf[i + from.len ..] });
}

fn expectFinding(a: std.mem.Allocator, r: Real, wf: []const u8, needle: []const u8) !void {
    const f = try checkBeta(a, wf, r.ds, r.langs);
    for (f.items) |m| {
        if (std.mem.indexOf(u8, m, needle) != null) return;
    }
    std.debug.print("expected a finding with `{s}`, got {d}:\n", .{ needle, f.items.len });
    for (f.items) |m| std.debug.print("  {s}\n", .{m});
    return error.DefectSurvived;
}

test "the real beta workflow has no findings" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try t.expectEqual(@as(usize, 6), r.langs.len);
    const f = try checkBeta(a, r.wf, r.ds, r.langs);
    for (f.items) |m| std.debug.print("finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "the synthetic workflow has no finding, so every variant below is red for its own rule" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = fx();
    const f = try checkBeta(a, r.wf, r.ds, r.langs);
    for (f.items) |m| std.debug.print("finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "the languages are read from beta/check.zig" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const got = try directoryLangs(a, "pub const expected_langs = [_][]const u8{ \"cxx\", \"zig\" };\nconst x = {};\n");
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("cxx", got[0]);
    try t.expectEqualStrings("zig", got[1]);
    try t.expectEqual(@as(usize, 0), (try directoryLangs(a, "nothing")).len);
}

test "rule: triggers, token and the cancel group" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = fx();
    try expectFinding(a, r, try mutate(a, r.wf, "on:\n  workflow_call:\n", "on:\n  push:\n  workflow_call:\n"), "triggered by `push`");
    try expectFinding(a, r, try mutate(a, r.wf, "on:\n  workflow_call:\n", "on:\n  workflow_dispatch:\n  workflow_call:\n"), "triggered by `workflow_dispatch`");
    // the tiers: a pull request runs build and unit tests, never the beta
    try expectFinding(a, r, try mutate(a, r.wf, "on:\n  workflow_call:\n", "on:\n  pull_request:\n  workflow_call:\n"), "triggered by `pull_request`");
    try expectFinding(a, r, try mutate(a, r.wf, "on:\n  workflow_call:\n", "on:\n  pull_request:\n"), "`on: workflow_call` is missing");
    try expectFinding(a, r, try mutate(a, r.wf, "on:\n  workflow_call:\n", "on:\n  pull_request_target:\n  workflow_call:\n"), "pull_request_target");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "      contents: read\n", "      contents: write\n"), "job `beta` holds `contents: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "      contents: read\n", "      contents: read\n      id-token: write\n"), "job `tools` holds `id-token: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_farm", "      id-token: write\n", "      id-token: write\n      packages: write\n"), "job `beta_farm` holds `packages: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_farm", "      id-token: write\n", ""), "does not hold `id-token: write`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "    permissions:\n      contents: read\n", ""), "states no `permissions:`");
    try expectFinding(a, r, try mutate(a, r.wf, "permissions:\n  contents: read\n\nconcurrency", "permissions:\n  contents: write\n\nconcurrency"), "outside a job's");
    try expectFinding(a, r, try mutate(a, r.wf, "persist-credentials: false", "persist-credentials: true"), "persist-credentials");
    try expectFinding(a, r, try mutate(a, r.wf, "COMMIT: ${{ github.sha }}", "COMMIT: ${{ secrets.X }}"), "`secrets.`");
    try expectFinding(a, r, try mutate(a, r.wf, "cancel-in-progress: false", "cancel-in-progress: ${{ github.event_name == 'pull_request' }}"), "nothing cancels a run");
    try expectFinding(a, r, try mutate(a, r.wf, "cancel-in-progress: false", "cancel-in-progress: true"), "nothing cancels a run");
    // one beta at a time: the per-commit group back, a group per ref, and the release workflow's own group (caller and callee would wait for each other) are red
    try expectFinding(a, r, try mutate(a, r.wf, "  group: beta\n", "  group: beta-${{ github.workflow }}-${{ github.sha }}\n"), "fixed `beta`");
    try expectFinding(a, r, try mutate(a, r.wf, "  group: beta\n", "  group: beta-${{ github.ref }}\n"), "fixed `beta`");
    try expectFinding(a, r, try mutate(a, r.wf, "  group: beta\n", "  group: release-push\n"), "fixed `beta`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "ref: ${{ github.sha }}", "ref: ${{ github.event.pull_request.head.sha || github.sha }}"), "names a pull request");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "runs-on: ubuntu-latest\n", "runs-on: ubuntu-latest\n    if: ${{ github.event_name != 'pull_request' }}\n"), "names a pull request");
}

test "rule: buck2 runs in local mode, as the literal ./buck2, from the pinned release, and both tools are built" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = fx();
    try expectFinding(a, r, try mutate(a, r.wf, "-c buildrules_re.mode=local --out stage", "--out stage"), "does not pass `-c buildrules_re.mode=local`");
    try expectFinding(a, r, try mutate(a, r.wf, "-c buildrules_re.mode=local --out buildrules", "-c buildrules_re.mode=remote --out buildrules"), "something other than `local`");
    try expectFinding(a, r, try mutate(a, r.wf, "      - run: chmod +x tool/stage tool/buildrules tool/buck2\n", "      - run: buck2 build //x:y\n"), "not the literal `./buck2`");
    try expectFinding(a, r, try mutate(a, r.wf, "--out stage //tools/stage:stage", "--out stage //tools/other:stage"), "does not build //tools/stage:stage");
    try expectFinding(a, r, try mutate(a, r.wf, "--out buildrules //cli:buildrules", "--out buildrules //cli:other"), "does not build //cli:buildrules");
    try expectFinding(a, r, try mutate(a, r.wf, "2026-09-15/buck2-x86_64", "2026-09-16/buck2-x86_64"), "url pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "1268fce33fb6", "0268fce33fb6"), "sha256 pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "--console simple", "--console simple -c buck2_re_client.engine_address=x"), "engine_address");
    try expectFinding(a, r, try mutate(a, r.wf, "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "actions/checkout@v7"), "not pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "uses: ./farm-action/.github/actions/farm-connect", "uses: ./elsewhere/.github/actions/farm-connect"), "not pinned");
}

test "rule: the languages of the matrix are the directories of beta/, and mojo is planned, not dropped" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = fx();
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "lang: [rust, cxx, zig, node, mixed]", "lang: [rust, cxx, zig, node]"), "matrix of the job `beta` is not the languages");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "lang: [rust, cxx, zig, node, mixed]", "lang: [rust, cxx, zig, node, mixed, go]"), "matrix of the job `beta` is not the languages");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_farm", "lang: [rust, cxx, zig, node, mixed]", "lang: [rust, zig]"), "matrix of the job `beta_farm`");
    // a directory with no job
    const more = [_][]const u8{ "cxx", "mixed", "mojo", "node", "rust", "zig", "go" };
    try expectFinding(a, .{ .wf = r.wf, .ds = r.ds, .langs = &more }, r.wf, "matrix of the job `beta` is not the languages");
    // no mojo directory at all
    const no_mojo = [_][]const u8{ "cxx", "mixed", "node", "rust", "zig" };
    try expectFinding(a, .{ .wf = r.wf, .ds = r.ds, .langs = &no_mojo }, r.wf, "no mojo directory");
    // the runner jobs wait for tools, run the stage tool in local mode, and use no farm
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "    needs: [tools]\n", ""), "`beta` does not wait for `tools`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "--exec local", "--exec farm"), "`beta` does not run in local mode");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "tool/stage beta ", "tool/stage plan "), "`beta` does not run `tool/stage beta `");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_mojo", "--exec local", "--exec local --exec farm"), "`beta_mojo` is a runner job and uses the farm");
}

test "rule: the mojo leg runs only when the tools job says it is ready" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = fx();
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_mojo", "needs.tools.outputs.mojo == 'ready'", "needs.tools.outputs.mojo != 'x'"), "does not run only when the tools job says mojo is ready");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_mojo", "needs.tools.outputs.mojo == 'ready'", "true"), "does not run only when the tools job says mojo is ready");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_mojo", "--lang mojo", "--lang zig"), "does not run the mojo leg");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "mojo: ${{ steps.plan.outputs.mojo }}", ""), "does not run `stage plan` and output `mojo`");
    try expectFinding(a, r, try mutate(a, r.wf, "\n  beta_mojo:\n", "\n  beta_mojo_x:\n"), "the job `beta_mojo` is missing");
}

test "rule: the native arm and macos legs run the command line of their host up to the build, say so, and claim nothing more" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = fx();
    for (natives) |n| {
        // skipped: a leg that never runs proves nothing, whatever condition keeps it from running
        const skipped = try std.fmt.allocPrint(a, "the job `{s}` has an `if:`", .{n.job});
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, "    needs: [tools]\n", "    needs: [tools]\n    if: ${{ github.event_name == 'planned' }}\n"), skipped);
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, "    needs: [tools]\n", "    needs: [tools]\n    if: ${{ true }}\n"), skipped);
        // dropped, or on the wrong machine, or not waiting for the tools
        const gone = try std.fmt.allocPrint(a, "the job `{s}` is missing", .{n.job});
        try expectFinding(a, r, try mutate(a, r.wf, try std.fmt.allocPrint(a, "\n  {s}:\n", .{n.job}), try std.fmt.allocPrint(a, "\n  {s}_x:\n", .{n.job})), gone);
        const runs = try std.fmt.allocPrint(a, "`{s}` does not run on {s}", .{ n.job, n.runner });
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, try std.fmt.allocPrint(a, "runs-on: {s}", .{n.runner}), "runs-on: ubuntu-latest"), runs);
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, "    needs: [tools]\n", ""), try std.fmt.allocPrint(a, "`{s}` does not wait for `tools`", .{n.job}));
        // the name says what the leg is, and that it does not build
        const named = try std.fmt.allocPrint(a, "`{s}` does not say in its name", .{n.job});
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, "native, no build yet", "native"), named);
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, "native, no build yet", "no build yet"), named);
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, "native, no build yet", "built twice"), named);
        // the languages: only those that need `init` alone before the build, and only directories of beta/
        const matrix = try std.fmt.allocPrint(a, "the matrix of the job `{s}` is not zig, cxx", .{n.job});
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, "lang: [zig, cxx]", "lang: [zig]"), matrix);
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, "lang: [zig, cxx]", "lang: [zig, cxx, rust]"), matrix);
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, "lang: [zig, cxx]", "lang: [zig, rust]"), matrix);
        const nodir = [_][]const u8{ "mixed", "mojo", "node", "rust", "zig" };
        try expectFinding(a, .{ .wf = r.wf, .ds = r.ds, .langs = &nodir }, r.wf, try std.fmt.allocPrint(a, "the matrix of the job `{s}` names `cxx`, which is not a directory", .{n.job}));
        // the command: the native command of the stage tool, for this host, on the file of this host
        const cmd = try std.fmt.allocPrint(a, "`{s}` does not run `tool/{s}/stage native`", .{ n.job, n.host });
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, "/stage native --root", "/stage beta --root"), cmd);
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, "--lang \"$LANG_DIR\" ", "--lang zig "), cmd);
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, try std.fmt.allocPrint(a, "run: tool/{s}/stage native", .{n.host}), "run: tool/stage native"), cmd);
        const host = try std.fmt.allocPrint(a, "`{s}` does not name its host", .{n.job});
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, try std.fmt.allocPrint(a, " --host {s} ", .{n.host}), " --host linux-x86_64 "), host);
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, try std.fmt.allocPrint(a, " --host {s} ", .{n.host}), " "), host);
        const version = try std.fmt.allocPrint(a, "`{s}` does not hold the command line to the version", .{n.job});
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, " --version \"$VERSION\" ", " "), version);
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, "VERSION: ${{ needs.tools.outputs.version }}", "VERSION: 0.0.0"), version);
        const own = try std.fmt.allocPrint(a, "`{s}` does not run the buck2 and the command line of its own host", .{n.job});
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, try std.fmt.allocPrint(a, "tool/{s}/buildrules\" --host", .{n.host}), "tool/linux-x86_64/buildrules\" --host"), own);
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, try std.fmt.allocPrint(a, "--buck2 \"$GITHUB_WORKSPACE/tool/{s}/buck2\"", .{n.host}), "--buck2 \"$GITHUB_WORKSPACE/tool/buck2\""), own);
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, try std.fmt.allocPrint(a, "      - run: chmod +x tool/{s}/stage tool/{s}/buildrules tool/{s}/buck2\n", .{ n.host, n.host, n.host }), "      - run: echo ready\n"), try std.fmt.allocPrint(a, "`{s}` does not make the downloaded files executable", .{n.job}));
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, "name: beta-native\n          path: tool", "name: beta-tools\n          path: tool"), try std.fmt.allocPrint(a, "`{s}` does not download the artifact `beta-native`", .{n.job}));
        // it does not build, join a farm or hold a token
        const claims = try std.fmt.allocPrint(a, "`{s}` is a native leg", .{n.job});
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, " --summary", " --exec local --summary"), claims);
        try expectFinding(a, r, try mutateIn(a, r.wf, n.job, "    permissions:\n      contents: read\n", "    permissions:\n      contents: read\n      id-token: write\n"), claims);
    }
    // the stage tool of the runner legs is not mistaken for the one of another host (whole words)
    try expectFinding(a, r, try mutate(a, r.wf, "--out stage //tools/stage:stage\n", "--out stage //tools/stage:stage_linux_aarch64\n"), "does not build //tools/stage:stage");
}

test "rule: the tools job builds the stage tool and takes the command line and the buck2 of the other hosts, says the version, and hands it all on" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = fx();
    // the version
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "      version: ${{ steps.version.outputs.version }}\n", ""), "does not output the version its command line says");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "        id: version\n", ""), "does not output the version its command line says");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "./stage version --buildrules ./buildrules", "./stage version --buildrules ./other"), "does not output the version its command line says");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "      - name: Install buck2\n", "      - name: Early\n        run: ./stage version --buildrules ./buildrules --output \"$GITHUB_OUTPUT\"\n\n      - name: Install buck2\n"), "asks the command line its version before it has");
    // the files of the other hosts: from the release's build when it names one, from the commit when it does not
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "        if: ${{ inputs.cli-bins-artifact == '' }}\n", ""), "does not build //cli:release_binaries into `cli-bins`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "inputs.cli-bins-artifact == ''", "inputs.cli-bins-artifact != ''"), "does not build //cli:release_binaries into `cli-bins`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "--out cli-bins //cli:release_binaries", "--out cli-bins //cli:buildrules"), "does not build //cli:release_binaries into `cli-bins`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "-c buildrules_re.mode=local --out cli-bins", "--out cli-bins"), "does not pass `-c buildrules_re.mode=local`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "        if: ${{ inputs.cli-bins-artifact != '' }}\n", ""), "does not download the artifact `inputs.cli-bins-artifact`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "          name: ${{ inputs.cli-bins-artifact }}\n", "          name: release-cli-bin\n"), "does not download the artifact `inputs.cli-bins-artifact`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "          path: cli-bins\n", "          path: cli\n"), "does not download the artifact `inputs.cli-bins-artifact`");
    try expectFinding(a, r, try mutate(a, r.wf, "      cli-bins-artifact:\n        type: string\n        default: \"\"\n", ""), "no string input `cli-bins-artifact`");
    try expectFinding(a, r, try mutate(a, r.wf, "      cli-bins-artifact:\n        type: string\n        default: \"\"\n", "      cli-bins-artifact:\n        type: string\n        default: release-cli-bins\n"), "no string input `cli-bins-artifact`");
    // the places, the artifact
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "mkdir -p native/linux-aarch64 native/macos-arm64", "mkdir -p native"), "does not make a directory for each other host");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "name: beta-native\n          path: native", "name: beta-native\n          path: tool"), "does not upload the directory `native` as the artifact `beta-native`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "name: beta-native\n          path: native", "name: beta-other\n          path: native"), "does not upload the directory `native` as the artifact `beta-native`");
    for (natives) |n| {
        // the stage tool of the host, and the command line of the host
        const stage = try std.fmt.allocPrint(a, "does not build the stage tool for {s}", .{n.host});
        try expectFinding(a, r, try mutateIn(a, r.wf, "tools", n.stage_target, "//tools/stage:stage"), stage);
        try expectFinding(a, r, try mutateIn(a, r.wf, "tools", try std.fmt.allocPrint(a, "--out native/{s}/stage", .{n.host}), "--out stage-other"), stage);
        try expectFinding(a, r, try mutateIn(a, r.wf, "tools", try std.fmt.allocPrint(a, "-c buildrules_re.mode=local --out native/{s}/stage", .{n.host}), try std.fmt.allocPrint(a, "--out native/{s}/stage", .{n.host})), "does not pass `-c buildrules_re.mode=local`");
        try expectFinding(a, r, try mutateIn(a, r.wf, "tools", try std.fmt.allocPrint(a, "cp cli-bins/{s}/buildrules native/{s}/buildrules\n", .{ n.host, n.host }), ""), try std.fmt.allocPrint(a, "does not hand on the command line of {s}", .{n.host}));
        try expectFinding(a, r, try mutateIn(a, r.wf, "tools", try std.fmt.allocPrint(a, "cp cli-bins/{s}/buildrules native/{s}/buildrules\n", .{ n.host, n.host }), try std.fmt.allocPrint(a, "cp cli-bins/linux-x86_64/buildrules native/{s}/buildrules\n", .{n.host})), try std.fmt.allocPrint(a, "does not hand on the command line of {s}", .{n.host}));
        // the buck2 of the host: the pinned url and sha256, checked before it is put in place, and put where the leg looks
        const pinned_digest = wc.dotslashPlatform(r.ds, n.buck2_platform).?;
        try expectFinding(a, r, try mutate(a, r.wf, pinned_digest.url, "https://example.invalid/2026-09-16/other.zst"), try std.fmt.allocPrint(a, "does not download the {s} url pinned in tools/buck2", .{n.buck2_platform}));
        try expectFinding(a, r, try mutate(a, r.wf, pinned_digest.digest[0..12], "0000000000000"), try std.fmt.allocPrint(a, "does not check the {s} sha256 pinned in tools/buck2", .{n.buck2_platform}));
        try expectFinding(a, r, try mutate(a, r.wf, try std.fmt.allocPrint(a, "-o native/{s}/buck2\n", .{n.host}), try std.fmt.allocPrint(a, "-o native/{s}/other\n", .{n.host})), try std.fmt.allocPrint(a, "does not decompress the checked {s} buck2", .{n.host}));
        // tools/buck2 without the platform: the parser is blind, and says so
        var blind = try a.alloc(u8, r.ds.len);
        @memcpy(blind, r.ds);
        const key = try std.fmt.allocPrint(a, "\"{s}\"", .{n.buck2_platform});
        const at = std.mem.indexOf(u8, blind, key).?;
        blind[at + 1] = 'X';
        const f = try checkBeta(a, r.wf, blind, r.langs);
        var said = false;
        for (f.items) |m| {
            if (std.mem.indexOf(u8, m, "tools/buck2 has no ") != null) said = true;
        }
        try t.expect(said);
    }
}

test "rule: the farm leg runs only with a farm, joins it through a verified action, and never in local mode" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = fx();
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_farm", "vars.FARM_ADDRESS != '' && ", ""), "runs when FARM_ADDRESS is not set");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_farm", " && vars.FARM_CONNECT_REF != ''", ""), "runs when FARM_CONNECT_REF is not set");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_farm", "    needs: [tools]\n", ""), "`beta_farm` does not wait for `tools`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_farm", "repository: ${{ vars.FARM_CONNECT_REPO }}", "repository: some/where"), "does not check the farm-connect action out");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_farm", "ref: ${{ vars.FARM_CONNECT_REF }}", "ref: main"), "does not check the farm-connect action out");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_farm", "        run: tool/stage action-ref --dir farm-action --ref \"$CONNECT_REF\"\n", "        run: echo skipped\n"), "has no `tool/stage action-ref ");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_farm", "--exec farm", "--exec local"), "is not `--exec farm` alone");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_farm", "--exec farm", "--exec farm --exec local"), "is not `--exec farm` alone");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_farm", " --farm-config \"$HOME/.buckconfig.d/farm.buckconfig\"", ""), "does not hand the farm-connect file");
    // the notice that says the leg was not run
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "if: ${{ vars.FARM_ADDRESS == '' || vars.FARM_CONNECT_REF == '' }}", "if: ${{ github.event_name == 'planned' }}"), "does not say, with a notice");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "::notice", "::debug"), "does not say, with a notice");
}

test "rule: run lines are single invocations, and the tools job hands on the three files" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = fx();
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "      - run: chmod +x tool/stage tool/buildrules tool/buck2\n", "      - run: chmod +x tool/stage && echo hi\n"), "more than one invocation");
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "      - run: chmod +x tool/stage tool/buildrules tool/buck2\n", "      - run: |\n          echo a\n          echo b\n"), "`run:` block in the job `beta`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "            ./buildrules\n", ""), "does not upload `stage`, `buildrules` and `buck2`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "name: beta-tools", "name: other"), "does not upload `stage`, `buildrules` and `buck2`");
}

test "rule: continue-on-error lets no red leg pass (G: the beta job), and nothing is expanded inline in a run line" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = fx();
    const rule = "`continue-on-error` is set to";
    // G: the beta job of beta.yml
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta", "    timeout-minutes: 120\n", "    timeout-minutes: 120\n    continue-on-error: true\n"), rule);
    // a step
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "        id: plan\n", "        id: plan\n        continue-on-error: true\n"), rule);
    // the farm job
    try expectFinding(a, r, try mutateIn(a, r.wf, "beta_farm", "    timeout-minutes: 120\n", "    timeout-minutes: 120\n    continue-on-error: ${{ true }}\n"), rule);
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "        run: ./stage plan --root \"$GITHUB_WORKSPACE\" --output \"$GITHUB_OUTPUT\"\n", "        run: ./stage plan --root \"${{ github.event.pull_request.title }}\"\n"), "expands `github.event.` inline");
}

test "rule: the legs run the command line the release built when it names one, and build it only when it does not" {
    // The defects: the legs rebuild the command line even in the release (they test bytes that are not the ones the release ships), the named artifact is
    // never downloaded, the downloaded file is not executable, or the input that carries the name is gone.
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = fx();
    // always built: the guard of the build step is gone, or says the opposite
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "        if: ${{ inputs.cli-artifact == '' }}\n", ""), "builds the command line even when the release names the one it built");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "inputs.cli-artifact == ''", "inputs.cli-artifact != ''"), "builds the command line even when the release names the one it built");
    // never downloaded: the guard says the opposite, the step is gone, another artifact, another path
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "        if: ${{ inputs.cli-artifact != '' }}\n        uses: actions/download-artifact", "        if: ${{ inputs.cli-artifact == '' }}\n        uses: actions/download-artifact"), "does not download the artifact `inputs.cli-artifact`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "          name: ${{ inputs.cli-artifact }}\n", "          name: release-cli-tarballs\n"), "does not download the artifact `inputs.cli-artifact`");
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "          name: ${{ inputs.cli-artifact }}\n          path: .\n", "          name: ${{ inputs.cli-artifact }}\n          path: cli\n"), "does not download the artifact `inputs.cli-artifact`");
    // not executable
    try expectFinding(a, r, try mutateIn(a, r.wf, "tools", "        run: chmod +x buildrules\n", "        run: echo not executable\n"), "does not make the downloaded command line executable");
    // the input is gone, or no longer an empty string by default
    try expectFinding(a, r, try mutate(a, r.wf, "    inputs:\n      cli-artifact:\n        type: string\n        default: \"\"\n", ""), "no string input `cli-artifact`");
    try expectFinding(a, r, try mutate(a, r.wf, "        default: \"\"\n", "        default: release-cli-bin\n"), "no string input `cli-artifact`");
}
