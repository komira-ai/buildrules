//! What `autopin` reads from the GitHub API, and the checks every value must pass before anything uses it: the
//! shapes of repository names, branch names and shas, JSON replies, and the raw read of a file at a commit.
//!
//! The raw read is done twice on purpose. The contents API in its JSON form gives the blob's `sha` and `size`
//! (its `content` is never used: for a file over a megabyte it is empty). The same path with the raw media type
//! gives the bytes. The bytes are believed only if their length is `size` and their git blob sha1
//! (`sha1("blob <len>\0" ++ bytes)`) is `sha`; an empty body, a JSON envelope where the bytes should be, a wrong
//! length or a wrong hash is an error, never "no change".

const std = @import("std");
const api_mod = @import("autopin_api.zig");
const safe = @import("autopin_safe.zig");

pub const Error = error{ Unreadable, BadJson, NotAFile, RawMismatch, OutOfMemory };

pub const Reply = struct { status: u16, value: ?std.json.Value = null };

/// GET `path` as JSON. A body that is not JSON is `error.BadJson`; an empty body is a null value.
pub fn get(a: std.mem.Allocator, api: api_mod.Api, path: []const u8) anyerror!Reply {
    const r = try api.send(a, .{ .path = path });
    if (r.body.len == 0) return .{ .status = r.status };
    const parsed = std.json.parseFromSlice(std.json.Value, a, r.body, .{}) catch return error.BadJson;
    return .{ .status = r.status, .value = parsed.value };
}

pub fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

pub fn str(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

pub fn int(v: ?std.json.Value) ?i64 {
    const x = v orelse return null;
    return if (x == .integer) x.integer else null;
}

pub fn isSha1(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

fn nameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-';
}

/// `owner/name`, each of letters, digits, `.`, `_`, `-`.
pub fn isRepo(s: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return false;
    const owner = s[0..slash];
    const name = s[slash + 1 ..];
    if (owner.len == 0 or name.len == 0 or s.len > 140) return false;
    for (owner) |c| if (!nameChar(c)) return false;
    for (name) |c| if (!nameChar(c)) return false;
    return true;
}

fn branchChar(c: u8) bool {
    return nameChar(c) or c == '@';
}

/// `dependabot/npm_and_yarn/<segments>`: each segment of letters, digits, `.`, `_`, `-`, `@`; no `..`, no empty
/// segment, no trailing `.` or `/`.
pub fn isDependabotBranch(s: []const u8) bool {
    const prefix = "dependabot/npm_and_yarn/";
    if (!std.mem.startsWith(u8, s, prefix) or s.len > 200) return false;
    const rest = s[prefix.len..];
    if (rest.len == 0 or std.mem.indexOf(u8, rest, "..") != null or rest[rest.len - 1] == '.') return false;
    var it = std.mem.splitScalar(u8, rest, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return false;
        for (seg) |c| if (!branchChar(c)) return false;
    }
    return true;
}

/// A default branch name as it appears in a URL: letters, digits, `.`, `_`, `-`, `/`; no `..`, no empty segment.
pub fn isBranchName(s: []const u8) bool {
    if (s.len == 0 or s.len > 100 or std.mem.indexOf(u8, s, "..") != null) return false;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return false;
        for (seg) |c| if (!nameChar(c)) return false;
    }
    return true;
}

/// The git blob id of `bytes`.
pub fn blobSha1(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    const head = try std.fmt.allocPrint(a, "blob {d}\x00", .{bytes.len});
    h.update(head);
    h.update(bytes);
    var d: [20]u8 = undefined;
    h.final(&d);
    return a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
}

pub const max_file: usize = 4 << 20;

pub const Blob = struct { sha: []const u8, bytes: []const u8 };

