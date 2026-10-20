//! What a release holds and how it is checked, as pure functions of text and bytes: the SHA256SUMS file, the comparison of an archive's file
//! list with the tracked files of the tag, what the publish job does about a release that already exists, and the release notes.
const std = @import("std");
const tar = @import("tar.zig");

pub const Findings = std.ArrayList([]const u8);

pub fn add(a: std.mem.Allocator, f: *Findings, comptime fmt: []const u8, args: anytype) !void {
    try f.append(a, try std.fmt.allocPrint(a, fmt, args));
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &h, .{});
    return std.fmt.bytesToHex(h, .lower);
}

// ---- SHA256SUMS -------------------------------------------------------------------------------------------------------------------------

/// The SHA256SUMS file for one file: `<64 hex>  <name>\n` (the format `sha256sum --check` reads).
pub fn formatSums(a: std.mem.Allocator, name: []const u8, bytes: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}  {s}\n", .{ sha256Hex(bytes), name });
}

pub const SumsError = error{ BadSums, WrongName, WrongDigest };

fn isLowerHex(s: []const u8) bool {
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

/// `sums` is exactly one line, for `name`, with the sha256 of `bytes`. A second line, a missing newline, an uppercase digest, one space
/// between digest and name (or the binary-mode `*`), another file name or another digest is refused.
pub fn checkSums(sums: []const u8, name: []const u8, bytes: []const u8) SumsError!void {
    if (!std.mem.endsWith(u8, sums, "\n")) return error.BadSums;
    const line = sums[0 .. sums.len - 1];
    if (std.mem.indexOfScalar(u8, line, '\n') != null) return error.BadSums;
    if (line.len < 64 + 2 + 1) return error.BadSums;
    const digest = line[0..64];
    if (!isLowerHex(digest)) return error.BadSums;
    if (!std.mem.eql(u8, line[64..66], "  ")) return error.BadSums;
    if (!std.mem.eql(u8, line[66..], name)) return error.WrongName;
    const want = sha256Hex(bytes);
    if (!std.mem.eql(u8, digest, &want)) return error.WrongDigest;
}

// ---- the archive's files against the tag's ----------------------------------------------------------------------------------------------

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// Findings when the files of the archive (`entries`, each under `prefix`, e.g. `buildrules-0.0.1/`) are not exactly `expected` (the
/// tracked files of the tag, `git ls-tree -r --name-only`): a file missing, a file that is not tracked, a path twice, an entry that is
/// neither a file, a symlink nor a directory, or an entry outside the prefix. Directories are implied by their files and not compared.
pub fn compareFileLists(a: std.mem.Allocator, f: *Findings, entries: []const tar.Entry, prefix: []const u8, expected: []const []const u8) !void {
    var got = std.ArrayList([]const u8).empty;
    const root = std.mem.trimRight(u8, prefix, "/");
    for (entries) |e| {
        if (std.mem.eql(u8, e.name, root) and e.kind == .dir) continue;
        if (!std.mem.startsWith(u8, e.name, prefix)) {
            try add(a, f, "the archive holds {s}, which is outside {s}", .{ e.name, prefix });
            continue;
        }
        switch (e.kind) {
            .dir => continue,
            .other => {
                try add(a, f, "the archive holds {s}, which is neither a file, a symlink nor a directory", .{e.name});
                continue;
            },
            else => try got.append(a, e.name[prefix.len..]),
        }
    }
    std.mem.sort([]const u8, got.items, {}, lessThan);
    const want = try a.dupe([]const u8, expected);
    std.mem.sort([]const u8, want, {}, lessThan);
    var i: usize = 1;
    while (i < got.items.len) : (i += 1) {
        if (std.mem.eql(u8, got.items[i], got.items[i - 1])) try add(a, f, "the archive holds {s} twice", .{got.items[i]});
    }
    var shown: usize = 0;
    var x: usize = 0;
    var y: usize = 0;
    while (x < got.items.len or y < want.len) {
        const order: std.math.Order = if (x == got.items.len) .gt else if (y == want.len) .lt else std.mem.order(u8, got.items[x], want[y]);
        switch (order) {
            .eq => {
                x += 1;
                y += 1;
            },
            .lt => {
                if (shown < 10) try add(a, f, "the archive holds {s}, which the tag does not track", .{got.items[x]});
                shown += 1;
                x += 1;
            },
            .gt => {
                if (shown < 10) try add(a, f, "the archive lacks {s}, which the tag tracks", .{want[y]});
                shown += 1;
                y += 1;
            },
        }
    }
    if (shown > 10) try add(a, f, "and {d} more differences", .{shown - 10});
}

// ---- a release that already exists ------------------------------------------------------------------------------------------------------

pub const Asset = struct {
    name: []const u8,
    /// The sha256 GitHub reports for the asset, hex; null when it reports none.
    sha256: ?[]const u8,
};

pub const File = struct { name: []const u8, sha256: []const u8 };

pub const Plan = union(enum) {
    /// No release for the tag: create it with every file.
    create,
    /// The release exists and holds some of the files: add the others (never replace one).
    upload: []const []const u8,
    /// The release exists and holds every file, byte for byte.
    nothing,
};

pub const PlanError = error{ AssetDiffers, AssetDigestUnknown, OutOfMemory };

/// What the publish job does. `existing` is null when no release has the tag. A file the release already holds must be the same bytes
/// (its reported digest equals ours) or the job fails and changes nothing: no asset is replaced, and a digest GitHub does not report is
/// not taken to match.
pub fn publishPlan(a: std.mem.Allocator, existing: ?[]const Asset, ours: []const File) PlanError!Plan {
    const have = existing orelse return .create;
    var missing = std.ArrayList([]const u8).empty;
    for (ours) |o| {
        var found: ?Asset = null;
        for (have) |h| {
            if (std.mem.eql(u8, h.name, o.name)) found = h;
        }
        const h = found orelse {
            try missing.append(a, o.name);
            continue;
        };
        const d = h.sha256 orelse return error.AssetDigestUnknown;
        if (!std.mem.eql(u8, d, o.sha256)) return error.AssetDiffers;
    }
    if (missing.items.len == 0) return .nothing;
    return .{ .upload = try missing.toOwnedSlice(a) };
}

/// The assets of `GET /repos/{repo}/releases/tags/{tag}` (its `assets[].name` and `assets[].digest`, `sha256:<hex>`).
pub fn parseAssets(a: std.mem.Allocator, json: []const u8) ![]Asset {
    const Doc = struct { assets: []const struct { name: []const u8, digest: ?[]const u8 = null } = &.{} };
    const parsed = try std.json.parseFromSlice(Doc, a, json, .{ .ignore_unknown_fields = true });
    var out = std.ArrayList(Asset).empty;
    for (parsed.value.assets) |x| {
        var d: ?[]const u8 = null;
        if (x.digest) |s| {
            if (std.mem.startsWith(u8, s, "sha256:")) d = s["sha256:".len..];
        }
        try out.append(a, .{ .name = x.name, .sha256 = d });
    }
    return out.toOwnedSlice(a);
}

// ---- the notes --------------------------------------------------------------------------------------------------------------------------

pub const max_subjects = 100;

pub const NotesArgs = struct {
    /// `0.0.2`
    number: []const u8,
    /// `v0.0.2`
    tag: []const u8,
    /// `owner/name`
    repo: []const u8,
    sha: []const u8,
    /// The tag of the previous release, or null for the first.
    previous: ?[]const u8,
    /// The commit subjects since the previous tag, newest first.
    subjects: []const []const u8,
    archive: []const u8,
    archive_sha256: []const u8,
};

/// A subject as one line of text: control characters become spaces and the ends are trimmed. Empty after that: null.
fn cleanSubject(a: std.mem.Allocator, s: []const u8) !?[]u8 {
    const buf = try a.dupe(u8, s);
    for (buf) |*c| {
        if (c.* < 0x20 or c.* == 0x7f) c.* = ' ';
    }
    const trimmed = std.mem.trim(u8, buf, " ");
    if (trimmed.len == 0) return null;
    return try a.dupe(u8, trimmed);
}

/// The text of the release: what it is, how to pin it, and the commit subjects since the previous tag.
pub fn notes(a: std.mem.Allocator, n: NotesArgs) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.print(a, "buildrules {s}: the source of commit {s}.\n\n", .{ n.number, n.sha });
    try out.print(a, "Pin the tag `{s}` and the sha256 of the archive:\n\n", .{n.tag});
    try out.print(a, "- archive: https://github.com/{s}/releases/download/{s}/{s}\n", .{ n.repo, n.tag, n.archive });
    try out.print(a, "- sha256: `{s}`\n", .{n.archive_sha256});
    try out.print(a, "- the archive and SHA256SUMS carry build provenance attestations: `gh attestation verify {s} --repo {s}`\n\n", .{ n.archive, n.repo });
    if (n.previous) |p| {
        try out.print(a, "Changes since {s}:\n\n", .{p});
    } else {
        try out.print(a, "This is the first release. Changes:\n\n", .{});
    }
    var shown: usize = 0;
    var total: usize = 0;
    for (n.subjects) |s| {
        const c = (try cleanSubject(a, s)) orelse continue;
        total += 1;
        if (shown < max_subjects) {
            try out.print(a, "- {s}\n", .{c});
            shown += 1;
        }
    }
    if (total == 0) try out.print(a, "- no commit subjects\n", .{});
    if (total > shown) try out.print(a, "- and {d} earlier commits\n", .{total - shown});
    return out.toOwnedSlice(a);
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;

test "SHA256SUMS: the format sha256sum reads, and what checkSums refuses" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sums = try formatSums(a, "buildrules-0.0.1.tar.gz", "abc");
    // the sha256 of "abc" is a published test vector
    try t.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  buildrules-0.0.1.tar.gz\n", sums);
    try checkSums(sums, "buildrules-0.0.1.tar.gz", "abc");
    try t.expectError(error.WrongDigest, checkSums(sums, "buildrules-0.0.1.tar.gz", "abd"));
    try t.expectError(error.WrongName, checkSums(sums, "buildrules-0.0.2.tar.gz", "abc"));
    try t.expectError(error.BadSums, checkSums(sums[0 .. sums.len - 1], "buildrules-0.0.1.tar.gz", "abc"));
    try t.expectError(error.BadSums, checkSums("", "x", "abc"));
    // two lines, one space, binary-mode star, uppercase, a short digest
    try t.expectError(error.BadSums, checkSums(try std.mem.concat(a, u8, &.{ sums, sums }), "buildrules-0.0.1.tar.gz", "abc"));
    const one_space = try std.mem.replaceOwned(u8, a, sums, "  buildrules", " buildrules");
    try t.expectError(error.BadSums, checkSums(one_space, "buildrules-0.0.1.tar.gz", "abc"));
    const star = try std.mem.replaceOwned(u8, a, sums, "  buildrules", " *buildrules");
    try t.expectError(error.BadSums, checkSums(star, "buildrules-0.0.1.tar.gz", "abc"));
    const upper = try std.ascii.allocUpperString(a, sums[0..64]);
    try t.expectError(error.BadSums, checkSums(try std.mem.concat(a, u8, &.{ upper, sums[64..] }), "buildrules-0.0.1.tar.gz", "abc"));
    try t.expectError(error.BadSums, checkSums("abc  buildrules-0.0.1.tar.gz\n", "buildrules-0.0.1.tar.gz", "abc"));
}

