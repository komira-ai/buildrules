//! The unit-graph generator (unitgen.zig), its readers (val.zig, toml.zig) and the policy it reads from Cargo.toml. These are the
//! tests of the Python generator it replaced, ported, and the ones that generator never had. Every test says the defect it catches.
//! The end-to-end golden (cargo's graphs for a real package in, the committed table out, byte for byte) is in
//! sync_check_test.zig.

const std = @import("std");
const kit = @import("testkit.zig");
const toml = @import("toml.zig");
const unitgen = @import("unitgen.zig");
const val = @import("val.zig");
const Diag = @import("diag.zig").Diag;
const t = std.testing;

const pins = @embedFile("fixture/rules_rust_pins.bzl.fixture");
const H = "a" ** 64;

const extra_text =
    "EXTRA_RUST_VERSIONS = {\n" ++
    "    \"1.86.0\": {\n" ++
    "        \"rustc\": {\"sha256\": \"" ++ H ++ "\", \"size\": 1},\n" ++
    "        \"rust_std\": {\"sha256\": \"" ++ H ++ "\", \"size\": 2},\n" ++
    "        \"cargo\": {\"sha256\": \"" ++ H ++ "\", \"size\": 3},\n" ++
    "        \"clippy\": {\"sha256\": \"" ++ H ++ "\", \"size\": 4},\n" ++
    "    },\n" ++
    "}\n";

const Env = struct {
    ar: std.heap.ArenaAllocator,
    fn init() Env {
        return .{ .ar = std.heap.ArenaAllocator.init(t.allocator) };
    }
    fn deinit(e: *Env) void {
        e.ar.deinit();
    }
    fn a(e: *Env) std.mem.Allocator {
        return e.ar.allocator();
    }
};

fn refusedWith(d: *Diag, needle: []const u8) !void {
    try t.expect(d.count() > 0);
    for (d.msgs.items) |m| if (std.mem.indexOf(u8, m, needle) != null) return;
    std.debug.print("no message holds `{s}`: {s}\n", .{ needle, d.msgs.items[0] });
    return error.TestExpectedMessage;
}

fn tomlOf(a: std.mem.Allocator, text: []const u8) !val.Value {
    const p = toml.parse(a, text);
    if (p.msg.len != 0) {
        std.debug.print("toml line {d}: {s}\n", .{ p.line, p.msg });
        return error.BadToml;
    }
    return p.value;
}

// ---- the toolchain (test_toolchain.py) -------------------------------------------------------------------------------

test "toolchain: the default is a builtin pin and is marked default; its four hashes are the sorted components" {
    // Defect: a default bump that leaves a stale hash in a table, or a record without all four components.
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    const tc = try unitgen.resolveToolchain(e.a(), &d, "1.95.0", pins, null);
    try t.expectEqualStrings("builtin", val.getStr(tc, "origin").?);
    try t.expect(val.get(tc, "default").?.bool);
    const sha = val.get(tc, "sha256").?.object;
    try t.expectEqual(@as(usize, 4), sha.count());
    const names = [_][]const u8{ "cargo", "clippy", "rust_std", "rustc" };
    for (names, sha.keys()) |want, got| try t.expectEqualStrings(want, got);
}

test "toolchain: the oldest supported is builtin and not the default, and its record carries no date" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    const tc = try unitgen.resolveToolchain(e.a(), &d, "1.85.0", pins, null);
    try t.expectEqualStrings("builtin", val.getStr(tc, "origin").?);
    try t.expect(!val.get(tc, "default").?.bool);
    try t.expect(val.get(tc, "date") == null);
}

test "toolchain: two versions have different hashes (a copy-pasted row would pass the same hash for both)" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    const x = (try unitgen.resolveToolchain(e.a(), &d, "1.95.0", pins, null)).object.get("sha256").?;
    const y = (try unitgen.resolveToolchain(e.a(), &d, "1.85.0", pins, null)).object.get("sha256").?;
    for (x.object.keys()) |k| try t.expect(!std.mem.eql(u8, val.getStr(x, k).?, val.getStr(y, k).?));
}

test "toolchain: a compiler nobody pinned is refused at sync, with the known versions and the format of a pin" {
    // Defect: an unpinned compiler accepted at sync, so the failure moves to build time.
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolveToolchain(e.a(), &d, "1.86.0", pins, null));
    try refusedWith(&d, "does not pin");
    try refusedWith(&d, "it pins 1.95.0, 1.85.0");
    try refusedWith(&d, "[rust.\"1.86.0\".rust-std]");
}

test "toolchain: a user pin is used and says where it came from" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    const tc = try unitgen.resolveToolchain(e.a(), &d, "1.86.0", pins, extra_text);
    try t.expectEqualStrings("buildrules-pins.toml", val.getStr(tc, "origin").?);
    try t.expect(!val.get(tc, "default").?.bool);
    try t.expectEqualStrings(H, val.getStr(val.get(tc, "sha256").?, "rustc").?);
}

test "toolchain: a user pin does not replace a reviewed one (the same version in both: the reviewed hashes win)" {
    // Defect: a repository silently re-pinning the default compiler to bytes nobody in buildrules reviewed.
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    const both = try std.mem.replaceOwned(u8, e.a(), extra_text, "1.86.0", "1.95.0");
    const tc = try unitgen.resolveToolchain(e.a(), &d, "1.95.0", pins, both);
    try t.expectEqualStrings("builtin", val.getStr(tc, "origin").?);
    try t.expect(!std.mem.eql(u8, val.getStr(val.get(tc, "sha256").?, "rustc").?, H));
}

test "toolchain: no extra file is no extra versions" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolveToolchain(e.a(), &d, "1.86.0", pins, null));
}

test "toolchain: the block is deterministic text and starts with the version" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    const x = try val.litString(e.a(), try unitgen.resolveToolchain(e.a(), &d, "1.85.0", pins, null), 0);
    const y = try val.litString(e.a(), try unitgen.resolveToolchain(e.a(), &d, "1.85.0", pins, null), 0);
    try t.expectEqualStrings(x, y);
    try t.expect(std.mem.startsWith(u8, x, "{\n    \"version\": \"1.85.0\""));
}

test "toolchain: a pins file that is not a literal is a refusal, not a crash" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolveToolchain(e.a(), &d, "1.95.0", "RUST_VERSIONS = {\n\"1.95.0\": oops(),\n}\nRUST_DEFAULT = \"1.95.0\"\n", null));
    try refusedWith(&d, "not a literal");
    var d2 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolveToolchain(e.a(), &d2, "1.95.0", "X = 1\n", null));
    try refusedWith(&d2, "no RUST_VERSIONS");
}

// ---- lints, features, policy (test_policy.py) ------------------------------------------------------------------------

test "lints: levels and tools become the flags the compiler takes, clippy lints with their prefix" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    const tables = try tomlOf(e.a(), "[rust]\nunused = \"warn\"\n[clippy]\npedantic = \"deny\"\n");
    const f = try unitgen.lintFlags(e.a(), &d, tables, "t");
    try t.expectEqualStrings("[\"-W\", \"unused\"]", try val.litString(e.a(), val.get(f, "rust").?, 0));
    try t.expectEqualStrings("[\"-D\", \"clippy::pedantic\"]", try val.litString(e.a(), val.get(f, "clippy").?, 0));
}

test "lints: a lower priority first, equal priority name-descending (cargo's order; a later, more specific lint wins)" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    const tables = try tomlOf(e.a(), "[rust]\nz_lint = \"warn\"\nb_lint = \"warn\"\na_grp = { level = \"deny\", priority = -1 }\n");
    const f = try unitgen.lintFlags(e.a(), &d, tables, "t");
    try t.expectEqualStrings("[\"-D\", \"a_grp\", \"-W\", \"z_lint\", \"-W\", \"b_lint\"]", try val.litString(e.a(), val.get(f, "rust").?, 0));
}

test "lints: unexpected_cfgs carries its check-cfg values" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    const tables = try tomlOf(e.a(), "[rust]\nunexpected_cfgs = { level = \"warn\", check-cfg = [\"cfg(x)\"] }\n");
    const f = try unitgen.lintFlags(e.a(), &d, tables, "t");
    try t.expectEqualStrings("[\"-W\", \"unexpected_cfgs\", \"--check-cfg\", \"cfg(x)\"]", try val.litString(e.a(), val.get(f, "rust").?, 0));
}

test "lints: an unknown level and a check-cfg on any other lint are refused at sync" {
    // Defect: a level the compiler would reject at build time, or a check-cfg that silently does nothing.
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.lintFlags(e.a(), &d, try tomlOf(e.a(), "[rust]\nx = \"loud\"\n"), "t"));
    try refusedWith(&d, "unknown level");
    var d2 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.lintFlags(e.a(), &d2, try tomlOf(e.a(), "[rust]\nx = { level = \"warn\", check-cfg = [\"cfg(y)\"] }\n"), "t"));
    try refusedWith(&d2, "check-cfg only belongs");
}

