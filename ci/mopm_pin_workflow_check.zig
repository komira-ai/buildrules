//! The mopm-pin workflow (.github/workflows/mopm-pin.yml) is what its header says it is: a job that fails a pull request when the mopm pinned in rules/mopm/pins.bzl is not the
//! tarball mopm's release workflow signed. A pure function of the text, so each rule is tested against edited copies of the text as well as against the real files (the
//! zig_test's `data`, under BUILDRULES_TEST_WORK). The rules shared with the other workflows (actions pinned by commit, no `continue-on-error`, no inline expansion of
//! `vars.` or `github.event.` in a `run:`, local mode, the pinned buck2) are workflow_check.zig's; the job parser is release_check.zig's.
//!
//! What the rules catch (each is a way to keep the file and lose the check):
//!  - the job gone or renamed: exactly one job, `verify` (the name a branch-protection rule requires, `mopm-pin / verify`), on `ubuntu-latest`;
//!  - a trigger that skips it: the triggers are exactly `pull_request` and `workflow_dispatch`, and `pull_request` has no `paths`, `branches` or `types` filter;
//!  - a job or a step that can be switched off or made to pass: no `if:` anywhere but `if: always()` on the step that stops buck2, no `continue-on-error`, no `|| true`-style
//!    tail, no `exit`, `set +e` or `trap`, and the verify command is the whole command line (a `;`, `&&`, `||` or pipe after it is a different command);
//!  - a token with more than it needs: the top level grants `contents: read` alone, nothing writes, no `id-token`, no secret, no environment;
//!  - another cosign or another signer: the cosign installer is release.yml's step byte for byte (the same action commit and `cosign-release: 'v3.0.6'`), installed once before
//!    the verify, and the workflow names no identity or issuer of its own (they are the program's, which ci/mopm_pin.zig tests);
//!  - a pin copied into the workflow: the version, url and sha256 of a mopm release in pins.bzl appear nowhere in the file, so the program's reading of pins.bzl is the only source;
//!  - the program not the one built here: the job builds `//ci:mopm_pin` in local mode with its unit tests, once, before it runs `mopm-pin verify --pins rules/mopm/pins.bzl`;
//!  - the lint itself dropped: ci/BUCK lists the workflow for actionlint, and the `workflow` group builds this check and the program.
const std = @import("std");
const wc = @import("workflow_check.zig");
const rc = @import("release_check.zig");
const t = std.testing;

const Findings = wc.Findings;
const add = wc.add;

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

const file = "mopm-pin.yml";

/// The scrub (tools/scrub) allows the project's name only in the paths of a mopm release and of this repository, so the mopm repository is spelled in parts, as the scrub spells its own.
const mopm_repo = "kom" ++ "ira-ai/mo" ++ "pm";

/// The install of cosign as release.yml spells it: the pinned action and the version it is told. The workflow's step must be this text, and so must release.yml's.
const cosign_step = "      - uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2\n        with:\n          cosign-release: 'v3.0.6'\n";
const build_cmd = "./buck2 build --console simple -c buildrules_re.mode=local --out mopm-pin //ci:mopm_pin";
const verify_cmd = "./mopm-pin verify --pins rules/mopm/pins.bzl --work \"$RUNNER_TEMP/mopm-pin\" --cosign cosign";
const stop_step = "      - name: Stop buck2\n        if: always()\n        run: ./buck2 kill\n";

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

fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

/// The `workflow` group line of ci/BUCK, or null.
fn workflowGroup(ci_buck: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, ci_buck, "group(name = \"workflow\"") orelse return null;
    const end = std.mem.indexOfScalarPos(u8, ci_buck, at, '\n') orelse ci_buck.len;
    return ci_buck[at..end];
}

/// The `actionlint_check` target `workflow_lint` of ci/BUCK (from its name line to the closing parenthesis), or empty.
fn lintBlock(ci_buck: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, ci_buck, "name = \"workflow_lint\"") orelse return "";
    const end = std.mem.indexOfPos(u8, ci_buck, at, "\n)") orelse ci_buck.len;
    return ci_buck[at..end];
}

