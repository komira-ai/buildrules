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

/// Unpacks the package `bytes` into `dir`; null when it was, else why not (the error, and the entry it was on when the tar refused one).
pub fn unpack(a: Alloc, bytes: []const u8, dir: std.fs.Dir) Oom!?[]const u8 {
    var why: []const u8 = "";
    const all = (try members(a, bytes, &why)) orelse return why;
    if (all.len == 0 or !std.mem.eql(u8, all[0].name, "debian-binary") or !std.mem.startsWith(u8, all[0].data, "2.")) {
        return "it is not a Debian package: its first member is not `debian-binary` holding a version 2 format";
    }
    for (all[1..]) |m| {
        if (!std.mem.startsWith(u8, m.name, "data.tar")) continue;
        const format = formatOf(m.name) orelse
            return try std.fmt.allocPrint(a, "its data member is `{s}`: the runner reads data.tar, data.tar.gz and data.tar.xz", .{m.name});
        var ex = bootstrap.extract.Extractor.init(a, dir, 0);
        defer ex.deinit();
        bootstrap.extractBytes(a, m.data, format, &ex) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return try std.fmt.allocPrint(a, "its `{s}` cannot be unpacked: {s} (at the entry `{s}`)", .{ m.name, @errorName(e), ex.lastName() }),
        };
        return null;
    }
    return "it has no data member (data.tar, data.tar.gz or data.tar.xz)";
}
