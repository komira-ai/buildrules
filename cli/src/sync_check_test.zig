//! `buildrules sync` and `buildrules check`. The fixture is the output of a real run (init, cargo new
//! crates/hello, sync) against the pinned cargo and the generator; the tests turn it into repositories
//! and break them one way at a time. Every test is named for the defect it catches.

const std = @import("std");
const buckgen = @import("buckgen.zig");
const contract = @import("contract.zig");
const ctxm = @import("ctx.zig");
const kit = @import("testkit.zig");
const pins_toml = @import("pins_toml.zig");
const t = std.testing;

const fx = struct {
    const root_cargo = @embedFile("fixture/root.Cargo.toml");
    const cargo_lock = @embedFile("fixture/Cargo.lock");
    const hello_cargo = @embedFile("fixture/hello.Cargo.toml");
    const toolchain = @embedFile("fixture/rust-toolchain.toml");
    const table = @embedFile("fixture/buildrules.lock.bzl");
    const third_party = @embedFile("fixture/third_party.BUCK");
    const sizes = @embedFile("fixture/crate_sizes.tsv");
    const hello_buck = @embedFile("fixture/hello.BUCK");
    const root_buck = @embedFile("fixture/root.BUCK");
    const bzl = @embedFile("fixture/buildrules.bzl");
    const graph_build = @embedFile("fixture/hello.build.graph.json");
    const graph_test = @embedFile("fixture/hello.test.graph.json");
    const graph_release = @embedFile("fixture/hello.release.graph.json");
    const rust_pins = @embedFile("fixture/rules_rust_pins.bzl.fixture");
};

/// A repository exactly as `sync` leaves it.
fn synced() !*kit.Harness {
    const h = try kit.Harness.create();
    try h.put(".buckconfig", "[cells]\n");
    try h.put("Cargo.toml", fx.root_cargo);
    try h.put("Cargo.lock", fx.cargo_lock);
    try h.put("crates/hello/Cargo.toml", fx.hello_cargo);
    try h.put("crates/hello/BUCK", fx.hello_buck);
    try h.put("rust-toolchain.toml", fx.toolchain);
    try h.put("buildrules.lock.bzl", fx.table);
    try h.put("buildrules.bzl", fx.bzl);
    try h.put("toolchains/rust_pins.bzl", pins_toml.empty);
    try h.put("BUCK", fx.root_buck);
    try h.put("third_party/buildrules/BUCK", fx.third_party);
    try h.put("third_party/buildrules/crate_sizes.tsv", fx.sizes);
    return h;
}

/// A repository before the first sync: cargo's files and the BUCK file of the member.
fn fresh() !*kit.Harness {
    const h = try kit.Harness.create();
    try h.put(".buckconfig", "[cells]\n");
    try h.put("Cargo.toml", fx.root_cargo);
    try h.put("Cargo.lock", fx.cargo_lock);
    try h.put("crates/hello/Cargo.toml", fx.hello_cargo);
    try h.put("crates/hello/BUCK", fx.hello_buck);
    try h.put("rust-toolchain.toml", fx.toolchain);
    return h;
}

// ---- check ---------------------------------------------------------------------------------------

test "check: a repository as sync left it is in sync (exit 0)" {
    const h = try synced();
    defer h.destroy();
    const r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, "ok: rustc 1.95.0"));
    try t.expectEqualStrings("", r.err);
}

test "check: an edited Cargo.lock is stale, and both hashes are printed" {
    const h = try synced();
    defer h.destroy();
    try h.put("Cargo.lock", try std.mem.concat(h.a(), u8, &.{ fx.cargo_lock, "# edited\n" }));
    const r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "Cargo.lock changed since `buildrules sync`"));
    try t.expect(kit.contains(r.err, "recorded sha256 "));
    try t.expect(kit.contains(r.err, "buildrules sync"));
}

test "check: a member's Cargo.toml edited without a sync is stale (the planted-dependency case)" {
    const h = try synced();
    defer h.destroy();
    try h.put("crates/hello/Cargo.toml", try std.mem.concat(h.a(), u8, &.{ fx.hello_cargo, "\n[dependencies]\nitoa = \"1\"\n" }));
    const r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "crates/hello/Cargo.toml changed since"));
}

test "check: the root Cargo.toml is hashed too (a profile or policy edit is stale)" {
    const h = try synced();
    defer h.destroy();
    try h.put("Cargo.toml", try std.mem.concat(h.a(), u8, &.{ fx.root_cargo, "\n[profile.release]\nlto = true\n" }));
    const r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "STALE: Cargo.toml changed"));
}

test "check: a compiler bump in rust-toolchain.toml is stale even though it is an exact release" {
    const h = try synced();
    defer h.destroy();
    try h.put("rust-toolchain.toml", "[toolchain]\nchannel = \"1.96.0\"\n");
    const r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pins 1.96.0 but buildrules.lock.bzl was synced for 1.95.0"));
}

