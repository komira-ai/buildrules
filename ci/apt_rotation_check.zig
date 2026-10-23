//! The keyring-rotation workflow (.github/workflows/apt-rotation.yml) is what its header says it is: the proof, with the real gpg, gpgv and apt and keys made in the job, that a
//! repository signed by two keys verifies and installs with either key alone. A pure function of the text, so each rule is tested against edited text as well as against the real
//! file (the zig_test's `data`, under BUILDRULES_TEST_WORK). The rules shared with the other workflows (actions pinned by commit, no `continue-on-error`, no inline expansion of
//! `vars.` or `github.event.` in a `run:`, the pinned buck2, local mode) are workflow_check.zig's; the job parser is release_check.zig's.
//!
//! What the rules catch:
//!  - a proof that stops running: the triggers are exactly `pull_request`, `schedule` and `workflow_dispatch`; the pull request is filtered to the apt tooling (tools/channels,
//!    tools/deploy, packaging/deb) and the workflow file itself, and the schedule is weekly;
//!  - a token with more than it needs, or a secret: the top level grants `contents: read` alone, no job has its own `permissions`, and nothing writes or reads a secret (the keys
//!    are made in the job);
//!  - a proof of other programs than the repository's: the three programs are built from //tools/deploy:apt_rotation, //tools/deploy:apt_publish and //tools/channels:channels,
//!    with the pinned buck2 in local mode, and `apt_rotation make` is given the other two;
//!  - a distribution that is not the pinned one: the images are exactly debian:12, ubuntu:22.04 and ubuntu:24.04, each by digest (`@sha256:` and 64 hex digits), and the two
//!    `docker run`s of the apt job take theirs from the matrix and nowhere else;
//!  - a leg that proves less: both keys are in the matrix (`signed_by: [a, b]`), the positive run is `--expect ok` with the keyring of that key, the control is `--expect refused`
//!    with the key that signed nothing, nothing can switch a step off (`if:` only on the `Stop buck2` step, as `always()`), and no failure is allowed to pass;
//!  - a workflow and a program that disagree: the artifact the first job uploads is the one the second downloads, the package and the file the containers look for are the ones
//!    apt_rotation.zig builds, and the keyrings and the commands it names are the ones it writes and has.
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

const file = "apt-rotation.yml";

/// The pull request paths: the apt tooling and this file.
const pr_paths = [_][]const u8{ ".github/workflows/apt-rotation.yml", "tools/channels/**", "tools/deploy/**", "packaging/deb/**" };

/// The distributions, each as the start of an image reference that is followed by `@sha256:` and a digest.
const distros = [_][]const u8{ "debian:12", "ubuntu:22.04", "ubuntu:24.04" };

const builds = [_][2][]const u8{
    .{ "rot-bin/apt_rotation", "//tools/deploy:apt_rotation" },
    .{ "rot-bin/apt_publish", "//tools/deploy:apt_publish" },
    .{ "rot-bin/channels", "//tools/channels:channels" },
};

const make_cmd = "rot-bin/apt_rotation make --work \"$RUNNER_TEMP/rotation-work\" --out rot --channels \"$PWD/rot-bin/channels\" --apt-publish \"$PWD/rot-bin/apt_publish\" --packaging packaging/deb";
const docker_head = "docker run --rm --volume \"$PWD/rot:/rot:ro\" \"$IMAGE\" /rot/apt_rotation apt-check --repo /rot/repo --keyring ";
const docker_tail = " --package rotation-test --installed-file /usr/share/rotation-test/hello --work /var/tmp/aptrot --expect ";
const run_ok = docker_head ++ "\"/rot/keys/$SIGNED_BY.gpg\"" ++ docker_tail ++ "ok";
const run_refused = docker_head ++ "/rot/keys/other.gpg" ++ docker_tail ++ "refused";

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

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

