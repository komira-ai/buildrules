//! `release bump-internal` (bump.zig), the step that opens the pull request moving the internal repository's submodule to a release, against a fake `gh`
//! and a fake `git` whose state is in memory. Nothing here reaches GitHub, clones anything or opens a pull request.
//!
//! The internal repository admits such a pull request only through its bump guard: author the release bot, exactly one changed path (the submodule's
//! gitlink), branch bump/<submodule>-v<semver>, the new commit descends from the old, the tag v<semver> names the new commit. The good scenario checks
//! every one of those on the calls the step made, then each test injects one defect (a variant) and requires a refusal for that reason with no push and
//! no pull request, so a refusal is the defect's doing. The fakes log their arguments: the token must be in no argument, only in the environment.
const std = @import("std");
const bump = @import("bump.zig");
const t = std.testing;
const Allocator = std.mem.Allocator;

const sha = "0123456789abcdef0123456789abcdef01234567";
const old = "a" ** 40;
const other = "fedcba9876543210fedcba9876543210fedcba98";
const token = "ghs_SECRETINSTALLATIONTOKEN";
const released = "org/rules";
const internal = "org/internal-repo";
const submodule = "rules";
const tag = "v1.2.3";
const branch = "bump/rules-v1.2.3";
const pr_head = "https://github.com/org/internal-repo/pull/";
/// The identity of the commit, spelled here independently of bump.zig: a change of either is red.
const bot = "kom" ++ "ira-release-bot[bot]";
const bot_mail = "345322945+" ++ bot ++ "@users.noreply.github.com";

const PrRow = struct { number: u64, state: []const u8, head: []const u8, auto: bool };

