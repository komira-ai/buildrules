//! mojo_lock.zig: the table a Mojo package's unit graph is committed as, the reader of mopm's graph, the toolchain table made from graphs, and mopm's
//! test-file rule. Each refusal here is one line of a table or one field of a graph that is wrong in one way, named by the message it must give.

const std = @import("std");
const Diag = @import("diag.zig").Diag;
const kit = @import("testkit.zig");
const lockm = @import("mojo_lock.zig");
const t = std.testing;

const graph = @embedFile("fixture/mojo.graph.json");
const H = "ab" ** 32;

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

fn hasMsg(d: *const Diag, needle: []const u8) bool {
    for (d.msgs.items) |m| if (std.mem.indexOf(u8, m, needle) != null) return true;
    return false;
}

fn expectMsg(d: *const Diag, needle: []const u8) !void {
    if (hasMsg(d, needle)) return;
    std.debug.print("no message holds `{s}`; got {d}:\n", .{ needle, d.count() });
    for (d.msgs.items) |m| std.debug.print("  {s}\n", .{m});
    return error.TestExpectedMessage;
}

// ---- the table -------------------------------------------------------------------------------------------

const lock_l = lockm.Lock{
    .schema = 1,
    .mopm_version = "0.0.1",
    .mopm_origin = "builtin",
    .mojo = "1.0.0",
    .closure_sha256 = H,
    .manifests = &.{ .{ .path = "mopm.lock", .sha256 = H }, .{ .path = "mopm.toml", .sha256 = H } },
    .graph_json = "{\"unit_graph\": 1}",
};

fn lockText(e: *Env) ![]u8 {
    return lockm.render(e.a(), lock_l);
}

test "render: a graph without a trailing newline or with none at all is closed on its own line; a graph that has one is not given another" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    const plain = try lockm.render(a, lock_l);
    try t.expect(std.mem.indexOf(u8, plain, "GRAPH_JSON = r'''{\"unit_graph\": 1}\n'''\nGRAPH = json.decode(GRAPH_JSON)\n") != null);
    var with_nl = lock_l;
    with_nl.graph_json = "{}\n";
    try t.expect(std.mem.indexOf(u8, try lockm.render(a, with_nl), "GRAPH_JSON = r'''{}\n'''\n") != null);
    var none = lock_l;
    none.graph_json = "";
    try t.expect(std.mem.indexOf(u8, try lockm.render(a, none), "GRAPH_JSON = r'''\n'''\n") != null);
    var no_manifests = lock_l;
    no_manifests.manifests = &.{};
    try t.expect(std.mem.indexOf(u8, try lockm.render(a, no_manifests), "MANIFEST_SHA256 = {\n}\n") != null);
}

test "parse: every problem of a table is a message, and the table is refused" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    const good = try lockText(&e);
    const cases = [_]struct { from: []const u8, to: []const u8, needle: []const u8 }{
        .{ .from = "GRAPH_JSON = r'''", .to = "GRAPH = r'''", .needle = "no GRAPH_JSON = r'''...''' block" },
        .{ .from = "\n'''\nGRAPH", .to = "\nGRAPH", .needle = "block is not closed" },
        .{ .from = "SCHEMA = 1\n", .to = "SCHEMA = x\n", .needle = "no SCHEMA" },
        .{ .from = "SCHEMA = 1\n", .to = "", .needle = "no SCHEMA" },
        .{ .from = "MOPM = {\"version\": \"0.0.1\", \"origin\": \"builtin\"}\n", .to = "", .needle = "no MOPM" },
        .{ .from = "MOPM = {\"version\": \"0.0.1\", \"origin\": \"builtin\"}\n", .to = "MOPM = {\"version\": \"0.0.1\n", .needle = "no MOPM" },
        .{ .from = "MOJO = \"1.0.0\"\n", .to = "", .needle = "no MOJO" },
        .{ .from = "CLOSURE_SHA256 = \"" ++ H ++ "\"\n", .to = "CLOSURE_SHA256 = \"zz\"\n", .needle = "CLOSURE_SHA256 is not a sha256" },
        .{ .from = "    \"mopm.lock\": \"" ++ H ++ "\",\n", .to = "    \"mopm.lock\" \"" ++ H ++ "\",\n", .needle = "cannot read the MANIFEST_SHA256 line" },
        .{ .from = "    \"mopm.lock\": \"" ++ H ++ "\",\n", .to = "    mopm.lock\": \"" ++ H ++ "\n", .needle = "cannot read the MANIFEST_SHA256 line" },
        .{ .from = "    \"mopm.lock\": \"" ++ H ++ "\",\n", .to = "    \"mopm.lock\": \"" ++ H ++ ",\n", .needle = "cannot read the MANIFEST_SHA256 line" },
    };
    for (cases) |c| {
        const text = try std.mem.replaceOwned(u8, a, good, c.from, c.to);
        try t.expect(!std.mem.eql(u8, text, good));
        var d = Diag.init(a);
        if (lockm.parse(a, "l.bzl", text, &d)) |_| {
            std.debug.print("accepted a table with: {s}\n", .{c.needle});
            return error.AcceptedABadTable;
        } else |err| try t.expectEqual(error.Invalid, err);
        try expectMsg(&d, c.needle);
        try kit.sweepRefusalLast(lockm.parse, .{ "l.bzl", text });
    }
}

