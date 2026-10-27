//! Unit tests of graph_norm.zig: the committed form of a unit graph holds a path dependency by identity, and nothing else of mopm's text changes.
const std = @import("std");
const N = @import("graph_norm.zig");
const t = std.testing;

/// A graph in mopm's layout: `app` (the package) imports `util`, a member, which imports `base`, a member; `cnative` is a registry package that
/// nothing here imports by path. `@S@` is the sha256 of util's source, `@K@` the key of util, `@A@` the key of app's library.
const template =
    \\{
    \\  "unit_graph": 1,
    \\  "package": "app@1.0.0",
    \\  "mojo": "1.0.0",
    \\  "toolchain": {
    \\    "mojo": "1.0.0",
    \\    "components": [
    \\      {"name": "libgcc", "version": "16.2.0"}
    \\    ]
    \\  },
    \\  "units": [
    \\    {
    \\      "id": "app@1.0.0#mojo1.0.0/lib",
    \\      "package": "app",
    \\      "version": "1.0.0",
    \\      "kind": "lib",
    \\      "root": "src/app",
    \\      "srcs": [
    \\        {"path": "src/app/__init__.mojo", "sha256": "aa"}
    \\      ],
    \\      "deps": ["util@0.1.0#mojo1.0.0/lib", "cnative@0.1.0#mojo1.0.0/lib"],
    \\      "natives": [],
    \\      "profile": {"opt": 1, "assert": "all", "debug": false},
    \\      "outputs": ["app.mojoc"],
    \\      "key": "@A@"
    \\    },
    \\    {
    \\      "id": "base@0.1.0#mojo1.0.0/lib",
    \\      "package": "base",
    \\      "version": "0.1.0",
    \\      "kind": "lib",
    \\      "root": "util/base/src/base",
    \\      "srcs": [
    \\        {"path": "util/base/src/base/__init__.mojo", "sha256": "bb"}
    \\      ],
    \\      "deps": [],
    \\      "natives": [],
    \\      "profile": {"opt": 1, "assert": "all", "debug": false},
    \\      "outputs": ["base.mojoc"],
    \\      "key": "bbkey"
    \\    },
    \\    {
    \\      "id": "cnative@0.1.0#mojo1.0.0/lib",
    \\      "package": "cnative",
    \\      "version": "0.1.0",
    \\      "kind": "prebuilt",
    \\      "artifact": {"url": "https://example.invalid/c.conda", "sha256": "cc", "size": 1},
    \\      "mojoc": "lib/mojo/cnative.mojoc",
    \\      "deps": [],
    \\      "natives": [],
    \\      "key": "cckey"
    \\    },
    \\    {
    \\      "id": "util@0.1.0#mojo1.0.0/lib",
    \\      "package": "util",
    \\      "version": "0.1.0",
    \\      "kind": "lib",
    \\      "root": "util/src/util",
    \\      "srcs": [
    \\        {"path": "util/src/util/__init__.mojo", "sha256": "@S@"}
    \\      ],
    \\      "deps": ["base@0.1.0#mojo1.0.0/lib"],
    \\      "natives": [],
    \\      "profile": {"opt": 1, "assert": "all", "debug": false},
    \\      "outputs": ["util.mojoc"],
    \\      "key": "@K@"
    \\    }
    \\  ]
    \\}
    \\
;

fn graph(a: std.mem.Allocator, sha: []const u8, util_key: []const u8, app_key: []const u8) ![]const u8 {
    var s: []const u8 = template;
    s = try std.mem.replaceOwned(u8, a, s, "@S@", sha);
    s = try std.mem.replaceOwned(u8, a, s, "@K@", util_key);
    return std.mem.replaceOwned(u8, a, s, "@A@", app_key);
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

test "a graph without a path dependency is returned as mopm printed it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lone =
        \\{
        \\  "unit_graph": 1,
        \\  "package": "base@0.1.0",
        \\  "units": [
        \\    {
        \\      "id": "base@0.1.0#mojo1.0.0/lib",
        \\      "package": "base",
        \\      "kind": "lib",
        \\      "root": "src/base",
        \\      "srcs": [
        \\        {"path": "src/base/__init__.mojo", "sha256": "bb"}
        \\      ],
        \\      "deps": [],
        \\      "key": "k"
        \\    }
        \\  ]
        \\}
        \\
    ;
    const got = try N.identityOnly(a, lone);
    try t.expectEqualStrings(lone, got);
    try t.expect(got.ptr == lone.ptr);
}

