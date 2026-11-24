//! The pinned macOS `unpack` on a Mac, on the real darwin zig 0.12.0 tarball of rules/pins/hosts.bzl (tools/bootstrap/BUCK, `darwin_integration`; run on a farm's macOS
//! worker by .github/workflows/farm-macos.yml). The tree it makes is held to the one the system's tar makes of the same bytes (entries, executable bits, sizes,
//! content digests, link targets, and the permission bits of every file), the zig in it runs and says its version, and the program refuses the
//! tarball under another sha256 or size, and a copy of it cut off after its first 1,000,000 bytes.
//!
//! The environment (the BUCK target gives it): UNPACK, the program; ZIG_TARBALL, the tarball; ZIG_SHA256, ZIG_SIZE and ZIG_VERSION, its row of the pin table;
//! TMPDIR, a fresh directory of the run's own (`check marker --private-scratch`).
const std = @import("std");
const real = @import("real.zig");

/// The reference: the tar of the machine (bsdtar on macOS), as the system ships it.
const system_tar = "/usr/bin/tar";

/// How much of the tarball the cut copy keeps.
const kept: usize = 1_000_000;

fn text(name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(real.a, name) catch {
        std.debug.print("the environment variable {s} is not set (BUCK gives it)\n", .{name});
        return error.MissingEnvironment;
    };
}

/// A path in the run's own directory.
fn scratch(name: []const u8) ![]u8 {
    const tmp = try real.envPath("TMPDIR");
    defer real.a.free(tmp);
    return real.join(&.{ tmp, name });
}

/// The permission bits of every regular file below `dir`, as sorted lines `path mode`. unpack gives a file its mode from the archive whatever the umask, and the
/// system's tar does with `-p`; a directory's mode is the umask's for both, and a link's own mode is not a property either tool sets.
fn modes(dir: []const u8) ![]u8 {
    var root = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer root.close();
    var lines = std.ArrayList([]u8).empty;
    defer {
        for (lines.items) |l| real.a.free(l);
        lines.deinit(real.a);
    }
    var w = try root.walk(real.a);
    defer w.deinit();
    while (try w.next()) |e| {
        if (e.kind != .file) continue;
        const st = try root.statFile(e.path);
        try lines.append(real.a, try std.fmt.allocPrint(real.a, "{s} {o}", .{ e.path, st.mode & 0o7777 }));
    }
    std.mem.sort([]u8, lines.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var out = std.ArrayList(u8).empty;
    for (lines.items) |l| {
        try out.appendSlice(real.a, l);
        try out.append(real.a, '\n');
    }
    return out.toOwnedSlice(real.a);
}

test "the darwin zig tarball, checked against its sha256 and size, unpacks to the tree the system's tar makes, and its zig says its version" {
    const unpack = try real.envPath("UNPACK");
    defer real.a.free(unpack);
    const arch = try real.envPath("ZIG_TARBALL");
    defer real.a.free(arch);
    const sha = try text("ZIG_SHA256");
    defer real.a.free(sha);
    const size = try text("ZIG_SIZE");
    defer real.a.free(size);
    const version = try text("ZIG_VERSION");
    defer real.a.free(version);

    const mine = try scratch("zig-from-unpack");
    defer real.a.free(mine);
    try std.testing.expectEqual(@as(u8, 0), try real.run(&.{ unpack, "--strip-components", "1", "--sha256", sha, "--size", size, arch, mine }));

    const theirs = try scratch("zig-from-tar");
    defer real.a.free(theirs);
    try std.fs.cwd().makePath(theirs);
    try std.testing.expectEqual(@as(u8, 0), try real.run(&.{ system_tar, "-xpJf", arch, "-C", theirs, "--strip-components", "1" }));

    const want = try real.tree(theirs);
    defer real.a.free(want);
    const got = try real.tree(mine);
    defer real.a.free(got);
    try std.testing.expect(want.len > 0);
    try std.testing.expectEqualStrings(want, got);

    const want_modes = try modes(theirs);
    defer real.a.free(want_modes);
    const got_modes = try modes(mine);
    defer real.a.free(got_modes);
    try std.testing.expectEqualStrings(want_modes, got_modes);

    const zig = try real.join(&.{ mine, "zig" });
    defer real.a.free(zig);
    const r = try std.process.Child.run(.{ .allocator = real.a, .argv = &.{ zig, "version" } });
    defer real.a.free(r.stdout);
    defer real.a.free(r.stderr);
    const said = try std.fmt.allocPrint(real.a, "{s}\n", .{version});
    defer real.a.free(said);
    try std.testing.expectEqualStrings(said, r.stdout);
}

test "the tarball under another sha256 or another size is refused, and nothing is written" {
    const unpack = try real.envPath("UNPACK");
    defer real.a.free(unpack);
    const arch = try real.envPath("ZIG_TARBALL");
    defer real.a.free(arch);
    const sha = try text("ZIG_SHA256");
    defer real.a.free(sha);
    const size = try text("ZIG_SIZE");
    defer real.a.free(size);

    // The pin's digest with its first hex digit changed, and the pin's size less one byte.
    const other_sha = try real.a.dupe(u8, sha);
    defer real.a.free(other_sha);
    other_sha[0] = if (other_sha[0] == '0') '1' else '0';
    const other_size = try std.fmt.allocPrint(real.a, "{d}", .{(try std.fmt.parseInt(u64, size, 10)) - 1});
    defer real.a.free(other_size);

    for ([_][2][]const u8{ .{ other_sha, size }, .{ sha, other_size } }, [_][]const u8{ "other-sha256", "other-size" }) |pin, name| {
        const out = try scratch(name);
        defer real.a.free(out);
        try std.testing.expectEqual(@as(u8, 2), try real.run(&.{ unpack, "--strip-components", "1", "--sha256", pin[0], "--size", pin[1], arch, out }));
        try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(out, .{}));
    }
}

test "a copy of the tarball cut off after its first 1,000,000 bytes is refused by --check" {
    const unpack = try real.envPath("UNPACK");
    defer real.a.free(unpack);
    const arch = try real.envPath("ZIG_TARBALL");
    defer real.a.free(arch);
    const cut = try scratch("zig-cut.tar.xz");
    defer real.a.free(cut);

    const buf = try real.a.alloc(u8, kept);
    defer real.a.free(buf);
    const f = try std.fs.cwd().openFile(arch, .{});
    defer f.close();
    // the tarball is larger than the part kept, or the cut copy would be the whole file
    try std.testing.expectEqual(kept, try f.readAll(buf));
    try std.fs.cwd().writeFile(.{ .sub_path = cut, .data = buf });

    try std.testing.expectEqual(@as(u8, 0), try real.run(&.{ unpack, "--check", arch }));
    try std.testing.expectEqual(@as(u8, 2), try real.run(&.{ unpack, "--check", cut }));
}