test "features: the implicit feature of an optional dependency is declared, unless dep: syntax hides it" {
    var e = Env.init();
    defer e.deinit();
    const doc = try tomlOf(e.a(),
        \\[features]
        \\a = []
        \\[dependencies]
        \\opt = { version = "1", optional = true }
        \\hid = { optional = true }
        \\[target.'cfg(unix)'.dependencies]
        \\t = { optional = true }
    );
    const names = try unitgen.declaredFeatures(e.a(), doc);
    try t.expectEqual(@as(usize, 4), names.len);
    const want = [_][]const u8{ "a", "hid", "opt", "t" };
    for (want, names) |w, g| try t.expectEqualStrings(w, g);
    const hidden = try tomlOf(e.a(), "[features]\na = [\"dep:opt\"]\n[dependencies]\nopt = { optional = true }\n");
    const only_a = try unitgen.declaredFeatures(e.a(), hidden);
    try t.expectEqual(@as(usize, 1), only_a.len);
    try t.expectEqualStrings("a", only_a[0]);
}

test "features: check-cfg flags quote the values, so unexpected_cfgs knows the package" {
    var e = Env.init();
    defer e.deinit();
    const f = try unitgen.checkCfgFlags(e.a(), &.{ "a", "b" });
    try t.expectEqualStrings("[\"--check-cfg\", \"cfg(docsrs,test)\", \"--check-cfg\", \"cfg(feature, values(\\\"a\\\", \\\"b\\\"))\"]", try val.litString(e.a(), f, 0));
}

test "policy: a package overrides one action and keeps the rest of the workspace's" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    const ws = try tomlOf(e.a(), "default-action = \"ci\"\n[actions]\nci = [\"lint\", \"test\"]\nship = [\"lint\", \"test\", \"release\"]\n[lint]\ndeny-warnings = true\n");
    const pkg = try tomlOf(e.a(), "[actions]\nci = [\"lint\", \"debug\", \"test\"]\n");
    const r = try unitgen.resolvePolicy(e.a(), &d, ws, pkg, "p");
    try t.expectEqualStrings("{\n    \"ci\": [\"lint\", \"debug\", \"test\"],\n    \"ship\": [\"lint\", \"test\", \"release\"],\n}", try val.litString(e.a(), val.get(r, "actions").?, 0));
    try t.expect(val.get(r, "deny_warnings").?.bool);
    try t.expectEqualStrings("ci", val.getStr(r, "default_action").?);
}

test "policy: refusals (a typo'd key, an action that shadows a step, a step that is not one, a default that is nothing)" {
    // Defects: a typo'd policy key that silently does nothing; an action named like a step; a step the build has no action for.
    var e = Env.init();
    defer e.deinit();
    const none = val.newObject(e.a());
    var d1 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.policyOf(e.a(), &d1, try tomlOf(e.a(), "[buildrules.profile]\n"), "w"));
    try refusedWith(&d1, "unknown key");
    var d2 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolvePolicy(e.a(), &d2, try tomlOf(e.a(), "[actions]\ntest = [\"lint\"]\n"), none, "w"));
    try refusedWith(&d2, "name of a step");
    var d3 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolvePolicy(e.a(), &d3, try tomlOf(e.a(), "[actions]\nci = [\"lint\", \"fmt\"]\n"), none, "w"));
    try refusedWith(&d3, "non-empty list of steps");
    var d4 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolvePolicy(e.a(), &d4, try tomlOf(e.a(), "[actions]\nci = []\n"), none, "w"));
    try refusedWith(&d4, "non-empty list of steps");
    var d5 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolvePolicy(e.a(), &d5, try tomlOf(e.a(), "default-action = \"nope\"\n"), none, "w"));
    try refusedWith(&d5, "default-action");
    var d6 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolvePolicy(e.a(), &d6, try tomlOf(e.a(), "[lint]\nwarnings-are-fine = true\n"), none, "w"));
    try refusedWith(&d6, "unknown lint policy key");
}

// ---- generate: a workspace on disk, cargo's graphs for it -----------------------------------------------------------

const lock_with_itoa =
    "version = 4\n\n[[package]]\nname = \"app\"\nversion = \"0.1.0\"\ndependencies = [\n \"itoa\",\n]\n\n" ++
    "[[package]]\nname = \"itoa\"\nversion = \"1.0.15\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\n" ++
    "checksum = \"4a5f13b858c8d314ee3e8f639011f7ccefe71f97f96e50151fb991f267928e2c\"\n";

const ws_manifest = "[workspace]\nmembers = [\"crates/app\"]\n[workspace.metadata.buildrules.actions]\nci = [\"lint\", \"test\"]\n";
const app_manifest = "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n";
const itoa_manifest = "[package]\nname = \"itoa\"\nversion = \"1.0.15\"\n";

const profile_dev =
    "{\"name\":\"dev\",\"opt_level\":\"0\",\"lto\":\"false\",\"codegen_backend\":null,\"codegen_units\":null,\"debuginfo\":2," ++
    "\"split_debuginfo\":null,\"debug_assertions\":true,\"overflow_checks\":true,\"rpath\":false,\"incremental\":false," ++
    "\"panic\":\"unwind\",\"strip\":{\"deferred\":\"None\"}}";

/// Cargo's graph for `app` (a library) depending on registry `itoa`: unit 0 is itoa, unit 1 is app.
const graph_app =
    "{\"version\":1,\"units\":[" ++
    "{\"pkg_id\":\"registry+https://github.com/rust-lang/crates.io-index#itoa@1.0.15\",\"target\":{\"kind\":[\"lib\"],\"crate_types\":[\"lib\"],\"name\":\"itoa\"," ++
    "\"src_path\":\"@ROOT@/cargo/registry/src/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15/src/lib.rs\",\"edition\":\"2018\",\"doctest\":true,\"test\":true}," ++
    "\"profile\":" ++ profile_dev ++ ",\"platform\":\"x86_64-unknown-linux-gnu\",\"mode\":\"build\",\"features\":[\"std\"],\"dependencies\":[]}," ++
    "{\"pkg_id\":\"path+file://@ROOT@/crates/app#0.1.0\",\"target\":{\"kind\":[\"lib\"],\"crate_types\":[\"lib\"],\"name\":\"app\"," ++
    "\"src_path\":\"@ROOT@/crates/app/src/lib.rs\",\"edition\":\"2021\",\"doctest\":true,\"test\":true}," ++
    "\"profile\":" ++ profile_dev ++ ",\"platform\":\"x86_64-unknown-linux-gnu\",\"mode\":\"build\",\"features\":[]," ++
    "\"dependencies\":[{\"index\":0,\"extern_crate_name\":\"itoa\",\"public\":false,\"noprelude\":false}]}" ++
    "],\"roots\":[1]}";

const Repo = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,

    fn create(e: *Env, lock: []const u8) !Repo {
        var tmp = std.testing.tmpDir(.{});
        try tmp.dir.makePath("crates/app/src");
        try tmp.dir.makePath("cargo/registry/src/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15/src");
        try tmp.dir.writeFile(.{ .sub_path = "Cargo.toml", .data = ws_manifest });
        try tmp.dir.writeFile(.{ .sub_path = "crates/app/Cargo.toml", .data = app_manifest });
        try tmp.dir.writeFile(.{ .sub_path = "rust-toolchain.toml", .data = "[toolchain]\nchannel = \"1.95.0\"\n" });
        try tmp.dir.writeFile(.{ .sub_path = "cargo/registry/src/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15/Cargo.toml", .data = itoa_manifest });
        const root = try tmp.dir.realpathAlloc(e.a(), ".");
        _ = lock;
        return .{ .tmp = tmp, .root = root };
    }

    fn graph(r: Repo, e: *Env, template: []const u8) ![]const u8 {
        return std.mem.replaceOwned(u8, e.a(), template, "@ROOT@", r.root);
    }

    fn input(r: Repo, e: *Env, lock: []const u8, graphs: []const unitgen.GraphIn) unitgen.Input {
        _ = e;
        return .{ .cargo_lock = lock, .root = r.root, .graphs = graphs, .rustc = "1.95.0", .target = "x86_64-unknown-linux-gnu", .rust_pins = pins, .manifests = &.{ "Cargo.toml", "crates/app/Cargo.toml", "rust-toolchain.toml" } };
    }
};

