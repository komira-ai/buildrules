//! `buildrules mojo sync` and `buildrules mojo check` (docs/contract.md, section 12).
//!
//! mopm owns what "build Mojo" means. `sync` asks the pinned mopm for each package's unit graph (`mopm plan --unit-graph
//! --locked`, offline: it never resolves) and commits mopm's answer verbatim as buildrules.mojo.lock.bzl next to the package's
//! mopm.toml, plus the toolchain facts the graphs carry as toolchains/mojo_pins.bzl. `check` is the offline gate: it reads
//! the files and fails when the committed table no longer describes them.
//!
//! The version choices are made in mopm-toolchain.toml, found by walking up from the package like rustup finds
//! rust-toolchain.toml, and required like it, with no default:
//!
//!     [toolchain]
//!     mopm = "0.0.1"     # a version of rules/mopm/pins.bzl, or one buildrules-pins.toml supplies a hash for
//!     mojo = "1.0.0"     # a version mopm pins a toolchain for: the graph names it, the lock records it
//!
//! `sync` runs mopm and (for the pinned mopm) buck2; `check` runs nothing.

const std = @import("std");
const contract = @import("contract.zig");
const ctxm = @import("ctx.zig");
const lockm = @import("mojo_lock.zig");
const mopm_pins = @import("mopm_pins.zig");
const pins_toml = @import("pins_toml.zig");
const toolchain = @import("toolchain.zig");
const Diag = @import("diag.zig").Diag;
const Ctx = ctxm.Ctx;

pub const usage_text =
    \\usage: buildrules mojo sync [--dir DIR] [--check] [--mopm MOPM] [--buck2 BUCK2] [PACKAGE_DIR...]
    \\       buildrules mojo check [--dir DIR]
    \\
    \\  sync    for each package (a directory with a mopm.toml and a BUCK file that calls mojo_package; no PACKAGE_DIR =
    \\          all of them): the pinned mopm's `plan --unit-graph --locked` is written, verbatim, as buildrules.mojo.lock.bzl
    \\          beside mopm.toml, with buildrules.mojo.bzl (the glue the BUCK file loads); the toolchain facts of the graphs go to
    \\          toolchains/mojo_pins.bzl and buildrules-pins.toml's [mopm."V"] tables to toolchains/mopm_pins.bzl.
    \\          --check writes nothing outside buck-out/ and exits 1 unless every file is what a sync now would write.
    \\          mopm is built by `buck2 build toolchains//:mopm_<v>` unless --mopm names an executable.
    \\  check   offline, read-only: exit 1 when a mopm.toml, mopm.lock, mopm-toolchain.toml, a source or a test file is not what the
    \\          committed table was made from, or a generated file is hand-edited.
    \\
    \\  --dir DIR  the repository root (default .): holds .buckconfig
    \\
    \\Exit codes: 0 ok, 1 failed or stale, 2 usage.
    \\
;

pub fn run(root: *Ctx, args: []const []const u8) u8 {
    if (args.len == 0) return root.usage("mojo: needs a subcommand\n{s}", .{usage_text});
    const sub = args[0];
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        root.say("{s}", .{usage_text});
        return ctxm.exit_ok;
    }
    const is_sync = std.mem.eql(u8, sub, "sync");
    if (!is_sync and !std.mem.eql(u8, sub, "check")) return root.usage("mojo: unknown subcommand {s}\n{s}", .{ sub, usage_text });
    var dir: []const u8 = ".";
    var check_only = !is_sync;
    var mopm_path: ?[]const u8 = null;
    var buck2: []const u8 = "buck2";
    var pkgs = std.ArrayList([]const u8).empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dir")) {
            dir = ctxm.flagValue(args, &i) orelse return root.usage("mojo {s}: --dir needs a value", .{sub});
        } else if (is_sync and std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        } else if (is_sync and std.mem.eql(u8, arg, "--mopm")) {
            mopm_path = ctxm.flagValue(args, &i) orelse return root.usage("mojo sync: --mopm needs a value", .{});
        } else if (is_sync and std.mem.eql(u8, arg, "--buck2")) {
            buck2 = ctxm.flagValue(args, &i) orelse return root.usage("mojo sync: --buck2 needs a value", .{});
        } else if (is_sync and arg.len > 0 and arg[0] != '-') {
            pkgs.append(root.a, trimSlashes(arg)) catch return ctxm.exit_fail;
        } else {
            return root.usage("mojo {s}: unknown argument {s}\n{s}", .{ sub, arg, usage_text });
        }
    }
    var ctx = root.into(dir) catch |e| return root.fail("cannot open {s}: {s}", .{ dir, @errorName(e) });
    defer ctx.dir.close();
    if (is_sync) return sync(&ctx, pkgs.items, check_only, mopm_path, buck2) catch |e| root.fail("mojo sync: {s}", .{@errorName(e)});
    return checkAll(&ctx) catch |e| root.fail("mojo check: {s}", .{@errorName(e)});
}

