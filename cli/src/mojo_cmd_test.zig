//! `buildrules mojo sync` and `buildrules mojo check`, and the files they write. The fixture is a real package (the leaf of the
//! examples' chain) with mopm's real `plan --unit-graph` output for it; the tests turn it into repositories and break them one way
//! at a time. Every test is named for the defect it catches.

const std = @import("std");
const contract = @import("contract.zig");
const ctxm = @import("ctx.zig");
const kit = @import("testkit.zig");
const lockm = @import("mojo_lock.zig");
const mopm_pins = @import("mopm_pins.zig");
const pins_toml = @import("pins_toml.zig");
const Diag = @import("diag.zig").Diag;
const t = std.testing;

pub const fx = struct {
    pub const graph = @embedFile("fixture/mojo.graph.json");
    pub const manifest = @embedFile("fixture/mojo.mopm.toml");
    pub const mopm_lock = @embedFile("fixture/mojo.mopm.lock");
    pub const lib = @embedFile("fixture/mojo.lib.mojo");
    pub const test_src = @embedFile("fixture/mojo.test.mojo");
    pub const toolchain = "[toolchain]\nmopm = \"0.0.1\"\nmojo = \"1.0.0\"\n";
    const buck = "load(\":buildrules.mojo.bzl\", \"mojo_package\")\n\nmojo_package(path = \".\")\n";
};

var calls: [32][]const u8 = undefined;
var n_calls: usize = 0;
var plan_code: u8 = 0;
pub var plan_graph: []const u8 = fx.graph;
/// A test's own answer to a plan run (mojo_subdir_test.zig): null leaves it to the fake.
pub var plan_hook: ?*const fn (ctx: *ctxm.Ctx, spec: ctxm.Exec) ?ctxm.ExecResult = null;
/// What the fake buck2 and mopm do instead of answering: an error from the exec seam (for the program whose path ends with `exec_error_on`), a
/// non-zero exit of buck2, or other output of buck2.
var exec_error: ?anyerror = null;
var exec_error_on: []const u8 = "";
/// Let `mopm --help` (the probe) answer while the plan run fails with `exec_error`.
var exec_error_spares_help: bool = false;
var buck2_code: u8 = 0;
var buck2_stdout: ?[]const u8 = null;
var mopm_dir_seen: [32][]const u8 = undefined;
/// What the fake mopm prints for `--help` (the capability probe), and its exit code. `fresh` starts with a mopm whose help does not list
/// `--workspace-root`; `help_with` is one that does.
const help_without = "usage: mopm <command> [args]\n  plan --unit-graph --locked [--mojo <version>] [-o <file>]\n";
pub const help_with = "usage: mopm <command> [args]\n  plan --unit-graph --locked [--mojo <version>] [--workspace-root <dir>] [-o <file>]\n";
pub var help_out: []const u8 = help_without;
var help_code: u8 = 0;

fn joinArgs(ctx: *ctxm.Ctx, spec: ctxm.Exec) ![]const u8 {
    var o = std.ArrayList(u8).empty;
    for (spec.argv, 0..) |x, i| {
        if (i != 0) try o.append(ctx.a, ' ');
        try o.appendSlice(ctx.a, x);
    }
    return o.toOwnedSlice(ctx.a);
}

fn fakeExec(ctx: *ctxm.Ctx, spec: ctxm.Exec) anyerror!ctxm.ExecResult {
    // A replay (testkit.zig) runs the command on a copy; only the run the test made is on the record.
    if (!kit.replaying) {
        calls[n_calls] = try joinArgs(ctx, spec);
        // Where the command ran: the context's directory holds the package's own mopm.toml, or the root's .buckconfig.
        mopm_dir_seen[n_calls] = if (ctx.exists("mopm.toml")) "package" else "root";
        n_calls += 1;
    }
    const a0 = spec.argv[0];
    const is_help = spec.argv.len == 2 and std.mem.eql(u8, spec.argv[1], "--help");
    if (exec_error) |e| if (std.mem.endsWith(u8, a0, exec_error_on) and !(is_help and exec_error_spares_help)) return e;
    if (std.mem.endsWith(u8, a0, "buck2")) {
        // The toolchain targets load toolchains/mopm_pins.bzl and mojo_pins.bzl: they must exist before buck2 is asked.
        if (!ctx.exists("toolchains/mopm_pins.bzl") or !ctx.exists("toolchains/mojo_pins.bzl")) return .{ .code = 9 };
        if (buck2_code != 0) return .{ .code = buck2_code };
        if (buck2_stdout) |out| return .{ .code = 0, .stdout = out };
        return .{ .code = 0, .stdout = try std.fmt.allocPrint(ctx.a, "{s} /fake/mopm\n", .{spec.argv[2]}) };
    }
    // mopm --help: the capability probe
    if (spec.argv.len == 2 and std.mem.eql(u8, spec.argv[1], "--help")) {
        if (help_code != 0) return .{ .code = help_code };
        return .{ .code = 0, .stdout = help_out };
    }
    if (plan_hook) |hook| if (hook(ctx, spec)) |answer| return answer;
    // mopm plan --unit-graph --locked --mojo M
    if (plan_code != 0) return .{ .code = plan_code };
    return .{ .code = 0, .stdout = plan_graph };
}

pub fn called(needle: []const u8) usize {
    var n: usize = 0;
    for (calls[0..n_calls]) |c| {
        if (std.mem.indexOf(u8, c, needle) != null) n += 1;
    }
    return n;
}

/// The package's files, before any sync.
pub fn fresh() !*kit.Harness {
    const h = try kit.Harness.create();
    h.ctx.execer = &fakeExec;
    n_calls = 0;
    plan_code = 0;
    help_out = help_without;
    help_code = 0;
    plan_graph = fx.graph;
    plan_hook = null;
    exec_error = null;
    exec_error_spares_help = false;
    buck2_code = 0;
    buck2_stdout = null;
    try h.put(".buckconfig", "[cells]\n");
    try h.put("mopm-toolchain.toml", fx.toolchain);
    try h.put("toolchains/BUCK", "# toolchains\n");
    try h.put("pkgs/base/mopm.toml", fx.manifest);
    try h.put("pkgs/base/mopm.lock", fx.mopm_lock);
    try h.put("pkgs/base/src/base/__init__.mojo", fx.lib);
    try h.put("pkgs/base/tests/test_base.mojo", fx.test_src);
    try h.put("pkgs/base/BUCK", fx.buck);
    return h;
}

pub fn synced() !*kit.Harness {
    const h = try fresh();
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    if (r.code != 0) std.debug.panic("sync failed: {s}", .{r.err});
    n_calls = 0;
    return h;
}

// ---- sync ---------------------------------------------------------------------------------------------

test "sync: mopm's graph is written verbatim, with the glue, the toolchain table and the mopm pins table" {
    const h = try fresh();
    defer h.destroy();
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), r.code);
    const lock = h.read("pkgs/base/buildrules.mojo.lock.bzl");
    // mopm's bytes, unchanged, between the markers.
    try t.expect(kit.contains(lock, "GRAPH_JSON = r'''" ++ fx.graph ++ "'''\nGRAPH = json.decode(GRAPH_JSON)\n"));
    try t.expect(kit.contains(lock, "SCHEMA = 1\nMOPM = {\"version\": \"0.0.1\", \"origin\": \"builtin\"}\nMOJO = \"1.0.0\"\n"));
    try t.expect(kit.contains(lock, "CLOSURE_SHA256 = \"fd654c4192487587d8f8d9402d060e45e218b79da7b8964503a703710e49b15d\"\n"));
    // Every file the graph was made from, the toolchain file found two directories up included.
    try t.expect(kit.contains(lock, "\"../../mopm-toolchain.toml\": \""));
    try t.expect(kit.contains(lock, "\"mopm.lock\": \""));
    try t.expect(kit.contains(lock, "\"mopm.toml\": \""));
    try t.expectEqualStrings(contract.mojo_bzl_text, h.read("pkgs/base/buildrules.mojo.bzl"));
    const pins = h.read("toolchains/mojo_pins.bzl");
    try t.expect(kit.contains(pins, "\"1.0.0\": {\n        \"subdir\": \"linux-64\""));
    try t.expect(kit.contains(pins, "\"closure_sha256\": \"fd654c4192487587d8f8d9402d060e45e218b79da7b8964503a703710e49b15d\""));
    try t.expect(kit.contains(pins, "{\"name\": \"mojo-compiler\", \"version\": \"1.0.0\""));
    try t.expectEqualStrings(mopm_pins.empty, h.read("toolchains/mopm_pins.bzl"));
    // And the repository it leaves passes check.
    const c = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 0), c.code);
    try t.expect(kit.contains(c.out, "ok: 1 Mojo package(s)"));
}

test "sync: mopm runs in the package's directory for the Mojo version of mopm-toolchain.toml, and the pinned mopm is built by label" {
    const h = try fresh();
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    try t.expectEqual(@as(usize, 1), called("./buck2 build toolchains//:mopm_0_0_1 --show-full-output"));
    try t.expectEqual(@as(usize, 1), called("/fake/mopm plan --unit-graph --locked --mojo 1.0.0"));
    // The plan ran in the package (it reads mopm.toml and mopm.lock of the current directory), the build in the root.
    for (calls[0..n_calls], 0..) |c, i| {
        if (std.mem.indexOf(u8, c, "plan --unit-graph") != null) try t.expectEqualStrings("package", mopm_dir_seen[i]);
    }
}

test "sync with --mopm never starts buck2" {
    const h = try fresh();
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--mopm", "/p/mopm" }).code);
    try t.expectEqual(@as(usize, 0), called("buck2"));
    try t.expectEqual(@as(usize, 1), called("/p/mopm plan --unit-graph"));
}