test "generate: a registry dependency is a sha256-pinned unit with the crate's path inside the package, a workspace member keeps its relative path" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    var d = Diag.init(e.a());
    const gs = [_]unitgen.GraphIn{.{ .scope = "app", .verb = "build", .json = try repo.graph(&e, graph_app) }};
    const res = try unitgen.generate(e.a(), &d, repo.input(&e, lock_with_itoa, &gs));
    const units = res.units.object;
    try t.expectEqual(@as(usize, 2), units.count());
    var saw_reg = false;
    var saw_path = false;
    for (units.keys(), units.values()) |uid, u| {
        // the id is the first ten hex digits of the hash of the body: the key says what was hashed
        try t.expectEqualStrings(uid[std.mem.indexOfScalar(u8, uid, ':').? + 1 ..], try val.contentId(e.a(), u, 10));
        if (std.mem.eql(u8, val.getStr(u, "crate").?, "itoa")) {
            saw_reg = true;
            try t.expectEqualStrings("registry", val.getStr(u, "source").?);
            try t.expectEqualStrings("src/lib.rs", val.getStr(u, "crate_root").?);
            try t.expectEqualStrings("4a5f13b858c8d314ee3e8f639011f7ccefe71f97f96e50151fb991f267928e2c", val.getStr(u, "sha256").?);
            try t.expectEqualStrings("[\"feature=\\\"std\\\"\"]", try val.litString(e.a(), val.get(u, "cfgs").?, 0));
            try t.expect(val.get(u, "path") == null);
        } else {
            saw_path = true;
            try t.expectEqualStrings("crates/app", val.getStr(u, "path").?);
            try t.expect(val.get(u, "sha256") == null);
            // the dependency edge is [extern name, unit id], and the unit id is itoa's
            try t.expectEqualStrings("itoa", val.get(u, "deps").?.array.items[0].array.items[0].string);
            try t.expect(std.mem.startsWith(u8, val.get(u, "deps").?.array.items[0].array.items[1].string, "itoa-1.0.15:"));
        }
    }
    try t.expect(saw_reg and saw_path);
    // nothing absolute is written
    try t.expect(std.mem.indexOf(u8, res.text, repo.root) == null);
    try t.expect(std.mem.indexOf(u8, res.text, "/registry/src/") == null);
    // PACKAGES comes from the manifests: the workspace's action is the member's
    try t.expect(std.mem.indexOf(u8, res.text, "\"ci\": [\"lint\", \"test\"]") != null);
}

test "generate: the same unit in two graphs is one entry (the cache-sharing fact), and the output is the same on a rerun" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    var d = Diag.init(e.a());
    const json = try repo.graph(&e, graph_app);
    const gs = [_]unitgen.GraphIn{ .{ .scope = "app", .verb = "build", .json = json }, .{ .scope = "*", .verb = "build", .json = json } };
    const r1 = try unitgen.generate(e.a(), &d, repo.input(&e, lock_with_itoa, &gs));
    try t.expectEqual(@as(usize, 2), r1.units.object.count());
    const r2 = try unitgen.generate(e.a(), &d, repo.input(&e, lock_with_itoa, &gs));
    try t.expectEqualStrings(r1.text, r2.text);
    // the workspace-wide graph is recorded under GRAPHS, the member's under MEMBERS
    try t.expect(std.mem.indexOf(u8, r1.text, "GRAPHS = {\n    \"build\": {") != null);
    try t.expect(std.mem.indexOf(u8, r1.text, "MEMBERS = {\n    \"app\": {") != null);
}

test "generate: a feature or a profile field changes the id (a unit that differs must not share a cache entry)" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    var d = Diag.init(e.a());
    const base = [_]unitgen.GraphIn{.{ .scope = "app", .verb = "build", .json = try repo.graph(&e, graph_app) }};
    const r1 = try unitgen.generate(e.a(), &d, repo.input(&e, lock_with_itoa, &base));
    const more = try std.mem.replaceOwned(u8, e.a(), try repo.graph(&e, graph_app), "\"features\":[\"std\"]", "\"features\":[\"std\",\"no-panic\"]");
    const gs2 = [_]unitgen.GraphIn{.{ .scope = "app", .verb = "build", .json = more }};
    const r2 = try unitgen.generate(e.a(), &d, repo.input(&e, lock_with_itoa, &gs2));
    const opt = try std.mem.replaceOwned(u8, e.a(), try repo.graph(&e, graph_app), "\"opt_level\":\"0\"", "\"opt_level\":\"3\"");
    const gs3 = [_]unitgen.GraphIn{.{ .scope = "app", .verb = "build", .json = opt }};
    const r3 = try unitgen.generate(e.a(), &d, repo.input(&e, lock_with_itoa, &gs3));
    for ([_]*const unitgen.Result{ &r1, &r2, &r3 }, 0..) |x, i| {
        for ([_]*const unitgen.Result{ &r1, &r2, &r3 }, 0..) |y, j| {
            if (i == j) continue;
            for (x.units.object.keys()) |k| try t.expect(!y.units.object.contains(k));
        }
    }
}

test "generate: the profile name is not part of the id (rustc never sees it)" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    var d = Diag.init(e.a());
    const gs1 = [_]unitgen.GraphIn{.{ .scope = "app", .verb = "build", .json = try repo.graph(&e, graph_app) }};
    const renamed = try std.mem.replaceOwned(u8, e.a(), try repo.graph(&e, graph_app), "\"name\":\"dev\"", "\"name\":\"test\"");
    const gs2 = [_]unitgen.GraphIn{.{ .scope = "app", .verb = "test", .json = renamed }};
    const r1 = try unitgen.generate(e.a(), &d, repo.input(&e, lock_with_itoa, &gs1));
    const r2 = try unitgen.generate(e.a(), &d, repo.input(&e, lock_with_itoa, &gs2));
    for (r1.units.object.keys()) |k| try t.expect(r2.units.object.contains(k));
}

test "generate: the links key of a registry package's manifest is recorded (the unit graph does not carry it)" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    try repo.tmp.dir.writeFile(.{ .sub_path = "cargo/registry/src/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15/Cargo.toml", .data = "[package]\nname = \"itoa\"\nversion = \"1.0.15\"\nlinks = \"native_itoa\"\n" });
    var d = Diag.init(e.a());
    const gs = [_]unitgen.GraphIn{.{ .scope = "app", .verb = "build", .json = try repo.graph(&e, graph_app) }};
    const res = try unitgen.generate(e.a(), &d, repo.input(&e, lock_with_itoa, &gs));
    for (res.units.object.values()) |u| {
        if (std.mem.eql(u8, val.getStr(u, "crate").?, "itoa")) try t.expectEqualStrings("native_itoa", val.getStr(u, "links").?);
    }
}

/// `generate` of the graph `json` on `repo`, whatever it reports: an allocation that fails is an error or a refusal, and a refusal is a message.
const GenerateCall = struct {
    repo: Repo,
    lock: []const u8,
    json: []const u8,
    manifests: []const []const u8 = &.{ "Cargo.toml", "crates/app/Cargo.toml", "rust-toolchain.toml" },
    expect_units: usize = 0,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        var d = Diag.init(a);
        const gs = [_]unitgen.GraphIn{.{ .scope = "app", .verb = "build", .json = self.json }};
        var in = self.repo.input(undefined, self.lock, &gs);
        in.manifests = self.manifests;
        const res = unitgen.generate(a, &d, in) catch return false;
        return res.units.object.count() == self.expect_units;
    }
};

fn generateRefused(e: *Env, repo: Repo, lock: []const u8, json: []const u8, needle: []const u8) !void {
    var d = Diag.init(e.a());
    const gs = [_]unitgen.GraphIn{.{ .scope = "app", .verb = "build", .json = json }};
    try t.expectError(error.Refused, unitgen.generate(e.a(), &d, repo.input(e, lock, &gs)));
    try refusedWith(&d, needle);
    // The same refusal with the allocator failing at each allocation: the refusal is the message, or the run fails; nothing ends as a table.
    try kit.sweepOomRefusal(GenerateCall{ .repo = repo, .lock = lock, .json = json });
}