test "check: a floating channel, a toolchain path and a missing rust-toolchain.toml are refused" {
    const h = try synced();
    defer h.destroy();
    for ([_][]const u8{ "stable", "1.95", "nightly-2026-10-01" }) |ch| {
        try h.put("rust-toolchain.toml", try std.fmt.allocPrint(h.a(), "[toolchain]\nchannel = \"{s}\"\n", .{ch}));
        const r = h.run(&.{"check"});
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, "not an exact release"));
    }
    try h.put("rust-toolchain.toml", "[toolchain]\nchannel = \"1.95.0\"\npath = \"/opt/rust\"\n");
    var r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "`path` names a toolchain on this machine"));
    try h.put("rust-toolchain.toml", "[toolchain]\ncomponents = []\n");
    r = h.run(&.{"check"});
    try t.expect(kit.contains(r.err, "no `channel"));
    try h.tmp.dir.deleteFile("rust-toolchain.toml");
    r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "rust-toolchain.toml is missing"));
}

test "check: a member added to the workspace without a sync is a new input; a removed one is reported" {
    const h = try synced();
    defer h.destroy();
    try h.put("crates/extra/Cargo.toml", "[package]\nname = \"extra\"\nversion = \"0.1.0\"\n");
    try h.put("crates/extra/BUCK", fx.hello_buck);
    try h.put("Cargo.toml", "[workspace]\nmembers = [\"crates/hello\", \"crates/extra\"]\n");
    var r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "crates/extra/Cargo.toml is a new input (a new member?)"));
    try h.put("Cargo.toml", "[workspace]\nmembers = []\n");
    r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "crates/hello/Cargo.toml is in the table but no longer in the workspace"));
}

test "check: a missing table, a missing Cargo.lock and a hand-edited wrapper are each exit 1" {
    const h = try synced();
    defer h.destroy();
    try h.tmp.dir.deleteFile("buildrules.lock.bzl");
    var r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "buildrules.lock.bzl is missing"));
    try h.put("buildrules.lock.bzl", fx.table);
    try h.tmp.dir.deleteFile("Cargo.lock");
    r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "Cargo.lock is missing"));
    try h.put("Cargo.lock", fx.cargo_lock);
    try h.put("buildrules.bzl", try std.mem.concat(h.a(), u8, &.{ fx.bzl, "# edited\n" }));
    r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "buildrules.bzl is not what sync writes"));
}

test "check: a table of another schema is refused, not half-read" {
    const h = try synced();
    defer h.destroy();
    const old = try std.mem.replaceOwned(u8, h.a(), fx.table, "SCHEMA = 2\n", "SCHEMA = 1\n");
    try h.put("buildrules.lock.bzl", old);
    const r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "SCHEMA = 1, but this buildrules reads schema 2"));
}

test "check: a member without a cargo_package call, and a root BUCK without cargo_workspace, are reported with the fix" {
    const h = try synced();
    defer h.destroy();
    try h.put("crates/hello/BUCK", "# nothing\n");
    try h.put("BUCK", "# nothing\n");
    const r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "crates/hello/BUCK has no cargo_package call: run `buildrules cargo adopt crates/hello`"));
    try t.expect(kit.contains(r.err, "BUCK has no cargo_workspace call"));
}

test "check: every problem is reported in one run" {
    const h = try synced();
    defer h.destroy();
    try h.put("Cargo.lock", "version = 4\n");
    try h.put("crates/hello/Cargo.toml", "[package]\nname = \"hello\"\n");
    try h.put("rust-toolchain.toml", "[toolchain]\nchannel = \"1.96.0\"\n");
    const r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.count(r.err, "STALE") >= 4);
}

test "check: usage errors exit 2" {
    const h = try synced();
    defer h.destroy();
    try t.expectEqual(@as(u8, 2), h.run(&.{ "check", "--bogus" }).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "check", "--dir" }).code);
}

// ---- sync: a fake cargo and buck2 behind the exec seam; the generator is the real one -----------------

var calls: [64][]const u8 = undefined;
var n_calls: usize = 0;
var fail_when: []const u8 = "";
var lock_missing_text: []const u8 = fx.cargo_lock;
var fetched: usize = 0;
/// What the fakes do instead of answering: an error from the exec seam for the command line that holds `error_when`, other output of buck2, another graph.
var error_when: []const u8 = "";
var buck2_out: ?[]const u8 = null;
var graph_text: ?[]const u8 = null;

fn joinArgs(ctx: *ctxm.Ctx, spec: ctxm.Exec) ![]const u8 {
    var o = std.ArrayList(u8).empty;
    for (spec.env) |kv| try o.print(ctx.a, "{s}={s} ", .{ kv[0], kv[1] });
    for (spec.argv, 0..) |x, i| {
        if (i != 0) try o.append(ctx.a, ' ');
        try o.appendSlice(ctx.a, x);
    }
    return o.toOwnedSlice(ctx.a);
}

/// The unit graph real cargo prints for the hello package: `@ROOT@` is the repository's absolute path.
fn helloGraph(ctx: *ctxm.Ctx, spec: ctxm.Exec) ![]const u8 {
    const verb = spec.argv[1];
    var release = false;
    for (spec.argv) |x| {
        if (std.mem.eql(u8, x, "--release")) release = true;
    }
    const template = graph_text orelse if (std.mem.eql(u8, verb, "test")) fx.graph_test else if (release) fx.graph_release else fx.graph_build;
    const root = try ctx.dir.realpathAlloc(ctx.a, ".");
    return std.mem.replaceOwned(u8, ctx.a, template, "@ROOT@", root);
}