/// A `gh` and a `git` in one: what GitHub and git would answer, and a record of every call.
const Fake = struct {
    a: Allocator,
    // what they answer
    tag_commit: ?[]const u8 = sha,
    ls_tree: []const u8 = "160000 commit " ++ old ++ "\t" ++ submodule ++ "\n",
    compare: []const u8 = "ahead",
    prs: std.ArrayList(PrRow) = .empty,
    /// An existing branch of the internal repository, and the commit its gitlink holds.
    existing_branch: ?[]const u8 = null,
    branch_gitlink: []const u8 = "",
    branch_lookup_error: bool = false,
    git_diff: ?[]const u8 = null,
    // what fails
    clone_fail: bool = false,
    commit_fail: bool = false,
    push_fail: bool = false,
    commit_wrong: bool = false,
    create_fail: bool = false,
    merge_fail: bool = false,
    close_fail: bool = false,
    auto_noop: bool = false,
    // what they were asked
    gh_log: std.ArrayList([]const u8) = .empty,
    git_log: std.ArrayList([]const u8) = .empty,
    git_env: std.ArrayList([]const u8) = .empty,
    pushed: std.ArrayList([]const u8) = .empty,
    gh_given_env: usize = 0,
    index_entry: ?[]const u8 = null,
    commit_msg: ?[]const u8 = null,
    committed: ?[]const u8 = null,
    /// The .buckconfig the clone leaves in the work directory (null: none), the one the pushed branch holds, and what `git add` was given.
    buckconfig: ?[]const u8 = null,
    branch_buckconfig: []const u8 = "",
    added: std.ArrayList([]const u8) = .empty,

    fn runner(f: *Fake) bump.Runner {
        return .{ .ctx = f, .run_fn = runFn };
    }

    fn runFn(ctx: *anyopaque, a: Allocator, argv: []const []const u8, env: ?*const std.process.EnvMap) anyerror!bump.Ran {
        _ = a;
        const f: *Fake = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, argv[0], "gh")) {
            if (env != null) f.gh_given_env += 1;
            return f.ghCall(argv[1..]);
        }
        if (std.mem.eql(u8, argv[0], "git")) return f.gitCall(argv[1..], env.?);
        return error.UnexpectedExecutable;
    }

    fn good(out: []const u8) bump.Ran {
        return .{ .ok = true, .stdout = out, .stderr = "" };
    }

    fn bad(msg: []const u8) bump.Ran {
        return .{ .ok = false, .stdout = "", .stderr = msg };
    }

    fn pf(f: *Fake, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(f.a, fmt, args);
    }

    fn prsText(f: *Fake) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        for (f.prs.items) |p| try buf.print(f.a, "{d} {s} {s} {d}\n", .{ p.number, p.state, p.head, @intFromBool(p.auto) });
        return buf.items;
    }

    fn ghCall(f: *Fake, args: []const []const u8) !bump.Ran {
        try f.gh_log.append(f.a, try std.mem.join(f.a, " ", args));
        if (std.mem.eql(u8, args[0], "api")) {
            const path = args[1];
            if (std.mem.startsWith(u8, path, "repos/" ++ released ++ "/commits/")) {
                const name = path[("repos/" ++ released ++ "/commits/").len..];
                if (std.mem.eql(u8, name, tag)) {
                    if (f.tag_commit) |c| return good(try f.pf("{s}\n", .{c}));
                }
                return bad("Not Found (HTTP 404)");
            }
            if (std.mem.startsWith(u8, path, "repos/" ++ released ++ "/compare/")) return good(try f.pf("{s}\n", .{f.compare}));
            if (std.mem.startsWith(u8, path, "repos/" ++ internal ++ "/git/ref/heads/")) {
                if (f.branch_lookup_error) return bad("Server Error (HTTP 500)");
                const name = path[("repos/" ++ internal ++ "/git/ref/heads/").len..];
                if (f.existing_branch) |b| {
                    if (std.mem.eql(u8, b, name)) return good("2222222222222222222222222222222222222222\n");
                }
                return bad("Not Found (HTTP 404)");
            }
            if (std.mem.startsWith(u8, path, "repos/" ++ internal ++ "/contents/.buckconfig")) return good(try f.pf("{s}\n", .{f.branch_buckconfig}));
            if (std.mem.startsWith(u8, path, "repos/" ++ internal ++ "/contents/")) return good(try f.pf("{s}\n", .{f.branch_gitlink}));
            return error.UnexpectedApiCall;
        }
        if (std.mem.eql(u8, args[0], "pr")) return f.prCall(args);
        return error.UnexpectedGhCall;
    }

    fn prCall(f: *Fake, args: []const []const u8) !bump.Ran {
        const verb = args[1];
        if (std.mem.eql(u8, verb, "list")) {
            var buf = std.ArrayList(u8).empty;
            try buf.append(f.a, '[');
            for (f.prs.items, 0..) |p, i| {
                const am: []const u8 = if (p.auto) "{\"mergeMethod\":\"MERGE\"}" else "null";
                try buf.print(f.a, "{s}{{\"number\":{d},\"state\":\"{s}\",\"headRefName\":\"{s}\",\"url\":\"{s}{d}\",\"autoMergeRequest\":{s}}}", .{ if (i == 0) "" else ",", p.number, p.state, p.head, pr_head, p.number, am });
            }
            try buf.appendSlice(f.a, "]\n");
            return good(buf.items);
        }
        if (std.mem.eql(u8, verb, "create")) {
            if (f.create_fail) return bad("pull request create failed");
            const n: u64 = 100 + f.prs.items.len;
            var head: []const u8 = "";
            for (args, 0..) |x, i| {
                if (std.mem.eql(u8, x, "--head")) head = args[i + 1];
            }
            try f.prs.append(f.a, .{ .number = n, .state = "OPEN", .head = head, .auto = false });
            return good(try f.pf("{s}{d}\n", .{ pr_head, n }));
        }
        // merge, view and close name the pull request by number or url.
        const ref = args[2];
        const num_text = ref[if (std.mem.lastIndexOfScalar(u8, ref, '/')) |s| s + 1 else 0..];
        for (f.prs.items) |*p| {
            if (!std.mem.eql(u8, try f.pf("{d}", .{p.number}), num_text)) continue;
            if (std.mem.eql(u8, verb, "merge")) {
                if (f.merge_fail) return bad("auto-merge cannot be enabled (GraphQL)");
                var auto = false;
                var merge = false;
                for (args) |x| {
                    if (std.mem.eql(u8, x, "--auto")) auto = true;
                    if (std.mem.eql(u8, x, "--merge")) merge = true;
                }
                if (!auto or !merge) return bad("this fake wants gh pr merge --auto --merge");
                if (!f.auto_noop) p.auto = true;
                return good("");
            }
            if (std.mem.eql(u8, verb, "close")) {
                if (f.close_fail) return bad("cannot close");
                p.state = "CLOSED";
                return good("");
            }
            if (std.mem.eql(u8, verb, "view")) return good(if (p.auto) "true\n" else "false\n");
            return error.UnexpectedPrVerb;
        }
        return bad("no pull request found");
    }

    fn envOr(env: *const std.process.EnvMap, name: []const u8) []const u8 {
        return env.get(name) orelse "(unset)";
    }

    fn gitCall(f: *Fake, argv: []const []const u8, env: *const std.process.EnvMap) !bump.Ran {
        try f.git_log.append(f.a, try std.mem.join(f.a, " ", argv));
        // Skip `-C <dir>` and `-c <k=v>`.
        var i: usize = 0;
        while (i + 1 < argv.len and (std.mem.eql(u8, argv[i], "-C") or std.mem.eql(u8, argv[i], "-c"))) i += 2;
        const verb = argv[i];
        const args = argv[i + 1 ..];
        try f.git_env.append(f.a, try f.pf("{s} GH_TOKEN={s} GITHUB_TOKEN={s} HEADER={s} AUTHOR={s} <{s}> COMMITTER={s} <{s}> PROTOCOL={s}", .{
            verb,
            envOr(env, "GH_TOKEN"),
            envOr(env, "GITHUB_TOKEN"),
            envOr(env, "GIT_CONFIG_VALUE_0"),
            envOr(env, "GIT_AUTHOR_NAME"),
            envOr(env, "GIT_AUTHOR_EMAIL"),
            envOr(env, "GIT_COMMITTER_NAME"),
            envOr(env, "GIT_COMMITTER_EMAIL"),
            envOr(env, "GIT_ALLOW_PROTOCOL"),
        }));
        if (std.mem.eql(u8, verb, "clone")) {
            if (f.clone_fail) return bad("could not read from the remote repository");
            if (f.buckconfig) |text| {
                const file = try std.fs.path.join(f.a, &.{ argv[argv.len - 1], ".buckconfig" });
                try std.fs.cwd().writeFile(.{ .sub_path = file, .data = text });
            }
            return good("");
        }
        if (std.mem.eql(u8, verb, "ls-tree")) return good(f.committed orelse f.ls_tree);
        if (std.mem.eql(u8, verb, "add")) {
            try f.added.append(f.a, try std.mem.join(f.a, " ", args));
            return good("");
        }
        if (std.mem.eql(u8, verb, "update-index")) {
            f.index_entry = args[1];
            return good("");
        }
        if (std.mem.eql(u8, verb, "diff")) {
            if (f.git_diff) |d| return good(d);
            if (f.index_entry) |e| {
                const path = e[std.mem.lastIndexOfScalar(u8, e, ',').? + 1 ..];
                const zeros = "0" ** 40;
                return good(try f.pf("{s}:160000 160000 {s} {s} M\x00{s}\x00", .{ if (f.added.items.len > 0) ":100644 100644 x y M\x00.buckconfig\x00" else "", zeros, zeros, path }));
            }
            return good("");
        }
        if (std.mem.eql(u8, verb, "commit")) {
            if (f.commit_fail) return bad("commit failed");
            var msgs = std.ArrayList(u8).empty;
            for (args, 0..) |x, k| {
                if (std.mem.eql(u8, x, "-m")) {
                    if (msgs.items.len != 0) try msgs.appendSlice(f.a, "\n---\n");
                    try msgs.appendSlice(f.a, args[k + 1]);
                }
            }
            f.commit_msg = msgs.items;
            const e = f.index_entry orelse return bad("nothing staged");
            var parts = std.mem.splitScalar(u8, e, ',');
            _ = parts.next();
            const staged = parts.next().?;
            const path = parts.next().?;
            const held: []const u8 = if (f.commit_wrong) "f" ** 40 else staged;
            f.committed = try f.pf("160000 commit {s}\t{s}\n", .{ held, path });
            return good("");
        }
        if (std.mem.eql(u8, verb, "push")) {
            if (f.push_fail) return bad("remote rejected");
            try f.pushed.append(f.a, args[args.len - 1]);
            return good("");
        }
        return error.UnexpectedGitCall;
    }

    // ---- what a test asks of the record ----

    fn countPrefix(list: []const []const u8, prefix: []const u8) usize {
        var n: usize = 0;
        for (list) |l| {
            if (std.mem.startsWith(u8, l, prefix)) n += 1;
        }
        return n;
    }

    fn countHas(list: []const []const u8, needle: []const u8) usize {
        var n: usize = 0;
        for (list) |l| {
            if (std.mem.indexOf(u8, l, needle) != null) n += 1;
        }
        return n;
    }

    fn created(f: *const Fake) usize {
        return countPrefix(f.gh_log.items, "pr create ");
    }

    /// Nothing was pushed, opened, enabled or closed.
    fn untouched(f: *const Fake) bool {
        return f.pushed.items.len == 0 and f.created() == 0 and countPrefix(f.gh_log.items, "pr close ") == 0 and countPrefix(f.gh_log.items, "pr merge ") == 0;
    }

    fn clones(f: *const Fake) usize {
        return countPrefix(f.git_log.items, "clone ");
    }
};

