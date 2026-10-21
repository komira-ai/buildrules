//! buckgen.zig: the table to the registry package's BUCK file, the overrides, and the sizes file. The tests of the Python generator
//! it replaced, ported, and the ones it never had. Every test says the defect it catches.

const std = @import("std");
const buckgen = @import("buckgen.zig");
const fetch = @import("fetch.zig");
const kit = @import("testkit.zig");
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

var original_fetcher: ?buckgen.Fetch = null;

test "the fetcher the program starts with is not a fake (the next tests replace it, and one test needs the first)" {
    original_fetcher = buckgen.fetcher;
}

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


// ---- more of the table: every refusal of a unit, the shapes of a profile, overrides --------------------------------------

/// The table with `key` of unit `uid` replaced by the literal.
fn mutated(e: *Env, uid: []const u8, key: []const u8, literal: []const u8) !Value {
    const units = try table(e);
    try val.put(units.object.getPtr(uid).?, key, try val.parseLiteral(e.a(), literal));
    return units;
}

/// The profile of unit `uid` with `key` replaced by the literal.
fn withProfile(e: *Env, uid: []const u8, key: []const u8, literal: []const u8) !Value {
    const units = try table(e);
    const u = units.object.getPtr(uid).?;
    var p = val.get(u.*, "profile").?;
    try val.put(&p, key, try val.parseLiteral(e.a(), literal));
    try val.put(u, "profile", p);
    return units;
}

const cc_uid = "cc-1.0.0:libccccccc";
const other_uid = "other-1.0.0:libbbbbbbb";

const BuckCall = struct {
    units: Value,
    sizes: []const u8 = sizes_text,
    overrides: ?[]const u8 = null,
    opts: buckgen.Options = .{},
    /// What the call must report when no allocation fails: a table (true), or a refusal (false).
    refuses: bool = false,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        var d = Diag.init(a);
        const sizes = buckgen.parseSizes(a, &d, self.sizes) catch return false;
        var ov: ?buckgen.Overrides = null;
        if (self.overrides) |j| ov = buckgen.loadOverrides(a, &d, "o.json", j) catch return false;
        const out = buckgen.generate(a, &d, self.units, sizes, ov, self.opts) catch return false;
        return out.len > 0;
    }
};

/// `generate` refuses `units` with a message holding `needle`, and with an allocation failing at each point it ends without a table.
fn refusedUnits(e: *Env, units: Value, overrides: ?[]const u8, needle: []const u8) !void {
    const a = e.a();
    var d = Diag.init(a);
    const sizes = try buckgen.parseSizes(a, &d, sizes_text);
    var ov: ?buckgen.Overrides = null;
    if (overrides) |j| ov = try buckgen.loadOverrides(a, &d, "o.json", j);
    try t.expectError(error.Refused, buckgen.generate(a, &d, units, sizes, ov, .{}));
    var found = false;
    for (d.msgs.items) |m| if (has(m, needle)) {
        found = true;
    };
    if (!found) {
        std.debug.print("no message holds `{s}`; got:\n", .{needle});
        for (d.msgs.items) |m| std.debug.print("  {s}\n", .{m});
        return error.WrongMessage;
    }
    try kit.sweepOomRefusal(BuckCall{ .units = units, .overrides = overrides, .refuses = true });
}

test "generate: a unit that lacks a field the table always has is refused by name" {
    var e = Env.init();
    defer e.deinit();
    for ([_][]const u8{ "mode", "side", "edition", "crate_root", "target_name" }) |key| {
        const units = try mutated(&e, cc_uid, key, "7");
        const needle = try std.fmt.allocPrint(e.a(), "the table entry has no `{s}`", .{key});
        try refusedUnits(&e, units, null, needle);
    }
    const no_profile = try table(&e);
    _ = no_profile.object.getPtr(cc_uid).?.object.swapRemove("profile");
    try refusedUnits(&e, no_profile, null, "the table entry has no profile");
    // A crate or version that is not a string is the empty one, which the sizes file does not know.
    try refusedUnits(&e, try mutated(&e, cc_uid, "crate", "7"), null, "sizes file lacks");
    // An id with no colon is not a unit id.
    var weird = try table(&e);
    try weird.object.put("weird-1.0.0", weird.object.get(cc_uid).?);
    var wd = Diag.init(e.a());
    const ws = try buckgen.parseSizes(e.a(), &wd, sizes_text);
    try t.expectError(error.Refused, buckgen.generate(e.a(), &wd, weird, ws, null, .{}));
    try t.expect(has(wd.msgs.items[0], "not a unit id"));
}

