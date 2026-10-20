//! prebuilt_unpack: the `.mojoc` of a registry package, out of its `.conda`.
//!
//! usage: prebuilt_unpack <package.conda> <name> <out.mojoc>
//!
//! A registry package is a `.conda` holding `lib/mojo/<name>.mojoc` (and `lib/mojo/<name>.mopm.json`), written by
//! `mopm pack` (spec/package-metadata.schema.json). The zip walk and the zstd/tar reading are those of
//! conda_unpack.zig (the compiler closure's unpacker), which cannot be used here: it insists on the compiler's
//! members and on `info/paths.json`, which a mopm package does not carry. Nothing but the one member is written.
//! The file's sha256 was checked when it was downloaded (pinned_file), so only its shape is checked here: a regular
//! file that is not empty.

const std = @import("std");

const window_len: u32 = 1 << 27;

fn le16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}
fn le32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn le64(b: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, b[at..][0..8], .little);
}

fn zip64CompressedSize(extra: []const u8, usize_is_64: bool) ?u64 {
    var i: usize = 0;
    while (i + 4 <= extra.len) {
        const id = le16(extra, i);
        const len = le16(extra, i + 2);
        if (i + 4 + len > extra.len) return null;
        if (id == 0x0001) {
            var at = i + 4;
            if (usize_is_64) at += 8;
            if (at + 8 > i + 4 + len) return null;
            return le64(extra, at);
        }
        i += 4 + len;
    }
    return null;
}

pub const Error = anyerror;

/// The body of the `pkg-*.tar.zst` member of a `.conda` (a zip of stored members).
pub fn payload(data: []const u8) Error![]const u8 {
    var pkg: ?[]const u8 = null;
    var off: usize = 0;
    while (off + 30 <= data.len and le32(data, off) == 0x04034b50) {
        const flags = le16(data, off + 6);
        const method = le16(data, off + 8);
        var csize: u64 = le32(data, off + 18);
        const usize32 = le32(data, off + 22);
        const nlen = le16(data, off + 26);
        const xlen = le16(data, off + 28);
        const start = off + 30 + nlen + xlen;
        if (start > data.len) return error.BadZip;
        const name = data[off + 30 .. off + 30 + nlen];
        const extra = data[off + 30 + nlen .. start];
        if (flags & 0x8 != 0 or method != 0) return error.BadZip;
        if (csize == 0xffffffff) csize = zip64CompressedSize(extra, usize32 == 0xffffffff) orelse return error.BadZip;
        if (start + csize > data.len) return error.BadZip;
        const body = data[start .. start + @as(usize, @intCast(csize))];
        off = start + @as(usize, @intCast(csize));
        if (std.mem.startsWith(u8, name, "pkg-") and std.mem.endsWith(u8, name, ".tar.zst")) pkg = body;
    }
    return pkg orelse error.NoPayload;
}

/// The bytes of `member` in the zstd-compressed tar `tar_zst`.
pub fn member(a: std.mem.Allocator, tar_zst: []const u8, want: []const u8) Error![]u8 {
    const window = try a.alloc(u8, window_len + std.compress.zstd.block_size_max);
    defer a.free(window);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var zin: std.Io.Reader = .fixed(tar_zst);
    var dz = std.compress.zstd.Decompress.init(&zin, window, .{ .window_len = window_len });
    var it = std.tar.Iterator.init(&dz.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    while (try it.next()) |f| {
        if (!std.mem.eql(u8, f.name, want)) {
            // The iterator would discard the body itself, but the discard of this release's zstd reader asserts: stream it into nothing.
            if (f.size != 0) {
                var sink = std.Io.Writer.Discarding.init(&.{});
                try it.streamRemaining(f, &sink.writer);
            }
            continue;
        }
        if (f.kind != .file) return error.NotAFile;
        if (f.size == 0) return error.EmptyMember;
        const bytes = try it.reader.readAlloc(a, @intCast(f.size));
        it.unread_file_bytes = 0;
        return bytes;
    }
    return error.NoMember;
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("prebuilt_unpack: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len != 4) die("usage: prebuilt_unpack <package.conda> <name> <out.mojoc>", .{});
    const data = std.fs.cwd().readFileAlloc(a, args[1], 1 << 30) catch |e| die("cannot read {s}: {s}", .{ args[1], @errorName(e) });
    const want = try std.fmt.allocPrint(a, "lib/mojo/{s}.mojoc", .{args[2]});
    const pkg = payload(data) catch |e| die("{s}: {s}", .{ args[1], @errorName(e) });
    const bytes = member(a, pkg, want) catch |e| die("{s}: {s}: {s}", .{ args[1], want, @errorName(e) });
    std.fs.cwd().writeFile(.{ .sub_path = args[3], .data = bytes }) catch |e| die("cannot write {s}: {s}", .{ args[3], @errorName(e) });
}
