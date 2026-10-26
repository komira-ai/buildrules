//! `buildrules mojo sync` and `check` with one unit graph per subdir (rules/mojo/subdirs.bzl). The fake mopm answers `plan --subdir <s>` with the fixture
//! graph made the graph of `<s>` (its toolchain section names the subdir and has its own closure hash), the way mopm's own output differs by subdir.
//! Every test is named for the defect it catches.

const std = @import("std");
const contract = @import("contract.zig");
const ctxm = @import("ctx.zig");
const kit = @import("testkit.zig");
const lockm = @import("mojo_lock.zig");
const Diag = @import("diag.zig").Diag;
const base = @import("mojo_cmd_test.zig");
const t = std.testing;


/// The subdir the fake mopm refuses (exit 3, as mopm does for a lock that lacks its closure), and the one it answers with the linux-64 graph whatever
/// it was asked for.
var refuse_subdir: []const u8 = "";
var ignore_subdir: []const u8 = "";

fn subdirOf(spec: ctxm.Exec) ?[]const u8 {
    for (spec.argv, 0..) |x, i| {
        if (std.mem.eql(u8, x, "--subdir") and i + 1 < spec.argv.len) return spec.argv[i + 1];
    }
    return null;
}

/// The fixture graph as the graph of `subdir`: its toolchain section names it, and its closure hash and compiler differ.
fn graphOf(a: std.mem.Allocator, subdir: []const u8) ![]const u8 {
    return graphFrom(a, base.plan_graph, subdir);
}

fn graphFrom(a: std.mem.Allocator, source: []const u8, subdir: []const u8) ![]const u8 {
    const closure = if (std.mem.eql(u8, subdir, "linux-aarch64")) "11111111" else "22222222";
    const arch = try std.mem.replaceOwned(u8, a, source, "\"subdir\": \"linux-64\"", try std.fmt.allocPrint(a, "\"subdir\": \"{s}\"", .{subdir}));
    const cc = try std.mem.replaceOwned(u8, a, arch, "x86_64-linux-gnu.2.34", try std.fmt.allocPrint(a, "cc-{s}", .{subdir}));
    return std.mem.replaceOwned(u8, a, cc, "fd654c41", closure);
}

/// How the fake mopm spoils the graph it prints for osx-arm64.
const Break = enum { none, not_json, triple_quote, other_mojo, unit_note };
var break_osx: Break = .none;

fn spoiled(a: std.mem.Allocator, graph: []const u8, how: Break) ![]const u8 {
    return switch (how) {
        .none => graph,
        .not_json => "not json",
        .triple_quote => std.mem.replaceOwned(u8, a, graph, "\"package\": \"base@0.1.0\"", "\"package\": \"base@0.1.0'''\""),
        .other_mojo => std.mem.replaceOwned(u8, a, graph, "\"mojo\": \"1.0.0\"", "\"mojo\": \"2.0.0\""),
        .unit_note => std.mem.replaceOwned(u8, a, graph, "    {\n      \"id\": \"util@", "    {\n      \"note\": \"first\",\n      \"id\": \"util@"),
    };
}

fn answer(ctx: *ctxm.Ctx, spec: ctxm.Exec) ?ctxm.ExecResult {
    const sd = subdirOf(spec) orelse return null;
    if (std.mem.eql(u8, sd, refuse_subdir)) return .{ .code = 3 };
    if (std.mem.eql(u8, sd, ignore_subdir)) return null;
    const graph = graphOf(ctx.a, sd) catch return .{ .code = 9 };
    const how: Break = if (std.mem.eql(u8, sd, "osx-arm64")) break_osx else .none;
    return .{ .code = 0, .stdout = spoiled(ctx.a, graph, how) catch return .{ .code = 9 } };
}

/// A mopm.lock that records the toolchain closure of every subdir, as `mopm lock` writes it.
const lock_all = "{\n  \"lock_version\": 2,\n  \"mojo\": [\"1.0.0\"],\n  \"toolchain\": {\"1.0.0\": {\"linux-64\": \"" ++ "a" ** 64 ++ "\", \"linux-aarch64\": \"" ++ "b" ** 64 ++ "\", \"osx-arm64\": \"" ++ "c" ** 64 ++ "\"}},\n  \"channels\": [\"https://conda.mopm.dev/\"],\n  \"packages\": []\n}\n";

