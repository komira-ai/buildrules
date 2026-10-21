//! `manifest.json` of an autopin artifact: `{"pr": N, "head_sha": "...", "base_sha": "...", "files": [{"path": "...", "sha256": "..."}]}`.
//! The compute job writes it; the commit job reads it as untrusted bytes. Strict: a key twice, an unknown
//! key, a missing key, a `pr` that is not a JSON integer, a path that is not an exact output of a SETS
//! directory, and a file twice are all refused. The path is used only to match a member of the artifact; the
//! path a file is WRITTEN to comes from SETS, never from here.

const std = @import("std");
const json = @import("autopin_json.zig");
const sets_mod = @import("autopin_sets.zig");
const zip = @import("autopin_zip.zig");
const ctxm = @import("ctx.zig");
const valid = @import("valid.zig");

pub const max_bytes = 64 * 1024;
pub const max_files = 11;
pub const max_pr: i64 = 999_999_999;

pub const File = struct { path: []const u8, sha256: []const u8 };

pub const Manifest = struct {
    pr: u64,
    head_sha: []const u8,
    base_sha: []const u8,
    files: []const File,
};

pub const Error = error{
    TooLarge,
    NotJson,
    NotAnObject,
    DuplicateKey,
    UnknownKey,
    MissingKey,
    PrNotInteger,
    PrOutOfRange,
    BadSha,
    BadFiles,
    BadFileEntry,
    PathNotInSets,
    DuplicatePath,
    OutOfMemory,
};

fn isSha1(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

/// Exactly these keys, each once. Returns the member values in the order of `keys`.
fn exactKeys(v: json.Value, comptime keys: []const []const u8) Error![keys.len]json.Value {
    if (v != .object) return error.NotAnObject;
    var out: [keys.len]json.Value = undefined;
    var seen = [_]bool{false} ** keys.len;
    for (v.object) |m| {
        var known = false;
        inline for (keys, 0..) |k, i| {
            if (std.mem.eql(u8, m.key, k)) {
                known = true;
                seen[i] = true;
                out[i] = m.value;
            }
        }
        if (!known) return error.UnknownKey;
    }
    for (seen) |s| if (!s) return error.MissingKey;
    return out;
}

pub fn parse(a: std.mem.Allocator, text: []const u8, sets: sets_mod.Sets) Error!Manifest {
    if (text.len > max_bytes) return error.TooLarge;
    const root = json.parse(a, text) catch |e| switch (e) {
        error.DuplicateKey => return error.DuplicateKey,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotJson,
    };
    const top = try exactKeys(root, &.{ "pr", "head_sha", "base_sha", "files" });
    if (top[0] != .int) return error.PrNotInteger;
    if (top[0].int < 1 or top[0].int > max_pr) return error.PrOutOfRange;
    if (top[1] != .string or !isSha1(top[1].string)) return error.BadSha;
    if (top[2] != .string or !isSha1(top[2].string)) return error.BadSha;
    if (top[3] != .array or top[3].array.len > max_files) return error.BadFiles;
    var files = std.ArrayList(File).empty;
    for (top[3].array) |entry| {
        const f = try exactKeys(entry, &.{ "path", "sha256" });
        if (f[0] != .string or f[1] != .string or !valid.isSha256(f[1].string)) return error.BadFileEntry;
        const idx = try sets.outputIndex(a, f[0].string);
        if (idx == null) return error.PathNotInSets;
        for (files.items) |have| if (std.mem.eql(u8, have.path, f[0].string)) return error.DuplicatePath;
        try files.append(a, .{ .path = f[0].string, .sha256 = f[1].string });
    }
    return .{ .pr = @intCast(top[0].int), .head_sha = top[1].string, .base_sha = top[2].string, .files = files.items };
}

/// The manifest as the compute job writes it (the text `parse` reads back).
pub fn render(a: std.mem.Allocator, m: Manifest) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.print(a, "{{\"pr\":{d},\"head_sha\":\"{s}\",\"base_sha\":\"{s}\",\"files\":[", .{ m.pr, m.head_sha, m.base_sha });
    for (m.files, 0..) |f, i| {
        if (i > 0) try buf.append(a, ',');
        try buf.print(a, "{{\"path\":\"{s}\",\"sha256\":\"{s}\"}}", .{ f.path, f.sha256 });
    }
    try buf.appendSlice(a, "]}\n");
    return buf.items;
}

/// One file of the artifact after it has been matched to the manifest and to SETS.
pub const Member = struct {
    /// Index into `Sets.items`: the directory this table belongs to. The path to WRITE is built from it.
    set: usize,
    /// The path in the artifact (equal to the table output of that set).
    path: []const u8,
    bytes: []const u8,
};

pub const MatchError = error{ NoManifest, MemberNotListed, ListedFileMissing, Sha256Mismatch, MemberNotInSets, OutOfMemory };

/// The text of `manifest.json` in the artifact's members.
pub fn manifestText(entries: []const zip.Entry) error{NoManifest}![]const u8 {
    for (entries) |e| if (std.mem.eql(u8, e.name, "manifest.json")) return e.data;
    return error.NoManifest;
}

/// Pairs the members with the manifest: every member but `manifest.json` is listed in `m.files` under its exact
/// name and holds the bytes whose sha256 the manifest states (transfer integrity, nothing more), and every listed
/// file is a member. The path of a member must be the table output of a SETS directory.
pub fn members(a: std.mem.Allocator, m: Manifest, entries: []const zip.Entry, sets: sets_mod.Sets) MatchError![]Member {
    var out = std.ArrayList(Member).empty;
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, "manifest.json")) continue;
        var listed: ?File = null;
        for (m.files) |f| if (std.mem.eql(u8, f.path, e.name)) {
            listed = f;
        };
        const f = listed orelse return error.MemberNotListed;
        const idx = (try sets.outputIndex(a, e.name)) orelse return error.MemberNotInSets;
        const digest = try ctxm.sha256Hex(a, e.data);
        if (!std.mem.eql(u8, digest, f.sha256)) return error.Sha256Mismatch;
        try out.append(a, .{ .set = idx, .path = e.name, .bytes = e.data });
    }
    for (m.files) |f| {
        var found = false;
        for (entries) |e| if (std.mem.eql(u8, e.name, f.path)) {
            found = true;
        };
        if (!found) return error.ListedFileMissing;
    }
    return out.items;
}
