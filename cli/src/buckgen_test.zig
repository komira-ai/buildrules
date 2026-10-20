//! buckgen.zig: the table to the registry package's BUCK file, the overrides, and the sizes file. The tests of the Python generator
//! it replaced, ported, and the ones it never had. Every test says the defect it catches.

const std = @import("std");
const buckgen = @import("buckgen.zig");
const fetch = @import("fetch.zig");
const val = @import("val.zig");
const Diag = @import("diag.zig").Diag;
const Value = val.Value;
const t = std.testing;

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

fn profile(a: std.mem.Allocator) !Value {
    return val.parseLiteral(a,
        \\{"opt_level": "0", "lto": "false", "codegen_backend": None, "codegen_units": None, "debuginfo": 0, "split_debuginfo": None,
        \\ "debug_assertions": True, "overflow_checks": True, "rpath": False, "incremental": False, "panic": "unwind", "strip": "none"}
    );
}

const Spec = struct {
    crate: []const u8,
    version: []const u8,
    mode: []const u8,
    kinds: []const []const u8,
    ctypes: []const []const u8,
    deps: []const [2][]const u8 = &.{},
    source: []const u8 = "registry",
    links: ?[]const u8 = null,
};

fn unit(a: std.mem.Allocator, s: Spec) !Value {
    var u = val.newObject(a);
    try val.put(&u, "crate", val.str(s.crate));
    try val.put(&u, "version", val.str(s.version));
    try val.put(&u, "source", val.str(s.source));
    try val.put(&u, "target_kind", try val.strList(a, s.kinds));
    try val.put(&u, "crate_types", try val.strList(a, s.ctypes));
    try val.put(&u, "target_name", val.str(s.crate));
    try val.put(&u, "mode", val.str(s.mode));
    try val.put(&u, "side", val.str("target"));
    try val.put(&u, "edition", val.str("2021"));
    try val.put(&u, "crate_root", val.str("src/lib.rs"));
    try val.put(&u, "features", val.newArray(a));
    try val.put(&u, "cfgs", val.newArray(a));
    try val.put(&u, "profile", try profile(a));
    var deps = val.newArray(a);
    for (s.deps) |d| try val.push(&deps, try val.strList(a, &d));
    try val.put(&u, "deps", deps);
    if (s.links) |l| try val.put(&u, "links", val.str(l));
    if (std.mem.eql(u8, s.source, "registry")) {
        try val.put(&u, "sha256", val.str(H));
    } else {
        try val.put(&u, "path", val.str("app"));
    }
    return u;
}