test "sync: a second run rewrites nothing" {
    const h = try synced();
    defer h.destroy();
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, "buildrules.mojo.lock.bzl is up to date"));
    try t.expect(!kit.contains(r.out, "wrote"));
}

test "sync --check writes nothing, and says what a sync would change" {
    const h = try fresh();
    defer h.destroy();
    var r = h.run(&.{ "mojo", "sync", "--check", "--mopm", "/p/mopm" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pkgs/base/buildrules.mojo.lock.bzl is missing"));
    try t.expect(!h.has("pkgs/base/buildrules.mojo.lock.bzl"));
    try t.expect(!h.has("toolchains/mopm_pins.bzl"));
    _ = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--check", "--mopm", "/p/mopm" }).code);
    try h.put("pkgs/base/src/base/__init__.mojo", fx.lib ++ "\ndef more() -> Int:\n    return 1\n");
    // The graph mopm prints is still the old one (the fake), so a sync --check sees no difference: the sources are `check`'s.
    r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
}

test "sync: mopm's exit 3 and 4 are explained, and nothing is written" {
    const h = try fresh();
    defer h.destroy();
    plan_code = 3;
    var r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "exited 3"));
    try t.expect(kit.contains(r.err, "run `mopm lock`"));
    plan_code = 4;
    r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "exited 4"));
    try t.expect(!h.has("pkgs/base/buildrules.mojo.lock.bzl"));
    try t.expect(!h.has("pkgs/base/buildrules.mojo.bzl"));
}

test "sync: a graph for another Mojo than the one asked for is refused" {
    const h = try fresh();
    defer h.destroy();
    plan_graph = try std.mem.replaceOwned(u8, h.a(), fx.graph, "\"mojo\": \"1.0.0\",\n  \"toolchain\"", "\"mojo\": \"1.1.0\",\n  \"toolchain\"");
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "asked mopm for Mojo 1.0.0 and got a graph for 1.1.0"));
}

test "sync: without mopm-toolchain.toml, or with a floating version, nothing runs" {
    const h = try fresh();
    defer h.destroy();
    try h.tmp.dir.deleteFile("mopm-toolchain.toml");
    var r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "no mopm-toolchain.toml at or above pkgs/base"));
    try t.expect(kit.contains(r.err, "it is required, like rust-toolchain.toml"));
    try t.expect(kit.contains(r.err, "there is no default"));
    try t.expect(kit.contains(r.err, "[toolchain]\nmopm = \"0.0.48\"\nmojo = \"1.0.0\"\n"));
    for ([_][]const u8{ "0.0", "latest", "^0.0.1" }) |v| {
        try h.put("mopm-toolchain.toml", try std.fmt.allocPrint(h.a(), "[toolchain]\nmopm = \"{s}\"\nmojo = \"1.0.0\"\n", .{v}));
        r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, "an exact release"));
    }
    try h.put("mopm-toolchain.toml", "[toolchain]\nmopm = \"0.0.1\"\n");
    r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expect(kit.contains(r.err, "needs `mojo = \"N.N.N\"`"));
    try t.expectEqual(@as(usize, 0), called("plan"));
}

test "sync: a package's own mopm-toolchain.toml wins over the one above it (the nearest file, as rustup does)" {
    const h = try fresh();
    defer h.destroy();
    try h.put("pkgs/base/mopm-toolchain.toml", "[toolchain]\nmopm = \"0.0.2\"\nmojo = \"1.0.0\"\n");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--mopm", "/p/mopm" }).code);
    try t.expect(kit.contains(h.read("pkgs/base/buildrules.mojo.lock.bzl"), "MOPM = {\"version\": \"0.0.2\""));
    try t.expect(kit.contains(h.read("pkgs/base/buildrules.mojo.lock.bzl"), "\"mopm-toolchain.toml\": \""));
}

test "sync: a mopm the repository pins itself is recorded with its origin and rendered into mopm_pins.bzl" {
    const h = try fresh();
    defer h.destroy();
    try h.put("mopm-toolchain.toml", "[toolchain]\nmopm = \"0.0.2\"\nmojo = \"1.0.0\"\n");
    try h.put("buildrules-pins.toml", "[mopm.\"0.0.2\"]\nurl = \"https://example.org/r/mopm-0.0.2-linux-x86_64.tar.gz\"\nsha256 = \"" ++ "ab" ** 32 ++ "\"\nsize = 1234\n");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    try t.expect(kit.contains(h.read("pkgs/base/buildrules.mojo.lock.bzl"), "MOPM = {\"version\": \"0.0.2\", \"origin\": \"buildrules-pins.toml\"}"));
    try t.expect(kit.contains(h.read("toolchains/mopm_pins.bzl"), "\"dir\": \"mopm-0.0.2-linux-x86_64\""));
    // buck2 was asked for the pin's label, after the table that defines it was written.
    try t.expectEqual(@as(usize, 1), called("build toolchains//:mopm_0_0_2"));
}

test "sync: with several packages mopm is built once per version, and the toolchains of their graphs must agree" {
    const h = try fresh();
    defer h.destroy();
    try h.put("pkgs/other/mopm.toml", fx.manifest);
    try h.put("pkgs/other/mopm.lock", fx.mopm_lock);
    try h.put("pkgs/other/src/base/__init__.mojo", fx.lib);
    try h.put("pkgs/other/tests/test_base.mojo", fx.test_src);
    try h.put("pkgs/other/BUCK", fx.buck);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    try t.expectEqual(@as(usize, 1), called("buck2 build toolchains//:mopm_0_0_1"));
    try t.expectEqual(@as(usize, 2), called("plan --unit-graph"));
    try t.expect(h.has("pkgs/other/buildrules.mojo.lock.bzl"));
    try t.expectEqual(@as(usize, 1), kit.count(h.read("toolchains/mojo_pins.bzl"), "\"1.0.0\": {"));
}

// ---- check ---------------------------------------------------------------------------------------------

test "check: an edited source is stale, and both hashes are printed" {
    const h = try synced();
    defer h.destroy();
    try h.put("pkgs/base/src/base/__init__.mojo", fx.lib ++ "# edited\n");
    const r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pkgs/base/src/base/__init__.mojo changed since `buildrules mojo sync`"));
    try t.expect(kit.contains(r.err, "the table has sha256 "));
}

test "check: an edited test file, mopm.toml and mopm.lock are each stale" {
    const h = try synced();
    defer h.destroy();
    try h.put("pkgs/base/tests/test_base.mojo", fx.test_src ++ "# edited\n");
    var r = h.run(&.{ "mojo", "check" });
    try t.expect(kit.contains(r.err, "pkgs/base/tests/test_base.mojo changed"));
    try h.put("pkgs/base/tests/test_base.mojo", fx.test_src);
    try h.put("pkgs/base/mopm.toml", fx.manifest ++ "\n# edited\n");
    r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pkgs/base/mopm.toml changed since"));
    try h.put("pkgs/base/mopm.toml", fx.manifest);
    try h.put("pkgs/base/mopm.lock", fx.mopm_lock ++ " \n");
    r = h.run(&.{ "mojo", "check" });
    try t.expect(kit.contains(r.err, "pkgs/base/mopm.lock changed since"));
}

test "check: a new test file and a new library source that the graph does not know are stale" {
    const h = try synced();
    defer h.destroy();
    try h.put("pkgs/base/tests/test_new.mojo", "def main():\n    pass\n");
    var r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pkgs/base/tests/test_new.mojo is a test file that the table does not know"));
    try h.tmp.dir.deleteFile("pkgs/base/tests/test_new.mojo");
    try h.put("pkgs/base/src/base/extra.mojo", "def f():\n    pass\n");
    r = h.run(&.{ "mojo", "check" });
    try t.expect(kit.contains(r.err, "pkgs/base/src/base/extra.mojo is a source of base@0.1.0#mojo1.0.0/lib that the table does not know"));
    // A test file inside the library's own directory is a test, not a source.
    try h.tmp.dir.deleteFile("pkgs/base/src/base/extra.mojo");
    try h.put("pkgs/base/src/base/tests/test_inner.mojo", "def main():\n    pass\n");
    r = h.run(&.{ "mojo", "check" });
    try t.expect(kit.contains(r.err, "pkgs/base/src/base/tests/test_inner.mojo is a test file that the table does not know"));
    try t.expect(!kit.contains(r.err, "is a source of"));
}

test "check: a removed source is stale too" {
    const h = try synced();
    defer h.destroy();
    try h.tmp.dir.deleteFile("pkgs/base/tests/test_base.mojo");
    const r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pkgs/base/tests/test_base.mojo (a source of base@0.1.0#mojo1.0.0/test:tests/test_base.mojo) is gone"));
}

test "check: bumping mopm or Mojo in mopm-toolchain.toml without a sync is stale" {
    const h = try synced();
    defer h.destroy();
    try h.put("mopm-toolchain.toml", "[toolchain]\nmopm = \"0.0.2\"\nmojo = \"1.0.0\"\n");
    var r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "mopm-toolchain.toml pins mopm 0.0.2 but pkgs/base/buildrules.mojo.lock.bzl was made with mopm 0.0.1"));
    try h.put("mopm-toolchain.toml", "[toolchain]\nmopm = \"0.0.1\"\nmojo = \"1.1.0\"\n");
    r = h.run(&.{ "mojo", "check" });
    try t.expect(kit.contains(r.err, "pins Mojo 1.1.0 but pkgs/base/buildrules.mojo.lock.bzl is the graph for Mojo 1.0.0"));
}