test "generate: refusals, each the defect it names" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    const ok = try repo.graph(&e, graph_app);
    // incremental compilation cannot be hermetic
    try generateRefused(&e, repo, lock_with_itoa, try std.mem.replaceOwned(u8, e.a(), ok, "\"incremental\":false", "\"incremental\":true"), "incremental compilation on");
    // unstable public/noprelude edges
    try generateRefused(&e, repo, lock_with_itoa, try std.mem.replaceOwned(u8, e.a(), ok, "\"public\":false", "\"public\":true"), "public/noprelude");
    // a git dependency
    try generateRefused(&e, repo, lock_with_itoa, try std.mem.replaceOwned(u8, e.a(), ok, "registry+https://github.com/rust-lang/crates.io-index#itoa@1.0.15", "git+https://example.invalid/x?rev=1#abcdef"), "source kind not supported");
    // a unit graph of another version
    try generateRefused(&e, repo, lock_with_itoa, try std.mem.replaceOwned(u8, e.a(), ok, "{\"version\":1,", "{\"version\":2,"), "version is not 1");
    // a path package outside the workspace
    const app_id = try std.fmt.allocPrint(e.a(), "path+file://{s}/crates/app", .{repo.root});
    try generateRefused(&e, repo, lock_with_itoa, try std.mem.replaceOwned(u8, e.a(), ok, app_id, "path+file:///elsewhere/app"), "outside the workspace");
    // a source path not in the package the id names
    try generateRefused(&e, repo, lock_with_itoa, try std.mem.replaceOwned(u8, e.a(), ok, "itoa-1.0.15/src/lib.rs", "itoa-9.9.9/src/lib.rs"), "is not in itoa-1.0.15");
    // a crate the lock does not know
    try generateRefused(&e, repo, "version = 4\n\n[[package]]\nname = \"app\"\nversion = \"0.1.0\"\n", ok, "not in Cargo.lock");
    // a registry crate with no checksum
    try generateRefused(&e, repo, "version = 4\n\n[[package]]\nname = \"app\"\nversion = \"0.1.0\"\n\n[[package]]\nname = \"itoa\"\nversion = \"1.0.15\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\n", ok, "no sha256 checksum");
    // another registry
    try generateRefused(&e, repo, lock_with_itoa_elsewhere, ok, "only crates.io is supported");
    // a Cargo.lock version 1/2 is cargo_lock's refusal, surfaced
    try generateRefused(&e, repo, "version = 2\n", ok, "lock version");
    // the document is not JSON
    try generateRefused(&e, repo, lock_with_itoa, "not json", "not JSON");
}

const lock_with_itoa_elsewhere =
    "version = 4\n\n[[package]]\nname = \"app\"\nversion = \"0.1.0\"\n\n" ++
    "[[package]]\nname = \"itoa\"\nversion = \"1.0.15\"\nsource = \"registry+https://example.invalid/index\"\n" ++
    "checksum = \"4a5f13b858c8d314ee3e8f639011f7ccefe71f97f96e50151fb991f267928e2c\"\n";

// ---- toml.zig ---------------------------------------------------------------------------------------------------------

test "toml: tables, dotted and quoted keys, arrays of tables, inline tables, every scalar" {
    var e = Env.init();
    defer e.deinit();
    const doc = try tomlOf(e.a(),
        \\# a comment
        \\title = "a \"quoted\" \u00e9 string"   # trailing
        \\lit = 'C:\no\escapes'
        \\n = 1_000
        \\neg = -7
        \\hex = 0xff
        \\f = 3.5
        \\yes = true
        \\when = 1979-05-27T07:32:00Z
        \\list = [
        \\  "a", # comment
        \\  "b",
        \\]
        \\inline = { x = 1, y = { z = "w" } }
        \\a.b.c = 2
        \\[server."host name"]
        \\port = 80
        \\[[bin]]
        \\name = "one"
        \\[[bin]]
        \\name = "two"
        \\[bin.meta]
        \\k = "v"
        \\[a.d]
        \\e = 3
    );
    try t.expectEqualStrings("a \"quoted\" \u{e9} string", val.getStr(doc, "title").?);
    try t.expectEqualStrings("C:\\no\\escapes", val.getStr(doc, "lit").?);
    try t.expectEqual(@as(i64, 1000), val.get(doc, "n").?.integer);
    try t.expectEqual(@as(i64, -7), val.get(doc, "neg").?.integer);
    try t.expectEqual(@as(i64, 255), val.get(doc, "hex").?.integer);
    try t.expectEqual(@as(f64, 3.5), val.get(doc, "f").?.float);
    try t.expect(val.get(doc, "yes").?.bool);
    try t.expectEqualStrings("1979-05-27T07:32:00Z", val.getStr(doc, "when").?);
    try t.expectEqual(@as(usize, 2), val.items(val.get(doc, "list")).len);
    try t.expectEqualStrings("w", val.getStr(val.get(val.get(doc, "inline").?, "y").?, "z").?);
    try t.expectEqual(@as(i64, 2), toml.at(doc, &.{ "a", "b", "c" }).?.integer);
    try t.expectEqual(@as(i64, 3), toml.at(doc, &.{ "a", "d", "e" }).?.integer);
    try t.expectEqual(@as(i64, 80), toml.at(doc, &.{ "server", "host name", "port" }).?.integer);
    const bins = val.items(val.get(doc, "bin"));
    try t.expectEqual(@as(usize, 2), bins.len);
    try t.expectEqualStrings("two", val.getStr(bins[1], "name").?);
    try t.expectEqualStrings("v", val.getStr(val.get(bins[1], "meta").?, "k").?);
    try t.expect(val.get(bins[0], "meta") == null);
}

test "toml: multi-line strings: the first newline is dropped, a trailing backslash joins lines, literal strings keep everything" {
    var e = Env.init();
    defer e.deinit();
    const doc = try tomlOf(e.a(), "a = \"\"\"\nline1\nline2\"\"\"\nb = \"\"\"one \\\n   two\"\"\"\nc = '''\nraw \\n stays\n'''\n");
    try t.expectEqualStrings("line1\nline2", val.getStr(doc, "a").?);
    try t.expectEqualStrings("one two", val.getStr(doc, "b").?);
    try t.expectEqualStrings("raw \\n stays\n", val.getStr(doc, "c").?);
}

test "toml: a duplicate key, an unclosed string and a bad value are errors with a line number (not a half-read manifest)" {
    var e = Env.init();
    defer e.deinit();
    const dup = toml.parse(e.a(), "a = 1\nb = 2\na = 3\n");
    try t.expect(dup.msg.len != 0);
    try t.expectEqual(@as(usize, 3), dup.line);
    try t.expect(toml.parse(e.a(), "a = \"open\n").msg.len != 0);
    try t.expect(toml.parse(e.a(), "a = what\n").msg.len != 0);
    try t.expect(toml.parse(e.a(), "[t]\n[t.u\nx = 1\n").msg.len != 0);
    try t.expect(toml.parse(e.a(), "a = 1 b = 2\n").msg.len != 0);
    try t.expect(toml.parse(e.a(), "a = [1, 2\n").msg.len != 0);
}

// ---- val.zig ---------------------------------------------------------------------------------------------------------

test "val: strings are written as Python's json.dumps writes them (the committed tables depend on it)" {
    var e = Env.init();
    defer e.deinit();
    try t.expectEqualStrings("\"a\\\"b\\\\c\\n\\t\\u0001\\u007f\"", try val.quoted(e.a(), "a\"b\\c\n\t\x01\x7f"));
    try t.expectEqualStrings("\"\\u00e9\\u4e2d\"", try val.quoted(e.a(), "\u{e9}\u{4e2d}"));
    try t.expectEqualStrings("\"\\ud83d\\ude00\"", try val.quoted(e.a(), "\u{1f600}"));
}

test "val: the canonical form sorts keys and has no spaces; the id of a body is the hash of it" {
    var e = Env.init();
    defer e.deinit();
    const v = try val.parseLiteral(e.a(), "{\"b\": [1, True, None], \"a\": {\"z\": \"x\", \"y\": False}}");
    var aw = std.Io.Writer.Allocating.init(e.a());
    try val.canonical(&aw.writer, e.a(), v);
    try t.expectEqualStrings("{\"a\":{\"y\":false,\"z\":\"x\"},\"b\":[1,true,null]}", aw.written());
    // sha256 of the line above, first ten hex digits (computed with sha256sum)
    try t.expectEqualStrings("7241ea43aa", try val.contentId(e.a(), v, 10));
}

test "val: literals: short flat dicts and lists on one line, a long or nested one a line per entry, deps and profile always on one line" {
    var e = Env.init();
    defer e.deinit();
    const short = try val.parseLiteral(e.a(), "{\"test\": True, \"doctest\": False}");
    try t.expectEqualStrings("{\"test\": True, \"doctest\": False}", try val.litString(e.a(), short, 1));
    const nested = try val.parseLiteral(e.a(), "{\"k\": {\"a\": 1}, \"deps\": [[\"x\", \"y\"]], \"profile\": {\"p\": None}}");
    try t.expectEqualStrings("{\n        \"k\": {\"a\": 1},\n        \"deps\": [[\"x\", \"y\"]],\n        \"profile\": {\"p\": None},\n    }", try val.litString(e.a(), nested, 1));
    const long = try val.parseLiteral(e.a(), "{\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\": \"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\", \"c\": \"dddddddddddd\"}");
    try t.expect(std.mem.startsWith(u8, try val.litString(e.a(), long, 0), "{\n"));
    try t.expectEqualStrings("[]", try val.litString(e.a(), try val.parseLiteral(e.a(), "[]"), 0));
    try t.expectEqualStrings("{}", try val.litString(e.a(), try val.parseLiteral(e.a(), "{}"), 0));
    try t.expectEqualStrings("[\n    [\"a\"],\n]", try val.litString(e.a(), try val.parseLiteral(e.a(), "[[\"a\"]]"), 0));
}

