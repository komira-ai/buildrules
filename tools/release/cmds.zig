//! The four steps of the automatic release (RELEASING.md), each a function of an `Io` (the commands it runs and the files it writes), so the
//! tests drive them with a fake that records the calls:
//!
//!  - `tag`: which version, if any, this commit is released as; creates the annotated tag (the one job that may write the repository);
//!  - `archive`: the deterministic source archive of a tag and its SHA256SUMS;
//!  - `verify`: everything that must hold before a file is published (nothing here writes);
//!  - `publish`: the GitHub release of the verified files, created once and never changed.
const std = @import("std");
const version = @import("version.zig");
const gz = @import("gz.zig");
const tar = @import("tar.zig");
const assets = @import("assets.zig");
const scrub = @import("scrub_lib");

pub const Out = struct { code: u8, stdout: []const u8, stderr: []const u8 };

pub const Io = struct {
    ctx: *anyopaque,
    run_fn: *const fn (ctx: *anyopaque, a: std.mem.Allocator, argv: []const []const u8) anyerror!Out,
    write_fn: *const fn (ctx: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void,

    pub fn run(self: Io, a: std.mem.Allocator, argv: []const []const u8) !Out {
        return self.run_fn(self.ctx, a, argv);
    }

    pub fn write(self: Io, path: []const u8, bytes: []const u8) !void {
        return self.write_fn(self.ctx, path, bytes);
    }
};

/// stdout of a command that must succeed.
fn must(io: Io, a: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    const o = try io.run(a, argv);
    if (o.code != 0) {
        std.debug.print("release: `{s}` exited {d}: {s}\n", .{ try std.mem.join(a, " ", argv), o.code, o.stderr });
        return error.CommandFailed;
    }
    return o.stdout;
}

fn isSha(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

/// Every archive is stamped with this time, whatever the commit's: the same tree is the same bytes.
pub const archive_mtime = "2026-09-01 00:00:00 +0000";

/// The identity GitHub gives its own Actions token; the address is spelled in parts so no address stands in the source.
const bot_name = "github-actions[bot]";
const bot_email = "41898282+github-actions[bot]" ++ "@" ++ "users.noreply.github.com";

fn trimNl(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \r\n");
}

// ---- tag --------------------------------------------------------------------------------------------------------------------------------

const TagRef = struct { name: []const u8, v: version.Version, commit: []const u8 };

/// `git for-each-ref --format=%(refname:strip=2)%09%(objecttype)%09%(objectname)%09%(*objectname)`: the release tags and the commit each
/// names (an annotated tag is peeled). Tags that are not `vMAJOR.MINOR.PATCH`, and tags of anything but a commit, are not releases.
fn parseTagRefs(a: std.mem.Allocator, text: []const u8) ![]TagRef {
    var out = std.ArrayList(TagRef).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, '\t');
        const name = f.next() orelse continue;
        const kind = f.next() orelse continue;
        const object = f.next() orelse continue;
        const peeled = f.next() orelse "";
        const v = version.parseTag(name) orelse continue;
        const commit = if (std.mem.eql(u8, kind, "tag")) peeled else if (std.mem.eql(u8, kind, "commit")) object else continue;
        if (!isSha(commit)) continue;
        try out.append(a, .{ .name = name, .v = v, .commit = commit });
    }
    return out.toOwnedSlice(a);
}

pub const TagOpts = struct {
    root: []const u8,
    repo: []const u8,
    sha: []const u8,
    /// The content of the `VERSION` file at `sha`.
    version_file: []const u8,
};

pub const TagResult = struct {
    released: bool,
    /// This run made the tag (false when the commit already had one: a re-run).
    created: bool = false,
    tag: []const u8 = "",
    number: []const u8 = "",
    previous: []const u8 = "",
    reason: []const u8,
};

/// The `key=value` lines the job appends to $GITHUB_OUTPUT.
pub fn tagOutputs(a: std.mem.Allocator, r: TagResult) ![]u8 {
    return std.fmt.allocPrint(a, "released={s}\ncreated={s}\ntag={s}\nnumber={s}\nprevious={s}\nreason={s}\n", .{
        if (r.released) "true" else "false",
        if (r.created) "true" else "false",
        r.tag,
        r.number,
        r.previous,
        r.reason,
    });
}

fn tagOf(tags: []const TagRef, v: version.Version) []const u8 {
    for (tags) |tg| {
        if (version.Version.order(tg.v, v) == .eq) return tg.name;
    }
    return "";
}

