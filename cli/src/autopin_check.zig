//! `buildrules autopin commit-check`: the part of the commit job that holds no write token. It is started by the
//! `workflow_run` event of a compute run and treats everything that run produced as hostile: the artifact, its
//! manifest and the tables in it. What it believes is what it reads again itself from the API (the pull request,
//! its commits and files, the lock, the package.json and the tables at the head commit, by git blob hash) and what
//! it derives (SETS, the canonical URL of a row). Out of the artifact only the VALUES of table rows are kept; the
//! bytes that may be written are re-made by the generator's own renderer and are written under `--out` for
//! `commit-push`, never to a path that came from the artifact.
//!
//! Two kinds of "no": a SKIP (exit 0, `has_change=false`, a line saying why) for a pull request that is not ours to
//! touch (closed, moved on, a human edited it, a file outside SETS changed), and a REFUSAL (exit 1) for bytes that
//! claim to be ours and are not (a hostile or broken artifact, a lock this tool does not accept, a table that is not
//! what its inputs produce, an API answer that cannot be believed).

const std = @import("std");
const api_mod = @import("autopin_api.zig");
const ctxm = @import("ctx.zig");
const event_mod = @import("autopin_event.zig");
const gh = @import("autopin_gh.zig");
const lock_mod = @import("autopin_lock.zig");
const manifest_mod = @import("autopin_manifest.zig");
const sets_mod = @import("autopin_sets.zig");
const table_mod = @import("autopin_table.zig");
const zip = @import("autopin_zip.zig");
const Diag = @import("diag.zig").Diag;
const Ctx = ctxm.Ctx;

pub const plan_file = "plan.json";
pub const max_artifact_bytes: usize = 16 << 20;

pub const usage_text =
    \\usage: buildrules autopin commit-check --event FILE --out DIR --set DIR=KIND [--set DIR=KIND ...] --app-login LOGIN [--github-output FILE]
    \\
    \\  --event FILE          the workflow_run event of the compute run (GITHUB_EVENT_PATH)
    \\  --out DIR             where the checked tables and plan.json go (an empty or absent directory)
    \\  --set D=KIND          the directories autopin may write, as for `compute`; repeatable
    \\  --app-login LOGIN     the autopin App's bot login, `<name>[bot]`: a commit by it, as by Dependabot, may be on the pull request
    \\  --github-output FILE  append `has_change=true` or `has_change=false` to this file (GITHUB_OUTPUT)
    \\
    \\Reads with the token in GH_TOKEN (read access only; it never writes). Exit codes: 0 checked or skipped (has_change says
    \\which), 1 refused, 2 usage.
    \\
;

const Stop = error{ Skip, Refuse };

/// What a pass says and how it ends.
const Rep = struct {
    ctx: *Ctx,

    fn skip(self: *Rep, comptime fmt: []const u8, args: anytype) Stop {
        self.ctx.say("autopin: skip: " ++ fmt, args);
        return error.Skip;
    }

    fn refuse(self: *Rep, comptime fmt: []const u8, args: anytype) Stop {
        self.ctx.err.print("buildrules: refused: " ++ fmt ++ "\n", args) catch {};
        return error.Refuse;
    }
};

/// What `commit-push` is given.
pub const Plan = struct {
    repo: []const u8,
    pr: u64,
    head_sha: []const u8,
    branch: []const u8,
    /// Repository-relative paths, each the table output of a SETS directory, each written under `--out`.
    files: []const []const u8,
};

pub fn renderPlan(a: std.mem.Allocator, p: Plan) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.print(a, "{{\"repo\":\"{s}\",\"pr\":{d},\"head_sha\":\"{s}\",\"branch\":\"{s}\",\"files\":[", .{ p.repo, p.pr, p.head_sha, p.branch });
    for (p.files, 0..) |f, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.print(a, "\"{s}\"", .{f});
    }
    try buf.appendSlice(a, "]}\n");
    return buf.items;
}

