//! Out-of-memory sweeps over inputs of every size. A list or a buffer grows by half again each time it is full, so an allocation that fails
//! is at a different place of the code for each length of its input: a sweep over one input proves the error exits at the places that input
//! grows at, and a sweep over many lengths proves the others. Each sweep fails the allocator at every allocation of a run (testkit.zig,
//! `sweepOom`) and asks of the code what its error exit promises: an error, never a short or half-made answer.

const std = @import("std");
const cargo_cmd = @import("cargo_cmd.zig");
const cargo_lock = @import("cargo_lock.zig");
const Diag = @import("diag.zig").Diag;
const kit = @import("testkit.zig");
const lockfile = @import("lockfile.zig");
const lockm = @import("mojo_lock.zig");
const toml = @import("toml.zig");
const val = @import("val.zig");
const ws = @import("workspace.zig");
const t = std.testing;

const H = "ab" ** 32;

// ---- val: random values, written and read back --------------------------------------------------------------------

fn randomString(r: std.Random, a: std.mem.Allocator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    const n = r.uintLessThan(usize, 14);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const cp: u21 = switch (r.uintLessThan(u8, 8)) {
            0 => r.intRangeAtMost(u21, 0, 31),
            1 => "\"\\\n\r\t\x08\x0c/'"[r.uintLessThan(usize, 9)],
            2 => 0x7f,
            3 => r.intRangeAtMost(u21, 0xa0, 0x7ff),
            4 => r.intRangeAtMost(u21, 0x800, 0xd7ff),
            5 => r.intRangeAtMost(u21, 0x10000, 0x10ffff),
            else => r.intRangeAtMost(u21, 0x20, 0x7e),
        };
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(cp, &buf);
        try out.appendSlice(a, buf[0..len]);
    }
    return out.toOwnedSlice(a);
}

fn randomValue(r: std.Random, a: std.mem.Allocator, depth: usize) !val.Value {
    const pick = r.uintLessThan(u8, if (depth >= 3) 4 else 6);
    return switch (pick) {
        0 => .null,
        1 => val.boolean(r.boolean()),
        2 => val.int(r.int(i32)),
        3 => val.str(try randomString(r, a)),
        4 => blk: {
            var arr = val.newArray(a);
            const n = r.uintLessThan(usize, 6);
            for (0..n) |_| try val.push(&arr, try randomValue(r, a, depth + 1));
            break :blk arr;
        },
        else => blk: {
            var o = val.newObject(a);
            const n = r.uintLessThan(usize, 6);
            const special = [_][]const u8{ "deps", "profile", "k", "" };
            for (0..n) |i| {
                const key = if (r.boolean()) special[i % special.len] else try randomString(r, a);
                try val.put(&o, key, try randomValue(r, a, depth + 1));
            }
            break :blk o;
        },
    };
}

const WriteCall = struct {
    v: val.Value,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        const s = try val.litString(a, self.v, 1);
        const id = try val.contentId(a, self.v, 12);
        var aw = std.Io.Writer.Allocating.init(a);
        try val.canonical(&aw.writer, a, self.v);
        var one = std.Io.Writer.Allocating.init(a);
        try val.oneline(&one.writer, a, self.v);
        return s.len > 0 and id.len == 12 and aw.written().len > 0 and one.written().len > 0;
    }
};

const ReadCall = struct {
    text: []const u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        _ = try val.parseLiteral(a, self.text);
        return true;
    }
};

test "val: a value written as a literal is read back as the same value, canonical form is stable, and every allocation can fail" {
    var prng = std.Random.DefaultPrng.init(0x5eed_0001);
    const r = prng.random();
    var n: usize = 0;
    while (n < 250) : (n += 1) {
        var ar = std.heap.ArenaAllocator.init(t.allocator);
        defer ar.deinit();
        const a = ar.allocator();
        const v = try randomValue(r, a, 0);
        const text = try val.litString(a, v, 0);
        const back = try val.parseLiteral(a, text);
        if (!val.eql(v, back)) {
            std.debug.print("value {d} does not survive its literal:\n{s}\n", .{ n, text });
            return error.LiteralDoesNotRoundTrip;
        }
        const again = try val.litString(a, back, 0);
        try t.expectEqualStrings(text, again);
        var c1 = std.Io.Writer.Allocating.init(a);
        var c2 = std.Io.Writer.Allocating.init(a);
        try val.canonical(&c1.writer, a, v);
        try val.canonical(&c2.writer, a, back);
        try t.expectEqualStrings(c1.written(), c2.written());
        try kit.sweepOom(WriteCall{ .v = v }, true);
        try kit.sweepOom(ReadCall{ .text = text }, true);
    }
}