fn check(ok: bool, name: []const u8) !void {
    if (!ok) {
        std.debug.print("CHECK FAILED: {s}\n", .{name});
        return error.CheckFailed;
    }
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn b64(a: Allocator, s: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const buf = try a.alloc(u8, enc.calcSize(s.len));
    return enc.encode(buf, s);
}

/// A scenario: the tag v1.2.3 names `sha`; the internal repository holds `old` as its gitlink, which `sha` is ahead of; no pull request, no branch.
const World = struct {
    a: Allocator,
    tmp: t.TmpDir,
    fake: Fake,
    env: std.process.EnvMap,
    o: bump.Options,

    fn init(a: Allocator) !*World {
        const w = try a.create(World);
        w.* = .{ .a = a, .tmp = t.tmpDir(.{}), .fake = .{ .a = a }, .env = std.process.EnvMap.init(a), .o = undefined };
        try w.env.put("GH_TOKEN", token);
        try w.env.put("GITHUB_TOKEN", "an-ambient-github-token");
        try w.env.put("HOME", "/nowhere");
        const base = try w.tmp.dir.realpathAlloc(a, ".");
        w.o = .{
            .repo = released,
            .dest_repo = internal,
            .submodule = submodule,
            .tag = tag,
            .sha = sha,
            .workdir = try std.fs.path.join(a, &.{ base, "wd" }),
            .token = token,
            .base_env = &w.env,
        };
        return w;
    }

    fn deinit(w: *World) void {
        w.tmp.cleanup();
    }

    fn go(w: *World) bump.Outcome {
        return bump.run(w.a, w.fake.runner(), w.o);
    }

    fn prs(w: *World) ![]const u8 {
        return w.fake.prsText();
    }

    fn row(w: *World, number: u64, state: []const u8, head: []const u8, auto: bool) !void {
        try w.fake.prs.append(w.a, .{ .number = number, .state = state, .head = head, .auto = auto });
    }
};

fn arenaOf() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

test "bump-internal: the pull request the bump guard admits, on the calls the step made" {
    var arena = arenaOf();
    defer arena.deinit();
    const a = arena.allocator();
    const w = try World.init(a);
    defer w.deinit();
    const f = &w.fake;

    const r = w.go();
    try check(r.ok and has(r.text, "opened " ++ pr_head ++ "100 with auto-merge"), "good: ok, and says it opened the pull request");
    try check(f.pushed.items.len == 1 and std.mem.eql(u8, f.pushed.items[0], "HEAD:refs/heads/" ++ branch), "good: the branch is bump/<submodule>-v1.2.3, pushed once");
    try check(Fake.countHas(f.git_log.items, "--force") == 0 and Fake.countHas(f.git_log.items, " -f ") == 0 and Fake.countHas(f.git_log.items, "+HEAD") == 0, "good: the push is a plain refspec (no force, no +)");
    try check(std.mem.eql(u8, f.index_entry.?, "160000," ++ sha ++ "," ++ submodule), "good: the gitlink is set with update-index --cacheinfo 160000,<sha>,<submodule>");
    try check(f.clones() == 1 and Fake.countHas(f.git_log.items, "--depth 1") == 1 and Fake.countHas(f.git_log.items, "submodule update") == 0 and Fake.countHas(f.git_log.items, "submodule init") == 0 and Fake.countPrefix(f.git_log.items, "submodule") == 0 and Fake.countHas(f.git_log.items, "--recurse") == 0 and Fake.countHas(f.git_log.items, "--no-checkout") == 0, "good: a shallow clone, no submodule is initialised");
    try check(Fake.countHas(f.git_log.items, "diff --cached --raw -z --no-renames --ignore-submodules=none HEAD") == 1 and Fake.countHas(f.git_log.items, "ls-tree HEAD -- " ++ submodule) == 2, "good: the staged change is checked before the commit, the commit is checked before the push");
    try check(std.mem.startsWith(u8, f.commit_msg.?, "chore(rules): bump to v1.2.3\n---\n") and has(f.commit_msg.?, "Release: https://github.com/org/rules/releases/tag/v1.2.3"), "good: the commit message is 'chore(<submodule>): bump to v1.2.3' with the release url in the body");
    // the identity and the token, in the environment of every git call
    const header = try std.fmt.allocPrint(a, "HEADER=AUTHORIZATION: basic {s} ", .{try b64(a, "x-access-token:" ++ token)});
    var commit_line: []const u8 = "";
    for (f.git_env.items) |l| {
        if (std.mem.startsWith(u8, l, "commit ")) commit_line = l;
    }
    try check(has(commit_line, "AUTHOR=" ++ bot ++ " <" ++ bot_mail ++ ">") and has(commit_line, "COMMITTER=" ++ bot ++ " <" ++ bot_mail ++ ">"), "good: the commit is authored and committed by the bot user (the id of the bot USER in the noreply address)");
    try check(f.git_env.items.len > 3 and Fake.countHas(f.git_env.items, "GH_TOKEN=(unset) GITHUB_TOKEN=(unset)") == f.git_env.items.len, "good: neither GH_TOKEN nor an ambient GITHUB_TOKEN reaches git");
    try check(Fake.countHas(f.git_env.items, header) == f.git_env.items.len, "good: the token reaches every git call as an HTTP header in the environment");
    try check(Fake.countHas(f.git_env.items, "PROTOCOL=https") == f.git_env.items.len, "good: git is limited to https");
    try check(f.gh_given_env == 0 and f.gh_log.items.len > 5, "good: gh takes the token from its own environment (the step passes it none)");
    const enc = try b64(a, "x-access-token:" ++ token);
    try check(Fake.countHas(f.gh_log.items, token) == 0 and Fake.countHas(f.git_log.items, token) == 0 and Fake.countHas(f.gh_log.items, enc) == 0 and Fake.countHas(f.git_log.items, enc) == 0, "good: the token is in no argument of gh or git");
    try check(std.mem.eql(u8, f.gh_log.items[0], "api repos/org/rules/commits/v1.2.3 --jq .sha"), "good: the tag of the released repository is checked against the commit first");
    try check(Fake.countPrefix(f.gh_log.items, "api repos/org/rules/compare/" ++ old ++ "..." ++ sha ++ " ") == 1, "good: the old gitlink is checked to be an ancestor (compare says ahead)");
    try check(Fake.countPrefix(f.gh_log.items, "pr create -R " ++ internal ++ " --base main --head " ++ branch ++ " --title chore(rules): bump to v1.2.3 --body ") == 1, "good: gh pr create names the base main, the branch and the title");
    try check(Fake.countPrefix(f.gh_log.items, "pr merge " ++ pr_head ++ "100 -R " ++ internal ++ " --auto --merge") == 1 and Fake.countPrefix(f.gh_log.items, "pr view ") == 1, "good: auto-merge is enabled with --auto --merge, then checked");
    try check(Fake.countPrefix(f.gh_log.items, "pr ") == Fake.countHas(f.gh_log.items, "-R " ++ internal) and Fake.countPrefix(f.gh_log.items, "pr ") == 4, "good: every pr call names the internal repository");
    try check(std.mem.eql(u8, try w.prs(), "100 OPEN " ++ branch ++ " 1\n"), "good: the pull request is open with auto-merge on, and no other is touched");

    // Idempotent: the same run again does nothing.
    const again = w.go();
    try check(again.ok and has(again.text, "nothing to open") and f.clones() == 1 and f.created() == 1 and f.pushed.items.len == 1 and std.mem.eql(u8, try w.prs(), "100 OPEN " ++ branch ++ " 1\n"), "idempotent: a second run finds the open pull request and does nothing");
}

test "bump-internal: a bump for this or a newer version that exists is the end of it; an older one is closed" {
    var arena = arenaOf();
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { name: []const u8, state: []const u8, head: []const u8, auto: bool }{
        .{ .name = "merged_same", .state = "MERGED", .head = "bump/rules-v1.2.3", .auto = true },
        .{ .name = "merged_newer", .state = "MERGED", .head = "bump/rules-v1.2.4", .auto = true },
        .{ .name = "open_newer", .state = "OPEN", .head = "bump/rules-v1.3.0", .auto = true },
        // Numeric: 1.10.0 is newer than 1.2.3 (a string comparison puts it below).
        .{ .name = "open_numeric_newer", .state = "OPEN", .head = "bump/rules-v1.10.0", .auto = true },
        .{ .name = "open_numeric_patch", .state = "OPEN", .head = "bump/rules-v1.2.10", .auto = false },
    };
    for (cases) |c| {
        const w = try World.init(a);
        defer w.deinit();
        try w.row(90, c.state, c.head, c.auto);
        const before = try w.prs();
        const r = w.go();
        try check(r.ok and has(r.text, "nothing to open") and w.fake.untouched() and w.fake.clones() == 0 and std.mem.eql(u8, try w.prs(), before), c.name);
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        try w.row(90, "OPEN", branch, false);
        const r = w.go();
        try check(r.ok and std.mem.eql(u8, try w.prs(), "90 OPEN " ++ branch ++ " 1\n") and w.fake.created() == 0 and w.fake.clones() == 0 and Fake.countPrefix(w.fake.gh_log.items, "pr merge 90 -R " ++ internal ++ " --auto --merge") == 1, "an open pull request for this version without auto-merge gets it, and no second is opened");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        try w.row(80, "OPEN", "bump/rules-v1.2.2", true);
        try w.row(81, "OPEN", "bump/rules-v1.1.9", false);
        const r = w.go();
        const prs = try w.prs();
        try check(r.ok and has(prs, "80 CLOSED bump/rules-v1.2.2 1\n") and has(prs, "81 CLOSED bump/rules-v1.1.9 0\n") and has(prs, "102 OPEN " ++ branch ++ " 1\n"), "older: an older open bump is closed in favour of the new one, which is open with auto-merge");
        try check(Fake.countPrefix(w.fake.gh_log.items, "pr close 80 -R " ++ internal ++ " --comment Superseded by " ++ pr_head ++ "102. --delete-branch") == 1, "older: the note names the new pull request");
        const merge_at = for (w.fake.gh_log.items, 0..) |l, i| {
            if (std.mem.startsWith(u8, l, "pr merge ")) break i;
        } else 999;
        const close_at = for (w.fake.gh_log.items, 0..) |l, i| {
            if (std.mem.startsWith(u8, l, "pr close ")) break i;
        } else 0;
        try check(merge_at != 999 and close_at > merge_at, "older: the older ones are closed after the new one is open with auto-merge");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        try w.row(70, "MERGED", "bump/rules-v1.2.2", true);
        try w.row(60, "CLOSED", branch, false);
        try w.row(50, "OPEN", "bump/other-v9.9.9", false);
        try w.row(51, "OPEN", "feature/x", false);
        try w.row(52, "OPEN", "bump/rules-vnot-a-version", false);
        const r = w.go();
        const prs = try w.prs();
        try check(r.ok and has(prs, "70 MERGED") and has(prs, "60 CLOSED") and has(prs, "50 OPEN bump/other-v9.9.9 0") and has(prs, "51 OPEN feature/x 0") and has(prs, "52 OPEN bump/rules-vnot-a-version 0") and has(prs, "105 OPEN " ++ branch ++ " 1") and Fake.countPrefix(w.fake.gh_log.items, "pr close ") == 0, "unrelated: merged-older, closed-unmerged, other-submodule and non-bump pull requests are neither a reason to stop nor closed");
    }
}

test "bump-internal: a branch an earlier run pushed is reused when it holds the commit, refused when it holds another" {
    var arena = arenaOf();
    defer arena.deinit();
    const a = arena.allocator();
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.existing_branch = branch;
        w.fake.branch_gitlink = sha;
        const r = w.go();
        try check(r.ok and w.fake.clones() == 0 and w.fake.pushed.items.len == 0 and w.fake.created() == 1 and std.mem.eql(u8, try w.prs(), "100 OPEN " ++ branch ++ " 1\n"), "retry: a pushed branch without a pull request is reused: no clone, no push, the pull request opened");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.existing_branch = branch;
        w.fake.branch_gitlink = other;
        const r = w.go();
        try check(!r.ok and has(r.text, "not " ++ sha) and w.fake.untouched() and w.fake.clones() == 0, "retry: a branch of that name that holds another commit is refused, not reused");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.branch_lookup_error = true;
        const r = w.go();
        try check(!r.ok and has(r.text, "cannot look for the branch") and w.fake.untouched() and w.fake.clones() == 0, "failure: a branch lookup that fails for another reason than 404 is red, not read as 'no branch'");
    }
}

