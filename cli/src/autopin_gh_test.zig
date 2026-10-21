//! The API helpers `autopin` leans on: the shapes a name must have, the raw read at a commit, the package.json guard,
//! and the `workflow_run` event. Every test is named for the defect it catches.

const std = @import("std");
const api_mod = @import("autopin_api.zig");
const event_mod = @import("autopin_event.zig");
const fx = @import("autopin_fixture_test.zig");
const gh = @import("autopin_gh.zig");
const t = std.testing;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

test "shapes: sha1, repository, branch names" {
    try t.expect(gh.isSha1("0123456789abcdef0123456789abcdef01234567"));
    try t.expect(!gh.isSha1("0123456789ABCDEF0123456789abcdef01234567"));
    try t.expect(!gh.isSha1("abc"));
    try t.expect(gh.isRepo("acme/widgets"));
    try t.expect(gh.isRepo("a.b/c_d-e"));
    try t.expect(!gh.isRepo("noslash"));
    try t.expect(!gh.isRepo("a/b/c"));
    try t.expect(!gh.isRepo("a b/c"));
    try t.expect(!gh.isRepo("/c"));
    try t.expect(!gh.isRepo("a/"));
    try t.expect(gh.isBranchName("main"));
    try t.expect(gh.isBranchName("release/1.2"));
    try t.expect(!gh.isBranchName(""));
    try t.expect(!gh.isBranchName("a..b"));
    try t.expect(!gh.isBranchName("a//b"));
    try t.expect(!gh.isBranchName("a b"));
}

test "dependabot branches: the prefix and the segments, nothing that climbs or ends oddly" {
    try t.expect(gh.isDependabotBranch("dependabot/npm_and_yarn/site/left-pad-1.3.1"));
    try t.expect(gh.isDependabotBranch("dependabot/npm_and_yarn/@scope/pkg-2.0.0"));
    try t.expect(!gh.isDependabotBranch("main"));
    try t.expect(!gh.isDependabotBranch("dependabot/cargo/x"));
    try t.expect(!gh.isDependabotBranch("dependabot/npm_and_yarn/"));
    try t.expect(!gh.isDependabotBranch("dependabot/npm_and_yarn/a/../b"));
    try t.expect(!gh.isDependabotBranch("dependabot/npm_and_yarn/a//b"));
    try t.expect(!gh.isDependabotBranch("dependabot/npm_and_yarn/a/"));
    try t.expect(!gh.isDependabotBranch("dependabot/npm_and_yarn/a."));
    try t.expect(!gh.isDependabotBranch("dependabot/npm_and_yarn/a b"));
    try t.expect(!gh.isDependabotBranch("dependabot/npm_and_yarn/a;b"));
}

test "the git blob id of bytes is sha1 of the header and the bytes" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", try gh.blobSha1(a, ""));
    try t.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", try gh.blobSha1(a, "hello\n"));
}

test "oneLine: control bytes, newlines above all, become question marks" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("a?::b?c?d", try gh.oneLine(a, "a\n::b\rc\x7fd"));
    try t.expectEqualStrings("plain/path.txt", try gh.oneLine(a, "plain/path.txt"));
}

fn same(base: []const u8, head: []const u8) !bool {
    var ar = arena();
    defer ar.deinit();
    return gh.sameOutsideDependencies(ar.allocator(), base, head);
}