/// app (member) -> sys (lib) -> its build script run -> its build script; sys's script wants cc; other (lib) has a script too and its
/// script's run reads the variables of sys's script run (a `links` dependency).
fn table(e: *Env) !Value {
    const a = e.a();
    var units = val.newObject(a);
    const lib: []const []const u8 = &.{"lib"};
    const cb: []const []const u8 = &.{"custom-build"};
    const bin: []const []const u8 = &.{"bin"};
    try units.object.put("app-0.1.0:aaaaaaaaaa", try unit(a, .{ .crate = "app", .version = "0.1.0", .mode = "build", .kinds = lib, .ctypes = lib, .source = "path", .deps = &.{ .{ "sys", "sys-1.0.0:libaaaaaaa" }, .{ "other", "other-1.0.0:libbbbbbbb" } } }));
    try units.object.put("sys-1.0.0:libaaaaaaa", try unit(a, .{ .crate = "sys", .version = "1.0.0", .mode = "build", .kinds = lib, .ctypes = lib, .links = "sys_links", .deps = &.{.{ "build_script_build", "sys-1.0.0:runaaaaaaa" }} }));
    try units.object.put("sys-1.0.0:runaaaaaaa", try unit(a, .{ .crate = "sys", .version = "1.0.0", .mode = "run-custom-build", .kinds = cb, .ctypes = bin, .links = "sys_links", .deps = &.{.{ "build_script_build", "sys-1.0.0:bldaaaaaaa" }} }));
    try units.object.put("sys-1.0.0:bldaaaaaaa", try unit(a, .{ .crate = "sys", .version = "1.0.0", .mode = "build", .kinds = cb, .ctypes = bin, .deps = &.{.{ "cc", "cc-1.0.0:libccccccc" }} }));
    try units.object.put("cc-1.0.0:libccccccc", try unit(a, .{ .crate = "cc", .version = "1.0.0", .mode = "build", .kinds = lib, .ctypes = lib }));
    try units.object.put("other-1.0.0:libbbbbbbb", try unit(a, .{ .crate = "other", .version = "1.0.0", .mode = "build", .kinds = lib, .ctypes = lib, .deps = &.{.{ "build_script_build", "other-1.0.0:runbbbbbbb" }} }));
    try units.object.put("other-1.0.0:runbbbbbbb", try unit(a, .{ .crate = "other", .version = "1.0.0", .mode = "run-custom-build", .kinds = cb, .ctypes = bin, .deps = &.{ .{ "build_script_build", "other-1.0.0:bldbbbbbbb" }, .{ "build_script_main", "sys-1.0.0:runaaaaaaa" } } }));
    try units.object.put("other-1.0.0:bldbbbbbbb", try unit(a, .{ .crate = "other", .version = "1.0.0", .mode = "build", .kinds = cb, .ctypes = bin }));
    return units;
}

const sizes_text = "sys 1.0.0 10\ncc 1.0.0 10\nother 1.0.0 10\n";

const sys_override =
    \\{"crates": {"sys 1.0.0": {"why": "the script compiles C; a buildrules archive replaces it", "drop_build_script": true, "cfgs": ["has_archive"],
    \\  "native_deps": ["//third_party/c:lib[static-pic]"], "patch": {"copy": ["src"], "sub": [{"file": "src/lib.rs", "from": "a", "to": "b", "count": 2}]}}}}
;

const Run = struct { code: u8, out: []const u8, msg: []const u8 };

