//! `buildrules rust-project`: code intelligence for a Cargo workspace that buildrules builds.
//!
//! `develop` builds the workspace's `//:rust_analyzer_inputs` (rules/rust/rust_analyzer.bzl) on the farm, downloads it to
//! `buck-out/buildrules/ra` and writes rust-project.json, rust-analyzer's description of a project that is not built by cargo: one
//! crate per unit of the table (buildrules.lock.bzl) that the directory's index.json names, with its dependencies, cfgs and
//! environment from the table, and what only a build makes (registry sources, build-script output, proc-macro shared objects,
//! the pinned sysroot and standard library sources) from the directory. Nothing runs a host rustc, cargo or rust-analyzer: the
//! sysroot and the standard library come from the inputs, and the standard library is described in the file itself
//! (`sysroot_project`), so rust-analyzer does not run cargo to find it.
//!
//! `check` is what the file names as rust-analyzer's check on save: it builds a member's `:flycheck` (the member's `:lint` runs
//! as diagnostics) on the farm and prints rustc's diagnostics, one JSON object per line, with every file name made absolute.

const std = @import("std");
const buckgen = @import("buckgen.zig");
const contract = @import("contract.zig");
const ctxm = @import("ctx.zig");
const val = @import("val.zig");
const Diag = @import("diag.zig").Diag;
const Ctx = ctxm.Ctx;
const Value = val.Value;

pub const usage_text =
    \\usage: buildrules rust-project develop [--dir DIR] [--buck2 BUCK2] [--inputs DIR] [--project FILE]
    \\       buildrules rust-project check [--dir DIR] [--buck2 BUCK2] TARGET
    \\
    \\  develop         build //:rust_analyzer_inputs on the farm, download it to buck-out/buildrules/ra, and write
    \\                  rust-project.json for rust-analyzer from buildrules.lock.bzl and the inputs
    \\  check TARGET    build TARGET (a member's :flycheck, which rust-project.json names) and print its
    \\                  diagnostics, one JSON object per line: rust-analyzer's check on save
    \\  --dir DIR       the repository root (default .)
    \\  --buck2 BUCK2   the buck2 binary (default buck2)
    \\  --inputs DIR    develop: inputs already downloaded (`buck2 build //:rust_analyzer_inputs --out DIR`); nothing is built
    \\  --project FILE  develop: where rust-project.json is written (default rust-project.json in DIR)
    \\
    \\Exit codes: 0 ok, 1 failed, 2 usage.
    \\
;

/// The version of index.json this program reads (rules/rust/rust_analyzer.bzl `_INDEX_VERSION`).
pub const index_version: i64 = 1;

const Opts = struct {
    dir: []const u8 = ".",
    buck2: []const u8 = "buck2",
    inputs: ?[]const u8 = null,
    project: []const u8 = contract.project_file,
    target: ?[]const u8 = null,
};

pub fn run(root: *Ctx, args: []const []const u8) u8 {
    if (args.len == 0) return root.usage("rust-project: develop or check?\n{s}", .{usage_text});
    const verb = args[0];
    const develop = std.mem.eql(u8, verb, "develop");
    if (!develop and !std.mem.eql(u8, verb, "check")) return root.usage("rust-project: unknown command {s}\n{s}", .{ verb, usage_text });
    var o = Opts{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const takes = std.mem.eql(u8, arg, "--dir") or std.mem.eql(u8, arg, "--buck2") or
            (develop and (std.mem.eql(u8, arg, "--inputs") or std.mem.eql(u8, arg, "--project")));
        if (takes) {
            const v = ctxm.flagValue(args, &i) orelse return root.usage("rust-project {s}: {s} needs a value", .{ verb, arg });
            if (std.mem.eql(u8, arg, "--dir")) o.dir = v else if (std.mem.eql(u8, arg, "--buck2")) o.buck2 = v else if (std.mem.eql(u8, arg, "--inputs")) o.inputs = v else o.project = v;
        } else if (!develop and o.target == null and !std.mem.startsWith(u8, arg, "-")) {
            o.target = arg;
        } else {
            return root.usage("rust-project {s}: unknown argument {s}\n{s}", .{ verb, arg, usage_text });
        }
    }
    if (!develop) {
        const t = o.target orelse return root.usage("rust-project check: which target? (rust-project.json passes a member's :flycheck)\n{s}", .{usage_text});
        if (!std.mem.startsWith(u8, t, "//") or std.mem.indexOfScalar(u8, t, ':') == null) {
            return root.usage("rust-project check: {s} is not a target (//<member>:flycheck)", .{t});
        }
    }
    var ctx = root.into(o.dir) catch |e| return root.fail("cannot open {s}: {s}", .{ o.dir, @errorName(e) });
    defer ctx.dir.close();
    if (develop) return finish(root, verb, writeProject(&ctx, o));
    return finish(root, verb, check(&ctx, o, o.target.?));
}

/// The exit code of a verb's result: a refusal has said why; any other error is named.
fn finish(root: *Ctx, verb: []const u8, r: anytype) u8 {
    return r catch |e| switch (e) {
        error.Refused => ctxm.exit_fail,
        else => root.fail("rust-project {s}: {s}", .{ verb, @errorName(e) }),
    };
}

fn refuse(ctx: *Ctx, comptime fmt: []const u8, args: anytype) error{Refused} {
    _ = ctx.fail(fmt, args);
    return error.Refused;
}

// ---- develop ---------------------------------------------------------------------------------------------------------

/// The table's parts this command reads.
const Table = struct { rustc: []const u8, units: Value, packages: Value };

fn readTable(ctx: *Ctx) !Table {
    const a = ctx.a;
    const text = (try ctx.readOpt(contract.lock_file)) orelse return refuse(ctx, "{s} is missing: run `buildrules sync` first", .{contract.lock_file});
    var out: Table = undefined;
    inline for (.{ "RUSTC", "UNITS", "PACKAGES" }) |name| {
        const v = val.readNamed(a, text, name) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return refuse(ctx, "{s}: {s} is not a literal: run `buildrules sync`", .{ contract.lock_file, name }),
        };
        const got = v orelse return refuse(ctx, "{s} has no {s}: run `buildrules sync`", .{ contract.lock_file, name });
        if (comptime std.mem.eql(u8, name, "RUSTC")) {
            if (got != .string) return refuse(ctx, "{s}: RUSTC is not a string", .{contract.lock_file});
            out.rustc = got.string;
        } else if (got != .object) {
            return refuse(ctx, "{s}: {s} is not a dict", .{ contract.lock_file, name });
        } else if (comptime std.mem.eql(u8, name, "UNITS")) out.units = got else out.packages = got;
    }
    return out;
}

