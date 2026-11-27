//! `:sync_patch` end to end on the farm, against a workspace whose Cargo.lock gained a crate: gitcrates//:stale_patch is examples/gitcrates
//! with fnv added to gdemo's dependencies and to Cargo.lock and its generated files as they were (examples/gitcrates/stale/). The data:
//!   patch/    what `sync_patch make` wrote for it (the verdict, offer/sync.patch, offer/files/);
//!   stale/    the workspace that sync started from (the target's `[workspace]`);
//!   sources/  the files Cargo.lock pins, fetched by hash (`[sources]`);
//!   synced/   what it wrote for examples/gitcrates itself (gitcrates//:sync_patch), whose generated files are committed in sync.
//! The test holds that the verdict is the stale table alone, that the patch applies to the workspace and makes the files the sync wrote,
//! that `buildrules check` (the table check, offline) is red before and green after, and that a second sync of the result, like the sync of
//! the committed example, offers nothing.

const std = @import("std");
const P = @import("sync_patch_lib");
const t = std.testing;
const Allocator = std.mem.Allocator;

fn getenv(a: Allocator, name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(a, name) catch |e| {
        std.debug.print("{s} is not in the environment (the zig_test's data / exec_tools)\n", .{name});
        return e;
    };
}

const Ran = struct { code: u8, out: []const u8 };

fn run(a: Allocator, argv: []const []const u8, cwd: []const u8) !Ran {
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv, .cwd = cwd, .max_output_bytes = 64 << 20 });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .out = try std.fmt.allocPrint(a, "{s}{s}", .{ r.stdout, r.stderr }) };
}

fn report(a: Allocator, dir: std.fs.Dir, path: []const u8) !P.Report {
    const text = try dir.readFileAlloc(a, path, 1 << 20);
    return (try P.parseVerdict(a, text)) orelse {
        std.debug.print("{s} is not a verdict:\n{s}\n", .{ path, text });
        return error.NotAVerdict;
    };
}

fn has(r: P.Report, letter: u8, path: []const u8) bool {
    for (r.entries) |e| {
        if (e.letter == letter and std.mem.eql(u8, e.path, path)) return true;
    }
    return false;
}

fn expectRan(r: Ran, code: u8, what: []const u8) !void {
    if (r.code != code) {
        std.debug.print("{s} exited {d} (want {d}):\n{s}\n", .{ what, r.code, code, r.out });
        return error.TestUnexpectedResult;
    }
}

test "a workspace whose Cargo.lock gained a crate: the stale table alone, a patch that applies and makes the table check pass, then nothing to offer" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const work_path = try getenv(a, "BUILDRULES_TEST_WORK");
    const buildrules = try getenv(a, "BR_BUILDRULES");
    var work = try std.fs.cwd().openDir(work_path, .{ .iterate = true });
    defer work.close();
    const stale_path = try std.fs.path.join(a, &.{ work_path, "stale" });

    // The verdict: the generated files alone, and none of the files the pull request wrote.
    const first = try report(a, work, "patch/verdict.txt");
    try t.expectEqual(P.Verdict.tables, first.verdict);
    try t.expect(has(first, 'M', "buildrules.lock.bzl"));
    try t.expect(has(first, 'M', "third_party/buildrules/BUCK"));
    try t.expect(has(first, 'M', "third_party/buildrules/crate_sizes.tsv"));
    for (first.entries) |e| {
        if (std.mem.eql(u8, std.fs.path.basename(e.path), "Cargo.toml") or std.mem.eql(u8, e.path, "Cargo.lock")) {
            std.debug.print("the patch changes {s}, which the pull request wrote\n", .{e.path});
            return error.TestUnexpectedResult;
        }
    }
    // the regenerated table has the crate the lock gained
    const sizes = try work.readFileAlloc(a, "patch/offer/files/third_party/buildrules/crate_sizes.tsv", 1 << 20);
    try t.expect(std.mem.indexOf(u8, sizes, "\nfnv 1.0.7 ") != null);

    // Before the patch the table check is red, and names the file the crate went into.
    const before = try run(a, &.{ buildrules, "check", "--dir", stale_path }, work_path);
    try expectRan(before, 1, "buildrules check before the patch");
    try t.expect(std.mem.indexOf(u8, before.out, "STALE") != null);

    // The patch applies, and makes each file the sync wrote.
    var stale = try work.openDir("stale", .{ .iterate = true });
    defer stale.close();
    var failed: []const u8 = "";
    P.apply(a, stale, try work.readFileAlloc(a, "patch/offer/sync.patch", 1 << 28), &failed) catch |e| {
        std.debug.print("the patch does not apply ({s}) at {s}\n", .{ @errorName(e), failed });
        return e;
    };
    var files = try work.openDir("patch/offer/files", .{ .iterate = true });
    defer files.close();
    var walker = try files.walk(a);
    defer walker.deinit();
    var seen: usize = 0;
    while (try walker.next()) |e| {
        if (e.kind != .file) continue;
        try t.expectEqualStrings(try files.readFileAlloc(a, e.path, 1 << 28), try stale.readFileAlloc(a, e.path, 1 << 28));
        seen += 1;
    }
    var written: usize = 0;
    for (first.entries) |e| written += @intFromBool(e.letter != 'D');
    try t.expectEqual(written, seen);

    // After it, the table check passes.
    try expectRan(try run(a, &.{ buildrules, "check", "--dir", stale_path }, work_path), 0, "buildrules check after the patch");

    // A second sync of the patched workspace offers nothing.
    const second_path = try std.fs.path.join(a, &.{ work_path, "second" });
    const second = try run(a, &.{
        try getenv(a, "BR_SYNC_PATCH"), "make",
        "--src",                         stale_path,
        "--out",                         second_path,
        "--buildrules",                  buildrules,
        "--cargo",                       try getenv(a, "BR_CARGO"),
        "--sysroot",                     try getenv(a, "BR_SYSROOT"),
        "--pins",                        try getenv(a, "BR_PINS"),
        "--sources",                     try std.fs.path.join(a, &.{ work_path, "sources" }),
    }, work_path);
    try expectRan(second, 0, "sync_patch make of the patched workspace");
    try t.expectEqual(P.Verdict.none, (try report(a, work, "second/verdict.txt")).verdict);
    try t.expectError(error.FileNotFound, work.access("second/offer/sync.patch", .{}));

    // And so does the sync of the committed example.
    try t.expectEqual(P.Verdict.none, (try report(a, work, "synced/verdict.txt")).verdict);
    try t.expectError(error.FileNotFound, work.access("synced/offer/sync.patch", .{}));
}
