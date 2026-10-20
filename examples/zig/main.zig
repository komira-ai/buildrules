const std = @import("std");
const hello = @import("hello.zig");

// std.posix.write exists in every pinned zig (0.12.0 and 0.15.2); std.io.getStdOut does not (removed in 0.15).
pub fn main() !void {
    _ = try std.posix.write(1, hello.greeting());
}
