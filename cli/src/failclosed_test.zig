//! What the command line does when an allocation fails, and what it promises about the files it writes. Each test names the defect it catches.
//!
//! A sweep runs a command with the allocator failing at its 1st, 2nd, ... allocation (and at every one after it) until a run meets no failure. A command that
//! could not allocate has not looked at everything it was asked to look at, so for a gate (`check`) an exit of 0 is a wrong answer, not a lucky one.

const std = @import("std");
const ctxm = @import("ctx.zig");
const Diag = @import("diag.zig").Diag;
const fetch = @import("fetch.zig");
const kit = @import("testkit.zig");
const lockfile = @import("lockfile.zig");
const main = @import("main.zig");
const npm = @import("npm_cmd.zig");
const pins_toml = @import("pins_toml.zig");
const toml = @import("toml.zig");
const val = @import("val.zig");
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
    const graph = @embedFile("fixture/mojo.graph.json");
    const manifest = @embedFile("fixture/mojo.mopm.toml");
    const mopm_lock = @embedFile("fixture/mojo.mopm.lock");
    const lib = @embedFile("fixture/mojo.lib.mojo");
    const test_src = @embedFile("fixture/mojo.test.mojo");
    const mojo_toolchain = "[toolchain]\nmopm = \"0.0.1\"\nmojo = \"1.0.0\"\n";
    const mojo_buck = "load(\":buildrules.mojo.bzl\", \"mojo_package\")\n\nmojo_package(path = \".\")\n";
};

// ---- the sweep ----------------------------------------------------------------------------------------------------

const Outcome = struct { code: u8, failed: bool };

/// `argv` run in the harness's directory with the allocator failing from its `index`th allocation on.
fn runFailingAt(h: *kit.Harness, argv: []const []const u8, index: usize) Outcome {
    var fa = t.FailingAllocator.init(h.a(), .{ .fail_index = index });
    var c = h.ctx;
    c.a = fa.allocator();
    h.out.clearRetainingCapacity();
    h.err.clearRetainingCapacity();
    const code = main.run(&c, argv);
    return .{ .code = code, .failed = fa.has_induced_failure };
}

/// The read-only command `argv` exits 0 with every allocation working, and exits non-zero whenever one fails.
fn expectFailsClosed(h: *kit.Harness, argv: []const []const u8) !void {
    const good = h.run(argv);
    if (good.code != 0) std.debug.panic("the command is not green to begin with: {s}", .{good.err});
    var failures: usize = 0;
    var open: usize = 0;
    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        const o = runFailingAt(h, argv, i);
        if (!o.failed) {
            if (open != 0) std.debug.print("`{s}`: {d} of {d} failed allocations ended in exit 0\n", .{ argv[0], open, failures });
            try t.expect(o.code == 0);
            return try t.expectEqual(@as(usize, 0), open);
        }
        failures += 1;
        if (o.code == 0) open += 1;
    }
    return error.SweepDidNotEnd;
}

// ---- repositories -------------------------------------------------------------------------------------------------