const Opts = struct {
    event: ?[]const u8 = null,
    out: ?[]const u8 = null,
    github_output: ?[]const u8 = null,
    app_login: ?[]const u8 = null,
    set_values: []const []const u8 = &.{},
};

/// Tests give a fake; `autopin.zig` gives the real client.
pub fn run(root: *Ctx, args: []const []const u8, api: api_mod.Api) u8 {
    var o = Opts{};
    var set_values = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const known = std.mem.eql(u8, arg, "--event") or std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "--set") or std.mem.eql(u8, arg, "--github-output") or std.mem.eql(u8, arg, "--app-login");
        if (!known) return root.usage("autopin commit-check: unknown argument {s}\n{s}", .{ arg, usage_text });
        const v = ctxm.flagValue(args, &i) orelse return root.usage("autopin commit-check: {s} needs a value", .{arg});
        if (std.mem.eql(u8, arg, "--event")) o.event = v else if (std.mem.eql(u8, arg, "--out")) o.out = v else if (std.mem.eql(u8, arg, "--github-output")) o.github_output = v else if (std.mem.eql(u8, arg, "--app-login")) o.app_login = v else set_values.append(root.a, v) catch return root.fail("out of memory", .{});
    }
    o.set_values = set_values.items;
    if (o.event == null or o.out == null or o.app_login == null) return root.usage("autopin commit-check: --event, --out and --app-login are required\n{s}", .{usage_text});
    if (!gh.isBotLogin(o.app_login.?)) return root.usage("autopin commit-check: --app-login must look like `name[bot]`", .{});
    const sets = sets_mod.Sets.parse(root.a, o.set_values) catch |e| return root.usage("autopin commit-check: --set: {s}", .{@errorName(e)});
    var rep = Rep{ .ctx = root };
    const result = check(&rep, root, api, o, sets);
    if (result) |changed| {
        writeOutput(root, o, changed) catch |e| return root.fail("autopin commit-check: cannot write the output: {s}", .{@errorName(e)});
        return ctxm.exit_ok;
    } else |e| switch (e) {
        error.Skip => {
            writeOutput(root, o, false) catch |we| return root.fail("autopin commit-check: cannot write the output: {s}", .{@errorName(we)});
            return ctxm.exit_ok;
        },
        error.Refuse => {
            writeOutput(root, o, false) catch {};
            return ctxm.exit_fail;
        },
        else => {
            writeOutput(root, o, false) catch {};
            return root.fail("autopin commit-check: {s}", .{@errorName(e)});
        },
    }
}

fn writeOutput(root: *Ctx, o: Opts, changed: bool) !void {
    const path = o.github_output orelse return;
    const old = (try root.readOpt(path)) orelse "";
    const line = if (changed) "has_change=true\n" else "has_change=false\n";
    try root.write(path, try std.mem.concat(root.a, u8, &.{ old, line }));
}

fn outDirEmpty(ctx: *Ctx, out: []const u8) !bool {
    var d = ctx.dir.openDir(out, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return true,
        else => return e,
    };
    defer d.close();
    var it = d.iterate();
    return (try it.next()) == null;
}

fn url(a: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(a, format, args);
}

/// `GET path` that must answer 200 with JSON.
fn getOk(rep: *Rep, a: std.mem.Allocator, api: api_mod.Api, p: []const u8) anyerror!std.json.Value {
    const r = try gh.get(a, api, p);
    if (r.status != 200 or r.value == null) return rep.refuse("the API answered {d} for {s}", .{ r.status, p });
    return r.value.?;
}