test "workspace_root: rendered as Starlark's True, read back, and a lowercase true is refused instead of read as not rooted" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    var rooted = lock_l;
    rooted.workspace_root = true;
    const text = try lockm.render(a, rooted);
    try t.expect(std.mem.indexOf(u8, text, "MOPM = {\"version\": \"0.0.1\", \"origin\": \"builtin\", \"workspace_root\": True}\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "true") == null);
    var d = Diag.init(a);
    const back = try lockm.parse(a, "l.bzl", text, &d);
    try t.expect(back.workspace_root);
    try t.expectEqual(@as(usize, 0), d.count());
    // a table that is not rooted says nothing about it and reads as not rooted
    const plain = try lockm.render(a, lock_l);
    try t.expect(std.mem.indexOf(u8, plain, "workspace_root") == null);
    try t.expect(!(try lockm.parse(a, "l.bzl", plain, &d)).workspace_root);
    // the spelling Starlark does not have: refused, naming the file, the word and the fix
    const lower = try std.mem.replaceOwned(u8, a, text, "\"workspace_root\": True", "\"workspace_root\": true");
    var d2 = Diag.init(a);
    try t.expectError(error.Invalid, lockm.parse(a, "l.bzl", lower, &d2));
    try expectMsg(&d2, "l.bzl: the MOPM line is not");
    try expectMsg(&d2, "Starlark spells the boolean True");
    try expectMsg(&d2, "buildrules mojo sync");
    try kit.sweepRefusalLast(lockm.parse, .{ "l.bzl", lower });
    // and so is a value that is neither
    const odd = try std.mem.replaceOwned(u8, a, text, "\"workspace_root\": True", "\"workspace_root\": False");
    var d3 = Diag.init(a);
    try t.expectError(error.Invalid, lockm.parse(a, "l.bzl", odd, &d3));
}

test "parse: the lines that are optional in the middle of a table are skipped, not fatal" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    const good = try lockText(&e);
    var d = Diag.init(a);
    // MOPM with the version but no origin, or an origin that is not closed: the version is read, the origin is empty.
    const no_origin = try std.mem.replaceOwned(u8, a, good, ", \"origin\": \"builtin\"", "");
    const l1 = try lockm.parse(a, "l", no_origin, &d);
    try t.expectEqualStrings("0.0.1", l1.mopm_version);
    try t.expectEqualStrings("", l1.mopm_origin);
    const open_origin = try std.mem.replaceOwned(u8, a, good, "\"origin\": \"builtin\"}", "\"origin\": \"builtin");
    const l2 = try lockm.parse(a, "l", open_origin, &d);
    try t.expectEqualStrings("", l2.mopm_origin);
    const l3 = try lockm.parse(a, "l", good, &d);
    try t.expectEqualStrings("builtin", l3.mopm_origin);
    try t.expectEqual(@as(usize, 2), l3.manifests.len);
    try t.expectEqualStrings("{\"unit_graph\": 1}\n", l3.graph_json);
    // Text outside the lines it knows is ignored.
    const noisy = try std.mem.replaceOwned(u8, a, good, "MOJO = ", "OTHER = 1\nMOJO = ");
    _ = try lockm.parse(a, "l", noisy, &d);
}

// ---- the graph -------------------------------------------------------------------------------------------

