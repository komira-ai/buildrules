//! `buildrules mojo sync` and `check` for a path dependency whose library is not at `<dir>/src/<name>`: a package whose mopm.toml says
//! `[targets] lib = { path = "generated/<name>" }`, the layout of a library whose sources are committed generator output. The member's directory is
//! the nearest one above its library that holds a mopm.toml, and that manifest is a manifest of the importing package's table. Every test is named for
//! the defect it catches.

const std = @import("std");
const kit = @import("testkit.zig");
const base = @import("mojo_cmd_test.zig");
const t = std.testing;

/// The repository of `fresh` with a second package `util`, whose library is `pkgs/util/generated/util` (its manifest is `pkgs/util/mopm.toml`), that
/// `base` imports. The paths are as an older mopm prints them: from the package.
fn withGeneratedMember(h: *kit.Harness) !void {
    try h.put("pkgs/util/mopm.toml", "[package]\nname = \"util\"\nversion = \"0.1.0\"\n\n[targets]\nlib = { path = \"generated/util\" }\n");
    try h.put("pkgs/util/generated/util/__init__.mojo", base.util_src);
    base.plan_graph = try base.memberGraph(h, base.util_src, "k0", "../util/generated/util", "../util/generated/util/__init__.mojo", "");
}

test "sync: a path dependency whose library is below its directory but not at src/<name> has its manifest in the table" {
    const h = try base.fresh();
    defer h.destroy();
    try withGeneratedMember(h);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    const lock = h.read(base.lock_path);
    const sha = try base.sha256Hex(h, try h.a().dupe(u8, h.read("pkgs/util/mopm.toml")));
    try t.expect(kit.contains(lock, try std.fmt.allocPrint(h.a(), "    \"../util/mopm.toml\": \"{s}\",\n", .{sha})));
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check" }).code);
}

test "check: the manifest of a member whose library is not at src/<name> is followed, so a changed version of it is stale" {
    const h = try base.fresh();
    defer h.destroy();
    try withGeneratedMember(h);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    try h.put("pkgs/util/mopm.toml", "[package]\nname = \"util\"\nversion = \"0.1.1\"\n\n[targets]\nlib = { path = \"generated/util\" }\n");
    const c = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), c.code);
    try t.expect(kit.contains(c.err, "pkgs/util/mopm.toml changed since"));
}

test "check: a table that lacks the manifest of a member whose library is not at src/<name> is stale, naming it" {
    const h = try base.fresh();
    defer h.destroy();
    try withGeneratedMember(h);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    const lock = h.read(base.lock_path);
    const prefix = "    \"../util/mopm.toml\": \"";
    const at = std.mem.indexOf(u8, lock, prefix).?;
    const end = std.mem.indexOfScalarPos(u8, lock, at, '\n').? + 1;
    try h.put(base.lock_path, try std.mem.concat(h.a(), u8, &.{ lock[0..at], lock[end..] }));
    const r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "../util/mopm.toml is a path dependency's manifest the table does not know"));
}

test "sync: a library below no directory with a mopm.toml is no member, and the library of the importing package itself is not one either" {
    const h = try base.fresh();
    defer h.destroy();
    // `loose` has sources and no manifest anywhere above them below the repository root, `base`'s own tree holds the other root.
    try h.put("pkgs/util/mopm.toml", "[package]\nname = \"util\"\nversion = \"0.1.0\"\n");
    try h.put("loose/generated/util/__init__.mojo", base.util_src);
    base.plan_graph = try base.memberGraph(h, base.util_src, "k0", "../../loose/generated/util", "../../loose/generated/util/__init__.mojo", "");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    const lock = h.read(base.lock_path);
    try t.expect(!kit.contains(lock, "\"../util/mopm.toml\""));
    try t.expect(!kit.contains(lock, "loose/mopm.toml"));
    // a library inside the importing package's own directory is its own, not a dependency
    base.plan_graph = try base.memberGraph(h, base.util_src, "k0", "gen/util", "gen/util/__init__.mojo", "");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    try t.expect(!kit.contains(h.read(base.lock_path), "\"../mopm.toml\""));
}