fn check(rep: *Rep, root: *Ctx, api: api_mod.Api, o: Opts, sets: sets_mod.Sets) anyerror!bool {
    const a = root.a;
    if (!try outDirEmpty(root, o.out.?)) return rep.refuse("--out {s} is not empty", .{o.out.?});
    const event_text = root.read(o.event.?) catch |e| return rep.refuse("cannot read the event {s}: {s}", .{ o.event.?, @errorName(e) });
    var why: ?[]const u8 = null;
    const ev = event_mod.parse(a, event_text, &why) catch |e| switch (e) {
        error.Refused => return rep.skip("{s}", .{why orelse "the event is not one to act on"}),
        else => return e,
    };
    const repo = ev.repo;

    // The repository: its id is the event's, and the default branch is the only base a pull request may have.
    const rj = try getOk(rep, a, api, try url(a, "repos/{s}", .{repo}));
    const default_branch = gh.str(gh.field(rj, "default_branch")) orelse return rep.refuse("the repository has no default branch", .{});
    if (!gh.isBranchName(default_branch)) return rep.refuse("the default branch name is not one this program uses", .{});
    if ((gh.int(gh.field(rj, "id")) orelse -1) != ev.repo_id) return rep.skip("the repository id differs from the event's", .{});

    // The artifact: exactly one named for this run and attempt.
    const art_name = try url(a, "autopin-{d}-{d}", .{ ev.run_id, ev.run_attempt });
    const listing = try getOk(rep, a, api, try url(a, "repos/{s}/actions/runs/{d}/artifacts?name={s}&per_page=100", .{ repo, ev.run_id, art_name }));
    const arts = gh.field(listing, "artifacts") orelse return rep.refuse("the artifact list has no artifacts", .{});
    if (arts != .array) return rep.refuse("the artifact list is not a list", .{});
    var found: usize = 0;
    var art_id: i64 = 0;
    for (arts.array.items) |x| {
        if (!std.mem.eql(u8, gh.str(gh.field(x, "name")) orelse "", art_name)) continue;
        if (gh.field(x, "expired")) |ex| if (ex == .bool and ex.bool) continue;
        found += 1;
        art_id = gh.int(gh.field(x, "id")) orelse -1;
    }
    if (found != 1 or art_id < 1) return rep.skip("{d} artifacts named {s} (one is needed)", .{ found, art_name });

    // The bytes, as untrusted as bytes can be.
    const zip_bytes = api_mod.download(a, api, try url(a, "repos/{s}/actions/artifacts/{d}/zip", .{ repo, art_id }), max_artifact_bytes) catch |e| return rep.refuse("the artifact download failed: {s}", .{@errorName(e)});
    var allowed = std.ArrayList([]const u8).empty;
    try allowed.append(a, "manifest.json");
    for (sets.items) |s| try allowed.append(a, try sets_mod.Sets.tablePath(a, s));
    const entries = zip.read(a, zip_bytes, allowed.items, .{}) catch |e| return rep.refuse("the artifact is not an acceptable zip: {s}", .{@errorName(e)});
    const manifest_text = manifest_mod.manifestText(entries) catch return rep.refuse("the artifact has no manifest.json", .{});
    const man = manifest_mod.parse(a, manifest_text, sets) catch |e| return rep.refuse("the manifest is not acceptable: {s}", .{@errorName(e)});
    const members = manifest_mod.members(a, man, entries, sets) catch |e| return rep.refuse("the artifact does not match its manifest: {s}", .{@errorName(e)});

    // The pull request, read again.
    var listed = false;
    for (ev.pull_requests) |n| if (n == @as(i64, @intCast(man.pr))) {
        listed = true;
    };
    if (!listed) return rep.skip("the manifest's pull request is not one the run belongs to", .{});
    const pr = try getOk(rep, a, api, try url(a, "repos/{s}/pulls/{d}", .{ repo, man.pr }));
    if (!std.mem.eql(u8, gh.str(gh.field(pr, "state")) orelse "", "open")) return rep.skip("the pull request is not open", .{});
    if (!std.mem.eql(u8, gh.str(nestedPr(pr, "user", "login")) orelse "", event_mod.dependabot)) return rep.skip("the pull request is not by Dependabot", .{});
    const head = gh.field(pr, "head") orelse return rep.refuse("the pull request has no head", .{});
    const head_full = gh.str(gh.field(gh.field(head, "repo") orelse .null, "full_name")) orelse "";
    if (!std.mem.eql(u8, head_full, repo)) return rep.skip("the pull request's head is not on this repository", .{});
    const base_ref = gh.str(nestedPr(pr, "base", "ref")) orelse "";
    if (!std.mem.eql(u8, base_ref, default_branch)) return rep.skip("the pull request does not target the default branch", .{});
    const head_sha = gh.str(gh.field(head, "sha")) orelse "";
    const base_sha = gh.str(nestedPr(pr, "base", "sha")) orelse "";
    if (!gh.isSha1(head_sha) or !gh.isSha1(base_sha)) return rep.refuse("the pull request's head or base sha is malformed", .{});
    if (!std.mem.eql(u8, head_sha, man.head_sha) or !std.mem.eql(u8, head_sha, ev.head_sha)) return rep.skip("the pull request moved: its head is not the one the artifact was made for", .{});
    const branch = gh.str(gh.field(head, "ref")) orelse "";
    if (!gh.isDependabotBranch(branch)) return rep.skip("the pull request's branch is not a Dependabot npm branch", .{});

    try checkCommits(rep, a, api, repo, man.pr, o.app_login.?);
    const touched = try checkFiles(rep, a, api, repo, man.pr, sets);

    // The inputs at the head commit, by blob hash; the package.json guard needs the merge base too.
    var changed = std.ArrayList([]const u8).empty;
    var tables = std.ArrayList(struct { set: usize, path: []const u8, text: []const u8 }).empty;
    for (sets.items, 0..) |set, si| {
        const lock_path = try sets_mod.Sets.path(a, set, sets_mod.package_lock);
        const pj_path = try sets_mod.Sets.path(a, set, sets_mod.package_json);
        const table_path = try sets_mod.Sets.tablePath(a, set);
        const lock_blob = try readOrRefuse(rep, a, api, repo, lock_path, head_sha);
        const pj_blob = try readOrRefuse(rep, a, api, repo, pj_path, head_sha);
        if (touched[si].package_json) try packageJsonGuard(rep, a, api, repo, pj_path, try mergeBase(rep, a, api, repo, base_sha, head_sha), pj_blob.bytes);

        var member: ?manifest_mod.Member = null;
        for (members) |m| if (m.set == si) {
            member = m;
        };
        const m = member orelse continue;

        // The lock: strict, and the table in the artifact must be exactly what it and the head package.json produce.
        var diag = Diag.init(a);
        const entries_lock = try lock_mod.read(a, lock_blob.bytes, &diag);
        if (diag.count() > 0) return rep.refuse("{s}: the lock is not acceptable: {s}", .{ try gh.oneLine(a, lock_path), try firstMessage(a, &diag) });
        const head_table = try readOrRefuse(rep, a, api, repo, table_path, head_sha);
        const sp = table_mod.split(m.bytes) orelse return rep.refuse("{s}: the table in the artifact has no NPM block", .{table_path});
        const rows = table_mod.parseRows(a, sp.npm, set.kind, &diag) catch return rep.refuse("{s}: the table in the artifact is not the generator's grammar: {s}", .{ table_path, try firstMessage(a, &diag) });
        try table_mod.bind(a, entries_lock, rows, set.kind, &diag);
        if (diag.count() > 0) return rep.refuse("{s}: the table does not match the lock: {s}", .{ table_path, try firstMessage(a, &diag) });
        const fresh: []const u8 = switch (set.kind) {
            .buildrules_lock => (try table_mod.freshBuildrules(a, pj_blob.bytes, lock_blob.bytes, rows, &diag)) orelse return rep.refuse("{s}: the head package.json is not one the generator accepts: {s}", .{ table_path, try firstMessage(a, &diag) }),
            .pins_lock => blk: {
                // The header and the PINS block are the repository's, not the pull request's: they are taken from the merge base,
                // so a pull request that edited them (and a compute run that kept the edit) gets a table that does not match.
                const mb = try mergeBase(rep, a, api, repo, base_sha, head_sha);
                const base_table = (gh.readFile(a, api, repo, table_path, mb) catch |e| switch (e) {
                    error.OutOfMemory => return e,
                    else => return rep.refuse("{s}: cannot be read at the merge base: {s}", .{ table_path, @errorName(e) }),
                }) orelse return rep.skip("{s} does not exist at the merge base", .{table_path});
                const base_split = table_mod.split(base_table.bytes) orelse return rep.refuse("{s}: the table at the merge base has no NPM block", .{table_path});
                break :blk try table_mod.freshPins(a, base_split.prefix, rows);
            },
        };
        if (!std.mem.eql(u8, fresh, m.bytes)) return rep.refuse("{s}: the table in the artifact is not what the generator makes of its rows (a header, PACKAGE block or digest that was changed)", .{table_path});
        if (std.mem.eql(u8, fresh, head_table.bytes)) continue;
        try tables.append(a, .{ .set = si, .path = table_path, .text = fresh });
    }
    for (tables.items) |t| {
        try root.write(try url(a, "{s}/{s}", .{ std.mem.trimRight(u8, o.out.?, "/"), t.path }), t.text);
        try changed.append(a, t.path);
    }
    const plan = try renderPlan(a, .{ .repo = repo, .pr = man.pr, .head_sha = head_sha, .branch = branch, .files = changed.items });
    try root.write(try url(a, "{s}/{s}", .{ std.mem.trimRight(u8, o.out.?, "/"), plan_file }), plan);
    if (changed.items.len == 0) {
        root.say("autopin: nothing to commit: the tables in the repository are what the lock calls for", .{});
        return false;
    }
    root.say("autopin: {d} table(s) to commit on pull request {d}", .{ changed.items.len, man.pr });
    return true;
}