/// The Rust version table, as a file `buck2 build` would name.
fn pinsFile(ctx: *ctxm.Ctx) ![]const u8 {
    try ctx.write("fake/pins.bzl", fx.rust_pins);
    return ctx.dir.realpathAlloc(ctx.a, "fake/pins.bzl");
}

fn fakeExec(ctx: *ctxm.Ctx, spec: ctxm.Exec) anyerror!ctxm.ExecResult {
    const line = try joinArgs(ctx, spec);
    // A replay (testkit.zig) runs the command on a copy; only the run the test made is on the record.
    if (!kit.replaying) {
        calls[n_calls] = line;
        n_calls += 1;
    }
    if (fail_when.len > 0 and std.mem.indexOf(u8, line, fail_when) != null) return .{ .code = 7 };
    if (error_when.len > 0 and std.mem.indexOf(u8, line, error_when) != null) return error.FileNotFound;
    const a0 = spec.argv[0];
    if (std.mem.endsWith(u8, a0, "buck2")) {
        if (buck2_out) |out| return .{ .code = 0, .stdout = out };
        // The toolchain targets load toolchains/rust_pins.bzl: it must exist before buck2 is asked for them.
        if (!ctx.exists("toolchains/rust_pins.bzl")) return .{ .code = 9 };
        // `buck2 build <cargo label> <sysroot label> <pins file> --show-full-output`: answer for the labels asked.
        return .{ .code = 0, .stdout = try std.fmt.allocPrint(ctx.a, "{s} /fake/cargo\n{s} /fake/sysroot\n{s} {s}\n", .{ spec.argv[2], spec.argv[3], spec.argv[4], try pinsFile(ctx) }) };
    }
    if (std.mem.endsWith(u8, a0, "cargo")) {
        if (std.mem.eql(u8, spec.argv[1], "fetch") and !ctx.exists("Cargo.lock")) try ctx.write("Cargo.lock", lock_missing_text);
        if (spec.capture) return .{ .code = 0, .stdout = try helloGraph(ctx, spec) };
        return .{ .code = 0 };
    }
    return .{ .code = 99 };
}

fn noNetwork(_: std.mem.Allocator, url: []const u8) anyerror!@import("fetch.zig").Digest.Result {
    if (!kit.replaying) fetched += 1;
    std.debug.print("unexpected download of {s}\n", .{url});
    return error.NoNetworkInThisTest;
}

fn withExec(h: *kit.Harness) void {
    h.ctx.execer = &fakeExec;
    n_calls = 0;
    fail_when = "";
    error_when = "";
    buck2_out = null;
    graph_text = null;
    lock_missing_text = fx.cargo_lock;
    fetched = 0;
    buckgen.fetcher = &noNetwork;
}

fn called(needle: []const u8) usize {
    var n: usize = 0;
    for (calls[0..n_calls]) |c| {
        if (std.mem.indexOf(u8, c, needle) != null) n += 1;
    }
    return n;
}

test "sync: asks buck2 for the pinned tools, captures three unit graphs per member, generates the table in process, writes the glue" {
    // The golden: the table, the sizes and the third-party package the generator writes from cargo's graphs are, byte for byte,
    // the files a real run produced (the Python generator this one replaced wrote them); the content ids of the three units are
    // the hash of their bodies, so a changed field, order or escape anywhere in the chain turns this red.
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    const r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), r.code);
    // buck2 builds the toolchain pieces and the version table, once.
    try t.expectEqual(@as(usize, 1), called("./buck2 build toolchains//:cargo_1_95_0 toolchains//:sysroot_1_95_0 buildrules//rules/rust:pins.bzl --show-full-output"));
    // cargo: fetch, then one unit graph per verb; all four on the pinned rustc, the graphs also under RUSTC_BOOTSTRAP (the unstable flag).
    try t.expectEqual(@as(usize, 1), called("/fake/cargo/bin/cargo fetch"));
    try t.expectEqual(@as(usize, 0), called("fetch --locked"));
    try t.expectEqual(@as(usize, 3), called("RUSTC_BOOTSTRAP=1"));
    try t.expectEqual(@as(usize, 4), called("RUSTC=/fake/sysroot/bin/rustc "));
    try t.expectEqual(@as(usize, 1), called("/fake/cargo/bin/cargo build -p hello --locked --offline --target x86_64-unknown-linux-gnu -Z unstable-options --unit-graph"));
    try t.expectEqual(@as(usize, 1), called("/fake/cargo/bin/cargo test -p hello --locked --offline"));
    try t.expectEqual(@as(usize, 1), called("/fake/cargo/bin/cargo build --release -p hello --locked --offline"));
    // Nothing else is run: no interpreter, no generator process.
    try t.expectEqual(@as(usize, 1 + 1 + 3), n_calls);
    // What this command writes itself is the contract's text, byte for byte.
    try t.expectEqualStrings(contract.bzl_text, h.read("buildrules.bzl"));
    try t.expectEqualStrings(contract.workspace_buck, h.read("BUCK"));
    try t.expectEqualStrings(fx.table, h.read("buildrules.lock.bzl"));
    try t.expectEqualStrings(fx.third_party, h.read("third_party/buildrules/BUCK"));
    try t.expectEqualStrings(fx.sizes, h.read("third_party/buildrules/crate_sizes.tsv"));
    try t.expectEqual(@as(usize, 0), fetched);
    // And the repository it leaves passes check.
    try t.expectEqual(@as(u8, 0), h.run(&.{"check"}).code);
}

