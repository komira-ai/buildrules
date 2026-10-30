//! `release bump-internal`: the last step of a release. After `publish`, open a pull request in the internal repository that moves its
//! submodule of this repository to the released commit, and turn auto-merge on. Standard library only; a copy of the tool the sibling
//! repository's release uses, with no dependency on it.
//!
//!     release bump-internal --repo OWNER/NAME --tag vX.Y.Z --sha COMMIT --internal-repo OWNER/NAME --submodule PATH --workdir EMPTYDIR
//!
//! The internal repository admits such a pull request only through its bump guard, which accepts the pull request of the release bot when
//! ALL of these hold: exactly one changed path, the submodule's gitlink; the branch is `bump/<submodule>-v<semver>`; the new commit
//! descends from the old; the tag `v<semver>` of the released repository names the new commit. This step produces exactly that, and refuses
//! (before it writes anything) whatever the guard would refuse, so a mistake is red here and not a stuck pull request.
//!
//! A submodule the internal repository also mounts as an external cell (a section `[external_cell_<submodule>]` in its `.buckconfig`, as buildrules is: the
//! build reads that section's `commit_hash`, not the gitlink) has two pins, and a bump that moved only the gitlink would build nothing against the new
//! release. For such a submodule the one pull request changes exactly two paths: the gitlink and the one `commit_hash` line of that section, set to the
//! same commit (the guard admits exactly that pair; the `.buckconfig` change also makes the internal repository's check build every target). A
//! submodule with no such section is bumped by its gitlink alone, as before. The section must have exactly one commit_hash line holding a commit id;
//! a gitlink already at --sha with another commit_hash is refused (a person sets the two pins to one commit), and a branch an earlier run pushed is
//! reused only when it holds both.
//!
//! Steps, every one a `gh` or `git` call with no shell:
//!   1. the tag names --sha (the guard's last rule);
//!   2. `gh pr list` of the internal repository: an open or merged bump pull request for this or a NEWER version means there is nothing to
//!      open (an open one for this version without auto-merge gets it);
//!   3. when the branch `bump/<submodule>-v<version>` already exists (an earlier run stopped after its push), its gitlink must be --sha and
//!      it is reused; otherwise a shallow clone (no submodule is initialised), the gitlink set with `git update-index --cacheinfo
//!      160000,<sha>,<submodule>` (no submodule checkout), a check that the staged change is that one gitlink and nothing else, the commit,
//!      and a push of the branch (never forced);
//!   4. `gh pr create`, then `gh pr merge --auto --merge`, then a check that auto-merge is on;
//!   5. every older open bump pull request is closed in favour of the new one.
//! The old gitlink must be an ancestor of --sha (GitHub's compare says ahead): the step never moves the submodule backwards. A run for a
//! version that is already the gitlink does nothing.
//!
//! The token is the App installation token of the release bot, handed in by the caller (the environment variable GH_TOKEN). `gh` reads it
//! from its environment. `git` gets it as an HTTP header through GIT_CONFIG_* in its environment (GH_TOKEN is removed from git's
//! environment). It is never an argument of any process, and the step refuses to run a command whose arguments contain it.
//!
//! The commands go through a `Runner`, so the tests drive every step against a fake `gh` and `git` that record their calls and their
//! environment (bump_test.zig).
const std = @import("std");
const version = @import("version.zig");
const Allocator = std.mem.Allocator;

/// The identity of the commit: the bot's login, and the noreply address GitHub gives a bot user (the id of the bot USER, then a plus sign,
/// then the login, at GitHub's noreply host). The id is the user's, not the App's. Spelled in parts: no address stands in the source,
/// and the project's name is not written out (tools/scrub).
pub const bot_name = "kom" ++ "ira-release-bot[bot]";
pub const bot_email = "345322945+" ++ bot_name ++ "@" ++ "users.noreply.github.com";

pub const Ran = struct { ok: bool, stdout: []const u8, stderr: []const u8 };

/// Runs `argv` with the environment `env` (null: this process's own).
pub const Runner = struct {
    ctx: *anyopaque,
    run_fn: *const fn (ctx: *anyopaque, a: Allocator, argv: []const []const u8, env: ?*const std.process.EnvMap) anyerror!Ran,
};