/// The file at `path` in `repo` at the commit `ref`, read as the header says; null when there is no such file.
pub fn readFile(a: std.mem.Allocator, api: api_mod.Api, repo: []const u8, path: []const u8, ref: []const u8) anyerror!?Blob {
    const url = try std.fmt.allocPrint(a, "repos/{s}/contents/{s}?ref={s}", .{ repo, path, ref });
    const meta = try get(a, api, url);
    if (meta.status == 404) return null;
    if (meta.status != 200 or meta.value == null) return error.Unreadable;
    const v = meta.value.?;
    if (!std.mem.eql(u8, str(field(v, "type")) orelse "", "file")) return error.NotAFile;
    const sha = str(field(v, "sha")) orelse return error.BadJson;
    const size = int(field(v, "size")) orelse return error.BadJson;
    if (!isSha1(sha) or size < 0 or size > max_file) return error.BadJson;
    const raw = try api.send(a, .{ .path = url, .accept = api_mod.raw_accept, .max_body = max_file + 1 });
    if (raw.status != 200) return error.Unreadable;
    if (raw.body.len != size) return error.RawMismatch;
    const have = try blobSha1(a, raw.body);
    if (!std.mem.eql(u8, have, sha)) return error.RawMismatch;
    return .{ .sha = sha, .bytes = raw.body };
}

/// `s` as one line that cannot start a workflow command (see `autopin_safe.zig`: every byte outside printable ASCII becomes
/// `?`, and a long string is cut). Every string that came from a pull request is printed through this.
pub const oneLine = safe.oneLine;

/// The names of the keys of the three dependency maps of a package.json.
pub const dependency_maps = [_][]const u8{ "dependencies", "devDependencies", "optionalDependencies" };

fn jsonEql(x: std.json.Value, y: std.json.Value) bool {
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return switch (x) {
        .null => true,
        .bool => |b| b == y.bool,
        .integer => |i| i == y.integer,
        .float => |f| f == y.float,
        .number_string => |s| std.mem.eql(u8, s, y.number_string),
        .string => |s| std.mem.eql(u8, s, y.string),
        .array => |arr| blk: {
            if (arr.items.len != y.array.items.len) break :blk false;
            for (arr.items, y.array.items) |p, q| if (!jsonEql(p, q)) break :blk false;
            break :blk true;
        },
        .object => |o| blk: {
            if (o.count() != y.object.count()) break :blk false;
            for (o.keys(), o.values()) |k, v| {
                const other = y.object.get(k) orelse break :blk false;
                if (!jsonEql(v, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

/// True when the package.json texts `base` and `head` are objects that differ at most inside the dependency maps:
/// every other key (scripts, the buildrules policy, name, version, workspaces...) is present in both with an equal
/// value. A table copies `scripts` and the policy, and they run on the farm, so a pull request that changes them is
/// not a dependency bump.
pub fn sameOutsideDependencies(a: std.mem.Allocator, base: []const u8, head: []const u8) !bool {
    const pb = std.json.parseFromSlice(std.json.Value, a, base, .{}) catch return false;
    const ph = std.json.parseFromSlice(std.json.Value, a, head, .{}) catch return false;
    if (pb.value != .object or ph.value != .object) return false;
    const ob = pb.value.object;
    const oh = ph.value.object;
    for (ob.keys(), ob.values()) |k, v| {
        if (isDependencyMap(k)) continue;
        const other = oh.get(k) orelse return false;
        if (!jsonEql(v, other)) return false;
    }
    for (oh.keys()) |k| {
        if (isDependencyMap(k)) continue;
        if (!ob.contains(k)) return false;
    }
    return true;
}

fn isDependencyMap(k: []const u8) bool {
    for (dependency_maps) |m| if (std.mem.eql(u8, m, k)) return true;
    return false;
}

/// `<name>[bot]`: the login GitHub gives an App's bot.
pub fn isBotLogin(s: []const u8) bool {
    const bot = "[bot]";
    if (!std.mem.endsWith(u8, s, bot) or s.len <= bot.len or s.len > 60) return false;
    for (s[0 .. s.len - bot.len]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
    return true;
}