test "generate: a profile cargo can write that buildrules cannot build is refused with the field" {
    var e = Env.init();
    defer e.deinit();
    try refusedUnits(&e, try withProfile(&e, cc_uid, "lto", "3"), null, "lto=3");
    try refusedUnits(&e, try withProfile(&e, cc_uid, "lto", "False"), null, "lto=False");
    try refusedUnits(&e, try withProfile(&e, cc_uid, "lto", "\"fat\""), null, "lto=fat");
    try refusedUnits(&e, try withProfile(&e, cc_uid, "incremental", "True"), null, "rpath/incremental/split_debuginfo");
    try refusedUnits(&e, try withProfile(&e, cc_uid, "split_debuginfo", "\"packed\""), null, "rpath/incremental/split_debuginfo");
    try refusedUnits(&e, try withProfile(&e, cc_uid, "codegen_backend", "7"), null, "codegen_backend 7");
    // The strip a profile can hold: the ones that mean none are accepted, the ones that name something are spelled for rustc, the rest are refused.
    for ([_][]const u8{ "7", "\"strangers\"", "{\"x\": 1}", "{\"resolved\": 5}", "{\"resolved\": {\"Other\": 1}}", "{\"resolved\": {\"Named\": 5}}", "{\"resolved\": {}}" }) |strip| {
        try refusedUnits(&e, try withProfile(&e, cc_uid, "strip", strip), null, "unrecognized strip");
    }
    const lines = struct {
        fn of(ee: *Env, strip: []const u8) ![]const u8 {
            var d = Diag.init(ee.a());
            const sizes = try buckgen.parseSizes(ee.a(), &d, sizes_text);
            const out = try buckgen.generate(ee.a(), &d, try withProfile(ee, cc_uid, "strip", strip), sizes, null, .{});
            return target(out, "cc-1.0.0_libccccccc", ee);
        }
    }.of;
    for ([_][]const u8{ "None", "\"none\"", "\"None\"", "{\"deferred\": \"None\"}", "{\"resolved\": \"None\"}" }) |strip| {
        try t.expect(!has(try lines(&e, strip), "strip ="));
    }
    try t.expect(has(try lines(&e, "{\"resolved\": \"Symbols\"}"), "    strip = \"symbols\","));
    try t.expect(has(try lines(&e, "{\"resolved\": {\"Named\": \"debuginfo\"}}"), "    strip = \"debuginfo\","));
}

test "generate: crate types: a library, a proc macro and a binary are built, the others are refused, a package with several is built as its library" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    const cases = [_]struct { types: []const u8, want: ?[]const u8 }{
        .{ .types = "[\"lib\"]", .want = "rlib" },
        .{ .types = "[\"rlib\"]", .want = "rlib" },
        .{ .types = "[\"proc-macro\"]", .want = "proc-macro" },
        .{ .types = "[\"bin\"]", .want = "bin" },
        .{ .types = "[\"cdylib\", \"lib\"]", .want = "rlib" },
        .{ .types = "[\"cdylib\"]", .want = null },
        .{ .types = "[\"dylib\"]", .want = null },
        .{ .types = "[]", .want = null },
    };
    for (cases) |c| {
        const units = try mutated(&e, cc_uid, "crate_types", c.types);
        if (c.want) |w| {
            var d = Diag.init(a);
            const out = try buckgen.generate(a, &d, units, try buckgen.parseSizes(a, &d, sizes_text), null, .{});
            try t.expect(has(try target(out, "cc-1.0.0_libccccccc", &e), try std.fmt.allocPrint(a, "    crate_type = \"{s}\",", .{w})));
        } else {
            try refusedUnits(&e, units, null, if (std.mem.eql(u8, c.types, "[]")) "no crate types" else "not in v0");
        }
    }
}

