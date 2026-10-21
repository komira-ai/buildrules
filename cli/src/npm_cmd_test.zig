//! `buildrules npm sync` and `buildrules npm check`. The network is replaced by a fake that serves
//! fixed digests, so each test says which fetches it expects. Every test is named for the defect it catches.

const std = @import("std");
const fetch = @import("fetch.zig");
const kit = @import("testkit.zig");
const npm = @import("npm_cmd.zig");
const t = std.testing;

const sri_a = "sha512-" ++ "A" ** 86 ++ "==";
const sri_b = "sha512-" ++ "B" ** 85 ++ "A==";
const sha_a = "a" ** 64;
const sha_b = "b" ** 64;

test "the fetcher the program starts with is the real one (the tests after this one replace it with a fake)" {
    original_fetcher = npm.fetcher;
}

const pkg_json =
    \\{"name":"demo","version":"1.0.0",
    \\ "scripts":{"typecheck":"tsc -p .","test":"jest","build":"tsc -p tsconfig.build.json"},
    \\ "buildrules":{"dist":"dist","actions":{"ci":["typecheck","test","build"]}}}
;

fn lockWith(h: *kit.Harness, sri_one: []const u8, extra: []const u8) ![]const u8 {
    return std.fmt.allocPrint(h.a(),
        \\{{"name":"demo","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{{
        \\ "":{{"name":"demo","version":"1.0.0"}},
        \\ "node_modules/left-pad":{{"version":"1.3.0","resolved":"https://registry.example/left-pad/-/left-pad-1.3.0.tgz","integrity":"{s}"}},
        \\ "node_modules/@scope/fsevents":{{"version":"2.0.0","resolved":"https://registry.example/@scope/fsevents/-/fsevents-2.0.0.tgz","integrity":"{s}","optional":true,"os":["darwin"]}}{s}
        \\}}}}
    , .{ sri_one, sri_b, extra });
}

var fetches: usize = 0;
var served_sri: []const u8 = sri_a;
var fetch_error: ?anyerror = null;
var original_fetcher: ?npm.Fetch = null;

fn fake(a: std.mem.Allocator, url: []const u8) anyerror!fetch.Digest.Result {
    _ = a;
    // A replay (testkit.zig) runs the command on a copy; only the run the test made is counted.
    if (!kit.replaying) fetches += 1;
    if (fetch_error) |e| return e;
    if (std.mem.indexOf(u8, url, "fsevents") != null) return .{ .sha256 = sha_b, .sri512 = sri_b, .size = 22 };
    return .{ .sha256 = sha_a, .sri512 = served_sri, .size = 11 };
}

fn fresh() !*kit.Harness {
    fetches = 0;
    served_sri = sri_a;
    fetch_error = null;
    npm.fetcher = &fake;
    const h = try kit.Harness.create();
    try h.put(".buckconfig", "[cells]\n");
    try h.put("pkg/package.json", pkg_json);
    try h.put("pkg/package-lock.json", try lockWith(h, sri_a, ""));
    return h;
}

fn synced() !*kit.Harness {
    const h = try fresh();
    const r = h.run(&.{ "npm", "sync", "pkg" });
    try t.expectEqual(@as(u8, 0), r.code);
    return h;
}