/// The inputs' index.json (rules/rust/rust_analyzer.bzl), checked against this program and the table.
const Index = struct { units: []const Value, crates: Value, runs: Value, proc_macros: Value, extra_dirs: Value, sysroot: []const u8, sysroot_src: []const u8 };

fn readIndex(ctx: *Ctx, inputs: []const u8, rustc: []const u8) !Index {
    const a = ctx.a;
    const path = try std.fs.path.join(a, &.{ inputs, "index.json" });
    const text = (try ctx.readOpt(path)) orelse return refuse(ctx, "{s} is missing: {s} is not a directory `//:rust_analyzer_inputs` made", .{ path, inputs });
    const v = std.json.parseFromSliceLeaky(Value, a, text, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(ctx, "{s}: not JSON ({s})", .{ path, @errorName(e) }),
    };
    const version = val.get(v, "version") orelse Value{ .null = {} };
    if (version != .integer or version.integer != index_version) {
        const shown = val.pyStr(a, version) catch "that is not a number";
        return refuse(ctx, "{s}: version {s}, and this program reads version {d}: use the buildrules release the repository's buildrules cell is", .{ path, shown, index_version });
    }
    const made_for = val.getStr(v, "rustc") orelse "";
    if (!std.mem.eql(u8, made_for, rustc)) {
        return refuse(ctx, "{s} was made for rustc {s} and {s} is for rustc {s}: build the inputs again", .{ path, made_for, contract.lock_file, rustc });
    }
    return .{
        .units = val.items(val.get(v, "units")),
        .crates = try object(ctx, path, v, "crates"),
        .runs = try object(ctx, path, v, "runs"),
        .proc_macros = try object(ctx, path, v, "proc_macros"),
        .extra_dirs = try object(ctx, path, v, "extra_dirs"),
        .sysroot = val.getStr(v, "sysroot") orelse return refuse(ctx, "{s}: no `sysroot`", .{path}),
        .sysroot_src = val.getStr(v, "sysroot_src") orelse return refuse(ctx, "{s}: no `sysroot_src`", .{path}),
    };
}

