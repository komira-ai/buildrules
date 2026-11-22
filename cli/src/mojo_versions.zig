//! The Mojo versions of a package whose mopm.toml lists several (`[package] mojo = [...]`): `sync` asks mopm for the graph of each version and `check`
//! reads the `MOJOS` table and the `GRAPH_JSON_MOJO_*` blocks back (mojo_lock.zig, docs/contract.md, section 12).

const std = @import("std");
const ctxm = @import("ctx.zig");
const lockm = @import("mojo_lock.zig");
const plan = @import("mojo_plan.zig");
const Diag = @import("diag.zig").Diag;
const Ctx = ctxm.Ctx;

const fix = "run `buildrules mojo sync` and commit the result";

fn stale(ctx: *Ctx, bad: *usize, comptime fmt: []const u8, args: anytype) void {
    _ = ctx.fail("STALE: " ++ fmt, args);
    bad.* += 1;
}

/// A version buildrules can name a graph block after: digits separated by single dots (`1.2.0`).
pub fn isVersion(v: []const u8) bool {
    if (v.len == 0 or v[0] == '.' or v[v.len - 1] == '.') return false;
    var before_dot = false;
    for (v) |c| {
        if (c == '.') {
            if (before_dot) return false;
            before_dot = true;
        } else if (c >= '0' and c <= '9') {
            before_dot = false;
        } else return false;
    }
    return true;
}

fn listsMojo(listed: []const []const u8, mojo: []const u8) bool {
    for (listed) |v| if (std.mem.eql(u8, v, mojo)) return true;
    return false;
}

/// Whether the versions of a several-version mopm.toml can be synced: each is a version of digits and dots, none is listed twice and the default
/// (mopm-toolchain.toml's) is one of them. A one-version list is always fine. Otherwise the refusal is reported (and added to `code`) and the answer is false.
pub fn listedOk(ctx: *Ctx, pkg: []const u8, listed: []const []const u8, default: []const u8, code: *u8) !bool {
    if (listed.len < 2) return true;
    for (listed, 0..) |v, i| {
        if (!isVersion(v)) {
            code.* |= ctx.fail("{s}: mopm.toml lists Mojo {s}, which is not a version of digits and dots (1.2.0): buildrules names its graph block after it", .{ pkg, v });
            return false;
        }
        if (listsMojo(listed[0..i], v)) {
            code.* |= ctx.fail("{s}: mopm.toml lists Mojo {s} more than once", .{ pkg, v });
            return false;
        }
    }
    if (!listsMojo(listed, default)) {
        code.* |= ctx.fail("{s}: mopm-toolchain.toml names Mojo {s}, which mopm.toml's mojo = [...] does not list ({s}): add it, or name one of those", .{ pkg, default, try std.mem.join(ctx.a, ", ", listed) });
        return false;
    }
    return true;
}

/// What `MOJOS` and the version blocks of a table hold, and the toolchains of the graphs of the other versions.
pub const Versions = struct { entries: []const lockm.MojoEntry = &.{}, blocks: []const lockm.MojoBlock = &.{}, tcs: []const lockm.Tc = &.{} };

/// The graphs of every listed version other than `default`, asked of mopm in mopm.toml's order. Nothing for a one-version list. Null after reporting why
/// (and adding to `code`) when one of them cannot be had.
pub fn planVersions(ctx: *Ctx, sub: *Ctx, pkg: []const u8, mopm: []const u8, mopm_version: []const u8, listed: []const []const u8, default: []const u8, default_closure: []const u8, rooted: bool, code: *u8) !?Versions {
    if (listed.len < 2) return Versions{};
    const a = ctx.a;
    var entries = std.ArrayList(lockm.MojoEntry).empty;
    var blocks = std.ArrayList(lockm.MojoBlock).empty;
    var tcs = std.ArrayList(lockm.Tc).empty;
    var failed = false;
    for (listed) |v| {
        if (std.mem.eql(u8, v, default)) {
            try entries.append(a, .{ .mojo = v, .closure_sha256 = default_closure });
            continue;
        }
        const o = (try plan.planOther(ctx, sub, pkg, mopm, mopm_version, v, rooted, code)) orelse {
            failed = true;
            continue;
        };
        try entries.append(a, .{ .mojo = v, .closure_sha256 = o.closure_sha256 });
        try blocks.appendSlice(a, o.blocks);
        try tcs.appendSlice(a, o.tcs);
    }
    if (failed) return null;
    return Versions{ .entries = entries.items, .blocks = blocks.items, .tcs = tcs.items };
}

