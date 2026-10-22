//! `package-lock.json` as `autopin` reads it: strictly. The lock of a Dependabot pull request is data a third
//! party shaped, and every row of a pin table must be derivable from it. Every non-root entry has to be a
//! registry tarball with a sha512 `integrity` and the canonical `resolved` URL
//!   https://registry.npmjs.org/<name>/-/<base>-<version>.tgz        (<base> is the name without its scope)
//! and nothing else: an entry with neither or only one of the two (bundled, `link`, git, `file:`, workspace
//! members), an alias (`name` that is not the name of the path), a version that is not strict semver, a name or
//! path outside the registry's character set is refused, naming its path. The URL of a table row is DERIVED
//! (`canonicalUrl`) and compared; it is never trusted from the row.

const std = @import("std");
const npm_cmd = @import("npm_cmd.zig");
const safe = @import("autopin_safe.zig");
const valid = @import("valid.zig");
const Diag = @import("diag.zig").Diag;

pub const registry = "https://registry.npmjs.org/";

pub const Entry = struct {
    /// `name@version`.
    key: []const u8,
    name: []const u8,
    version: []const u8,
    sri512: []const u8,
    /// Derived from name and version, never read from the lock.
    url: []const u8,
    /// The first path (in the lock's order) that named this key, for messages.
    path: []const u8,
    os: ?[]const []const u8 = null,
    cpu: ?[]const []const u8 = null,
    libc: ?[]const []const u8 = null,
};

/// `https://registry.npmjs.org/<name>/-/<base>-<version>.tgz`.
pub fn canonicalUrl(a: std.mem.Allocator, name: []const u8, version: []const u8) ![]u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name[i + 1 ..] else name;
    return std.fmt.allocPrint(a, registry ++ "{s}/-/{s}-{s}.tgz", .{ name, base, version });
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn numeric(s: []const u8) bool {
    return allDigits(s) and (s.len == 1 or s[0] != '0');
}

fn identChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-';
}

/// MAJOR.MINOR.PATCH, optional -PRERELEASE and +BUILD, as semver.org writes them: no leading zeros in a numeric
/// field, no empty identifier, nothing but [0-9A-Za-z-] in an identifier, no `v`, no range, no tag.
pub fn isStrictSemver(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    var rest = s;
    var build: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '+')) |i| {
        build = rest[i + 1 ..];
        rest = rest[0..i];
    }
    var pre: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, rest, '-')) |i| {
        pre = rest[i + 1 ..];
        rest = rest[0..i];
    }
    var it = std.mem.splitScalar(u8, rest, '.');
    var n: usize = 0;
    while (it.next()) |part| : (n += 1) {
        if (!numeric(part)) return false;
    }
    if (n != 3) return false;
    if (pre) |p| {
        var ids = std.mem.splitScalar(u8, p, '.');
        while (ids.next()) |id| {
            if (id.len == 0) return false;
            for (id) |c| if (!identChar(c)) return false;
            if (allDigits(id) and !numeric(id)) return false;
        }
    }
    if (build) |b| {
        var ids = std.mem.splitScalar(u8, b, '.');
        while (ids.next()) |id| {
            if (id.len == 0) return false;
            for (id) |c| if (!identChar(c)) return false;
        }
    }
    return true;
}

/// The package name of a lock path `node_modules/a/node_modules/@s/b` (here `@s/b`), or null when the path is not
/// a chain of `node_modules/<name>` segments.
fn nameOfPath(path: []const u8) ?[]const u8 {
    const marker = "node_modules/";
    var rest = path;
    while (true) {
        if (!std.mem.startsWith(u8, rest, marker)) return null;
        rest = rest[marker.len..];
        if (std.mem.indexOf(u8, rest, "/" ++ marker)) |i| {
            if (!isNpmName(rest[0..i])) return null;
            rest = rest[i + 1 ..];
        } else {
            return if (isNpmName(rest)) rest else null;
        }
    }
}

fn lessEntry(_: void, x: Entry, y: Entry) bool {
    return std.mem.lessThan(u8, x.key, y.key);
}

fn flag(o: std.json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v != .bool or v.bool;
}

