//! The farm-macos workflow (.github/workflows/farm-macos.yml) is what its header says it is: after the merge (a push to main, or a run started by hand, never a pull
//! request), on a linux runner, it joins the farm with its macOS workers and builds the targets labelled `macos-farm` there, and while those workers are not configured it
//! builds nothing and says so. A pure function of the text, so each rule is tested against an edited copy of the file as well as against the real files (the zig_test's
//! `data`, under BUILDRULES_TEST_WORK). The rules shared with the other workflows are workflow_check.zig's.
//!
//! What the rules catch:
//!  - a trigger that a change can start: the triggers are exactly `push` (to main) and `workflow_dispatch`, and the file never names a pull request;
//!  - a token with more than it needs: `contents: read` at the top, `id-token: write` in the farm job alone (the farm's network trusts that token), no secret, no environment;
//!  - a runner that is not hosted linux x86_64 (the Mac is the farm's worker, never a runner here), an action not pinned by commit or not GitHub's own, a buck2 that is not the
//!    release pinned in tools/buck2, a buck2 command of this file outside local mode (the farm build is the stage tool's);
//!  - the farm joined some other way: the farm-connect action checked out of the repository and commit FARM_CONNECT_REPO and FARM_CONNECT_REF name, its own directory alone,
//!    checked by `stage action-ref` before it runs, given the macOS worker set and host identities, then `stage farm-macos` with the file the action wrote;
//!  - the switch: the farm job runs exactly when its four variables are set, the other job exactly when one is not; that job notices when MACOS_ON_FARM is not `true`
//!    and fails when it is; and beta.yml's hosted leg of the same checks (`unpack_cross`, `unpack_macos`) is off exactly when MACOS_ON_FARM is `true`.
const std = @import("std");
const wc = @import("workflow_check.zig");
const rc = @import("release_check.zig");
const t = std.testing;

const Findings = wc.Findings;
const add = wc.add;

const file = "farm-macos.yml";
const farm_action = "./farm-action/.github/actions/farm-connect";

/// The four variables the farm job needs, set and not set.
const configured = "${{ vars.FARM_ADDRESS != '' && vars.FARM_CONNECT_REF != '' && vars.FARM_DARWIN_ARM64_PROPERTIES != '' && vars.FARM_DARWIN_MACOS_HOSTS != '' }}";
const not_configured = "${{ vars.FARM_ADDRESS == '' || vars.FARM_CONNECT_REF == '' || vars.FARM_DARWIN_ARM64_PROPERTIES == '' || vars.FARM_DARWIN_MACOS_HOSTS == '' }}";
const switch_off = "${{ vars.MACOS_ON_FARM != 'true' }}";
const switch_on = "${{ vars.MACOS_ON_FARM == 'true' }}";

/// The hosted leg of beta.yml whose checks this workflow runs on the farm (ci/stages_check.zig allows them this one `if:`).
const hosted_leg = [_][]const u8{ "unpack_cross", "unpack_macos" };

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

/// The text of the job `name` as it is written (its lines keep their indentation), from its header to the next job's, or "" when there is none.
fn jobBlock(wf: []const u8, name: []const u8) []const u8 {
    var buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "\n  {s}:\n", .{name}) catch return "";
    const s = std.mem.indexOf(u8, wf, header) orelse return "";
    var pos = s + header.len;
    while (std.mem.indexOfPos(u8, wf, pos, "\n  ")) |i| {
        const c = if (i + 3 < wf.len) wf[i + 3] else ' ';
        if (c != ' ' and c != '\n' and c != '#') return wf[s..i];
        pos = i + 1;
    }
    return wf[s..];
}

/// The steps of a job's text, each from its `- ` line to the next.
fn steps(a: std.mem.Allocator, jt: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var from: ?usize = null;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, jt, pos, "\n      - ")) |i| {
        if (from) |s| try out.append(jt[s..i]);
        from = i;
        pos = i + 1;
    }
    if (from) |s| try out.append(jt[s..]);
    return out.toOwnedSlice();
}