// ---- toml: documents of every size -------------------------------------------------------------------------------

const TomlCall = struct {
    text: []const u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        return toml.parse(a, self.text).msg.len == 0;
    }
};

test "toml: documents with n keys, elements, tables, escapes and string lengths: no allocation that fails ends in a crash or a different document" {
    var n: usize = 0;
    while (n < 40) : (n += 1) {
        var ar = std.heap.ArenaAllocator.init(t.allocator);
        defer ar.deinit();
        const a = ar.allocator();
        var doc = std.ArrayList(u8).empty;
        try doc.print(a, "name = \"{s}\\n{s}\"\nlit = '{s}'\nml = \"\"\"{s}\\\n   {s}\"\"\"\n", .{ "x" ** 3, "y" ** 5, "z" ** 7, "m" ** 9, "n" ** 11 });
        try doc.appendSlice(a, "list = [");
        for (0..n) |i| try doc.print(a, "{d}, ", .{i});
        try doc.appendSlice(a, "]\ninline = {");
        for (0..n) |i| try doc.print(a, " k{d} = {d},", .{ i, i });
        try doc.appendSlice(a, " last = 1 }\n");
        for (0..n) |i| try doc.print(a, "[t{d}.sub]\nv = \"{s}\"\nw = [[1], [2]]\n", .{ i, "s" ** 20 });
        for (0..n) |i| try doc.print(a, "[[arr]]\nid = {d}\n[arr.meta]\nk = true\n", .{i});
        try doc.print(a, "long = \"{s}\"\n", .{"q" ** 300});
        try kit.sweepOom(TomlCall{ .text = doc.items }, false);
    }
}

// ---- the small readers: lists of n entries ------------------------------------------------------------------------

const LockCall = struct {
    text: []const u8,
    n: usize,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        var d = Diag.init(a);
        const es = try cargo_lock.parse(a, "Cargo.lock", self.text, &d);
        return es.len == self.n;
    }
};

const TableCall = struct {
    text: []const u8,
    n: usize,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        var d = Diag.init(a);
        const l = try lockfile.parse(a, "t.bzl", self.text, &d);
        return l.manifests.len == self.n;
    }
};

const PatternsCall = struct {
    text: []const u8,
    n: usize,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        const ps = try ws.memberPatterns(a, self.text);
        return ps.len == self.n;
    }
};

const MemberCall = struct {
    text: []const u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        const m = try cargo_cmd.ensureMember(a, self.text, "crates/new");
        return m == .edited;
    }
};

const BuckCall = struct {
    text: []const u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        const b = try cargo_cmd.ensureBuck(a, self.text);
        const m = try cargo_cmd.ensureMetadata(a, "[package]\nname = \"p\"\n");
        return b != null and m != null;
    }
};

test "the readers of Cargo.lock, the table, the workspace and the BUCK edits: lists of every length, every allocation failing" {
    var n: usize = 0;
    while (n < 70) : (n += 1) {
        var ar = std.heap.ArenaAllocator.init(t.allocator);
        defer ar.deinit();
        const a = ar.allocator();
        var lock = std.ArrayList(u8).empty;
        try lock.appendSlice(a, "version = 4\n");
        for (0..n) |i| try lock.print(a, "\n[[package]]\nname = \"p{d}\"\nversion = \"1.0.{d}\"\ndependencies = [\n \"a\",\n \"b\",\n]\n", .{ i, i });
        try kit.sweepOom(LockCall{ .text = lock.items, .n = n }, true);
        var table = std.ArrayList(u8).empty;
        try table.print(a, "SCHEMA = 2\nRUSTC = \"1.95.0\"\nTARGET = \"x\"\nCARGO_LOCK_SHA256 = \"{s}\"\nMANIFEST_SHA256 = {{\n", .{H});
        for (0..n) |i| try table.print(a, "    \"crates/c{d}/Cargo.toml\": \"{s}\",\n", .{ i, H });
        try table.appendSlice(a, "}\n");
        try kit.sweepOom(TableCall{ .text = table.items, .n = n }, true);
        var members = std.ArrayList(u8).empty;
        try members.appendSlice(a, "[workspace]\nmembers = [\n");
        for (0..n) |i| try members.print(a, "    \"crates/m{d}\", # {d}\n", .{ i, i });
        try members.appendSlice(a, "]\n");
        try kit.sweepOom(PatternsCall{ .text = members.items, .n = n }, true);
        try kit.sweepOom(MemberCall{ .text = members.items }, true);
        var one_line = std.ArrayList(u8).empty;
        try one_line.appendSlice(a, "[workspace]\nmembers = [");
        for (0..n) |i| try one_line.print(a, "\"m{d}\", ", .{i});
        try one_line.appendSlice(a, "]\n");
        try kit.sweepOom(MemberCall{ .text = one_line.items }, true);
        const pad = try a.alloc(u8, n);
        @memset(pad, 'x');
        try kit.sweepOom(BuckCall{ .text = pad }, true);
    }
}