fn object(ctx: *Ctx, path: []const u8, v: Value, key: []const u8) !Value {
    const x = val.get(v, key) orelse Value{ .null = {} };
    if (x != .object) return refuse(ctx, "{s}: `{s}` is not an object", .{ path, key });
    return x;
}

const Field = struct { []const u8, Value };

/// An object of `fields`, in their order. One allocation: what the file holds is built with as few places that can fail as there are objects.
fn obj(a: std.mem.Allocator, fields: []const Field) !Value {
    var v = val.newObject(a);
    try v.object.ensureTotalCapacity(fields.len);
    for (fields) |f| v.object.putAssumeCapacity(f[0], f[1]);
    return v;
}

fn strings(a: std.mem.Allocator, v: ?Value) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (val.items(v)) |x| if (x == .string) try out.append(a, x.string);
    return out.toOwnedSlice(a);
}

fn has(xs: []const []const u8, x: []const u8) bool {
    for (xs) |y| if (std.mem.eql(u8, x, y)) return true;
    return false;
}

/// The edition of the standard library's crates (as rust-src's own manifests say).
const std_edition = "2024";

/// The standard library crates rust-project.json describes (`sysroot_project`), paths relative to the library sources. `core` must
/// exist; a crate whose root a release does not have is left out, with the edges to it.
const sysroot_crates = [_]struct { name: []const u8, root: []const u8, deps: []const []const u8 }{
    .{ .name = "core", .root = "core/src/lib.rs", .deps = &.{} },
    .{ .name = "alloc", .root = "alloc/src/lib.rs", .deps = &.{"core"} },
    .{ .name = "std_detect", .root = "std_detect/src/lib.rs", .deps = &.{ "core", "alloc" } },
    .{ .name = "std", .root = "std/src/lib.rs", .deps = &.{ "alloc", "core", "std_detect" } },
    .{ .name = "proc_macro", .root = "proc_macro/src/lib.rs", .deps = &.{ "std", "core" } },
    .{ .name = "test", .root = "test/src/lib.rs", .deps = &.{ "std", "core" } },
};

fn sysrootProject(ctx: *Ctx, src_abs: []const u8, edition: []const u8) !Value {
    const a = ctx.a;
    var crates = val.newArray(a);
    var at = std.StringHashMap(i64).init(a);
    for (sysroot_crates) |c| {
        if (!ctx.exists(try std.fs.path.join(a, &.{ src_abs, c.root }))) {
            if (std.mem.eql(u8, c.name, "core")) return refuse(ctx, "{s} has no {s}: the inputs' rust-src is not the standard library's sources", .{ src_abs, c.root });
            continue;
        }
        var deps = val.newArray(a);
        for (c.deps) |d| if (at.get(d)) |n| try val.push(&deps, try obj(a, &.{ .{ "crate", val.int(n) }, .{ "name", val.str(d) } }));
        try at.put(c.name, @intCast(crates.array.items.len));
        try val.push(&crates, try obj(a, &.{
            .{ "display_name", val.str(c.name) },
            .{ "root_module", val.str(c.root) },
            .{ "edition", val.str(edition) },
            .{ "deps", deps },
            .{ "is_workspace_member", val.boolean(false) },
        }));
    }
    return obj(a, &.{.{ "crates", crates }});
}

