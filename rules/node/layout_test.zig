const std = @import("std");
const layout = @import("layout.zig");
const sri = @import("sri.zig");
const tartest = @import("tartest.zig");

const Pkg = struct {
    path: []const u8,
    name: []const u8,
    version: []const u8,
    /// More members of the lockfile entry, each starting with a comma.
    extra: []const u8 = "",
    files: []const tartest.Entry = &.{},
    /// The tarball's bytes when they are not the ones the integrity is of.
    other_bytes: ?[]const u8 = null,
    no_tarball: bool = false,
    /// The pinned lock's sri512 when it is not the lockfile's.
    pinned: ?[]const u8 = null,
    no_lock_entry_integrity: bool = false,
};

const Result = struct {
    failed: bool,
    msg: []const u8,
    tmp: std.testing.TmpDir,
    out: std.fs.Dir,

    fn deinit(r: *Result) void {
        r.out.close();
        r.tmp.cleanup();
    }
};

fn lay(a: std.mem.Allocator, pkgs: []const Pkg) !Result {
    return layWith(a, pkgs, false);
}

/// The same fixtures, assembled from per-package unpacked directories (`unpack` first, then the tree).
fn layDirs(a: std.mem.Allocator, pkgs: []const Pkg) !Result {
    return layWith(a, pkgs, true);
}

/// The spec of a lockfile of `pkgs`, with their tarballs (or unpacked directories) in `tmp`.
const Built = struct {
    tmp: std.testing.TmpDir,
    base: []const u8,
    spec: layout.Spec,
    unpack_failed: bool,
    unpack_msg: []const u8,
};

fn build(a: std.mem.Allocator, pkgs: []const Pkg, use_dirs: bool) !Built {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(a, ".");
    var lock = std.ArrayList(u8).empty;
    try lock.appendSlice(a, "{\"lockfileVersion\":3,\"packages\":{\"\":{\"name\":\"root\"}");
    var spec = layout.Spec{
        .lockfile = "",
        .tarballs = std.StringHashMap([]const u8).init(a),
        .sri512 = std.StringHashMap([]const u8).init(a),
        .dirs = if (use_dirs) std.StringHashMap([]const u8).init(a) else null,
    };
    var unpack_msg = tartest.Sink{ .a = a };
    var unpack_failed = false;
    for (pkgs, 0..) |p, i| {
        const good = try tartest.tgz(a, p.name, p.version, p.files);
        const integrity = try sri.of(a, good);
        const key = try std.fmt.allocPrint(a, "{s}@{s}", .{ p.name, p.version });
        const integ_json = if (p.no_lock_entry_integrity) "" else try std.fmt.allocPrint(a, ",\"integrity\":\"{s}\"", .{integrity});
        try lock.writer(a).print(",\"{s}\":{{\"version\":\"{s}\"{s}{s}", .{ p.path, p.version, integ_json, p.extra });
        try lock.appendSlice(a, "}");
        if (std.mem.indexOf(u8, p.extra, "\"name\"") == null and !std.mem.endsWith(u8, p.path, p.name)) {
            // an alias or a path whose last segment is not the name needs "name"
            return error.TestFixture;
        }
        if (use_dirs and !p.no_tarball) {
            const sub = try std.fmt.allocPrint(a, "pk{d}", .{i});
            try tmp.dir.makePath(sub);
            var d = try tmp.dir.openDir(sub, .{ .iterate = true });
            defer d.close();
            layout.unpackOne(a, p.other_bytes orelse good, integrity, p.name, p.version, d, &unpack_msg) catch |e| switch (e) {
                error.Failed => unpack_failed = true,
                else => return e,
            };
            try spec.dirs.?.put(key, try std.fs.path.join(a, &.{ base, sub }));
        } else if (!p.no_tarball) {
            const file = try std.fmt.allocPrint(a, "t{d}.tgz", .{i});
            try tmp.dir.writeFile(.{ .sub_path = file, .data = p.other_bytes orelse good });
            try spec.tarballs.put(key, try std.fs.path.join(a, &.{ base, file }));
        }
        try spec.sri512.put(key, p.pinned orelse integrity);
    }
    try lock.appendSlice(a, "}}");
    spec.lockfile = lock.items;
    return .{ .tmp = tmp, .base = base, .spec = spec, .unpack_failed = unpack_failed, .unpack_msg = unpack_msg.text.items };
}

fn layWith(a: std.mem.Allocator, pkgs: []const Pkg, use_dirs: bool) !Result {
    const b = try build(a, pkgs, use_dirs);
    var tmp = b.tmp;
    errdefer tmp.cleanup();
    try tmp.dir.makePath("out");
    const out = try tmp.dir.openDir("out", .{ .iterate = true });
    const out_path = try std.fs.path.join(a, &.{ b.base, "out" });
    var msg = tartest.Sink{ .a = a };
    var failed = false;
    layout.assemble(a, b.spec, out, out_path, &msg) catch |e| switch (e) {
        error.Failed => failed = true,
        else => return e,
    };
    if (b.unpack_failed) return .{ .failed = true, .msg = try std.mem.concat(a, u8, &.{ b.unpack_msg, msg.text.items }), .tmp = tmp, .out = out };
    return .{ .failed = failed, .msg = msg.text.items, .tmp = tmp, .out = out };
}

fn expectMsg(r: Result, needle: []const u8) !void {
    try std.testing.expect(r.failed);
    if (std.mem.indexOf(u8, r.msg, needle) == null) {
        std.debug.print("message:\n{s}\nwant: {s}\n", .{ r.msg, needle });
        return error.TestExpectedMessage;
    }
}

fn read(a: std.mem.Allocator, r: *Result, path: []const u8) ![]u8 {
    return r.out.readFileAlloc(a, path, 1 << 20);
}

test "nested, hoisted, scoped and aliased packages land at their lockfile paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{
        .{ .path = "node_modules/fx-a", .name = "fx-a", .version = "1.0.0", .files = &.{.{ .name = "package/index.js", .data = "a1" }} },
        .{ .path = "node_modules/fx-a/node_modules/fx-b", .name = "fx-b", .version = "2.0.0", .files = &.{.{ .name = "package/index.js", .data = "b2" }} },
        .{ .path = "node_modules/fx-b", .name = "fx-b", .version = "1.0.0", .files = &.{.{ .name = "package/index.js", .data = "b1" }} },
        .{ .path = "node_modules/@fx/scoped", .name = "@fx/scoped", .version = "3.0.0", .files = &.{.{ .name = "package/index.js", .data = "s3" }} },
        .{ .path = "node_modules/alias-b", .name = "fx-b", .version = "1.0.0", .extra = ",\"name\":\"fx-b\"", .files = &.{.{ .name = "package/index.js", .data = "b1" }} },
    });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    try std.testing.expectEqualStrings("a1", try read(a, &r, "fx-a/index.js"));
    try std.testing.expectEqualStrings("b2", try read(a, &r, "fx-a/node_modules/fx-b/index.js"));
    try std.testing.expectEqualStrings("b1", try read(a, &r, "fx-b/index.js"));
    try std.testing.expectEqualStrings("s3", try read(a, &r, "@fx/scoped/index.js"));
    try std.testing.expectEqualStrings("b1", try read(a, &r, "alias-b/index.js"));
    const report = try read(a, &r, ".buildrules-node-modules.json");
    try std.testing.expect(std.mem.indexOf(u8, report, "\"installed\": 5") != null);
}