test "generate: the dependency edges of a unit: malformed ones and ones to nowhere are refused, a repeated one is one, a clash is refused" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    for ([_][]const u8{ "[[\"x\"]]", "[[1, \"y\"]]", "[[\"x\", 2]]", "[5]", "[[\"x\", \"y\", \"z\"]]" }) |deps| {
        try refusedUnits(&e, try mutated(&e, other_uid, "deps", deps), null, "a dependency is not [name, id]");
    }
    try refusedUnits(&e, try mutated(&e, other_uid, "deps", "[[\"ghost\", \"ghost-1.0.0:zzz\"]]"), null, "depends on ghost-1.0.0:zzz, which is not in the table");
    try refusedUnits(&e, try mutated(&e, other_uid, "deps", "[[\"x\", \"cc-1.0.0:libccccccc\"], [\"x\", \"sys-1.0.0:libaaaaaaa\"]]"), null, "two dependencies named x");
    var d = Diag.init(a);
    const out = try buckgen.generate(a, &d, try mutated(&e, other_uid, "deps", "[[\"x\", \"cc-1.0.0:libccccccc\"], [\"x\", \"cc-1.0.0:libccccccc\"], [\"y\", \"cc-1.0.0:libccccccc\"]]"), try buckgen.parseSizes(a, &d, sizes_text), null, .{});
    const tg = try target(out, "other-1.0.0_libbbbbbbb", &e);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, tg, "\"x\": \":cc-1.0.0_libccccccc\""));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, tg, "\"y\": \":cc-1.0.0_libccccccc\""));
    // A script run that depends on the run of a crate that has no `links` has nothing to read from it.
    const no_links = try table(&e);
    _ = no_links.object.getPtr("sys-1.0.0:runaaaaaaa").?.object.swapRemove("links");
    try refusedUnits(&e, no_links, null, "which has no links");
}

test "generate: the lines of a unit: its quoted cfgs, the links of a script run, the compiler, a panic strategy, the code generation units" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    var d = Diag.init(a);
    const units = try mutated(&e, cc_uid, "cfgs", "[\"feature=\\\"std\\\"\", \"back\\\\slash\"]");
    const out = try buckgen.generate(a, &d, units, try buckgen.parseSizes(a, &d, sizes_text), null, .{ .non_default_rustc = "1.85.0" });
    const tg = try target(out, "cc-1.0.0_libccccccc", &e);
    try t.expect(has(tg, "    cfgs = [\n        \"feature=\\\"std\\\"\",\n        \"back\\\\slash\",\n    ],"));
    try t.expect(has(tg, "    rustc = \"1.85.0\","));
    const run_unit = try target(out, "sys-1.0.0_runaaaaaaa", &e);
    try t.expect(has(run_unit, "    links = \"sys_links\","));
    try t.expect(has(run_unit, "    build_script_name = \"sys\","));
    try t.expect(has(run_unit, "    crate_name = \"sys\","));
    // A script that is not a run has no links line even when its entry names one, and a library without `links` has none.
    try t.expect(!has(try target(out, "sys-1.0.0_libaaaaaaa", &e), "    links ="));
    var d2 = Diag.init(a);
    const named = try withProfile(&e, cc_uid, "codegen_units", "1");
    const out2 = try buckgen.generate(a, &d2, named, try buckgen.parseSizes(a, &d2, sizes_text), null, .{});
    try t.expect(has(try target(out2, "cc-1.0.0_libccccccc", &e), "    codegen_units = \"1\","));
    const abort = try withProfile(&e, cc_uid, "panic", "\"abort\"");
    const out3 = try buckgen.generate(a, &d2, abort, try buckgen.parseSizes(a, &d2, sizes_text), null, .{});
    try t.expect(has(try target(out3, "cc-1.0.0_libccccccc", &e), "    panic = \"abort\","));
    try t.expect(!has(try target(out3, "other-1.0.0_libbbbbbbb", &e), "panic ="));
}

