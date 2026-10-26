//! The lock's one rendering: golden, canonical order, round trip, and that
//! nothing outside the safe character sets is ever written.

const std = @import("std");
const fx = @import("fixtures.zig");
const lockfmt = @import("lockfmt.zig");
const Diag = @import("diag.zig").Diag;
const t = std.testing;

const golden = @embedFile("example.lock.bzl");

fn example() lockfmt.Lock {
    const Files = struct {
        const list = [_]lockfmt.File{
            .{ .platform = "linux-x86_64", .url = "https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz", .sha256 = "c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad", .size = 45480516 },
            .{ .platform = "linux-aarch64", .url = "https://ziglang.org/download/0.12.0/zig-linux-aarch64-0.12.0.tar.xz", .sha256 = fx.ABC_SHA256, .size = 3 },
        };
        const pins = [_]lockfmt.LockPin{.{ .name = "zig", .version = "0.12.0", .files = &list }};
        const npm = [_]lockfmt.Npm{
            .{ .key = "left-pad@1.3.0", .name = "left-pad", .version = "1.3.0", .url = "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz", .sri512 = fx.ABC_SRI512, .sha256 = fx.ABC_SHA256, .size = 3 },
            .{ .key = "@scope/pkg@2.0.1", .name = "@scope/pkg", .version = "2.0.1", .url = "https://registry.npmjs.org/@scope/pkg/-/pkg-2.0.1.tgz", .sri512 = fx.ABC_SRI512, .sha256 = fx.ABC_SHA256, .size = 3 },
        };
    };
    return .{ .pins = &Files.pins, .npm = &Files.npm };
}

test "render is the committed golden (which Buck2 also loads: BUCK)" {
    const text = try lockfmt.render(t.allocator, example());
    defer t.allocator.free(text);
    try t.expectEqualStrings(golden, text);
}

test "render does not depend on the order entries were built in" {
    const lock = example();
    const rev_files = [_]lockfmt.File{ lock.pins[0].files[1], lock.pins[0].files[0] };
    const rev_pins = [_]lockfmt.LockPin{.{ .name = "zig", .version = "0.12.0", .files = &rev_files }};
    const rev_npm = [_]lockfmt.Npm{ lock.npm[1], lock.npm[0] };
    const a = try lockfmt.render(t.allocator, lock);
    defer t.allocator.free(a);
    const b = try lockfmt.render(t.allocator, .{ .pins = &rev_pins, .npm = &rev_npm });
    defer t.allocator.free(b);
    try t.expectEqualStrings(a, b);
}

test "the empty lock" {
    const text = try lockfmt.render(t.allocator, .{});
    defer t.allocator.free(text);
    try t.expect(std.mem.endsWith(u8, text, "PINS = {}\n\nNPM = {}\n"));
}

test "parse reads what render wrote" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var d = Diag.init(ar.allocator());
    const lock = try lockfmt.parse(ar.allocator(), golden, &d);
    try t.expectEqual(@as(usize, 1), lock.pins.len);
    try t.expectEqual(@as(usize, 2), lock.pins[0].files.len);
    try t.expectEqual(@as(u64, 45480516), lockfmt.findFile(lock.pins[0], "linux-x86_64").?.size);
    try t.expectEqualStrings(fx.ABC_SRI512, lock.findNpm("left-pad@1.3.0").?.sri512);
    const again = try lockfmt.render(ar.allocator(), lock);
    try t.expectEqualStrings(golden, again);
}

test "render refuses a value that could be code: a quote, a backslash, a newline, a space" {
    const bad_urls = [_][]const u8{
        "https://h.example/x\", \"pwn\": \"y",
        "https://h.example/x\\",
        "https://h.example/x\ny",
        "https://h.example/x y",
        "ftp://h.example/x",
        "https://",
    };
    for (bad_urls) |u| {
        const files = [_]lockfmt.File{.{ .platform = "p", .url = u, .sha256 = fx.ABC_SHA256, .size = 1 }};
        const pins = [_]lockfmt.LockPin{.{ .name = "a", .version = "1", .files = &files }};
        try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .pins = &pins }));
    }
    const files = [_]lockfmt.File{.{ .platform = "p", .url = "https://h.example/x", .sha256 = fx.ABC_SHA256, .size = 1 }};
    const bad_names = [_][]const u8{ "a\"b", "A", "a b", "" };
    for (bad_names) |n| {
        const pins = [_]lockfmt.LockPin{.{ .name = n, .version = "1", .files = &files }};
        try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .pins = &pins }));
    }
    // A sha256 must be 64 lower-case hex digits; a sha512 SRI is not one.
    const f2 = [_]lockfmt.File{.{ .platform = "p", .url = "https://h.example/x", .sha256 = fx.ABC_SRI512, .size = 1 }};
    const p2 = [_]lockfmt.LockPin{.{ .name = "a", .version = "1", .files = &f2 }};
    try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .pins = &p2 }));
    // npm: a key that is not name@version, a sha256 where the sri512 goes.
    var n = example().npm[0];
    n.key = "other@1.3.0";
    try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .npm = &.{n} }));
    n = example().npm[0];
    n.sri512 = fx.ABC_SHA256;
    try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .npm = &.{n} }));
    n = example().npm[0];
    n.sha256 = fx.ABC_SRI512;
    try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .npm = &.{n} }));
}

