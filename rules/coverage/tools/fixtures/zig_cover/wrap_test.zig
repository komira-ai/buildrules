//! The wrapping tests of zig_cover_exe_test.zig: the negative arm of `classify` runs 128 times in each of two tests, 256 times in all, which is what an 8-bit block
//! counter holds none of (it wraps to zero). The positive arm runs once.
const std = @import("std");
const mini = @import("mini.zig");

fn negatives(times: usize) !void {
    var n: i32 = -3;
    _ = &n;
    for (0..times) |_| try std.testing.expectEqualStrings("negative", mini.classify(n));
}

test "the negative arm, 128 times" {
    try negatives(128);
}

test "the negative arm, 128 times more" {
    try negatives(128);
}

test "the positive arm, once" {
    var n: i32 = 7;
    _ = &n;
    try std.testing.expectEqualStrings("positive", mini.classify(n));
}
