//! main.zig: the command line, the checks made before anything is read (size, sha256, format), and the whole path from a file to a tree, through the same
//! function the executable calls.
const std = @import("std");
const kit = @import("testkit.zig");
const main = @import("main.zig");
const t = std.testing;
const a = kit.a;

fn parseOk(args: []const []const u8) !main.Options {
    var diag: []const u8 = "";
    return main.parse(args, &diag);
}

fn parseBad(args: []const []const u8, want: []const u8) !void {
    var diag: []const u8 = "";
    try t.expectError(error.Usage, main.parse(args, &diag));
    try t.expectEqualStrings(want, diag);
}

const sha_of_x = "2d711642b726b04401627ca9fbac32f5c8530fb1903cc4db02258717921a4881";

test "parse: every option" {
    const o = try parseOk(&.{ "--strip-components", "2", "--size", "123", "--sha256", sha_of_x, "--format", "tar.xz", "in.tar.xz", "out" });
    try t.expectEqual(@as(usize, 2), o.strip);
    try t.expectEqual(@as(?u64, 123), o.size);
    try t.expectEqual(main.archive.Format.tar_xz, o.format.?);
    try t.expectEqualStrings("in.tar.xz", o.archive);
    try t.expectEqualStrings("out", o.dest.?);
    try t.expectEqual(@as(u8, 0x2d), o.sha256.?[0]);
    try t.expectEqual(@as(u8, 0x81), o.sha256.?[31]);
    for ([_][]const u8{ "tar", "tar.gz", "zip" }) |f| {
        const p = try parseOk(&.{ "--format", f, "a", "b" });
        try t.expect(p.format != null);
    }
}

test "parse: --check takes the archive alone" {
    const o = try parseOk(&.{ "--check", "in.zip" });
    try t.expect(o.dest == null);
    try t.expectEqualStrings("in.zip", o.archive);
    const p = try parseOk(&.{ "in.zip", "--check" });
    try t.expect(p.dest == null);
}

test "parse: refusals say what is wrong" {
    try parseBad(&.{}, "no archive given");
    try parseBad(&.{"only-one"}, "the archive and the destination are both required");
    try parseBad(&.{ "a", "b", "c" }, "too many arguments");
    try parseBad(&.{ "--check", "a", "b" }, "--check takes the archive and no destination");
    try parseBad(&.{"--strip-components"}, "an option has no value");
    try parseBad(&.{ "--strip-components", "x", "a", "b" }, "--strip-components takes a number");
    try parseBad(&.{ "--strip-components", "-1", "a", "b" }, "--strip-components takes a number");
    try parseBad(&.{ "--size", "big", "a", "b" }, "--size takes a number of bytes");
    try parseBad(&.{ "--sha256", "abc", "a", "b" }, "--sha256 takes 64 lower-case hex digits");
    try parseBad(&.{ "--sha256", "G" ** 64, "a", "b" }, "--sha256 takes 64 lower-case hex digits");
    try parseBad(&.{ "--sha256", "A" ** 64, "a", "b" }, "--sha256 takes 64 lower-case hex digits");
    try parseBad(&.{ "--format", "rar", "a", "b" }, "--format is tar, tar.gz, tar.xz or zip");
    try parseBad(&.{ "--bogus", "1", "a", "b" }, "unknown option");
}

/// Writes `bytes` as `name` in the temporary directory and returns its absolute path (and `out`'s, below).
fn put(d: *kit.Dest, name: []const u8, bytes: []const u8) ![]u8 {
    try d.tmp.dir.writeFile(.{ .sub_path = name, .data = bytes });
    return where(d, name);
}

fn where(d: *kit.Dest, name: []const u8) ![]u8 {
    const root = try d.tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    return std.fs.path.join(a, &.{ root, name });
}

fn sampleTarGz() ![]u8 {
    var b = kit.Tar{};
    defer b.deinit();
    try b.file("pkg/bin/run", 0o755, "program");
    try b.file("pkg/data", 0o644, "data");
    try b.end();
    return kit.gzipStored(b.bytes());
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &h, .{});
    return std.fmt.bytesToHex(h, .lower);
}

test "run: extracts, with the size and sha256 given" {
    var d = kit.Dest.init();
    defer d.deinit();
    const gz = try sampleTarGz();
    defer a.free(gz);
    const archive = try put(&d, "in.tar.gz", gz);
    defer a.free(archive);
    const dest = try where(&d, "out/nested/dest");
    defer a.free(dest);
    var entry = main.Entry{};
    const sums = sha256Hex(gz);
    const stats = try main.run(a, .{ .archive = archive, .dest = dest, .strip = 1, .size = gz.len, .sha256 = hexBytes(&sums) }, &entry);
    try t.expectEqual(@as(u64, 2), stats.files);
    const got = try d.read("out/nested/dest/bin/run");
    defer a.free(got);
    try t.expectEqualStrings("program", got);
    try t.expectEqual(@as(u32, 0o755), try d.mode("out/nested/dest/bin/run"));
}