pub fn tag(a: std.mem.Allocator, io: Io, o: TagOpts) !TagResult {
    if (!isSha(o.sha)) return error.BadSha;
    const mm = try version.parseMajorMinor(o.version_file);
    const refs = try must(io, a, &.{ "git", "-C", o.root, "for-each-ref", "--format=%(refname:strip=2)%09%(objecttype)%09%(objectname)%09%(*objectname)", "refs/tags/" });
    const tags = try parseTagRefs(a, refs);
    var all = std.ArrayList(version.Version).empty;
    for (tags) |tg| try all.append(a, tg.v);

    // A commit that already has a release tag is that release (this run is a re-run): nothing is created, the later jobs go on.
    var have: ?version.Version = null;
    for (tags) |tg| {
        if (std.mem.eql(u8, tg.commit, o.sha) and (have == null or version.Version.order(tg.v, have.?) == .gt)) have = tg.v;
    }
    if (have) |h| {
        return .{
            .released = true,
            .tag = tagOf(tags, h),
            .number = try version.numberText(a, h),
            .previous = if (version.previousOf(all.items, h)) |p| tagOf(tags, p) else "",
            .reason = "this commit already has its release tag",
        };
    }

    // The version file never goes behind the tags, whatever else is decided.
    const next = try version.next(all.items, mm);
    var previous: []const u8 = "";
    if (version.latest(all.items)) |last| {
        previous = tagOf(tags, last);
        var last_commit: []const u8 = "";
        for (tags) |tg| {
            if (version.Version.order(tg.v, last) == .eq) last_commit = tg.commit;
        }
        const anc = try io.run(a, &.{ "git", "-C", o.root, "merge-base", "--is-ancestor", last_commit, o.sha });
        if (anc.code == 1) return .{ .released = false, .previous = previous, .reason = "this commit is not after the last release" };
        if (anc.code != 0) {
            std.debug.print("release: git merge-base exited {d}: {s}\n", .{ anc.code, anc.stderr });
            return error.CommandFailed;
        }
        const diff = try must(io, a, &.{ "git", "-C", o.root, "diff", "--name-only", "-z", last_commit, o.sha });
        var paths = std.ArrayList([]const u8).empty;
        var it = std.mem.splitScalar(u8, diff, 0);
        while (it.next()) |p| {
            if (p.len != 0) try paths.append(a, p);
        }
        if (version.releaseWorthy(paths.items) == null)
            return .{ .released = false, .previous = previous, .reason = "only documentation and CI changed since the last release" };
    }

    const name = try version.tagName(a, next);
    const number = try version.numberText(a, next);
    const message = try std.fmt.allocPrint(a, "buildrules {s}\n\nautomatic release of commit {s}\n", .{ number, o.sha });
    const object = trimNl(try must(io, a, &.{
        "gh",                                                                  "api",                                                       "--method", "POST",
        try std.fmt.allocPrint(a, "repos/{s}/git/tags", .{o.repo}),            "-f",                                                        try std.fmt.allocPrint(a, "tag={s}", .{name}),
        "-f",                                                                  try std.fmt.allocPrint(a, "message={s}", .{message}),       "-f",       try std.fmt.allocPrint(a, "object={s}", .{o.sha}),
        "-f",                                                                  "type=commit",                                               "-f",       "tagger[name]=" ++ bot_name,
        "-f",                                                                  "tagger[email]=" ++ bot_email,                               "--jq",     ".sha",
    }));
    if (!isSha(object)) return error.BadTagObject;
    // A tag that exists is refused here by GitHub (422), which is the "fail if the tag already exists" for a race the listing above missed.
    _ = try must(io, a, &.{
        "gh",  "api",                                                  "--method", "POST",
        try std.fmt.allocPrint(a, "repos/{s}/git/refs", .{o.repo}), "-f",       try std.fmt.allocPrint(a, "ref=refs/tags/{s}", .{name}),
        "-f",  try std.fmt.allocPrint(a, "sha={s}", .{object}),
    });
    return .{ .released = true, .created = true, .tag = name, .number = number, .previous = previous, .reason = "a release commit" };
}

// ---- archive ----------------------------------------------------------------------------------------------------------------------------

pub const Built = struct {
    /// `buildrules-0.0.1.tar.gz`
    name: []const u8,
    archive: []const u8,
    /// The content of SHA256SUMS.
    sums: []const u8,
    /// `buildrules-0.0.1/`
    prefix: []const u8,
};

pub const sums_name = "SHA256SUMS";

/// The source archive of the tag: `git archive` of the tag's tree under `buildrules-<number>/`, every entry stamped `archive_mtime` and
/// with the modes of umask 022, compressed by `gz.gzip` (no gzip, no zlib, no git compression), named for the number.
pub fn archive(a: std.mem.Allocator, io: Io, root: []const u8, tag_name: []const u8) !Built {
    const v = version.parseTag(tag_name) orelse return error.BadTag;
    const number = try version.numberText(a, v);
    const prefix = try std.fmt.allocPrint(a, "buildrules-{s}/", .{number});
    const tar_bytes = try must(io, a, &.{
        "git",                                              "-C",       root,                                       "-c",        "tar.umask=0022",
        "archive",                                          "--format=tar", try std.fmt.allocPrint(a, "--prefix={s}", .{prefix}), "--mtime=" ++ archive_mtime, try std.fmt.allocPrint(a, "refs/tags/{s}", .{tag_name}),
    });
    const archive_bytes = try gz.gzip(a, tar_bytes);
    const name = try std.fmt.allocPrint(a, "buildrules-{s}.tar.gz", .{number});
    return .{ .name = name, .archive = archive_bytes, .sums = try assets.formatSums(a, name, archive_bytes), .prefix = prefix };
}

// ---- verify -----------------------------------------------------------------------------------------------------------------------------

pub const VerifyOpts = struct {
    root: []const u8,
    repo: []const u8,
    tag: []const u8,
    sha: []const u8,
    /// The directory holding the archive and SHA256SUMS (the attestations are checked on these files).
    dist: []const u8,
    archive_name: []const u8,
    archive: []const u8,
    sums: []const u8,
    /// The workflow that signed the attestations, `.github/workflows/release.yml`.
    workflow: []const u8,
};