/// What a build-script run gave the crates that use it: its OUT_DIR, the `--cfg`s of its rustc_args and the rustc_env variables.
const Run = struct { out_dir: []const u8, cfgs: []const []const u8, env: []const [2][]const u8 };

fn readRun(ctx: *Ctx, inputs_abs: []const u8, rel: []const u8, manifest_dir: []const u8) !Run {
    const a = ctx.a;
    const dir = try std.fs.path.join(a, &.{ inputs_abs, rel });
    const out_dir = try std.fs.path.join(a, &.{ dir, "OUT_DIR" });
    var cfgs = std.ArrayList([]const u8).empty;
    var env = std.ArrayList([2][]const u8).empty;
    const args_path = try std.fs.path.join(a, &.{ dir, "rustc_args" });
    const args_text = (try ctx.readOpt(args_path)) orelse return refuse(ctx, "{s} is missing: the inputs are not what `//:rust_analyzer_inputs` makes", .{args_path});
    var lines = std.mem.splitScalar(u8, args_text, '\n');
    while (lines.next()) |l| {
        // One argument per line (rules/rust/bs_runner.zig): a `--cfg` is followed by its value.
        if (std.mem.eql(u8, l, "--cfg")) if (lines.next()) |c| try cfgs.append(a, try expand(a, c, out_dir, manifest_dir));
    }
    const env_path = try std.fs.path.join(a, &.{ dir, "rustc_env" });
    const env_text = (try ctx.readOpt(env_path)) orelse return refuse(ctx, "{s} is missing: the inputs are not what `//:rust_analyzer_inputs` makes", .{env_path});
    var el = std.mem.splitScalar(u8, env_text, '\n');
    while (el.next()) |l| {
        if (l.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, l, '=') orelse return refuse(ctx, "{s}: a line has no `=`: {s}", .{ env_path, l });
        try env.append(a, .{ l[0..eq], try expand(a, l[eq + 1 ..], out_dir, manifest_dir) });
    }
    return .{ .out_dir = out_dir, .cfgs = cfgs.items, .env = env.items };
}

/// The tokens a build-script run records in place of the worker's paths (rules/rust/bs_runner.zig), made the paths here.
fn expand(a: std.mem.Allocator, s: []const u8, out_dir: []const u8, manifest_dir: []const u8) ![]const u8 {
    const x = try std.mem.replaceOwned(u8, a, s, "{OUT_DIR}", out_dir);
    return std.mem.replaceOwned(u8, a, x, "{MANIFEST_DIR}", manifest_dir);
}

/// The package variables cargo sets for a crate (rules/rust/cargo_unit.bzl `_pkg_env` does the same for rustc).
fn pkgEnv(env: *Value, crate: []const u8, version: []const u8, crate_name: []const u8, manifest_dir: []const u8) !void {
    const v = if (std.mem.indexOfScalar(u8, version, '+')) |p| version[0..p] else version;
    const core = if (std.mem.indexOfScalar(u8, v, '-')) |p| v[0..p] else v;
    const pre = if (core.len < v.len) v[core.len + 1 ..] else "";
    var nums = [3][]const u8{ "0", "0", "0" };
    var it = std.mem.splitScalar(u8, core, '.');
    for (&nums) |*n| n.* = it.next() orelse "0";
    const pairs = [_][2][]const u8{
        .{ "CARGO_CRATE_NAME", crate_name },
        .{ "CARGO_MANIFEST_DIR", manifest_dir },
        .{ "CARGO_PKG_AUTHORS", "" },
        .{ "CARGO_PKG_DESCRIPTION", "" },
        .{ "CARGO_PKG_HOMEPAGE", "" },
        .{ "CARGO_PKG_LICENSE", "" },
        .{ "CARGO_PKG_LICENSE_FILE", "" },
        .{ "CARGO_PKG_NAME", crate },
        .{ "CARGO_PKG_README", "" },
        .{ "CARGO_PKG_REPOSITORY", "" },
        .{ "CARGO_PKG_RUST_VERSION", "" },
        .{ "CARGO_PKG_VERSION", version },
        .{ "CARGO_PKG_VERSION_MAJOR", nums[0] },
        .{ "CARGO_PKG_VERSION_MINOR", nums[1] },
        .{ "CARGO_PKG_VERSION_PATCH", nums[2] },
        .{ "CARGO_PKG_VERSION_PRE", pre },
    };
    try env.object.ensureUnusedCapacity(pairs.len);
    for (pairs) |kv| env.object.putAssumeCapacity(kv[0], val.str(kv[1]));
}