/// The package of `fresh`, whose mopm.lock records the closure of every subdir, and a mopm that prints the graph of the subdir it is asked for.
fn withSubdirs() !*kit.Harness {
    const h = try base.fresh();
    try h.put("pkgs/base/mopm.lock", lock_all);
    refuse_subdir = "";
    ignore_subdir = "";
    break_osx = .none;
    base.plan_hook = &answer;
    return h;
}

test "sync: a mopm that takes --subdir is asked for every other subdir and the table holds one graph for each" {
    const h = try withSubdirs();
    defer h.destroy();
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 0), r.code);
    // One plan per other subdir; linux-64 is mopm's default, so it is asked for without the flag and never with it.
    try t.expectEqual(@as(usize, 1), base.called("--subdir linux-aarch64"));
    try t.expectEqual(@as(usize, 1), base.called("--subdir osx-arm64"));
    try t.expectEqual(@as(usize, 0), base.called("--subdir linux-64"));
    const lock = h.read(base.lock_path);
    // The linux-64 graph is where it always was, and each other graph is its own block, named by its subdir.
    try t.expect(kit.contains(lock, "GRAPH_JSON = r'''" ++ base.fx.graph ++ "'''\nGRAPH = json.decode(GRAPH_JSON)\nGRAPH_JSON_LINUX_AARCH64 = r'''{"));
    try t.expect(kit.contains(lock, "'''\nGRAPH_JSON_OSX_ARM64 = r'''{"));
    try t.expect(kit.contains(lock, "\"subdir\": \"linux-aarch64\""));
    try t.expect(kit.contains(lock, "\"subdir\": \"osx-arm64\""));
    try t.expect(kit.contains(lock, "GRAPHS = {\n    \"linux-64\": GRAPH,\n    \"linux-aarch64\": json.decode(GRAPH_JSON_LINUX_AARCH64),\n    \"osx-arm64\": json.decode(GRAPH_JSON_OSX_ARM64),\n}\n"));
    // CLOSURE_SHA256 stays the linux-64 graph's: a reader that knows nothing of subdirs reads the same table.
    try t.expect(kit.contains(lock, "CLOSURE_SHA256 = \"fd654c4192487587d8f8d9402d060e45e218b79da7b8964503a703710e49b15d\"\n"));
    // The glue loads GRAPHS, and it is the glue `check` wants.
    try t.expectEqualStrings(contract.mojo_bzl_text_graphs, h.read("pkgs/base/buildrules.mojo.bzl"));
    try t.expect(kit.contains(h.read("pkgs/base/buildrules.mojo.bzl"), "\"GRAPHS\": GRAPHS,\n"));
    const checked = h.run(&.{ "mojo", "check" });
    try t.expectEqualStrings("", checked.err);
    try t.expectEqual(@as(u8, 0), checked.code);
}

test "sync: the toolchain table has a row for each subdir and the linux-64 row keeps its key" {
    const h = try withSubdirs();
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    const pins = h.read("toolchains/mojo_pins.bzl");
    try t.expect(kit.contains(pins, "MOJO_TOOLCHAINS = {\n    \"1.0.0\": {\n        \"subdir\": \"linux-64\","));
    try t.expect(kit.contains(pins, "    \"1.0.0@linux-aarch64\": {\n        \"subdir\": \"linux-aarch64\",\n        \"cc_target\": \"cc-linux-aarch64\","));
    try t.expect(kit.contains(pins, "    \"1.0.0@osx-arm64\": {\n        \"subdir\": \"osx-arm64\",\n        \"cc_target\": \"cc-osx-arm64\","));
    // linux-64 first, then the order sync asks in.
    const ilinux64 = std.mem.indexOf(u8, pins, "\"1.0.0\": {").?;
    const iaa = std.mem.indexOf(u8, pins, "\"1.0.0@linux-aarch64\"").?;
    const iosx = std.mem.indexOf(u8, pins, "\"1.0.0@osx-arm64\"").?;
    try t.expect(ilinux64 < iaa and iaa < iosx);
    // A second sync writes nothing new, and --check agrees.
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--check", "--buck2", "./buck2" }).code);
}

