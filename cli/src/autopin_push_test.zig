//! `buildrules autopin commit-push` against a fake GitHub that records every request. The plan is the one
//! `commit-check` wrote; the commit is built on the head commit's own tree with `force: false`. Every test is named
//! for the defect it catches.

const std = @import("std");
const autopin = @import("autopin.zig");
const check = @import("autopin_check.zig");
const fx = @import("autopin_fixture_test.zig");
const kit = @import("testkit.zig");
const push = @import("autopin_push.zig");
const t = std.testing;

const blob_sha = "a1" ** 20;
const tree_sha = "b2" ** 20;
const commit_sha = "c3" ** 20;
const name = "autopin-app[bot]";
const email = "123+autopin-app[bot]@users.noreply.github.com";
const ref_key = "repos/" ++ fx.repo ++ "/git/refs/heads/" ++ fx.branch;

const Env = struct {
    h: *kit.Harness,
    fake: *fx.Fake,
};

fn setup() !Env {
    const h = try kit.Harness.create();
    const fake = try h.a().create(fx.Fake);
    fake.* = .{ .a = h.a() };
    fake.put(.GET, "repos/" ++ fx.repo ++ "/git/commits/" ++ fx.head, 200, "{\"sha\":\"" ++ fx.head ++ "\",\"tree\":{\"sha\":\"" ++ fx.tree ++ "\"}}");
    fake.put(.POST, "repos/" ++ fx.repo ++ "/git/blobs", 201, "{\"sha\":\"" ++ blob_sha ++ "\"}");
    fake.put(.POST, "repos/" ++ fx.repo ++ "/git/trees", 201, "{\"sha\":\"" ++ tree_sha ++ "\"}");
    fake.put(.POST, "repos/" ++ fx.repo ++ "/git/commits", 201, "{\"sha\":\"" ++ commit_sha ++ "\"}");
    fake.put(.PATCH, ref_key, 200, "{\"ref\":\"refs/heads/x\"}");
    try writePlan(h, &.{"site/buildrules.lock.bzl"});
    try h.put("plan/site/buildrules.lock.bzl", "TABLE BYTES\n");
    return .{ .h = h, .fake = fake };
}

fn writePlan(h: *kit.Harness, files: []const []const u8) !void {
    const text = try check.renderPlan(h.a(), .{ .repo = fx.repo, .pr = 7, .head_sha = fx.head, .branch = fx.branch, .files = files });
    try h.put("plan/plan.json", text);
}

fn runPush(env: *Env, extra: []const []const u8) kit.Run {
    autopin.api_override = env.fake.api();
    var argv = std.ArrayList([]const u8).empty;
    argv.appendSlice(env.h.a(), &.{ "autopin", "commit-push", "--plan", "plan", "--set", "site=buildrules-lock", "--set", "infra=pins-lock", "--author-name", name, "--author-email", email }) catch unreachable;
    argv.appendSlice(env.h.a(), extra) catch unreachable;
    return env.h.run(argv.items);
}

fn finish(env: *Env) void {
    autopin.api_override = null;
    env.h.destroy();
}

test "push: a blob, a tree on the head commit's tree, a commit whose only parent is the head, then the branch moves with force false" {
    var env = try setup();
    defer finish(&env);
    const r = runPush(&env, &.{});
    try t.expectEqual(@as(u8, 0), r.code);
    // Five requests: the head commit, one blob, a tree, a commit, the ref.
    try t.expectEqual(@as(usize, 5), env.fake.log.items.len);
    const log = env.fake.log.items;
    try t.expectEqual(@import("autopin_api.zig").Method.GET, log[0].method);
    try t.expectEqualStrings("repos/" ++ fx.repo ++ "/git/commits/" ++ fx.head, log[0].key);
    try t.expectEqualStrings("repos/" ++ fx.repo ++ "/git/blobs", log[1].key);
    try t.expectEqualStrings("repos/" ++ fx.repo ++ "/git/trees", log[2].key);
    try t.expectEqualStrings("repos/" ++ fx.repo ++ "/git/commits", log[3].key);
    try t.expectEqualStrings(ref_key, log[4].key);
    // base64 of "TABLE BYTES\n"
    try t.expectEqualStrings("{\"content\":\"VEFCTEUgQllURVMK\",\"encoding\":\"base64\"}", log[1].body.?);
    try t.expectEqualStrings("{\"base_tree\":\"" ++ fx.tree ++ "\",\"tree\":[{\"path\":\"site/buildrules.lock.bzl\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"" ++ blob_sha ++ "\"}]}", log[2].body.?);
    try t.expectEqualStrings("{\"sha\":\"" ++ commit_sha ++ "\",\"force\":false}", log[4].body.?);
    try t.expect(kit.contains(r.out, "committed 1 table(s)"));
}