test "check: a closure hash edited in one place only is caught (the hash beside the graph is a second copy)" {
    const h = try synced();
    defer h.destroy();
    const lock = h.read("pkgs/base/buildrules.mojo.lock.bzl");
    // Tamper with the copy outside the graph.
    try h.put("pkgs/base/buildrules.mojo.lock.bzl", try std.mem.replaceOwned(u8, h.a(), lock, "CLOSURE_SHA256 = \"fd654c", "CLOSURE_SHA256 = \"0d654c"));
    var r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "CLOSURE_SHA256 0d654c"));
    try t.expect(kit.contains(r.err, "is not the closure its unit graph pins"));
    // And the other copy: the graph's, with the recorded one intact.
    try h.put("pkgs/base/buildrules.mojo.lock.bzl", try std.mem.replaceOwned(u8, h.a(), lock, "\"closure_sha256\": \"fd654c", "\"closure_sha256\": \"0d654c"));
    r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "is not the closure its unit graph pins (0d654c"));
}

test "check: a hand-edited glue file, a missing table and a table of another schema are refused" {
    const h = try synced();
    defer h.destroy();
    try h.put("pkgs/base/buildrules.mojo.bzl", contract.mojo_bzl_text ++ "# mine\n");
    var r = h.run(&.{ "mojo", "check" });
    try t.expect(kit.contains(r.err, "buildrules.mojo.bzl is not what sync writes"));
    try h.put("pkgs/base/buildrules.mojo.bzl", contract.mojo_bzl_text);
    const lock = h.read("pkgs/base/buildrules.mojo.lock.bzl");
    try h.put("pkgs/base/buildrules.mojo.lock.bzl", try std.mem.replaceOwned(u8, h.a(), lock, "SCHEMA = 1", "SCHEMA = 7"));
    r = h.run(&.{ "mojo", "check" });
    try t.expect(kit.contains(r.err, "SCHEMA 7, this buildrules reads 1"));
    try h.tmp.dir.deleteFile("pkgs/base/buildrules.mojo.lock.bzl");
    r = h.run(&.{ "mojo", "check" });
    try t.expect(kit.contains(r.err, "buildrules.mojo.lock.bzl is missing"));
}

test "check: toolchains/mojo_pins.bzl and mopm_pins.bzl must be what the graphs and buildrules-pins.toml generate" {
    const h = try synced();
    defer h.destroy();
    try h.put("toolchains/mojo_pins.bzl", lockm.pins_empty);
    var r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "toolchains/mojo_pins.bzl is not what the unit graphs generate"));
    _ = h.run(&.{ "mojo", "sync", "--mopm", "/p/mopm" });
    try h.put("buildrules-pins.toml", "[mopm.\"0.0.2\"]\nurl = \"https://example.org/r/mopm-0.0.2-linux-x86_64.tar.gz\"\nsha256 = \"" ++ "cd" ** 32 ++ "\"\nsize = 5\n");
    r = h.run(&.{ "mojo", "check" });
    try t.expect(kit.contains(r.err, "toolchains/mopm_pins.bzl is not what buildrules-pins.toml generates"));
}

test "check: `buildrules check` runs the Mojo gate too when the repository has Mojo packages" {
    const h = try synced();
    defer h.destroy();
    // No Rust files here, so `check` fails on those; the Mojo problem must be reported in the same run.
    try h.put("pkgs/base/src/base/__init__.mojo", fx.lib ++ "# edited\n");
    const r = h.run(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pkgs/base/src/base/__init__.mojo changed since `buildrules mojo sync`"));
    // And without a Mojo package, `check` says nothing about Mojo.
    const g = try kit.Harness.create();
    defer g.destroy();
    try g.put(".buckconfig", "[cells]\n");
    try t.expect(!kit.contains(g.run(&.{"check"}).err, "mojo_package"));
}

test "check: a repository with no Mojo package is a failure of `mojo check`, and `check` ignores Mojo then" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try h.put(".buckconfig", "[cells]\n");
    const r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "no package here calls mojo_package"));
}

test "usage: unknown subcommands and flags are exit 2" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try t.expectEqual(@as(u8, 2), h.run(&.{"mojo"}).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "mojo", "build" }).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "mojo", "check", "--bogus" }).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "mojo", "sync", "--mopm" }).code);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "--help" }).code);
}

// ---- the tables ------------------------------------------------------------------------------------------

test "lock: render and parse are inverse, and the graph text is untouched" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = lockm.Lock{
        .schema = 1,
        .mopm_version = "0.0.1",
        .mopm_origin = "builtin",
        .mojo = "1.0.0",
        .closure_sha256 = "a" ** 64,
        .manifests = &.{ .{ .path = "../x.toml", .sha256 = "b" ** 64 }, .{ .path = "mopm.toml", .sha256 = "c" ** 64 } },
        .graph_json = "{\n  \"unit_graph\": 1\n}\n",
    };
    const text = try lockm.render(a, l);
    var d = Diag.init(a);
    const back = try lockm.parse(a, "x", text, &d);
    try t.expectEqualStrings(l.graph_json, back.graph_json);
    try t.expectEqualStrings("1.0.0", back.mojo);
    try t.expectEqual(@as(usize, 2), back.manifests.len);
    try t.expectEqualStrings("../x.toml", back.manifests[0].path);
    try t.expectEqualStrings("c" ** 64, lockm.manifestHash(back, "mopm.toml").?);
    try t.expectEqual(@as(?[]const u8, null), lockm.manifestHash(back, "nope"));
}

test "pins: two graphs for one Mojo with different toolchains are refused; characters a table may not carry are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = Diag.init(a);
    const g1 = try lockm.parseGraph(a, "g1", fx.graph, &d);
    const other = try std.mem.replaceOwned(u8, a, fx.graph, "\"cc_target\": \"x86_64-linux-gnu.2.34\"", "\"cc_target\": \"x86_64-linux-gnu.2.28\"");
    const g2 = try lockm.parseGraph(a, "g2", other, &d);
    var dd = Diag.init(a);
    try t.expectError(error.Invalid, lockm.renderPins(a, &.{ .{ .mojo = "1.0.0", .toolchain = g1.toolchain }, .{ .mojo = "1.0.0", .toolchain = g2.toolchain } }, &dd));
    try t.expect(kit.contains(dd.msgs.items[0], "pin different toolchains for Mojo 1.0.0"));
    // The same toolchain twice is one entry.
    var d3 = Diag.init(a);
    const ok = try lockm.renderPins(a, &.{ .{ .mojo = "1.0.0", .toolchain = g1.toolchain }, .{ .mojo = "1.0.0", .toolchain = g1.toolchain } }, &d3);
    try t.expectEqual(@as(usize, 1), kit.count(ok, "\"1.0.0\": {"));
    // A URL with a quote would be code in the table.
    const evil = try std.mem.replaceOwned(u8, a, fx.graph, "zig-linux-x86_64-0.12.0.tar.xz", "x\\\"y.tar.xz");
    var d4 = Diag.init(a);
    const g4 = try lockm.parseGraph(a, "g4", evil, &d4);
    var d5 = Diag.init(a);
    try t.expectError(error.Invalid, lockm.renderPins(a, &.{.{ .mojo = "1.0.0", .toolchain = g4.toolchain }}, &d5));
    try t.expect(kit.contains(d5.msgs.items[0], "zig.url"));
}

test "mopm pins: a table renders sorted, with the unpack directory taken from the URL" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = Diag.init(a);
    const text = "# mine\n[mopm.\"0.2.0\"]\nurl = \"https://e.org/mopm-0.2.0-linux-x86_64.tar.gz\" # a release\nsha256 = \"" ++ "11" ** 32 ++ "\"\nsize = 20\n\n[mopm.\"0.1.0\"]\nurl = \"https://e.org/mopm-0.1.0-linux-x86_64.tar.gz\"\nsha256 = \"" ++ "22" ** 32 ++ "\"\nsize = 10\n";
    const out = try mopm_pins.render(a, text, &d);
    try t.expect(std.mem.indexOf(u8, out, "\"0.1.0\"").? < std.mem.indexOf(u8, out, "\"0.2.0\"").?);
    try t.expect(kit.contains(out, "\"dir\": \"mopm-0.1.0-linux-x86_64\""));
    try t.expect(kit.contains(out, "\"size\": 20,"));
}

test "mopm pins: a missing field, a duplicate, a floating version, a bad hash and an unknown key are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "[mopm.\"0.1.0\"]\nsha256 = \"" ++ "11" ** 32 ++ "\"\nsize = 1\n", "needs url, sha256 and size" },
        .{ "[mopm.\"0.1.0\"]\nurl = \"https://e.org/m-0.1.0.tar.gz\"\nsha256 = \"" ++ "11" ** 32 ++ "\"\nsize = 1\n[mopm.\"0.1.0\"]\n", "appears twice" },
        .{ "[mopm.\"latest\"]\n", "is not an exact release" },
        .{ "[mopm.\"0.1.0\"]\nurl = \"https://e.org/m-0.1.0.tar.gz\"\nsha256 = \"XYZ\"\nsize = 1\n", "sha256 must be 64 lower-case hex digits" },
        .{ "[mopm.\"0.1.0\"]\ncolour = \"red\"\n", "unknown key `colour`" },
        .{ "[mopm.\"0.1.0\"]\nurl = \"https://e.org/m-0.1.0.zip\"\nsha256 = \"" ++ "11" ** 32 ++ "\"\nsize = 1\n", "url must be a quoted https URL of a .tar.gz" },
        .{ "url = \"https://e.org/x.tar.gz\"\n", "outside any table" },
    };
    for (cases) |c| {
        var d = Diag.init(a);
        try t.expectError(error.Invalid, mopm_pins.render(a, c[0], &d));
        var found = false;
        for (d.msgs.items) |m| found = found or kit.contains(m, c[1]);
        if (!found) std.debug.panic("wanted `{s}` in {s}", .{ c[1], try std.mem.join(a, "; ", d.msgs.items) });
    }
}