fn entry(name: []const u8, kind: tar.Kind) tar.Entry {
    return .{ .name = name, .kind = kind, .data = "" };
}

fn expectFindings(a: std.mem.Allocator, entries: []const tar.Entry, expected: []const []const u8, needles: []const []const u8) !void {
    var f = Findings.empty;
    try compareFileLists(a, &f, entries, "buildrules-0.0.1/", expected);
    for (needles) |nd| {
        var hit = false;
        for (f.items) |m| {
            if (std.mem.indexOf(u8, m, nd) != null) hit = true;
        }
        if (!hit) {
            std.debug.print("no finding with `{s}`; got:\n", .{nd});
            for (f.items) |m| std.debug.print("  {s}\n", .{m});
            return error.MutantSurvived;
        }
    }
    if (needles.len == 0 and f.items.len != 0) {
        for (f.items) |m| std.debug.print("unexpected: {s}\n", .{m});
        return error.UnexpectedFinding;
    }
}

test "the archive's files are the tag's tracked files, exactly" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = [_]tar.Entry{
        entry("buildrules-0.0.1", .dir),
        entry("buildrules-0.0.1/BUCK", .file),
        entry("buildrules-0.0.1/rules", .dir),
        entry("buildrules-0.0.1/rules/zig.bzl", .file),
        entry("buildrules-0.0.1/link", .symlink),
    };
    const tracked = [_][]const u8{ "rules/zig.bzl", "link", "BUCK" };
    try expectFindings(a, &good, &tracked, &.{});
    // a file the tag tracks is missing, a file it does not track is present, the same path twice
    try expectFindings(a, good[0..4], &tracked, &.{"lacks link"});
    try expectFindings(a, &good, &.{ "BUCK", "link" }, &.{"holds rules/zig.bzl, which the tag does not track"});
    try expectFindings(a, &(good ++ [_]tar.Entry{entry("buildrules-0.0.1/BUCK", .file)}), &tracked, &.{"BUCK twice"});
    // a path outside the prefix, even one that starts like it; a hard link or device
    try expectFindings(a, &(good ++ [_]tar.Entry{entry("buildrules-0.0.10/x", .file)}), &tracked, &.{"outside buildrules-0.0.1/"});
    try expectFindings(a, &(good ++ [_]tar.Entry{entry("other/x", .file)}), &tracked, &.{"outside"});
    try expectFindings(a, &(good ++ [_]tar.Entry{entry("buildrules-0.0.1/dev", .other)}), &tracked, &.{"neither a file"});
    // a different case or a different spelling is a different file
    try expectFindings(a, &good, &.{ "rules/Zig.bzl", "link", "BUCK" }, &.{ "lacks rules/Zig.bzl", "holds rules/zig.bzl" });
}

