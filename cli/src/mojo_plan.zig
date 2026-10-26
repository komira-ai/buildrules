//! Asking the pinned mopm for unit graphs (`buildrules mojo sync`, rules/mojo/subdirs.bzl): what its `--help` says it can do, and one `plan --unit-graph` run.

const std = @import("std");
const ctxm = @import("ctx.zig");
const lockm = @import("mojo_lock.zig");
const graph_norm = @import("mojo_graph_norm");
const Diag = @import("diag.zig").Diag;
const Ctx = ctxm.Ctx;

pub fn sha256Of(ctx: *Ctx, rel: []const u8) !?[]const u8 {
    const bytes = (try ctx.readOpt(rel)) orelse return null;
    return try ctxm.sha256Hex(ctx.a, bytes);
}

pub const Probe = enum { supported, unsupported, failed };

/// Whether the mopm at `mopm` takes `plan --unit-graph --workspace-root DIR`, asked of the binary itself: `mopm --help` (standard output, exit 0)
/// lists the flag in its `plan` line when it has it. (`mopm plan --help` is no probe: `plan` takes no help option and prints its usage to
/// standard error with exit 2 whatever it supports.) No release number is compared. The answer is kept for the run per binary path and sha256, so
/// a binary is asked once. A mopm that cannot be asked is reported once and counts as unsupported: the caller does not plan with it.
pub fn probeWorkspaceRoot(ctx: *Ctx, mopm: []const u8, cache: *std.StringHashMap(Probe)) !Probe {
    const a = ctx.a;
    const digest = (try sha256Of(ctx, mopm)) orelse "unreadable";
    const key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ mopm, digest });
    if (cache.get(key)) |known| return known;
    var answer: Probe = .unsupported;
    const r = ctx.execer(ctx, .{ .argv = &.{ mopm, "--help" }, .capture = true }) catch |e| {
        _ = ctx.fail("cannot ask {s} whether it supports --workspace-root: `{s} --help` cannot run: {s}; this mopm is treated as not supporting it, and sync does not use it", .{ mopm, mopm, @errorName(e) });
        try cache.put(key, .failed);
        return .failed;
    };
    if (r.code != 0) {
        _ = ctx.fail("cannot ask {s} whether it supports --workspace-root: `{s} --help` exited {d}; this mopm is treated as not supporting it, and sync does not use it", .{ mopm, mopm, r.code });
        try cache.put(key, .failed);
        return .failed;
    }
    if (std.mem.indexOf(u8, r.stdout, "--workspace-root") != null) answer = .supported;
    try cache.put(key, answer);
    return answer;
}

/// `mopm plan --unit-graph --locked --mojo <mojo>` in `sub` (the package), with `--workspace-root` when `rooted` and `--subdir <subdir>` for a subdir other
/// than linux-64: its graph text, or null after reporting why (and adding to `code`). `''' ` in the text is refused for the first graph by the caller.
pub fn planOne(ctx: *Ctx, sub: *Ctx, pkg: []const u8, mopm: []const u8, mojo: []const u8, rooted: bool, subdir: ?[]const u8, code: *u8) !?[]const u8 {
    const a = ctx.a;
    const shown = if (pkg.len == 0) "." else pkg;
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{ mopm, "plan", "--unit-graph", "--locked", "--mojo", mojo });
    if (rooted) try argv.appendSlice(a, &.{ "--workspace-root", try ctx.dir.realpathAlloc(a, ".") });
    if (subdir) |s| try argv.appendSlice(a, &.{ "--subdir", s });
    const r = ctx.execer(sub, .{ .argv = argv.items, .capture = true }) catch |e| {
        code.* |= ctx.fail("{s}: cannot run mopm: {s}", .{ shown, @errorName(e) });
        return null;
    };
    if (r.code != 0) {
        code.* |= ctx.fail("{s}: `mopm plan --unit-graph --locked --mojo {s}{s}{s}{s}` exited {d}{s}", .{
            shown,
            mojo,
            if (rooted) " --workspace-root <the repository root>" else "",
            if (subdir != null) " --subdir " else "",
            subdir orelse "",
            r.code,
            if (r.code == 3) " (no usable mopm.lock, or it is out of date with mopm.toml: run `mopm lock`, which records the toolchain closure of every subdir)" else if (r.code == 4) " (mopm cannot make a graph from this project and lock; its message is above)" else "",
        });
        if (!rooted) _ = ctx.fail("{s}: this mopm does not support --workspace-root (needs a release containing it); pin one in mopm-toolchain.toml", .{shown});
        return null;
    }
    if (subdir == null and std.mem.indexOf(u8, r.stdout, "'''") != null) {
        code.* |= ctx.fail("{s}: mopm's graph holds ''' and cannot be embedded in a table", .{shown});
        return null;
    }
    return r.stdout;
}

