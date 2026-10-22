//! The formats `unpack` reads, how one is told from the bytes, and the path from the file's bytes to the extractor.
const std = @import("std");
const extract = @import("extract.zig");
const inflate = @import("inflate.zig");
const tar = @import("tar.zig");
const xz = @import("xz.zig");
const zip = @import("zip.zig");

pub const Format = enum { tar, tar_gz, tar_xz, zip };

pub const names = [_]struct { text: []const u8, format: Format }{
    .{ .text = "tar", .format = .tar },
    .{ .text = "tar.gz", .format = .tar_gz },
    .{ .text = "tar.xz", .format = .tar_xz },
    .{ .text = "zip", .format = .zip },
};

/// The format a file's first bytes say it is: the xz, gzip or zip magic, or `ustar` at its place in a tar header. A tar of an older kind has no magic and is
/// named with `--format tar`.
pub fn detect(bytes: []const u8) ?Format {
    if (std.mem.startsWith(u8, bytes, "\xfd7zXZ\x00")) return .tar_xz;
    if (std.mem.startsWith(u8, bytes, "\x1f\x8b")) return .tar_gz;
    if (std.mem.startsWith(u8, bytes, "PK\x03\x04") or std.mem.startsWith(u8, bytes, "PK\x05\x06")) return .zip;
    if (bytes.len >= 263 and std.mem.eql(u8, bytes[257..262], "ustar")) return .tar;
    return null;
}

/// Extracts the archive `bytes` of `format` through `ex`; a tar must end as a tar ends (tar.zig) and a compressed one must be whole to its checksums.
pub fn extractBytes(a: std.mem.Allocator, bytes: []const u8, format: Format, ex: *extract.Extractor) !void {
    var parser = tar.Parser.init(a, ex);
    defer parser.deinit();
    switch (format) {
        .zip => return zip.extractAll(a, bytes, ex),
        .tar => try parser.write(bytes),
        .tar_gz => try inflate.gunzip(a, bytes, parser.sink()),
        .tar_xz => try xz.unxz(a, bytes, parser.sink()),
    }
    try parser.finish();
}