test "sync: writes the table, the glue and a BUCK file, pinning each tarball once" {
    const h = try fresh();
    defer h.destroy();
    const r = h.run(&.{ "npm", "sync", "pkg" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqual(@as(usize, 2), fetches);
    const table = h.read("pkg/buildrules.lock.bzl");
    try t.expect(kit.contains(table, "\"left-pad@1.3.0\": {"));
    try t.expect(kit.contains(table, "\"sha256\": \"" ++ sha_a ++ "\""));
    try t.expect(kit.contains(table, "\"size\": 11"));
    try t.expect(kit.contains(table, "\"sri512\": \"" ++ sri_a ++ "\""));
    try t.expect(kit.contains(table, "\"dist\": \"dist\""));
    try t.expect(kit.contains(table, "\"typecheck\": \"tsc -p .\""));
    try t.expect(kit.contains(h.read("pkg/BUCK"), "npm_package(path = \".\")"));
    try t.expect(kit.contains(h.read("pkg/buildrules.bzl"), "def npm_package(**kwargs)"));
}

test "sync: the platform lists of an optional package reach the table (so a build skips it on linux)" {
    const h = try synced();
    defer h.destroy();
    try t.expect(kit.contains(h.read("pkg/buildrules.lock.bzl"), "\"os\": [\"darwin\"]"));
}

test "sync: a second sync is a no-op and fetches nothing (the table is the memory)" {
    const h = try synced();
    defer h.destroy();
    const before = h.read("pkg/buildrules.lock.bzl");
    fetches = 0;
    const r = h.run(&.{ "npm", "sync", "pkg" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqual(@as(usize, 0), fetches);
    try t.expectEqualStrings(before, h.read("pkg/buildrules.lock.bzl"));
}

test "sync: tarball bytes whose sha512 is not the lockfile's are refused and nothing is written" {
    const h = try fresh();
    defer h.destroy();
    served_sri = sri_b;
    const r = h.run(&.{ "npm", "sync", "pkg" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "Nothing was pinned"));
    try t.expect(!h.has("pkg/buildrules.lock.bzl"));
}

test "sync: a version whose integrity changed is refused, and --accept-changed allows it" {
    const h = try synced();
    defer h.destroy();
    try h.put("pkg/package-lock.json", try lockWith(h, sri_b, ""));
    served_sri = sri_b;
    const bad = h.run(&.{ "npm", "sync", "pkg" });
    try t.expectEqual(@as(u8, 1), bad.code);
    try t.expect(kit.contains(bad.err, "the same version with other bytes"));
    try t.expect(kit.contains(h.read("pkg/buildrules.lock.bzl"), sri_a));
    const ok = h.run(&.{ "npm", "sync", "pkg", "--accept-changed" });
    try t.expectEqual(@as(u8, 0), ok.code);
    try t.expect(kit.contains(h.read("pkg/buildrules.lock.bzl"), "\"sri512\": \"" ++ sri_b ++ "\""));
}

test "sync: a seed with the same integrity avoids the download" {
    const h = try synced();
    defer h.destroy();
    const seed = h.read("pkg/buildrules.lock.bzl");
    try h.put("seed.bzl", seed);
    try h.put("pkg/buildrules.lock.bzl", "stale\n");
    fetches = 0;
    const r = h.run(&.{ "npm", "sync", "pkg", "--seed", "seed.bzl" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqual(@as(usize, 0), fetches);
    try t.expectEqualStrings(seed, h.read("pkg/buildrules.lock.bzl"));
}

test "sync: a sha1 integrity is refused (only sha512 pins a tarball)" {
    const h = try fresh();
    defer h.destroy();
    try h.put("pkg/package-lock.json", try lockWith(h, "sha1-AAAAAAAAAAAAAAAAAAAAAAAAAAA=", ""));
    const r = h.run(&.{ "npm", "sync", "pkg" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "sha1 and sha256 integrities are refused"));
}

test "sync: a git dependency (no integrity) is refused, not skipped" {
    const h = try fresh();
    defer h.destroy();
    try h.put("pkg/package-lock.json", try lockWith(h, sri_a,
        \\,
        \\ "node_modules/gitdep":{"version":"1.0.0","resolved":"git+ssh://example.invalid/x.git#abc"}
    ));
    const r = h.run(&.{ "npm", "sync", "pkg" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "gitdep"));
}

test "sync: lockfileVersion 2 is refused" {
    const h = try fresh();
    defer h.destroy();
    try h.put("pkg/package-lock.json", "{\"lockfileVersion\":2,\"packages\":{}}");
    const r = h.run(&.{ "npm", "sync", "pkg" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "lockfileVersion 3"));
}

test "sync: workspaces are refused with the gap named" {
    const h = try fresh();
    defer h.destroy();
    try h.put("pkg/package.json", "{\"name\":\"d\",\"workspaces\":[\"a\"]}");
    const r = h.run(&.{ "npm", "sync", "pkg" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "workspaces"));
}

test "sync: a policy key the tool does not know is refused (typos do not pass silently)" {
    const h = try fresh();
    defer h.destroy();
    try h.put("pkg/package.json", "{\"name\":\"d\",\"scripts\":{\"test\":\"jest\"},\"buildrules\":{\"distt\":\"dist\"}}");
    const r = h.run(&.{ "npm", "sync", "pkg" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "allowed: steps, actions, dist, default-action"));
}

test "sync: a step mapped to a script package.json lacks is refused" {
    const h = try fresh();
    defer h.destroy();
    try h.put("pkg/package.json", "{\"name\":\"d\",\"scripts\":{},\"buildrules\":{\"steps\":{\"test\":\"nope\"}}}");
    const r = h.run(&.{ "npm", "sync", "pkg" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "which package.json lacks"));
}

test "sync: an action named like a step is refused" {
    const h = try fresh();
    defer h.destroy();
    try h.put("pkg/package.json", "{\"name\":\"d\",\"scripts\":{\"test\":\"jest\"},\"buildrules\":{\"actions\":{\"test\":[\"test\"]}}}");
    const r = h.run(&.{ "npm", "sync", "pkg" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "buildrules.actions.test"));
}

test "check: a package as sync left it is in sync" {
    const h = try synced();
    defer h.destroy();
    const r = h.run(&.{ "npm", "check", "pkg" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, "pkg: in sync"));
}

test "check: a lockfile changed without a sync is stale (a new package, not in the table)" {
    const h = try synced();
    defer h.destroy();
    try h.put("pkg/package-lock.json", try lockWith(h, sri_a,
        \\,
        \\ "node_modules/extra":{"version":"1.0.0","resolved":"https://registry.example/extra/-/extra-1.0.0.tgz","integrity":"
    ++ sri_a ++
        \\"}
    ));
    fetches = 0;
    const r = h.run(&.{ "npm", "check", "pkg" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "extra@1.0.0 is in package-lock.json and not in the table"));
    try t.expectEqual(@as(usize, 0), fetches); // check never fetches
}

test "check: a lockfile edited in a way that changes no package is still stale (its hash is recorded)" {
    const h = try synced();
    defer h.destroy();
    const lk = h.read("pkg/package-lock.json");
    try h.put("pkg/package-lock.json", try std.mem.concat(h.a(), u8, &.{ lk, "\n" }));
    const r = h.run(&.{ "npm", "check", "pkg" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "is stale"));
}

test "check: a changed script is stale (the table holds the scripts the steps run)" {
    const h = try synced();
    defer h.destroy();
    try h.put("pkg/package.json", try std.mem.replaceOwned(u8, h.a(), pkg_json, "\"jest\"", "\"jest --bail\""));
    const r = h.run(&.{ "npm", "check", "pkg" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "buildrules.lock.bzl is stale"));
}

test "check: a hand-edited buildrules.bzl is flagged" {
    const h = try synced();
    defer h.destroy();
    try h.put("pkg/buildrules.bzl", "# mine\n");
    const r = h.run(&.{ "npm", "check", "pkg" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "buildrules.bzl is not what sync writes"));
}

test "check: finds every package that has a table when no path is named" {
    const h = try synced();
    defer h.destroy();
    const r = h.run(&.{ "npm", "check" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, "pkg: in sync"));
}

test "usage: no subcommand and an unknown one are exit 2" {
    const h = try fresh();
    defer h.destroy();
    try t.expectEqual(@as(u8, 2), h.run(&.{"npm"}).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "npm", "frob" }).code);
}


// ---- the real fetcher, the arguments, and finding packages ----------------------------------------------------------

test "the real fetcher refuses a URL that is not https before it opens a socket" {
    try t.expect(original_fetcher != null);
    try t.expectError(error.UrlNotAllowed, original_fetcher.?(t.allocator, "http://127.0.0.1:1/a.tgz"));
}

test "usage: a flag without its value, a flag of the other subcommand, and an unknown flag are exit 2" {
    const h = try fresh();
    defer h.destroy();
    const bad = [_][]const []const u8{
        &.{ "npm", "sync", "--dir" },
        &.{ "npm", "check", "--dir" },
        &.{ "npm", "sync", "pkg", "--seed" },
        &.{ "npm", "check", "pkg", "--seed", "x.bzl" },
        &.{ "npm", "check", "pkg", "--accept-changed" },
        &.{ "npm", "check", "pkg", "--check" },
        &.{ "npm", "sync", "pkg", "--frobnicate" },
    };
    for (bad) |argv| try t.expectEqual(@as(u8, 2), h.run(argv).code);
    try t.expect(kit.contains(h.run(&.{ "npm", "sync", "--dir" }).err, "--dir needs a value"));
    try t.expect(kit.contains(h.run(&.{ "npm", "sync", "pkg", "--seed" }).err, "--seed needs a value"));
    // --dir that is not a directory is a failure, not a usage error.
    const r = h.run(&.{ "npm", "sync", "--dir", "nowhere", "pkg" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "cannot open nowhere"));
}

test "sync --dir DIR works on the package under DIR, and sync --check writes nothing and says what is stale" {
    const h = try fresh();
    defer h.destroy();
    try h.put("repo/pkg/package.json", pkg_json);
    try h.put("repo/pkg/package-lock.json", try lockWith(h, sri_a, ""));
    const r = h.run(&.{ "npm", "sync", "--dir", "repo", "pkg" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(h.has("repo/pkg/buildrules.lock.bzl"));
    const fresh_dir = try fresh();
    defer fresh_dir.destroy();
    const stale = fresh_dir.run(&.{ "npm", "sync", "pkg", "--check" });
    try t.expectEqual(@as(u8, 1), stale.code);
    try t.expect(kit.contains(stale.err, "is in package-lock.json and not in the table"));
    try t.expect(!fresh_dir.has("pkg/buildrules.lock.bzl"));
    try t.expect(kit.contains(stale.err, "1 package(s) stale or refused"));
    const synced_dir = try synced();
    defer synced_dir.destroy();
    const same = synced_dir.run(&.{ "npm", "sync", "pkg", "--check" });
    try t.expectEqual(@as(u8, 0), same.code);
    try t.expect(kit.contains(same.out, "pkg: in sync"));
}

test "check finds the packages with a table under the directory: not past depth 8, not in dot or build directories, not a table written by hand" {
    const h = try synced();
    defer h.destroy();
    const lock = h.read("pkg/buildrules.lock.bzl");
    const pj = h.read("pkg/package.json");
    const lk = h.read("pkg/package-lock.json");
    for ([_][]const u8{ "a/b/c/d/e/f/g/h", ".hidden", "node_modules/dep", "buck-out/x", "a/b/c/d/e/f/g/h/i/j" }) |dir| {
        try h.put(try std.fmt.allocPrint(h.a(), "{s}/buildrules.lock.bzl", .{dir}), lock);
        try h.put(try std.fmt.allocPrint(h.a(), "{s}/package.json", .{dir}), pj);
        try h.put(try std.fmt.allocPrint(h.a(), "{s}/package-lock.json", .{dir}), lk);
    }
    // A table nobody generated is not a package this command owns.
    try h.put("by-hand/buildrules.lock.bzl", "SCHEMA = 1\n");
    const r = h.run(&.{ "npm", "check" });
    // Depth 8 is found, and it is stale there (no BUCK file, no glue): the others were never looked at.
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "a/b/c/d/e/f/g/h: "));
    try t.expect(!kit.contains(r.err, "a/b/c/d/e/f/g/h/i/j"));
    try t.expect(!kit.contains(r.err, ".hidden"));
    try t.expect(!kit.contains(r.err, "node_modules/dep"));
    try t.expect(!kit.contains(r.err, "buck-out"));
    try t.expect(!kit.contains(r.err, "by-hand"));
    try t.expect(kit.contains(r.out, "pkg: in sync"));
    const empty = try kit.Harness.create();
    defer empty.destroy();
    const none = empty.run(&.{ "npm", "check" });
    try t.expectEqual(@as(u8, 1), none.code);
    try t.expect(kit.contains(none.err, "no package under . has a buildrules.lock.bzl"));
}

test "sync and check on a directory that is not a package: no package.json, no lockfile, no BUCK call" {
    const h = try fresh();
    defer h.destroy();
    const missing = h.run(&.{ "npm", "sync", "nowhere" });
    try t.expectEqual(@as(u8, 1), missing.code);
    try t.expect(kit.contains(missing.err, "nowhere: no package.json"));
    try h.put("half/package.json", pkg_json);
    const half = h.run(&.{ "npm", "check", "half" });
    try t.expectEqual(@as(u8, 1), half.code);
    try t.expect(kit.contains(half.err, "half: no package-lock.json"));
    // The BUCK file: check says it is missing, sync writes it, and a BUCK file without the call is refused either way.
    const s = try synced();
    defer s.destroy();
    try s.tmp.dir.deleteFile("pkg/BUCK");
    const no_buck = s.run(&.{ "npm", "check", "pkg" });
    try t.expectEqual(@as(u8, 1), no_buck.code);
    try t.expect(kit.contains(no_buck.err, "no BUCK file with an npm_package call"));
    try t.expectEqual(@as(u8, 0), s.run(&.{ "npm", "sync", "pkg" }).code);
    try t.expect(kit.contains(s.read("pkg/BUCK"), "npm_package(path = \".\")"));
    try s.put("pkg/BUCK", "# nothing\n");
    for ([_][]const []const u8{ &.{ "npm", "check", "pkg" }, &.{ "npm", "sync", "pkg" } }) |argv| {
        const r = s.run(argv);
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, "the BUCK file has no npm_package call"));
    }
}

fn syncWithLock(h: *kit.Harness, body: []const u8) !kit.Run {
    try h.put("pkg/package-lock.json", try std.fmt.allocPrint(h.a(), "{{\"lockfileVersion\":3,\"packages\":{{\"\":{{\"name\":\"demo\"}}{s}}}}}", .{body}));
    return h.run(&.{ "npm", "sync", "pkg" });
}

/// `,"path": {fields}` (or `,"path": value` when the text is not a list of fields).
fn entry(a: std.mem.Allocator, path: []const u8, extra: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, extra, ':') == null) return std.fmt.allocPrint(a, ",\"{s}\":{s}", .{ path, extra });
    return std.fmt.allocPrint(a, ",\"{s}\":{{{s}}}", .{ path, extra });
}

const good_fields = "\"version\":\"1.0.0\",\"resolved\":\"https://registry.example/x/-/x-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"";

test "sync: a lockfile that is not a lockfile, and an entry of it that cannot be pinned, is refused with the entry's path" {
    const h = try fresh();
    defer h.destroy();
    const a = h.a();
    const whole = [_]struct { text: []const u8, needle: []const u8 }{
        .{ .text = "not json", .needle = "package-lock.json is not valid JSON" },
        .{ .text = "[]", .needle = "package-lock.json is not a JSON object" },
        .{ .text = "{\"packages\":{}}", .needle = "not lockfileVersion 3" },
        .{ .text = "{\"lockfileVersion\":\"3\",\"packages\":{}}", .needle = "not lockfileVersion 3" },
        .{ .text = "{\"lockfileVersion\":3}", .needle = "has no `packages` object" },
        .{ .text = "{\"lockfileVersion\":3,\"packages\":[]}", .needle = "`packages` is not an object" },
    };
    for (whole) |c| {
        try h.put("pkg/package-lock.json", c.text);
        const r = h.run(&.{ "npm", "sync", "pkg" });
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, c.needle));
    }
    const entries = [_]struct { path: []const u8, fields: []const u8, needle: []const u8 }{
        .{ .path = "node_modules/x", .fields = "5", .needle = "packages[node_modules/x] is not an object" },
        .{ .path = "node_modules/x", .fields = "\"version\":\"1.0.0\",\"integrity\":\"" ++ sri_a ++ "\"", .needle = "has no `resolved`" },
        .{ .path = "node_modules/x", .fields = "\"version\":\"1.0.0\",\"resolved\":\"https://r.example/x.tgz\"", .needle = "has no `integrity`" },
        .{ .path = "other/dir", .fields = good_fields, .needle = "packages[other/dir] has no name" },
        .{ .path = "node_modules/x", .fields = "\"resolved\":\"https://r.example/x.tgz\",\"integrity\":\"" ++ sri_a ++ "\"", .needle = "has no version" },
        .{ .path = "node_modules/x", .fields = "\"version\":\"1.0.0\",\"resolved\":\"https://r.example/x.tgz\",\"integrity\":\"sha512-short\"", .needle = "integrity is not a sha512 of 64 bytes" },
        .{ .path = "node_modules/x", .fields = "\"version\":\"1.0.0\",\"resolved\":\"http://r.example/x.tgz\",\"integrity\":\"" ++ sri_a ++ "\"", .needle = "resolved is not an https URL" },
        .{ .path = "node_modules/x", .fields = "\"version\":\"1.0.0\",\"resolved\":\"https://r.example/x y.tgz\",\"integrity\":\"" ++ sri_a ++ "\"", .needle = "resolved is not an https URL" },
        .{ .path = "node_modules/x", .fields = "\"name\":\"bad name\"," ++ good_fields, .needle = "unsupported characters" },
        .{ .path = "node_modules/x", .fields = "\"version\":\"1 0\",\"resolved\":\"https://r.example/x.tgz\",\"integrity\":\"" ++ sri_a ++ "\"", .needle = "unsupported characters" },
        .{ .path = "node_modules/x", .fields = good_fields ++ ",\"os\":\"linux\"", .needle = "os is not an array" },
        .{ .path = "node_modules/x", .fields = good_fields ++ ",\"cpu\":[5]", .needle = "cpu holds a value this tool does not accept" },
        .{ .path = "node_modules/x", .fields = good_fields ++ ",\"libc\":[\"\"]", .needle = "libc holds a value this tool does not accept" },
        .{ .path = "node_modules/x", .fields = good_fields ++ ",\"os\":[\"" ++ "a" ** 33 ++ "\"]", .needle = "os holds a value this tool does not accept" },
        .{ .path = "node_modules/x", .fields = good_fields ++ ",\"os\":[\"a b\"]", .needle = "os holds a value this tool does not accept" },
    };
    for (entries) |c| {
        const r = try syncWithLock(h, try entry(a, c.path, c.fields));
        try t.expectEqual(@as(u8, 1), r.code);
        if (!kit.contains(r.err, c.needle)) {
            std.debug.print("expected `{s}`, got: {s}\n", .{ c.needle, r.err });
            return error.WrongMessage;
        }
    }
    const twice = try syncWithLock(h, try std.mem.concat(a, u8, &.{
        try entry(a, "node_modules/x", good_fields),
        try entry(a, "node_modules/a/node_modules/x", "\"version\":\"1.0.0\",\"resolved\":\"https://registry.example/x/-/x-1.0.0.tgz\",\"integrity\":\"" ++ sri_b ++ "\""),
    }));
    try t.expectEqual(@as(u8, 1), twice.code);
    try t.expect(kit.contains(twice.err, "x@1.0.0 appears twice with different integrities"));
}

