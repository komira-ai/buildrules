//! sync_stage.zig: the staging, the command line of the sync, what is collected into the output, and the flags. The run of
//! `buildrules sync` itself is the farm's (crates//:sync_check, gitcrates//:sync_check).
const std = @import("std");
const S = @import("sync_stage.zig");
const t = std.testing;

test "flags: every tool is required, --sources and --check are optional, anything else is refused" {
    const ok = try S.parseArgs(&.{ "--src", "s", "--out", "o", "--buildrules", "b", "--cargo", "c", "--sysroot", "r", "--pins", "p", "--check", "--sources", "g" });
    try t.expect(ok.check);
    try t.expectEqualStrings("g", ok.sources.?);
    const bare = try S.parseArgs(&.{ "--src", "s", "--out", "o", "--buildrules", "b", "--cargo", "c", "--sysroot", "r", "--pins", "p" });
    try t.expect(!bare.check);
    try t.expect(bare.sources == null);
    try t.expectError(error.MissingFlag, S.parseArgs(&.{ "--src", "s", "--out", "o" }));
    try t.expectError(error.UnknownFlag, S.parseArgs(&.{ "--nope", "x" }));
    // the local registry of earlier versions is gone: the sources are fetched by hash
    try t.expectError(error.UnknownFlag, S.parseArgs(&.{ "--registry", "x" }));
    try t.expectError(error.MissingValue, S.parseArgs(&.{"--src"}));
}

test "stage: the workspace is copied and a .buckconfig is added when it has none, and kept when it has one" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src/crates/app/src");
    try tmp.dir.writeFile(.{ .sub_path = "src/Cargo.toml", .data = "[workspace]\n" });
    try tmp.dir.writeFile(.{ .sub_path = "src/crates/app/src/lib.rs", .data = "// lib\n" });
    try tmp.dir.makePath("work");
    var src = try tmp.dir.openDir("src", .{ .iterate = true });
    defer src.close();
    var work = try tmp.dir.openDir("work", .{ .iterate = true });
    defer work.close();
    try t.expect(try S.stage(a, src, work));
    try t.expectEqualStrings("[workspace]\n", try tmp.dir.readFileAlloc(a, "work/Cargo.toml", 1 << 10));
    try t.expectEqualStrings("// lib\n", try tmp.dir.readFileAlloc(a, "work/crates/app/src/lib.rs", 1 << 10));
    try t.expectEqualStrings("[cells]\n", try tmp.dir.readFileAlloc(a, "work/.buckconfig", 1 << 10));

    try tmp.dir.writeFile(.{ .sub_path = "src/.buckconfig", .data = "[cells]\n  mine = .\n" });
    try tmp.dir.makePath("work2");
    var work2 = try tmp.dir.openDir("work2", .{ .iterate = true });
    defer work2.close();
    try t.expect(!try S.stage(a, src, work2));
    try t.expectEqualStrings("[cells]\n  mine = .\n", try tmp.dir.readFileAlloc(a, "work2/.buckconfig", 1 << 10));
}

fn fakeReal(a: std.mem.Allocator, p: []const u8) anyerror![]u8 {
    return std.fmt.allocPrint(a, "/abs/{s}", .{p});
}

test "the sync runs with every path absolute, the pinned tools inside their directories, and --sources and --check only when given" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const base = S.Args{ .src = "s", .out = "o", .buildrules = "br", .cargo = "c", .sysroot = "r", .pins = "p.bzl" };
    const plain = try S.syncArgv(a, base, "/work", &fakeReal);
    const want_plain = [_][]const u8{ "/abs/br", "sync", "--dir", "/work", "--cargo", "/abs/c/bin/cargo", "--rustc", "/abs/r/bin/rustc", "--pins", "/abs/p.bzl" };
    try t.expectEqual(want_plain.len, plain.len);
    for (want_plain, plain) |w, g| try t.expectEqualStrings(w, g);
    var full = base;
    full.sources = "fetched";
    full.check = true;
    const both = try S.syncArgv(a, full, "/work", &fakeReal);
    try t.expectEqual(want_plain.len + 3, both.len);
    try t.expectEqualStrings("--sources", both[want_plain.len]);
    try t.expectEqualStrings("/abs/fetched", both[want_plain.len + 1]);
    try t.expectEqualStrings("--check", both[want_plain.len + 2]);
}