/// The entries (`- value`) under the key line `header` (exact, with its indentation) of the workflow, up to the first line that is not an entry of that depth.
fn entries(a: std.mem.Allocator, wf: []const u8, header: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var in = false;
    var dash: []const u8 = "";
    var it = std.mem.splitScalar(u8, wf, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, " \r");
        if (!in) {
            if (std.mem.eql(u8, line, header)) {
                in = true;
                dash = try std.fmt.allocPrint(a, "{s}  - ", .{header[0 .. header.len - std.mem.trimLeft(u8, header, " ").len]});
            }
            continue;
        }
        if (!std.mem.startsWith(u8, line, dash)) break;
        try out.append(std.mem.trim(u8, line[dash.len..], " \""));
    }
    return out.toOwnedSlice();
}

/// A weekly cron: five fields, the day of the month and the month `*`, the day of the week one digit.
fn weekly(cron: []const u8) bool {
    var fields = std.mem.tokenizeScalar(u8, cron, ' ');
    var n: usize = 0;
    var ok = true;
    while (fields.next()) |fld| : (n += 1) {
        switch (n) {
            0, 1 => for (fld) |c| {
                if (!std.ascii.isDigit(c)) ok = false;
            },
            2, 3 => if (!std.mem.eql(u8, fld, "*")) {
                ok = false;
            },
            4 => if (fld.len != 1 or !std.ascii.isDigit(fld[0])) {
                ok = false;
            },
            else => ok = false,
        }
    }
    return ok and n == 5;
}

/// Whether the step that uses `actions/<action>@...` has exactly `with_body` (the lines of its `with:` block) right after its `uses:` line.
fn stepWith(wf: []const u8, action: []const u8, with_body: []const u8) bool {
    var buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "      - uses: actions/{s}@", .{action}) catch return false;
    const at = std.mem.indexOf(u8, wf, key) orelse return false;
    const eol = std.mem.indexOfScalarPos(u8, wf, at, '\n') orelse return false;
    const with = "        with:\n";
    const rest = wf[eol + 1 ..];
    return std.mem.startsWith(u8, rest, with) and std.mem.startsWith(u8, rest[with.len..], with_body);
}

/// A logical command line without its leading `run: `.
fn stepCmd(c: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, c, "run: ")) c["run: ".len..] else c;
}

