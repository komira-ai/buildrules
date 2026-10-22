//! How fast `unpack` reads the real zig tarball (xz) against busybox, which unpacked it before zig_dist moved onto `unpack` (only zig_dist uses xz). Decoding alone (busybox's
//! `xzcat` and `unpack --check`, output thrown away) and extracting (`unpack`) are each the fastest of a few runs; the budget is that unpack takes
//! less than three times busybox's time, or the xz path is swapped for a faster one.
const std = @import("std");
const real = @import("real.zig");

/// The budget, in hundredths: 300 is "three times".
const budget_x100: u64 = 300;

test "unpack reads the real xz tarball in under three times busybox's time" {
    const w = try real.work();
    defer real.a.free(w);
    const unpack = try real.envPath("UNPACK");
    defer real.a.free(unpack);
    const bb = try real.envPath("BUSYBOX");
    defer real.a.free(bb);
    const arch = try real.join(&.{ w, "zig.tar.xz" });
    defer real.a.free(arch);

    const bb_decode = try real.timeIt(&.{ bb, "xzcat", arch }, 2);
    const my_decode = try real.timeIt(&.{ unpack, "--check", arch }, 3);

    const my_out = try std.fmt.allocPrint(real.a, "{s}/speed_unpack", .{w});
    defer real.a.free(my_out);
    const my_extract = try real.timeIt(&.{ unpack, arch, my_out }, 2);

    std.debug.print("xz decode:  busybox xzcat {d:.2} s, unpack --check {d:.2} s, ratio {d:.2}\n", .{ bb_decode, my_decode, my_decode / bb_decode });
    std.debug.print("xz extract: unpack {d:.2} s (busybox's own extraction is not timed)\n", .{my_extract});
    const limit = @as(f64, @floatFromInt(budget_x100)) / 100.0;
    try std.testing.expect(my_decode < limit * bb_decode);
}
