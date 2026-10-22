//! `buildrules autopin verify-pins`: the check a pull request gets without any secret. `compute` downloads only the tarballs a table
//! lacks, so a wrong sha256 or size in a row that did not change is never looked at. This command downloads EVERY row of each table from
//! the registry, through the same path as `compute` (registry host only, no redirect, https only, 64 MiB each), and compares: the sha512
//! of the bytes with the lock's integrity (and the row's), the sha256 and the size with the row's. The lock is read as strictly as
//! `compute` reads it and the table is bound to it first, so a row is only fetched from a URL derived from its name and version.
//! A pull request's text only reaches the log through `oneLine`.
//!
//! NOT checked here (a limit of this command, stated rather than hidden): that a package a lock marks `inBundle` is really inside its
//! parent's tarball. `autopin_lock` believes the flag only when the parent lists the child in `bundleDependencies`; if the listed child
//! is missing from the tarball, npm fetches it from the registry by name and version, and nothing here pins that fetch. Looking inside the
//! tarball needs the gzip stream inflated and a tar reader with caps; a real bundling package (aws-cdk-lib) is large, more than a strict
//! reader should hold in memory, so it needs a streaming reader and is left to a follow-up.

const std = @import("std");
const compute = @import("autopin_compute.zig");
const ctxm = @import("ctx.zig");
const lock_mod = @import("autopin_lock.zig");
const safe = @import("autopin_safe.zig");
const sets_mod = @import("autopin_sets.zig");
const table_mod = @import("autopin_table.zig");
const Diag = @import("diag.zig").Diag;
const Ctx = ctxm.Ctx;

/// A table has at most `table_mod.max_rows` rows; all of them may be fetched, up to this many bytes together.
pub const max_total_bytes: u64 = 4 << 30;

pub const usage_text =
    \\usage: buildrules autopin verify-pins --set DIR=KIND [--set DIR=KIND ...] [--dir DIR]
    \\
    \\  --set D=KIND   a directory whose table is verified; KIND is buildrules-lock or pins-lock; repeatable, at most 8
    \\  --dir DIR      the repository root (default .)
    \\
    \\For each directory: the lock must be strict (as for `compute`), the table must be bound to it, and then EVERY row is downloaded
    \\from registry.npmjs.org only (no redirect, https only, 64 MiB each, 4 GiB in all): the sha512 must be the lock's, the sha256 and the
    \\size the row's. Needs no token. Exit codes: 0 every row verified, 1 a row differs or a download failed, 2 usage.
    \\
;

pub fn run(root: *Ctx, args: []const []const u8) u8 {
    var dir: []const u8 = ".";
    var set_values = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const is_dir = std.mem.eql(u8, arg, "--dir");
        if (!is_dir and !std.mem.eql(u8, arg, "--set")) return root.usage("autopin verify-pins: unknown argument {s}\n{s}", .{ arg, usage_text });
        const v = ctxm.flagValue(args, &i) orelse return root.usage("autopin verify-pins: {s} needs a value", .{arg});
        if (is_dir) dir = v else set_values.append(root.a, v) catch return root.fail("out of memory", .{});
    }
    if (set_values.items.len == 0) return root.usage("autopin verify-pins: at least one --set is required\n{s}", .{usage_text});
    return verify(root, dir, set_values.items) catch |e| root.fail("autopin verify-pins: {s}", .{@errorName(e)});
}

fn verify(root: *Ctx, dir: []const u8, set_values: []const []const u8) !u8 {
    const a = root.a;
    compute.resetCounters();
    const sets = sets_mod.Sets.parse(a, set_values) catch |e| return root.usage("autopin verify-pins: --set: {s}", .{@errorName(e)});
    var repo = root.into(dir) catch |e| return root.fail("cannot open {s}: {s}", .{ dir, @errorName(e) });
    defer repo.dir.close();
    const saved_rows = compute.row_cap;
    const saved_total = compute.total_cap;
    compute.row_cap = table_mod.max_rows;
    compute.total_cap = max_total_bytes;
    defer {
        compute.row_cap = saved_rows;
        compute.total_cap = saved_total;
    }
    var bad: usize = 0;
    for (sets.items) |set| {
        var sd = Diag.init(a);
        const verified = verifySet(&repo, set, &sd) catch |e| blk: {
            sd.add("{s}", .{@errorName(e)});
            break :blk 0;
        };
        for (sd.msgs.items) |m| _ = root.fail("{s}: {s}", .{ set.dir, try safe.oneLine(a, m) });
        if (sd.lost > 0) _ = root.fail("{s}: {s}", .{ set.dir, Diag.lost_text });
        if (sd.count() > 0) {
            bad += 1;
            continue;
        }
        root.say("{s}: verified {d} row(s)", .{ set.dir, verified });
    }
    if (bad > 0) return root.fail("autopin verify-pins: {d} directory(ies) failed", .{bad});
    return ctxm.exit_ok;
}

/// The number of rows of the table of `set` that were downloaded and found as the table says. Problems go to `diag`.
fn verifySet(repo: *Ctx, set: sets_mod.Set, diag: *Diag) !usize {
    const a = repo.a;
    const lock_path = try sets_mod.Sets.path(a, set, sets_mod.package_lock);
    const table_path = try sets_mod.Sets.tablePath(a, set);
    const lock_text = try repo.readOpt(lock_path) orelse {
        diag.add("no {s}", .{lock_path});
        return 0;
    };
    const entries = try lock_mod.read(a, lock_text, diag);
    if (diag.count() > 0) return 0;
    const table_text = try repo.readOpt(table_path) orelse {
        diag.add("no table {s}", .{table_path});
        return 0;
    };
    const sp = table_mod.split(table_text) orelse {
        diag.add("{s} has no NPM block", .{table_path});
        return 0;
    };
    const rows = table_mod.parseRows(a, sp.npm, set.kind, diag) catch return 0;
    if (diag.count() > 0) return 0;
    try table_mod.bind(a, entries, rows, set.kind, diag);
    if (diag.count() > 0) return 0;
    var good: usize = 0;
    for (rows) |r| {
        const d = compute.capped(a, r.url) catch |err| {
            diag.add("{s}: fetching {s}: {s}", .{ r.key, r.url, @errorName(err) });
            continue;
        };
        if (!std.mem.eql(u8, d.sri512, r.sri512)) {
            diag.add("{s}: the bytes at {s} have sha512 {s}; the lock and the row say {s}", .{ r.key, r.url, d.sri512, r.sri512 });
            continue;
        }
        if (!std.mem.eql(u8, d.sha256, r.sha256)) {
            diag.add("{s}: the bytes at {s} have sha256 {s}; the row says {s}", .{ r.key, r.url, d.sha256, r.sha256 });
            continue;
        }
        if (d.size != r.size) {
            diag.add("{s}: the bytes at {s} are {d} bytes; the row says {d}", .{ r.key, r.url, d.size, r.size });
            continue;
        }
        good += 1;
    }
    return good;
}