// The boundaries of valid.zig, each with the longest value that is accepted next to the shortest that is not: a check loosened by one is red on the refusal,
// a check tightened by one is red on the control.
fn renderFile(f: lockfmt.File) lockfmt.RenderError![]u8 {
    const files = [_]lockfmt.File{f};
    const pins = [_]lockfmt.LockPin{.{ .name = "a", .version = "1", .files = &files }};
    return lockfmt.render(t.allocator, .{ .pins = &pins });
}

fn renderNpm(n: lockfmt.Npm) lockfmt.RenderError![]u8 {
    return lockfmt.render(t.allocator, .{ .npm = &.{n} });
}

fn accepts(r: lockfmt.RenderError![]u8) !void {
    t.allocator.free(try r);
}

test "render: a sha256 is exactly 64 digits, not 65" {
    const ok = lockfmt.File{ .platform = "p", .url = "https://h.example/x", .sha256 = fx.ABC_SHA256, .size = 1 };
    try accepts(renderFile(ok));
    var f = ok;
    f.sha256 = fx.ABC_SHA256 ++ "0";
    try t.expectError(error.UnsafeValue, renderFile(f));
    f.sha256 = fx.ABC_SHA256[1..];
    try t.expectError(error.UnsafeValue, renderFile(f));
    var n = example().npm[0];
    try accepts(renderNpm(n));
    n.sha256 = fx.ABC_SHA256 ++ "0";
    try t.expectError(error.UnsafeValue, renderNpm(n));
}

test "render: a pin or platform name is at most 64 characters" {
    const ok = lockfmt.File{ .platform = "p" ** 64, .url = "https://h.example/x", .sha256 = fx.ABC_SHA256, .size = 1 };
    try accepts(renderFile(ok));
    var f = ok;
    f.platform = "p" ** 65;
    try t.expectError(error.UnsafeValue, renderFile(f));
    const files = [_]lockfmt.File{ok};
    const long = [_]lockfmt.LockPin{.{ .name = "a" ** 64, .version = "1", .files = &files }};
    t.allocator.free(try lockfmt.render(t.allocator, .{ .pins = &long }));
    const longer = [_]lockfmt.LockPin{.{ .name = "a" ** 65, .version = "1", .files = &files }};
    try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .pins = &longer }));
}

test "render: a url is at most 2048 characters, and has a host" {
    const prefix = "https://h.example/";
    const ok = lockfmt.File{ .platform = "p", .url = prefix ++ "a" ** (2048 - prefix.len), .sha256 = fx.ABC_SHA256, .size = 1 };
    try accepts(renderFile(ok));
    var f = ok;
    f.url = prefix ++ "a" ** (2049 - prefix.len);
    try t.expectError(error.UnsafeValue, renderFile(f));
    f.url = "https:///x";
    try t.expectError(error.UnsafeValue, renderFile(f));
    f.url = "http:///x";
    try t.expectError(error.UnsafeValue, renderFile(f));
}

test "render: a package name with an empty path segment is refused" {
    var n = example().npm[0];
    n.name = "a//b";
    n.key = "a//b@1.3.0";
    try t.expectError(error.UnsafeValue, renderNpm(n));
    n.name = "a/b";
    n.key = "a/b@1.3.0";
    try accepts(renderNpm(n));
}

test "render refuses a duplicate key" {
    const lock = example();
    const dup = [_]lockfmt.Npm{ lock.npm[0], lock.npm[0] };
    try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .npm = &dup }));
}

fn parseFails(text: []const u8) !void {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var d = Diag.init(ar.allocator());
    try t.expectError(error.Invalid, lockfmt.parse(ar.allocator(), text, &d));
    try t.expect(d.count() > 0);
}