/// The step that holds `needle`, if exactly one does.
fn stepWith(a: std.mem.Allocator, jt: []const u8, needle: []const u8) !?[]const u8 {
    var found: ?[]const u8 = null;
    for (try steps(a, jt)) |s| {
        if (!has(s, needle)) continue;
        if (found != null) return null;
        found = s;
    }
    return found;
}

/// Everything wrong with `raw` (farm-macos.yml), given tools/buck2 (the dotslash file) and beta.yml.
pub fn check(a: std.mem.Allocator, raw: []const u8, dotslash: []const u8, beta: []const u8) !Findings {
    var f = Findings.init(a);
    const wf = try rc.body(a, raw);

    try wc.noContinueOnError(a, &f, wf);
    try wc.noInlineContext(a, &f, wf);
    try wc.prRunners(a, &f, wf);
    const uses = try wc.pinnedUses(a, &f, wf, &.{farm_action});
    if (uses == 0) try add(a, &f, "{s}: no `uses:` line found (this parser is blind)", .{file});
    var uit = std.mem.splitScalar(u8, wf, '\n');
    while (uit.next()) |line| {
        if (rc.usesRepo(line)) |repo| {
            if (!std.mem.startsWith(u8, repo, "actions/") and !std.mem.eql(u8, repo, farm_action))
                try add(a, &f, "{s}: the action `{s}` is not allowed (GitHub's own `actions/` actions and the farm-connect action checked out at FARM_CONNECT_REF)", .{ file, repo });
        }
    }
    if (std.mem.count(u8, wf, "actions/checkout@") != std.mem.count(u8, wf, "persist-credentials: false"))
        try add(a, &f, "{s}: a checkout keeps its credentials (every `actions/checkout` has `persist-credentials: false`)", .{file});

    // Triggers: after the merge, and by hand; nothing a change can start.
    const trig = try rc.triggers(a, wf);
    if (!sameSet(trig, &.{ "push", "workflow_dispatch" })) try add(a, &f, "{s}: the triggers are not exactly `push` and `workflow_dispatch` (got {d}): the farm's Macs are not a pull request's", .{ file, trig.len });
    if (!has(wf, "\n  push:\n    branches: [main]\n")) try add(a, &f, "{s}: the push trigger is not `branches: [main]` alone", .{file});
    for ([_][]const u8{ "pull_request", "workflow_run", "workflow_call", "secrets.", "write-all", "environment:" }) |bad| {
        if (has(wf, bad)) try add(a, &f, "{s}: `{s}` is present", .{ file, bad });
    }

    // The token: the contents at the top; the id-token in the farm job alone.
    if (!has(wf, "\npermissions:\n  contents: read\n\n")) try add(a, &f, "{s}: the top-level permissions are not `contents: read` alone", .{file});
    if (std.mem.count(u8, wf, ": write") != 1 or std.mem.count(u8, wf, "id-token: write") != 1) try add(a, &f, "{s}: a write scope other than the farm job's one `id-token: write`", .{file});

    // Two jobs, each under the exact condition of the variables.
    const jobs = try rc.parseJobs(a, wf);
    if (jobs.len != 2) try add(a, &f, "{s}: the workflow has {d} jobs, not exactly `not_configured` and `macos`", .{ file, jobs.len });
    for (jobs) |*j| {
        if (!j.has_perms) try add(a, &f, "{s}: the job `{s}` does not state its permissions", .{ file, j.name });
    }
    if (rc.jobNamed(jobs, "not_configured")) |j| {
        const jt = jobBlock(wf, "not_configured");
        if (j.if_expr == null or !std.mem.eql(u8, j.if_expr.?, not_configured)) try add(a, &f, "{s}: the job `not_configured` does not run exactly when one of the four variables is empty (`if: {s}`)", .{ file, not_configured });
        if (rc.permLevel(j, "id-token") != null) try add(a, &f, "{s}: the job `not_configured` holds an id-token", .{file});
        const notice = try stepWith(a, jt, "::notice title=farm-macos::");
        if (notice == null or !has(notice.?, "        if: " ++ switch_off ++ "\n")) try add(a, &f, "{s}: no one step says with a notice that nothing was built while MACOS_ON_FARM is not `true` (`if: {s}`)", .{ file, switch_off });
        const err = try stepWith(a, jt, "::error title=farm-macos::");
        if (err == null or !has(err.?, "        if: " ++ switch_on ++ "\n") or !std.mem.endsWith(u8, std.mem.trimRight(u8, err.?, " \n"), "&& false"))
            try add(a, &f, "{s}: no one step fails (`&& false`) while MACOS_ON_FARM is `true` and the macOS workers are not configured (`if: {s}`)", .{ file, switch_on });
        if (has(jt, "./buck2") or has(jt, "stage\"")) try add(a, &f, "{s}: the job `not_configured` builds something", .{file});
    } else try add(a, &f, "{s}: the job `not_configured` is missing", .{file});

    if (rc.jobNamed(jobs, "macos")) |j| {
        const jt = jobBlock(wf, "macos");
        if (j.if_expr == null or !std.mem.eql(u8, j.if_expr.?, configured)) try add(a, &f, "{s}: the job `macos` does not run exactly when the four variables are set (`if: {s}`)", .{ file, configured });
        const idt = rc.permLevel(j, "id-token");
        if (idt == null or !std.mem.eql(u8, idt.?, "write")) try add(a, &f, "{s}: the job `macos` does not hold `id-token: write`, which joining the farm's network needs", .{file});
        // the farm is joined as beta.yml's farm leg joins it, in this order
        const markers = [_][]const u8{
            "--out \"$RUNNER_TEMP/stage\" //tools/stage:stage\n",
            "repository: ${{ vars.FARM_CONNECT_REPO }}\n          ref: ${{ vars.FARM_CONNECT_REF }}\n          path: farm-action\n          sparse-checkout: .github/actions/farm-connect\n          sparse-checkout-cone-mode: false\n",
            "\"$RUNNER_TEMP/stage\" action-ref --dir farm-action --ref \"$CONNECT_REF\"",
            "uses: " ++ farm_action ++ "\n",
            "\"$RUNNER_TEMP/stage\" farm-macos --root \"$GITHUB_WORKSPACE\" --buck2 \"$GITHUB_WORKSPACE/buck2\" --farm-config \"$HOME/.buckconfig.d/farm.buckconfig\"",
        };
        var at: usize = 0;
        for (markers) |m| {
            const i = std.mem.indexOfPos(u8, jt, at, m);
            if (i == null) {
                try add(a, &f, "{s}: the job `macos` has no `{s}` after the step before it (order: the stage tool, the checkout of the action's directory alone, action-ref, farm-connect, farm-macos)", .{ file, m });
                break;
            }
            at = i.?;
        }
        if (!has(jt, "      CONNECT_REF: ${{ vars.FARM_CONNECT_REF }}\n")) try add(a, &f, "{s}: the job `macos` does not give action-ref the commit FARM_CONNECT_REF names", .{file});
        for ([_][]const u8{
            "farm-properties: ${{ vars.FARM_LINUX_X86_64_PROPERTIES }}\n",
            "darwin-properties: ${{ vars.FARM_DARWIN_ARM64_PROPERTIES }}\n",
            "darwin-macos-hosts: ${{ vars.FARM_DARWIN_MACOS_HOSTS }}\n",
        }) |input| {
            if (!has(jt, input)) try add(a, &f, "{s}: the farm-connect step is not given `{s}`", .{ file, std.mem.trimRight(u8, input, "\n") });
        }
    } else try add(a, &f, "{s}: the job `macos` is missing", .{file});

    // The buck2 of this file builds the stage tool on the runner, in local mode, with the pinned release; the farm build is the stage tool's.
    if ((try wc.localMode(a, &f, wf)) == 0) try add(a, &f, "{s}: no `./buck2 build` command found", .{file});
    try wc.buck2Install(a, &f, wf, dotslash);

    // The other side of the switch: beta.yml's hosted leg is off exactly when MACOS_ON_FARM is `true`.
    const beta_jobs = try rc.parseJobs(a, try rc.body(a, beta));
    for (hosted_leg) |name| {
        const j = rc.jobNamed(beta_jobs, name) orelse {
            try add(a, &f, "beta.yml has no job `{s}`: the hosted leg of the checks this workflow runs", .{name});
            continue;
        };
        if (j.if_expr == null or !std.mem.eql(u8, j.if_expr.?, switch_off)) try add(a, &f, "beta.yml's `{s}` is not switched off by MACOS_ON_FARM (`if: {s}`)", .{ name, switch_off });
    }
    return f;
}

