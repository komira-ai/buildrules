//! sync_stage.zig: the staging (what is copied, what is written for cargo) and the flags. The run of `buildrules sync` is the farm's.
const std = @import("std");
const S = @import("sync_stage.zig");
const t = std.testing;

test "flags: every tool is required, --registry and --check are optional, anything else is refused" {
    const ok = try S.parseArgs(&.{ "--src", "s", "--out", "o", "--buildrules", "b", "--cargo", "c", "--sysroot", "r", "--pins", "p", "--check", "--registry", "g" });
    try t.expect(ok.check);
    try t.expectEqualStrings("g", ok.registry.?);
    try t.expectError(error.MissingFlag, S.parseArgs(&.{ "--src", "s", "--out", "o" }));
    try t.expectError(error.UnknownFlag, S.parseArgs(&.{ "--nope", "x" }));
    try t.expectError(error.MissingValue, S.parseArgs(&.{"--src"}));
}

test "stage: the workspace is copied, a .buckconfig is added once, and a local registry is wired in for cargo and for the sizes" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src/crates/app/src");
    try tmp.dir.writeFile(.{ .sub_path = "src/Cargo.toml", .data = "[workspace]\n" });
    try tmp.dir.writeFile(.{ .sub_path = "src/crates/app/src/lib.rs", .data = "// lib\n" });
    try tmp.dir.makePath("reg/index/zs/td");
    try tmp.dir.writeFile(.{ .sub_path = "reg/index/zs/td/zstd-sys", .data = "{}\n" });
    try tmp.dir.writeFile(.{ .sub_path = "reg/zstd-sys-2.0.9+zstd.1.5.5.crate", .data = "bytes" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    const args = S.Args{
        .src = try std.fmt.allocPrint(a, "{s}/src", .{root}),
        .out = try std.fmt.allocPrint(a, "{s}/out", .{root}),
        .registry = try std.fmt.allocPrint(a, "{s}/reg", .{root}),
        .buildrules = "b",
        .cargo = "c",
        .sysroot = "r",
        .pins = "p",
    };
    try S.stage(a, args);
    try t.expectEqualStrings("[workspace]\n", try tmp.dir.readFileAlloc(a, "out/Cargo.toml", 1 << 10));
    try t.expectEqualStrings("// lib\n", try tmp.dir.readFileAlloc(a, "out/crates/app/src/lib.rs", 1 << 10));
    try t.expectEqualStrings("[cells]\n", try tmp.dir.readFileAlloc(a, "out/.buckconfig", 1 << 10));
    try t.expectEqualStrings(S.config_toml, try tmp.dir.readFileAlloc(a, "out/.cargo/config.toml", 1 << 10));
    try t.expectEqualStrings("{}\n", try tmp.dir.readFileAlloc(a, "out/registry/index/zs/td/zstd-sys", 1 << 10));
    // the crates are where sync looks for sizes, so it downloads nothing; the index lines are not crates
    try t.expectEqualStrings("bytes", try tmp.dir.readFileAlloc(a, "out/" ++ S.cache_dir ++ "/zstd-sys-2.0.9+zstd.1.5.5.crate", 1 << 10));
    try t.expectError(error.FileNotFound, tmp.dir.access("out/" ++ S.cache_dir ++ "/zstd-sys", .{}));
}

test "stage: a .buckconfig the workspace has is kept, and without a registry cargo is not redirected" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "src/.buckconfig", .data = "[cells]\n  mine = .\n" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    try S.stage(a, .{ .src = try std.fmt.allocPrint(a, "{s}/src", .{root}), .out = try std.fmt.allocPrint(a, "{s}/out", .{root}), .buildrules = "b", .cargo = "c", .sysroot = "r", .pins = "p" });
    try t.expectEqualStrings("[cells]\n  mine = .\n", try tmp.dir.readFileAlloc(a, "out/.buckconfig", 1 << 10));
    try t.expectError(error.FileNotFound, tmp.dir.access("out/.cargo/config.toml", .{}));
}