test "parse refuses a lock that is not what render writes" {
    try parseFails("KPIN_LOCK_VERSION = 2\nPINS = {}\nNPM = {}\n");
    try parseFails("PINS = {}\nNPM = {}\n");
    try parseFails("KPIN_LOCK_VERSION = 1\nPINS = {}\nNPM = {}\nEVIL = {}\n");
    try parseFails("KPIN_LOCK_VERSION = 1\nPINS = {\"a\": {\"version\": \"1\", \"files\": {}, \"extra\": \"x\"}}\nNPM = {}\n");
    try parseFails("KPIN_LOCK_VERSION = 1\nPINS = {\"a\": {\"version\": \"1\", \"files\": {\"p\": {\"url\": \"https://h.example/x\", \"sha256\": \"zz\", \"size\": 1}}}}\nNPM = {}\n");
    try parseFails("KPIN_LOCK_VERSION = 1\nPINS = {}\nNPM = {\"a@1\": {\"name\": \"a\"}}\n");
    try parseFails("KPIN_LOCK_VERSION = 1\nPINS = {\"a\\\"\": {}}\nNPM = {}\n");
    try parseFails("KPIN_LOCK_VERSION = 1\nPINS = {\n");
}

test "render refuses an injection-shaped value in each emitted field" {
    const evil = "x\", \"pwn\": \"y";
    const base = example();
    // PINS: name, version, platform, url, sha256.
    var fields: usize = 0;
    inline for (.{ "name", "version" }) |f| {
        var p = base.pins[0];
        @field(p, f) = evil;
        try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .pins = &.{p} }));
        fields += 1;
    }
    inline for (.{ "platform", "url", "sha256" }) |f| {
        var file = base.pins[0].files[0];
        @field(file, f) = evil;
        var p = base.pins[0];
        p.files = &.{file};
        try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .pins = &.{p} }));
        fields += 1;
    }
    // A size the reader could not read as an integer.
    var file2 = base.pins[0].files[0];
    file2.size = std.math.maxInt(u64);
    var p2 = base.pins[0];
    p2.files = &.{file2};
    try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .pins = &.{p2} }));
    // NPM: key, name, version, url, sri512, sha256, size.
    inline for (.{ "key", "name", "version", "url", "sri512", "sha256" }) |f| {
        var n = base.npm[0];
        @field(n, f) = evil;
        try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .npm = &.{n} }));
        fields += 1;
    }
    var n2 = base.npm[0];
    n2.size = std.math.maxInt(u64);
    try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .npm = &.{n2} }));
    try t.expectEqual(@as(usize, 11), fields);
}

fn parseMutated(find: []const u8, replace: []const u8) !void {
    const text = try std.mem.replaceOwned(u8, t.allocator, golden, find, replace);
    defer t.allocator.free(text);
    try t.expect(!std.mem.eql(u8, text, golden)); // the edit applied
    try parseFails(text);
}

test "parse refuses a bad value in each field of the lock text" {
    try parseMutated("\"zig\": {", "\"Zig\": {");
    try parseMutated("\"version\": \"0.12.0\",", "\"version\": \"0.12.0 x\",");
    try parseMutated("\"linux-aarch64\": {", "\"linux aarch64\": {");
    try parseMutated("zig-linux-aarch64-0.12.0.tar.xz\",", "zig-linux-aarch64-0.12.0.tar.xz y\",");
    try parseMutated("c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad", "C7AE866B8A76A568E2D5CFD31FE89CDB629BDD161FDD5018B29A4A0A17045CAD");
    try parseMutated("\"size\": 45480516,", "\"size\": \"45480516\",");
    try parseMutated("\"left-pad@1.3.0\": {", "\"left-pad@1.3.1\": {");
    try parseMutated("\"name\": \"left-pad\",", "\"name\": \"left pad\",");
    try parseMutated("\"url\": \"https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz\",", "\"url\": \"ftp://registry.npmjs.org/left-pad.tgz\",");
    try parseMutated("3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw==", "3a81");
}

test "render sorts the pins by name, and refuses a pin or a platform written twice" {
    const base = example().pins[0];
    var a_pin = base;
    a_pin.name = "a-first";
    var b_pin = base;
    b_pin.name = "b-second";
    const forward = try lockfmt.render(t.allocator, .{ .pins = &.{ a_pin, b_pin } });
    defer t.allocator.free(forward);
    const backward = try lockfmt.render(t.allocator, .{ .pins = &.{ b_pin, a_pin } });
    defer t.allocator.free(backward);
    try t.expectEqualStrings(forward, backward);
    try t.expect(std.mem.indexOf(u8, forward, "a-first").? < std.mem.indexOf(u8, forward, "b-second").?);
    // Two pins of one name would be one key written twice: Starlark keeps the last, and the first would vanish.
    try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .pins = &.{ a_pin, a_pin } }));
    // The same for a platform inside a pin.
    var twice = base;
    twice.files = &.{ base.files[0], base.files[0] };
    try t.expectError(error.UnsafeValue, lockfmt.render(t.allocator, .{ .pins = &.{twice} }));
}