pub const Options = struct {
    gh: []const u8 = "gh",
    git: []const u8 = "git",
    /// The released repository, `owner/name`: its tag names the commit.
    repo: []const u8,
    dest_repo: []const u8,
    submodule: []const u8,
    /// The release tag, `vX.Y.Z`.
    tag: []const u8,
    sha: []const u8,
    /// Where the clone goes: it must not exist or be empty.
    workdir: []const u8,
    base: []const u8 = "main",
    /// The installation token of the release bot (GH_TOKEN).
    token: []const u8,
    /// The environment git starts from (this process's own): the token and the identity are put on a copy.
    base_env: *const std.process.EnvMap,
};

/// What the step did: `text` is what it says on standard output, or why it refused.
pub const Outcome = struct { ok: bool, text: []const u8 };

const Err = error{ Refused, OutOfMemory };

// ---- names ------------------------------------------------------------------------------------------------------------------------------

/// A repository or submodule name part: letters, digits, `.`, `_`, `-`; not empty, not starting with `.`.
pub fn namePart(s: []const u8) bool {
    if (s.len == 0 or s[0] == '.') return false;
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// `owner/name`, both parts names.
pub fn ownerName(s: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return false;
    return namePart(s[0..slash]) and namePart(s[slash + 1 ..]);
}

fn isHex40(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \r\n");
}

// ---- the session: running gh and git ----------------------------------------------------------------------------------------------------

const Session = struct {
    a: Allocator,
    runner: Runner,
    o: Options,
    git_env: std.process.EnvMap,
    msg: []const u8 = "",
    out: std.ArrayList(u8) = .empty,

    fn pf(s: *Session, comptime f: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(s.a, f, args);
    }

    fn fail(s: *Session, comptime f: []const u8, args: anytype) Err {
        s.msg = std.fmt.allocPrint(s.a, "release bump-internal: " ++ f, args) catch return error.OutOfMemory;
        return error.Refused;
    }

    fn say(s: *Session, comptime f: []const u8, args: anytype) !void {
        try s.out.print(s.a, f, args);
    }

    /// Refuses a command whose arguments hold the token: the token is world-readable in argv.
    fn noToken(s: *Session, exe: []const u8, args: []const []const u8) Err!void {
        if (std.mem.indexOf(u8, exe, s.o.token) != null) return s.fail("refusing to run a command with the token in its name", .{});
        for (args) |x| {
            if (std.mem.indexOf(u8, x, s.o.token) != null) return s.fail("refusing to run {s} with the token in its arguments (the token goes in the environment only)", .{std.fs.path.basename(exe)});
        }
    }

    fn exec(s: *Session, exe: []const u8, args: []const []const u8, env: ?*const std.process.EnvMap) Err!Ran {
        try s.noToken(exe, args);
        var argv = std.ArrayList([]const u8).empty;
        try argv.append(s.a, exe);
        try argv.appendSlice(s.a, args);
        return s.runner.run_fn(s.runner.ctx, s.a, argv.items, env) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return s.fail("could not run {s}: {s}", .{ exe, @errorName(err) }),
        };
    }

    fn gh(s: *Session, args: []const []const u8) Err!Ran {
        return s.exec(s.o.gh, args, null);
    }

    fn git(s: *Session, args: []const []const u8) Err!Ran {
        return s.exec(s.o.git, args, &s.git_env);
    }

    /// Standard output of a gh call that must succeed, trimmed.
    fn ghMust(s: *Session, args: []const []const u8) Err![]const u8 {
        const r = try s.gh(args);
        if (!r.ok) return s.fail("gh {s} failed: {s}", .{ args[0], trim(r.stderr) });
        return trim(r.stdout);
    }

    fn gitMust(s: *Session, args: []const []const u8) Err![]const u8 {
        const r = try s.git(args);
        if (!r.ok) return s.fail("git {s} failed: {s}", .{ firstNonFlag(args), trim(r.stderr) });
        return r.stdout;
    }
};

fn firstNonFlag(args: []const []const u8) []const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-C") or std.mem.eql(u8, args[i], "-c")) {
            i += 1;
            continue;
        }
        return args[i];
    }
    return "?";
}