test "sync: third_party/buildrules/overrides.json, when the repository has one, is read; a bad one stops the sync" {
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    try h.put("third_party/buildrules/overrides.json", "{\"crates\": {}}\n");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "sync", "--buck2", "./buck2" }).code);
    try h.put("third_party/buildrules/overrides.json", "{\"crates\": {\"itoa 1.0.15\": {\"drop_build_script\": true}}}\n");
    const r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "`why` is required"));
}

test "sync with --cargo --rustc --pins never starts buck2" {
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    const pins = try pinsFile(&h.ctx);
    const r = h.run(&.{ "sync", "--cargo", "/p/cargo", "--rustc", "/p/rustc", "--pins", pins });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqual(@as(usize, 0), called("buck2"));
    try t.expectEqual(@as(usize, 4), called("RUSTC=/p/rustc "));
    try t.expectEqualStrings(fx.table, h.read("buildrules.lock.bzl"));
}

test "sync: --python and --unitgen are gone: the generator is part of the program, so nothing names an interpreter" {
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "sync", "--python", "py" }).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "sync", "--unitgen", "/p/ug" }).code);
    try t.expectEqual(@as(usize, 0), n_calls);
}

test "sync: a second run rewrites nothing, and a user's own root BUCK is kept" {
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    try h.put("BUCK", "load(\"//:buildrules.bzl\", \"cargo_workspace\")\n\ncargo_workspace(path = \".\")\n\n# mine\n");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "sync", "--buck2", "./buck2" }).code);
    try t.expect(kit.contains(h.read("BUCK"), "# mine"));
    const r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, "buildrules.bzl is up to date"));
}

test "sync: cargo fetch (not --locked) resolves: it creates a missing Cargo.lock and is the only cargo call that may change it" {
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    try h.tmp.dir.deleteFile("Cargo.lock");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "sync", "--buck2", "./buck2" }).code);
    try t.expectEqual(@as(usize, 1), called("/fake/cargo/bin/cargo fetch"));
    try t.expect(h.has("Cargo.lock"));
    // every call after the resolution is locked and offline
    try t.expectEqual(@as(usize, 3), called("--locked --offline"));
}

test "sync: registry crates in Cargo.lock get no unit graph of their own, only the workspace packages do" {
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    try h.put("Cargo.lock", "version = 4\n\n[[package]]\nname = \"hello\"\nversion = \"0.1.0\"\ndependencies = [\n \"itoa\",\n]\n\n[[package]]\nname = \"itoa\"\nversion = \"1.0.15\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\nchecksum = \"4a5f13b858c8d314ee3e8f639011f7ccefe71f97f96e50151fb991f267928e2c\"\n");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "sync", "--buck2", "./buck2" }).code);
    try t.expectEqual(@as(usize, 3), called("--unit-graph"));
    try t.expectEqual(@as(usize, 0), called("-p itoa"));
}

test "sync: a precondition that fails runs nothing and writes nothing" {
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    // not at a repository root
    try h.tmp.dir.deleteFile(".buckconfig");
    var r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "no .buckconfig here"));
    try h.put(".buckconfig", "[cells]\n");
    // a floating compiler
    try h.put("rust-toolchain.toml", "[toolchain]\nchannel = \"stable\"\n");
    r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "not an exact release"));
    try h.put("rust-toolchain.toml", fx.toolchain);
    // a member nobody gave a BUCK file, and a root that is a package
    try h.put("crates/hello/BUCK", "");
    r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "run `buildrules cargo adopt crates/hello`"));
    try h.put("crates/hello/BUCK", fx.hello_buck);
    try h.put("Cargo.toml", "[package]\nname = \"x\"\n[workspace]\nmembers = []\n");
    r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "is a package"));
    // a root BUCK that is not ours to extend
    try h.put("Cargo.toml", fx.root_cargo);
    try h.put("BUCK", "# empty\n");
    r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "BUCK has no cargo_workspace call"));
    try t.expectEqual(@as(usize, 0), n_calls);
    try t.expect(!h.has("buildrules.bzl"));
    try t.expect(!h.has("buildrules.lock.bzl"));
}

test "sync: a failing cargo, generator or buck2 is exit 1 and the glue is not written" {
    const steps = [_][]const u8{ "buck2 build", "cargo fetch", "cargo test -p hello" };
    for (steps) |s| {
        const h = try fresh();
        defer h.destroy();
        withExec(h);
        fail_when = s;
        const r = h.run(&.{ "sync", "--buck2", "./buck2" });
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, "exited") or kit.contains(r.err, "7"));
        try t.expect(!h.has("buildrules.bzl"));
        try t.expect(!h.has("BUCK"));
    }
}

