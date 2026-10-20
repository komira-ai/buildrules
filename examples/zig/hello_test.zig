const std = @import("std");
const hello = @import("hello.zig");

test "greeting is exactly what the program prints" {
    try std.testing.expectEqualStrings("hello from zig\n", hello.greeting());
}
