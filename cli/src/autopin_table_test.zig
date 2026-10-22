//! The strict lock reader, the table reader and the row-to-lock binding of `autopin`. The lock and the table are
//! untrusted: every test plants one defect and names what must refuse it.

const std = @import("std");
const lock = @import("autopin_lock.zig");
const sets_mod = @import("autopin_sets.zig");
const sets = sets_mod;
const table = @import("autopin_table.zig");
const Diag = @import("diag.zig").Diag;
const t = std.testing;
const oom = @import("autopin_oom_test.zig");

const sri_a = "sha512-" ++ "A" ** 86 ++ "==";
const sri_b = "sha512-" ++ "B" ** 85 ++ "A==";
const sha_a = "a" ** 64;
const sha_b = "b" ** 64;
const reg = "https://registry.npmjs.org/";

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

const pad_pkg = "\"node_modules/left-pad\":{\"version\":\"1.3.0\",\"resolved\":\"" ++ reg ++ "left-pad/-/left-pad-1.3.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}";
const scope_pkg = "\"node_modules/@scope/pkg\":{\"version\":\"2.0.0\",\"resolved\":\"" ++ reg ++ "@scope/pkg/-/pkg-2.0.0.tgz\",\"integrity\":\"" ++ sri_b ++ "\",\"os\":[\"darwin\"]}";

fn lockWith(a: std.mem.Allocator, extra: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"name\":\"demo\",\"lockfileVersion\":3,\"packages\":{{\"\":{{\"name\":\"demo\"}},{s},{s}{s}}}}}", .{ pad_pkg, scope_pkg, extra });
}

/// What `lock.read` says about `text`: the entries and the number of problems.
fn readLock(a: std.mem.Allocator, text: []const u8, diag: *Diag) ![]lock.Entry {
    return lock.read(a, text, diag);
}

fn expectRefused(extra: []const u8, needle: []const u8) !void {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    oom.mustSweep(struct {
        fn f(al: std.mem.Allocator, args: anytype) !bool {
            var d = Diag.init(al);
            _ = try lock.read(al, try lockWith(al, args.extra), &d);
            return d.count() > 0;
        }
    }.f, .{ .extra = extra });
    var diag = Diag.init(a);
    _ = try readLock(a, try lockWith(a, extra), &diag);
    try t.expect(diag.count() > 0);
    var named = false;
    for (diag.msgs.items) |m| if (std.mem.indexOf(u8, m, needle) != null) {
        named = true;
    };
    if (!named) {
        std.debug.print("no message names {s}: {s}\n", .{ needle, if (diag.msgs.items.len > 0) diag.msgs.items[0] else "(none)" });
    }
    try t.expect(named);
}

test "lock: a registry lock reads, sorted, with the canonical url derived and the platform lists kept" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var diag = Diag.init(a);
    const got = try readLock(a, try lockWith(a, ""), &diag);
    try t.expectEqual(@as(usize, 0), diag.count());
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("@scope/pkg@2.0.0", got[0].key);
    try t.expectEqualStrings(reg ++ "@scope/pkg/-/pkg-2.0.0.tgz", got[0].url);
    try t.expectEqualStrings("darwin", got[0].os.?[0]);
    try t.expectEqualStrings("left-pad@1.3.0", got[1].key);
    try t.expectEqualStrings(reg ++ "left-pad/-/left-pad-1.3.0.tgz", got[1].url);
    try t.expect(got[1].os == null);
}

test "lock: the same name@version at two paths is one entry" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var diag = Diag.init(a);
    const same = ",\"node_modules/x/node_modules/left-pad\":{\"version\":\"1.3.0\",\"resolved\":\"" ++ reg ++ "left-pad/-/left-pad-1.3.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}";
    const got = try readLock(a, try lockWith(a, same), &diag);
    // node_modules/x has no entry of its own, which is fine: the path is a chain of node_modules/<name> segments.
    try t.expectEqual(@as(usize, 0), diag.count());
    try t.expectEqual(@as(usize, 2), got.len);
}

test "lock: the same name@version at two paths with different integrities is refused, naming both paths" {
    try expectRefused(",\"node_modules/x/node_modules/left-pad\":{\"version\":\"1.3.0\",\"resolved\":\"" ++ reg ++ "left-pad/-/left-pad-1.3.0.tgz\",\"integrity\":\"" ++ sri_b ++ "\"}", "node_modules/x/node_modules/left-pad");
}

