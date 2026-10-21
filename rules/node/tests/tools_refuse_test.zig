//! The refusals of node_tools as a user meets them: `zig test` of this file, run as a build action by `:node_tools_refuse`. node_tools is run as the process the
//! public target hands out (its path in the environment as NODE_TOOLS, the zig_test's `env_tools`), over a spec and files the test writes, and each case holds the
//! exit status and the message on stderr to what the tool must say. The unit tests of each part call it in-process and read error codes; these read the
//! sentence a person is shown, which names the file and says what to run instead.
//!
//! `check` is also run on a table that matches its files, so a tool that refuses everything is red.

const std = @import("std");
const proc = @import("refusal_proc");

const USAGE = "node_modules: usage: node_tools assemble|run|unpack|tree|check <spec.json> <out> | manifest <package.json> <out>";
const SRI_A = "sha512-3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw==";

fn sha256(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

const LOCK =
    \\{"name":"app","lockfileVersion":3,"packages":{"":{"name":"app"},"node_modules/left-pad":{"version":"1.3.0","resolved":"https://registry.example/left-pad.tgz","integrity":"sha512-AAAA"}}}
;
const PACKAGE_JSON = "{\"name\":\"app\",\"scripts\":{\"test\":\"node t.js\"}}";

fn tools(a: std.mem.Allocator, rest: []const []const u8) ![]const []const u8 {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(a, try proc.tool(a, "NODE_TOOLS"));
    try argv.appendSlice(a, rest);
    return argv.items;
}

/// The spec of `check` over the files `package.json` and `package-lock.json` of `tmp`, with the sha256 the table recorded and its pins.
fn checkSpec(a: std.mem.Allocator, pj_sha: []const u8, lock_sha: []const u8, table: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"packageJson\":\"package.json\",\"lockfile\":\"package-lock.json\",\"packageJsonSha256\":\"{s}\",\"lockfileSha256\":\"{s}\",\"table\":{s}}}", .{ pj_sha, lock_sha, table });
}

fn checkRun(a: std.mem.Allocator, tmp: *std.testing.TmpDir, package_json: []const u8, lock: []const u8, pj_sha: []const u8, lock_sha: []const u8, table: []const u8) !proc.Run {
    try tmp.dir.writeFile(.{ .sub_path = "package.json", .data = package_json });
    try tmp.dir.writeFile(.{ .sub_path = "package-lock.json", .data = lock });
    try tmp.dir.writeFile(.{ .sub_path = "spec.json", .data = try checkSpec(a, pj_sha, lock_sha, table) });
    return proc.run(a, tmp.dir, try tools(a, &.{ "check", "spec.json", "result.json" }));
}

test "check: a table that matches its files is accepted, and the result is a success for Buck2" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try checkRun(a, &tmp, PACKAGE_JSON, LOCK, &sha256(PACKAGE_JSON), &sha256(LOCK), "{\"left-pad@1.3.0\":\"sha512-AAAA\"}");
    try proc.expectOk("a table that matches", r);
    const result = try tmp.dir.readFileAlloc(a, "result.json", 1 << 16);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"status\": \"success\"") != null);
}

test "check: a table that is stale is refused, line by line, and the fix is named" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fix = "npm check: the table is stale: run `buildrules npm sync` and commit the result";
    const good_pj = sha256(PACKAGE_JSON);
    const good_lock = sha256(LOCK);
    const pin = "{\"left-pad@1.3.0\":\"sha512-AAAA\"}";
    const v2 = "{\"lockfileVersion\":2,\"packages\":{}}";
    const v2_sha = sha256(v2);
    const text_sha = sha256("lockfile?");
    const Case = struct { name: []const u8, package_json: []const u8 = PACKAGE_JSON, lock: []const u8 = LOCK, pj_sha: []const u8, lock_sha: []const u8, table: []const u8, msgs: []const []const u8 };
    const cases = [_]Case{
        .{ .name = "package.json edited since the table was made", .package_json = "{\"name\":\"app\",\"scripts\":{\"test\":\"node other.js\"}}", .pj_sha = &good_pj, .lock_sha = &good_lock, .table = pin, .msgs = &.{ "npm check: package.json is not the one the table was made from", fix } },
        .{ .name = "package-lock.json edited since the table was made", .lock = "{\"lockfileVersion\":3,\"packages\":{}}", .pj_sha = &good_pj, .lock_sha = &good_lock, .table = "{}", .msgs = &.{ "npm check: package-lock.json is not the one the table was made from", fix } },
        .{ .name = "a package the table does not pin", .pj_sha = &good_pj, .lock_sha = &good_lock, .table = "{}", .msgs = &.{ "npm check: left-pad@1.3.0 is in package-lock.json and not in the table", fix } },
        .{ .name = "a pin the lockfile no longer has", .pj_sha = &good_pj, .lock_sha = &good_lock, .table = "{\"left-pad@1.3.0\":\"sha512-AAAA\",\"gone@2.0.0\":\"sha512-BBBB\"}", .msgs = &.{ "npm check: gone@2.0.0 is in the table and no longer in package-lock.json", fix } },
        .{ .name = "a package whose integrity changed", .pj_sha = &good_pj, .lock_sha = &good_lock, .table = "{\"left-pad@1.3.0\":\"sha512-CCCC\"}", .msgs = &.{ "npm check: left-pad@1.3.0: package-lock.json says sha512-AAAA, the table pins sha512-CCCC", fix } },
        .{ .name = "a lockfile of version 2", .lock = v2, .pj_sha = &good_pj, .lock_sha = &v2_sha, .table = "{}", .msgs = &.{ "npm check: package-lock.json is not lockfileVersion 3 (npm >= 9)", fix } },
        .{ .name = "a lockfile that is not JSON", .lock = "lockfile?", .pj_sha = &good_pj, .lock_sha = &text_sha, .table = "{}", .msgs = &.{ "npm check: package-lock.json is not JSON", fix } },
    };
    for (cases) |c| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try proc.expectRefusal(c.name, try checkRun(a, &tmp, c.package_json, c.lock, c.pj_sha, c.lock_sha, c.table), 1, c.msgs);
        // a table that is stale writes no result: a build that reads it is red
        try std.testing.expectError(error.FileNotFound, tmp.dir.access("result.json", .{}));
    }
}