test "package.json guard: only the dependency maps may differ" {
    try t.expect(try same("{\"name\":\"a\",\"dependencies\":{\"x\":\"1\"}}", "{\"name\":\"a\",\"dependencies\":{\"x\":\"2\"}}"));
    try t.expect(try same("{\"name\":\"a\"}", "{\"name\":\"a\",\"devDependencies\":{\"x\":\"2\"},\"optionalDependencies\":{}}"));
    try t.expect(try same("{\"name\":\"a\",\"scripts\":{\"t\":\"x\"},\"dependencies\":{}}", "{\"dependencies\":{\"y\":\"1\"},\"scripts\":{\"t\":\"x\"},\"name\":\"a\"}"));
    try t.expect(!try same("{\"name\":\"a\",\"scripts\":{\"t\":\"x\"}}", "{\"name\":\"a\",\"scripts\":{\"t\":\"y\"}}"));
    try t.expect(!try same("{\"name\":\"a\",\"scripts\":{\"t\":\"x\"}}", "{\"name\":\"a\",\"scripts\":{\"t\":\"x\",\"u\":\"z\"}}"));
    try t.expect(!try same("{\"name\":\"a\"}", "{\"name\":\"b\"}"));
    try t.expect(!try same("{\"name\":\"a\",\"version\":\"1\"}", "{\"name\":\"a\"}"));
    try t.expect(!try same("{\"name\":\"a\"}", "{\"name\":\"a\",\"buildrules\":{}}"));
    try t.expect(!try same("{\"name\":\"a\",\"files\":[\"x\"]}", "{\"name\":\"a\",\"files\":[\"y\"]}"));
    try t.expect(!try same("{\"n\":1}", "{\"n\":2}"));
    try t.expect(!try same("{\"n\":1.5}", "{\"n\":1.25}"));
    try t.expect(!try same("{\"n\":true}", "{\"n\":false}"));
    try t.expect(try same("{\"n\":null,\"b\":true,\"f\":1.5,\"i\":3,\"a\":[1,\"x\"]}", "{\"n\":null,\"b\":true,\"f\":1.5,\"i\":3,\"a\":[1,\"x\"]}"));
    try t.expect(!try same("{\"n\":[1,2]}", "{\"n\":[1]}"));
    try t.expect(!try same("{\"n\":{\"a\":1}}", "{\"n\":{\"b\":1}}"));
    try t.expect(!try same("{\"n\":1}", "{\"n\":\"1\"}"));
    try t.expect(!try same("not json", "{}"));
    try t.expect(!try same("{}", "[]"));
}

const key = "repos/o/r/contents/f.txt?ref=" ++ "1" ** 40;

test "readFile: the bytes are believed only when length and blob hash agree with the metadata" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var f = fx.Fake{ .a = a };
    const bytes = "hello\n";
    f.putAccept(.GET, key, api_mod.json_accept, 200, "{\"type\":\"file\",\"sha\":\"ce013625030ba8dba906f756967f9e9ca394464a\",\"size\":6,\"content\":\"\"}");
    f.putAccept(.GET, key, api_mod.raw_accept, 200, bytes);
    const got = (try gh.readFile(a, f.api(), "o/r", "f.txt", "1" ** 40)).?;
    try t.expectEqualStrings(bytes, got.bytes);
    // The raw request carried the raw media type, and the JSON request did not.
    try t.expectEqualStrings(api_mod.json_accept, f.log.items[0].accept);
    try t.expectEqualStrings(api_mod.raw_accept, f.log.items[1].accept);
}

test "readFile: a 404 is no file, other statuses are errors" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var f = fx.Fake{ .a = a };
    f.putAccept(.GET, key, api_mod.json_accept, 404, "{}");
    try t.expect((try gh.readFile(a, f.api(), "o/r", "f.txt", "1" ** 40)) == null);
    f.putAccept(.GET, key, api_mod.json_accept, 500, "{}");
    try t.expectError(error.Unreadable, gh.readFile(a, f.api(), "o/r", "f.txt", "1" ** 40));
    f.putAccept(.GET, key, api_mod.json_accept, 200, "");
    try t.expectError(error.Unreadable, gh.readFile(a, f.api(), "o/r", "f.txt", "1" ** 40));
}