test "pins: the Rust reader leaves [mopm] tables alone and the mopm reader leaves [rust] tables alone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const both = "[mopm.\"0.1.0\"]\nurl = \"https://e.org/m-0.1.0.tar.gz\"\nsha256 = \"" ++ "11" ** 32 ++ "\"\nsize = 1\n\n[rust.\"1.86.0\"]\n[rust.\"1.86.0\".rustc]\nsha256 = \"" ++ "22" ** 32 ++ "\"\nsize = 5\n[rust.\"1.86.0\".rust-std]\nsha256 = \"" ++ "22" ** 32 ++ "\"\nsize = 5\n[rust.\"1.86.0\".cargo]\nsha256 = \"" ++ "22" ** 32 ++ "\"\nsize = 5\n[rust.\"1.86.0\".clippy]\nsha256 = \"" ++ "22" ** 32 ++ "\"\nsize = 5\n";
    var d1 = Diag.init(a);
    const rust = try pins_toml.render(a, both, &d1);
    try t.expect(kit.contains(rust, "\"1.86.0\""));
    try t.expect(!kit.contains(rust, "0.1.0"));
    var d2 = Diag.init(a);
    const mopm = try mopm_pins.render(a, both, &d2);
    try t.expect(kit.contains(mopm, "\"0.1.0\""));
    try t.expect(!kit.contains(mopm, "1.86.0"));
}

test "paths: normalize resolves . and .. and join never leaves a leading slash" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mc = @import("mojo_cmd.zig");
    try t.expectEqualStrings("examples/mojo/mopm-toolchain.toml", try mc.join(a, "examples/mojo/ws/util/base", "../../../mopm-toolchain.toml"));
    try t.expectEqualStrings("pkg/a.toml", try mc.join(a, "", "pkg/./a.toml"));
    try t.expectEqualStrings("../b", try mc.join(a, "a", "../../b"));
}

test "test files: mopm's discovery rule" {
    try t.expect(lockm.isTestPath("tests/test_a.mojo"));
    try t.expect(lockm.isTestPath("tests/deep/test_a.mojo"));
    try t.expect(lockm.isTestPath("src/p/tests/test_a.mojo"));
    try t.expect(!lockm.isTestPath("src/p/test_a.mojo"));
    try t.expect(!lockm.isTestPath("tests/helper.mojo"));
    try t.expect(!lockm.isTestPath("tests/.hidden/test_a.mojo"));
    try t.expect(!lockm.isTestPath("test_a.mojo"));
}

// ---- the export of mopm-toolchain.toml (the :check of a package names it as a target) ----------------------------------

test "sync: a toolchain file in another directory than the package is exported by that directory's BUCK file, created if it has none" {
    // Defect: the :check of a package refers to //<dir>:mopm-toolchain.toml and the target does not exist, so every build of the package fails to load.
    const h = try fresh();
    defer h.destroy();
    try t.expect(!h.has("BUCK"));
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), r.code);
    const mc = @import("mojo_cmd.zig");
    try t.expectEqualStrings(mc.export_header ++ mc.export_snippet, h.read("BUCK"));
    // a second sync leaves it, and check is satisfied
    const again = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expect(!kit.contains(again.out, "wrote   BUCK"));
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check" }).code);
}

test "sync: a BUCK file the directory already has is kept, and the export is appended once" {
    const h = try fresh();
    defer h.destroy();
    try h.put("BUCK", "# mine\nexport_file(name = \"other\", src = \"other\")\n");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    const mc = @import("mojo_cmd.zig");
    try t.expectEqualStrings("# mine\nexport_file(name = \"other\", src = \"other\")\n\n" ++ mc.export_snippet, h.read("BUCK"));
    const before = h.read("BUCK");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    try t.expectEqualStrings(before, h.read("BUCK"));
}

test "check, and sync --check: a missing export is stale and names the file; sync --check writes nothing" {
    const h = try synced();
    defer h.destroy();
    try h.put("BUCK", "# nothing exported here\n");
    var r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "BUCK does not export mopm-toolchain.toml"));
    r = h.run(&.{ "mojo", "sync", "--check", "--mopm", "/p/mopm" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "BUCK does not export mopm-toolchain.toml"));
    try t.expectEqualStrings("# nothing exported here\n", h.read("BUCK"));
}

test "a package that holds its own mopm-toolchain.toml needs no export (mojo_package exports it)" {
    const mc = @import("mojo_cmd.zig");
    try t.expect(!mc.needsExport(.{ .rel_to_pkg = "mopm-toolchain.toml", .at_root = "pkg/mopm-toolchain.toml", .mopm = "0.0.1", .mojo = "1.0.0" }));
    try t.expect(mc.needsExport(.{ .rel_to_pkg = "../mopm-toolchain.toml", .at_root = "mopm-toolchain.toml", .mopm = "0.0.1", .mojo = "1.0.0" }));
}

test "check: without mopm-toolchain.toml the check fails and says what to write, nothing is defaulted" {
    // Defect: a missing file falls back to a default mopm and Mojo, and the check is green.
    const h = try synced();
    defer h.destroy();
    try h.tmp.dir.deleteFile("mopm-toolchain.toml");
    const r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "no mopm-toolchain.toml at or above pkgs/base"));
    try t.expect(kit.contains(r.err, "there is no default"));
    try t.expect(kit.contains(r.err, "[toolchain]\nmopm = \"0.0.48\"\nmojo = \"1.0.0\"\n"));
    try t.expect(!kit.contains(r.out, "ok:"));
}

test "the BUCK export of mopm-toolchain.toml fails the load, with the file and an example, when the file is missing" {
    const mc = @import("mojo_cmd.zig");
    try t.expect(kit.contains(mc.export_snippet, "if glob([\"mopm-toolchain.toml\"]) else fail("));
    try t.expect(kit.contains(mc.export_snippet, "mopm-toolchain.toml is required and there is no default. Create it, for example:"));
    try t.expect(kit.contains(mc.export_snippet, "[toolchain]\\nmopm = '0.0.48'\\nmojo = '1.0.0'"));
}

// ---- more of sync and check: arguments, discovery, failures of the programs it runs, path dependencies --------------------

pub fn sha256Hex(h: *kit.Harness, bytes: []const u8) ![]const u8 {
    return ctxm.sha256Hex(h.a(), bytes);
}

test "arguments: -h, a flag without its value, package directories in their several spellings, and a directory that is not there" {
    const h = try fresh();
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "-h" }).code);
    for ([_][]const []const u8{
        &.{ "mojo", "sync", "--dir" },
        &.{ "mojo", "check", "--dir" },
        &.{ "mojo", "sync", "--buck2" },
        &.{ "mojo", "check", "--mopm", "x" },
        &.{ "mojo", "check", "pkgs/base" },
        &.{ "mojo", "sync", "-x" },
    }) |argv| try t.expectEqual(@as(u8, 2), h.run(argv).code);
    // The package given as ./pkgs/base/, pkgs/base//, and by --dir.
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2", "./pkgs/base/" }).code);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2", "pkgs/base//" }).code);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--dir", ".", "--buck2", "./buck2", "./pkgs/base" }).code);
    // A package that has no mopm.toml, and the root, which has none either.
    var r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2", "pkgs/none" });
    try t.expectEqual(@as(u8, 1), r.code);
    // (A package that does not exist at all is refused by the toolchains-directory guard before the package is looked at; one that exists without a
    // mopm.toml gets the message below.)
    try t.expect(kit.contains(r.err, "cannot resolve the Mojo package pkgs/none"));
    try h.put("pkgs/empty/BUCK", "# no mopm.toml here\n");
    r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2", "pkgs/empty" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pkgs/empty: no mopm.toml here"));
    r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2", "." });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, ".: no mopm.toml here"));
    r = h.run(&.{ "mojo", "sync", "--dir", "nowhere", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "cannot open nowhere"));
    r = h.run(&.{ "mojo", "check", "--dir", "nowhere" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "cannot open nowhere"));
}

test "sync: no .buckconfig, no Mojo package, and packages in directories the walk does not enter" {
    const h = try fresh();
    defer h.destroy();
    for ([_][]const u8{ ".git", "node_modules", "buck-out", "target", ".buck", ".hidden", "ok/.deep" }) |dir| {
        try h.put(try std.fmt.allocPrint(h.a(), "{s}/BUCK", .{dir}), fx.buck);
        try h.put(try std.fmt.allocPrint(h.a(), "{s}/mopm.toml", .{dir}), fx.manifest);
    }
    try h.put("other/BUCK", "# a BUCK file that calls no mojo_package\n");
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, "synced: 1 Mojo package(s)"));
    try h.tmp.dir.deleteFile(".buckconfig");
    const no_cell = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), no_cell.code);
    try t.expect(kit.contains(no_cell.err, "no .buckconfig here"));
    const empty = try kit.Harness.create();
    defer empty.destroy();
    try empty.put(".buckconfig", "[cells]\n");
    const none = empty.run(&.{ "mojo", "sync" });
    try t.expectEqual(@as(u8, 1), none.code);
    try t.expect(kit.contains(none.err, "no package here calls mojo_package"));
}

test "sync: buck2 that fails, prints nothing usable, or cannot be started is a message that says what to do, and mopm that cannot be started too" {
    const h = try fresh();
    defer h.destroy();
    buck2_code = 1;
    var r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "`./buck2 build toolchains//:mopm_0_0_1` exited 1"));
    try t.expect(kit.contains(r.err, "[mopm.\"0.0.1\"]"));
    buck2_code = 0;
    for ([_][]const u8{ "", "nothing useful here\n", "other//:label /abs/path\n", "toolchains//:mopm_0_0_1 relative/path\n", "toolchains//:mopm_0_0_1 \n" }) |out| {
        buck2_stdout = out;
        r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, "printed no output path (pass --mopm instead)"));
    }
    buck2_stdout = null;
    exec_error = error.FileNotFound;
    exec_error_on = "buck2";
    r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "cannot run ./buck2: FileNotFound (pass --mopm instead)"));
    exec_error_on = "mopm";
    exec_error_spares_help = true;
    r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pkgs/base: cannot run mopm: FileNotFound"));
    exec_error = null;
    exec_error_spares_help = false;
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
}

