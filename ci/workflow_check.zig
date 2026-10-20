//! The public CI workflow (.github/workflows/ci.yml) is what docs/contract.md section 14 says it is. A pure function per rule, so each
//! rule is tested against planted text as well as against the real files (the zig_test's `data`, under BUILDRULES_TEST_WORK).
//!
//! What the rules catch:
//!  - an action referenced by a tag or branch (a moved tag changes what runs with the repository's token): every `uses:` is an
//!    owner/repo@<40 hex>;
//!  - a token with more than read access, or a trigger that runs fork code with secrets (`pull_request_target`);
//!  - a CI that stops building the target it promises (//ci:all), stops running the completeness check, builds in remote mode (the
//!    `./buck2 build` command itself must pass `-c buildrules_re.mode=local`; any other value of that key anywhere is refused), or names a
//!    remote-execution endpoint;
//!  - a buck2 install that drifted from the release pinned in tools/buck2 (url or sha256).
const std = @import("std");
const t = std.testing;

/// The one target the workflow builds: //ci:all covers the tree, and ci/completeness.bxl (run by the workflow) fails when it does not.
pub const targets = [_][]const u8{
    "//ci:all",
};

/// The workflow runs the completeness check before it builds.
const completeness = "./buck2 bxl //ci:completeness.bxl:check";

pub const Findings = std.ArrayList([]const u8);

fn add(a: std.mem.Allocator, f: *Findings, comptime fmt: []const u8, args: anytype) !void {
    try f.append(try std.fmt.allocPrint(a, fmt, args));
}

fn isHex40(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

/// The value of `"digest": "..."` and the first provider url inside the `linux-x86_64` block of a dotslash file.
fn dotslashLinux(text: []const u8) ?struct { digest: []const u8, url: []const u8 } {
    const at = std.mem.indexOf(u8, text, "\"linux-x86_64\"") orelse return null;
    const rest = text[at..];
    const end = std.mem.indexOf(u8, rest, "\"macos") orelse rest.len;
    const block = rest[0..end];
    const digest = between(block, "\"digest\": \"", "\"") orelse return null;
    const url = between(block, "{\"url\": \"", "\"") orelse return null;
    return .{ .digest = digest, .url = url };
}

fn between(s: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, s, open) orelse return null;
    const from = i + open.len;
    const j = std.mem.indexOfPos(u8, s, from, close) orelse return null;
    return s[from..j];
}

fn hasLine(text: []const u8, exact: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trimRight(u8, line, " \r"), exact)) return true;
    }
    return false;
}

/// Whether a line of the workflow (not a comment) is the target `tg`, as a line of the build command: `//pkg:name \\` or `//pkg:name`.
fn hasTargetLine(text: []const u8, tg: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \r");
        if (std.mem.endsWith(u8, line, "\\")) line = std.mem.trimRight(u8, line[0 .. line.len - 1], " ");
        if (std.mem.eql(u8, line, tg)) return true;
    }
    return false;
}

/// The commands of the workflow's shell, one per logical line: a trailing `\` joins the next line, and a word that starts with `#` begins a
/// comment that runs to the end of its physical line (so the rest of that line is not part of any command).
fn commands(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var cur = std.ArrayList(u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \r");
        var comment = false;
        for (line, 0..) |c, i| {
            if (c == '#' and (i == 0 or line[i - 1] == ' ')) {
                line = std.mem.trimRight(u8, line[0..i], " ");
                comment = true;
                break;
            }
        }
        if (!comment and std.mem.endsWith(u8, line, "\\")) {
            try cur.appendSlice(std.mem.trimRight(u8, line[0 .. line.len - 1], " "));
            try cur.append(' ');
            continue;
        }
        try cur.appendSlice(line);
        if (cur.items.len > 0) try out.append(try cur.toOwnedSlice());
    }
    if (cur.items.len > 0) try out.append(try cur.toOwnedSlice());
    return out.toOwnedSlice();
}

const mode_key = "buildrules_re.mode";