// ---- tests -----------------------------------------------------------------------------------------------------------------------------

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

const Real = struct { wf: []const u8, ds: []const u8, beta: []const u8 };

fn real(a: std.mem.Allocator) !Real {
    return .{
        .wf = try work(a, ".github/workflows/farm-macos.yml"),
        .ds = try work(a, "tools/buck2"),
        .beta = try work(a, ".github/workflows/beta.yml"),
    };
}

fn mutate(a: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const i = std.mem.indexOf(u8, text, from) orelse return error.DefectDidNotApply;
    return std.mem.concat(a, u8, &.{ text[0..i], to, text[i + from.len ..] });
}

fn expectFinding(a: std.mem.Allocator, r: Real, wf: []const u8, beta: []const u8, needle: []const u8) !void {
    const f = try check(a, wf, r.ds, beta);
    // a finding that holds the needle, else the test fails and prints the needle against the empty string
    var seen: []const u8 = "";
    for (f.items) |m| {
        if (has(m, needle)) seen = needle;
    }
    if (seen.len == 0) for (f.items) |m| std.debug.print("  finding: {s}\n", .{m});
    try t.expectEqualStrings(needle, seen);
}

fn expectDefect(a: std.mem.Allocator, r: Real, from: []const u8, to: []const u8, needle: []const u8) !void {
    try expectFinding(a, r, try mutate(a, r.wf, from, to), r.beta, needle);
}