test "a long list of differences is cut, with a count" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var names = std.ArrayList([]const u8).empty;
    for (0..30) |i| try names.append(a, try std.fmt.allocPrint(a, "f{d:0>3}", .{i}));
    try expectFindings(a, &.{entry("buildrules-0.0.1", .dir)}, names.items, &.{ "lacks f000", "and 20 more differences" });
}

test "a release that exists is never changed: same bytes, a missing file added, a different file refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ours = [_]File{ .{ .name = "x.tar.gz", .sha256 = "aa" }, .{ .name = "SHA256SUMS", .sha256 = "bb" } };
    try t.expect((try publishPlan(a, null, &ours)) == .create);
    try t.expect((try publishPlan(a, &.{ .{ .name = "x.tar.gz", .sha256 = "aa" }, .{ .name = "SHA256SUMS", .sha256 = "bb" } }, &ours)) == .nothing);
    // extra assets someone added are left alone
    try t.expect((try publishPlan(a, &.{ .{ .name = "x.tar.gz", .sha256 = "aa" }, .{ .name = "SHA256SUMS", .sha256 = "bb" }, .{ .name = "other", .sha256 = null } }, &ours)) == .nothing);
    const up = try publishPlan(a, &.{.{ .name = "x.tar.gz", .sha256 = "aa" }}, &ours);
    try t.expectEqual(@as(usize, 1), up.upload.len);
    try t.expectEqualStrings("SHA256SUMS", up.upload[0]);
    const all = try publishPlan(a, &.{}, &ours);
    try t.expectEqual(@as(usize, 2), all.upload.len);
    try t.expectError(error.AssetDiffers, publishPlan(a, &.{ .{ .name = "x.tar.gz", .sha256 = "ab" }, .{ .name = "SHA256SUMS", .sha256 = "bb" } }, &ours));
    try t.expectError(error.AssetDiffers, publishPlan(a, &.{.{ .name = "SHA256SUMS", .sha256 = "ff" }}, &ours));
    try t.expectError(error.AssetDigestUnknown, publishPlan(a, &.{.{ .name = "x.tar.gz", .sha256 = null }}, &ours));
}