/// Whether the `./buck2 build` command `cmd` has `-c buildrules_re.mode=local` as whole arguments.
fn buildInLocalMode(cmd: []const u8) bool {
    return hasArgs(cmd, "-c buildrules_re.mode=local");
}

/// Whether `args` occurs in `cmd` as whole space-separated words.
fn hasArgs(cmd: []const u8, args: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, cmd, from, args)) |i| : (from = i + 1) {
        const before_ok = i == 0 or cmd[i - 1] == ' ';
        const e = i + args.len;
        if (before_ok and (e == cmd.len or cmd[e] == ' ')) return true;
    }
    return false;
}

/// Everything wrong with `workflow`, given the dotslash file of the pinned buck2 and ci/BUCK.
pub fn check(a: std.mem.Allocator, workflow: []const u8, dotslash: []const u8, ci_buck: []const u8) !Findings {
    var f = Findings.init(a);

    // Every `uses:` is pinned to a full commit.
    var uses: usize = 0;
    var it = std.mem.splitScalar(u8, workflow, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " -");
        if (std.mem.startsWith(u8, line, "#")) continue;
        if (!std.mem.startsWith(u8, line, "uses:")) continue;
        uses += 1;
        var v = std.mem.trim(u8, line["uses:".len..], " ");
        if (std.mem.indexOfScalar(u8, v, '#')) |h| v = std.mem.trim(u8, v[0..h], " ");
        const at = std.mem.indexOfScalar(u8, v, '@');
        if (at == null or !isHex40(v[at.? + 1 ..])) try add(a, &f, "`uses: {s}` is not pinned to a full commit sha", .{v});
    }
    if (uses == 0) try add(a, &f, "no `uses:` line found (the checkout step is missing, or this parser is blind)", .{});

    // Permissions: contents: read at the top level, nothing broader anywhere.
    if (!hasLine(workflow, "permissions:") or !hasLine(workflow, "  contents: read")) try add(a, &f, "top-level `permissions:` with `contents: read` is missing", .{});
    if (std.mem.indexOf(u8, workflow, ": write") != null) try add(a, &f, "a `: write` permission is granted", .{});
    if (std.mem.indexOf(u8, workflow, "write-all") != null) try add(a, &f, "`write-all` is granted", .{});
    if (std.mem.indexOf(u8, workflow, "pull_request_target") != null) try add(a, &f, "`pull_request_target` runs fork code with the base repository's token", .{});
    if (std.mem.indexOf(u8, workflow, "secrets.") != null) try add(a, &f, "the workflow reads a secret", .{});

    // Triggers and runner.
    if (!hasLine(workflow, "  pull_request:")) try add(a, &f, "`on: pull_request` is missing", .{});
    if (!hasLine(workflow, "  push:") or !hasLine(workflow, "    branches: [main]")) try add(a, &f, "`on: push: branches: [main]` is missing", .{});
    if (std.mem.indexOf(u8, workflow, "runs-on: ubuntu-latest") == null) try add(a, &f, "`runs-on: ubuntu-latest` is missing", .{});

    // Local mode, never a remote-execution endpoint, every promised target.
    // The flag is on the `./buck2 build` command itself (not on an echo, a comment or another command), every such command has it, and no
    // other value of the key appears anywhere (comments included), nor the key outside a build command.
    var builds: usize = 0;
    var mode_uses: usize = 0;
    var mode_on_builds: usize = 0;
    for (try commands(a, workflow)) |cmd| {
        const is_build = std.mem.indexOf(u8, cmd, "./buck2 build ") != null;
        const here = std.mem.count(u8, cmd, mode_key);
        mode_uses += here;
        if (is_build) {
            builds += 1;
            mode_on_builds += here;
            if (!buildInLocalMode(cmd)) try add(a, &f, "a `./buck2 build` command does not pass `-c buildrules_re.mode=local`: {s}", .{cmd});
        }
    }
    if (builds == 0) try add(a, &f, "no `./buck2 build` command found (the build does not pass `-c buildrules_re.mode=local`; or this parser is blind)", .{});
    if (mode_uses != mode_on_builds) try add(a, &f, "`{s}` appears outside a `./buck2 build` command", .{mode_key});
    var mit = std.mem.splitScalar(u8, workflow, '\n');
    while (mit.next()) |line| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, line, from, mode_key)) |i| : (from = i + mode_key.len) {
            const rest = line[i + mode_key.len ..];
            const ok = std.mem.startsWith(u8, rest, "=local") and (rest.len == "=local".len or rest["=local".len] == ' ' or rest["=local".len] == '`' or rest["=local".len] == ',' or rest["=local".len] == ')' or rest["=local".len] == '.');
            if (!ok) try add(a, &f, "`{s}` is set to something other than `local`: {s}", .{ mode_key, std.mem.trim(u8, line, " ") });
        }
    }
    for ([_][]const u8{ "engine_address", "cas_address", "action_cache_address", "linux_x86_64_properties", "--no-remote-cache" }) |bad| {
        if (std.mem.indexOf(u8, workflow, bad) != null) try add(a, &f, "the workflow mentions `{s}`", .{bad});
    }
    for (targets) |tg| {
        if (!hasTargetLine(workflow, tg)) try add(a, &f, "target {s} is not built", .{tg});
    }
    var ran_completeness = false;
    for (try commands(a, workflow)) |cmd| {
        if (std.mem.indexOf(u8, cmd, completeness) != null) ran_completeness = true;
    }
    if (!ran_completeness) try add(a, &f, "the workflow does not run `{s}`", .{completeness});
    // `//ci:` targets exist in ci/BUCK.
    for (targets) |tg| {
        if (!std.mem.startsWith(u8, tg, "//ci:")) continue;
        const want = try std.fmt.allocPrint(a, "name = \"{s}\"", .{tg["//ci:".len..]});
        if (std.mem.indexOf(u8, ci_buck, want) == null) try add(a, &f, "{s} is not declared in ci/BUCK", .{tg});
    }
    if (hasTargetLine(workflow, "//ci:mojo")) try add(a, &f, "//ci:mojo is built, and it needs a mirror a public runner does not have", .{});
    if (std.mem.indexOf(u8, workflow, "# //ci:mojo is not built") == null) try add(a, &f, "the comment that says why //ci:mojo is not built is missing", .{});

    // The buck2 install is the release pinned in tools/buck2.
    if (dotslashLinux(dotslash)) |p| {
        if (std.mem.indexOf(u8, workflow, p.url) == null) try add(a, &f, "the workflow does not download the url pinned in tools/buck2", .{});
        const line = try std.fmt.allocPrint(a, "{s}  buck2.zst", .{p.digest});
        if (std.mem.indexOf(u8, workflow, line) == null) try add(a, &f, "the workflow does not check the sha256 pinned in tools/buck2", .{});
    } else try add(a, &f, "tools/buck2 has no linux-x86_64 digest and url (this parser is blind)", .{});

    // The cache is keyed on lock files.
    const key = std.mem.indexOf(u8, workflow, "key: buck-out-");
    if (key == null or std.mem.indexOf(u8, workflow, "hashFiles(") == null or std.mem.indexOf(u8, workflow, "package-lock.json") == null or std.mem.indexOf(u8, workflow, "Cargo.lock") == null)
        try add(a, &f, "the cache key is not derived from the lock files", .{});
    return f;
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