/// buckgen over the table above; `overrides_json` null = no overrides file.
fn run(e: *Env, overrides_json: ?[]const u8, opts: buckgen.Options) !Run {
    const a = e.a();
    var d = Diag.init(a);
    const units = try table(e);
    const sizes = try buckgen.parseSizes(a, &d, sizes_text);
    var ov: ?buckgen.Overrides = null;
    if (overrides_json) |j| {
        ov = buckgen.loadOverrides(a, &d, "o.json", j) catch return .{ .code = 1, .out = "", .msg = if (d.count() > 0) d.msgs.items[0] else "?" };
    }
    const out = buckgen.generate(a, &d, units, sizes, ov, opts) catch return .{ .code = 1, .out = "", .msg = if (d.count() > 0) d.msgs.items[0] else "?" };
    return .{ .code = 0, .out = out, .msg = "" };
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// The text of the target called `name`: from its `name = ` line to the next target.
fn target(out: []const u8, name: []const u8, e: *Env) ![]const u8 {
    const key = try std.fmt.allocPrint(e.a(), "name = \"{s}\"", .{name});
    const at = std.mem.indexOf(u8, out, key) orelse return error.NoSuchTarget;
    const rest = out[at..];
    const end = std.mem.indexOf(u8, rest[1..], "\ncargo_unit(") orelse std.mem.indexOf(u8, rest[1..], "\ncrate_src(") orelse rest.len - 1;
    return rest[0 .. end + 1];
}

// ---- overrides (test_overrides.py) ------------------------------------------------------------------------------------

test "overrides: without any, every script is emitted (the control: what the next tests remove is really there)" {
    var e = Env.init();
    defer e.deinit();
    const r = try run(&e, null, .{});
    try t.expectEqual(@as(u8, 0), r.code);
    // the package's own files as a target (cargo_sync stages the workspace from it): without an overrides file, none is named
    try t.expect(has(r.out, "filegroup(\n    name = \"files\",\n    srcs = [\"BUCK\", \"crate_sizes.tsv\"],"));
    for ([_][]const u8{ "sys-1.0.0_runaaaaaaa", "sys-1.0.0_bldaaaaaaa", "cc-1.0.0_libccccccc" }) |uid| {
        try t.expect(has(r.out, try std.fmt.allocPrint(e.a(), "name = \"{s}\"", .{uid})));
    }
    // the dependency edge of the library on its script's run, and the link between the two runs
    try t.expect(has(try target(r.out, "sys-1.0.0_libaaaaaaa", &e), "\"build_script_build\": \":sys-1.0.0_runaaaaaaa\""));
    try t.expect(has(try target(r.out, "other-1.0.0_runbbbbbbb", &e), "link_deps = [\n        \":sys-1.0.0_runaaaaaaa\",\n    ]"));
}

test "overrides: a dropped script and what only it needed are not emitted" {
    // Defect: the script still built (and cc still compiled for nothing), or the lib still depending on the run.
    var e = Env.init();
    defer e.deinit();
    const r = try run(&e, sys_override, .{});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(!has(r.out, "name = \"sys-1.0.0_runaaaaaaa\""));
    try t.expect(!has(r.out, "name = \"sys-1.0.0_bldaaaaaaa\""));
    try t.expect(!has(r.out, "name = \"cc-1.0.0_libccccccc\""));
    try t.expect(!has(r.out, "src-cc-1.0.0"));
    try t.expect(!has(try target(r.out, "sys-1.0.0_libaaaaaaa", &e), "build_script_build"));
}

test "overrides: a script that read the dropped ones' variables loses the edge and stays" {
    // Defect: the generator refusing, or leaving a dangling label to a unit that is not emitted.
    var e = Env.init();
    defer e.deinit();
    const r = try run(&e, sys_override, .{});
    try t.expectEqual(@as(u8, 0), r.code);
    const run_unit = try target(r.out, "other-1.0.0_runbbbbbbb", &e);
    try t.expect(!has(run_unit, "link_deps"));
    try t.expect(!has(run_unit, "sys-1.0.0_runaaaaaaa"));
    try t.expect(has(run_unit, "build_script_build"));
}

test "overrides: cfgs, native_deps and the patch reach the generated targets" {
    // Defect: an archive that is never linked, a patch that is never applied.
    var e = Env.init();
    defer e.deinit();
    const r = try run(&e, sys_override, .{});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(has(r.out, "srcs = [\"BUCK\", \"crate_sizes.tsv\", \"overrides.json\"],"));
    const lib = try target(r.out, "sys-1.0.0_libaaaaaaa", &e);
    try t.expect(has(lib, "\"has_archive\""));
    try t.expect(has(lib, "//third_party/c:lib[static-pic]"));
    const src = try target(r.out, "src-sys-1.0.0", &e);
    try t.expect(has(src, "patch = {\"copy\": [\"src\"], \"sub\": [{\"file\": \"src/lib.rs\", \"from\": \"a\", \"to\": \"b\", \"count\": 2}]}"));
    // and only the crate that was overridden carries them
    try t.expect(!has(try target(r.out, "other-1.0.0_libbbbbbbb", &e), "has_archive"));
}

test "overrides: an override that matches no unit is refused" {
    // Defect: a version bump that leaves the override behind, silently building the C after all.
    var e = Env.init();
    defer e.deinit();
    const bumped = try std.mem.replaceOwned(u8, e.a(), sys_override, "sys 1.0.0", "sys 2.0.0");
    const r = try run(&e, bumped, .{});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(has(r.msg, "no unit of the table is that crate"));
}

test "overrides: `why` is required, unknown keys and a malformed file are refused" {
    var e = Env.init();
    defer e.deinit();
    var r = try run(&e, "{\"crates\": {\"sys 1.0.0\": {\"drop_build_script\": true}}}", .{});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(has(r.msg, "`why` is required"));
    const typo = try std.mem.replaceOwned(u8, e.a(), sys_override, "\"drop_build_script\"", "\"drop_build_scripts\"");
    r = try run(&e, typo, .{});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(has(r.msg, "unknown key drop_build_scripts"));
    r = try run(&e, "{\"crate\": {}}", .{});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(has(r.msg, "the top level is"));
    r = try run(&e, "{\"crates\": {\"sys\": {\"why\": \"x\"}}}", .{});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(has(r.msg, "the key is `name version`"));
    r = try run(&e, "not json", .{});
    try t.expectEqual(@as(u8, 1), r.code);
}

// ---- the toolchain a unit names (test_toolchain.py) -------------------------------------------------------------------

test "rustc: the default compiler adds nothing to a unit; a non-default one is named in every unit" {
    // Defect: a non-default compiler whose third-party units still use the default (a proc-macro built by one rustc and loaded by another).
    var e = Env.init();
    defer e.deinit();
    const def = try run(&e, null, .{});
    try t.expect(!has(def.out, "rustc ="));
    const old = try run(&e, null, .{ .non_default_rustc = "1.85.0" });
    try t.expectEqual(@as(usize, 7), std.mem.count(u8, old.out, "    rustc = \"1.85.0\","));
    try t.expectEqual(std.mem.count(u8, old.out, "\ncargo_unit("), std.mem.count(u8, old.out, "    rustc = \"1.85.0\","));
}

// ---- the file as a whole ------------------------------------------------------------------------------------------------

test "generate: one crate_src per registry crate, units sorted by id, the same bytes on a rerun, the sizes in the downloads" {
    var e = Env.init();
    defer e.deinit();
    const r1 = try run(&e, null, .{});
    const r2 = try run(&e, null, .{});
    try t.expectEqualStrings(r1.out, r2.out);
    try t.expect(std.mem.startsWith(u8, r1.out, "# Generated by `buildrules sync` from the unit table. Do not edit.\n# 7 cargo units, 3 registry crates (sha256"));
    try t.expectEqual(@as(usize, 3), std.mem.count(u8, r1.out, "\ncrate_src("));
    try t.expect(has(r1.out, "    url = \"https://static.crates.io/crates/sys/sys-1.0.0.crate\",\n    sha256 = \"" ++ H ++ "\",\n    size_bytes = 10,\n"));
    // units sorted by id
    var last: usize = 0;
    for ([_][]const u8{ "cc-1.0.0_libccccccc", "other-1.0.0_bldbbbbbbb", "other-1.0.0_libbbbbbbb", "other-1.0.0_runbbbbbbb", "sys-1.0.0_bldaaaaaaa", "sys-1.0.0_libaaaaaaa", "sys-1.0.0_runaaaaaaa" }) |n| {
        const at = std.mem.indexOf(u8, r1.out, try std.fmt.allocPrint(e.a(), "name = \"{s}\"", .{n})) orelse return error.Missing;
        try t.expect(at > last);
        last = at;
    }
    // the member is not emitted: cargo_package makes it
    try t.expect(!has(r1.out, "app-0.1.0"));
    // a registry unit is capped (a lint in a dependency is not ours) and takes its sources from the crate_src
    const lib = try target(r1.out, "sys-1.0.0_libaaaaaaa", &e);
    try t.expect(has(lib, "    cap_lints = True,\n    src = \":src-sys-1.0.0\","));
    try t.expect(has(lib, "    crate_hash = \"libaaaaaaa\","));
    try t.expect(has(lib, "    visibility = [\"PUBLIC\"],\n)"));
}

test "generate: a crate missing from the sizes file is a refusal that says what to run" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    const sizes = try buckgen.parseSizes(e.a(), &d, "sys 1.0.0 10\n");
    try t.expectError(error.Refused, buckgen.generate(e.a(), &d, try table(&e), sizes, null, .{}));
    try t.expect(has(d.msgs.items[0], "sizes file lacks: cc 1.0.0, other 1.0.0 (run `buildrules sync`)"));
}

