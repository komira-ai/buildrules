//! The strict lock reader, the table reader and the row-to-lock binding of `autopin`. The lock and the table are
//! untrusted: every test plants one defect and names what must refuse it.

const std = @import("std");
const lock = @import("autopin_lock.zig");
const sets_mod = @import("autopin_sets.zig");
const table = @import("autopin_table.zig");
const Diag = @import("diag.zig").Diag;
const t = std.testing;

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
    const bad = [_][]const u8{ "", "1", "1.0", "1.0.0." ++ "0", "01.0.0", "1.00.0", "1.0.0-", "1.0.0-01", "1.0.0-a..b", "1.0.0+", "1.0.0+a..b", "1.0.0-a_b", "v1.0.0", "1.0.0 ", "^1.0.0", "x" ** 65 };
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
    const good = [_][]const u8{ "left-pad", "@scope/pkg", "a", "A_b.c", "a.b", "x~y", "-x", "@s/n", "a-b_c.d-1" };
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