test "sync: a lock that records the closure of linux-64 alone gives the table it always was, and no subdir is asked for" {
    const h = try withSubdirs();
    defer h.destroy();
    try h.put("pkgs/base/mopm.lock", base.fx.mopm_lock);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    try t.expectEqual(@as(usize, 0), base.called("--subdir"));
    const lock = h.read(base.lock_path);
    try t.expect(!kit.contains(lock, "GRAPHS"));
    try t.expect(!kit.contains(lock, "GRAPH_JSON_"));
    try t.expectEqualStrings(contract.mojo_bzl_text, h.read("pkgs/base/buildrules.mojo.bzl"));
    try t.expect(!kit.contains(h.read("toolchains/mojo_pins.bzl"), "@"));
}

test "sync: the table holds the graphs of the subdirs the lock records and no others" {
    const h = try withSubdirs();
    defer h.destroy();
    const only_osx = try std.mem.replaceOwned(u8, h.a(), lock_all, "\"linux-aarch64\": \"" ++ "b" ** 64 ++ "\", ", "");
    try h.put("pkgs/base/mopm.lock", only_osx);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    try t.expectEqual(@as(usize, 0), base.called("--subdir linux-aarch64"));
    try t.expectEqual(@as(usize, 1), base.called("--subdir osx-arm64"));
    const lock = h.read(base.lock_path);
    try t.expect(kit.contains(lock, "GRAPH_JSON_OSX_ARM64 = r'''{"));
    try t.expect(!kit.contains(lock, "GRAPH_JSON_LINUX_AARCH64"));
    try t.expect(kit.contains(lock, "GRAPHS = {\n    \"linux-64\": GRAPH,\n    \"osx-arm64\": json.decode(GRAPH_JSON_OSX_ARM64),\n}\n"));
    const pins = h.read("toolchains/mojo_pins.bzl");
    try t.expect(kit.contains(pins, "\"1.0.0@osx-arm64\""));
    try t.expect(!kit.contains(pins, "linux-aarch64"));
}

test "sync: a lock that is not a toolchain record of the Mojo version names no subdir" {
    for ([_][]const u8{
        "not json",
        "[]",
        "{}",
        "{\"toolchain\": 1}",
        "{\"toolchain\": {}}",
        "{\"toolchain\": {\"2.0.0\": {\"osx-arm64\": \"x\"}}}",
        "{\"toolchain\": {\"1.0.0\": 5}}",
    }) |lock_text| {
        const h = try withSubdirs();
        defer h.destroy();
        try h.put("pkgs/base/mopm.lock", lock_text);
        try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
        try t.expectEqual(@as(usize, 0), base.called("--subdir"));
        try t.expect(!kit.contains(h.read(base.lock_path), "GRAPHS"));
    }
}

test "sync: a subdir mopm cannot plan stops the sync, names the subdir and says to run mopm lock, and writes nothing" {
    const h = try withSubdirs();
    defer h.destroy();
    refuse_subdir = "osx-arm64";
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "--subdir osx-arm64` exited 3"));
    try t.expect(kit.contains(r.err, "run `mopm lock`, which records the toolchain closure of every subdir"));
    try t.expect(!h.has(base.lock_path));
}

test "sync: a graph for another subdir than the one asked for is refused" {
    const h = try withSubdirs();
    defer h.destroy();
    ignore_subdir = "linux-aarch64";
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "asked mopm for the linux-aarch64 graph and got one for \"linux-64\""));
    try t.expect(!h.has(base.lock_path));
}

test "check: a table whose graph of one subdir is the graph of another is stale" {
    const h = try withSubdirs();
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    const lock = h.read(base.lock_path);
    try h.put(base.lock_path, try std.mem.replaceOwned(u8, h.a(), lock, "\"subdir\": \"osx-arm64\"", "\"subdir\": \"linux-64\""));
    const r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "the graph kept for osx-arm64 is the graph of \"linux-64\""));
}