test "a path dependency is kept by identity: no sources, no key, and the units that import it have no key either" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try N.identityOnly(a, try graph(a, "ss", "uk", "ak"));
    // the members util and base: their identity stays, their sources and keys are gone
    try t.expect(has(got, "\"id\": \"util@0.1.0#mojo1.0.0/lib\""));
    try t.expect(has(got, "\"root\": \"util/src/util\""));
    try t.expect(has(got, "\"root\": \"util/base/src/base\""));
    try t.expect(has(got, "\"deps\": [\"base@0.1.0#mojo1.0.0/lib\"]"));
    try t.expect(has(got, "\"outputs\": [\"util.mojoc\"]"));
    try t.expect(!has(got, "util/src/util/__init__.mojo"));
    try t.expect(!has(got, "util/base/src/base/__init__.mojo"));
    try t.expect(!has(got, "\"uk\""));
    try t.expect(!has(got, "bbkey"));
    // the package's own library keeps its sources; its key hashed util's key, so it is gone
    try t.expect(has(got, "{\"path\": \"src/app/__init__.mojo\", \"sha256\": \"aa\"}"));
    try t.expect(!has(got, "\"ak\""));
    // a registry package is not a path dependency: its key stays
    try t.expect(has(got, "\"key\": \"cckey\""));
    // the last field of a unit has no comma after the key went, and the whole is still JSON
    try t.expect(has(got, "\"outputs\": [\"util.mojoc\"]\n    }"));
    try t.expect(has(got, "\"outputs\": [\"app.mojoc\"]\n    },"));
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, got, .{});
    try t.expectEqual(@as(usize, 4), parsed.object.get("units").?.array.items.len);
}

test "a member's own edit does not change the committed form" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try N.identityOnly(a, try graph(a, "ss", "uk", "ak"));
    const after = try N.identityOnly(a, try graph(a, "another-sha256", "another-key", "another-app-key"));
    try t.expectEqualStrings(before, after);
    // but the package's own source is still in the table: an edit there changes it
    const own = try std.mem.replaceOwned(u8, a, try graph(a, "ss", "uk", "ak"), "\"sha256\": \"aa\"", "\"sha256\": \"a2\"");
    try t.expect(!std.mem.eql(u8, before, try N.identityOnly(a, own)));
}

test "a member's identity is in the committed form: a new version or another root changes it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try graph(a, "ss", "uk", "ak");
    const before = try N.identityOnly(a, base);
    const moved = try std.mem.replaceOwned(u8, a, base, "\"root\": \"util/src/util\"", "\"root\": \"elsewhere/src/util\"");
    try t.expect(!std.mem.eql(u8, before, try N.identityOnly(a, moved)));
    const bumped = try std.mem.replaceOwned(u8, a, base, "\"version\": \"0.1.0\",\n      \"kind\": \"lib\",\n      \"root\": \"util/src/util\"", "\"version\": \"0.2.0\",\n      \"kind\": \"lib\",\n      \"root\": \"util/src/util\"");
    try t.expect(!std.mem.eql(u8, before, try N.identityOnly(a, bumped)));
}