test "bin: a relative link in the node_modules that holds the package, to an executable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{
        .{ .path = "node_modules/tool", .name = "tool", .version = "1.0.0", .extra = ",\"bin\":{\"tool\":\"./bin/tool.js\"}", .files = &.{.{ .name = "package/bin/tool.js", .mode = 0o644, .data = "x" }} },
        .{ .path = "node_modules/tool/node_modules/inner", .name = "inner", .version = "1.0.0", .extra = ",\"bin\":\"cli.js\"", .files = &.{.{ .name = "package/cli.js", .data = "y" }} },
        .{ .path = "node_modules/@s/scoped", .name = "@s/scoped", .version = "1.0.0", .extra = ",\"bin\":\"cli.js\"", .files = &.{.{ .name = "package/cli.js", .data = "z" }} },
    });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("../tool/bin/tool.js", try r.out.readLink(".bin/tool", &buf));
    try std.testing.expectEqualStrings("../inner/cli.js", try r.out.readLink("tool/node_modules/.bin/inner", &buf));
    try std.testing.expectEqualStrings("../@s/scoped/cli.js", try r.out.readLink(".bin/scoped", &buf));
    const st = try r.out.statFile(".bin/tool");
    try std.testing.expect(st.mode & 0o111 != 0);
}

test "bin: a name two packages want goes to the shallowest, then the first by path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{
        .{ .path = "node_modules/b", .name = "b", .version = "1.0.0", .extra = ",\"bin\":{\"x\":\"x.js\"}", .files = &.{.{ .name = "package/x.js", .data = "b" }} },
        .{ .path = "node_modules/a", .name = "a", .version = "1.0.0", .extra = ",\"bin\":{\"x\":\"x.js\"}", .files = &.{.{ .name = "package/x.js", .data = "a" }} },
    });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("../a/x.js", try r.out.readLink(".bin/x", &buf));
}

test "an optional package for another os is skipped and reported, a required one fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{
        .{ .path = "node_modules/mac", .name = "mac", .version = "1.0.0", .extra = ",\"optional\":true,\"os\":[\"darwin\"]" },
        .{ .path = "node_modules/lin", .name = "lin", .version = "1.0.0", .extra = ",\"os\":[\"linux\"],\"cpu\":[\"x64\"],\"libc\":[\"glibc\"]" },
        .{ .path = "node_modules/musl", .name = "musl", .version = "1.0.0", .extra = ",\"optional\":true,\"libc\":[\"musl\"]" },
    });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    try std.testing.expectError(error.FileNotFound, r.out.statFile("mac"));
    try std.testing.expectError(error.FileNotFound, r.out.statFile("musl"));
    _ = try r.out.statFile("lin/package.json");
    const report = try read(a, &r, ".buildrules-node-modules.json");
    try std.testing.expect(std.mem.indexOf(u8, report, "node_modules/mac mac@1.0.0: optional, os [\\\"darwin\\\"] excludes linux") != null);

    var r2 = try lay(a, &.{.{ .path = "node_modules/mac", .name = "mac", .version = "1.0.0", .extra = ",\"os\":[\"darwin\"]" }});
    defer r2.deinit();
    try expectMsg(r2, "needs os [\"darwin\"] and is not optional");
}

test "a package with an install script is installed, the script is listed and nothing runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{
        .{ .path = "node_modules/native", .name = "native", .version = "1.0.0", .extra = ",\"hasInstallScript\":true", .files = &.{.{ .name = "package/install.js", .data = "throw 1" }} },
    });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    const report = try read(a, &r, ".buildrules-node-modules.json");
    try std.testing.expect(std.mem.indexOf(u8, report, "\"node_modules/native native@1.0.0\"") != null);
}

test "bundled: present in the parent's tarball is fine, absent is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{
        .{ .path = "node_modules/host", .name = "host", .version = "1.0.0", .files = &.{.{ .name = "package/node_modules/inner/package.json", .data = "{\"name\":\"inner\",\"version\":\"1.0.0\"}" }} },
        .{ .path = "node_modules/host/node_modules/inner", .name = "inner", .version = "1.0.0", .extra = ",\"inBundle\":true", .no_tarball = true, .no_lock_entry_integrity = true },
    });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    _ = try r.out.statFile("host/node_modules/inner/package.json");

    var r2 = try lay(a, &.{
        .{ .path = "node_modules/host", .name = "host", .version = "1.0.0" },
        .{ .path = "node_modules/host/node_modules/inner", .name = "inner", .version = "1.0.0", .extra = ",\"inBundle\":true", .no_tarball = true, .no_lock_entry_integrity = true },
    });
    defer r2.deinit();
    try expectMsg(r2, "is bundled but its parent's tarball holds no node_modules/host/node_modules/inner/package.json");
}

test "a lockfile package with no pinned tarball names the package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{.{ .path = "node_modules/x", .name = "x", .version = "1.0.0", .no_tarball = true }});
    defer r.deinit();
    try expectMsg(r, "x@1.0.0 (node_modules/x) has no pinned tarball");
}

test "the pinned lock's integrity must be the lockfile's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const other = "sha512-" ++ "Q" ** 86 ++ "==";
    var r = try lay(a, &.{.{ .path = "node_modules/x", .name = "x", .version = "1.0.0", .pinned = other }});
    defer r.deinit();
    try expectMsg(r, "x@1.0.0: the lockfile says sha512-");
    try expectMsg(r, "the pinned lock says " ++ other);
}

test "a tarball whose bytes are not the lockfile's integrity is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const other = try tartest.tgz(a, "x", "1.0.0", &.{.{ .name = "package/extra.js", .data = "tampered" }});
    var r = try lay(a, &.{.{ .path = "node_modules/x", .name = "x", .version = "1.0.0", .other_bytes = other }});
    defer r.deinit();
    try expectMsg(r, "x@1.0.0: the tarball is sha512-");
    try std.testing.expectError(error.FileNotFound, r.out.statFile("x/extra.js"));
}

test "a package.json of another name or version is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The tarball of y 2.0.0 under x 1.0.0's entry, with the integrity of its own bytes.
    const y = try tartest.tgz(a, "y", "2.0.0", &.{});
    var tmp_pkgs = [_]Pkg{.{ .path = "node_modules/x", .name = "x", .version = "1.0.0", .other_bytes = y, .pinned = null }};
    var r = try lay(a, &tmp_pkgs);
    defer r.deinit();
    // The bytes differ from x's own tarball, so this is refused by the integrity first;
    // the name check is reached with matching integrity (below).
    try expectMsg(r, "the tarball is sha512-");

    var r2 = try layWithBytes(a, "node_modules/x", "x", "1.0.0", y);
    defer r2.deinit();
    try expectMsg(r2, "x@1.0.0: its package.json says y@2.0.0");
    var r3 = try layWithBytes(a, "node_modules/x", "x", "1.0.0", try tartest.tgz(a, "x", "1.0.1", &.{}));
    defer r3.deinit();
    try expectMsg(r3, "x@1.0.0: its package.json says x@1.0.1");
}

