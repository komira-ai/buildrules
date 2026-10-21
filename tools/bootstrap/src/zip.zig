//! A zip file (stored and deflated members, zip64) read from memory by its central directory, and extracted through an `Extractor`.
//!
//! Refused, naming the member: encryption, a compression method other than stored and deflate, a member whose bytes are not where its header says or whose
//! CRC-32 or length is not its header's, a split archive, a name with a backslash, and an archive with no member. A member made on a Unix host keeps its
//! permission bits and may be a symbolic link (its content is the target); any other host's members are files of mode `0o644` or directories.
const std = @import("std");
const paths = @import("paths.zig");
const extract = @import("extract.zig");
const inflate = @import("inflate.zig");
const stream = @import("stream.zig");

pub const Error = error{
    BadZip,
    Encrypted,
    UnsupportedMethod,
    SplitArchive,
    BackslashInName,
    EntryCorrupt,
    EmptyArchive,
    UnsupportedType,
};

fn le16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn le32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn le64(b: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, b[at..][0..8], .little);
}

/// `n` bytes of `b` from `at`, or `BadZip` when the file is not that long.
fn slice(b: []const u8, at: u64, n: u64) ![]const u8 {
    if (at > b.len or n > b.len - at) return error.BadZip;
    return b[@intCast(at)..][0..@intCast(n)];
}

const Directory = struct { offset: u64, size: u64, count: u64 };

fn findDirectory(b: []const u8) !Directory {
    if (b.len < 22) return error.BadZip;
    const lowest = b.len -| (22 + 0xffff);
    var at = b.len - 22;
    while (le32(b, at) != 0x06054b50) : (at -= 1) {
        if (at == lowest) return error.BadZip;
    }
    const eocd = b[at..];
    if (le16(eocd, 4) != 0 or le16(eocd, 6) != 0) return error.SplitArchive;
    var d = Directory{ .count = le16(eocd, 10), .size = le32(eocd, 12), .offset = le32(eocd, 16) };
    if (d.count == 0xffff or d.size == 0xffffffff or d.offset == 0xffffffff) {
        if (at < 20) return error.BadZip;
        const loc = b[at - 20 ..];
        if (le32(loc, 0) != 0x07064b50) return error.BadZip;
        if (le32(loc, 4) != 0 or le32(loc, 16) != 1) return error.SplitArchive;
        const z = try slice(b, le64(loc, 8), 56);
        if (le32(z, 0) != 0x06064b50) return error.BadZip;
        if (le32(z, 16) != 0 or le32(z, 20) != 0) return error.SplitArchive;
        d = .{ .count = le64(z, 32), .size = le64(z, 40), .offset = le64(z, 48) };
    }
    return d;
}

/// The zip64 extended-information extra field's values, taken in order for each of the header's fields that is all ones.
fn zip64(extra: []const u8, usize_: *u64, csize: *u64, offset: *u64) !void {
    var at: usize = 0;
    while (at + 4 <= extra.len) {
        const id = le16(extra, at);
        const len = le16(extra, at + 2);
        const body = try slice(extra, at + 4, len);
        at += 4 + len;
        if (id != 0x0001) continue;
        var k: usize = 0;
        for ([_]*u64{ usize_, csize, offset }) |field| {
            if (field.* != 0xffffffff) continue;
            if (k + 8 > body.len) return error.BadZip;
            field.* = le64(body, k);
            k += 8;
        }
        return;
    }
}

const S_IFMT = 0o170000;
const S_IFDIR = 0o040000;
const S_IFLNK = 0o120000;
const S_IFREG = 0o100000;

/// Extracts every member of the zip file `b` through `ex`.
pub fn extractAll(a: std.mem.Allocator, b: []const u8, ex: *extract.Extractor) !void {
    const dir = try findDirectory(b);
    var at = dir.offset;
    _ = try slice(b, dir.offset, dir.size);
    var n: u64 = 0;
    while (n < dir.count) : (n += 1) {
        const h = try slice(b, at, 46);
        if (le32(h, 0) != 0x02014b50) return error.BadZip;
        const made_by = le16(h, 4);
        const flags = le16(h, 8);
        const method = le16(h, 10);
        const crc = le32(h, 16);
        var csize: u64 = le32(h, 20);
        var usize_: u64 = le32(h, 24);
        const nlen = le16(h, 28);
        const elen = le16(h, 30);
        const clen = le16(h, 32);
        const attrs = le32(h, 38);
        var offset: u64 = le32(h, 42);
        const name = try slice(b, at + 46, nlen);
        const extra = try slice(b, at + 46 + nlen, elen);
        at += 46 + @as(u64, nlen) + elen + clen;
        try zip64(extra, &usize_, &csize, &offset);

        ex.note(name);
        if (flags & 0x41 != 0) return error.Encrypted;
        if (std.mem.indexOfScalar(u8, name, '\\') != null) return error.BackslashInName;
        var buf: [paths.max_path]u8 = undefined;
        const rel = try paths.clean(name, ex.strip, &buf);

        const unix = (made_by >> 8) == 3;
        const mode: u32 = if (unix) attrs >> 16 else 0;
        const kind: u32 = if (unix) mode & S_IFMT else 0;
        if (kind == S_IFDIR or name[name.len - 1] == '/') {
            if (rel) |r| try ex.mkdir(r);
            continue;
        }
        if (kind != 0 and kind != S_IFREG and kind != S_IFLNK) return error.UnsupportedType;
        if (method != 0 and method != 8) return error.UnsupportedMethod;

        const local = try slice(b, offset, 30);
        if (le32(local, 0) != 0x04034b50) return error.BadZip;
        const start = offset + 30 + @as(u64, le16(local, 26)) + le16(local, 28);
        const body = try slice(b, start, csize);

        if (kind == S_IFLNK) {
            var target = Collect{ .a = a };
            defer target.list.deinit(a);
            try member(a, method, body, crc, usize_, stream.sinkOf(Collect, &target), ex);
            if (rel) |r| try ex.symlink(r, target.list.items);
            continue;
        }
        if (rel) |r| {
            var out = try ex.createFile(r, if (mode & 0o777 != 0) mode else 0o644);
            defer out.close();
            try member(a, method, body, crc, usize_, stream.sinkOf(extract.Out, &out), ex);
        } else {
            var out = extract.Out{ .file = null };
            try member(a, method, body, crc, usize_, stream.sinkOf(extract.Out, &out), ex);
        }
    }
    if (ex.entries == 0) return error.EmptyArchive;
}

/// One member's content into `sink`, checked against the CRC-32 and the length of its header.
fn member(a: std.mem.Allocator, method: u16, body: []const u8, crc: u32, size: u64, sink: stream.Sink, ex: *extract.Extractor) !void {
    var got_crc: u32 = undefined;
    var got_len: u64 = undefined;
    if (method == 0) {
        try sink.write(body);
        got_crc = std.hash.Crc32.hash(body);
        got_len = body.len;
    } else {
        const r = try inflate.inflate(a, body, sink);
        got_crc = r.crc;
        got_len = r.len;
    }
    if (got_crc != crc or got_len != size) return error.EntryCorrupt;
    ex.stats.bytes += got_len;
}

/// A symbolic link's target, read out of its member (at most a path's length).
const Collect = struct {
    a: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    pub fn write(self: *Collect, bytes: []const u8) !void {
        if (self.list.items.len + bytes.len > paths.max_path) return error.NameTooLong;
        try self.list.appendSlice(self.a, bytes);
    }
};