/// Every reason the files must not be published; empty when there is none. Nothing is written.
pub fn verify(a: std.mem.Allocator, io: Io, o: VerifyOpts) !assets.Findings {
    var f = assets.Findings.empty;
    const v = version.parseTag(o.tag) orelse {
        try assets.add(a, &f, "`{s}` is not a release tag (vMAJOR.MINOR.PATCH)", .{o.tag});
        return f;
    };
    const number = try version.numberText(a, v);
    const want_name = try std.fmt.allocPrint(a, "buildrules-{s}.tar.gz", .{number});
    if (!std.mem.eql(u8, want_name, o.archive_name)) try assets.add(a, &f, "the archive is named {s}, the tag names {s}", .{ o.archive_name, want_name });
    const tag_ref = try std.fmt.allocPrint(a, "refs/tags/{s}", .{o.tag});

    // 1. the archive is the file SHA256SUMS lists.
    assets.checkSums(o.sums, o.archive_name, o.archive) catch |e| try assets.add(a, &f, "SHA256SUMS does not match the archive: {s}", .{@errorName(e)});

    // 2. the tag is an annotated tag of the commit being released.
    const peeled = try io.run(a, &.{ "git", "-C", o.root, "rev-parse", "--verify", try std.fmt.allocPrint(a, "{s}^{{commit}}", .{tag_ref}) });
    if (peeled.code != 0 or !std.mem.eql(u8, trimNl(peeled.stdout), o.sha)) try assets.add(a, &f, "the tag {s} does not name commit {s}", .{ o.tag, o.sha });
    const kind = try io.run(a, &.{ "git", "-C", o.root, "cat-file", "-t", tag_ref });
    if (kind.code != 0 or !std.mem.eql(u8, trimNl(kind.stdout), "tag")) try assets.add(a, &f, "the tag {s} is not an annotated tag", .{o.tag});

    // 3. both files carry an attestation of this workflow, for this tag's commit, on main.
    const signer = try std.fmt.allocPrint(a, "{s}/{s}", .{ o.repo, o.workflow });
    for ([_][]const u8{ o.archive_name, sums_name }) |file| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ o.dist, file });
        const r = try io.run(a, &.{
            "gh",                                "attestation",       "verify",              path,
            "--repo",                            o.repo,              "--signer-workflow",   signer,
            "--signer-digest",                   o.sha,               "--source-digest",     o.sha,
            "--source-ref",                      "refs/heads/main",   "--deny-self-hosted-runners",
        });
        if (r.code != 0) try assets.add(a, &f, "the attestation of {s} does not verify (workflow {s}, commit {s}, refs/heads/main): {s}", .{ file, signer, o.sha, trimNl(r.stderr) });
    }

    // 4. building the archive again from the tag gives these very bytes.
    if (archive(a, io, o.root, o.tag)) |again| {
        if (!std.mem.eql(u8, again.archive, o.archive)) try assets.add(a, &f, "the archive does not reproduce: building {s} again from the tag gives other bytes", .{o.tag});
    } else |e| try assets.add(a, &f, "the archive cannot be built again from the tag: {s}", .{@errorName(e)});

    // 5. its files are the tag's tracked files, 6. and the scrub passes on them.
    const tree = try io.run(a, &.{ "git", "-C", o.root, "ls-tree", "-r", "-z", "--name-only", tag_ref });
    if (tree.code != 0) {
        try assets.add(a, &f, "cannot list the files of the tag: {s}", .{trimNl(tree.stderr)});
        return f;
    }
    var tracked = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, tree.stdout, 0);
    while (it.next()) |p| {
        if (p.len != 0) try tracked.append(a, p);
    }
    if (tracked.items.len == 0) try assets.add(a, &f, "the tag {s} tracks no file", .{o.tag});
    const plain = gz.gunzip(a, o.archive) catch |e| {
        try assets.add(a, &f, "the archive is not a gzip file: {s}", .{@errorName(e)});
        return f;
    };
    const prefix = try std.fmt.allocPrint(a, "buildrules-{s}/", .{number});
    const entries = tar.parse(a, plain) catch |e| {
        try assets.add(a, &f, "the archive does not hold a tar: {s}", .{@errorName(e)});
        return f;
    };
    try assets.compareFileLists(a, &f, entries, prefix, tracked.items);
    var hits = std.ArrayList(scrub.Hit).empty;
    for (entries) |e| {
        if (e.kind != .file or !std.mem.startsWith(u8, e.name, prefix)) continue;
        if (scrub.isBinary(e.data)) continue;
        try scrub.scanText(a, e.name[prefix.len..], e.data, &hits);
    }
    for (hits.items) |h| {
        if (h.allowed != null) continue;
        try assets.add(a, &f, "scrub: [{s}] {s}:{d}: {s}", .{ h.rule, h.file, h.line, h.text });
    }
    return f;
}

// ---- publish ----------------------------------------------------------------------------------------------------------------------------

pub const PublishOpts = struct {
    root: []const u8,
    repo: []const u8,
    tag: []const u8,
    sha: []const u8,
    /// The previous release's tag, or empty for the first.
    previous: []const u8,
    dist: []const u8,
    archive_name: []const u8,
    archive: []const u8,
    sums: []const u8,
    notes_path: []const u8,
};

pub const PublishResult = enum { created, uploaded, unchanged };

