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

pub const Named = struct { name: []const u8, bytes: []const u8 };

pub const SumsFilesError = SumsError || error{ MissingLine, TwoLines, NotSorted };

fn nameLess(_: void, x: Named, y: Named) bool {
    return std.mem.lessThan(u8, x.name, y.name);
}

/// The text of SHA256SUMS for `files`: one `<64 hex>  <name>\n` line per file, in name order (byte order, as `sha256sum` lists a sorted glob).
pub fn formatSumsFiles(a: std.mem.Allocator, files: []const Named) ![]u8 {
    const sorted = try a.dupe(Named, files);
    std.mem.sort(Named, sorted, {}, nameLess);
    var out = std.ArrayList(u8).empty;
    for (sorted) |f| try out.print(a, "{s}  {s}\n", .{ sha256Hex(f.bytes), f.name });
    return out.toOwnedSlice(a);
}

/// `sums` is exactly the SHA256SUMS of `files`: one line for each, in name order, nothing else. A missing line, a second line for a file, a line for a file that
/// is not one of them, a wrong digest, a line out of order, a missing newline, an uppercase digest, one space between digest and name or any other shape is
/// refused (the one-line `checkSums` is this for one file).
pub fn checkSumsFiles(sums: []const u8, files: []const Named) SumsFilesError!void {
    if (sums.len == 0 or !std.mem.endsWith(u8, sums, "\n")) return error.BadSums;
    var seen: usize = 0;
    var previous: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, sums[0 .. sums.len - 1], '\n');
    while (lines.next()) |line| {
        if (line.len < 64 + 2 + 1) return error.BadSums;
        const digest = line[0..64];
        if (!isLowerHex(digest) or !std.mem.eql(u8, line[64..66], "  ")) return error.BadSums;
        const name = line[66..];
        var found: ?Named = null;
        for (files) |f| {
            if (std.mem.eql(u8, f.name, name)) found = f;
        }
        const f = found orelse return error.WrongName;
        if (previous) |p| {
            if (std.mem.eql(u8, p, name)) return error.TwoLines;
            if (!std.mem.lessThan(u8, p, name)) return error.NotSorted;
        }
        previous = name;
        const want = sha256Hex(f.bytes);
        if (!std.mem.eql(u8, digest, &want)) return error.WrongDigest;
        seen += 1;
    }
    if (seen != files.len) return error.MissingLine;
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

/// The end of the name of a Sigstore bundle: `<file>.sigstore.json` is the signature of `<file>`.
pub const bundle_suffix = ".sigstore.json";

/// The digest the release reports for `name`, or null when the release holds no such asset or reports no digest.
pub fn heldDigest(have: []const Asset, name: []const u8) ?[]const u8 {
    for (have) |h| {
        if (std.mem.eql(u8, h.name, name)) return h.sha256;
    }
    return null;
}

/// True when `o` is a signature bundle that differs from the held one only because every signing makes a new one (a fresh certificate and a
/// new transparency-log entry), which is so when the file it signs is held with exactly our bytes: the held bundle then already signs the
/// bytes we have, and is kept. A bundle whose file is missing, unreported or different is a real difference.
fn bundleOfSameBytes(have: []const Asset, ours: []const File, o: File) bool {
    if (!std.mem.endsWith(u8, o.name, bundle_suffix)) return false;
    const signed = o.name[0 .. o.name.len - bundle_suffix.len];
    const held = heldDigest(have, signed) orelse return false;
    for (ours) |f| {
        if (std.mem.eql(u8, f.name, signed)) return std.mem.eql(u8, f.sha256, held);
    }
    return false;
}

/// What the publish job does. `existing` is null when no release has the tag. A file the release already holds must be the same bytes
/// (its reported digest equals ours) or the job fails and changes nothing: no asset is replaced, and a digest GitHub does not report is
/// not taken to match. The one exception is a signature bundle (`bundleOfSameBytes`): signing the same bytes again gives other bundle bytes,
/// so a re-run of a released commit keeps the bundle the release holds instead of failing.
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
        if (!std.mem.eql(u8, d, o.sha256) and !bundleOfSameBytes(have, ours, o)) return error.AssetDiffers;
    }
    if (missing.items.len == 0) return .nothing;
    return .{ .upload = try missing.toOwnedSlice(a) };
}