/// A lockfile entry whose integrity is that of `bytes`.
fn layWithBytes(a: std.mem.Allocator, path: []const u8, name: []const u8, version: []const u8, bytes: []const u8) !Result {
    var tmp = std.testing.tmpDir(.{});
    const base = try tmp.dir.realpathAlloc(a, ".");
    const integrity = try sri.of(a, bytes);
    const key = try std.fmt.allocPrint(a, "{s}@{s}", .{ name, version });
    var spec = layout.Spec{
        .lockfile = try std.fmt.allocPrint(a, "{{\"lockfileVersion\":3,\"packages\":{{\"{s}\":{{\"version\":\"{s}\",\"integrity\":\"{s}\"}}}}}}", .{ path, version, integrity }),
        .tarballs = std.StringHashMap([]const u8).init(a),
        .sri512 = std.StringHashMap([]const u8).init(a),
    };
    try tmp.dir.writeFile(.{ .sub_path = "t.tgz", .data = bytes });
    try spec.tarballs.put(key, try std.fs.path.join(a, &.{ base, "t.tgz" }));
    try spec.sri512.put(key, integrity);
    try tmp.dir.makePath("out");
    const out = try tmp.dir.openDir("out", .{ .iterate = true });
    var msg = tartest.Sink{ .a = a };
    var failed = false;
    layout.assemble(a, spec, out, try std.fs.path.join(a, &.{ base, "out" }), &msg) catch |e| switch (e) {
        error.Failed => failed = true,
        else => return e,
    };
    return .{ .failed = failed, .msg = msg.text.items, .tmp = tmp, .out = out };
}

test "a tarball entry that leaves the package fails that package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{.{ .path = "node_modules/x", .name = "x", .version = "1.0.0", .files = &.{.{ .name = "package/../../escape.txt", .data = "x" }} }});
    defer r.deinit();
    try expectMsg(r, "x@1.0.0: PathEscapes");
    try std.testing.expectError(error.FileNotFound, r.tmp.dir.statFile("escape.txt"));
}

test "a lockfile that is not version 3, and workspace entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try tmp.dir.makeOpenPath("out", .{});
    defer out.close();
    var msg = tartest.Sink{ .a = a };
    const spec = layout.Spec{ .lockfile = "{\"lockfileVersion\":2,\"packages\":{}}", .tarballs = std.StringHashMap([]const u8).init(a), .sri512 = std.StringHashMap([]const u8).init(a) };
    try std.testing.expectError(error.Failed, layout.assemble(a, spec, out, "/x", &msg));
    try std.testing.expect(std.mem.indexOf(u8, msg.text.items, "not a lockfileVersion 3") != null);

    const ws = layout.Spec{
        .lockfile = "{\"lockfileVersion\":3,\"packages\":{\"\":{},\"packages/w\":{\"version\":\"1.0.0\"},\"node_modules/w\":{\"resolved\":\"packages/w\",\"link\":true}}}",
        .tarballs = std.StringHashMap([]const u8).init(a),
        .sri512 = std.StringHashMap([]const u8).init(a),
    };
    var msg2 = tartest.Sink{ .a = a };
    try layout.assemble(a, ws, out, "/x", &msg2);
}

test "from unpacked directories: the same tree, with the same bin links, as from tarballs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pkgs = [_]Pkg{
        .{ .path = "node_modules/tool", .name = "tool", .version = "1.0.0", .extra = ",\"bin\":{\"tool\":\"./bin/tool.js\"}", .files = &.{.{ .name = "package/bin/tool.js", .mode = 0o755, .data = "x" }} },
        .{ .path = "node_modules/tool/node_modules/fx-b", .name = "fx-b", .version = "2.0.0", .files = &.{.{ .name = "package/index.js", .data = "b2" }} },
        .{ .path = "node_modules/@fx/scoped", .name = "@fx/scoped", .version = "3.0.0", .files = &.{.{ .name = "package/lib/index.js", .data = "s3" }} },
    };
    var r = try layDirs(a, &pkgs);
    defer r.deinit();
    try std.testing.expect(!r.failed);
    try std.testing.expectEqualStrings("b2", try read(a, &r, "tool/node_modules/fx-b/index.js"));
    try std.testing.expectEqualStrings("s3", try read(a, &r, "@fx/scoped/lib/index.js"));
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("../tool/bin/tool.js", try r.out.readLink(".bin/tool", &buf));
    try std.testing.expect((try r.out.statFile("tool/bin/tool.js")).mode & 0o111 != 0);
    var t = try lay(a, &pkgs);
    defer t.deinit();
    try std.testing.expectEqualStrings(try read(a, &t, ".buildrules-node-modules.json"), try read(a, &r, ".buildrules-node-modules.json"));
}

test "from unpacked directories: a package with no directory, a wrong pin and a bad tarball are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files: []const tartest.Entry = &.{.{ .name = "package/index.js", .data = "a" }};
    var r1 = try layDirs(a, &.{.{ .path = "node_modules/fx-a", .name = "fx-a", .version = "1.0.0", .files = files, .no_tarball = true }});
    defer r1.deinit();
    try expectMsg(r1, "fx-a@1.0.0 (node_modules/fx-a) has no unpacked package");
    var r2 = try layDirs(a, &.{.{ .path = "node_modules/fx-a", .name = "fx-a", .version = "1.0.0", .files = files, .pinned = "sha512-other" }});
    defer r2.deinit();
    try expectMsg(r2, "the lockfile says");
    var r3 = try layDirs(a, &.{.{ .path = "node_modules/fx-a", .name = "fx-a", .version = "1.0.0", .files = files, .other_bytes = "not the tarball" }});
    defer r3.deinit();
    try expectMsg(r3, "the tarball is sha512-");
    var r4 = try layDirs(a, &.{.{ .path = "node_modules/fx-a", .name = "fx-a", .version = "1.0.0", .extra = ",\"name\":\"fx-a\"", .files = &.{.{ .name = "package/index.js", .data = "a" }} }});
    defer r4.deinit();
    try std.testing.expect(!r4.failed);
}

// ---- a lockfile written by hand: the entries the Pkg fixtures cannot make (no version, no integrity, a missing file) ----

const Raw = struct {
    /// The members of "packages" after the root, as text (any number, comma-separated).
    entry: []const u8,
    /// The tarball of `x@1.0.0`; its pin is the integrity of these bytes unless `pin` is given.
    bytes: ?[]const u8 = null,
    /// When there are no bytes: the name of a tarball file that is not there.
    ghost: ?[]const u8 = null,
    pin: ?[]const u8 = null,
};

fn layRaw(a: std.mem.Allocator, raw: Raw) !Result {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(a, ".");
    var spec = layout.Spec{
        .lockfile = try std.fmt.allocPrint(a, "{{\"lockfileVersion\":3,\"packages\":{{\"\":{{}},{s}}}}}", .{raw.entry}),
        .tarballs = std.StringHashMap([]const u8).init(a),
        .sri512 = std.StringHashMap([]const u8).init(a),
    };
    if (raw.bytes) |b| {
        try tmp.dir.writeFile(.{ .sub_path = "t.tgz", .data = b });
        try spec.tarballs.put("x@1.0.0", try std.fs.path.join(a, &.{ base, "t.tgz" }));
        try spec.sri512.put("x@1.0.0", raw.pin orelse try sri.of(a, b));
    } else {
        if (raw.ghost) |g| try spec.tarballs.put("x@1.0.0", try std.fs.path.join(a, &.{ base, g }));
        if (raw.pin) |p| try spec.sri512.put("x@1.0.0", p);
    }
    try tmp.dir.makePath("out");
    var out = try tmp.dir.openDir("out", .{ .iterate = true });
    errdefer out.close();
    var msg = tartest.Sink{ .a = a };
    var failed = false;
    layout.assemble(a, spec, out, try std.fs.path.join(a, &.{ base, "out" }), &msg) catch |e| switch (e) {
        error.Failed => failed = true,
        else => return e,
    };
    return .{ .failed = failed, .msg = msg.text.items, .tmp = tmp, .out = out };
}