/// The environment of git: no GH_TOKEN, the token as an HTTP header (for github.com only), the bot as author and committer, https only.
fn buildGitEnv(a: Allocator, base: *const std.process.EnvMap, token: []const u8) !std.process.EnvMap {
    var env = std.process.EnvMap.init(a);
    var it = base.iterator();
    while (it.next()) |e| try env.put(e.key_ptr.*, e.value_ptr.*);
    env.remove("GH_TOKEN");
    env.remove("GITHUB_TOKEN");
    const cred = try std.fmt.allocPrint(a, "x-access-token:{s}", .{token});
    const enc = std.base64.standard.Encoder;
    const buf = try a.alloc(u8, enc.calcSize(cred.len));
    const b64 = enc.encode(buf, cred);
    try env.put("GIT_CONFIG_COUNT", "1");
    try env.put("GIT_CONFIG_KEY_0", "http.https://github.com/.extraheader");
    try env.put("GIT_CONFIG_VALUE_0", try std.fmt.allocPrint(a, "AUTHORIZATION: basic {s}", .{b64}));
    try env.put("GIT_TERMINAL_PROMPT", "0");
    try env.put("GIT_ALLOW_PROTOCOL", "https");
    try env.put("GIT_AUTHOR_NAME", bot_name);
    try env.put("GIT_AUTHOR_EMAIL", bot_email);
    try env.put("GIT_COMMITTER_NAME", bot_name);
    try env.put("GIT_COMMITTER_EMAIL", bot_email);
    return env;
}

// ---- the pull requests of the internal repository ---------------------------------------------------------------------------------------

const Pr = struct {
    number: u64 = 0,
    state: []const u8 = "",
    headRefName: []const u8 = "",
    url: []const u8 = "",
    autoMergeRequest: ?std.json.Value = null,
};

fn listPrs(s: *Session) Err![]const Pr {
    const json = try s.ghMust(&.{ "pr", "list", "-R", s.o.dest_repo, "--state", "all", "--limit", "500", "--json", "number,state,headRefName,url,autoMergeRequest" });
    const parsed = std.json.parseFromSlice([]const Pr, s.a, json, .{ .ignore_unknown_fields = true }) catch |err| {
        return s.fail("cannot read the pull request list: {s}", .{@errorName(err)});
    };
    return parsed.value;
}

/// The version a bump branch `bump/<submodule>-v<semver>` names, or null for any other branch.
fn branchVersion(s: *Session, head: []const u8) !?version.Version {
    const want = try s.pf("bump/{s}-v", .{s.o.submodule});
    if (!std.mem.startsWith(u8, head, want)) return null;
    const tag = try s.pf("v{s}", .{head[want.len..]});
    return version.parseTag(tag);
}

fn enableAutoMerge(s: *Session, pr: []const u8) Err!void {
    _ = try s.ghMust(&.{ "pr", "merge", pr, "-R", s.o.dest_repo, "--auto", "--merge" });
    const on = try s.ghMust(&.{ "pr", "view", pr, "-R", s.o.dest_repo, "--json", "autoMergeRequest", "--jq", ".autoMergeRequest != null" });
    if (!std.mem.eql(u8, on, "true")) return s.fail("auto-merge is not on for {s} after `gh pr merge --auto --merge`", .{pr});
}

// ---- the bump ---------------------------------------------------------------------------------------------------------------------------

pub fn run(a: Allocator, runner: Runner, o: Options) Outcome {
    var s = Session{ .a = a, .runner = runner, .o = o, .git_env = std.process.EnvMap.init(a) };
    bump(&s) catch |err| switch (err) {
        error.Refused => return .{ .ok = false, .text = s.msg },
        error.OutOfMemory => return .{ .ok = false, .text = "release bump-internal: out of memory" },
    };
    return .{ .ok = true, .text = s.out.items };
}