/// True when the release already holds every one of `expected`, byte for byte: what `publishPlan` calls `.nothing`, so the plan step and the publish step
/// judge a release by one rule. No release, a missing file, a different digest and a digest GitHub does not report are all false (the build then runs, and
/// publish decides what to add or refuse). So is an error of any kind, running out of memory included: not knowing costs a build, never a skipped release.
pub fn releaseHolds(a: std.mem.Allocator, existing: ?[]const Asset, expected: []const File) bool {
    const doing = publishPlan(a, existing, expected) catch return false;
    return doing == .nothing;
}

/// The assets of `GET /repos/{repo}/releases/tags/{tag}`(its `assets[].name` and `assets[].digest`, `sha256:<hex>`).
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
    /// The command-line tarballs of the release, with their sha256, in the order to show.
    binaries: []const Binary = &.{},
    /// The Debian packages of the release, with their sha256, in the order to show.
    debs: []const Binary = &.{},
};

pub const Binary = struct { name: []const u8, sha256: []const u8 };

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
    if (n.binaries.len != 0) {
        try out.print(a, "- the command line, one static tarball per platform (`buildrules` and `LICENSE` in a directory of the tarball's name):\n", .{});
        for (n.binaries) |b| try out.print(a, "  - https://github.com/{s}/releases/download/{s}/{s} sha256 `{s}`\n", .{ n.repo, n.tag, b.name, b.sha256 });
    }
    if (n.debs.len != 0) {
        try out.print(a, "- the command line as a Debian package, one static package per architecture (`buildrules` in `/usr/bin`):\n", .{});
        for (n.debs) |b| try out.print(a, "  - https://github.com/{s}/releases/download/{s}/{s} sha256 `{s}`\n", .{ n.repo, n.tag, b.name, b.sha256 });
    }
    try out.print(a, "- SHA256SUMS lists every file above; each file and SHA256SUMS carries a build provenance attestation (`gh attestation verify {s} --repo {s}`)", .{ n.archive, n.repo });
    if (n.binaries.len != 0) try out.print(a, " and a keyless signature `<file>.sigstore.json` (`cosign verify-blob --bundle {s}.sigstore.json --certificate-identity https://github.com/{s}/.github/workflows/release.yml@refs/heads/main --certificate-oidc-issuer https://token.actions.githubusercontent.com {s}`)", .{ n.archive, n.repo, n.archive });
    try out.print(a, "\n\n", .{});
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
            return error.DefectSurvived;
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

test "releaseHolds: true only when the release has every file with the expected digest" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ours = [_]File{ .{ .name = "x.tar.gz", .sha256 = "aa" }, .{ .name = "SHA256SUMS", .sha256 = "bb" } };
    const same = [_]Asset{ .{ .name = "x.tar.gz", .sha256 = "aa" }, .{ .name = "SHA256SUMS", .sha256 = "bb" } };
    try t.expect(releaseHolds(a, &same, &ours) and
        !releaseHolds(a, null, &ours) and
        !releaseHolds(a, same[0..1], &ours) and
        !releaseHolds(a, &.{ .{ .name = "x.tar.gz", .sha256 = "ab" }, same[1] }, &ours) and
        !releaseHolds(a, &.{ same[0], .{ .name = "SHA256SUMS", .sha256 = null } }, &ours));
}