// ---- the Mojo table and the toolchain table -----------------------------------------------------------------------------

const graph = @embedFile("fixture/mojo.graph.json");

const MojoCall = struct {
    n: usize,
    graph_json: []const u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        var ms = std.ArrayList(lockm.Manifest).empty;
        for (0..self.n) |i| try ms.append(a, .{ .path = try std.fmt.allocPrint(a, "m{d}/mopm.toml", .{i}), .sha256 = H });
        const text = try lockm.render(a, .{ .schema = 1, .mopm_version = "0.0.1", .mopm_origin = "builtin", .mojo = "1.0.0", .closure_sha256 = H, .manifests = ms.items, .graph_json = self.graph_json });
        var d = Diag.init(a);
        const back = try lockm.parse(a, "l", text, &d);
        const g = try lockm.parseGraph(a, "g", back.graph_json, &d);
        return back.manifests.len == self.n and g.units.len >= 1;
    }
};

const ComponentsCall = struct {
    text: []const u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        var d = Diag.init(a);
        const g = try lockm.parseGraph(a, "g", self.text, &d);
        const text = try lockm.renderPins(a, &.{ .{ .mojo = "1.0.0", .toolchain = g.toolchain }, .{ .mojo = "1.1.0", .toolchain = g.toolchain } }, &d);
        return text.len > 0;
    }
};

test "the Mojo tables: n manifests, graphs with n units and n toolchain components, every allocation failing" {
    var n: usize = 0;
    while (n < 40) : (n += 1) {
        var ar = std.heap.ArenaAllocator.init(t.allocator);
        defer ar.deinit();
        const a = ar.allocator();
        // A graph text with and without the newline at its end.
        const text = if (n % 2 == 0) graph else std.mem.trimRight(u8, graph, "\n");
        try kit.sweepOom(MojoCall{ .n = n, .graph_json = text }, false);
        // n components, each a copy of the first.
        const first = std.mem.indexOf(u8, graph, "{\"name\": \"libgcc\"").?;
        const end = std.mem.indexOfPos(u8, graph, first, "}").? + 1;
        var comps = std.ArrayList(u8).empty;
        for (0..n) |i| {
            const one = try std.mem.replaceOwned(u8, a, graph[first..end], "libgcc", try std.fmt.allocPrint(a, "lib{d}", .{i}));
            try comps.print(a, "{s}{s}", .{ if (i == 0) "" else ", ", one });
        }
        // The fixture's own components are kept; the toolchain table is made with the extra ones appended after them.
        const extra = try std.mem.replaceOwned(u8, a, graph, "\"components\": [", try std.fmt.allocPrint(a, "\"components\": [{s}{s}", .{ comps.items, if (n == 0) "" else ", " }));
        try kit.sweepOom(ComponentsCall{ .text = extra }, false);
    }
}

// ---- buckgen: the units a table can hold, in every combination of the optional lines of a BUCK target -----------------------------------------------

const buckgen = @import("buckgen.zig");

const ComboCall = struct {
    units: val.Value,
    overrides: []const u8,
    rustc: ?[]const u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        var d = Diag.init(a);
        const sizes = try buckgen.parseSizes(a, &d, "u 1.0.0 10\nd 1.0.0 10\nr 1.0.0 10\n");
        const ov: ?buckgen.Overrides = if (self.overrides.len == 0) null else try buckgen.loadOverrides(a, &d, "o", self.overrides);
        const out = try buckgen.generate(a, &d, self.units, sizes, ov, .{ .non_default_rustc = self.rustc });
        return out.len > 0;
    }
};

