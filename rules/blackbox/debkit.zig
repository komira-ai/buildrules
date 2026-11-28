//! Writes Debian packages for the tests and the toy (toy/pack.zig): an `ar` archive of `debian-binary`, `control.tar.gz` and a data member, the tars
//! in ustar with any entry a test needs (an absolute name, a `..`, a link), gzip of stored deflate blocks. Written apart from the reader it tests (deb.zig
//! and the extractor of tools/bootstrap), from the formats' own descriptions.

const std = @import("std");

const Alloc = std.mem.Allocator;
const Oom = error{OutOfMemory};

pub const Entry = struct {
    name: []const u8,
    /// `0` a file, `5` a directory, `2` a symbolic link, `1` a hard link.
    typeflag: u8 = '0',
    mode: u32 = 0o644,
    link: []const u8 = "",
    data: []const u8 = "",
};

fn octal(field: []u8, v: u64) void {
    // Right-aligned, zero-padded, NUL-terminated: `0000644\x00`.
    var digits = v;
    var k = field.len - 1;
    while (k > 0) {
        k -= 1;
        field[k] = '0' + @as(u8, @intCast(digits & 7));
        digits >>= 3;
    }
    field[field.len - 1] = 0;
}

/// The ustar header of `e`.
pub fn header(e: Entry) [512]u8 {
    var h = [_]u8{0} ** 512;
    @memcpy(h[0..e.name.len], e.name);
    octal(h[100..108], e.mode);
    octal(h[108..116], 0);
    octal(h[116..124], 0);
    octal(h[124..136], if (e.typeflag == '0') e.data.len else 0);
    octal(h[136..148], 0);
    h[156] = e.typeflag;
    @memcpy(h[157 .. 157 + e.link.len], e.link);
    @memcpy(h[257..265], "ustar\x0000");
    @memset(h[148..156], ' ');
    var sum: u64 = 0;
    for (h) |b| sum += b;
    _ = std.fmt.bufPrint(h[148..155], "{o:0>6}\x00", .{sum}) catch unreachable;
    return h;
}

/// A tar of `entries`, ended by its two zero blocks.
pub fn tar(a: Alloc, entries: []const Entry) Oom![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (entries) |e| {
        try out.appendSlice(a, &header(e));
        if (e.typeflag == '0') {
            try out.appendSlice(a, e.data);
            try out.appendNTimes(a, 0, (512 - e.data.len % 512) % 512);
        }
    }
    try out.appendNTimes(a, 0, 1024);
    return out.items;
}

/// A gzip file of `plain` in stored deflate blocks (at most 65535 bytes each), with its CRC-32 and length.
pub fn gzip(a: Alloc, plain: []const u8) Oom![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, &.{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3 });
    var rest = plain;
    while (true) {
        const n = @min(rest.len, 65535);
        const final = n == rest.len;
        try out.append(a, @intFromBool(final));
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(n))));
        try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u16, ~@as(u16, @intCast(n)))));
        try out.appendSlice(a, rest[0..n]);
        rest = rest[n..];
        if (final) break;
    }
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, std.hash.Crc32.hash(plain))));
    try out.appendSlice(a, &std.mem.toBytes(std.mem.nativeToLittle(u32, @truncate(plain.len))));
    return out.items;
}

pub const Member = struct { name: []const u8, data: []const u8 };

/// An `ar` archive of `members` (each padded to an even length, as the format has it).
pub fn ar(a: Alloc, members: []const Member) Oom![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "!<arch>\n");
    for (members) |m| {
        var h = [_]u8{' '} ** 60;
        @memcpy(h[0..m.name.len], m.name);
        h[16] = '0';
        h[28] = '0';
        h[34] = '0';
        @memcpy(h[40..46], "100644");
        const size = std.fmt.bufPrint(h[48..58], "{d}", .{m.data.len}) catch unreachable;
        _ = size;
        @memcpy(h[58..60], "`\n");
        try out.appendSlice(a, &h);
        try out.appendSlice(a, m.data);
        if (m.data.len % 2 == 1) try out.append(a, '\n');
    }
    return out.items;
}

/// A Debian package whose data member is `data_name` (`data.tar.gz`, `data.tar`, or anything a test needs) holding `data`, already in that member's form.
pub fn package(a: Alloc, data_name: []const u8, data: []const u8) Oom![]const u8 {
    const control = try gzip(a, try tar(a, &.{.{ .name = "./control", .data = "Package: toy\nVersion: 1.0.0\nArchitecture: amd64\nMaintainer: none\nDescription: a toy\n" }}));
    return ar(a, &.{
        .{ .name = "debian-binary", .data = "2.0\n" },
        .{ .name = "control.tar.gz", .data = control },
        .{ .name = data_name, .data = data },
    });
}

/// A package whose `data.tar.gz` holds `files` under `./`, with the directories above them, as dpkg-deb writes it.
pub fn packageOf(a: Alloc, files: []const Entry) Oom![]const u8 {
    var entries: std.ArrayList(Entry) = .empty;
    try entries.append(a, .{ .name = "./", .typeflag = '5', .mode = 0o755 });
    for (files) |f| {
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, f.name, at, '/')) |slash| : (at = slash + 1) {
            const dir = try std.fmt.allocPrint(a, "./{s}/", .{f.name[0..slash]});
            var seen = false;
            for (entries.items) |e| seen = seen or std.mem.eql(u8, e.name, dir);
            if (!seen) try entries.append(a, .{ .name = dir, .typeflag = '5', .mode = 0o755 });
        }
        var e = f;
        e.name = try std.fmt.allocPrint(a, "./{s}", .{f.name});
        try entries.append(a, e);
    }
    return package(a, "data.tar.gz", try gzip(a, try tar(a, entries.items)));
}
