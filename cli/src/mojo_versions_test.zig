//! `buildrules mojo sync` and `check` for a package whose mopm.toml lists several Mojo versions: one unit graph per version (`MOJOS` and the
//! `GRAPH_JSON_MOJO_*` blocks). The fake mopm answers `plan --mojo <v> [--subdir <s>]` with the fixture graph made the graph of that version and subdir
//! (its `mojo`, toolchain subdir and closure hash differ). Every test is named for the defect it catches.

const std = @import("std");
const contract = @import("contract.zig");
const ctxm = @import("ctx.zig");
const kit = @import("testkit.zig");
const lockm = @import("mojo_lock.zig");
const plan = @import("mojo_plan.zig");
const base = @import("mojo_cmd_test.zig");
const t = std.testing;

/// What the fake mopm does for one asked version (and subdir, when `only_subdir` is set): exit 3, print the graph of another Mojo, or print a spoiled one.
const How = enum { fine, refuse, other_mojo, not_json, unit_note };
var how: How = .fine;
var how_mojo: []const u8 = "";
var how_subdir: ?[]const u8 = null;

fn argAfter(spec: ctxm.Exec, flag: []const u8) ?[]const u8 {
    for (spec.argv, 0..) |x, i| {
        if (std.mem.eql(u8, x, flag) and i + 1 < spec.argv.len) return spec.argv[i + 1];
    }
    return null;
}

/// The closure hash's first eight characters of each graph: unique per version and subdir, and the fixture's own for 1.0.0 on linux-64.
fn tag(mojo: []const u8, subdir: []const u8) []const u8 {
    if (std.mem.eql(u8, mojo, "1.0.0") and std.mem.eql(u8, subdir, "linux-64")) return "fd654c41";
    if (std.mem.eql(u8, mojo, "1.1.0")) return if (std.mem.eql(u8, subdir, "linux-64")) "c1100000" else "c1102222";
    if (std.mem.eql(u8, mojo, "1.2.0")) {
        if (std.mem.eql(u8, subdir, "linux-64")) return "c1200000";
        return if (std.mem.eql(u8, subdir, "linux-aarch64")) "c1201111" else "c1202222";
    }
    return if (std.mem.eql(u8, subdir, "linux-64")) "e1000000" else if (std.mem.eql(u8, subdir, "linux-aarch64")) "e1001111" else "e1002222";
}

/// The fixture graph as the graph of `mojo` on `subdir`.
fn graphOf(a: std.mem.Allocator, mojo: []const u8, subdir: []const u8) ![]const u8 {
    const g1 = try std.mem.replaceOwned(u8, a, base.plan_graph, "\"mojo\": \"1.0.0\"", try std.fmt.allocPrint(a, "\"mojo\": \"{s}\"", .{mojo}));
    const g2 = try std.mem.replaceOwned(u8, a, g1, "\"subdir\": \"linux-64\"", try std.fmt.allocPrint(a, "\"subdir\": \"{s}\"", .{subdir}));
    return std.mem.replaceOwned(u8, a, g2, "fd654c41", tag(mojo, subdir));
}

/// The closure hash of that graph.
fn closureOf(a: std.mem.Allocator, mojo: []const u8, subdir: []const u8) ![]const u8 {
    const full = "fd654c4192487587d8f8d9402d060e45e218b79da7b8964503a703710e49b15d";
    return std.mem.replaceOwned(u8, a, full, "fd654c41", tag(mojo, subdir));
}

fn answer(ctx: *ctxm.Ctx, spec: ctxm.Exec) ?ctxm.ExecResult {
    const mojo = argAfter(spec, "--mojo") orelse return null;
    const subdir = argAfter(spec, "--subdir") orelse "linux-64";
    const graph = graphOf(ctx.a, mojo, subdir) catch return .{ .code = 9 };
    const hit = how != .fine and std.mem.eql(u8, mojo, how_mojo) and (how_subdir == null or std.mem.eql(u8, subdir, how_subdir.?));
    if (!hit) return .{ .code = 0, .stdout = graph };
    return switch (how) {
        .fine => unreachable,
        .refuse => .{ .code = 3 },
        .other_mojo => .{ .code = 0, .stdout = graphOf(ctx.a, "1.0.0", subdir) catch return .{ .code = 9 } },
        .not_json => .{ .code = 0, .stdout = "not json" },
        .unit_note => .{ .code = 0, .stdout = std.mem.replaceOwned(u8, ctx.a, graph, "    {\n      \"id\": \"util@", "    {\n      \"note\": \"first\",\n      \"id\": \"util@") catch return .{ .code = 9 } },
    };
}

