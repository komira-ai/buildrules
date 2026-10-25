//! mojo_sync.zig: the staging, the guard on the mopm version, the choice of the files that leave the action, their comparison with the committed copies, and
//! the copy back into a working tree. The run of `buildrules mojo sync` is the farm's (examples/mojo/sibfake/chain/a:sync_check).
const std = @import("std");
const S = @import("mojo_sync.zig");
const t = std.testing;

const stage_flags = [_][]const u8{ "stage", "--src", "s", "--work", "w", "--out", "o", "--buildrules", "b", "--mopm", "m", "--mopm-version", "0.0.48" };

fn withPackages(a: std.mem.Allocator, extra: []const []const u8) ![]const []const u8 {
    return std.mem.concat(a, []const u8, &.{ &stage_flags, extra });
}

test "flags: stage needs every tool and one package; package paths are cleaned; apply takes --from and --to" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const ok = try S.parseArgs(a, try withPackages(a, &.{ "--toolchains", "tc/", "--committed", "c", "--hint", "do it", "pkgs/a", "./pkgs//b/" }));
    try t.expectEqual(S.Mode.stage, ok.mode);
    try t.expectEqualStrings("tc", ok.toolchains);
    try t.expectEqualStrings("c", ok.committed.?);
    try t.expectEqualStrings("do it", ok.hint);
    try t.expectEqual(@as(usize, 2), ok.packages.len);
    try t.expectEqualStrings("pkgs/a", ok.packages[0]);
    try t.expectEqualStrings("pkgs/b", ok.packages[1]);
    // the default: toolchains/, and the root package as ""
    const root = try S.parseArgs(a, try withPackages(a, &.{"."}));
    try t.expectEqualStrings("toolchains", root.toolchains);
    try t.expectEqualStrings("", root.packages[0]);

    try t.expectError(error.NoPackage, S.parseArgs(a, &stage_flags));
    try t.expectError(error.MissingFlag, S.parseArgs(a, &.{ "stage", "--src", "s", "x" }));
    try t.expectError(error.UnknownFlag, S.parseArgs(a, try withPackages(a, &.{ "--nope", "1", "p" })));
    try t.expectError(error.MissingValue, S.parseArgs(a, try withPackages(a, &.{"--hint"})));
    try t.expectError(error.BadPath, S.parseArgs(a, try withPackages(a, &.{"../p"})));
    try t.expectError(error.BadPath, S.parseArgs(a, try withPackages(a, &.{"/abs/p"})));
    try t.expectError(error.BadPath, S.parseArgs(a, try withPackages(a, &.{ "--toolchains", "a/../../x", "p" })));
    try t.expectError(error.UnknownMode, S.parseArgs(a, &.{}));
    try t.expectError(error.UnknownMode, S.parseArgs(a, &.{"sync"}));

    const ap = try S.parseArgs(a, &.{ "apply", "--from", "f", "--to", "t" });
    try t.expectEqual(S.Mode.apply, ap.mode);
    try t.expectEqualStrings("f", ap.from);
    try t.expectEqualStrings("t", ap.to);
    try t.expectEqualStrings(".", (try S.parseArgs(a, &.{ "apply", "--from", "f" })).to);
    try t.expectError(error.MissingFlag, S.parseArgs(a, &.{"apply"}));
    // a stage flag is not an apply flag, and apply names no package
    try t.expectError(error.UnknownFlag, S.parseArgs(a, &.{ "apply", "--from", "f", "--out", "o" }));
    try t.expectError(error.UnknownFlag, S.parseArgs(a, &.{ "apply", "--from", "f", "pkg" }));
}