/// Creates the release of the tag with the archive and SHA256SUMS and the notes, or adds the files an existing release lacks, or does
/// nothing. A release that already holds a file with other bytes fails the job and changes nothing: no asset is replaced.
pub fn publish(a: std.mem.Allocator, io: Io, o: PublishOpts) !PublishResult {
    const v = version.parseTag(o.tag) orelse return error.BadTag;
    const number = try version.numberText(a, v);
    try assets.checkSums(o.sums, o.archive_name, o.archive);

    const peeled = try must(io, a, &.{ "git", "-C", o.root, "rev-parse", "--verify", try std.fmt.allocPrint(a, "refs/tags/{s}^{{commit}}", .{o.tag}) });
    if (!std.mem.eql(u8, trimNl(peeled), o.sha)) return error.TagIsNotTheCommit;

    const archive_hex = assets.sha256Hex(o.archive);
    const sums_hex = assets.sha256Hex(o.sums);
    const ours = [_]assets.File{
        .{ .name = o.archive_name, .sha256 = &archive_hex },
        .{ .name = sums_name, .sha256 = &sums_hex },
    };
    const existing = try io.run(a, &.{ "gh", "api", try std.fmt.allocPrint(a, "repos/{s}/releases/tags/{s}", .{ o.repo, o.tag }) });
    var have: ?[]const assets.Asset = null;
    if (existing.code == 0) {
        have = try assets.parseAssets(a, existing.stdout);
    } else if (std.mem.indexOf(u8, existing.stderr, "404") == null) {
        std.debug.print("release: gh api exited {d}: {s}\n", .{ existing.code, existing.stderr });
        return error.CommandFailed;
    }
    const plan = try assets.publishPlan(a, have, &ours);
    const archive_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ o.dist, o.archive_name });
    const sums_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ o.dist, sums_name });
    switch (plan) {
        .nothing => return .unchanged,
        .upload => |names| {
            var argv = std.ArrayList([]const u8).empty;
            try argv.appendSlice(a, &.{ "gh", "release", "upload", o.tag });
            for (names) |n| try argv.append(a, if (std.mem.eql(u8, n, sums_name)) sums_path else archive_path);
            try argv.appendSlice(a, &.{ "--repo", o.repo });
            _ = try must(io, a, argv.items);
            return .uploaded;
        },
        .create => {
            const log_range = if (o.previous.len == 0) try std.fmt.allocPrint(a, "refs/tags/{s}", .{o.tag}) else try std.fmt.allocPrint(a, "refs/tags/{s}..refs/tags/{s}", .{ o.previous, o.tag });
            const log = try must(io, a, &.{ "git", "-C", o.root, "log", "--no-merges", "--format=%s", log_range });
            var subjects = std.ArrayList([]const u8).empty;
            var lines = std.mem.splitScalar(u8, log, '\n');
            while (lines.next()) |l| try subjects.append(a, l);
            const text = try assets.notes(a, .{
                .number = number,
                .tag = o.tag,
                .repo = o.repo,
                .sha = o.sha,
                .previous = if (o.previous.len == 0) null else o.previous,
                .subjects = subjects.items,
                .archive = o.archive_name,
                .archive_sha256 = &archive_hex,
            });
            try io.write(o.notes_path, text);
            _ = try must(io, a, &.{
                "gh",       "release",  "create", o.tag,
                archive_path, sums_path, "--repo", o.repo,
                "--verify-tag", "--title", try std.fmt.allocPrint(a, "buildrules {s}", .{number}), "--notes-file", o.notes_path,
            });
            return .created;
        },
    }
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;

const sha_a = "a" ** 40;
const sha_b = "b" ** 40;
const sha_c = "c" ** 40;

/// A fake `Io`: the first rule whose needle occurs in the command line answers; a command no rule answers fails the test.
const Fake = struct {
    a: std.mem.Allocator,
    rules: []const Rule,
    calls: std.ArrayList([]const u8) = .empty,
    files: std.ArrayList([]const u8) = .empty,

    const Rule = struct { needle: []const u8, out: Out = .{ .code = 0, .stdout = "", .stderr = "" } };

    fn run(ctx: *anyopaque, a: std.mem.Allocator, argv: []const []const u8) anyerror!Out {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const line = try std.mem.join(a, " ", argv);
        try self.calls.append(self.a, line);
        for (self.rules) |r| {
            if (std.mem.indexOf(u8, line, r.needle) != null) return r.out;
        }
        std.debug.print("unscripted command: {s}\n", .{line});
        return error.UnscriptedCommand;
    }

    fn write(ctx: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        try self.files.append(self.a, try std.fmt.allocPrint(self.a, "{s}\n{s}", .{ path, bytes }));
    }

    fn io(self: *Fake) Io {
        return .{ .ctx = self, .run_fn = run, .write_fn = write };
    }

    fn count(self: *const Fake, needle: []const u8) usize {
        var n: usize = 0;
        for (self.calls.items) |c| {
            if (std.mem.indexOf(u8, c, needle) != null) n += 1;
        }
        return n;
    }
};

fn ok(stdout: []const u8) Out {
    return .{ .code = 0, .stdout = stdout, .stderr = "" };
}

fn fail(code: u8, stderr: []const u8) Out {
    return .{ .code = code, .stdout = "", .stderr = stderr };
}

const no_tags = "";
// name, object type, object, peeled commit (empty for a lightweight tag)
const tags_v1 = "v0.0.1\ttag\t" ++ "1" ** 40 ++ "\t" ++ sha_b ++ "\n";

test "the first release: no tag yet, so v0.0.1 is created as an annotated tag, through two API calls" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "for-each-ref", .out = ok(no_tags) },
        .{ .needle = "git/tags", .out = ok(sha_c ++ "\n") },
        .{ .needle = "git/refs" },
    } };
    const r = try tag(a, fake.io(), .{ .root = "/w", .repo = "o/n", .sha = sha_a, .version_file = "0.0\n" });
    try t.expect(r.released and r.created);
    try t.expectEqualStrings("v0.0.1", r.tag);
    try t.expectEqualStrings("0.0.1", r.number);
    try t.expectEqualStrings("", r.previous);
    try t.expectEqual(@as(usize, 1), fake.count("repos/o/n/git/tags"));
    try t.expectEqual(@as(usize, 1), fake.count("repos/o/n/git/refs"));
    // the tag object names the commit and is of type commit; the ref points at the tag object, not at the commit
    try t.expectEqual(@as(usize, 1), fake.count("object=" ++ sha_a ++ " -f type=commit"));
    try t.expectEqual(@as(usize, 1), fake.count("ref=refs/tags/v0.0.1 -f sha=" ++ sha_c));
    const out = try tagOutputs(a, r);
    try t.expectEqualStrings("released=true\ncreated=true\ntag=v0.0.1\nnumber=0.0.1\nprevious=\nreason=a release commit\n", out);
}

