//! The built `unpack` on the real pinned archives, against what the rest of the build makes of the same bytes: the zig tarball (xz) against the zig distribution the build
//! unpacks today (`//rules/pins:zig`, made by busybox), the actionlint tarball (gzip, dynamic Huffman blocks as a real compressor writes them) against busybox's own
//! `tar -xzf`, and a conda package (a zip) against what its members must be. Trees are compared entry by entry: kind, executable bit, size, content digest, link target.
const std = @import("std");
const real = @import("real.zig");

test "the pinned zig tarball (tar.xz) extracts to the zig distribution the build has today" {
    const dist = try real.envPath("ZIG_DIST");
    defer real.a.free(dist);
    try real.sameAsDirectory("zig", "zig.tar.xz", 1, dist);
}

test "the pinned actionlint tarball (tar.gz) extracts to what busybox extracts" {
    try real.sameAsBusyboxTar("actionlint", "actionlint.tar.gz", "-xzf");
}

test "a pinned conda package (a zip) extracts to its members, whole" {
    const w = try real.work();
    defer real.a.free(w);
    const unpack = try real.envPath("UNPACK");
    defer real.a.free(unpack);
    const arch = try real.join(&.{ w, "libgcc.conda" });
    defer real.a.free(arch);
    const out = try std.fmt.allocPrint(real.a, "{s}/conda_unpack", .{w});
    defer real.a.free(out);
    try std.testing.expectEqual(@as(u8, 0), try real.run(&.{ unpack, arch, out }));
    var dir = try std.fs.cwd().openDir(out, .{ .iterate = true });
    defer dir.close();
    var pkg = false;
    var info = false;
    var meta = false;
    var it = dir.iterate();
    while (try it.next()) |e| {
        const bytes = try dir.readFileAlloc(real.a, e.name, 1 << 28);
        defer real.a.free(bytes);
        if (std.mem.startsWith(u8, e.name, "pkg-") and std.mem.endsWith(u8, e.name, ".tar.zst")) {
            pkg = true;
            try std.testing.expectEqualSlices(u8, "\x28\xb5\x2f\xfd", bytes[0..4]); // a zstd frame
        } else if (std.mem.startsWith(u8, e.name, "info-") and std.mem.endsWith(u8, e.name, ".tar.zst")) {
            info = true;
            try std.testing.expectEqualSlices(u8, "\x28\xb5\x2f\xfd", bytes[0..4]);
        } else if (std.mem.eql(u8, e.name, "metadata.json")) {
            meta = true;
            try std.testing.expect(bytes.len > 2 and bytes[0] == '{');
        }
    }
    try std.testing.expect(pkg and info and meta);
}

test "the extracted zig is executable and is the pinned version" {
    const w = try real.work();
    defer real.a.free(w);
    const unpack = try real.envPath("UNPACK");
    defer real.a.free(unpack);
    const out = try std.fmt.allocPrint(real.a, "{s}/zig_run", .{w});
    defer real.a.free(out);
    const arch = try real.join(&.{ w, "zig.tar.xz" });
    defer real.a.free(arch);
    try std.testing.expectEqual(@as(u8, 0), try real.run(&.{ unpack, "--strip-components", "1", arch, out }));
    const zig = try real.join(&.{ out, "zig" });
    defer real.a.free(zig);
    const r = try std.process.Child.run(.{ .allocator = real.a, .argv = &.{ zig, "version" } });
    defer real.a.free(r.stdout);
    defer real.a.free(r.stderr);
    try std.testing.expectEqualStrings("0.12.0\n", r.stdout);
}

test "--check reads the real archives to the end and writes nothing" {
    const w = try real.work();
    defer real.a.free(w);
    const unpack = try real.envPath("UNPACK");
    defer real.a.free(unpack);
    for ([_][]const u8{ "zig.tar.xz", "actionlint.tar.gz", "libgcc.conda" }) |name| {
        const arch = try real.join(&.{ w, name });
        defer real.a.free(arch);
        try std.testing.expectEqual(@as(u8, 0), try real.run(&.{ unpack, "--check", arch }));
    }
}

test "a real archive cut short is refused by --check (xz, gzip), and a flipped byte is too" {
    const w = try real.work();
    defer real.a.free(w);
    const unpack = try real.envPath("UNPACK");
    defer real.a.free(unpack);
    for ([_][]const u8{ "zig.tar.xz", "actionlint.tar.gz" }) |name| {
        const arch = try real.join(&.{ w, name });
        defer real.a.free(arch);
        const bytes = try std.fs.cwd().readFileAlloc(real.a, arch, 1 << 30);
        defer real.a.free(bytes);
        const cut = try std.fmt.allocPrint(real.a, "{s}/cut_{s}", .{ w, name });
        defer real.a.free(cut);
        try std.fs.cwd().writeFile(.{ .sub_path = cut, .data = bytes[0 .. bytes.len - 20] });
        try std.testing.expectEqual(@as(u8, 2), try real.run(&.{ unpack, "--check", cut }));
        bytes[bytes.len / 2] ^= 0x10;
        const flipped = try std.fmt.allocPrint(real.a, "{s}/flipped_{s}", .{ w, name });
        defer real.a.free(flipped);
        try std.fs.cwd().writeFile(.{ .sub_path = flipped, .data = bytes });
        try std.testing.expectEqual(@as(u8, 2), try real.run(&.{ unpack, "--check", flipped }));
    }
}