test "mopm version of a toolchain file: either quote, comments, spacing; nothing for a file that pins none" {
    try t.expectEqualStrings("0.0.48", S.mopmVersionOf("[toolchain]\nmopm = \"0.0.48\"\nmojo = \"1.0.0\"\n").?);
    try t.expectEqualStrings("0.0.48", S.mopmVersionOf("[toolchain]\n  mopm='0.0.48'  # pinned\n").?);
    try t.expectEqualStrings("0.0.25", S.mopmVersionOf("# mopm = \"9\"\n[toolchain]\nmojo = \"1.0.0\"\nmopm   =   \"0.0.25\"\r\n").?);
    try t.expect(S.mopmVersionOf("[toolchain]\nmojo = \"1.0.0\"\n") == null);
    try t.expect(S.mopmVersionOf("mopm_extra = \"1\"\n") == null);
    try t.expect(S.mopmVersionOf("mopm = 42\n") == null);
    try t.expect(S.mopmVersionOf("mopm = \"unterminated\n") == null);
    try t.expect(S.mopmVersionOf("") == null);
}

test "stage: the sources are copied, a .buckconfig naming the toolchains directory is added once, and the directory exists" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src/pkgs/a/src/a");
    try tmp.dir.writeFile(.{ .sub_path = "src/pkgs/a/mopm.toml", .data = "[package]\n" });
    try tmp.dir.writeFile(.{ .sub_path = "src/pkgs/a/src/a/__init__.mojo", .data = "# a\n" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    var args = S.Args{ .src = try std.fmt.allocPrint(a, "{s}/src", .{root}), .work = try std.fmt.allocPrint(a, "{s}/work", .{root}), .toolchains = "tc" };
    try S.stage(a, args);
    try t.expectEqualStrings("[package]\n", try tmp.dir.readFileAlloc(a, "work/pkgs/a/mopm.toml", 1 << 10));
    try t.expectEqualStrings("# a\n", try tmp.dir.readFileAlloc(a, "work/pkgs/a/src/a/__init__.mojo", 1 << 10));
    try t.expectEqualStrings("[cells]\n  toolchains = tc\n", try tmp.dir.readFileAlloc(a, "work/.buckconfig", 1 << 10));
    try tmp.dir.access("work/tc", .{});

    // a .buckconfig the sources bring is kept
    try tmp.dir.writeFile(.{ .sub_path = "src/.buckconfig", .data = "[cells]\n  toolchains = elsewhere\n" });
    args.work = try std.fmt.allocPrint(a, "{s}/work2", .{root});
    try S.stage(a, args);
    try t.expectEqualStrings("[cells]\n  toolchains = elsewhere\n", try tmp.dir.readFileAlloc(a, "work2/.buckconfig", 1 << 10));
}

test "mopm guard: the toolchain file is found at or above the package, and a package pinned to another mopm is refused by name" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("ex/mojo/chain/a");
    try tmp.dir.makePath("other/b");
    try tmp.dir.makePath("elsewhere/c");
    try tmp.dir.writeFile(.{ .sub_path = "ex/mojo/mopm-toolchain.toml", .data = "[toolchain]\nmopm = \"0.0.48\"\n" });
    try tmp.dir.writeFile(.{ .sub_path = "other/mopm-toolchain.toml", .data = "[toolchain]\nmopm = \"0.0.25\"\n" });
    try tmp.dir.writeFile(.{ .sub_path = "mopm-toolchain.toml", .data = "[toolchain]\nmojo = \"1.0.0\"\n" });
    const dir = tmp.dir;
    try t.expectEqualStrings("0.0.48", (try S.pinnedMopm(a, dir, "ex/mojo/chain/a")).?);
    try t.expectEqualStrings("0.0.25", (try S.pinnedMopm(a, dir, "other/b")).?);
    // the nearest file wins even when it pins no mopm; the root file here pins none
    try t.expect((try S.pinnedMopm(a, dir, "elsewhere/c")) == null);

    try t.expect((try S.toolchainMismatch(a, dir, &.{ "ex/mojo/chain/a", "elsewhere/c" }, "0.0.48")) == null);
    const why = (try S.toolchainMismatch(a, dir, &.{ "ex/mojo/chain/a", "other/b" }, "0.0.48")).?;
    try t.expect(std.mem.indexOf(u8, why, "other/b") != null);
    try t.expect(std.mem.indexOf(u8, why, "0.0.25") != null);
    try t.expect(std.mem.indexOf(u8, why, "0.0.48") != null);
    try t.expect(std.mem.indexOf(u8, why, "ex/mojo") == null);
}