test "sync --check: fresh files are exit 0 and nothing outside buck-out is written; a hand-edited table is exit 1" {
    const h = try synced();
    defer h.destroy();
    withExec(h);
    var r = h.run(&.{ "sync", "--check", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, "every generated file is up to date"));
    // The sizes (the network) are not fetched in --check; the committed sizes are the input.
    try t.expectEqual(@as(usize, 0), fetched);
    try t.expect(h.has("buck-out/buildrules/check/buildrules.lock.bzl"));
    try h.put("buildrules.lock.bzl", try std.mem.concat(h.a(), u8, &.{ fx.table, "# edited\n" }));
    n_calls = 0;
    r = h.run(&.{ "sync", "--check", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "buildrules.lock.bzl is not what the inputs generate"));
    try t.expectEqualStrings(try std.mem.concat(h.a(), u8, &.{ fx.table, "# edited\n" }), h.read("buildrules.lock.bzl"));
}

test "sync --check: a stale third-party package or wrapper is exit 1" {
    const h = try synced();
    defer h.destroy();
    withExec(h);
    try h.put("third_party/buildrules/BUCK", "# old\n");
    var r = h.run(&.{ "sync", "--check", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "third_party/buildrules/BUCK is not what the inputs generate"));
    try h.put("third_party/buildrules/BUCK", fx.third_party);
    try h.put("buildrules.bzl", "# old\n");
    r = h.run(&.{ "sync", "--check", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "buildrules.bzl is not what the inputs generate"));
}

test "sync: usage errors exit 2" {
    const h = try fresh();
    defer h.destroy();
    try t.expectEqual(@as(u8, 2), h.run(&.{ "sync", "--nope" }).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "sync", "--cargo" }).code);
}

const my_pins =
    "[rust.\"1.86.0\"]\n" ++
    "[rust.\"1.86.0\".rustc]\nsha256 = \"1111111111111111111111111111111111111111111111111111111111111111\"\nsize = 1\n" ++
    "[rust.\"1.86.0\".rust-std]\nsha256 = \"2222222222222222222222222222222222222222222222222222222222222222\"\nsize = 2\n" ++
    "[rust.\"1.86.0\".cargo]\nsha256 = \"3333333333333333333333333333333333333333333333333333333333333333\"\nsize = 3\n" ++
    "[rust.\"1.86.0\".clippy]\nsha256 = \"4444444444444444444444444444444444444444444444444444444444444444\"\nsize = 4\n";

test "sync: buildrules-pins.toml becomes toolchains/rust_pins.bzl, and the tools asked of buck2 are those of the pinned version" {
    // Defect caught: a version only the user pinned is built with the default's cargo and sysroot, or its toolchain targets
    // do not exist yet when buck2 is asked for them (the file must be written first), or the generator is not told of the pin.
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    try h.put("rust-toolchain.toml", "[toolchain]\nchannel = \"1.86.0\"\n");
    try h.put("buildrules-pins.toml", my_pins);
    const r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqual(@as(usize, 1), called("./buck2 build toolchains//:cargo_1_86_0 toolchains//:sysroot_1_86_0 buildrules//rules/rust:pins.bzl"));
    try t.expect(kit.contains(h.read("toolchains/rust_pins.bzl"), "\"1.86.0\": {"));
    try t.expect(kit.contains(h.read("toolchains/rust_pins.bzl"), "\"size\": 4"));
    // The generator was told of the pin: the table records the user's hashes and names the file as an input.
    const table = h.read("buildrules.lock.bzl");
    try t.expect(kit.contains(table, "RUSTC = \"1.86.0\""));
    try t.expect(kit.contains(table, "\"origin\": \"buildrules-pins.toml\""));
    try t.expect(kit.contains(table, "\"default\": False"));
    try t.expect(kit.contains(table, "\"rustc\": \"1111111111111111111111111111111111111111111111111111111111111111\""));
    try t.expect(kit.contains(table, "    \"buildrules-pins.toml\": \""));
}

test "sync: an invalid buildrules-pins.toml is reported with its line and nothing runs" {
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    try h.put("buildrules-pins.toml", "[rust.\"1.86.0\"]\ndate = \"soon\"\n");
    const r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "buildrules-pins.toml:2: unknown key `date`"));
    try t.expect(kit.contains(r.err, "component rustc needs both sha256 and size"));
    try t.expectEqual(@as(usize, 0), n_calls);
    try t.expect(!h.has("toolchains/rust_pins.bzl"));
}

test "check: a pin added to buildrules-pins.toml without a sync is stale twice (a new input, and the generated file)" {
    const h = try synced();
    defer h.destroy();
    try h.put("buildrules-pins.toml", my_pins);
    const r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "buildrules-pins.toml is a new input"));
    try t.expect(kit.contains(r.err, "toolchains/rust_pins.bzl is not what buildrules-pins.toml generates"));
}

test "check: a hand-edited toolchains/rust_pins.bzl is stale (a hash nobody reviewed in buildrules-pins.toml)" {
    const h = try synced();
    defer h.destroy();
    try h.put("toolchains/rust_pins.bzl", "EXTRA_RUST_VERSIONS = {\"9.9.9\": {}}\n");
    const r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "toolchains/rust_pins.bzl is not what buildrules-pins.toml generates"));
}

