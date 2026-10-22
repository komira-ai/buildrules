//! How much memory `unpack` needs for a real archive: the peak resident set of the child that reads the archive named `archive` in the test's data (`--check`: every
//! decoder and rule, nothing written). The program reads the archive into memory, the gzip decoder keeps a 64 KiB window, and the standard library's xz decoder decodes a whole
//! xz block before it returns any of it, so an archive that is a single block costs its decompressed size as well. The limit below is what README.md states.
const std = @import("std");
const real = @import("real.zig");

/// The peak, in MiB, this archive is allowed: README.md states the figures measured with this test (about three times the decompressed size for a single-block xz).

const limit_mib: u64 = 2048;

test "the peak memory of reading the real archive" {
    const w = try real.work();
    defer real.a.free(w);
    const unpack = try real.envPath("UNPACK");
    defer real.a.free(unpack);
    const arch = try real.join(&.{ w, "archive" });
    defer real.a.free(arch);
    const size = (try std.fs.cwd().statFile(arch)).size;
    try std.testing.expectEqual(@as(u8, 0), try real.run(&.{ unpack, "--check", arch }));
    const ru = std.posix.getrusage(std.posix.rusage.CHILDREN);
    const peak_mib: u64 = @intCast(@divTrunc(ru.maxrss, 1024)); // Linux reports kilobytes
    std.debug.print("peak memory: {d} MiB for an archive of {d} MiB\n", .{ peak_mib, size >> 20 });
    try std.testing.expect(peak_mib < limit_mib);
}
