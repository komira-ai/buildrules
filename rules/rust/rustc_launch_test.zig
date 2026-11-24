//! The refusal of a static link for a glibc target (rustc_launch.zig, `staticGlibcRefusal`), and through `_ = launch` the tests of the launcher
//! itself. Its run through the pinned rustc on the farm is crt_static_test.zig.

const std = @import("std");
const launch = @import("rustc_launch.zig");

test {
    _ = launch;
}

test "a static link for a glibc target is refused, naming the flag and the target; any other link, a compile and a musl target are not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const tail = " is refused: zig cc cannot link glibc statically, and the link would succeed with a dynamically linked program. Build without +crt-static.";
    try std.testing.expectEqualStrings(
        "a static link (-static-pie, which rustc passes for -C target-feature=+crt-static) for the glibc target x86_64-linux-gnu.2.34" ++ tail,
        (try launch.staticGlibcRefusal(x, "x86_64-linux-gnu.2.34", &.{ "-m64", "a.o", "-static-pie", "-o", "out" })).?,
    );
    try std.testing.expectEqualStrings(
        "a static link (-static, which rustc passes for -C target-feature=+crt-static) for the glibc target aarch64-linux-gnu" ++ tail,
        (try launch.staticGlibcRefusal(x, "aarch64-linux-gnu", &.{ "-static", "-no-pie", "a.o" })).?,
    );
    // A dynamic link, and flags that only start like the static ones (`-static-libgcc` links libgcc into a dynamic program).
    try std.testing.expectEqual(@as(?[]const u8, null), try launch.staticGlibcRefusal(x, "x86_64-linux-gnu.2.34", &.{ "-pie", "a.o", "-o", "out" }));
    try std.testing.expectEqual(@as(?[]const u8, null), try launch.staticGlibcRefusal(x, "x86_64-linux-gnu.2.34", &.{ "-static-libgcc", "-Wl,-Bstatic", "a.o" }));
    try std.testing.expectEqual(@as(?[]const u8, null), try launch.staticGlibcRefusal(x, "x86_64-linux-gnu.2.34", &.{}));
    // musl links statically.
    try std.testing.expectEqual(@as(?[]const u8, null), try launch.staticGlibcRefusal(x, "x86_64-linux-musl", &.{ "-static-pie", "a.o" }));
    // A compile is not a link; the shim asks isCompile first.
    try std.testing.expect(launch.isCompile(&.{ "-static", "-c", "a.c" }));
    try std.testing.expect(launch.isCompile(&.{"-S"}));
    try std.testing.expect(launch.isCompile(&.{"-E"}));
    try std.testing.expect(!launch.isCompile(&.{ "-static-pie", "a.o" }));
    // The refusal that cannot be written is an error, not a link let through.
    var buf: [0]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    try std.testing.expectError(error.OutOfMemory, launch.staticGlibcRefusal(fba.allocator(), "x86_64-linux-gnu.2.34", &.{"-static"}));
}

test "the arguments of a response file are read after it, so a static link rustc put in one is refused too" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "linker-arguments", .data = "-m64\na.o\n-static-pie\n-o\nout" });
    const got = try launch.withResponseFiles(x, tmp.dir, &.{ "-v", "@linker-arguments", "@missing", "@", "b.o" });
    const want = [_][]const u8{ "-v", "@linker-arguments", "-m64", "a.o", "-static-pie", "-o", "out", "@missing", "@", "b.o" };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
    try std.testing.expect((try launch.staticGlibcRefusal(x, "x86_64-linux-gnu.2.34", got)) != null);
    // A response file that cannot be held is an error, not a link let through.
    var buf: [0]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    try std.testing.expectError(error.OutOfMemory, launch.withResponseFiles(fba.allocator(), tmp.dir, &.{"@linker-arguments"}));
}