test "lock: a resolved url that is not the canonical registry url is refused" {
    try expectRefused(",\"node_modules/a\":{\"version\":\"1.0.0\",\"resolved\":\"https://evil.example/a/-/a-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "node_modules/a");
    try expectRefused(",\"node_modules/a\":{\"version\":\"1.0.0\",\"resolved\":\"" ++ reg ++ "a/-/a-1.0.0.tgz?x=1\",\"integrity\":\"" ++ sri_a ++ "\"}", "node_modules/a");
    try expectRefused(",\"node_modules/a\":{\"version\":\"1.0.0\",\"resolved\":\"" ++ reg ++ "a/-/a-1.0.1.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "node_modules/a");
    try expectRefused(",\"node_modules/a\":{\"version\":\"1.0.0\",\"resolved\":\"http://registry.npmjs.org/a/-/a-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "node_modules/a");
}

test "lock: a resolved url whose name is another package's is refused (name and url disagree)" {
    try expectRefused(",\"node_modules/a\":{\"version\":\"1.0.0\",\"resolved\":\"" ++ reg ++ "b/-/b-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "node_modules/a");
}

test "lock: a scoped package's file name is the base name, not scope/name" {
    try expectRefused(",\"node_modules/@s/a\":{\"version\":\"1.0.0\",\"resolved\":\"" ++ reg ++ "@s/a/-/@s/a-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "node_modules/@s/a");
}

test "lock: an alias (name differs from the path's) is refused" {
    try expectRefused(",\"node_modules/alias\":{\"name\":\"real\",\"version\":\"1.0.0\",\"resolved\":\"" ++ reg ++ "real/-/real-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "alias");
}

test "lock: a bundled entry is refused, naming the path" {
    try expectRefused(",\"node_modules/b\":{\"version\":\"1.0.0\",\"inBundle\":true}", "node_modules/b");
}

test "lock: a bundled entry that has a tarball is refused too" {
    try expectRefused(",\"node_modules/b\":{\"version\":\"1.0.0\",\"inBundle\":true,\"resolved\":\"" ++ reg ++ "b/-/b-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "node_modules/b");
}

test "lock: a link is refused" {
    try expectRefused(",\"node_modules/l\":{\"resolved\":\"packages/l\",\"link\":true}", "node_modules/l");
    try expectRefused(",\"node_modules/l2\":{\"version\":\"1.0.0\",\"resolved\":\"" ++ reg ++ "l2/-/l2-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\",\"link\":true}", "node_modules/l2");
}

test "lock: a git dependency is refused" {
    try expectRefused(",\"node_modules/g\":{\"version\":\"1.0.0\",\"resolved\":\"git+ssh://git@github.com/o/g.git#abc\"}", "node_modules/g");
}

test "lock: a file: dependency is refused" {
    try expectRefused(",\"node_modules/f\":{\"version\":\"1.0.0\",\"resolved\":\"file:../f\"}", "node_modules/f");
    try expectRefused(",\"node_modules/f2\":{\"version\":\"1.0.0\",\"resolved\":\"file:../f\",\"integrity\":\"" ++ sri_a ++ "\"}", "node_modules/f2");
}

test "lock: a workspace member is refused" {
    try expectRefused(",\"packages/w\":{\"name\":\"w\",\"version\":\"1.0.0\"}", "packages/w");
}

test "lock: an entry with no integrity, or a sha1 integrity, is refused" {
    try expectRefused(",\"node_modules/n\":{\"version\":\"1.0.0\",\"resolved\":\"" ++ reg ++ "n/-/n-1.0.0.tgz\"}", "node_modules/n");
    try expectRefused(",\"node_modules/s1\":{\"version\":\"1.0.0\",\"resolved\":\"" ++ reg ++ "s1/-/s1-1.0.0.tgz\",\"integrity\":\"sha1-qUwiJOvKwEeCoNkDVSHyRzW37JI=\"}", "node_modules/s1");
}

test "lock: a version that is not strict semver is refused" {
    const bad = [_][]const u8{ "^1.0.0", "1.0", "01.0.0", "1.0.0-01", "v1.0.0", "latest", "1.0.0 ", "1.0.0+", "1.0.0." ++ "0" };
    for (bad) |v| {
        var ar = arena();
        defer ar.deinit();
        const a = ar.allocator();
        const extra = try std.fmt.allocPrint(a, ",\"node_modules/v\":{{\"version\":\"{s}\",\"resolved\":\"{s}v/-/v-{s}.tgz\",\"integrity\":\"{s}\"}}", .{ v, reg, v, sri_a });
        var diag = Diag.init(a);
        _ = try readLock(a, try lockWith(a, extra), &diag);
        try t.expect(diag.count() > 0);
    }
}

test "lock: semver, as semver.org writes it" {
    const good = [_][]const u8{ "1.0.0", "0.0.1", "10.20.30", "1.0.0-rc.1", "1.0.0-alpha-1.2", "1.0.0+build.5", "1.2.3-0.3.7+exp.sha.5114f85", "1.0.0-0" };
    for (good) |v| try t.expect(lock.isStrictSemver(v));
    const bad = [_][]const u8{ "", "1", "1.0", "1.0.0." ++ "0", "1..0", ".1.0", "1.0.0+a_b", "1.0.0+a b", "01.0.0", "1.00.0", "1.0.0-", "1.0.0-01", "1.0.0-a..b", "1.0.0+", "1.0.0+a..b", "1.0.0-a_b", "v1.0.0", "1.0.0 ", "^1.0.0", "x" ** 65 };
    for (bad) |v| try t.expect(!lock.isStrictSemver(v));
}

test "lock: not JSON, not an object, not lockfileVersion 3, no packages are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const bad = [_][]const u8{ "{", "[]", "{\"lockfileVersion\":2,\"packages\":{}}", "{\"lockfileVersion\":3}", "{\"lockfileVersion\":3,\"packages\":[]}", "{\"lockfileVersion\":3,\"packages\":{\"node_modules/a\":1}}" };
    for (bad) |text| {
        var diag = Diag.init(a);
        _ = try readLock(a, text, &diag);
        try t.expect(diag.count() > 0);
    }
}

const hdr = "# header\n\nPINS = {}\n\n";

fn row(a: std.mem.Allocator, key: []const u8, name: []const u8, version: []const u8, url: []const u8, sri: []const u8, sha: []const u8, size: []const u8, extra: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "    \"{s}\": {{\n        \"name\": \"{s}\",\n        \"version\": \"{s}\",\n        \"url\": \"{s}\",\n        \"sri512\": \"{s}\",\n        \"sha256\": \"{s}\",\n        \"size\": {s},\n{s}    }},\n", .{ key, name, version, url, sri, sha, size, extra });
}

fn padRow(a: std.mem.Allocator) ![]u8 {
    return row(a, "left-pad@1.3.0", "left-pad", "1.3.0", reg ++ "left-pad/-/left-pad-1.3.0.tgz", sri_a, sha_a, "11", "");
}

fn scopeRow(a: std.mem.Allocator, extra: []const u8) ![]u8 {
    return row(a, "@scope/pkg@2.0.0", "@scope/pkg", "2.0.0", reg ++ "@scope/pkg/-/pkg-2.0.0.tgz", sri_b, sha_b, "22", extra);
}

fn block(a: std.mem.Allocator, rows: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, "NPM = {\n");
    for (rows) |r| try out.appendSlice(a, r);
    try out.appendSlice(a, "}\n");
    return out.items;
}

fn parseBlock(a: std.mem.Allocator, text: []const u8, kind: sets_mod.Kind, diag: *Diag) ![]table.Row {
    return table.parseRows(a, text, kind, diag);
}

fn expectBadBlock(text: []const u8, kind: sets_mod.Kind) !void {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    oom.mustSweep(struct {
        fn f(al: std.mem.Allocator, args: anytype) !bool {
            var d = Diag.init(al);
            _ = table.parseRows(al, args.text, args.kind, &d) catch return true;
            return d.count() > 0;
        }
    }.f, .{ .text = text, .kind = kind });
    var diag = Diag.init(a);
    try t.expectError(error.BadNpmBlock, parseBlock(a, text, kind, &diag));
    try t.expect(diag.count() > 0);
}

test "table: reads the rows of both kinds, with platform lists only in a buildrules table" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var diag = Diag.init(a);
    const text = try block(a, &.{ try scopeRow(a, "        \"os\": [\"darwin\", \"linux\"],\n        \"libc\": [\"glibc\"],\n"), try padRow(a) });
    const rows = try parseBlock(a, text, .buildrules_lock, &diag);
    try t.expectEqual(@as(usize, 2), rows.len);
    try t.expectEqualStrings("darwin", rows[0].os.?[0]);
    try t.expectEqualStrings("linux", rows[0].os.?[1]);
    try t.expect(rows[0].cpu == null);
    try t.expectEqualStrings("glibc", rows[0].libc.?[0]);
    try t.expectEqual(@as(u64, 22), rows[0].size);
    try t.expectEqual(@as(usize, 0), (try parseBlock(a, "NPM = {}\n", .pins_lock, &diag)).len);
    try t.expectEqual(@as(usize, 0), diag.count());
    try expectBadBlock(text, .pins_lock);
}

test "table: a statement standing in a row's header, over a complete row body, is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const body = "        \"name\": \"left-pad\",\n        \"version\": \"1.3.0\",\n        \"url\": \"" ++ reg ++ "left-pad/-/left-pad-1.3.0.tgz\",\n        \"sri512\": \"" ++ sri_a ++ "\",\n        \"sha256\": \"" ++ sha_a ++ "\",\n        \"size\": 11,\n    },\n";
    try expectBadBlock(try std.mem.concat(a, u8, &.{ "NPM = {\n", "    load(\"//evil:x.bzl\", \"y\")\n", body, "}\n" }), .pins_lock);
    try expectBadBlock(try std.mem.concat(a, u8, &.{ "NPM = {\n", "    native.genrule(name = \"x\")\n", body, "}\n" }), .pins_lock);
}

test "table: text after the block (a call, a blank line) is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const good_row = try padRow(a);
    try expectBadBlock(try std.mem.concat(a, u8, &.{ "NPM = {\n", good_row, "}\nnative.genrule()\n" }), .pins_lock);
}

test "table: a blank line after the block is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectBadBlock(try std.mem.concat(a, u8, &.{ "NPM = {\n", try padRow(a), "}\n\n" }), .pins_lock);
}

test "table: a block with no closing brace, or a second one, is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectBadBlock(try std.mem.concat(a, u8, &.{ "NPM = {\n", try padRow(a) }), .pins_lock);
    try expectBadBlock("NPM = {}\nload(\"x\")\n", .pins_lock);
    try expectBadBlock("NPM = {\n}\n}\n", .pins_lock);
}

test "table: a block that does not open with NPM = { is refused" {
    try expectBadBlock("NPM = []\n", .pins_lock);
    try expectBadBlock("", .pins_lock);
}

test "table: an extra field is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectBadBlock(try block(a, &.{try row(a, "left-pad@1.3.0", "left-pad", "1.3.0", reg ++ "left-pad/-/left-pad-1.3.0.tgz", sri_a, sha_a, "11", "        \"extra\": \"x\",\n")}), .pins_lock);
}