fn trimSlashes(s: []const u8) []const u8 {
    var t = s;
    while (std.mem.startsWith(u8, t, "./")) t = t[2..];
    while (t.len > 1 and t[t.len - 1] == '/') t = t[0 .. t.len - 1];
    return if (std.mem.eql(u8, t, ".")) "" else t;
}

// ---- paths -------------------------------------------------------------------------------------------

/// `a/b/../c` -> `a/c`; "" is the root. A path that leaves the root keeps its leading `..`.
pub fn normalize(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var parts = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
                continue;
            }
        }
        try parts.append(a, p);
    }
    return std.mem.join(a, "/", parts.items);
}

pub fn join(a: std.mem.Allocator, base: []const u8, rel: []const u8) ![]u8 {
    const raw = if (base.len == 0) try a.dupe(u8, rel) else try std.fmt.allocPrint(a, "{s}/{s}", .{ base, rel });
    return normalize(a, raw);
}

fn inDir(a: std.mem.Allocator, pkg: []const u8, name: []const u8) ![]u8 {
    return join(a, pkg, name);
}

// ---- mopm-toolchain.toml -------------------------------------------------------------------------------

pub const Tc = struct {
    /// The file, relative to the package directory (`../../mopm-toolchain.toml`) and to the root.
    rel_to_pkg: []const u8,
    at_root: []const u8,
    mopm: []const u8,
    mojo: []const u8,
};

fn quotedValue(line: []const u8, key: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, t, key)) return null;
    var rest = std.mem.trim(u8, t[key.len..], " \t");
    if (rest.len == 0 or rest[0] != '=') return null;
    rest = std.mem.trim(u8, rest[1..], " \t");
    if (rest.len < 2 or rest[0] != '"') return null;
    const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
    return rest[1..end];
}

/// The nearest mopm-toolchain.toml at or above `pkg`, or the reason there is none.
pub fn findToolchain(ctx: *Ctx, pkg: []const u8, why: *[]const u8) !?Tc {
    const a = ctx.a;
    var dir: []const u8 = pkg;
    var up: []const u8 = "";
    while (true) {
        const at = try join(a, dir, contract.mojo_toolchain_file);
        if (try ctx.readOpt(at)) |text| {
            var mopm: ?[]const u8 = null;
            var mojo: ?[]const u8 = null;
            var it = std.mem.splitScalar(u8, text, '\n');
            while (it.next()) |line| {
                if (quotedValue(line, "mopm")) |v| mopm = v;
                if (quotedValue(line, "mojo")) |v| mojo = v;
            }
            if (mopm == null or !toolchain.isExactRelease(mopm.?)) {
                why.* = try std.fmt.allocPrint(a, "{s}: needs `mopm = \"N.N.N\"` (an exact release): a floating version names a different mopm tomorrow", .{at});
                return null;
            }
            if (mojo == null or !toolchain.isExactRelease(mojo.?)) {
                why.* = try std.fmt.allocPrint(a, "{s}: needs `mojo = \"N.N.N\"` (an exact release)", .{at});
                return null;
            }
            return .{ .rel_to_pkg = try std.fmt.allocPrint(a, "{s}{s}", .{ up, contract.mojo_toolchain_file }), .at_root = at, .mopm = mopm.?, .mojo = mojo.? };
        }
        if (dir.len == 0) break;
        dir = std.fs.path.dirname(dir) orelse "";
        up = try std.fmt.allocPrint(a, "{s}../", .{up});
    }
    why.* = try std.fmt.allocPrint(a, "no {s} at or above {s}: it is required, like rust-toolchain.toml, and there is no default. Create it, for example:\n\n[toolchain]\nmopm = \"0.0.1\"\nmojo = \"1.0.0\"\n\n(an exact release each)", .{ contract.mojo_toolchain_file, if (pkg.len == 0) "." else pkg });
    return null;
}


// ---- the export of mopm-toolchain.toml -------------------------------------------------------------------

/// What the BUCK file of the toolchain file's directory holds so that the `:check` of every package below (rules/mojo/check.bzl) can name the
/// file as a target.
pub const export_snippet =
    "export_file(\n" ++
    "    name = \"" ++ contract.mojo_toolchain_file ++ "\",\n" ++
    "    src = \"" ++ contract.mojo_toolchain_file ++ "\" if glob([\"" ++ contract.mojo_toolchain_file ++ "\"]) else fail(\"" ++ contract.mojo_toolchain_file ++
    " is required and there is no default. Create it, for example:\\n\\n[toolchain]\\nmopm = '0.0.1'\\nmojo = '1.0.0'\\n\"),\n" ++
    "    visibility = [\"PUBLIC\"],\n" ++
    ")\n";