test "the real workflow has no findings" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const f = try check(a, r.wf, r.ds, r.beta);
    for (f.items) |m| std.debug.print("farm-macos.yml finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "the parsers are not blind: the real file has the triggers, the jobs and the steps the rules read" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const wf = try rc.body(a, r.wf);
    try t.expectEqual(@as(usize, 2), (try rc.triggers(a, wf)).len);
    const jobs = try rc.parseJobs(a, wf);
    try t.expectEqual(@as(usize, 2), jobs.len);
    const nc = jobBlock(wf, "not_configured");
    try t.expect(std.mem.endsWith(u8, std.mem.trimRight(u8, nc, " \n"), "&& false"));
    try t.expect(std.mem.startsWith(u8, jobBlock(wf, "macos"), "\n  macos:\n"));
    try t.expectEqualStrings("", jobBlock(wf, "none"));
    try t.expectEqual(@as(usize, 2), (try steps(a, nc)).len);
    try t.expect((try stepWith(a, nc, "::notice title=farm-macos::")) != null);
    try t.expect((try stepWith(a, nc, "title=farm-macos::")) == null);
    try t.expectEqual(@as(usize, 0), (try steps(a, "    runs-on: ubuntu-latest\n")).len);
}

test "a trigger a change can start, or a push to another branch, is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectDefect(a, r, "on:\n  push:", "on:\n  pull_request:\n  push:", "triggers are not exactly");
    try expectDefect(a, r, "on:\n  push:", "on:\n  pull_request:\n  push:", "`pull_request` is present");
    try expectDefect(a, r, "  workflow_dispatch:\n", "  workflow_call:\n", "triggers are not exactly");
    try expectDefect(a, r, "  workflow_dispatch:\n", "  workflow_dispatch:\n  workflow_call:\n", "`workflow_call` is present");
    try expectDefect(a, r, "    branches: [main]\n", "    branches: [main, next]\n", "not `branches: [main]` alone");
}