fn syncWithGraph(h: *kit.Harness, text: []const u8) kit.Run {
    plan_graph = text;
    return h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
}

test "sync: a graph mopm printed that is not a graph, or that cannot be embedded, is refused with the package" {
    const h = try fresh();
    defer h.destroy();
    const cases = [_]struct { text: []const u8, needle: []const u8 }{
        .{ .text = "not json", .needle = "pkgs/base: the GRAPH_JSON block is not JSON" },
        .{ .text = "[]", .needle = "the unit graph is not a JSON object" },
        .{ .text = "{\"unit_graph\": 4}", .needle = "unit_graph format is not 1, 2 or 3" },
        .{ .text = "{\"unit_graph\": 1, \"toolchain\": {}}", .needle = "no `units` array" },
    };
    for (cases) |c| {
        const r = syncWithGraph(h, c.text);
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, c.needle));
    }
    const triple = try std.mem.replaceOwned(u8, h.a(), fx.graph, "\"package\": \"base@0.1.0\"", "\"package\": \"base@0.1.0'''\"");
    const r = syncWithGraph(h, triple);
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "mopm's graph holds ''' and cannot be embedded in a table"));
    try t.expect(!h.has("pkgs/base/buildrules.mojo.lock.bzl"));
}

test "sync: a native a member builds is written with the graph, and an entry built by a native unit the graph does not have is refused with a message that names it" {
    const h = try fresh();
    defer h.destroy();
    const plain = "\"deps\": [],\n      \"natives\": [],";
    const with_entry = "\"deps\": [],\n      \"natives\": [{\"id\": \"shim\", \"soname\": \"libshim.a\", \"package\": \"base\", \"kind\": \"static\", \"built\": \"native:base/shim\"}],";
    const dangling = try std.mem.replaceOwned(u8, h.a(), fx.graph, plain, with_entry);
    try t.expect(!std.mem.eql(u8, dangling, fx.graph));
    const bad = syncWithGraph(h, dangling);
    try t.expectEqual(@as(u8, 1), bad.code);
    try t.expect(kit.contains(bad.err, "base@0.1.0#mojo1.0.0/lib links the native library libshim.a, built by native:base/shim, but the graph has no such native unit"));
    try t.expect(!h.has("pkgs/base/buildrules.mojo.lock.bzl"));
    // With the unit in the graph, the same entry is fine, and the graph is written as mopm printed it.
    const unit = "\"units\": [\n    {\"id\": \"native:base/shim\", \"kind\": \"native\", \"package\": \"base\", \"soname\": \"libshim.a\"},";
    const whole = try std.mem.replaceOwned(u8, h.a(), dangling, "\"units\": [", unit);
    const ok = syncWithGraph(h, whole);
    try t.expectEqual(@as(u8, 0), ok.code);
    try t.expect(kit.contains(h.read("pkgs/base/buildrules.mojo.lock.bzl"), "{\"id\": \"native:base/shim\", \"kind\": \"native\""));
}

test "sync: a toolchain in a graph that a table may not carry is refused, and so is a missing mopm.lock" {
    const h = try fresh();
    defer h.destroy();
    const r = syncWithGraph(h, try std.mem.replaceOwned(u8, h.a(), fx.graph, "\"zig\": {", "\"zag\": {"));
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "the unit graph's toolchain has no zig"));
    plan_graph = fx.graph;
    try h.tmp.dir.deleteFile("pkgs/base/mopm.lock");
    const missing = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), missing.code);
    try t.expect(kit.contains(missing.err, "pkgs/base/mopm.lock is missing: `mopm lock` writes it"));
}

test "sync and check: buildrules-pins.toml with a bad [mopm] table is a failure of both" {
    const h = try fresh();
    defer h.destroy();
    try h.put("buildrules-pins.toml", "[mopm.\"1.0\"]\n");
    for ([_][]const []const u8{ &.{ "mojo", "sync", "--buck2", "./buck2" }, &.{ "mojo", "sync", "--check", "--mopm", "/p/mopm" } }) |argv| {
        const r = h.run(argv);
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, "mopm \"1.0\" is not an exact release"));
    }
    try h.put("buildrules-pins.toml", "");
    _ = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try h.put("buildrules-pins.toml", "[mopm.\"1.0\"]\n");
    const c = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), c.code);
    try t.expect(kit.contains(c.err, "mopm \"1.0\" is not an exact release"));
}

/// The unit block mopm prints for the library of `util`, a path dependency of `base`: its sources and its key are what the table must not hold.
/// `@ROOT@` is the root as mopm prints it (relative to the package, or to the repository root), `@PATH@` the path of its one source.
const util_graph_unit =
    "    {\n" ++
    "      \"id\": \"util@0.1.0#mojo1.0.0/lib\",\n" ++
    "      \"package\": \"util\",\n" ++
    "      \"version\": \"0.1.0\",\n" ++
    "      \"kind\": \"lib\",\n" ++
    "      \"root\": \"@ROOT@\",\n" ++
    "      \"srcs\": [\n" ++
    "        {\"path\": \"@PATH@\", \"sha256\": \"@SHA@\"}\n" ++
    "      ],\n" ++
    "      \"deps\": [],\n" ++
    "      \"natives\": [],\n" ++
    "      \"profile\": {\"opt\": 1, \"assert\": \"all\", \"debug\": false},\n" ++
    "      \"outputs\": [\"util.mojoc\"],\n" ++
    "      \"key\": \"@KEY@\"\n" ++
    "    },\n";
/// Units of other shapes, on one line each (not in mopm's layout, which the committed form leaves alone): only a library of another package, in a
/// directory of its own (`src/<its name>` below it, or below the nearest directory with a mopm.toml: mojo_generated_test.zig), is a path dependency.
/// Each of these is in the importing package's own directory, or is not a library.
const odd_units =
    "    {\"package\": \"base\", \"kind\": \"lib\", \"root\": \"../base2/src/base\"}, " ++
    "{\"package\": \"vendored\", \"kind\": \"test\", \"root\": \"../v/src/vendored\"}, " ++
    "{\"package\": \"flat\", \"kind\": \"lib\", \"root\": \"src/flat\"}, " ++
    "{\"package\": \"elsewhere\", \"kind\": \"lib\", \"root\": \"somewhere/else\"}, " ++
    "{\"package\": \"zeta\", \"kind\": \"lib\", \"root\": \"xsrc/zeta\"}, " ++
    "{\"id\": \"reg@1.0.0#mojo1.0.0/lib\", \"package\": \"reg\", \"kind\": \"prebuilt\"}, " ++
    "{\"id\": \"bare@1.0.0#mojo1.0.0/lib\", \"package\": \"bare\", \"kind\": \"lib\"},\n";

pub const util_src = "def util() -> Int:\n    return 1\n";
const base_key = "c35bac7771b58268a8da642c068d5a26fba08d652a1bea867fe87d7e8ecedc2d";

/// mopm's graph for `base` when it imports `util` (whose source is `src`, its key `key`): `base`'s library imports it, so its key (mopm hashes the keys
/// below a unit) is `base_key` with `key` appended. `root` and `path` are as mopm prints them; `prefix` goes before the paths of `base` itself.
pub fn memberGraph(h: *kit.Harness, src: []const u8, key: []const u8, root: []const u8, path: []const u8, prefix: []const u8) ![]const u8 {
    const a = h.a();
    var unit = try std.mem.replaceOwned(u8, a, util_graph_unit, "@ROOT@", root);
    unit = try std.mem.replaceOwned(u8, a, unit, "@PATH@", path);
    unit = try std.mem.replaceOwned(u8, a, unit, "@SHA@", try sha256Hex(h, src));
    unit = try std.mem.replaceOwned(u8, a, unit, "@KEY@", key);
    // (the odd units are paths relative to the package; with the root as the base the same words would name other directories)
    var g = try std.mem.replaceOwned(u8, a, fx.graph, "\"units\": [\n", try std.mem.concat(a, u8, &.{ "\"units\": [\n", unit, if (prefix.len == 0) odd_units else "" }));
    // base's library imports util, and its key moved with util's
    g = try std.mem.replaceOwned(u8, a, g, "      \"deps\": [],\n      \"natives\": [],\n      \"profile\": {\"opt\": 1, \"assert\": \"all\", \"debug\": false},\n      \"outputs\": [\"base.mojoc\"],", "      \"deps\": [\"util@0.1.0#mojo1.0.0/lib\"],\n      \"natives\": [],\n      \"profile\": {\"opt\": 1, \"assert\": \"all\", \"debug\": false},\n      \"outputs\": [\"base.mojoc\"],");
    g = try std.mem.replaceOwned(u8, a, g, base_key, try std.mem.concat(a, u8, &.{ base_key, key }));
    if (prefix.len > 0) {
        g = try std.mem.replaceOwned(u8, a, g, "\"root\": \"src/base\"", try std.fmt.allocPrint(a, "\"root\": \"{s}src/base\"", .{prefix}));
        g = try std.mem.replaceOwned(u8, a, g, "\"path\": \"src/base/", try std.fmt.allocPrint(a, "\"path\": \"{s}src/base/", .{prefix}));
        g = try std.mem.replaceOwned(u8, a, g, "\"path\": \"tests/", try std.fmt.allocPrint(a, "\"path\": \"{s}tests/", .{prefix}));
    }
    return g;
}

/// The repository of `fresh` with a second package `util` that `base` imports: the graph names it, and its manifest is a manifest of the table.
pub fn withMember(h: *kit.Harness) !void {
    try h.put("pkgs/util/mopm.toml", "[package]\nname = \"util\"\nversion = \"0.1.0\"\n");
    try h.put("pkgs/util/src/util/__init__.mojo", util_src);
    plan_graph = try memberGraph(h, util_src, "k0", "../util/src/util", "../util/src/util/__init__.mojo", "");
}