test "table: platform lists in a pins.lock.bzl table are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectBadBlock(try block(a, &.{try row(a, "left-pad@1.3.0", "left-pad", "1.3.0", reg ++ "left-pad/-/left-pad-1.3.0.tgz", sri_a, sha_a, "11", "        \"os\": [\"darwin\"],\n")}), .pins_lock);
}

test "table: a reordered field is refused" {
    const swapped = "NPM = {\n    \"left-pad@1.3.0\": {\n        \"version\": \"1.3.0\",\n        \"name\": \"left-pad\",\n        \"url\": \"" ++ reg ++ "left-pad/-/left-pad-1.3.0.tgz\",\n        \"sri512\": \"" ++ sri_a ++ "\",\n        \"sha256\": \"" ++ sha_a ++ "\",\n        \"size\": 11,\n    },\n}\n";
    try expectBadBlock(swapped, .pins_lock);
}

test "table: a missing field is refused" {
    const missing = "NPM = {\n    \"left-pad@1.3.0\": {\n        \"name\": \"left-pad\",\n        \"version\": \"1.3.0\",\n        \"url\": \"" ++ reg ++ "left-pad/-/left-pad-1.3.0.tgz\",\n        \"sri512\": \"" ++ sri_a ++ "\",\n        \"size\": 11,\n    },\n}\n";
    try expectBadBlock(missing, .pins_lock);
}

test "table: a changed indent is refused" {
    const indent = "NPM = {\n  \"left-pad@1.3.0\": {\n        \"name\": \"left-pad\",\n    },\n}\n";
    try expectBadBlock(indent, .pins_lock);
}

test "table: rows out of order are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectBadBlock(try block(a, &.{ try padRow(a), try scopeRow(a, "") }), .pins_lock);
}

test "table: a key twice is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectBadBlock(try block(a, &.{ try padRow(a), try padRow(a) }), .pins_lock);
}

test "table: a key that is not name@version is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectBadBlock(try block(a, &.{try row(a, "left-pad@1.3.1", "left-pad", "1.3.0", reg ++ "left-pad/-/left-pad-1.3.0.tgz", sri_a, sha_a, "11", "")}), .pins_lock);
}

test "table: values outside their sets are refused (name, version, url, sha512, sha256, size)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const u = reg ++ "left-pad/-/left-pad-1.3.0.tgz";
    try expectBadBlock(try block(a, &.{try row(a, "l pad@1.3.0", "l pad", "1.3.0", u, sri_a, sha_a, "11", "")}), .pins_lock);
    try expectBadBlock(try block(a, &.{try row(a, "left-pad@^1.3.0", "left-pad", "^1.3.0", u, sri_a, sha_a, "11", "")}), .pins_lock);
    try expectBadBlock(try block(a, &.{try row(a, "left-pad@1.3.0", "left-pad", "1.3.0", "ftp://x/y", sri_a, sha_a, "11", "")}), .pins_lock);
    try expectBadBlock(try block(a, &.{try row(a, "left-pad@1.3.0", "left-pad", "1.3.0", u, "sha512-short", sha_a, "11", "")}), .pins_lock);
    try expectBadBlock(try block(a, &.{try row(a, "left-pad@1.3.0", "left-pad", "1.3.0", u, sri_a, "A" ** 64, "11", "")}), .pins_lock);
    try expectBadBlock(try block(a, &.{try row(a, "left-pad@1.3.0", "left-pad", "1.3.0", u, sri_a, sha_a, "011", "")}), .pins_lock);
    try expectBadBlock(try block(a, &.{try row(a, "left-pad@1.3.0", "left-pad", "1.3.0", u, sri_a, sha_a, "-1", "")}), .pins_lock);
    try expectBadBlock(try block(a, &.{try row(a, "left-pad@1.3.0", "left-pad", "1.3.0", u, sri_a, sha_a, "67108865", "")}), .pins_lock);
    try expectBadBlock(try block(a, &.{try row(a, "left-pad@1.3.0", "left-pad", "1.3.0", u, sri_a, sha_a, "1234567890123", "")}), .pins_lock);
    try expectBadBlock(try block(a, &.{try row(a, "left-pad@1.3.0\\", "left-pad", "1.3.0", u, sri_a, sha_a, "11", "")}), .pins_lock);
    var okd = Diag.init(a);
    const ok = try parseBlock(a, try block(a, &.{try row(a, "left-pad@1.3.0", "left-pad", "1.3.0", u, sri_a, sha_a, "67108864", "")}), .pins_lock, &okd);
    try t.expectEqual(@as(u64, 67108864), ok[0].size);
}