/// A Cargo repository exactly as `sync` leaves it.
fn cargoSynced() !*kit.Harness {
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

/// The mopm and the graph a fake `mopm plan` prints: the package that holds `graph.variant` gets a graph with another C target.
fn fakeExec(ctx: *ctxm.Ctx, spec: ctxm.Exec) anyerror!ctxm.ExecResult {
    if (std.mem.endsWith(u8, spec.argv[0], "buck2")) {
        return .{ .code = 0, .stdout = try std.fmt.allocPrint(ctx.a, "{s} /fake/mopm\n", .{spec.argv[2]}) };
    }
    if (ctx.exists("graph.variant")) {
        return .{ .code = 0, .stdout = try std.mem.replaceOwned(u8, ctx.a, fx.graph, "\"cc_target\": \"x86_64-linux-gnu.2.34\"", "\"cc_target\": \"x86_64-linux-gnu.2.28\"") };
    }
    return .{ .code = 0, .stdout = fx.graph };
}

fn putMojoPackage(h: *kit.Harness, dir: []const u8) !void {
    const a = h.a();
    try h.put(try std.fmt.allocPrint(a, "{s}/mopm.toml", .{dir}), fx.manifest);
    try h.put(try std.fmt.allocPrint(a, "{s}/mopm.lock", .{dir}), fx.mopm_lock);
    try h.put(try std.fmt.allocPrint(a, "{s}/src/base/__init__.mojo", .{dir}), fx.lib);
    try h.put(try std.fmt.allocPrint(a, "{s}/tests/test_base.mojo", .{dir}), fx.test_src);
    try h.put(try std.fmt.allocPrint(a, "{s}/BUCK", .{dir}), fx.mojo_buck);
}

/// A Mojo package before any sync.
fn mojoFresh() !*kit.Harness {
    const h = try kit.Harness.create();
    h.ctx.execer = &fakeExec;
    try h.put(".buckconfig", "[cells]\n");
    try h.put("mopm-toolchain.toml", fx.mojo_toolchain);
    try h.put("toolchains/BUCK", "# toolchains\n");
    try putMojoPackage(h, "pkgs/base");
    return h;
}

fn mojoSynced() !*kit.Harness {
    const h = try mojoFresh();
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    if (r.code != 0) std.debug.panic("sync failed: {s}", .{r.err});
    return h;
}

const sri_a = "sha512-" ++ "A" ** 86 ++ "==";

fn fakeFetch(a: std.mem.Allocator, url: []const u8) anyerror!fetch.Digest.Result {
    _ = .{ a, url };
    return .{ .sha256 = "a" ** 64, .sri512 = sri_a, .size = 11 };
}

fn npmFresh() !*kit.Harness {
    npm.fetcher = &fakeFetch;
    const h = try kit.Harness.create();
    try h.put(".buckconfig", "[cells]\n");
    try h.put("pkg/package.json",
        \\{"name":"demo","version":"1.0.0",
        \\ "scripts":{"typecheck":"tsc -p .","test":"jest","build":"tsc -p tsconfig.build.json"},
        \\ "buildrules":{"dist":"dist","actions":{"ci":["typecheck","test","build"]}}}
    );
    try h.put("pkg/package-lock.json", "{\"name\":\"demo\",\"version\":\"1.0.0\",\"lockfileVersion\":3,\"requires\":true,\"packages\":{" ++
        "\"\":{\"name\":\"demo\",\"version\":\"1.0.0\"}," ++
        "\"node_modules/left-pad\":{\"version\":\"1.3.0\",\"resolved\":\"https://registry.example/left-pad/-/left-pad-1.3.0.tgz\",\"integrity\":\"" ++ sri_a ++ "\"}}}");
    return h;
}

// ---- 2. Ctx.write -------------------------------------------------------------------------------------------------

test "Ctx.write: a rename that fails leaves no <path>.buildrules-tmp behind" {
    const h = try kit.Harness.create();
    defer h.destroy();
    // A file cannot be renamed onto a directory that is not empty.
    try h.put("blocked/keep", "x");
    if (h.ctx.write("blocked", "data")) |_| return error.WriteShouldHaveFailed else |_| {}
    try t.expect(!h.has("blocked.buildrules-tmp"));
    try t.expectEqualStrings("x", h.read("blocked/keep"));
}

// ---- 4. toml.number -----------------------------------------------------------------------------------------------

test "toml: an allocation that fails while an integer is read is an error, never the digits kept as a date string" {
    // The number is the last thing the document allocates for: the table has room for its key already, so a number that is dropped to a string by a failed
    // allocation would otherwise be stored without another allocation, and the parse would succeed.
    const docs = [_][]const u8{ "a = 1\nb = 1_000", "a = 1\nb = -42", "a = 1\nb = 0xff", "a = 1\nb = 1_000_000_000_000" };
    for (docs) |doc| {
        var i: usize = 0;
        while (i < 60) : (i += 1) {
            var ar = std.heap.ArenaAllocator.init(t.allocator);
            defer ar.deinit();
            var fa = t.FailingAllocator.init(ar.allocator(), .{ .fail_index = i });
            const p = toml.parse(fa.allocator(), doc);
            if (p.msg.len != 0) continue;
            const v = val.get(p.value, "b") orelse return error.KeyLost;
            if (v != .integer) {
                std.debug.print("`{s}`: with allocation {d} failing, `b` came out as {s}, not an integer\n", .{ doc, i, @tagName(v) });
                return error.IntegerBecameSomethingElse;
            }
        }
    }
}

// ---- 1. Diag ------------------------------------------------------------------------------------------------------

test "Diag.add: a message it cannot allocate or store is counted, and nothing it allocated is leaked" {
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        var fa = t.FailingAllocator.init(t.allocator, .{ .fail_index = i });
        var d = Diag.init(fa.allocator());
        d.add("problem {d}: {s}", .{ i, "x" ** 40 });
        d.add("another problem", .{});
        try t.expectEqual(@as(usize, 2), d.count());
        for (d.msgs.items) |m| fa.allocator().free(m);
        d.msgs.deinit(fa.allocator());
    }
}