test "val: readNamed reads a top-level literal, skips defs and other statements, and tells a missing name from a bad literal" {
    var e = Env.init();
    defer e.deinit();
    const text =
        \\"""docstring with RUST_X = 1 inside"""
        \\load("//x:y.bzl", "z")
        \\A = {
        \\    # a comment
        \\    "k": ["v", 2, True,],  # trailing
        \\}
        \\def f(x):
        \\    B = 3
        \\    return B
        \\C = 'single' + "oops"
        \\D = (1, 2)
    ;
    const a_v = (try val.readNamed(e.a(), text, "A")).?;
    try t.expectEqualStrings("[\"v\", 2, True]", try val.litString(e.a(), val.get(a_v, "k").?, 0));
    try t.expect((try val.readNamed(e.a(), text, "B")) == null);
    try t.expectError(error.BadLiteral, val.readNamed(e.a(), text, "C"));
    try t.expectEqual(@as(usize, 2), (try val.readNamed(e.a(), text, "D")).?.array.items.len);
}


// ---- generate: more refusals and the shapes of a unit graph -------------------------------------------------------------

const GenerateOk = struct {
    fn run(e: *Env, repo: Repo, lock: []const u8, json: []const u8) !unitgen.Result {
        var d = Diag.init(e.a());
        const gs = [_]unitgen.GraphIn{.{ .scope = "app", .verb = "build", .json = json }};
        return unitgen.generate(e.a(), &d, repo.input(e, lock, &gs));
    }
};

fn swapped(e: *Env, repo: Repo, from: []const u8, to: []const u8) ![]const u8 {
    const text = try std.mem.replaceOwned(u8, e.a(), try repo.graph(e, graph_app), from, to);
    // A replacement that matches nothing would test nothing.
    try t.expect(!std.mem.eql(u8, text, try repo.graph(e, graph_app)));
    return text;
}

test "generate: a unit missing a field cargo always writes is refused by name, not read as an empty one" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    const L = lock_with_itoa;
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"pkg_id\":\"registry+https://github.com/rust-lang/crates.io-index#itoa@1.0.15\",", ""), "a unit has no pkg_id");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"target\":{\"kind\":[\"lib\"],\"crate_types\":[\"lib\"],\"name\":\"itoa\"", "\"targ\":{\"kind\":[\"lib\"],\"crate_types\":[\"lib\"],\"name\":\"itoa\""), "a unit has no target");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"src_path\":", "\"srcp\":"), "the target has no src_path");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"profile\":{", "\"prof\":{"), "a unit has no profile");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"opt_level\":\"0\",", ""), "the profile has no `opt_level`");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"crate_types\":[\"lib\"],\"name\":\"itoa\"", "\"crate_types\":[\"lib\"],\"nme\":\"itoa\""), "the target has no name");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"mode\":\"build\"", "\"mod\":\"build\""), "a unit has no mode");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"edition\":\"2018\"", "\"edi\":\"2018\""), "the target has no edition");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"kind\":[\"lib\"]", "\"kind\":[1]"), "target kind holds a non-string");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"crate_types\":[\"lib\"],\"name\":\"itoa\"", "\"crate_types\":[true],\"name\":\"itoa\""), "target crate_types holds a non-string");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"features\":[\"std\"]", "\"features\":[1]"), "a feature is not a string");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"extern_crate_name\":\"itoa\"", "\"extern\":\"itoa\""), "a dependency has no extern_crate_name");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"index\":0", "\"idx\":0"), "a dependency has no index");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"index\":0", "\"index\":7"), "a dependency index is out of range");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"index\":0", "\"index\":-1"), "a dependency index is out of range");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"index\":0", "\"index\":\"0\""), "a dependency index is out of range");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"noprelude\":false", "\"noprelude\":true"), "public/noprelude");
}

test "generate: a root that is not a unit is refused, a repeated root is one root, and a graph with no unit is an empty table" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    const L = lock_with_itoa;
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"roots\":[1]", "\"roots\":[9]"), "a root index is out of range");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"roots\":[1]", "\"roots\":[-1]"), "a root index is out of range");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "\"roots\":[1]", "\"roots\":[\"x\"]"), "a root index is out of range");
    const twice = try GenerateOk.run(&e, repo, L, try swapped(&e, repo, "\"roots\":[1]", "\"roots\":[1,1,0]"));
    try t.expect(std.mem.indexOf(u8, twice.text, "\"units\": 2, \"graph_units\": 2") != null or std.mem.indexOf(u8, twice.text, "\"graph_units\": 2") != null);
    try t.expect(std.mem.count(u8, twice.text, "\"roots\": [\"app-0.1.0:") == 1);
    const none = try GenerateOk.run(&e, repo, L, "{\"version\":1,\"units\":[],\"roots\":[]}");
    try t.expectEqual(@as(usize, 0), none.units.object.count());
    try t.expect(std.mem.indexOf(u8, none.text, "UNITS = {\n}\n") != null);
}

test "generate: the package id decides the name and version; the source path must be inside the package it names" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    const L = lock_with_itoa;
    const reg = "registry+https://github.com/rust-lang/crates.io-index#itoa@1.0.15";
    try generateRefused(&e, repo, L, try swapped(&e, repo, reg, "registry+https://github.com/rust-lang/crates.io-index"), "no #name@version in the package id");
    try generateRefused(&e, repo, L, try swapped(&e, repo, "#itoa@1.0.15", "#itoa"), "no name@version in the package id");
    // The registry source path: no /registry/src/, an empty index directory, an empty package directory, and paths that end early.
    const src = "/cargo/registry/src/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15/src/lib.rs";
    try generateRefused(&e, repo, L, try swapped(&e, repo, src, "/cargo/vendor/itoa-1.0.15/src/lib.rs"), "is not in itoa-1.0.15");
    try generateRefused(&e, repo, L, try swapped(&e, repo, src, "/cargo/registry/src//itoa-1.0.15/src/lib.rs"), "is not in itoa-1.0.15");
    try generateRefused(&e, repo, L, try swapped(&e, repo, src, "/cargo/registry/src/idx//src/lib.rs"), "is not in itoa-1.0.15");
    try generateRefused(&e, repo, L, try swapped(&e, repo, src, "/cargo/registry/src/idx"), "is not in itoa-1.0.15");
    try generateRefused(&e, repo, L, try swapped(&e, repo, src, "/cargo/registry/src/idx/itoa-1.0.15"), "is not in itoa-1.0.15");
    // Path packages.
    try generateRefused(&e, repo, L, try swapped(&e, repo, "#0.1.0", ""), "no #version in the package id");
    const app_src = "/crates/app/src/lib.rs";
    try generateRefused(&e, repo, L, try swapped(&e, repo, app_src, "/elsewhere/lib.rs"), "outside its package directory");
    try generateRefused(&e, repo, L, try swapped(&e, repo, app_src, "/crates/app2/src/lib.rs"), "outside its package directory");
    // A lock that gives a path package a source is not a lock of this workspace.
    try generateRefused(&e, repo, "version = 4\n[[package]]\nname = \"app\"\nversion = \"0.1.0\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\n[[package]]\nname = \"itoa\"\nversion = \"1.0.15\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\nchecksum = \"" ++ "4a5f13b858c8d314ee3e8f639011f7ccefe71f97f96e50151fb991f267928e2c" ++ "\"\n", try repo.graph(&e, graph_app), "path package has a source");
}

test "generate: a path package id may carry its name (name@version), and a member at the top of the workspace is named by its directory" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    const named = try GenerateOk.run(&e, repo, lock_with_itoa, try swapped(&e, repo, "/crates/app#0.1.0", "/crates/app#app@0.1.0"));
    var found = false;
    for (named.units.object.values()) |u| {
        if (std.mem.eql(u8, val.getStr(u, "crate").?, "app")) {
            found = true;
            try t.expectEqualStrings("0.1.0", val.getStr(u, "version").?);
            try t.expectEqualStrings("crates/app", val.getStr(u, "path").?);
        }
    }
    try t.expect(found);
    // A member directly under the root: its name is the whole relative path.
    try repo.tmp.dir.makePath("app/src");
    try repo.tmp.dir.writeFile(.{ .sub_path = "app/Cargo.toml", .data = app_manifest });
    const top = try swapped(&e, repo, "/crates/app", "/app");
    const res = try GenerateOk.run(&e, repo, lock_with_itoa, top);
    for (res.units.object.values()) |u| {
        if (std.mem.eql(u8, val.getStr(u, "crate").?, "app")) try t.expectEqualStrings("app", val.getStr(u, "path").?);
    }
}

