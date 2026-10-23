const std = @import("std");
const sri = @import("sri.zig");

// The npm integrity of an empty file is the best-known sha512 SRI.
const EMPTY = "sha512-z4PhNX7vuL3xVChQ1m2AB9Yg5AULVxXcg/SpIdNs6c5H0NE8XYXysP+DGNKHfuwvY7kxvUdBeoGlODJ6+SfaPg==";

test "of: the sha512 of known bytes, in npm's form" {
    const got = try sri.of(std.testing.allocator, "");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(EMPTY, got);
}

test "of: one byte of difference is a different integrity" {
    const a = try sri.of(std.testing.allocator, "abc");
    defer std.testing.allocator.free(a);
    const b = try sri.of(std.testing.allocator, "abd");
    defer std.testing.allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

test "wellFormed: only sha512 of 64 bytes in base64" {
    try std.testing.expect(sri.wellFormed(EMPTY));
    try std.testing.expect(!sri.wellFormed("sha1-AAAAAAAAAAAAAAAAAAAAAAAAAAA="));
    try std.testing.expect(!sri.wellFormed("sha512-"));
    try std.testing.expect(!sri.wellFormed("sha512-AAAA"));
    try std.testing.expect(!sri.wellFormed("xsha512-" ++ EMPTY["sha512-".len..]));
    try std.testing.expect(!sri.wellFormed("sha512-" ++ "A" ** 86 ++ "=!"));
}

const tartest = @import("tartest.zig");

test "wellFormed: the padding, the alphabet and the length of the digest each decide" {
    try std.testing.expect(sri.wellFormed("sha512-" ++ "A" ** 86 ++ "=="));
    // 86 characters without their padding, and 87: not a base64 string at all
    try std.testing.expect(!sri.wellFormed("sha512-" ++ "A" ** 86));
    try std.testing.expect(!sri.wellFormed("sha512-" ++ "A" ** 87));
    // the right length with a character outside the alphabet
    try std.testing.expect(!sri.wellFormed("sha512-" ++ "A" ** 10 ++ "!" ++ "A" ** 75 ++ "=="));
    // 66 bytes of base64 and 63 bytes of base64 are well-formed base64 of the wrong digest size
    try std.testing.expect(!sri.wellFormed("sha512-" ++ "A" ** 88));
    try std.testing.expect(!sri.wellFormed("sha512-" ++ "A" ** 84));
}

test "of: what it makes is well-formed, 7 + 88 characters, and a different input is a different string" {
    const a = std.testing.allocator;
    const got = try sri.of(a, "a package");
    defer a.free(got);
    try std.testing.expectEqual(@as(usize, 7 + 88), got.len);
    try std.testing.expect(sri.wellFormed(got));
    try std.testing.expect(std.mem.endsWith(u8, got, "=="));
}

fn integrity(a: std.mem.Allocator, _: void) !void {
    _ = try sri.of(a, "a package");
}

test "of: an allocation that fails is an error, not a string" {
    try tartest.allocSweep(integrity, {});
}
