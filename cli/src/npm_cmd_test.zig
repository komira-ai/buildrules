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

fn fake(a: std.mem.Allocator, url: []const u8) anyerror!fetch.Digest.Result {
    _ = a;
    fetches += 1;
    if (std.mem.indexOf(u8, url, "fsevents") != null) return .{ .sha256 = sha_b, .sri512 = sri_b, .size = 22 };
    return .{ .sha256 = sha_a, .sri512 = served_sri, .size = 11 };
}

fn fresh() !*kit.Harness {
    fetches = 0;
    served_sri = sri_a;
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