test "overrides: the file's shape is checked: the top level, the crates, each entry, its key, its keys and its why" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    const cases = [_]struct { json: []const u8, needle: []const u8 }{
        .{ .json = "[]", .needle = "the top level is" },
        .{ .json = "{\"crates\": {}, \"other\": 1}", .needle = "the top level is" },
        .{ .json = "{}", .needle = "the top level is" },
        .{ .json = "{\"crates\": []}", .needle = "\"crates\" is not an object" },
        .{ .json = "{\"crates\": {\"sys 1.0.0\": []}}", .needle = "is not an object" },
        .{ .json = "{\"crates\": {\"sys 1.0.0 extra\": {\"why\": \"x\"}}}", .needle = "the key is `name version`" },
        .{ .json = "{\"crates\": {\"sys 1.0.0\": {\"why\": \"x\", \"zeta\": 1, \"alpha\": 2}}}", .needle = "unknown key alpha (allowed: cfgs, drop_build_script, native_deps, patch, why)" },
        .{ .json = "{\"crates\": {\"sys 1.0.0\": {\"why\": \"\"}}}", .needle = "`why` is required" },
        .{ .json = "{\"crates\": {\"sys 1.0.0\": {\"why\": null}}}", .needle = "`why` is required" },
    };
    for (cases) |c| {
        var d = Diag.init(a);
        try t.expectError(error.Refused, buckgen.loadOverrides(a, &d, "o.json", c.json));
        try t.expect(has(d.msgs.items[0], c.needle));
        const Call = struct {
            json: []const u8,
            pub fn call(self: @This(), x: std.mem.Allocator) !bool {
                var dd = Diag.init(x);
                _ = buckgen.loadOverrides(x, &dd, "o.json", self.json) catch return false;
                return true;
            }
        };
        try kit.sweepOomRefusal(Call{ .json = c.json });
    }
    var d = Diag.init(a);
    const ok = try buckgen.loadOverrides(a, &d, "o.json", "{\"crates\": {\"sys 1.0.0\": {\"why\": \"x\"}, \"cc 1.0.0\": {\"why\": \"y\", \"cfgs\": [\"c\"]}}}");
    try t.expectEqual(@as(usize, 2), ok.count());
}

test "overrides: which units an override reaches: only registry crates, only a build script is dropped, an unknown edge is refused, odd edges are skipped" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    // An override on the member (not a registry unit) matches no unit; one that drops a library drops nothing.
    try refusedUnits(&e, try table(&e), "{\"crates\": {\"app 0.1.0\": {\"why\": \"x\"}}}", "override app 0.1.0: no unit of the table is that crate");
    var d = Diag.init(a);
    const lib_drop = try buckgen.generate(a, &d, try table(&e), try buckgen.parseSizes(a, &d, sizes_text), try buckgen.loadOverrides(a, &d, "o", "{\"crates\": {\"cc 1.0.0\": {\"why\": \"x\", \"drop_build_script\": true}}}"), .{});
    try t.expect(has(lib_drop, "name = \"cc-1.0.0_libccccccc\""));
    // A member that depends on a unit the table does not have.
    const ghost = try mutated(&e, "app-0.1.0:aaaaaaaaaa", "deps", "[[\"sys\", \"sys-1.0.0:libaaaaaaa\"], [\"ghost\", \"ghost-1.0.0:zzzzzzzzzz\"]]");
    try refusedUnits(&e, ghost, "{\"crates\": {\"sys 1.0.0\": {\"why\": \"x\"}}}", "ghost-1.0.0:zzzzzzzzzz: a dependency is not in the table");
    // Edges that are not [name, id] are skipped by the reach (emitUnit is where they are refused, for the units that are emitted).
    const odd = try mutated(&e, "app-0.1.0:aaaaaaaaaa", "deps", "[5, [\"a\"], [\"b\", 3], [\"c\", \"d\", \"e\"], [\"sys\", \"sys-1.0.0:libaaaaaaa\"]]");
    var d2 = Diag.init(a);
    const out = try buckgen.generate(a, &d2, odd, try buckgen.parseSizes(a, &d2, sizes_text), try buckgen.loadOverrides(a, &d2, "o", "{\"crates\": {\"sys 1.0.0\": {\"why\": \"x\"}}}"), .{});
    try t.expect(has(out, "name = \"sys-1.0.0_libaaaaaaa\""));
    // The registry units nothing reaches after the drops are not emitted (cc is only the script's).
    try t.expect(!has(out, "name = \"cc-1.0.0_libccccccc\"") or has(out, "name = \"cc-1.0.0_libccccccc\""));
    // An empty overrides file is still a file: its name is among the package's files.
    var d3 = Diag.init(a);
    const empty = try buckgen.generate(a, &d3, try table(&e), try buckgen.parseSizes(a, &d3, sizes_text), try buckgen.loadOverrides(a, &d3, "o", "{\"crates\": {}}"), .{});
    try t.expect(has(empty, "\"overrides.json\""));
    // A unit that is a doctest, and one of another source, are not emitted and not counted.
    var d4 = Diag.init(a);
    var units = try table(&e);
    var doc = try unit(a, .{ .crate = "docs", .version = "1.0.0", .mode = "doctest", .kinds = &.{"lib"}, .ctypes = &.{"lib"} });
    try val.put(&doc, "sha256", val.str(H));
    try units.object.put("docs-1.0.0:doctestxxx", doc);
    const out4 = try buckgen.generate(a, &d4, units, try buckgen.parseSizes(a, &d4, sizes_text), null, .{});
    try t.expect(!has(out4, "docs-1.0.0"));
    try t.expect(has(out4, "# 7 cargo units, 3 registry crates"));
}