test "table: a bad platform list is refused (empty, unquoted, outside the token set)" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try expectBadBlock(try block(a, &.{try scopeRow(a, "        \"os\": [],\n")}), .buildrules_lock);
    try expectBadBlock(try block(a, &.{try scopeRow(a, "        \"os\": [darwin],\n")}), .buildrules_lock);
    try expectBadBlock(try block(a, &.{try scopeRow(a, "        \"os\": [\"da rwin\"],\n")}), .buildrules_lock);
    try expectBadBlock(try block(a, &.{try scopeRow(a, "        \"cpu\": [\"x64\"],\n        \"os\": [\"darwin\"],\n")}), .buildrules_lock);
}

test "table: split finds the NPM block after the prefix" {
    const s = table.split("# h\n\nPINS = {}\n\nNPM = {}\n").?;
    try t.expectEqualStrings("# h\n\nPINS = {}\n\n", s.prefix);
    try t.expectEqualStrings("NPM = {}\n", s.npm);
    try t.expect(table.split("# no block\n") == null);
}

fn entriesAndRows(a: std.mem.Allocator, kind: sets_mod.Kind, row_extra: []const u8) !struct { entries: []lock.Entry, rows: []table.Row } {
    var diag = Diag.init(a);
    const entries = try lock.read(a, try lockWith(a, ""), &diag);
    const text = try block(a, &.{ try scopeRow(a, row_extra), try padRow(a) });
    const rows = try table.parseRows(a, text, kind, &diag);
    try t.expectEqual(@as(usize, 0), diag.count());
    return .{ .entries = entries, .rows = rows };
}

fn expectBound(a: std.mem.Allocator, entries: []const lock.Entry, rows: []const table.Row, kind: sets_mod.Kind, needle: ?[]const u8) !void {
    oom.mustSweep(struct {
        fn f(al: std.mem.Allocator, args: anytype) !bool {
            var d = Diag.init(al);
            try table.bind(al, args.entries, args.rows, args.kind, &d);
            return d.count() > 0;
        }
    }.f, .{ .entries = entries, .rows = rows, .kind = kind });
    var diag = Diag.init(a);
    try table.bind(a, entries, rows, kind, &diag);
    if (needle) |n| {
        try t.expect(diag.count() > 0);
        var named = false;
        for (diag.msgs.items) |m| if (std.mem.indexOf(u8, m, n) != null) {
            named = true;
        };
        if (!named) std.debug.print("no message has {s}: {s}\n", .{ n, if (diag.msgs.items.len > 0) diag.msgs.items[0] else "(none)" });
        try t.expect(named);
    } else try t.expectEqual(@as(usize, 0), diag.count());
}

test "bind: rows and lock entries pair one to one" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try entriesAndRows(a, .buildrules_lock, "        \"os\": [\"darwin\"],\n");
    try expectBound(a, p.entries, p.rows, .buildrules_lock, null);
}

test "bind: a row whose url is not the canonical url of its name and version is refused, whatever the lock says" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try entriesAndRows(a, .pins_lock, "");
    const rows = try a.dupe(table.Row, p.rows);
    rows[1].url = "https://evil.example/left-pad/-/left-pad-1.3.0.tgz";
    try expectBound(a, p.entries, rows, .pins_lock, "left-pad@1.3.0");
    // The URL of the lock entry is derived, so even a row that copies a hostile lock URL cannot pass.
    rows[1].url = reg ++ "left-pad/-/left-pad-1.3.0.tgz?evil=1";
    try expectBound(a, p.entries, rows, .pins_lock, "left-pad@1.3.0");
}

test "bind: a row whose name or version differs from the entry's is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try entriesAndRows(a, .pins_lock, "");
    const rows = try a.dupe(table.Row, p.rows);
    rows[1].name = "left-padx";
    rows[1].url = reg ++ "left-padx/-/left-padx-1.3.0.tgz"; // consistent with the new name, so only the name check can refuse it
    try expectBound(a, p.entries, rows, .pins_lock, "left-pad@1.3.0");
}

test "bind: a row whose sri512 is not the lock's integrity is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try entriesAndRows(a, .pins_lock, "");
    const rows = try a.dupe(table.Row, p.rows);
    rows[0].sri512 = sri_a;
    try expectBound(a, p.entries, rows, .pins_lock, "@scope/pkg@2.0.0");
}

test "bind: a lock entry with no row is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try entriesAndRows(a, .pins_lock, "");
    try expectBound(a, p.entries, p.rows[1..], .pins_lock, "@scope/pkg@2.0.0 is in package-lock.json");
    try expectBound(a, p.entries, p.rows[0..1], .pins_lock, "left-pad@1.3.0 is in package-lock.json");
}

test "bind: a row with no lock entry is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try entriesAndRows(a, .pins_lock, "");
    try expectBound(a, p.entries[0..1], p.rows, .pins_lock, "left-pad@1.3.0 has a row in the table and no entry");
    try expectBound(a, &.{}, p.rows, .pins_lock, "has a row");
}

test "bind: platform lists must equal the lock's in a buildrules table" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try entriesAndRows(a, .buildrules_lock, "        \"os\": [\"darwin\"],\n");
    const rows = try a.dupe(table.Row, p.rows);
    rows[0].os = &.{"linux"};
    try expectBound(a, p.entries, rows, .buildrules_lock, "os, cpu or libc");
    rows[0].os = null;
    try expectBound(a, p.entries, rows, .buildrules_lock, "os, cpu or libc");
    rows[0].os = &.{"darwin"};
    rows[1].cpu = &.{"arm64"};
    try expectBound(a, p.entries, rows, .buildrules_lock, "os, cpu or libc");
}

test "fresh pins table: the prefix is kept byte for byte and the block is re-emitted, and it reads back" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try entriesAndRows(a, .pins_lock, "");
    const text = try table.freshPins(a, hdr, p.rows);
    try t.expect(std.mem.startsWith(u8, text, hdr));
    const sp = table.split(text).?;
    try t.expectEqualStrings(hdr, sp.prefix);
    var diag = Diag.init(a);
    const again = try table.parseRows(a, sp.npm, .pins_lock, &diag);
    try t.expectEqual(@as(usize, 2), again.len);
    try t.expectEqualStrings(text, try table.freshPins(a, hdr, again));
    try t.expectEqualStrings("NPM = {}\n", try table.emitPinsNpm(a, &.{}));
}