const Real = struct { wf: []const u8, ds: []const u8, cb: []const u8 };

fn real(a: std.mem.Allocator) !Real {
    return .{ .wf = try work(a, ".github/workflows/ci.yml"), .ds = try work(a, "tools/buck2"), .cb = try work(a, "ci/BUCK") };
}

/// `wf` with the first `from` replaced by `to`; fails the test if `from` is absent (a mutant that changes nothing proves nothing).
fn mutate(a: std.mem.Allocator, wf: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const i = std.mem.indexOf(u8, wf, from) orelse return error.MutantDidNotApply;
    return std.mem.concat(a, u8, &.{ wf[0..i], to, wf[i + from.len ..] });
}

/// As `mutate`, at the last occurrence (the code, where a comment above also names the text).
fn mutateLast(a: std.mem.Allocator, wf: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const i = std.mem.lastIndexOf(u8, wf, from) orelse return error.MutantDidNotApply;
    return std.mem.concat(a, u8, &.{ wf[0..i], to, wf[i + from.len ..] });
}

fn expectFinding(a: std.mem.Allocator, r: Real, wf: []const u8, needle: []const u8) !void {
    const f = try check(a, wf, r.ds, r.cb);
    for (f.items) |m| {
        if (std.mem.indexOf(u8, m, needle) != null) return;
    }
    std.debug.print("expected a finding with `{s}`, got {d}:\n", .{ needle, f.items.len });
    for (f.items) |m| std.debug.print("  {s}\n", .{m});
    return error.MutantSurvived;
}