fn isCustomBuild(a: std.mem.Allocator, u: Value) !bool {
    const kinds = try strings(a, val.get(u, "target_kind"));
    return kinds.len == 1 and std.mem.eql(u8, kinds[0], "custom-build");
}

/// rust-project.json for the table and the inputs at `inputs_abs`; `root_abs` is the workspace root, `self_exe` and `buck2` what the
/// check on save runs.
fn project(ctx: *Ctx, table: Table, index: Index, root_abs: []const u8, inputs_abs: []const u8, overrides: ?buckgen.Overrides, self_exe: []const u8, buck2: []const u8) !Value {
    const a = ctx.a;
    const units = table.units;
    // 1. The rows: the units the index names that rustc compiles (a run of a build script is not a crate).
    var rows = std.ArrayList([]const u8).empty;
    var row_of = std.StringHashMap(i64).init(a);
    for (index.units) |x| {
        if (x != .string) return refuse(ctx, "index.json: a unit id is not a string", .{});
        const u = units.object.get(x.string) orelse return refuse(ctx, "index.json names {s}, which {s} does not have: build the inputs again", .{ x.string, contract.lock_file });
        const mode = val.getStr(u, "mode") orelse "";
        if (!std.mem.eql(u8, mode, "build") and !std.mem.eql(u8, mode, "test")) continue;
        try row_of.put(x.string, @intCast(rows.items.len));
        try rows.append(a, x.string);
    }
    var crates = val.newArray(a);
    for (rows.items) |uid| try val.push(&crates, try crateRow(ctx, table, index, uid, &row_of, root_abs, inputs_abs, overrides));

    // 2. The file. The check on save is this program's `rust-project check` of the crate's label (`{label}`, rust-analyzer's placeholder).
    const src_abs = try std.fs.path.join(a, &.{ inputs_abs, index.sysroot_src });
    const check_cmd = try obj(a, &.{
        .{ "kind", val.str("flycheck") },
        .{ "program", val.str(self_exe) },
        .{ "args", try val.strList(a, &.{ "rust-project", "check", "--dir", root_abs, "--buck2", buck2, "{label}" }) },
        .{ "cwd", val.str(root_abs) },
    });
    var runnables = val.newArray(a);
    try val.push(&runnables, check_cmd);
    return obj(a, &.{
        .{ "sysroot", val.str(try std.fs.path.join(a, &.{ inputs_abs, index.sysroot })) },
        .{ "sysroot_src", val.str(src_abs) },
        .{ "sysroot_project", try sysrootProject(ctx, src_abs, std_edition) },
        .{ "crates", crates },
        .{ "runnables", runnables },
    });
}