test "sync: links, bundled packages and workspace members are not pinned, the same package twice is one, platform lists keep their order, a name field wins over the path" {
    const h = try fresh();
    defer h.destroy();
    const a = h.a();
    const body = try std.mem.concat(a, u8, &.{
        try entry(a, "node_modules/l", "\"link\":true,\"resolved\":\"../l\""),
        try entry(a, "node_modules/b", "\"inBundle\":true," ++ good_fields),
        try entry(a, "packages/member", "\"version\":\"0.0.1\""),
        try entry(a, "node_modules/x", good_fields ++ ",\"os\":[\"linux\",\"!win32\"],\"cpu\":[\"x64\"],\"libc\":[\"glibc\"]"),
        try entry(a, "node_modules/a/node_modules/x", good_fields),
        try entry(a, "node_modules/alias", "\"name\":\"real-name\",\"version\":\"2.0.0\",\"resolved\":\"https://registry.example/real-name/-/real-name-2.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\",\"link\":false,\"inBundle\":\"yes\""),
    });
    const r = try syncWithLock(h, body);
    try t.expectEqual(@as(u8, 0), r.code);
    const table = h.read("pkg/buildrules.lock.bzl");
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, table, "\"x@1.0.0\": {"));
    try t.expect(kit.contains(table, "\"real-name@2.0.0\": {"));
    try t.expect(!kit.contains(table, "member"));
    try t.expect(!kit.contains(table, "\"l@"));
    try t.expect(kit.contains(table, "\"os\": [\"linux\", \"!win32\"],"));
    try t.expect(kit.contains(table, "\"cpu\": [\"x64\"],"));
    try t.expect(kit.contains(table, "\"libc\": [\"glibc\"],"));
    try t.expectEqual(@as(usize, 2), fetches);
}