test "generate: what a unit cannot be built from is refused, one defect each" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    const Case = struct { from: []const u8, to: []const u8, msg: []const u8 };
    const cases = [_]Case{
        .{ .from = "lto\": \"false\"", .to = "lto\": \"thin\"", .msg = "lto=thin" },
        .{ .from = "\"rpath\": False", .to = "\"rpath\": True", .msg = "rpath/incremental/split_debuginfo" },
        .{ .from = "\"codegen_backend\": None", .to = "\"codegen_backend\": \"cranelift\"", .msg = "codegen_backend cranelift" },
        .{ .from = "\"strip\": \"none\"", .to = "\"strip\": \"weird\"", .msg = "unrecognized strip" },
    };
    for (cases) |c| {
        var d = Diag.init(a);
        const units = try table(&e);
        const cc = units.object.getPtr("cc-1.0.0:libccccccc").?;
        const p = try val.litString(a, val.get(cc.*, "profile").?, 0);
        const bad = try std.mem.replaceOwned(u8, a, p, c.from, c.to);
        try val.put(cc, "profile", try val.parseLiteral(a, bad));
        const sizes = try buckgen.parseSizes(a, &d, sizes_text);
        try t.expectError(error.Refused, buckgen.generate(a, &d, units, sizes, null, .{}));
        try t.expect(has(d.msgs.items[0], c.msg));
    }
    // a crate type buckgen has no rule for
    var d = Diag.init(a);
    const units = try table(&e);
    const cc = units.object.getPtr("cc-1.0.0:libccccccc").?;
    try val.put(cc, "crate_types", try val.strList(a, &.{"staticlib"}));
    const sizes = try buckgen.parseSizes(a, &d, sizes_text);
    try t.expectError(error.Refused, buckgen.generate(a, &d, units, sizes, null, .{}));
    try t.expect(has(d.msgs.items[0], "crate type staticlib not in v0"));
}