test "readFile: metadata that is malformed is refused (no sha, a bad sha, no size, a size over the cap, not JSON)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var f = fx.Fake{ .a = a };
    f.putAccept(.GET, key, api_mod.raw_accept, 200, "hello\n");
    const bad = [_][]const u8{
        "{\"type\":\"file\",\"size\":6}",
        "{\"type\":\"file\",\"sha\":\"zz\",\"size\":6}",
        "{\"type\":\"file\",\"sha\":\"ce013625030ba8dba906f756967f9e9ca394464a\"}",
        "{\"type\":\"file\",\"sha\":\"ce013625030ba8dba906f756967f9e9ca394464a\",\"size\":99999999}",
        "{\"type\":\"file\",\"sha\":\"ce013625030ba8dba906f756967f9e9ca394464a\",\"size\":-1}",
    };
    for (bad) |b| {
        f.putAccept(.GET, key, api_mod.json_accept, 200, b);
        try t.expectError(error.BadJson, gh.readFile(a, f.api(), "o/r", "f.txt", "1" ** 40));
    }
    f.putAccept(.GET, key, api_mod.json_accept, 200, "<html>");
    try t.expectError(error.BadJson, gh.readFile(a, f.api(), "o/r", "f.txt", "1" ** 40));
}

test "readFile: a directory or a symlink is not a file; a raw answer that is not 200 is an error" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var f = fx.Fake{ .a = a };
    f.putAccept(.GET, key, api_mod.json_accept, 200, "{\"type\":\"dir\"}");
    try t.expectError(error.NotAFile, gh.readFile(a, f.api(), "o/r", "f.txt", "1" ** 40));
    f.putAccept(.GET, key, api_mod.json_accept, 200, "{\"type\":\"file\",\"sha\":\"ce013625030ba8dba906f756967f9e9ca394464a\",\"size\":6}");
    f.putAccept(.GET, key, api_mod.raw_accept, 502, "");
    try t.expectError(error.Unreadable, gh.readFile(a, f.api(), "o/r", "f.txt", "1" ** 40));
}

fn ev(a: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
    const good = try fx.eventJson(a, 3, fx.head);
    if (from.len == 0) return good;
    try t.expect(std.mem.indexOf(u8, good, from) != null);
    return std.mem.replaceOwned(u8, a, good, from, to);
}

fn refusedWith(text: []const u8, why: []const u8) !void {
    var ar = arena();
    defer ar.deinit();
    var reason: ?[]const u8 = null;
    try t.expectError(error.Refused, event_mod.parse(ar.allocator(), text, &reason));
    try t.expect(std.mem.indexOf(u8, reason.?, why) != null);
}

test "event: the compute run's own event is read, with its attempt and the pull requests it belongs to" {
    var ar = arena();
    defer ar.deinit();
    var why: ?[]const u8 = null;
    const e = try event_mod.parse(ar.allocator(), try ev(ar.allocator(), "", ""), &why);
    try t.expectEqualStrings(fx.repo, e.repo);
    try t.expectEqual(@as(i64, 42), e.repo_id);
    try t.expectEqual(@as(i64, 1001), e.run_id);
    try t.expectEqual(@as(i64, 3), e.run_attempt);
    try t.expectEqualStrings(fx.head, e.head_sha);
    try t.expectEqual(@as(usize, 1), e.pull_requests.len);
    try t.expectEqual(@as(i64, 7), e.pull_requests[0]);
}

test "event: a run that did not succeed is refused" {
    var ar = arena();
    defer ar.deinit();
    try refusedWith(try ev(ar.allocator(), "\"conclusion\":\"success\"", "\"conclusion\":\"cancelled\""), "did not succeed");
}

test "event: a run started by something other than a pull_request event is refused" {
    var ar = arena();
    defer ar.deinit();
    try refusedWith(try ev(ar.allocator(), "\"event\":\"pull_request\"", "\"event\":\"pull_request_target\""), "pull_request event");
}

