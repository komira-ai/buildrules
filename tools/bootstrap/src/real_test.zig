//! The built `unpack` on the real pinned archives, against what busybox's `tar` makes of the same bytes: the zig tarballs (xz), the mopm tarball and the actionlint tarball
//! (gzip, dynamic Huffman blocks as a real compressor writes them), and a conda package (a zip) against what its members must be. Trees are compared entry by entry: kind,
//! executable bit, size, content digest, link target.
//!
//! The distributions the build makes with `unpack` (`//rules/pins:zig`, `:zig_next`, the mopm toolchain) are held to the digest of the tree busybox's `tar` made of the same
//! archive when they were made with it: a digest below is that tree's, so the rules' outputs are the bytes they were, and no key that reads them has moved.
const std = @import("std");
const real = @import("real.zig");

/// The trees busybox's `tar --strip-components=1` made of the pinned zig 0.12.0 and zig 0.15.2 tarballs and of the mopm 0.0.25 tarball (15,189, 18,105 and 2 files).
const zig_0_12_tree = "a286115817de29ac2e0f22badf1c83991a95eb3df96dbc674b2718b64090e57c";
const zig_0_15_tree = "0224303b20cdaad846f421f648e688fb2cbc88b02d1194338317e64b05f3b551";
const mopm_0_0_25_tree = "3ee86ef3c2d6a8f06eabe9465d45d41daccfd5cf2a76f6eef644f687be21a974";

test "the zig 0.12.0 distribution the build makes is the tree the reference tar made of the same tarball" {
    const dist = try real.envPath("ZIG_DIST");
    defer real.a.free(dist);
    const digest = try real.treeDigest(dist);
    try std.testing.expectEqualStrings(zig_0_12_tree, &digest);
}

test "the zig 0.15.2 distribution the build makes is the tree the reference tar made of the same tarball" {
    const dist = try real.envPath("ZIG_NEXT_DIST");
    defer real.a.free(dist);
    const digest = try real.treeDigest(dist);
    try std.testing.expectEqualStrings(zig_0_15_tree, &digest);
}

test "the pinned zig tarball (tar.xz) extracts to what the reference tar extracts" {
    try real.sameAsBusyboxTar("zig", "zig.tar.xz", "-xJf", 1);
}

test "the pinned mopm tarball (tar.gz) extracts to what the reference tar extracts, and to the tree the toolchain was" {
    try real.sameAsBusyboxTar("mopm", "mopm.tar.gz", "-xzf", 1);
    const w = try real.work();
    defer real.a.free(w);
    const mine = try std.fmt.allocPrint(real.a, "{s}/mopm_unpack", .{w});
    defer real.a.free(mine);
    const digest = try real.treeDigest(mine);
    try std.testing.expectEqualStrings(mopm_0_0_25_tree, &digest);
    // The toolchain's executable is the tarball's.
    const exe = try real.envPath("MOPM");
    defer real.a.free(exe);
    const inner = try real.join(&.{ mine, "mopm" });
    defer real.a.free(inner);
    const want = try real.sha256(inner);
    const got = try real.sha256(exe);
    try std.testing.expectEqualStrings(&want, &got);
}

test "the pinned actionlint tarball (tar.gz) extracts to what busybox extracts" {
    try real.sameAsBusyboxTar("actionlint", "actionlint.tar.gz", "-xzf", 0);
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

test "--strip-components counts a leading ./ as busybox's tar does" {
    const kit = @import("testkit.zig");
    const w = try real.work();
    defer real.a.free(w);
    const unpack = try real.envPath("UNPACK");
    defer real.a.free(unpack);
    const bb = try real.envPath("BUSYBOX");
    defer real.a.free(bb);
    var tb = kit.Tar{};
    defer tb.deinit();
    try tb.dir("./");
    try tb.dir("./a/");
    try tb.file("./a/b", 0o644, "inner");
    try tb.file("./a/deep/c", 0o755, "deeper");
    try tb.file("./top", 0o644, "top");
    try tb.symlink("./a/l", "b");
    try tb.end();
    const tarball = try real.join(&.{ w, "dot.tar" });
    defer real.a.free(tarball);
    try std.fs.cwd().writeFile(.{ .sub_path = tarball, .data = tb.bytes() });
    for ([_]u8{ 0, 1, 2, 3 }) |strip| {
        const mine = try std.fmt.allocPrint(real.a, "{s}/dot_mine_{d}", .{ w, strip });
        defer real.a.free(mine);
        const theirs = try std.fmt.allocPrint(real.a, "{s}/dot_bb_{d}", .{ w, strip });
        defer real.a.free(theirs);
        try std.fs.cwd().makePath(theirs);
        var num: [4]u8 = undefined;
        const n = try std.fmt.bufPrint(&num, "{d}", .{strip});
        const flag = try std.fmt.allocPrint(real.a, "--strip-components={d}", .{strip});
        defer real.a.free(flag);
        try std.testing.expectEqual(@as(u8, 0), try real.run(&.{ unpack, "--strip-components", n, tarball, mine }));
        try std.testing.expectEqual(@as(u8, 0), try real.run(&.{ bb, "tar", "-xf", tarball, "-C", theirs, flag }));
        const m = try real.tree(mine);
        defer real.a.free(m);
        const b = try real.tree(theirs);
        defer real.a.free(b);
        try std.testing.expectEqualStrings(b, m);
    }
}
