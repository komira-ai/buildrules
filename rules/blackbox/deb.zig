//! A Debian package unpacked into a directory, the way `dpkg-deb -x` lays it out, without dpkg: the runner must work in an image that has none, and as a
//! user that cannot install anything.
//!
//! A `.deb` is an `ar` archive whose first member is `debian-binary` (`2.0\n`) and which holds `control.tar.*` and `data.tar`, `data.tar.gz` or
//! `data.tar.xz`. Only the data member is unpacked; the control member (the maintainer scripts) is not run, as the service's program is started by
//! hand. The tar is read by the extractor of `unpack` (tools/bootstrap): an entry that would land outside the directory (an absolute path, a `..`, a
//! link that climbs out, an entry written through a link) is refused, and set-uid, set-gid and sticky bits are dropped. `data.tar.zst` is refused by
//! name: no package this is for writes one.

const std = @import("std");
const bootstrap = @import("bootstrap_archive");

const Alloc = std.mem.Allocator;
const Oom = error{OutOfMemory};

const magic = "!<arch>\n";
const header_len = 60;

pub const Member = struct { name: []const u8, data: []const u8 };

/// The members of the ar archive `bytes`, in order, or why it is not one.
pub fn members(a: Alloc, bytes: []const u8, why: *[]const u8) Oom!?[]const Member {
    if (!std.mem.startsWith(u8, bytes, magic)) {
        why.* = "it is not an ar archive (a .deb starts with `!<arch>`)";
        return null;
    }
    var out: std.ArrayList(Member) = .empty;
    var at: usize = magic.len;
    while (at < bytes.len) {
        if (bytes.len - at < header_len) {
            why.* = "it ends inside a member's header";
            return null;
        }
        const h = bytes[at .. at + header_len];
        if (!std.mem.eql(u8, h[58..60], "`\n")) {
            why.* = "a member's header does not end as an ar header ends";
            return null;
        }
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, h[48..58], " "), 10) catch {
            why.* = "a member's size is not a number";
            return null;
        };
        at += header_len;
        if (size > bytes.len - at) {
            why.* = "it ends inside a member";
            return null;
        }
        const name = std.mem.trimRight(u8, std.mem.trimRight(u8, h[0..16], " "), "/");
        try out.append(a, .{ .name = name, .data = bytes[at .. at + size] });
        // A member starts at an even offset: an odd one is followed by a newline.
        at += size + (size & 1);
    }
    return out.items;
}

/// The format of a data member, by its name.
fn formatOf(name: []const u8) ?bootstrap.Format {
    if (std.mem.eql(u8, name, "data.tar")) return .tar;
    if (std.mem.eql(u8, name, "data.tar.gz")) return .tar_gz;
    if (std.mem.eql(u8, name, "data.tar.xz")) return .tar_xz;
    return null;
}

/// The data member of the package `bytes` and its format.
pub const Data = struct { name: []const u8, format: bootstrap.Format, bytes: []const u8 };

/// A package's data member, or why it has none this reads (`why`).
fn dataOf(a: Alloc, bytes: []const u8, why: *[]const u8) Oom!?Data {
    const all = (try members(a, bytes, why)) orelse return null;
    if (all.len == 0 or !std.mem.eql(u8, all[0].name, "debian-binary") or !std.mem.startsWith(u8, all[0].data, "2.")) {
        why.* = "it is not a Debian package: its first member is not `debian-binary` holding a version 2 format";
        return null;
    }
    for (all[1..]) |m| {
        if (!std.mem.startsWith(u8, m.name, "data.tar")) continue;
        const format = formatOf(m.name) orelse {
            why.* = try std.fmt.allocPrint(a, "its data member is `{s}`: the runner reads data.tar, data.tar.gz and data.tar.xz", .{m.name});
            return null;
        };
        return .{ .name = m.name, .format = format, .bytes = m.data };
    }
    why.* = "it has no data member (data.tar, data.tar.gz or data.tar.xz)";
    return null;
}

/// Collects what a decoder writes.
const Collect = struct {
    a: Alloc,
    out: std.ArrayList(u8) = .empty,

    pub fn write(self: *Collect, bytes: []const u8) !void {
        try self.out.appendSlice(self.a, bytes);
    }
};

/// What `files` gives: the paths, or why the package cannot be read.
pub const Listing = struct { paths: []const []const u8 = &.{}, why: ?[]const u8 = null };

/// The paths of every entry of the package `bytes` that is not a directory (files and links), as it puts them below the root: `usr/bin/x` for
/// `./usr/bin/x`. Read without writing anything, so two packages can be compared before either is unpacked.
pub fn files(a: Alloc, bytes: []const u8) Oom!Listing {
    var why: []const u8 = "";
    const data = (try dataOf(a, bytes, &why)) orelse return .{ .why = why };
    var c = Collect{ .a = a };
    const plain: []const u8 = switch (data.format) {
        .tar_gz, .tar_xz => blk: {
            const decoded = if (data.format == .tar_gz) bootstrap.inflate.gunzip(a, data.bytes, bootstrap.stream.sinkOf(Collect, &c)) else bootstrap.xz.unxz(a, data.bytes, bootstrap.stream.sinkOf(Collect, &c));
            decoded catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return .{ .why = try std.fmt.allocPrint(a, "its `{s}` cannot be read: {s}", .{ data.name, @errorName(e) }) },
            };
            break :blk c.out.items;
        },
        else => data.bytes,
    };
    var in: std.Io.Reader = .fixed(plain);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.tar.Iterator.init(&in, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var out: std.ArrayList([]const u8) = .empty;
    while (it.next() catch |e| return .{ .why = try std.fmt.allocPrint(a, "its `{s}` cannot be read: {s}", .{ data.name, @errorName(e) }) }) |f| {
        if (f.kind == .directory) continue;
        var name = f.name;
        while (std.mem.startsWith(u8, name, "./")) name = name[2..];
        try out.append(a, try a.dupe(u8, name));
    }
    return .{ .paths = out.items };
}

/// Unpacks the package `bytes` into `dir`; null when it was, else why not (the error, and the entry it was on when the tar refused one).
pub fn unpack(a: Alloc, bytes: []const u8, dir: std.fs.Dir) Oom!?[]const u8 {
    var why: []const u8 = "";
    const data = (try dataOf(a, bytes, &why)) orelse return why;
    var ex = bootstrap.extract.Extractor.init(a, dir, 0);
    defer ex.deinit();
    bootstrap.extractBytes(a, data.bytes, data.format, &ex) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try std.fmt.allocPrint(a, "its `{s}` cannot be unpacked: {s} (at the entry `{s}`)", .{ data.name, @errorName(e), ex.lastName() }),
    };
    return null;
}