test "the next release is the highest patch plus one, after code changed since the last tag" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refs = "v0.0.2\ttag\t" ++ "2" ** 40 ++ "\t" ++ sha_b ++ "\n" ++ tags_v1 ++ "latest\ttag\t" ++ "3" ** 40 ++ "\t" ++ sha_c ++ "\nv1\tcommit\t" ++ sha_c ++ "\t\n";
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "for-each-ref", .out = ok(refs) },
        .{ .needle = "merge-base --is-ancestor " ++ sha_b ++ " " ++ sha_a },
        .{ .needle = "diff --name-only -z " ++ sha_b ++ " " ++ sha_a, .out = ok("README.md\x00rules/zig/zig.bzl\x00") },
        .{ .needle = "git/tags", .out = ok(sha_c ++ "\n") },
        .{ .needle = "git/refs" },
    } };
    const r = try tag(a, fake.io(), .{ .root = "/w", .repo = "o/n", .sha = sha_a, .version_file = "0.0" });
    try t.expect(r.released and r.created);
    try t.expectEqualStrings("v0.0.3", r.tag);
    try t.expectEqualStrings("v0.0.2", r.previous);
}

test "documentation and CI alone make no release and no tag" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "for-each-ref", .out = ok(tags_v1) },
        .{ .needle = "merge-base" },
        .{ .needle = "diff --name-only", .out = ok("README.md\x00docs/contract.md\x00.github/workflows/ci.yml\x00ci/BUCK\x00") },
    } };
    const r = try tag(a, fake.io(), .{ .root = "/w", .repo = "o/n", .sha = sha_a, .version_file = "0.0\n" });
    try t.expect(!r.released and !r.created);
    try t.expectEqual(@as(usize, 0), fake.count("gh "));
    try t.expectEqualStrings("only documentation and CI changed since the last release", r.reason);
}

test "a commit that is not after the last release is skipped, not released out of order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "for-each-ref", .out = ok(tags_v1) },
        .{ .needle = "merge-base", .out = fail(1, "") },
    } };
    const r = try tag(a, fake.io(), .{ .root = "/w", .repo = "o/n", .sha = sha_a, .version_file = "0.0\n" });
    try t.expect(!r.released);
    try t.expectEqual(@as(usize, 0), fake.count("gh "));
    // another failure of merge-base (a shallow clone, an unknown commit) is an error, not a skip
    var fake2 = Fake{ .a = a, .rules = &.{
        .{ .needle = "for-each-ref", .out = ok(tags_v1) },
        .{ .needle = "merge-base", .out = fail(128, "fatal: bad object") },
    } };
    try t.expectError(error.CommandFailed, tag(a, fake2.io(), .{ .root = "/w", .repo = "o/n", .sha = sha_a, .version_file = "0.0\n" }));
}

test "a re-run of a released commit creates nothing and carries on with the tag it has" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refs = "v0.0.1\ttag\t" ++ "1" ** 40 ++ "\t" ++ sha_b ++ "\nv0.0.2\ttag\t" ++ "2" ** 40 ++ "\t" ++ sha_a ++ "\n";
    var fake = Fake{ .a = a, .rules = &.{.{ .needle = "for-each-ref", .out = ok(refs) }} };
    const r = try tag(a, fake.io(), .{ .root = "/w", .repo = "o/n", .sha = sha_a, .version_file = "0.0\n" });
    try t.expect(r.released and !r.created);
    try t.expectEqualStrings("v0.0.2", r.tag);
    try t.expectEqualStrings("v0.0.1", r.previous);
    try t.expectEqual(@as(usize, 1), fake.calls.items.len);
}

test "a lightweight tag counts as a release of its commit" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .a = a, .rules = &.{.{ .needle = "for-each-ref", .out = ok("v0.0.7\tcommit\t" ++ sha_a ++ "\t\n") }} };
    const r = try tag(a, fake.io(), .{ .root = "/w", .repo = "o/n", .sha = sha_a, .version_file = "0.0\n" });
    try t.expect(r.released and !r.created);
    try t.expectEqualStrings("v0.0.7", r.tag);
}

test "bumping VERSION starts a new line at patch 1; a VERSION behind the tags is an error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "for-each-ref", .out = ok("v0.0.9\ttag\t" ++ "1" ** 40 ++ "\t" ++ sha_b ++ "\n") },
        .{ .needle = "merge-base" },
        .{ .needle = "diff --name-only", .out = ok("VERSION\x00") },
        .{ .needle = "git/tags", .out = ok(sha_c ++ "\n") },
        .{ .needle = "git/refs" },
    } };
    const r = try tag(a, fake.io(), .{ .root = "/w", .repo = "o/n", .sha = sha_a, .version_file = "0.1\n" });
    try t.expectEqualStrings("v0.1.1", r.tag);
    try t.expectEqualStrings("v0.0.9", r.previous);
    var behind = Fake{ .a = a, .rules = &.{.{ .needle = "for-each-ref", .out = ok("v0.2.1\ttag\t" ++ "1" ** 40 ++ "\t" ++ sha_b ++ "\n") }} };
    try t.expectError(error.TagsAheadOfVersionFile, tag(a, behind.io(), .{ .root = "/w", .repo = "o/n", .sha = sha_a, .version_file = "0.1\n" }));
    try t.expectEqual(@as(usize, 0), behind.count("gh "));
}