test "bump-internal: the tag must name the commit, or nothing is cloned" {
    var arena = arenaOf();
    defer arena.deinit();
    const a = arena.allocator();
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.tag_commit = other;
        const r = w.go();
        try check(!r.ok and has(r.text, "the tag v1.2.3 of org/rules names " ++ other) and w.fake.untouched() and w.fake.clones() == 0, "defect: the tag names another commit (the guard's tag_elsewhere) is refused before the clone");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.tag_commit = null;
        const r = w.go();
        try check(!r.ok and has(r.text, "gh api failed") and w.fake.untouched() and w.fake.clones() == 0, "defect: there is no tag (the guard's not_tagged) is refused before the clone");
    }
}

test "bump-internal: a staged change that is not one modified gitlink is refused before the commit" {
    var arena = arenaOf();
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_]struct { diff: []const u8, why: []const u8 }{
        .{ .diff = ":160000 160000 x y M\x00rules\x00:100644 100644 x y M\x00README.md\x00", .why = "more than one changed path" },
        .{ .diff = ":160000 160000 x y M\x00other\x00", .why = "a different submodule" },
        .{ .diff = ":100644 100644 x y M\x00.gitmodules\x00", .why = ".gitmodules" },
        .{ .diff = ":100644 100644 x y M\x00rules\x00", .why = "a file" },
        .{ .diff = ":160000 100644 x y M\x00rules\x00", .why = "a gitlink turned file" },
        .{ .diff = ":160000 000000 x y D\x00rules\x00", .why = "deleted" },
        .{ .diff = ":160000 160000 x y R100\x00rules\x00other\x00", .why = "a rename" },
        .{ .diff = "", .why = "no change" },
    };
    for (bad) |c| {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.git_diff = c.diff;
        const r = w.go();
        try check(!r.ok and has(r.text, "not exactly one modified gitlink at rules") and w.fake.commit_msg == null and w.fake.untouched(), c.why);
    }
}

