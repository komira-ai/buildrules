//! files_check.zig: a file that changed, a file that is gone, a file that is right, and the output only on success.
const std = @import("std");
const C = @import("files_check.zig");
const t = std.testing;

fn sha(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
}

test "files_check: files that hash to the table's values are no mismatch" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "mopm.toml", .data = "[project]\nname = \"x\"\n" });
    try tmp.dir.writeFile(.{ .sub_path = "mopm-toolchain.toml", .data = "[toolchain]\nmojo = \"1.0.0\"\n" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    const p1 = try std.fmt.allocPrint(a, "{s}/mopm.toml", .{root});
    const p2 = try std.fmt.allocPrint(a, "{s}/mopm-toolchain.toml", .{root});
    const bad = try C.check(a, &.{ try sha(a, "[project]\nname = \"x\"\n"), p1, "mopm.toml", try sha(a, "[toolchain]\nmojo = \"1.0.0\"\n"), p2, "../mopm-toolchain.toml" });
    try t.expectEqual(@as(usize, 0), bad.items.len);
}

test "files_check: a file edited since the sync is named, with what it hashes to now" {
    // Defect: mojo = \"1.1.0\" in mopm-toolchain.toml and a green build of a table made for 1.0.0.
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "mopm-toolchain.toml", .data = "[toolchain]\nmojo = \"1.1.0\"\n" });
    const p = try std.fmt.allocPrint(a, "{s}/mopm-toolchain.toml", .{try tmp.dir.realpathAlloc(a, ".")});
    const was = try sha(a, "[toolchain]\nmojo = \"1.0.0\"\n");
    const bad = try C.check(a, &.{ was, p, "../mopm-toolchain.toml" });
    try t.expectEqual(@as(usize, 1), bad.items.len);
    try t.expectEqualStrings("../mopm-toolchain.toml", bad.items[0].name);
    try t.expectEqualStrings(was, bad.items[0].want);
    try t.expectEqualStrings(try sha(a, "[toolchain]\nmojo = \"1.1.0\"\n"), bad.items[0].got);
}

test "files_check: a file that is gone is a mismatch, not a pass; every bad file is reported, the good ones are not" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "ok.toml", .data = "ok" });
    try tmp.dir.writeFile(.{ .sub_path = "edited.toml", .data = "new" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    const bad = try C.check(a, &.{
        try sha(a, "ok"),  try std.fmt.allocPrint(a, "{s}/ok.toml", .{root}),     "ok.toml",
        try sha(a, "old"), try std.fmt.allocPrint(a, "{s}/edited.toml", .{root}), "edited.toml",
        try sha(a, "x"),   try std.fmt.allocPrint(a, "{s}/gone.toml", .{root}),   "gone.toml",
    });
    try t.expectEqual(@as(usize, 2), bad.items.len);
    try t.expectEqualStrings("edited.toml", bad.items[0].name);
    try t.expectEqualStrings("gone.toml", bad.items[1].name);
    try t.expect(std.mem.startsWith(u8, bad.items[1].got, "unreadable"));
}

test "files_check: arguments that are not triples are an error" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    try t.expectError(error.BadArguments, C.check(ar.allocator(), &.{ "a", "b" }));
}
