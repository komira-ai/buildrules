//! `buildrules mojo sync` and `check` of a unit graph of format 6, which names every package `<namespace>/<name>` and gives each unit its `import`
//! (mopm's spec/unit-graph.md, "Names"). The fixtures are mopm 0.0.113's real output: `mojo6.graph.json` (and its graphs of the other subdirs) is
//! `plan --unit-graph --locked` of the package of `mojo.graph.json` named `example/base`, with the `mopm.lock` (lock_version 3) that `mopm lock` wrote for
//! it; `mojo6.rooted.graph.json` is `plan --workspace-root` of a workspace whose package `example/app` has a path dependency `example/util`, a native of its
//! own and a test below its library. Every test is named for the defect it catches.

const std = @import("std");
const contract = @import("contract.zig");
const ctxm = @import("ctx.zig");
const kit = @import("testkit.zig");
const lockm = @import("mojo_lock.zig");
const Diag = @import("diag.zig").Diag;
const base = @import("mojo_cmd_test.zig");
const t = std.testing;

const graph6 = @embedFile("fixture/mojo6.graph.json");
const graph6_aarch64 = @embedFile("fixture/mojo6.linux-aarch64.graph.json");
const graph6_osx = @embedFile("fixture/mojo6.osx-arm64.graph.json");
const lock3 = @embedFile("fixture/mojo6.mopm.lock");
const manifest6 = @embedFile("fixture/mojo6.mopm.toml");
const rooted6 = @embedFile("fixture/mojo6.rooted.graph.json");

const Env = struct {
    arena: std.heap.ArenaAllocator,
    fn init() Env {
        return .{ .arena = std.heap.ArenaAllocator.init(t.allocator) };
    }
    fn deinit(self: *Env) void {
        self.arena.deinit();
    }
    fn a(self: *Env) std.mem.Allocator {
        return self.arena.allocator();
    }
};

fn unitById(g: lockm.Graph, id: []const u8) !lockm.Unit {
    for (g.units) |u| if (std.mem.eql(u8, u.id, id)) return u;
    return error.TestNoSuchUnit;
}

fn expectMsg(d: *Diag, needle: []const u8) !void {
    for (d.msgs.items) |m| if (std.mem.indexOf(u8, m, needle) != null) return;
    std.debug.print("no message contains {s}; messages:\n", .{needle});
    for (d.msgs.items) |m| std.debug.print("  {s}\n", .{m});
    return error.TestExpectedMessage;
}

// ---- the reader --------------------------------------------------------------------------------------------------------------

// Defect caught: mopm 0.0.113's graph refused as a format this buildrules does not read ("update buildrules"), so no package of a namespaced repository syncs.
test "parseGraph: mopm 0.0.113's graph of format 6 is read, each unit with its full name and its import name" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    var d = Diag.init(a);
    const g = try lockm.parseGraph(a, "g", graph6, &d);
    try t.expectEqual(@as(usize, 0), d.count());
    try t.expectEqualStrings("example/base@0.1.0", g.package);
    try t.expectEqual(@as(usize, 2), g.units.len);
    for (g.units) |u| {
        try t.expectEqualStrings("example/base", u.package);
        try t.expectEqualStrings("base", u.import);
    }
    try t.expectEqualStrings("example/base@0.1.0#mojo1.0.0/lib", g.units[0].id);
    try t.expectEqualStrings("src/base", g.units[0].root);
}

// Defect caught: a member's native unit (`native:<namespace>/<name>/<id>`) not found by the entry that says `built`, so a namespaced package with a native of its
// own is refused; or the path dependency's import name taken from the wrong part of its full name.
test "parseGraph: the rooted format 6 graph is read, its native unit found by the entry that says built, and the member's import is its name" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    var d = Diag.init(a);
    const g = try lockm.parseGraph(a, "g", rooted6, &d);
    try t.expectEqual(@as(usize, 0), d.count());
    try t.expectEqualStrings("example/app@0.1.0", g.package);
    const lib = try unitById(g, "example/app@0.1.0#mojo1.0.0/lib");
    try t.expectEqualStrings("app", lib.import);
    try t.expectEqual(@as(usize, 1), lib.built.len);
    try t.expectEqualStrings("native:example/app/shim", lib.built[0].unit);
    try t.expectEqualStrings("libshim.a", lib.built[0].soname);
    const util = try unitById(g, "example/util@0.2.0#mojo1.0.0/lib");
    try t.expectEqualStrings("example/util", util.package);
    try t.expectEqualStrings("util", util.import);
    try t.expectEqualStrings("pkgs/util/src/util", util.root);
    const native = try unitById(g, "native:example/app/shim");
    try t.expectEqualStrings("native", native.kind);
    try t.expectEqualStrings("app", native.import);
}

// Defect caught: a graph of an older format read as if its units had full names, which would move every staged directory and `.mojoc` of a package that did not change.
test "parseGraph: a unit of a graph before format 6 has its package as its import name" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    for ([_][]const u8{ "1", "2", "3", "4", "5" }) |n| {
        var d = Diag.init(a);
        const text = try std.fmt.allocPrint(a, "{{\"unit_graph\": {s}, \"toolchain\": {{}}, \"units\": [{{\"id\": \"u\", \"package\": \"base\"}}]}}", .{n});
        const g = try lockm.parseGraph(a, "g", text, &d);
        try t.expectEqualStrings("base", g.units[0].import);
        try t.expectEqual(@as(usize, 0), d.count());
    }
}

