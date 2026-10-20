//! `buildrules cargo new|init`. Every test is named for the defect it catches.

const std = @import("std");
const kit = @import("testkit.zig");
const cargo_cmd = @import("cargo_cmd.zig");
const ctxm = @import("ctx.zig");
const t = std.testing;

// ---- a fake cargo: the runner seam records the command line and writes what cargo writes ----

var seen: [8][]const u8 = undefined;
var seen_len: usize = 0;
var fake_code: u8 = 0;

fn fakeCargo(ctx: *ctxm.Ctx, argv: []const []const u8) anyerror!u8 {
    seen_len = 0;
    for (argv) |x| {
        seen[seen_len] = try ctx.a.dupe(u8, x);
        seen_len += 1;
    }
    if (fake_code != 0) return fake_code;
    const path = argv[argv.len - 1];
    const name = std.fs.path.basename(path);
    const manifest = try std.fmt.allocPrint(ctx.a, "{s}/Cargo.toml", .{path});
    try ctx.write(manifest, try std.fmt.allocPrint(ctx.a, "[package]\nname = \"{s}\"\nversion = \"0.1.0\"\nedition = \"2024\"\n\n[dependencies]\n", .{name}));
    return 0;
}

fn withFake(h: *kit.Harness) void {
    h.ctx.runner = &fakeCargo;
    seen_len = 0;
    fake_code = 0;
}

// ---- the pure edits ---------------------------------------------------------------------

test "ensureBuck: a new BUCK gets the load and the call, once" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const got = (try cargo_cmd.ensureBuck(a, "")).?;
    try t.expectEqualStrings("load(\"//:buildrules.bzl\", \"cargo_package\")\n\ncargo_package(path = \".\")\n", got);
    try t.expect((try cargo_cmd.ensureBuck(a, got)) == null);
}

test "ensureBuck: existing rules are kept and the call is appended after them" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const got = (try cargo_cmd.ensureBuck(a, "load(\"@x//y.bzl\", \"z\")\nz()")).?;
    try t.expectEqualStrings("load(\"//:buildrules.bzl\", \"cargo_package\")\n\nload(\"@x//y.bzl\", \"z\")\nz()\n\ncargo_package(path = \".\")\n", got);
}

test "ensureMetadata: added once at the end, and a manifest without [package] is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "[package]\nname = \"x\"\n\n[dependencies]\nserde = \"1\"\n";
    const got = (try cargo_cmd.ensureMetadata(a, src)).?;
    try t.expect(std.mem.startsWith(u8, got, src));
    try t.expect(kit.contains(got, "\n[package.metadata.buildrules]\n"));
    try t.expect((try cargo_cmd.ensureMetadata(a, got)) == null);
    try t.expectError(error.NoPackageTable, cargo_cmd.ensureMetadata(a, "[workspace]\nmembers = []\n"));
}

fn member(a: std.mem.Allocator, text: []const u8, rel: []const u8) !cargo_cmd.Member {
    return cargo_cmd.ensureMember(a, text, rel);
}

fn tag(a: std.mem.Allocator, text: []const u8, rel: []const u8) !std.meta.Tag(cargo_cmd.Member) {
    return std.meta.activeTag(try member(a, text, rel));
}

test "ensureMember: inline, multi-line, empty and absent members arrays" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("[workspace]\nmembers = [\"a\", \"crates/hello\"]\n", (try member(a, "[workspace]\nmembers = [\"a\"]\n", "crates/hello")).edited);
    try t.expectEqualStrings("[workspace]\nmembers = [\"crates/hello\"]\n", (try member(a, "[workspace]\nmembers = []\n", "crates/hello")).edited);
    try t.expectEqualStrings("[workspace]\nmembers = [\n    \"a\",\n    \"b\",\n]\n", (try member(a, "[workspace]\nmembers = [\n    \"a\",\n]\n", "b")).edited);
    // No trailing comma on the last element.
    try t.expectEqualStrings("[workspace]\nmembers = [\n    \"a\",\n    \"b\",\n]\n", (try member(a, "[workspace]\nmembers = [\n    \"a\"\n]\n", "b")).edited);
    try t.expectEqualStrings("[workspace]\nmembers = [\"b\"]\nresolver = \"2\"\n", (try member(a, "[workspace]\nresolver = \"2\"\n", "b")).edited);
}

test "ensureMember: a member already listed, or covered by a glob, is not added twice" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expect((try tag(a, "[workspace]\nmembers = [\"crates/hello\"]\n", "crates/hello")) == .present);
    try t.expect((try tag(a, "[workspace]\nmembers = [\"crates/*\"]\n", "crates/hello")) == .present);
    // A glob over another directory does not cover it.
    try t.expect((try tag(a, "[workspace]\nmembers = [\"libs/*\"]\n", "crates/hello")) == .edited);
    // `members` of another table is not the workspace's.
    try t.expect((try tag(a, "[package]\nname = \"x\"\n[workspace.metadata]\nmembers = []\n", "b")) == .not_workspace);
}

// ---- the command ------------------------------------------------------------------------

const root_ws = "[workspace]\nmembers = []\n";