test "generate: a package that is also a cdylib is taken as its rlib; the strip a profile resolves to is spelled the way rustc takes it" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    var d = Diag.init(a);
    const units = try table(&e);
    const cc = units.object.getPtr("cc-1.0.0:libccccccc").?;
    try val.put(cc, "crate_types", try val.strList(a, &.{ "cdylib", "rlib" }));
    try val.put(cc, "profile", try val.parseLiteral(a, "{\"opt_level\": \"3\", \"lto\": \"false\", \"codegen_backend\": None, \"codegen_units\": 16, \"debuginfo\": 0, \"split_debuginfo\": None, \"debug_assertions\": False, \"overflow_checks\": False, \"rpath\": False, \"incremental\": False, \"panic\": \"abort\", \"strip\": {\"resolved\": {\"Named\": \"debuginfo\"}}}"));
    const sizes = try buckgen.parseSizes(a, &d, sizes_text);
    const out = try buckgen.generate(a, &d, units, sizes, null, .{});
    const tg = try target(out, "cc-1.0.0_libccccccc", &e);
    try t.expect(has(tg, "    crate_type = \"rlib\","));
    try t.expect(has(tg, "    panic = \"abort\","));
    try t.expect(has(tg, "    strip = \"debuginfo\","));
    try t.expect(has(tg, "    codegen_units = \"16\","));
    try t.expect(has(tg, "    debug_assertions = False,"));
    try t.expect(has(tg, "    opt_level = \"3\","));
}

// ---- the sizes file -------------------------------------------------------------------------------------------------------

const fake_bytes = "not really a crate";
var downloads: usize = 0;
var served_sha: []const u8 = "";