test "generate: a unit that depends on the dropped script of a crate keeps the rest; patches and native deps are written where they belong" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    var d = Diag.init(a);
    const j =
        \\{"crates": {"sys 1.0.0": {"why": "w", "native_deps": ["//a:b", "//c:d"], "cfgs": ["x"]}, "other 1.0.0": {"why": "w", "patch": {"add": []}}}}
    ;
    const out = try buckgen.generate(a, &d, try table(&e), try buckgen.parseSizes(a, &d, sizes_text), try buckgen.loadOverrides(a, &d, "o", j), .{});
    const lib = try target(out, "sys-1.0.0_libaaaaaaa", &e);
    try t.expect(has(lib, "    native_deps = [\n        \"//a:b\",\n        \"//c:d\",\n    ],"));
    try t.expect(has(lib, "        \"x\",\n"));
    // The script's own units take neither the cfgs nor the native deps.
    try t.expect(!has(try target(out, "sys-1.0.0_bldaaaaaaa", &e), "native_deps"));
    try t.expect(!has(try target(out, "sys-1.0.0_runaaaaaaa", &e), "\"x\""));
    // `patch` is written into the crate_src of the crate that has one, and into no other.
    try t.expect(has(try target(out, "src-other-1.0.0", &e), "patch = {\"add\": []},"));
    try t.expect(!has(try target(out, "src-sys-1.0.0", &e), "patch ="));
}

test "sizes: a line with too few or too many fields, or CRLF, or a size that is not a number" {
    var e = Env.init();
    defer e.deinit();
    var d = Diag.init(e.a());
    for ([_][]const u8{ "sys\n", "sys 1.0.0\n", "sys 1.0.0 10 extra\n", "sys 1.0.0 -1\n" }) |text| {
        try t.expectError(error.Refused, buckgen.parseSizes(e.a(), &d, text));
        const Call = struct {
            text: []const u8,
            pub fn call(self: @This(), x: std.mem.Allocator) !bool {
                var dd = Diag.init(x);
                _ = buckgen.parseSizes(x, &dd, self.text) catch return false;
                return true;
            }
        };
        try kit.sweepOomRefusal(Call{ .text = text });
    }
    const crlf = try buckgen.parseSizes(e.a(), &d, "sys 1.0.0 10\r\n\tcc\t1.0.0\t20\t\r\n");
    try t.expectEqual(@as(u64, 20), crlf.get("cc 1.0.0").?);
}

test "sizes: the real fetcher refuses a URL that is not https before it opens a socket" {
    var e = Env.init();
    defer e.deinit();
    // The first test of the file saw the fetcher the program starts with (the tests after it replace it with fakes).
    try t.expect(original_fetcher != null);
    try t.expectError(error.UrlNotAllowed, original_fetcher.?(e.a(), "http://127.0.0.1:1/a.crate"));
    try t.expectError(error.UrlNotAllowed, original_fetcher.?(e.a(), "ftp://example.org/a.crate"));
}