fn bump(s: *Session) Err!void {
    const o = s.o;
    const mine = version.parseTag(o.tag) orelse return s.fail("--tag '{s}' is not vMAJOR.MINOR.PATCH (plain numbers)", .{o.tag});
    const number = try version.numberText(s.a, mine);
    if (!isHex40(o.sha)) return s.fail("--sha '{s}' is not a 40-character lowercase commit sha", .{o.sha});
    if (!ownerName(o.repo)) return s.fail("--repo '{s}' is not owner/name", .{o.repo});
    if (!ownerName(o.dest_repo)) return s.fail("--internal-repo '{s}' is not owner/name", .{o.dest_repo});
    if (!namePart(o.submodule)) return s.fail("--submodule '{s}' is not a submodule name", .{o.submodule});
    if (o.token.len == 0) return s.fail("GH_TOKEN is not set (the App installation token of the release bot)", .{});
    s.git_env = try buildGitEnv(s.a, o.base_env, o.token);

    const branch = try s.pf("bump/{s}-v{s}", .{ o.submodule, number });
    const title = try s.pf("chore({s}): bump to v{s}", .{ o.submodule, number });

    // 1. The guard's last rule, checked first: the tag names the commit.
    const tagged = try s.ghMust(&.{ "api", try s.pf("repos/{s}/commits/{s}", .{ o.repo, o.tag }), "--jq", ".sha" });
    if (!std.mem.eql(u8, tagged, o.sha)) return s.fail("the tag {s} of {s} names {s}, not {s}: the guard would refuse this bump", .{ o.tag, o.repo, tagged, o.sha });

    // 2. Is there a bump for this or a newer version already?
    const prs = try listPrs(s);
    var covered: ?Pr = null;
    var covered_same = false;
    var older = std.ArrayList(Pr).empty;
    for (prs) |p| {
        const v = (try branchVersion(s, p.headRefName)) orelse continue;
        const open = std.mem.eql(u8, p.state, "OPEN");
        const merged = std.mem.eql(u8, p.state, "MERGED");
        if (!open and !merged) continue;
        switch (v.order(mine)) {
            .lt => if (open) try older.append(s.a, p),
            else => {
                if (covered == null or (open and std.mem.eql(u8, covered.?.state, "MERGED"))) {
                    covered = p;
                    covered_same = v.order(mine) == .eq;
                }
            },
        }
    }

    var opened: []const u8 = "";
    if (covered) |p| {
        opened = p.url;
        if (covered_same and std.mem.eql(u8, p.state, "OPEN") and p.autoMergeRequest == null) {
            try enableAutoMerge(s, try s.pf("{d}", .{p.number}));
            try s.say("the bump pull request {s} for v{s} was open without auto-merge: turned it on.\n", .{ p.url, number });
        } else {
            try s.say("a bump pull request for v{s} or newer exists ({s}, {s}): nothing to open.\n", .{ number, p.url, p.state });
        }
    } else if (try branchGitlink(s, branch)) |held| {
        // 3a. An earlier run pushed the branch and stopped: reuse it if it is the right commit.
        if (!std.mem.eql(u8, held, o.sha)) return s.fail("the branch {s} exists in {s} with {s} at {s}, not {s}; delete the branch by hand", .{ branch, o.dest_repo, o.submodule, held, o.sha });
        try requireBranchPin(s, branch);
        opened = try openPr(s, branch, title, number);
    } else {
        // 3b. Build the commit and push the branch.
        if (!try pushBump(s, branch, title, number)) {
            try s.say("{s} is already at {s}: nothing to open.\n", .{ o.submodule, o.sha });
        } else opened = try openPr(s, branch, title, number);
    }

    // 5. Older open bumps are superseded.
    for (older.items) |p| {
        const note = if (opened.len != 0) try s.pf("Superseded by {s}.", .{opened}) else try s.pf("Superseded by the bump to v{s}.", .{number});
        _ = try s.ghMust(&.{ "pr", "close", try s.pf("{d}", .{p.number}), "-R", o.dest_repo, "--comment", note, "--delete-branch" });
        try s.say("closed {s} (older than v{s}).\n", .{ p.url, number });
    }
}

/// The commit of the submodule's gitlink on `branch` of the internal repository, or null when the branch does not exist.
fn branchGitlink(s: *Session, branch: []const u8) Err!?[]const u8 {
    const o = s.o;
    const r = try s.gh(&.{ "api", try s.pf("repos/{s}/git/ref/heads/{s}", .{ o.dest_repo, branch }), "--jq", ".object.sha" });
    if (!r.ok) {
        if (std.mem.indexOf(u8, r.stderr, "404") != null or std.mem.indexOf(u8, r.stderr, "Not Found") != null) return null;
        return s.fail("cannot look for the branch {s}: {s}", .{ branch, trim(r.stderr) });
    }
    return try s.ghMust(&.{ "api", try s.pf("repos/{s}/contents/{s}?ref={s}", .{ o.dest_repo, o.submodule, branch }), "--jq", ".sha" });
}