/// Everything wrong with `raw`, given the dotslash file of the pinned buck2 and the text of tools/deploy/apt_rotation.zig.
pub fn check(a: std.mem.Allocator, raw: []const u8, dotslash: []const u8, rotation_src: []const u8) !Findings {
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

    // Triggers: a change to the apt tooling, every week, and by hand.
    const trig = try rc.triggers(a, wf);
    if (!sameSet(trig, &.{ "pull_request", "schedule", "workflow_dispatch" })) try add(a, &f, "{s}: the triggers are not exactly `pull_request`, `schedule` and `workflow_dispatch` (got {d})", .{ file, trig.len });
    const paths = try entries(a, wf, "    paths:");
    if (paths.len != pr_paths.len or !sameSet(paths, &pr_paths)) try add(a, &f, "{s}: the pull request `paths` are not exactly the apt tooling and this file", .{file});
    if (!has(wf, "  pull_request:\n    paths:\n")) try add(a, &f, "{s}: the pull request trigger has no `paths` filter", .{file});
    if (!has(wf, "  schedule:\n    - cron: \"")) {
        try add(a, &f, "{s}: no `schedule` with a cron entry", .{file});
    } else {
        const cron = wc.between(wf, "- cron: \"", "\"") orelse "";
        if (!weekly(cron)) try add(a, &f, "{s}: the cron `{s}` is not weekly (minute, hour, `*`, `*`, one weekday)", .{ file, cron });
    }

    // Permissions: read the contents and nothing else; no secret (the keys are made in the job).
    const top = try topLines(a, wf, "permissions:");
    if (top == null or !sameSet(top.?, &.{"contents: read"})) try add(a, &f, "{s}: the top-level permissions are not exactly `contents: read`", .{file});
    if (has(wf, "write-all") or has(wf, ": write")) try add(a, &f, "{s}: a write permission is granted", .{file});
    if (has(wf, "id-token")) try add(a, &f, "{s}: `id-token` is mentioned (no cloud role is assumed here)", .{file});
    if (has(wf, "secrets.")) try add(a, &f, "{s}: the workflow reads a secret (the keys it signs with are made in the job)", .{file});
    const jobs = try rc.parseJobs(a, wf);
    if (jobs.len != 2 or rc.jobNamed(jobs, "repo") == null or rc.jobNamed(jobs, "apt") == null) try add(a, &f, "{s}: the jobs are not exactly `repo` and `apt` (got {d})", .{ file, jobs.len });
    for (jobs) |j| {
        if (j.has_perms) try add(a, &f, "{s}: job `{s}` has its own `permissions` (the top level is the whole grant)", .{ file, j.name });
    }
    if (rc.jobNamed(jobs, "apt")) |j| {
        if (!rc.hasNeed(j, "repo")) try add(a, &f, "{s}: job `apt` does not need `repo` (the repository it installs from is made there)", .{file});
    }

    // Nothing switches a step off: the one `if:` is `always()` on the step that stops buck2.
    var ifs: usize = 0;
    var if_ok = true;
    var prev: []const u8 = "";
    var lit = std.mem.splitScalar(u8, wf, '\n');
    while (lit.next()) |raw_line| {
        const line = std.mem.trimLeft(u8, std.mem.trim(u8, raw_line, " \r"), "- ");
        if (std.mem.startsWith(u8, line, "if:")) {
            ifs += 1;
            if (!std.mem.eql(u8, line, "if: always()") or !std.mem.eql(u8, std.mem.trim(u8, prev, " \r-"), "name: Stop buck2")) if_ok = false;
        }
        prev = raw_line;
    }
    if (ifs != 1 or !if_ok) try add(a, &f, "{s}: `if:` appears {d} time(s) (exactly one, `if: always()` on the `Stop buck2` step: nothing else may switch a step off)", .{ file, ifs });

    // The programs: the repository's own, built by the pinned buck2 in local mode.
    try wc.buck2Install(a, &f, wf, dotslash);
    const n_builds = try wc.localMode(a, &f, wf);
    if (n_builds != builds.len or count(wf, "./buck2 build") != builds.len) try add(a, &f, "{s}: {d} `./buck2 build` commands (exactly the {d} programs)", .{ file, n_builds, builds.len });
    for (builds) |b| {
        const want = try std.fmt.allocPrint(a, "./buck2 build --console simple -c buildrules_re.mode=local --out {s} {s}\n", .{ b[0], b[1] });
        if (!has(wf, want)) try add(a, &f, "{s}: the build of {s} is not `{s}`", .{ file, b[1], std.mem.trim(u8, want, "\n") });
    }
    if (!has(wf, make_cmd ++ "\n")) try add(a, &f, "{s}: the `make` step is not `{s}`", .{ file, make_cmd });
    if (count(wf, "apt_rotation make") != 1) try add(a, &f, "{s}: `apt_rotation make` is not run exactly once", .{file});

    // The artifact: the repository, the keyrings and the program travel in one, from the first job to the second.
    if (!stepWith(wf, "upload-artifact", "          name: rotation\n          path: rot\n          retention-days: 1\n          if-no-files-found: error\n")) try add(a, &f, "{s}: the first job does not upload the artifact `rotation` from `rot` (the directory `make` writes), failing when there is no file", .{file});
    if (!stepWith(wf, "download-artifact", "          name: rotation\n          path: rot\n")) try add(a, &f, "{s}: the second job does not download the artifact `rotation` into `rot`", .{file});

    // The matrix: three distributions by digest, and both keys.
    if (!has(wf, "      fail-fast: false\n")) try add(a, &f, "{s}: the matrix does not set `fail-fast: false` (a red leg must not hide the others)", .{file});
    const images = try entries(a, wf, "        image:");
    if (images.len != distros.len) try add(a, &f, "{s}: {d} images in the matrix (exactly {d}: {s}, {s}, {s})", .{ file, images.len, distros.len, distros[0], distros[1], distros[2] });
    for (distros) |d| {
        var found: usize = 0;
        for (images) |img| {
            const at = std.mem.indexOfScalar(u8, img, '@') orelse img.len;
            if (std.mem.eql(u8, img[0..at], d)) found += 1;
        }
        if (found != 1) try add(a, &f, "{s}: the distribution {s} is in the matrix {d} times (exactly once)", .{ file, d, found });
    }
    for (images) |img| {
        const at = std.mem.indexOfScalar(u8, img, '@');
        if (at == null or !std.mem.startsWith(u8, img[at.? + 1 ..], "sha256:") or !isHex64(img[at.? + 1 + "sha256:".len ..])) try add(a, &f, "{s}: the image `{s}` is not pinned by digest (`name@sha256:` and 64 lowercase hex digits)", .{ file, img });
    }
    if (!has(wf, "        signed_by: [a, b]\n")) try add(a, &f, "{s}: the matrix does not hold exactly the two keys `signed_by: [a, b]`", .{file});

    // The runs: exactly two containers, the image from the matrix, the key of the leg, and the control with the key that signed nothing.
    var runs: usize = 0;
    var oks: usize = 0;
    var refused: usize = 0;
    for (try wc.commands(a, wf)) |c| {
        if (!has(c, "docker")) continue;
        runs += 1;
        const cmd = stepCmd(c);
        if (std.mem.eql(u8, cmd, run_ok)) oks += 1 else if (std.mem.eql(u8, cmd, run_refused)) refused += 1 else try add(a, &f, "{s}: `{s}` is neither the run with a key of the matrix nor the control", .{ file, cmd });
    }
    if (runs != 2 or oks != 1 or refused != 1) try add(a, &f, "{s}: {d} docker commands, {d} positive and {d} control (exactly one of each)", .{ file, runs, oks, refused });
    if (count(wf, "          IMAGE: ${{ matrix.image }}\n") != 2) try add(a, &f, "{s}: the image of both runs is not `IMAGE: ${{{{ matrix.image }}}}` in the step's env", .{file});
    if (count(wf, "          SIGNED_BY: ${{ matrix.signed_by }}\n") != 1) try add(a, &f, "{s}: the key of the positive run is not `SIGNED_BY: ${{{{ matrix.signed_by }}}}` in the step's env", .{file});
    var mit = std.mem.splitScalar(u8, wf, '\n');
    while (mit.next()) |line| {
        if (has(line, "${{ matrix.")) {
            const l = std.mem.trim(u8, line, " \r");
            if (!std.mem.eql(u8, l, "IMAGE: ${{ matrix.image }}") and !std.mem.eql(u8, l, "SIGNED_BY: ${{ matrix.signed_by }}")) try add(a, &f, "{s}: `{s}`: the matrix is read only through the two env entries", .{ file, l });
        }
    }

    // The workflow and the program agree on what is made and what is looked for.
    for ([_][]const u8{
        "\"--name\", \"rotation-test\"",
        "usr/share/rotation-test/hello",
        "\"a.gpg\"",
        "\"b.gpg\"",
        "\"other.gpg\"",
        "\"keys\"",
        "\"repo\"",
        "std.mem.eql(u8, argv[1], \"make\")",
        "std.mem.eql(u8, argv[1], \"apt-check\")",
    }) |w| {
        if (!has(rotation_src, w)) try add(a, &f, "{s}: apt_rotation.zig does not have `{s}`, which this workflow relies on", .{ file, w });
    }
    return f;
}