fn lockFor(a: std.mem.Allocator, rows: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\n  \"lock_version\": 2,\n  \"mojo\": [\"1.0.0\", \"1.1.0\", \"1.2.0\"],\n  \"toolchain\": {{{s}}},\n  \"channels\": [\"https://conda.mopm.dev/\"],\n  \"packages\": []\n}}\n", .{rows});
}

const sha = "\": \"" ++ "a" ** 64 ++ "\"";
/// A lock that records linux-64 for each version.
const rows_plain = "\"1.0.0\": {\"linux-64" ++ sha ++ "}, \"1.1.0\": {\"linux-64" ++ sha ++ "}, \"1.2.0\": {\"linux-64" ++ sha ++ "}";
/// A lock that records, besides linux-64, osx-arm64 for 1.0.0 and 1.2.0, and linux-aarch64 for 1.2.0.
const rows_subdirs = "\"1.0.0\": {\"linux-64" ++ sha ++ ", \"osx-arm64" ++ sha ++ "}, \"1.1.0\": {\"linux-64" ++ sha ++ "}, \"1.2.0\": {\"linux-64" ++ sha ++ ", \"linux-aarch64" ++ sha ++ ", \"osx-arm64" ++ sha ++ "}";
/// Only 1.2.0 has osx-arm64.
const rows_osx12 = "\"1.0.0\": {\"linux-64" ++ sha ++ "}, \"1.1.0\": {\"linux-64" ++ sha ++ "}, \"1.2.0\": {\"linux-64" ++ sha ++ ", \"osx-arm64" ++ sha ++ "}";

fn manifestOf(a: std.mem.Allocator, list: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, base.fx.manifest, "mojo = [\"1.0.0\"]", try std.fmt.allocPrint(a, "mojo = [{s}]", .{list}));
}

/// A package whose mopm.toml lists `list` (default 1.0.0 in mopm-toolchain.toml), whose mopm.lock is `lock_rows`, and a mopm that answers per version.
fn several(list: []const u8, lock_rows: []const u8) !*kit.Harness {
    const h = try base.fresh();
    try h.put("pkgs/base/mopm.toml", try manifestOf(h.a(), list));
    try h.put("pkgs/base/mopm.lock", try lockFor(h.a(), lock_rows));
    how = .fine;
    how_mojo = "";
    how_subdir = null;
    base.plan_hook = &answer;
    return h;
}

fn synced3() !*kit.Harness {
    const h = try several("\"1.0.0\", \"1.1.0\", \"1.2.0\"", rows_osx12);
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    if (r.code != 0) std.debug.panic("sync failed: {s}", .{r.err});
    return h;
}

fn expectStale(h: *kit.Harness, msg: []const u8) !void {
    const r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    if (!kit.contains(r.err, msg)) std.debug.panic("check did not say `{s}`; it said:\n{s}", .{ msg, r.err });
}

fn edit(h: *kit.Harness, from: []const u8, to: []const u8) !void {
    const lock = h.read(base.lock_path);
    try t.expect(kit.contains(lock, from));
    try h.put(base.lock_path, try std.mem.replaceOwned(u8, h.a(), lock, from, to));
}

const glue_mojos =
    "# Written by `buildrules mojo sync`. Do not edit: `buildrules check` fails when this differs from what sync writes.\n" ++
    "# Binds the generated table (buildrules.mojo.lock.bzl) to the macro of @buildrules//rules/mojo:defs.bzl.\n" ++
    "load(\"@buildrules//rules/mojo:defs.bzl\", _mojo_package = \"mojo_package\")\n" ++
    "load(\":buildrules.mojo.lock.bzl\", \"CLOSURE_SHA256\", \"GRAPH\", \"MANIFEST_SHA256\", \"MOJO\", \"MOJOS\", \"MOPM\", \"SCHEMA\")\n\n" ++
    "TABLE = {\n" ++
    "    \"CLOSURE_SHA256\": CLOSURE_SHA256,\n" ++
    "    \"GRAPH\": GRAPH,\n" ++
    "    \"MANIFEST_SHA256\": MANIFEST_SHA256,\n" ++
    "    \"MOJO\": MOJO,\n" ++
    "    \"MOJOS\": MOJOS,\n" ++
    "    \"MOPM\": MOPM,\n" ++
    "    \"SCHEMA\": SCHEMA,\n" ++
    "}\n\n" ++
    "def mojo_package(path = \".\", **kwargs):\n" ++
    "    _mojo_package(path = path, table = TABLE, **kwargs)\n";