pub const export_header =
    "# Exports " ++ contract.mojo_toolchain_file ++ ". Every Mojo package below this directory carries a `:check` that compares it with the hash its\n" ++
    "# table recorded (rules/mojo/check.bzl). Written by `buildrules mojo sync` when this directory had no BUCK file.\n";

/// A package whose toolchain file is in another directory refers to it as a target of that directory: the file is exported there.
pub fn needsExport(tc: Tc) bool {
    return std.mem.startsWith(u8, tc.rel_to_pkg, "../");
}

fn exportBuckPath(ctx: *Ctx, tc: Tc) ![]const u8 {
    const dir = std.fs.path.dirname(tc.at_root) orelse "";
    return join(ctx.a, dir, "BUCK");
}

fn exportPresent(ctx: *Ctx, tc: Tc) !bool {
    const text = (try ctx.readOpt(try exportBuckPath(ctx, tc))) orelse return false;
    return std.mem.indexOf(u8, text, "name = \"" ++ contract.mojo_toolchain_file ++ "\"") != null;
}

/// A file `sync` will write once everything it writes has been rendered.
const Pending = struct {
    path: []const u8,
    text: []const u8,
    /// What to say after writing it, when it is not the usual "wrote   <path>" of `writeIfChanged`.
    note: ?[]const u8 = null,
};

fn pendingText(pend: []const Pending, path: []const u8) ?[]const u8 {
    for (pend) |p| if (std.mem.eql(u8, p.path, path)) return p.text;
    return null;
}

/// The file `path` as it will be when the pending writes are done; the last write of a path wins.
fn queue(a: std.mem.Allocator, pend: *std.ArrayList(Pending), item: Pending) !void {
    for (pend.items) |*p| {
        if (std.mem.eql(u8, p.path, item.path)) {
            p.* = item;
            return;
        }
    }
    try pend.append(a, item);
}

/// sync: make sure the export is there (queue a BUCK file, or the export appended once to the one that exists); check: say it is not. Nothing is written
/// here: the writes of a sync happen after everything has been rendered.
fn ensureExport(ctx: *Ctx, tc: Tc, check_only: bool, pend: *std.ArrayList(Pending)) !u8 {
    if (!needsExport(tc)) return ctxm.exit_ok;
    const path = try exportBuckPath(ctx, tc);
    const have: ?[]const u8 = pendingText(pend.items, path) orelse try ctx.readOpt(path);
    if (have) |h| if (std.mem.indexOf(u8, h, "name = \"" ++ contract.mojo_toolchain_file ++ "\"") != null) return ctxm.exit_ok;
    if (check_only) return ctx.fail("{s} does not export {s}, which the :check of the packages below compares with their tables: run `buildrules mojo sync`", .{ path, contract.mojo_toolchain_file });
    if (have) |h| {
        const sep: []const u8 = if (h.len == 0 or h[h.len - 1] == '\n') "\n" else "\n\n";
        try queue(ctx.a, pend, .{
            .path = path,
            .text = try std.mem.concat(ctx.a, u8, &.{ h, sep, export_snippet }),
            .note = try std.fmt.allocPrint(ctx.a, "wrote   {s} (appended the export of {s})", .{ path, contract.mojo_toolchain_file }),
        });
    } else {
        try queue(ctx.a, pend, .{ .path = path, .text = export_header ++ export_snippet, .note = try std.fmt.allocPrint(ctx.a, "wrote   {s}", .{path}) });
    }
    return ctxm.exit_ok;
}

// ---- packages ------------------------------------------------------------------------------------------

const skip_dirs = [_][]const u8{ "buck-out", ".git", "node_modules", "target", ".buck" };

fn isSkipped(name: []const u8) bool {
    for (skip_dirs) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// Directories (relative to the root) whose BUCK file calls `mojo_package(`.
pub fn discover(ctx: *Ctx) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    try walk(ctx, "", &out);
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out.toOwnedSlice(ctx.a);
}

fn walk(ctx: *Ctx, rel: []const u8, out: *std.ArrayList([]const u8)) !void {
    const a = ctx.a;
    var d = (if (rel.len == 0) ctx.dir.openDir(".", .{ .iterate = true }) else ctx.dir.openDir(rel, .{ .iterate = true })) catch return;
    defer d.close();
    var it = d.iterate();
    var subdirs = std.ArrayList([]const u8).empty;
    while (try it.next()) |e| {
        if (e.kind == .directory) {
            if (!isSkipped(e.name) and !(e.name.len > 0 and e.name[0] == '.')) try subdirs.append(a, try a.dupe(u8, e.name));
        } else if (e.kind == .file and std.mem.eql(u8, e.name, "BUCK")) {
            const text = d.readFileAlloc(a, "BUCK", 8 << 20) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => continue,
            };
            if (std.mem.indexOf(u8, text, "mojo_package(") != null) try out.append(a, try a.dupe(u8, rel));
        }
    }
    for (subdirs.items) |s| try walk(ctx, try join(a, rel, s), out);
}