test "mopm guard: a tree with no toolchain file at all pins nothing (the sync itself refuses it)" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("p");
    try t.expect((try S.pinnedMopm(a, tmp.dir, "p")) == null);
    try t.expect((try S.pinnedMopm(a, tmp.dir, "")) == null);
}

test "generated files: the lock and the glue of each package, and the two pins tables, nothing else" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const got = try S.generatedPaths(a, &.{ "pkgs/a", "" }, "tc");
    const want = [_][]const u8{
        "pkgs/a/buildrules.mojo.lock.bzl", "pkgs/a/buildrules.mojo.bzl",
        "buildrules.mojo.lock.bzl",        "buildrules.mojo.bzl",
        "tc/mojo_pins.bzl",                "tc/mopm_pins.bzl",
    };
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

fn writeSynced(dir: std.fs.Dir) !void {
    try dir.makePath("pkgs/a");
    try dir.makePath("tc");
    try dir.writeFile(.{ .sub_path = "pkgs/a/buildrules.mojo.lock.bzl", .data = "LOCK\n" });
    try dir.writeFile(.{ .sub_path = "pkgs/a/buildrules.mojo.bzl", .data = "GLUE\n" });
    try dir.writeFile(.{ .sub_path = "tc/mojo_pins.bzl", .data = "MOJO\n" });
    try dir.writeFile(.{ .sub_path = "tc/mopm_pins.bzl", .data = "MOPM\n" });
}

test "harvest: only the files a sync writes leave the work directory, at their paths; a file the sync did not write is named" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("work");
    var work = try tmp.dir.openDir("work", .{});
    defer work.close();
    try writeSynced(work);
    try work.writeFile(.{ .sub_path = "pkgs/a/mopm.toml", .data = "source\n" });
    try work.writeFile(.{ .sub_path = "tc/BUCK", .data = "buck\n" });
    try tmp.dir.makePath("out");
    var out = try tmp.dir.openDir("out", .{ .iterate = true });
    defer out.close();
    var missing: []const u8 = "";
    try S.harvest(a, work, out, &.{"pkgs/a"}, "tc", &missing);
    try t.expectEqualStrings("LOCK\n", try out.readFileAlloc(a, "pkgs/a/buildrules.mojo.lock.bzl", 1 << 10));
    try t.expectEqualStrings("GLUE\n", try out.readFileAlloc(a, "pkgs/a/buildrules.mojo.bzl", 1 << 10));
    try t.expectEqualStrings("MOJO\n", try out.readFileAlloc(a, "tc/mojo_pins.bzl", 1 << 10));
    try t.expectEqualStrings("MOPM\n", try out.readFileAlloc(a, "tc/mopm_pins.bzl", 1 << 10));
    try t.expectError(error.FileNotFound, out.access("pkgs/a/mopm.toml", .{}));
    try t.expectError(error.FileNotFound, out.access("tc/BUCK", .{}));

    // a second package the sync never wrote
    try t.expectError(error.NotWritten, S.harvest(a, work, out, &.{ "pkgs/a", "pkgs/b" }, "tc", &missing));
    try t.expectEqualStrings("pkgs/b/buildrules.mojo.lock.bzl", missing);
}

test "first difference: the line, both texts, and a longer text on either side" {
    try t.expect(S.firstDifference("a\nb\n", "a\nb\n") == null);
    const d = S.firstDifference("a\nb\nc\n", "a\nX\nc\n").?;
    try t.expectEqual(@as(usize, 2), d.no);
    try t.expectEqualStrings("b", d.have);
    try t.expectEqualStrings("X", d.want);
    const longer = S.firstDifference("a\nb\n", "a\n").?;
    try t.expectEqual(@as(usize, 2), longer.no);
    try t.expectEqualStrings("b", longer.have);
    try t.expectEqualStrings("", longer.want);
    const shorter = S.firstDifference("a", "a\nz").?;
    try t.expectEqual(@as(usize, 2), shorter.no);
    try t.expectEqualStrings("z", shorter.want);
    // only the final newline differs
    const nl = S.firstDifference("a", "a\n").?;
    try t.expectEqual(@as(usize, 2), nl.no);
}