const glue_graphs_mojos =
    "# Written by `buildrules mojo sync`. Do not edit: `buildrules check` fails when this differs from what sync writes.\n" ++
    "# Binds the generated table (buildrules.mojo.lock.bzl) to the macro of @buildrules//rules/mojo:defs.bzl.\n" ++
    "load(\"@buildrules//rules/mojo:defs.bzl\", _mojo_package = \"mojo_package\")\n" ++
    "load(\":buildrules.mojo.lock.bzl\", \"CLOSURE_SHA256\", \"GRAPH\", \"GRAPHS\", \"MANIFEST_SHA256\", \"MOJO\", \"MOJOS\", \"MOPM\", \"SCHEMA\")\n\n" ++
    "TABLE = {\n" ++
    "    \"CLOSURE_SHA256\": CLOSURE_SHA256,\n" ++
    "    \"GRAPH\": GRAPH,\n" ++
    "    \"GRAPHS\": GRAPHS,\n" ++
    "    \"MANIFEST_SHA256\": MANIFEST_SHA256,\n" ++
    "    \"MOJO\": MOJO,\n" ++
    "    \"MOJOS\": MOJOS,\n" ++
    "    \"MOPM\": MOPM,\n" ++
    "    \"SCHEMA\": SCHEMA,\n" ++
    "}\n\n" ++
    "def mojo_package(path = \".\", **kwargs):\n" ++
    "    _mojo_package(path = path, table = TABLE, **kwargs)\n";

// ---- sync --------------------------------------------------------------------------------------------

