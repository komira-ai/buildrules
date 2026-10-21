//! A test that leaks: the runner of a coverage build fails it, as zig's own runner does.
const std = @import("std");
const mini = @import("mini.zig");

test "leaks one byte" {
    _ = mini.classify(1);
    _ = try std.testing.allocator.alloc(u8, 1);
}
