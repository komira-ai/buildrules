//! The `workflow_run` event the commit half is started by (the file `GITHUB_EVENT_PATH` names). The job-level
//! condition of the workflow already refuses a run that is not the compute workflow's own, for a pull request,
//! on this repository, by Dependabot, and successful; this checks the same things again from the same file, so a
//! workflow that lost one of those conjuncts still does not commit. Nothing here is believed beyond what it is
//! compared with: the pull request, its commits and files are read again from the API.

const std = @import("std");
const gh = @import("autopin_gh.zig");

/// The one workflow file whose runs this program accepts.
pub const compute_workflow_path = ".github/workflows/autopin-compute.yml";
pub const dependabot = "dependabot[bot]";

pub const Event = struct {
    repo: []const u8,
    repo_id: i64,
    run_id: i64,
    run_attempt: i64,
    head_sha: []const u8,
    pull_requests: []const i64,
};

fn nested(v: std.json.Value, comptime keys: []const []const u8) ?std.json.Value {
    var cur = v;
    inline for (keys) |k| cur = gh.field(cur, k) orelse return null;
    return cur;
}

fn refuse(why: *?[]const u8, msg: []const u8) error{Refused} {
    why.* = msg;
    return error.Refused;
}

/// The event, or `error.Refused` with the reason in `why`.
pub fn parse(a: std.mem.Allocator, text: []const u8, why: *?[]const u8) error{ OutOfMemory, Refused }!Event {
    const parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(why, "the event is not JSON"),
    };
    const root = parsed.value;
    const run = gh.field(root, "workflow_run") orelse return refuse(why, "the event has no workflow_run");
    if (!std.mem.eql(u8, gh.str(gh.field(run, "conclusion")) orelse "", "success")) return refuse(why, "the compute run did not succeed");
    if (!std.mem.eql(u8, gh.str(gh.field(run, "event")) orelse "", "pull_request")) return refuse(why, "the compute run was not started by a pull_request event");
    if (!std.mem.eql(u8, gh.str(gh.field(run, "path")) orelse "", compute_workflow_path)) return refuse(why, "the run is not of the compute workflow file");
    const repo = gh.str(nested(root, &.{ "repository", "full_name" })) orelse return refuse(why, "the event names no repository");
    const repo_id = gh.int(nested(root, &.{ "repository", "id" })) orelse return refuse(why, "the event names no repository id");
    if (!gh.isRepo(repo)) return refuse(why, "the repository name is not a plain owner/name");
    const head_repo = gh.str(nested(run, &.{ "head_repository", "full_name" })) orelse "";
    const head_repo_id = gh.int(nested(run, &.{ "head_repository", "id" })) orelse -1;
    if (head_repo_id != repo_id or !std.mem.eql(u8, head_repo, repo)) return refuse(why, "the compute run is of another repository (a fork)");
    if (!std.mem.eql(u8, gh.str(nested(run, &.{ "actor", "login" })) orelse "", dependabot)) return refuse(why, "the compute run's actor is not Dependabot");
    if (!std.mem.eql(u8, gh.str(nested(run, &.{ "triggering_actor", "login" })) orelse "", dependabot)) return refuse(why, "the compute run's triggering actor is not Dependabot");
    const run_id = gh.int(gh.field(run, "id")) orelse return refuse(why, "the run has no id");
    const attempt = gh.int(gh.field(run, "run_attempt")) orelse return refuse(why, "the run has no run_attempt");
    const head_sha = gh.str(gh.field(run, "head_sha")) orelse "";
    if (run_id < 1 or attempt < 1 or attempt > 1000 or !gh.isSha1(head_sha)) return refuse(why, "the run's id, attempt or head sha is malformed");
    var prs = std.ArrayList(i64).empty;
    const list = gh.field(run, "pull_requests") orelse return refuse(why, "the run lists no pull requests");
    if (list != .array) return refuse(why, "the run's pull_requests is not a list");
    for (list.array.items) |p| {
        const n = gh.int(gh.field(p, "number")) orelse return refuse(why, "a pull request of the run has no number");
        try prs.append(a, n);
    }
    return .{ .repo = repo, .repo_id = repo_id, .run_id = run_id, .run_attempt = attempt, .head_sha = head_sha, .pull_requests = prs.items };
}