test "check: an invalid buildrules-pins.toml is reported, not silently ignored" {
    const h = try synced();
    defer h.destroy();
    try h.put("buildrules-pins.toml", "[rust.\"stable\"]\n");
    const r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "\"stable\" is not an exact release"));
}

// ---- more of sync: arguments, the tools, the steps that fail, the registry crates ------------------------------------

test "sync arguments: a flag without its value, a directory that is not there, and --dir to a repository below the working directory" {
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    for ([_][]const u8{ "--dir", "--cargo", "--rustc", "--pins", "--buck2" }) |flag| {
        const r = h.run(&.{ "sync", flag });
        try t.expectEqual(@as(u8, 2), r.code);
        try t.expect(kit.contains(r.err, "needs a value"));
    }
    var r = h.run(&.{ "sync", "--dir", "nowhere" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "cannot open nowhere"));
    try t.expectEqual(@as(usize, 0), n_calls);
    // The whole repository one directory down.
    const below = try kit.Harness.create();
    defer below.destroy();
    withExec(below);
    try below.put("sub/.buckconfig", "[cells]\n");
    try below.put("sub/Cargo.toml", fx.root_cargo);
    try below.put("sub/Cargo.lock", fx.cargo_lock);
    try below.put("sub/crates/hello/Cargo.toml", fx.hello_cargo);
    try below.put("sub/crates/hello/BUCK", fx.hello_buck);
    try below.put("sub/rust-toolchain.toml", fx.toolchain);
    r = below.run(&.{ "sync", "--dir", "sub", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(below.has("sub/buildrules.lock.bzl"));
    try t.expectEqual(@as(u8, 0), below.run(&.{ "check", "--dir", "sub" }).code);
}

test "sync: a tool given by a flag is used and not asked of buck2; the ones not given are" {
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "sync", "--cargo", "/c/cargo", "--buck2", "./buck2" }).code);
    try t.expectEqual(@as(usize, 1), called("./buck2 build"));
    try t.expectEqual(@as(usize, 1), called("/c/cargo fetch"));
    try t.expectEqual(@as(usize, 4), called("RUSTC=/fake/sysroot/bin/rustc "));
    const g = try fresh();
    defer g.destroy();
    withExec(g);
    try t.expectEqual(@as(u8, 0), g.run(&.{ "sync", "--rustc", "/r/rustc", "--pins", "fake/pins.bzl", "--buck2", "./buck2" }).code);
    try t.expectEqual(@as(usize, 4), called("RUSTC=/r/rustc "));
    try t.expectEqual(@as(usize, 1), called("/fake/cargo/bin/cargo fetch"));
}

test "sync: buck2 that prints nothing usable, fails, or cannot be started is a message that names the flags to pass" {
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    for ([_][]const u8{
        "",
        "no space here\n",
        "toolchains//:cargo_1_95_0 relative/path\ntoolchains//:sysroot_1_95_0 /abs\nbuildrules//rules/rust:pins.bzl /abs/pins.bzl\n",
        "toolchains//:cargo_1_95_0 \n",
        "other//:label /abs/x\n",
    }) |out| {
        buck2_out = out;
        const r = h.run(&.{ "sync", "--buck2", "./buck2" });
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, "could not find the pinned cargo, rustc and the Rust version table (pass --cargo, --rustc and --pins)"));
    }
    buck2_out = null;
    error_when = "buck2 build";
    var r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "cannot run ./buck2: FileNotFound (pass --cargo, --rustc and --pins instead)"));
    error_when = "";
    fail_when = "buck2 build";
    r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "exited 7. If rust-toolchain.toml names a Rust version buildrules does not pin"));
}

test "sync: a root Cargo.toml that is missing, is not a workspace, or has a glob it cannot expand is a refusal that runs nothing" {
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    try h.tmp.dir.deleteFile("Cargo.toml");
    var r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "Cargo.toml is missing"));
    try h.put("Cargo.toml", "[dependencies]\n");
    r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "Cargo.toml has no [workspace]"));
    try h.put("Cargo.toml", "[workspace]\nmembers = [\"crates/*/x\"]\n");
    r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "a `members` entry is a glob buildrules does not expand"));
    try t.expectEqual(@as(usize, 0), n_calls);
}

test "sync: cargo that cannot be started, a Cargo.lock it leaves unreadable, and one with no workspace package are refusals" {
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    error_when = "cargo fetch";
    var r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "cargo fetch: cannot run /fake/cargo/bin/cargo: FileNotFound"));
    error_when = "-p hello";
    r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "cargo build -p hello --unit-graph: FileNotFound"));
    error_when = "";
    fail_when = "cargo build --release -p hello";
    r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "cargo build -p hello --unit-graph exited 7"));
    fail_when = "";
    try h.put("Cargo.lock", "version = 2\n[[package]]\nname = \"hello\"\nversion = \"0.1.0\"\n");
    r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "Cargo.lock: lock version 2 is not 3 or 4"));
    try h.put("Cargo.lock", "version = 4\n[[package]]\nname = \"itoa\"\nversion = \"1.0.15\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\nchecksum = \"" ++ "ab" ** 32 ++ "\"\n");
    r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "Cargo.lock lists no workspace package: run `buildrules cargo new crates/NAME` first"));
}

