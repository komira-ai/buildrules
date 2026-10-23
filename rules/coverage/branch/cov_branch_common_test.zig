//! Unit tests of what the cov_branch subcommands share (cov_branch_common.zig), run by `zig test` as a build action (`:cov_branch_unit`).

const std = @import("std");
const c = @import("cov_branch_common.zig");
const testing = std.testing;

test "parseFlags returns the values in the order of the names, whatever the order given" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const got = (try c.parseFlags(a, &.{ "--a", "--b" }, &.{ "--b", "2", "--a", "1" }, &why)).?;
    try testing.expectEqualStrings("1", got[0]);
    try testing.expectEqualStrings("2", got[1]);
}

test "parseFlags names the first fault: unknown, valueless, repeated, empty, then missing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const names = [_][]const u8{ "--a", "--b" };
    const cases = [_]struct { argv: []const []const u8, why: []const u8 }{
        .{ .argv = &.{ "--z", "1" }, .why = "unknown argument --z" },
        .{ .argv = &.{"--z"}, .why = "unknown argument --z" },
        .{ .argv = &.{"--a"}, .why = "--a needs a value" },
        .{ .argv = &.{ "--a", "1", "--a", "2" }, .why = "--a given twice" },
        .{ .argv = &.{ "--a", "" }, .why = "--a is empty" },
        .{ .argv = &.{ "--a", "1" }, .why = "--b is missing" },
        .{ .argv = &.{}, .why = "--a is missing" },
        // A flag is matched whole.
        .{ .argv = &.{ "--a", "1", "--bb", "2" }, .why = "unknown argument --bb" },
        .{ .argv = &.{ "--a", "1", "--", "2" }, .why = "unknown argument --" },
    };
    for (cases) |cs| {
        try testing.expect((try c.parseFlags(a, &names, cs.argv, &why)) == null);
        try testing.expectEqualStrings(cs.why, why);
    }
    // A value may look like a flag.
    const got = (try c.parseFlags(a, &names, &.{ "--a", "--b", "--b", "x" }, &why)).?;
    try testing.expectEqualStrings("--b", got[0]);
}

test "abs leaves an absolute path alone and puts a relative one under the working directory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/x/y", try c.abs(a, "/w", "/x/y"));
    try testing.expectEqualStrings("/w/x/y", try c.abs(a, "/w", "x/y"));
}

test "the scratch directory of each subcommand follows BUCK_SCRATCH_PATH" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "link", "run", "annotate" }) |name| {
        const cases = [_]struct { s: ?[]const u8, want: []const u8 }{
            .{ .s = null, .want = "/w/.cov_branch_{s}" },
            .{ .s = "", .want = "/w/.cov_branch_{s}" },
            .{ .s = "/abs/s", .want = "/abs/s/cov_branch_{s}" },
            .{ .s = "rel/s", .want = "/w/rel/s/cov_branch_{s}" },
            // One character is a directory name like any other.
            .{ .s = "s", .want = "/w/s/cov_branch_{s}" },
        };
        for (cases) |cs| {
            const got = try c.scratchDir(a, name, "/w", cs.s);
            const want = try std.mem.replaceOwned(u8, a, cs.want, "{s}", name);
            try testing.expectEqualStrings(want, got);
        }
    }
}

test "nonEmpty: a file of any size above 0, through a link; not a missing, empty or dangling one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    try tmp.dir.writeFile(.{ .sub_path = "one", .data = "x" });
    try tmp.dir.writeFile(.{ .sub_path = "none", .data = "" });
    try tmp.dir.symLink("one", "ln", .{});
    try tmp.dir.symLink("nowhere", "dangling", .{});
    for ([_]struct { name: []const u8, want: bool }{
        .{ .name = "one", .want = true },
        .{ .name = "ln", .want = true },
        .{ .name = "none", .want = false },
        .{ .name = "dangling", .want = false },
        .{ .name = "absent", .want = false },
    }) |cs| {
        try testing.expectEqual(cs.want, c.nonEmpty(try std.fs.path.join(a, &.{ root, cs.name })));
    }
}

test "head4 reads up to four bytes: fewer from a short file, none from one that cannot be opened" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    try tmp.dir.writeFile(.{ .sub_path = "long", .data = "abcdef" });
    try tmp.dir.writeFile(.{ .sub_path = "short", .data = "ab" });
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("abcd", c.head4(try std.fs.path.join(a, &.{ root, "long" }), &buf));
    try testing.expectEqualStrings("ab", c.head4(try std.fs.path.join(a, &.{ root, "short" }), &buf));
    try testing.expectEqualStrings("", c.head4(try std.fs.path.join(a, &.{ root, "absent" }), &buf));
}

test "lastLines is the last N lines, a final newline ending the last line" {
    try testing.expectEqualStrings("", c.lastLines("", 40));
    try testing.expectEqualStrings("b\n", c.lastLines("a\nb\n", 1));
    try testing.expectEqualStrings("b", c.lastLines("a\nb", 1));
    try testing.expectEqualStrings("a\nb\n", c.lastLines("a\nb\n", 40));
    try testing.expectEqualStrings("\n\n", c.lastLines("x\n\n\n", 2));
}

test "childEnv replaces PATH, and LC_ALL when asked, and keeps every other entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{ "PATH=/old", "LC_ALL=fr", "PATHX=1", "Z=2" };
    const with = try c.childEnv(a, &base, "/k/bin", true);
    try testing.expectEqual(@as(usize, 4), with.len);
    try testing.expectEqualStrings("PATHX=1", with[0]);
    try testing.expectEqualStrings("Z=2", with[1]);
    try testing.expectEqualStrings("PATH=/k/bin", with[2]);
    try testing.expectEqualStrings("LC_ALL=C", with[3]);
    const without = try c.childEnv(a, &base, "/k/bin", false);
    try testing.expectEqual(@as(usize, 4), without.len);
    try testing.expectEqualStrings("LC_ALL=fr", without[0]);
    try testing.expectEqualStrings("PATH=/k/bin", without[3]);
}
