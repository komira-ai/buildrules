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
    var out = tartest.Sink{ .a = a };
    check.check(a, .{ .package_json = pj, .lockfile = lock, .package_json_sha256 = pj_sha, .lockfile_sha256 = lock_sha, .table = t }, &out) catch |e| switch (e) {
        error.Failed => return out.text.items,
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

const tartest = @import("tartest.zig");

fn specOf(a: std.mem.Allocator, pj: []const u8, lock: []const u8, table: []const [2][]const u8) !check.Spec {
    var t = std.StringArrayHashMap([]const u8).init(a);
    for (table) |kv| try t.put(kv[0], kv[1]);
    return .{ .package_json = pj, .lockfile = lock, .package_json_sha256 = try sha(a, pj), .lockfile_sha256 = try sha(a, lock), .table = t };
}

const head = "{\"lockfileVersion\":3,\"packages\":{";
const BadLock = struct { lock: []const u8, want: []const u8 };
const bad_locks = [_]BadLock{
        .{ .lock = "{", .want = "package-lock.json is not JSON" },
        .{ .lock = "[]", .want = "package-lock.json is not a JSON object" },
        .{ .lock = "{\"packages\":{}}", .want = "package-lock.json is not lockfileVersion 3 (npm >= 9)" },
        .{ .lock = "{\"lockfileVersion\":\"3\",\"packages\":{}}", .want = "package-lock.json is not lockfileVersion 3 (npm >= 9)" },
        .{ .lock = "{\"lockfileVersion\":3}", .want = "package-lock.json has no `packages`" },
        .{ .lock = "{\"lockfileVersion\":3,\"packages\":[]}", .want = "package-lock.json `packages` is not an object" },
        .{ .lock = head ++ "\"vendor/x\":{\"version\":\"1.0.0\",\"resolved\":\"https://r/x.tgz\"}}}", .want = "vendor/x: no name" },
        .{ .lock = head ++ "\"node_modules/x\":{\"resolved\":\"https://r/x.tgz\"}}}", .want = "node_modules/x: no version" },
        .{ .lock = head ++ "\"node_modules/x\":{\"version\":\"1.0.0\",\"integrity\":3}}}", .want = "x@1.0.0: no integrity (a git or file dependency cannot be pinned)" },
};

test "lockPackages: a lockfile that cannot be pinned is named, and says nothing else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (bad_locks) |c| {
        var problems = std.ArrayList([]const u8).empty;
        const got = try check.lockPackages(a, c.lock, &problems);
        try std.testing.expectEqual(@as(usize, 0), got.count());
        try std.testing.expectEqual(@as(usize, 1), problems.items.len);
        try std.testing.expectEqualStrings(c.want, problems.items[0]);
    }
}

test "lockPackages: an entry that is not an object, the root and a link name nothing; a name member beats the path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lock = "{\"lockfileVersion\":3,\"packages\":{\"\":{\"version\":\"9.9.9\"},\"node_modules/n\":5,\"node_modules/l\":{\"link\":true,\"version\":\"1.0.0\"}," ++
        "\"node_modules/alias\":{\"name\":\"real\",\"version\":\"2.0.0\",\"integrity\":\"sha512-RRRR\"}}}";
    var problems = std.ArrayList([]const u8).empty;
    const got = try check.lockPackages(a, lock, &problems);
    try std.testing.expectEqual(@as(usize, 0), problems.items.len);
    try std.testing.expectEqual(@as(usize, 1), got.count());
    try std.testing.expectEqualStrings("sha512-RRRR", got.get("real@2.0.0").?);
}

/// A lockfile of 45 packages p0 .. p44.
fn bigLock(a: std.mem.Allocator) ![]const u8 {
    var lock = std.ArrayList(u8).empty;
    try lock.appendSlice(a, "{\"lockfileVersion\":3,\"packages\":{");
    for (0..45) |i| {
        if (i > 0) try lock.append(a, ',');
        try lock.writer(a).print("\"node_modules/p{d}\":{{\"version\":\"1.0.0\",\"resolved\":\"https://r/p{d}.tgz\",\"integrity\":\"sha512-P{d}\"}}", .{ i, i, i });
    }
    try lock.appendSlice(a, "}}");
    return lock.items;
}

