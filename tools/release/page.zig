//! The page of a release on the site (RELEASING.md, "The release page"): one HTML file per release holding what a user pins: the tag, the commit
//! for `.buckconfig`, the archive's url and its sha256. A pure function of the verified release's facts, so the same release is the same page; the
//! release job uploads it as an artifact and nothing deploys it (the deploy of the site is held).
const std = @import("std");
const assets = @import("assets.zig");
const version = @import("version.zig");

pub const Facts = struct {
    /// `OWNER/NAME` of the repository.
    repo: []const u8,
    tag: []const u8,
    /// The commit the tag names, 40 hex.
    sha: []const u8,
    archive_name: []const u8,
    /// The 64-hex sha256 of the archive, from SHA256SUMS.
    sha256: []const u8,
};

pub const Error = error{ BadTag, BadSha, BadSums, BadRepo, WrongName };

fn isHex(s: []const u8, n: usize) bool {
    if (s.len != n) return false;
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

/// The digest of the line for `name` in a SHA256SUMS file (the format `assets.checkSumsFiles` accepts: a line per release file, here the source archive and
/// the three command-line tarballs). Every line must be well formed, `name` must appear once, and a file with no line for it is `WrongName`.
pub fn digestOf(sums: []const u8, name: []const u8) Error![]const u8 {
    if (!std.mem.endsWith(u8, sums, "\n")) return error.BadSums;
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, sums[0 .. sums.len - 1], '\n');
    while (lines.next()) |line| {
        if (line.len < 67) return error.BadSums;
        if (!isHex(line[0..64], 64) or !std.mem.eql(u8, line[64..66], "  ")) return error.BadSums;
        if (!std.mem.eql(u8, line[66..], name)) continue;
        if (found != null) return error.BadSums;
        found = line[0..64];
    }
    return found orelse error.WrongName;
}

fn escape(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '"' => try out.appendSlice(a, "&quot;"),
        else => try out.append(a, c),
    };
}

fn repoOk(s: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return false;
    if (slash == 0 or slash + 1 == s.len) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '/')) return false;
    }
    return std.mem.indexOfScalarPos(u8, s, slash + 1, '/') == null;
}

/// The page. The facts are checked first: a tag that is not a release, a commit or digest that is not hex, a repository that is not `owner/name`.
pub fn render(a: std.mem.Allocator, f: Facts) ![]u8 {
    const v = version.parseTag(f.tag) orelse return error.BadTag;
    if (!isHex(f.sha, 40)) return error.BadSha;
    if (!isHex(f.sha256, 64)) return error.BadSums;
    if (!repoOk(f.repo)) return error.BadRepo;
    const number = try version.numberText(a, v);
    const want_name = try std.fmt.allocPrint(a, "buildrules-{s}.tar.gz", .{number});
    if (!std.mem.eql(u8, want_name, f.archive_name)) return error.WrongName;

    const origin = try std.fmt.allocPrint(a, "https://github.com/{s}", .{f.repo});
    const url = try std.fmt.allocPrint(a, "{s}/releases/download/{s}/{s}", .{ origin, f.tag, f.archive_name });
    const buckconfig = try std.fmt.allocPrint(a, "[external_cells]\n  buildrules = git\n[external_cell_buildrules]\n  git_origin = {s}\n  commit_hash = {s}\n", .{ origin, f.sha });

    var o = std.ArrayList(u8).empty;
    try o.appendSlice(a, "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<title>buildrules ");
    try escape(a, &o, number);
    try o.appendSlice(a, "</title>\n</head>\n<body>\n<h1>buildrules ");
    try escape(a, &o, number);
    try o.appendSlice(a, "</h1>\n<p>Tag <code>");
    try escape(a, &o, f.tag);
    try o.appendSlice(a, "</code>, commit <code>");
    try escape(a, &o, f.sha);
    try o.appendSlice(a, "</code>. A release is a tag and a source archive; there are no binaries.</p>\n");
    try o.appendSlice(a, "<h2>Pin it in .buckconfig</h2>\n<pre><code>");
    try escape(a, &o, buckconfig);
    try o.appendSlice(a, "</code></pre>\n<h2>Or take the archive</h2>\n<p><a href=\"");
    try escape(a, &o, url);
    try o.appendSlice(a, "\">");
    try escape(a, &o, f.archive_name);
    try o.appendSlice(a, "</a></p>\n<p>sha256 <code>");
    try escape(a, &o, f.sha256);
    try o.appendSlice(a, "</code></p>\n<pre><code>");
    const check = try std.fmt.allocPrint(a, "sha256sum --check SHA256SUMS\ntar -xzf {s}\ngh attestation verify {s} --repo {s}\n", .{ f.archive_name, f.archive_name, f.repo });
    try escape(a, &o, check);
    try o.appendSlice(a, "</code></pre>\n</body>\n</html>\n");
    return o.toOwnedSlice(a);
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;

const facts = Facts{ .repo = "org/name", .tag = "v0.0.2", .sha = "a" ** 40, .archive_name = "buildrules-0.0.2.tar.gz", .sha256 = "b" ** 64 };

test "the page holds the tag, the commit, the archive url, its sha256 and the .buckconfig to pin" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const html = try render(a, facts);
    try t.expect(std.mem.indexOf(u8, html, "<title>buildrules 0.0.2</title>") != null);
    try t.expect(std.mem.indexOf(u8, html, "Tag <code>v0.0.2</code>, commit <code>" ++ "a" ** 40 ++ "</code>") != null);
    try t.expect(std.mem.indexOf(u8, html, "[external_cell_buildrules]\n  git_origin = https://github.com/org/name\n  commit_hash = " ++ "a" ** 40 ++ "\n") != null);
    try t.expect(std.mem.indexOf(u8, html, "href=\"https://github.com/org/name/releases/download/v0.0.2/buildrules-0.0.2.tar.gz\"") != null);
    try t.expect(std.mem.indexOf(u8, html, "sha256 <code>" ++ "b" ** 64 ++ "</code>") != null);
    try t.expect(std.mem.indexOf(u8, html, "sha256sum --check SHA256SUMS\ntar -xzf buildrules-0.0.2.tar.gz\n") != null);
    try t.expect(std.mem.indexOf(u8, html, "gh attestation verify buildrules-0.0.2.tar.gz --repo org/name") != null);
    // the same facts are the same page
    try t.expectEqualStrings(html, try render(a, facts));
    // a different release is a different page
    var other = facts;
    other.tag = "v0.0.3";
    other.archive_name = "buildrules-0.0.3.tar.gz";
    try t.expect(!std.mem.eql(u8, html, try render(a, other)));
}