test "collect: only what the sync wrote or changed reaches the output, never buck-out/ or the added .buckconfig, and a removed file is named" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_][2][]const u8{
        .{ "src/Cargo.lock", "lock v1\n" },
        .{ "src/buildrules.lock.bzl", "table v1\n" },
        .{ "src/Cargo.toml", "[workspace]\n" },
        .{ "src/third_party/buildrules/git_archives.tsv", "# record\n" },
        .{ "src/third_party/buildrules/BUCK", "# old\n" },
    }) |f| {
        if (std.fs.path.dirname(f[0])) |d| try tmp.dir.makePath(d);
        try tmp.dir.writeFile(.{ .sub_path = f[0], .data = f[1] });
    }
    var src = try tmp.dir.openDir("src", .{ .iterate = true });
    defer src.close();
    try tmp.dir.makePath("work");
    var work = try tmp.dir.openDir("work", .{ .iterate = true });
    defer work.close();
    try t.expect(try S.stage(a, src, work));
    // what a sync does: rewrites the table, writes a new file, leaves the lock, removes the record, fills buck-out
    try work.writeFile(.{ .sub_path = "buildrules.lock.bzl", .data = "table v2\n" });
    try work.writeFile(.{ .sub_path = "buildrules.bzl", .data = "# glue\n" });
    try work.writeFile(.{ .sub_path = "third_party/buildrules/BUCK", .data = "# new\n" });
    try work.deleteFile("third_party/buildrules/git_archives.tsv");
    try work.makePath("buck-out/buildrules/vendor");
    try work.writeFile(.{ .sub_path = "buck-out/buildrules/vendor/x", .data = "scratch" });
    try tmp.dir.makePath("out");
    var out = try tmp.dir.openDir("out", .{ .iterate = true });
    defer out.close();
    const removed = try S.collect(a, src, work, out, true);
    try t.expectEqual(@as(usize, 1), removed.len);
    try t.expectEqualStrings("third_party/buildrules/git_archives.tsv", removed[0]);
    try t.expectEqualStrings("table v2\n", try out.readFileAlloc(a, "buildrules.lock.bzl", 1 << 10));
    try t.expectEqualStrings("# glue\n", try out.readFileAlloc(a, "buildrules.bzl", 1 << 10));
    try t.expectEqualStrings("# new\n", try out.readFileAlloc(a, "third_party/buildrules/BUCK", 1 << 10));
    var names = std.ArrayList([]const u8).empty;
    var w = try out.walk(a);
    defer w.deinit();
    while (try w.next()) |e| if (e.kind == .file) try names.append(a, try a.dupe(u8, e.path));
    try t.expectEqual(@as(usize, 3), names.items.len);
    try t.expectError(error.FileNotFound, out.access("Cargo.lock", .{}));
    try t.expectError(error.FileNotFound, out.access(".buckconfig", .{}));
    try t.expectError(error.FileNotFound, out.access("buck-out", .{}));

    // a .buckconfig the workspace had is the workspace's: a sync that changed it would be collected like any file
    try work.writeFile(.{ .sub_path = ".buckconfig", .data = "[cells]\n  x = .\n" });
    try tmp.dir.makePath("out2");
    var out2 = try tmp.dir.openDir("out2", .{});
    defer out2.close();
    _ = try S.collect(a, src, work, out2, false);
    try t.expectEqualStrings("[cells]\n  x = .\n", try out2.readFileAlloc(a, ".buckconfig", 1 << 10));
}

test "collect: a sync that changed nothing leaves the output empty" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src/crates/x");
    try tmp.dir.writeFile(.{ .sub_path = "src/crates/x/Cargo.toml", .data = "[package]\n" });
    try tmp.dir.makePath("work");
    try tmp.dir.makePath("out");
    var src = try tmp.dir.openDir("src", .{ .iterate = true });
    defer src.close();
    var work = try tmp.dir.openDir("work", .{ .iterate = true });
    defer work.close();
    var out = try tmp.dir.openDir("out", .{ .iterate = true });
    defer out.close();
    const added = try S.stage(a, src, work);
    try t.expectEqual(@as(usize, 0), (try S.collect(a, src, work, out, added)).len);
    var it = out.iterate();
    try t.expect(try it.next() == null);
}