test "fresh buildrules table: PACKAGE comes from package.json, never from the artifact, and the digests are the files'" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try entriesAndRows(a, .buildrules_lock, "        \"os\": [\"darwin\"],\n");
    const pj = "{\"name\":\"demo\",\"version\":\"1.0.0\",\"scripts\":{\"test\":\"jest\"},\"buildrules\":{\"dist\":\"dist\"}}";
    const lk = try lockWith(a, "");
    var diag = Diag.init(a);
    const text = (try table.freshBuildrules(a, pj, lk, p.rows, &diag)).?;
    try t.expectEqual(@as(usize, 0), diag.count());
    try t.expect(std.mem.indexOf(u8, text, "\"test\": \"jest\"") != null);
    try t.expect(std.mem.indexOf(u8, text, "\"left-pad@1.3.0\": {") != null);
    try t.expect(std.mem.indexOf(u8, text, "PACKAGE_LOCK_SHA256 = \"") != null);
    const sp = table.split(text).?;
    const back = try table.parseRows(a, sp.npm, .buildrules_lock, &diag);
    try t.expectEqual(@as(usize, 2), back.len);
    // A package.json the generator refuses gives no table.
    var diag2 = Diag.init(a);
    try t.expect((try table.freshBuildrules(a, "{\"workspaces\":[\"a\"]}", lk, p.rows, &diag2)) == null);
    try t.expect(diag2.count() > 0);
}

test "lock: a path over 512 bytes, a name that is not a string, and an entry with no version are refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const long = try std.fmt.allocPrint(a, "node_modules/{s}/node_modules/{s}/node_modules/{s}", .{ "a" ** 200, "b" ** 200, "c" ** 200 });
    const entry = try std.fmt.allocPrint(a, ",\"{s}\":{{\"version\":\"1.0.0\",\"resolved\":\"{s}{s}/-/{s}-1.0.0.tgz\",\"integrity\":\"{s}\"}}", .{ long, reg, "c" ** 200, "c" ** 200, sri_a });
    try expectRefused(entry, "longer than 512");
    try expectRefused(",\"node_modules/n\":{\"name\":5,\"version\":\"1.0.0\",\"resolved\":\"" ++ reg ++ "n/-/n-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "not a string");
    try expectRefused(",\"node_modules/n\":{\"resolved\":\"" ++ reg ++ "n/-/n-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "no version");
}

test "table: a block that stops in the middle of its first line is refused" {
    try expectBadBlock("NPM = {", .pins_lock);
}

test "table: a row with an extra field and no closing line, followed by a row header, is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // Without the check for the row's closing line, the extra line would be taken for it and the next header would read as a row.
    const open_a = "    \"@scope/pkg@2.0.0\": {\n        \"name\": \"@scope/pkg\",\n        \"version\": \"2.0.0\",\n        \"url\": \"" ++ reg ++ "@scope/pkg/-/pkg-2.0.0.tgz\",\n        \"sri512\": \"" ++ sri_b ++ "\",\n        \"sha256\": \"" ++ sha_b ++ "\",\n        \"size\": 22,\n        \"extra\": \"swallowed\",\n";
    try expectBadBlock(try std.mem.concat(a, u8, &.{ "NPM = {\n", open_a, try padRow(a), "}\n" }), .pins_lock);
}

test "table: a statement whose middle reads as a row key, over a complete row body, is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const body = "        \"name\": \"left-pad\",\n        \"version\": \"1.3.0\",\n        \"url\": \"" ++ reg ++ "left-pad/-/left-pad-1.3.0.tgz\",\n        \"sri512\": \"" ++ sri_a ++ "\",\n        \"sha256\": \"" ++ sha_a ++ "\",\n        \"size\": 11,\n    },\n";
    // The key is read from the characters between the first five and the last four: here exactly left-pad@1.3.0.
    try expectBadBlock(try std.mem.concat(a, u8, &.{ "NPM = {\n", "    (left-pad@1.3.0)xyz\n", body, "}\n" }), .pins_lock);
}

test "npm names: an optional scope and one segment are accepted" {
    const good = [_][]const u8{ "left-pad", "@scope/pkg", "a", "A_b.c", "a.b", "x~y", "@s/n", "a-b_c.d-1" };
    for (good) |n| try t.expect(lock.isNpmName(n));
}

test "npm names: a name may not start with . or _ (nor the scope, nor the name after it)" {
    for ([_][]const u8{ "_x", ".x", "@_s/n", "@s/.n", "@s/_n" }) |n| try t.expect(!lock.isNpmName(n));
}

test "npm names: the scope is a segment of its own, and a bare @ or @scope is no name" {
    for ([_][]const u8{ "@", "@s", "@s/", "@/n", "@s s/n", "@s\"/n" }) |n| try t.expect(!lock.isNpmName(n));
}

test "npm names: at most 214 bytes, and not empty" {
    try t.expect(lock.isNpmName("x" ** 214));
    try t.expect(!lock.isNpmName("x" ** 215));
    try t.expect(!lock.isNpmName(""));
}

test "npm names: no further slash, no plus, no at-sign in the middle, no quote or space" {
    for ([_][]const u8{ "a/./b", "a/b/c", "a/b", "@s/n/m", "a@b", "a+b", "a/-/b", "a b", "a\"b", "a..b/c" }) |n| try t.expect(!lock.isNpmName(n));
}