/// The lockfile entry of `node_modules/x` 1.0.0 whose integrity is that of `bytes`; `extra` follows (starting with a comma).
fn xEntry(a: std.mem.Allocator, bytes: []const u8, extra: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "\"node_modules/x\":{{\"version\":\"1.0.0\",\"integrity\":\"{s}\"{s}}}", .{ try sri.of(a, bytes), extra });
}

test "a lockfile that is not a version 3 package-lock.json is refused, whatever it is instead" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const not_v3 = [_][]const u8{ "[]", "3", "{}", "{\"lockfileVersion\":3}", "{\"lockfileVersion\":3,\"packages\":[]}", "{\"lockfileVersion\":\"3\",\"packages\":{}}", "{\"lockfileVersion\":2,\"packages\":{}}", "{\"lockfileVersion\":4,\"packages\":{}}" };
    for (not_v3) |lock| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var out = try tmp.dir.makeOpenPath("out", .{});
        defer out.close();
        var msg = tartest.Sink{ .a = a };
        const spec = layout.Spec{ .lockfile = lock, .tarballs = std.StringHashMap([]const u8).init(a), .sri512 = std.StringHashMap([]const u8).init(a) };
        try std.testing.expectError(error.Failed, layout.assemble(a, spec, out, "/x", &msg));
        try std.testing.expectEqualStrings("node_modules: the lockfile is not a lockfileVersion 3 package-lock.json\n", msg.text.items);
        // and nothing was laid out
        try std.testing.expectError(error.FileNotFound, out.statFile(".buildrules-node-modules.json"));
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var out = try tmp.dir.makeOpenPath("out", .{});
    defer out.close();
    var msg = tartest.Sink{ .a = a };
    const spec = layout.Spec{ .lockfile = "{", .tarballs = std.StringHashMap([]const u8).init(a), .sri512 = std.StringHashMap([]const u8).init(a) };
    try std.testing.expectError(error.Failed, layout.assemble(a, spec, out, "/x", &msg));
    try std.testing.expectEqualStrings("node_modules: the lockfile is not JSON\n", msg.text.items);
}

test "entries with nothing to install are skipped: not an object, outside node_modules, a link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try layRaw(a, .{ .entry = "\"node_modules/n\":5,\"packages/w\":{\"version\":\"1.0.0\"},\"node_modules/l\":{\"link\":true,\"resolved\":\"packages/w\"}" });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    try std.testing.expectEqualStrings("node_modules: 0 packages, 0 bin links, 0 skipped, 0 install scripts not run\n", r.msg);
    try std.testing.expectError(error.FileNotFound, r.out.statFile("n"));
    try std.testing.expectError(error.FileNotFound, r.out.statFile("l"));
}

test "a lockfile entry that cannot be installed is named" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try tartest.tgz(a, "x", "1.0.0", &.{});
    const good_sri = try sri.of(a, good);
    const no_pj = try tartest.gzip(a, try tartest.tar(a, &.{.{ .name = "package/index.js", .data = "x" }}));
    const bad_pj = try tartest.tgz(a, "x", "1.0.0", &.{.{ .name = "package/package.json", .data = "{" }});
    const no_version = try tartest.tgz(a, "x", "1.0.0", &.{.{ .name = "package/package.json", .data = "{\"name\":\"x\"}" }});

    const Case = struct { raw: Raw, want: []const u8 };
    const cases = [_]Case{
        .{ .raw = .{ .entry = "\"node_modules/x\":{\"resolved\":\"r\"}" }, .want = "x (node_modules/x) has no version" },
        .{ .raw = .{ .entry = "\"node_modules/x\":{\"name\":\"y\",\"resolved\":\"r\"}" }, .want = "y (node_modules/x) has no version" },
        .{ .raw = .{ .entry = "\"node_modules/x\":{\"version\":\"1.0.0\"}" }, .want = "x@1.0.0 (node_modules/x) has no sha512 integrity in the lockfile" },
        .{ .raw = .{ .entry = "\"node_modules/x\":{\"version\":\"1.0.0\",\"integrity\":\"sha1-abc=\"}" }, .want = "x@1.0.0 (node_modules/x) has no sha512 integrity in the lockfile" },
        .{ .raw = .{ .entry = try xEntry(a, good, "") }, .want = try std.fmt.allocPrint(a, "x@1.0.0: the lockfile says {s}, the pinned lock says undefined (kpin check)", .{good_sri}) },
        .{ .raw = .{ .entry = try xEntry(a, good, ""), .pin = good_sri, .ghost = "missing.tgz" }, .want = "/missing.tgz: FileNotFound" },
        .{ .raw = .{ .entry = try xEntry(a, no_pj, ""), .bytes = no_pj }, .want = "x@1.0.0: the tarball holds no package.json" },
        .{ .raw = .{ .entry = try xEntry(a, bad_pj, ""), .bytes = bad_pj }, .want = "x@1.0.0: package.json is not JSON" },
        .{ .raw = .{ .entry = try xEntry(a, no_version, ""), .bytes = no_version }, .want = "x@1.0.0: its package.json says x@undefined" },
    };
    for (cases) |c| {
        var r = try layRaw(a, c.raw);
        defer r.deinit();
        try expectMsg(r, c.want);
    }
    // the missing file is named with the path it was looked for at
    var r = try layRaw(a, cases[5].raw);
    defer r.deinit();
    try expectMsg(r, "x@1.0.0: cannot read ");
    // a package that is refused leaves nothing in the tree
    try std.testing.expectError(error.FileNotFound, r.out.statFile(".buildrules-node-modules.json"));
}

test "links in a tarball are not extracted: each package says how many it dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{
        .{ .path = "node_modules/one", .name = "one", .version = "1.0.0", .files = &.{.{ .name = "package/l", .kind = '2', .link = "/etc/passwd" }} },
        .{ .path = "node_modules/two", .name = "two", .version = "1.0.0", .files = &.{ .{ .name = "package/l", .kind = '2', .link = "a" }, .{ .name = "package/m", .kind = '2', .link = "b" } } },
    });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    try std.testing.expectError(error.FileNotFound, r.out.statFile("one/l"));
    const report = try read(a, &r, ".buildrules-node-modules.json");
    try std.testing.expect(std.mem.indexOf(u8, report, "node_modules/one one@1.0.0: 1 link entry in the tarball, not extracted (npm drops them)") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "node_modules/two two@1.0.0: 2 link entries in the tarball, not extracted (npm drops them)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.msg, "2 skipped") != null);
}

test "an optional package for another cpu is skipped; a required one for another cpu or libc fails, naming the field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{
        .{ .path = "node_modules/arm", .name = "arm", .version = "1.0.0", .extra = ",\"optional\":true,\"cpu\":[\"arm64\"]" },
        .{ .path = "node_modules/notlinux", .name = "notlinux", .version = "1.0.0", .extra = ",\"optional\":true,\"os\":[\"!linux\"]" },
    });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    const report = try read(a, &r, ".buildrules-node-modules.json");
    try std.testing.expect(std.mem.indexOf(u8, report, "node_modules/arm arm@1.0.0: optional, cpu [\\\"arm64\\\"] excludes x64") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "node_modules/notlinux notlinux@1.0.0: optional, os [\\\"!linux\\\"] excludes linux") != null);
    var r2 = try lay(a, &.{.{ .path = "node_modules/arm", .name = "arm", .version = "1.0.0", .extra = ",\"cpu\":[\"arm64\"]" }});
    defer r2.deinit();
    try expectMsg(r2, "arm@1.0.0 (node_modules/arm) needs cpu [\"arm64\"] and is not optional");
    var r3 = try lay(a, &.{.{ .path = "node_modules/musl", .name = "musl", .version = "1.0.0", .extra = ",\"libc\":[\"musl\"]" }});
    defer r3.deinit();
    try expectMsg(r3, "musl@1.0.0 (node_modules/musl) needs libc [\"musl\"] and is not optional");
}