test "a re-run of a released commit: other signature bundles over the same bytes are kept, nothing else may differ" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ours = [_]File{
        .{ .name = "x.tar.gz", .sha256 = "aa" },
        .{ .name = "SHA256SUMS", .sha256 = "bb" },
        .{ .name = "x.tar.gz" ++ bundle_suffix, .sha256 = "n1" },
        .{ .name = "SHA256SUMS" ++ bundle_suffix, .sha256 = "n2" },
    };
    // the shape of v0.0.11: the files are the same, every bundle is a new signing
    const held = [_]Asset{
        .{ .name = "x.tar.gz", .sha256 = "aa" },
        .{ .name = "SHA256SUMS", .sha256 = "bb" },
        .{ .name = "x.tar.gz" ++ bundle_suffix, .sha256 = "o1" },
        .{ .name = "SHA256SUMS" ++ bundle_suffix, .sha256 = "o2" },
    };
    try t.expect((try publishPlan(a, &held, &ours)) == .nothing);
    // a missing bundle is still added, next to a kept one
    const up = try publishPlan(a, held[0..3], &ours);
    try t.expectEqual(@as(usize, 1), up.upload.len);
    try t.expectEqualStrings("SHA256SUMS" ++ bundle_suffix, up.upload[0]);
    // a different file is refused, whatever its bundle
    try t.expectError(error.AssetDiffers, publishPlan(a, &.{
        .{ .name = "x.tar.gz", .sha256 = "ab" },
        .{ .name = "SHA256SUMS", .sha256 = "bb" },
        .{ .name = "x.tar.gz" ++ bundle_suffix, .sha256 = "o1" },
        .{ .name = "SHA256SUMS" ++ bundle_suffix, .sha256 = "o2" },
    }, &ours));
    // a bundle whose file the release does not hold may sign other bytes: refused
    try t.expectError(error.AssetDiffers, publishPlan(a, &.{
        .{ .name = "x.tar.gz" ++ bundle_suffix, .sha256 = "o1" },
    }, &ours));
    // a bundle whose file has no reported digest: refused (the file is met first)
    try t.expectError(error.AssetDigestUnknown, publishPlan(a, &.{
        .{ .name = "x.tar.gz", .sha256 = null },
        .{ .name = "x.tar.gz" ++ bundle_suffix, .sha256 = "o1" },
    }, &ours));
    // a file that is not a bundle never gets the allowance, even with a bundle-looking sibling
    try t.expectError(error.AssetDiffers, publishPlan(a, &.{
        .{ .name = "x.tar.gz", .sha256 = "aa" },
        .{ .name = "SHA256SUMS", .sha256 = "ff" },
    }, &ours));
    // the allowance itself (the loop would refuse the file later, so it is asked directly): same bytes yes, other bytes no
    try t.expect(bundleOfSameBytes(&held, &ours, ours[2]));
    try t.expect(!bundleOfSameBytes(&.{ .{ .name = "x.tar.gz", .sha256 = "ab" }, .{ .name = "x.tar.gz" ++ bundle_suffix, .sha256 = "o1" } }, &ours, ours[2]));
    try t.expect(!bundleOfSameBytes(&held, &ours, ours[0]));
    // a bundle name over a file we do not ship is not covered either
    try t.expectError(error.AssetDiffers, publishPlan(a, &.{
        .{ .name = "z" ++ bundle_suffix, .sha256 = "o1" },
    }, &.{.{ .name = "z" ++ bundle_suffix, .sha256 = "n1" }}));
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

