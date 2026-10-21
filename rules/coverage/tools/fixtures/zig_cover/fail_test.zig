//! A test that fails: zig_cover must fail with it, and write no report.
const std = @import("std");
const mini = @import("mini.zig");

test "wrong answer" {
    try std.testing.expectEqualStrings("zero", mini.classify(7));
}