test "event: a run of another workflow file is refused" {
    var ar = arena();
    defer ar.deinit();
    try refusedWith(try ev(ar.allocator(), ".github/workflows/autopin-compute.yml", ".github/workflows/autopin-compute.yml.evil"), "compute workflow file");
}

test "event: a run whose repository id is another is refused (a fork)" {
    var ar = arena();
    defer ar.deinit();
    try refusedWith(try ev(ar.allocator(), "\"head_repository\":{\"id\":42", "\"head_repository\":{\"id\":43"), "fork");
}

test "event: a run whose repository name is another is refused (a fork)" {
    var ar = arena();
    defer ar.deinit();
    try refusedWith(try ev(ar.allocator(), "\"full_name\":\"acme/demo\"},\"actor\"", "\"full_name\":\"mallory/demo\"},\"actor\""), "fork");
}

test "event: a run whose actor is not Dependabot is refused" {
    var ar = arena();
    defer ar.deinit();
    try refusedWith(try ev(ar.allocator(), "\"actor\":{\"login\":\"dependabot[bot]\"}", "\"actor\":{\"login\":\"dependabot-preview[bot]\"}"), "actor is not Dependabot");
}

test "event: a run whose triggering actor is not Dependabot is refused (a re-run by a person)" {
    var ar = arena();
    defer ar.deinit();
    try refusedWith(try ev(ar.allocator(), "\"triggering_actor\":{\"login\":\"dependabot[bot]\"}", "\"triggering_actor\":{\"login\":\"alice\"}"), "triggering actor");
}

test "event: missing or malformed fields are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try refusedWith("not json", "not JSON");
    try refusedWith("{}", "no workflow_run");
    try refusedWith(try ev(a, "\"run_attempt\":3", "\"run_attempt\":0"), "malformed");
    try refusedWith(try ev(a, "\"id\":1001", "\"id\":-5"), "malformed");
    try refusedWith(try ev(a, fx.head, "short"), "malformed");
    try refusedWith(try ev(a, "\"pull_requests\":[{\"number\":7}]", "\"pull_requests\":{}"), "not a list");
    try refusedWith(try ev(a, "\"pull_requests\":[{\"number\":7}]", "\"pull_requests\":[{}]"), "no number");
    try refusedWith(try ev(a, "\"repository\":{\"full_name\":\"acme/demo\",\"id\":42}", "\"repository\":{\"id\":42}"), "no repository");
    try refusedWith(try ev(a, "\"repository\":{\"full_name\":\"acme/demo\",\"id\":42}", "\"repository\":{\"full_name\":\"acme/demo\"}"), "repository id");
    try refusedWith(try ev(a, "\"repository\":{\"full_name\":\"acme/demo\",\"id\":42}", "\"repository\":{\"full_name\":\"a b\",\"id\":42}"), "plain owner/name");
}

test "dependabot branches: a percent sign, a question mark and a hash are not branch characters (each could rewrite a URL)" {
    try t.expect(!gh.isDependabotBranch("dependabot/npm_and_yarn/a%2e%2e/b"));
    try t.expect(!gh.isDependabotBranch("dependabot/npm_and_yarn/a%"));
    try t.expect(!gh.isDependabotBranch("dependabot/npm_and_yarn/a?x"));
    try t.expect(!gh.isDependabotBranch("dependabot/npm_and_yarn/a#frag"));
    try t.expect(!gh.isDependabotBranch("dependabot/npm_and_yarn/a\\b"));
    try t.expect(!gh.isDependabotBranch("dependabot/npm_and_yarn/a:b"));
    try t.expect(!gh.isDependabotBranch("dependabot/npm_and_yarn/a+b"));
    try t.expect(!gh.isDependabotBranch("dependabot/npm_and_yarn/a~b"));
    // What the real names hold stays accepted.
    try t.expect(gh.isDependabotBranch("dependabot/npm_and_yarn/@types/node-22.1.0"));
}