test "sync: a package.json that is not a manifest, and every way its policy can be wrong, is refused with the key" {
    const h = try fresh();
    defer h.destroy();
    const cases = [_]struct { text: []const u8, needle: []const u8 }{
        .{ .text = "not json", .needle = "package.json is not valid JSON" },
        .{ .text = "[]", .needle = "package.json is not a JSON object" },
        .{ .text = "{\"scripts\":5}", .needle = "\"scripts\" is not an object" },
        .{ .text = "{\"scripts\":{\"a\":5}}", .needle = "script a is not a string" },
        .{ .text = "{\"buildrules\":5}", .needle = "\"buildrules\" is not an object" },
        .{ .text = "{\"buildrules\":{\"dist\":\"../x\"}}", .needle = "buildrules.dist must be a relative directory" },
        .{ .text = "{\"buildrules\":{\"dist\":5}}", .needle = "buildrules.dist must be a relative directory" },
        .{ .text = "{\"buildrules\":{\"default-action\":5}}", .needle = "default-action must be a string" },
        .{ .text = "{\"buildrules\":{\"steps\":[]}}", .needle = "steps must be an object" },
        .{ .text = "{\"scripts\":{\"s\":\"x\"},\"buildrules\":{\"steps\":{\"nope\":\"s\"}}}", .needle = "buildrules.steps.nope: not a step" },
        .{ .text = "{\"buildrules\":{\"steps\":{\"test\":5}}}", .needle = "buildrules.steps.test must be a script name" },
        .{ .text = "{\"buildrules\":{\"actions\":[]}}", .needle = "actions must be an object" },
        .{ .text = "{\"buildrules\":{\"actions\":{\"dist\":[\"test\"]}}}", .needle = "the name is a step's or a target's" },
        .{ .text = "{\"buildrules\":{\"actions\":{\"check\":[\"test\"]}}}", .needle = "the name is a step's or a target's" },
        .{ .text = "{\"buildrules\":{\"actions\":{\"node_modules\":[\"test\"]}}}", .needle = "the name is a step's or a target's" },
        .{ .text = "{\"buildrules\":{\"actions\":{\"Bad\":[\"test\"]}}}", .needle = "not a lower-case name" },
        .{ .text = "{\"buildrules\":{\"actions\":{\"ci\":5}}}", .needle = "buildrules.actions.ci must be a non-empty list of steps" },
        .{ .text = "{\"buildrules\":{\"actions\":{\"ci\":[]}}}", .needle = "buildrules.actions.ci must be a non-empty list of steps" },
        .{ .text = "{\"buildrules\":{\"actions\":{\"ci\":[\"nope\"]}}}", .needle = "names something that is not a step" },
        .{ .text = "{\"buildrules\":{\"actions\":{\"ci\":[5]}}}", .needle = "names something that is not a step" },
    };
    for (cases) |c| {
        try h.put("pkg/package.json", c.text);
        const r = h.run(&.{ "npm", "sync", "pkg" });
        try t.expectEqual(@as(u8, 1), r.code);
        if (!kit.contains(r.err, c.needle)) {
            std.debug.print("expected `{s}`, got: {s}\n", .{ c.needle, r.err });
            return error.WrongMessage;
        }
    }
}