test "the real workflow has no findings" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const f = try check(a, r.wf, r.ds, r.cb);
    for (f.items) |m| std.debug.print("finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "an action pinned by tag, by branch or by a short sha is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const sha = "3d3c42e5aac5ba805825da76410c181273ba90b1";
    try expectFinding(a, r, try mutate(a, r.wf, "actions/checkout@" ++ sha, "actions/checkout@v7"), "not pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "actions/checkout@" ++ sha, "actions/checkout@main"), "not pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "actions/checkout@" ++ sha, "actions/checkout@3d3c42e"), "not pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "actions/checkout@" ++ sha, "actions/checkout"), "not pinned");
    // a 40-character value that is not hex
    try expectFinding(a, r, try mutate(a, r.wf, "actions/checkout@" ++ sha, "actions/checkout@" ++ "z" ** 40), "not pinned");
}

test "a workflow with no uses lines is found, not passed" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectFinding(a, r, "name: x\n", "no `uses:`");
}

test "a broader token, a fork-code trigger or a secret is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectFinding(a, r, try mutate(a, r.wf, "  contents: read", "  contents: write"), "permissions");
    try expectFinding(a, r, try mutate(a, r.wf, "  contents: read", "  contents: read\n  packages: write"), "write");
    try expectFinding(a, r, try mutate(a, r.wf, "permissions:\n  contents: read\n", ""), "permissions");
    try expectFinding(a, r, try mutate(a, r.wf, "  pull_request:", "  pull_request_target:"), "pull_request_target");
    try expectFinding(a, r, try mutate(a, r.wf, "persist-credentials: false", "token: ${{ secrets.X }}"), "secret");
}

test "a missing trigger or runner is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectFinding(a, r, try mutate(a, r.wf, "  pull_request:\n", ""), "pull_request");
    try expectFinding(a, r, try mutate(a, r.wf, "branches: [main]", "branches: [dev]"), "push");
    try expectFinding(a, r, try mutate(a, r.wf, "runs-on: ubuntu-latest", "runs-on: self-hosted"), "ubuntu-latest");
}

test "a build in remote mode, an endpoint, or a dropped target is found (also when only a comment names it)" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectFinding(a, r, try mutateLast(a, r.wf, "-c buildrules_re.mode=local", "-c buildrules_re.mode=remote"), "mode=local");
    try expectFinding(a, r, try mutate(a, r.wf, "--console simple", "--console simple -c buck2_re_client.engine_address=x"), "engine_address");
    try expectFinding(a, r, try mutate(a, r.wf, "--console simple", "--console simple --no-remote-cache"), "--no-remote-cache");
    // each target, dropped on its own, is named: the line holding it is rewritten to another target's name
    for (targets) |tg| {
        const wf = try std.mem.replaceOwned(u8, a, r.wf, tg, "//elsewhere:x");
        try expectFinding(a, r, wf, tg);
    }
}