fn nestedPr(v: std.json.Value, k1: []const u8, k2: []const u8) ?std.json.Value {
    const x = gh.field(v, k1) orelse return null;
    return gh.field(x, k2);
}

fn firstMessage(a: std.mem.Allocator, diag: *Diag) ![]u8 {
    if (diag.msgs.items.len == 0) return a.dupe(u8, "(no message)");
    return gh.oneLine(a, diag.msgs.items[0]);
}

fn readOrRefuse(rep: *Rep, a: std.mem.Allocator, api: api_mod.Api, repo: []const u8, p: []const u8, ref: []const u8) anyerror!gh.Blob {
    const blob = gh.readFile(a, api, repo, p, ref) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return rep.refuse("{s}: cannot be read at the head commit as raw bytes that match their blob hash: {s}", .{ p, @errorName(e) }),
    };
    return blob orelse rep.refuse("{s}: there is no such file at the head commit", .{p});
}

/// Every commit of the pull request is by Dependabot or by this program's own App. A tripwire, not a barrier:
/// authors are free text, and a signature proves only who GitHub signed for.
fn checkCommits(rep: *Rep, a: std.mem.Allocator, api: api_mod.Api, repo: []const u8, pr: u64, app_login: []const u8) anyerror!void {
    var page: usize = 1;
    while (true) : (page += 1) {
        const v = try getListOrSkip(rep, a, api, try url(a, "repos/{s}/pulls/{d}/commits?per_page=100&page={d}", .{ repo, pr, page }));
        if (page == 2) {
            if (v.array.items.len > 0) return rep.skip("the pull request has more than 100 commits", .{});
            return;
        }
        for (v.array.items) |c| {
            const author = gh.field(c, "author") orelse return rep.skip("a commit has no GitHub author", .{});
            if (author == .null) return rep.skip("a commit has no GitHub author", .{});
            const login = gh.str(gh.field(author, "login")) orelse return rep.skip("a commit has no author login", .{});
            if (!std.mem.eql(u8, login, event_mod.dependabot) and !std.mem.eql(u8, login, app_login)) return rep.skip("a commit is by {s}, not Dependabot or the autopin App", .{try gh.oneLine(a, login)});
        }
        if (v.array.items.len < 100) return;
    }
}