test "bin: what leaves the package, or has no name, is refused; what is not a table is ignored; a missing file is no link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files: []const tartest.Entry = &.{.{ .name = "package/ok.js", .data = "ok" }};
    const refused = [_]struct { bin: []const u8, why: []const u8 }{
        .{ .bin = "{\"a/b\":\"ok.js\"}", .why = "tool: bin a/b leaves the package" },
        .{ .bin = "{\"x\":\"../ok.js\"}", .why = "tool: bin x leaves the package" },
        .{ .bin = "{\"x\":\"./../ok.js\"}", .why = "tool: bin x leaves the package" },
        .{ .bin = "{\"x\":\"lib/../../ok.js\"}", .why = "tool: bin x leaves the package" },
        .{ .bin = "{\"x\":\"/etc/passwd\"}", .why = "tool: bin x leaves the package" },
        .{ .bin = "{\"x\":\"\"}", .why = "tool: bin x leaves the package" },
        .{ .bin = "{\"x\":\"./\"}", .why = "tool: bin x leaves the package" },
        .{ .bin = "{\"\":\"ok.js\"}", .why = "tool: bin  leaves the package" },
    };
    for (refused) |c| {
        const extra = try std.fmt.allocPrint(a, ",\"bin\":{s}", .{c.bin});
        var r = try lay(a, &.{.{ .path = "node_modules/tool", .name = "tool", .version = "1.0.0", .extra = extra, .files = files }});
        defer r.deinit();
        try expectMsg(r, c.why);
        try std.testing.expectError(error.FileNotFound, r.out.statFile(".bin"));
    }
    // not a table of commands: nothing is linked and nothing is wrong
    for ([_][]const u8{ "[\"ok.js\"]", "5", "true", "null" }) |bin| {
        const extra = try std.fmt.allocPrint(a, ",\"bin\":{s}", .{bin});
        var r = try lay(a, &.{.{ .path = "node_modules/tool", .name = "tool", .version = "1.0.0", .extra = extra, .files = files }});
        defer r.deinit();
        try std.testing.expect(!r.failed);
        try std.testing.expectError(error.FileNotFound, r.out.statFile(".bin"));
    }
    // a command whose file is not a string is skipped, the others are linked
    var mixed = try lay(a, &.{.{ .path = "node_modules/tool", .name = "tool", .version = "1.0.0", .extra = ",\"bin\":{\"x\":5,\"y\":\"ok.js\"}", .files = files }});
    defer mixed.deinit();
    try std.testing.expect(!mixed.failed);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("../tool/ok.js", try mixed.out.readLink(".bin/y", &buf));
    try std.testing.expectError(error.FileNotFound, mixed.out.statFile(".bin/x"));
    // a file the tarball does not hold is reported, not linked
    var missing = try lay(a, &.{
        .{ .path = "node_modules/tool", .name = "tool", .version = "1.0.0", .extra = ",\"bin\":{\"x\":\"gone.js\"}", .files = files },
        .{ .path = "node_modules/solo", .name = "solo", .version = "1.0.0", .extra = ",\"bin\":\"gone.js\"", .files = files },
    });
    defer missing.deinit();
    try std.testing.expect(!missing.failed);
    try std.testing.expectError(error.FileNotFound, missing.out.statFile(".bin"));
    const report = try read(a, &missing, ".buildrules-node-modules.json");
    try std.testing.expect(std.mem.indexOf(u8, report, "node_modules/tool: bin x -> gone.js is not in the tarball, no link") != null);
    try std.testing.expect(std.mem.indexOf(u8, report, "node_modules/solo: bin solo -> gone.js is not in the tarball, no link") != null);
}

test "bin: a bundled package's executable is linked beside it, in the node_modules of its parent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try lay(a, &.{
        .{ .path = "node_modules/host", .name = "host", .version = "1.0.0", .files = &.{
            .{ .name = "package/node_modules/inner/package.json", .data = "{\"name\":\"inner\",\"version\":\"1.0.0\"}" },
            .{ .name = "package/node_modules/inner/cli.js", .mode = 0o644, .data = "x" },
        } },
        .{ .path = "node_modules/host/node_modules/inner", .name = "inner", .version = "1.0.0", .extra = ",\"inBundle\":true,\"bin\":\"cli.js\"", .no_tarball = true, .no_lock_entry_integrity = true },
    });
    defer r.deinit();
    try std.testing.expect(!r.failed);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("../inner/cli.js", try r.out.readLink("host/node_modules/.bin/inner", &buf));
    try std.testing.expect((try r.out.statFile("host/node_modules/inner/cli.js")).mode & 0o111 != 0);
}

test "more than forty problems: forty are listed, the rest counted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pkgs: [45]Pkg = undefined;
    for (&pkgs, 0..) |*p, i| p.* = .{
        .path = try std.fmt.allocPrint(a, "node_modules/p{d}", .{i}),
        .name = try std.fmt.allocPrint(a, "p{d}", .{i}),
        .version = "1.0.0",
        .no_tarball = true,
    };
    var r = try lay(a, &pkgs);
    defer r.deinit();
    try expectMsg(r, "node_modules: p39@1.0.0 (node_modules/p39) has no pinned tarball");
    try std.testing.expectEqual(@as(usize, 41), std.mem.count(u8, r.msg, "node_modules: "));
    try std.testing.expect(std.mem.indexOf(u8, r.msg, "p40@1.0.0") == null);
    try std.testing.expect(std.mem.endsWith(u8, r.msg, "node_modules: ... and 5 more\n"));
}

// ---- unpackOne, the work of `unpack` on one tarball ----

const Out = struct { failed: bool, msg: []const u8 };

fn unpackIt(a: std.mem.Allocator, bytes: []const u8, want: []const u8, name: []const u8) !Out {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var msg = tartest.Sink{ .a = a };
    layout.unpackOne(a, bytes, want, name, "1.0.0", tmp.dir, &msg) catch |e| switch (e) {
        error.Failed => return .{ .failed = true, .msg = msg.text.items },
        else => return e,
    };
    return .{ .failed = false, .msg = msg.text.items };
}