test "check: a table with graphs per subdir wants the glue that loads them" {
    const h = try withSubdirs();
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    try h.put("pkgs/base/buildrules.mojo.bzl", contract.mojo_bzl_text);
    const r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "buildrules.mojo.bzl is not what sync writes"));
}

test "lock: graphs per subdir render and parse back, and a lock without them renders as before" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = lockm.Lock{
        .schema = 1,
        .mopm_version = "0.0.1",
        .mopm_origin = "builtin",
        .mojo = "1.0.0",
        .closure_sha256 = "a" ** 64,
        .manifests = &.{},
        .graph_json = "{\n  \"unit_graph\": 1\n}\n",
    };
    const text = try lockm.render(a, plain);
    try t.expect(!kit.contains(text, "GRAPHS"));
    var d = Diag.init(a);
    try t.expectEqual(@as(usize, 0), (try lockm.parse(a, "x", text, &d)).extra.len);

    var with = plain;
    with.extra = &.{ .{ .subdir = "linux-aarch64", .graph_json = "{\"a\": 1}" }, .{ .subdir = "osx-arm64", .graph_json = "{\"b\": 2}\n" } };
    const text2 = try lockm.render(a, with);
    // The part up to GRAPH is the plain table's, byte for byte.
    try t.expect(std.mem.startsWith(u8, text2, text));
    const back = try lockm.parse(a, "x", text2, &d);
    try t.expectEqualStrings(plain.graph_json, back.graph_json);
    try t.expectEqual(@as(usize, 2), back.extra.len);
    try t.expectEqualStrings("linux-aarch64", back.extra[0].subdir);
    try t.expectEqualStrings("{\"a\": 1}\n", back.extra[0].graph_json);
    try t.expectEqualStrings("osx-arm64", back.extra[1].subdir);
    try t.expectEqualStrings("{\"b\": 2}\n", back.extra[1].graph_json);
    // A block that is never closed is refused, naming it.
    const cut = text2[0 .. std.mem.lastIndexOf(u8, text2, "'''\nGRAPHS").?];
    try t.expectError(error.Invalid, lockm.parse(a, "x", cut, &d));
}

test "sync: a graph of a subdir that is not a graph, is for another Mojo or is in a layout the committed form cannot edit is refused with the package and the subdir" {
    const cases = [_]struct { how: Break, member: bool, needle: []const u8 }{
        .{ .how = .not_json, .member = false, .needle = "pkgs/base: the GRAPH_JSON block is not JSON" },
        .{ .how = .triple_quote, .member = false, .needle = "pkgs/base: mopm's osx-arm64 graph holds ''' and cannot be embedded in a table" },
        .{ .how = .other_mojo, .member = false, .needle = "pkgs/base: asked mopm for Mojo 1.0.0 (osx-arm64) and got a graph for 2.0.0" },
        .{ .how = .unit_note, .member = true, .needle = "pkgs/base: mopm's osx-arm64 unit graph is not in the layout `buildrules mojo sync` reads" },
    };
    for (cases) |c| {
        const h = try withSubdirs();
        defer h.destroy();
        if (c.member) try base.withMember(h);
        break_osx = c.how;
        const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, c.needle));
        try t.expect(!h.has(base.lock_path));
    }
    break_osx = .none;
}

test "toolchain subdir: the subdir a graph's toolchain names, and nothing when it names none" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parse = struct {
        fn of(al: std.mem.Allocator, text: []const u8) !std.json.Value {
            return std.json.parseFromSliceLeaky(std.json.Value, al, text, .{});
        }
    }.of;
    try t.expectEqualStrings("osx-arm64", lockm.toolchainSubdir(try parse(a, "{\"subdir\": \"osx-arm64\"}")));
    try t.expectEqualStrings("", lockm.toolchainSubdir(try parse(a, "{\"cc_target\": \"x\"}")));
    try t.expectEqualStrings("", lockm.toolchainSubdir(try parse(a, "{\"subdir\": 5}")));
    try t.expectEqualStrings("", lockm.toolchainSubdir(try parse(a, "[]")));
}