test "a bad command line, and a spec that is missing, not JSON or without its fields, are refused" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "notjson.json", .data = "{spec" });
    try tmp.dir.writeFile(.{ .sub_path = "empty.json", .data = "{}" });
    const cases = [_]struct { name: []const u8, args: []const []const u8, msgs: []const []const u8 }{
        .{ .name = "no arguments", .args = &.{}, .msgs = &.{USAGE} },
        .{ .name = "a mode that is not one", .args = &.{ "install", "spec.json", "out" }, .msgs = &.{USAGE} },
        .{ .name = "a mode with no output", .args = &.{ "assemble", "spec.json" }, .msgs = &.{USAGE} },
        .{ .name = "an extra argument", .args = &.{ "assemble", "spec.json", "out", "more" }, .msgs = &.{USAGE} },
        .{ .name = "a spec that is not there", .args = &.{ "assemble", "missing.json", "out" }, .msgs = &.{"node_modules: cannot read missing.json: FileNotFound"} },
        .{ .name = "a spec that is not JSON", .args = &.{ "tree", "notjson.json", "out" }, .msgs = &.{"node_modules: notjson.json is not JSON"} },
        .{ .name = "an assemble spec without its lockfile", .args = &.{ "assemble", "empty.json", "out" }, .msgs = &.{"node_modules: BadSpec"} },
        .{ .name = "a check spec without its package.json", .args = &.{ "check", "empty.json", "out" }, .msgs = &.{"node_modules: BadSpec"} },
        .{ .name = "an unpack spec without its tarball", .args = &.{ "unpack", "empty.json", "out" }, .msgs = &.{"node_modules: BadSpec"} },
        .{ .name = "a run spec without its arguments", .args = &.{ "run", "empty.json", "out" }, .msgs = &.{"node_modules: BadSpec"} },
        .{ .name = "a package.json that is not there", .args = &.{ "manifest", "missing.json", "out" }, .msgs = &.{"node_modules: cannot read missing.json: FileNotFound"} },
        .{ .name = "a package.json that is not JSON", .args = &.{ "manifest", "notjson.json", "out" }, .msgs = &.{"node_modules: notjson.json: NotJson"} },
    };
    for (cases) |c| try proc.expectRefusal(c.name, try proc.run(a, tmp.dir, try tools(a, c.args)), 1, c.msgs);
}

test "assemble: a lockfile that is not a version 3 package-lock.json is refused" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { name: []const u8, lock: []const u8, msg: []const u8 }{
        .{ .name = "not JSON", .lock = "lock?", .msg = "node_modules: the lockfile is not JSON" },
        .{ .name = "version 2", .lock = "{\"lockfileVersion\":2,\"packages\":{}}", .msg = "node_modules: the lockfile is not a lockfileVersion 3 package-lock.json" },
        .{ .name = "no version", .lock = "{\"packages\":{}}", .msg = "node_modules: the lockfile is not a lockfileVersion 3 package-lock.json" },
    };
    for (cases) |c| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "package-lock.json", .data = c.lock });
        try tmp.dir.writeFile(.{ .sub_path = "spec.json", .data = "{\"lockfile\":\"package-lock.json\",\"tarballs\":{},\"sri512\":{}}" });
        try proc.expectRefusal(c.name, try proc.run(a, tmp.dir, try tools(a, &.{ "assemble", "spec.json", "out" })), 1, &.{c.msg});
    }
}

test "unpack: a tarball that is not the pinned bytes, an integrity that is not sha512, a tarball that is not there" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = "these bytes are not a tarball";
    var d: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(bytes, &d, .{});
    var b64: [88]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&b64, &d);
    const got = try std.fmt.allocPrint(a, "sha512-{s}", .{b64});
    const cases = [_]struct { name: []const u8, tarball: []const u8, sri: []const u8, msgs: []const []const u8 }{
        .{ .name = "other bytes than the pin", .tarball = "pkg.tgz", .sri = SRI_A, .msgs = &.{ "node_modules: pkg@1.0.0: the tarball is ", got, ", the pinned integrity is ", SRI_A } },
        .{ .name = "a sha1 integrity", .tarball = "pkg.tgz", .sri = "sha1-abc", .msgs = &.{"node_modules: pkg@1.0.0: integrity sha1-abc is not sha512-<base64>"} },
        .{ .name = "a tarball that is not there", .tarball = "missing.tgz", .sri = SRI_A, .msgs = &.{"node_modules: cannot read missing.tgz: FileNotFound"} },
    };
    for (cases) |c| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "pkg.tgz", .data = bytes });
        const spec = try std.fmt.allocPrint(a, "{{\"tarball\":\"{s}\",\"sri512\":\"{s}\",\"name\":\"pkg\",\"version\":\"1.0.0\"}}", .{ c.tarball, c.sri });
        try tmp.dir.writeFile(.{ .sub_path = "spec.json", .data = spec });
        try proc.expectRefusal(c.name, try proc.run(a, tmp.dir, try tools(a, &.{ "unpack", "spec.json", "out" })), 1, c.msgs);
    }
}