fn originOf(ctx: *Ctx, version: []const u8) ![]const u8 {
    const text: []const u8 = (try ctx.readOpt(contract.pins_file)) orelse "";
    const needle = try std.fmt.allocPrint(ctx.a, "[mopm.\"{s}\"]", .{version});
    return if (std.mem.indexOf(u8, text, needle) != null) contract.pins_file else "builtin";
}

// ---- sync ----------------------------------------------------------------------------------------------

fn sha256Of(ctx: *Ctx, rel: []const u8) !?[]const u8 {
    const bytes = (try ctx.readOpt(rel)) orelse return null;
    return try ctxm.sha256Hex(ctx.a, bytes);
}

fn lessManifest(_: void, x: lockm.Manifest, y: lockm.Manifest) bool {
    return std.mem.lessThan(u8, x.path, y.path);
}

/// The member directories (relative to `pkg`) the root package's graph imports: the libraries that are not the root's own.
fn memberDirs(a: std.mem.Allocator, g: lockm.Graph) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    const root_name = if (std.mem.indexOfScalar(u8, g.package, '@')) |at| g.package[0..at] else g.package;
    for (g.units) |u| {
        if (!std.mem.eql(u8, u.kind, "lib") or std.mem.eql(u8, u.package, root_name)) continue;
        const suffix = try std.fmt.allocPrint(a, "src/{s}", .{u.package});
        if (std.mem.eql(u8, u.root, suffix)) continue;
        if (!std.mem.endsWith(u8, u.root, suffix) or u.root.len == suffix.len or u.root[u.root.len - suffix.len - 1] != '/') continue;
        try out.append(a, u.root[0 .. u.root.len - suffix.len - 1]);
    }
    return out.toOwnedSlice(a);
}

fn mopmFor(ctx: *Ctx, buck2: []const u8, version: []const u8, given: ?[]const u8) !?[]const u8 {
    if (given) |g| return g;
    const a = ctx.a;
    const v = try a.dupe(u8, version);
    std.mem.replaceScalar(u8, v, '.', '_');
    const label = try std.fmt.allocPrint(a, "toolchains//:mopm_{s}", .{v});
    const r = ctx.execer(ctx, .{ .argv = &.{ buck2, "build", label, "--show-full-output" }, .capture = true }) catch |e| {
        _ = ctx.fail("cannot run {s}: {s} (pass --mopm instead)", .{ buck2, @errorName(e) });
        return null;
    };
    if (r.code != 0) {
        _ = ctx.fail("`{s} build {s}` exited {d}. If mopm-toolchain.toml names a mopm version buildrules does not pin, add its url, sha256 and size as [mopm.\"{s}\"] to {s} and run `buildrules mojo sync` again (docs/contract.md, section 12)", .{ buck2, label, r.code, version, contract.pins_file });
        return null;
    }
    var it = std.mem.splitScalar(u8, r.stdout, '\n');
    while (it.next()) |line| {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (!std.mem.eql(u8, line[0..sp], label)) continue;
        const path = std.mem.trim(u8, line[sp + 1 ..], " \t\r");
        if (path.len > 0 and path[0] == '/') return try a.dupe(u8, path);
    }
    _ = ctx.fail("`{s} build {s}` printed no output path (pass --mopm instead)", .{ buck2, label });
    return null;
}