test "bump-internal: a gitlink that is not a forward move of a gitlink is refused, and one already there is not touched" {
    var arena = arenaOf();
    defer arena.deinit();
    const a = arena.allocator();
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.ls_tree = "100644 blob " ++ old ++ "\trules\n";
        const r = w.go();
        try check(!r.ok and has(r.text, "is not a gitlink") and w.fake.index_entry == null and w.fake.untouched(), "defect: the submodule is a file in the internal repository (not_a_gitlink) is refused before it is staged");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.ls_tree = "";
        const r = w.go();
        try check(!r.ok and has(r.text, "the path is not in the repository") and w.fake.untouched(), "defect: the submodule is not in the internal repository at all is refused");
    }
    for ([_][]const u8{ "behind", "diverged", "identical" }) |status| {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.compare = status;
        const r = w.go();
        try check(!r.ok and has(r.text, try std.fmt.allocPrint(a, "compare says '{s}'", .{status})) and w.fake.index_entry == null and w.fake.untouched(), status);
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.ls_tree = "160000 commit " ++ sha ++ "\trules\n";
        const r = w.go();
        try check(r.ok and has(r.text, "is already at") and w.fake.index_entry == null and w.fake.commit_msg == null and w.fake.untouched(), "the submodule is already at --sha: nothing to open, nothing staged, no empty commit");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.commit_wrong = true;
        const r = w.go();
        try check(!r.ok and has(r.text, "after the commit the gitlink of rules is not") and w.fake.untouched(), "defect: the commit holds another gitlink than the one staged is refused before the push");
    }
}