fn parseSays(text: []const u8, needle: []const u8) !void {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var d = Diag.init(ar.allocator());
    try t.expectError(error.Invalid, lockfmt.parse(ar.allocator(), text, &d));
    for (d.msgs.items) |m| if (std.mem.indexOf(u8, m, needle) != null) return;
    std.debug.print("no message holds `{s}`; messages:\n", .{needle});
    for (d.msgs.items) |m| std.debug.print("  {s}\n", .{m});
    return error.TestExpectedMessage;
}

const lock_head = "KPIN_LOCK_VERSION = 1\n";
const good_url = "\"url\": \"https://h.example/x\"";

test "parse says what is wrong with text that is not the literals render writes" {
    // Syntax: each refusal names what was expected.
    try parseSays(lock_head ++ "PINS = [\n", "expected a string, an integer or a { dict }");
    try parseSays(lock_head ++ "PINS = {\"a\" 1}\n", "expected `:`");
    try parseSays(lock_head ++ "PINS = {\"a\": 1 \"b\": 2}\n", "expected `,` or `}`");
    try parseSays(lock_head ++ "PINS = {1: 2}\n", "expected a string");
    try parseSays(lock_head ++ "PINS = {\"a\\b\": 1}\n", "a string has a backslash or a newline");
    try parseSays(lock_head ++ "PINS = {\"a\nb\": 1}\n", "a string has a backslash or a newline");
    try parseSays(lock_head ++ "PINS = {\"abc", "a string is not closed");
    try parseSays("KPIN_LOCK_VERSION = 99999999999999999999999\n", "integer out of range");
    try parseSays("KPIN_LOCK_VERSION =", "unexpected end of file");
    try parseSays("KPIN_LOCK_VERSION 1\n", "expected `NAME = value` at byte 0");
    try parseSays("= 1\n", "expected `NAME = value` at byte 0");
    // The version is an integer, not the string that looks like one.
    try parseSays("KPIN_LOCK_VERSION = \"1\"\nPINS = {}\nNPM = {}\n", "KPIN_LOCK_VERSION must be 1");
}

test "parse says which entry of the lock is wrong" {
    try parseSays(lock_head ++ "PINS = {\"a\": 5}\nNPM = {}\n", "PINS[a] is not a dict");
    try parseSays(lock_head ++ "PINS = {\"a\": {\"version\": 1, \"files\": {}}}\nNPM = {}\n", "PINS[a] has a bad name or version");
    // A file without its sha256.
    try parseSays(lock_head ++ "PINS = {\"a\": {\"version\": \"1\", \"files\": {\"p\": {" ++ good_url ++ ", \"size\": 1}}}}\nNPM = {}\n", "PINS[a][p] must have exactly url, sha256 and size");
    // A key written twice makes the count right and the keys known; the missing one is still missing.
    try parseSays(lock_head ++ "PINS = {\"a\": {\"version\": \"1\", \"files\": {\"p\": {" ++ good_url ++ ", " ++ good_url ++ ", \"size\": 1}}}}\nNPM = {}\n", "PINS[a][p] has a malformed field");
    try parseSays(lock_head ++ "PINS = {}\nNPM = {\"a@1\": 5}\n", "NPM[a@1] must have exactly name, version");
    try parseSays(lock_head ++ "PINS = {}\nNPM = {\"a@1\": {\"name\": \"a\", \"name\": \"a\", \"version\": \"1\", " ++ good_url ++ ", \"sri512\": \"" ++ fx.ABC_SRI512 ++ "\", \"size\": 1}}\n", "NPM[a@1] has a malformed field");
    // Every problem is reported, not the first.
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var d = Diag.init(ar.allocator());
    try t.expectError(error.Invalid, lockfmt.parse(ar.allocator(), lock_head ++ "PINS = {\"a\": 5, \"b\": 6}\nNPM = {\"c@1\": 7}\n", &d));
    try t.expectEqual(@as(usize, 3), d.count());
}

