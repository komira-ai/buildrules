//! The xz path of `unpack` on the real zig tarball, by what it decides and not by how long it takes (a test never asserts elapsed time). `--check` decodes the whole
//! archive and writes nothing, so it must accept the real tarball, and it must refuse a copy cut off after its first megabyte. A decoder that stops early (and so
//! looks fast) accepts the cut copy; one that skips blocks rejects the real file. Whether the extraction is the right one is `real_test.zig`'s question.
const std = @import("std");
const real = @import("real.zig");

/// How much of the real archive the cut copy keeps.
const kept: usize = 1 << 20;

test "unpack --check accepts the whole real xz tarball" {
    const w = try real.work();
    defer real.a.free(w);
    const unpack = try real.envPath("UNPACK");
    defer real.a.free(unpack);
    const arch = try real.join(&.{ w, "zig.tar.xz" });
    defer real.a.free(arch);

    try std.testing.expectEqual(@as(u8, 0), try real.run(&.{ unpack, "--check", arch }));
}

test "unpack --check refuses the real xz tarball cut off after its first megabyte" {
    const w = try real.work();
    defer real.a.free(w);
    const unpack = try real.envPath("UNPACK");
    defer real.a.free(unpack);
    const arch = try real.join(&.{ w, "zig.tar.xz" });
    defer real.a.free(arch);
    const cut = try real.join(&.{ w, "zig_cut.tar.xz" });
    defer real.a.free(cut);

    var buf = try real.a.alloc(u8, kept);
    defer real.a.free(buf);
    const f = try std.fs.cwd().openFile(arch, .{});
    defer f.close();
    const n = try f.readAll(buf);
    try std.testing.expectEqual(kept, n); // the real archive is larger than the part kept, or the cut would be the whole file
    try std.fs.cwd().writeFile(.{ .sub_path = cut, .data = buf[0..n] });

    try std.testing.expect(try real.run(&.{ unpack, "--check", cut }) != 0);
}