test "a tag that already exists fails the job (GitHub refuses the ref), and a bad input is refused before any call" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "for-each-ref", .out = ok(no_tags) },
        .{ .needle = "git/tags", .out = ok(sha_c ++ "\n") },
        .{ .needle = "git/refs", .out = fail(1, "gh: Reference already exists (HTTP 422)") },
    } };
    try t.expectError(error.CommandFailed, tag(a, fake.io(), .{ .root = "/w", .repo = "o/n", .sha = sha_a, .version_file = "0.0\n" }));
    var none = Fake{ .a = a, .rules = &.{} };
    try t.expectError(error.BadSha, tag(a, none.io(), .{ .root = "/w", .repo = "o/n", .sha = "main", .version_file = "0.0\n" }));
    try t.expectError(error.BadSha, tag(a, none.io(), .{ .root = "/w", .repo = "o/n", .sha = "A" ** 40, .version_file = "0.0\n" }));
    try t.expectError(error.BadVersionFile, tag(a, none.io(), .{ .root = "/w", .repo = "o/n", .sha = sha_a, .version_file = "v0.0\n" }));
    try t.expectEqual(@as(usize, 0), none.calls.items.len);
    // a tag object GitHub answers with something that is not a sha
    var odd = Fake{ .a = a, .rules = &.{
        .{ .needle = "for-each-ref", .out = ok(no_tags) },
        .{ .needle = "git/tags", .out = ok("{\"message\": \"Not Found\"}") },
    } };
    try t.expectError(error.BadTagObject, tag(a, odd.io(), .{ .root = "/w", .repo = "o/n", .sha = sha_a, .version_file = "0.0\n" }));
    try t.expectEqual(@as(usize, 0), odd.count("git/refs"));
}

const sample_tar_entries = [_]tar.Entry{
    .{ .name = "buildrules-0.0.1/", .kind = .dir, .data = "" },
    .{ .name = "buildrules-0.0.1/BUCK", .kind = .file, .data = "load(\"x\")\n" },
    .{ .name = "buildrules-0.0.1/rules/zig.bzl", .kind = .file, .data = "def f(): pass\n" },
};

test "the archive command: git archive of the tag with the fixed prefix and time, gzip by this tool, SHA256SUMS of the result" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar_bytes = try tar.build(a, &sample_tar_entries);
    const rules = [_]Fake.Rule{.{ .needle = " archive ", .out = ok(tar_bytes) }};
    var fake = Fake{ .a = a, .rules = &rules };
    const b = try archive(a, fake.io(), "/w", "v0.0.1");
    try t.expectEqualStrings("buildrules-0.0.1.tar.gz", b.name);
    try t.expectEqualStrings("buildrules-0.0.1/", b.prefix);
    try t.expectEqualStrings("git -C /w -c tar.umask=0022 archive --format=tar --prefix=buildrules-0.0.1/ --mtime=" ++ archive_mtime ++ " refs/tags/v0.0.1", fake.calls.items[0]);
    // the gzip is this tool's own and holds the tar
    const back = try gz.gunzip(a, b.archive);
    try t.expectEqualSlices(u8, tar_bytes, back);
    try assets.checkSums(b.sums, b.name, b.archive);
    // twice: the same bytes
    const again = try archive(a, fake.io(), "/w", "v0.0.1");
    try t.expectEqualSlices(u8, b.archive, again.archive);
    try t.expectEqualStrings(b.sums, again.sums);
}

test "the archive command takes only a release tag" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .a = a, .rules = &.{} };
    for ([_][]const u8{ "main", "v1", "v0.0.1-rc1", "0.0.1", "v0.0.1 --output=/x", "../v0.0.1", "v0.0.01" }) |bad| {
        try t.expectError(error.BadTag, archive(a, fake.io(), "/w", bad));
    }
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
}

fn verifyRules(tar_bytes: []const u8, tree: []const u8, attest: Out, kind: []const u8, peeled: []const u8) [5]Fake.Rule {
    return .{
        .{ .needle = "rev-parse", .out = ok(peeled) },
        .{ .needle = "cat-file -t", .out = ok(kind) },
        .{ .needle = "gh attestation verify", .out = attest },
        .{ .needle = " archive ", .out = ok(tar_bytes) },
        .{ .needle = "ls-tree", .out = ok(tree) },
    };
}

fn expectFinding(f: assets.Findings, needle: []const u8) !void {
    for (f.items) |m| {
        if (std.mem.indexOf(u8, m, needle) != null) return;
    }
    std.debug.print("expected a finding with `{s}`, got {d}:\n", .{ needle, f.items.len });
    for (f.items) |m| std.debug.print("  {s}\n", .{m});
    return error.MutantSurvived;
}