fn sync(ctx: *Ctx, given: []const []const u8, check_only: bool, mopm_path: ?[]const u8, buck2: []const u8) !u8 {
    const a = ctx.a;
    if (!ctx.exists(".buckconfig")) return ctx.fail("no .buckconfig here: run `buildrules mojo sync` from the repository root (or give --dir)", .{});
    const pkgs = if (given.len > 0) given else try discover(ctx);
    if (pkgs.len == 0) return ctx.fail("no package here calls mojo_package(...) in its BUCK file", .{});
    var code: u8 = ctxm.exit_ok;

    // buildrules-pins.toml -> toolchains/mopm_pins.bzl first: the build of the pinned mopm loads it.
    var pd = Diag.init(a);
    const pins_text: []const u8 = (try ctx.readOpt(contract.pins_file)) orelse "";
    const mopm_pins_text: []const u8 = mopm_pins.render(a, pins_text, &pd) catch {
        for (pd.msgs.items) |m| _ = ctx.fail("{s}", .{m});
        if (pd.lost > 0) _ = ctx.fail("{s}", .{Diag.lost_text});
        return ctxm.exit_fail;
    };
    if (!check_only) {
        try writeIfChanged(ctx, contract.mopm_pins_file, mopm_pins_text);
        // toolchains/BUCK loads the Mojo table too: an empty one until the graphs are in.
        if (!ctx.exists(contract.mojo_pins_file)) try ctx.write(contract.mojo_pins_file, lockm.pins_empty);
    }

    // What the sync writes from here on is collected and written at the end, once the toolchain table has been rendered too: a sync that
    // refuses halfway leaves the files as they were. (The two pins tables above are written first on purpose: the build of the pinned mopm loads them.)
    var pend = std.ArrayList(Pending).empty;
    var mopm_cache = std.StringHashMap(?[]const u8).init(a);
    var tcs = std.ArrayList(lockm.Tc).empty;
    for (pkgs) |pkg| {
        if (!ctx.exists(try inDir(a, pkg, "mopm.toml"))) {
            code |= ctx.fail("{s}: no mopm.toml here", .{if (pkg.len == 0) "." else pkg});
            continue;
        }
        var why: []const u8 = "";
        const tc = (try findToolchain(ctx, pkg, &why)) orelse {
            code |= ctx.fail("{s}", .{why});
            continue;
        };
        const gop = try mopm_cache.getOrPut(tc.mopm);
        if (!gop.found_existing) gop.value_ptr.* = try mopmFor(ctx, buck2, tc.mopm, mopm_path);
        const mopm = gop.value_ptr.* orelse return ctxm.exit_fail;

        var sub = try ctx.into(if (pkg.len == 0) "." else pkg);
        defer sub.dir.close();
        const r = ctx.execer(&sub, .{ .argv = &.{ mopm, "plan", "--unit-graph", "--locked", "--mojo", tc.mojo }, .capture = true }) catch |e| {
            code |= ctx.fail("{s}: cannot run mopm: {s}", .{ pkg, @errorName(e) });
            continue;
        };
        if (r.code != 0) {
            code |= ctx.fail("{s}: `mopm plan --unit-graph --locked --mojo {s}` exited {d}{s}", .{
                if (pkg.len == 0) "." else pkg, tc.mojo, r.code,
                if (r.code == 3) " (no usable mopm.lock, or it is out of date with mopm.toml: run `mopm lock`)" else if (r.code == 4) " (mopm cannot make a graph from this project and lock; its message is above)" else "",
            });
            continue;
        }
        if (std.mem.indexOf(u8, r.stdout, "'''") != null) {
            code |= ctx.fail("{s}: mopm's graph holds ''' and cannot be embedded in a table", .{pkg});
            continue;
        }
        var diag = Diag.init(a);
        const g = lockm.parseGraph(a, pkg, r.stdout, &diag) catch {
            for (diag.msgs.items) |m| _ = ctx.fail("{s}", .{m});
            if (diag.lost > 0) _ = ctx.fail("{s}", .{Diag.lost_text});
            code = ctxm.exit_fail;
            continue;
        };
        if (!std.mem.eql(u8, g.mojo, tc.mojo)) {
            code |= ctx.fail("{s}: asked mopm for Mojo {s} and got a graph for {s}", .{ pkg, tc.mojo, g.mojo });
            continue;
        }
        // Every file the graph was made from, by sha256 (the sources are in the graph itself).
        var ms = std.ArrayList(lockm.Manifest).empty;
        const names = [_][]const u8{ "mopm.toml", "mopm.lock" };
        var missing = false;
        for (names) |n| {
            const p = try inDir(a, pkg, n);
            const h = (try sha256Of(ctx, p)) orelse {
                code |= ctx.fail("{s} is missing: `mopm lock` writes it", .{p});
                missing = true;
                continue;
            };
            try ms.append(a, .{ .path = n, .sha256 = h });
        }
        const th = (try sha256Of(ctx, tc.at_root)).?;
        try ms.append(a, .{ .path = tc.rel_to_pkg, .sha256 = th });
        for (try memberDirs(a, g)) |md| {
            const rel = try join(a, md, "mopm.toml");
            const p = try inDir(a, pkg, rel);
            const h = (try sha256Of(ctx, p)) orelse {
                code |= ctx.fail("{s} is missing (a path dependency of {s})", .{ p, pkg });
                missing = true;
                continue;
            };
            try ms.append(a, .{ .path = rel, .sha256 = h });
        }
        if (missing) continue;
        std.mem.sort(lockm.Manifest, ms.items, {}, lessManifest);
        const text = try lockm.render(a, .{
            .schema = contract.mojo_schema,
            .mopm_version = tc.mopm,
            .mopm_origin = try originOf(ctx, tc.mopm),
            .mojo = tc.mojo,
            .closure_sha256 = g.closure_sha256,
            .manifests = ms.items,
            .graph_json = r.stdout,
        });
        try tcs.append(a, .{ .mojo = g.mojo, .toolchain = g.toolchain });
        code |= try ensureExport(ctx, tc, check_only, &pend);
        const lock_path = try inDir(a, pkg, contract.mojo_lock_file);
        const bzl_path = try inDir(a, pkg, contract.mojo_bzl_file);
        if (check_only) {
            code |= compareOne(ctx, lock_path, text);
            code |= compareOne(ctx, bzl_path, contract.mojo_bzl_text);
        } else {
            try queue(a, &pend, .{ .path = lock_path, .text = text });
            try queue(a, &pend, .{ .path = bzl_path, .text = contract.mojo_bzl_text });
        }
    }

    // The toolchain facts of the graphs, once, for toolchains/BUCK.
    if (tcs.items.len > 0) {
        var td = Diag.init(a);
        if (lockm.renderPins(a, tcs.items, &td)) |pins| {
            if (check_only) {
                code |= compareOne(ctx, contract.mojo_pins_file, pins);
                code |= compareOne(ctx, contract.mopm_pins_file, mopm_pins_text);
            } else {
                try queue(a, &pend, .{ .path = contract.mojo_pins_file, .text = pins });
            }
        } else |_| {
            for (td.msgs.items) |m| _ = ctx.fail("{s}", .{m});
            if (td.lost > 0) _ = ctx.fail("{s}", .{Diag.lost_text});
            return ctxm.exit_fail;
        }
    }
    for (pend.items) |p| {
        if (p.note) |n| {
            try ctx.write(p.path, p.text);
            ctx.say("{s}", .{n});
        } else try writeIfChanged(ctx, p.path, p.text);
    }
    if (code == ctxm.exit_ok) {
        if (check_only) ctx.say("mojo sync --check: every generated file is up to date", .{}) else ctx.say("synced: {d} Mojo package(s)", .{pkgs.len});
    }
    return code;
}