test "sync: a policy and scripts of every shape reach the table, with the strings escaped so that the Starlark stays one string" {
    const h = try fresh();
    defer h.destroy();
    try h.put("pkg/package.json",
        \\{"name":"d\"q","version":"1.0.0-rc.1",
        \\ "scripts":{"typecheck":"a\\b\nc\td\re\u0001f\u007fg\u00e9","test":"jest","build":"tsc"},
        \\ "buildrules":{"dist":"out/dist","default-action":"ci","steps":{"test":"test","build":"build"},"actions":{"ci":["test","typecheck"],"ship":["build"]}}}
    );
    const r = h.run(&.{ "npm", "sync", "pkg" });
    try t.expectEqual(@as(u8, 0), r.code);
    const table = h.read("pkg/buildrules.lock.bzl");
    try t.expect(kit.contains(table, "\"name\": \"d\\\"q\","));
    try t.expect(kit.contains(table, "\"version\": \"1.0.0-rc.1\","));
    try t.expect(kit.contains(table, "\"typecheck\": \"a\\\\b\\nc\\td\\re\\x01f\\x7fg\u{e9}\","));
    try t.expect(kit.contains(table, "\"default-action\": \"ci\","));
    try t.expect(kit.contains(table, "\"dist\": \"out/dist\","));
    try t.expect(kit.contains(table, "\"steps\": {\n            \"build\": \"build\",\n            \"test\": \"test\",\n        },"));
    try t.expect(kit.contains(table, "\"ci\": [\"test\", \"typecheck\"],"));
    try t.expect(kit.contains(table, "\"ship\": [\"build\"],"));
    // A manifest with neither name nor version nor scripts is a table without them.
    try h.put("pkg/package.json", "{}");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "npm", "sync", "pkg" }).code);
    try t.expect(kit.contains(h.read("pkg/buildrules.lock.bzl"), "PACKAGE = {\n    \"scripts\": {\n    },\n    \"buildrules\": {\n    },\n}\n"));
}