test "pins: two graphs of one subdir with different toolchains are refused, naming the subdir, and the rows of other subdirs are not mixed with them" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = Diag.init(a);
    const g1 = try lockm.parseGraph(a, "g1", try graphFrom(a, base.fx.graph, "osx-arm64"), &d);
    const g2 = try lockm.parseGraph(a, "g2", try std.mem.replaceOwned(u8, a, try graphFrom(a, base.fx.graph, "osx-arm64"), "cc-osx-arm64", "cc-other"), &d);
    const g3 = try lockm.parseGraph(a, "g3", try graphFrom(a, base.fx.graph, "linux-aarch64"), &d);
    var d1 = Diag.init(a);
    try t.expectError(error.Invalid, lockm.renderPins(a, &.{
        .{ .mojo = "1.0.0", .toolchain = g1.toolchain, .subdir = "osx-arm64" },
        .{ .mojo = "1.0.0", .toolchain = g2.toolchain, .subdir = "osx-arm64" },
    }, &d1));
    try t.expect(kit.contains(d1.msgs.items[0], "different toolchains for Mojo 1.0.0 on osx-arm64"));
    // The same Mojo on two subdirs is two rows, not a disagreement.
    var d2 = Diag.init(a);
    const ok = try lockm.renderPins(a, &.{
        .{ .mojo = "1.0.0", .toolchain = g1.toolchain, .subdir = "osx-arm64" },
        .{ .mojo = "1.0.0", .toolchain = g3.toolchain, .subdir = "linux-aarch64" },
    }, &d2);
    try t.expect(kit.contains(ok, "\"1.0.0@linux-aarch64\": {"));
    try t.expect(kit.contains(ok, "\"1.0.0@osx-arm64\": {"));
    // With an allocation failing anywhere, the table is rendered or refused, never half-written.
    try kit.sweepRefusalLast(lockm.renderPins, .{@as([]const lockm.Tc, &.{
        .{ .mojo = "1.0.0", .toolchain = g1.toolchain, .subdir = "osx-arm64" },
        .{ .mojo = "1.0.0", .toolchain = g3.toolchain, .subdir = "linux-aarch64" },
        .{ .mojo = "1.0.0", .toolchain = g3.toolchain, .subdir = "linux-64" },
    })});
}

test "lock: with an allocation failing anywhere, a table with graphs per subdir is rendered and read, or refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const with = lockm.Lock{
        .schema = 1,
        .mopm_version = "0.0.1",
        .mopm_origin = "builtin",
        .mojo = "1.0.0",
        .closure_sha256 = "a" ** 64,
        .manifests = &.{},
        .graph_json = "{\n  \"unit_graph\": 1\n}\n",
        .extra = &.{ .{ .subdir = "linux-aarch64", .graph_json = "{\"a\": 1}" }, .{ .subdir = "osx-arm64", .graph_json = "{\"b\": 2}\n" } },
    };
    const Render = struct {
        l: lockm.Lock,
        pub fn call(self: @This(), alloc: std.mem.Allocator) !bool {
            _ = lockm.render(alloc, self.l) catch return false;
            return true;
        }
    };
    try kit.sweepOom(Render{ .l = with }, true);
    try kit.sweepRefusalLast(lockm.parse, .{ "x", try lockm.render(a, with) });
}

test "check: a graph kept for one subdir that is not JSON, or is for another Mojo than the table's, is stale" {
    const h = try withSubdirs();
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--buck2", "./buck2" }).code);
    const lock = h.read(base.lock_path);

    try h.put(base.lock_path, try std.mem.replaceOwned(u8, h.a(), lock, "GRAPH_JSON_OSX_ARM64 = r'''{", "GRAPH_JSON_OSX_ARM64 = r'''not json {"));
    var r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "the GRAPH_JSON block is not JSON"));

    const at = std.mem.indexOf(u8, lock, "GRAPH_JSON_OSX_ARM64 = r'''").?;
    const tail = try std.mem.replaceOwned(u8, h.a(), lock[at..], "\"mojo\": \"1.0.0\"", "\"mojo\": \"2.0.0\"");
    try h.put(base.lock_path, try std.mem.concat(h.a(), u8, &.{ lock[0..at], tail }));
    r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "the osx-arm64 graph is for Mojo 2.0.0 but MOJO is 1.0.0"));
}