fn withRoot(h: *kit.Harness) !void {
    try h.put("Cargo.toml", root_ws);
}

test "new without --cargo says it skipped cargo and writes a buildable package" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try withRoot(h);
    const r = h.run(&.{ "cargo", "new", "crates/hello" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, "cargo   skipped: --cargo"));
    try t.expect(kit.contains(h.read("crates/hello/Cargo.toml"), "name = \"hello\""));
    try t.expect(kit.contains(h.read("crates/hello/Cargo.toml"), "[package.metadata.buildrules]"));
    try t.expect(h.has("crates/hello/src/main.rs"));
    try t.expectEqualStrings("load(\"//:buildrules.bzl\", \"cargo_package\")\n\ncargo_package(path = \".\")\n", h.read("crates/hello/BUCK"));
    try t.expectEqualStrings("[workspace]\nmembers = [\"crates/hello\"]\n", h.read("Cargo.toml"));
}

test "new --lib writes a library with a test" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try withRoot(h);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "cargo", "new", "lib1", "--lib" }).code);
    try t.expect(kit.contains(h.read("lib1/src/lib.rs"), "#[test]"));
    try t.expect(!h.has("lib1/src/main.rs"));
}

test "new adds the member; a second package is added next to the first" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try h.put("Cargo.toml", "[workspace]\nresolver = \"2\"\n");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "cargo", "new", "crates/a" }).code);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "cargo", "new", "./crates/b/" }).code);
    try t.expectEqualStrings("[workspace]\nmembers = [\"crates/a\", \"crates/b\"]\nresolver = \"2\"\n", h.read("Cargo.toml"));
}

test "no root Cargo.toml, a root that is not a workspace, or a root that is a package: refused before anything is written" {
    const h = try kit.Harness.create();
    defer h.destroy();
    var r = h.run(&.{ "cargo", "new", "crates/a" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "buildrules init"));
    try t.expect(!h.has("crates"));
    try h.put("Cargo.toml", "[package]\nname = \"x\"\n");
    r = h.run(&.{ "cargo", "new", "crates/a" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "no [workspace]"));
    try h.put("Cargo.toml", "[package]\nname = \"x\"\n[workspace]\nmembers = []\n");
    r = h.run(&.{ "cargo", "new", "crates/a" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "virtual workspace"));
    try t.expect(!h.has("crates"));
    try t.expect(!h.has("BUCK"));
}

test "new with --cargo runs exactly cargo new --vcs none PATH, then does the rest" {
    const h = try kit.Harness.create();
    defer h.destroy();
    withFake(h);
    try withRoot(h);
    try h.put("pinned/cargo", "");
    const r = h.run(&.{ "cargo", "new", "x/pkg", "--cargo", "pinned/cargo", "--lib" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqual(@as(usize, 6), seen_len);
    try t.expect(std.mem.endsWith(u8, seen[0], "/pinned/cargo"));
    try t.expectEqualStrings("new", seen[1]);
    try t.expectEqualStrings("--vcs", seen[2]);
    try t.expectEqualStrings("none", seen[3]);
    try t.expectEqualStrings("--lib", seen[4]);
    try t.expectEqualStrings("x/pkg", seen[5]);
    try t.expect(kit.contains(h.read("x/pkg/Cargo.toml"), "[package.metadata.buildrules]"));
    try t.expect(h.has("x/pkg/BUCK"));
}

test "a cargo that fails leaves no BUCK file and exits 1" {
    const h = try kit.Harness.create();
    defer h.destroy();
    withFake(h);
    try withRoot(h);
    fake_code = 101;
    try h.put("cargo", "");
    const r = h.run(&.{ "cargo", "new", "p", "--cargo", "cargo" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "exited 101"));
    try t.expect(!h.has("p/BUCK"));
}

test "a --cargo that does not exist is an error, not a silent skip" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try withRoot(h);
    const r = h.run(&.{ "cargo", "new", "p", "--cargo", "no/such/cargo" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(!h.has("p"));
}

test "new refuses a destination that exists, and paths that leave the directory" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try withRoot(h);
    try h.put("p/Cargo.toml", "[package]\nname = \"p\"\n");
    try t.expectEqual(@as(u8, 1), h.run(&.{ "cargo", "new", "p" }).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "cargo", "new", "../out" }).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "cargo", "new", "/abs/p" }).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "cargo", "new" }).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "cargo", "frob", "p" }).code);
}

test "init on an existing package leaves its sources alone and adds the table, BUCK and member" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try h.put("Cargo.toml", "[workspace]\nmembers = [\"old\"]\n");
    try h.put("pk/Cargo.toml", "[package]\nname = \"pk\"\nversion = \"1.2.3\"\n");
    try h.put("pk/src/lib.rs", "// mine\n");
    const r = h.run(&.{ "cargo", "init", "pk" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, "already a Cargo package"));
    try t.expectEqualStrings("// mine\n", h.read("pk/src/lib.rs"));
    try t.expect(kit.contains(h.read("pk/Cargo.toml"), "version = \"1.2.3\""));
    try t.expect(kit.contains(h.read("pk/Cargo.toml"), "[package.metadata.buildrules]"));
    try t.expectEqualStrings("[workspace]\nmembers = [\"old\", \"pk\"]\n", h.read("Cargo.toml"));
}