test "sync: a three-version manifest writes the default's table as always, a block per other version and a MOJOS table, exactly" {
    const h = try several("\"1.0.0\", \"1.1.0\", \"1.2.0\"", rows_osx12);
    defer h.destroy();
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), r.code);
    const a = h.a();
    // mopm is asked once per version; the default is asked as it always was, and only 1.2.0 has another subdir in the lock.
    try t.expectEqual(@as(usize, 1), base.called("/fake/mopm plan --unit-graph --locked --mojo 1.0.0"));
    try t.expectEqual(@as(usize, 1), base.called("/fake/mopm plan --unit-graph --locked --mojo 1.1.0"));
    try t.expectEqual(@as(usize, 2), base.called("/fake/mopm plan --unit-graph --locked --mojo 1.2.0"));
    try t.expectEqual(@as(usize, 1), base.called("--mojo 1.2.0 --subdir osx-arm64"));
    try t.expectEqual(@as(usize, 0), base.called("--subdir linux"));
    const manifest = h.read("pkgs/base/mopm.toml");
    const want = try std.fmt.allocPrint(a,
        "{s}SCHEMA = 1\nMOPM = {{\"version\": \"0.0.1\", \"origin\": \"builtin\"}}\nMOJO = \"1.0.0\"\nCLOSURE_SHA256 = \"{s}\"\nMANIFEST_SHA256 = {{\n" ++
            "    \"../../mopm-toolchain.toml\": \"{s}\",\n    \"mopm.lock\": \"{s}\",\n    \"mopm.toml\": \"{s}\",\n}}\n" ++
            "GRAPH_JSON = r'''{s}'''\nGRAPH = json.decode(GRAPH_JSON)\n" ++
            "GRAPH_JSON_MOJO_1_1_0 = r'''{s}'''\n" ++
            "GRAPH_JSON_MOJO_1_2_0 = r'''{s}'''\n" ++
            "GRAPH_JSON_MOJO_1_2_0_OSX_ARM64 = r'''{s}'''\n" ++
            "MOJOS = {{\n" ++
            "    \"1.0.0\": {{\"CLOSURE_SHA256\": CLOSURE_SHA256, \"GRAPHS\": {{\"linux-64\": GRAPH}}}},\n" ++
            "    \"1.1.0\": {{\"CLOSURE_SHA256\": \"{s}\", \"GRAPHS\": {{\"linux-64\": json.decode(GRAPH_JSON_MOJO_1_1_0)}}}},\n" ++
            "    \"1.2.0\": {{\"CLOSURE_SHA256\": \"{s}\", \"GRAPHS\": {{\"linux-64\": json.decode(GRAPH_JSON_MOJO_1_2_0), \"osx-arm64\": json.decode(GRAPH_JSON_MOJO_1_2_0_OSX_ARM64)}}}},\n" ++
            "}}\n",
        .{
            lockm.header,
            try closureOf(a, "1.0.0", "linux-64"),
            try ctxm.sha256Hex(a, base.fx.toolchain),
            try ctxm.sha256Hex(a, h.read("pkgs/base/mopm.lock")),
            try ctxm.sha256Hex(a, manifest),
            try graphOf(a, "1.0.0", "linux-64"),
            try graphOf(a, "1.1.0", "linux-64"),
            try graphOf(a, "1.2.0", "linux-64"),
            try graphOf(a, "1.2.0", "osx-arm64"),
            try closureOf(a, "1.1.0", "linux-64"),
            try closureOf(a, "1.2.0", "linux-64"),
        });
    try t.expectEqualStrings(want, h.read(base.lock_path));
    // The glue also loads and passes MOJOS, and is the text of the contract.
    try t.expectEqualStrings(glue_mojos, h.read("pkgs/base/buildrules.mojo.bzl"));
    try t.expectEqualStrings(contract.mojo_bzl_text_mojos, h.read("pkgs/base/buildrules.mojo.bzl"));
    // toolchains/mojo_pins.bzl has the rows of every version's graphs, each version its own key.
    const pins = h.read("toolchains/mojo_pins.bzl");
    try t.expect(kit.contains(pins, "\"1.0.0\": {\n        \"subdir\": \"linux-64\","));
    try t.expect(kit.contains(pins, "\"1.1.0\": {\n        \"subdir\": \"linux-64\","));
    try t.expect(kit.contains(pins, "\"1.2.0\": {\n        \"subdir\": \"linux-64\","));
    try t.expect(kit.contains(pins, "\"1.2.0@osx-arm64\": {\n        \"subdir\": \"osx-arm64\","));
    try t.expect(kit.contains(pins, "\"closure_sha256\": \"" ++ "c1100000" ++ "92487587d8f8d9402d060e45e218b79da7b8964503a703710e49b15d\""));
    // The repository it leaves passes check, and a second sync writes nothing.
    const c = h.run(&.{ "mojo", "check" });
    try t.expectEqualStrings("", c.err);
    try t.expectEqual(@as(u8, 0), c.code);
    const again = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), again.code);
    try t.expect(!kit.contains(again.out, "wrote"));
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--check", "--buck2", "./buck2" }).code);
}