/// Every way `mopm-pin.yml` (`raw`) stops being a blocking signature check of the pin. `release_raw` is release.yml, `dotslash` tools/buck2, `pins` rules/mopm/pins.bzl and
/// `ci_buck` ci/BUCK.
pub fn check(a: std.mem.Allocator, raw: []const u8, release_raw: []const u8, dotslash: []const u8, pins: []const u8, ci_buck: []const u8) !Findings {
    var f = Findings.init(a);
    const wf = try rc.body(a, raw);

    try wc.noContinueOnError(a, &f, wf);
    try wc.noInlineContext(a, &f, wf);
    const uses = try wc.pinnedUses(a, &f, wf, &.{});
    if (uses != 2) try add(a, &f, "{s}: {d} `uses:` lines (exactly two: the checkout and the cosign installer)", .{ file, uses });
    var uit = std.mem.splitScalar(u8, wf, '\n');
    while (uit.next()) |line| {
        if (rc.usesRepo(line)) |repo| {
            if (!std.mem.startsWith(u8, repo, "actions/") and !std.mem.eql(u8, repo, "sigstore/cosign-installer"))
                try add(a, &f, "{s}: the action `{s}` is not allowed (only GitHub's own `actions/` actions and sigstore/cosign-installer run here)", .{ file, repo });
        }
    }

    // The job: one, named verify, on the hosted runner.
    const jobs = try rc.parseJobs(a, wf);
    if (jobs.len != 1) try add(a, &f, "{s}: the workflow has {d} jobs, not exactly one", .{ file, jobs.len });
    if (rc.jobNamed(jobs, "verify") == null) try add(a, &f, "{s}: no job `verify` (the name a branch-protection rule requires: `mopm-pin / verify`)", .{file});
    if (!has(wf, "\n    runs-on: ubuntu-latest\n")) try add(a, &f, "{s}: `runs-on: ubuntu-latest` is missing", .{file});
    if (!std.mem.startsWith(u8, wf, "name: mopm-pin\n")) try add(a, &f, "{s}: the workflow is not named `mopm-pin` (the check is `mopm-pin / verify`)", .{file});

    // Triggers: every pull request, and a manual run. No filter that can skip a pull request.
    const trig = try rc.triggers(a, wf);
    var got_pr = false;
    var got_dispatch = false;
    for (trig) |tr| {
        if (std.mem.eql(u8, tr, "pull_request")) {
            got_pr = true;
        } else if (std.mem.eql(u8, tr, "workflow_dispatch")) {
            got_dispatch = true;
        } else try add(a, &f, "{s}: the trigger `{s}` (only `pull_request` and `workflow_dispatch`)", .{ file, tr });
    }
    if (!got_pr) try add(a, &f, "{s}: no `pull_request` trigger: a change to the pin would not be checked", .{file});
    if (!got_dispatch) try add(a, &f, "{s}: no `workflow_dispatch` trigger", .{file});
    if (trig.len != 2) try add(a, &f, "{s}: {d} triggers, not exactly `pull_request` and `workflow_dispatch`", .{ file, trig.len });
    if (!has(wf, "\non:\n  pull_request:\n  workflow_dispatch:\n")) try add(a, &f, "{s}: `pull_request:` and `workflow_dispatch:` are not the whole `on:` block (a `paths`, `branches` or `types` filter can skip a pull request)", .{file});
    if (has(wf, "pull_request_target")) try add(a, &f, "{s}: `pull_request_target` runs fork code with the base repository's token", .{file});

    // Permissions: read the contents, nothing else, no key, no environment.
    const top = try topLines(a, wf, "permissions:");
    if (top == null or top.?.len != 1 or !std.mem.eql(u8, top.?[0], "contents: read")) try add(a, &f, "{s}: the top-level permissions are not exactly `contents: read`", .{file});
    if (has(wf, ": write") or has(wf, "write-all")) try add(a, &f, "{s}: a write permission is granted", .{file});
    if (has(wf, "id-token")) try add(a, &f, "{s}: `id-token` (the signature is checked, not made, so no identity token is needed)", .{file});
    if (has(wf, "secrets.")) try add(a, &f, "{s}: the workflow reads a secret", .{file});
    if (count(wf, "permissions:") != 1) try add(a, &f, "{s}: `permissions:` appears {d} times (once, at the top level)", .{ file, count(wf, "permissions:") });
    var lit = std.mem.splitScalar(u8, wf, '\n');
    while (lit.next()) |raw_line| {
        const line = std.mem.trimLeft(u8, std.mem.trim(u8, raw_line, " \r"), "- ");
        if (std.mem.startsWith(u8, line, "environment:")) try add(a, &f, "{s}: `{s}`: no environment (nothing here needs a protected one)", .{ file, line });
        // Nothing can switch the job or a step off. The only `if:` is the cleanup that must run even after a red step.
        if (std.mem.startsWith(u8, line, "if:") and !std.mem.eql(u8, line, "if: always()")) try add(a, &f, "{s}: `{s}`: no `if:` on the job or a step (the check must always run)", .{ file, line });
    }
    if (count(wf, "if:") != 1 or !has(wf, stop_step)) try add(a, &f, "{s}: the only `if:` is `if: always()` on the step that stops buck2 (`- name: Stop buck2`, `run: ./buck2 kill`)", .{file});

    // The commands: nothing that turns a red command green.
    const cmds = try wc.commands(a, wf);
    for (cmds) |c| {
        // the concurrency group is an expression, not a command: `a || b` there picks the pull request number or the commit
        if (std.mem.startsWith(u8, c, "group: ")) continue;
        for ([_][]const u8{ "|| ", "exit", "set +e", "trap ", "true", "; :", "&& :" }) |bad| {
            if (has(c, bad)) try add(a, &f, "{s}: `{s}` in `{s}` (a failing command must fail the job)", .{ file, bad, c });
        }
    }

    // The pin is read from pins.bzl by the program, never copied: no version, url or digest of a mopm release in this file.
    if (has(wf, mopm_repo)) try add(a, &f, "{s}: the workflow names the mopm repository (the url and the signer are the program's: it reads pins.bzl)", .{file});
    if (has(wf, "certificate-identity") or has(wf, "certificate-oidc-issuer") or has(wf, "verify-blob")) try add(a, &f, "{s}: the workflow runs or names cosign's verification itself (the program does, with the signer it tests)", .{file});
    const table = std.mem.indexOf(u8, pins, "MOPM_VERSIONS = {");
    if (table) |at| {
        var pit = std.mem.splitScalar(u8, pins[at..], '\n');
        while (pit.next()) |pl| {
            if (std.mem.startsWith(u8, std.mem.trimLeft(u8, pl, " "), "#")) continue;
            if (wc.between(pl, "\"sha256\": \"", "\"")) |sha| {
                if (has(wf, sha)) try add(a, &f, "{s}: the sha256 {s} of a pinned mopm is copied into the workflow (the program reads pins.bzl)", .{ file, sha });
            }
            if (wc.between(pl, "\"url\": \"", "\"")) |u| {
                if (has(wf, u)) try add(a, &f, "{s}: the url {s} of a pinned mopm is copied into the workflow (the program reads pins.bzl)", .{ file, u });
            }
        }
    } else try add(a, &f, "rules/mopm/pins.bzl has no `MOPM_VERSIONS = {{` table (this check is blind)", .{});

    // The buck2 install is the release pinned in tools/buck2, the build is in local mode, and the program is built (with its unit tests) before it runs.
    try wc.buck2Install(a, &f, wf, dotslash);
    const builds = try wc.localMode(a, &f, wf);
    if (builds != 1) try add(a, &f, "{s}: {d} `./buck2 build` commands (exactly one: the verifier)", .{ file, builds });
    var build_n: usize = 0;
    var verify_n: usize = 0;
    for (cmds) |c| {
        if (has(c, "./buck2 build")) {
            build_n += 1;
            if (!std.mem.endsWith(u8, c, build_cmd) or !(std.mem.eql(u8, c, build_cmd) or std.mem.eql(u8, c, "run: " ++ build_cmd)))
                try add(a, &f, "{s}: the build is not `{s}`", .{ file, build_cmd });
        }
        if (has(c, "mopm-pin verify")) {
            verify_n += 1;
            if (!std.mem.eql(u8, c, verify_cmd)) try add(a, &f, "{s}: the verify command is not exactly `{s}` (got `{s}`)", .{ file, verify_cmd, c });
        }
    }
    if (build_n != 1) try add(a, &f, "{s}: {d} builds of the verifier (exactly one: `{s}`)", .{ file, build_n, build_cmd });
    if (verify_n != 1) try add(a, &f, "{s}: {d} verify commands (exactly one: `{s}`)", .{ file, verify_n, verify_cmd });
    if (!has(wf, "        run: |\n          chmod +x mopm-pin\n          mkdir \"$RUNNER_TEMP/mopm-pin\"\n          " ++ verify_cmd ++ "\n"))
        try add(a, &f, "{s}: the verify step is not `chmod +x mopm-pin`, `mkdir \"$RUNNER_TEMP/mopm-pin\"` and the verify command, in one `run: |` block", .{file});

    // cosign: release.yml's install, once, before the verify.
    if (!has(release_raw, cosign_step)) try add(a, &f, "release.yml no longer spells the cosign install as this check expects (update both)", .{});
    if (count(wf, cosign_step) != 1 or count(wf, "sigstore/cosign-installer@") != 1) try add(a, &f, "{s}: the cosign install is not release.yml's step (the same action commit and `cosign-release: 'v3.0.6'`), once", .{file});
    const cosign_at = std.mem.indexOf(u8, wf, cosign_step);
    const build_at = std.mem.indexOf(u8, wf, build_cmd);
    const verify_at = std.mem.indexOf(u8, wf, verify_cmd);
    if (cosign_at == null or build_at == null or verify_at == null) {
        try add(a, &f, "{s}: the cosign install, the build or the verify command is missing", .{file});
    } else if (!(build_at.? < verify_at.? and cosign_at.? < verify_at.?)) {
        try add(a, &f, "{s}: the verify does not come after the build of the program and the install of cosign", .{file});
    }

    // The lint itself stays: ci/BUCK has actionlint read the file, and the workflow group builds this check and the program.
    if (!has(lintBlock(ci_buck), "\"//:mopm-pin.yml\"")) try add(a, &f, "ci/BUCK: actionlint (`workflow_lint`) does not read //:mopm-pin.yml", .{});
    if (workflowGroup(ci_buck)) |g| {
        for ([_][]const u8{ ":mopm_pin_workflow_check", ":mopm_pin_unit", ":mopm_pin\"" }) |need| {
            if (!has(g, need)) try add(a, &f, "ci/BUCK: the `workflow` group does not build `{s}`", .{need});
        }
    } else try add(a, &f, "ci/BUCK: no `workflow` group", .{});
    return f;
}