test "bump-internal: every failing call is red, and a retry finishes what stopped" {
    var arena = arenaOf();
    defer arena.deinit();
    const a = arena.allocator();
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.clone_fail = true;
        const r = w.go();
        try check(!r.ok and has(r.text, "git clone failed") and w.fake.untouched(), "a clone that fails is red, nothing pushed or opened");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.commit_fail = true;
        const r = w.go();
        try check(!r.ok and has(r.text, "git commit failed") and w.fake.untouched(), "a commit that fails is red, nothing pushed or opened");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.push_fail = true;
        const r = w.go();
        try check(!r.ok and has(r.text, "git push failed") and w.fake.created() == 0, "a push that fails is red and no pull request is opened");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.create_fail = true;
        const r = w.go();
        try check(!r.ok and has(r.text, "gh pr failed") and w.fake.prs.items.len == 0, "a pull request that cannot be created is red");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.merge_fail = true;
        const r = w.go();
        try check(!r.ok and has(r.text, "gh pr failed") and std.mem.eql(u8, try w.prs(), "100 OPEN " ++ branch ++ " 0\n"), "auto-merge that cannot be enabled is red (the pull request stays open)");
        // the retry: the branch is on the remote now, and the pull request exists without auto-merge
        w.fake.merge_fail = false;
        const retry = w.go();
        try check(retry.ok and std.mem.eql(u8, try w.prs(), "100 OPEN " ++ branch ++ " 1\n") and w.fake.created() == 1 and w.fake.clones() == 1, "... and the retry finds that pull request and enables auto-merge, opening no second");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.auto_noop = true;
        const r = w.go();
        try check(!r.ok and has(r.text, "auto-merge is not on"), "defect: a merge call that leaves auto-merge off is caught by the check");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        try w.row(80, "OPEN", "bump/rules-v1.2.2", true);
        w.fake.close_fail = true;
        const r = w.go();
        try check(!r.ok and has(r.text, "gh pr failed"), "an older bump that cannot be closed is red");
    }
}

