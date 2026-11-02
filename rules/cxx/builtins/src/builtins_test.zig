//! The list of compiler builtins is exactly nine names, each matched whole.

const std = @import("std");
const B = @import("builtins.zig");

test "every builtin is one, and nothing near it is" {
    try std.testing.expectEqual(@as(usize, 9), B.names.len);
    for (B.names) |n| {
        try std.testing.expect(B.isBuiltin(n));
        try std.testing.expect(!B.isBuiltin(n[0 .. n.len - 1]));
        var buf: [32]u8 = undefined;
        const longer = try std.fmt.bufPrint(&buf, "{s}x", .{n});
        try std.testing.expect(!B.isBuiltin(longer));
        const lead = try std.fmt.bufPrint(&buf, "k_{s}", .{n});
        try std.testing.expect(!B.isBuiltin(lead));
    }
    try std.testing.expect(!B.isBuiltin(""));
    try std.testing.expect(!B.isBuiltin("memcpy"));
}