test "sync: a compiler nobody pinned is refused by the generator with the way to pin it; a pinned one that is not the default is recorded as such" {
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    try h.put("rust-toolchain.toml", "[toolchain]\nchannel = \"1.80.0\"\n");
    var r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "rust-toolchain.toml pins rustc 1.80.0, which buildrules does not pin"));
    try t.expect(!h.has("buildrules.lock.bzl"));
    try h.put("rust-toolchain.toml", "[toolchain]\nchannel = \"1.85.0\"\n");
    r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(h.read("buildrules.lock.bzl"), "\"default\": False"));
    try t.expectEqual(@as(usize, 1), called("toolchains//:cargo_1_85_0"));
}

const itoa_sum = "4a5f13b858c8d314ee3e8f639011f7ccefe71f97f96e50151fb991f267928e2c";
const profile_dev_text =
    "{\"name\":\"dev\",\"opt_level\":\"0\",\"lto\":\"false\",\"codegen_backend\":null,\"codegen_units\":null,\"debuginfo\":2," ++
    "\"split_debuginfo\":null,\"debug_assertions\":true,\"overflow_checks\":true,\"rpath\":false,\"incremental\":false," ++
    "\"panic\":\"unwind\",\"strip\":{\"deferred\":\"None\"}}";
const graph_with_itoa =
    "{\"version\":1,\"units\":[" ++
    "{\"pkg_id\":\"registry+https://github.com/rust-lang/crates.io-index#itoa@1.0.15\",\"target\":{\"kind\":[\"lib\"],\"crate_types\":[\"lib\"],\"name\":\"itoa\"," ++
    "\"src_path\":\"@ROOT@/cargo/registry/src/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15/src/lib.rs\",\"edition\":\"2018\",\"doctest\":true,\"test\":true}," ++
    "\"profile\":" ++ profile_dev_text ++ ",\"platform\":\"x86_64-unknown-linux-gnu\",\"mode\":\"build\",\"features\":[\"std\"],\"dependencies\":[]}," ++
    "{\"pkg_id\":\"path+file://@ROOT@/crates/hello#0.1.0\",\"target\":{\"kind\":[\"lib\"],\"crate_types\":[\"lib\"],\"name\":\"hello\"," ++
    "\"src_path\":\"@ROOT@/crates/hello/src/lib.rs\",\"edition\":\"2021\",\"doctest\":true,\"test\":true}," ++
    "\"profile\":" ++ profile_dev_text ++ ",\"platform\":\"x86_64-unknown-linux-gnu\",\"mode\":\"build\",\"features\":[]," ++
    "\"dependencies\":[{\"index\":0,\"extern_crate_name\":\"itoa\",\"public\":false,\"noprelude\":false}]}" ++
    "],\"roots\":[1]}";

/// A repository whose one member depends on the registry crate itoa, whose bytes sit in the cargo registry cache `sync` looks in.
fn withRegistry(h: *kit.Harness, crate_bytes: []const u8) !void {
    withExec(h);
    graph_text = graph_with_itoa;
    const sum = try ctxm.sha256Hex(h.a(), crate_bytes);
    try h.put("Cargo.lock", try std.fmt.allocPrint(h.a(), "version = 4\n\n[[package]]\nname = \"hello\"\nversion = \"0.1.0\"\ndependencies = [\n \"itoa\",\n]\n\n[[package]]\nname = \"itoa\"\nversion = \"1.0.15\"\nsource = \"registry+https://github.com/rust-lang/crates.io-index\"\nchecksum = \"{s}\"\n", .{sum}));
    try h.put("buck-out/buildrules/cargo-home/registry/cache/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15.crate", crate_bytes);
    try h.put("cargo/registry/src/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15/Cargo.toml", "[package]\nname = \"itoa\"\nversion = \"1.0.15\"\n");
}

test "sync: a registry crate is read from the cargo cache, its size is recorded and its hash is checked against Cargo.lock; check reads the same files" {
    const h = try fresh();
    defer h.destroy();
    try withRegistry(h, "the bytes of the crate");
    const r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(h.read("third_party/buildrules/crate_sizes.tsv"), "itoa 1.0.15 22\n"));
    try t.expect(kit.contains(h.read("third_party/buildrules/BUCK"), "crate_src("));
    try t.expect(kit.contains(h.read("third_party/buildrules/BUCK"), "size_bytes = 22"));
    try t.expectEqual(@as(usize, 0), fetched);
    const c = h.run(&.{ "sync", "--check", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), c.code);
}