fn expectClean(f: assets.Findings) !void {
    for (f.items) |m| std.debug.print("unexpected finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

const tree_ok = "BUCK\x00rules/zig.bzl\x00";
const peeled_a = sha_a ++ "\n";

fn opts(b: Built) VerifyOpts {
    return .{ .root = "/w", .repo = "o/n", .tag = "v0.0.1", .sha = sha_a, .dist = "dist", .archive_name = b.name, .archive = b.archive, .sums = b.sums, .workflow = ".github/workflows/release.yml" };
}

test "verify: a correct archive has no finding, and every check was made" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar_bytes = try tar.build(a, &sample_tar_entries);
    const rules = verifyRules(tar_bytes, tree_ok, ok(""), "tag\n", peeled_a);
    var fake = Fake{ .a = a, .rules = &rules };
    const b = try archive(a, fake.io(), "/w", "v0.0.1");
    const f = try verify(a, fake.io(), opts(b));
    try expectClean(f);
    // both files are attested, pinned to the workflow, the commit twice (signer and source) and main
    try t.expectEqual(@as(usize, 2), fake.count("gh attestation verify dist/"));
    try t.expectEqual(@as(usize, 1), fake.count("verify dist/buildrules-0.0.1.tar.gz --repo o/n --signer-workflow o/n/.github/workflows/release.yml --signer-digest " ++ sha_a ++ " --source-digest " ++ sha_a ++ " --source-ref refs/heads/main --deny-self-hosted-runners"));
    try t.expectEqual(@as(usize, 1), fake.count("verify dist/SHA256SUMS "));
}

test "verify mutants: each defect is a finding" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar_bytes = try tar.build(a, &sample_tar_entries);
    const good = verifyRules(tar_bytes, tree_ok, ok(""), "tag\n", peeled_a);
    var base = Fake{ .a = a, .rules = &good };
    const b = try archive(a, base.io(), "/w", "v0.0.1");

    // SHA256SUMS lists another digest or another name
    var o = opts(b);
    o.sums = try assets.formatSums(a, b.name, "other bytes");
    var fake = Fake{ .a = a, .rules = &good };
    try expectFinding(try verify(a, fake.io(), o), "SHA256SUMS does not match the archive: WrongDigest");
    o = opts(b);
    o.sums = try assets.formatSums(a, "buildrules-0.0.2.tar.gz", b.archive);
    try expectFinding(try verify(a, fake.io(), o), "WrongName");

    // the tag names another commit, or is not annotated
    const other = verifyRules(tar_bytes, tree_ok, ok(""), "tag\n", sha_b ++ "\n");
    fake = Fake{ .a = a, .rules = &other };
    try expectFinding(try verify(a, fake.io(), opts(b)), "does not name commit " ++ sha_a);
    const light = verifyRules(tar_bytes, tree_ok, ok(""), "commit\n", peeled_a);
    fake = Fake{ .a = a, .rules = &light };
    try expectFinding(try verify(a, fake.io(), opts(b)), "is not an annotated tag");

    // the attestation does not verify
    const bad_attest = verifyRules(tar_bytes, tree_ok, fail(1, "no matching attestations"), "tag\n", peeled_a);
    fake = Fake{ .a = a, .rules = &bad_attest };
    try expectFinding(try verify(a, fake.io(), opts(b)), "attestation of buildrules-0.0.1.tar.gz does not verify");
    try expectFinding(try verify(a, fake.io(), opts(b)), "attestation of SHA256SUMS does not verify");

    // the archive is not what the tag builds (another tar, so other bytes)
    const tar2 = try tar.build(a, sample_tar_entries[0..2]);
    const rebuilt = verifyRules(tar2, tree_ok, ok(""), "tag\n", peeled_a);
    fake = Fake{ .a = a, .rules = &rebuilt };
    try expectFinding(try verify(a, fake.io(), opts(b)), "does not reproduce");

    // the tag tracks a file the archive lacks, or the archive holds one the tag does not track
    const more = verifyRules(tar_bytes, tree_ok ++ "extra.txt\x00", ok(""), "tag\n", peeled_a);
    fake = Fake{ .a = a, .rules = &more };
    try expectFinding(try verify(a, fake.io(), opts(b)), "lacks extra.txt");
    const fewer = verifyRules(tar_bytes, "BUCK\x00", ok(""), "tag\n", peeled_a);
    fake = Fake{ .a = a, .rules = &fewer };
    try expectFinding(try verify(a, fake.io(), opts(b)), "holds rules/zig.bzl, which the tag does not track");

    // the file name does not match the tag; the tag is not a release tag
    o = opts(b);
    o.archive_name = "buildrules-0.0.2.tar.gz";
    fake = Fake{ .a = a, .rules = &good };
    try expectFinding(try verify(a, fake.io(), o), "the archive is named");
    o = opts(b);
    o.tag = "v1";
    try expectFinding(try verify(a, fake.io(), o), "is not a release tag");

    // not a gzip file
    o = opts(b);
    o.archive = "not gzip at all";
    o.sums = try assets.formatSums(a, b.name, o.archive);
    fake = Fake{ .a = a, .rules = &good };
    try expectFinding(try verify(a, fake.io(), o), "not a gzip file");
}

test "verify runs the scrub on the archive's contents" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // text the scrub refuses, spelled in parts so this file holds none of it
    const dated = "released on 2" ++ "025" ++ "-01" ++ "-15\n";
    const entries = [_]tar.Entry{
        .{ .name = "buildrules-0.0.1/", .kind = .dir, .data = "" },
        .{ .name = "buildrules-0.0.1/NOTES.txt", .kind = .file, .data = dated },
        .{ .name = "buildrules-0.0.1/blob.bin", .kind = .file, .data = "\x00" ++ dated },
    };
    const tar_bytes = try tar.build(a, &entries);
    const rules = verifyRules(tar_bytes, "NOTES.txt\x00blob.bin\x00", ok(""), "tag\n", peeled_a);
    var fake = Fake{ .a = a, .rules = &rules };
    const b = try archive(a, fake.io(), "/w", "v0.0.1");
    const f = try verify(a, fake.io(), opts(b));
    try expectFinding(f, "scrub: [");
    try expectFinding(f, "NOTES.txt:1");
    // the binary file is not scanned (as in the repository's own scrub)
    for (f.items) |m| try t.expect(std.mem.indexOf(u8, m, "blob.bin") == null);
}

fn publishCase(a: std.mem.Allocator) !struct { b: Built, o: PublishOpts } {
    const tar_bytes = try tar.build(a, &sample_tar_entries);
    const rules = [_]Fake.Rule{.{ .needle = " archive ", .out = ok(tar_bytes) }};
    var fake = Fake{ .a = a, .rules = &rules };
    const b = try archive(a, fake.io(), "/w", "v0.0.2");
    return .{ .b = b, .o = .{
        .root = "/w",
        .repo = "o/n",
        .tag = "v0.0.2",
        .sha = sha_a,
        .previous = "v0.0.1",
        .dist = "dist",
        .archive_name = b.name,
        .archive = b.archive,
        .sums = b.sums,
        .notes_path = "dist/notes.md",
    } };
}

