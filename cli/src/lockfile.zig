//! buildrules.lock.bzl, the generated table, read back: only the lines `buildrules check` needs
//! (SCHEMA, RUSTC, TARGET, CARGO_LOCK_SHA256 and the MANIFEST_SHA256 block). The generator writes
//! them one per line on purpose (docs/contract.md, "The table"); nothing else in the file is read.

const std = @import("std");
const contract = @import("contract.zig");
const valid = @import("valid.zig");
const Diag = @import("diag.zig").Diag;

pub const Manifest = struct { path: []const u8, sha256: []const u8 };

pub const Lock = struct {
    schema: u32,
    rustc: []const u8,
    target: []const u8,
    lock_sha256: []const u8,
    manifests: []const Manifest,
};

/// The string in a `KEY = "value"` line, null when the line is not exactly that.
pub fn stringLine(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    const rest = line[key.len..];
    if (!std.mem.startsWith(u8, rest, " = \"") or rest.len < 5 or rest[rest.len - 1] != '"') return null;
    return rest[4 .. rest.len - 1];
}

/// `    "path": "sha256",`
fn manifestLine(line: []const u8) ?Manifest {
    const t = std.mem.trim(u8, line, " ");
    if (t.len < 8 or t[0] != '"' or t[t.len - 1] != ',') return null;
    const mid = std.mem.indexOf(u8, t, "\": \"") orelse return null;
    const path = t[1..mid];
    const rest = t[mid + 4 ..];
    if (rest.len < 3 or rest[rest.len - 2] != '"') return null;
    return .{ .path = path, .sha256 = rest[0 .. rest.len - 2] };
}

/// Every problem goes into `diag` (a refused schema, a missing key, a malformed hash or path).
pub fn parse(a: std.mem.Allocator, label: []const u8, text: []const u8, diag: *Diag) error{Invalid}!Lock {
    const before = diag.count();
    var schema: ?u32 = null;
    var rustc: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var lock_sha: ?[]const u8 = null;
    var have_block = false;
    var manifests = std.ArrayList(Manifest).empty;
    var in_block = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (in_block) {
            if (std.mem.eql(u8, line, "}")) {
                in_block = false;
                continue;
            }
            const m = manifestLine(line) orelse {
                diag.add("{s}: a MANIFEST_SHA256 line is not `    \"path\": \"sha256\",`: {s}", .{ label, line });
                continue;
            };
            if (!valid.isRelPath(m.path) or !valid.isSha256(m.sha256)) diag.add("{s}: MANIFEST_SHA256 entry `{s}` has a bad path or hash", .{ label, m.path });
            manifests.append(a, m) catch return error.Invalid;
            continue;
        }
        if (std.mem.startsWith(u8, line, "SCHEMA = ")) {
            schema = std.fmt.parseInt(u32, line["SCHEMA = ".len..], 10) catch null;
            if (schema == null) diag.add("{s}: `{s}` is not a number", .{ label, line });
        } else if (stringLine(line, "RUSTC")) |v| {
            rustc = v;
        } else if (stringLine(line, "TARGET")) |v| {
            target = v;
        } else if (stringLine(line, "CARGO_LOCK_SHA256")) |v| {
            lock_sha = v;
        } else if (std.mem.eql(u8, line, "MANIFEST_SHA256 = {")) {
            in_block = true;
            have_block = true;
        } else if (std.mem.startsWith(u8, line, "MANIFEST_SHA256 = ")) {
            diag.add("{s}: MANIFEST_SHA256 must be written one entry per line (regenerate with `buildrules sync`)", .{label});
        }
    }
    if (schema == null) {
        diag.add("{s}: no `SCHEMA = N` line: not a buildrules table; run `buildrules sync`", .{label});
    } else if (schema.? != contract.schema) {
        diag.add("{s}: SCHEMA = {d}, but this buildrules reads schema {d}: run `buildrules sync` with this version", .{ label, schema.?, contract.schema });
    }
    if (rustc == null) diag.add("{s}: no RUSTC line", .{label});
    if (target == null) diag.add("{s}: no TARGET line", .{label});
    if (lock_sha == null or !valid.isSha256(lock_sha.?)) diag.add("{s}: no valid CARGO_LOCK_SHA256 line", .{label});
    if (!have_block) diag.add("{s}: no MANIFEST_SHA256 block", .{label});
    if (in_block) diag.add("{s}: MANIFEST_SHA256 block is not closed", .{label});
    if (diag.count() != before) return error.Invalid;
    return .{ .schema = schema.?, .rustc = rustc.?, .target = target.?, .lock_sha256 = lock_sha.?, .manifests = manifests.toOwnedSlice(a) catch return error.Invalid };
}

/// The sha256 recorded for `path`, or null.
pub fn manifestHash(lock: Lock, path: []const u8) ?[]const u8 {
    for (lock.manifests) |m| if (std.mem.eql(u8, m.path, path)) return m.sha256;
    return null;
}

/// 1-based number of the first line where the two texts differ.
pub fn firstDifference(x: []const u8, y: []const u8) usize {
    var line: usize = 1;
    const n = @min(x.len, y.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (x[i] != y[i]) return line;
        if (x[i] == '\n') line += 1;
    }
    return line;
}