fn crateRow(ctx: *Ctx, table: Table, index: Index, uid: []const u8, row_of: *std.StringHashMap(i64), root_abs: []const u8, inputs_abs: []const u8, overrides: ?buckgen.Overrides) !Value {
    const a = ctx.a;
    const units = table.units;
    const u = units.object.get(uid).?;
    const crate = val.getStr(u, "crate") orelse return refuse(ctx, "{s}: {s} has no `crate`", .{ contract.lock_file, uid });
    const version = val.getStr(u, "version") orelse "";
    const target_name = val.getStr(u, "target_name") orelse crate;
    const crate_root = val.getStr(u, "crate_root") orelse return refuse(ctx, "{s}: {s} has no `crate_root`", .{ contract.lock_file, uid });
    const registry = std.mem.eql(u8, val.getStr(u, "source") orelse "", "registry");
    const custom = try isCustomBuild(a, u);
    const kinds = try strings(a, val.get(u, "target_kind"));
    const crate_types = try strings(a, val.get(u, "crate_types"));
    const test_mode = std.mem.eql(u8, val.getStr(u, "mode") orelse "", "test");
    const proc_macro = !test_mode and has(crate_types, "proc-macro");

    // Where the crate's files are: a member's directory in the checkout, a registry crate's in the inputs.
    var manifest_dir: []const u8 = undefined;
    var member_path: []const u8 = "";
    if (registry) {
        const key = try std.fmt.allocPrint(a, "{s}-{s}", .{ crate, version });
        const rel = val.getStr(index.crates, key) orelse return refuse(ctx, "the inputs have no sources of {s} {s}: build the inputs again", .{ crate, version });
        manifest_dir = try std.fs.path.join(a, &.{ inputs_abs, rel });
    } else {
        const pkg = val.get(table.packages, crate) orelse return refuse(ctx, "{s}: {s} is not a member in PACKAGES", .{ contract.lock_file, crate });
        member_path = val.getStr(pkg, "path") orelse return refuse(ctx, "{s}: member {s} has no `path`", .{ contract.lock_file, crate });
        manifest_dir = try std.fs.path.join(a, &.{ root_abs, member_path });
    }
    var include = std.ArrayList([]const u8).empty;
    try include.append(a, manifest_dir);
    // A member's files outside its package (a `#[path]` module): rust-analyzer resolves a module only in the crate's own source root.
    if (!registry) for (try strings(a, val.get(index.extra_dirs, crate))) |d| try include.append(a, try std.fs.path.join(a, &.{ root_abs, d }));
    const crate_name = try a.dupe(u8, if (custom) crate else target_name);
    std.mem.replaceScalar(u8, crate_name, '-', '_');

    var env = val.newObject(a);
    try pkgEnv(&env, crate, version, crate_name, manifest_dir);
    var cfgs = std.ArrayList([]const u8).empty;
    try cfgs.appendSlice(a, try strings(a, val.get(u, "cfgs")));
    const profile = val.get(u, "profile") orelse Value{ .null = {} };
    if (val.truthy(val.get(profile, "debug_assertions"))) try cfgs.append(a, "debug_assertions");
    if (test_mode) try cfgs.append(a, "test");
    const override: ?Value = if (overrides) |ov| ov.get(try std.fmt.allocPrint(a, "{s} {s}", .{ crate, version })) else null;
    if (registry and !custom) if (override) |o| try cfgs.appendSlice(a, try strings(a, val.get(o, "cfgs")));

    var deps = val.newArray(a);
    var dep_names = std.ArrayList([]const u8).empty;
    for (val.items(val.get(u, "deps"))) |dep| {
        if (dep != .array or dep.array.items.len != 2 or dep.array.items[0] != .string or dep.array.items[1] != .string) {
            return refuse(ctx, "{s}: {s}: a dependency is not [name, id]", .{ contract.lock_file, uid });
        }
        const ext = dep.array.items[0].string;
        const did = dep.array.items[1].string;
        const du = units.object.get(did) orelse return refuse(ctx, "{s}: {s} depends on {s}, which is not in the table", .{ contract.lock_file, uid, did });
        if (std.mem.eql(u8, val.getStr(du, "mode") orelse "", "run-custom-build")) {
            // The build script this crate is compiled with: its OUT_DIR, cfgs and variables. An override may have dropped a registry crate's.
            const tname = try a.dupe(u8, did);
            std.mem.replaceScalar(u8, tname, ':', '_');
            const rel = val.getStr(index.runs, tname) orelse {
                const dropped = override != null and val.truthy(val.get(override.?, "drop_build_script"));
                if (registry and dropped) continue;
                return refuse(ctx, "the inputs have no run of the build script {s} that {s} is compiled with: build the inputs again", .{ did, uid });
            };
            const r = try readRun(ctx, inputs_abs, rel, manifest_dir);
            try env.object.ensureUnusedCapacity(r.env.len + 1);
            env.object.putAssumeCapacity("OUT_DIR", val.str(r.out_dir));
            for (r.env) |kv| env.object.putAssumeCapacity(kv[0], val.str(kv[1]));
            try cfgs.appendSlice(a, r.cfgs);
            try include.append(a, r.out_dir);
            continue;
        }
        // A binary of the same package (an integration test's CARGO_BIN_EXE_<name>) is not a dependency rustc links.
        const dkinds = try strings(a, val.get(du, "target_kind"));
        if (dkinds.len == 1 and std.mem.eql(u8, dkinds[0], "bin")) continue;
        const n = row_of.get(did) orelse return refuse(ctx, "{s} depends on {s}, which the inputs' index does not name: build the inputs again", .{ uid, did });
        if (has(dep_names.items, ext)) continue; // cargo lists a package that names itself as a dev-dependency twice
        try dep_names.append(a, ext);
        try val.push(&deps, try obj(a, &.{ .{ "crate", val.int(n) }, .{ "name", val.str(ext) } }));
    }

    var fields = std.ArrayList(Field).empty;
    try fields.appendSlice(a, &.{
        .{ "display_name", val.str(target_name) },
        .{ "root_module", val.str(try std.fs.path.join(a, &.{ manifest_dir, crate_root })) },
        .{ "edition", val.str(val.getStr(u, "edition") orelse "2015") },
        .{ "version", val.str(version) },
        .{ "deps", deps },
        .{ "cfg", try val.strList(a, cfgs.items) },
        .{ "env", env },
        .{ "is_workspace_member", val.boolean(!registry) },
        .{ "source", try obj(a, &.{ .{ "include_dirs", try val.strList(a, include.items) }, .{ "exclude_dirs", val.newArray(a) } }) },
    });
    if (proc_macro) {
        const rel = val.getStr(index.proc_macros, uid) orelse return refuse(ctx, "the inputs have no shared object of the proc-macro {s}: build the inputs again", .{uid});
        try fields.appendSlice(a, &.{ .{ "is_proc_macro", val.boolean(true) }, .{ "proc_macro_dylib_path", val.str(try std.fs.path.join(a, &.{ inputs_abs, rel })) } });
    }
    if (!registry) {
        // The member's check on save: its `:flycheck` (rust-project check builds it).
        const kind: []const u8 = if (test_mode or has(kinds, "test")) "test" else if (has(kinds, "bin") or custom) "bin" else "lib";
        try fields.append(a, .{ "build", try obj(a, &.{
            .{ "label", val.str(try std.fmt.allocPrint(a, "//{s}:flycheck", .{member_path})) },
            .{ "build_file", val.str(try std.fs.path.join(a, &.{ manifest_dir, "BUCK" })) },
            .{ "target_kind", val.str(kind) },
        }) });
    }
    return obj(a, fields.items);
}

