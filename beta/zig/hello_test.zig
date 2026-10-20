const std = @import("std");
const hello = @import("hello.zig");

test "the greeting" {
    try std.testing.expectEqualStrings("Hello, world!\n", hello.greeting());
}