test "push: the commit's parent is the head commit, its author and committer are the App's bot, and its message carries the skip marker" {
    var env = try setup();
    defer finish(&env);
    _ = runPush(&env, &.{});
    const body = env.fake.bodyOf(.POST, "repos/" ++ fx.repo ++ "/git/commits").?;
    try t.expect(kit.contains(body, "\"parents\":[\"" ++ fx.head ++ "\"]"));
    try t.expect(kit.contains(body, "\"tree\":\"" ++ tree_sha ++ "\""));
    try t.expect(kit.contains(body, "\"author\":{\"name\":\"" ++ name ++ "\",\"email\":\"" ++ email ++ "\"}"));
    try t.expect(kit.contains(body, "\"committer\":{\"name\":\"" ++ name ++ "\",\"email\":\"" ++ email ++ "\"}"));
    try t.expect(kit.contains(body, "[dependabot skip]"));
    try t.expect(kit.contains(body, "autopin: regenerate pin tables"));
}

test "push: every ref update says force false, whatever else happens" {
    var env = try setup();
    defer finish(&env);
    _ = runPush(&env, &.{});
    for (env.fake.log.items) |l| if (l.method == .PATCH) try t.expect(kit.contains(l.body.?, "\"force\":false") and !kit.contains(l.body.?, "\"force\":true"));
    try t.expectEqual(@as(usize, 1), env.fake.count(.PATCH));
}

test "push: two files make two blobs and two tree entries, in the plan's order" {
    var env = try setup();
    defer finish(&env);
    try writePlan(env.h, &.{ "infra/pins.lock.bzl", "site/buildrules.lock.bzl" });
    try env.h.put("plan/infra/pins.lock.bzl", "PINS BYTES\n");
    const r = runPush(&env, &.{});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqual(@as(usize, 2), env.fake.count(.POST) - 2);
    const tree_body = env.fake.bodyOf(.POST, "repos/" ++ fx.repo ++ "/git/trees").?;
    const first = std.mem.indexOf(u8, tree_body, "infra/pins.lock.bzl").?;
    const second = std.mem.indexOf(u8, tree_body, "site/buildrules.lock.bzl").?;
    try t.expect(first < second);
}

test "push: an update that is not a fast forward, as GitHub words it, is a clean skip" {
    var env = try setup();
    defer finish(&env);
    env.fake.put(.PATCH, ref_key, 422, "{\"message\":\"Update is not a fast forward\",\"documentation_url\":\"x\"}");
    const r = runPush(&env, &.{});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, "the branch moved since the check"));
}

test "push: a 422 with another message (a ruleset that wants a pull request) fails" {
    var env = try setup();
    defer finish(&env);
    env.fake.put(.PATCH, ref_key, 422, "{\"message\":\"Changes must be made through a pull request.\"}");
    const r = runPush(&env, &.{});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "could not be updated"));
}

test "push: a 422 about signed commits fails" {
    var env = try setup();
    defer finish(&env);
    env.fake.put(.PATCH, ref_key, 422, "{\"message\":\"Commits must have verified signatures.\"}");
    try t.expectEqual(@as(u8, 1), runPush(&env, &.{}).code);
}

test "push: a 422 whose body is not JSON fails" {
    var env = try setup();
    defer finish(&env);
    env.fake.put(.PATCH, ref_key, 422, "not json");
    try t.expectEqual(@as(u8, 1), runPush(&env, &.{}).code);
}

test "push: a 403 fails" {
    var env = try setup();
    defer finish(&env);
    env.fake.put(.PATCH, ref_key, 403, "{\"message\":\"Resource not accessible by integration\"}");
    try t.expectEqual(@as(u8, 1), runPush(&env, &.{}).code);
}

