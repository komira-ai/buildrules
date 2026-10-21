//! `buildrules autopin commit-push`: the one step that holds a write token. It reads the plan `commit-check` made
//! (the repository, the pull request, the head commit, the branch, and the tables to write, which `commit-check`
//! wrote under the plan's directory) and checks it again against SETS and the shapes it must have: nothing in the
//! plan is a path or a name until it has passed the same tests a stranger's input would.
//!
//! The commit is made with the Git Data API on top of the head commit the plan names: the head commit's tree is the
//! base tree, one blob and one tree entry (mode 100644, a SETS table path, never under `.github/`) per file, a commit
//! whose only parent is the head commit and whose author and committer are the App's bot identity, and then the
//! branch is moved to it with `force: false`. `force: false` is the safety property: if the branch moved since the
//! check, GitHub refuses the update as a non-fast-forward, and that exact refusal is a clean skip. Any other failure
//! is a red exit. Nothing here runs a shell or `git`.

const std = @import("std");
const api_mod = @import("autopin_api.zig");
const check_mod = @import("autopin_check.zig");
const ctxm = @import("ctx.zig");
const gh = @import("autopin_gh.zig");
const json = @import("autopin_json.zig");
const sets_mod = @import("autopin_sets.zig");
const Ctx = ctxm.Ctx;

pub const commit_message = "autopin: regenerate pin tables [dependabot skip]";
/// The message GitHub gives a ref update that is not a fast forward.
pub const non_fast_forward = "Update is not a fast forward";
pub const max_file_bytes: usize = 2 << 20;

pub const usage_text =
    \\usage: buildrules autopin commit-push --plan DIR --set DIR=KIND [--set DIR=KIND ...] --author-name NAME --author-email EMAIL
    \\
    \\  --plan DIR         the directory `commit-check` wrote (plan.json and the tables)
    \\  --set D=KIND       the directories autopin may write, as for `compute`; repeatable
    \\  --author-name N    the App's bot name, `<name>[bot]`; author and committer of the commit
    \\  --author-email E   the App's bot address, `<id>+<name>[bot]@users.noreply.github.com`
    \\
    \\Writes with the token in GH_TOKEN. A plan with no files makes no request at all. Exit codes: 0 committed or skipped
    \\because the branch moved, 1 failed, 2 usage.
    \\
;

const Opts = struct {
    plan: ?[]const u8 = null,
    name: ?[]const u8 = null,
    email: ?[]const u8 = null,
    set_values: []const []const u8 = &.{},
};

pub fn run(root: *Ctx, args: []const []const u8, api: api_mod.Api) u8 {
    var o = Opts{};
    var set_values = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const known = std.mem.eql(u8, arg, "--plan") or std.mem.eql(u8, arg, "--set") or std.mem.eql(u8, arg, "--author-name") or std.mem.eql(u8, arg, "--author-email");
        if (!known) return root.usage("autopin commit-push: unknown argument {s}\n{s}", .{ arg, usage_text });
        const v = ctxm.flagValue(args, &i) orelse return root.usage("autopin commit-push: {s} needs a value", .{arg});
        if (std.mem.eql(u8, arg, "--plan")) o.plan = v else if (std.mem.eql(u8, arg, "--author-name")) o.name = v else if (std.mem.eql(u8, arg, "--author-email")) o.email = v else set_values.append(root.a, v) catch return root.fail("out of memory", .{});
    }
    o.set_values = set_values.items;
    if (o.plan == null or o.name == null or o.email == null) return root.usage("autopin commit-push: --plan, --author-name and --author-email are required\n{s}", .{usage_text});
    if (!identityOk(o.name.?, o.email.?)) return root.usage("autopin commit-push: the author name and email must be an App bot's (`<name>[bot]`, `<id>+<name>[bot]@users.noreply.github.com`)", .{});
    const sets = sets_mod.Sets.parse(root.a, o.set_values) catch |e| return root.usage("autopin commit-push: --set: {s}", .{@errorName(e)});
    return push(root, api, o, sets) catch |e| root.fail("autopin commit-push: {s}", .{@errorName(e)});
}

fn botChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-';
}