test "sync: the versions follow mopm.toml's order, the default wherever it stands, and each version's subdirs follow the order of the subdirs" {
    const h = try several("\"1.2.0\", \"1.0.0\", \"1.1.0\"", rows_subdirs);
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    const lock = h.read(base.lock_path);
    // The default keeps GRAPH and GRAPHS; its MOJOS entry names them. 1.2.0 lists linux-aarch64 before osx-arm64.
    try t.expect(kit.contains(lock, "GRAPHS = {\n    \"linux-64\": GRAPH,\n    \"osx-arm64\": json.decode(GRAPH_JSON_OSX_ARM64),\n}\n"));
    try t.expect(kit.contains(lock, "}\nGRAPH_JSON_MOJO_1_2_0 = r'''{"));
    try t.expect(kit.contains(lock, "'''\nGRAPH_JSON_MOJO_1_2_0_LINUX_AARCH64 = r'''{"));
    try t.expect(kit.contains(lock, "'''\nGRAPH_JSON_MOJO_1_2_0_OSX_ARM64 = r'''{"));
    try t.expect(kit.contains(lock, "'''\nGRAPH_JSON_MOJO_1_1_0 = r'''{"));
    try t.expect(!kit.contains(lock, "GRAPH_JSON_MOJO_1_0_0"));
    try t.expect(kit.contains(lock, "MOJOS = {\n" ++
        "    \"1.2.0\": {\"CLOSURE_SHA256\": \"c1200000" ++ "92487587d8f8d9402d060e45e218b79da7b8964503a703710e49b15d\", \"GRAPHS\": {\"linux-64\": json.decode(GRAPH_JSON_MOJO_1_2_0), \"linux-aarch64\": json.decode(GRAPH_JSON_MOJO_1_2_0_LINUX_AARCH64), \"osx-arm64\": json.decode(GRAPH_JSON_MOJO_1_2_0_OSX_ARM64)}},\n" ++
        "    \"1.0.0\": {\"CLOSURE_SHA256\": CLOSURE_SHA256, \"GRAPHS\": GRAPHS},\n" ++
        "    \"1.1.0\": {\"CLOSURE_SHA256\": \"c1100000" ++ "92487587d8f8d9402d060e45e218b79da7b8964503a703710e49b15d\", \"GRAPHS\": {\"linux-64\": json.decode(GRAPH_JSON_MOJO_1_1_0)}},\n}\n"));
    // Version blocks sit after the default's subdir blocks and GRAPHS, and the glue loads both GRAPHS and MOJOS.
    try t.expect(std.mem.indexOf(u8, lock, "\nGRAPHS = {").? < std.mem.indexOf(u8, lock, "\nGRAPH_JSON_MOJO_1_2_0 = ").?);
    try t.expectEqualStrings(glue_graphs_mojos, h.read("pkgs/base/buildrules.mojo.bzl"));
    try t.expectEqualStrings(contract.mojo_bzl_text_graphs_mojos, h.read("pkgs/base/buildrules.mojo.bzl"));
    const pins = h.read("toolchains/mojo_pins.bzl");
    for ([_][]const u8{ "\"1.0.0\"", "\"1.0.0@osx-arm64\"", "\"1.1.0\"", "\"1.2.0\"", "\"1.2.0@linux-aarch64\"", "\"1.2.0@osx-arm64\"" }) |key| {
        try t.expect(kit.contains(pins, key));
    }
    const c = h.run(&.{ "mojo", "check" });
    try t.expectEqualStrings("", c.err);
    try t.expectEqual(@as(u8, 0), c.code);
}

test "sync: a default that mopm.toml's list does not hold is refused by name and nothing is written" {
    const h = try several("\"1.1.0\", \"1.2.0\"", rows_plain);
    defer h.destroy();
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pkgs/base: mopm-toolchain.toml names Mojo 1.0.0, which mopm.toml's mojo = [...] does not list (1.1.0, 1.2.0): add it, or name one of those\n"));
    try t.expect(!h.has(base.lock_path));
    try t.expect(!h.has("pkgs/base/buildrules.mojo.bzl"));
    try t.expectEqual(@as(usize, 0), base.called("plan --unit-graph"));
}

test "sync: a one-version manifest, however it names the version, gives the table and glue it always did and asks mopm once" {
    for ([_][]const u8{ "\"1.0.0\"", "" }) |list| {
        const h = try several(list, rows_plain);
        defer h.destroy();
        if (list.len == 0) try h.put("pkgs/base/mopm.toml", "[package]\nname = \"base\"\nversion = \"0.1.0\"\nmojo = \"1.0.0\"\n\n[targets]\nlib = { path = \"src/base\" }\ntests = [\"tests\"]\n");
        try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
        try t.expectEqual(@as(usize, 1), base.called("plan --unit-graph"));
        const lock = h.read(base.lock_path);
        try t.expect(!kit.contains(lock, "MOJOS"));
        try t.expect(!kit.contains(lock, "GRAPH_JSON_MOJO_"));
        try t.expect(kit.contains(lock, "GRAPH_JSON = r'''" ++ base.fx.graph ++ "'''\nGRAPH = json.decode(GRAPH_JSON)\n"));
        try t.expectEqualStrings(contract.mojo_bzl_text, h.read("pkgs/base/buildrules.mojo.bzl"));
        try t.expectEqualStrings("", h.run(&.{ "mojo", "check" }).err);
    }
}