test "lock: a path whose package name is not an npm name is refused" {
    const R = "https://registry.npmjs.org/";
    try expectRefused(",\"node_modules/a/b/c\":{\"version\":\"1.0.0\",\"resolved\":\"" ++ R ++ "a/b/c/-/c-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "node_modules/a/b/c");
    try expectRefused(",\"node_modules/@s/n/m\":{\"version\":\"1.0.0\",\"resolved\":\"" ++ R ++ "@s/n/m/-/m-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "node_modules/@s/n/m");
    try expectRefused(",\"node_modules/_x\":{\"version\":\"1.0.0\",\"resolved\":\"" ++ R ++ "_x/-/_x-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "node_modules/_x");
    try expectRefused(",\"node_modules/a+b\":{\"version\":\"1.0.0\",\"resolved\":\"" ++ R ++ "a+b/-/a+b-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "node_modules/a+b");
    try expectRefused(",\"node_modules/node_modules/x\":{\"version\":\"1.0.0\",\"resolved\":\"" ++ R ++ "x/-/x-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "node_modules/node_modules/x");
    try expectRefused(",\"node_modules/a+b/node_modules/x\":{\"version\":\"1.0.0\",\"resolved\":\"" ++ R ++ "x/-/x-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "node_modules/a+b/node_modules/x");
}

test "lock: a nested node_modules chain of valid names is accepted" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var diag = Diag.init(a);
    const R = "https://registry.npmjs.org/";
    const got = try readLock(a, try lockWith(a, ",\"node_modules/a/node_modules/@s/b\":{\"version\":\"1.0.0\",\"resolved\":\"" ++ R ++ "@s/b/-/b-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}"), &diag);
    try t.expectEqual(@as(usize, 0), diag.count());
    try t.expectEqual(@as(usize, 3), got.len);
}

test "lock: the resolved url must be exactly the derived one (host case, trailing dot, encoding, query, fragment, scheme)" {
    const R = "https://registry.npmjs.org/";
    const sri = sri_a;
    const cases = [_][3][]const u8{
        .{ "node_modules/@s/n", R ++ "@s/n/-/@s/n-1.0.0.tgz", "1.0.0" },
        .{ "node_modules/@s/n", R ++ "%40s%2fn/-/n-1.0.0.tgz", "1.0.0" },
        .{ "node_modules/a", "https://REGISTRY.npmjs.org/a/-/a-1.0.0.tgz", "1.0.0" },
        .{ "node_modules/a", "https://registry.npmjs.org./a/-/a-1.0.0.tgz", "1.0.0" },
        .{ "node_modules/a", R ++ "a/-/a-1.0.0.tgz#sha1=ab", "1.0.0" },
        .{ "node_modules/a", R ++ "a/-/a-1.0.tgz", "1.0" },
        .{ "node_modules/a", R ++ "a/-/a-v1.0.0.tgz", "v1.0.0" },
        .{ "node_modules/a", R ++ "a/-/a-1.0.0-.tgz", "1.0.0-" },
        .{ "node_modules/a", R ++ "a/-/a-1.0.0-01.tgz", "1.0.0-01" },
        .{ "node_modules/a", R ++ "a/-/a-1.0.0+.tgz", "1.0.0+" },
        .{ "node_modules/a", R ++ "a/-/a-1.0.0-a..b.tgz", "1.0.0-a..b" },
        .{ "node_modules/a/node_modules", R ++ "a/-/a-1.0.0.tgz", "1.0.0" },
        .{ "node_modules/../x", R ++ "../x/-/x-1.0.0.tgz", "1.0.0" },
    };
    for (cases) |c| {
        var ar = arena();
        defer ar.deinit();
        const a = ar.allocator();
        var diag = Diag.init(a);
        const entry = try std.fmt.allocPrint(a, ",\"{s}\":{{\"version\":\"{s}\",\"resolved\":\"{s}\",\"integrity\":\"{s}\"}}", .{ c[0], c[2], c[1], sri });
        _ = try readLock(a, try lockWith(a, entry), &diag);
        if (diag.count() == 0) std.debug.print("accepted {s} {s} {s}\n", .{ c[0], c[1], c[2] });
        try t.expect(diag.count() > 0);
    }
}

test "lock: very deep nesting is refused, not a stack overflow" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var s = std.ArrayList(u8).empty;
    try s.appendSlice(a, "{\"lockfileVersion\":3,\"packages\":{\"\":{},\"node_modules/x\":{\"version\":");
    try s.appendNTimes(a, '[', 300000);
    var d = Diag.init(a);
    const e = try lock.read(a, s.items, &d);
    try t.expectEqual(@as(usize, 0), e.len);
    try t.expect(d.count() > 0);
    try t.expect(kit_contains(d.msgs.items[0], "nests deeper"));
}

fn kit_contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}



test "oom: reading a lock, reading and binding a table, and making fresh tables fail closed at every allocation" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const lock_text = try lockWith(a, "");
    const pj = "{\"name\":\"demo\",\"version\":\"1.0.0\",\"scripts\":{\"test\":\"jest\"},\"buildrules\":{\"dist\":\"dist\"}}";
    const rows_text = try block(a, &.{ try scopeRow(a, "        \"os\": [\"darwin\"],\n"), try padRow(a) });
    const run = struct {
        fn f(al: std.mem.Allocator, args: anytype) !bool {
            var diag = Diag.init(al);
            const entries = try lock.read(al, args.lock, &diag);
            if (diag.count() > 0) return true;
            const rows = table.parseRows(al, args.rows, .buildrules_lock, &diag) catch return true;
            if (diag.count() > 0) return true;
            try table.bind(al, entries, rows, .buildrules_lock, &diag);
            const fresh = (try table.freshBuildrules(al, args.pj, args.lock, rows, &diag)) orelse return true;
            if (diag.count() > 0) return true;
            const sp = table.split(fresh) orelse return true;
            _ = try table.freshPins(al, sp.prefix, rows);
            _ = try table.emitPinsNpm(al, rows);
            return diag.count() > 0;
        }
    }.f;
    var diag = Diag.init(a);
    _ = try lock.read(a, lock_text, &diag);
    try t.expectEqual(@as(usize, 0), diag.count());
    try oom.sweep(run, .{ .lock = lock_text, .rows = rows_text, .pj = pj });
}

test "oom: a lock and a table that are refused are refused at every allocation too" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const bad = try lockWith(a, ",\"node_modules/x\":{\"name\":\"y\",\"version\":\"1.0.0\",\"resolved\":\"x\",\"integrity\":\"y\"},\"node_modules/g\":{\"version\":\"1.0.0\"}");
    const run = struct {
        fn f(al: std.mem.Allocator, args: anytype) !bool {
            var diag = Diag.init(al);
            _ = try lock.read(al, args.lock, &diag);
            return diag.count() > 0;
        }
    }.f;
    try oom.sweep(run, .{ .lock = bad });
    const bad_rows = try std.mem.concat(a, u8, &.{ "NPM = {\n", try padRow(a), try padRow(a), "}\n" });
    const run_rows = struct {
        fn f(al: std.mem.Allocator, args: anytype) !bool {
            var diag = Diag.init(al);
            _ = table.parseRows(al, args.rows, .pins_lock, &diag) catch return true;
            return diag.count() > 0;
        }
    }.f;
    try oom.sweep(run_rows, .{ .rows = bad_rows });
}

test "oom: SETS parsing and matching fail closed at every allocation" {
    const run = struct {
        fn f(al: std.mem.Allocator, _: void) !bool {
            const s = try sets.Sets.parse(al, &.{ "site=buildrules-lock", "infra/x=pins-lock" });
            _ = try s.outputIndex(al, "infra/x/pins.lock.bzl");
            _ = try s.prMayTouch(al, "site/package.json");
            _ = try s.prMayTouch(al, "elsewhere");
            _ = try sets.Sets.tablePath(al, s.items[0]);
            return false;
        }
    }.f;
    try oom.sweep(run, {});
}

test "lock: an integrity of 88 base64 characters that decode to more than 64 bytes is refused, not decoded into a 64-byte buffer" {
    const valid = @import("valid.zig");
    // No padding: 88 characters are 66 bytes. One padding character: 65. Padding in the middle. Each used to overrun the buffer.
    try t.expect(!valid.isSri512("sha512-" ++ "A" ** 88));
    try t.expect(!valid.isSri512("sha512-" ++ "A" ** 87 ++ "="));
    try t.expect(!valid.isSri512("sha512-" ++ "A" ** 40 ++ "==" ++ "A" ** 46));
    try t.expect(valid.isSri512("sha512-" ++ "A" ** 86 ++ "=="));
    const R = "https://registry.npmjs.org/";
    try expectRefused(",\"node_modules/x\":{\"version\":\"1.0.0\",\"resolved\":\"" ++ R ++ "x/-/x-1.0.0.tgz\",\"integrity\":\"sha512-" ++ "A" ** 88 ++ "\"}", "integrity is not a sha512");
}

test "table: a block cut at any byte is refused, and a block with any one byte replaced never crashes the reader" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const text = try block(a, &.{ try scopeRow(a, "        \"os\": [\"darwin\", \"linux\"],\n        \"cpu\": [\"x64\"],\n        \"libc\": [\"glibc\"],\n"), try padRow(a) });
    for (0..text.len) |cut| {
        var diag = Diag.init(a);
        try t.expectError(error.BadNpmBlock, table.parseRows(a, text[0..cut], .buildrules_lock, &diag));
    }
    const mutated = try a.dupe(u8, text);
    for ([_]u8{ 'x', '"', '\n', '0', ' ', ',' }) |with| {
        for (0..text.len) |i| {
            mutated[i] = with;
            var diag = Diag.init(a);
            _ = table.parseRows(a, mutated, .buildrules_lock, &diag) catch {};
            var diag2 = Diag.init(a);
            _ = table.parseRows(a, mutated, .pins_lock, &diag2) catch {};
            mutated[i] = text[i];
        }
    }
}