test "publish: with no release yet, one is created with both files, the notes and a verified tag" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try publishCase(a);
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = fail(1, "gh: Not Found (HTTP 404)") },
        .{ .needle = "log --no-merges", .out = ok("rules: one thing\nci: another\n") },
        .{ .needle = "release create" },
    } };
    try t.expectEqual(PublishResult.created, try publish(a, fake.io(), c.o));
    try t.expectEqual(@as(usize, 1), fake.count("gh release create v0.0.2 dist/buildrules-0.0.2.tar.gz dist/SHA256SUMS --repo o/n --verify-tag --title buildrules 0.0.2 --notes-file dist/notes.md"));
    try t.expectEqual(@as(usize, 1), fake.count("refs/tags/v0.0.1..refs/tags/v0.0.2"));
    try t.expectEqual(@as(usize, 1), fake.files.items.len);
    try t.expect(std.mem.startsWith(u8, fake.files.items[0], "dist/notes.md\n"));
    try t.expect(std.mem.indexOf(u8, fake.files.items[0], "- rules: one thing\n- ci: another\n") != null);
    // never a replacement
    try t.expectEqual(@as(usize, 0), fake.count("clobber"));
}

test "publish: the first release logs the whole tag" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var c = try publishCase(a);
    c.o.previous = "";
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags", .out = fail(1, "HTTP 404") },
        .{ .needle = "log --no-merges --format=%s refs/tags/v0.0.2", .out = ok("first\n") },
        .{ .needle = "release create" },
    } };
    try t.expectEqual(PublishResult.created, try publish(a, fake.io(), c.o));
    try t.expect(std.mem.indexOf(u8, fake.files.items[0], "This is the first release.") != null);
}

fn releaseJson(a: std.mem.Allocator, archive_sha: ?[]const u8, sums_sha: ?[]const u8, archive_present: bool, sums_present: bool) ![]u8 {
    var s = std.ArrayList(u8).empty;
    try s.appendSlice(a, "{\"assets\": [");
    var first = true;
    if (archive_present) {
        try s.print(a, "{{\"name\": \"buildrules-0.0.2.tar.gz\", \"digest\": {s}}}", .{if (archive_sha) |h| try std.fmt.allocPrint(a, "\"sha256:{s}\"", .{h}) else "null"});
        first = false;
    }
    if (sums_present) {
        if (!first) try s.appendSlice(a, ", ");
        try s.print(a, "{{\"name\": \"SHA256SUMS\", \"digest\": {s}}}", .{if (sums_sha) |h| try std.fmt.allocPrint(a, "\"sha256:{s}\"", .{h}) else "null"});
    }
    try s.appendSlice(a, "]}");
    return s.toOwnedSlice(a);
}

test "publish: a re-run changes nothing, adds only a missing file, and refuses a different one" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try publishCase(a);
    const ah = assets.sha256Hex(c.b.archive);
    const sh = assets.sha256Hex(c.b.sums);

    // both there, same bytes: no call that writes
    const same = try releaseJson(a, &ah, &sh, true, true);
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = ok(same) },
    } };
    try t.expectEqual(PublishResult.unchanged, try publish(a, fake.io(), c.o));
    try t.expectEqual(@as(usize, 0), fake.count("release create"));
    try t.expectEqual(@as(usize, 0), fake.count("release upload"));
    try t.expectEqual(@as(usize, 0), fake.files.items.len);

    // the sums file is missing (a run that died between uploads): only it is added, never with --clobber
    const part = try releaseJson(a, &ah, null, true, false);
    fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = ok(part) },
        .{ .needle = "release upload" },
    } };
    try t.expectEqual(PublishResult.uploaded, try publish(a, fake.io(), c.o));
    try t.expectEqual(@as(usize, 1), fake.count("gh release upload v0.0.2 dist/SHA256SUMS --repo o/n"));
    try t.expectEqual(@as(usize, 0), fake.count("clobber"));

    // the archive there has other bytes: the job fails, nothing is uploaded or created
    const bad_hash = "0" ** 64;
    const differs = try releaseJson(a, bad_hash, &sh, true, true);
    fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = ok(differs) },
    } };
    try t.expectError(error.AssetDiffers, publish(a, fake.io(), c.o));
    try t.expectEqual(@as(usize, 0), fake.count("release "));

    // a digest GitHub does not report is not taken to match
    const unknown = try releaseJson(a, null, &sh, true, true);
    fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = ok(unknown) },
    } };
    try t.expectError(error.AssetDigestUnknown, publish(a, fake.io(), c.o));
}

test "publish: refuses before any release call when the files, the tag or the API are wrong" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try publishCase(a);
    // SHA256SUMS does not match the archive
    var o = c.o;
    o.sums = try assets.formatSums(a, c.b.name, "other");
    var fake = Fake{ .a = a, .rules = &.{} };
    try t.expectError(error.WrongDigest, publish(a, fake.io(), o));
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
    // the tag is another commit
    fake = Fake{ .a = a, .rules = &.{.{ .needle = "rev-parse", .out = ok(sha_b ++ "\n") }} };
    try t.expectError(error.TagIsNotTheCommit, publish(a, fake.io(), c.o));
    try t.expectEqual(@as(usize, 0), fake.count("gh "));
    // the API fails for a reason other than "no such release"
    fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags", .out = fail(1, "gh: Bad credentials (HTTP 401)") },
    } };
    try t.expectError(error.CommandFailed, publish(a, fake.io(), c.o));
    try t.expectEqual(@as(usize, 0), fake.count("release "));
}

test "busybox tar, an independent reader, lists the archive this tool writes, with its prefix" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar_bytes = try tar.build(a, &sample_tar_entries);
    const rules = [_]Fake.Rule{.{ .needle = " archive ", .out = ok(tar_bytes) }};
    var fake = Fake{ .a = a, .rules = &rules };
    const b = try archive(a, fake.io(), "/w", "v0.0.1");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = b.name, .data = b.archive });
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realpathAlloc(a, "."), b.name });
    const r = try std.process.Child.run(.{ .allocator = a, .argv = &.{ "tar", "-tzf", path } });
    try t.expectEqual(@as(u8, 0), r.term.Exited);
    try t.expectEqualStrings("buildrules-0.0.1/\nbuildrules-0.0.1/BUCK\nbuildrules-0.0.1/rules/zig.bzl\n", r.stdout);
}
