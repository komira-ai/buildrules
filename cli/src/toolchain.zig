//! rust-toolchain.toml: the pinned compiler. Only the `channel` line is read;
//! `buildrules check` refuses a channel that is not an exact release, because
//! a floating one (`stable`, `1.95`) is a different compiler tomorrow.

const std = @import("std");

/// The value of `channel = "..."`, or null when there is no such line.
pub fn channel(text: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "channel")) continue;
        var rest = std.mem.trim(u8, line["channel".len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        rest = std.mem.trim(u8, rest[1..], " \t");
        if (rest.len < 2 or rest[0] != '"') return null;
        const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
        return rest[1..end];
    }
    return null;
}

/// `N.N.N`: digits, two dots, no suffix.
pub fn isExactRelease(s: []const u8) bool {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| : (n += 1) {
        if (part.len == 0 or part.len > 4) return false;
        for (part) |c| if (c < '0' or c > '9') return false;
    }
    return n == 3;
}

/// The first mopm release whose `plan --unit-graph` takes `--workspace-root DIR`: with it, every path of the graph is relative to DIR and the
/// package and its path dependencies may be siblings below it. `buildrules mojo sync` asks for it from that release on, and records that it did in
/// the table (`MOPM = {..., "workspace_root": true}`), which is what the rules read: they never compare versions themselves.
pub const workspace_root_since = [3]u32{ 0, 0, 26 };

/// Whether mopm `version` (an exact release `N.N.N`) takes `--workspace-root`; a version that is not an exact release does not.
pub fn supportsWorkspaceRoot(version: []const u8) bool {
    if (!isExactRelease(version)) return false;
    var it = std.mem.splitScalar(u8, version, '.');
    var k: usize = 0;
    while (it.next()) |part| : (k += 1) {
        // (digits only, at most four: `isExactRelease`)
        var n: u32 = 0;
        for (part) |c| n = n * 10 + (c - '0');
        if (n != workspace_root_since[k]) return n > workspace_root_since[k];
    }
    return true;
}

pub const Verdict = union(enum) {
    ok: []const u8,
    /// A message for the user.
    bad: []const u8,
};

/// What `rust-toolchain.toml` (`text`, null when absent) pins.
pub fn judge(text: ?[]const u8) Verdict {
    const t = text orelse return .{ .bad = "rust-toolchain.toml is missing: pin the compiler with an exact release (`buildrules init` writes one)" };
    const ch = channel(t) orelse return .{ .bad = "rust-toolchain.toml has no `channel = \"N.N.N\"` line" };
    if (!isExactRelease(ch)) return .{ .bad = "rust-toolchain.toml: channel is not an exact release (N.N.N): a floating channel names a different compiler tomorrow" };
    var it = std.mem.splitScalar(u8, t, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "path") and std.mem.trim(u8, line["path".len..], " \t").len > 0 and std.mem.trim(u8, line["path".len..], " \t")[0] == '=') {
            return .{ .bad = "rust-toolchain.toml: `path` names a toolchain on this machine; buildrules pins the compiler by hash, so only `channel` is allowed" };
        }
    }
    return .{ .ok = ch };
}
