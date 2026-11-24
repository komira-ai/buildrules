//! Git sources of Cargo.lock (docs/contract.md, "Git sources"). cargo writes a git dependency's `source` as
//! `git+<url>?<ref>#<commit>`: the URL as Cargo.toml wrote it, the reference Cargo.toml named (`rev=`, `branch=`, `tag=`, or
//! nothing for the default branch) and the commit cargo resolved. buildrules builds one from the GitHub archive of that commit,
//! so it takes only a source whose reference is the commit itself: `rev = "<40 hex>"` on github.com. A branch, a tag, the
//! default branch or a short rev names something that can move, and is refused with the reason and the fix.

const std = @import("std");

pub const Git = struct {
    /// `github.com/<owner>/<repo>`, without a `.git` suffix: the repository's name in the record file and in messages.
    repo: []const u8,
    owner: []const u8,
    /// The repository's own name (the URL's last segment, less `.git`).
    name: []const u8,
    /// The commit: 40 lower-case hex digits.
    rev: []const u8,
    /// The source up to `#`, as cargo wrote it: what a unit graph's `pkg_id` of the same package starts with.
    id: []const u8,
};

pub const Judged = union(enum) { ok: Git, bad: []const u8 };

pub const prefix = "git+";

pub fn isGit(source: []const u8) bool {
    return std.mem.startsWith(u8, source, prefix);
}

pub fn isRev(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// A GitHub owner: letters, digits and hyphens.
fn isOwner(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
    return true;
}

fn isNamePart(s: []const u8) bool {
    if (s.len == 0 or std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return true;
}

const pin_fix = "pin it by commit: `rev = \"<the 40-hex commit>\"` in Cargo.toml, then `buildrules sync`";

/// Judges a Cargo.lock `source` that starts with `git+`. A refusal's text says why and how to fix it; the caller prefixes the
/// package's name and version.
pub fn judge(a: std.mem.Allocator, source: []const u8) error{OutOfMemory}!Judged {
    const hash = std.mem.indexOfScalar(u8, source, '#') orelse
        return .{ .bad = try std.fmt.allocPrint(a, "the git source {s} has no resolved commit (`#<commit>`); let cargo write Cargo.lock", .{source}) };
    const id = source[0..hash];
    const commit = source[hash + 1 ..];
    const https = prefix ++ "https://";
    if (!std.mem.startsWith(u8, id, https)) {
        return .{ .bad = try std.fmt.allocPrint(a, "the git source {s} is not https: buildrules fetches the GitHub archive of a commit over https only", .{id}) };
    }
    const q = std.mem.indexOfScalar(u8, id, '?');
    const url = id[https.len .. q orelse id.len];
    const query = if (q) |i| id[i + 1 ..] else "";
    var parts = std.mem.splitScalar(u8, url, '/');
    const host = parts.next().?;
    const owner = parts.next() orelse "";
    var repo_part = parts.next() orelse "";
    const extra = parts.next();
    if (!std.mem.eql(u8, host, "github.com")) {
        return .{ .bad = try std.fmt.allocPrint(a, "the git source {s} is not on github.com: buildrules fetches a git dependency as the GitHub archive of its commit, so only github.com repositories are supported", .{id}) };
    }
    if (std.mem.endsWith(u8, repo_part, ".git")) repo_part = repo_part[0 .. repo_part.len - 4];
    if (!isOwner(owner) or !isNamePart(repo_part) or (extra != null and extra.?.len != 0) or parts.next() != null) {
        return .{ .bad = try std.fmt.allocPrint(a, "the git source {s} is not https://github.com/<owner>/<repository>", .{id}) };
    }
    if (query.len == 0) {
        return .{ .bad = try std.fmt.allocPrint(a, "the git source {s} follows the repository's default branch, which moves: {s}", .{ id, pin_fix }) };
    }
    if (std.mem.indexOfScalar(u8, query, '&') != null) {
        return .{ .bad = try std.fmt.allocPrint(a, "the git source {s} has more than one query parameter: {s}", .{ id, pin_fix }) };
    }
    const kinds = [_][2][]const u8{ .{ "branch=", "branch" }, .{ "tag=", "tag" }, .{ "ref=", "branch" } };
    for (kinds) |k| if (std.mem.startsWith(u8, query, k[0])) {
        return .{ .bad = try std.fmt.allocPrint(a, "the git source {s} follows {s} `{s}`, which can move: {s}", .{ id, k[1], query[k[0].len..], pin_fix }) };
    };
    if (!std.mem.startsWith(u8, query, "rev=")) {
        return .{ .bad = try std.fmt.allocPrint(a, "the git source {s} has an unknown reference `{s}`: {s}", .{ id, query, pin_fix }) };
    }
    const rev = query["rev=".len..];
    if (!isRev(rev)) {
        return .{ .bad = try std.fmt.allocPrint(a, "the git source {s} names rev `{s}`, which is not a full commit id (40 lower-case hex digits): {s}", .{ id, rev, pin_fix }) };
    }
    if (!std.mem.eql(u8, commit, rev)) {
        return .{ .bad = try std.fmt.allocPrint(a, "the git source {s} resolved to commit {s}, not to its rev: let cargo rewrite Cargo.lock", .{ id, commit }) };
    }
    return .{ .ok = .{
        .repo = try std.fmt.allocPrint(a, "github.com/{s}/{s}", .{ owner, repo_part }),
        .owner = owner,
        .name = repo_part,
        .rev = rev,
        .id = id,
    } };
}

/// The archive `crate_src` downloads: GitHub's tarball of the commit (its one top directory is `<name>-<rev>`).
pub fn archiveUrl(a: std.mem.Allocator, g: Git) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(a, "https://{s}/archive/{s}.tar.gz", .{ g.repo, g.rev });
}

/// The archive's file name in the directory of `buildrules sync --sources` (sources.zig): `<owner>_<repository>_<commit>.tar.gz`.
/// An owner has no `_`, so the first one ends it and two repositories never share a name.
pub fn archiveFile(a: std.mem.Allocator, g: Git) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(a, "{s}_{s}_{s}.tar.gz", .{ g.owner, g.name, g.rev });
}

/// `repo@rev`: one archive, shared by every crate of the repository at that commit.
pub fn key(a: std.mem.Allocator, repo: []const u8, rev: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(a, "{s}@{s}", .{ repo, rev });
}