test "first difference: a text that differs only after a long shared prefix is found at its line, with both lines whole" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // 300 identical lines of 40 bytes (12 KB), then a line that differs near its end, then more text
    var common = std.ArrayList(u8).empty;
    for (0..300) |i| try common.appendSlice(a, try std.fmt.allocPrint(a, "line {d:0>4} of a lock file, identical here\n", .{i}));
    const have = try std.mem.concat(a, u8, &.{ common.items, "pin = \"0.0.41\"\ntail\n" });
    const want = try std.mem.concat(a, u8, &.{ common.items, "pin = \"0.0.48\"\ntail\n" });
    const d = S.firstDifference(have, want).?;
    try t.expectEqual(@as(usize, 301), d.no);
    try t.expectEqualStrings("pin = \"0.0.41\"", d.have);
    try t.expectEqualStrings("pin = \"0.0.48\"", d.want);
    // the difference is the very last byte of a long text
    const last = S.firstDifference(try std.mem.concat(a, u8, &.{ common.items, "x" }), try std.mem.concat(a, u8, &.{ common.items, "y" })).?;
    try t.expectEqual(@as(usize, 301), last.no);
    try t.expectEqualStrings("x", last.have);
    try t.expectEqualStrings("y", last.want);
    // two long texts that are equal have no difference
    try t.expect(S.firstDifference(have, try a.dupe(u8, have)) == null);
}

test "compare: committed files equal to the sync pass (a file that is not committed is not held), a stale or an unknown one is named with the fix" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("out");
    var out = try tmp.dir.openDir("out", .{ .iterate = true });
    defer out.close();
    try writeSynced(out);

    try tmp.dir.makePath("same/pkgs/a");
    try tmp.dir.writeFile(.{ .sub_path = "same/pkgs/a/buildrules.mojo.lock.bzl", .data = "LOCK\n" });
    try tmp.dir.writeFile(.{ .sub_path = "same/pkgs/a/buildrules.mojo.bzl", .data = "GLUE\n" });
    var same = try tmp.dir.openDir("same", .{ .iterate = true });
    defer same.close();
    try t.expectEqual(@as(usize, 0), (try S.compare(a, out, same, "")).len);

    try tmp.dir.makePath("old/pkgs/a");
    try tmp.dir.writeFile(.{ .sub_path = "old/pkgs/a/buildrules.mojo.lock.bzl", .data = "LOCK\nold line\n" });
    try tmp.dir.writeFile(.{ .sub_path = "old/pkgs/a/buildrules.mojo.bzl", .data = "GLUE\n" });
    try tmp.dir.writeFile(.{ .sub_path = "old/pkgs/a/buildrules.mojo.extra.bzl", .data = "x\n" });
    var old = try tmp.dir.openDir("old", .{ .iterate = true });
    defer old.close();
    const bad = try S.compare(a, out, old, "\n  fix: buck2 run //x:sync");
    try t.expectEqual(@as(usize, 2), bad.len);
    var saw_lock = false;
    var saw_extra = false;
    for (bad) |m| {
        if (std.mem.indexOf(u8, m, "pkgs/a/buildrules.mojo.lock.bzl") != null) {
            saw_lock = true;
            try t.expect(std.mem.indexOf(u8, m, "line 2") != null);
            try t.expect(std.mem.indexOf(u8, m, "old line") != null);
            try t.expect(std.mem.indexOf(u8, m, "buck2 run //x:sync") != null);
        }
        if (std.mem.indexOf(u8, m, "buildrules.mojo.extra.bzl") != null) saw_extra = true;
    }
    try t.expect(saw_lock and saw_extra);
}