test "generate: a unit built for the host (no platform) is on the exec side, one built for the target is on the target side; an empty links is no links" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    const sides = struct {
        fn of(res: unitgen.Result, crate: []const u8) []const u8 {
            for (res.units.object.values()) |u| if (std.mem.eql(u8, val.getStr(u, "crate").?, crate)) return val.getStr(u, "side").?;
            return "(missing)";
        }
    }.of;
    const base = try GenerateOk.run(&e, repo, lock_with_itoa, try repo.graph(&e, graph_app));
    try t.expectEqualStrings("target", sides(base, "itoa"));
    const null_platform = try GenerateOk.run(&e, repo, lock_with_itoa, try swapped(&e, repo, "\"platform\":\"x86_64-unknown-linux-gnu\"", "\"platform\":null"));
    try t.expectEqualStrings("exec", sides(null_platform, "itoa"));
    try t.expectEqualStrings("exec", sides(null_platform, "app"));
    const no_platform = try GenerateOk.run(&e, repo, lock_with_itoa, try swapped(&e, repo, ",\"platform\":\"x86_64-unknown-linux-gnu\"", ""));
    try t.expectEqualStrings("exec", sides(no_platform, "itoa"));
    try repo.tmp.dir.writeFile(.{ .sub_path = "cargo/registry/src/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15/Cargo.toml", .data = "[package]\nname = \"itoa\"\nversion = \"1.0.15\"\nlinks = \"\"\n" });
    const empty_links = try GenerateOk.run(&e, repo, lock_with_itoa, try repo.graph(&e, graph_app));
    for (empty_links.units.object.values()) |u| try t.expect(val.get(u, "links") == null);
}

test "generate: an unreadable or malformed manifest of a registry package, or of the workspace, is a refusal naming the file" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    const itoa_toml = "cargo/registry/src/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15/Cargo.toml";
    try repo.tmp.dir.writeFile(.{ .sub_path = itoa_toml, .data = "[package\nname = \"itoa\"\n" });
    try generateRefused(&e, repo, lock_with_itoa, try repo.graph(&e, graph_app), "itoa-1.0.15/Cargo.toml:1:");
    try repo.tmp.dir.deleteFile(itoa_toml);
    try generateRefused(&e, repo, lock_with_itoa, try repo.graph(&e, graph_app), "cannot read the manifest of");
    try repo.tmp.dir.writeFile(.{ .sub_path = itoa_toml, .data = itoa_manifest });
    // The workspace manifest and a member's.
    try repo.tmp.dir.writeFile(.{ .sub_path = "Cargo.toml", .data = "[workspace\n" });
    try generateRefused(&e, repo, lock_with_itoa, try repo.graph(&e, graph_app), "Cargo.toml:1:");
    try repo.tmp.dir.deleteFile("Cargo.toml");
    try generateRefused(&e, repo, lock_with_itoa, try repo.graph(&e, graph_app), "cannot read");
    try repo.tmp.dir.writeFile(.{ .sub_path = "Cargo.toml", .data = ws_manifest });
    try repo.tmp.dir.deleteFile("crates/app/Cargo.toml");
    try generateRefused(&e, repo, lock_with_itoa, try repo.graph(&e, graph_app), "cannot read");
}

test "generate: a file in the manifests list that is not there is a refusal, not a hash of nothing" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    var d = Diag.init(e.a());
    const gs = [_]unitgen.GraphIn{.{ .scope = "app", .verb = "build", .json = try repo.graph(&e, graph_app) }};
    var in = repo.input(&e, lock_with_itoa, &gs);
    in.manifests = &.{ "Cargo.toml", "Cargo.toml", "gone/Cargo.toml" };
    try t.expectError(error.Refused, unitgen.generate(e.a(), &d, in));
    try refusedWith(&d, "cannot read");
    // A name listed twice is listed once.
    var d2 = Diag.init(e.a());
    in.manifests = &.{ "Cargo.toml", "Cargo.toml" };
    const res = try unitgen.generate(e.a(), &d2, in);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, res.text, "    \"Cargo.toml\": \""));
}

test "generate: member policy is read from the manifests: workspace lints, a package's own, actions, a default action, clippy.toml" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    const json = try repo.graph(&e, graph_app);
    // `lints.workspace = true`: the workspace's tables.
    try repo.tmp.dir.writeFile(.{ .sub_path = "Cargo.toml", .data = ws_manifest ++ "[workspace.lints.rust]\nunused = \"warn\"\n[workspace.lints.clippy]\npedantic = \"deny\"\n" });
    try repo.tmp.dir.writeFile(.{ .sub_path = "crates/app/Cargo.toml", .data = app_manifest ++ "[lints]\nworkspace = true\n" });
    const inherited = try GenerateOk.run(&e, repo, lock_with_itoa, json);
    try t.expect(std.mem.indexOf(u8, inherited.text, "\"rust\": [\"-W\", \"unused\"]") != null);
    try t.expect(std.mem.indexOf(u8, inherited.text, "\"clippy\": [\"-D\", \"clippy::pedantic\"]") != null);
    // `workspace = false` next to the package's own table: the package's own table, without the key.
    try repo.tmp.dir.writeFile(.{ .sub_path = "crates/app/Cargo.toml", .data = app_manifest ++ "[lints]\nworkspace = false\n[lints.rust]\nunsafe_code = \"forbid\"\n" });
    const own = try GenerateOk.run(&e, repo, lock_with_itoa, json);
    try t.expect(std.mem.indexOf(u8, own.text, "\"rust\": [\"-F\", \"unsafe_code\"]") != null);
    try t.expect(std.mem.indexOf(u8, own.text, "unused") == null);
    // The package's metadata overrides the workspace's action and default; clippy.toml is recorded.
    try repo.tmp.dir.writeFile(.{ .sub_path = "crates/app/Cargo.toml", .data = app_manifest ++ "[package.metadata.buildrules]\ndefault-action = \"test\"\n[package.metadata.buildrules.actions]\nship = [\"release\"]\n[package.metadata.buildrules.lint]\ndeny-warnings = true\n" });
    try repo.tmp.dir.writeFile(.{ .sub_path = "clippy.toml", .data = "msrv = \"1.70\"\n" });
    const meta = try GenerateOk.run(&e, repo, lock_with_itoa, json);
    try t.expect(std.mem.indexOf(u8, meta.text, "\"ship\": [\"release\"]") != null);
    try t.expect(std.mem.indexOf(u8, meta.text, "\"default_action\": \"test\"") != null);
    try t.expect(std.mem.indexOf(u8, meta.text, "\"deny_warnings\": True") != null);
    try t.expect(std.mem.indexOf(u8, meta.text, "\"clippy_conf\": \"clippy.toml\"") != null);
    // Refusals from the manifests are refusals of the sync.
    try repo.tmp.dir.writeFile(.{ .sub_path = "crates/app/Cargo.toml", .data = app_manifest ++ "[package.metadata.buildrules]\nprofile = 1\n" });
    try generateRefused(&e, repo, lock_with_itoa, json, "unknown key(s) ['profile'] in metadata.buildrules");
    try repo.tmp.dir.writeFile(.{ .sub_path = "crates/app/Cargo.toml", .data = app_manifest ++ "[lints.rust]\nx = \"loud\"\n" });
    try generateRefused(&e, repo, lock_with_itoa, json, "unknown level");
    try repo.tmp.dir.writeFile(.{ .sub_path = "crates/app/Cargo.toml", .data = app_manifest });
    try repo.tmp.dir.writeFile(.{ .sub_path = "Cargo.toml", .data = ws_manifest ++ "[workspace.metadata.buildrules]\nbogus = 1\n" });
    try generateRefused(&e, repo, lock_with_itoa, json, "unknown key(s) ['bogus']");
}

test "generate: the output of a run that fails an allocation is an error, never a table (at every allocation)" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    try repo.tmp.dir.writeFile(.{ .sub_path = "crates/app/Cargo.toml", .data = app_manifest ++ "[lints.rust]\nunused = \"warn\"\n[package.metadata.buildrules.actions]\nship = [\"release\"]\n" });
    try kit.sweepOom(GenerateCall{ .repo = repo, .lock = lock_with_itoa, .json = try repo.graph(&e, graph_app), .expect_units = 2 }, true);
}

// ---- the toolchain record, lints, features, policy: the rest of the branches ----------------------------------------------