test "sync and check: a package the graph imports from a sibling directory has its manifest in the table, and check follows it" {
    const h = try fresh();
    defer h.destroy();
    try withMember(h);
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), r.code);
    const lock = h.read("pkgs/base/buildrules.mojo.lock.bzl");
    try t.expect(kit.contains(lock, "\"../util/mopm.toml\": \""));
    // Only the library of another package that is in a directory of its own is a member.
    try t.expect(!kit.contains(lock, "\"../base2/mopm.toml\""));
    try t.expect(!kit.contains(lock, "\"../v/mopm.toml\""));
    try t.expect(!kit.contains(lock, "\"../elsewhere"));
    try t.expect(!kit.contains(lock, "xsrc/mopm.toml"));
    // The member's manifest changed, and its source gained files: the manifest is the table's business (a new version or other dependencies change the
    // graph), the member's sources are not (its own table lists them).
    try h.put("pkgs/util/mopm.toml", "[package]\nname = \"util\"\nversion = \"0.1.1\"\n");
    try h.put("pkgs/util/src/util/extra.mojo", "def f():\n    pass\n");
    try h.put("pkgs/util/src/util/tests/test_inner.mojo", "def main():\n    pass\n");
    try h.put("pkgs/util/src/util/.hidden/skip.mojo", "def g():\n    pass\n");
    try h.put("pkgs/util/src/util/.skip.mojo", "def g():\n    pass\n");
    const c = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), c.code);
    try t.expect(kit.contains(c.err, "pkgs/util/mopm.toml changed since"));
    try t.expect(!kit.contains(c.err, "extra.mojo"));
    try t.expect(!kit.contains(c.err, "skip.mojo"));
    try t.expect(!kit.contains(c.err, "test_inner.mojo"));
    // The manifest is gone: sync says so, and the table is not written again.
    try h.tmp.dir.deleteFile("pkgs/util/mopm.toml");
    const gone = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), gone.code);
    try t.expect(kit.contains(gone.err, "pkgs/util/mopm.toml is missing (a path dependency of pkgs/base)"));
}

test "check: a table that does not record the manifests of its package, or a path dependency's, is stale" {
    const h = try fresh();
    defer h.destroy();
    try withMember(h);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    const lock = h.read("pkgs/base/buildrules.mojo.lock.bzl");
    const sha = try sha256Hex(h, "[package]\nname = \"util\"\nversion = \"0.1.0\"\n");
    const util_line = try std.fmt.allocPrint(h.a(), "    \"../util/mopm.toml\": \"{s}\",\n", .{sha});
    try t.expect(kit.contains(lock, util_line));
    var r: kit.Run = undefined;
    for ([_][]const u8{ "mopm.toml", "mopm.lock" }) |name| {
        const prefix = try std.fmt.allocPrint(h.a(), "    \"{s}\": \"", .{name});
        const at = std.mem.indexOf(u8, lock, prefix).?;
        const end = std.mem.indexOfScalarPos(u8, lock, at, '\n').? + 1;
        try h.put("pkgs/base/buildrules.mojo.lock.bzl", try std.mem.concat(h.a(), u8, &.{ lock[0..at], lock[end..] }));
        r = h.run(&.{ "mojo", "check" });
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, try std.fmt.allocPrint(h.a(), "does not record {s}", .{name})));
    }
    try h.put("pkgs/base/buildrules.mojo.lock.bzl", try std.mem.replaceOwned(u8, h.a(), lock, util_line, ""));
    r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "../util/mopm.toml is a path dependency's manifest the table does not know"));
    // A manifest the table records that is gone from disk.
    try h.put("pkgs/base/buildrules.mojo.lock.bzl", lock);
    try h.tmp.dir.deleteFile("pkgs/base/mopm.lock");
    r = h.run(&.{ "mojo", "check" });
    try t.expect(kit.contains(r.err, "pkgs/base/mopm.lock is in pkgs/base/buildrules.mojo.lock.bzl but is gone"));
}

test "check: a table that is damaged is refused with the line, whichever line it is" {
    const h = try synced();
    defer h.destroy();
    const lock = h.read("pkgs/base/buildrules.mojo.lock.bzl");
    const cases = [_]struct { from: []const u8, to: []const u8, needle: []const u8 }{
        .{ .from = "GRAPH_JSON = r'''", .to = "GRAPH = r'''", .needle = "no GRAPH_JSON" },
        .{ .from = "\"unit_graph\": 1", .to = "\"unit_graph\": 4", .needle = "unit_graph format is not 1" },
        .{ .from = "{\n  \"unit_graph\"", .to = "[\n  \"unit_graph\"", .needle = "is not JSON" },
        .{ .from = "MOJO = \"1.0.0\"", .to = "MOJO = \"1.0.1\"", .needle = "MOJO is 1.0.1 but its unit graph is for Mojo 1.0.0" },
        .{ .from = "CLOSURE_SHA256 = \"", .to = "CLOSURE_SHA256 = \"x", .needle = "CLOSURE_SHA256 is not a sha256" },
    };
    for (cases) |c| {
        try h.put("pkgs/base/buildrules.mojo.lock.bzl", try std.mem.replaceOwned(u8, h.a(), lock, c.from, c.to));
        const r = h.run(&.{ "mojo", "check" });
        try t.expectEqual(@as(u8, 1), r.code);
        if (!kit.contains(r.err, c.needle)) {
            std.debug.print("expected `{s}`, got: {s}\n", .{ c.needle, r.err });
            return error.WrongMessage;
        }
    }
    // The glue file is not there at all.
    try h.put("pkgs/base/buildrules.mojo.lock.bzl", lock);
    try h.tmp.dir.deleteFile("pkgs/base/buildrules.mojo.bzl");
    const r = h.run(&.{ "mojo", "check" });
    try t.expect(kit.contains(r.err, "pkgs/base/buildrules.mojo.bzl is missing"));
}

test "check: a toolchain table that cannot be made from the graphs in the committed tables is a failure, whichever table it is" {
    const h = try synced();
    defer h.destroy();
    const lock = h.read("pkgs/base/buildrules.mojo.lock.bzl");
    // The graph inside the table lost its zig: the tables are otherwise consistent (the closure hash copy is the graph's).
    try h.put("pkgs/base/buildrules.mojo.lock.bzl", try std.mem.replaceOwned(u8, h.a(), lock, "\"zig\": {", "\"zag\": {"));
    const r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "the unit graph's toolchain has no zig"));
    // sync --check does the same with mopm's fresh graph.
    plan_graph = try std.mem.replaceOwned(u8, h.a(), fx.graph, "\"zig\": {", "\"zag\": {");
    const s = h.run(&.{ "mojo", "sync", "--check", "--mopm", "/p/mopm" });
    try t.expectEqual(@as(u8, 1), s.code);
    try t.expect(kit.contains(s.err, "the unit graph's toolchain has no zig"));
}

test "sync --check says which generated file is not what a sync writes, for the table, the glue and the pins" {
    const h = try synced();
    defer h.destroy();
    try h.put("pkgs/base/buildrules.mojo.bzl", "# mine\n");
    try h.put("toolchains/mojo_pins.bzl", "# mine\n");
    try h.put("toolchains/mopm_pins.bzl", "# mine\n");
    try h.put("pkgs/base/buildrules.mojo.lock.bzl", "# mine\n");
    const r = h.run(&.{ "mojo", "sync", "--check", "--mopm", "/p/mopm" });
    try t.expectEqual(@as(u8, 1), r.code);
    for ([_][]const u8{ "pkgs/base/buildrules.mojo.lock.bzl is not what the inputs generate", "pkgs/base/buildrules.mojo.bzl is not what the inputs generate", "toolchains/mojo_pins.bzl is not what the inputs generate", "toolchains/mopm_pins.bzl is not what the inputs generate" }) |m| {
        try t.expect(kit.contains(r.err, m));
    }
    try h.tmp.dir.deleteFile("toolchains/mopm_pins.bzl");
    try t.expect(kit.contains(h.run(&.{ "mojo", "sync", "--check", "--mopm", "/p/mopm" }).err, "toolchains/mopm_pins.bzl is missing"));
}

test "mojo_cmd.run itself answers --help and -h (main answers `mojo --help` before it gets here, so this is the entry used by a caller of the module)" {
    const h = try kit.Harness.create();
    defer h.destroy();
    const mc = @import("mojo_cmd.zig");
    for ([_][]const u8{ "--help", "-h" }) |flag| {
        h.out.clearRetainingCapacity();
        try t.expectEqual(@as(u8, 0), mc.run(&h.ctx, &.{flag}));
        try t.expect(kit.contains(h.out.written(), "usage: buildrules mojo sync"));
    }
}

// ---- the toolchain file, the walk, and the odd texts ---------------------------------------------------------------------