fn compareOne(ctx: *Ctx, path: []const u8, fresh: []const u8) u8 {
    const have = (ctx.readOpt(path) catch null) orelse {
        return ctx.fail("{s} is missing: run `buildrules mojo sync` and commit it", .{path});
    };
    if (std.mem.eql(u8, have, fresh)) {
        ctx.say("{s} is up to date", .{path});
        return 0;
    }
    return ctx.fail("{s} is not what the inputs generate (first difference at line {d}): run `buildrules mojo sync` and commit the result; never edit it by hand", .{ path, firstDifference(have, fresh) });
}

fn firstDifference(x: []const u8, y: []const u8) usize {
    var line: usize = 1;
    var i: usize = 0;
    while (i < x.len and i < y.len) : (i += 1) {
        if (x[i] != y[i]) return line;
        if (x[i] == '\n') line += 1;
    }
    return line;
}

fn writeIfChanged(ctx: *Ctx, path: []const u8, text: []const u8) !void {
    if (try ctx.readOpt(path)) |have| {
        if (std.mem.eql(u8, have, text)) {
            ctx.say("{s} is up to date", .{path});
            return;
        }
    }
    try ctx.write(path, text);
    ctx.say("wrote   {s}", .{path});
}

// ---- check ---------------------------------------------------------------------------------------------

const fix = "run `buildrules mojo sync` and commit the result";

/// Whether the repository has any Mojo package: `buildrules check` runs this part only then. A walk that runs out of memory
/// is an error, not "no package": the gate must not skip the Mojo packages it could not look for. (A directory or BUCK file that cannot be read is skipped.)
pub fn hasPackages(ctx: *Ctx) !bool {
    const p = try discover(ctx);
    return p.len > 0;
}

pub fn checkAll(ctx: *Ctx) !u8 {
    const a = ctx.a;
    const pkgs = try discover(ctx);
    if (pkgs.len == 0) {
        _ = ctx.fail("no package here calls mojo_package(...) in its BUCK file", .{});
        return ctxm.exit_fail;
    }
    var bad: usize = 0;
    var tcs = std.ArrayList(lockm.Tc).empty;
    for (pkgs) |pkg| try checkPackage(ctx, pkg, &bad, &tcs);

    // toolchains/mojo_pins.bzl and mopm_pins.bzl are what the graphs and buildrules-pins.toml generate.
    var td = Diag.init(a);
    if (tcs.items.len > 0) {
        if (lockm.renderPins(a, tcs.items, &td)) |pins| {
            const have = (try ctx.readOpt(contract.mojo_pins_file)) orelse "";
            if (!std.mem.eql(u8, have, pins)) {
                _ = ctx.fail("STALE: {s} is not what the unit graphs generate (first difference at line {d}): {s}", .{ contract.mojo_pins_file, firstDifference(have, pins), fix });
                bad += 1;
            }
        } else |_| {
            for (td.msgs.items) |m| _ = ctx.fail("{s}", .{m});
            if (td.lost > 0) _ = ctx.fail("{s}", .{Diag.lost_text});
            bad += @max(1, td.count());
        }
    }
    var pd = Diag.init(a);
    const pins_text: []const u8 = (try ctx.readOpt(contract.pins_file)) orelse "";
    if (mopm_pins.render(a, pins_text, &pd)) |fresh| {
        const have = (try ctx.readOpt(contract.mopm_pins_file)) orelse "";
        if (!std.mem.eql(u8, have, fresh)) {
            _ = ctx.fail("STALE: {s} is not what {s} generates (first difference at line {d}): {s}", .{ contract.mopm_pins_file, contract.pins_file, firstDifference(have, fresh), fix });
            bad += 1;
        }
    } else |_| {
        for (pd.msgs.items) |m| _ = ctx.fail("{s}", .{m});
        if (pd.lost > 0) _ = ctx.fail("{s}", .{Diag.lost_text});
        bad += @max(1, pd.count());
    }
    if (bad == 0) {
        ctx.say("ok: {d} Mojo package(s) match their mopm.toml, mopm.lock, mopm-toolchain.toml, sources and tests", .{pkgs.len});
        return ctxm.exit_ok;
    }
    return ctxm.exit_fail;
}

