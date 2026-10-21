//! `buildrules autopin compute`: the unprivileged half. It runs on the checkout of a Dependabot pull request, with
//! a read-only token and no secrets, and regenerates the pin table of every SETS directory whose lock needs one:
//! the tarballs the lock names (registry.npmjs.org only, no redirects, size and count caps) are downloaded once to
//! learn their sha256 and size, and each sha512 must be the lock's. The tables that came out different are written
//! under `--out` at their repository-relative paths, with a `manifest.json` that says which pull request and which
//! head they were computed for. The commit half re-reads all of it as untrusted bytes; nothing here is trusted.

const std = @import("std");
const ctxm = @import("ctx.zig");
const fetch = @import("fetch.zig");
const lock_mod = @import("autopin_lock.zig");
const manifest_mod = @import("autopin_manifest.zig");
const npm_cmd = @import("npm_cmd.zig");
const safe = @import("autopin_safe.zig");
const sets_mod = @import("autopin_sets.zig");
const table_mod = @import("autopin_table.zig");
const Diag = @import("diag.zig").Diag;
const Ctx = ctxm.Ctx;

pub const max_new_rows: usize = 200;
pub const max_total_bytes: u64 = 512 << 20;

pub const usage_text =
    \\usage: buildrules autopin compute --event FILE --out DIR --set DIR=KIND [--set DIR=KIND ...] [--dir DIR]
    \\
    \\  --event FILE   the pull_request event of the run (GITHUB_EVENT_PATH): the pull request number and the head and base sha
    \\  --out DIR      where the changed tables and manifest.json go (an empty or absent directory)
    \\  --set D=KIND   a directory that may be regenerated; KIND is buildrules-lock (buildrules.lock.bzl, from `npm sync`) or
    \\                 pins-lock (pins.lock.bzl, from kpin); repeatable, at most 8
    \\  --dir DIR      the repository root (default .)
    \\
    \\For each directory: the lock must be strict (registry tarballs with sha512 integrity and the canonical URL, strict semver,
    \\no alias, link, git, file or workspace entry); a tarball the table lacks is downloaded from registry.npmjs.org only (no
    \\redirect, 64 MiB each, 200 new, 512 MiB in all) and must have the lock's sha512; the new table is read back and bound to
    \\the lock offline. Exit codes: 0 ok (also when nothing changed), 1 refused or failed, 2 usage.
    \\
;

/// The network seam of the downloads (tests replace it).
pub var fetcher: npm_cmd.Fetch = &httpFetch;

var fetched_rows: usize = 0;
var fetched_bytes: u64 = 0;

/// Forget the downloads counted so far (a run starts with none).
pub fn resetCounters() void {
    fetched_rows = 0;
    fetched_bytes = 0;
}

fn httpFetch(a: std.mem.Allocator, url: []const u8) anyerror!fetch.Digest.Result {
    var http = fetch.HttpFetcher{ .allocator = a, .max_redirects = 0 };
    var d = fetch.Digest{ .max = table_mod.max_size };
    try http.fetcher().get(url, d.sink());
    return d.finish(a);
}

/// What every download goes through: the registry host only, at most `max_new_rows` of them, each at most
/// `table_mod.max_size`, `max_total_bytes` together.
pub fn capped(a: std.mem.Allocator, url: []const u8) anyerror!fetch.Digest.Result {
    if (!std.mem.startsWith(u8, url, lock_mod.registry)) return error.HostNotAllowed;
    if (fetched_rows >= max_new_rows) return error.TooManyNewPackages;
    fetched_rows += 1;
    const d = try fetcher(a, url);
    if (d.size > table_mod.max_size) return error.TarballTooLarge;
    fetched_bytes += d.size;
    if (fetched_bytes > max_total_bytes) return error.TotalTooLarge;
    return d;
}

const Opts = struct {
    dir: []const u8 = ".",
    out: ?[]const u8 = null,
    event: ?[]const u8 = null,
    set_values: []const []const u8 = &.{},
};

