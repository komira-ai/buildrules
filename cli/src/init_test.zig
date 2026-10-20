//! `buildrules init`. Every test is named for the defect it catches.

const std = @import("std");
const kit = @import("testkit.zig");
const init = @import("init.zig");
const t = std.testing;

const commit = "0123456789abcdef0123456789abcdef01234567";

test "a fresh directory gets every file, and nothing in them names an endpoint" {
    const h = try kit.Harness.create();
    defer h.destroy();
    const r = h.run(&.{ "init", "repo", "--path", "third_party/buildrules" });
    try t.expectEqual(@as(u8, 0), r.code);
    for ([_][]const u8{ "repo/.buckconfig", "repo/toolchains/BUCK", "repo/toolchains/rust_pins.bzl", "repo/platforms/BUCK", "repo/.buckconfig.local.example", "repo/rust-toolchain.toml", "repo/Cargo.toml", "repo/.gitignore" }) |f| {
        try t.expect(h.has(f));
        // The defect: a committed file carrying an address a farm answers on.
        try t.expect(!kit.contains(h.read(f), "grpc:" ++ "//" ++ "my-" ++ "host"));
        try t.expect(!kit.contains(h.read(f), "ts.net"));
    }
    const cfg = h.read("repo/.buckconfig");
    try t.expect(kit.contains(cfg, "  root = .\n"));
    try t.expect(kit.contains(cfg, "  buildrules = third_party/buildrules\n"));
    try t.expect(kit.contains(cfg, "execution_platforms = root//platforms:exec"));
    try t.expect(kit.contains(h.read("repo/toolchains/BUCK"), "rust_toolchains(extra = EXTRA_RUST_VERSIONS)"));
    try t.expect(kit.contains(h.read("repo/rust-toolchain.toml"), "channel = \"" ++ init.default_rust ++ "\""));
    try t.expect(kit.contains(init.usage_text, "(default " ++ init.default_rust ++ ")"));
    const ig = h.read("repo/.gitignore");
    try t.expect(kit.contains(ig, ".buckconfig.local\n"));
    try t.expect(kit.contains(ig, "buck-out/\n"));
    // The example is placeholders only: every endpoint line is commented out.
    var it = std.mem.splitScalar(u8, h.read("repo/.buckconfig.local.example"), '\n');
    while (it.next()) |l| {
        const tl = std.mem.trim(u8, l, " ");
        try t.expect(!std.mem.startsWith(u8, tl, "engine_address") and !std.mem.startsWith(u8, tl, "linux_x86_64_properties"));
    }
}

test "a git cell is pinned at a commit and has no local path" {
    const h = try kit.Harness.create();
    defer h.destroy();
    const r = h.run(&.{ "init", ".", "--git", "https://example.invalid/buildrules.git", "--commit", commit, "--cell", "mopm" });
    try t.expectEqual(@as(u8, 0), r.code);
    const cfg = h.read(".buckconfig");
    try t.expect(kit.contains(cfg, "  buildrules = git\n"));
    try t.expect(kit.contains(cfg, "[external_cell_buildrules]\n  git_origin = https://example.invalid/buildrules.git\n  commit_hash = " ++ commit ++ "\n"));
    try t.expect(kit.contains(cfg, "  mopm = .\n"));
    try t.expect(kit.contains(cfg, "target:mopm//...->buildrules//platforms:linux_x86_64"));
}

test "running init twice changes nothing and does not duplicate .gitignore lines" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&.{ "init", "--path", "bu" }).code);
    const before = h.read(".gitignore");
    const cfg = h.read(".buckconfig");
    const second = h.run(&.{ "init", "--path", "bu" });
    try t.expectEqual(@as(u8, 0), second.code);
    try t.expectEqualStrings(before, h.read(".gitignore"));
    try t.expectEqualStrings(cfg, h.read(".buckconfig"));
    try t.expectEqual(@as(usize, 1), kit.count(h.read(".gitignore"), "buck-out/"));
    try t.expect(kit.contains(second.out, "kept    .buckconfig"));
}

test "existing .gitignore lines are kept and only the missing ones are appended" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try h.put(".gitignore", "target/\nbuck-out/");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "init", "--path", "bu" }).code);
    try t.expectEqualStrings("target/\nbuck-out/\n.buckconfig.local\n", h.read(".gitignore"));
}