test "mopm-toolchain.toml: the lines that are not `mopm = \"N.N.N\"` are not the line, and the file needs both" {
    const h = try fresh();
    defer h.destroy();
    const cases = [_]struct { text: []const u8, needle: []const u8 }{
        .{ .text = "[toolchain]\nmojo = \"1.0.0\"\n", .needle = "needs `mopm = \"N.N.N\"`" },
        .{ .text = "[toolchain]\nmopm-extra = \"0.0.1\"\nmojo = \"1.0.0\"\n", .needle = "needs `mopm = \"N.N.N\"`" },
        .{ .text = "[toolchain]\nmopm\nmojo = \"1.0.0\"\n", .needle = "needs `mopm = \"N.N.N\"`" },
        .{ .text = "[toolchain]\nmopm = 0.0.1\nmojo = \"1.0.0\"\n", .needle = "needs `mopm = \"N.N.N\"`" },
        .{ .text = "[toolchain]\nmopm = \"0.0.1\nmojo = \"1.0.0\"\n", .needle = "needs `mopm = \"N.N.N\"`" },
        .{ .text = "[toolchain]\nmopm = \"0.0.1\"\nmojo = 1.0.0\n", .needle = "needs `mojo = \"N.N.N\"`" },
        .{ .text = "[toolchain]\nmopm = \"0.0.1\"\nmojo = \"1.0.0\n", .needle = "needs `mojo = \"N.N.N\"`" },
        .{ .text = "", .needle = "needs `mopm = \"N.N.N\"`" },
    };
    for (cases) |c| {
        try h.put("mopm-toolchain.toml", c.text);
        const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
        try t.expectEqual(@as(u8, 1), r.code);
        if (!kit.contains(r.err, c.needle)) {
            std.debug.print("expected `{s}`, got: {s}\n", .{ c.needle, r.err });
            return error.WrongMessage;
        }
    }
    // Blanks around the key and the quotes, and a comment after the value, are fine.
    try h.put("mopm-toolchain.toml", "  mopm   =   \"0.0.1\"  # the mopm\n\tmojo\t=\t\"1.0.0\"\n");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
}

test "mopm's exit codes other than 3 and 4 are reported without advice, and a graph for a package whose name has no version is read" {
    const h = try fresh();
    defer h.destroy();
    plan_code = 5;
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "exited 5\n"));
    try t.expect(!kit.contains(r.err, "mopm lock"));
    plan_code = 0;
    // A package named without a version: the members are the libraries of other packages.
    const bare = try std.mem.replaceOwned(u8, h.a(), fx.graph, "\"package\": \"base@0.1.0\"", "\"package\": \"base\"");
    try t.expectEqual(@as(u8, 0), syncWithGraph(h, bare).code);
}

test "mojo paths: normalize and join resolve ., .. and doubled slashes; a path that leaves the root keeps its .." {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mc = @import("mojo_cmd.zig");
    try t.expectEqualStrings("a/b", try mc.normalize(a, "a//./b/"));
    try t.expectEqualStrings("", try mc.normalize(a, "./"));
    try t.expectEqualStrings("../a", try mc.normalize(a, "../a"));
    try t.expectEqualStrings("../../a", try mc.normalize(a, "../b/../../a"));
    try t.expectEqualStrings("a", try mc.normalize(a, "a/b/.."));
    try t.expectEqualStrings("", try mc.normalize(a, "a/.."));
    try t.expectEqualStrings("x/y", try mc.join(a, "", "x/y"));
    try t.expectEqualStrings("p/x", try mc.join(a, "p", "./x"));
}

test "check: the toolchain tables that are missing are stale, a glue file that is only the start of what sync writes names the line, and an export appended to an empty BUCK file" {
    const h = try synced();
    defer h.destroy();
    try h.tmp.dir.deleteFile("toolchains/mojo_pins.bzl");
    try h.tmp.dir.deleteFile("toolchains/mopm_pins.bzl");
    var r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "toolchains/mojo_pins.bzl is not what the unit graphs generate (first difference at line 1)"));
    try t.expect(kit.contains(r.err, "toolchains/mopm_pins.bzl is not what buildrules-pins.toml generates (first difference at line 1)"));
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    try h.put("pkgs/base/buildrules.mojo.bzl", contract.mojo_bzl_text[0 .. contract.mojo_bzl_text.len / 2]);
    r = h.run(&.{ "mojo", "check" });
    try t.expect(kit.contains(r.err, "buildrules.mojo.bzl is not what sync writes (first difference at line "));
    // The directory's BUCK file is there and empty: the export is appended after one blank line at most.
    const g = try fresh();
    defer g.destroy();
    try g.put("BUCK", "");
    try t.expectEqual(@as(u8, 0), g.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    const mc = @import("mojo_cmd.zig");
    try t.expectEqualStrings("\n" ++ mc.export_snippet, g.read("BUCK"));
}

// ---- path dependencies: identity in the table, and the repository root as the base of the graph's paths ----------------------------------

pub const lock_path = "pkgs/base/buildrules.mojo.lock.bzl";

test "probe: the flag is used when the mopm's own help lists it, whatever release the toolchain file names" {
    // a release number that no rule knows: only the binary's answer counts
    for ([_][]const u8{ "0.0.7", "0.0.40", "9.9.9" }) |v| {
        const h = try fresh();
        defer h.destroy();
        try h.put("mopm-toolchain.toml", try std.fmt.allocPrint(h.a(), "[toolchain]\nmopm = \"{s}\"\nmojo = \"1.0.0\"\n", .{v}));
        help_out = help_with;
        try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
        try t.expectEqual(@as(usize, 1), called("--workspace-root"));
        try t.expect(kit.contains(h.read(lock_path), "\"workspace_root\": True}\n"));
    }
}

/// The `plan` entry of the usage text that mopm 0.0.48 (the pinned release) prints for `--help`, copied from `usage` in its src/cli/main.zig at the
/// tag v0.0.48: the line that names the flag, and the lines that describe it.
const help_pinned_0_0_48 =
    "usage: mopm <command> [args]\n\nworking today:\n" ++
    "  plan --unit-graph --locked [--mojo <version>] [--workspace-root <dir>] [-o <file>]\n" ++
    "                          print the unit graph (spec/unit-graph.md) of\n" ++
    "                          mopm.lock for one Mojo version; never resolves;\n" ++
    "                          --workspace-root: graph paths are relative to\n" ++
    "                          <dir>, which holds this directory and every\n" ++
    "                          path dependency\n";

test "probe: the pinned 0.0.48 help lists the flag, so sync gives it the repository root and the table records that" {
    const h = try fresh();
    defer h.destroy();
    try h.put("mopm-toolchain.toml", "[toolchain]\nmopm = \"0.0.48\"\nmojo = \"1.0.0\"\n");
    help_out = help_pinned_0_0_48;
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    try t.expectEqual(@as(usize, 1), called("/fake/mopm --help"));
    try t.expectEqual(@as(usize, 1), called("--workspace-root"));
    const lock = h.read(lock_path);
    try t.expect(kit.contains(lock, "MOPM = {\"version\": \"0.0.48\", \"origin\": \"builtin\", \"workspace_root\": True}\n"));
}

test "probe: a mopm whose help does not list the flag is not given it, even at a release that would be expected to have it" {
    for ([_][]const u8{ "0.0.1", "0.0.33", "0.0.40", "9.9.9" }) |v| {
        const h = try fresh();
        defer h.destroy();
        try h.put("mopm-toolchain.toml", try std.fmt.allocPrint(h.a(), "[toolchain]\nmopm = \"{s}\"\nmojo = \"1.0.0\"\n", .{v}));
        try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
        try t.expectEqual(@as(usize, 1), called("/fake/mopm --help"));
        try t.expectEqual(@as(usize, 0), called("--workspace-root"));
        try t.expect(!kit.contains(h.read(lock_path), "workspace_root"));
    }
}

test "probe: a mopm without the flag that fails a plan says what a sibling path dependency needs" {
    const h = try fresh();
    defer h.destroy();
    plan_code = 4;
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqual(@as(usize, 0), called("--workspace-root"));
    try t.expect(kit.contains(r.err, "this mopm does not support --workspace-root (needs a release containing it); pin one in mopm-toolchain.toml"));
    // a mopm that has the flag is not told that
    help_out = help_with;
    const r2 = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expect(!kit.contains(r2.err, "does not support --workspace-root"));
}

test "probe: a mopm that cannot be asked is an error that says so, is not planned with, and nothing is written" {
    const h = try fresh();
    defer h.destroy();
    help_code = 2;
    help_out = help_with; // what it printed does not count when it failed
    var r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "cannot ask /fake/mopm whether it supports --workspace-root: `/fake/mopm --help` exited 2"));
    try t.expectEqual(@as(usize, 0), called("plan --unit-graph"));
    try t.expect(!h.has(lock_path));
    // and a mopm that cannot even run
    help_code = 0;
    exec_error = error.FileNotFound;
    exec_error_on = "mopm";
    r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "cannot ask /fake/mopm whether it supports --workspace-root: `/fake/mopm --help` cannot run: FileNotFound"));
    try t.expect(!h.has(lock_path));
}

test "probe: one binary is asked once per run, and check never runs mopm" {
    const h = try fresh();
    defer h.destroy();
    try h.put("pkgs/other/mopm.toml", fx.manifest);
    try h.put("pkgs/other/mopm.lock", fx.mopm_lock);
    try h.put("pkgs/other/src/base/__init__.mojo", fx.lib);
    try h.put("pkgs/other/tests/test_base.mojo", fx.test_src);
    try h.put("pkgs/other/BUCK", fx.buck);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    try t.expectEqual(@as(usize, 2), called("plan --unit-graph"));
    try t.expectEqual(@as(usize, 1), called("/fake/mopm --help"));
    const before = n_calls;
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check" }).code);
    try t.expectEqual(before, n_calls);
}

/// The repository of `fresh` for a mopm that takes `--workspace-root`, with `util` a sibling of `base` (`pkgs/util`): the graph's paths start at the repository root.
fn rootedWithSibling(h: *kit.Harness, src: []const u8, key: []const u8) !void {
    try h.put("mopm-toolchain.toml", "[toolchain]\nmopm = \"0.0.40\"\nmojo = \"1.0.0\"\n");
    help_out = help_with;
    try h.put("pkgs/util/mopm.toml", "[package]\nname = \"util\"\nversion = \"0.1.0\"\n");
    try h.put("pkgs/util/src/util/__init__.mojo", src);
    plan_graph = try memberGraph(h, src, key, "pkgs/util/src/util", "pkgs/util/src/util/__init__.mojo", "pkgs/base/");
}