test "unpackOne: an integrity that is not sha512, a tarball that is not the pinned one, and a package that is not the one asked for" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try tartest.tgz(a, "x", "1.0.0", &.{});
    const good_sri = try sri.of(a, good);
    const other = "sha512-" ++ "Q" ** 86 ++ "==";

    const sha1 = try unpackIt(a, good, "sha1-xyz=", "x");
    try std.testing.expect(sha1.failed);
    try std.testing.expectEqualStrings("node_modules: x@1.0.0: integrity sha1-xyz= is not sha512-<base64>\n", sha1.msg);

    const wrong = try unpackIt(a, good, other, "x");
    try std.testing.expect(wrong.failed);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "node_modules: x@1.0.0: the tarball is {s}, the pinned integrity is {s}\n", .{ good_sri, other }), wrong.msg);

    const escapes = try tartest.tgz(a, "x", "1.0.0", &.{.{ .name = "package/../../e", .data = "x" }});
    const esc = try unpackIt(a, escapes, try sri.of(a, escapes), "x");
    try std.testing.expect(esc.failed);
    try std.testing.expectEqualStrings("node_modules: x@1.0.0: PathEscapes\n", esc.msg);

    const named_y = try unpackIt(a, good, good_sri, "y");
    try std.testing.expect(named_y.failed);
    try std.testing.expectEqualStrings("node_modules: y@1.0.0: its package.json says x@1.0.0\n", named_y.msg);

    const no_pj = try tartest.gzip(a, try tartest.tar(a, &.{.{ .name = "package/index.js", .data = "x" }}));
    const none = try unpackIt(a, no_pj, try sri.of(a, no_pj), "x");
    try std.testing.expect(none.failed);
    try std.testing.expectEqualStrings("node_modules: x@1.0.0: the tarball holds no package.json\n", none.msg);

    const bad_pj = try tartest.tgz(a, "x", "1.0.0", &.{.{ .name = "package/package.json", .data = "[" }});
    const notjson = try unpackIt(a, bad_pj, try sri.of(a, bad_pj), "x");
    try std.testing.expect(notjson.failed);
    try std.testing.expectEqualStrings("node_modules: x@1.0.0: package.json is not JSON\n", notjson.msg);

    const fine = try unpackIt(a, good, good_sri, "x");
    try std.testing.expect(!fine.failed);
    try std.testing.expectEqualStrings("", fine.msg);
}

test "unpackOne: the links it dropped are said, in the singular and the plural" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try tartest.tgz(a, "x", "1.0.0", &.{.{ .name = "package/l", .kind = '2', .link = "a" }});
    const two = try tartest.tgz(a, "x", "1.0.0", &.{ .{ .name = "package/l", .kind = '2', .link = "a" }, .{ .name = "package/m", .kind = '2', .link = "b" } });
    const r1 = try unpackIt(a, one, try sri.of(a, one), "x");
    try std.testing.expect(!r1.failed);
    try std.testing.expectEqualStrings("node_modules: x@1.0.0: 1 link entry in the tarball, not extracted (npm drops them)\n", r1.msg);
    const r2 = try unpackIt(a, two, try sri.of(a, two), "x");
    try std.testing.expect(!r2.failed);
    try std.testing.expectEqualStrings("node_modules: x@1.0.0: 2 link entries in the tarball, not extracted (npm drops them)\n", r2.msg);
}

// ---- from unpacked directories: what cannot be copied ----

test "from unpacked directories: a directory that cannot be opened is named; a link inside one is not copied" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pkgs = [_]Pkg{.{ .path = "node_modules/x", .name = "x", .version = "1.0.0", .files = &.{.{ .name = "package/index.js", .data = "a" }} }};
    {
        var b = try build(a, &pkgs, true);
        defer b.tmp.cleanup();
        try b.spec.dirs.?.put("x@1.0.0", try std.fs.path.join(a, &.{ b.base, "nodir" }));
        var out = try b.tmp.dir.makeOpenPath("out", .{});
        defer out.close();
        var msg = tartest.Sink{ .a = a };
        try std.testing.expectError(error.Failed, layout.assemble(a, b.spec, out, "/x", &msg));
        try std.testing.expect(std.mem.indexOf(u8, msg.text.items, "node_modules: x@1.0.0: cannot open ") != null);
        try std.testing.expect(std.mem.indexOf(u8, msg.text.items, "/nodir: FileNotFound") != null);
    }
    {
        var b = try build(a, &pkgs, true);
        defer b.tmp.cleanup();
        try b.tmp.dir.symLink("index.js", "pk0/link", .{});
        var out = try b.tmp.dir.makeOpenPath("out", .{});
        defer out.close();
        var msg = tartest.Sink{ .a = a };
        try std.testing.expectError(error.UnsupportedFileKind, layout.assemble(a, b.spec, out, "/x", &msg));
    }
}

test "copyTree: a link in the tree is refused, not copied and not followed" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.makePath("dst");
    try tmp.dir.writeFile(.{ .sub_path = "src/real", .data = "x" });
    try tmp.dir.symLink("real", "src/link", .{});
    var src = try tmp.dir.openDir("src", .{ .iterate = true });
    defer src.close();
    var dst = try tmp.dir.openDir("dst", .{});
    defer dst.close();
    try std.testing.expectError(error.UnsupportedFileKind, layout.copyTree(std.testing.allocator, src, dst));
    try std.testing.expectError(error.FileNotFound, dst.statFile("link"));
}

// ---- allocation and write failures: assemble and unpackOne never report a tree they did not finish ----

fn assembleInto(a: std.mem.Allocator, spec: *const layout.Spec, w: anytype) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("out");
    var out = try tmp.dir.openDir("out", .{ .iterate = true });
    defer out.close();
    const out_path = try tmp.dir.realpathAlloc(std.testing.allocator, "out");
    defer std.testing.allocator.free(out_path);
    try layout.assemble(a, spec.*, out, out_path, w);
}

/// Into a list that grows by the allocator that fails.
fn assembleOnce(a: std.mem.Allocator, spec: *const layout.Spec) !void {
    var msg = tartest.Sink{ .a = a };
    try assembleInto(a, spec, &msg);
}


/// The text `assemble` wrote, for a spec that is refused.
fn assembleText(a: std.mem.Allocator, spec: *const layout.Spec) ![]const u8 {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("out");
    var out = try tmp.dir.openDir("out", .{ .iterate = true });
    defer out.close();
    var msg = tartest.Sink{ .a = a };
    layout.assemble(a, spec.*, out, "/x", &msg) catch |e| switch (e) {
        error.Failed => {},
        else => return e,
    };
    return msg.text.items;
}

fn assembleWriting(w: *tartest.Sink, spec: *const layout.Spec) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("out");
    var out = try tmp.dir.openDir("out", .{ .iterate = true });
    defer out.close();
    const out_path = try tmp.dir.realpathAlloc(std.testing.allocator, "out");
    defer std.testing.allocator.free(out_path);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try layout.assemble(arena.allocator(), spec.*, out, out_path, w);
}

/// Packages that install, with executables, a bundled one, an optional one skipped, an install script and dropped links.
const installing = [_]Pkg{
    .{ .path = "node_modules/tool", .name = "tool", .version = "1.0.0", .extra = ",\"bin\":{\"tool\":\"./bin/tool.js\",\"gone\":\"gone.js\"}", .files = &.{.{ .name = "package/bin/tool.js", .mode = 0o644, .data = "x" }} },
    .{ .path = "node_modules/tool/node_modules/inner", .name = "inner", .version = "1.0.0", .extra = ",\"bin\":\"cli.js\"", .files = &.{.{ .name = "package/cli.js", .data = "y" }} },
    .{ .path = "node_modules/@s/scoped", .name = "@s/scoped", .version = "1.0.0", .extra = ",\"bin\":\"cli.js\",\"hasInstallScript\":true", .files = &.{.{ .name = "package/cli.js", .data = "z" }} },
    .{ .path = "node_modules/mac", .name = "mac", .version = "1.0.0", .extra = ",\"optional\":true,\"os\":[\"darwin\"]" },
    .{ .path = "node_modules/linky", .name = "linky", .version = "1.0.0", .files = &.{ .{ .name = "package/l", .kind = '2', .link = "a" }, .{ .name = "package/m", .kind = '2', .link = "b" } } },
    .{ .path = "node_modules/host", .name = "host", .version = "1.0.0", .files = &.{.{ .name = "package/node_modules/b/package.json", .data = "{\"name\":\"b\",\"version\":\"1.0.0\"}" }} },
    .{ .path = "node_modules/host/node_modules/b", .name = "b", .version = "1.0.0", .extra = ",\"inBundle\":true,\"bin\":\"cli.js\"", .no_tarball = true, .no_lock_entry_integrity = true },
};

