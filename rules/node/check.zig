//! `check`: is the committed table (buildrules.lock.bzl, written by `buildrules npm sync`) still
//! what package.json and package-lock.json say?
//!
//! Three things must agree: the sha256 of package.json (the table carries its scripts and policy),
//! the sha256 of package-lock.json, and the set of pinned tarballs: every package of the lockfile
//! that has a tarball is in the table with the same sha512 integrity, and the table holds nothing
//! else. Any difference is a line naming it; the fix is always `buildrules npm sync`.
const std = @import("std");

pub const Spec = struct {
    package_json: []const u8,
    lockfile: []const u8,
    /// The sha256 (lower-case hex) of each file as the table recorded it.
    package_json_sha256: []const u8,
    lockfile_sha256: []const u8,
    /// `name@version` -> sri512 of the table.
    table: std.StringArrayHashMap([]const u8),
};

fn hex(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.allocPrint(a, "{x}", .{&d});
}

fn str(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn flag(o: std.json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}

/// `name@version` -> integrity of every package of the lockfile that has a tarball (the set kpin pins).
pub fn lockPackages(a: std.mem.Allocator, lock: []const u8, problems: *std.ArrayList([]const u8)) !std.StringArrayHashMap([]const u8) {
    var out = std.StringArrayHashMap([]const u8).init(a);
    const parsed = std.json.parseFromSlice(std.json.Value, a, lock, .{}) catch {
        try problems.append(a, "package-lock.json is not JSON");
        return out;
    };
    const root = if (parsed.value == .object) parsed.value.object else {
        try problems.append(a, "package-lock.json is not a JSON object");
        return out;
    };
    const lv = root.get("lockfileVersion");
    if (lv == null or lv.? != .integer or lv.?.integer != 3) {
        try problems.append(a, "package-lock.json is not lockfileVersion 3 (npm >= 9)");
        return out;
    }
    const pk = root.get("packages") orelse {
        try problems.append(a, "package-lock.json has no `packages`");
        return out;
    };
    if (pk != .object) {
        try problems.append(a, "package-lock.json `packages` is not an object");
        return out;
    }
    const marker = "node_modules/";
    for (pk.object.keys(), pk.object.values()) |path, e| {
        if (path.len == 0 or e != .object) continue;
        if (flag(e.object, "link") or flag(e.object, "inBundle")) continue;
        const at = std.mem.lastIndexOf(u8, path, marker);
        if (str(e.object, "resolved") == null and at == null) continue; // a workspace member
        const name = str(e.object, "name") orelse if (at) |i| path[i + marker.len ..] else {
            try problems.append(a, try std.fmt.allocPrint(a, "{s}: no name", .{path}));
            continue;
        };
        const version = str(e.object, "version") orelse {
            try problems.append(a, try std.fmt.allocPrint(a, "{s}: no version", .{path}));
            continue;
        };
        const integrity = str(e.object, "integrity") orelse {
            try problems.append(a, try std.fmt.allocPrint(a, "{s}@{s}: no integrity (a git or file dependency cannot be pinned)", .{ name, version }));
            continue;
        };
        try out.put(try std.fmt.allocPrint(a, "{s}@{s}", .{ name, version }), integrity);
    }
    return out;
}

/// Writes every difference to `w` as a `npm check:` line; error.Failed if there is any.
pub fn check(a: std.mem.Allocator, spec: Spec, w: anytype) !void {
    var problems = std.ArrayList([]const u8).empty;
    const pj = try hex(a, spec.package_json);
    if (!std.mem.eql(u8, pj, spec.package_json_sha256))
        try problems.append(a, try std.fmt.allocPrint(a, "package.json is not the one the table was made from (sha256 {s}, the table has {s})", .{ pj, spec.package_json_sha256 }));
    const lk = try hex(a, spec.lockfile);
    if (!std.mem.eql(u8, lk, spec.lockfile_sha256))
        try problems.append(a, try std.fmt.allocPrint(a, "package-lock.json is not the one the table was made from (sha256 {s}, the table has {s})", .{ lk, spec.lockfile_sha256 }));

    const locked = try lockPackages(a, spec.lockfile, &problems);
    for (locked.keys(), locked.values()) |k, integrity| {
        const pinned = spec.table.get(k) orelse {
            try problems.append(a, try std.fmt.allocPrint(a, "{s} is in package-lock.json and not in the table", .{k}));
            continue;
        };
        if (!std.mem.eql(u8, pinned, integrity))
            try problems.append(a, try std.fmt.allocPrint(a, "{s}: package-lock.json says {s}, the table pins {s}", .{ k, integrity, pinned }));
    }
    for (spec.table.keys()) |k| {
        if (!locked.contains(k)) try problems.append(a, try std.fmt.allocPrint(a, "{s} is in the table and no longer in package-lock.json", .{k}));
    }
    if (problems.items.len == 0) return;
    const shown = @min(problems.items.len, 40);
    for (problems.items[0..shown]) |m| try w.print("npm check: {s}\n", .{m});
    if (problems.items.len > shown) try w.print("npm check: ... and {d} more\n", .{problems.items.len - shown});
    try w.print("npm check: the table is stale: run `buildrules npm sync` and commit the result\n", .{});
    return error.Failed;
}

/// package.json as the steps read it: the top-level "buildrules" key (policy) removed, the rest in
/// its order, two-space indented. Policy edits then leave the steps' inputs unchanged.
pub fn withoutPolicy(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return error.NotJson;
    var v = parsed.value;
    if (v != .object) return error.NotAnObject;
    _ = v.object.orderedRemove("buildrules");
    return std.json.Stringify.valueAlloc(a, v, .{ .whitespace = .indent_2 });
}