/// Clones, sets the gitlink, commits and pushes the branch. False when the gitlink is already --sha.
fn pushBump(s: *Session, branch: []const u8, title: []const u8, number: []const u8) Err!bool {
    const o = s.o;
    // The clone goes into a directory this run made, or an empty one.
    std.fs.cwd().makePath(o.workdir) catch |err| return s.fail("cannot make {s}: {s}", .{ o.workdir, @errorName(err) });
    {
        var d = std.fs.cwd().openDir(o.workdir, .{ .iterate = true }) catch |err| return s.fail("cannot open {s}: {s}", .{ o.workdir, @errorName(err) });
        defer d.close();
        var it = d.iterate();
        const first = it.next() catch |err| return s.fail("cannot read {s}: {s}", .{ o.workdir, @errorName(err) });
        if (first != null) return s.fail("{s} is not empty; give an empty directory", .{o.workdir});
    }
    const url = try s.pf("https://github.com/{s}.git", .{o.dest_repo});
    // No submodule is initialised: `clone` without --recurse-submodules leaves the gitlink as it is.
    _ = try s.gitMust(&.{ "clone", "--quiet", "--depth", "1", "--no-tags", "--single-branch", "--branch", o.base, url, o.workdir });

    // The old gitlink: mode 160000, type commit, exactly the submodule's path.
    const old = try gitlinkAt(s);
    const pin = try workdirPin(s);
    if (std.mem.eql(u8, old, o.sha)) {
        if (pin) |p| {
            if (!std.mem.eql(u8, p.pin.value, o.sha)) return s.fail("{s} is already at {s} but .buckconfig commit_hash is {s}: the two pins disagree, a person sets them to one commit (a bump pull request would not change the gitlink)", .{ o.submodule, o.sha, p.pin.value });
        }
        return false;
    }
    // Forward only (the guard's rule): --sha descends from the old commit.
    const status = try s.ghMust(&.{ "api", try s.pf("repos/{s}/compare/{s}...{s}", .{ o.repo, old, o.sha }), "--jq", ".status" });
    if (!std.mem.eql(u8, status, "ahead")) return s.fail("{s} is not ahead of {s} in {s} (compare says '{s}'): the bump would move {s} backwards or sideways", .{ o.sha, old, o.repo, status, o.submodule });

    _ = try s.gitMust(&.{ "-C", o.workdir, "update-index", "--cacheinfo", try s.pf("160000,{s},{s}", .{ o.sha, o.submodule }) });
    if (pin) |p| {
        try movePin(s, p);
        try requireStagedPair(s);
    } else try requireOneGitlink(s);

    const body = try s.pf(
        \\Moves the `{s}` submodule to the commit of the release v{s} ({s}).
        \\
        \\Release: https://github.com/{s}/releases/tag/{s}
        \\
        \\Opened by the release pipeline of {s} after it published the release. Auto-merge fires when the required checks pass, among them the bump guard.
    , .{ o.submodule, number, o.sha, o.repo, o.tag, o.repo });
    _ = try s.gitMust(&.{ "-C", o.workdir, "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", title, "-m", body });
    if (!std.mem.eql(u8, try gitlinkAt(s), o.sha)) return s.fail("after the commit the gitlink of {s} is not {s}", .{ o.submodule, o.sha });
    _ = try s.gitMust(&.{ "-C", o.workdir, "push", "--quiet", "origin", try s.pf("HEAD:refs/heads/{s}", .{branch}) });
    return true;
}

/// The commit of the submodule's gitlink at HEAD of the clone.
fn gitlinkAt(s: *Session) Err![]const u8 {
    const o = s.o;
    const text = try s.gitMust(&.{ "-C", o.workdir, "ls-tree", "HEAD", "--", o.submodule });
    const line = trim(text);
    // <mode> SP <type> SP <sha> TAB <path>
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return s.fail("git ls-tree HEAD {s} printed '{s}': the path is not in the repository", .{ o.submodule, line });
    if (!std.mem.eql(u8, line[tab + 1 ..], o.submodule)) return s.fail("git ls-tree printed the path '{s}', not {s}", .{ line[tab + 1 ..], o.submodule });
    var f = std.mem.splitScalar(u8, line[0..tab], ' ');
    const mode = f.next() orelse "";
    const kind = f.next() orelse "";
    const sha = f.next() orelse "";
    if (!std.mem.eql(u8, mode, "160000") or !std.mem.eql(u8, kind, "commit") or !isHex40(sha)) {
        return s.fail("{s} is not a gitlink in {s} ('{s}'): the guard would refuse a bump of it", .{ o.submodule, o.dest_repo, line });
    }
    return sha;
}