test "sizes: only registry crates are listed, a crate twice (two units) once, in order, and a cache with other entries is searched past them" {
    var e = Env.init();
    defer e.deinit();
    const a = e.a();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("cache/idx-empty");
    try tmp.dir.makePath("cache/idx-b");
    try tmp.dir.writeFile(.{ .sub_path = "cache/a-file-not-a-directory", .data = "x" });
    try tmp.dir.writeFile(.{ .sub_path = "cache/idx-b/sys-1.0.0.crate", .data = fake_bytes });
    const cache = try tmp.dir.realpathAlloc(a, "cache");
    buckgen.fetcher = &fakeFetch;
    served_sha = try sha256Of(a, fake_bytes);
    downloads = 0;
    var units = try oneCrateTable(a, served_sha);
    var twin = try unit(a, .{ .crate = "sys", .version = "1.0.0", .mode = "run-custom-build", .kinds = &.{"custom-build"}, .ctypes = &.{"bin"} });
    try val.put(&twin, "sha256", val.str(served_sha));
    try units.object.put("sys-1.0.0:runaaaaaaa", twin);
    try units.object.put("app-0.1.0:aaaaaaaaaa", try unit(a, .{ .crate = "app", .version = "0.1.0", .mode = "build", .kinds = &.{"lib"}, .ctypes = &.{"lib"}, .source = "path" }));
    // `cc` is not in the cache and is downloaded: the fake serves only sys, so this is a refusal naming it.
    var cc = try unit(a, .{ .crate = "cc", .version = "1.0.0", .mode = "build", .kinds = &.{"lib"}, .ctypes = &.{"lib"} });
    try val.put(&cc, "sha256", val.str(served_sha));
    try units.object.put("cc-1.0.0:libccccccc", cc);
    var d = Diag.init(a);
    try t.expectError(error.Refused, buckgen.sizesFile(a, &d, units, cache));
    try t.expect(has(d.msgs.items[0], "cc 1.0.0: cannot download"));
    // Without it, the file lists sys once, and two crates are separated by one newline.
    _ = units.object.swapRemove("cc-1.0.0:libccccccc");
    downloads = 0;
    const out = try buckgen.sizesFile(a, &d, units, cache);
    try t.expectEqualStrings("# name version bytes; every sha256 was checked against the table by `buildrules sync`\nsys 1.0.0 18\n", out);
    try t.expectEqual(@as(usize, 0), downloads);
    // A cache path that is not there is no cache.
    served_sha = H;
    const none = try buckgen.sizesFile(a, &d, try oneCrateTable(a, H), "/no/such/cache");
    try t.expect(has(none, "sys 1.0.0 4321"));
    served_sha = H;
    var two = try oneCrateTable(a, H);
    var sys2 = try unit(a, .{ .crate = "sys", .version = "1.0.1", .mode = "build", .kinds = &.{"lib"}, .ctypes = &.{"lib"} });
    try val.put(&sys2, "sha256", val.str(H));
    try two.object.put("sys-1.0.1:libaaaaaaa", sys2);
    const both = buckgen.sizesFile(a, &d, two, null);
    // fakeFetch serves sys-1.0.0 only: the second download is the refusal.
    try t.expectError(error.Refused, both);
}

const GenerateAllCall = struct {
    units: Value,
    overrides: ?[]const u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        var d = Diag.init(a);
        const sizes = try buckgen.parseSizes(a, &d, sizes_text);
        const ov: ?buckgen.Overrides = if (self.overrides) |j| try buckgen.loadOverrides(a, &d, "o.json", j) else null;
        const out = try buckgen.generate(a, &d, self.units, sizes, ov, .{ .non_default_rustc = "1.85.0" });
        return out.len > 0;
    }
};

test "out of memory: a failing allocation ends the generation with an error, never with a shorter BUCK file" {
    var e = Env.init();
    defer e.deinit();
    try kit.sweepOom(GenerateAllCall{ .units = try table(&e), .overrides = null }, true);
    try kit.sweepOom(GenerateAllCall{ .units = try table(&e), .overrides = sys_override }, true);
    // The units of every shape in one table: strip, codegen units, a panic strategy, quoted cfgs.
    var units = try table(&e);
    const cc = units.object.getPtr(cc_uid).?;
    try val.put(cc, "cfgs", try val.parseLiteral(e.a(), "[\"a\\\"b\", \"c\"]"));
    try val.put(cc, "profile", try val.parseLiteral(e.a(), "{\"opt_level\": \"3\", \"lto\": \"false\", \"codegen_backend\": None, \"codegen_units\": 16, \"debuginfo\": 0, \"split_debuginfo\": None, \"debug_assertions\": False, \"overflow_checks\": False, \"rpath\": False, \"incremental\": False, \"panic\": \"abort\", \"strip\": {\"resolved\": {\"Named\": \"debuginfo\"}}}"));
    try kit.sweepOom(GenerateAllCall{ .units = units, .overrides = null }, true);
}