// ---- tests -----------------------------------------------------------------------------------------------------------------------------

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

const Real = struct { wf: []const u8, dotslash: []const u8, src: []const u8 };

fn real(a: std.mem.Allocator) !Real {
    return .{ .wf = try work(a, ".github/workflows/apt-rotation.yml"), .dotslash = try work(a, "tools/buck2"), .src = try work(a, "tools/deploy/apt_rotation.zig") };
}

/// `text` with the first `from` replaced by `to`; fails the test if `from` is absent (an edit that changes nothing proves nothing).
fn mutate(a: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const i = std.mem.indexOf(u8, text, from) orelse return error.EditDidNotApply;
    return std.mem.concat(a, u8, &.{ text[0..i], to, text[i + from.len ..] });
}

fn expectFinding(a: std.mem.Allocator, r: Real, wf: []const u8, src: []const u8, needle: []const u8) !void {
    const f = try check(a, wf, r.dotslash, src);
    for (f.items) |m| {
        if (has(m, needle)) return;
    }
    std.debug.print("apt-rotation.yml: expected a finding with `{s}`, got {d}:\n", .{ needle, f.items.len });
    for (f.items) |m| std.debug.print("  {s}\n", .{m});
    return error.RuleDidNotFire;
}

fn expectEdit(a: std.mem.Allocator, r: Real, from: []const u8, to: []const u8, needle: []const u8) !void {
    try expectFinding(a, r, try mutate(a, r.wf, from, to), r.src, needle);
}