fn text(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// The entries of the lock, sorted by key, one per `name@version` (entries at several paths collapse; their
/// integrity must agree). Problems go to `diag`, each naming the path; the result is then not to be used.
pub fn read(a: std.mem.Allocator, lock_text: []const u8, diag: *Diag) ![]Entry {
    if (!safe.jsonDepthOk(lock_text)) {
        diag.add("package-lock.json nests deeper than {d} levels", .{safe.max_json_depth});
        return &.{};
    }
    const parsed = std.json.parseFromSlice(std.json.Value, a, lock_text, .{}) catch {
        diag.add("package-lock.json is not valid JSON", .{});
        return &.{};
    };
    if (parsed.value != .object) {
        diag.add("package-lock.json is not a JSON object", .{});
        return &.{};
    }
    const root = parsed.value.object;
    const lv = root.get("lockfileVersion");
    if (lv == null or lv.? != .integer or lv.?.integer != 3) {
        diag.add("package-lock.json is not lockfileVersion 3", .{});
        return &.{};
    }
    const pk = root.get("packages") orelse {
        diag.add("package-lock.json has no `packages` object", .{});
        return &.{};
    };
    if (pk != .object) {
        diag.add("package-lock.json `packages` is not an object", .{});
        return &.{};
    }
    var list = std.ArrayList(Entry).empty;
    var bundled = std.ArrayList([]const u8).empty;
    for (pk.object.keys(), pk.object.values()) |path, e| {
        if (path.len == 0) continue;
        if (e != .object) {
            diag.add("packages[{s}] is not an object", .{path});
            continue;
        }
        const o = e.object;
        const derived = nameOfPath(path) orelse {
            diag.add("packages[{s}]: the path is not a chain of node_modules/<name> (a workspace member, or a name this tool does not accept)", .{path});
            continue;
        };
        if (path.len > 512) {
            diag.add("packages[{s}]: the path is longer than 512 bytes", .{path});
            continue;
        }
        if (flag(o, "link") or flag(o, "bundled")) {
            diag.add("packages[{s}]: a link or a bundled package has no tarball of its own", .{path});
            continue;
        }
        if (flag(o, "inBundle")) {
            // A bundled package ships inside the tarball of the package that bundles it, so it has no tarball and no row of its own.
            // It is skipped only if it has nothing of a package of its own (no tarball, no alias) and, below, its parent chain reaches
            // a package that has a tarball.
            if (text(o, "resolved") != null or text(o, "integrity") != null) {
                diag.add("packages[{s}]: a bundled package that also names a tarball", .{path});
                continue;
            }
            if (text(o, "name")) |n| if (!std.mem.eql(u8, n, derived)) {
                diag.add("packages[{s}]: an alias (`name` is {s}, the path says {s})", .{ path, n, derived });
                continue;
            };
            try bundled.append(a, path);
            continue;
        }
        const resolved = text(o, "resolved") orelse "";
        const integrity = text(o, "integrity") orelse "";
        if (resolved.len == 0 or integrity.len == 0) {
            diag.add("packages[{s}]: needs both `resolved` and `integrity` (a bundled, git, file: or workspace entry has neither)", .{path});
            continue;
        }
        if (text(o, "name")) |n| if (!std.mem.eql(u8, n, derived)) {
            diag.add("packages[{s}]: an alias (`name` is {s}, the path says {s})", .{ path, n, derived });
            continue;
        };
        if (o.get("name")) |n| if (n != .string) {
            diag.add("packages[{s}]: `name` is not a string", .{path});
            continue;
        };
        const version = text(o, "version") orelse {
            diag.add("packages[{s}]: no version", .{path});
            continue;
        };
        if (!isStrictSemver(version) or !valid.isVersion(version)) {
            diag.add("packages[{s}]: version {s} is not strict semver", .{ path, version });
            continue;
        }
        if (!valid.isSri512(integrity)) {
            diag.add("packages[{s}]: integrity is not a sha512 of 64 bytes", .{path});
            continue;
        }
        const url = try canonicalUrl(a, derived, version);
        if (!std.mem.eql(u8, resolved, url)) {
            diag.add("packages[{s}]: resolved is not the registry tarball URL of {s}@{s} (git, another host, another file name, a query?)", .{ path, derived, version });
            continue;
        }
        const where = try std.fmt.allocPrint(a, "packages[{s}]", .{path});
        try list.append(a, .{
            .key = try std.fmt.allocPrint(a, "{s}@{s}", .{ derived, version }),
            .name = derived,
            .version = version,
            .sri512 = integrity,
            .url = url,
            .path = path,
            .os = npm_cmd.strList(a, o, "os", diag, where),
            .cpu = npm_cmd.strList(a, o, "cpu", diag, where),
            .libc = npm_cmd.strList(a, o, "libc", diag, where),
        });
    }
    try checkBundled(a, pk.object, list.items, bundled.items, diag);
    std.mem.sort(Entry, list.items, {}, lessEntry);
    var out = std.ArrayList(Entry).empty;
    for (list.items) |en| {
        if (out.items.len > 0 and std.mem.eql(u8, out.items[out.items.len - 1].key, en.key)) {
            const prev = out.items[out.items.len - 1];
            if (!std.mem.eql(u8, prev.sri512, en.sri512))
                diag.add("{s} has two different integrities: packages[{s}] and packages[{s}]", .{ en.key, prev.path, en.path });
            continue;
        }
        try out.append(a, en);
    }
    return out.items;
}

/// The path of the package that holds `path` (`node_modules/a/node_modules/b` is held by `node_modules/a`), or null at the top.
fn parentPath(path: []const u8) ?[]const u8 {
    const i = std.mem.lastIndexOf(u8, path, "/node_modules/") orelse return null;
    return path[0..i];
}

/// Every bundled path must have, going up through bundled paths only, a parent that is an accepted package with a tarball.
/// True when the lock entry at `parent` lists the package `child` among the packages it bundles: `bundleDependencies` is `true` (all of
/// its dependencies) or an array holding the name. npm decides what is bundled from the PARENT's list, never from the child's own
/// `inBundle` flag: a child the parent does not list is fetched from the registry by name and version, with nothing pinning it.
fn parentBundles(pk: std.json.ObjectMap, parent: []const u8, child: []const u8) bool {
    const p = pk.get(parent) orelse return false;
    if (p != .object) return false;
    const list = p.object.get("bundleDependencies") orelse p.object.get("bundledDependencies") orelse return false;
    switch (list) {
        .bool => |b| return b,
        .array => |items| {
            for (items.items) |item| if (item == .string and std.mem.eql(u8, item.string, child)) return true;
            return false;
        },
        else => return false,
    }
}

/// The package name of a lock path: what follows its last `node_modules/`.
fn lastName(path: []const u8) []const u8 {
    const marker = "node_modules/";
    const i = std.mem.lastIndexOf(u8, path, marker) orelse return path;
    return path[i + marker.len ..];
}

/// Every bundled path must, going up one level at a time, have an IMMEDIATE parent that is in the lock and lists it in its
/// `bundleDependencies`, each parent in turn being a bundled path with the same property, until a parent is an accepted package with a
/// tarball. What this does not prove: that the listed child is really inside the parent's tarball (see `verify-pins`).
fn checkBundled(a: std.mem.Allocator, pk: std.json.ObjectMap, accepted: []const Entry, bundled: []const []const u8, diag: *Diag) !void {
    var real = std.StringHashMap(void).init(a);
    for (accepted) |e| try real.put(e.path, {});
    var bundled_set = std.StringHashMap(void).init(a);
    for (bundled) |p| try bundled_set.put(p, {});
    for (bundled) |p| {
        var cur = p;
        const reaches = while (parentPath(cur)) |up| {
            if (!parentBundles(pk, up, lastName(cur))) break false;
            if (real.contains(up)) break true;
            if (!bundled_set.contains(up)) break false;
            cur = up;
        } else false;
        if (!reaches) diag.add("packages[{s}]: a bundled package whose parent chain does not reach a package that has a tarball and lists it in bundleDependencies", .{p});
    }
}

fn nameSegment(x: []const u8) bool {
    if (x.len == 0) return false;
    for (x, 0..) |c, i| {
        const first_ok = std.ascii.isAlphanumeric(c) or c == '~';
        const rest_ok = first_ok or c == '.' or c == '_' or c == '-';
        if (!(if (i == 0) first_ok else rest_ok)) return false;
    }
    return true;
}

/// An npm package name: an optional `@scope/` and one segment, each segment of letters, digits and `~`, then also `-`,
/// `.` and `_` after the first character (upper case is allowed: old packages have it). No other `/`, no `..`
/// component, no `+`, no `@` in the middle.
pub fn isNpmName(s: []const u8) bool {
    if (s.len == 0 or s.len > 214) return false;
    if (s[0] == '@') {
        const slash = std.mem.indexOfScalar(u8, s, '/') orelse return false;
        return nameSegment(s[1..slash]) and nameSegment(s[slash + 1 ..]);
    }
    return nameSegment(s);
}
