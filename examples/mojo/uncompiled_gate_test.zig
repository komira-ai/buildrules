//! What `:coverage` does with the functions no test compiled that are not uncovered code (rules/coverage/tools/mojo_calls.zig, mojo_gate.zig), held to the
//! real outputs of `examples/mojo/uncompiled_gate`, built by the real compiler and run under kcov.
//!
//! The library has five functions and one test, which calls `entry`. `entry` has `comptime if False: return only_here(x)`: an arm the compiler drops, so
//! `only_here` has no record, and its only use is in an arm no report records: it is platform-gated, and its two lines are neither found nor listed as
//! uncovered. `twice` is `@always_inline` and `entry` calls it; the compiler kept a line record for it in this build (so it is the compiler's, hit), which is
//! what the case holds: a function with a record is never reclassified. `inlined_nobody_calls` (`@always_inline`, no caller) and `zero_callers` (no use) are
//! what they look like: found and not hit.

const std = @import("std");
const t = std.testing;

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

const lib = "examples/mojo/uncompiled_gate/src/uncompiled_gate/__init__.mojo";

test "the platform-gated function is left out and listed; the inlined and the uncalled ones are counted" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Lines: `twice` 7 (the `def` line carries no record of its own here), `entry` 23 and 26 are the compiler's, all hit; `inlined_nobody_calls` (11, 12) and
    // `zero_callers` (19, 20) are the source's, not hit; `only_here` (15, 16) is left out. No decision in the source: `0/0` branches.
    try t.expectEqualStrings(
        lib ++ " 3/7 42%\n" ++
            "examples/mojo/uncompiled_gate/tests/test_entry.mojo 4/4 100% (not counted)\n" ++
            "total 3/7 42%\n" ++
            "branches " ++ lib ++ " 0/0 0%\n" ++
            "branches total 0/0 0%\n",
        try work(a, "coverage.txt"),
    );
    try t.expectEqualStrings(
        "excluded total 0 lines 0 arms\n" ++
            "gated " ++ lib ++ " only_here 15 2 lines\n" ++
            "gated total 1 functions 2 lines 0 arms\n",
        try work(a, "uncompiled.excluded.txt"),
    );
}

test "the lines in the report of the code no test compiled are the lines coverage.txt counted as unhit" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const xml = try work(a, "uncompiled.cobertura.xml");
    for ([_]u8{ 11, 12, 19, 20 }) |ln| {
        const row = try std.fmt.allocPrint(a, "<line number=\"{d}\" hits=\"0\"/>", .{ln});
        try t.expect(std.mem.indexOf(u8, xml, row) != null);
    }
    // The gated function's lines (15, 16) and the compiler's (7, 23, 26) are not in it.
    for ([_]u8{ 15, 16, 7, 23, 26 }) |ln| {
        const row = try std.fmt.allocPrint(a, "<line number=\"{d}\" ", .{ln});
        try t.expect(std.mem.indexOf(u8, xml, row) == null);
    }
}
