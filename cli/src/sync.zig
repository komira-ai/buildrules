//! `buildrules sync`: cargo's files in, the generated table and the glue out (docs/contract.md, "What
//! sync writes"). cargo (the pinned one) captures `--unit-graph` JSON per member and verb; the generator
//! (unitgen.zig and buckgen.zig, part of this program) turns Cargo.lock, the manifests and the graphs into
//! buildrules.lock.bzl, third_party/buildrules/crate_sizes.tsv and third_party/buildrules/BUCK.
//! This command writes the rest itself: buildrules.bzl, and the root BUCK when there is none.
//!
//! `sync` is the only command that runs cargo. The pinned cargo, the pinned rustc and the Rust version
//! table (rules/rust/pins.bzl) come from the buildrules cell through `buck2 build` unless a flag names
//! them. Nothing here needs Python or any other interpreter.

const std = @import("std");
const buckgen = @import("buckgen.zig");
const cargo_lock = @import("cargo_lock.zig");
const contract = @import("contract.zig");
const ctxm = @import("ctx.zig");
const lockfile = @import("lockfile.zig");
const toolchain = @import("toolchain.zig");
const unitgen = @import("unitgen.zig");
const val = @import("val.zig");
const pins_toml = @import("pins_toml.zig");
const ws = @import("workspace.zig");
const Diag = @import("diag.zig").Diag;
const Ctx = ctxm.Ctx;

/// Scratch the command owns (under buck-out, which is ignored): cargo's home, the unit graphs, the
/// output of `--check`.
pub const work_dir = "buck-out/buildrules";

pub const usage_text =
    \\usage: buildrules sync [--dir DIR] [--check] [--cargo CARGO --rustc RUSTC --pins FILE]
    \\                       [--buck2 BUCK2]
    \\
    \\  --dir DIR       the repository root (default .): holds .buckconfig, Cargo.toml, Cargo.lock,
    \\                  rust-toolchain.toml
    \\  --check         write nothing outside buck-out/; exit 1 unless every generated file is what a
    \\                  sync now would write
    \\  --cargo, --rustc, --pins
    \\                  the pinned cargo and rustc binaries and the Rust version table (rules/rust/pins.bzl).
    \\                  Any that is absent is built from the buildrules cell with `buck2 build` (the
    \\                  toolchains//:cargo and :sysroot targets, buildrules//rules/rust:pins.bzl).
    \\  --buck2 BUCK2   the buck2 binary for that (default buck2)
    \\
;

const Opts = struct {
    dir: []const u8 = ".",
    check: bool = false,
    cargo: ?[]const u8 = null,
    rustc: ?[]const u8 = null,
    pins: ?[]const u8 = null,
    buck2: []const u8 = "buck2",
};

pub fn run(root: *Ctx, args: []const []const u8) u8 {
    var o = Opts{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--check")) {
            o.check = true;
        } else if (std.mem.eql(u8, arg, "--dir") or std.mem.eql(u8, arg, "--cargo") or std.mem.eql(u8, arg, "--rustc") or
            std.mem.eql(u8, arg, "--pins") or std.mem.eql(u8, arg, "--buck2"))
        {
            const v = ctxm.flagValue(args, &i) orelse return root.usage("sync: {s} needs a value", .{arg});
            if (std.mem.eql(u8, arg, "--dir")) o.dir = v else if (std.mem.eql(u8, arg, "--cargo")) o.cargo = v else if (std.mem.eql(u8, arg, "--rustc")) o.rustc = v else if (std.mem.eql(u8, arg, "--pins")) o.pins = v else o.buck2 = v;
        } else {
            return root.usage("sync: unknown argument {s}\n{s}", .{ arg, usage_text });
        }
    }
    var ctx = root.into(o.dir) catch |e| return root.fail("cannot open {s}: {s}", .{ o.dir, @errorName(e) });
    defer ctx.dir.close();
    return sync(&ctx, o) catch |e| root.fail("sync: {s}", .{@errorName(e)});
}

const Tools = struct { cargo: []const u8, rustc: []const u8, pins: []const u8 };