fn writeProject(ctx: *Ctx, o: Opts) !u8 {
    const a = ctx.a;
    const table = try readTable(ctx);
    const inputs = o.inputs orelse blk: {
        // `--out` copies into what is there and leaves what is not in the output: start from nothing.
        try ctx.dir.deleteTree(contract.ra_dir);
        const r = ctx.execer(ctx, .{ .argv = &.{ o.buck2, "build", contract.ra_target, "--out", contract.ra_dir }, .capture = true }) catch |e| {
            return refuse(ctx, "cannot run {s}: {s}", .{ o.buck2, @errorName(e) });
        };
        if (r.code != 0) return refuse(ctx, "`{s} build {s}` exited {d} (its output says why)", .{ o.buck2, contract.ra_target, r.code });
        break :blk contract.ra_dir;
    };
    const index = try readIndex(ctx, inputs, table.rustc);
    const root_abs = try ctx.dir.realpathAlloc(a, ".");
    const inputs_abs = ctx.dir.realpathAlloc(a, inputs) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return refuse(ctx, "{s}: {s}", .{ inputs, @errorName(e) }),
    };
    var overrides: ?buckgen.Overrides = null;
    if (try ctx.readOpt(contract.overrides_file)) |text| {
        var d = Diag.init(a);
        overrides = buckgen.loadOverrides(a, &d, contract.overrides_file, text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                for (d.msgs.items) |m| _ = ctx.fail("{s}", .{m});
                return error.Refused;
            },
        };
    }
    const self_exe = try std.fs.selfExePathAlloc(a);
    const p = try project(ctx, table, index, root_abs, inputs_abs, overrides, self_exe, o.buck2);
    const text = try std.json.Stringify.valueAlloc(a, p, .{ .whitespace = .indent_2 });
    try ctx.write(o.project, try std.fmt.allocPrint(a, "{s}\n", .{text}));
    ctx.say("wrote   {s} ({d} crates, inputs in {s})", .{ o.project, val.items(val.get(p, "crates")).len, inputs });
    return ctxm.exit_ok;
}

