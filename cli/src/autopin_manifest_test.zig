//! The manifest of an artifact, and the strict JSON and SETS it is read with. Each test names the defect it catches.

const std = @import("std");
const ctxm = @import("ctx.zig");
const json = @import("autopin_json.zig");
const manifest = @import("autopin_manifest.zig");
const sets_mod = @import("autopin_sets.zig");
const zip = @import("autopin_zip.zig");
const t = std.testing;

const head = "1" ** 40;
const base = "2" ** 40;
const sha_a = "a" ** 64;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

fn sets(a: std.mem.Allocator) !sets_mod.Sets {
    return sets_mod.Sets.parse(a, &.{ "site=buildrules-lock", "service/api=pins-lock" });
}

const good = "{\"pr\":7,\"head_sha\":\"" ++ head ++ "\",\"base_sha\":\"" ++ base ++ "\",\"files\":[{\"path\":\"site/buildrules.lock.bzl\",\"sha256\":\"" ++ sha_a ++ "\"}]}";

fn parseWith(a: std.mem.Allocator, text: []const u8) !manifest.Manifest {
    return manifest.parse(a, text, try sets(a));
}

test "json: a duplicate key is an error (std.json would keep the last)" {
    var ar = arena();
    defer ar.deinit();
    try t.expectError(error.DuplicateKey, json.parse(ar.allocator(), "{\"a\":1,\"a\":2}"));
    try t.expectError(error.DuplicateKey, json.parse(ar.allocator(), "{\"o\":{\"a\":1,\"b\":2,\"a\":3}}"));
}

test "json: numbers, strings, whitespace, depth and trailing data are strict" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqual(@as(i64, 12), (try json.parse(a, " 12\n")).int);
    try t.expectEqual(@as(i64, -3), (try json.parse(a, "-3")).int);
    try t.expect((try json.parse(a, "1.5")) == .float);
    try t.expect((try json.parse(a, "1e3")) == .float);
    try t.expectError(error.BadNumber, json.parse(a, "007"));
    try t.expectError(error.BadNumber, json.parse(a, "-"));
    try t.expectError(error.BadNumber, json.parse(a, "1234567890123456"));
    try t.expectError(error.BadString, json.parse(a, "\"a\\u0041\""));
    try t.expectError(error.BadString, json.parse(a, "\"a\x01\""));
    try t.expectError(error.BadString, json.parse(a, "\"caf\xc3\xa9\""));
    try t.expectError(error.TrailingData, json.parse(a, "{} x"));
    try t.expectError(error.TooDeep, json.parse(a, "[[[[[[[[1]]]]]]]]"));
    try t.expectError(error.Syntax, json.parse(a, "{\"a\":1,}"));
    try t.expectError(error.Syntax, json.parse(a, "[1,]"));
    try t.expectError(error.Syntax, json.parse(a, "{a:1}"));
    try t.expectError(error.Syntax, json.parse(a, "\x0b1"));
    try t.expectError(error.Syntax, json.parse(a, "{\"a\":1"));
    try t.expectError(error.Syntax, json.parse(a, "tru"));
    try t.expectError(error.Syntax, json.parse(a, ""));
    const v = try json.parse(a, "{\"a\":[true,false,null,\"s\",{}],\"b\":{}}");
    try t.expectEqual(@as(usize, 5), v.get("a").?.array.len);
    try t.expect(v.get("a").?.array[0].boolean);
    try t.expect(v.get("a").?.array[2] == .nil);
    try t.expect(v.get("zz") == null);
}

test "manifest: the good one parses, and renders back to itself" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const m = try parseWith(a, good);
    try t.expectEqual(@as(u64, 7), m.pr);
    try t.expectEqualStrings(head, m.head_sha);
    try t.expectEqual(@as(usize, 1), m.files.len);
    const text = try manifest.render(a, m);
    try t.expectEqualStrings(good ++ "\n", text);
    _ = try parseWith(a, text);
}

test "manifest: a duplicate key is refused" {
    var ar = arena();
    defer ar.deinit();
    const dup = "{\"pr\":7,\"pr\":8,\"head_sha\":\"" ++ head ++ "\",\"base_sha\":\"" ++ base ++ "\",\"files\":[]}";
    try t.expectError(error.DuplicateKey, parseWith(ar.allocator(), dup));
}

test "manifest: pr must be a JSON integer (a string, a float, a bool are refused)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectError(error.PrNotInteger, parseWith(a, try prManifest(a, "\"7\"")));
    try t.expectError(error.PrNotInteger, parseWith(a, try prManifest(a, "7.0")));
    try t.expectError(error.PrNotInteger, parseWith(a, try prManifest(a, "7e0")));
    try t.expectError(error.PrNotInteger, parseWith(a, try prManifest(a, "true")));
}

