//! What `:coverage` does with a source kcov cannot record and the package lists in `coverage_unmeasured.txt` (rules/coverage/tools/cov_unmeasured.zig), held to the
//! real outputs of `examples/mojo/unmeasured`, built by the real compiler and run under kcov.
//!
//! The library has `ops.mojo` (ordinary code, every line and both arms of an `if` hit) and `fast.mojo`, every function of which is `@always_inline("nodebug")`: the
//! test calls them and kcov records no line of the file. Without the list `:coverage` would refuse `fast.mojo` ("is in no report"), and counting it 0/0 would say
//! nothing was there. The list names it with its reason: it is printed, and it is in no total.

const std = @import("std");
const t = std.testing;

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

const dir = "examples/mojo/unmeasured/";

test "the unmeasured source is listed with its reason and counted in no total; the rest is counted as it is" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "examples/mojo/unmeasured/src/unmeasured/__init__.mojo 0/0 0%\n" ++
            "examples/mojo/unmeasured/src/unmeasured/ops.mojo 4/4 100%\n" ++
            "examples/mojo/unmeasured/tests/test_unmeasured.mojo 10/10 100% (not counted)\n" ++
            "total 4/4 100%\n" ++
            "branches examples/mojo/unmeasured/src/unmeasured/__init__.mojo 0/0 0%\n" ++
            "branches examples/mojo/unmeasured/src/unmeasured/ops.mojo 2/2 100%\n" ++
            "branches total 2/2 100%\n" ++
            "unmeasured: examples/mojo/unmeasured/src/unmeasured/fast.mojo: every function is @always_inline(\"nodebug\"): kcov records no line of it, though test_fast_functions_run runs it\n" ++
            "unmeasured total 1 files: left out of the line and branch totals and the floors\n",
        try work(a, "coverage.txt"),
    );
}

test "the reports of the tests name no line of the unmeasured source, which is why it is listed" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const xml = try work(a, "reports_of_tests.xml");
    try t.expect(std.mem.indexOf(u8, xml, dir ++ "src/unmeasured/ops.mojo") != null);
    try t.expect(std.mem.indexOf(u8, xml, "fast.mojo") == null);
    // Nor does the report of the code no test compiled: a listed source is not found-and-not-hit either.
    try t.expect(std.mem.indexOf(u8, try work(a, "uncompiled.cobertura.xml"), "fast.mojo") == null);
}