test "importName: the name after the namespace, or the whole of a bare name" {
    try t.expectEqualStrings("json", lockm.importName("example/json"));
    try t.expectEqualStrings("base", lockm.importName("base"));
    try t.expectEqualStrings("", lockm.importName(""));
    try t.expectEqualStrings("", lockm.importName("example/"));
}

const head6 = "{\"unit_graph\": 6, \"toolchain\": {}, \"units\": [";

// Defect caught: a graph mopm would not print (a format 6 unit without its import name, or with one that is not its package's) accepted, so the rules stage a
// library under a name its importers do not use; a format 7 graph read by a buildrules that does not know what it adds.
test "parseGraph: an `import` mopm would not print, and a format above 6, are refused, one reason each" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    const cases = [_]struct { text: []const u8, needle: []const u8 }{
        .{ .text = head6 ++ "{\"id\": \"u\", \"package\": \"example/json\"}]}", .needle = "g: u: a unit of a graph of format 6 has no `import`" },
        .{ .text = head6 ++ "{\"id\": \"u\", \"package\": \"example/json\", \"import\": 5}]}", .needle = "g: u: `import` is not a string" },
        .{ .text = head6 ++ "{\"id\": \"u\", \"package\": \"example/json\", \"import\": \"example\"}]}", .needle = "g: u: `import` is example but the package is example/json" },
        .{ .text = head6 ++ "{\"id\": \"u\", \"package\": \"example/json\", \"import\": \"\"}]}", .needle = "g: u: `import` is  but the package is example/json" },
        // A bare name is no package of a format 6 graph, even when `import` repeats it.
        .{ .text = head6 ++ "{\"id\": \"u\", \"package\": \"json\", \"import\": \"json\"}]}", .needle = "g: u: `import` is json but the package is json: in a graph of format 6 a package is `<namespace>/<name>`" },
        .{ .text = "{\"unit_graph\": 5, \"toolchain\": {}, \"units\": [{\"id\": \"u\", \"package\": \"json\", \"import\": \"json\"}]}", .needle = "g: u: has `import` in a graph of format 5; it is a format 6 key" },
        .{ .text = "{\"unit_graph\": 7}", .needle = "g: unit_graph format is not 1, 2, 3, 4, 5 or 6" },
        .{ .text = "{\"unit_graph\": 7}", .needle = "and 6, which names each package `<namespace>/<name>` and gives each unit its `import`); a newer format needs a newer buildrules: update buildrules" },
    };
    for (cases) |c| {
        var d = Diag.init(a);
        try t.expectError(error.Invalid, lockm.parseGraph(a, "g", c.text, &d));
        try expectMsg(&d, c.needle);
        // Out of memory at any allocation is still a refusal: a message that could not be recorded counts.
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

// ---- sync and check ------------------------------------------------------------------------------------------------------------

/// The package of `fresh` named `example/base`, its lock made by mopm 0.0.113 (lock_version 3, the closure of every subdir), and a mopm that prints 0.0.113's
/// graph of the subdir it is asked for.
fn namespaced() !*kit.Harness {
    const h = try base.fresh();
    try h.put("pkgs/base/mopm.toml", manifest6);
    try h.put("pkgs/base/mopm.lock", lock3);
    base.plan_graph = graph6;
    base.plan_hook = &bySubdir;
    return h;
}

fn bySubdir(_: *ctxm.Ctx, spec: ctxm.Exec) ?ctxm.ExecResult {
    for (spec.argv, 0..) |x, i| {
        if (!std.mem.eql(u8, x, "--subdir") or i + 1 >= spec.argv.len) continue;
        const sd = spec.argv[i + 1];
        if (std.mem.eql(u8, sd, "linux-aarch64")) return .{ .code = 0, .stdout = graph6_aarch64 };
        if (std.mem.eql(u8, sd, "osx-arm64")) return .{ .code = 0, .stdout = graph6_osx };
        return .{ .code = 9 };
    }
    return null;
}

// Defect caught: a lock of lock_version 3 not read for the subdirs it records, or a format 6 graph not written into the table, so a namespaced package keeps a
// stale table (or none) and the rules build what mopm no longer prints.
test "sync: a package of mopm 0.0.113 (lock_version 3, graphs of format 6) gets mopm's graphs verbatim for every subdir, and check passes" {
    const h = try namespaced();
    defer h.destroy();
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqualStrings("", r.err);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqual(@as(usize, 1), base.called("--subdir linux-aarch64"));
    try t.expectEqual(@as(usize, 1), base.called("--subdir osx-arm64"));
    const lock = h.read(base.lock_path);
    try t.expect(kit.contains(lock, "GRAPH_JSON = r'''" ++ graph6 ++ "'''\nGRAPH = json.decode(GRAPH_JSON)\n"));
    try t.expect(kit.contains(lock, "GRAPH_JSON_LINUX_AARCH64 = r'''" ++ graph6_aarch64 ++ "'''\n"));
    try t.expect(kit.contains(lock, "GRAPH_JSON_OSX_ARM64 = r'''" ++ graph6_osx ++ "'''\n"));
    try t.expect(kit.contains(lock, "CLOSURE_SHA256 = \"3ed75e01401544e0d660ee48dc387dacce437e3833ac296d4a0601f28abd4aec\"\n"));
    try t.expectEqualStrings(contract.mojo_bzl_text_graphs, h.read("pkgs/base/buildrules.mojo.bzl"));
    const c = h.run(&.{ "mojo", "check" });
    try t.expectEqualStrings("", c.err);
    try t.expectEqual(@as(u8, 0), c.code);
    // The library is found at `src/<import>`: a new source of it is the table's business, as it is for a package of an older format.
    try h.put("pkgs/base/src/base/extra.mojo", "def f():\n    pass\n");
    const stale = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), stale.code);
    try t.expect(kit.contains(stale.err, "pkgs/base/src/base/extra.mojo is a source of example/base@0.1.0#mojo1.0.0/lib that the table does not know"));
}