// ---- tests -----------------------------------------------------------------------------------------------------------------------------

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 22);
}

const Real = struct { wf: []const u8, release: []const u8, dotslash: []const u8, pins: []const u8, ci_buck: []const u8 };

fn real(a: std.mem.Allocator) !Real {
    return .{
        .wf = try work(a, ".github/workflows/mopm-pin.yml"),
        .release = try work(a, ".github/workflows/release.yml"),
        .dotslash = try work(a, "tools/buck2"),
        .pins = try work(a, "rules/mopm/pins.bzl"),
        .ci_buck = try work(a, "ci/BUCK"),
    };
}

fn mutate(a: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const i = std.mem.indexOf(u8, text, from) orelse return error.EditDidNotApply;
    return std.mem.concat(a, u8, &.{ text[0..i], to, text[i + from.len ..] });
}

fn expectFinding(a: std.mem.Allocator, r: Real, wf: []const u8, needle: []const u8) !void {
    const f = try check(a, wf, r.release, r.dotslash, r.pins, r.ci_buck);
    for (f.items) |m| {
        if (has(m, needle)) return;
    }
    std.debug.print("mopm-pin.yml: expected a finding with `{s}`, got {d}:\n", .{ needle, f.items.len });
    for (f.items) |m| std.debug.print("  {s}\n", .{m});
    return error.RuleDidNotFire;
}