test "listedMojos: the versions of [package] mojo in order, and none for anything that is not a list of strings" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const three = try plan.listedMojos(a, "[package]\nmojo = [\"1.0.0\", \"1.1.0\", \"1.2.0\"]\n");
    try t.expectEqual(@as(usize, 3), three.len);
    try t.expectEqualStrings("1.1.0", three[1]);
    for ([_][]const u8{ "", "not toml [", "[package]\nname = \"x\"\n", "[package]\nmojo = \"1.0.0\"\n", "[package]\nmojo = [1, 2]\n", "[package]\nmojo = [\"1.0.0\", 2]\n", "[toolchain]\nmojo = \"1.0.0\"\n" }) |text| {
        try t.expectEqual(@as(usize, 0), (try plan.listedMojos(a, text)).len);
    }
}

test "sync: a version for which mopm prints another Mojo's graph is refused by name and nothing is written" {
    const h = try several("\"1.0.0\", \"1.1.0\", \"1.2.0\"", rows_plain);
    defer h.destroy();
    how = .other_mojo;
    how_mojo = "1.1.0";
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pkgs/base: asked mopm for Mojo 1.1.0 and got a graph for 1.0.0\n"));
    try t.expect(!h.has(base.lock_path));
    try t.expect(!h.has("pkgs/base/buildrules.mojo.bzl"));
}

test "sync: a subdir graph of another version that is the graph of another Mojo is refused by name" {
    const h = try several("\"1.0.0\", \"1.2.0\"", rows_osx12);
    defer h.destroy();
    how = .other_mojo;
    how_mojo = "1.2.0";
    how_subdir = "osx-arm64";
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pkgs/base: asked mopm for Mojo 1.2.0 (osx-arm64) and got a graph for 1.0.0\n"));
    try t.expect(!h.has(base.lock_path));
}

test "sync: a version mopm cannot plan stops the sync, names the version and says to run mopm lock, and writes nothing" {
    const h = try several("\"1.0.0\", \"1.1.0\", \"1.2.0\"", rows_plain);
    defer h.destroy();
    how = .refuse;
    how_mojo = "1.2.0";
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "--mojo 1.2.0` exited 3"));
    try t.expect(kit.contains(r.err, "run `mopm lock`"));
    try t.expect(!h.has(base.lock_path));
}

test "sync: a graph of another version that is not JSON, or has a unit block sync cannot edit, is refused by name" {
    const h = try several("\"1.0.0\", \"1.1.0\"", rows_plain);
    defer h.destroy();
    try base.withMember(h);
    how = .not_json;
    how_mojo = "1.1.0";
    var r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "the GRAPH_JSON block is not JSON"));
    how = .unit_note;
    r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "pkgs/base: mopm's Mojo 1.1.0 unit graph is not in the layout `buildrules mojo sync` reads (a unit block it cannot edit): the pinned mopm 0.0.1 and this buildrules disagree\n"));
    try t.expect(!h.has(base.lock_path));
}

// ---- check -------------------------------------------------------------------------------------------

test "check: a block whose graph is for another Mojo than its name says is stale" {
    const h = try synced3();
    defer h.destroy();
    const lock = h.read(base.lock_path);
    const at = std.mem.indexOf(u8, lock, "GRAPH_JSON_MOJO_1_1_0 = r'''").?;
    const end = std.mem.indexOfPos(u8, lock, at, "'''\nGRAPH_JSON_MOJO_1_2_0 =").?;
    const spoiled = try std.mem.replaceOwned(u8, h.a(), lock[at..end], "\"mojo\": \"1.1.0\"", "\"mojo\": \"1.3.0\"");
    try h.put(base.lock_path, try std.mem.concat(h.a(), u8, &.{ lock[0..at], spoiled, lock[end..] }));
    try expectStale(h, "STALE: pkgs/base/buildrules.mojo.lock.bzl: the GRAPH_JSON_MOJO_1_1_0 block is the graph for Mojo 1.3.0: run `buildrules mojo sync` and commit the result\n");
}