test "sync: a download that fails is a message naming the package and the URL, and nothing is written" {
    const h = try fresh();
    defer h.destroy();
    fetch_error = error.HttpStatusNotOk;
    const r = h.run(&.{ "npm", "sync", "pkg" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "left-pad@1.3.0: fetching https://registry.example/left-pad/-/left-pad-1.3.0.tgz: HttpStatusNotOk"));
    try t.expect(!h.has("pkg/buildrules.lock.bzl"));
}

test "sync: a table whose lines are not the generated layout, or hold a bad hash or size, pins nothing (the packages are fetched again); a seed of another integrity is not used" {
    const h = try synced();
    defer h.destroy();
    const good_table = h.read("pkg/buildrules.lock.bzl");
    const damaged = [_][2][]const u8{
        .{ "\"size\": 11,", "\"size\": eleven," },
        .{ "\"sha256\": \"" ++ sha_a ++ "\",", "\"sha256\": \"zz\"," },
        .{ "\"sha256\": \"" ++ sha_a ++ "\",", "" },
        .{ "    \"left-pad@1.3.0\": {", "    left-pad: {" },
    };
    for (damaged) |d| {
        try h.put("pkg/buildrules.lock.bzl", try std.mem.replaceOwned(u8, h.a(), good_table, d[0], d[1]));
        fetches = 0;
        const r = h.run(&.{ "npm", "sync", "pkg" });
        try t.expectEqual(@as(u8, 0), r.code);
        try t.expect(fetches >= 1);
        try t.expectEqualStrings(good_table, h.read("pkg/buildrules.lock.bzl"));
    }
    // Lines that are not entries, before the entries, do not hide them.
    try h.put("pkg/buildrules.lock.bzl", try std.mem.replaceOwned(u8, h.a(), good_table, "NPM = {\n", "NPM = {\n    \"left-pad@1.3.0\": {\n    },\n    junk\n"));
    fetches = 0;
    try t.expectEqual(@as(u8, 0), h.run(&.{ "npm", "sync", "pkg" }).code);
    try t.expectEqual(@as(usize, 0), fetches);
    // A seed that knows the package at another integrity is no seed for it.
    try h.put("pkg/buildrules.lock.bzl", "stale\n");
    try h.put("seed.bzl", try std.mem.replaceOwned(u8, h.a(), good_table, sri_a, sri_b));
    fetches = 0;
    try t.expectEqual(@as(u8, 0), h.run(&.{ "npm", "sync", "pkg", "--seed", "seed.bzl" }).code);
    try t.expect(fetches >= 1);
    // A seed that is not there is a failure that names it.
    const gone = h.run(&.{ "npm", "sync", "pkg", "--seed", "missing.bzl" });
    try t.expectEqual(@as(u8, 1), gone.code);
    try t.expect(kit.contains(gone.err, "cannot read --seed missing.bzl"));
}