// ---- 1. the gates fail closed -------------------------------------------------------------------------------------

test "check: with an allocation failing anywhere, a repository as sync left it is not reported in sync" {
    const h = try cargoSynced();
    defer h.destroy();
    try expectFailsClosed(h, &.{"check"});
}

test "check: the Mojo packages of a repository are checked, or the run fails, when an allocation fails" {
    const h = try mojoFresh();
    defer h.destroy();
    // The Cargo side of the repository as sync left it, beside the Mojo package (and the export `mojo sync` appends to the root BUCK file).
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
    const s = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    if (s.code != 0) std.debug.panic("sync failed: {s}", .{s.err});
    try expectFailsClosed(h, &.{"check"});
}

test "mojo check: with an allocation failing anywhere, a synced package is not reported in sync" {
    const h = try mojoSynced();
    defer h.destroy();
    try expectFailsClosed(h, &.{ "mojo", "check" });
}

test "npm sync: with an allocation failing anywhere, the exit is not 0" {
    var i: usize = 0;
    var open: usize = 0;
    while (i < 20_000) : (i += 1) {
        const h = try npmFresh();
        defer h.destroy();
        const o = runFailingAt(h, &.{ "npm", "sync", "pkg" }, i);
        if (!o.failed) {
            try t.expectEqual(@as(u8, 0), o.code);
            try t.expectEqual(@as(usize, 0), open);
            return;
        }
        if (o.code == 0) open += 1;
    }
    return error.SweepDidNotEnd;
}

// ---- 3. mojo sync -------------------------------------------------------------------------------------------------

test "mojo sync: when the toolchain table cannot be rendered, no package's table or glue (and no export) has been written" {
    const h = try mojoFresh();
    defer h.destroy();
    // A second package whose graph pins another toolchain for the same Mojo: the pins table refuses the pair, after both graphs were made.
    try putMojoPackage(h, "pkgs/other");
    try h.put("pkgs/other/graph.variant", "");
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pin different toolchains for Mojo 1.0.0"));
    for ([_][]const u8{ "pkgs/base/buildrules.mojo.lock.bzl", "pkgs/base/buildrules.mojo.bzl", "pkgs/other/buildrules.mojo.lock.bzl", "pkgs/other/buildrules.mojo.bzl", "BUCK" }) |p| {
        if (h.has(p)) {
            std.debug.print("a refused sync wrote {s}\n", .{p});
            return error.HalfASync;
        }
    }
}

// ---- 1. lockfile.parse (last: before the fix it panics, which ends the run) --------------------------------------

test "lockfile.parse: a text that is not a table is refused with an error even when the messages cannot be allocated" {
    var i: usize = 0;
    while (i < 24) : (i += 1) {
        var ar = std.heap.ArenaAllocator.init(t.allocator);
        defer ar.deinit();
        var fa = t.FailingAllocator.init(ar.allocator(), .{ .fail_index = i });
        var d = Diag.init(fa.allocator());
        try t.expectError(error.Invalid, lockfile.parse(fa.allocator(), "buildrules.lock.bzl", "# nothing\n", &d));
    }
}
