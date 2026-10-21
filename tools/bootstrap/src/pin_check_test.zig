//! The pins of `unpack` are the programs this tree builds (pins.zig): each of the three hosts' programs, built by the pinned zig from the source in this tree, is hashed and
//! compared with its row of rules/pins/bootstrap.bzl. The release assets are made from these same builds (tools/held/publish_unpack.zig), so a pin that passes here is a
//! pin of the bytes the source makes, and a source change without new rows is red. The build is reproducible: the farm and a runner give the same bytes.
const std = @import("std");
const pins = @import("pins.zig");
const t = std.testing;
const a = t.allocator;

fn builtFor(host: []const u8, env: []const u8) !pins.Built {
    const path = std.process.getEnvVarOwned(a, env) catch {
        std.debug.print("the environment variable {s} is not set (BUCK gives it with exec_tools)\n", .{env});
        return error.MissingEnvironment;
    };
    defer a.free(path);
    const bytes = try std.fs.cwd().readFileAlloc(a, path, 1 << 28);
    defer a.free(bytes);
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return .{ .host = host, .sha256 = std.fmt.bytesToHex(d, .lower), .size = bytes.len };
}

test "the pinned unpack programs are the ones this tree builds" {
    const work = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    defer a.free(work);
    const table_path = try std.fs.path.join(a, &.{ work, "rules/pins/bootstrap.bzl" });
    defer a.free(table_path);
    const table = try std.fs.cwd().readFileAlloc(a, table_path, 1 << 20);
    defer a.free(table);
    const built = [_]pins.Built{
        try builtFor("linux-x86_64", "UNPACK_LINUX_X86_64"),
        try builtFor("linux-aarch64", "UNPACK_LINUX_AARCH64"),
        try builtFor("macos-aarch64", "UNPACK_MACOS_AARCH64"),
    };
    var f = try pins.check(a, table, &built);
    defer {
        for (f.items) |x| a.free(x);
        f.deinit(a);
    }
    for (f.items) |x| std.debug.print("{s}\n", .{x});
    try t.expectEqual(@as(usize, 0), f.items.len);
}
