//! The .deb of a release (RELEASING.md): which targets get one, what it is called, and the check that it is the package of the tarball of its target.
//!
//! The release ships `buildrules_<V>_amd64.deb` and `buildrules_<V>_arm64.deb` beside the tarballs of linux-x86_64 and linux-aarch64. They are made by
//! `tools/channels deb-package` (`release debs`, binaries.zig) from the very binary the tarball was packaged from, and this file is what lets the
//! release tool know that afterwards, without running anything: it reads the `ar` archive, and requires its control file to say this package, this
//! version and this architecture, and `/usr/bin/buildrules` to be, byte for byte, the program inside the tarball. The package is written by another
//! tool and another zig, so what is checked here is only its shape, and a .deb that holds another program than its tarball is refused.
const std = @import("std");
const gz = @import("gz.zig");
const tar = @import("tar.zig");

pub const package_name = "buildrules";

/// A target that gets a .deb, and the Debian architecture of it. Both are static musl binaries.
pub const Deb = struct { target: []const u8, arch: []const u8 };

pub const debs = [_]Deb{
    .{ .target = "linux-x86_64", .arch = "amd64" },
    .{ .target = "linux-aarch64", .arch = "arm64" },
};

const prefix = package_name ++ "_";
const suffix = ".deb";

/// `buildrules_<V>_<arch>.deb`
pub fn name(a: std.mem.Allocator, v: []const u8, arch: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, prefix ++ "{s}_{s}" ++ suffix, .{ v, arch });
}

pub const Named = struct { version: []const u8, arch: []const u8 };

/// The version and architecture a file name spells; null for any other name. The architecture is one of `debs`; the version is not checked here.
pub fn parseName(file: []const u8) ?Named {
    if (!std.mem.startsWith(u8, file, prefix) or !std.mem.endsWith(u8, file, suffix)) return null;
    const mid = file[prefix.len .. file.len - suffix.len];
    const us = std.mem.lastIndexOfScalar(u8, mid, '_') orelse return null;
    const arch = mid[us + 1 ..];
    for (debs) |d| {
        if (std.mem.eql(u8, d.arch, arch)) return .{ .version = mid[0..us], .arch = d.arch };
    }
    return null;
}

/// The architecture a target's .deb carries; null for the target that has none.
pub fn archOf(target: []const u8) ?[]const u8 {
    for (debs) |d| {
        if (std.mem.eql(u8, d.target, target)) return d.arch;
    }
    return null;
}

pub const Error = error{ NotADeb, WrongControl, NoBinary, WrongBinary, OutOfMemory };

const Member = struct { name: []const u8, data: []const u8 };

/// The members of an ar archive, in order (the slices point into `bytes`). A size that runs past the end, a header that does not end in "`\n" are `NotADeb`.
fn readAr(a: std.mem.Allocator, bytes: []const u8) Error![]Member {
    if (!std.mem.startsWith(u8, bytes, "!<arch>\n")) return error.NotADeb;
    var out = std.ArrayList(Member).empty;
    var off: usize = 8;
    while (off < bytes.len) {
        if (off + 60 > bytes.len) return error.NotADeb;
        const h = bytes[off .. off + 60];
        if (h[58] != '`' or h[59] != '\n') return error.NotADeb;
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, h[48..58], " "), 10) catch return error.NotADeb;
        off += 60;
        if (size > bytes.len - off) return error.NotADeb;
        const member = std.mem.trimRight(u8, std.mem.trimRight(u8, h[0..16], " "), "/");
        try out.append(a, .{ .name = member, .data = bytes[off .. off + size] });
        off += size + size % 2;
    }
    return out.toOwnedSlice(a);
}

fn hasLine(text: []const u8, line: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (std.mem.eql(u8, l, line)) return true;
    }
    return false;
}

/// Requires `deb` to be the package `buildrules` of `version` for `arch`, whose `/usr/bin/buildrules` is exactly `binary`.
pub fn check(a: std.mem.Allocator, deb: []const u8, version: []const u8, arch: []const u8, binary: []const u8) Error!void {
    const members = try readAr(a, deb);
    if (members.len != 3) return error.NotADeb;
    if (!std.mem.eql(u8, members[0].name, "debian-binary") or !std.mem.eql(u8, members[0].data, "2.0\n")) return error.NotADeb;
    if (!std.mem.eql(u8, members[1].name, "control.tar.gz") or !std.mem.eql(u8, members[2].name, "data.tar.gz")) return error.NotADeb;

    const control_tar = gz.gunzip(a, members[1].data) catch return error.NotADeb;
    var control: ?[]const u8 = null;
    for (tar.parse(a, control_tar) catch return error.NotADeb) |e| {
        if (e.kind == .file and (std.mem.eql(u8, e.name, "./control") or std.mem.eql(u8, e.name, "control"))) control = e.data;
    }
    const text = control orelse return error.WrongControl;
    const want = [_][]const u8{
        try std.fmt.allocPrint(a, "Package: {s}", .{package_name}),
        try std.fmt.allocPrint(a, "Version: {s}", .{version}),
        try std.fmt.allocPrint(a, "Architecture: {s}", .{arch}),
    };
    for (want) |line| {
        if (!hasLine(text, line)) return error.WrongControl;
    }

    const data_tar = gz.gunzip(a, members[2].data) catch return error.NotADeb;
    for (tar.parse(a, data_tar) catch return error.NotADeb) |e| {
        if (e.kind == .file and std.mem.eql(u8, e.name, "./usr/bin/" ++ package_name)) {
            if (!std.mem.eql(u8, e.data, binary)) return error.WrongBinary;
            return;
        }
    }
    return error.NoBinary;
}