test "parseGraph: the fixture, and the leniencies: missing optional fields are empty, sources that are not objects with a path and a hash are skipped" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    var d = Diag.init(a);
    const g = try lockm.parseGraph(a, "g", graph, &d);
    try t.expectEqualStrings("base@0.1.0", g.package);
    try t.expectEqualStrings("1.0.0", g.mojo);
    try t.expectEqual(@as(usize, 2), g.units.len);
    try t.expectEqualStrings("lib", g.units[0].kind);
    try t.expectEqualStrings("src/base", g.units[0].root);
    try t.expectEqual(@as(usize, 1), g.units[0].srcs.len);
    const sparse = "{\"unit_graph\": 1, \"toolchain\": {}, \"units\": [{}, {\"id\": 5, \"package\": null, \"kind\": [], \"root\": {}, \"srcs\": {}}, " ++
        "{\"srcs\": [5, {\"path\": 1, \"sha256\": \"x\"}, {\"path\": \"p\", \"sha256\": 2}, {\"path\": \"p\"}, {\"sha256\": \"x\"}, {\"path\": \"ok\", \"sha256\": \"h\"}]}]}";
    const s = try lockm.parseGraph(a, "g", sparse, &d);
    try t.expectEqualStrings("", s.package);
    try t.expectEqualStrings("", s.mojo);
    try t.expectEqualStrings("", s.closure_sha256);
    try t.expectEqual(@as(usize, 3), s.units.len);
    try t.expectEqualStrings("", s.units[1].id);
    try t.expectEqual(@as(usize, 0), s.units[1].srcs.len);
    try t.expectEqual(@as(usize, 1), s.units[2].srcs.len);
    try t.expectEqualStrings("ok", s.units[2].srcs[0].path);
}

test "parseGraph: a graph that is not mopm's format is refused, one reason each" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    const cases = [_]struct { text: []const u8, needle: []const u8 }{
        .{ .text = "not json", .needle = "the GRAPH_JSON block is not JSON" },
        .{ .text = "[]", .needle = "the unit graph is not a JSON object" },
        .{ .text = "\"x\"", .needle = "the unit graph is not a JSON object" },
        .{ .text = "{}", .needle = "no `unit_graph` format number" },
        .{ .text = "{\"unit_graph\": 2}", .needle = "unit_graph format is not 1" },
        .{ .text = "{\"unit_graph\": \"1\"}", .needle = "unit_graph format is not 1" },
        .{ .text = "{\"unit_graph\": 1}", .needle = "no `toolchain` object" },
        .{ .text = "{\"unit_graph\": 1, \"toolchain\": 5}", .needle = "no `toolchain` object" },
        .{ .text = "{\"unit_graph\": 1, \"toolchain\": {}}", .needle = "no `units` array" },
        .{ .text = "{\"unit_graph\": 1, \"toolchain\": {}, \"units\": {}}", .needle = "no `units` array" },
        .{ .text = "{\"unit_graph\": 1, \"toolchain\": {}, \"units\": [5]}", .needle = "a unit is not an object" },
    };
    for (cases) |c| {
        var d = Diag.init(a);
        try t.expectError(error.Invalid, lockm.parseGraph(a, "g", c.text, &d));
        try expectMsg(&d, c.needle);
        const Call = struct {
            text: []const u8,
            pub fn call(self: @This(), x: std.mem.Allocator) !bool {
                var dd = Diag.init(x);
                _ = lockm.parseGraph(x, "g", self.text, &dd) catch return false;
                return true;
            }
        };
        try kit.sweepOomRefusal(Call{ .text = c.text });
    }
}

const GraphCall = struct {
    pub fn call(_: @This(), a: std.mem.Allocator) !bool {
        var d = Diag.init(a);
        const g = try lockm.parseGraph(a, "g", graph, &d);
        return g.units.len == 2;
    }
};

const LockCall = struct {
    text: []const u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        var d = Diag.init(a);
        const l = try lockm.parse(a, "l", self.text, &d);
        return l.manifests.len == 2;
    }
};

const RenderCall = struct {
    pub fn call(_: @This(), a: std.mem.Allocator) !bool {
        const text = try lockm.render(a, lock_l);
        return text.len > 0;
    }
};

test "out of memory: the table and the graph are read and written whole or not at all" {
    var e = Env.init();
    defer e.deinit();
    try kit.sweepOom(GraphCall{}, true);
    try kit.sweepOom(LockCall{ .text = try lockText(&e) }, true);
    try kit.sweepOom(RenderCall{}, true);
}

// ---- the toolchain table -----------------------------------------------------------------------------------

fn toolchainOf(e: *Env, text: []const u8) !std.json.Value {
    var d = Diag.init(e.a());
    return (try lockm.parseGraph(e.a(), "g", text, &d)).toolchain;
}