fn expectEdit(a: std.mem.Allocator, r: Real, from: []const u8, to: []const u8, needle: []const u8) !void {
    try expectFinding(a, r, try mutate(a, r.wf, from, to), needle);
}

const verify_step = "      - name: Verify the pinned mopm release against its signature\n";

test "the real workflow has no findings" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const f = try check(a, r.wf, r.release, r.dotslash, r.pins, r.ci_buck);
    for (f.items) |m| std.debug.print("mopm-pin.yml finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "the parsers are not blind: the real file has its triggers, its job and its commands" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const wf = try rc.body(a, r.wf);
    try t.expectEqual(@as(usize, 2), (try rc.triggers(a, wf)).len);
    try t.expectEqual(@as(usize, 1), (try rc.parseJobs(a, wf)).len);
    try t.expectEqual(@as(usize, 1), (try topLines(a, wf, "permissions:")).?.len);
    try t.expect((try topLines(a, wf, "nothing:")) == null);
    var n: usize = 0;
    for (try wc.commands(a, wf)) |c| {
        if (has(c, "mopm-pin verify")) n += 1;
    }
    try t.expectEqual(@as(usize, 1), n);
    try t.expect(workflowGroup(r.ci_buck) != null);
    try t.expect(workflowGroup("nothing") == null);
}