/// The `MOJOS` table and the `GRAPH_JSON_MOJO_*` blocks against mopm.toml's list of versions and against each other; the toolchains of the blocks go to `tcs`.
pub fn checkMojos(ctx: *Ctx, lock_path: []const u8, l: lockm.Lock, listed: []const []const u8, bad: *usize, tcs: *std.ArrayList(lockm.Tc)) !void {
    const a = ctx.a;
    for (l.mojos, 0..) |e, i| {
        if (!isVersion(e.mojo)) stale(ctx, bad, "{s}: MOJOS names Mojo {s}, which is not a version of digits and dots: {s}", .{ lock_path, e.mojo, fix });
        for (l.mojos[0..i]) |p| if (std.mem.eql(u8, p.mojo, e.mojo)) stale(ctx, bad, "{s}: MOJOS names Mojo {s} twice: {s}", .{ lock_path, e.mojo, fix });
    }
    if (listed.len > 1) {
        var in_table = std.ArrayList([]const u8).empty;
        if (l.mojos.len == 0) try in_table.append(a, l.mojo);
        for (l.mojos) |e| try in_table.append(a, e.mojo);
        const same = in_table.items.len == listed.len and for (listed, in_table.items) |x, y| {
            if (!std.mem.eql(u8, x, y)) break false;
        } else true;
        if (!same) stale(ctx, bad, "{s}: the table is for Mojo {s} but mopm.toml's mojo = [...] lists {s}: {s}", .{ lock_path, try std.mem.join(a, ", ", in_table.items), try std.mem.join(a, ", ", listed), fix });
    } else if (l.mojos.len > 0) {
        stale(ctx, bad, "{s}: has a MOJOS table but mopm.toml lists one Mojo version: {s}", .{ lock_path, fix });
    }
    if (l.mojos.len > 0 and !mojoNamed(l.mojos, l.mojo)) stale(ctx, bad, "{s}: MOJOS does not name MOJO {s}: {s}", .{ lock_path, l.mojo, fix });
    for (l.mojo_blocks, 0..) |b, i| {
        const var_name = try lockm.graphVarMojo(a, b.mojo, b.subdir);
        for (l.mojo_blocks[0..i]) |p| if (std.mem.eql(u8, p.mojo, b.mojo) and std.mem.eql(u8, p.subdir, b.subdir)) stale(ctx, bad, "{s}: the {s} block is there twice: {s}", .{ lock_path, var_name, fix });
        if (!mojoNamed(l.mojos, b.mojo)) stale(ctx, bad, "{s}: the {s} block is for Mojo {s}, which MOJOS does not name: {s}", .{ lock_path, var_name, b.mojo, fix });
        var bd = Diag.init(a);
        const bg = lockm.parseGraph(a, lock_path, b.graph_json, &bd) catch {
            for (bd.msgs.items) |m| _ = ctx.fail("{s}", .{m});
            bad.* += @max(1, bd.count());
            continue;
        };
        const got_sub = lockm.toolchainSubdir(bg.toolchain);
        if (!std.mem.eql(u8, bg.mojo, b.mojo)) stale(ctx, bad, "{s}: the {s} block is the graph for Mojo {s}: {s}", .{ lock_path, var_name, bg.mojo, fix });
        if (!std.mem.eql(u8, got_sub, b.subdir)) stale(ctx, bad, "{s}: the {s} block is the graph of \"{s}\", not of {s}: {s}", .{ lock_path, var_name, got_sub, b.subdir, fix });
        try tcs.append(a, .{ .mojo = bg.mojo, .toolchain = bg.toolchain, .subdir = b.subdir });
        if (std.mem.eql(u8, b.subdir, lockm.base_subdir)) {
            for (l.mojos) |e| {
                if (std.mem.eql(u8, e.mojo, b.mojo) and !std.mem.eql(u8, e.closure_sha256, bg.closure_sha256)) {
                    stale(ctx, bad, "{s}: the MOJOS entry of {s} has CLOSURE_SHA256 {s}, not the closure its unit graph pins ({s}): the file was edited by hand; {s}", .{ lock_path, e.mojo, e.closure_sha256, bg.closure_sha256, fix });
                }
            }
        }
    }
    for (l.mojos) |e| {
        if (std.mem.eql(u8, e.mojo, l.mojo)) continue;
        var has = false;
        for (l.mojo_blocks) |b| has = has or (std.mem.eql(u8, b.mojo, e.mojo) and std.mem.eql(u8, b.subdir, lockm.base_subdir));
        if (!has) stale(ctx, bad, "{s}: MOJOS names Mojo {s} but the table has no {s} block: {s}", .{ lock_path, e.mojo, try lockm.graphVarMojo(a, e.mojo, lockm.base_subdir), fix });
    }
}

fn mojoNamed(entries: []const lockm.MojoEntry, mojo: []const u8) bool {
    for (entries) |e| if (std.mem.eql(u8, e.mojo, mojo)) return true;
    return false;
}