test "facts that are not a release are refused, and the text is escaped" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = facts;
    f.tag = "v0.0";
    try t.expectError(error.BadTag, render(a, f));
    f = facts;
    f.sha = "A" ** 40;
    try t.expectError(error.BadSha, render(a, f));
    f.sha = "a" ** 39;
    try t.expectError(error.BadSha, render(a, f));
    f = facts;
    f.sha256 = "b" ** 63;
    try t.expectError(error.BadSums, render(a, f));
    f = facts;
    f.repo = "no-slash";
    try t.expectError(error.BadRepo, render(a, f));
    f.repo = "a/b\"><script>";
    try t.expectError(error.BadRepo, render(a, f));
    f = facts;
    f.archive_name = "buildrules-0.0.3.tar.gz";
    try t.expectError(error.WrongName, render(a, f));
    var out = std.ArrayList(u8).empty;
    try escape(a, &out, "<a href=\"x\">&</a>");
    try t.expectEqualStrings("&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;", out.items);
}

test "the digest is read from a SHA256SUMS of exactly one line for the archive" {
    const good = "c" ** 64 ++ "  buildrules-0.0.2.tar.gz\n";
    try t.expectEqualStrings("c" ** 64, try digestOf(good, "buildrules-0.0.2.tar.gz"));
    try t.expectError(error.WrongName, digestOf(good, "buildrules-0.0.3.tar.gz"));
    try t.expectError(error.BadSums, digestOf("c" ** 64 ++ "  buildrules-0.0.2.tar.gz", "buildrules-0.0.2.tar.gz"));
    try t.expectError(error.BadSums, digestOf(good ++ good, "buildrules-0.0.2.tar.gz"));
    try t.expectError(error.BadSums, digestOf("C" ** 64 ++ "  buildrules-0.0.2.tar.gz\n", "buildrules-0.0.2.tar.gz"));
    try t.expectError(error.BadSums, digestOf("c" ** 64 ++ " buildrules-0.0.2.tar.gz\n", "buildrules-0.0.2.tar.gz"));
    // it is the digest assets.checkSums accepts for those bytes
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sums = try assets.formatSums(a, "buildrules-0.0.2.tar.gz", "bytes");
    try assets.checkSums(sums, "buildrules-0.0.2.tar.gz", "bytes");
    try t.expectEqualSlices(u8, &assets.sha256Hex("bytes"), try digestOf(sums, "buildrules-0.0.2.tar.gz"));
}

test "digestOf reads the line of a four-line SHA256SUMS: the archive's digest, and no other file's" {
    // The defect: the one-line reader, which refuses the SHA256SUMS of a release that holds the command-line tarballs (the page job would fail every release),
    // or one that takes the first line whatever the name (the page would show a tarball's digest as the archive's).
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]assets.Named{
        .{ .name = "buildrules-0.0.2.tar.gz", .bytes = "source" },
        .{ .name = "buildrules-cli-0.0.2-linux-aarch64.tar.gz", .bytes = "a" },
        .{ .name = "buildrules-cli-0.0.2-linux-x86_64.tar.gz", .bytes = "b" },
        .{ .name = "buildrules-cli-0.0.2-macos-arm64.tar.gz", .bytes = "c" },
    };
    const sums = try assets.formatSumsFiles(a, &files);
    try t.expectEqualSlices(u8, &assets.sha256Hex("source"), try digestOf(sums, "buildrules-0.0.2.tar.gz"));
    try t.expectEqualSlices(u8, &assets.sha256Hex("c"), try digestOf(sums, "buildrules-cli-0.0.2-macos-arm64.tar.gz"));
    try t.expectError(error.WrongName, digestOf(sums, "buildrules-0.0.3.tar.gz"));
    // a malformed line anywhere is a bad file, even when the line asked for is fine
    const broken = try std.mem.concat(a, u8, &.{ sums, "not a sums line\n" });
    try t.expectError(error.BadSums, digestOf(broken, "buildrules-0.0.2.tar.gz"));
}
