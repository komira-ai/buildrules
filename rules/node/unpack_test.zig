const std = @import("std");
const unpack = @import("unpack.zig");
const tartest = @import("tartest.zig");

fn mode(dir: std.fs.Dir, path: []const u8) !u32 {
    const st = try dir.statFile(path);
    return @intCast(st.mode & 0o777);
}

test "stripFirst: the first component goes, whatever it is" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("lib/a.js", try unpack.stripFirst("package/lib/a.js", &buf));
    try std.testing.expectEqualStrings("lib/a.js", try unpack.stripFirst("fx-scoped-3.0.0/lib/a.js", &buf));
    try std.testing.expectEqualStrings("lib/a.js", try unpack.stripFirst("./package//lib/./a.js", &buf));
    try std.testing.expectEqualStrings("", try unpack.stripFirst("package/", &buf));
    try std.testing.expectEqualStrings("", try unpack.stripFirst("package", &buf));
}

test "stripFirst: a path that leaves the package is refused" {
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.PathEscapes, unpack.stripFirst("package/../../etc/passwd", &buf));
    try std.testing.expectError(error.PathEscapes, unpack.stripFirst("../package/a", &buf));
    try std.testing.expectError(error.PathEscapes, unpack.stripFirst("package/a/..", &buf));
    try std.testing.expectError(error.PathEscapes, unpack.stripFirst("/etc/passwd", &buf));
}

test "unpackTgz: files at their stripped paths with npm's modes, links not extracted" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const z = try tartest.tgz(arena.allocator(), "p", "1.0.0", &.{
        .{ .name = "package/bin/run.js", .mode = 0o755, .data = "#!/usr/bin/env node\n" },
        .{ .name = "package/lib/a.js", .mode = 0o600, .data = "exports.a = 1;\n" },
        .{ .name = "package/lib/b.js", .mode = 0o664, .data = "" },
        .{ .name = "package/evil", .kind = '2', .link = "/etc/passwd" },
        .{ .name = "package/empty/", .kind = '5', .mode = 0o700 },
    });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const st = try unpack.unpackTgz(tmp.dir, z);
    try std.testing.expectEqual(@as(usize, 4), st.files);
    try std.testing.expectEqual(@as(usize, 1), st.links);
    try std.testing.expectEqual(@as(u32, 0o755), try mode(tmp.dir, "bin/run.js"));
    try std.testing.expectEqual(@as(u32, 0o644), try mode(tmp.dir, "lib/a.js"));
    try std.testing.expectEqual(@as(u32, 0o644), try mode(tmp.dir, "lib/b.js"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("evil"));
    const text = try tmp.dir.readFileAlloc(a, "lib/a.js", 100);
    defer a.free(text);
    try std.testing.expectEqualStrings("exports.a = 1;\n", text);
    var d = try tmp.dir.openDir("empty", .{});
    d.close();
}

test "unpackTgz: an entry that escapes the package fails the unpack and writes nothing outside" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const z = try tartest.tgz(arena.allocator(), "p", "1.0.0", &.{
        .{ .name = "package/../escaped.txt", .data = "x" },
    });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sub = try tmp.dir.makeOpenPath("pkg", .{});
    defer sub.close();
    try std.testing.expectError(error.PathEscapes, unpack.unpackTgz(sub, z));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("escaped.txt"));
}

test "unpackTgz: a stream that is not gzip, and a truncated one, are errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expect(std.meta.isError(unpack.unpackTgz(tmp.dir, "not a gzip stream at all")));
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const z = try tartest.tgz(arena.allocator(), "p", "1.0.0", &.{.{ .name = "package/a", .data = "0123456789" }});
    try std.testing.expect(std.meta.isError(unpack.unpackTgz(tmp.dir, z[0 .. z.len - 20])));
}

test "stripFirst: an empty name is the package itself, and a path that does not fit the buffer is refused" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("", try unpack.stripFirst("", &buf));
    try std.testing.expectEqualStrings("abcdefg", try unpack.stripFirst("package/abcdefg", &buf));
    try std.testing.expectError(error.PathEscapes, unpack.stripFirst("package/abcdefgh", &buf));
    try std.testing.expectEqualStrings("ab/cdefg", try unpack.stripFirst("package/ab/cdefg", &buf));
    try std.testing.expectError(error.PathEscapes, unpack.stripFirst("package/ab/cdefgh", &buf));
}

test "unpackTgz: a gzip stream cut inside its trailer is an error, not a package" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const z = try tartest.tgz(arena.allocator(), "p", "1.0.0", &.{.{ .name = "package/a", .data = "0123456789" }});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // the whole stream unpacks; the same stream without the last four bytes of its eight-byte trailer does not
    const whole = try unpack.unpackTgz(tmp.dir, z);
    try std.testing.expectEqual(@as(usize, 2), whole.files);
    try std.testing.expectError(error.CorruptGzip, unpack.unpackTgz(tmp.dir, z[0 .. z.len - 4]));
}

test "unpackTgz: a tar that ends inside a file's data is an error, not a short file" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tar = try tartest.tar(arena.allocator(), &.{.{ .name = "package/a", .data = "0123456789" }});
    // the header block and three bytes of the data
    const z = try tartest.gzip(arena.allocator(), tar[0 .. 512 + 3]);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expect(std.meta.isError(unpack.unpackTgz(tmp.dir, z)));
}

