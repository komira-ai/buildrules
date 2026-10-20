const std = @import("std");
const hello = @import("hello.zig");

// std.posix.write exists in every pinned zig.
pub fn main() !void {
    _ = try std.posix.write(1, hello.greeting());
}