test "toolchain: the pin of a version must name all four components with a sha256, and the pins file must say which it defaults to" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    const no_clippy = "EXTRA_RUST_VERSIONS = {\n    \"1.86.0\": {\"rustc\": {\"sha256\": \"" ++ H ++ "\"}, \"rust_std\": {\"sha256\": \"" ++ H ++ "\"}, \"cargo\": {\"sha256\": \"" ++ H ++ "\"}},\n}\n";
    try t.expectError(error.Refused, unitgen.resolveToolchain(e.a(), &d, "1.86.0", pins, no_clippy));
    try refusedWith(&d, "the pin of rustc 1.86.0 has no clippy");
    var d2 = Diag.init(e.a());
    const no_sha = "EXTRA_RUST_VERSIONS = {\n    \"1.86.0\": {\"cargo\": {\"size\": 1}},\n}\n";
    try t.expectError(error.Refused, unitgen.resolveToolchain(e.a(), &d2, "1.86.0", pins, no_sha));
    try refusedWith(&d2, "the pin of rustc 1.86.0: cargo has no sha256");
    var d3 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolveToolchain(e.a(), &d3, "1.86.0", pins, "OTHER = 1\n"));
    try refusedWith(&d3, "no EXTRA_RUST_VERSIONS");
    var d4 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolveToolchain(e.a(), &d4, "1.86.0", pins, "EXTRA_RUST_VERSIONS = oops()\n"));
    try refusedWith(&d4, "EXTRA_RUST_VERSIONS is not a literal");
    var d5 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolveToolchain(e.a(), &d5, "1.95.0", "RUST_VERSIONS = {}\n", null));
    try refusedWith(&d5, "no RUST_DEFAULT");
    var d6 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolveToolchain(e.a(), &d6, "1.95.0", "RUST_VERSIONS = {}\nRUST_DEFAULT = oops()\n", null));
    try refusedWith(&d6, "RUST_DEFAULT is not a literal");
    // A table of no versions says none are known (and a table that is not a table says the same).
    var d7 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolveToolchain(e.a(), &d7, "1.95.0", "RUST_VERSIONS = {}\nRUST_DEFAULT = \"1.95.0\"\n", null));
    try refusedWith(&d7, "(it pins )");
    var d8 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolveToolchain(e.a(), &d8, "1.95.0", "RUST_VERSIONS = [1]\nRUST_DEFAULT = \"1.95.0\"\n", null));
    try refusedWith(&d8, "(it pins )");
    // The record names the default: true for the default version only.
    const default_rec = try unitgen.resolveToolchain(e.a(), &d8, "1.95.0", "RUST_VERSIONS = {\"1.95.0\": {\"cargo\": {\"sha256\": \"a\"}, \"clippy\": {\"sha256\": \"a\"}, \"rust_std\": {\"sha256\": \"a\"}, \"rustc\": {\"sha256\": \"a\"}}}\nRUST_DEFAULT = 7\n", null);
    try t.expect(!val.get(default_rec, "default").?.bool);
}

test "lints: a lint given as a table with a priority, a table without a level, a priority that is not a number, a value that is neither, and tools that are not tables" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    const ok = try unitgen.lintFlags(e.a(), &d, try tomlOf(e.a(), "[rust]\nb = { level = \"forbid\", priority = 2 }\na = { level = \"force-warn\" }\nc = \"allow\"\n[clippy]\nd = \"deny\"\n"), "t");
    try t.expectEqualStrings("[\"-A\", \"c\", \"--force-warn\", \"a\", \"-F\", \"b\"]", try val.litString(e.a(), val.get(ok, "rust").?, 0));
    try t.expectEqualStrings("[\"-D\", \"clippy::d\"]", try val.litString(e.a(), val.get(ok, "clippy").?, 0));
    const empty = try unitgen.lintFlags(e.a(), &d, try tomlOf(e.a(), "rust = 1\nclippy = []\n"), "t");
    try t.expectEqualStrings("[]", try val.litString(e.a(), val.get(empty, "rust").?, 0));
    const none = try unitgen.lintFlags(e.a(), &d, null, "t");
    try t.expectEqualStrings("[]", try val.litString(e.a(), val.get(none, "clippy").?, 0));
    const cases = [_]struct { text: []const u8, needle: []const u8 }{
        .{ .text = "[rust]\nx = { level = \"warn\", priority = \"high\" }\n", .needle = "priority is not an integer" },
        .{ .text = "[rust]\nx = { priority = 1 }\n", .needle = "unknown level ''" },
        .{ .text = "[rust]\nx = 5\n", .needle = "is not a level or a table" },
        .{ .text = "[clippy]\nunexpected_cfgs = { level = \"warn\", check-cfg = [\"cfg(y)\"] }\n", .needle = "check-cfg only belongs" },
        .{ .text = "[rust]\nother = { level = \"warn\", check-cfg = [\"cfg(y)\"] }\n", .needle = "check-cfg only belongs" },
    };
    for (cases) |c| {
        var dd = Diag.init(e.a());
        try t.expectError(error.Refused, unitgen.lintFlags(e.a(), &dd, try tomlOf(e.a(), c.text), "t"));
        try refusedWith(&dd, c.needle);
    }
}

test "features: dependency tables of every kind, a feature that names a dependency with dep:, tables that are not tables" {
    var e = Env.init();
    defer e.deinit();
    const doc = try tomlOf(e.a(),
        \\[features]
        \\a = ["dep:used", "other/feature", 3]
        \\[dependencies]
        \\used = { optional = true }
        \\plain = { version = "1" }
        \\str = "1"
        \\opt_false = { optional = false }
        \\[build-dependencies]
        \\b = { optional = true }
        \\[target.'cfg(unix)'.build-dependencies]
        \\tb = { optional = true }
        \\[target.'cfg(windows)']
        \\unrelated = 1
    );
    const names = try unitgen.declaredFeatures(e.a(), doc);
    const want = [_][]const u8{ "a", "b", "tb" };
    try t.expectEqual(want.len, names.len);
    for (want, names) |w, g| try t.expectEqualStrings(w, g);
    try t.expectEqual(@as(usize, 0), (try unitgen.declaredFeatures(e.a(), try tomlOf(e.a(), "features = 1\ndependencies = 2\ntarget = 3\n"))).len);
    try t.expectEqual(@as(usize, 0), (try unitgen.declaredFeatures(e.a(), val.newObject(e.a()))).len);
    const none = try unitgen.checkCfgFlags(e.a(), &.{});
    try t.expectEqualStrings("[\"--check-cfg\", \"cfg(docsrs,test)\", \"--check-cfg\", \"cfg(feature, values())\"]", try val.litString(e.a(), none, 0));
}

test "policy: buildrules metadata that is not a table, several unknown keys in order, the default taken from the package then the workspace" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    try t.expectEqual(@as(usize, 0), (try unitgen.policyOf(e.a(), &d, null, "w")).object.count());
    try t.expectEqual(@as(usize, 0), (try unitgen.policyOf(e.a(), &d, try tomlOf(e.a(), "other = 1\n"), "w")).object.count());
    try t.expectEqual(@as(usize, 3), (try unitgen.policyOf(e.a(), &d, try tomlOf(e.a(), "[buildrules]\nactions = {}\ndefault-action = \"ci\"\nlint = {}\n"), "w")).object.count());
    var d1 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.policyOf(e.a(), &d1, try tomlOf(e.a(), "buildrules = 1\n"), "w"));
    try refusedWith(&d1, "metadata.buildrules is not a table");
    var d2 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.policyOf(e.a(), &d2, try tomlOf(e.a(), "[buildrules]\nzeta = 1\nalpha = 2\nactions = {}\n"), "w"));
    try refusedWith(&d2, "unknown key(s) ['alpha', 'zeta']");
    const none = val.newObject(e.a());
    const from_ws = try unitgen.resolvePolicy(e.a(), &d, try tomlOf(e.a(), "default-action = \"release\"\n"), none, "w");
    try t.expectEqualStrings("release", val.getStr(from_ws, "default_action").?);
    const from_pkg = try unitgen.resolvePolicy(e.a(), &d, try tomlOf(e.a(), "default-action = \"release\"\n"), try tomlOf(e.a(), "default-action = \"ci\"\n[actions]\nci = [\"lint\"]\n"), "w");
    try t.expectEqualStrings("ci", val.getStr(from_pkg, "default_action").?);
    const absent = try unitgen.resolvePolicy(e.a(), &d, none, none, "w");
    try t.expect(val.get(absent, "default_action").? == .null);
    try t.expect(!val.get(absent, "deny_warnings").?.bool);
    var d3 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolvePolicy(e.a(), &d3, try tomlOf(e.a(), "default-action = 3\n"), none, "w"));
    try refusedWith(&d3, "default-action ? is neither");
    var d4 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolvePolicy(e.a(), &d4, try tomlOf(e.a(), "[lint]\nzeta = 1\nalpha = 2\n"), none, "w"));
    try refusedWith(&d4, "unknown lint policy key(s) ['alpha', 'zeta']");
    var d5 = Diag.init(e.a());
    try t.expectError(error.Refused, unitgen.resolvePolicy(e.a(), &d5, try tomlOf(e.a(), "[actions]\nci = \"lint\"\n"), none, "w"));
    try refusedWith(&d5, "non-empty list of steps");
}