test "sync: a crate whose bytes are not the ones Cargo.lock pinned is refused, and so is a sizes file or an overrides file that is wrong" {
    const h = try fresh();
    defer h.destroy();
    try withRegistry(h, "the bytes of the crate");
    try h.put("buck-out/buildrules/cargo-home/registry/cache/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15.crate", "other bytes");
    var r = h.run(&.{ "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "itoa 1.0.15: sha256 "));
    try t.expect(kit.contains(r.err, "but the table (Cargo.lock) says"));
    try t.expect(!h.has("third_party/buildrules/BUCK"));
    // --check does not read the cache: the sizes file is its input.
    try h.put("buck-out/buildrules/cargo-home/registry/cache/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15.crate", "the bytes of the crate");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "sync", "--buck2", "./buck2" }).code);
    try h.put("third_party/buildrules/crate_sizes.tsv", "itoa 1.0.15 many\n");
    r = h.run(&.{ "sync", "--check", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "the sizes file: `many` is not a number"));
    try h.put("third_party/buildrules/crate_sizes.tsv", "# no crates\n");
    r = h.run(&.{ "sync", "--check", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "sizes file lacks: itoa 1.0.15"));
    try h.tmp.dir.deleteFile("third_party/buildrules/crate_sizes.tsv");
    r = h.run(&.{ "sync", "--check", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "third_party/buildrules/crate_sizes.tsv is missing: run `buildrules sync` and commit it"));
}

test "sync --check: a missing generated file is named, and so is a missing root BUCK" {
    const h = try synced();
    defer h.destroy();
    withExec(h);
    try h.tmp.dir.deleteFile("buildrules.bzl");
    try h.tmp.dir.deleteFile("BUCK");
    const r = h.run(&.{ "sync", "--check", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "buildrules.bzl is missing: run `buildrules sync` and commit it"));
    try t.expect(kit.contains(r.err, "BUCK is missing: run `buildrules sync` and commit it"));
    try h.tmp.dir.deleteFile("buildrules.lock.bzl");
    try t.expect(kit.contains(h.run(&.{ "sync", "--check", "--buck2", "./buck2" }).err, "buildrules.lock.bzl is missing"));
}

// ---- more of check ------------------------------------------------------------------------------------------------

test "check: a Cargo.toml that is missing, is a package, or has a glob it cannot expand, a missing BUCK, glue and Cargo.lock are each reported" {
    const h = try synced();
    defer h.destroy();
    try h.tmp.dir.deleteFile("Cargo.toml");
    var r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "Cargo.toml is missing"));
    try h.put("Cargo.toml", "[package]\nname = \"x\"\n[workspace]\n");
    r = h.run(&.{"check"});
    try t.expect(kit.contains(r.err, "Cargo.toml must be a virtual workspace"));
    try h.put("Cargo.toml", "[workspace]\nmembers = [\"a/*/b\"]\n");
    r = h.run(&.{"check"});
    try t.expect(kit.contains(r.err, "a `members` entry is a glob buildrules does not expand"));
    try h.put("Cargo.toml", fx.root_cargo);
    try h.tmp.dir.deleteFile("BUCK");
    try h.tmp.dir.deleteFile("buildrules.bzl");
    try h.tmp.dir.deleteFile("Cargo.lock");
    r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "BUCK is missing"));
    try t.expect(kit.contains(r.err, "buildrules.bzl is missing"));
    try t.expect(kit.contains(r.err, "Cargo.lock is missing"));
    try h.put("BUCK", fx.root_buck);
    try h.tmp.dir.deleteFile("rust-toolchain.toml");
    r = h.run(&.{"check"});
    try t.expect(kit.contains(r.err, "rust-toolchain.toml is missing"));
}

test "check: a pins file that sync recorded is an input like a manifest: edited, it is stale, and removed, it is no longer in the workspace" {
    const h = try fresh();
    defer h.destroy();
    withExec(h);
    try h.put("rust-toolchain.toml", "[toolchain]\nchannel = \"1.86.0\"\n");
    try h.put("buildrules-pins.toml", my_pins);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "sync", "--buck2", "./buck2" }).code);
    try t.expectEqual(@as(u8, 0), h.run(&.{"check"}).code);
    try h.put("buildrules-pins.toml", my_pins ++ "# edited\n");
    var r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "buildrules-pins.toml changed since `buildrules sync`"));
    try h.tmp.dir.deleteFile("buildrules-pins.toml");
    r = h.run(&.{"check"});
    try t.expect(kit.contains(r.err, "buildrules-pins.toml is in the table but no longer in the workspace"));
}

test "check: the working directory is the repository unless --dir says otherwise, and a directory that is not there is an error" {
    const h = try synced();
    defer h.destroy();
    const r = h.run(&.{ "check", "--dir", "nowhere" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "cannot open nowhere"));
    try t.expectEqual(@as(u8, 0), h.run(&.{ "check", "--dir", "." }).code);
}

test "sync: a registry crate of a compiler that is not the default names that compiler in its target; the default's targets name none" {
    const h = try fresh();
    defer h.destroy();
    try withRegistry(h, "the bytes of the crate");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "sync", "--buck2", "./buck2" }).code);
    try t.expect(!kit.contains(h.read("third_party/buildrules/BUCK"), "rustc ="));
    try h.put("rust-toolchain.toml", "[toolchain]\nchannel = \"1.85.0\"\n");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "sync", "--buck2", "./buck2" }).code);
    try t.expect(kit.contains(h.read("third_party/buildrules/BUCK"), "    rustc = \"1.85.0\","));
}