fn hexBytes(hex: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "run: a wrong size or sha256 is refused before anything is written" {
    var d = kit.Dest.init();
    defer d.deinit();
    const gz = try sampleTarGz();
    defer a.free(gz);
    const archive = try put(&d, "in.tar.gz", gz);
    defer a.free(archive);
    const dest = try where(&d, "out");
    defer a.free(dest);
    var entry = main.Entry{};
    try t.expectError(error.SizeMismatch, main.run(a, .{ .archive = archive, .dest = dest, .size = gz.len + 1 }, &entry));
    try t.expectError(error.SizeMismatch, main.run(a, .{ .archive = archive, .dest = dest, .size = gz.len - 1 }, &entry));
    const wrong = hexBytes(&sha256Hex("something else"));
    try t.expectError(error.Sha256Mismatch, main.run(a, .{ .archive = archive, .dest = dest, .sha256 = wrong }, &entry));
    // the digest of a file with one byte changed
    const flipped = try a.dupe(u8, gz);
    defer a.free(flipped);
    flipped[flipped.len / 2] ^= 1;
    const archive2 = try put(&d, "flipped.tar.gz", flipped);
    defer a.free(archive2);
    const sum = hexBytes(&sha256Hex(gz));
    try t.expectError(error.Sha256Mismatch, main.run(a, .{ .archive = archive2, .dest = dest, .size = gz.len, .sha256 = sum }, &entry));
    try t.expect(!d.has("out"));
}

test "run: a file that is no archive, or is not the format given" {
    var d = kit.Dest.init();
    defer d.deinit();
    const text = try put(&d, "notes.txt", "just some text, not an archive");
    defer a.free(text);
    const dest = try where(&d, "out");
    defer a.free(dest);
    var entry = main.Entry{};
    try t.expectError(error.UnknownFormat, main.run(a, .{ .archive = text, .dest = dest }, &entry));
    try t.expectError(error.NotGzip, main.run(a, .{ .archive = text, .dest = dest, .format = .tar_gz }, &entry));
    try t.expectError(error.Corrupt, main.run(a, .{ .archive = text, .dest = dest, .format = .tar_xz }, &entry));
    try t.expectError(error.BadZip, main.run(a, .{ .archive = text, .dest = dest, .format = .zip }, &entry));
    // plain text of block size read as a tar: its checksum field is no number
    const block = try put(&d, "block", "x" ** 512);
    defer a.free(block);
    try t.expectError(error.BadNumber, main.run(a, .{ .archive = block, .dest = dest, .format = .tar }, &entry));
}

test "run: a missing archive, and one over the size limit" {
    var d = kit.Dest.init();
    defer d.deinit();
    const none = try where(&d, "nothing.tar");
    defer a.free(none);
    var entry = main.Entry{};
    try t.expectError(error.FileNotFound, main.run(a, .{ .archive = none, .dest = null }, &entry));
    const f = try d.tmp.dir.createFile("huge.tar", .{});
    try f.setEndPos(main.max_archive + 1);
    f.close();
    const huge = try where(&d, "huge.tar");
    defer a.free(huge);
    try t.expectError(error.ArchiveTooLarge, main.run(a, .{ .archive = huge, .dest = null }, &entry));
}

test "run: --check reads everything, writes nothing, and names the entry that fails" {
    var d = kit.Dest.init();
    defer d.deinit();
    const gz = try sampleTarGz();
    defer a.free(gz);
    const archive = try put(&d, "in.tar.gz", gz);
    defer a.free(archive);
    var entry = main.Entry{};
    const stats = try main.run(a, .{ .archive = archive, .dest = null }, &entry);
    try t.expectEqual(@as(u64, 2), stats.files);
    try t.expectEqual(@as(usize, 0), entry.name().len);

    var b = kit.Tar{};
    defer b.deinit();
    try b.file("fine", 0o644, "x");
    try b.file("pkg/../../evil", 0o644, "x");
    try b.end();
    const slip = try put(&d, "slip.tar", b.bytes());
    defer a.free(slip);
    try t.expectError(error.ParentComponent, main.run(a, .{ .archive = slip, .dest = null }, &entry));
    try t.expectEqualStrings("pkg/../../evil", entry.name());
}

test "mainWith: exit status 0 on success and 2 on every refusal" {
    var d = kit.Dest.init();
    defer d.deinit();
    const gz = try sampleTarGz();
    defer a.free(gz);
    const archive = try put(&d, "in.tar.gz", gz);
    defer a.free(archive);
    const dest = try where(&d, "out");
    defer a.free(dest);
    try t.expectEqual(@as(u8, 0), main.mainWith(a, &.{ archive, dest }));
    try t.expect(d.has("out/pkg/data"));
    try t.expectEqual(@as(u8, 0), main.mainWith(a, &.{ "--check", archive }));
    try t.expectEqual(@as(u8, 2), main.mainWith(a, &.{}));
    try t.expectEqual(@as(u8, 2), main.mainWith(a, &.{ "--size", "1", archive, dest }));
    try t.expectEqual(@as(u8, 2), main.mainWith(a, &.{ "/nonexistent/archive.tar", dest }));
    var b = kit.Tar{};
    defer b.deinit();
    try b.file("../evil", 0o644, "x");
    try b.end();
    const slip = try put(&d, "slip.tar", b.bytes());
    defer a.free(slip);
    try t.expectEqual(@as(u8, 2), main.mainWith(a, &.{ slip, dest }));
}

test "explainError: each refusal has a sentence, and an unknown error has none" {
    try t.expect(main.explainError(error.ParentComponent) != null);
    try t.expect(main.explainError(error.Sha256Mismatch) != null);
    try t.expect(main.explainError(error.Truncated) != null);
    try t.expect(main.explainError(error.OutOfMemory) == null);
    // every sentence is distinct and says something
    for (main.explainErrors(), 0..) |x, i| {
        try t.expect(x.text.len > 10);
        for (main.explainErrors()[0..i]) |y| try t.expect(!std.mem.eql(u8, x.text, y.text));
    }
}
