//! `buildrules check`: the commit-time gate, offline and read-only. Exit 0 when everything the build
//! was generated from still hashes to what `buildrules sync` recorded; exit 1 when anything is
//! stale or refused (every problem is printed, with the fix); exit 2 for a usage error.
//!
//! It reads: rust-toolchain.toml (an exact release, no `path`), buildrules.lock.bzl (schema 2),
//! Cargo.lock, the root Cargo.toml and every member's Cargo.toml (each against MANIFEST_SHA256, a new
//! or a removed member too), buildrules.bzl (what sync writes), and the BUCK files (cargo_workspace
//! at the root, cargo_package in each member). It runs neither cargo nor any other program.

const std = @import("std");
const contract = @import("contract.zig");
const ctxm = @import("ctx.zig");
const lockfile = @import("lockfile.zig");
const toolchain = @import("toolchain.zig");
const mojo_cmd = @import("mojo_cmd.zig");
const pins_toml = @import("pins_toml.zig");
const ws = @import("workspace.zig");
const Diag = @import("diag.zig").Diag;
const Ctx = ctxm.Ctx;

pub const usage_text =
    \\usage: buildrules check [--dir DIR]
    \\
    \\  --dir DIR   the repository root (default .)
    \\
    \\Exit codes: 0 in sync, 1 stale or refused (each problem is printed with the fix), 2 usage.
    \\
;

const fix = "run `buildrules sync` and commit the result";

pub fn run(root: *Ctx, args: []const []const u8) u8 {
    var dir: []const u8 = ".";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dir")) {
            dir = ctxm.flagValue(args, &i) orelse return root.usage("check: --dir needs a value", .{});
        } else {
            return root.usage("check: unknown argument {s}\n{s}", .{ args[i], usage_text });
        }
    }
    var ctx = root.into(dir) catch |e| return root.fail("cannot open {s}: {s}", .{ dir, @errorName(e) });
    defer ctx.dir.close();
    return check(&ctx) catch |e| root.fail("check: {s}", .{@errorName(e)});
}