test "a token with more than it needs, or a farm job without its id-token, is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectDefect(a, r, "permissions:\n  contents: read\n\njobs", "permissions:\n  contents: write\n\njobs", "top-level permissions are not");
    try expectDefect(a, r, "      contents: read\n    steps:", "      contents: read\n      id-token: write\n    steps:", "other than the farm job's one");
    try expectDefect(a, r, "      id-token: write\n", "", "does not hold `id-token: write`");
    try expectDefect(a, r, "    timeout-minutes: 120\n", "    timeout-minutes: 120\n    environment: farm\n", "`environment:` is present");
    try expectDefect(a, r, "    timeout-minutes: 5\n    permissions:\n      contents: read\n", "    timeout-minutes: 5\n", "does not state its permissions");
    try expectDefect(a, r, "          ts-client-id: ${{ vars.TS_CLIENT_ID }}\n", "          ts-client-id: ${{ secrets.TS_CLIENT_ID }}\n", "`secrets.` is present");
}

test "a runner that is not hosted linux x86_64, an action not pinned or not allowed, a checkout with credentials, or a continue-on-error is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectDefect(a, r, "    runs-on: ubuntu-latest\n    timeout-minutes: 120\n", "    runs-on: macos-15\n    timeout-minutes: 120\n", "macos-15");
    try expectDefect(a, r, "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "actions/checkout@v7", "not pinned to a full commit");
    try expectDefect(a, r, "uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "uses: someone/else@3d3c42e5aac5ba805825da76410c181273ba90b1", "is not allowed");
    try expectDefect(a, r, "uses: " ++ farm_action ++ "\n", "uses: ./other/farm-connect\n", "not pinned to a full commit");
    try expectDefect(a, r, "        with:\n          persist-credentials: false\n", "", "keeps its credentials");
    try expectDefect(a, r, "    timeout-minutes: 120\n", "    timeout-minutes: 120\n    continue-on-error: true\n", "`continue-on-error` is set");
    try expectFinding(a, r, "name: x\n", r.beta, "no `uses:` line found");
}

test "the switch: either job under another condition, a notice or a failure that is gone or wrong, and beta.yml's hosted leg not switched, are found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectDefect(a, r, "    if: " ++ configured ++ "\n", "    if: ${{ vars.FARM_ADDRESS != '' }}\n", "does not run exactly when the four variables are set");
    try expectDefect(a, r, "    if: " ++ not_configured ++ "\n", "", "does not run exactly when one of the four variables is empty");
    try expectDefect(a, r, "        if: " ++ switch_off ++ "\n", "", "says with a notice");
    try expectDefect(a, r, "        if: " ++ switch_on ++ "\n", "        if: " ++ switch_off ++ "\n", "fails (`&& false`)");
    try expectDefect(a, r, " Set them, or unset MACOS_ON_FARM.\" && false", " Set them, or unset MACOS_ON_FARM.\"", "fails (`&& false`)");
    try expectDefect(a, r, "      - name: the macOS checks are on the farm", "      - run: ./buck2 build --console simple -c buildrules_re.mode=local //tools/stage:stage\n      - name: the macOS checks are on the farm", "`not_configured` builds something");
    try expectDefect(a, r, "      contents: read\n    steps:", "      contents: read\n      id-token: read\n    steps:", "`not_configured` holds an id-token");
    try expectDefect(a, r, "\n  not_configured:\n", "\n  unconfigured:\n", "the job `not_configured` is missing");
    try expectDefect(a, r, "\n  macos:\n", "\n  mac:\n", "the job `macos` is missing");
    try expectDefect(a, r, "\njobs:\n", "\njobs:\n  other:\n    runs-on: ubuntu-latest\n    permissions:\n      contents: read\n    steps:\n      - run: true\n", "not exactly `not_configured` and `macos`");
    const leg = "    if: " ++ switch_off ++ "\n";
    const off_cross = try mutate(a, r.beta, "    runs-on: ubuntu-latest\n" ++ leg, "    runs-on: ubuntu-latest\n");
    try expectFinding(a, r, r.wf, off_cross, "beta.yml's `unpack_cross` is not switched off");
    try expectFinding(a, r, r.wf, try mutate(a, r.beta, "    needs: unpack_cross\n" ++ leg, "    needs: unpack_cross\n    if: ${{ vars.MACOS_ON_FARM == '' }}\n"), "beta.yml's `unpack_macos` is not switched off");
    try expectFinding(a, r, r.wf, try mutate(a, r.beta, "\n  unpack_macos:\n", "\n  unpack_macos_x:\n"), "beta.yml has no job `unpack_macos`");
}