test "bump-internal: inputs that the guard would refuse are refused before any gh or git call" {
    var arena = arenaOf();
    defer arena.deinit();
    const a = arena.allocator();
    const Field = enum { tag, sha, repo, submodule, dest_repo };
    const bad = [_]struct { field: Field, value: []const u8, said: []const u8 }{
        .{ .field = .tag, .value = "1.2.3", .said = "--tag" },
        .{ .field = .tag, .value = "v1.2", .said = "--tag" },
        .{ .field = .tag, .value = "v1.2.3-rc.1", .said = "--tag" },
        .{ .field = .tag, .value = "v1.02.3", .said = "--tag" },
        .{ .field = .sha, .value = "0123456", .said = "--sha" },
        .{ .field = .sha, .value = "0123456789ABCDEF0123456789ABCDEF01234567", .said = "--sha" },
        .{ .field = .submodule, .value = "../rules", .said = "--submodule" },
        .{ .field = .submodule, .value = "a/b", .said = "--submodule" },
        .{ .field = .submodule, .value = "", .said = "--submodule" },
        .{ .field = .repo, .value = "rules", .said = "--repo" },
        .{ .field = .dest_repo, .value = "internal-repo", .said = "--internal-repo" },
        .{ .field = .dest_repo, .value = "a/b/c", .said = "--internal-repo" },
        .{ .field = .dest_repo, .value = "org/", .said = "--internal-repo" },
    };
    for (bad) |c| {
        const w = try World.init(a);
        defer w.deinit();
        switch (c.field) {
            .tag => w.o.tag = c.value,
            .sha => w.o.sha = c.value,
            .repo => w.o.repo = c.value,
            .submodule => w.o.submodule = c.value,
            .dest_repo => w.o.dest_repo = c.value,
        }
        const r = w.go();
        try check(!r.ok and has(r.text, c.said) and w.fake.gh_log.items.len == 0 and w.fake.git_log.items.len == 0, c.value);
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        w.o.token = "";
        const r = w.go();
        try check(!r.ok and has(r.text, "GH_TOKEN is not set") and w.fake.gh_log.items.len == 0 and w.fake.git_log.items.len == 0, "no token is refused before any gh or git call");
    }
}

test "bump-internal: a token in an argument, and a work directory that is not empty, are refused before the command runs" {
    var arena = arenaOf();
    defer arena.deinit();
    const a = arena.allocator();
    {
        // The guard against the token in an argument is live: a token that is a substring of an argument is refused.
        const w = try World.init(a);
        defer w.deinit();
        w.o.token = "internal-repo";
        const r = w.go();
        try check(!r.ok and has(r.text, "with the token in its arguments") and w.fake.git_log.items.len == 0 and w.fake.untouched(), "defect: a token that appears in an argument is refused before the command runs");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        try w.tmp.dir.makePath("wd");
        try w.tmp.dir.writeFile(.{ .sub_path = "wd/leftover", .data = "x" });
        const r = w.go();
        try check(!r.ok and has(r.text, "is not empty") and w.fake.clones() == 0 and w.fake.untouched(), "defect: the work directory is not empty is refused before the clone");
    }
}

test "bump-internal: the names the step accepts" {
    try t.expect(bump.namePart("rules") and bump.namePart("a.b_c-d") and bump.namePart("X9"));
    try t.expect(!bump.namePart("") and !bump.namePart(".hidden") and !bump.namePart("a/b") and !bump.namePart("a b") and !bump.namePart("..") and !bump.namePart("a$b"));
    try t.expect(bump.ownerName("org/name") and bump.ownerName("o-r.g/n_1"));
    try t.expect(!bump.ownerName("name") and !bump.ownerName("/name") and !bump.ownerName("org/") and !bump.ownerName("a/b/c") and !bump.ownerName("org/.name"));
}

test "bump-internal: the identity is the release bot's login and the noreply address of its user id" {
    try t.expectEqualStrings(bot, bump.bot_name);
    try t.expectEqualStrings(bot_mail, bump.bot_email);
}

// ---- a submodule that the internal repository mounts as an external cell: .buckconfig's commit_hash moves with the gitlink ----

/// The internal repository's .buckconfig: the section `[external_cell_<submodule>]` holds the second pin; another cell's commit_hash and a
/// comment that mentions the key stand next to it and must stay as they are.
fn cfgWith(comptime pin: []const u8) []const u8 {
    return "[cells]\n  rules = rules-ext\n\n[external_cell_other]\n  commit_hash = " ++ other ++ "\n\n[external_cell_rules]\n  git_origin = https://example.test/rules.git\n" ++
        "  # the pin: commit_hash = " ++ old ++ "\n  commit_hash = " ++ pin ++ "\n\n[buildfile]\n  name = BUCK\n";
}

fn workText(a: Allocator, w: *World, name: []const u8) ![]const u8 {
    const file = try std.fs.path.join(a, &.{ w.o.workdir, name });
    return std.fs.cwd().readFileAlloc(a, file, 1 << 20);
}

test "bump-internal: a submodule with an external cell has the commit_hash line set to the commit in the same commit as the gitlink" {
    var arena = arenaOf();
    defer arena.deinit();
    const a = arena.allocator();
    const w = try World.init(a);
    defer w.deinit();
    const f = &w.fake;
    f.buckconfig = cfgWith(old);
    const r = w.go();
    try check(r.ok and has(r.text, "opened " ++ pr_head ++ "100 with auto-merge"), "pin: ok, and the pull request is opened");
    try check(std.mem.eql(u8, try workText(a, w, ".buckconfig"), cfgWith(sha)), "pin: exactly the commit_hash line of [external_cell_rules] is the new commit; the other cell's key, the comment and every other line are as they were");
    try check(f.added.items.len == 1 and std.mem.eql(u8, f.added.items[0], "-- .buckconfig"), "pin: .buckconfig is staged by path, once");
    try check(Fake.countPrefix(f.git_log.items, "-C ") > 0 and Fake.countHas(f.git_log.items, "add -- .buckconfig") == 1 and Fake.countHas(f.git_log.items, "add -A") == 0 and Fake.countHas(f.git_log.items, "commit -a") == 0, "pin: no add -A, no commit -a");
    try check(f.pushed.items.len == 1 and f.created() == 1 and std.mem.eql(u8, f.index_entry.?, "160000," ++ sha ++ "," ++ submodule), "pin: the gitlink is moved in the same commit, pushed once");
}

