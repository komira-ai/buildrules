const std = @import("std");
const S = @import("asm_split.zig");
const t = std.testing;

test "splitSemicolons: every semicolon is a line break, nothing else changes" {
    const got = try S.splitSemicolons(t.allocator, "mov x0,#7; mov x0,#9\n  ret;\n");
    defer t.allocator.free(got);
    try t.expectEqualStrings("mov x0,#7\n mov x0,#9\n  ret\n\n", got);
    const same = try S.splitSemicolons(t.allocator, "nop\n");
    defer t.allocator.free(same);
    try t.expectEqualStrings("nop\n", same);
}

test "plan: a compile without the marker is left alone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expect((try S.plan(arena.allocator(), &.{ "-target", "aarch64-macos", "-c", "a.S", "-o", "a.o" }, "a.s")) == null);
}

test "plan: the marked compile becomes a preprocessing command and an assembling one, with the flags of both the same" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const p = (try S.plan(arena.allocator(), &.{ "-target", "aarch64-macos", "-DX=1", "-include", "p.h", S.marker, "-c", "dir/a.S", "-o", "out/a.o" }, "out/a.o.split.s")).?;
    // preprocessing: the flags and `-E dir/a.S`, no -c, no -o, no marker.
    try eqArgs(&.{ "-target", "aarch64-macos", "-DX=1", "-include", "p.h", "-E", "dir/a.S" }, p.pre);
    // assembling: the same flags, then `-c -x assembler <tmp> -o <out>`.
    try eqArgs(&.{ "-target", "aarch64-macos", "-DX=1", "-include", "p.h", "-c", "-x", "assembler", "out/a.o.split.s", "-o", "out/a.o" }, p.post);
}

test "plan: a marked command with no source or no output is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.NoSource, S.plan(arena.allocator(), &.{ S.marker, "-o", "a.o" }, "x"));
    try t.expectError(error.NoOutput, S.plan(arena.allocator(), &.{ S.marker, "-c", "a.S" }, "x"));
}

fn eqArgs(want: []const []const u8, got: []const []const u8) !void {
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}