test "the farm joined another way, or the stage tool not given what it needs, is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectDefect(a, r, "          sparse-checkout: .github/actions/farm-connect\n", "", "has no `repository:");
    try expectDefect(a, r, "          sparse-checkout-cone-mode: false\n", "", "has no `repository:");
    try expectDefect(a, r, "repository: ${{ vars.FARM_CONNECT_REPO }}", "repository: someone/farm", "has no `repository:");
    try expectDefect(a, r, "action-ref --dir farm-action --ref \"$CONNECT_REF\"", "action-ref --dir farm-action --ref main", "action-ref --dir farm-action");
    try expectDefect(a, r, "      CONNECT_REF: ${{ vars.FARM_CONNECT_REF }}\n", "      CONNECT_REF: main\n", "does not give action-ref the commit");
    try expectDefect(a, r, "--farm-config \"$HOME/.buckconfig.d/farm.buckconfig\"", "--farm-config farm.buckconfig", "farm-macos --root");
    try expectDefect(a, r, "--out \"$RUNNER_TEMP/stage\" //tools/stage:stage", "--out \"$RUNNER_TEMP/stage\" //tools/stage:stage_unit", "//tools/stage:stage\n` after");
    try expectDefect(a, r, "          darwin-properties: ${{ vars.FARM_DARWIN_ARM64_PROPERTIES }}\n", "", "not given `darwin-properties");
    try expectDefect(a, r, "          darwin-macos-hosts: ${{ vars.FARM_DARWIN_MACOS_HOSTS }}\n", "", "not given `darwin-macos-hosts");
    try expectDefect(a, r, "          farm-properties: ${{ vars.FARM_LINUX_X86_64_PROPERTIES }}\n", "", "not given `farm-properties");
    // the farm-connect step before action-ref
    const connect_at = std.mem.indexOf(u8, r.wf, "      - name: connect to the farm").?;
    const build_at = std.mem.indexOf(u8, r.wf, "      - name: The macos-farm targets").?;
    const ref_at = std.mem.indexOf(u8, r.wf, "      - name: the action that joins the farm").?;
    const swapped = try std.mem.concat(a, u8, &.{ r.wf[0..ref_at], r.wf[connect_at..build_at], r.wf[ref_at..connect_at], r.wf[build_at..] });
    try expectFinding(a, r, swapped, r.beta, "uses: " ++ farm_action);
}

test "a buck2 that is not the pinned release, a build outside local mode, an endpoint, or a value expanded into a script is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectDefect(a, r, "1268fce33fb6", "0268fce33fb6", "sha256 pinned");
    try expectDefect(a, r, "build --console simple -c buildrules_re.mode=local --out", "build --console simple --out", "does not pass `-c buildrules_re.mode=local`");
    try expectDefect(a, r, "      - name: Stop the buck2 of the local build\n        run: ./buck2 kill\n", "      - name: Stop the buck2 of the local build\n        run: ./buck2 build //tools/bootstrap:darwin_integration\n", "does not pass `-c buildrules_re.mode=local`");
    try expectDefect(a, r, "        run: ./buck2 build --console simple -c buildrules_re.mode=local --out \"$RUNNER_TEMP/stage\" //tools/stage:stage\n", "        run: \"$RUNNER_TEMP/stage\" version --buildrules x\n", "no `./buck2 build` command found");
    try expectDefect(a, r, "    env:\n", "    env:\n      X: engine_address\n", "mentions `engine_address`");
    try expectDefect(a, r, "action-ref --dir farm-action --ref \"$CONNECT_REF\"", "action-ref --dir farm-action --ref \"${{ vars.FARM_CONNECT_REF }}\"", "expands `vars.` inline");
}