test "the job removed, renamed, or the workflow renamed is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, "\n  verify:\n", "\n  check:\n", "no job `verify`");
    try expectEdit(a, r, "\nname: mopm-pin\n", "\nname: pin\n", "not named `mopm-pin`");
    try expectEdit(a, r, "    runs-on: ubuntu-latest\n", "    runs-on: self-hosted\n", "runs-on: ubuntu-latest");
}

test "a trigger that skips a pull request, or none, is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, "  pull_request:\n  workflow_dispatch:\n", "  workflow_dispatch:\n", "no `pull_request` trigger");
    try expectEdit(a, r, "  pull_request:\n  workflow_dispatch:\n", "  pull_request:\n    paths:\n      - rules/mopm/**\n  workflow_dispatch:\n", "can skip a pull request");
    try expectEdit(a, r, "  pull_request:\n  workflow_dispatch:\n", "  pull_request:\n    branches: [main]\n  workflow_dispatch:\n", "can skip a pull request");
    try expectEdit(a, r, "  pull_request:\n  workflow_dispatch:\n", "  pull_request:\n  workflow_dispatch:\n  push:\n", "the trigger `push`");
    try expectEdit(a, r, "  pull_request:\n  workflow_dispatch:\n", "  pull_request_target:\n  workflow_dispatch:\n", "pull_request_target");
}

test "a job or a step that can be switched off is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, verify_step, verify_step ++ "        if: github.event_name == 'workflow_dispatch'\n", "no `if:` on the job or a step");
    try expectEdit(a, r, "    runs-on: ubuntu-latest\n", "    if: false\n    runs-on: ubuntu-latest\n", "no `if:` on the job or a step");
    try expectEdit(a, r, verify_step, verify_step ++ "        if: always()\n", "the only `if:`");
    try expectEdit(a, r, stop_step, "      - name: Stop buck2\n        run: ./buck2 kill\n", "the only `if:`");
}

test "a step made non-blocking is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, verify_step, verify_step ++ "        continue-on-error: true\n", "`continue-on-error` is set to `true`");
    try expectEdit(a, r, "--cosign cosign\n", "--cosign cosign || true\n", "a failing command must fail the job");
    try expectEdit(a, r, "--cosign cosign\n", "--cosign cosign || echo skipped\n", "a failing command must fail the job");
    try expectEdit(a, r, "--cosign cosign\n", "--cosign cosign\n          exit 0\n", "a failing command must fail the job");
    try expectEdit(a, r, "          chmod +x mopm-pin\n", "          set +e\n          chmod +x mopm-pin\n", "a failing command must fail the job");
    try expectEdit(a, r, "--cosign cosign\n", "--cosign cosign; true\n", "a failing command must fail the job");
}

test "a verify command that is not the program run on pins.bzl with cosign is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, "--pins rules/mopm/pins.bzl", "--pins other.bzl", "the verify command is not exactly");
    try expectEdit(a, r, " --cosign cosign\n", "\n", "the verify command is not exactly");
    try expectEdit(a, r, "./mopm-pin verify", "./mopm-pin verify --extra", "the verify command is not exactly");
    try expectEdit(a, r, "          ./mopm-pin verify --pins rules/mopm/pins.bzl --work \"$RUNNER_TEMP/mopm-pin\" --cosign cosign\n", "", "0 verify commands");
    try expectEdit(a, r, "          ./mopm-pin verify --pins rules/mopm/pins.bzl --work \"$RUNNER_TEMP/mopm-pin\" --cosign cosign\n", "          echo ./mopm-pin verify\n", "the verify command is not exactly");
}

test "a cosign other than release.yml's, or none, or one after the verify is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, "cosign-release: 'v3.0.6'", "cosign-release: 'v3.0.5'", "not release.yml's step");
    try expectEdit(a, r, "cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2", "cosign-installer@v4", "not pinned to a full commit");
    try expectEdit(a, r, "          cosign-release: 'v3.0.6'\n", "", "not release.yml's step");
    // moved after the verify
    const moved = try mutate(a, try mutate(a, r.wf, cosign_step, ""), stop_step, cosign_step ++ stop_step);
    try expectFinding(a, r, moved, "does not come after the build of the program and the install of cosign");
    // release.yml drifted from the spelling this check holds both to
    const drifted = try std.mem.replaceOwned(u8, a, r.release, "cosign-release: 'v3.0.6'", "cosign-release: 'v3.1.0'");
    const f = try check(a, r.wf, drifted, r.dotslash, r.pins, r.ci_buck);
    var seen = false;
    for (f.items) |m| {
        if (has(m, "release.yml no longer spells the cosign install")) seen = true;
    }
    try t.expect(seen);
}