test "the mode flag must be on the build command, and no other mode may appear" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const flag = " -c buildrules_re.mode=local \\\n";
    // the flag moves from the build command to an echo line: the old substring check passed this
    const moved = try mutateLast(a, r.wf, "./buck2 build --console simple" ++ flag, "echo -c buildrules_re.mode=local\n          ./buck2 build --console simple \\\n");
    try expectFinding(a, r, moved, "does not pass `-c buildrules_re.mode=local`");
    try expectFinding(a, r, moved, "appears outside a `./buck2 build` command");
    // a later build in remote mode, after the local one: the old check passed this too
    const later = try std.mem.concat(a, u8, &.{ r.wf, "      - run: ./buck2 build -c buildrules_re.mode=remote //x:y\n" });
    try expectFinding(a, r, later, "something other than `local`");
    try expectFinding(a, r, later, "does not pass `-c buildrules_re.mode=local`");
    // the other value on its own line, in the same command, or in a comment
    try expectFinding(a, r, try mutateLast(a, r.wf, " -c buildrules_re.mode=local \\\n", " -c buildrules_re.mode=local -c buildrules_re.mode=remote \\\n"), "something other than `local`");
    try expectFinding(a, r, try std.mem.concat(a, u8, &.{ r.wf, "# -c buildrules_re.mode=remote\n" }), "something other than `local`");
    try expectFinding(a, r, try mutateLast(a, r.wf, "buildrules_re.mode=local \\\n", "buildrules_re.mode=localx \\\n"), "does not pass");
    // the flag dropped altogether; and a workflow with no build command
    try expectFinding(a, r, try mutateLast(a, r.wf, flag, " \\\n"), "does not pass");
    try expectFinding(a, r, "name: x\nuses: a/b@" ++ "0" ** 40 ++ "\n", "no `./buck2 build` command");
    // the flag in a comment above the build does not count
    try expectFinding(a, r, try mutateLast(a, r.wf, flag, " \\\n          # -c buildrules_re.mode=local\n"), "does not pass");
}

test "the completeness check must run" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectFinding(a, r, try mutate(a, r.wf, "run: ./buck2 bxl //ci:completeness.bxl:check", "run: echo ./buck2 bxl //ci:completeness.bxl:chec"), "completeness");
}

test "a target named only in a comment is not built" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    // a comment names //ci:all; the build line is removed
    try t.expect(std.mem.indexOf(u8, r.wf, "//ci:all") != null);
    try expectFinding(a, r, try mutate(a, r.wf, "            //ci:all\n", "            #//ci:all\n"), "//ci:all is not built");
}

test "mojo may only appear with its reason" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectFinding(a, r, try mutate(a, r.wf, "            //ci:all\n", "            //ci:all \\\n            //ci:mojo\n"), "//ci:mojo is built");
    try expectFinding(a, r, try mutate(a, r.wf, "# //ci:mojo is not built", "# //ci:mojo is built"), "comment that says why");
}

test "a buck2 install that drifted from tools/buck2 is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectFinding(a, r, try mutate(a, r.wf, "2026-09-15/buck2-x86_64", "2026-09-16/buck2-x86_64"), "url pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "1268fce33fb6", "0268fce33fb6"), "sha256 pinned");
    // the pin moves and the workflow does not
    try expectFinding(a, .{ .wf = r.wf, .ds = try mutate(a, r.ds, "1268fce33fb6", "9999fce33fb6"), .cb = r.cb }, r.wf, "sha256 pinned");
    try expectFinding(a, .{ .wf = r.wf, .ds = "{}", .cb = r.cb }, r.wf, "blind");
}

test "a cache key that does not follow the lock files is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectFinding(a, r, try mutate(a, r.wf, "key: buck-out-${{ runner.os }}-${{ hashFiles(", "key: buck-out-${{ runner.os }}-${{ github.sha }}${{ x("), "lock files");
}

test "a //ci: target missing from ci/BUCK is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    try expectFinding(a, .{ .wf = r.wf, .ds = r.ds, .cb = "name = \"matrix\"\n" }, r.wf, "//ci:all is not declared");
}