test "push: a 404 fails" {
    var env = try setup();
    defer finish(&env);
    env.fake.put(.PATCH, ref_key, 404, "{\"message\":\"Reference does not exist\"}");
    try t.expectEqual(@as(u8, 1), runPush(&env, &.{}).code);
}

test "push: a failing blob, tree or commit call fails before the ref is touched" {
    var env = try setup();
    defer finish(&env);
    env.fake.put(.POST, "repos/" ++ fx.repo ++ "/git/blobs", 403, "{}");
    try t.expectEqual(@as(u8, 1), runPush(&env, &.{}).code);
    try t.expectEqual(@as(usize, 0), env.fake.count(.PATCH));
    env.fake.put(.POST, "repos/" ++ fx.repo ++ "/git/blobs", 201, "{\"sha\":\"" ++ blob_sha ++ "\"}");
    env.fake.put(.POST, "repos/" ++ fx.repo ++ "/git/trees", 500, "{}");
    try t.expectEqual(@as(u8, 1), runPush(&env, &.{}).code);
    env.fake.put(.POST, "repos/" ++ fx.repo ++ "/git/trees", 201, "{\"sha\":\"" ++ tree_sha ++ "\"}");
    env.fake.put(.POST, "repos/" ++ fx.repo ++ "/git/commits", 422, "{}");
    try t.expectEqual(@as(u8, 1), runPush(&env, &.{}).code);
    try t.expectEqual(@as(usize, 0), env.fake.count(.PATCH));
}

test "push: an answer without a sha, with a malformed sha, or that is not JSON fails" {
    var env = try setup();
    defer finish(&env);
    const bad = [_][]const u8{ "{}", "{\"sha\":\"nope\"}", "not json" };
    for (bad) |b| {
        env.fake.put(.POST, "repos/" ++ fx.repo ++ "/git/blobs", 201, b);
        try t.expectEqual(@as(u8, 1), runPush(&env, &.{}).code);
    }
    try t.expectEqual(@as(usize, 0), env.fake.count(.PATCH));
}

test "push: a head commit that cannot be read, or has no tree, fails before anything is written" {
    var env = try setup();
    defer finish(&env);
    env.fake.put(.GET, "repos/" ++ fx.repo ++ "/git/commits/" ++ fx.head, 404, "{}");
    try t.expectEqual(@as(u8, 1), runPush(&env, &.{}).code);
    env.fake.put(.GET, "repos/" ++ fx.repo ++ "/git/commits/" ++ fx.head, 200, "{\"sha\":\"x\"}");
    try t.expectEqual(@as(u8, 1), runPush(&env, &.{}).code);
    env.fake.put(.GET, "repos/" ++ fx.repo ++ "/git/commits/" ++ fx.head, 200, "{\"tree\":{\"sha\":\"nope\"}}");
    try t.expectEqual(@as(u8, 1), runPush(&env, &.{}).code);
    try t.expectEqual(@as(usize, 0), env.fake.count(.POST) + env.fake.count(.PATCH));
}

test "push: a plan with no files makes no request at all" {
    var env = try setup();
    defer finish(&env);
    try writePlan(env.h, &.{});
    const r = runPush(&env, &.{});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqual(@as(usize, 0), env.fake.log.items.len);
    try t.expect(kit.contains(r.out, "nothing to commit"));
}

fn expectPlanRefused(env: *Env, text: []const u8) !void {
    try env.h.put("plan/plan.json", text);
    const r = runPush(env, &.{});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "the plan is not acceptable"));
    try t.expectEqual(@as(usize, 0), env.fake.log.items.len);
}

test "push: a plan with a file outside SETS is refused before any request" {
    var env = try setup();
    defer finish(&env);
    try expectPlanRefused(&env, "{\"repo\":\"" ++ fx.repo ++ "\",\"pr\":7,\"head_sha\":\"" ++ fx.head ++ "\",\"branch\":\"" ++ fx.branch ++ "\",\"files\":[\"site/BUCK\"]}");
    try expectPlanRefused(&env, "{\"repo\":\"" ++ fx.repo ++ "\",\"pr\":7,\"head_sha\":\"" ++ fx.head ++ "\",\"branch\":\"" ++ fx.branch ++ "\",\"files\":[\"../site/buildrules.lock.bzl\"]}");
}