fn expectSrcEdit(a: std.mem.Allocator, r: Real, from: []const u8, to: []const u8, needle: []const u8) !void {
    try expectFinding(a, r, r.wf, try mutate(a, r.src, from, to), needle);
}

test "the real workflow has no findings" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const f = try check(a, r.wf, r.dotslash, r.src);
    for (f.items) |m| std.debug.print("apt-rotation.yml finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "the parsers are not blind: the real file has the triggers, the jobs, the images and the commands the rules read" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const wf = try rc.body(a, r.wf);
    try t.expectEqual(@as(usize, 3), (try rc.triggers(a, wf)).len);
    try t.expectEqual(@as(usize, 2), (try rc.parseJobs(a, wf)).len);
    try t.expectEqual(@as(usize, 4), (try entries(a, wf, "    paths:")).len);
    try t.expectEqual(@as(usize, 3), (try entries(a, wf, "        image:")).len);
    try t.expectEqual(@as(usize, 0), (try entries(a, wf, "        nothing:")).len);
    try t.expectEqual(@as(usize, 1), (try topLines(a, wf, "permissions:")).?.len);
    try t.expect((try topLines(a, wf, "nothing:")) == null);
    var docker: usize = 0;
    for (try wc.commands(a, wf)) |c| {
        if (has(c, "docker")) docker += 1;
    }
    try t.expectEqual(@as(usize, 2), docker);
    try t.expect(weekly("23 6 * * 1"));
    try t.expect(!weekly("23 6 * * *"));
    try t.expect(!weekly("23 6 1 * 1"));
    try t.expect(!weekly("23 6 * 5 1"));
    try t.expect(!weekly("23 x * * 1"));
    try t.expect(!weekly("23 6 * * 12"));
    try t.expect(!weekly("23 6 * *"));
    try t.expect(!weekly("23 6 * * 1 1"));
}

test "a rule refuses a trigger that is not a pull request on the apt tooling, a week, or a person" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, "on:\n  pull_request:", "on:\n  push:\n  pull_request:", "triggers are not exactly");
    try expectEdit(a, r, "  workflow_dispatch:\n", "", "triggers are not exactly");
    try expectEdit(a, r, "  schedule:\n    - cron: \"23 6 * * 1\"\n", "", "triggers are not exactly");
    try expectEdit(a, r, "on:\n  pull_request:", "on:\n  workflow_run:\n  pull_request:", "triggers are not exactly");
    try expectEdit(a, r, "  pull_request:\n    paths:\n", "  pull_request:\n", "no `paths` filter");
    try expectEdit(a, r, "      - \"tools/deploy/**\"\n", "", "are not exactly the apt tooling");
    try expectEdit(a, r, "      - \"tools/channels/**\"\n", "", "are not exactly the apt tooling");
    try expectEdit(a, r, "      - \"packaging/deb/**\"\n", "", "are not exactly the apt tooling");
    try expectEdit(a, r, "      - \".github/workflows/apt-rotation.yml\"\n", "", "are not exactly the apt tooling");
    try expectEdit(a, r, "      - \"packaging/deb/**\"\n", "      - \"packaging/deb/**\"\n      - \"docs/**\"\n", "are not exactly the apt tooling");
    try expectEdit(a, r, "\"23 6 * * 1\"", "\"23 6 * * *\"", "is not weekly");
    try expectEdit(a, r, "\"23 6 * * 1\"", "\"23 6 1 * *\"", "is not weekly");
    try expectEdit(a, r, "\"23 6 * * 1\"", "\"23 6 * *\"", "is not weekly");
    try expectEdit(a, r, "    - cron: \"23 6 * * 1\"\n", "", "no `schedule` with a cron");
}