/// `toolchains//:cargo_1_85_0` for ("cargo", "1.85.0").
fn versionedLabel(a: std.mem.Allocator, what: []const u8, version: []const u8) ![]const u8 {
    const v = try a.dupe(u8, version);
    std.mem.replaceScalar(u8, v, '.', '_');
    return std.fmt.allocPrint(a, "toolchains//:{s}_{s}", .{ what, v });
}

fn labelIs(label: []const u8, want: []const u8) bool {
    return std.mem.eql(u8, label, want);
}

/// The pinned cargo and rustc and the generator directory: the flags, else `buck2 build ... --show-full-output`.
fn resolveTools(ctx: *Ctx, o: Opts, rustc_version: []const u8) !?Tools {
    const a = ctx.a;
    // One cargo and one sysroot per Rust version (toolchains/BUCK): the labels carry the version with `_` for `.`.
    const cargo_label = try versionedLabel(a, "cargo", rustc_version);
    const sysroot_label = try versionedLabel(a, "sysroot", rustc_version);
    var cargo = o.cargo;
    var rustc = o.rustc;
    var pins = o.pins;
    if (cargo == null or rustc == null or pins == null) {
        const r = ctx.execer(ctx, .{
            .argv = &.{ o.buck2, "build", cargo_label, sysroot_label, contract.pins_target, "--show-full-output" },
            .capture = true,
        }) catch |e| {
            _ = ctx.fail("cannot run {s}: {s} (pass --cargo, --rustc and --pins instead)", .{ o.buck2, @errorName(e) });
            return null;
        };
        if (r.code != 0) {
            _ = ctx.fail("`{s} build` of the pinned toolchain and the Rust version table exited {d}. If rust-toolchain.toml names a Rust version buildrules does not pin, add its hashes to {s} (docs/contract.md, section 6) and run `buildrules sync` again", .{ o.buck2, r.code, contract.pins_file });
            return null;
        }
        var it = std.mem.splitScalar(u8, r.stdout, '\n');
        while (it.next()) |line| {
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const label = line[0..sp];
            const path = std.mem.trim(u8, line[sp + 1 ..], " \t\r");
            if (path.len == 0 or path[0] != '/') continue;
            if (labelIs(label, cargo_label)) {
                if (cargo == null) cargo = try std.fmt.allocPrint(a, "{s}/bin/cargo", .{path});
            } else if (labelIs(label, sysroot_label)) {
                if (rustc == null) rustc = try std.fmt.allocPrint(a, "{s}/bin/rustc", .{path});
            } else if (labelIs(label, contract.pins_target)) {
                if (pins == null) pins = try a.dupe(u8, path);
            }
        }
    }
    if (cargo == null or rustc == null or pins == null) {
        _ = ctx.fail("could not find the pinned cargo, rustc and the Rust version table (pass --cargo, --rustc and --pins)", .{});
        return null;
    }
    return .{ .cargo = cargo.?, .rustc = rustc.?, .pins = pins.? };
}

/// Runs a step; a non-zero exit is reported and returns false.
fn step(ctx: *Ctx, what: []const u8, spec: ctxm.Exec) !bool {
    const r = ctx.execer(ctx, spec) catch |e| {
        _ = ctx.fail("{s}: cannot run {s}: {s}", .{ what, spec.argv[0], @errorName(e) });
        return false;
    };
    if (r.code != 0) {
        _ = ctx.fail("{s} exited {d}", .{ what, r.code });
        return false;
    }
    return true;
}

