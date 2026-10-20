const std = @import("std");
const check = @import("check.zig");

const lock_a =
    \\{"lockfileVersion":3,"packages":{
    \\ "":{"name":"app"},
    \\ "node_modules/fx-a":{"version":"1.0.0","resolved":"https://registry.example/fx-a.tgz","integrity":"sha512-AAAA"},
    \\ "node_modules/fx-a/node_modules/fx-b":{"version":"2.0.0","resolved":"https://registry.example/fx-b.tgz","integrity":"sha512-BBBB"},
    \\ "node_modules/alias":{"name":"fx-b","version":"2.0.0","resolved":"https://registry.example/fx-b.tgz","integrity":"sha512-BBBB"},
    \\ "node_modules/link":{"resolved":"packages/x","link":true},
    \\ "packages/x":{"name":"x","version":"0.0.0"},
    \\ "node_modules/fx-a/node_modules/bundled":{"version":"1.0.0","inBundle":true}
    \\}}
;

fn run(a: std.mem.Allocator, pj: []const u8, lock: []const u8, pj_sha: []const u8, lock_sha: []const u8, table: []const [2][]const u8) ![]const u8 {
    var t = std.StringArrayHashMap([]const u8).init(a);
    for (table) |kv| try t.put(kv[0], kv[1]);
    var out = std.ArrayList(u8).empty;
    check.check(a, .{ .package_json = pj, .lockfile = lock, .package_json_sha256 = pj_sha, .lockfile_sha256 = lock_sha, .table = t }, out.writer(a)) catch |e| switch (e) {
        error.Failed => return out.items,
        else => return e,
    };
    return "";
}

fn sha(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.allocPrint(a, "{x}", .{&d});
}

const good_table = [_][2][]const u8{ .{ "fx-a@1.0.0", "sha512-AAAA" }, .{ "fx-b@2.0.0", "sha512-BBBB" } };

test "a table made from these files passes: aliases and the project itself, links, workspace members and bundled packages are not pins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msg = try run(a, "{}", lock_a, try sha(a, "{}"), try sha(a, lock_a), &good_table);
    try std.testing.expectEqualStrings("", msg);
}

test "a lockfile changed after sync: the digest, a new package and a changed integrity are each named" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pj_sha = try sha(a, "{}");
    const lock_b = try std.mem.replaceOwned(u8, a, lock_a, "sha512-AAAA", "sha512-CCCC");
    const m1 = try run(a, "{}", lock_b, pj_sha, try sha(a, lock_a), &good_table);
    try std.testing.expect(std.mem.indexOf(u8, m1, "package-lock.json is not the one the table was made from") != null);
    try std.testing.expect(std.mem.indexOf(u8, m1, "fx-a@1.0.0: package-lock.json says sha512-CCCC, the table pins sha512-AAAA") != null);
    try std.testing.expect(std.mem.indexOf(u8, m1, "buildrules npm sync") != null);
    // the same bytes, but a package the table lacks
    const m2 = try run(a, "{}", lock_a, pj_sha, try sha(a, lock_a), good_table[0..1]);
    try std.testing.expect(std.mem.indexOf(u8, m2, "fx-b@2.0.0 is in package-lock.json and not in the table") != null);
    // and a table row the lockfile dropped
    const extra = good_table ++ [_][2][]const u8{.{ "gone@1.0.0", "sha512-DDDD" }};
    const m3 = try run(a, "{}", lock_a, pj_sha, try sha(a, lock_a), &extra);
    try std.testing.expect(std.mem.indexOf(u8, m3, "gone@1.0.0 is in the table and no longer in package-lock.json") != null);
}

test "package.json changed after sync is stale; a non-v3 or unpinnable lockfile is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m1 = try run(a, "{\"scripts\":{}}", lock_a, try sha(a, "{}"), try sha(a, lock_a), &good_table);
    try std.testing.expect(std.mem.indexOf(u8, m1, "package.json is not the one the table was made from") != null);
    const v2 = "{\"lockfileVersion\":2,\"packages\":{}}";
    const m2 = try run(a, "{}", v2, try sha(a, "{}"), try sha(a, v2), &.{});
    try std.testing.expect(std.mem.indexOf(u8, m2, "not lockfileVersion 3") != null);
    const git = "{\"lockfileVersion\":3,\"packages\":{\"node_modules/g\":{\"version\":\"1.0.0\",\"resolved\":\"git+ssh://x\"}}}";
    const m3 = try run(a, "{}", git, try sha(a, "{}"), try sha(a, git), &.{});
    try std.testing.expect(std.mem.indexOf(u8, m3, "g@1.0.0: no integrity") != null);
}

test "withoutPolicy: only the buildrules key goes; a policy edit changes nothing else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try check.withoutPolicy(a, "{\"name\":\"x\",\"scripts\":{\"test\":\"jest\"},\"buildrules\":{\"dist\":\"dist\"},\"version\":\"1.0.0\"}");
    const two = try check.withoutPolicy(a, "{\"name\":\"x\",  \"buildrules\":{\"actions\":{\"ci\":[\"test\"]}}, \"scripts\":{\"test\":\"jest\"},\"version\":\"1.0.0\"}");
    try std.testing.expectEqualStrings(one, two);
    try std.testing.expect(std.mem.indexOf(u8, one, "buildrules") == null);
    try std.testing.expect(std.mem.indexOf(u8, one, "\"test\": \"jest\"") != null);
    // a script edit does change it
    const three = try check.withoutPolicy(a, "{\"name\":\"x\",\"scripts\":{\"test\":\"jest --ci\"},\"version\":\"1.0.0\"}");
    try std.testing.expect(!std.mem.eql(u8, one, three));
    try std.testing.expectError(error.NotJson, check.withoutPolicy(a, "{"));
    try std.testing.expectError(error.NotAnObject, check.withoutPolicy(a, "[]"));
}