const Touched = struct { package_json: bool = false };

/// Every changed file (and every file a rename left) is package.json, package-lock.json or the table of a SETS
/// directory. The list is read to its end: a page that could be the cap of the API, or any error, is a skip.
fn checkFiles(rep: *Rep, a: std.mem.Allocator, api: api_mod.Api, repo: []const u8, pr: u64, sets: sets_mod.Sets) anyerror![]Touched {
    const touched = try a.alloc(Touched, sets.items.len);
    @memset(touched, .{});
    var page: usize = 1;
    while (true) : (page += 1) {
        const v = try getListOrSkip(rep, a, api, try url(a, "repos/{s}/pulls/{d}/files?per_page=100&page={d}", .{ repo, pr, page }));
        for (v.array.items) |f| {
            const names = [_]?[]const u8{ gh.str(gh.field(f, "filename")), gh.str(gh.field(f, "previous_filename")) };
            if (names[0] == null) return rep.refuse("a file of the pull request has no name", .{});
            for (names) |maybe| if (maybe) |n| {
                if (!try sets.prMayTouch(a, n)) return rep.skip("the pull request changes {s}, which is not a lock, package.json or pin table of a SETS directory", .{try gh.oneLine(a, n)});
            };
            for (sets.items, 0..) |s, si| {
                const pj = try sets_mod.Sets.path(a, s, sets_mod.package_json);
                if (std.mem.eql(u8, names[0].?, pj)) touched[si].package_json = true;
            }
        }
        if (v.array.items.len < 100) break;
        if (page >= 30) return rep.skip("the file list is as long as the API allows and may be cut", .{});
    }
    return touched;
}