test "unpackTgz: an entry that needs a file to be a directory, or a directory to be a file, is an error and the file stays" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const x = arena.allocator();
    const cases = [_][]const tartest.Entry{
        // a file, then a file below it
        &.{ .{ .name = "package/a", .data = "first" }, .{ .name = "package/a/b", .data = "below" } },
        // a file, then a directory of its name
        &.{ .{ .name = "package/a", .data = "first" }, .{ .name = "package/a/", .kind = '5', .mode = 0o755 } },
    };
    for (cases) |entries| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try std.testing.expect(std.meta.isError(unpack.unpackTgz(tmp.dir, try tartest.tgz(x, "p", "1.0.0", entries))));
        const kept = try tmp.dir.readFileAlloc(a, "a", 100);
        defer a.free(kept);
        try std.testing.expectEqualStrings("first", kept);
    }
    // a directory, then a file of its name
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const z = try tartest.tgz(x, "p", "1.0.0", &.{ .{ .name = "package/d/", .kind = '5', .mode = 0o755 }, .{ .name = "package/d", .data = "file" } });
    try std.testing.expect(std.meta.isError(unpack.unpackTgz(tmp.dir, z)));
    var d = try tmp.dir.openDir("d", .{});
    d.close();
}

test "unpackTgz: a gzip trailer that does not state the CRC-32 of the tar is refused, and so is a flipped data byte" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const x = arena.allocator();
    const z = try tartest.tgz(x, "p", "1.0.0", &.{.{ .name = "package/a", .data = "0123456789" }});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // the trailer is the CRC-32 (four bytes) and then the length (four bytes)
    for (0..4) |i| {
        const bad = try x.dupe(u8, z);
        bad[bad.len - 8 + i] ^= 0x01;
        try std.testing.expectError(error.GzipCrcMismatch, unpack.unpackTgz(tmp.dir, bad));
    }
    // a stored block's data is the tar's bytes: one of them changed, with the trailer as it was
    const bad = try x.dupe(u8, z);
    const at = std.mem.indexOf(u8, bad, "0123456789").?;
    bad[at] = 'X';
    try std.testing.expectError(error.GzipCrcMismatch, unpack.unpackTgz(tmp.dir, bad));
}

test "unpackTgz: a gzip trailer that does not state the length of the tar is refused" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const x = arena.allocator();
    const z = try tartest.tgz(x, "p", "1.0.0", &.{.{ .name = "package/a", .data = "0123456789" }});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (0..4) |i| {
        const bad = try x.dupe(u8, z);
        bad[bad.len - 4 + i] ^= 0x01;
        try std.testing.expectError(error.GzipSizeMismatch, unpack.unpackTgz(tmp.dir, bad));
    }
}

test "unpackTgz: a stream of several deflate blocks, whose file is larger than the readers' buffers, is accepted whole and refused with one changed byte" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const x = arena.allocator();
    const big = try x.alloc(u8, 200 * 1024 + 17);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 31 +% (i >> 8));
    const z = try tartest.tgz(x, "p", "1.0.0", &.{.{ .name = "package/big.bin", .data = big }});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const st = try unpack.unpackTgz(tmp.dir, z);
    try std.testing.expectEqual(@as(usize, 2), st.files);
    const got = try tmp.dir.readFileAlloc(a, "big.bin", big.len + 1);
    defer a.free(got);
    try std.testing.expectEqualSlices(u8, big, got);
    // the last byte of the file, far into the stream
    const bad = try x.dupe(u8, z);
    const at = std.mem.lastIndexOf(u8, bad, big[big.len - 64 ..]).?;
    bad[at + 63] ^= 0x80;
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    try std.testing.expectError(error.GzipCrcMismatch, unpack.unpackTgz(tmp2.dir, bad));
}

test "unpackTgz: a trailer cut at any byte is refused" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const z = try tartest.tgz(arena.allocator(), "p", "1.0.0", &.{.{ .name = "package/a", .data = "0123456789" }});
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for (1..9) |cut| try std.testing.expectError(error.CorruptGzip, unpack.unpackTgz(tmp.dir, z[0 .. z.len - cut]));
}

test "Summing: a read of no bytes is no bytes and not the end, and what is read is summed" {
    const a = std.testing.allocator;
    var in: std.Io.Reader = .fixed("hello, world");
    var buf: [16]u8 = undefined;
    var sum = unpack.Summing.init(&in, &buf);
    var out = std.Io.Writer.Allocating.init(a);
    defer out.deinit();
    try std.testing.expectEqual(@as(usize, 0), try sum.reader.stream(&out.writer, .limited(0)));
    try std.testing.expectEqual(@as(usize, 5), try sum.reader.stream(&out.writer, .limited(5)));
    try std.testing.expectEqual(@as(usize, 7), try sum.reader.stream(&out.writer, .limited(100)));
    try std.testing.expectError(error.EndOfStream, sum.reader.stream(&out.writer, .limited(100)));
    try std.testing.expectEqualStrings("hello, world", out.written());
    try std.testing.expectEqual(std.hash.Crc32.hash("hello, world"), sum.crc.final());
    try std.testing.expectEqual(@as(u32, 12), sum.len);
}