test "package.json guard: a changed overrides map is not a dependency bump" {
    try t.expect(!try same("{\"name\":\"a\",\"overrides\":{\"x\":\"1\"}}", "{\"name\":\"a\",\"overrides\":{\"x\":\"2\"}}"));
    try t.expect(!try same("{\"name\":\"a\"}", "{\"name\":\"a\",\"overrides\":{\"x\":\"2\"}}"));
}

test "package.json guard: a changed resolutions map is not a dependency bump" {
    try t.expect(!try same("{\"name\":\"a\",\"resolutions\":{\"x\":\"1\"}}", "{\"name\":\"a\",\"resolutions\":{\"x\":\"2\"}}"));
    try t.expect(!try same("{\"name\":\"a\"}", "{\"name\":\"a\",\"resolutions\":{\"x\":\"2\"}}"));
}

test "package.json guard: a changed bin map (it runs on install) is not a dependency bump" {
    try t.expect(!try same("{\"name\":\"a\",\"bin\":{\"x\":\"a.js\"}}", "{\"name\":\"a\",\"bin\":{\"x\":\"evil.js\"}}"));
    try t.expect(!try same("{\"name\":\"a\"}", "{\"name\":\"a\",\"bin\":{\"x\":\"evil.js\"}}"));
}

test "package.json guard: a changed peerDependencies map is not a dependency bump" {
    try t.expect(!try same("{\"name\":\"a\",\"peerDependencies\":{\"x\":\"1\"}}", "{\"name\":\"a\",\"peerDependencies\":{\"x\":\"2\"}}"));
    try t.expect(!try same("{\"name\":\"a\"}", "{\"name\":\"a\",\"peerDependencies\":{\"x\":\"2\"}}"));
}

test "package.json guard: numbers beyond a 64-bit integer are compared by their digits" {
    try t.expect(try same("{\"n\":123456789012345678901234567890}", "{\"n\":123456789012345678901234567890}"));
    try t.expect(!try same("{\"n\":123456789012345678901234567890}", "{\"n\":123456789012345678901234567891}"));
}

test "event: a field renamed away, one at a time, is a refusal (each read has its own message)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const cases = [_][2][]const u8{
        .{ "\"conclusion\"", "no success" },
        .{ "\"event\"", "pull_request event" },
        .{ "\"path\"", "workflow file" },
        .{ "\"head_repository\"", "another repository" },
        .{ "\"actor\"", "actor is not Dependabot" },
        .{ "\"triggering_actor\"", "triggering actor" },
        .{ "\"id\":1001", "no id" },
        .{ "\"run_attempt\"", "no run_attempt" },
        .{ "\"head_sha\"", "malformed" },
        .{ "\"pull_requests\"", "no pull requests" },
    };
    for (cases) |c| {
        const renamed = try std.mem.concat(a, u8, &.{ c[0][0 .. c[0].len - 1], "X\"" });
        const from = if (std.mem.indexOf(u8, c[0], ":") != null) c[0] else c[0];
        const to = if (std.mem.indexOf(u8, c[0], ":") != null) "\"idX\":1001" else renamed;
        var why: ?[]const u8 = null;
        try t.expectError(error.Refused, event_mod.parse(a, try ev(a, from, to), &why));
        try t.expect(why != null);
    }
}

test "gh: typed reads answer null for a value of another kind, a sha1 is lower-case hex only, a bot login has no odd characters" {
    try t.expect(gh.str(.{ .integer = 1 }) == null);
    try t.expect(gh.str(null) == null);
    try t.expect(gh.int(.{ .string = "1" }) == null);
    try t.expect(gh.int(null) == null);
    try t.expect(!gh.isSha1("g" ** 40));
    try t.expect(!gh.isSha1("A" ** 40));
    try t.expect(!gh.isBotLogin("a b[bot]"));
    try t.expect(!gh.isBotLogin("a_b[bot]"));
    try t.expect(!try same("[]", "{}"));
}