test "checkSumsFiles: exactly one correct line per file, in name order, and nothing else" {
    // The defect: a reader of one line (the old checkSums) used on a SHA256SUMS of four, which refuses a good release, or a reader of many that
    // takes a file without a line, a line for a stranger, a wrong digest or a repeated line.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]Named{
        .{ .name = "buildrules-cli-0.0.7-macos-arm64.tar.gz", .bytes = "mac" },
        .{ .name = "buildrules-0.0.7.tar.gz", .bytes = "source" },
        .{ .name = "buildrules-cli-0.0.7-linux-x86_64.tar.gz", .bytes = "linux" },
    };
    const good = try formatSumsFiles(a, &files);
    // name order, whatever the order of the files given
    try t.expect(std.mem.startsWith(u8, good[66..], "buildrules-0.0.7.tar.gz\n"));
    try checkSumsFiles(good, &files);
    // the one-line reader and this one agree on one file
    try checkSumsFiles(try formatSums(a, "x", "bytes"), &.{.{ .name = "x", .bytes = "bytes" }});
    // a line is missing, repeated, foreign or wrong
    var lines = std.mem.splitScalar(u8, good[0 .. good.len - 1], '\n');
    const l0 = lines.next().?;
    const l1 = lines.next().?;
    const l2 = lines.next().?;
    try t.expectError(error.MissingLine, checkSumsFiles(try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ l0, l1 }), &files));
    try t.expectError(error.TwoLines, checkSumsFiles(try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n{s}\n", .{ l0, l1, l1, l2 }), &files));
    try t.expectError(error.NotSorted, checkSumsFiles(try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n", .{ l1, l0, l2 }), &files));
    try t.expectError(error.WrongName, checkSumsFiles(try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n{s}\n", .{ l0, l1, l2, "e" ** 64 ++ "  zzz.tar.gz" }), &files));
    try t.expectError(error.WrongDigest, checkSumsFiles(try std.fmt.allocPrint(a, "{s}\n{s}{s}\n{s}\n", .{ l0, "0" ** 64, l1[64..], l2 }), &files));
    // the shape: no newline at the end, an uppercase digest, one space, an empty file
    try t.expectError(error.BadSums, checkSumsFiles(good[0 .. good.len - 1], &files));
    try t.expectError(error.BadSums, checkSumsFiles("", &files));
    var upper = try a.dupe(u8, good);
    upper[0] = 'F';
    try t.expectError(error.BadSums, checkSumsFiles(upper, &files));
    try t.expectError(error.BadSums, checkSumsFiles(try std.fmt.allocPrint(a, "{s}\n{s} {s}\n{s}\n", .{ l0, l1[0..64], l1[66..], l2 }), &files));
    // a file whose bytes changed after the sums were written
    var changed = files;
    changed[0].bytes = "mac, rebuilt";
    try t.expectError(error.WrongDigest, checkSumsFiles(good, &changed));
}

test "the notes list the command-line tarballs and how to verify them" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try notes(a, .{
        .number = "0.0.2",
        .tag = "v0.0.2",
        .repo = "owner/name",
        .sha = "0123456789abcdef0123456789abcdef01234567",
        .previous = "v0.0.1",
        .subjects = &.{"x"},
        .archive = "buildrules-0.0.2.tar.gz",
        .archive_sha256 = "ab" ** 32,
        .binaries = &.{ .{ .name = "buildrules-cli-0.0.2-linux-x86_64.tar.gz", .sha256 = "cd" ** 32 }, .{ .name = "buildrules-cli-0.0.2-macos-arm64.tar.gz", .sha256 = "ef" ** 32 } },
    });
    try t.expect(std.mem.indexOf(u8, text, "  - https://github.com/owner/name/releases/download/v0.0.2/buildrules-cli-0.0.2-linux-x86_64.tar.gz sha256 `" ++ "cd" ** 32 ++ "`\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "buildrules-cli-0.0.2-macos-arm64.tar.gz sha256 `" ++ "ef" ** 32 ++ "`") != null);
    try t.expect(std.mem.indexOf(u8, text, "cosign verify-blob --bundle buildrules-0.0.2.tar.gz.sigstore.json --certificate-identity https://github.com/owner/name/.github/workflows/release.yml@refs/heads/main --certificate-oidc-issuer https://token.actions.githubusercontent.com buildrules-0.0.2.tar.gz") != null);
    // without binaries (the earlier releases' shape) the section is not written
    const plain = try notes(a, .{ .number = "0.0.1", .tag = "v0.0.1", .repo = "o/n", .sha = "s", .previous = null, .subjects = &.{}, .archive = "a", .archive_sha256 = "h" });
    try t.expect(std.mem.indexOf(u8, plain, "the command line") == null);
}
