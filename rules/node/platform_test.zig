const std = @import("std");
const platform = @import("platform.zig");

fn list(a: std.mem.Allocator, text: []const u8) !std.json.Value {
    return (try std.json.parseFromSlice(std.json.Value, a, text, .{})).value;
}

test "ok: no list, an empty list and a list naming the platform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(platform.ok(null, "linux"));
    try std.testing.expect(platform.ok(try list(a, "[]"), "linux"));
    try std.testing.expect(platform.ok(try list(a, "[\"linux\"]"), "linux"));
    try std.testing.expect(platform.ok(try list(a, "[\"darwin\",\"linux\"]"), "linux"));
}

test "ok: a list that does not name the platform refuses it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(!platform.ok(try list(a, "[\"darwin\"]"), "linux"));
    try std.testing.expect(!platform.ok(try list(a, "[\"arm64\"]"), "x64"));
}

test "ok: a refusal list allows the rest and a refused platform stays refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(platform.ok(try list(a, "[\"!win32\"]"), "linux"));
    try std.testing.expect(!platform.ok(try list(a, "[\"!linux\"]"), "linux"));
    try std.testing.expect(!platform.ok(try list(a, "[\"linux\",\"!linux\"]"), "linux"));
    // a refusal of the platform before or after an allowed name; `!` alone refuses nothing (the name after it is empty)
    try std.testing.expect(!platform.ok(try list(a, "[\"!linux\",\"linux\"]"), "linux"));
    try std.testing.expect(platform.ok(try list(a, "[\"!\"]"), "linux"));
    // refusals of other platforms do not make the platform one of the allowed names
    try std.testing.expect(platform.ok(try list(a, "[\"!win32\",\"!darwin\"]"), "linux"));
}

test "ok: a field that is not a list, and members that are not strings, are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // not an array: no restriction is read from it
    try std.testing.expect(platform.ok(try list(a, "\"darwin\""), "linux"));
    try std.testing.expect(platform.ok(try list(a, "{\"os\":[\"darwin\"]}"), "linux"));
    try std.testing.expect(platform.ok(try list(a, "null"), "linux"));
    // members that are not strings name nothing: a list of them allows everything, beside a name it still decides
    try std.testing.expect(platform.ok(try list(a, "[1,true,null]"), "linux"));
    try std.testing.expect(!platform.ok(try list(a, "[1,\"darwin\"]"), "linux"));
    try std.testing.expect(platform.ok(try list(a, "[1,\"linux\"]"), "linux"));
    // an empty name is a name, and it is not this platform
    try std.testing.expect(!platform.ok(try list(a, "[\"\"]"), "linux"));
}