/// Packages each refused for its own reason.
const refusing = [_]Pkg{
    .{ .path = "node_modules/nopin", .name = "nopin", .version = "1.0.0", .no_tarball = true },
    .{ .path = "node_modules/wrongpin", .name = "wrongpin", .version = "1.0.0", .pinned = "sha512-other" },
    .{ .path = "node_modules/tampered", .name = "tampered", .version = "1.0.0", .other_bytes = "not the tarball" },
    .{ .path = "node_modules/escapes", .name = "escapes", .version = "1.0.0", .files = &.{.{ .name = "package/../../e", .data = "x" }} },
    .{ .path = "node_modules/leaves", .name = "leaves", .version = "1.0.0", .extra = ",\"bin\":{\"x\":\"../x.js\"}" },
    .{ .path = "node_modules/needsmac", .name = "needsmac", .version = "1.0.0", .extra = ",\"os\":[\"darwin\"]" },
    .{ .path = "node_modules/bundled", .name = "bundled", .version = "1.0.0", .extra = ",\"inBundle\":true", .no_tarball = true, .no_lock_entry_integrity = true },
    .{ .path = "node_modules/badpj", .name = "badpj", .version = "1.0.0", .files = &.{.{ .name = "package/package.json", .data = "{" }} },
    .{ .path = "node_modules/wrongname", .name = "wrongname", .version = "1.0.0", .files = &.{.{ .name = "package/package.json", .data = "{\"name\":\"other\",\"version\":\"1.0.0\"}" }} },
};


test "the fixtures of the failure sweeps are what they are called: one installs, the other is refused for each of its packages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ok = try lay(a, &installing);
    defer ok.deinit();
    try std.testing.expect(!ok.failed);
    // five from tarballs (not the optional one for another os, not the bundled one); links for tool, inner and scoped; skipped: mac, the
    // links of linky, the bin `gone` of tool and the bin of the bundled package, which its host does not hold
    try std.testing.expectEqualStrings("node_modules: 5 packages, 3 bin links, 4 skipped, 1 install scripts not run\n", ok.msg);
    var refused = try lay(a, &refusing);
    defer refused.deinit();
    for ([_][]const u8{
        "nopin@1.0.0 (node_modules/nopin) has no pinned tarball",
        "wrongpin@1.0.0: the lockfile says",
        "tampered@1.0.0: the tarball is",
        "escapes@1.0.0: PathEscapes",
        "leaves: bin x leaves the package",
        "needsmac@1.0.0 (node_modules/needsmac) needs os",
        "bundled@1.0.0 (node_modules/bundled) is bundled but its parent's tarball holds no",
        "badpj@1.0.0: package.json is not JSON",
        "wrongname@1.0.0: its package.json says other@1.0.0",
    }) |line| {
        try std.testing.expect(std.mem.indexOf(u8, refused.msg, line) != null);
    }
    // and with the members of a hand-written lockfile, from tarballs and from unpacked directories
    var m = try handwritten(a, false, &refusing, null);
    defer m.tmp.cleanup();
    const text = try assembleText(a, &m.spec);
    for ([_][]const u8{
        "nover (node_modules/nover) has no version",
        "noint@1.0.0 (node_modules/noint) has no sha512 integrity",
        "sha1@1.0.0 (node_modules/sha1) has no sha512 integrity",
        "nopinraw@1.0.0: the lockfile says sha512-AAAA, the pinned lock says undefined",
        "ghost@1.0.0: cannot read ",
        "nopj@1.0.0: the tarball holds no package.json",
        "badpj@1.0.0: package.json is not JSON",
    }) |line| {
        if (std.mem.indexOf(u8, text, line) == null) {
            std.debug.print("{s}\nwant: {s}\n", .{ text, line });
            return error.TestExpectedMessage;
        }
    }
    var md = try handwritten(a, true, &refusing, null);
    defer md.tmp.cleanup();
    const dir_text = try assembleText(a, &md.spec);
    for ([_][]const u8{ "nover (node_modules/nover) has no version", "ghost@1.0.0: cannot open ", "nopj@1.0.0 (node_modules/nopj) has no unpacked package" }) |line| {
        if (std.mem.indexOf(u8, dir_text, line) == null) {
            std.debug.print("{s}\nwant: {s}\n", .{ dir_text, line });
            return error.TestExpectedMessage;
        }
    }
}

fn copyOnce(a: std.mem.Allocator, d: *const [2]std.fs.Dir) !void {
    try layout.copyTree(a, d[0], d[1]);
}

test "an allocation that fails while a tree is copied is an error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src/lib/deep");
    try tmp.dir.makePath("dst");
    try tmp.dir.writeFile(.{ .sub_path = "src/lib/deep/a.txt", .data = "a" });
    try tmp.dir.writeFile(.{ .sub_path = "src/run.sh", .data = "b", .flags = .{ .mode = 0o755 } });
    var src = try tmp.dir.openDir("src", .{ .iterate = true });
    defer src.close();
    var dst = try tmp.dir.openDir("dst", .{});
    defer dst.close();
    try tartest.allocSweep(copyOnce, &[2]std.fs.Dir{ src, dst });
}

test "assemble does not replace what is in its output directory: something in the way of a package, a link or the report is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pkgs = [_]Pkg{.{ .path = "node_modules/tool", .name = "tool", .version = "1.0.0", .extra = ",\"bin\":\"cli.js\"", .files = &.{.{ .name = "package/cli.js", .data = "x" }} }};
    const Way = struct { parent: ?[]const u8 = null, name: []const u8, dir: bool = false, from_dirs: bool = false };
    const ways = [_]Way{
        .{ .name = ".bin" },
        .{ .parent = ".bin", .name = ".bin/tool" },
        .{ .name = ".buildrules-node-modules.json", .dir = true },
        .{ .name = "tool" },
        .{ .name = "tool", .from_dirs = true },
    };
    for (ways) |way| {
        var b = try build(a, &pkgs, way.from_dirs);
        defer b.tmp.cleanup();
        var out = try b.tmp.dir.makeOpenPath("out", .{ .iterate = true });
        defer out.close();
        if (way.parent) |p| try out.makePath(p);
        if (way.dir) try out.makePath(way.name) else try out.writeFile(.{ .sub_path = way.name, .data = "mine" });
        var msg = tartest.Sink{ .a = a };
        const out_path = try std.fs.path.join(a, &.{ b.base, "out" });
        try std.testing.expect(std.meta.isError(layout.assemble(a, b.spec, out, out_path, &msg)));
        if (!way.dir) {
            const kept = try out.readFileAlloc(a, way.name, 100);
            try std.testing.expectEqualStrings("mine", kept);
        }
    }
}