test "a rule refuses a token with more than it needs, a secret, a job-level grant and a step that can be switched off" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, "permissions:\n  contents: read\n\nconcurrency", "permissions:\n  contents: write\n\nconcurrency", "top-level permissions are not exactly");
    try expectEdit(a, r, "permissions:\n  contents: read\n\nconcurrency", "permissions:\n  contents: read\n  pull-requests: read\n\nconcurrency", "top-level permissions are not exactly");
    try expectEdit(a, r, "permissions:\n  contents: read\n\nconcurrency", "permissions: write-all\n\nconcurrency", "a write permission is granted");
    try expectEdit(a, r, "permissions:\n  contents: read\n\nconcurrency", "concurrency", "top-level permissions are not exactly");
    try expectEdit(a, r, "  repo:\n    runs-on: ubuntu-latest\n", "  repo:\n    runs-on: ubuntu-latest\n    permissions:\n      contents: read\n", "has its own `permissions`");
    try expectEdit(a, r, "  repo:\n    runs-on: ubuntu-latest\n", "  repo:\n    runs-on: ubuntu-latest\n    permissions:\n      id-token: write\n", "`id-token` is mentioned");
    try expectEdit(a, r, "  repo:\n    runs-on: ubuntu-latest\n", "  repo:\n    runs-on: ubuntu-latest\n    permissions:\n      issues: write\n", "a write permission is granted");
    try expectEdit(a, r, "        with:\n          persist-credentials: false\n", "        with:\n          token: ${{ secrets.TOKEN }}\n", "reads a secret");
    try expectEdit(a, r, "  apt:\n    needs: repo\n", "  apt:\n    needs: []\n", "does not need `repo`");
    try expectEdit(a, r, "  apt:\n    needs: repo\n", "  extra:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n  apt:\n    needs: repo\n", "the jobs are not exactly");
    try expectEdit(a, r, "      - name: Stop buck2\n        if: always()\n", "      - name: Stop buck2\n", "`if:` appears 0 time");
    try expectEdit(a, r, "      - name: Stop buck2\n        if: always()\n", "      - name: Stop buck2\n        if: github.event_name == 'schedule'\n", "`if:` appears 1 time");
    try expectEdit(a, r, "      - run: chmod +x rot/apt_rotation\n", "      - if: false\n        run: chmod +x rot/apt_rotation\n", "`if:` appears 2 time");
    try expectEdit(a, r, "      - name: apt update and install with Signed-By the key of one signer\n", "      - name: apt update and install with Signed-By the key of one signer\n        if: false\n", "`if:` appears 2 time");
    try expectEdit(a, r, "    timeout-minutes: 20\n", "    timeout-minutes: 20\n    continue-on-error: true\n", "`continue-on-error` is set to `true`");
    try expectEdit(a, r, "      - name: Build the channels program\n", "      - name: Build the channels program\n        continue-on-error: true\n", "`continue-on-error` is set to `true`");
}

test "a rule refuses an action that is third-party or unpinned" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, "      - name: Install buck2\n", "      - uses: someone/setup@3d3c42e5aac5ba805825da76410c181273ba90b1\n      - name: Install buck2\n", "is not allowed");
    try expectEdit(a, r, "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "actions/checkout@v7", "not pinned to a full commit sha");
    try expectEdit(a, r, "actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333", "actions/download-artifact@v8", "not pinned to a full commit sha");
}