// ---- generate: units with several dependencies, a unit twice, a dependency that is refused, the manifests' odd shapes -------------------------------------

/// Cargo's graph for `app` (unit 0) depending on unit 1 and unit 2, which are `itoa` twice with different features: edges to one extern name
/// that differ in the unit they reach.
const graph_two_deps =
    "{\"version\":1,\"units\":[" ++
    "{\"pkg_id\":\"path+file://@ROOT@/crates/app#0.1.0\",\"target\":{\"kind\":[\"lib\"],\"crate_types\":[\"lib\"],\"name\":\"app\"," ++
    "\"src_path\":\"@ROOT@/crates/app/src/lib.rs\",\"edition\":\"2021\",\"doctest\":true,\"test\":true}," ++
    "\"profile\":" ++ profile_dev ++ ",\"platform\":\"x86_64-unknown-linux-gnu\",\"mode\":\"build\",\"features\":[]," ++
    "\"dependencies\":[{\"index\":2,\"extern_crate_name\":\"itoa\"},{\"index\":1,\"extern_crate_name\":\"itoa\"},{\"index\":1,\"extern_crate_name\":\"a_first\"}]}," ++
    "{\"pkg_id\":\"registry+https://github.com/rust-lang/crates.io-index#itoa@1.0.15\",\"target\":{\"kind\":[\"lib\"],\"crate_types\":[\"lib\"],\"name\":\"itoa\"," ++
    "\"src_path\":\"@ROOT@/cargo/registry/src/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15/src/lib.rs\",\"edition\":\"2018\",\"doctest\":true,\"test\":true}," ++
    "\"profile\":" ++ profile_dev ++ ",\"platform\":\"x86_64-unknown-linux-gnu\",\"mode\":\"build\",\"features\":[\"std\"],\"dependencies\":[]}," ++
    "{\"pkg_id\":\"registry+https://github.com/rust-lang/crates.io-index#itoa@1.0.15\",\"target\":{\"kind\":[\"lib\"],\"crate_types\":[\"lib\"],\"name\":\"itoa\"," ++
    "\"src_path\":\"@ROOT@/cargo/registry/src/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15/src/lib.rs\",\"edition\":\"2018\",\"doctest\":true,\"test\":true}," ++
    "\"profile\":" ++ profile_dev ++ ",\"platform\":\"x86_64-unknown-linux-gnu\",\"mode\":\"build\",\"features\":[\"std\",\"alloc\"],\"dependencies\":[]}," ++
    "{\"pkg_id\":\"registry+https://github.com/rust-lang/crates.io-index#itoa@1.0.15\",\"target\":{\"kind\":[\"lib\"],\"crate_types\":[\"lib\"],\"name\":\"itoa\"," ++
    "\"src_path\":\"@ROOT@/cargo/registry/src/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15/src/lib.rs\",\"edition\":\"2018\",\"doctest\":true,\"test\":true}," ++
    "\"profile\":" ++ profile_dev ++ ",\"platform\":\"x86_64-unknown-linux-gnu\",\"mode\":\"build\",\"features\":[\"std\"],\"dependencies\":[]}" ++
    "],\"roots\":[0]}";

test "generate: a unit with several dependencies lists them by extern name and then by unit; the same unit written twice is one entry" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    const res = try GenerateOk.run(&e, repo, lock_with_itoa, try repo.graph(&e, graph_two_deps));
    // app, itoa[std], itoa[std,alloc]: unit 3 repeats unit 1, so it is not a fourth entry.
    try t.expectEqual(@as(usize, 3), res.units.object.count());
    var deps_text: []const u8 = "";
    for (res.units.object.values()) |u| {
        if (std.mem.eql(u8, val.getStr(u, "crate").?, "app")) deps_text = try val.litString(e.a(), val.get(u, "deps").?, 0);
    }
    // a_first < itoa; of the two itoa edges, the lower unit id comes first: the unit with the features [std] has the id that sorts first or second, never unsorted.
    try t.expect(std.mem.indexOf(u8, deps_text, "[\"a_first\", \"itoa-1.0.15:") != null);
    const first_itoa = std.mem.indexOf(u8, deps_text, "[\"itoa\", \"").?;
    const second_itoa = std.mem.indexOfPos(u8, deps_text, first_itoa + 1, "[\"itoa\", \"").?;
    const id1 = deps_text[first_itoa + 10 .. std.mem.indexOfScalarPos(u8, deps_text, first_itoa + 10, '"').?];
    const id2 = deps_text[second_itoa + 10 .. std.mem.indexOfScalarPos(u8, deps_text, second_itoa + 10, '"').?];
    try t.expect(std.mem.lessThan(u8, id1, id2));
    // The graphs count the unit twice: units is the distinct ones, graph_units the raw count.
    try t.expect(std.mem.indexOf(u8, res.text, "\"graph_units\": 4") != null);
    try t.expect(std.mem.indexOf(u8, res.text, "\"units\": 3") != null);
}

test "generate: a dependency that is refused is refused through the unit that needs it" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    // app is unit 0 and needs unit 1, which has no profile: the refusal comes up through app's resolution.
    const broken = try std.mem.replaceOwned(u8, e.a(), graph_two_deps, "\"edition\":\"2018\",\"doctest\":true,\"test\":true},\"profile\":" ++ profile_dev, "\"edition\":\"2018\",\"doctest\":true,\"test\":true},\"prof\":" ++ profile_dev);
    try generateRefused(&e, repo, lock_with_itoa, try repo.graph(&e, broken), "itoa 1.0.15: a unit has no profile");
}

test "generate: incremental compilation is refused naming the profile, `dev` when the profile has no name" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    const nameless = try swapped(&e, repo, "\"name\":\"dev\",\"opt_level\":\"0\",\"lto\":\"false\",\"codegen_backend\":null,\"codegen_units\":null,\"debuginfo\":2,\"split_debuginfo\":null,\"debug_assertions\":true,\"overflow_checks\":true,\"rpath\":false,\"incremental\":false", "\"opt_level\":\"0\",\"lto\":\"false\",\"codegen_backend\":null,\"codegen_units\":null,\"debuginfo\":2,\"split_debuginfo\":null,\"debug_assertions\":true,\"overflow_checks\":true,\"rpath\":false,\"incremental\":true");
    try generateRefused(&e, repo, lock_with_itoa, nameless, "the `dev` profile has incremental compilation on");
    const named = try swapped(&e, repo, "\"name\":\"dev\",\"opt_level\":\"0\",\"lto\":\"false\",\"codegen_backend\":null,\"codegen_units\":null,\"debuginfo\":2,\"split_debuginfo\":null,\"debug_assertions\":true,\"overflow_checks\":true,\"rpath\":false,\"incremental\":false", "\"name\":\"fast\",\"opt_level\":\"0\",\"lto\":\"false\",\"codegen_backend\":null,\"codegen_units\":null,\"debuginfo\":2,\"split_debuginfo\":null,\"debug_assertions\":true,\"overflow_checks\":true,\"rpath\":false,\"incremental\":true");
    try generateRefused(&e, repo, lock_with_itoa, named, "the `fast` profile has incremental compilation on");
}

test "generate: a graph without a version, a root manifest without [workspace], a member without [package], lints.workspace with no workspace lints" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e, lock_with_itoa);
    defer repo.tmp.cleanup();
    try generateRefused(&e, repo, lock_with_itoa, "{\"units\":[],\"roots\":[]}", "unit graph version is not 1");
    const json = try repo.graph(&e, graph_app);
    try repo.tmp.dir.writeFile(.{ .sub_path = "Cargo.toml", .data = "# a root with nothing in it\n" });
    const bare = try GenerateOk.run(&e, repo, lock_with_itoa, json);
    try t.expectEqual(@as(usize, 2), bare.units.object.count());
    try repo.tmp.dir.writeFile(.{ .sub_path = "Cargo.toml", .data = ws_manifest });
    try repo.tmp.dir.writeFile(.{ .sub_path = "crates/app/Cargo.toml", .data = "[lib]\npath = \"src/lib.rs\"\n[lints]\nworkspace = true\n" });
    const no_package = try GenerateOk.run(&e, repo, lock_with_itoa, json);
    try t.expect(std.mem.indexOf(u8, no_package.text, "\"rust\": []") != null);
    try t.expect(std.mem.indexOf(u8, no_package.text, "\"clippy\": []") != null);
    try t.expect(std.mem.indexOf(u8, no_package.text, "\"clippy_conf\": None") != null);
}
