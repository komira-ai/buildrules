//! Running out of memory at any allocation of an extraction leaves no leak and no other error than OutOfMemory: every allocation of the decoders, the tar parser, the zip
//! reader and the extractor is made to fail in turn (std.testing.checkAllAllocationFailures), over archives that use all of them.
const std = @import("std");
const kit = @import("testkit.zig");
const archive = @import("archive.zig");
const extract = @import("extract.zig");
const t = std.testing;
const a = kit.a;

fn extractAll(alloc: std.mem.Allocator, dir: std.fs.Dir, bytes: []const u8, format: archive.Format) !void {
    var ex = extract.Extractor.init(alloc, dir, 0);
    defer ex.deinit();
    try archive.extractBytes(alloc, bytes, format, &ex);
}

fn sweep(bytes: []const u8, format: archive.Format) !void {
    var d = kit.Dest.init();
    defer d.deinit();
    try t.checkAllAllocationFailures(t.allocator, extractAll, .{ d.tmp.dir, bytes, format });
}

fn sampleTar() !kit.Tar {
    var b = kit.Tar{};
    errdefer b.deinit();
    try b.gnuLong('L', "a/very/" ** 20 ++ "long");
    try b.file("short", 0o644, "long named file");
    try b.pax(&.{ .{ "path", "pax/named" }, .{ "linkpath", "target" } });
    try b.add(.{ .name = "x", .typeflag = '2', .link = "target" });
    try b.gnuLong('K', "pkg/file");
    try b.add(.{ .name = "pkg/link", .typeflag = '2', .link = "ignored" });
    try b.file("pkg/file", 0o755, "x" ** 700);
    try b.hardlink("pkg/hard", "pkg/file");
    try b.dir("pkg/dir/");
    try b.end();
    return b;
}

test "tar, tar.gz and tar.xz: every allocation failing in turn" {
    var b = try sampleTar();
    defer b.deinit();
    try sweep(b.bytes(), .tar);
    const stored = try kit.gzipStored(b.bytes());
    defer a.free(stored);
    try sweep(stored, .tar_gz);
    const body = try kit.deflateText(b.bytes());
    defer a.free(body);
    const fixed = try kit.gzipOf(body, b.bytes());
    defer a.free(fixed);
    try sweep(fixed, .tar_gz);
    const xz = try kit.xzOf(b.bytes(), .crc64);
    defer a.free(xz);
    try sweep(xz, .tar_xz);
}

test "zip: every allocation failing in turn" {
    var z = kit.Zip{};
    defer z.deinit();
    const body = try kit.deflateText("deflated member");
    defer a.free(body);
    try z.add(.{ .name = "d/", .data = "" });
    try z.add(.{ .name = "d/stored", .data = "stored member", .unix_mode = 0o100755 });
    try z.add(.{ .name = "d/deflated", .data = "deflated member", .body = body });
    try z.add(.{ .name = "d/link", .data = "stored", .unix_mode = 0o120777 });
    const file = try z.finish(false);
    defer a.free(file);
    try sweep(file, .zip);
}