// ---- check -----------------------------------------------------------------------------------------------------------

/// Every `file_name` in a diagnostic (its spans, its children's, the spans of a macro expansion) made absolute against `root`.
pub fn absoluteFileNames(a: std.mem.Allocator, v: *Value, root: []const u8) !void {
    switch (v.*) {
        .object => |*o| {
            var it = o.iterator();
            while (it.next()) |e| {
                if (std.mem.eql(u8, e.key_ptr.*, "file_name") and e.value_ptr.* == .string and !std.fs.path.isAbsolute(e.value_ptr.string)) {
                    e.value_ptr.* = val.str(try std.fs.path.join(a, &.{ root, e.value_ptr.string }));
                } else {
                    try absoluteFileNames(a, e.value_ptr, root);
                }
            }
        },
        .array => |*arr| for (arr.items) |*x| try absoluteFileNames(a, x, root),
        else => {},
    }
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn check(ctx: *Ctx, o: Opts, target: []const u8) !u8 {
    const a = ctx.a;
    try ctx.dir.deleteTree(contract.flycheck_dir);
    // Standard output is the diagnostics: buck2's own output is captured, its progress and errors stay on standard error.
    const b = ctx.execer(ctx, .{ .argv = &.{ o.buck2, "build", target, "--out", contract.flycheck_dir }, .capture = true }) catch |e| {
        return refuse(ctx, "cannot run {s}: {s}", .{ o.buck2, @errorName(e) });
    };
    if (b.code != 0) return refuse(ctx, "`{s} build {s}` exited {d} (its output says why)", .{ o.buck2, target, b.code });
    // rustc names a file by its path from the project root, where the action ran.
    const r = ctx.execer(ctx, .{ .argv = &.{ o.buck2, "root", "--kind", "project" }, .capture = true }) catch |e| {
        return refuse(ctx, "cannot run {s}: {s}", .{ o.buck2, @errorName(e) });
    };
    const root = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (r.code != 0 or !std.fs.path.isAbsolute(root)) return refuse(ctx, "`{s} root --kind project` exited {d} and printed `{s}`, not the project's root", .{ o.buck2, r.code, root });

    var dir = ctx.dir.openDir(contract.flycheck_dir, .{ .iterate = true }) catch |e| return refuse(ctx, "{s}: {s} (is {s} a :flycheck target?)", .{ contract.flycheck_dir, @errorName(e), target });
    defer dir.close();
    var names = std.ArrayList([]const u8).empty;
    var it = dir.iterate();
    while (try it.next()) |e| if (e.kind == .file and std.mem.endsWith(u8, e.name, ".json")) try names.append(a, try a.dupe(u8, e.name));
    std.mem.sort([]const u8, names.items, {}, lessThan);
    var n: usize = 0;
    for (names.items) |name| {
        const text = try ctx.read(try std.fs.path.join(a, &.{ contract.flycheck_dir, name }));
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            var v = std.json.parseFromSliceLeaky(Value, a, line, .{}) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return refuse(ctx, "{s}: a line is not JSON ({s}): {s}", .{ name, @errorName(e), line }),
            };
            try absoluteFileNames(a, &v, root);
            ctx.say("{s}", .{try std.json.Stringify.valueAlloc(a, v, .{})});
            n += 1;
        }
    }
    ctx.err.print("buildrules: {s}: {d} diagnostic(s) from {d} unit(s)\n", .{ target, n, names.items.len }) catch {};
    return ctxm.exit_ok;
}