test "a member whose root is relative to the cell is read the same way, whatever the directory" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sibling =
        \\{
        \\  "unit_graph": 1,
        \\  "package": "wire_codec@1.0.0",
        \\  "units": [
        \\    {
        \\      "id": "wire_codec@1.0.0#mojo1.0.0/lib",
        \\      "package": "wire_codec",
        \\      "kind": "lib",
        \\      "root": "src/wire_codec/src/wire_codec",
        \\      "srcs": [],
        \\      "deps": ["wire_json@1.0.0#mojo1.0.0/lib"],
        \\      "key": "k1"
        \\    },
        \\    {
        \\      "id": "wire_json@1.0.0#mojo1.0.0/lib",
        \\      "package": "wire_json",
        \\      "kind": "lib",
        \\      "root": "src/wire_json/src/wire_json",
        \\      "srcs": [
        \\        {"path": "src/wire_json/src/wire_json/__init__.mojo", "sha256": "11"}
        \\      ],
        \\      "deps": [],
        \\      "key": "k2"
        \\    }
        \\  ]
        \\}
        \\
    ;
    const got = try N.identityOnly(a, sibling);
    try t.expect(!has(got, "__init__.mojo"));
    try t.expect(!has(got, "\"key\""));
    try t.expect(has(got, "\"root\": \"src/wire_json/src/wire_json\""));
    // the package's own library: `"srcs": []` on one line stays, its key is gone
    try t.expect(has(got, "\"srcs\": [],"));
    // a one-line `srcs` of a member goes whole
    const one = try std.mem.replaceOwned(u8, a, sibling, "      \"srcs\": [\n        {\"path\": \"src/wire_json/src/wire_json/__init__.mojo\", \"sha256\": \"11\"}\n      ],", "      \"srcs\": [{\"path\": \"x\", \"sha256\": \"11\"}],");
    const one_got = try N.identityOnly(a, one);
    try t.expect(!has(one_got, "\"sha256\": \"11\""));
}

test "text that is not a graph is returned unchanged, and a layout it does not know is an error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "not json", "[1, 2]\n", "{}\n", "{\"package\": \"a@1\"}\n", "{\"package\": \"a@1\", \"units\": 3}\n", "{\"package\": 3, \"units\": []}\n" }) |s| {
        try t.expectEqualStrings(s, try N.identityOnly(a, s));
    }
    // a member whose block is not in mopm's layout (no id on the second line)
    const odd = try std.mem.replaceOwned(u8, a, try graph(a, "ss", "uk", "ak"), "    {\n      \"id\": \"util@0.1.0#mojo1.0.0/lib\",", "    {\n      \"note\": \"first\",\n      \"id\": \"util@0.1.0#mojo1.0.0/lib\",");
    try t.expectError(error.Broken, N.identityOnly(a, odd));
    // a block that is closed at another indent than mopm's
    const open = try std.mem.replaceOwned(u8, a, try graph(a, "ss", "uk", "ak"), "    }\n  ]", "}\n  ]");
    try t.expectError(error.Broken, N.identityOnly(a, open));
    // a member whose sources are written at another indent than mopm's: they would stay in the table, so that is refused too
    const indent = try std.mem.replaceOwned(u8, a, try graph(a, "ss", "uk", "ak"), "      \"srcs\": [\n        {\"path\": \"util/src/util/__init__.mojo\", \"sha256\": \"ss\"}\n      ],", "        \"srcs\": [\n        {\"path\": \"util/src/util/__init__.mojo\", \"sha256\": \"ss\"}\n        ],");
    try t.expectError(error.Broken, N.identityOnly(a, indent));
    // and a key at another indent
    const key = try std.mem.replaceOwned(u8, a, try graph(a, "ss", "uk", "ak"), "      \"key\": \"uk\"", "       \"key\": \"uk\"");
    try t.expectError(error.Broken, N.identityOnly(a, key));
    // a srcs list that is closed at another indent than mopm's
    const srcs = try std.mem.replaceOwned(u8, a, try graph(a, "ss", "uk", "ak"), "      ],\n      \"deps\": [\"base@", "        ],\n      \"deps\": [\"base@");
    try t.expectError(error.Broken, N.identityOnly(a, srcs));
}