test "a signer, an issuer or a pin copied into the workflow is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, "--cosign cosign\n", "--cosign cosign --certificate-identity x\n", "names cosign's verification");
    try expectEdit(a, r, "          chmod +x mopm-pin\n", "          echo " ++ mopm_repo ++ "\n          chmod +x mopm-pin\n", "names the mopm repository");
    // the digest of the pinned tarball, written in the workflow
    const sha = wc.between(r.pins[std.mem.indexOf(u8, r.pins, "MOPM_VERSIONS = {").?..], "\"sha256\": \"", "\"").?;
    const text = try std.fmt.allocPrint(a, "          echo {s}\n          chmod +x mopm-pin\n", .{sha});
    try expectEdit(a, r, "          chmod +x mopm-pin\n", text, "is copied into the workflow");
}

test "a broader token, an environment, a secret or an unpinned or foreign action is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, "permissions:\n  contents: read\n", "permissions:\n  contents: write\n", "not exactly `contents: read`");
    try expectEdit(a, r, "permissions:\n  contents: read\n", "permissions:\n  contents: read\n  id-token: read\n", "not exactly `contents: read`");
    try expectEdit(a, r, "    timeout-minutes: 20\n", "    timeout-minutes: 20\n    permissions:\n      id-token: write\n", "a write permission is granted");
    try expectEdit(a, r, "    timeout-minutes: 20\n", "    timeout-minutes: 20\n    environment: release\n", "no environment");
    try expectEdit(a, r, "          chmod +x mopm-pin\n", "          echo ${{ secrets.X }}\n          chmod +x mopm-pin\n", "reads a secret");
    try expectEdit(a, r, "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n", "      - uses: actions/checkout@v4\n", "not pinned to a full commit");
    try expectEdit(a, r, "      - name: Stop buck2\n", "      - uses: someone/else@3d3c42e5aac5ba805825da76410c181273ba90b1\n      - name: Stop buck2\n", "is not allowed");
}

test "a build that is not the program in local mode, or the buck2 of another release, is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, "./buck2 build --console simple -c buildrules_re.mode=local", "./buck2 build --console simple", "does not pass `-c buildrules_re.mode=local`");
    try expectEdit(a, r, "//ci:mopm_pin\n", "//ci:mopm_pin_unit\n", "the build is not");
    try expectEdit(a, r, "      - name: Build the verifier\n", "      - name: Build the verifier\n        run: ./buck2 build --console simple -c buildrules_re.mode=local //ci:all\n      - name: Build it again\n", "2 builds of the verifier");
    try expectEdit(a, r, "download/2026-09-15/buck2-x86_64", "download/2026-09-14/buck2-x86_64", "does not download the url pinned in tools/buck2");
}

test "the lint dropped from ci/BUCK is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    var r2 = r;
    const lb = lintBlock(r.ci_buck);
    try t.expect(lb.len > 0);
    r2.ci_buck = try mutate(a, r.ci_buck, lb, try mutate(a, lb, "\"//:mopm-pin.yml\"", "\"//:other.yml\""));
    try expectFinding(a, r2, r.wf, "actionlint (`workflow_lint`) does not read");
    const g = workflowGroup(r.ci_buck).?;
    r2.ci_buck = try mutate(a, r.ci_buck, g, try mutate(a, g, ":mopm_pin_workflow_check", ":nothing"));
    try expectFinding(a, r2, r.wf, "does not build `:mopm_pin_workflow_check`");
    r2.ci_buck = try mutate(a, r.ci_buck, g, try mutate(a, g, ":mopm_pin_unit", ":nothing"));
    try expectFinding(a, r2, r.wf, "does not build `:mopm_pin_unit`");
    r2.ci_buck = try mutate(a, r.ci_buck, g, try mutate(a, g, ":mopm_pin\"", ":nothing\""));
    try expectFinding(a, r2, r.wf, "does not build `:mopm_pin\"`");
    r2.ci_buck = try mutate(a, r.ci_buck, "group(name = \"workflow\"", "group(name = \"flow\"");
    try expectFinding(a, r2, r.wf, "no `workflow` group");
}
