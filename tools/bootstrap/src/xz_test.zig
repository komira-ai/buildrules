//! xz.zig: the container, over uncompressed LZMA2 chunks that testkit.zig writes (the compression itself is the standard library's, and the real compressed
//! archives are held by real_test.zig). The point here is what this tool adds: every cut-off or corrupt file is an error and not a short result.
const std = @import("std");
const kit = @import("testkit.zig");
const xz = @import("xz.zig");
const stream = @import("stream.zig");
const archive = @import("archive.zig");
const t = std.testing;
const a = kit.a;

const Collect = struct {
    list: std.ArrayList(u8) = .empty,

    pub fn write(self: *Collect, bytes: []const u8) !void {
        try self.list.appendSlice(a, bytes);
    }
};

fn unxz(input: []const u8) ![]u8 {
    var c = Collect{};
    errdefer c.list.deinit(a);
    try xz.unxz(a, input, stream.sinkOf(Collect, &c));
    return c.list.toOwnedSlice(a);
}

fn unxzFails(input: []const u8) anyerror!void {
    const out = try unxz(input);
    a.free(out);
}

test "a file decodes to its content under each kind of check" {
    var data: [200_000]u8 = undefined;
    for (&data, 0..) |*c, i| c.* = @truncate(i *% 7 +% (i >> 9));
    for ([_]kit.Check{ .none, .crc32, .crc64 }) |check| {
        const file = try kit.xzOf(&data, check);
        defer a.free(file);
        const got = try unxz(file);
        defer a.free(got);
        try t.expectEqualSlices(u8, &data, got);
    }
}

test "an empty content is a file" {
    const file = try kit.xzOf("", .crc32);
    defer a.free(file);
    const got = try unxz(file);
    defer a.free(got);
    try t.expectEqual(@as(usize, 0), got.len);
}

test "truncated xz: no proper prefix of a file is accepted" {
    const file = try kit.xzOf("some content to cut " ** 20, .crc64);
    defer a.free(file);
    var cut: usize = 0;
    while (cut < file.len) : (cut += 1) {
        unxzFails(file[0..cut]) catch |e| {
            // a cut-off file is truncated, or (when the cut leaves a header that reads as another thing) corrupt
            try t.expect(e == error.Truncated or e == error.Corrupt);
            continue;
        };
        std.debug.print("an xz file cut at {d} of {d} bytes was accepted\n", .{ cut, file.len });
        return error.TestUnexpectedResult;
    }
}

test "truncated xz: a cut in the stream is Truncated" {
    const file = try kit.xzOf("0123456789" ** 100, .crc32);
    defer a.free(file);
    try t.expectError(error.Truncated, unxzFails(file[0 .. file.len / 2]));
    try t.expectError(error.Truncated, unxzFails(file[0 .. file.len - 1]));
}

test "xz: bytes after the stream, and a wrong check, are refused" {
    const file = try kit.xzOf("payload", .crc32);
    defer a.free(file);
    const more = try std.mem.concat(a, u8, &.{ file, "extra" });
    defer a.free(more);
    try t.expectError(error.TrailingData, unxzFails(more));
    // the CRC-32 of the content follows the block's padding: flip a byte of the content, and the check no longer matches
    const bad = try a.dupe(u8, file);
    defer a.free(bad);
    const at = std.mem.indexOf(u8, bad, "payload").?;
    bad[at] ^= 1;
    try t.expectError(error.Corrupt, unxzFails(bad));
}

test "xz: not an xz file" {
    try t.expectError(error.Truncated, unxzFails(""));
    try t.expectError(error.Corrupt, unxzFails("not xz at all, just text"));
}

const Failing = struct {
    pub fn write(_: *Failing, _: []const u8) !void {
        return error.DiskFull;
    }
};

test "an error of the sink is the decoder's error" {
    const file = try kit.xzOf("payload", .crc32);
    defer a.free(file);
    var f = Failing{};
    try t.expectError(error.DiskFull, xz.unxz(a, file, stream.sinkOf(Failing, &f)));
}

test "a tar.xz extracts, and one cut inside its tar is a cut-off archive" {
    var b = kit.Tar{};
    defer b.deinit();
    try b.file("pkg/f", 0o644, "inside xz");
    try b.end();
    const file = try kit.xzOf(b.bytes(), .crc64);
    defer a.free(file);
    var d = kit.Dest.init();
    defer d.deinit();
    _ = try d.unpack(file, .tar_xz, 0);
    const got = try d.read("pkg/f");
    defer a.free(got);
    try t.expectEqualStrings("inside xz", got);
    // a well-formed xz whose tar ends inside an entry
    const short = try kit.xzOf(b.bytes()[0..700], .crc64);
    defer a.free(short);
    var d2 = kit.Dest.init();
    defer d2.deinit();
    try t.expectError(error.TruncatedArchive, d2.unpack(short, .tar_xz, 0));
}

test "detect: each format by its magic" {
    const x = try kit.xzOf("x", .none);
    defer a.free(x);
    try t.expectEqual(archive.Format.tar_xz, archive.detect(x).?);
    const g = try kit.gzipStored("x");
    defer a.free(g);
    try t.expectEqual(archive.Format.tar_gz, archive.detect(g).?);
    try t.expectEqual(archive.Format.zip, archive.detect("PK\x03\x04rest").?);
    try t.expectEqual(archive.Format.zip, archive.detect("PK\x05\x06rest").?);
    var b = kit.Tar{};
    defer b.deinit();
    try b.file("f", 0o644, "x");
    try t.expectEqual(archive.Format.tar, archive.detect(b.bytes()).?);
    try t.expect(archive.detect("plain text") == null);
    try t.expect(archive.detect("") == null);
    // a tar header with no magic is not detected (--format tar names it)
    var v7 = try kit.Tar.header(.{ .name = "f", .magic = "" });
    try t.expect(archive.detect(&v7) == null);
}