test "sync: a mopm that takes --workspace-root is given the repository root, and the table records that its paths start there" {
    const h = try fresh();
    defer h.destroy();
    try rootedWithSibling(h, util_src, "k0");
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), r.code);
    const root = try h.tmp.dir.realpathAlloc(h.a(), ".");
    const want = try std.fmt.allocPrint(h.a(), "/fake/mopm plan --unit-graph --locked --mojo 1.0.0 --workspace-root {s}", .{root});
    try t.expectEqual(@as(usize, 1), called(want));
    // still run in the package's own directory
    for (calls[0..n_calls], 0..) |c, i| {
        if (kit.contains(c, "plan --unit-graph")) try t.expectEqualStrings("package", mopm_dir_seen[i]);
    }
    const lock = h.read(lock_path);
    try t.expect(kit.contains(lock, "MOPM = {\"version\": \"0.0.40\", \"origin\": \"builtin\", \"workspace_root\": True}\n"));
    // the sibling is a path dependency: its manifest, found from the package, is in the table; its sources are not
    try t.expect(kit.contains(lock, "\"../util/mopm.toml\": \""));
    try t.expect(!kit.contains(lock, "pkgs/util/src/util/__init__.mojo"));
    // the package's own paths are the graph's, from the root
    try t.expect(kit.contains(lock, "\"path\": \"pkgs/base/src/base/__init__.mojo\""));
    const c = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 0), c.code);
    // a new test file of the package, and a source edit, are found at the graph's paths
    try h.put("pkgs/base/tests/test_new.mojo", "def main():\n    pass\n");
    try h.put("pkgs/base/src/base/__init__.mojo", "def changed():\n    pass\n");
    const stale = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), stale.code);
    try t.expect(kit.contains(stale.err, "pkgs/base/tests/test_new.mojo is a test file that the table does not know"));
    try t.expect(kit.contains(stale.err, "pkgs/base/src/base/__init__.mojo changed since `buildrules mojo sync`"));
}

test "sync: an older mopm is not given a flag it does not have, and its table says nothing of it" {
    const h = try fresh();
    defer h.destroy();
    try withMember(h);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    try t.expectEqual(@as(usize, 0), called("--workspace-root"));
    try t.expect(kit.contains(h.read(lock_path), "MOPM = {\"version\": \"0.0.1\", \"origin\": \"builtin\"}\n"));
}

test "sync: a path dependency is in the table by identity, so editing its source leaves the table as it was" {
    for ([_]bool{ false, true }) |rooted| {
        const h = try fresh();
        defer h.destroy();
        if (rooted) try rootedWithSibling(h, util_src, "k0") else try withMember(h);
        try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
        const before = h.read(lock_path);
        try t.expect(kit.contains(before, "\"id\": \"util@0.1.0#mojo1.0.0/lib\""));
        try t.expect(kit.contains(before, "\"outputs\": [\"util.mojoc\"]"));
        try t.expect(!kit.contains(before, "util/__init__.mojo"));
        try t.expect(!kit.contains(before, "\"key\": \"k0\""));
        // the package's library imports util, and its test imports the library: their keys hash util's, so they are not in the table either; their
        // sources are
        try t.expect(!kit.contains(before, "\"key\""));
        try t.expect(kit.contains(before, "fb0f853364953595d2c32433c6ffc27013146e9afbbb8e8e12ff472453038116"));
        try t.expect(kit.contains(before, "35516852663564abe5b5bdc74703846e0833e0b69cc1481a51701fbe9543bea5"));

        // util's source changes: mopm prints another hash and another key (and base's library another key)
        const edited = "def util() -> Int:\n    return 2\n";
        try h.put("pkgs/util/src/util/__init__.mojo", edited);
        plan_graph = if (rooted)
            try memberGraph(h, edited, "k1", "pkgs/util/src/util", "pkgs/util/src/util/__init__.mojo", "pkgs/base/")
        else
            try memberGraph(h, edited, "k1", "../util/src/util", "../util/src/util/__init__.mojo", "");
        try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
        try t.expectEqualStrings(before, h.read(lock_path));
        // and the table is still the one the files describe
        try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check" }).code);

        // the package's own source is in the table: editing it is stale
        try h.put("pkgs/base/src/base/__init__.mojo", "def other():\n    pass\n");
        try t.expectEqual(@as(u8, 1), h.run(&.{ "mojo", "check" }).code);
    }
}

test "sync: a path dependency outside the repository root is refused, naming it, and writes nothing" {
    // rooted: the graph's own path leaves the root; older mopm: the package's path does
    const cases = [_]struct { toolchain: []const u8, help: []const u8, root: []const u8, path: []const u8, prefix: []const u8 }{
        .{ .toolchain = "0.0.40", .help = help_with, .root = "../outside/src/util", .path = "../outside/src/util/__init__.mojo", .prefix = "pkgs/base/" },
        .{ .toolchain = "0.0.1", .help = help_without, .root = "../../../outside/src/util", .path = "../../../outside/src/util/__init__.mojo", .prefix = "" },
    };
    for (cases) |c| {
        const h = try fresh();
        defer h.destroy();
        try h.put("mopm-toolchain.toml", try std.fmt.allocPrint(h.a(), "[toolchain]\nmopm = \"{s}\"\nmojo = \"1.0.0\"\n", .{c.toolchain}));
        help_out = c.help;
        plan_graph = try memberGraph(h, util_src, "k0", c.root, c.path, c.prefix);
        const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, "pkgs/base: util@0.1.0#mojo1.0.0/lib lives in "));
        try t.expect(kit.contains(r.err, "outside the repository root"));
        try t.expect(!h.has(lock_path));
    }
}

test "sync: a graph in a layout the committed form cannot edit is refused with the package and the mopm, and nothing is written" {
    const h = try fresh();
    defer h.destroy();
    try withMember(h);
    plan_graph = try std.mem.replaceOwned(u8, h.a(), plan_graph, "    {\n      \"id\": \"util@", "    {\n      \"note\": \"first\",\n      \"id\": \"util@");
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pkgs/base: mopm's unit graph is not in the layout `buildrules mojo sync` reads"));
    try t.expect(kit.contains(r.err, "the pinned mopm 0.0.1"));
    try t.expect(!h.has(lock_path));
}

test "sync: a mopm that was given --workspace-root and failed says so" {
    const h = try fresh();
    defer h.destroy();
    try h.put("mopm-toolchain.toml", "[toolchain]\nmopm = \"0.0.40\"\nmojo = \"1.0.0\"\n");
    help_out = help_with;
    plan_code = 4;
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "`mopm plan --unit-graph --locked --mojo 1.0.0 --workspace-root <the repository root>` exited 4"));
}

test "sync: a path dependency at the repository root itself is a directory like another, and its manifest is found from the package" {
    const h = try fresh();
    defer h.destroy();
    try h.put("mopm-toolchain.toml", "[toolchain]\nmopm = \"0.0.40\"\nmojo = \"1.0.0\"\n");
    help_out = help_with;
    try h.put("mopm.toml", "[package]\nname = \"util\"\nversion = \"0.1.0\"\n");
    try h.put("src/util/__init__.mojo", util_src);
    plan_graph = try memberGraph(h, util_src, "k0", "src/util", "src/util/__init__.mojo", "pkgs/base/");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    try t.expect(kit.contains(h.read(lock_path), "\"../../mopm.toml\": \""));
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check" }).code);
}

test "sync: every path dependency outside the repository root is refused, an absolute path and a bare .. as much as a path up, and the first is named" {
    const h = try fresh();
    defer h.destroy();
    try h.put("mopm-toolchain.toml", "[toolchain]\nmopm = \"0.0.40\"\nmojo = \"1.0.0\"\n");
    help_out = help_with;
    const graph = try memberGraph(h, util_src, "k0", "/opt/outside/src/util", "/opt/outside/src/util/__init__.mojo", "pkgs/base/");
    // a second dependency, also outside, as a bare `..`
    const second = try std.mem.replaceOwned(u8, h.a(), try std.mem.replaceOwned(u8, h.a(), util_graph_unit, "@ROOT@", ".."), "util", "other");
    const two = try std.mem.replaceOwned(u8, h.a(), graph, "\"units\": [\n", try std.mem.concat(h.a(), u8, &.{ "\"units\": [\n", try std.mem.replaceOwned(u8, h.a(), try std.mem.replaceOwned(u8, h.a(), second, "@PATH@", "x"), "@SHA@", "11"), "" }));
    plan_graph = try std.mem.replaceOwned(u8, h.a(), two, "@KEY@", "k9");
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "other@0.1.0#mojo1.0.0/lib lives in .., which is outside the repository root"));
    try t.expect(!kit.contains(r.err, "util@0.1.0#mojo1.0.0/lib lives in /opt"));
    try t.expect(!h.has(lock_path));
}

test "the root .buckconfig: the first include line is the one named, odd lines of it are skipped, and a repository with none is read with the default toolchains cell" {
    const h = try fresh();
    defer h.destroy();
    try h.put(".buckconfig", "<file:first.bcfg>\n<file:second.bcfg>\n[cells\n[cells]\nloose line without a value\ntoolchains = toolchains\n");
    var r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, ".buckconfig has an include line (<file:first.bcfg>)"));
    try t.expect(!kit.contains(r.err, "second.bcfg"));
    try h.tmp.dir.deleteFile(".buckconfig");
    r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pkgs/base/buildrules.mojo.lock.bzl is missing"));
}

test "check: a table that names a path dependency outside the repository root is stale" {
    const h = try fresh();
    defer h.destroy();
    try rootedWithSibling(h, util_src, "k0");
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    const lock = h.read(lock_path);
    try h.put(lock_path, try std.mem.replaceOwned(u8, h.a(), lock, "\"root\": \"pkgs/util/src/util\"", "\"root\": \"../elsewhere/src/util\""));
    const r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "lives in ../elsewhere/src/util, which is outside the repository root"));
}