/// The graphs of the other subdirs in the committed form (path dependencies by identity only), each held to be a graph of the Mojo asked for and of the
/// subdir it was asked for: `extras` and `tcs` are filled; false after reporting why (and adding to `code`) when one is not.
pub fn committedExtras(ctx: *Ctx, pkg: []const u8, mojo: []const u8, mopm_version: []const u8, runs: []const lockm.SubGraph, extras: *std.ArrayList(lockm.SubGraph), tcs: *std.ArrayList(lockm.Tc), code: *u8) !bool {
    const a = ctx.a;
    var ok = true;
    for (runs) |x| {
        if (std.mem.indexOf(u8, x.graph_json, "'''") != null) {
            code.* |= ctx.fail("{s}: mopm's {s} graph holds ''' and cannot be embedded in a table", .{ pkg, x.subdir });
            ok = false;
            continue;
        }
        var xd = Diag.init(a);
        const xg = lockm.parseGraph(a, pkg, x.graph_json, &xd) catch {
            for (xd.msgs.items) |m| _ = ctx.fail("{s}", .{m});
            if (xd.lost > 0) _ = ctx.fail("{s}", .{Diag.lost_text});
            code.* = ctxm.exit_fail;
            ok = false;
            continue;
        };
        if (!std.mem.eql(u8, xg.mojo, mojo)) {
            code.* |= ctx.fail("{s}: asked mopm for Mojo {s} ({s}) and got a graph for {s}", .{ pkg, mojo, x.subdir, xg.mojo });
            ok = false;
            continue;
        }
        const got_sub = lockm.toolchainSubdir(xg.toolchain);
        if (!std.mem.eql(u8, got_sub, x.subdir)) {
            code.* |= ctx.fail("{s}: asked mopm for the {s} graph and got one for \"{s}\": the pinned mopm {s} and this buildrules disagree about `plan --subdir`", .{ pkg, x.subdir, got_sub, mopm_version });
            ok = false;
            continue;
        }
        const committed = graph_norm.identityOnly(a, x.graph_json) catch |e| switch (e) {
            error.OutOfMemory => return e,
            error.Broken => {
                code.* |= ctx.fail("{s}: mopm's {s} unit graph is not in the layout `buildrules mojo sync` reads (a unit block it cannot edit)", .{ pkg, x.subdir });
                ok = false;
                continue;
            },
        };
        try extras.append(a, .{ .subdir = x.subdir, .graph_json = committed });
        try tcs.append(a, .{ .mojo = xg.mojo, .toolchain = xg.toolchain, .subdir = x.subdir });
    }
    return ok;
}

/// What `planAll` asked mopm: the linux-64 graph (mopm's default) and the graph of every other subdir the lock records a toolchain for.
pub const Planned = struct { base: []const u8, extra: []const lockm.SubGraph };

/// The subdirs other than linux-64 whose toolchain closure the package's `mopm.lock` records for `mojo` (`"toolchain": {"1.0.0": {"linux-64": "<sha256>",
/// "osx-arm64": "<sha256>"}}`), in the order of `lockm.extra_subdirs`: the graphs the table can hold. A lock made before mopm recorded more than linux-64
/// has none, and then the table is what it always was. An unreadable lock has none either: the missing or broken lock is the sync's own error, reported where
/// the files the graph was made from are hashed.
pub fn lockSubdirs(sub: *Ctx, mojo: []const u8) ![]const []const u8 {
    const a = sub.a;
    var out = std.ArrayList([]const u8).empty;
    const text = (try sub.readOpt("mopm.lock")) orelse return out.items;
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return out.items;
    if (root != .object) return out.items;
    const tc = root.object.get("toolchain") orelse return out.items;
    if (tc != .object) return out.items;
    const row = tc.object.get(mojo) orelse return out.items;
    if (row != .object) return out.items;
    for (lockm.extra_subdirs) |sd| {
        if (row.object.get(sd) != null) try out.append(a, sd);
    }
    return out.items;
}

/// Asks the pinned mopm for the graph of linux-64 and then, for every other subdir the lock records (`lockSubdirs`), `plan --subdir`. A failure of any of
/// them is reported and stops the package, so a table never holds some of the graphs its lock can print and not the rest. Null after reporting why.
pub fn planAll(ctx: *Ctx, sub: *Ctx, pkg: []const u8, mopm: []const u8, mojo: []const u8, rooted: bool, code: *u8) !?Planned {
    const base = (try planOne(ctx, sub, pkg, mopm, mojo, rooted, null, code)) orelse return null;
    var extra = std.ArrayList(lockm.SubGraph).empty;
    var failed = false;
    for (try lockSubdirs(sub, mojo)) |sd| {
        if (try planOne(ctx, sub, pkg, mopm, mojo, rooted, sd, code)) |out| {
            try extra.append(ctx.a, .{ .subdir = sd, .graph_json = out });
        } else failed = true;
    }
    if (failed) return null;
    return .{ .base = base, .extra = extra.items };
}