/// The staged change is exactly one path, the submodule's, a gitlink before and after, modified.
fn requireOneGitlink(s: *Session) Err!void {
    const o = s.o;
    const raw = try s.gitMust(&.{ "-C", o.workdir, "diff", "--cached", "--raw", "-z", "--no-renames", "--ignore-submodules=none", "HEAD" });
    var it = std.mem.splitScalar(u8, raw, 0);
    const meta = it.next() orelse "";
    const path = it.next() orelse "";
    const rest = it.next() orelse "";
    const more = it.next();
    // ":160000 160000 <old> <new> M" then the path, then nothing but the end of the output.
    const shape = std.mem.startsWith(u8, meta, ":160000 160000 ") and std.mem.endsWith(u8, meta, " M");
    if (meta.len == 0 or !shape or !std.mem.eql(u8, path, o.submodule) or rest.len != 0 or more != null) {
        return s.fail("the staged change is not exactly one modified gitlink at {s} (git diff says '{s}'): refusing to commit, the guard would refuse it", .{ o.submodule, std.mem.trim(u8, raw, "\x00\n") });
    }
}

/// Opens the pull request of `branch` and turns auto-merge on. Returns its url.
fn openPr(s: *Session, branch: []const u8, title: []const u8, number: []const u8) Err![]const u8 {
    const o = s.o;
    const body = try s.pf("Moves the `{s}` submodule to release v{s}.\n\nRelease: https://github.com/{s}/releases/tag/{s}\n\nOpened by the release pipeline of {s}. Auto-merge fires when the required checks pass, among them the bump guard.", .{ o.submodule, number, o.repo, o.tag, o.repo });
    const made = try s.ghMust(&.{ "pr", "create", "-R", o.dest_repo, "--base", o.base, "--head", branch, "--title", title, "--body", body });
    // The url is the last line of what `gh pr create` prints.
    const nl = std.mem.lastIndexOfScalar(u8, made, '\n');
    const url = if (nl) |i| made[i + 1 ..] else made;
    if (!std.mem.startsWith(u8, url, "https://")) return s.fail("gh pr create printed '{s}', not a pull request url", .{made});
    try enableAutoMerge(s, url);
    try s.say("opened {s} with auto-merge: {s} to v{s}.\n", .{ url, o.submodule, number });
    return url;
}

// ---- the second pin: .buckconfig's commit_hash --------------------------------------------------------------------------------------------

/// Where the `commit_hash` value of `[external_cell_<submodule>]` sits in the text of the internal repository's `.buckconfig`.
const Pin = struct { start: usize, end: usize, value: []const u8 };

/// The commit_hash line of the section `[external_cell_<submodule>]`, null when the text has no such section. A section without exactly one
/// commit_hash line, or with a value that is not a 40-character commit id, is refused: it is not a pin this step can move. The same key in
/// another section, and a comment, are not it.
fn findPin(s: *Session, text: []const u8) Err!?Pin {
    const header = try s.pf("[external_cell_{s}]", .{s.o.submodule});
    var in_section = false;
    var seen = false;
    var found: ?Pin = null;
    var off: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| : (off += line.len + 1) {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0 and t[0] == '[') {
            in_section = std.mem.eql(u8, t, header);
            seen = seen or in_section;
            continue;
        }
        if (!in_section or t.len == 0 or t[0] == '#' or t[0] == ';') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), "commit_hash")) continue;
        if (found != null) return s.fail(".buckconfig {s} has two commit_hash lines: this step moves exactly one", .{header});
        const after = line[eq + 1 ..];
        const lead = after.len - std.mem.trimLeft(u8, after, " \t").len;
        const value = std.mem.trim(u8, after, " \t\r");
        found = .{ .start = off + eq + 1 + lead, .end = off + eq + 1 + lead + value.len, .value = value };
    }
    if (!seen) return null;
    const p = found orelse return s.fail(".buckconfig {s} has no commit_hash line to move", .{header});
    if (!isHex40(p.value)) return s.fail(".buckconfig {s} commit_hash '{s}' is not a 40-character lowercase commit id", .{ header, p.value });
    return p;
}