/// `<name>[bot]` and `<digits>+<name>[bot]@users.noreply.github.com`, the same name in both.
pub fn identityOk(name: []const u8, email: []const u8) bool {
    const bot = "[bot]";
    if (!std.mem.endsWith(u8, name, bot) or name.len <= bot.len or name.len > 60) return false;
    const base = name[0 .. name.len - bot.len];
    for (base) |c| if (!botChar(c)) return false;
    const domain = "@users.noreply.github.com";
    if (!std.mem.endsWith(u8, email, domain)) return false;
    const local = email[0 .. email.len - domain.len];
    const plus = std.mem.indexOfScalar(u8, local, '+') orelse return false;
    if (plus == 0 or plus > 12) return false;
    for (local[0..plus]) |c| if (c < '0' or c > '9') return false;
    return std.mem.eql(u8, local[plus + 1 ..], name);
}

fn jstr(v: ?json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

/// The plan, checked: exactly the five keys, a repository and branch of the shapes this program uses, a head sha, and
/// files that are each, by exact equality, the table output of a SETS directory (and never under `.github/`). The
/// strings point into `text`.
pub fn parsePlan(a: std.mem.Allocator, text: []const u8, sets: sets_mod.Sets) !check_mod.Plan {
    const root = json.parse(a, text) catch return error.PlanNotAcceptable;
    if (root != .object or root.object.len != 5) return error.PlanNotAcceptable;
    const repo = jstr(root.get("repo")) orelse return error.PlanNotAcceptable;
    const pr = root.get("pr") orelse return error.PlanNotAcceptable;
    const head = jstr(root.get("head_sha")) orelse return error.PlanNotAcceptable;
    const branch = jstr(root.get("branch")) orelse return error.PlanNotAcceptable;
    const files = root.get("files") orelse return error.PlanNotAcceptable;
    if (pr != .int or pr.int < 1 or pr.int > 999_999_999 or files != .array or files.array.len > 11) return error.PlanNotAcceptable;
    if (!gh.isRepo(repo) or !gh.isSha1(head) or !gh.isDependabotBranch(branch)) return error.PlanNotAcceptable;
    var list = std.ArrayList([]const u8).empty;
    for (files.array) |f| {
        if (f != .string) return error.PlanNotAcceptable;
        const p = f.string;
        if (std.mem.startsWith(u8, p, ".github/") or (try sets.outputIndex(a, p)) == null) return error.PlanNotAcceptable;
        for (list.items) |have| if (std.mem.eql(u8, have, p)) return error.PlanNotAcceptable;
        try list.append(a, p);
    }
    return .{ .repo = repo, .pr = @intCast(pr.int), .head_sha = head, .branch = branch, .files = list.items };
}

fn send(a: std.mem.Allocator, api: api_mod.Api, method: api_mod.Method, p: []const u8, body: ?[]const u8) anyerror!api_mod.Response {
    return api.send(a, .{ .method = method, .path = p, .body = body, .max_body = 1 << 20 });
}

fn sha_of(a: std.mem.Allocator, r: api_mod.Response, what: []const u8, ctx: *Ctx) !?[]const u8 {
    if (r.status != 200 and r.status != 201) {
        _ = ctx.fail("{s}: the API answered {d}", .{ what, r.status });
        return null;
    }
    const parsed = std.json.parseFromSlice(std.json.Value, a, r.body, .{}) catch {
        _ = ctx.fail("{s}: the answer is not JSON", .{what});
        return null;
    };
    const sha = gh.str(gh.field(parsed.value, "sha")) orelse {
        _ = ctx.fail("{s}: the answer has no sha", .{what});
        return null;
    };
    if (!gh.isSha1(sha)) {
        _ = ctx.fail("{s}: the answer's sha is malformed", .{what});
        return null;
    }
    return sha;
}

fn push(root: *Ctx, api: api_mod.Api, o: Opts, sets: sets_mod.Sets) !u8 {
    const a = root.a;
    const plan_dir = std.mem.trimRight(u8, o.plan.?, "/");
    const text = root.read(try std.fmt.allocPrint(a, "{s}/{s}", .{ plan_dir, check_mod.plan_file })) catch |e| return root.fail("autopin commit-push: cannot read the plan: {s}", .{@errorName(e)});
    const plan = parsePlan(a, text, sets) catch |e| return root.fail("autopin commit-push: the plan is not acceptable: {s}", .{@errorName(e)});
    if (plan.files.len == 0) {
        root.say("autopin: nothing to commit", .{});
        return ctxm.exit_ok;
    }
    // The bytes to write are the files `commit-check` wrote, at SETS paths only.
    var contents = std.ArrayList([]const u8).empty;
    for (plan.files) |f| {
        const bytes = root.read(try std.fmt.allocPrint(a, "{s}/{s}", .{ plan_dir, f })) catch |e| return root.fail("autopin commit-push: cannot read {s}: {s}", .{ f, @errorName(e) });
        if (bytes.len == 0 or bytes.len > max_file_bytes) return root.fail("autopin commit-push: {s} is empty or over {d} bytes", .{ f, max_file_bytes });
        try contents.append(a, bytes);
    }

    // The base tree is the head commit's own tree, read now.
    const head = try send(a, api, .GET, try std.fmt.allocPrint(a, "repos/{s}/git/commits/{s}", .{ plan.repo, plan.head_sha }), null);
    if (head.status != 200) return root.fail("autopin commit-push: the head commit cannot be read (the API answered {d})", .{head.status});
    const head_json = std.json.parseFromSlice(std.json.Value, a, head.body, .{}) catch return root.fail("autopin commit-push: the head commit's answer is not JSON", .{});
    const base_tree = gh.str(gh.field(gh.field(head_json.value, "tree") orelse .null, "sha")) orelse return root.fail("autopin commit-push: the head commit has no tree", .{});
    if (!gh.isSha1(base_tree)) return root.fail("autopin commit-push: the head commit's tree sha is malformed", .{});

    var entries = std.ArrayList(u8).empty;
    for (plan.files, contents.items, 0..) |f, bytes, i| {
        const enc = std.base64.standard.Encoder;
        const b64 = try a.alloc(u8, enc.calcSize(bytes.len));
        _ = enc.encode(b64, bytes);
        const body = try std.fmt.allocPrint(a, "{{\"content\":\"{s}\",\"encoding\":\"base64\"}}", .{b64});
        const r = try send(a, api, .POST, try std.fmt.allocPrint(a, "repos/{s}/git/blobs", .{plan.repo}), body);
        const sha = (try sha_of(a, r, "the blob", root)) orelse return ctxm.exit_fail;
        if (i > 0) try entries.append(a, ',');
        try entries.print(a, "{{\"path\":\"{s}\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"{s}\"}}", .{ f, sha });
    }
    const tree_body = try std.fmt.allocPrint(a, "{{\"base_tree\":\"{s}\",\"tree\":[{s}]}}", .{ base_tree, entries.items });
    const tree = (try sha_of(a, try send(a, api, .POST, try std.fmt.allocPrint(a, "repos/{s}/git/trees", .{plan.repo}), tree_body), "the tree", root)) orelse return ctxm.exit_fail;
    const who = try std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"email\":\"{s}\"}}", .{ o.name.?, o.email.? });
    const commit_body = try std.fmt.allocPrint(a, "{{\"message\":\"{s}\",\"tree\":\"{s}\",\"parents\":[\"{s}\"],\"author\":{s},\"committer\":{s}}}", .{ commit_message, tree, plan.head_sha, who, who });
    const commit = (try sha_of(a, try send(a, api, .POST, try std.fmt.allocPrint(a, "repos/{s}/git/commits", .{plan.repo}), commit_body), "the commit", root)) orelse return ctxm.exit_fail;

    const ref_body = try std.fmt.allocPrint(a, "{{\"sha\":\"{s}\",\"force\":false}}", .{commit});
    const moved = try send(a, api, .PATCH, try std.fmt.allocPrint(a, "repos/{s}/git/refs/heads/{s}", .{ plan.repo, plan.branch }), ref_body);
    if (moved.status == 200) {
        root.say("autopin: committed {d} table(s) to the branch of pull request {d}", .{ plan.files.len, plan.pr });
        return ctxm.exit_ok;
    }
    if (moved.status == 422) {
        const parsed = std.json.parseFromSlice(std.json.Value, a, moved.body, .{}) catch null;
        if (parsed) |p| if (std.mem.eql(u8, gh.str(gh.field(p.value, "message")) orelse "", non_fast_forward)) {
            root.say("autopin: skip: the branch moved since the check; a fresh compute follows", .{});
            return ctxm.exit_ok;
        };
    }
    return root.fail("autopin commit-push: the branch could not be updated (the API answered {d})", .{moved.status});
}