test "parse reads a lock with comments, tabs and carriage returns, and an empty one" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var d = Diag.init(ar.allocator());
    const lock = try lockfmt.parse(ar.allocator(), "# c\r\nKPIN_LOCK_VERSION\t=\t1 # trailing\r\nPINS = {}\r\nNPM = {}\r\n", &d);
    try t.expectEqual(@as(usize, 0), lock.pins.len);
    try t.expectEqual(@as(usize, 0), lock.npm.len);
    try t.expectEqual(@as(usize, 0), d.count());
}

test "parse reads a text that ends in an integer or in a comment, with no newline after it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var d = Diag.init(ar.allocator());
    const lock = try lockfmt.parse(ar.allocator(), "PINS = {}\nNPM = {}\nKPIN_LOCK_VERSION = 1", &d);
    try t.expectEqual(@as(usize, 0), lock.pins.len);
    var d2 = Diag.init(ar.allocator());
    _ = try lockfmt.parse(ar.allocator(), "KPIN_LOCK_VERSION = 1\n# the end", &d2);
    try t.expectEqual(@as(usize, 0), d2.count());
}

test "parse says where a string that is a value is not closed, and what a file entry that is not a dict lacks" {
    try parseSays(lock_head ++ "PINS = {\"a\": \"abc", "a string is not closed");
    try parseSays(lock_head ++ "PINS = {\"a\": {\"version\": \"1\", \"files\": {\"p\": 5}}}\nNPM = {}\n", "PINS[a][p] must have exactly url, sha256 and size");
}

test "a lock with no PINS or no NPM reads as empty there, and a lock whose files are not a dict is not the lock the inputs produce" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    var d = Diag.init(ar.allocator());
    const lock = try lockfmt.parse(ar.allocator(), lock_head, &d);
    try t.expectEqual(@as(usize, 0), lock.pins.len + lock.npm.len);
    const only_pins = try lockfmt.parse(ar.allocator(), lock_head ++ "PINS = {\"a\": {\"version\": \"1\", \"files\": {}}}\n", &d);
    try t.expectEqual(@as(usize, 1), only_pins.pins.len);
    try t.expectEqual(@as(usize, 0), only_pins.npm.len);
    // `files` that is a string reads as no files: the pin is there, with nothing in it, so a comparison against the inputs finds it wanting.
    const odd = try lockfmt.parse(ar.allocator(), lock_head ++ "PINS = {\"a\": {\"version\": \"1\", \"files\": \"x\"}}\nNPM = {}\n", &d);
    try t.expectEqual(@as(usize, 1), odd.pins.len);
    try t.expectEqual(@as(usize, 0), odd.pins[0].files.len);
    try t.expectEqual(@as(usize, 0), d.count());
}

/// A dict of the `keys` with `missing` left out and `dup` written a second time in its place: the count and the names are right, one value is not there.
fn dictWithout(a: std.mem.Allocator, comptime keys: []const []const u8, values: []const []const u8, missing: usize, dup: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(a, '{');
    for (keys, 0..) |k, i| {
        const at = if (i == missing) dup else i;
        try out.print(a, "\"{s}\": {s}, ", .{ keys[at], values[at] });
        _ = k;
    }
    try out.append(a, '}');
    return out.items;
}

test "parse refuses an entry in which a key is written twice for a key that is not there, whichever key it is" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const file_keys = [_][]const u8{ "url", "sha256", "size" };
    const file_vals = [_][]const u8{ "\"https://h.example/x\"", "\"" ++ fx.ABC_SHA256 ++ "\"", "3" };
    for (0..file_keys.len) |missing| {
        const dup: usize = if (missing == 0) 1 else 0;
        const f = try dictWithout(a, &file_keys, &file_vals, missing, dup);
        const text = try std.fmt.allocPrint(a, "{s}PINS = {{\"a\": {{\"version\": \"1\", \"files\": {{\"p\": {s}}}}}}}\nNPM = {{}}\n", .{ lock_head, f });
        try parseSays(text, "PINS[a][p] has a malformed field");
    }
    const npm_keys = [_][]const u8{ "name", "version", "url", "sri512", "sha256", "size" };
    const npm_vals = [_][]const u8{ "\"a\"", "\"1\"", "\"https://h.example/x\"", "\"" ++ fx.ABC_SRI512 ++ "\"", "\"" ++ fx.ABC_SHA256 ++ "\"", "3" };
    for (0..npm_keys.len) |missing| {
        const dup: usize = if (missing == 0) 1 else 0;
        const n = try dictWithout(a, &npm_keys, &npm_vals, missing, dup);
        const text = try std.fmt.allocPrint(a, "{s}PINS = {{}}\nNPM = {{\"a@1\": {s}}}\n", .{ lock_head, n });
        try parseSays(text, "NPM[a@1] has a malformed field");
    }
}