fn pinsRefused(e: *Env, tc: std.json.Value, mojo: []const u8, needle: []const u8) !void {
    var d = Diag.init(e.a());
    try t.expectError(error.Invalid, lockm.renderPins(e.a(), &.{.{ .mojo = mojo, .toolchain = tc }}, &d));
    try expectMsg(&d, needle);
    const Call = struct {
        tc: std.json.Value,
        mojo: []const u8,
        pub fn call(self: @This(), x: std.mem.Allocator) !bool {
            var dd = Diag.init(x);
            _ = lockm.renderPins(x, &.{.{ .mojo = self.mojo, .toolchain = self.tc }}, &dd) catch return false;
            return true;
        }
    };
    try kit.sweepOomRefusal(Call{ .tc = tc, .mojo = mojo });
}

test "renderPins: the toolchain of a graph is written only when every field of it is a thing a table may carry" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    const swapped = struct {
        fn of(ee: *Env, from: []const u8, to: []const u8) !std.json.Value {
            const text = try std.mem.replaceOwned(u8, ee.a(), graph, from, to);
            try t.expect(!std.mem.eql(u8, text, graph));
            return toolchainOf(ee, text);
        }
    }.of;
    const cases = [_]struct { from: []const u8, to: []const u8, needle: []const u8 }{
        .{ .from = "\"subdir\": \"linux-64\"", .to = "\"subdir\": \"linux 64\"", .needle = "subdir is missing or has characters" },
        .{ .from = "\"subdir\": \"linux-64\"", .to = "\"subdir\": 5", .needle = "subdir is missing" },
        .{ .from = "\"cc_target\": \"x86_64-linux-gnu.2.34\"", .to = "\"cc_target\": \"X86\"", .needle = "cc_target is missing" },
        .{ .from = "\"cc_target\": \"x86_64-linux-gnu.2.34\"", .to = "\"cc_target\": \"\"", .needle = "cc_target is missing" },
        .{ .from = "\"cc_target\": \"x86_64-linux-gnu.2.34\"", .to = "\"cc_target\": \"" ++ "a" ** 65 ++ "\"", .needle = "cc_target is missing" },
        .{ .from = "\"closure_sha256\": \"fd654c", .to = "\"closure_sha256\": \"Zd654c", .needle = "closure_sha256 is missing" },
        .{ .from = "\"zig\": {", .to = "\"zag\": {", .needle = "has no zig" },
        .{ .from = "\"zig\": {\"version\": \"0.12.0\"", .to = "\"zig\": {\"version\": \"-\"", .needle = "zig.version is missing" },
        .{ .from = "https://ziglang.org/download", .to = "ftp://ziglang.org/download", .needle = "zig.url is missing" },
        .{ .from = "\"sha256\": \"c7ae866b", .to = "\"sha256\": \"C7ae866b", .needle = "zig.sha256 is missing" },
        .{ .from = "\"size\": 45480516", .to = "\"size\": 0", .needle = "zig.size is missing" },
        .{ .from = "\"size\": 45480516", .to = "\"size\": \"big\"", .needle = "zig.size is missing" },
        .{ .from = "\"components\": [", .to = "\"componentz\": [", .needle = "has no components" },
        .{ .from = "{\"name\": \"libgcc\"", .to = "5, {\"name\": \"libgcc\"", .needle = "a component is not an object" },
        .{ .from = "\"name\": \"libgcc\"", .to = "\"name\": \"lib gcc\"", .needle = "component name is missing" },
        .{ .from = "\"version\": \"16.2.0\", \"url\": \"https://conda.anaconda.org/conda-forge/linux-64/libgcc", .to = "\"version\": \"!\", \"url\": \"https://conda.anaconda.org/conda-forge/linux-64/libgcc", .needle = "component version is missing" },
        .{ .from = "https://conda.anaconda.org/conda-forge/linux-64/libgcc", .to = "gopher://conda/libgcc", .needle = "component url is missing" },
        .{ .from = "\"size\": 1058444", .to = "\"size\": -3", .needle = "a component has no size" },
    };
    for (cases) |c| try pinsRefused(&e, try swapped(&e, c.from, c.to), "1.0.0", c.needle);
    const good = try toolchainOf(&e, graph);
    try pinsRefused(&e, good, "1.0 0", "Mojo version 1.0 0 has characters a table may not carry");
    try pinsRefused(&e, .null, "1.0.0", "toolchain is not an object");
    try pinsRefused(&e, .{ .integer = 4 }, "1.0.0", "toolchain is not an object");
    // The good one renders, sorted by Mojo version, and an empty list of toolchains is the empty table.
    var d = Diag.init(a);
    const two = try lockm.renderPins(a, &.{ .{ .mojo = "1.1.0", .toolchain = good }, .{ .mojo = "1.0.0", .toolchain = good } }, &d);
    try t.expect(std.mem.indexOf(u8, two, "\"1.0.0\": {").? < std.mem.indexOf(u8, two, "\"1.1.0\": {").?);
    try t.expectEqualStrings(lockm.pins_empty, try lockm.renderPins(a, &.{}, &d));
}