fn sync(ctx: *Ctx, o: Opts) !u8 {
    const a = ctx.a;
    var problems: usize = 0;

    // 1. Preconditions, all reported in one run.
    if (!ctx.exists(".buckconfig")) {
        _ = ctx.fail("no .buckconfig here: run `buildrules sync` from the repository root (or give --dir); `buildrules init` sets a repository up", .{});
        problems += 1;
    }
    const rustc_version: []const u8 = switch (toolchain.judge(try ctx.readOpt("rust-toolchain.toml"))) {
        .ok => |v| v,
        .bad => |m| blk: {
            _ = ctx.fail("{s}", .{m});
            problems += 1;
            break :blk "";
        },
    };
    var members: []const []const u8 = &.{};
    if (try ctx.readOpt("Cargo.toml")) |root_manifest| {
        if (ws.workspaceSection(root_manifest) == null) {
            _ = ctx.fail("Cargo.toml has no [workspace]: v0 builds a Cargo workspace whose root is the repository root", .{});
            problems += 1;
        } else if (ws.isPackage(root_manifest)) {
            _ = ctx.fail("the root Cargo.toml is a package ([package]): v0 wants a virtual workspace at the root and packages in subdirectories", .{});
            problems += 1;
        } else {
            members = ws.memberDirs(ctx, root_manifest) catch |e| switch (e) {
                error.UnsupportedMemberPattern => blk: {
                    _ = ctx.fail("a `members` entry is a glob buildrules does not expand (only `dir/*` is): list the packages", .{});
                    problems += 1;
                    break :blk &.{};
                },
                else => return e,
            };
        }
    } else {
        _ = ctx.fail("Cargo.toml is missing: `buildrules init` writes a virtual workspace", .{});
        problems += 1;
    }
    for (members) |m| {
        const buck = try std.fmt.allocPrint(a, "{s}/BUCK", .{m});
        const text = (try ctx.readOpt(buck)) orelse "";
        if (std.mem.indexOf(u8, text, "cargo_package(") == null) {
            _ = ctx.fail("{s} has no cargo_package call: run `buildrules cargo adopt {s}`", .{ buck, m });
            problems += 1;
        }
    }
    if (try ctx.readOpt("BUCK")) |b| {
        if (std.mem.indexOf(u8, b, "cargo_workspace(") == null) {
            _ = ctx.fail("BUCK has no cargo_workspace call: add `load(\"//:{s}\", \"cargo_workspace\")` and `cargo_workspace(path = \".\")`", .{contract.bzl_file});
            problems += 1;
        }
    }

    // The repository's own Rust pins: buildrules-pins.toml -> toolchains/rust_pins.bzl, which the toolchain targets (and so
    // `buck2 build toolchains//:cargo_<v>` below) load. Written first because the build of the tools needs it.
    var pins_diag = Diag.init(a);
    const pins_text: []const u8 = (try ctx.readOpt(contract.pins_file)) orelse "";
    const rust_pins: []const u8 = pins_toml.render(a, pins_text, &pins_diag) catch blk: {
        for (pins_diag.msgs.items) |m| _ = ctx.fail("{s}", .{m});
        if (pins_diag.lost > 0) _ = ctx.fail("{s}", .{Diag.lost_text});
        problems += 1;
        break :blk "";
    };
    if (problems != 0) return ctxm.exit_fail;
    if (!o.check) try writeIfChanged(ctx, contract.rust_pins_file, rust_pins);

    const tools = (try resolveTools(ctx, o, rustc_version)) orelse return ctxm.exit_fail;
    const root_abs = try ctx.dir.realpathAlloc(a, ".");
    try ctx.dir.makePath(work_dir);
    const cargo_home = try std.fmt.allocPrint(a, "{s}/{s}/cargo-home", .{ root_abs, work_dir });
    try ctx.dir.makePath(work_dir ++ "/cargo-home");
    // cargo runs on the pinned rustc with its own home (never ~/.cargo); the unit graph is an unstable
    // flag, which a stable cargo accepts under RUSTC_BOOTSTRAP (nothing compiles).
    const base_env = [_][2][]const u8{ .{ "RUSTC", tools.rustc }, .{ "CARGO_HOME", cargo_home } };
    const graph_env = [_][2][]const u8{ .{ "RUSTC", tools.rustc }, .{ "CARGO_HOME", cargo_home }, .{ "RUSTC_BOOTSTRAP", "1" } };

    // 2. Cargo.lock and the sources it names. Cargo resolves: `cargo fetch` creates the lock when there is none and
    //    changes it as little as the manifests need (a new dependency adds its crates, nothing else is upgraded);
    //    every later cargo call is `--locked`.
    if (!try step(ctx, "cargo fetch", .{ .argv = &.{ tools.cargo, "fetch" }, .env = &base_env })) return ctxm.exit_fail;
    const lock = try ctx.read("Cargo.lock");
    var diag = Diag.init(a);
    const entries = cargo_lock.parse(a, "Cargo.lock", lock, &diag) catch {
        for (diag.msgs.items) |m| ctx.err.print("buildrules: {s}\n", .{m}) catch {};
        if (diag.lost > 0) ctx.err.print("buildrules: {s}\n", .{Diag.lost_text}) catch {};
        return ctxm.exit_fail;
    };

    // 3. The unit graphs: every workspace package, build / test / release.
    var graphs = std.ArrayList(unitgen.GraphIn).empty;
    const verbs = [_]struct { name: []const u8, argv: []const []const u8 }{
        .{ .name = "build", .argv = &.{"build"} },
        .{ .name = "test", .argv = &.{"test"} },
        .{ .name = "release", .argv = &.{ "build", "--release" } },
    };
    for (entries) |e| {
        if (e.source.len != 0) continue;
        for (verbs) |v| {
            var argv = std.ArrayList([]const u8).empty;
            try argv.append(a, tools.cargo);
            try argv.appendSlice(a, v.argv);
            try argv.appendSlice(a, &.{ "-p", e.name, "--locked", "--offline", "--target", contract.target, "-Z", "unstable-options", "--unit-graph" });
            const what = try std.fmt.allocPrint(a, "cargo {s} -p {s} --unit-graph", .{ v.argv[0], e.name });
            const r = ctx.execer(ctx, .{ .argv = argv.items, .env = &graph_env, .capture = true }) catch |err| return ctx.fail("{s}: {s}", .{ what, @errorName(err) });
            if (r.code != 0) return ctx.fail("{s} exited {d}", .{ what, r.code });
            // Kept for the reader who wants to see what cargo said (the generator reads the captured text).
            try ctx.write(try std.fmt.allocPrint(a, "{s}/graphs/{s}.{s}.json", .{ work_dir, e.name, v.name }), r.stdout);
            try graphs.append(a, .{ .scope = e.name, .verb = v.name, .json = r.stdout });
        }
    }
    if (graphs.items.len == 0) return ctx.fail("Cargo.lock lists no workspace package: run `buildrules cargo new crates/NAME` first", .{});

    // 4. The generator, in this process. In --check mode it writes under buck-out/ and the result is compared.
    const out_root: []const u8 = if (o.check) work_dir ++ "/check" else ".";
    try ctx.dir.makePath(out_root);
    const lock_out = try std.fmt.allocPrint(a, "{s}/{s}", .{ out_root, contract.lock_file });
    var manifests = std.ArrayList([]const u8).empty;
    try manifests.appendSlice(a, &.{ "Cargo.toml", "rust-toolchain.toml" });
    if (ctx.exists(contract.pins_file)) try manifests.append(a, contract.pins_file);
    for (members) |m| try manifests.append(a, try std.fmt.allocPrint(a, "{s}/Cargo.toml", .{m}));
    var gdiag = Diag.init(a);
    const generated = unitgen.generate(a, &gdiag, .{
        .cargo_lock = lock,
        .root = root_abs,
        .graphs = graphs.items,
        .rustc = rustc_version,
        .target = contract.target,
        .rust_pins = try ctx.read(tools.pins),
        .extra_pins = try ctx.readOpt(contract.rust_pins_file),
        .manifests = manifests.items,
    }) catch |e| switch (e) {
        error.Refused => return reportAll(ctx, &gdiag),
        else => return e,
    };
    try ctx.write(lock_out, generated.text);

    // 5. The registry crates' sizes (a download needs its size besides its sha256), then their package.
    try ctx.dir.makePath(contract.third_party);
    if (!o.check) {
        const cache = try std.fmt.allocPrint(a, "{s}/registry/cache", .{cargo_home});
        const sizes_text = buckgen.sizesFile(a, &gdiag, generated.units, cache) catch |e| switch (e) {
            error.Refused => return reportAll(ctx, &gdiag),
            else => return e,
        };
        try ctx.write(contract.sizes_file, sizes_text);
    } else if (!ctx.exists(contract.sizes_file)) {
        return ctx.fail("{s} is missing: run `buildrules sync` and commit it", .{contract.sizes_file});
    }
    const sizes = buckgen.parseSizes(a, &gdiag, try ctx.read(contract.sizes_file)) catch |e| switch (e) {
        error.Refused => return reportAll(ctx, &gdiag),
        else => return e,
    };
    // A registry crate whose build script a buildrules target replaces is declared in a file of the repository's own (docs/contract.md).
    var overrides: ?buckgen.Overrides = null;
    if (try ctx.readOpt(contract.overrides_file)) |text| {
        overrides = buckgen.loadOverrides(a, &gdiag, contract.overrides_file, text) catch |e| switch (e) {
            error.Refused => return reportAll(ctx, &gdiag),
            else => return e,
        };
    }
    const tc_default = isDefaultToolchain(generated.toolchain);
    const third_party_buck = buckgen.generate(a, &gdiag, generated.units, sizes, overrides, .{ .non_default_rustc = if (tc_default) null else rustc_version }) catch |e| switch (e) {
        error.Refused => return reportAll(ctx, &gdiag),
        else => return e,
    };
    try ctx.write(try std.fmt.allocPrint(a, "{s}/{s}/BUCK", .{ out_root, contract.third_party }), third_party_buck);

    // 6. The files this command writes itself.
    const files = [_]struct { path: []const u8, fresh: []const u8 }{
        .{ .path = contract.bzl_file, .fresh = contract.bzl_text },
    };
    var code: u8 = ctxm.exit_ok;
    if (o.check) {
        const gen = [_][]const u8{ contract.lock_file, contract.third_party ++ "/BUCK" };
        for (gen) |p| {
            const fresh = try ctx.read(try std.fmt.allocPrint(a, "{s}/{s}", .{ out_root, p }));
            code |= compareOne(ctx, p, fresh);
        }
        for (files) |f| code |= compareOne(ctx, f.path, f.fresh);
        code |= compareOne(ctx, contract.rust_pins_file, rust_pins);
        if (!ctx.exists("BUCK")) {
            code |= ctx.fail("BUCK is missing: run `buildrules sync` and commit it", .{});
        }
        if (code == 0) ctx.say("sync --check: every generated file is up to date", .{});
        return code;
    }
    for (files) |f| try writeIfChanged(ctx, f.path, f.fresh);
    if (!ctx.exists("BUCK")) {
        try ctx.write("BUCK", contract.workspace_buck);
        ctx.say("wrote   BUCK", .{});
    }
    ctx.say("synced: {d} workspace package(s), rustc {s}", .{ members.len, rustc_version });
    return code;
}

fn compareOne(ctx: *Ctx, path: []const u8, fresh: []const u8) u8 {
    const have = (ctx.readOpt(path) catch null) orelse {
        return ctx.fail("{s} is missing: run `buildrules sync` and commit it", .{path});
    };
    if (std.mem.eql(u8, have, fresh)) {
        ctx.say("{s} is up to date", .{path});
        return 0;
    }
    return ctx.fail("{s} is not what the inputs generate (first difference at line {d}): run `buildrules sync` and commit the result; never edit it by hand", .{ path, lockfile.firstDifference(have, fresh) });
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

/// Prints every message the generator collected and returns the failing exit code.
fn reportAll(ctx: *Ctx, diag: *Diag) u8 {
    for (diag.msgs.items) |m| ctx.err.print("buildrules: {s}\n", .{m}) catch {};
    if (diag.lost > 0) ctx.err.print("buildrules: {s}\n", .{Diag.lost_text}) catch {};
    return ctxm.exit_fail;
}

/// Whether the TOOLCHAIN record says the version is buildrules' default.
fn isDefaultToolchain(tc: val.Value) bool {
    const d = val.get(tc, "default") orelse return true;
    return d == .bool and d.bool;
}