test "push: a plan with a file under .github is refused before any request" {
    var env = try setup();
    defer finish(&env);
    try expectPlanRefused(&env, "{\"repo\":\"" ++ fx.repo ++ "\",\"pr\":7,\"head_sha\":\"" ++ fx.head ++ "\",\"branch\":\"" ++ fx.branch ++ "\",\"files\":[\".github/workflows/x.yml\"]}");
}

test "push: a plan with the same file twice is refused" {
    var env = try setup();
    defer finish(&env);
    try expectPlanRefused(&env, "{\"repo\":\"" ++ fx.repo ++ "\",\"pr\":7,\"head_sha\":\"" ++ fx.head ++ "\",\"branch\":\"" ++ fx.branch ++ "\",\"files\":[\"site/buildrules.lock.bzl\",\"site/buildrules.lock.bzl\"]}");
}


test "push: a plan with a branch that is not a Dependabot npm branch is refused" {
    var env = try setup();
    defer finish(&env);
    try expectPlanRefused(&env, "{\"repo\":\"" ++ fx.repo ++ "\",\"pr\":7,\"head_sha\":\"" ++ fx.head ++ "\",\"branch\":\"main\",\"files\":[]}");
    try expectPlanRefused(&env, "{\"repo\":\"" ++ fx.repo ++ "\",\"pr\":7,\"head_sha\":\"" ++ fx.head ++ "\",\"branch\":\"dependabot/npm_and_yarn/../../main\",\"files\":[]}");
}

test "push: a plan whose repository is not a plain owner/name is refused" {
    var env = try setup();
    defer finish(&env);
    try expectPlanRefused(&env, "{\"repo\":\"not a repo\",\"pr\":7,\"head_sha\":\"" ++ fx.head ++ "\",\"branch\":\"" ++ fx.branch ++ "\",\"files\":[]}");
}

test "push: a plan whose head sha is not 40 hex digits is refused" {
    var env = try setup();
    defer finish(&env);
    try expectPlanRefused(&env, "{\"repo\":\"" ++ fx.repo ++ "\",\"pr\":7,\"head_sha\":\"abc\",\"branch\":\"" ++ fx.branch ++ "\",\"files\":[]}");
}

test "push: a plan whose pr is not an integer in range is refused" {
    var env = try setup();
    defer finish(&env);
    try expectPlanRefused(&env, "{\"repo\":\"" ++ fx.repo ++ "\",\"pr\":\"7\",\"head_sha\":\"" ++ fx.head ++ "\",\"branch\":\"" ++ fx.branch ++ "\",\"files\":[]}");
    try expectPlanRefused(&env, "{\"repo\":\"" ++ fx.repo ++ "\",\"pr\":0,\"head_sha\":\"" ++ fx.head ++ "\",\"branch\":\"" ++ fx.branch ++ "\",\"files\":[]}");
}

test "push: a plan with a key it does not know is refused" {
    var env = try setup();
    defer finish(&env);
    try expectPlanRefused(&env, "{\"repo\":\"" ++ fx.repo ++ "\",\"pr\":7,\"head_sha\":\"" ++ fx.head ++ "\",\"branch\":\"" ++ fx.branch ++ "\",\"files\":[],\"force\":true}");
}

test "push: a plan with a key twice, or that is not JSON, is refused" {
    var env = try setup();
    defer finish(&env);
    try expectPlanRefused(&env, "{\"repo\":\"" ++ fx.repo ++ "\",\"pr\":7,\"pr\":8,\"head_sha\":\"" ++ fx.head ++ "\",\"branch\":\"" ++ fx.branch ++ "\",\"files\":[]}");
    try expectPlanRefused(&env, "not json at all");
}

test "push: a plan with more than eleven files is refused" {
    var env = try setup();
    defer finish(&env);
    var list = std.ArrayList(u8).empty;
    for (0..12) |i| try list.print(env.h.a(), "{s}\"site/f{d}\"", .{ if (i == 0) "" else ",", i });
    try expectPlanRefused(&env, try std.fmt.allocPrint(env.h.a(), "{{\"repo\":\"{s}\",\"pr\":7,\"head_sha\":\"{s}\",\"branch\":\"{s}\",\"files\":[{s}]}}", .{ fx.repo, fx.head, fx.branch, list.items }));
}