test "a table stale in many places lists forty of them, counts the rest, and ends on the fix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lock = try bigLock(a);
    const msg = try run(a, "{}", lock, try sha(a, "{}"), try sha(a, lock), &.{});
    try std.testing.expectEqual(@as(usize, 42), std.mem.count(u8, msg, "npm check: "));
    try std.testing.expectEqual(@as(usize, 40), std.mem.count(u8, msg, " is in package-lock.json and not in the table\n"));
    try std.testing.expect(std.mem.indexOf(u8, msg, "npm check: p39@1.0.0 is in package-lock.json and not in the table\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "p40@1.0.0") == null);
    try std.testing.expect(std.mem.endsWith(u8, msg, "npm check: ... and 5 more\nnpm check: the table is stale: run `buildrules npm sync` and commit the result\n"));
}

test "both digests stale at once: each file is named, in the order package.json then the lockfile" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const msg = try run(a, "{}", lock_a, "0" ** 64, "1" ** 64, &good_table);
    const pj_at = std.mem.indexOf(u8, msg, "package.json is not the one the table was made from (sha256 ").?;
    const lk_at = std.mem.indexOf(u8, msg, "package-lock.json is not the one the table was made from (sha256 ").?;
    try std.testing.expect(pj_at < lk_at);
    try std.testing.expect(std.mem.indexOf(u8, msg, "the table has " ++ "0" ** 64 ++ ")") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "the table has " ++ "1" ** 64 ++ ")") != null);
}

fn checkOnce(a: std.mem.Allocator, spec: *const check.Spec) !void {
    var out = tartest.Sink{ .a = a };
    try check.check(a, spec.*, &out);
}


fn checkWriting(w: *tartest.Sink, spec: *const check.Spec) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try check.check(arena.allocator(), spec.*, w);
}

fn pinnable(a: std.mem.Allocator, lock: *const []const u8) !void {
    var problems = std.ArrayList([]const u8).empty;
    _ = try check.lockPackages(a, lock.*, &problems);
    if (problems.items.len > 0) return error.Problems;
}

fn unpoliced(a: std.mem.Allocator, text: *const []const u8) !void {
    _ = try check.withoutPolicy(a, text.*);
}

test "an allocation that fails is never a pass: check, lockPackages and withoutPolicy return an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const clean = try specOf(a, "{}", lock_a, &good_table);
    try tartest.allocSweep(checkOnce, &clean);
    var stale = try specOf(a, "{\"scripts\":{}}", lock_a, good_table[0..1]);
    stale.lockfile_sha256 = "0" ** 64;
    try tartest.allocSweep(checkOnce, &stale);
    const bad_lock: []const u8 = "{\"lockfileVersion\":3,\"packages\":{\"vendor/x\":{\"version\":\"1\",\"resolved\":\"r\"},\"node_modules/y\":{\"resolved\":\"r\"},\"node_modules/z\":{\"version\":\"1\"}}}";
    const bad = try specOf(a, "{}", bad_lock, &.{.{ "gone@1", "sha512-X" }});
    try tartest.allocSweep(checkOnce, &bad);
    const lock: []const u8 = lock_a;
    try tartest.allocSweep(pinnable, &lock);
    try tartest.allocSweep(pinnable, &bad_lock);
    // every lockfile that cannot be pinned, whole and through check, to a writer that does not fail
    for (&bad_locks) |*c| {
        try tartest.allocSweep(pinnable, &c.lock);
        const spec = try specOf(a, "{}", c.lock, &.{});
        try tartest.allocSweep(checkOnce, &spec);
    }
    const big = try specOf(a, "{}", try bigLock(a), &.{});
    try tartest.allocSweep(checkOnce, &big);
    // each difference alone (the list of problems is grown by the first of them)
    var pj_only = try specOf(a, "{}", lock_a, &good_table);
    pj_only.package_json_sha256 = "0" ** 64;
    try tartest.allocSweep(checkOnce, &pj_only);
    var lock_only = try specOf(a, "{}", lock_a, &good_table);
    lock_only.lockfile_sha256 = "0" ** 64;
    try tartest.allocSweep(checkOnce, &lock_only);
    const unpinned = try specOf(a, "{}", lock_a, good_table[0..1]);
    try tartest.allocSweep(checkOnce, &unpinned);
    const changed = try specOf(a, "{}", lock_a, &.{ .{ "fx-a@1.0.0", "sha512-ZZZZ" }, .{ "fx-b@2.0.0", "sha512-BBBB" } });
    try tartest.allocSweep(checkOnce, &changed);
    const extra_row = try specOf(a, "{}", lock_a, &(good_table ++ [_][2][]const u8{.{ "gone@1.0.0", "sha512-DDDD" }}));
    try tartest.allocSweep(checkOnce, &extra_row);
    const pj: []const u8 = "{\"name\":\"x\",\"buildrules\":{\"dist\":\"dist\"},\"scripts\":{\"test\":\"jest\"}}";
    try tartest.allocSweep(unpoliced, &pj);
}

test "a report that cannot be written is never a pass: check fails whichever line is lost" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stale = try specOf(a, "{\"scripts\":{}}", lock_a, good_table[0..1]);
    stale.lockfile_sha256 = "0" ** 64;
    try tartest.writerSweep(checkWriting, &stale);
    var many = try specOf(a, "{}", try bigLock(a), &.{});
    many.package_json_sha256 = "0" ** 64;
    try tartest.writerSweep(checkWriting, &many);
}
