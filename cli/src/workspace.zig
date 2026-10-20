//! The root Cargo.toml, as far as buildrules reads it: is there a `[workspace]`, is the root a
//! package, and which directories are members. Not a TOML parser: only the `[workspace]` table's
//! `members` strings and the line forms cargo itself writes.

const std = @import("std");
const ctxm = @import("ctx.zig");
const Ctx = ctxm.Ctx;

pub const Section = struct { start: usize, end: usize };

/// The body of the `[workspace]` table (after its header line, up to the next table).
pub fn workspaceSection(text: []const u8) ?Section {
    var pos: usize = 0;
    var start: ?usize = null;
    while (pos < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, pos, '\n');
        const line_end = nl orelse text.len;
        const line = std.mem.trim(u8, text[pos..line_end], " \t\r");
        const next = if (nl) |n| n + 1 else text.len;
        if (start == null) {
            if (std.mem.eql(u8, line, "[workspace]")) start = next;
        } else if (line.len > 0 and line[0] == '[') {
            return .{ .start = start.?, .end = pos };
        }
        pos = next;
    }
    if (start) |s| return .{ .start = s, .end = text.len };
    return null;
}

/// Whether a line of exactly `want` (trimmed) is in `text`.
pub fn hasLine(text: []const u8, want: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (std.mem.eql(u8, std.mem.trim(u8, l, " \t\r"), want)) return true;
    return false;
}

/// The root is a package (has a `[package]` table), which v0 refuses at the workspace root.
pub fn isPackage(text: []const u8) bool {
    return hasLine(text, "[package]");
}

/// The quoted strings of `members = [ ... ]` in the `[workspace]` table, comments skipped.
pub fn memberPatterns(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    const sec = workspaceSection(text) orelse return out.toOwnedSlice(a);
    return memberPatternsFrom(a, text[sec.start..sec.end], &out);
}

fn memberPatternsFrom(a: std.mem.Allocator, body: []const u8, out: *std.ArrayList([]const u8)) ![]const []const u8 {
    // Find `members` at the start of a line, then the `[`.
    var at: ?usize = null;
    var pos: usize = 0;
    while (pos < body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, pos, '\n');
        const t = std.mem.trim(u8, body[pos .. nl orelse body.len], " \t\r");
        if (std.mem.startsWith(u8, t, "members")) {
            const rest = std.mem.trim(u8, t["members".len..], " \t");
            if (rest.len > 0 and rest[0] == '=') {
                at = pos;
                break;
            }
        }
        pos = if (nl) |n| n + 1 else body.len;
    }
    const start = at orelse return out.toOwnedSlice(a);
    var j = std.mem.indexOfScalarPos(u8, body, start, '[') orelse return out.toOwnedSlice(a);
    j += 1;
    var in_str = false;
    var in_comment = false;
    var str_start: usize = 0;
    while (j < body.len) : (j += 1) {
        const c = body[j];
        if (in_comment) {
            if (c == '\n') in_comment = false;
            continue;
        }
        if (in_str) {
            if (c == '"') {
                in_str = false;
                try out.append(a, body[str_start..j]);
            }
            continue;
        }
        switch (c) {
            '"' => {
                in_str = true;
                str_start = j + 1;
            },
            '#' => in_comment = true,
            ']' => break,
            else => {},
        }
    }
    return out.toOwnedSlice(a);
}

pub const Error = error{UnsupportedMemberPattern};

/// The member directories (relative to the repository root, sorted): each `members` entry that
/// is a path with a Cargo.toml, and each subdirectory with a Cargo.toml of a `dir/*` entry.
/// Any other glob is refused (v0).
pub fn memberDirs(ctx: *Ctx, root_manifest: []const u8) ![]const []const u8 {
    const a = ctx.a;
    var out = std.ArrayList([]const u8).empty;
    for (try memberPatterns(a, root_manifest)) |p| {
        if (std.mem.indexOfAny(u8, p, "*?[") == null) {
            const m = try std.fmt.allocPrint(a, "{s}/Cargo.toml", .{p});
            if (ctx.exists(m)) try out.append(a, p);
            continue;
        }
        if (!std.mem.endsWith(u8, p, "/*") or std.mem.indexOfAny(u8, p[0 .. p.len - 2], "*?[") != null) return error.UnsupportedMemberPattern;
        const parent = p[0 .. p.len - 2];
        var d = ctx.dir.openDir(parent, .{ .iterate = true }) catch continue;
        defer d.close();
        var it = d.iterate();
        while (try it.next()) |e| {
            if (e.kind != .directory) continue;
            const rel = try std.fmt.allocPrint(a, "{s}/{s}", .{ parent, e.name });
            const m = try std.fmt.allocPrint(a, "{s}/Cargo.toml", .{rel});
            if (ctx.exists(m)) try out.append(a, rel);
        }
    }
    std.mem.sort([]const u8, out.items, {}, lessStr);
    return out.toOwnedSlice(a);
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}
