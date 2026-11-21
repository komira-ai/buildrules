//! rustc_diag (rustc_diag.zig) with programs of the test's PATH (the pinned busybox's applets) in place of rustc: what each run writes and
//! the status it gives.

const std = @import("std");
const diag = @import("rustc_diag.zig");
const t = std.testing;

test "rustc's 0 and 1 are a run that succeeded; an internal compiler error, a usage error and a signal are not" {
    const got = [_]u8{ diag.status(0), diag.status(1), diag.status(101), diag.status(2), diag.status(137) };
    try t.expectEqualSlices(u8, &.{ 0, 0, 101, 2, 137 }, &got);
}

/// One run of `argv` in a fresh directory: its status and the file it wrote.
fn runIn(argv: []const []const u8) !struct { code: u8, text: []const u8, out_dir: bool } {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.heap.page_allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    const file = try std.fs.path.join(a, &.{ root, "diagnostics.json" });
    const code = try diag.run(a, file, try std.fs.path.join(a, &.{ root, "scratch" }), argv);
    var out_dir = true;
    tmp.dir.access("scratch/diag", .{}) catch {
        out_dir = false;
    };
    return .{ .code = code, .text = try std.fs.cwd().readFileAlloc(a, file, 1 << 20), .out_dir = out_dir };
}

test "a program that fails with 1 is a run that succeeded, and what it wrote on standard error is the file" {
    // busybox `cat` refuses the options the run adds (`--error-format=json`), says so on standard error and exits 1, as rustc does on an error.
    const r = try runIn(&.{"cat"});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(std.mem.indexOf(u8, r.text, "error-format") != null);
    try t.expect(r.out_dir);
}

test "a program that exits 0 writes an empty file" {
    const r = try runIn(&.{"true"});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("", r.text);
}

test "a program that exits with another status fails the run with that status" {
    // busybox `expr` given what is not an expression exits 2.
    const r = try runIn(&.{"expr"});
    try t.expectEqual(@as(u8, 2), r.code);
}

test "a program that is not there is an error, not a run" {
    try t.expectError(error.FileNotFound, runIn(&.{"no-such-program-here"}));
}

test "a child's end is its status, 128 + N for a signal, and 1 for anything else" {
    const got = [_]u8{ diag.codeOf(.{ .Exited = 3 }), diag.codeOf(.{ .Signal = 9 }), diag.codeOf(.{ .Stopped = 19 }), diag.codeOf(.{ .Unknown = 7 }) };
    try t.expectEqualSlices(u8, &.{ 3, 137, 1, 1 }, &got);
}

test "a scratch directory that cannot be made, or a file that cannot be written, is an error before anything runs" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.heap.page_allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    try tmp.dir.writeFile(.{ .sub_path = "a-file", .data = "" });
    const file = try std.fs.path.join(a, &.{ root, "diagnostics.json" });
    try t.expectError(error.NotDir, diag.run(a, file, try std.fs.path.join(a, &.{ root, "a-file" }), &.{"true"}));
    try t.expectError(error.FileNotFound, diag.run(a, try std.fs.path.join(a, &.{ root, "no", "such", "dir", "d.json" }), root, &.{"true"}));
}

test "every allocation that fails is an error of the run, never a crash or a half-made command" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.heap.page_allocator, ".");
    var fail_at: usize = 0;
    var failed: usize = 0;
    while (fail_at < 64) : (fail_at += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = fail_at });
        const a = failing.allocator();
        const file = try std.fs.path.join(std.heap.page_allocator, &.{ root, "diagnostics.json" });
        if (diag.run(a, file, root, &.{"true"})) |code| {
            try t.expectEqual(@as(u8, 0), code);
            if (!failing.has_induced_failure) break;
        } else |e| {
            try t.expectEqual(error.OutOfMemory, e);
            failed += 1;
        }
    }
    try t.expect(failed > 0 and fail_at < 64);
}