test "fresh buildrules table: a diagnostic already raised (by the binding) gives no table" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const p = try entriesAndRows(a, .buildrules_lock, "        \"os\": [\"darwin\"],\n");
    const pj = "{\"name\":\"demo\",\"version\":\"1.0.0\",\"scripts\":{\"test\":\"jest\"},\"buildrules\":{\"dist\":\"dist\"}}";
    var diag = Diag.init(a);
    diag.add("something already wrong", .{});
    try t.expect((try table.freshBuildrules(a, pj, try lockWith(a, ""), p.rows, &diag)) == null);
}

test "table: a platform list may hold a negated token, and a list of another length than the lock's is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const text = try block(a, &.{try scopeRow(a, "        \"libc\": [\"!musl\", \"glibc\"],\n")});
    var diag = Diag.init(a);
    const rows = try table.parseRows(a, text, .buildrules_lock, &diag);
    try t.expectEqualStrings("!musl", rows[0].libc.?[0]);
    const p = try entriesAndRows(a, .buildrules_lock, "        \"os\": [\"darwin\"],\n");
    const longer = try a.dupe(table.Row, p.rows);
    longer[0].os = &.{ "darwin", "linux" };
    try expectBound(a, p.entries, longer, .buildrules_lock, "os, cpu or libc");
}

test "npm names: a name may not start with a hyphen (a bare name, the scope, or the name after it)" {
    for ([_][]const u8{ "-x", "--x", "@-s/n", "@s/-n" }) |n| try t.expect(!lock.isNpmName(n));
    try t.expect(lock.isNpmName("a-"));
    try t.expect(lock.isNpmName("a-b"));
}

/// What an npm 10 lock holds for aws-cdk-lib: the package with its tarball and `bundleDependencies`, and under it the packages it bundles
/// (`inBundle`, no `resolved`, no `integrity`), some of them with bundled packages of their own.
const cdk_lib = "\"node_modules/aws-cdk-lib\":{\"version\":\"2.150.0\",\"resolved\":\"" ++ reg ++ "aws-cdk-lib/-/aws-cdk-lib-2.150.0.tgz\",\"integrity\":\"" ++ sri_a ++
    "\",\"bundleDependencies\":[\"@balena/dockerignore\",\"ajv\",\"table\",\"@scope/inner\"],\"license\":\"Apache-2.0\",\"engines\":{\"node\":\">= 14.15.0\"},\"peerDependencies\":{\"constructs\":\"^10.0.0\"}}";
const cdk_bundled = ",\"node_modules/aws-cdk-lib/node_modules/@balena/dockerignore\":{\"version\":\"1.0.2\",\"inBundle\":true,\"license\":\"Apache-2.0\"}" ++
    ",\"node_modules/aws-cdk-lib/node_modules/ajv\":{\"version\":\"8.17.1\",\"inBundle\":true,\"license\":\"MIT\",\"dependencies\":{\"fast-deep-equal\":\"^3.1.3\"}}" ++
    ",\"node_modules/aws-cdk-lib/node_modules/table\":{\"version\":\"6.8.2\",\"inBundle\":true,\"bundleDependencies\":[\"ajv\"],\"license\":\"BSD-3-Clause\"}" ++
    ",\"node_modules/aws-cdk-lib/node_modules/table/node_modules/ajv\":{\"version\":\"8.12.0\",\"inBundle\":true,\"license\":\"MIT\"}" ++
    ",\"node_modules/aws-cdk-lib/node_modules/@scope/inner\":{\"version\":\"1.0.0\",\"inBundle\":true}";

test "lock: the packages an aws-cdk-lib-shaped lock bundles need no row, and the package that bundles them is read as usual" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var diag = Diag.init(a);
    const text = try lockWith(a, "," ++ cdk_lib ++ cdk_bundled);
    const entries = try readLock(a, text, &diag);
    try t.expectEqual(@as(usize, 0), diag.count());
    // left-pad, @scope/pkg and aws-cdk-lib: nothing of what is bundled.
    try t.expectEqual(@as(usize, 3), entries.len);
    var found = false;
    for (entries) |e| found = found or std.mem.eql(u8, e.key, "aws-cdk-lib@2.150.0");
    try t.expect(found);
    for (entries) |e| try t.expect(std.mem.indexOf(u8, e.path, "aws-cdk-lib/") == null);
}

test "lock: a bundled package whose parent chain does not reach a package with a tarball is refused" {
    // No parent at all (top level), a parent that is not in the lock, and a chain with a gap.
    try expectRefused(",\"node_modules/b\":{\"version\":\"1.0.0\",\"inBundle\":true}", "node_modules/b");
    try expectRefused(",\"node_modules/ghost/node_modules/b\":{\"version\":\"1.0.0\",\"inBundle\":true}", "does not reach");
    try expectRefused(",\"node_modules/ghost/node_modules/mid/node_modules/b\":{\"version\":\"1.0.0\",\"inBundle\":true},\"node_modules/ghost/node_modules/mid\":{\"version\":\"1.0.0\",\"inBundle\":true}", "does not reach");
    // A parent that is itself refused (a git dependency) is no tarball either.
    try expectRefused(",\"node_modules/g\":{\"version\":\"1.0.0\",\"resolved\":\"git+ssh://git@github.com/o/g.git#abc\"},\"node_modules/g/node_modules/b\":{\"version\":\"1.0.0\",\"inBundle\":true}", "does not reach");
    // A parent that is a link.
    try expectRefused(",\"node_modules/l\":{\"resolved\":\"../l\",\"link\":true},\"node_modules/l/node_modules/b\":{\"version\":\"1.0.0\",\"inBundle\":true}", "does not reach");
}