test "a rule refuses programs that are not the repository's own, or built any way but the pinned one" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, "releases/download/2026-09-15/buck2-x86_64-unknown-linux-gnu.zst", "releases/latest/download/buck2-x86_64-unknown-linux-gnu.zst", "does not download the url pinned");
    try expectEdit(a, r, "1268fce33fb61273091dd5dd8c60b65de1521a3caa36b88983813e882b7ffd89  buck2.zst", "0000000000000000000000000000000000000000000000000000000000000000  buck2.zst", "does not check the sha256 pinned");
    try expectEdit(a, r, "./buck2 build --console simple -c buildrules_re.mode=local --out rot-bin/apt_publish //tools/deploy:apt_publish", "./buck2 build --console simple --out rot-bin/apt_publish //tools/deploy:apt_publish", "does not pass `-c buildrules_re.mode=local`");
    try expectEdit(a, r, "-c buildrules_re.mode=local --out rot-bin/channels //tools/channels:channels", "-c buildrules_re.mode=remote --out rot-bin/channels //tools/channels:channels", "set to something other than `local`");
    try expectEdit(a, r, "--out rot-bin/channels //tools/channels:channels", "--out rot-bin/channels //tools/channels:channels_other", "the build of //tools/channels:channels is not");
    try expectEdit(a, r, "--out rot-bin/apt_rotation //tools/deploy:apt_rotation", "--out rot-bin/apt_rotation //tools/deploy:apt_publish", "the build of //tools/deploy:apt_rotation is not");
    try expectEdit(a, r, "      - name: Build the apt publish program\n        run: ./buck2 build --console simple -c buildrules_re.mode=local --out rot-bin/apt_publish //tools/deploy:apt_publish\n\n", "", "the build of //tools/deploy:apt_publish is not");
    try expectEdit(a, r, "      - name: Build the apt publish program\n        run: ./buck2 build --console simple -c buildrules_re.mode=local --out rot-bin/apt_publish //tools/deploy:apt_publish\n\n", "      - name: Build the apt publish program\n        run: ./buck2 build --console simple -c buildrules_re.mode=local --out rot-bin/apt_publish //tools/deploy:apt_publish\n\n      - run: ./buck2 build --console simple -c buildrules_re.mode=local //ci:all\n\n", "`./buck2 build` commands");
    try expectEdit(a, r, "--apt-publish \"$PWD/rot-bin/apt_publish\" --packaging packaging/deb", "--apt-publish \"$PWD/rot-bin/apt_publish\"", "the `make` step is not");
    try expectEdit(a, r, "--apt-publish \"$PWD/rot-bin/apt_publish\"", "--apt-publish /usr/bin/apt_publish", "the `make` step is not");
    try expectEdit(a, r, "          chmod +x rot-bin/apt_rotation rot-bin/apt_publish rot-bin/channels\n", "          chmod +x rot-bin/apt_rotation rot-bin/apt_publish rot-bin/channels\n          rot-bin/apt_rotation make --work x --out y --channels z --apt-publish w\n", "not run exactly once");
}

test "a rule refuses an artifact the two jobs do not share" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, "          name: rotation\n          path: rot\n          retention-days: 1\n", "          name: rotation\n          path: rotation-out\n          retention-days: 1\n", "does not upload the artifact");
    try expectEdit(a, r, "          if-no-files-found: error\n", "", "does not upload the artifact");
    try expectEdit(a, r, "          name: rotation\n          path: rot\n\n      - run: chmod", "          name: rotation-other\n          path: rot\n\n      - run: chmod", "does not download the artifact");
}

test "a rule refuses an image that is not one of the three distributions by digest" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, "debian:12@sha256:854dd8ab51d62866dbd8f5431d15ce77b12983a2a4a1e1fe43a2395dc7ef9f61", "debian:12", "is not pinned by digest");
    try expectEdit(a, r, "ubuntu:22.04@sha256:0a9887931b0e38af2e3487ed39e29436b0535c4f3f52e57745baaf79d1898956", "ubuntu:22.04@sha256:0a98", "is not pinned by digest");
    try expectEdit(a, r, "ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac", "ubuntu:24.04@sha256:68EE22004A9109B44973313B02FF7B1DE250F1DE0F5ECB628D73F579AAFF33AC", "is not pinned by digest");
    try expectEdit(a, r, "ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac", "ubuntu:24.04@md5:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac", "is not pinned by digest");
    try expectEdit(a, r, "          - ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac\n", "", "2 images in the matrix");
    try expectEdit(a, r, "          - ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac\n", "          - ubuntu:26.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac\n", "ubuntu:24.04 is in the matrix 0 times");
    try expectEdit(a, r, "          - ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac\n", "          - ubuntu:22.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac\n", "ubuntu:22.04 is in the matrix 2 times");
    try expectEdit(a, r, "          - ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac\n", "          - ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac\n          - alpine:3@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac\n", "4 images in the matrix");
    try expectEdit(a, r, "      fail-fast: false\n", "", "`fail-fast: false`");
}

