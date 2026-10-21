const std = @import("std");
const fetch = @import("fetch.zig");

const EMPTY = "sha512-z4PhNX7vuL3xVChQ1m2AB9Yg5AULVxXcg/SpIdNs6c5H0NE8XYXysP+DGNKHfuwvY7kxvUdBeoGlODJ6+SfaPg==";

test "parseSri: the known digest of empty input round-trips" {
    const d = try fetch.parseSri(EMPTY);
    try std.testing.expectEqualStrings(EMPTY, &fetch.sriOf(d));
}

test "parseSri: refuses wrong algorithm, short digests and bad base64" {
    try std.testing.expectError(error.BadSri, fetch.parseSri("sha256-z4PhNX7vuL3xVChQ1m2AB9Yg5AULVxXcg/SpIdNs6c5H0NE8XYXysP+DGNKHfuwvY7kxvUdBeoGlODJ6+SfaPg=="));
    try std.testing.expectError(error.BadSri, fetch.parseSri("sha512-AAAA"));
    try std.testing.expectError(error.BadSri, fetch.parseSri("sha512-!!!!"));
    try std.testing.expectError(error.BadSri, fetch.parseSri(""));
}

test "hostAllowed: exact host, any port, case-insensitive" {
    const allow = [_][]const u8{"registry.npmjs.org"};
    try std.testing.expect(fetch.hostAllowed("https://registry.npmjs.org/ms/-/ms-2.1.3.tgz", &allow));
    try std.testing.expect(fetch.hostAllowed("https://Registry.NPMJS.org:443/x", &allow));
}

test "hostAllowed: a lookalike, a suffix, a userinfo trick and another scheme are refused" {
    const allow = [_][]const u8{"registry.npmjs.org"};
    try std.testing.expect(!fetch.hostAllowed("https://registry.npmjs.org.evil.example/x", &allow));
    try std.testing.expect(!fetch.hostAllowed("https://evilregistry.npmjs.org/x", &allow));
    try std.testing.expect(!fetch.hostAllowed("https://registry.npmjs.org@evil.example/x", &allow));
    try std.testing.expect(!fetch.hostAllowed("https://evil.example/registry.npmjs.org", &allow));
    try std.testing.expect(!fetch.hostAllowed("ftp://registry.npmjs.org/x", &allow));
    try std.testing.expect(!fetch.hostAllowed("https:///x", &allow));
    try std.testing.expect(!fetch.hostAllowed("https://10.0.0.1/x", &allow));
}

test "resolveRedirect: absolute, same-origin path, and a relative path refused" {
    const a = std.testing.allocator;
    const abs = try fetch.resolveRedirect(a, "https://h.example/a", "https://o.example/b");
    defer a.free(abs);
    try std.testing.expectEqualStrings("https://o.example/b", abs);
    const rel = try fetch.resolveRedirect(a, "https://h.example:8443/a/b?q=1", "/c");
    defer a.free(rel);
    try std.testing.expectEqualStrings("https://h.example:8443/c", rel);
    try std.testing.expectError(error.BadUrl, fetch.resolveRedirect(a, "https://h.example/a", "c"));
}

test "publish: matching bytes are written, with no part file left" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const want = try fetch.parseSri(EMPTY);
    var got: [64]u8 = undefined;
    try std.testing.expectEqual(fetch.Published.published, try fetch.publish(tmp.dir, "out.tgz", "", want, &got));
    _ = try tmp.dir.statFile("out.tgz");
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("out.tgz.part"));
}

test "publish: one wrong byte writes nothing and reports what was computed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const want = try fetch.parseSri(EMPTY);
    var got: [64]u8 = undefined;
    try std.testing.expectEqual(fetch.Published.mismatch, try fetch.publish(tmp.dir, "out.tgz", "x", want, &got));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("out.tgz"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("out.tgz.part"));
    try std.testing.expect(!std.mem.eql(u8, &got, &want));
}

test "publish: a digest wrong only in the last byte is a mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var want = try fetch.parseSri(EMPTY);
    want[63] ^= 1;
    var got: [64]u8 = undefined;
    try std.testing.expectEqual(fetch.Published.mismatch, try fetch.publish(tmp.dir, "o", "", want, &got));
}

test "dataPayload: base64 data URL decodes; other forms are refused" {
    const a = std.testing.allocator;
    const got = try fetch.dataPayload(a, "data:application/octet-stream;base64,aGVsbG8K");
    defer a.free(got);
    try std.testing.expectEqualStrings("hello\n", got);
    try std.testing.expectError(error.BadUrl, fetch.dataPayload(a, "data:,hello"));
    try std.testing.expectError(error.BadUrl, fetch.dataPayload(a, "https://h.example/x"));
    try std.testing.expectError(error.BadUrl, fetch.dataPayload(a, "data:;base64,!!!"));
}