// The files of the workspace `mojo6.rooted.graph.json` was made from, byte for byte (the graph pins each by its sha256).
const app_lib = "from util import twice\n\ndef four() -> Int:\n    return twice(2)\n";
const app_in_src = "from app import four\nfrom std.testing import assert_equal\n\ndef test_in_src():\n    assert_equal(four(), 4)\n";
const app_test = "from app import four\nfrom std.testing import assert_equal\n\ndef test_four():\n    assert_equal(four(), 4)\n";
const util_lib = "def twice(x: Int) -> Int:\n    return 2 * x\n";
const shim_c = "int shim_one(void) { return 1; }\n";
const shim_h = "int shim_one(void);\n";

/// The workspace of `mojo6.rooted.graph.json`: `pkgs/app` (`example/app`) imports `pkgs/util` (`example/util`), each library at `src/<import>`; a mopm that
/// takes `--workspace-root` prints the graph.
fn rootedWorkspace() !*kit.Harness {
    const h = try base.fresh();
    try h.put("mopm-toolchain.toml", "[toolchain]\nmopm = \"0.0.40\"\nmojo = \"1.0.0\"\n");
    base.help_out = base.help_with;
    base.plan_graph = rooted6;
    try h.put("pkgs/app/mopm.toml", "[package]\nname = \"example/app\"\nversion = \"0.1.0\"\n");
    try h.put("pkgs/app/mopm.lock", base.fx.mopm_lock);
    try h.put("pkgs/app/BUCK", "load(\":buildrules.mojo.bzl\", \"mojo_package\")\n\nmojo_package(path = \".\")\n");
    try h.put("pkgs/app/src/app/__init__.mojo", app_lib);
    try h.put("pkgs/app/src/app/tests/test_in_src.mojo", app_in_src);
    try h.put("pkgs/app/tests/test_app.mojo", app_test);
    try h.put("pkgs/app/native/shim.c", shim_c);
    try h.put("pkgs/app/native/shim.h", shim_h);
    try h.put("pkgs/util/mopm.toml", "[package]\nname = \"example/util\"\nversion = \"0.2.0\"\n");
    try h.put("pkgs/util/src/util/__init__.mojo", util_lib);
    // Only `app` is synced here: `base` of `fresh` is not part of this workspace.
    try h.tmp.dir.deleteTree("pkgs/base");
    return h;
}

// Defect caught: the library of a rooted package looked for at `src/<namespace>/<name>`, which is no directory, so the package's own directory is not found and a
// new test file below the library (`src/app/tests/test_x.mojo`) is reported as a source of the library the table does not know, not as the test file it is.
test "check: a rooted format 6 package's library is found at src/<import>, so a new test below it is reported as a test, and its member's manifest is in the table" {
    const h = try rootedWorkspace();
    defer h.destroy();
    const r = h.run(&.{ "mojo", "sync", "--buck2", "./buck2" });
    try t.expectEqualStrings("", r.err);
    try t.expectEqual(@as(u8, 0), r.code);
    const lock = h.read("pkgs/app/buildrules.mojo.lock.bzl");
    try t.expect(kit.contains(lock, "\"../util/mopm.toml\": \""));
    try t.expect(kit.contains(lock, "MOPM = {\"version\": \"0.0.40\", \"origin\": \"builtin\", \"workspace_root\": True}\n"));
    const c = h.run(&.{ "mojo", "check" });
    try t.expectEqualStrings("", c.err);
    try t.expectEqual(@as(u8, 0), c.code);
    try h.put("pkgs/app/src/app/tests/test_new.mojo", "def main():\n    pass\n");
    const stale = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), stale.code);
    try t.expect(kit.contains(stale.err, "pkgs/app/src/app/tests/test_new.mojo is a test file that the table does not know"));
    try t.expect(!kit.contains(stale.err, "is a source of example/app@0.1.0#mojo1.0.0/lib"));
}
