//! A diagnostics run (rules/rust/cargo_unit.bzl `diag = True`, rules/rust/rustc_diag.zig), what each member's `:flycheck` is made of, on a crate
//! with a type error and an unused variable (shared/diag_fixture.rs): the run succeeds, and its output is rustc's diagnostics as JSON, one per
//! line, naming the file the action compiled.

const std = @import("std");

const Found = struct { error_at: bool = false, warning_at: bool = false, lines: usize = 0 };

fn scan(a: std.mem.Allocator, text: []const u8) !Found {
    var f = Found{};
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, line, .{});
        f.lines += 1;
        const level = v.object.get("level").?.string;
        const message = v.object.get("message").?.string;
        const spans = v.object.get("spans").?.array.items;
        if (spans.len == 0) continue;
        const file = spans[0].object.get("file_name").?.string;
        const ours = std.mem.endsWith(u8, file, "shared/diag_fixture.rs");
        if (ours and std.mem.eql(u8, level, "error") and std.mem.indexOf(u8, message, "mismatched types") != null) f.error_at = true;
        if (ours and std.mem.eql(u8, level, "warning") and std.mem.indexOf(u8, message, "unused variable") != null) f.warning_at = true;
    }
    return f;
}

test "a diagnostics run of code with an error succeeds and holds the error and the warning as JSON, at the file compiled" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const work = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const text = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ work, "diagnostics.json" }), 1 << 24);
    const f = try scan(a, text);
    if (!f.error_at or !f.warning_at) {
        std.debug.print("the diagnostics run wrote:\n{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
}