fn stale(ctx: *Ctx, bad: *usize, comptime fmt: []const u8, args: anytype) void {
    _ = ctx.fail("STALE: " ++ fmt, args);
    bad.* += 1;
}

fn checkPackage(ctx: *Ctx, pkg: []const u8, bad: *usize, tcs: *std.ArrayList(lockm.Tc)) !void {
    const a = ctx.a;
    const shown = if (pkg.len == 0) "." else pkg;
    const lock_path = try inDir(a, pkg, contract.mojo_lock_file);
    const text = (try ctx.readOpt(lock_path)) orelse {
        _ = ctx.fail("{s} is missing: {s}", .{ lock_path, fix });
        bad.* += 1;
        return;
    };
    var diag = Diag.init(a);
    const l = lockm.parse(a, lock_path, text, &diag) catch {
        for (diag.msgs.items) |m| _ = ctx.fail("{s}", .{m});
        if (diag.lost > 0) _ = ctx.fail("{s}", .{Diag.lost_text});
        bad.* += @max(1, diag.count());
        return;
    };
    if (l.schema != contract.mojo_schema) {
        _ = ctx.fail("{s}: SCHEMA {d}, this buildrules reads {d}: {s}", .{ lock_path, l.schema, contract.mojo_schema, fix });
        bad.* += 1;
        return;
    }
    const g = lockm.parseGraph(a, lock_path, l.graph_json, &diag) catch {
        for (diag.msgs.items) |m| _ = ctx.fail("{s}", .{m});
        if (diag.lost > 0) _ = ctx.fail("{s}", .{Diag.lost_text});
        bad.* += @max(1, diag.count());
        return;
    };

    // The versions: mopm-toolchain.toml against the table.
    var why: []const u8 = "";
    if (try findToolchain(ctx, pkg, &why)) |tc| {
        if (!std.mem.eql(u8, tc.mopm, l.mopm_version)) stale(ctx, bad, "{s} pins mopm {s} but {s} was made with mopm {s}: {s}", .{ tc.at_root, tc.mopm, lock_path, l.mopm_version, fix });
        if (!std.mem.eql(u8, tc.mojo, l.mojo)) stale(ctx, bad, "{s} pins Mojo {s} but {s} is the graph for Mojo {s}: {s}", .{ tc.at_root, tc.mojo, lock_path, l.mojo, fix });
        if (needsExport(tc) and !(try exportPresent(ctx, tc))) stale(ctx, bad, "{s} does not export {s}, which the :check of {s} compares with its table: {s}", .{ try exportBuckPath(ctx, tc), contract.mojo_toolchain_file, shown, fix });
    } else {
        _ = ctx.fail("{s}", .{why});
        bad.* += 1;
    }

    // The graph is for the Mojo the table says, and its toolchain hash is the one recorded beside it.
    if (!std.mem.eql(u8, g.mojo, l.mojo)) stale(ctx, bad, "{s}: MOJO is {s} but its unit graph is for Mojo {s}", .{ lock_path, l.mojo, g.mojo });
    if (!std.mem.eql(u8, g.closure_sha256, l.closure_sha256)) stale(ctx, bad, "{s}: CLOSURE_SHA256 {s} is not the closure its unit graph pins ({s}): the file was edited by hand; {s}", .{ lock_path, l.closure_sha256, g.closure_sha256, fix });
    try tcs.append(a, .{ .mojo = g.mojo, .toolchain = g.toolchain });

    // Every file the table was made from.
    for (l.manifests) |m| {
        const p = try inDir(a, pkg, m.path);
        const got = (try sha256Of(ctx, p)) orelse {
            stale(ctx, bad, "{s} is in {s} but is gone: {s}", .{ p, lock_path, fix });
            continue;
        };
        if (!std.mem.eql(u8, got, m.sha256)) stale(ctx, bad, "{s} changed since `buildrules mojo sync` (recorded sha256 {s}, now {s}): {s}", .{ p, m.sha256, got, fix });
    }
    inline for (.{ "mopm.toml", "mopm.lock" }) |need| {
        if (lockm.manifestHash(l, need) == null) stale(ctx, bad, "{s} does not record {s}: {s}", .{ lock_path, need, fix });
    }
    for (try memberDirs(a, g)) |md| {
        const rel = try join(a, md, "mopm.toml");
        if (lockm.manifestHash(l, rel) == null) stale(ctx, bad, "{s} is a path dependency's manifest the table does not know: {s}", .{ rel, fix });
    }

    // The sources the graph names, by sha256.
    for (g.units) |u| {
        for (u.srcs) |s| {
            const p = try inDir(a, pkg, s.path);
            const got = (try sha256Of(ctx, p)) orelse {
                stale(ctx, bad, "{s} (a source of {s}) is gone: {s}", .{ p, u.id, fix });
                continue;
            };
            if (!std.mem.eql(u8, got, s.sha256)) stale(ctx, bad, "{s} changed since `buildrules mojo sync` (the table has sha256 {s}, now {s}): {s}", .{ p, s.sha256, got, fix });
        }
    }

    // Files the graph does not know: a new source in a library, a new test file.
    try checkListings(ctx, pkg, g, bad);

    // The glue and the BUCK file.
    const bzl_path = try inDir(a, pkg, contract.mojo_bzl_file);
    if (try ctx.readOpt(bzl_path)) |b| {
        if (!std.mem.eql(u8, b, contract.mojo_bzl_text)) stale(ctx, bad, "{s} is not what sync writes (first difference at line {d}): {s}", .{ bzl_path, firstDifference(b, contract.mojo_bzl_text), fix });
    } else {
        _ = ctx.fail("{s} is missing: {s}", .{ bzl_path, fix });
        bad.* += 1;
    }
}