test "copyTree: a file whose place in the destination is taken by a directory is an error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.makePath("dst/f");
    try tmp.dir.writeFile(.{ .sub_path = "src/f", .data = "x" });
    var src = try tmp.dir.openDir("src", .{ .iterate = true });
    defer src.close();
    var dst = try tmp.dir.openDir("dst", .{});
    defer dst.close();
    try std.testing.expect(std.meta.isError(layout.copyTree(std.testing.allocator, src, dst)));
}

/// `pkgs` and members a hand-written lockfile has (all of them, or only the `only`th): no version, no integrity, a pin the
/// lockfile does not hold, a tarball (or an unpacked directory) that is not there and a tarball without a package.json.
fn handwritten(a: std.mem.Allocator, use_dirs: bool, pkgs: []const Pkg, only: ?usize) !Built {
    var b = try build(a, pkgs, use_dirs);
    errdefer b.tmp.cleanup();
    const no_pj = try tartest.gzip(a, try tartest.tar(a, &.{.{ .name = "package/index.js", .data = "x" }}));
    const no_pj_sri = try sri.of(a, no_pj);
    const entries = [_][]const u8{
        "\"node_modules/nover\":{\"resolved\":\"r\"}",
        "\"node_modules/noint\":{\"version\":\"1.0.0\"}",
        "\"node_modules/sha1\":{\"version\":\"1.0.0\",\"integrity\":\"sha1-a=\"}",
        "\"node_modules/nopinraw\":{\"version\":\"1.0.0\",\"integrity\":\"sha512-AAAA\"}",
        "\"node_modules/ghost\":{\"version\":\"1.0.0\",\"integrity\":\"sha512-GGGG\"}",
        try std.fmt.allocPrint(a, "\"node_modules/nopj\":{{\"version\":\"1.0.0\",\"integrity\":\"{s}\"}}", .{no_pj_sri}),
    };
    var lock = std.ArrayList(u8).empty;
    try lock.appendSlice(a, b.spec.lockfile[0 .. b.spec.lockfile.len - 2]);
    for (entries, 0..) |e, i| {
        if (only != null and only.? != i) continue;
        try lock.append(a, ',');
        try lock.appendSlice(a, e);
    }
    try lock.appendSlice(a, "}}");
    b.spec.lockfile = lock.items;
    try b.spec.sri512.put("ghost@1.0.0", "sha512-GGGG");
    try b.spec.sri512.put("nopj@1.0.0", no_pj_sri);
    const missing = try std.fs.path.join(a, &.{ b.base, "missing" });
    if (use_dirs) {
        try b.spec.dirs.?.put("ghost@1.0.0", missing);
    } else {
        try b.spec.tarballs.put("ghost@1.0.0", missing);
        try b.tmp.dir.writeFile(.{ .sub_path = "nopj.tgz", .data = no_pj });
        try b.spec.tarballs.put("nopj@1.0.0", try std.fs.path.join(a, &.{ b.base, "nopj.tgz" }));
    }
    return b;
}

/// Both failures at every point of one spec: an allocation that fails and a line that cannot be written.
fn bothSweeps(spec: *const layout.Spec) !void {
    try tartest.allocSweep(assembleOnce, spec);
    try tartest.writerSweep(assembleWriting, spec);
}

test "an allocation that fails, or a report that cannot be written, while a tree is laid out, is an error: for each way a lockfile is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // what installs, from tarballs and from unpacked directories
    var from_tarballs = try build(a, &installing, false);
    defer from_tarballs.tmp.cleanup();
    try bothSweeps(&from_tarballs.spec);
    var from_dirs = try build(a, &installing, true);
    defer from_dirs.tmp.cleanup();
    try bothSweeps(&from_dirs.spec);
    // everything refused at once, and then each package refused alone (the list of problems is grown by the first of them)
    var refused = try build(a, &refusing, false);
    defer refused.tmp.cleanup();
    try bothSweeps(&refused.spec);
    for (0..refusing.len) |i| {
        for ([_]bool{ false, true }) |dirs| {
            var one = try build(a, refusing[i..][0..1], dirs);
            defer one.tmp.cleanup();
            try bothSweeps(&one.spec);
        }
    }
    // the members of a hand-written lockfile, all at once and each alone, from tarballs and from unpacked directories
    for ([_]bool{ false, true }) |dirs| {
        var all = try handwritten(a, dirs, &refusing, null);
        defer all.tmp.cleanup();
        try bothSweeps(&all.spec);
        for (0..6) |i| {
            var one = try handwritten(a, dirs, &.{}, i);
            defer one.tmp.cleanup();
            try bothSweeps(&one.spec);
        }
    }
    // each package that installs, alone (the lists of what was skipped are grown by the first entry)
    for (0..installing.len) |i| {
        for ([_]bool{ false, true }) |dirs| {
            var one = try build(a, installing[i..][0..1], dirs);
            defer one.tmp.cleanup();
            try bothSweeps(&one.spec);
        }
    }
    // more than forty problems
    var many: [45]Pkg = undefined;
    for (&many, 0..) |*p, i| p.* = .{
        .path = try std.fmt.allocPrint(a, "node_modules/p{d}", .{i}),
        .name = try std.fmt.allocPrint(a, "p{d}", .{i}),
        .version = "1.0.0",
        .no_tarball = true,
    };
    var lots = try build(a, &many, false);
    defer lots.tmp.cleanup();
    try bothSweeps(&lots.spec);
    // lockfiles that are not lockfiles
    for ([_][]const u8{ "{", "[]", "{\"lockfileVersion\":2,\"packages\":{}}" }) |lock| {
        const spec = layout.Spec{ .lockfile = lock, .tarballs = std.StringHashMap([]const u8).init(a), .sri512 = std.StringHashMap([]const u8).init(a) };
        try bothSweeps(&spec);
    }
}

fn unpackOnce(a: std.mem.Allocator, c: *const [2][]const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var msg = tartest.Sink{ .a = a };
    try layout.unpackOne(a, c[0], c[1], "x", "1.0.0", tmp.dir, &msg);
}

fn unpackWriting(w: *tartest.Sink, c: *const [2][]const u8) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try layout.unpackOne(arena.allocator(), c[0], c[1], "x", "1.0.0", tmp.dir, w);
}

test "an allocation that fails, or a line that cannot be written, while one tarball is unpacked, is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const links = try tartest.tgz(a, "x", "1.0.0", &.{.{ .name = "package/l", .kind = '2', .link = "a" }});
    const plain = try tartest.tgz(a, "x", "1.0.0", &.{.{ .name = "package/index.js", .data = "a" }});
    const bad_pj = try tartest.tgz(a, "x", "1.0.0", &.{.{ .name = "package/package.json", .data = "{" }});
    const escapes = try tartest.tgz(a, "x", "1.0.0", &.{.{ .name = "package/../../e", .data = "x" }});
    const no_pj = try tartest.gzip(a, try tartest.tar(a, &.{.{ .name = "package/index.js", .data = "x" }}));
    const cases = [_][2][]const u8{
        .{ links, try sri.of(a, links) },
        .{ plain, try sri.of(a, plain) },
        .{ bad_pj, try sri.of(a, bad_pj) },
        .{ escapes, try sri.of(a, escapes) },
        .{ no_pj, try sri.of(a, no_pj) },
        .{ plain, "sha512-other" },
        .{ plain, "sha1-x" },
    };
    for (&cases) |*c| {
        try tartest.allocSweep(unpackOnce, c);
        try tartest.writerSweep(unpackWriting, c);
    }
}

