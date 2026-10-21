//! A test that logs an error and otherwise passes: the runner of a coverage build fails the run, as zig's own runner does.
const std = @import("std");
const mini = @import("mini.zig");

test "logs an error" {
    _ = mini.classify(1);
    std.log.err("an error that nobody expected", .{});
}