test "push: a table file that is missing, empty or over the size cap fails before any write" {
    var env = try setup();
    defer finish(&env);
    try env.h.put("plan/site/buildrules.lock.bzl", "");
    try t.expectEqual(@as(u8, 1), runPush(&env, &.{}).code);
    try env.h.put("plan/site/buildrules.lock.bzl", "x" ** (push.max_file_bytes + 1));
    try t.expectEqual(@as(u8, 1), runPush(&env, &.{}).code);
    env.h.tmp.dir.deleteFile("plan/site/buildrules.lock.bzl") catch {};
    try t.expectEqual(@as(u8, 1), runPush(&env, &.{}).code);
    try t.expectEqual(@as(usize, 0), env.fake.log.items.len);
}

test "push: the bot identity must be an App's: name[bot] and id+name[bot]@users.noreply.github.com" {
    try t.expect(push.identityOk("autopin-app[bot]", "123+autopin-app[bot]@users.noreply.github.com"));
    try t.expect(!push.identityOk("autopin-app", "123+autopin-app" ++ "@users.noreply.github.com"));
    try t.expect(!push.identityOk("autopin-app[bot]", "autopin-app[bot]@users.noreply.github.com"));
    try t.expect(!push.identityOk("autopin-app[bot]", "123+other[bot]@users.noreply.github.com"));
    try t.expect(!push.identityOk("autopin-app[bot]", "123+autopin-app[bot]@example.com"));
    try t.expect(!push.identityOk("autopin-app[bot]", "12a+autopin-app[bot]@users.noreply.github.com"));
    try t.expect(!push.identityOk("[bot]", "1+[bot]@users.noreply.github.com"));
    try t.expect(!push.identityOk("a\"b[bot]", "1+a\"b[bot]@users.noreply.github.com"));
    try t.expect(!push.identityOk("autopin-app[bot]", "+autopin-app[bot]@users.noreply.github.com"));
}

test "push: usage errors exit 2, and an identity that is not a bot's is refused before any request" {
    var env = try setup();
    defer finish(&env);
    autopin.api_override = env.fake.api();
    const cases = [_][]const []const u8{
        &.{ "autopin", "commit-push", "--set", "site=pins-lock", "--author-name", name, "--author-email", email },
        &.{ "autopin", "commit-push", "--plan", "plan", "--author-name", name, "--author-email", email },
        &.{ "autopin", "commit-push", "--plan", "plan", "--set", "site=pins-lock", "--author-email", email },
        &.{ "autopin", "commit-push", "--plan", "plan", "--set", "site=pins-lock", "--author-name", name },
        &.{ "autopin", "commit-push", "--bogus" },
        &.{ "autopin", "commit-push", "--plan" },
        &.{ "autopin", "commit-push", "--plan", "plan", "--set", "x=other", "--author-name", name, "--author-email", email },
        &.{ "autopin", "commit-push", "--plan", "plan", "--set", "site=pins-lock", "--author-name", "mallory", "--author-email", "mallory" ++ "@example.com" },
    };
    for (cases) |argv| try t.expectEqual(@as(u8, 2), env.h.run(argv).code);
    try t.expectEqual(@as(usize, 0), env.fake.log.items.len);
    const help = env.h.run(&.{ "autopin", "commit-push", "-h" });
    try t.expectEqual(@as(u8, 0), help.code);
    try t.expect(kit.contains(help.out, "--author-email EMAIL"));
    const top = env.h.run(&.{ "autopin", "bogus" });
    try t.expectEqual(@as(u8, 2), top.code);
}

test "push: a plan that cannot be read fails" {
    var env = try setup();
    defer finish(&env);
    env.h.tmp.dir.deleteFile("plan/plan.json") catch {};
    try t.expectEqual(@as(u8, 1), runPush(&env, &.{}).code);
}

test "push: a plan file under .github is refused even when a SETS directory is named so" {
    var env = try setup();
    defer finish(&env);
    try writePlan(env.h, &.{".github/x/pins.lock.bzl"});
    try env.h.put("plan/.github/x/pins.lock.bzl", "x\n");
    const r = runPush(&env, &.{ "--set", ".github/x=pins-lock" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "the plan is not acceptable"));
    try t.expectEqual(@as(usize, 0), env.fake.log.items.len);
}