test "bump-internal: no .buckconfig, or no cell section for the submodule, leaves the bump a gitlink alone" {
    var arena = arenaOf();
    defer arena.deinit();
    const a = arena.allocator();
    {
        const w = try World.init(a);
        defer w.deinit();
        const r = w.go();
        try check(r.ok and w.fake.added.items.len == 0 and w.fake.created() == 1, "no .buckconfig in the clone: a gitlink alone");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        const text = "[cells]\n  rules = rules-ext\n\n[external_cell_other]\n  commit_hash = " ++ other ++ "\n";
        w.fake.buckconfig = text;
        const r = w.go();
        try check(r.ok and w.fake.added.items.len == 0 and w.fake.created() == 1 and std.mem.eql(u8, try workText(a, w, ".buckconfig"), text), "another cell's commit_hash is not touched and not staged");
    }
}

test "bump-internal: a cell section with no commit_hash, or two, is refused before the commit" {
    var arena = arenaOf();
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_]struct { text: []const u8, why: []const u8 }{
        .{ .text = "[external_cell_rules]\n  git_origin = https://example.test/rules.git\n", .why = "no commit_hash" },
        .{ .text = "[external_cell_rules]\n  commit_hash = " ++ old ++ "\n  commit_hash = " ++ other ++ "\n", .why = "two commit_hash lines" },
        .{ .text = "[external_cell_rules]\n  commit_hash = v1.2.3\n", .why = "a commit_hash that is not a commit id" },
    };
    for (bad) |c| {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.buckconfig = c.text;
        const r = w.go();
        try check(!r.ok and has(r.text, "commit_hash") and w.fake.commit_msg == null and w.fake.added.items.len == 0 and w.fake.untouched(), c.why);
    }
}

test "bump-internal: a gitlink already at the commit with another commit_hash is refused, with both it is nothing to do" {
    var arena = arenaOf();
    defer arena.deinit();
    const a = arena.allocator();
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.ls_tree = "160000 commit " ++ sha ++ "\trules\n";
        w.fake.buckconfig = cfgWith(old);
        const r = w.go();
        try check(!r.ok and has(r.text, "commit_hash") and has(r.text, old) and w.fake.commit_msg == null and w.fake.untouched(), "the gitlink moved alone earlier: refused, a person fixes the two pins");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.ls_tree = "160000 commit " ++ sha ++ "\trules\n";
        w.fake.buckconfig = cfgWith(sha);
        const r = w.go();
        try check(r.ok and has(r.text, "is already at") and w.fake.commit_msg == null and w.fake.untouched(), "both pins already at the commit: nothing to open");
    }
}

test "bump-internal: with a commit_hash to move, the staged change must be exactly .buckconfig and the gitlink" {
    var arena = arenaOf();
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_]struct { diff: []const u8, why: []const u8 }{
        .{ .diff = ":160000 160000 x y M\x00rules\x00", .why = "the gitlink alone" },
        .{ .diff = ":100644 100644 x y M\x00.buckconfig\x00", .why = ".buckconfig alone" },
        .{ .diff = ":100644 100644 x y M\x00.buckconfig\x00:100644 100644 x y M\x00README.md\x00:160000 160000 x y M\x00rules\x00", .why = "a third path" },
        .{ .diff = ":100644 100755 x y M\x00.buckconfig\x00:160000 160000 x y M\x00rules\x00", .why = ".buckconfig made executable" },
        .{ .diff = ":100644 100644 x y M\x00.buckconfig\x00:100644 100644 x y M\x00.gitmodules\x00", .why = ".gitmodules instead of the gitlink" },
        .{ .diff = ":100644 100644 x y M\x00.buckconfig\x00:160000 160000 x y M\x00other\x00", .why = "another submodule's gitlink" },
    };
    for (bad) |c| {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.buckconfig = cfgWith(old);
        w.fake.git_diff = c.diff;
        const r = w.go();
        try check(!r.ok and has(r.text, "not exactly the gitlink of rules and .buckconfig") and w.fake.commit_msg == null and w.fake.untouched(), c.why);
    }
}

test "bump-internal: a pushed branch is reused only when its gitlink and its commit_hash are both the commit" {
    var arena = arenaOf();
    defer arena.deinit();
    const a = arena.allocator();
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.existing_branch = branch;
        w.fake.branch_gitlink = sha;
        w.fake.branch_buckconfig = cfgWith(sha);
        const r = w.go();
        try check(r.ok and w.fake.clones() == 0 and w.fake.pushed.items.len == 0 and w.fake.created() == 1, "retry: both pins right: reused");
    }
    {
        const w = try World.init(a);
        defer w.deinit();
        w.fake.existing_branch = branch;
        w.fake.branch_gitlink = sha;
        w.fake.branch_buckconfig = cfgWith(old);
        const r = w.go();
        try check(!r.ok and has(r.text, "commit_hash") and has(r.text, old) and w.fake.untouched() and w.fake.clones() == 0, "retry: the branch holds the gitlink but another commit_hash: refused, not reused");
    }
}