test "units that are not objects, or lack the fields that tell a member, are left alone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const odd = "{\"package\": \"a@1\", \"units\": [3, {\"package\": \"x\"}, {\"id\": \"i\"}, {\"id\": \"i\", \"kind\": \"lib\"}, {\"id\": \"i\", \"kind\": \"lib\", \"package\": \"x\"}, {\"id\": \"p\", \"kind\": \"prebuilt\", \"package\": \"x\", \"root\": \"r\", \"deps\": 4}]}\n";
    try t.expectEqualStrings(odd, try N.identityOnly(a, odd));
}

test "every allocation failing in turn is an error, never a wrong graph" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const text = try graph(arena.allocator(), "ss", "uk", "ak");
    const want = try N.identityOnly(arena.allocator(), text);
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        var inner = std.heap.ArenaAllocator.init(t.allocator);
        defer inner.deinit();
        var fa = t.FailingAllocator.init(inner.allocator(), .{ .fail_index = i });
        if (N.identityOnly(fa.allocator(), text)) |got| {
            try t.expect(!fa.has_induced_failure);
            try t.expectEqualStrings(want, got);
            return;
        } else |e| try t.expectEqual(error.OutOfMemory, e);
    }
    return error.SweepDidNotEnd;
}

// A format 3 graph (docs/contract.md, section 12.11): a top-level `system_libs` array of objects at the indentation of the units, and `loads` on a unit. Defect caught:
// the layout of the array taken for a unit block (a graph with a member refused as "a layout this function does not know"), the entries edited or dropped, the
// `loads` of a unit lost.
const system_libs =
    \\  "system_libs": [
    \\    {
    \\      "name": "libsqlite",
    \\      "version": "3.54.1",
    \\      "build": "h0737f62_101",
    \\      "url": "https://conda.anaconda.org/conda-forge/linux-64/libsqlite-3.54.1-h0737f62_101.conda",
    \\      "sha256": "c294029f893d05286f1061bbab85b820f1eea73dd859af4bcc619197bcc34810",
    \\      "size": 980491
    \\    }
    \\  ],
    \\
;

test "a format 3 graph with a path dependency: the system_libs array is not a unit and is kept, wherever it stands, and loads stay" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try graph(a, "ss", "kk", "aakey");
    const with_loads = try std.mem.replaceOwned(u8, a, base, "      \"natives\": [],\n      \"profile\": {\"opt\": 1, \"assert\": \"all\", \"debug\": false},\n      \"outputs\": [\"app.mojoc\"],", "      \"natives\": [],\n      \"loads\": [\"libsqlite\"],\n      \"profile\": {\"opt\": 1, \"assert\": \"all\", \"debug\": false},\n      \"outputs\": [\"app.mojoc\"],");
    try t.expect(has(with_loads, "\"loads\""));
    const before = try std.mem.replaceOwned(u8, a, with_loads, "  \"units\": [\n", system_libs ++ "  \"units\": [\n");
    const tail = try std.fmt.allocPrint(a, "    }}\n  ],\n{s}\n}}\n", .{std.mem.trimRight(u8, system_libs, ",\n")});
    const after = try std.mem.replaceOwned(u8, a, with_loads, "    }\n  ]\n}\n", tail);
    for ([_][]const u8{ before, after }) |g| {
        const got = try N.identityOnly(a, g);
        // the member's source and key are gone, as without the array
        try t.expect(!has(got, "\"util/src/util/__init__.mojo\""));
        try t.expect(!has(got, "\"key\": \"kk\""));
        // the entry is exactly what mopm printed, and the unit's loads are there
        try t.expect(has(got, "      \"sha256\": \"c294029f893d05286f1061bbab85b820f1eea73dd859af4bcc619197bcc34810\",\n      \"size\": 980491\n    }\n"));
        try t.expect(has(got, "\"loads\": [\"libsqlite\"],"));
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, got, .{});
        try t.expectEqual(@as(usize, 1), parsed.object.get("system_libs").?.array.items.len);
        try t.expectEqual(@as(usize, 4), parsed.object.get("units").?.array.items.len);
    }
}