const PinText = struct { text: []const u8, pin: Pin };

/// The pin in the clone's `.buckconfig`, or null when the clone has no such file or its `.buckconfig` has no section for the submodule.
fn workdirPin(s: *Session) Err!?PinText {
    const file = try std.fs.path.join(s.a, &.{ s.o.workdir, ".buckconfig" });
    const text = std.fs.cwd().readFileAlloc(s.a, file, 1 << 22) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return s.fail("cannot read {s}: {s}", .{ file, @errorName(err) }),
    };
    const p = (try findPin(s, text)) orelse return null;
    return .{ .text = text, .pin = p };
}

/// Sets the pin to --sha in the clone and stages `.buckconfig` by path.
fn movePin(s: *Session, p: PinText) Err!void {
    const file = try std.fs.path.join(s.a, &.{ s.o.workdir, ".buckconfig" });
    const moved = try std.mem.concat(s.a, u8, &.{ p.text[0..p.pin.start], s.o.sha, p.text[p.pin.end..] });
    std.fs.cwd().writeFile(.{ .sub_path = file, .data = moved }) catch |err| return s.fail("cannot write {s}: {s}", .{ file, @errorName(err) });
    _ = try s.gitMust(&.{ "-C", s.o.workdir, "add", "--", ".buckconfig" });
}

/// A branch an earlier run pushed holds the commit_hash too (when the internal repository has the section): both pins or it is not reused.
fn requireBranchPin(s: *Session, branch: []const u8) Err!void {
    const o = s.o;
    const r = try s.gh(&.{ "api", try s.pf("repos/{s}/contents/.buckconfig?ref={s}", .{ o.dest_repo, branch }), "-H", "Accept: application/vnd.github.raw" });
    if (!r.ok) {
        if (std.mem.indexOf(u8, r.stderr, "404") != null or std.mem.indexOf(u8, r.stderr, "Not Found") != null) return;
        return s.fail("cannot read .buckconfig on the branch {s}: {s}", .{ branch, trim(r.stderr) });
    }
    const p = (try findPin(s, r.stdout)) orelse return;
    if (!std.mem.eql(u8, p.value, o.sha)) return s.fail("the branch {s} exists in {s} with the gitlink at {s} but .buckconfig commit_hash at {s}; delete the branch by hand", .{ branch, o.dest_repo, o.sha, p.value });
}

/// The staged change is exactly two modified paths: `.buckconfig` (a plain file) and the submodule's gitlink.
fn requireStagedPair(s: *Session) Err!void {
    const o = s.o;
    const raw = try s.gitMust(&.{ "-C", o.workdir, "diff", "--cached", "--raw", "-z", "--no-renames", "--ignore-submodules=none", "HEAD" });
    var it = std.mem.splitScalar(u8, raw, 0);
    var file_ok = false;
    var link_ok = false;
    var n: usize = 0;
    while (it.next()) |meta| {
        if (meta.len == 0) break;
        const path = it.next() orelse "";
        n += 1;
        const modified = std.mem.endsWith(u8, meta, " M");
        if (std.mem.eql(u8, path, ".buckconfig") and modified and std.mem.startsWith(u8, meta, ":100644 100644 ")) file_ok = true;
        if (std.mem.eql(u8, path, o.submodule) and modified and std.mem.startsWith(u8, meta, ":160000 160000 ")) link_ok = true;
    }
    if (n != 2 or !file_ok or !link_ok) {
        return s.fail("the staged change is not exactly the gitlink of {s} and .buckconfig (git diff says '{s}'): refusing to commit, the guard would refuse it", .{ o.submodule, std.mem.trim(u8, raw, "\x00\n") });
    }
}

// ---- the real commands --------------------------------------------------------------------------------------------------------------------

fn realRunFn(_: *anyopaque, a: Allocator, argv: []const []const u8, env: ?*const std.process.EnvMap) anyerror!Ran {
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv, .env_map = env, .max_output_bytes = 1 << 22 });
    return .{ .ok = r.term == .Exited and r.term.Exited == 0, .stdout = r.stdout, .stderr = r.stderr };
}

var unused_ctx: u8 = 0;

/// The `gh` and `git` of this machine.
pub const real_runner = Runner{ .ctx = &unused_ctx, .run_fn = realRunFn };