test "manifest: pr must be in 1..999999999" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectError(error.PrOutOfRange, parseWith(a, try prManifest(a, "0")));
    try t.expectError(error.PrOutOfRange, parseWith(a, try prManifest(a, "-1")));
    try t.expectError(error.PrOutOfRange, parseWith(a, try prManifest(a, "1000000000")));
    try t.expectEqual(@as(u64, 999_999_999), (try parseWith(a, try prManifest(a, "999999999"))).pr);
}

fn prManifest(al: std.mem.Allocator, pr: []const u8) ![]u8 {
    return std.fmt.allocPrint(al, "{{\"pr\":{s},\"head_sha\":\"{s}\",\"base_sha\":\"{s}\",\"files\":[]}}", .{ pr, head, base });
}

test "manifest: an unknown key is refused, in the manifest and in a file entry" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const extra = "{\"pr\":7,\"head_sha\":\"" ++ head ++ "\",\"base_sha\":\"" ++ base ++ "\",\"files\":[],\"note\":\"x\"}";
    try t.expectError(error.UnknownKey, parseWith(a, extra));
    const file_extra = "{\"pr\":7,\"head_sha\":\"" ++ head ++ "\",\"base_sha\":\"" ++ base ++ "\",\"files\":[{\"path\":\"site/buildrules.lock.bzl\",\"sha256\":\"" ++ sha_a ++ "\",\"mode\":\"755\"}]}";
    try t.expectError(error.UnknownKey, parseWith(a, file_extra));
}

test "manifest: a missing key is refused" {
    var ar = arena();
    defer ar.deinit();
    const missing = "{\"pr\":7,\"head_sha\":\"" ++ head ++ "\",\"files\":[]}";
    try t.expectError(error.MissingKey, parseWith(ar.allocator(), missing));
}

test "manifest: a non-object, text that is not JSON, and text over the size cap are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectError(error.NotAnObject, parseWith(a, "[]"));
    try t.expectError(error.NotJson, parseWith(a, "{"));
    try t.expectError(error.TooLarge, parseWith(a, " " ** (manifest.max_bytes + 1)));
}

test "manifest: a head or base sha that is not 40 lower-case hex digits is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const bad_head = "{\"pr\":7,\"head_sha\":\"" ++ "G" ** 40 ++ "\",\"base_sha\":\"" ++ base ++ "\",\"files\":[]}";
    try t.expectError(error.BadSha, parseWith(a, bad_head));
    const upper = "{\"pr\":7,\"head_sha\":\"" ++ "A" ** 40 ++ "\",\"base_sha\":\"" ++ base ++ "\",\"files\":[]}";
    try t.expectError(error.BadSha, parseWith(a, upper));
    const short_base = "{\"pr\":7,\"head_sha\":\"" ++ head ++ "\",\"base_sha\":\"abc\",\"files\":[]}";
    try t.expectError(error.BadSha, parseWith(a, short_base));
}

test "manifest: a file sha256 that is not 64 lower-case hex digits is refused" {
    var ar = arena();
    defer ar.deinit();
    const bad_file = "{\"pr\":7,\"head_sha\":\"" ++ head ++ "\",\"base_sha\":\"" ++ base ++ "\",\"files\":[{\"path\":\"site/buildrules.lock.bzl\",\"sha256\":\"abc\"}]}";
    try t.expectError(error.BadFileEntry, parseWith(ar.allocator(), bad_file));
}

test "manifest: files that is not an array is refused" {
    var ar = arena();
    defer ar.deinit();
    const not_array = "{\"pr\":7,\"head_sha\":\"" ++ head ++ "\",\"base_sha\":\"" ++ base ++ "\",\"files\":{}}";
    try t.expectError(error.BadFiles, parseWith(ar.allocator(), not_array));
}

test "manifest: a path that is not a SETS output is refused (it is never used to write)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const paths = [_][]const u8{
        ".github/workflows/ci.yml",
        "../site/buildrules.lock.bzl",
        "site/pins.lock.bzl", // the other kind's file in a buildrules-lock directory
        "service/api/buildrules.lock.bzl",
        "site/buildrules.lock.bzl/",
        "Site/buildrules.lock.bzl",
        "/site/buildrules.lock.bzl",
        "site/package-lock.json",
        "",
    };
    for (paths) |p| {
        const text = try std.fmt.allocPrint(a, "{{\"pr\":7,\"head_sha\":\"{s}\",\"base_sha\":\"{s}\",\"files\":[{{\"path\":\"{s}\",\"sha256\":\"{s}\"}}]}}", .{ head, base, p, sha_a });
        try t.expectError(error.PathNotInSets, parseWith(a, text));
    }
}