fn comboUnit(a: std.mem.Allocator, mask: u32) !val.Value {
    const custom = mask & 2 != 0;
    const strip: []const u8 = if (mask & 128 != 0) "{\"resolved\": {\"Named\": \"debuginfo\"}}" else "\"none\"";
    const profile = try std.fmt.allocPrint(a,
        "{{\"opt_level\": \"3\", \"lto\": \"false\", \"codegen_backend\": None, \"codegen_units\": {s}, \"debuginfo\": 0, \"split_debuginfo\": None, \"debug_assertions\": False, " ++
            "\"overflow_checks\": False, \"rpath\": False, \"incremental\": False, \"panic\": \"{s}\", \"strip\": {s}}}",
        .{ if (mask & 256 != 0) "16" else "None", if (mask & 64 != 0) "abort" else "unwind", strip });
    const deps: []const u8 = switch ((mask >> 3) & 3) {
        0 => "[]",
        1 => "[[\"d\", \"d-1.0.0:libdddddddd\"]]",
        2 => "[[\"d\", \"d-1.0.0:libdddddddd\"], [\"d\", \"d-1.0.0:libdddddddd\"]]",
        else => "[[\"d\", \"d-1.0.0:libdddddddd\"], [\"r\", \"r-1.0.0:libeeeeeeee\"], [\"build_script_build\", \"r-1.0.0:runeeeeeeee\"]]",
    };
    const cfgs: []const u8 = if (mask & 32 != 0) "[\"feature=\\\"a\\\"\", \"b\"]" else "[]";
    const text = try std.fmt.allocPrint(a,
        "{{\"crate\": \"u\", \"version\": \"1.0.0\", \"source\": \"registry\", \"target_kind\": [\"{s}\"], \"crate_types\": [\"{s}\"], \"target_name\": \"u-x\", \"mode\": \"{s}\", " ++
            "\"side\": \"target\", \"edition\": \"2021\", \"crate_root\": \"src/lib.rs\", \"features\": [], \"cfgs\": {s}, \"profile\": {s}, \"deps\": {s}, {s}\"sha256\": \"{s}\"}}",
        .{ if (custom) "custom-build" else "lib", if (custom) "bin" else "lib", if (custom) "run-custom-build" else "build", cfgs, profile, deps, if (mask & 4 != 0) "\"links\": \"ul\", " else "", H });
    return val.parseLiteral(a, text);
}

/// A registry unit with the plain profile: the dependency the combos refer to.
fn plainUnit(a: std.mem.Allocator, crate: []const u8, mode: []const u8, kind: []const u8, links: []const u8) !val.Value {
    const text = try std.fmt.allocPrint(a,
        "{{\"crate\": \"{s}\", \"version\": \"1.0.0\", \"source\": \"registry\", \"target_kind\": [\"{s}\"], \"crate_types\": [\"lib\"], \"target_name\": \"{s}\", \"mode\": \"{s}\", " ++
            "\"side\": \"target\", \"edition\": \"2021\", \"crate_root\": \"src/lib.rs\", \"features\": [], \"cfgs\": [], {s}" ++
            "\"profile\": {{\"opt_level\": \"0\", \"lto\": \"false\", \"codegen_backend\": None, \"codegen_units\": None, \"debuginfo\": 2, \"split_debuginfo\": None, \"debug_assertions\": True, " ++
            "\"overflow_checks\": True, \"rpath\": False, \"incremental\": False, \"panic\": \"unwind\", \"strip\": \"none\"}}, \"deps\": [], \"sha256\": \"{s}\"}}",
        .{ crate, kind, crate, mode, links, H });
    return val.parseLiteral(a, text);
}

fn comboTable(a: std.mem.Allocator, mask: u32) !val.Value {
    var units = val.newObject(a);
    try units.object.put("u-1.0.0:libuuuuuuuu", try comboUnit(a, mask));
    try units.object.put("d-1.0.0:libdddddddd", try plainUnit(a, "d", "build", "lib", ""));
    try units.object.put("r-1.0.0:libeeeeeeee", try plainUnit(a, "r", "build", "lib", ""));
    try units.object.put("r-1.0.0:runeeeeeeee", try plainUnit(a, "r", "run-custom-build", "custom-build", "\"links\": \"rl\", "));
    return units;
}

test "buckgen: every combination of the optional lines of a unit, with and without overrides and a named compiler, is generated or fails whole under every allocation failure" {
    var mask: u32 = 0;
    while (mask < 512) : (mask += 1) {
        var ar = std.heap.ArenaAllocator.init(t.allocator);
        defer ar.deinit();
        const a = ar.allocator();
        const units = try comboTable(a, mask);
        const overrides: []const u8 = switch (mask % 3) {
            0 => "",
            1 => "{\"crates\": {\"u 1.0.0\": {\"why\": \"w\", \"cfgs\": [\"x\"], \"native_deps\": [\"//a:b\"], \"patch\": {\"add\": []}}, \"d 1.0.0\": {\"why\": \"w\"}}}",
            else => "{\"crates\": {\"u 1.0.0\": {\"why\": \"w\", \"drop_build_script\": true}, \"r 1.0.0\": {\"why\": \"w\", \"drop_build_script\": true}}}",
        };
        try kit.sweepOomRefusal(ComboCall{ .units = units, .overrides = overrides, .rustc = if (mask % 2 == 0) null else "1.85.0" });
    }
}
