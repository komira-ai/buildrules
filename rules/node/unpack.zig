//! Unpacking an npm tarball as npm does: the first path component is dropped
//! whatever it is, links are not extracted, files are 0644 (0755 when the
//! tarball marks them executable) and directories 0755.
const std = @import("std");

pub const Stats = struct { files: usize = 0, links: usize = 0 };

pub const Error = error{PathEscapes};

/// The path of `name` below its first component, built in `buf`: empty and
/// `.` components are dropped; a `..` component or a leading `/` is refused.
pub fn stripFirst(name: []const u8, buf: []u8) Error![]const u8 {
    if (name.len > 0 and name[0] == '/') return error.PathEscapes;
    var it = std.mem.tokenizeScalar(u8, name, '/');
    var first = true;
    var n: usize = 0;
    var seen_dotdot = false;
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) seen_dotdot = true;
        if (first) {
            first = false;
            continue;
        }
        if (n + c.len + 1 > buf.len) return error.PathEscapes;
        if (n > 0) {
            buf[n] = '/';
            n += 1;
        }
        @memcpy(buf[n .. n + c.len], c);
        n += c.len;
    }
    if (seen_dotdot) return error.PathEscapes;
    return buf[0..n];
}

pub fn modeOf(tar_mode: u32) std.fs.File.Mode {
    return if (tar_mode & 0o111 != 0) 0o755 else 0o644;
}

/// Extracts the tar read from `reader` into `dest`.
pub fn unpackTar(dest: std.fs.Dir, reader: *std.Io.Reader) !Stats {
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.tar.Iterator.init(reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var stats = Stats{};
    while (try it.next()) |f| {
        if (f.kind == .sym_link) {
            stats.links += 1;
            continue;
        }
        const rel = try stripFirst(f.name, &rel_buf);
        if (rel.len == 0) continue;
        switch (f.kind) {
            .directory => try dest.makePath(rel),
            .file => {
                if (std.fs.path.dirname(rel)) |d| try dest.makePath(d);
                const file = try dest.createFile(rel, .{ .mode = modeOf(f.mode) });
                defer file.close();
                var fbuf: [64 * 1024]u8 = undefined;
                var fw = file.writer(&fbuf);
                try it.streamRemaining(f, &fw.interface);
                try fw.interface.flush();
                try file.chmod(modeOf(f.mode));
                stats.files += 1;
            },
            .sym_link => unreachable,
        }
    }
    return stats;
}

/// A reader that hands on what `inner` yields and keeps the CRC-32 and the
/// length (mod 2^32) of it: the two values a gzip trailer states of the
/// decompressed bytes, which the standard library's decompressor reads but
/// does not compare.
pub const Summing = struct {
    inner: *std.Io.Reader,
    crc: std.hash.Crc32 = .init(),
    len: u32 = 0,
    reader: std.Io.Reader,

    pub fn init(inner: *std.Io.Reader, buffer: []u8) Summing {
        return .{
            .inner = inner,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Summing = @fieldParentPtr("reader", r);
        const dest = limit.slice(try w.writableSliceGreedy(1));
        if (dest.len == 0) return 0;
        const n = try self.inner.readSliceShort(dest);
        if (n == 0) return error.EndOfStream;
        self.crc.update(dest[0..n]);
        self.len +%= @as(u32, @truncate(n));
        w.advance(n);
        return n;
    }
};

/// Extracts the gzipped tar `bytes` into `dest`.
pub fn unpackTgz(dest: std.fs.Dir, bytes: []const u8) !Stats {
    var in: std.Io.Reader = .fixed(bytes);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec = std.compress.flate.Decompress.init(&in, .gzip, &window);
    var sbuf: [8 * 1024]u8 = undefined;
    var sum = Summing.init(&dec.reader, &sbuf);
    // A read that fails is the gzip stream's: the decompressor refuses a block, or a trailer that is cut (it reads the trailer as the last
    // block ends, which can be while the tar is still reading its zero blocks).
    const stats = unpackTar(dest, &sum.reader) catch |err| return if (err == error.ReadFailed) error.CorruptGzip else err;
    // The tar ends at its zero blocks; reading the rest of the gzip stream
    // reads its trailer, so a truncated tarball is an error and not a short
    // package. The decompressor keeps the trailer's CRC-32 and length but
    // compares neither: they are compared here with those of the bytes that
    // were read, so a corrupt tarball is an error as well.
    _ = sum.reader.discardRemaining() catch return error.CorruptGzip;
    const trailer = dec.container_metadata.gzip;
    if (trailer.crc != sum.crc.final()) return error.GzipCrcMismatch;
    if (trailer.count != sum.len) return error.GzipSizeMismatch;
    return stats;
}