test "manifest: a file listed twice is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const one = "{\"path\":\"site/buildrules.lock.bzl\",\"sha256\":\"" ++ sha_a ++ "\"}";
    const twice = "{\"pr\":7,\"head_sha\":\"" ++ head ++ "\",\"base_sha\":\"" ++ base ++ "\",\"files\":[" ++ one ++ "," ++ one ++ "]}";
    try t.expectError(error.DuplicatePath, parseWith(a, twice));
}

test "manifest: more than eleven files are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const one = "{\"path\":\"site/buildrules.lock.bzl\",\"sha256\":\"" ++ sha_a ++ "\"}";
    const many = "{\"pr\":7,\"head_sha\":\"" ++ head ++ "\",\"base_sha\":\"" ++ base ++ "\",\"files\":[" ++ (one ++ ",") ** 11 ++ one ++ "]}";
    try t.expectError(error.BadFiles, parseWith(a, many));
}

test "sets: DIR=KIND, no duplicates, no unsafe directory, at most eight" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const s = try sets_mod.Sets.parse(a, &.{ ".=buildrules-lock", "a/b-c=pins-lock" });
    try t.expectEqual(sets_mod.Kind.buildrules_lock, s.items[0].kind);
    try t.expectEqualStrings("buildrules.lock.bzl", try sets_mod.Sets.tablePath(a, s.items[0]));
    try t.expectEqualStrings("a/b-c/pins.lock.bzl", try sets_mod.Sets.tablePath(a, s.items[1]));
    try t.expectEqual(@as(?usize, 1), try s.outputIndex(a, "a/b-c/pins.lock.bzl"));
    try t.expectEqual(@as(?usize, null), try s.outputIndex(a, "a/b-c/buildrules.lock.bzl"));
    try t.expectError(error.NoSets, sets_mod.Sets.parse(a, &.{}));
    try t.expectError(error.DuplicateSet, sets_mod.Sets.parse(a, &.{ "a=pins-lock", "a=buildrules-lock" }));
    try t.expectError(error.BadSet, sets_mod.Sets.parse(a, &.{"../x=pins-lock"}));
    try t.expectError(error.BadSet, sets_mod.Sets.parse(a, &.{"/x=pins-lock"}));
    try t.expectError(error.BadSet, sets_mod.Sets.parse(a, &.{"x/=pins-lock"}));
    try t.expectError(error.BadSet, sets_mod.Sets.parse(a, &.{"x=other"}));
    try t.expectError(error.BadSet, sets_mod.Sets.parse(a, &.{"x"}));
    var many: [9][]const u8 = undefined;
    for (&many, 0..) |*m, i| m.* = try std.fmt.allocPrint(a, "d{d}=pins-lock", .{i});
    try t.expectError(error.TooManySets, sets_mod.Sets.parse(a, &many));
}

test "sets: a pull request may touch package.json, package-lock.json and the table of a set, by exact name only" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const s = try sets(a);
    const ok = [_][]const u8{ "site/package.json", "site/package-lock.json", "site/buildrules.lock.bzl", "service/api/package.json", "service/api/pins.lock.bzl" };
    for (ok) |p| try t.expect(try s.prMayTouch(a, p));
    const no = [_][]const u8{ "site/BUCK", ".github/workflows/ci.yml", "site/pins.lock.bzl", "service/api/buildrules.lock.bzl", "site/package.json.bak", "Site/package.json", "site/sub/package.json", "package.json", "site/buildrules.bzl" };
    for (no) |p| try t.expect(!try s.prMayTouch(a, p));
}

fn entry(name: []const u8, data: []const u8) zip.Entry {
    return .{ .name = name, .data = data };
}

fn manifestFor(a: std.mem.Allocator, data: []const u8) !manifest.Manifest {
    const digest = try ctxm.sha256Hex(a, data);
    const files = try a.dupe(manifest.File, &.{.{ .path = "site/buildrules.lock.bzl", .sha256 = digest }});
    return .{ .pr = 7, .head_sha = head, .base_sha = base, .files = files };
}

test "members: pairs members with the manifest and with SETS, and the path to write comes from the set" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const m = try manifestFor(a, "table");
    const got = try manifest.members(a, m, &.{ entry("manifest.json", "{}"), entry("site/buildrules.lock.bzl", "table") }, try sets(a));
    try t.expectEqual(@as(usize, 1), got.len);
    try t.expectEqual(@as(usize, 0), got[0].set);
    try t.expectEqualStrings("table", got[0].bytes);
    try t.expectEqualStrings("{}", try manifest.manifestText(&.{ entry("manifest.json", "{}"), entry("x", "") }));
    try t.expectError(error.NoManifest, manifest.manifestText(&.{entry("x", "")}));
}