test "renderPins: a toolchain field that is not there at all is the same refusal as one that is wrong" {
    var e = Env.init();
    defer e.deinit();
    const keys = [_]struct { from: []const u8, needle: []const u8 }{
        .{ .from = "\"subdir\": \"linux-64\",", .needle = "subdir is missing" },
        .{ .from = "\"cc_target\": \"x86_64-linux-gnu.2.34\",", .needle = "cc_target is missing" },
        .{ .from = "\"closure_sha256\": \"fd654c4192487587d8f8d9402d060e45e218b79da7b8964503a703710e49b15d\",", .needle = "closure_sha256 is missing" },
        .{ .from = "\"version\": \"0.12.0\", ", .needle = "zig.version is missing" },
        .{ .from = "\"url\": \"https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz\", ", .needle = "zig.url is missing" },
        .{ .from = "\"sha256\": \"c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad\", ", .needle = "zig.sha256 is missing" },
        .{ .from = "{\"name\": \"libgcc\", ", .needle = "component name is missing" },
        .{ .from = "\"version\": \"16.2.0\", \"url\": \"https://conda.anaconda.org/conda-forge/linux-64/libgcc", .needle = "component version is missing" },
        .{ .from = "\"url\": \"https://conda.anaconda.org/conda-forge/linux-64/libgcc-16.2.0-ha9f2e26_7.conda\", ", .needle = "component url is missing" },
        .{ .from = "\"sha256\": \"e031634c3a928f9594eba868bc46ef5230d6571a364a0c63215b06c4563bfcea\", ", .needle = "component sha256 is missing" },
    };
    for (keys) |k| {
        const to: []const u8 = if (std.mem.indexOf(u8, k.from, "\"version\": \"16.2.0\"") != null) "\"url\": \"https://conda.anaconda.org/conda-forge/linux-64/libgcc" else "";
        const text = try std.mem.replaceOwned(u8, e.a(), graph, k.from, if (std.mem.eql(u8, k.needle, "component name is missing")) "{" else to);
        try t.expect(!std.mem.eql(u8, text, graph));
        try pinsRefused(&e, try toolchainOf(&e, text), "1.0.0", k.needle);
    }
}

const PinsCall = struct {
    tc: std.json.Value,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        var d = Diag.init(a);
        const text = try lockm.renderPins(a, &.{ .{ .mojo = "1.0.0", .toolchain = self.tc }, .{ .mojo = "0.9.0", .toolchain = self.tc }, .{ .mojo = "1.0.0", .toolchain = self.tc } }, &d);
        return text.len > 0;
    }
};

test "out of memory: the toolchain table is written whole or not at all" {
    var e = Env.init();
    defer e.deinit();
    try kit.sweepOom(PinsCall{ .tc = try toolchainOf(&e, graph) }, true);
}

// ---- mopm's rule for test files ------------------------------------------------------------------------------

test "isTestPath: tests/**/test_*.mojo and src/**/tests/test_*.mojo, nothing hidden, nothing else" {
    const yes = [_][]const u8{ "tests/test_a.mojo", "tests/a/b/test_c.mojo", "src/tests/test_a.mojo", "src/p/tests/test_a.mojo", "src/p/q/tests/test_x.mojo" };
    for (yes) |p| try t.expect(lockm.isTestPath(p));
    const no = [_][]const u8{
        "",
        "test_a.mojo",
        "tests",
        "tests/test_a.txt",
        "tests/a_test.mojo",
        "tests/helper.mojo",
        "tests/.hidden/test_a.mojo",
        ".tests/test_a.mojo",
        "tests//test_a.mojo",
        "src/test_a.mojo",
        "src/p/test_a.mojo",
        "src/tests/helper.mojo",
        "lib/tests/test_a.mojo",
        "src/p/tests/q/test_a.mojo",
    };
    for (no) |p| try t.expect(!lockm.isTestPath(p));
}