test "apply: files that differ are written, identical ones are left alone, and a directory that is not a repository root is refused before anything is written" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("synced");
    var from = try tmp.dir.openDir("synced", .{ .iterate = true });
    defer from.close();
    try writeSynced(from);

    try tmp.dir.makePath("tree");
    var tree = try tmp.dir.openDir("tree", .{});
    defer tree.close();
    var none = std.ArrayList([]const u8).empty;
    try t.expectError(error.NotARoot, S.apply(a, from, tree, &none));
    try t.expectEqual(@as(usize, 0), none.items.len);
    try t.expectError(error.FileNotFound, tree.access("tc/mojo_pins.bzl", .{}));

    try tree.writeFile(.{ .sub_path = ".buckconfig", .data = "[cells]\n" });
    try tree.makePath("pkgs/a");
    try tree.writeFile(.{ .sub_path = "pkgs/a/buildrules.mojo.lock.bzl", .data = "OLD\n" });
    try tree.writeFile(.{ .sub_path = "pkgs/a/buildrules.mojo.bzl", .data = "GLUE\n" });
    var wrote = std.ArrayList([]const u8).empty;
    try S.apply(a, from, tree, &wrote);
    // the changed lock and the two tables that did not exist; the glue was already right
    try t.expectEqual(@as(usize, 3), wrote.items.len);
    for (wrote.items) |p| try t.expect(!std.mem.eql(u8, p, "pkgs/a/buildrules.mojo.bzl"));
    try t.expectEqualStrings("LOCK\n", try tree.readFileAlloc(a, "pkgs/a/buildrules.mojo.lock.bzl", 1 << 10));
    try t.expectEqualStrings("MOJO\n", try tree.readFileAlloc(a, "tc/mojo_pins.bzl", 1 << 10));
    try t.expectEqualStrings("[cells]\n", try tree.readFileAlloc(a, ".buckconfig", 1 << 10));

    var again = std.ArrayList([]const u8).empty;
    try S.apply(a, from, tree, &again);
    try t.expectEqual(@as(usize, 0), again.items.len);
}

test "apply: a file whose new contents are as long as the old ones, in one byte or in all, is still written" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("synced");
    var from = try tmp.dir.openDir("synced", .{ .iterate = true });
    defer from.close();
    try writeSynced(from);

    try tmp.dir.makePath("tree");
    var tree = try tmp.dir.openDir("tree", .{});
    defer tree.close();
    try tree.writeFile(.{ .sub_path = ".buckconfig", .data = "[cells]\n" });
    try tree.makePath("pkgs/a");
    try tree.makePath("tc");
    try tree.writeFile(.{ .sub_path = "pkgs/a/buildrules.mojo.lock.bzl", .data = "LOCL\n" }); // one byte off, same length as "LOCK\n"
    try tree.writeFile(.{ .sub_path = "pkgs/a/buildrules.mojo.bzl", .data = "glue\n" }); // every byte off
    try tree.writeFile(.{ .sub_path = "tc/mojo_pins.bzl", .data = "MOJO\n" }); // right already
    var wrote = std.ArrayList([]const u8).empty;
    try S.apply(a, from, tree, &wrote);
    try t.expectEqualStrings("LOCK\n", try tree.readFileAlloc(a, "pkgs/a/buildrules.mojo.lock.bzl", 1 << 10));
    try t.expectEqualStrings("GLUE\n", try tree.readFileAlloc(a, "pkgs/a/buildrules.mojo.bzl", 1 << 10));
    try t.expectEqualStrings("MOPM\n", try tree.readFileAlloc(a, "tc/mopm_pins.bzl", 1 << 10));
    // the two same-length files and the missing table are reported; the file that was right is not
    try t.expectEqual(@as(usize, 3), wrote.items.len);
    for (wrote.items) |p| try t.expect(!std.mem.eql(u8, p, "tc/mojo_pins.bzl"));
}