test "a rule refuses a leg that proves less: one key, a hidden image, a changed control" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, "signed_by: [a, b]", "signed_by: [a]", "`signed_by: [a, b]`");
    try expectEdit(a, r, "signed_by: [a, b]", "signed_by: [b, a, other]", "`signed_by: [a, b]`");
    try expectEdit(a, r, "\"/rot/keys/$SIGNED_BY.gpg\"", "/rot/keys/a.gpg", "neither the run with a key of the matrix nor the control");
    try expectEdit(a, r, "--expect ok", "--expect refused", "neither the run with a key of the matrix nor the control");
    try expectEdit(a, r, "--expect refused", "--expect ok", "neither the run with a key of the matrix nor the control");
    try expectEdit(a, r, "/rot/keys/other.gpg", "/rot/keys/b.gpg", "neither the run with a key of the matrix nor the control");
    try expectEdit(a, r, "\"$IMAGE\" /rot/apt_rotation apt-check --repo /rot/repo --keyring \"/rot/keys", "debian:12 /rot/apt_rotation apt-check --repo /rot/repo --keyring \"/rot/keys", "neither the run with a key of the matrix nor the control");
    try expectEdit(a, r, "--volume \"$PWD/rot:/rot:ro\" \"$IMAGE\" /rot/apt_rotation apt-check --repo /rot/repo --keyring /rot/keys/other.gpg", "--volume \"$PWD/rot:/rot\" \"$IMAGE\" /rot/apt_rotation apt-check --repo /rot/repo --keyring /rot/keys/other.gpg", "neither the run with a key of the matrix nor the control");
    try expectEdit(a, r, "--package rotation-test --installed-file /usr/share/rotation-test/hello --work /var/tmp/aptrot --expect refused", "--package other --installed-file /usr/share/rotation-test/hello --work /var/tmp/aptrot --expect refused", "neither the run with a key of the matrix nor the control");
    try expectEdit(a, r, "      - name: apt refuses the repository", "      - run: docker run --rm debian:12 true\n      - name: apt refuses the repository", "3 docker commands");    try expectEdit(a, r, "          IMAGE: ${{ matrix.image }}\n        run: docker run --rm --volume \"$PWD/rot:/rot:ro\" \"$IMAGE\" /rot/apt_rotation apt-check --repo /rot/repo --keyring /rot/keys/other.gpg", "          IMAGE: debian:12\n        run: docker run --rm --volume \"$PWD/rot:/rot:ro\" \"$IMAGE\" /rot/apt_rotation apt-check --repo /rot/repo --keyring /rot/keys/other.gpg", "the image of both runs");
    try expectEdit(a, r, "          SIGNED_BY: ${{ matrix.signed_by }}\n", "          SIGNED_BY: a\n", "the key of the positive run");
    try expectEdit(a, r, "          SIGNED_BY: ${{ matrix.signed_by }}\n", "          SIGNED_BY: ${{ matrix.signed_by }}\n          OTHER: ${{ matrix.image }}\n", "read only through the two env entries");
}

test "a rule refuses a workflow and a program that disagree" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectSrcEdit(a, r, "\"--name\", \"rotation-test\"", "\"--name\", \"other\"", "apt_rotation.zig does not have");
    try expectSrcEdit(a, r, "usr/share/rotation-test/hello", "usr/share/other/hello", "apt_rotation.zig does not have");
    try expectSrcEdit(a, r, "\"a.gpg\"", "\"a.key\"", "apt_rotation.zig does not have");
    try expectSrcEdit(a, r, "\"other.gpg\"", "\"c.gpg\"", "apt_rotation.zig does not have");
    try expectSrcEdit(a, r, "std.mem.eql(u8, argv[1], \"apt-check\")", "std.mem.eql(u8, argv[1], \"check\")", "apt_rotation.zig does not have");
}

test "a rule refuses an inline expansion of event data" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectEdit(a, r, "      - run: chmod +x rot/apt_rotation\n", "      - run: echo ${{ github.event.pull_request.title }}\n      - run: chmod +x rot/apt_rotation\n", "expands `github.event.` inline");
}