test "check: a block whose graph is the graph of another subdir than its name says is stale" {
    const h = try synced3();
    defer h.destroy();
    const lock = h.read(base.lock_path);
    const at = std.mem.indexOf(u8, lock, "GRAPH_JSON_MOJO_1_2_0_OSX_ARM64 = r'''").?;
    const spoiled = try std.mem.replaceOwned(u8, h.a(), lock[at..], "\"subdir\": \"osx-arm64\"", "\"subdir\": \"linux-64\"");
    try h.put(base.lock_path, try std.mem.concat(h.a(), u8, &.{ lock[0..at], spoiled }));
    try expectStale(h, "STALE: pkgs/base/buildrules.mojo.lock.bzl: the GRAPH_JSON_MOJO_1_2_0_OSX_ARM64 block is the graph of \"linux-64\", not of osx-arm64: run `buildrules mojo sync` and commit the result\n");
}

test "check: a block that is not a graph is reported" {
    const h = try synced3();
    defer h.destroy();
    try edit(h, "GRAPH_JSON_MOJO_1_1_0 = r'''{", "GRAPH_JSON_MOJO_1_1_0 = r'''not json {");
    try expectStale(h, "the GRAPH_JSON block is not JSON");
}

test "check: a MOJOS entry whose CLOSURE_SHA256 is not its graph's is stale" {
    const h = try synced3();
    defer h.destroy();
    const good = try closureOf(h.a(), "1.1.0", "linux-64");
    try edit(h, try std.fmt.allocPrint(h.a(), "\"1.1.0\": {{\"CLOSURE_SHA256\": \"{s}\"", .{good}), "\"1.1.0\": {\"CLOSURE_SHA256\": \"" ++ "b" ** 64 ++ "\"");
    try expectStale(h, try std.fmt.allocPrint(h.a(), "STALE: pkgs/base/buildrules.mojo.lock.bzl: the MOJOS entry of 1.1.0 has CLOSURE_SHA256 {s}, not the closure its unit graph pins ({s}): the file was edited by hand; run `buildrules mojo sync` and commit the result\n", .{ "b" ** 64, good }));
}

test "check: a table whose MOJOS does not name its MOJO is stale" {
    const h = try synced3();
    defer h.destroy();
    try edit(h, "    \"1.0.0\": {\"CLOSURE_SHA256\": CLOSURE_SHA256, \"GRAPHS\": {\"linux-64\": GRAPH}},\n", "");
    try expectStale(h, "STALE: pkgs/base/buildrules.mojo.lock.bzl: MOJOS does not name MOJO 1.0.0: run `buildrules mojo sync` and commit the result\n");
}

test "check: versions of the table that differ from mopm.toml's list are stale, and a MOJOS table for a one-version manifest is" {
    const h = try synced3();
    defer h.destroy();
    try h.put("pkgs/base/mopm.toml", try manifestOf(h.a(), "\"1.0.0\", \"1.1.0\", \"1.2.0\", \"1.3.0\""));
    try expectStale(h, "STALE: pkgs/base/buildrules.mojo.lock.bzl: the table is for Mojo 1.0.0, 1.1.0, 1.2.0 but mopm.toml's mojo = [...] lists 1.0.0, 1.1.0, 1.2.0, 1.3.0: run `buildrules mojo sync` and commit the result\n");
    try h.put("pkgs/base/mopm.toml", try manifestOf(h.a(), "\"1.2.0\", \"1.0.0\", \"1.1.0\""));
    try expectStale(h, "the table is for Mojo 1.0.0, 1.1.0, 1.2.0 but mopm.toml's mojo = [...] lists 1.2.0, 1.0.0, 1.1.0");
    try h.put("pkgs/base/mopm.toml", try manifestOf(h.a(), "\"1.0.0\", \"1.1.0\""));
    try expectStale(h, "the table is for Mojo 1.0.0, 1.1.0, 1.2.0 but mopm.toml's mojo = [...] lists 1.0.0, 1.1.0");
    try h.put("pkgs/base/mopm.toml", try manifestOf(h.a(), "\"1.0.0\""));
    try expectStale(h, "STALE: pkgs/base/buildrules.mojo.lock.bzl: has a MOJOS table but mopm.toml lists one Mojo version: run `buildrules mojo sync` and commit the result\n");
}

test "check: a one-version table of a manifest that now lists several versions is stale" {
    const h = try base.fresh();
    defer h.destroy();
    base.plan_hook = null;
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    try h.put("pkgs/base/mopm.toml", try manifestOf(h.a(), "\"1.0.0\", \"1.1.0\""));
    try expectStale(h, "STALE: pkgs/base/buildrules.mojo.lock.bzl: the table is for Mojo 1.0.0 but mopm.toml's mojo = [...] lists 1.0.0, 1.1.0: run `buildrules mojo sync` and commit the result\n");
}