pub fn run(root: *Ctx, args: []const []const u8) u8 {
    var o = Opts{};
    var set_values = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const is_value_flag = std.mem.eql(u8, arg, "--dir") or std.mem.eql(u8, arg, "--out") or std.mem.eql(u8, arg, "--event") or std.mem.eql(u8, arg, "--set");
        if (!is_value_flag) return root.usage("autopin compute: unknown argument {s}\n{s}", .{ arg, usage_text });
        const v = ctxm.flagValue(args, &i) orelse return root.usage("autopin compute: {s} needs a value", .{arg});
        if (std.mem.eql(u8, arg, "--dir")) o.dir = v else if (std.mem.eql(u8, arg, "--out")) o.out = v else if (std.mem.eql(u8, arg, "--event")) o.event = v else set_values.append(root.a, v) catch return root.fail("out of memory", .{});
    }
    o.set_values = set_values.items;
    if (o.out == null or o.event == null) return root.usage("autopin compute: --event and --out are required\n{s}", .{usage_text});
    return compute(root, o) catch |e| root.fail("autopin compute: {s}", .{@errorName(e)});
}

const Event = struct { pr: u64, head_sha: []const u8, base_sha: []const u8 };

fn isSha1(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

fn objGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn readEvent(ctx: *Ctx, path: []const u8, diag: *Diag) !?Event {
    const text = ctx.read(path) catch |e| {
        diag.add("cannot read the event {s}: {s}", .{ path, @errorName(e) });
        return null;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, ctx.a, text, .{}) catch {
        diag.add("the event is not valid JSON", .{});
        return null;
    };
    const pr = objGet(parsed.value, "pull_request") orelse {
        diag.add("the event has no pull_request (this is not a pull_request run)", .{});
        return null;
    };
    const num = objGet(pr, "number");
    const head = objGet(objGet(pr, "head") orelse .null, "sha");
    const base = objGet(objGet(pr, "base") orelse .null, "sha");
    if (num == null or num.? != .integer or num.?.integer < 1 or num.?.integer > manifest_mod.max_pr) {
        diag.add("the event's pull request number is not a positive integer", .{});
        return null;
    }
    if (head == null or head.? != .string or !isSha1(head.?.string) or base == null or base.? != .string or !isSha1(base.?.string)) {
        diag.add("the event's head or base sha is not 40 lower-case hex digits", .{});
        return null;
    }
    return .{ .pr = @intCast(num.?.integer), .head_sha = head.?.string, .base_sha = base.?.string };
}

fn outDirEmpty(ctx: *Ctx, out: []const u8) !bool {
    var d = ctx.dir.openDir(out, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return true,
        else => return e,
    };
    defer d.close();
    var it = d.iterate();
    return (try it.next()) == null;
}

fn compute(root: *Ctx, o: Opts) !u8 {
    const a = root.a;
    resetCounters();
    const sets = sets_mod.Sets.parse(a, o.set_values) catch |e| return root.usage("autopin compute: --set: {s}", .{@errorName(e)});
    var diag = Diag.init(a);
    const ev = (try readEvent(root, o.event.?, &diag)) orelse {
        for (diag.msgs.items) |m| _ = root.fail("{s}", .{try safe.oneLine(a, m)});
        return ctxm.exit_fail;
    };
    if (!try outDirEmpty(root, o.out.?)) return root.fail("autopin compute: --out {s} is not empty", .{o.out.?});

    var repo = root.into(o.dir) catch |e| return root.fail("cannot open {s}: {s}", .{ o.dir, @errorName(e) });
    defer repo.dir.close();
    npm_cmd.fetcher = &capped;

    var files = std.ArrayList(manifest_mod.File).empty;
    var bad: usize = 0;
    for (sets.items) |set| {
        var sd = Diag.init(a);
        const changed = computeSet(&repo, set, &sd) catch |e| blk: {
            sd.add("{s}", .{@errorName(e)});
            break :blk null;
        };
        for (sd.msgs.items) |m| _ = root.fail("{s}: {s}", .{ set.dir, try safe.oneLine(a, m) });
        if (sd.lost > 0) _ = root.fail("{s}: {s}", .{ set.dir, Diag.lost_text });
        if (sd.count() > 0) {
            bad += 1;
            continue;
        }
        if (changed) |text| {
            const rel = try sets_mod.Sets.tablePath(a, set);
            const dest = try std.fmt.allocPrint(a, "{s}/{s}", .{ std.mem.trimRight(u8, o.out.?, "/"), rel });
            try root.write(dest, text);
            try files.append(a, .{ .path = rel, .sha256 = try ctxm.sha256Hex(a, text) });
            root.say("{s}: regenerated {s}", .{ set.dir, rel });
        } else root.say("{s}: in sync", .{set.dir});
    }
    if (bad > 0) return root.fail("autopin compute: {d} directory(ies) refused; nothing is uploaded", .{bad});
    const text = try manifest_mod.render(a, .{ .pr = ev.pr, .head_sha = ev.head_sha, .base_sha = ev.base_sha, .files = files.items });
    try root.write(try std.fmt.allocPrint(a, "{s}/manifest.json", .{std.mem.trimRight(u8, o.out.?, "/")}), text);
    return ctxm.exit_ok;
}

/// The regenerated table of one SETS directory, or null when the table in the repository is already what the lock
/// calls for. Problems go to `diag`.
fn computeSet(repo: *Ctx, set: sets_mod.Set, diag: *Diag) !?[]const u8 {
    const a = repo.a;
    const lock_path = try sets_mod.Sets.path(a, set, sets_mod.package_lock);
    const table_path = try sets_mod.Sets.tablePath(a, set);
    const lock_text = try repo.readOpt(lock_path) orelse {
        diag.add("no {s}", .{lock_path});
        return null;
    };
    const entries = try lock_mod.read(a, lock_text, diag);
    if (diag.count() > 0) return null;
    const existing = try repo.readOpt(table_path) orelse {
        diag.add("no table {s} to regenerate (the directory is named in SETS, so its table must exist)", .{table_path});
        return null;
    };

    const fresh: []const u8 = switch (set.kind) {
        .buildrules_lock => blk: {
            const built = (try npm_cmd.buildTable(repo, set.dir, false, false, null, diag)) orelse return null;
            break :blk built.table;
        },
        .pins_lock => blk: {
            const sp = table_mod.split(existing) orelse {
                diag.add("{s} has no NPM block", .{table_path});
                return null;
            };
            const old = try table_mod.parseRows(a, sp.npm, .pins_lock, diag);
            if (diag.count() > 0) return null;
            var rows = std.ArrayList(table_mod.Row).empty;
            for (entries) |e| {
                var sha: []const u8 = "";
                var size: u64 = 0;
                var known = false;
                for (old) |r| if (std.mem.eql(u8, r.key, e.key)) {
                    if (!std.mem.eql(u8, r.sri512, e.sri512)) {
                        diag.add("{s}: package-lock.json says {s} but the table pins {s}: the same version with other bytes", .{ e.key, e.sri512, r.sri512 });
                        break;
                    }
                    sha = r.sha256;
                    size = r.size;
                    known = true;
                };
                if (diag.count() > 0) continue;
                if (!known) {
                    const d = capped(a, e.url) catch |err| {
                        diag.add("{s}: fetching {s}: {s}", .{ e.key, e.url, @errorName(err) });
                        continue;
                    };
                    if (!std.mem.eql(u8, d.sri512, e.sri512)) {
                        diag.add("{s}: the bytes at {s} have sha512 {s}; package-lock.json says {s}. Nothing was pinned", .{ e.key, e.url, d.sri512, e.sri512 });
                        continue;
                    }
                    sha = d.sha256;
                    size = d.size;
                    repo.say("{s}: pinned {s} ({d} bytes)", .{ set.dir, e.key, size });
                }
                try rows.append(a, .{ .key = e.key, .name = e.name, .version = e.version, .url = e.url, .sri512 = e.sri512, .sha256 = sha, .size = size });
            }
            if (diag.count() > 0) return null;
            break :blk try table_mod.freshPins(a, sp.prefix, rows.items);
        },
    };

    // The offline check, with the reader and the binding the commit half uses.
    const sp = table_mod.split(fresh) orelse {
        diag.add("the regenerated table has no NPM block", .{});
        return null;
    };
    const rows = try table_mod.parseRows(a, sp.npm, set.kind, diag);
    if (diag.count() > 0) return null;
    try table_mod.bind(a, entries, rows, set.kind, diag);
    if (diag.count() > 0) return null;
    if (std.mem.eql(u8, fresh, existing)) return null;
    return fresh;
}