test "the assets of a release come from the API's name and digest" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{"id": 1, "tag_name": "v0.0.1", "assets": [
        \\ {"name": "buildrules-0.0.1.tar.gz", "size": 10, "digest": "sha256:aabb"},
        \\ {"name": "SHA256SUMS", "digest": null},
        \\ {"name": "odd", "digest": "sha1:cc"}]}
    ;
    const xs = try parseAssets(a, json);
    try t.expectEqual(@as(usize, 3), xs.len);
    try t.expectEqualStrings("aabb", xs[0].sha256.?);
    try t.expect(xs[1].sha256 == null);
    try t.expect(xs[2].sha256 == null);
    try t.expectEqual(@as(usize, 0), (try parseAssets(a, "{\"id\": 1}")).len);
}

test "the notes pin the tag and the hash, and list the subjects since the previous tag" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try notes(a, .{
        .number = "0.0.2",
        .tag = "v0.0.2",
        .repo = "owner/name",
        .sha = "0123456789abcdef0123456789abcdef01234567",
        .previous = "v0.0.1",
        .subjects = &.{ "rules: pin a thing", "  ", "ci: check\tthe thing\r", "" },
        .archive = "buildrules-0.0.2.tar.gz",
        .archive_sha256 = "ab" ** 32,
    });
    try t.expect(std.mem.indexOf(u8, text, "buildrules 0.0.2: the source of commit 0123456789abcdef0123456789abcdef01234567.") != null);
    try t.expect(std.mem.indexOf(u8, text, "https://github.com/owner/name/releases/download/v0.0.2/buildrules-0.0.2.tar.gz") != null);
    try t.expect(std.mem.indexOf(u8, text, "sha256: `" ++ "ab" ** 32 ++ "`") != null);
    try t.expect(std.mem.indexOf(u8, text, "Changes since v0.0.1:\n\n- rules: pin a thing\n- ci: check the thing\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "gh attestation verify buildrules-0.0.2.tar.gz --repo owner/name") != null);
}

test "the first release and an empty range say so; a long range is cut" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = NotesArgs{ .number = "0.0.1", .tag = "v0.0.1", .repo = "o/n", .sha = "s", .previous = null, .subjects = &.{}, .archive = "a", .archive_sha256 = "h" };
    const first = try notes(a, base);
    try t.expect(std.mem.indexOf(u8, first, "This is the first release.") != null);
    try t.expect(std.mem.indexOf(u8, first, "- no commit subjects") != null);
    var subjects = std.ArrayList([]const u8).empty;
    for (0..130) |i| try subjects.append(a, try std.fmt.allocPrint(a, "commit {d}", .{i}));
    var many = base;
    many.subjects = subjects.items;
    const long = try notes(a, many);
    try t.expect(std.mem.indexOf(u8, long, "- commit 99\n") != null);
    try t.expect(std.mem.indexOf(u8, long, "- commit 100\n") == null);
    try t.expect(std.mem.indexOf(u8, long, "- and 30 earlier commits\n") != null);
}