/// The merge base of the pull request's base and head: the commit its changes are measured from (one compare request).
fn mergeBase(rep: *Rep, a: std.mem.Allocator, api: api_mod.Api, repo: []const u8, base_sha: []const u8, head_sha: []const u8) anyerror![]const u8 {
    const cmp = try getOk(rep, a, api, try url(a, "repos/{s}/compare/{s}...{s}", .{ repo, base_sha, head_sha }));
    const mb = gh.str(nestedPr(cmp, "merge_base_commit", "sha")) orelse return rep.refuse("the comparison has no merge base", .{});
    if (!gh.isSha1(mb)) return rep.refuse("the merge base sha is malformed", .{});
    return mb;
}

/// package.json may differ from the merge base only inside the dependency maps: the table copies its `scripts` and the
/// `buildrules` policy, and the farm runs them.
fn packageJsonGuard(rep: *Rep, a: std.mem.Allocator, api: api_mod.Api, repo: []const u8, pj_path: []const u8, mb: []const u8, head_bytes: []const u8) anyerror!void {
    const base_blob = (gh.readFile(a, api, repo, pj_path, mb) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return rep.refuse("{s}: cannot be read at the merge base: {s}", .{ pj_path, @errorName(e) }),
    }) orelse return rep.skip("{s} does not exist at the merge base", .{pj_path});
    if (!try gh.sameOutsideDependencies(a, base_blob.bytes, head_bytes)) return rep.skip("{s} changes more than its dependency maps (scripts and policy are not a dependency bump)", .{pj_path});
}

/// `GET path` for a list that must be read to its end: an answer that is not a 200 (an error on page 2, a rate limit)
/// leaves the pull request alone this time.
fn getListOrSkip(rep: *Rep, a: std.mem.Allocator, api: api_mod.Api, p: []const u8) anyerror!std.json.Value {
    const r = try gh.get(a, api, p);
    if (r.status != 200 or r.value == null) return rep.skip("the API answered {d} for a list that has to be read to its end", .{r.status});
    if (r.value.? != .array) return rep.refuse("a list answer is not a list", .{});
    return r.value.?;
}