fn listMojo(ctx: *Ctx, dir_rel: []const u8, out: *std.ArrayList([]const u8)) !void {
    const a = ctx.a;
    var d = (if (dir_rel.len == 0) ctx.dir.openDir(".", .{ .iterate = true }) else ctx.dir.openDir(dir_rel, .{ .iterate = true })) catch return;
    defer d.close();
    var w = try d.walk(a);
    defer w.deinit();
    while (try w.next()) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".mojo")) continue;
        if (std.mem.startsWith(u8, e.path, ".") or std.mem.indexOf(u8, e.path, "/.") != null) continue;
        try out.append(a, try a.dupe(u8, e.path));
    }
}

fn graphHas(g: lockm.Graph, path_from_pkg: []const u8) bool {
    for (g.units) |u| for (u.srcs) |s| if (std.mem.eql(u8, s.path, path_from_pkg)) return true;
    return false;
}

fn checkListings(ctx: *Ctx, pkg: []const u8, g: lockm.Graph, bad: *usize) !void {
    const a = ctx.a;
    // Libraries: every non-test .mojo under a library's root is a source of its unit.
    for (g.units) |u| {
        if (!std.mem.eql(u8, u.kind, "lib") or u.root.len == 0) continue;
        const suffix = try std.fmt.allocPrint(a, "src/{s}", .{u.package});
        const member = if (std.mem.eql(u8, u.root, suffix)) "" else if (std.mem.endsWith(u8, u.root, suffix)) u.root[0 .. u.root.len - suffix.len - 1] else "";
        var files = std.ArrayList([]const u8).empty;
        try listMojo(ctx, try inDir(a, pkg, u.root), &files);
        for (files.items) |f| {
            const rel = try join(a, u.root, f);
            const in_member = if (member.len == 0) rel else if (rel.len > member.len) rel[member.len + 1 ..] else rel;
            if (lockm.isTestPath(in_member)) continue;
            if (!graphHas(g, rel)) stale(ctx, bad, "{s} is a source of {s} that the table does not know: {s}", .{ try inDir(a, pkg, rel), u.id, fix });
        }
    }
    // Tests of the root package.
    var files = std.ArrayList([]const u8).empty;
    for ([_][]const u8{ "tests", "src" }) |top| {
        var found = std.ArrayList([]const u8).empty;
        try listMojo(ctx, try inDir(a, pkg, top), &found);
        for (found.items) |f| try files.append(a, try join(a, top, f));
    }
    for (files.items) |f| {
        if (!lockm.isTestPath(f)) continue;
        if (!graphHas(g, f)) stale(ctx, bad, "{s} is a test file that the table does not know: {s}", .{ try inDir(a, pkg, f), fix });
    }
}
