//! The passing tests of zig_cover_exe_test.zig: they reach the negative and the positive arm of `classify` and not the zero arm.
const std = @import("std");
const mini = @import("mini.zig");

test "negative" {
    try std.testing.expectEqualStrings("negative", mini.classify(-3));
}

test "positive" {
    try std.testing.expectEqualStrings("positive", mini.classify(7));
}

test "a skipped test is not a failure" {
    return error.SkipZigTest;
}