test "an existing .buckconfig is never rewritten; init exits 1 and prints the cells it needs" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try h.put(".buckconfig", "[cells]\n  mine = .\n");
    const r = h.run(&.{ "init", "--path", "bu" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("[cells]\n  mine = .\n", h.read(".buckconfig"));
    try t.expect(kit.contains(r.err, "  buildrules = bu\n"));
    // The files that do not depend on the config were still written.
    try t.expect(h.has("toolchains/BUCK"));
}

test "an existing rust-toolchain.toml is kept, not replaced by the default" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try h.put("rust-toolchain.toml", "[toolchain]\nchannel = \"1.80.0\"\n");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "init", "--path", "bu" }).code);
    try t.expectEqualStrings("[toolchain]\nchannel = \"1.80.0\"\n", h.read("rust-toolchain.toml"));
}

test "usage errors exit 2 and write nothing: no source, both sources, a branch for a commit, a floating compiler" {
    const h = try kit.Harness.create();
    defer h.destroy();
    const bad = [_][]const []const u8{
        &.{"init"},
        &.{ "init", "--path", "bu", "--git", "https://example.invalid/x.git", "--commit", commit },
        &.{ "init", "--git", "https://example.invalid/x.git", "--commit", "main" },
        // An abbreviated hash is not a pin.
        &.{ "init", "--git", "https://example.invalid/x.git", "--commit", "0123abc" },
        // Upper case is not what git prints.
        &.{ "init", "--git", "https://example.invalid/x.git", "--commit", "0123456789ABCDEF0123456789abcdef01234567" },
        &.{ "init", "--git", "https://example.invalid/x.git" },
        // file:// takes an absolute path, never a relative one or a parent reference.
        &.{ "init", "--git", "file://relative/x", "--commit", commit },
        &.{ "init", "--git", "file:///abs/../x", "--commit", commit },
        &.{ "init", "--path", "bu", "--rust-version", "stable" },
        &.{ "init", "--path", "bu", "--rust-version", "1.95" },
        &.{ "init", "--path", "bu\"x" },
        // Buck2: "expected a normalized path" for a cell outside the repository.
        &.{ "init", "--path", "../buildrules" },
        &.{ "init", "--path", "a/../b" },
        &.{ "init", "--path", "/abs/buildrules" },
        &.{ "init", "--path", "bu/" },
        &.{ "init", "--path", "bu", "--cell", "Bad Name" },
        &.{ "init", "--path", "bu", "--nope" },
    };
    for (bad) |argv| {
        const r = h.run(argv);
        try t.expectEqual(@as(u8, 2), r.code);
    }
    try t.expect(!h.has(".buckconfig"));
}

test "a file:// origin is accepted for a local clone; the pin is still the full commit" {
    const h = try kit.Harness.create();
    defer h.destroy();
    const r = h.run(&.{ "init", ".", "--git", "file:///srv/clone/buildrules", "--commit", commit });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(h.read(".buckconfig"), "  git_origin = file:///srv/clone/buildrules\n  commit_hash = " ++ commit ++ "\n"));
}

test "init writes a virtual workspace whose policy and profile the generator accepts, and keeps an existing Cargo.toml" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&.{ "init", "--path", "bu" }).code);
    const m = h.read("Cargo.toml");
    // Virtual (v0 refuses a root package), policy tables, and the profile a hermetic build needs.
    try t.expect(!kit.contains(m, "\n[package]\n"));
    try t.expect(kit.contains(m, "\n[workspace]\n"));
    try t.expect(kit.contains(m, "\n[workspace.metadata.buildrules]\n"));
    try t.expect(kit.contains(m, "\n[profile.dev]\nincremental = false\n"));
    const h2 = try kit.Harness.create();
    defer h2.destroy();
    try h2.put("Cargo.toml", "[workspace]\nmembers = [\"mine\"]\n");
    try t.expectEqual(@as(u8, 0), h2.run(&.{ "init", "--path", "bu" }).code);
    try t.expectEqualStrings("[workspace]\nmembers = [\"mine\"]\n", h2.read("Cargo.toml"));
}

test "init then cargo new then check: the files init wrote are the ones the other commands accept" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&.{ "init", "--path", "bu" }).code);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "cargo", "new", "crates/hello" }).code);
    try t.expect(kit.contains(h.read("Cargo.toml"), "members = [\"crates/hello\"]"));
}