fn check(ctx: *Ctx) !u8 {
    const a = ctx.a;
    var bad: usize = 0;

    // rust-toolchain.toml
    var rustc: ?[]const u8 = null;
    switch (toolchain.judge(try ctx.readOpt("rust-toolchain.toml"))) {
        .ok => |v| rustc = v,
        .bad => |m| {
            _ = ctx.fail("{s}", .{m});
            bad += 1;
        },
    }

    // The table.
    var table: ?lockfile.Lock = null;
    if (try ctx.readOpt(contract.lock_file)) |text| {
        var diag = Diag.init(a);
        if (lockfile.parse(a, contract.lock_file, text, &diag)) |l| {
            table = l;
        } else |_| {
            for (diag.msgs.items) |m| _ = ctx.fail("{s}", .{m});
            bad += diag.count();
        }
    } else {
        _ = ctx.fail("{s} is missing: {s}", .{ contract.lock_file, fix });
        bad += 1;
    }

    // Cargo.lock
    const lock = try ctx.readOpt("Cargo.lock");
    if (lock == null) {
        _ = ctx.fail("Cargo.lock is missing: run cargo to resolve (or `buildrules sync`)", .{});
        bad += 1;
    }

    // The workspace and its members.
    var members: []const []const u8 = &.{};
    const root_manifest = try ctx.readOpt("Cargo.toml");
    if (root_manifest) |rm| {
        if (ws.workspaceSection(rm) == null or ws.isPackage(rm)) {
            _ = ctx.fail("Cargo.toml must be a virtual workspace (a [workspace] and no [package]) in v0", .{});
            bad += 1;
        } else {
            members = ws.memberDirs(ctx, rm) catch |e| switch (e) {
                error.UnsupportedMemberPattern => blk: {
                    _ = ctx.fail("a `members` entry is a glob buildrules does not expand (only `dir/*` is)", .{});
                    bad += 1;
                    break :blk &.{};
                },
                else => return e,
            };
        }
    } else {
        _ = ctx.fail("Cargo.toml is missing", .{});
        bad += 1;
    }

    if (table) |t| {
        if (rustc) |r| {
            if (!std.mem.eql(u8, r, t.rustc)) {
                _ = ctx.fail("STALE: rust-toolchain.toml pins {s} but {s} was synced for {s}: {s}", .{ r, contract.lock_file, t.rustc, fix });
                bad += 1;
            }
        }
        if (lock) |l| {
            const now = try ctxm.sha256Hex(a, l);
            if (!std.mem.eql(u8, now, t.lock_sha256)) {
                _ = ctx.fail("STALE: Cargo.lock changed since `buildrules sync` (recorded sha256 {s}, now {s}): {s}", .{ t.lock_sha256, now, fix });
                bad += 1;
            }
        }
        // Every manifest the table was made from, and every one it should have been made from.
        var now_set = std.ArrayList([]const u8).empty;
        try now_set.append(a, "Cargo.toml");
        try now_set.append(a, "rust-toolchain.toml");
        if (ctx.exists(contract.pins_file)) try now_set.append(a, contract.pins_file);
        for (members) |m| try now_set.append(a, try std.fmt.allocPrint(a, "{s}/Cargo.toml", .{m}));
        for (now_set.items) |p| {
            const want = lockfile.manifestHash(t, p) orelse {
                _ = ctx.fail("STALE: {s} is a new input (a new member?) the table does not know: {s}", .{ p, fix });
                bad += 1;
                continue;
            };
            const text = (try ctx.readOpt(p)) orelse continue;
            const got = try ctxm.sha256Hex(a, text);
            if (!std.mem.eql(u8, got, want)) {
                _ = ctx.fail("STALE: {s} changed since `buildrules sync` (recorded sha256 {s}, now {s}): {s}", .{ p, want, got, fix });
                bad += 1;
            }
        }
        for (t.manifests) |m| {
            var found = false;
            for (now_set.items) |p| {
                if (std.mem.eql(u8, p, m.path)) found = true;
            }
            if (!found) {
                _ = ctx.fail("STALE: {s} is in the table but no longer in the workspace: {s}", .{ m.path, fix });
                bad += 1;
            }
        }
    }

    // buildrules-pins.toml and the file generated from it.
    {
        var pd = Diag.init(a);
        const want_text: []const u8 = (try ctx.readOpt(contract.pins_file)) orelse "";
        if (pins_toml.render(a, want_text, &pd)) |fresh| {
            const have = (try ctx.readOpt(contract.rust_pins_file)) orelse "";
            if (!std.mem.eql(u8, have, fresh)) {
                _ = ctx.fail("STALE: {s} is not what {s} generates (first difference at line {d}): {s}", .{ contract.rust_pins_file, contract.pins_file, lockfile.firstDifference(have, fresh), fix });
                bad += 1;
            }
        } else |_| {
            for (pd.msgs.items) |m| _ = ctx.fail("{s}", .{m});
            bad += pd.count();
        }
    }

    // The glue.
    if (try ctx.readOpt(contract.bzl_file)) |b| {
        if (!std.mem.eql(u8, b, contract.bzl_text)) {
            _ = ctx.fail("STALE: {s} is not what sync writes (first difference at line {d}): {s}", .{ contract.bzl_file, lockfile.firstDifference(b, contract.bzl_text), fix });
            bad += 1;
        }
    } else {
        _ = ctx.fail("{s} is missing: {s}", .{ contract.bzl_file, fix });
        bad += 1;
    }
    if (try ctx.readOpt("BUCK")) |b| {
        if (std.mem.indexOf(u8, b, "cargo_workspace(") == null) {
            _ = ctx.fail("BUCK has no cargo_workspace call", .{});
            bad += 1;
        }
    } else {
        _ = ctx.fail("BUCK is missing: {s}", .{fix});
        bad += 1;
    }
    for (members) |m| {
        const buck = try std.fmt.allocPrint(a, "{s}/BUCK", .{m});
        const text = (try ctx.readOpt(buck)) orelse "";
        if (std.mem.indexOf(u8, text, "cargo_package(") == null) {
            _ = ctx.fail("{s} has no cargo_package call: run `buildrules cargo adopt {s}`", .{ buck, m });
            bad += 1;
        }
    }

    // The Mojo packages, when the repository has any: the same gate as `buildrules mojo check`.
    if (mojo_cmd.hasPackages(ctx)) {
        if ((try mojo_cmd.checkAll(ctx)) != ctxm.exit_ok) bad += 1;
    }

    if (bad == 0) {
        ctx.say("ok: rustc {s}; {s} matches Cargo.lock, rust-toolchain.toml and {d} member manifest(s)", .{ rustc.?, contract.lock_file, members.len });
        return ctxm.exit_ok;
    }
    return ctxm.exit_fail;
}