test "sync: fields of the lockfile that have the wrong type are the same as fields that are absent; an empty platform list is no list" {
    const h = try fresh();
    defer h.destroy();
    const a = h.a();
    const r1 = try syncWithLock(h, try entry(a, "node_modules/x", "\"version\":5,\"resolved\":\"https://registry.example/x.tgz\",\"integrity\":\"" ++ sri_a ++ "\""));
    try t.expectEqual(@as(u8, 1), r1.code);
    try t.expect(kit.contains(r1.err, "has no version"));
    const r2 = try syncWithLock(h, try entry(a, "node_modules/x", "\"version\":\"1.0.0\",\"resolved\":7,\"integrity\":\"" ++ sri_a ++ "\""));
    try t.expectEqual(@as(u8, 1), r2.code);
    try t.expect(kit.contains(r2.err, "has no `resolved`"));
    const ok = try syncWithLock(h, try entry(a, "node_modules/x", good_fields ++ ",\"os\":[],\"name\":9"));
    try t.expectEqual(@as(u8, 0), ok.code);
    try t.expect(!kit.contains(h.read("pkg/buildrules.lock.bzl"), "\"os\":"));
    try t.expect(kit.contains(h.read("pkg/buildrules.lock.bzl"), "\"x@1.0.0\": {"));
}

test "sync: table lines that are quoted wrongly are not read, so the package is fetched again; an empty integrity is read, and is not the lockfile's" {
    const h = try synced();
    defer h.destroy();
    const good_table = h.read("pkg/buildrules.lock.bzl");
    for ([_][2][]const u8{
        .{ "        \"sri512\": \"" ++ sri_a ++ "\",", "        \"sri512\": " ++ sri_a ++ "," },
        .{ "        \"sri512\": \"" ++ sri_a ++ "\",", "        \"sri512\": \"" },
    }) |c| {
        try h.put("pkg/buildrules.lock.bzl", try std.mem.replaceOwned(u8, h.a(), good_table, c[0], c[1]));
        fetches = 0;
        const r = h.run(&.{ "npm", "sync", "pkg" });
        try t.expectEqual(@as(u8, 0), r.code);
        try t.expect(fetches >= 1);
    }
    try h.put("pkg/buildrules.lock.bzl", try std.mem.replaceOwned(u8, h.a(), good_table, "        \"sri512\": \"" ++ sri_a ++ "\",", "        \"sri512\": \"\","));
    const r = h.run(&.{ "npm", "sync", "pkg" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "the same version with other bytes"));
}