test "init is idempotent: the second run changes no file" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try withRoot(h);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "cargo", "new", "p" }).code);
    const m = h.read("p/Cargo.toml");
    const b = h.read("p/BUCK");
    const w = h.read("Cargo.toml");
    const r = h.run(&.{ "cargo", "init", "p" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings(m, h.read("p/Cargo.toml"));
    try t.expectEqualStrings(b, h.read("p/BUCK"));
    try t.expectEqualStrings(w, h.read("Cargo.toml"));
    try t.expectEqual(@as(usize, 1), kit.count(h.read("p/BUCK"), "cargo_package(path"));
}

test "init with no path would make the workspace root a package: refused" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try withRoot(h);
    const r = h.run(&.{ "cargo", "init" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "workspace root"));
    try t.expect(!h.has("BUCK"));
    try t.expectEqualStrings(root_ws, h.read("Cargo.toml"));
}

test "a virtual workspace manifest is not a package: adopt says so and edits nothing" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try withRoot(h);
    try h.put("v/Cargo.toml", "[workspace]\nmembers = []\n");
    const r = h.run(&.{ "cargo", "adopt", "v" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "no [package] table"));
    try t.expectEqualStrings(root_ws, h.read("Cargo.toml"));
    try t.expect(!h.has("v/BUCK"));
}

// ---- adopt ---------------------------------------------------------------------------------

test "adopt PATH: metadata table, BUCK file and member, with no cargo run" {
    const h = try kit.Harness.create();
    defer h.destroy();
    withFake(h);
    try withRoot(h);
    try h.put("crates/a/Cargo.toml", "[package]\nname = \"a\"\nversion = \"0.1.0\"\n");
    const r = h.run(&.{ "cargo", "adopt", "crates/a" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqual(@as(usize, 0), seen_len);
    try t.expect(kit.contains(h.read("crates/a/Cargo.toml"), "\n[package.metadata.buildrules]\n"));
    try t.expectEqualStrings("load(\"//:buildrules.bzl\", \"cargo_package\")\n\ncargo_package(path = \".\")\n", h.read("crates/a/BUCK"));
    try t.expectEqualStrings("[workspace]\nmembers = [\"crates/a\"]\n", h.read("Cargo.toml"));
}

test "adopt with no path takes every member, expanding dir/* and skipping a directory without a manifest" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try h.put("Cargo.toml", "[workspace]\nmembers = [\n    \"crates/*\",  # the packages\n    \"tools/x\",\n]\n");
    try h.put("crates/a/Cargo.toml", "[package]\nname = \"a\"\n");
    try h.put("crates/b/Cargo.toml", "[package]\nname = \"b\"\n");
    try h.put("crates/notapkg/readme", "");
    try h.put("tools/x/Cargo.toml", "[package]\nname = \"x\"\n");
    const r = h.run(&.{ "cargo", "adopt" });
    try t.expectEqual(@as(u8, 0), r.code);
    for ([_][]const u8{ "crates/a", "crates/b", "tools/x" }) |p| {
        try t.expect(kit.contains(h.read(try std.fmt.allocPrint(h.a(), "{s}/BUCK", .{p})), "cargo_package(path = \".\")"));
        try t.expect(kit.contains(h.read(try std.fmt.allocPrint(h.a(), "{s}/Cargo.toml", .{p})), "[package.metadata.buildrules]"));
    }
    try t.expect(!h.has("crates/notapkg/BUCK"));
    // Cargo.toml is untouched: the globs already cover them.
    try t.expect(kit.contains(h.read("Cargo.toml"), "# the packages"));
    // A second adopt changes nothing.
    const before = h.read("crates/a/Cargo.toml");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "cargo", "adopt" }).code);
    try t.expectEqualStrings(before, h.read("crates/a/Cargo.toml"));
    try t.expectEqual(@as(usize, 1), kit.count(h.read("crates/a/BUCK"), "cargo_package(path"));
}

test "adopt keeps the rules a BUCK file already has, refuses a glob it cannot expand and flags that do not apply" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try withRoot(h);
    try h.put("a/Cargo.toml", "[package]\nname = \"a\"\n");
    try h.put("a/BUCK", "genrule(name = \"g\")\n");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "cargo", "adopt", "a" }).code);
    try t.expect(kit.contains(h.read("a/BUCK"), "genrule(name = \"g\")"));
    try t.expect(kit.contains(h.read("a/BUCK"), "cargo_package(path = \".\")"));
    try t.expectEqual(@as(u8, 1), h.run(&.{ "cargo", "adopt", "missing" }).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "cargo", "adopt", "a", "--cargo", "c" }).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "cargo", "adopt", "a", "--lib" }).code);
    try h.put("Cargo.toml", "[workspace]\nmembers = [\"a/**/b\"]\n");
    const r = h.run(&.{ "cargo", "adopt" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "glob"));
}