test "lock: a bundled package under a real one is still refused when it is a link, an alias, or names a tarball" {
    try expectRefused("," ++ cdk_lib ++ ",\"node_modules/aws-cdk-lib/node_modules/b\":{\"resolved\":\"../b\",\"link\":true,\"inBundle\":true}", "node_modules/aws-cdk-lib/node_modules/b");
    try expectRefused("," ++ cdk_lib ++ ",\"node_modules/aws-cdk-lib/node_modules/b\":{\"name\":\"c\",\"version\":\"1.0.0\",\"inBundle\":true}", "alias");
    try expectRefused("," ++ cdk_lib ++ ",\"node_modules/aws-cdk-lib/node_modules/b\":{\"version\":\"1.0.0\",\"inBundle\":true,\"resolved\":\"" ++ reg ++ "b/-/b-1.0.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}", "also names a tarball");
    try expectRefused("," ++ cdk_lib ++ ",\"node_modules/aws-cdk-lib/node_modules/b\":{\"version\":\"1.0.0\",\"bundled\":true}", "node_modules/aws-cdk-lib/node_modules/b");
    // A package of the lock that is not bundled and has no tarball stays refused, whatever is above it.
    try expectRefused("," ++ cdk_lib ++ ",\"node_modules/aws-cdk-lib/node_modules/b\":{\"version\":\"1.0.0\"}", "node_modules/aws-cdk-lib/node_modules/b");
}

const cdk_real_open = "\"node_modules/aws-cdk-lib\":{\"version\":\"2.150.0\",\"resolved\":\"" ++ reg ++ "aws-cdk-lib/-/aws-cdk-lib-2.150.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"";
const child_b = ",\"node_modules/aws-cdk-lib/node_modules/b\":{\"version\":\"6.6.6\",\"inBundle\":true}";

test "lock: a bundled flag the parent does not back is refused (npm reads bundleDependencies of the parent, never the child's flag)" {
    // The parent has no bundleDependencies at all: npm would fetch b from the registry by name and version, unpinned.
    try expectRefused("," ++ cdk_real_open ++ "}" ++ child_b, "bundleDependencies");
    // The parent lists only another package.
    try expectRefused("," ++ cdk_real_open ++ ",\"bundleDependencies\":[\"other\"]}" ++ child_b, "bundleDependencies");
    // An empty list, a list of non-strings, a string, false, and the other spelling with the wrong name.
    try expectRefused("," ++ cdk_real_open ++ ",\"bundleDependencies\":[]}" ++ child_b, "bundleDependencies");
    try expectRefused("," ++ cdk_real_open ++ ",\"bundleDependencies\":[7,null]}" ++ child_b, "bundleDependencies");
    try expectRefused("," ++ cdk_real_open ++ ",\"bundleDependencies\":\"b\"}" ++ child_b, "bundleDependencies");
    try expectRefused("," ++ cdk_real_open ++ ",\"bundleDependencies\":false}" ++ child_b, "bundleDependencies");
    try expectRefused("," ++ cdk_real_open ++ ",\"bundledDependencies\":[\"other\"]}" ++ child_b, "bundleDependencies");
}

test "lock: a parent that lists the child (an array holding its name, true, or the other spelling) backs the flag" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const parents = [_][]const u8{
        ",\"bundleDependencies\":[\"b\"]}",
        ",\"bundleDependencies\":[\"other\",\"b\"]}",
        ",\"bundleDependencies\":true}",
        ",\"bundledDependencies\":[\"b\"]}",
    };
    inline for (parents) |tail| {
        var diag = Diag.init(a);
        const entries = try readLock(a, try lockWith(a, "," ++ cdk_real_open ++ tail ++ child_b), &diag);
        try t.expectEqual(@as(usize, 0), diag.count());
        try t.expectEqual(@as(usize, 3), entries.len);
    }
}

test "lock: a scoped child is listed by its full name, and a name that is only the part after the slash is not enough" {
    const child = ",\"node_modules/aws-cdk-lib/node_modules/@s/inner\":{\"version\":\"1.0.0\",\"inBundle\":true}";
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var diag = Diag.init(a);
    _ = try readLock(a, try lockWith(a, "," ++ cdk_real_open ++ ",\"bundleDependencies\":[\"@s/inner\"]}" ++ child), &diag);
    try t.expectEqual(@as(usize, 0), diag.count());
    try expectRefused("," ++ cdk_real_open ++ ",\"bundleDependencies\":[\"inner\"]}" ++ child, "bundleDependencies");
    try expectRefused("," ++ cdk_real_open ++ ",\"bundleDependencies\":[\"@t/inner\"]}" ++ child, "bundleDependencies");
}

test "lock: in a chain every link must be listed by its own parent" {
    const mid = ",\"node_modules/aws-cdk-lib/node_modules/mid\":{\"version\":\"1.0.0\",\"inBundle\":true";
    const leaf = ",\"node_modules/aws-cdk-lib/node_modules/mid/node_modules/leaf\":{\"version\":\"1.0.0\",\"inBundle\":true}";
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var diag = Diag.init(a);
    _ = try readLock(a, try lockWith(a, "," ++ cdk_real_open ++ ",\"bundleDependencies\":[\"mid\"]}" ++ mid ++ ",\"bundleDependencies\":[\"leaf\"]}" ++ leaf), &diag);
    try t.expectEqual(@as(usize, 0), diag.count());
    // mid is listed by the real package, but leaf is not listed by mid.
    try expectRefused("," ++ cdk_real_open ++ ",\"bundleDependencies\":[\"mid\"]}" ++ mid ++ "}" ++ leaf, "leaf");
    try expectRefused("," ++ cdk_real_open ++ ",\"bundleDependencies\":[\"mid\"]}" ++ mid ++ ",\"bundleDependencies\":[\"other\"]}" ++ leaf, "leaf");
    // leaf is listed by mid, but mid is not listed by the real package: the whole chain is refused (leaf and mid both).
    try expectRefused("," ++ cdk_real_open ++ ",\"bundleDependencies\":[\"other\"]}" ++ mid ++ ",\"bundleDependencies\":[\"leaf\"]}" ++ leaf, "leaf");
    try expectRefused("," ++ cdk_real_open ++ ",\"bundleDependencies\":[\"other\"]}" ++ mid ++ ",\"bundleDependencies\":[\"leaf\"]}" ++ leaf, "mid");
}

test "lock: an absent middle node is not bridged (real/node_modules/mid/node_modules/b with mid missing)" {
    try expectRefused("," ++ cdk_real_open ++ ",\"bundleDependencies\":[\"mid\",\"b\"]},\"node_modules/aws-cdk-lib/node_modules/mid/node_modules/b\":{\"version\":\"1.0.0\",\"inBundle\":true}", "does not reach");
}