test "check: a glue that is not the variant for the table is stale" {
    const h = try synced3();
    defer h.destroy();
    try h.put("pkgs/base/buildrules.mojo.bzl", contract.mojo_bzl_text);
    try expectStale(h, "pkgs/base/buildrules.mojo.bzl is not what sync writes");
    try h.put("pkgs/base/buildrules.mojo.bzl", contract.mojo_bzl_text_graphs_mojos);
    try expectStale(h, "pkgs/base/buildrules.mojo.bzl is not what sync writes");
}

test "check: a version block MOJOS does not name, and a MOJOS entry without its block, are stale" {
    const h = try synced3();
    defer h.destroy();
    try edit(h, "\nGRAPH_JSON_MOJO_1_1_0 = r'''", "\nGRAPH_JSON_MOJO_9_9_9 = r'''");
    const r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "the GRAPH_JSON_MOJO_9_9_9 block is for Mojo 9.9.9, which MOJOS does not name: run `buildrules mojo sync` and commit the result\n"));
    try t.expect(kit.contains(r.err, "MOJOS names Mojo 1.1.0 but the table has no GRAPH_JSON_MOJO_1_1_0 block: run `buildrules mojo sync` and commit the result\n"));
}

test "check: the toolchain table of a table with versions must hold every version's toolchains" {
    const h = try synced3();
    defer h.destroy();
    try h.put("toolchains/mojo_pins.bzl", lockm.pins_empty);
    try expectStale(h, "toolchains/mojo_pins.bzl is not what the unit graphs generate");
}

test "check: a table whose version blocks or MOJOS lines cannot be read is refused by what is wrong" {
    const h = try synced3();
    defer h.destroy();
    const good = h.read(base.lock_path);
    // A block with no name, a block that is not closed, a MOJOS line without the key's quote or without its separator.
    try h.put(base.lock_path, try std.mem.concat(h.a(), u8, &.{ good, "\nGRAPH_JSON_MOJO_x\n" }));
    try expectStale(h, "cannot read the name of the GRAPH_JSON_MOJO_ block");
    const cut = std.mem.indexOf(u8, good, "\nMOJOS = {").?;
    try h.put(base.lock_path, good[0..cut]);
    try expectStale(h, "block is not closed");
    try h.put(base.lock_path, good);
    try edit(h, "\n    \"1.1.0\": {\"CLOSURE_SHA256\"", "\n  \"1.1.0\": {\"CLOSURE_SHA256\"");
    try expectStale(h, "cannot read the MOJOS line   \"1.1.0\": {\"CLOSURE_SHA256\"");
    try h.put(base.lock_path, good);
    try edit(h, "\n    \"1.1.0\": {\"CLOSURE_SHA256\"", "\n    \"1.1.0\" {\"CLOSURE_SHA256\"");
    try expectStale(h, "cannot read the MOJOS line     \"1.1.0\" {\"CLOSURE_SHA256\"");
}

test "check: a MOJOS entry whose closure is cut short or missing is a closure that does not match" {
    const h = try synced3();
    defer h.destroy();
    const good = h.read(base.lock_path);
    const row = try std.fmt.allocPrint(h.a(), "    \"1.1.0\": {{\"CLOSURE_SHA256\": \"{s}\", \"GRAPHS\": {{\"linux-64\": json.decode(GRAPH_JSON_MOJO_1_1_0)}}}},\n", .{try closureOf(h.a(), "1.1.0", "linux-64")});
    try t.expect(kit.contains(good, row));
    try h.put(base.lock_path, try std.mem.replaceOwned(u8, h.a(), good, row, "    \"1.1.0\": {\"CLOSURE_SHA256\": \"abc\n"));
    try expectStale(h, "the MOJOS entry of 1.1.0 has CLOSURE_SHA256 abc, not the closure its unit graph pins");
    try h.put(base.lock_path, try std.mem.replaceOwned(u8, h.a(), good, row, "    \"1.1.0\": {\"CLOSURE_SHA256\": \n"));
    try expectStale(h, "the MOJOS entry of 1.1.0 has CLOSURE_SHA256 , not the closure its unit graph pins");
}