test "members: bytes whose sha256 is not the manifest's are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const m = try manifestFor(a, "table");
    try t.expectError(error.Sha256Mismatch, manifest.members(a, m, &.{ entry("manifest.json", "{}"), entry("site/buildrules.lock.bzl", "tablE") }, try sets(a)));
}

test "members: a member the manifest does not list is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const m = try manifestFor(a, "table");
    try t.expectError(error.MemberNotListed, manifest.members(a, m, &.{ entry("manifest.json", "{}"), entry("site/buildrules.lock.bzl", "table"), entry("service/api/pins.lock.bzl", "x") }, try sets(a)));
}

test "members: a listed file with no member is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const m = try manifestFor(a, "table");
    try t.expectError(error.ListedFileMissing, manifest.members(a, m, &.{entry("manifest.json", "{}")}, try sets(a)));
}

test "members: a listed name that is no SETS output is refused even with a good digest" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const digest = try ctxm.sha256Hex(a, "x");
    const files = try a.dupe(manifest.File, &.{.{ .path = ".github/workflows/ci.yml", .sha256 = digest }});
    const m = manifest.Manifest{ .pr = 7, .head_sha = head, .base_sha = base, .files = files };
    try t.expectError(error.MemberNotInSets, manifest.members(a, m, &.{ entry("manifest.json", "{}"), entry(".github/workflows/ci.yml", "x") }, try sets(a)));
}

test "manifest: every pr that is not a plain integer in 1..999999999 is refused, whatever its spelling" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const bad_prs = [_][]const u8{ "0", "-1", "1000000000", "99999999999999999999", "9999999999999999", "1.0", "1e3", "\"7\"", "01", "-0", "7.", "+7", "0x7", "null", "true", "[7]", "1E2", "999999999999999" };
    for (bad_prs) |p| {
        if (parseWith(a, try prManifest(a, p))) |m| {
            std.debug.print("accepted pr {s} as {d}\n", .{ p, m.pr });
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    for ([_][]const u8{ "1", "999999999", " 7 " }) |p| _ = try parseWith(a, try prManifest(a, p));
}

test "manifest: nesting that is too deep, an invalid byte in a string, and paths that only look like a SETS output are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var deep = std.ArrayList(u8).empty;
    try deep.appendSlice(a, "{\"pr\":7,\"x\":");
    try deep.appendNTimes(a, '[', 200000);
    if (parseWith(a, deep.items)) |_| return error.TestUnexpectedResult else |_| {}
    const inv = "{\"pr\":7,\"head_sha\":\"" ++ head ++ "\",\"base_sha\":\"" ++ base ++ "\",\"files\":[{\"path\":\"site/buildrules.lock.bzl\xff\",\"sha256\":\"" ++ sha_a ++ "\"}]}";
    if (parseWith(a, inv)) |_| return error.TestUnexpectedResult else |_| {}
    const paths = [_][]const u8{ "site/buildrules.lock.bzl ", "Site/buildrules.lock.bzl", "./site/buildrules.lock.bzl", "site//buildrules.lock.bzl", "site/buildrules.lock.bzl/", "site/../site/buildrules.lock.bzl", "site/buildrules.lock.bzl\\n" };
    for (paths) |p| {
        const text = try std.fmt.allocPrint(a, "{{\"pr\":7,\"head_sha\":\"{s}\",\"base_sha\":\"{s}\",\"files\":[{{\"path\":\"{s}\",\"sha256\":\"{s}\"}}]}}", .{ head, base, p, sha_a });
        if (parseWith(a, text)) |_| {
            std.debug.print("accepted path {s}\n", .{p});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "json: a one-byte change anywhere in a valid manifest never crashes the reader" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var i: usize = 0;
    while (i < good.len) : (i += 1) {
        var c: u16 = 0;
        while (c < 256) : (c += 1) {
            const tmp = try a.dupe(u8, good);
            tmp[i] = @intCast(c);
            _ = parseWith(a, tmp) catch {};
        }
    }
}

const oom = @import("autopin_oom_test.zig");

test "oom: reading a manifest and pairing it with its members fails closed at every allocation" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const mt = try manifest.render(a, try manifestFor(a, "table"));
    const run = struct {
        fn f(al: std.mem.Allocator, args: anytype) !bool {
            const s = try sets(al);
            const m = manifest.parse(al, args.text, s) catch return true;
            const entries = [_]zip.Entry{ .{ .name = "manifest.json", .data = args.text }, .{ .name = "site/buildrules.lock.bzl", .data = "table" } };
            _ = manifest.members(al, m, &entries, s) catch return true;
            _ = manifest.render(al, m) catch return true;
            return false;
        }
    }.f;
    try oom.sweep(run, .{ .text = mt });
}