fn fakeFetch(a: std.mem.Allocator, url: []const u8) anyerror!fetch.Digest.Result {
    downloads += 1;
    if (std.mem.indexOf(u8, url, "sys-1.0.0") == null) return error.HttpStatusNotOk;
    return .{ .sha256 = served_sha, .sri512 = try a.dupe(u8, "sha512-x"), .size = 4321 };
}

fn sha256Of(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var dg: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &dg, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(dg, .lower));
}

fn oneCrateTable(a: std.mem.Allocator, sha: []const u8) !Value {
    var units = val.newObject(a);
    var u = try unit(a, .{ .crate = "sys", .version = "1.0.0", .mode = "build", .kinds = &.{"lib"}, .ctypes = &.{"lib"} });
    try val.put(&u, "sha256", val.str(sha));
    try units.object.put("sys-1.0.0:libaaaaaaa", u);
    return units;
}

test "sizes: a crate in the cargo registry cache is read, not downloaded, and its bytes are checked against the table" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("cache/index.crates.io-1949cf8c6b5b557f");
    try tmp.dir.writeFile(.{ .sub_path = "cache/index.crates.io-1949cf8c6b5b557f/sys-1.0.0.crate", .data = fake_bytes });
    const cache = try tmp.dir.realpathAlloc(a, "cache");
    buckgen.fetcher = &fakeFetch;
    downloads = 0;
    var d = Diag.init(a);
    const out = try buckgen.sizesFile(a, &d, try oneCrateTable(a, try sha256Of(a, fake_bytes)), cache);
    try t.expectEqualStrings("# name version bytes; every sha256 was checked against the table by `buildrules sync`\nsys 1.0.0 18\n", out);
    try t.expectEqual(@as(usize, 0), downloads);
    // Defect: a crate whose bytes are not the ones Cargo.lock pinned goes into the table with a size anyway.
    try t.expectError(error.Refused, buckgen.sizesFile(a, &d, try oneCrateTable(a, H), cache));
    try t.expect(has(d.msgs.items[0], "sha256"));
}

test "sizes: a crate that is not in the cache is downloaded once, its sha256 checked, and a failed download is a refusal naming the crate" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    buckgen.fetcher = &fakeFetch;
    downloads = 0;
    served_sha = H;
    var d = Diag.init(a);
    const out = try buckgen.sizesFile(a, &d, try oneCrateTable(a, H), null);
    try t.expect(has(out, "sys 1.0.0 4321\n"));
    try t.expectEqual(@as(usize, 1), downloads);
    served_sha = "f" ** 64;
    try t.expectError(error.Refused, buckgen.sizesFile(a, &d, try oneCrateTable(a, H), null));
    try t.expect(has(d.msgs.items[0], "but the table (Cargo.lock) says"));
    var units2 = try oneCrateTable(a, H);
    try val.put(units2.object.getPtr("sys-1.0.0:libaaaaaaa").?, "version", val.str("2.0.0"));
    var d2 = Diag.init(a);
    try t.expectError(error.Refused, buckgen.sizesFile(a, &d2, units2, null));
    try t.expect(has(d2.msgs.items[0], "sys 2.0.0: cannot download"));
}

test "sizes: no registry crate is the header and a blank line (what a fresh workspace commits)" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    const out = try buckgen.sizesFile(e.a(), &d, val.newObject(e.a()), null);
    try t.expectEqualStrings("# name version bytes; every sha256 was checked against the table by `buildrules sync`\n\n", out);
}

test "sizes: parse refuses a line that is not name version bytes" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    try t.expectError(error.Refused, buckgen.parseSizes(e.a(), &d, "sys 1.0.0\n"));
    try t.expectError(error.Refused, buckgen.parseSizes(e.a(), &d, "sys 1.0.0 many\n"));
    const ok = try buckgen.parseSizes(e.a(), &d, "# header\n\nsys 1.0.0 10\n");
    try t.expectEqual(@as(u64, 10), ok.get("sys 1.0.0").?);
}
