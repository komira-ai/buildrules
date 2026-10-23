//! The steps of the automatic release (RELEASING.md), each a function of an `Io` (the commands it runs and the files it writes), so the
//! tests drive them with a fake that records the calls. The order is plan, archive, verify, tag, publish: nothing is tagged until the archive
//! of the tested commit is built, attested and verified, so a failure before the tag leaves no tag behind.
//!
//!  - `plan`: which version, if any, this commit is released as (reads tags, writes nothing);
//!  - `archive`: the deterministic source archive of a commit under the planned version's prefix, and its SHA256SUMS;
//!  - `verify`: everything that must hold before a file is published (nothing here writes);
//!  - `tag` (`settleTag`): fetches the tags again, in the serialized job, and then either ends the run as superseded (its commit is contained in the newest
//!    release tag's commit), refuses (the planned number was taken by another commit), or makes the annotated tag of the verified commit (the one step that
//!    writes the repository, with publish), and says which tag publish, the site and the bump take;
//!  - `publish`: the GitHub release of the verified files, created once and never changed.
const std = @import("std");
const version = @import("version.zig");
const gz = @import("gz.zig");
const tar = @import("tar.zig");
const assets = @import("assets.zig");
const binhdr = @import("binhdr");
const debfile = @import("debs.zig");
const page = @import("page.zig");
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

// ---- plan ---------------------------------------------------------------------------------------------------------------------------------

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

pub const PlanOpts = struct {
    root: []const u8,
    sha: []const u8,
    /// The content of the `VERSION` file at `sha`.
    version_file: []const u8,
    /// The repository variable RELEASE_FREEZE, as the workflow gives it: empty or `false` (released as usual) or `true` (nothing is released). Read here and nowhere else.
    freeze: []const u8 = "",
    /// The dry run (the release workflow no longer asks for it: no pull request runs the pipeline): the version the commit would be released as, whatever the commit changed, with nothing created.
    dry: bool = false,
    /// `OWNER/NAME`. When given, and the commit already has its release tag, the plan asks GitHub whether that release is complete (`releaseComplete`).
    /// Empty: it does not ask, and `complete` is false.
    repo: []const u8 = "",
};

pub const Plan = struct {
    released: bool,
    /// The commit's release already holds every file of a release, with the digests this commit's build must reproduce, so the build and the jobs that only
    /// produce the same files again are skipped. False for a new release, for one that lacks a file or holds another digest, and whenever it could not be told.
    complete: bool = false,
    /// The commit has no tag yet, so the tag job creates it (false when the commit already has one: a re-run).
    new: bool = false,
    tag: []const u8 = "",
    number: []const u8 = "",
    previous: []const u8 = "",
    reason: []const u8,
};

/// The `key=value` lines the job appends to $GITHUB_OUTPUT.
pub fn planOutputs(a: std.mem.Allocator, r: Plan) ![]u8 {
    return std.fmt.allocPrint(a, "released={s}\nnew={s}\ncomplete={s}\ntag={s}\nnumber={s}\nprevious={s}\nreason={s}\n", .{
        if (r.released) "true" else "false",
        if (r.new) "true" else "false",
        if (r.complete) "true" else "false",
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

/// The value of RELEASE_FREEZE: `true` freezes, empty and `false` do not, and anything else is an error (a misspelt freeze must stop the plan, not release).
fn freezeState(v: []const u8) !bool {
    if (std.mem.eql(u8, v, "true")) return true;
    if (v.len == 0 or std.mem.eql(u8, v, "false")) return false;
    std.debug.print("release: RELEASE_FREEZE is `{s}`; it is `true` to freeze a release, and empty or `false` otherwise\n", .{v});
    return error.BadFreeze;
}

pub fn plan(a: std.mem.Allocator, io: Io, o: PlanOpts) !Plan {
    if (!isSha(o.sha)) return error.BadSha;
    const mm = try version.parseMajorMinor(o.version_file);
    const frozen = try freezeState(o.freeze);
    const refs = try must(io, a, &.{ "git", "-C", o.root, "for-each-ref", "--format=%(refname:strip=2)%09%(objecttype)%09%(objectname)%09%(*objectname)", "refs/tags/" });
    const tags = try parseTagRefs(a, refs);
    var all = std.ArrayList(version.Version).empty;
    for (tags) |tg| try all.append(a, tg.v);

    // The dry run (the release workflow no longer asks for it: no pull request runs the pipeline) walks every stage that creates nothing, so it takes the next number whatever the commit changed and whatever the freeze says
    // (a freeze stops a release; this makes none).
    if (o.dry) {
        const next_dry = try version.next(all.items, mm);
        const last_dry = version.latest(all.items);
        return .{
            .released = true,
            .new = true,
            .tag = try version.tagName(a, next_dry),
            .number = try version.numberText(a, next_dry),
            .previous = if (last_dry) |l| tagOf(tags, l) else "",
            .reason = "dry run: nothing is created",
        };
    }
    // The freeze stops everything that follows: no stage after the plan runs, so nothing is tagged or published, a re-run of an old run included.
    if (frozen) return .{ .released = false, .previous = if (version.latest(all.items)) |l| tagOf(tags, l) else "", .reason = "release freeze: RELEASE_FREEZE is true" };

    // A commit that already has a release tag is that release (this run is a re-run): nothing is created, the later jobs go on.
    var have: ?version.Version = null;
    for (tags) |tg| {
        if (std.mem.eql(u8, tg.commit, o.sha) and (have == null or version.Version.order(tg.v, have.?) == .gt)) have = tg.v;
    }
    if (have) |h| {
        const tag = tagOf(tags, h);
        var complete = false;
        if (o.repo.len != 0) {
            complete = releaseComplete(a, io, .{ .root = o.root, .repo = o.repo, .tag = tag, .sha = o.sha }) catch |e| blk: {
                // Not being able to tell is not a reason to skip the build: it only costs time.
                std.debug.print("release: could not tell whether {s} is complete ({s}); the build runs\n", .{ tag, @errorName(e) });
                break :blk false;
            };
        }
        return .{
            .released = true,
            .complete = complete,
            .tag = tag,
            .number = try version.numberText(a, h),
            .previous = if (version.previousOf(all.items, h)) |p| tagOf(tags, p) else "",
            .reason = if (complete) "this commit's release is complete: it holds every file, with the digests of its SHA256SUMS" else "this commit already has its release tag",
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

    return .{ .released = true, .new = true, .tag = try version.tagName(a, next), .number = try version.numberText(a, next), .previous = previous, .reason = "a release commit" };
}

pub const CompleteOpts = struct {
    root: []const u8,
    repo: []const u8,
    /// The tag the commit already has.
    tag: []const u8,
    sha: []const u8,
};

/// True when the GitHub release of `o.tag` holds all fourteen files of a release (the archive, the three tarballs, the two .debs, SHA256SUMS and a bundle for each
/// of those seven) with the digests this commit's build must produce, so a run for the commit has nothing left to build or publish. The expected digests are:
/// the archive's, rebuilt here from the commit (`archive` is deterministic); SHA256SUMS's, the sha256 of the SHA256SUMS the release holds; the tarballs' and the
/// .debs', the lines of that SHA256SUMS (the build is deterministic, which publish relies on when it refuses a different file). The comparison is
/// `assets.publishPlan`, the one publish uses, and only `.nothing` counts: a release with one file missing, one digest different or one digest unreported is
/// not complete, so the build runs and publish adds the file or refuses the difference. A bundle only has to be there (every signing makes a new one).
pub fn releaseComplete(a: std.mem.Allocator, io: Io, o: CompleteOpts) !bool {
    const v = version.parseTag(o.tag) orelse return error.BadTag;
    const number = try version.numberText(a, v);
    const built = try archive(a, io, o.root, o.tag, o.sha);
    const archive_hex = assets.sha256Hex(built.archive);

    const existing = try io.run(a, &.{ "gh", "api", try std.fmt.allocPrint(a, "repos/{s}/releases/tags/{s}", .{ o.repo, o.tag }) });
    if (existing.code != 0) return false;
    const held = try assets.parseAssets(a, existing.stdout);

    const downloaded = try io.run(a, &.{ "gh", "release", "download", o.tag, "--repo", o.repo, "--pattern", sums_name, "--output", "-" });
    if (downloaded.code != 0 or downloaded.stdout.len == 0) return false;
    const sums = downloaded.stdout;

    // The seven files that SHA256SUMS or the digest of its own bytes vouches for, then the bundle of each.
    const n_cli = binhdr.targets.len;
    var names: [n_cli + debfile.debs.len + 2][]const u8 = undefined;
    var ours: [2 * names.len]assets.File = undefined;
    names[0] = built.name;
    for (binhdr.targets, 0..) |tg, i| names[1 + i] = try cliName(a, number, tg);
    for (debfile.debs, 0..) |d, i| names[1 + n_cli + i] = try debfile.name(a, number, d.arch);
    names[names.len - 1] = sums_name;
    const sums_hex = assets.sha256Hex(sums);
    for (names[0 .. names.len - 1], 0..) |n, i| {
        const listed = page.digestOf(sums, n) catch return false;
        // The archive is checked against the commit, not only against the release's own list of it.
        if (i == 0 and !std.mem.eql(u8, listed, &archive_hex)) return false;
        ours[i] = .{ .name = n, .sha256 = listed };
    }
    ours[names.len - 1] = .{ .name = sums_name, .sha256 = &sums_hex };
    for (names, names.len..) |n, i| {
        const bundle = try std.fmt.allocPrint(a, "{s}" ++ bundle_suffix, .{n});
        ours[i] = .{ .name = bundle, .sha256 = assets.heldDigest(held, bundle) orelse "" };
    }
    return assets.releaseHolds(a, held, &ours);
}

// ---- tag ----------------------------------------------------------------------------------------------------------------------------------

pub const TagOpts = struct {
    root: []const u8,
    repo: []const u8,
    /// The planned tag, `vMAJOR.MINOR.PATCH`.
    tag: []const u8,
    /// The commit that was archived and verified.
    sha: []const u8,
};

pub const TagMade = enum { created, existed };

/// Creates the annotated tag `o.tag` at `o.sha`, after the archive of that commit was verified. A tag that already names `o.sha` is a re-run and
/// stays as it is; a tag that names another commit is an error (another release took the number), and nothing is created.
pub fn createTag(a: std.mem.Allocator, io: Io, o: TagOpts) !TagMade {
    if (!isSha(o.sha)) return error.BadSha;
    const v = version.parseTag(o.tag) orelse return error.BadTag;
    const number = try version.numberText(a, v);
    const have = try io.run(a, &.{ "git", "-C", o.root, "rev-parse", "--verify", "--quiet", try std.fmt.allocPrint(a, "refs/tags/{s}^{{commit}}", .{o.tag}) });
    if (have.code == 0) {
        if (std.mem.eql(u8, trimNl(have.stdout), o.sha)) return .existed;
        std.debug.print("release: the tag {s} already names {s}, not {s}\n", .{ o.tag, trimNl(have.stdout), o.sha });
        return error.TagNamesOtherCommit;
    }
    const message = try std.fmt.allocPrint(a, "buildrules {s}\n\nautomatic release of commit {s}\n", .{ number, o.sha });
    const object = trimNl(try must(io, a, &.{
        "gh",                                                                  "api",                                                       "--method", "POST",
        try std.fmt.allocPrint(a, "repos/{s}/git/tags", .{o.repo}),            "-f",                                                        try std.fmt.allocPrint(a, "tag={s}", .{o.tag}),
        "-f",                                                                  try std.fmt.allocPrint(a, "message={s}", .{message}),       "-f",       try std.fmt.allocPrint(a, "object={s}", .{o.sha}),
        "-f",                                                                  "type=commit",                                               "-f",       "tagger[name]=" ++ bot_name,
        "-f",                                                                  "tagger[email]=" ++ bot_email,                               "--jq",     ".sha",
    }));
    if (!isSha(object)) return error.BadTagObject;
    // A tag that exists is refused here by GitHub (422), which is the "fail if the tag already exists" for a race the check above missed.
    _ = try must(io, a, &.{
        "gh",  "api",                                                  "--method", "POST",
        try std.fmt.allocPrint(a, "repos/{s}/git/refs", .{o.repo}), "-f",       try std.fmt.allocPrint(a, "ref=refs/tags/{s}", .{o.tag}),
        "-f",  try std.fmt.allocPrint(a, "sha={s}", .{object}),
    });
    return .created;
}

pub const SettleOpts = struct {
    root: []const u8,
    repo: []const u8,
    /// The tag the plan chose when the run began (provisional: the build stamped its number into the binaries and the archive).
    tag: []const u8,
    sha: []const u8,
};

pub const Settled = struct {
    /// The commit is contained in the newest release tag's commit: that release carries its changes, so this run makes no tag, release or bump.
    superseded: bool,
    made: ?TagMade = null,
    /// The tag that names `sha` after this step (empty when superseded). Publish, site and bump take it from here, not from the plan.
    tag: []const u8 = "",
    number: []const u8 = "",
    reason: []const u8,
};

/// The `key=value` lines the tag job appends to $GITHUB_OUTPUT.
pub fn settleOutputs(a: std.mem.Allocator, r: Settled) ![]u8 {
    return std.fmt.allocPrint(a, "superseded={s}\ntag={s}\nnumber={s}\nmade={s}\nreason={s}\n", .{
        if (r.superseded) "true" else "false",
        r.tag,
        r.number,
        if (r.made) |m| @tagName(m) else "none",
        r.reason,
    });
}

/// The tag step, inside the serialized job (concurrency group `release`): the plan ran long ago, and two pushes that landed close together both planned
/// the same number. So the tags are fetched again here and the decision is made on what exists now:
///  - a tag that names `sha` already is this release (a re-run): it must be the planned one, and it is kept;
///  - `sha` contained in the commit of the newest release tag (an ancestor of it, or it): that release carries these changes, so the run ends as
///    superseded and makes nothing;
///  - otherwise the next free number is the planned one, and the tag is made; if it is not (another run took the number first), the run fails
///    with `NumberTaken`: the binaries, the archive, the sums, the signatures and the attestations carry the planned number, so the run cannot be
///    tagged under another one without rebuilding, and nothing in the job that holds the token rebuilds. A re-run of the whole workflow plans
///    again, from the tags that exist, and releases the commit under the free number.
pub fn settleTag(a: std.mem.Allocator, io: Io, o: SettleOpts) !Settled {
    if (!isSha(o.sha)) return error.BadSha;
    const planned = version.parseTag(o.tag) orelse return error.BadTag;
    _ = try must(io, a, &.{ "git", "-C", o.root, "fetch", "--force", "--quiet", "--tags", "origin" });
    const refs = try must(io, a, &.{ "git", "-C", o.root, "for-each-ref", "--format=%(refname:strip=2)%09%(objecttype)%09%(objectname)%09%(*objectname)", "refs/tags/" });
    const tags = try parseTagRefs(a, refs);
    var all = std.ArrayList(version.Version).empty;
    for (tags) |tg| try all.append(a, tg.v);

    for (tags) |tg| {
        if (!std.mem.eql(u8, tg.commit, o.sha)) continue;
        if (version.Version.order(tg.v, planned) != .eq) {
            std.debug.print("release: the commit {s} already has the tag {s}, but this run was built as {s}: refusing to make a second tag\n", .{ o.sha, tg.name, o.tag });
            return error.TagMismatch;
        }
        const made = try createTag(a, io, .{ .root = o.root, .repo = o.repo, .tag = o.tag, .sha = o.sha });
        return .{ .superseded = false, .made = made, .tag = o.tag, .number = try version.numberText(a, planned), .reason = "this commit already has its release tag" };
    }

    if (version.latest(all.items)) |newest| {
        const newest_commit = tagCommit(tags, newest);
        const anc = try io.run(a, &.{ "git", "-C", o.root, "merge-base", "--is-ancestor", o.sha, newest_commit });
        if (anc.code == 0) {
            const name = tagOf(tags, newest);
            const reason = try std.fmt.allocPrint(a, "{s} is contained in {s} ({s}), which was tagged while this run was building: that release carries its changes, so this run makes no tag, release or bump", .{ o.sha, name, newest_commit });
            return .{ .superseded = true, .reason = reason };
        }
        if (anc.code != 1) {
            std.debug.print("release: git merge-base exited {d}: {s}\n", .{ anc.code, anc.stderr });
            return error.CommandFailed;
        }
    }

    const free = try version.next(all.items, .{ .major = planned.major, .minor = planned.minor });
    if (version.Version.order(free, planned) != .eq) {
        std.debug.print("release: {s} was planned and built for {s}, but the next free number is {s} (another run tagged first, at another commit): nothing is tagged; re-run all jobs of this run to release the commit as {s}\n", .{ o.tag, o.tag, try version.tagName(a, free), try version.tagName(a, free) });
        return error.NumberTaken;
    }
    const made = try createTag(a, io, .{ .root = o.root, .repo = o.repo, .tag = o.tag, .sha = o.sha });
    return .{ .superseded = false, .made = made, .tag = o.tag, .number = try version.numberText(a, planned), .reason = "the planned number is free" };
}

fn tagCommit(tags: []const TagRef, v: version.Version) []const u8 {
    for (tags) |tg| {
        if (version.Version.order(tg.v, v) == .eq) return tg.commit;
    }
    return "";
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

/// The source archive of the commit `sha` (the one that was tested, not a tag: the tag is made after the archive is verified): `git archive` of its tree under `buildrules-<number>/`, every entry stamped `archive_mtime` and
/// with the modes of umask 022, compressed by `gz.gzip` (no gzip, no zlib, no git compression), named for the number.
pub fn archive(a: std.mem.Allocator, io: Io, root: []const u8, tag_name: []const u8, sha: []const u8) !Built {
    if (!isSha(sha)) return error.BadSha;
    const v = version.parseTag(tag_name) orelse return error.BadTag;
    const number = try version.numberText(a, v);
    const prefix = try std.fmt.allocPrint(a, "buildrules-{s}/", .{number});
    const tar_bytes = try must(io, a, &.{
        "git", "-C", root, "-c", "core.autocrlf=false", "-c", "core.eol=lf", "-c", "tar.umask=0022",
        "archive",                                          "--format=tar", try std.fmt.allocPrint(a, "--prefix={s}", .{prefix}), "--mtime=" ++ archive_mtime, sha,
    });
    const archive_bytes = try gz.gzip(a, tar_bytes);
    const name = try std.fmt.allocPrint(a, "buildrules-{s}.tar.gz", .{number});
    return .{ .name = name, .archive = archive_bytes, .sums = try assets.formatSums(a, name, archive_bytes), .prefix = prefix };
}

// ---- verify -----------------------------------------------------------------------------------------------------------------------------

/// A file of the release, by name and bytes.
pub const Blob = assets.Named;

/// The issuer of the certificate a keyless signature of this workflow carries.
pub const oidc_issuer = "https://token.actions.githubusercontent.com";

const tar_suffix = ".tar.gz";
const bundle_suffix = assets.bundle_suffix;

/// `buildrules-cli-<number>-<target>.tar.gz`
pub fn cliName(a: std.mem.Allocator, number: []const u8, target: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "buildrules-cli-{s}-{s}" ++ tar_suffix, .{ number, target });
}

fn blobNamed(blobs: []const Blob, name: []const u8) ?Blob {
    for (blobs) |b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

/// The bytes of `buildrules` inside the command-line tarball of `target`.
fn tarballBinary(a: std.mem.Allocator, number: []const u8, target: []const u8, tarball: []const u8) ![]const u8 {
    const entries = try tar.parse(a, try gz.gunzip(a, tarball));
    const want = try std.fmt.allocPrint(a, "buildrules-cli-{s}-{s}/buildrules", .{ number, target });
    for (entries) |e| {
        if (e.kind == .file and std.mem.eql(u8, e.name, want)) return e.data;
    }
    return error.NoBinaryInTarball;
}

/// Tries of `cosign verify-blob` per file when it cannot fetch the Sigstore trusted root.
const cosign_tries: u32 = 3;

/// The default delay before the second try (ms); the third waits twice as long.
pub const default_retry_ms: u32 = 2000;

/// The most that one `verify` waits in all, across every file (ms). A try whose wait would pass it is not made: the fetch failure is reported at once.
/// The default waits cost 6000 ms for a file whose fetch never works, so the budget lets two such files retry fully and no more.
pub const max_total_wait_ms: u64 = 12_000;

/// cosign's FINAL stderr line says the trusted root (the TUF repository) could not be fetched: a network failure that says nothing about the
/// signature. Only these retry; any other refusal (a signature or certificate mismatch) is final. Only the last line counts: in legacy-bundle
/// mode cosign prints the `Could not fetch trusted_root.json ... Continuing` warning and may then report a real mismatch, which is a verdict.
/// One more shape retries: cosign v3.0.6 (cmd/cosign/cli/verify/common.go, under `co.TrustedMaterial == nil && !verifyOfflineWithKey`) ends a failed fetch with `trusted root is required when
/// using new bundle format`, raised when the trusted material is nil after the fetch failed, and the fetch error itself is only an earlier warning line. That final
/// line retries only when an earlier line holds one of the fetch markers; alone it says nothing about why the root is missing.
fn isTrustedRootFetchFailure(stderr: []const u8) bool {
    const text = std.mem.trim(u8, stderr, " \r\n");
    const cut = std.mem.lastIndexOfScalar(u8, text, '\n');
    const last = if (cut) |i| text[i + 1 ..] else text;
    const earlier = if (cut) |i| text[0..i] else "";
    const markers = [_][]const u8{ "tuf refresh failed", "Could not fetch trusted_root.json", "error getting live trusted root" };
    for (markers) |m| {
        if (std.mem.indexOf(u8, last, m) != null) return true;
    }
    if (std.mem.indexOf(u8, last, "trusted root is required when using new bundle format") != null) {
        for (markers) |m| {
            if (std.mem.indexOf(u8, earlier, m) != null) return true;
        }
    }
    return false;
}


/// The waits (in ms) that `verify` would have slept between the tries of `cosign verify-blob`; for tests.
pub const Waits = struct {
    ms: [16]u64 = [_]u64{0} ** 16,
    n: usize = 0,
};

pub const VerifyOpts = struct {
    root: []const u8,
    repo: []const u8,
    tag: []const u8,
    sha: []const u8,
    /// The directory holding the release files (the attestations and signatures are checked on these files).
    dist: []const u8,
    archive_name: []const u8,
    archive: []const u8,
    /// The SHA256SUMS of the source archive, the three command-line tarballs and the two .debs.
    sums: []const u8,
    /// The workflow that signed the attestations, `.github/workflows/release.yml`.
    workflow: []const u8,
    /// The `buildrules` program of the linux-x86_64 target, built again from the commit with the planned version stamped in (`-c buildrules.release_version`);
    /// verify runs it.
    cli: []const u8,
    /// The bytes of that file: they must be the program inside the linux-x86_64 tarball, so the version it prints is the version of the file that ships.
    cli_bytes: []const u8 = "",
    /// The three command-line tarballs of `dist`, exactly as they are to be published.
    tarballs: []const Blob = &.{},
    /// The same three tarballs, made again from a fresh build of the commit: byte for byte the same, or the build is not reproducible.
    rebuilt: []const Blob = &.{},
    /// The two .debs of `dist` (`buildrules_<V>_<arch>.deb`), exactly as they are to be published, and the same two made again from the second build.
    debs: []const Blob = &.{},
    rebuilt_debs: []const Blob = &.{},
    /// The dry run (the release workflow no longer asks for it: no pull request runs the pipeline): nothing is signed or attested there, so the signatures and attestations are not checked. Everything else is.
    dry: bool = false,
    cosign: []const u8 = "cosign",
    /// The delay before the second try of a `cosign verify-blob` that could not fetch the trusted root; the third waits twice as long.
    retry_ms: u32 = default_retry_ms,
    /// A test seam: when set, the waits between the tries are recorded here and not slept.
    waits: ?*Waits = null,
};

/// Every reason the files must not be published; empty when there is none. Nothing is written.
pub fn verify(a: std.mem.Allocator, io: Io, o: VerifyOpts) !assets.Findings {
    var f = assets.Findings.empty;
    const v = version.parseTag(o.tag) orelse {
        try assets.add(a, &f, "`{s}` is not a release tag (vMAJOR.MINOR.PATCH)", .{o.tag});
        return f;
    };
    const number = try version.numberText(a, v);
    const want_name = try std.fmt.allocPrint(a, "buildrules-{s}" ++ tar_suffix, .{number});
    if (!std.mem.eql(u8, want_name, o.archive_name)) try assets.add(a, &f, "the archive is named {s}, the tag names {s}", .{ o.archive_name, want_name });

    // 0. the command-line tarballs are the three of this version, each once, and nothing else.
    var want_tarballs = std.ArrayList([]const u8).empty;
    for (binhdr.targets) |tg| try want_tarballs.append(a, try cliName(a, number, tg));
    for (want_tarballs.items) |n| {
        var count: usize = 0;
        for (o.tarballs) |b| {
            if (std.mem.eql(u8, b.name, n)) count += 1;
        }
        if (count != 1) try assets.add(a, &f, "dist holds {d} files named {s}, not one", .{ count, n });
    }
    if (o.tarballs.len != want_tarballs.items.len) try assets.add(a, &f, "dist holds {d} command-line tarballs, not {d}", .{ o.tarballs.len, want_tarballs.items.len });

    // 0b. and the .debs are the two of this version, once each, and nothing else.
    var want_debs = std.ArrayList([]const u8).empty;
    for (debfile.debs) |d| try want_debs.append(a, try debfile.name(a, number, d.arch));
    for (want_debs.items) |n| {
        var count: usize = 0;
        for (o.debs) |b| {
            if (std.mem.eql(u8, b.name, n)) count += 1;
        }
        if (count != 1) try assets.add(a, &f, "dist holds {d} files named {s}, not one", .{ count, n });
    }
    if (o.debs.len != want_debs.items.len) try assets.add(a, &f, "dist holds {d} .debs, not {d}", .{ o.debs.len, want_debs.items.len });

    // 1. the archive, the tarballs and the .debs are the files SHA256SUMS lists, each once, in name order.
    var listed = std.ArrayList(Blob).empty;
    try listed.append(a, .{ .name = o.archive_name, .bytes = o.archive });
    try listed.appendSlice(a, o.tarballs);
    try listed.appendSlice(a, o.debs);
    assets.checkSumsFiles(o.sums, listed.items) catch |e| try assets.add(a, &f, "SHA256SUMS does not match the release files: {s}", .{@errorName(e)});

    // 2. the checkout is the commit being released (no tag exists yet: it is made after this).
    const head = try io.run(a, &.{ "git", "-C", o.root, "rev-parse", "--verify", "HEAD^{commit}" });
    if (head.code != 0 or !std.mem.eql(u8, trimNl(head.stdout), o.sha)) try assets.add(a, &f, "the checkout is not commit {s}", .{o.sha});

    // 3. every file carries an attestation of this workflow, for this commit, on main, and a keyless signature of the same identity. A dry run
    // signs nothing and has none to check.
    var signed = std.ArrayList([]const u8).empty;
    try signed.append(a, o.archive_name);
    try signed.appendSlice(a, want_tarballs.items);
    try signed.appendSlice(a, want_debs.items);
    try signed.append(a, sums_name);
    if (!o.dry) {
        const signer = try std.fmt.allocPrint(a, "{s}/{s}", .{ o.repo, o.workflow });
        const identity = try std.fmt.allocPrint(a, "https://github.com/{s}/{s}@refs/heads/main", .{ o.repo, o.workflow });
        var waited_ms: u64 = 0; // all the waiting of the retries below, bounded by max_total_wait_ms
        for (signed.items) |file| {
            const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ o.dist, file });
            const r = try io.run(a, &.{
                "gh",                                "attestation",       "verify",              path,
                "--repo",                            o.repo,              "--signer-workflow",   signer,
                "--signer-digest",                   o.sha,               "--source-digest",     o.sha,
                "--source-ref",                      "refs/heads/main",   "--deny-self-hosted-runners",
            });
            if (r.code != 0) try assets.add(a, &f, "the attestation of {s} does not verify (workflow {s}, commit {s}, refs/heads/main): {s}", .{ file, signer, o.sha, trimNl(r.stderr) });
            const bundle = try std.fmt.allocPrint(a, "{s}" ++ bundle_suffix, .{path});
            var tries: u32 = 1;
            const c = while (true) : (tries += 1) {
                const got = try io.run(a, &.{
                    o.cosign,                             "verify-blob",                  "--bundle",                                   bundle,
                    "--certificate-identity",             identity,                       "--certificate-oidc-issuer",                  oidc_issuer,
                    "--certificate-github-workflow-sha",  o.sha,                          "--certificate-github-workflow-trigger",      "push",
                    "--certificate-github-workflow-repository", o.repo,                   path,
                });
                // Only a failure to fetch the Sigstore trusted root is retried (a network flake, not a verdict on the signature).
                if (got.code == 0 or tries >= cosign_tries or !isTrustedRootFetchFailure(got.stderr)) break got;
                const wait_ms = @as(u64, o.retry_ms) * tries;
                if (waited_ms + wait_ms > max_total_wait_ms) break got;
                waited_ms += wait_ms;
                if (o.waits) |w| {
                    w.ms[w.n] = wait_ms;
                    w.n += 1;
                } else std.Thread.sleep(wait_ms * std.time.ns_per_ms);
            };
            if (c.code != 0 and isTrustedRootFetchFailure(c.stderr)) {
                try assets.add(a, &f, "the signature of {s} could not be checked: cosign could not fetch the Sigstore trusted root in {d} tries (a network failure, not a verdict on the signature): {s}", .{ file, tries, trimNl(c.stderr) });
            } else if (c.code != 0) try assets.add(a, &f, "the signature of {s} does not verify (identity {s}, commit {s}): {s}", .{ file, identity, o.sha, trimNl(c.stderr) });
        }
    }

    // 4. building the source archive again from the commit gives these very bytes.
    if (archive(a, io, o.root, o.tag, o.sha)) |again| {
        if (!std.mem.eql(u8, again.archive, o.archive)) try assets.add(a, &f, "the archive does not reproduce: building {s} again from the commit gives other bytes", .{o.tag});
    } else |e| try assets.add(a, &f, "the archive cannot be built again from the commit: {s}", .{@errorName(e)});

    // 5. building the command line again, from the commit on another machine, gives these very tarballs.
    for (want_tarballs.items) |n| {
        const shipped = blobNamed(o.tarballs, n) orelse continue;
        const again = blobNamed(o.rebuilt, n) orelse {
            try assets.add(a, &f, "the second build holds no {s}: it cannot be compared", .{n});
            continue;
        };
        if (!std.mem.eql(u8, shipped.bytes, again.bytes)) {
            const was = assets.sha256Hex(shipped.bytes);
            const now = assets.sha256Hex(again.bytes);
            try assets.add(a, &f, "{s} does not reproduce: a second build from the commit gives sha256 {s}, the release has {s}", .{ n, &now, &was });
        }
    }
    if (o.rebuilt.len != want_tarballs.items.len) try assets.add(a, &f, "the second build holds {d} tarballs, not {d}", .{ o.rebuilt.len, want_tarballs.items.len });
    for (want_debs.items) |n| {
        const shipped = blobNamed(o.debs, n) orelse continue;
        const again = blobNamed(o.rebuilt_debs, n) orelse {
            try assets.add(a, &f, "the second build holds no {s}: it cannot be compared", .{n});
            continue;
        };
        if (!std.mem.eql(u8, shipped.bytes, again.bytes)) {
            const was = assets.sha256Hex(shipped.bytes);
            const now = assets.sha256Hex(again.bytes);
            try assets.add(a, &f, "{s} does not reproduce: a second build from the commit gives sha256 {s}, the release has {s}", .{ n, &now, &was });
        }
    }
    if (o.rebuilt_debs.len != want_debs.items.len) try assets.add(a, &f, "the second build holds {d} .debs, not {d}", .{ o.rebuilt_debs.len, want_debs.items.len });

    // 5b. each .deb is the package of its version and architecture and holds the very program of the tarball of its target.
    for (debfile.debs) |d| {
        const deb_name = try debfile.name(a, number, d.arch);
        const deb = blobNamed(o.debs, deb_name) orelse continue;
        const tarball = blobNamed(o.tarballs, try cliName(a, number, d.target)) orelse continue;
        const program = tarballBinary(a, number, d.target, tarball.bytes) catch |e| {
            try assets.add(a, &f, "{s} holds no readable `buildrules`: {s}", .{ tarball.name, @errorName(e) });
            continue;
        };
        debfile.check(a, deb.bytes, number, d.arch, program) catch |e| try assets.add(a, &f, "{s} is not the package of the `buildrules` inside {s}: {s}", .{ deb_name, tarball.name, @errorName(e) });
    }

    // 6. the program built for this release prints this release's version: a stamp that is missing, stale (the hard-coded constant it replaced) or of
    // another release is a finding. The program is run exactly as a user runs it, `--version`, and it is the very file the linux-x86_64 tarball holds.
    const want_version = try std.fmt.allocPrint(a, "buildrules {s}", .{number});
    const ran = io.run(a, &.{ o.cli, "--version" }) catch |e| blk: {
        try assets.add(a, &f, "the built program {s} cannot be run: {s}", .{ o.cli, @errorName(e) });
        break :blk null;
    };
    if (ran) |r| {
        if (r.code != 0) {
            try assets.add(a, &f, "`{s} --version` exited {d}: {s}", .{ o.cli, r.code, trimNl(r.stderr) });
        } else if (!std.mem.eql(u8, trimNl(r.stdout), want_version)) {
            try assets.add(a, &f, "`{s} --version` printed `{s}`, the release is `{s}`: the program was not built with the release's version", .{ o.cli, trimNl(r.stdout), want_version });
        }
    }
    if (blobNamed(o.tarballs, want_tarballs.items[0])) |linux| {
        const inside: ?[]const u8 = tarballBinary(a, number, binhdr.targets[0], linux.bytes) catch |e| blk: {
            try assets.add(a, &f, "{s} holds no readable `buildrules`: {s}", .{ linux.name, @errorName(e) });
            break :blk null;
        };
        if (inside) |bytes| {
            if (!std.mem.eql(u8, bytes, o.cli_bytes)) try assets.add(a, &f, "the program run for its version ({s}) is not the `buildrules` inside {s}: the version it printed says nothing about the file that ships", .{ o.cli, linux.name });
        }
    }

    // 7. its files are the commit's tracked files, 8. and the scrub passes on them.
    const tree = try io.run(a, &.{ "git", "-C", o.root, "ls-tree", "-r", "-z", "--name-only", o.sha });
    if (tree.code != 0) {
        try assets.add(a, &f, "cannot list the files of the commit: {s}", .{trimNl(tree.stderr)});
        return f;
    }
    var tracked = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, tree.stdout, 0);
    while (it.next()) |p| {
        if (p.len != 0) try tracked.append(a, p);
    }
    if (tracked.items.len == 0) try assets.add(a, &f, "the commit {s} tracks no file", .{o.sha});
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
    /// The three command-line tarballs of `dist`.
    tarballs: []const Blob = &.{},
    /// The two .debs of `dist`.
    debs: []const Blob = &.{},
    /// The `<file>.sigstore.json` of each of the seven files above (the archive, the three tarballs, the two .debs and SHA256SUMS).
    bundles: []const Blob = &.{},
};

pub const PublishResult = enum { created, uploaded, unchanged };

/// The files a release holds, in the order they are listed: the source archive, the three tarballs (target order), the two .debs (architecture order), SHA256SUMS,
/// then the signature bundle of each of those seven. A tarball, a .deb or a bundle that is missing, empty or not expected is an error: a release is made of
/// exactly these fourteen files.
fn releaseFiles(a: std.mem.Allocator, o: PublishOpts, number: []const u8) ![]Blob {
    var out = std.ArrayList(Blob).empty;
    try out.append(a, .{ .name = o.archive_name, .bytes = o.archive });
    for (binhdr.targets) |tg| {
        const n = try cliName(a, number, tg);
        try out.append(a, blobNamed(o.tarballs, n) orelse return error.MissingTarball);
    }
    if (o.tarballs.len != binhdr.targets.len) return error.StrayTarball;
    for (debfile.debs) |d| {
        const n = try debfile.name(a, number, d.arch);
        try out.append(a, blobNamed(o.debs, n) orelse return error.MissingDeb);
    }
    if (o.debs.len != debfile.debs.len) return error.StrayDeb;
    try out.append(a, .{ .name = sums_name, .bytes = o.sums });
    const payload = out.items.len;
    // by index: appending to `out` moves its items
    for (0..payload) |i| {
        const n = try std.fmt.allocPrint(a, "{s}" ++ bundle_suffix, .{out.items[i].name});
        const b = blobNamed(o.bundles, n) orelse return error.MissingBundle;
        if (b.bytes.len == 0) return error.MissingBundle;
        try out.append(a, b);
    }
    if (o.bundles.len != payload) return error.StrayBundle;
    return out.toOwnedSlice(a);
}

/// Creates the release of the tag with the archive, the three command-line tarballs, the two .debs, SHA256SUMS, a signature bundle for each of them and the notes, or adds
/// the files an existing release lacks, or does nothing. A release that already holds a file with other bytes fails the job and changes nothing: no asset
/// is replaced.
pub fn publish(a: std.mem.Allocator, io: Io, o: PublishOpts) !PublishResult {
    const v = version.parseTag(o.tag) orelse return error.BadTag;
    const number = try version.numberText(a, v);
    const files = try releaseFiles(a, o, number);
    const payload_files = 1 + binhdr.targets.len + debfile.debs.len;
    try assets.checkSumsFiles(o.sums, files[0..payload_files]);

    const peeled = try must(io, a, &.{ "git", "-C", o.root, "rev-parse", "--verify", try std.fmt.allocPrint(a, "refs/tags/{s}^{{commit}}", .{o.tag}) });
    if (!std.mem.eql(u8, trimNl(peeled), o.sha)) return error.TagIsNotTheCommit;

    var ours_list = std.ArrayList(assets.File).empty;
    for (files) |b| {
        const hex = assets.sha256Hex(b.bytes);
        try ours_list.append(a, .{ .name = b.name, .sha256 = try a.dupe(u8, &hex) });
    }
    const ours = ours_list.items;
    const existing = try io.run(a, &.{ "gh", "api", try std.fmt.allocPrint(a, "repos/{s}/releases/tags/{s}", .{ o.repo, o.tag }) });
    var have: ?[]const assets.Asset = null;
    if (existing.code == 0) {
        have = try assets.parseAssets(a, existing.stdout);
    } else if (std.mem.indexOf(u8, existing.stderr, "404") == null) {
        std.debug.print("release: gh api exited {d}: {s}\n", .{ existing.code, existing.stderr });
        return error.CommandFailed;
    }
    const doing = try assets.publishPlan(a, have, ours);
    switch (doing) {
        .nothing => return .unchanged,
        .upload => |names| {
            var argv = std.ArrayList([]const u8).empty;
            try argv.appendSlice(a, &.{ "gh", "release", "upload", o.tag });
            for (names) |n| try argv.append(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ o.dist, n }));
            try argv.appendSlice(a, &.{ "--repo", o.repo });
            _ = try must(io, a, argv.items);
            return .uploaded;
        },
        .create => {
            // Never create a release below one that exists: a re-run of an old run's failed jobs, after a newer release, would otherwise
            // publish the lower number afterwards (and could take over "Latest"). Only creating is guarded: a missing file of a release
            // that exists is still added above. A tag with no release does not block anything (RELEASING.md, "When something fails").
            const listing = try must(io, a, &.{ "gh", "api", "--paginate", try std.fmt.allocPrint(a, "repos/{s}/releases?per_page=100", .{o.repo}), "--jq", ".[].tag_name" });
            var names = std.mem.splitScalar(u8, listing, '\n');
            while (names.next()) |n| {
                const other = version.parseTag(trimNl(n)) orelse continue;
                if (version.Version.order(other, v) == .gt) {
                    std.debug.print("release: {s} exists, which is higher than {s}: refusing to create a lower-numbered release after it\n", .{ trimNl(n), o.tag });
                    return error.HigherReleaseExists;
                }
            }
            const log_range = if (o.previous.len == 0) try std.fmt.allocPrint(a, "refs/tags/{s}", .{o.tag}) else try std.fmt.allocPrint(a, "refs/tags/{s}..refs/tags/{s}", .{ o.previous, o.tag });
            const log = try must(io, a, &.{ "git", "-C", o.root, "log", "--no-merges", "--format=%s", log_range });
            var subjects = std.ArrayList([]const u8).empty;
            var lines = std.mem.splitScalar(u8, log, '\n');
            while (lines.next()) |l| try subjects.append(a, l);
            var bins = std.ArrayList(assets.Binary).empty;
            for (files[1 .. 1 + binhdr.targets.len], ours[1 .. 1 + binhdr.targets.len]) |b, h| try bins.append(a, .{ .name = b.name, .sha256 = h.sha256 });
            var packages = std.ArrayList(assets.Binary).empty;
            for (files[1 + binhdr.targets.len .. payload_files], ours[1 + binhdr.targets.len .. payload_files]) |b, h| try packages.append(a, .{ .name = b.name, .sha256 = h.sha256 });
            const text = try assets.notes(a, .{
                .number = number,
                .tag = o.tag,
                .repo = o.repo,
                .sha = o.sha,
                .previous = if (o.previous.len == 0) null else o.previous,
                .subjects = subjects.items,
                .archive = o.archive_name,
                .archive_sha256 = ours[0].sha256,
                .binaries = bins.items,
                .debs = packages.items,
            });
            try io.write(o.notes_path, text);
            var argv = std.ArrayList([]const u8).empty;
            try argv.appendSlice(a, &.{ "gh", "release", "create", o.tag });
            for (files) |b| try argv.append(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ o.dist, b.name }));
            try argv.appendSlice(a, &.{
                "--repo",       o.repo,
                "--verify-tag", "--title",
                try std.fmt.allocPrint(a, "buildrules {s}", .{number}), "--notes-file",
                o.notes_path,
                // The highest release is the latest; the guard above makes this one the highest.
                "--latest",
            });
            _ = try must(io, a, argv.items);
            return .created;
        },
    }
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;
const debs_sample = @import("debs_test.zig");

const sha_a = "a" ** 40;
const sha_b = "b" ** 40;
const sha_c = "c" ** 40;

/// A fake `Io`: the first rule whose needle occurs in the command line answers; a command no rule answers fails the test.
const Fake = struct {
    a: std.mem.Allocator,
    rules: []const Rule,
    calls: std.ArrayList([]const u8) = .empty,
    files: std.ArrayList([]const u8) = .empty,
    /// The first `flaky_n` calls to `cosign verify-blob` answer `flaky_out` whatever the rules say (a network flake that then clears).
    flaky_n: usize = 0,
    flaky_out: Out = .{ .code = 0, .stdout = "", .stderr = "" },

    const Rule = struct { needle: []const u8, out: Out = .{ .code = 0, .stdout = "", .stderr = "" } };

    fn run(ctx: *anyopaque, a: std.mem.Allocator, argv: []const []const u8) anyerror!Out {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const line = try std.mem.join(a, " ", argv);
        try self.calls.append(self.a, line);
        if (self.flaky_n > 0 and std.mem.indexOf(u8, line, "verify-blob") != null) {
            self.flaky_n -= 1;
            return self.flaky_out;
        }
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

test "the first release: no tag yet, so the plan is v0.0.1 and it writes nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .a = a, .rules = &.{.{ .needle = "for-each-ref", .out = ok(no_tags) }} };
    const r = try plan(a, fake.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n" });
    try t.expect(r.released and r.new);
    try t.expectEqualStrings("v0.0.1", r.tag);
    try t.expectEqualStrings("0.0.1", r.number);
    try t.expectEqualStrings("", r.previous);
    // planning only reads: no API call, no tag, so a failure after it leaves nothing behind
    try t.expectEqual(@as(usize, 0), fake.count("gh "));
    try t.expectEqual(@as(usize, 1), fake.calls.items.len);
    const out = try planOutputs(a, r);
    try t.expectEqualStrings("released=true\nnew=true\ncomplete=false\ntag=v0.0.1\nnumber=0.0.1\nprevious=\nreason=a release commit\n", out);
}

test "the tag step: an annotated tag at the verified commit, through two API calls" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = fail(1, "") },
        .{ .needle = "git/tags", .out = ok(sha_c ++ "\n") },
        .{ .needle = "git/refs" },
    } };
    try t.expectEqual(TagMade.created, try createTag(a, fake.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.1", .sha = sha_a }));
    try t.expectEqual(@as(usize, 1), fake.count("repos/o/n/git/tags"));
    try t.expectEqual(@as(usize, 1), fake.count("repos/o/n/git/refs"));
    // the tag object names the commit and is of type commit; the ref points at the tag object, not at the commit
    try t.expectEqual(@as(usize, 1), fake.count("object=" ++ sha_a ++ " -f type=commit"));
    try t.expectEqual(@as(usize, 1), fake.count("tag=v0.0.1 "));
    try t.expectEqual(@as(usize, 1), fake.count("ref=refs/tags/v0.0.1 -f sha=" ++ sha_c));
}

test "the tag step: a re-run keeps the tag it has; a tag on another commit, a bad sha or a bad tag create nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var same = Fake{ .a = a, .rules = &.{.{ .needle = "rev-parse", .out = ok(sha_a ++ "\n") }} };
    try t.expectEqual(TagMade.existed, try createTag(a, same.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.1", .sha = sha_a }));
    try t.expectEqual(@as(usize, 0), same.count("gh "));
    var other = Fake{ .a = a, .rules = &.{.{ .needle = "rev-parse", .out = ok(sha_b ++ "\n") }} };
    try t.expectError(error.TagNamesOtherCommit, createTag(a, other.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.1", .sha = sha_a }));
    try t.expectEqual(@as(usize, 0), other.count("gh "));
    var none = Fake{ .a = a, .rules = &.{} };
    try t.expectError(error.BadSha, createTag(a, none.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.1", .sha = "main" }));
    try t.expectError(error.BadTag, createTag(a, none.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0", .sha = sha_a }));
    try t.expectEqual(@as(usize, 0), none.calls.items.len);
    // GitHub refuses a ref that exists (a race the check above missed): the step fails
    var race = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = fail(1, "") },
        .{ .needle = "git/tags", .out = ok(sha_c ++ "\n") },
        .{ .needle = "git/refs", .out = fail(1, "gh: Reference already exists (HTTP 422)") },
    } };
    try t.expectError(error.CommandFailed, createTag(a, race.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.1", .sha = sha_a }));
    // a tag object GitHub answers with something that is not a sha
    var odd = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = fail(1, "") },
        .{ .needle = "git/tags", .out = ok("{\"message\": \"Not Found\"}") },
    } };
    try t.expectError(error.BadTagObject, createTag(a, odd.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.1", .sha = sha_a }));
    try t.expectEqual(@as(usize, 0), odd.count("git/refs"));
}

/// One `for-each-ref` line: an annotated tag (its own object, here `e`s) peeled to `commit`.
fn tagLine(comptime name: []const u8, comptime commit: []const u8) []const u8 {
    return name ++ "\ttag\t" ++ "e" ** 40 ++ "\t" ++ commit ++ "\n";
}

const sha_1 = "1" ** 40;
const sha_2 = "2" ** 40;
const sha_3 = "3" ** 40;
const sha_4 = "4" ** 40;
const sha_5 = "5" ** 40;
/// The tags v0.0.1 to v0.0.5, each at its own commit.
const tags_1_to_5 = tagLine("v0.0.1", sha_1) ++ tagLine("v0.0.2", sha_2) ++ tagLine("v0.0.3", sha_3) ++ tagLine("v0.0.4", sha_4) ++ tagLine("v0.0.5", sha_5);
/// ... and v0.0.6 at commit B, which appeared after commit A (sha_a) planned v0.0.6.
const tags_1_to_6_at_b = tags_1_to_5 ++ tagLine("v0.0.6", sha_b);

fn creatingRules(refs: []const u8, ancestor: Out) [6]Fake.Rule {
    return .{
        .{ .needle = " fetch ", .out = ok("") },
        .{ .needle = "for-each-ref", .out = ok(refs) },
        .{ .needle = "merge-base --is-ancestor", .out = ancestor },
        .{ .needle = "rev-parse", .out = fail(1, "") },
        .{ .needle = "git/tags", .out = ok(sha_c ++ "\n") },
        .{ .needle = "git/refs" },
    };
}

test "the tag race: A planned v0.0.6, v0.0.6 appeared at B, and A is an ancestor of B: A ends superseded (exit 0) and writes nothing" {
    // The defect: both pushes planned v0.0.6, B tagged first, and A went red with TagNamesOtherCommit although B's release already carries A's changes.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `rev-parse` answers B: a run without the re-check goes on to createTag and fails with TagNamesOtherCommit.
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = " fetch ", .out = ok("") },
        .{ .needle = "for-each-ref", .out = ok(tags_1_to_6_at_b) },
        .{ .needle = "merge-base --is-ancestor " ++ sha_a ++ " " ++ sha_b },
        .{ .needle = "rev-parse", .out = ok(sha_b ++ "\n") },
    } };
    const r = try settleTag(a, fake.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.6", .sha = sha_a });
    try t.expect(r.superseded);
    try t.expect(r.made == null);
    try t.expectEqualStrings("", r.tag);
    try t.expectEqualStrings("", r.number);
    try t.expect(std.mem.indexOf(u8, r.reason, "v0.0.6") != null);
    try t.expectEqual(@as(usize, 0), fake.count("gh "));
    try t.expectEqualStrings("superseded=true\ntag=\nnumber=\nmade=none\nreason=" ++ sha_a ++ " is contained in v0.0.6 (" ++ sha_b ++ "), which was tagged while this run was building: that release carries its changes, so this run makes no tag, release or bump\n", try settleOutputs(a, r));
    // the tags are fetched again before they are read
    try t.expect(std.mem.indexOf(u8, fake.calls.items[0], " fetch --force --quiet --tags origin") != null);
    try t.expect(std.mem.indexOf(u8, fake.calls.items[1], "for-each-ref") != null);
}

test "the tag race: contained is decided by the ancestry test against the newest tag's commit, whatever number the run planned" {
    // A run that planned v0.0.9 (a number no tag has) is superseded all the same when its commit is an ancestor of the newest tag's commit.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = " fetch ", .out = ok("") },
        .{ .needle = "for-each-ref", .out = ok(tags_1_to_6_at_b) },
        .{ .needle = "merge-base --is-ancestor " ++ sha_c ++ " " ++ sha_b },
    } };
    const r = try settleTag(a, fake.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.9", .sha = sha_c });
    try t.expect(r.superseded);
    try t.expectEqual(@as(usize, 0), fake.count("gh "));
}

test "the tag race: A is not contained in B and the number is taken: the run fails with NumberTaken, and nothing is created" {
    // The incident itself in the other order: the earlier push tagged v0.0.6, and this later commit, which is not contained in it, planned v0.0.6 too.
    // It cannot be tagged v0.0.6 (the tag names the other commit) and cannot be tagged v0.0.7 (its binaries, archive and signatures say 0.0.6).
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rules = creatingRules(tags_1_to_6_at_b, fail(1, ""));
    rules[3] = .{ .needle = "rev-parse", .out = ok(sha_b ++ "\n") }; // a run without the re-check meets this and fails with TagNamesOtherCommit
    var fake = Fake{ .a = a, .rules = &rules };
    try t.expectError(error.NumberTaken, settleTag(a, fake.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.6", .sha = sha_a }));
    try t.expectEqual(@as(usize, 0), fake.count("gh "));
    // a planned number below the tags (a stale plan) is refused the same way
    var stale = Fake{ .a = a, .rules = &rules };
    try t.expectError(error.NumberTaken, settleTag(a, stale.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.4", .sha = sha_a }));
    try t.expectEqual(@as(usize, 0), stale.count("gh "));
}

test "the tag race: A is not contained in the newest tag and the planned number is the next free one: the tag is made" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rules = creatingRules(tags_1_to_5, fail(1, ""));
    var fake = Fake{ .a = a, .rules = &rules };
    const r = try settleTag(a, fake.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.6", .sha = sha_a });
    try t.expect(!r.superseded);
    try t.expectEqual(TagMade.created, r.made.?);
    try t.expectEqualStrings("v0.0.6", r.tag);
    try t.expectEqualStrings("0.0.6", r.number);
    try t.expectEqual(@as(usize, 1), fake.count("ref=refs/tags/v0.0.6 -f sha=" ++ sha_c));
    try t.expectEqualStrings("superseded=false\ntag=v0.0.6\nnumber=0.0.6\nmade=created\nreason=the planned number is free\n", try settleOutputs(a, r));
    // the first release: no tag at all, so nothing to be contained in
    const first_rules = creatingRules("", fail(1, ""));
    var first = Fake{ .a = a, .rules = &first_rules };
    const f = try settleTag(a, first.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.1", .sha = sha_a });
    try t.expectEqual(TagMade.created, f.made.?);
    try t.expectEqual(@as(usize, 0), first.count("merge-base"));
}

test "the tag race: a re-run of a tagged commit keeps its own tag even when newer releases exist; a different tag at the commit is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // v0.0.6 names A and v0.0.7 names B (a descendant): the re-run of A's failed publish is not superseded, it carries on with the tag it has
    var again = Fake{ .a = a, .rules = &.{
        .{ .needle = " fetch ", .out = ok("") },
        .{ .needle = "for-each-ref", .out = ok(comptime tags_1_to_5 ++ tagLine("v0.0.6", sha_a) ++ tagLine("v0.0.7", sha_b)) },
        .{ .needle = "merge-base --is-ancestor", .out = ok("") },
        .{ .needle = "rev-parse", .out = ok(sha_a ++ "\n") },
    } };
    const r = try settleTag(a, again.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.6", .sha = sha_a });
    try t.expect(!r.superseded);
    try t.expectEqual(TagMade.existed, r.made.?);
    try t.expectEqualStrings("v0.0.6", r.tag);
    try t.expectEqual(@as(usize, 0), again.count("gh "));
    // the commit has v0.0.7 but this run was built as v0.0.6: its stamps are wrong for that tag
    var other = Fake{ .a = a, .rules = &.{
        .{ .needle = " fetch ", .out = ok("") },
        .{ .needle = "for-each-ref", .out = ok(comptime tags_1_to_5 ++ tagLine("v0.0.7", sha_a)) },
    } };
    try t.expectError(error.TagMismatch, settleTag(a, other.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.6", .sha = sha_a }));
}

test "the tag race: a failed fetch, a failed ancestry test, a bad sha or a bad tag stop the step before anything is created" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nofetch = Fake{ .a = a, .rules = &.{.{ .needle = " fetch ", .out = fail(128, "fatal: unable to access") }} };
    try t.expectError(error.CommandFailed, settleTag(a, nofetch.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.6", .sha = sha_a }));
    try t.expectEqual(@as(usize, 1), nofetch.calls.items.len);
    const rules = creatingRules(tags_1_to_5, fail(128, "fatal: Not a valid commit name"));
    var broken = Fake{ .a = a, .rules = &rules };
    try t.expectError(error.CommandFailed, settleTag(a, broken.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.6", .sha = sha_a }));
    try t.expectEqual(@as(usize, 0), broken.count("gh "));
    var none = Fake{ .a = a, .rules = &.{} };
    try t.expectError(error.BadSha, settleTag(a, none.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.6", .sha = "main" }));
    try t.expectError(error.BadTag, settleTag(a, none.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0", .sha = sha_a }));
    try t.expectEqual(@as(usize, 0), none.calls.items.len);
    // a tag line ahead of the planned MAJOR.MINOR (VERSION went backwards) is the plan's error too
    var ahead = Fake{ .a = a, .rules = &.{
        .{ .needle = " fetch ", .out = ok("") },
        .{ .needle = "for-each-ref", .out = ok(comptime tagLine("v0.1.1", sha_b)) },
        .{ .needle = "merge-base --is-ancestor", .out = fail(1, "") },
    } };
    try t.expectError(error.TagsAheadOfVersionFile, settleTag(a, ahead.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.6", .sha = sha_a }));
}

test "plan: a bad input is refused before any call" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var none = Fake{ .a = a, .rules = &.{} };
    try t.expectError(error.BadSha, plan(a, none.io(), .{ .root = "/w", .sha = "main", .version_file = "0.0\n" }));
    try t.expectError(error.BadSha, plan(a, none.io(), .{ .root = "/w", .sha = "A" ** 40, .version_file = "0.0\n" }));
    try t.expectError(error.BadVersionFile, plan(a, none.io(), .{ .root = "/w", .sha = sha_a, .version_file = "v0.0\n" }));
    try t.expectEqual(@as(usize, 0), none.calls.items.len);
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
    const r = try plan(a, fake.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0" });
    try t.expect(r.released and r.new);
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
    const r = try plan(a, fake.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n" });
    try t.expect(!r.released and !r.new);
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
    const r = try plan(a, fake.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n" });
    try t.expect(!r.released);
    try t.expectEqual(@as(usize, 0), fake.count("gh "));
    // another failure of merge-base (a shallow clone, an unknown commit) is an error, not a skip
    var fake2 = Fake{ .a = a, .rules = &.{
        .{ .needle = "for-each-ref", .out = ok(tags_v1) },
        .{ .needle = "merge-base", .out = fail(128, "fatal: bad object") },
    } };
    try t.expectError(error.CommandFailed, plan(a, fake2.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n" }));
}

test "a re-run of a released commit creates nothing and carries on with the tag it has" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refs = "v0.0.1\ttag\t" ++ "1" ** 40 ++ "\t" ++ sha_b ++ "\nv0.0.2\ttag\t" ++ "2" ** 40 ++ "\t" ++ sha_a ++ "\n";
    var fake = Fake{ .a = a, .rules = &.{.{ .needle = "for-each-ref", .out = ok(refs) }} };
    const r = try plan(a, fake.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n" });
    try t.expect(r.released and !r.new);
    try t.expectEqualStrings("v0.0.2", r.tag);
    try t.expectEqualStrings("v0.0.1", r.previous);
    try t.expectEqual(@as(usize, 1), fake.calls.items.len);
}

test "a lightweight tag counts as a release of its commit" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .a = a, .rules = &.{.{ .needle = "for-each-ref", .out = ok("v0.0.7\tcommit\t" ++ sha_a ++ "\t\n") }} };
    const r = try plan(a, fake.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n" });
    try t.expect(r.released and !r.new);
    try t.expectEqualStrings("v0.0.7", r.tag);
}

/// The plan of the commit that has the tag v0.0.2, asked whether its release is complete: GitHub answers `release` for the release and `sums` for the SHA256SUMS download.
fn planWithRelease(a: std.mem.Allocator, release: Out, sums: Out) !struct { fake: *Fake, plan: Plan } {
    const rules = try a.dupe(Fake.Rule, &.{
        .{ .needle = "for-each-ref", .out = ok("v0.0.2\ttag\t" ++ "2" ** 40 ++ "\t" ++ sha_a ++ "\n") },
        .{ .needle = " archive ", .out = ok(try tar.build(a, &sample_tar_entries)) },
        .{ .needle = "releases/tags/v0.0.2", .out = release },
        .{ .needle = "release download v0.0.2", .out = sums },
    });
    const fake = try a.create(Fake);
    fake.* = .{ .a = a, .rules = rules };
    return .{ .fake = fake, .plan = try plan(a, fake.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n", .repo = "o/n" }) };
}

/// Whether the plan calls the release complete, when it holds `listed` and serves `sums`. A setup that fails (out of memory, an unscripted command) stops the test.
fn completeWith(a: std.mem.Allocator, listed: []const Listed, sums: []const u8) bool {
    const json = releaseJson(a, listed) catch @panic("out of memory");
    return (planWithRelease(a, ok(json), ok(sums)) catch @panic("the plan failed")).plan.complete;
}

/// `listed` with its `i`th entry left out, and with its `i`th digest replaced.
fn without(a: std.mem.Allocator, listed: []const Listed, i: usize) []const Listed {
    return std.mem.concat(a, Listed, &.{ listed[0..i], listed[i + 1 ..] }) catch @panic("out of memory");
}

fn withDigest(a: std.mem.Allocator, listed: []const Listed, i: usize, digest: ?[]const u8) []const Listed {
    const copy = a.dupe(Listed, listed) catch @panic("out of memory");
    copy[i].digest = digest;
    return copy;
}

test "plan: a release that holds all fourteen files with the digests of its SHA256SUMS is complete, and nothing is changed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try publishCase(a);
    const r = try planWithRelease(a, ok(try releaseJson(a, try allListed(a, c))), ok(c.r.sums));
    const out = try planOutputs(a, r.plan);
    // released, not new, complete; it only read the file list and the sums, and made no upload, release or file
    try t.expect(r.plan.released and !r.plan.new and r.plan.complete and std.mem.startsWith(u8, out, "released=true\nnew=false\ncomplete=true\ntag=v0.0.2\n") and
        r.fake.count("gh release download v0.0.2 --repo o/n --pattern SHA256SUMS --output -") == 1 and
        r.fake.count("release create") + r.fake.count("release upload") + r.fake.files.items.len == 0);
}

test "plan: a release that lacks a file, holds another digest or reports none is not complete (a partial upload still builds)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try publishCase(a);
    const all = try allListed(a, c);
    var wrongly: usize = 0;
    // any one of the fourteen files missing, and a run that died after the first four uploads
    for (0..all.len) |i| wrongly += @intFromBool(completeWith(a, without(a, all, i), c.r.sums));
    wrongly += @intFromBool(completeWith(a, all[0..4], c.r.sums));
    wrongly += @intFromBool(completeWith(a, &.{}, c.r.sums));
    // each of the seven files held with other bytes than the commit builds (the archive) or the release's SHA256SUMS lists (the others, SHA256SUMS itself against its own bytes)
    for (all, 0..) |l, i| {
        if (!std.mem.endsWith(u8, l.name, assets.bundle_suffix)) wrongly += @intFromBool(completeWith(a, withDigest(a, all, i, "0" ** 64), c.r.sums));
    }
    // a digest GitHub does not report is not taken to match; nor is a SHA256SUMS that lists another digest for the archive than the commit builds, or is cut short
    const forged = std.fmt.allocPrint(a, "{s}  {s}\n", .{ "f" ** 64, c.r.b.name }) catch @panic("out of memory");
    wrongly += @intFromBool(completeWith(a, withDigest(a, all, 1, null), c.r.sums));
    wrongly += @intFromBool(completeWith(a, all, forged));
    wrongly += @intFromBool(completeWith(a, all, c.r.sums[0 .. c.r.sums.len / 2]));
    // a release that is consistent with itself but not with the commit: its SHA256SUMS lists another archive digest, the held archive carries that digest, the SHA256SUMS held
    // carries the digest of those bytes, and every other file agrees; only the comparison of the archive with the commit's build tells it from a complete one
    const archive_hex = assets.sha256Hex(c.r.b.archive);
    const other_sums = std.mem.replaceOwned(u8, a, c.r.sums, &archive_hex, "f" ** 64) catch @panic("out of memory");
    wrongly += @intFromBool(std.mem.eql(u8, other_sums, c.r.sums));
    wrongly += @intFromBool(completeWith(a, withDigest(a, withDigest(a, all, 0, "f" ** 64), 6, &assets.sha256Hex(other_sums)), other_sums));
    // a bundle held with other bytes is the same file signed again: the release stays complete
    try t.expect(wrongly == 0 and completeWith(a, withDigest(a, all, 7, "1" ** 64), c.r.sums));
}

test "plan: no release, no answer from GitHub or a git that fails is not complete, and the plan still goes on" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try publishCase(a);
    const held = ok(try releaseJson(a, try allListed(a, c)));
    const none = try planWithRelease(a, fail(1, "gh: Not Found (HTTP 404)"), ok(c.r.sums));
    const down = try planWithRelease(a, fail(1, "HTTP 502"), ok(c.r.sums));
    const no_sums = try planWithRelease(a, held, fail(1, "no assets match"));
    const empty_sums = try planWithRelease(a, held, ok(""));
    var broken = Fake{ .a = a, .rules = &.{
        .{ .needle = "for-each-ref", .out = ok("v0.0.2\ttag\t" ++ "2" ** 40 ++ "\t" ++ sha_a ++ "\n") },
        .{ .needle = " archive ", .out = fail(128, "fatal: bad object") },
    } };
    const unanswered = try plan(a, broken.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n", .repo = "o/n" });
    // every one still releases the commit under its tag (the build runs); with no release GitHub is not asked for the sums
    try t.expect(!(none.plan.complete or down.plan.complete or no_sums.plan.complete or empty_sums.plan.complete or unanswered.complete) and
        (none.plan.released and down.plan.released and no_sums.plan.released and empty_sums.plan.released and unanswered.released) and
        (!none.plan.new and !unanswered.new) and none.fake.count("release download") == 0 and broken.count("gh ") == 0);
}

test "plan: a new release is never complete and GitHub is not asked; nor without --repo" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .a = a, .rules = &.{ .{ .needle = "for-each-ref", .out = ok(tags_v1) }, .{ .needle = "merge-base" }, .{ .needle = "diff --name-only", .out = ok("rules/zig/zig.bzl\x00") } } };
    const r = try plan(a, fake.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n", .repo = "o/n" });
    var tagged = Fake{ .a = a, .rules = &.{.{ .needle = "for-each-ref", .out = ok("v0.0.2\ttag\t" ++ "2" ** 40 ++ "\t" ++ sha_a ++ "\n") }} };
    const again = try plan(a, tagged.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n" });
    try t.expect(r.released and r.new and !r.complete and fake.count("gh ") == 0 and again.released and !again.new and !again.complete and tagged.calls.items.len == 1);
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
    const r = try plan(a, fake.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.1\n" });
    try t.expectEqualStrings("v0.1.1", r.tag);
    try t.expectEqualStrings("v0.0.9", r.previous);
    var behind = Fake{ .a = a, .rules = &.{.{ .needle = "for-each-ref", .out = ok("v0.2.1\ttag\t" ++ "1" ** 40 ++ "\t" ++ sha_b ++ "\n") }} };
    try t.expectError(error.TagsAheadOfVersionFile, plan(a, behind.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.1\n" }));
    try t.expectEqual(@as(usize, 0), behind.count("gh "));
}


test "plan: RELEASE_FREEZE=true releases nothing, even a code change and even a commit that already has its tag" {
    // The defect: a freeze that is read in another stage, or only for new commits (a re-run would still tag and publish), or one that is ignored.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "for-each-ref", .out = ok(tags_v1) },
        .{ .needle = "merge-base" },
        .{ .needle = "diff --name-only", .out = ok("rules/zig/zig.bzl\x00") },
    } };
    const r = try plan(a, fake.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n", .freeze = "true" });
    try t.expect(!r.released and !r.new);
    try t.expectEqualStrings("v0.0.1", r.previous);
    try t.expectEqualStrings("release freeze: RELEASE_FREEZE is true", r.reason);
    // nothing but the tag listing was run: no diff, no ancestry, no gh
    try t.expectEqual(@as(usize, 1), fake.calls.items.len);
    // the outputs a frozen plan writes say "not released", which every later job waits for
    try t.expect(std.mem.startsWith(u8, try planOutputs(a, r), "released=false\nnew=false\ncomplete=false\ntag=\n"));
    // a commit that already has its tag is frozen too
    var tagged = Fake{ .a = a, .rules = &.{.{ .needle = "for-each-ref", .out = ok("v0.0.1\ttag\t" ++ "1" ** 40 ++ "\t" ++ sha_a ++ "\n") }} };
    const again = try plan(a, tagged.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n", .freeze = "true" });
    try t.expect(!again.released);
    // and the same plan without the freeze releases it, so the freeze is what stopped it
    var open = Fake{ .a = a, .rules = &.{
        .{ .needle = "for-each-ref", .out = ok(tags_v1) },
        .{ .needle = "merge-base" },
        .{ .needle = "diff --name-only", .out = ok("rules/zig/zig.bzl\x00") },
    } };
    for ([_][]const u8{ "", "false" }) |free| {
        const go = try plan(a, open.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n", .freeze = free });
        try t.expect(go.released and go.new);
        try t.expectEqualStrings("v0.0.2", go.tag);
    }
}

test "plan: a freeze that is not true, false or empty stops the plan before any command" {
    // The defect: `True`, `1`, `yes` or a typo read as "not frozen", so a freeze the owner set is silently ignored.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var none = Fake{ .a = a, .rules = &.{} };
    for ([_][]const u8{ "True", "TRUE", "1", "yes", "on", "true ", " true", "freeze" }) |bad| {
        try t.expectError(error.BadFreeze, plan(a, none.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n", .freeze = bad }));
    }
    try t.expectEqual(@as(usize, 0), none.calls.items.len);
}

test "plan --dry: the next version for any commit, read-only, whatever the freeze says" {
    // The defect: a dry run that depends on what changed (a docs-only pull request would walk no stage), or that creates or moves anything.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refs = "v0.0.2\ttag\t" ++ "2" ** 40 ++ "\t" ++ sha_b ++ "\n" ++ tags_v1;
    // docs only since the last tag, and not after it: the real plan would release nothing in either case
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "for-each-ref", .out = ok(refs) },
        .{ .needle = "merge-base", .out = fail(1, "") },
        .{ .needle = "diff --name-only", .out = ok("README.md\x00") },
    } };
    const r = try plan(a, fake.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n", .dry = true });
    try t.expect(r.released and r.new);
    try t.expectEqualStrings("v0.0.3", r.tag);
    try t.expectEqualStrings("0.0.3", r.number);
    try t.expectEqualStrings("v0.0.2", r.previous);
    try t.expectEqualStrings("dry run: nothing is created", r.reason);
    try t.expectEqual(@as(usize, 1), fake.calls.items.len);
    try t.expectEqual(@as(usize, 0), fake.count("gh "));
    // the freeze does not stop a dry run (it makes no release), and a bad freeze still does
    const frozen = try plan(a, fake.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n", .dry = true, .freeze = "true" });
    try t.expect(frozen.released);
    try t.expectError(error.BadFreeze, plan(a, fake.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n", .dry = true, .freeze = "maybe" }));
    // a VERSION behind the tags is still an error in a dry run: the pull request would break the first release
    var behind = Fake{ .a = a, .rules = &.{.{ .needle = "for-each-ref", .out = ok("v0.2.1\ttag\t" ++ "1" ** 40 ++ "\t" ++ sha_b ++ "\n") }} };
    try t.expectError(error.TagsAheadOfVersionFile, plan(a, behind.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.1\n", .dry = true }));
    // the first release of a repository with no tag
    var empty = Fake{ .a = a, .rules = &.{.{ .needle = "for-each-ref", .out = ok("") }} };
    const first = try plan(a, empty.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n", .dry = true });
    try t.expectEqualStrings("v0.0.1", first.tag);
    try t.expectEqualStrings("", first.previous);
}

const sample_tar_entries = [_]tar.Entry{
    .{ .name = "buildrules-0.0.1/", .kind = .dir, .data = "" },
    .{ .name = "buildrules-0.0.1/BUCK", .kind = .file, .data = "load(\"x\")\n" },
    .{ .name = "buildrules-0.0.1/rules/zig.bzl", .kind = .file, .data = "def f(): pass\n" },
};

test "the archive command: git archive of the commit sha with the fixed prefix and time, gzip by this tool, SHA256SUMS of the result" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar_bytes = try tar.build(a, &sample_tar_entries);
    const rules = [_]Fake.Rule{.{ .needle = " archive ", .out = ok(tar_bytes) }};
    var fake = Fake{ .a = a, .rules = &rules };
    const b = try archive(a, fake.io(), "/w", "v0.0.1", sha_a);
    try t.expectEqualStrings("buildrules-0.0.1.tar.gz", b.name);
    try t.expectEqualStrings("buildrules-0.0.1/", b.prefix);
    try t.expectEqualStrings("git -C /w -c core.autocrlf=false -c core.eol=lf -c tar.umask=0022 archive --format=tar --prefix=buildrules-0.0.1/ --mtime=" ++ archive_mtime ++ " " ++ sha_a, fake.calls.items[0]);
    // the gzip is this tool's own and holds the tar
    const back = try gz.gunzip(a, b.archive);
    try t.expectEqualSlices(u8, tar_bytes, back);
    try assets.checkSums(b.sums, b.name, b.archive);
    // twice: the same bytes
    const again = try archive(a, fake.io(), "/w", "v0.0.1", sha_a);
    try t.expectEqualSlices(u8, b.archive, again.archive);
    try t.expectEqualStrings(b.sums, again.sums);
}

test "the archive command takes only a release tag" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .a = a, .rules = &.{} };
    for ([_][]const u8{ "main", "v1", "v0.0.1-rc1", "0.0.1", "v0.0.1 --output=/x", "../v0.0.1", "v0.0.01" }) |bad| {
        try t.expectError(error.BadTag, archive(a, fake.io(), "/w", bad, sha_a));
    }
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
    // and only a full commit sha (a tag name or a branch would archive what the workflow did not test)
    for ([_][]const u8{ "v0.0.1", "main", "A" ** 40, "a" ** 39 }) |bad| {
        try t.expectError(error.BadSha, archive(a, fake.io(), "/w", "v0.0.1", bad));
    }
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
}

const cli_path = "cli/buildrules";
const cli_program = "the linux-x86_64 program";

/// The three command-line tarballs of release `number`: each holds `buildrules-cli-<number>-<target>/{buildrules,LICENSE}`, the program being `cli_program`
/// for linux-x86_64 and the target's own name for the others.
fn cliTarballs(a: std.mem.Allocator, number: []const u8) ![]Blob {
    var out = std.ArrayList(Blob).empty;
    for (binhdr.targets) |tg| {
        const dir = try std.fmt.allocPrint(a, "buildrules-cli-{s}-{s}/", .{ number, tg });
        const program = if (std.mem.eql(u8, tg, binhdr.targets[0])) cli_program else tg;
        const tar_bytes = try tar.build(a, &.{
            .{ .name = dir, .kind = .dir, .data = "", .mode = 0o755 },
            .{ .name = try std.fmt.allocPrint(a, "{s}buildrules", .{dir}), .kind = .file, .data = program, .mode = 0o755 },
            .{ .name = try std.fmt.allocPrint(a, "{s}LICENSE", .{dir}), .kind = .file, .data = "license\n" },
        });
        try out.append(a, .{ .name = try cliName(a, number, tg), .bytes = try gz.gzip(a, tar_bytes) });
    }
    return out.items;
}

/// The two .debs of release `number`, each holding the program of the tarball of its target (`cliTarballs`).
fn cliDebs(a: std.mem.Allocator, number: []const u8) ![]Blob {
    var out = std.ArrayList(Blob).empty;
    for (debfile.debs) |d| {
        const program = if (std.mem.eql(u8, d.target, binhdr.targets[0])) cli_program else d.target;
        try out.append(a, .{ .name = try debfile.name(a, number, d.arch), .bytes = try debs_sample.sample(a, number, d.arch, program) });
    }
    return out.items;
}

/// A release's files: the source archive (built through a fake git), the three tarballs, the two .debs and the SHA256SUMS of those six.
const Release = struct { b: Built, tarballs: []Blob, debs: []Blob, sums: []const u8 };

fn releaseOf(a: std.mem.Allocator, tar_bytes: []const u8, tag: []const u8, number: []const u8) !Release {
    const rules = [_]Fake.Rule{.{ .needle = " archive ", .out = ok(tar_bytes) }};
    var fake = Fake{ .a = a, .rules = &rules };
    const b = try archive(a, fake.io(), "/w", tag, sha_a);
    const tarballs = try cliTarballs(a, number);
    const package_files = try cliDebs(a, number);
    var listed = std.ArrayList(Blob).empty;
    try listed.append(a, .{ .name = b.name, .bytes = b.archive });
    try listed.appendSlice(a, tarballs);
    try listed.appendSlice(a, package_files);
    return .{ .b = b, .tarballs = tarballs, .debs = package_files, .sums = try assets.formatSumsFiles(a, listed.items) };
}

/// What `git`, `gh` and `cosign` answer to verify: `cosign` answers `cosign_says`.
fn verifyRules(tar_bytes: []const u8, tree: []const u8, attest: Out, kind: []const u8, peeled: []const u8) [7]Fake.Rule {
    return verifyRulesCli(tar_bytes, tree, attest, kind, peeled, ok("buildrules 0.0.1\n"));
}

/// As `verifyRules`, with what `cli/buildrules --version` answers.
fn verifyRulesCli(tar_bytes: []const u8, tree: []const u8, attest: Out, kind: []const u8, peeled: []const u8, cli_says: Out) [7]Fake.Rule {
    return .{
        .{ .needle = "rev-parse", .out = ok(peeled) },
        .{ .needle = "cat-file -t", .out = ok(kind) },
        .{ .needle = "gh attestation verify", .out = attest },
        .{ .needle = " archive ", .out = ok(tar_bytes) },
        .{ .needle = "ls-tree", .out = ok(tree) },
        .{ .needle = cli_path ++ " --version", .out = cli_says },
        .{ .needle = "cosign verify-blob", .out = ok("Verified OK\n") },
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

/// The options of a correct verify of `r`: the second build is the first.
fn opts(r: Release) VerifyOpts {
    return .{
        .root = "/w",
        .repo = "o/n",
        .tag = "v0.0.1",
        .sha = sha_a,
        .dist = "dist",
        .archive_name = r.b.name,
        .archive = r.b.archive,
        .sums = r.sums,
        .workflow = ".github/workflows/release.yml",
        .cli = cli_path,
        .cli_bytes = cli_program,
        .tarballs = r.tarballs,
        .rebuilt = r.tarballs,
        .debs = r.debs,
        .rebuilt_debs = r.debs,
    };
}

test "verify: a correct release has no finding, and every check was made on every file" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar_bytes = try tar.build(a, &sample_tar_entries);
    const rules = verifyRules(tar_bytes, tree_ok, ok(""), "tag\n", peeled_a);
    var fake = Fake{ .a = a, .rules = &rules };
    const r = try releaseOf(a, tar_bytes, "v0.0.1", "0.0.1");
    try expectClean(try verify(a, fake.io(), opts(r)));
    // all seven files are attested, pinned to the workflow, the commit twice (signer and source) and main
    try t.expectEqual(@as(usize, 7), fake.count("gh attestation verify dist/"));
    try t.expectEqual(@as(usize, 1), fake.count("verify dist/buildrules-0.0.1.tar.gz --repo o/n --signer-workflow o/n/.github/workflows/release.yml --signer-digest " ++ sha_a ++ " --source-digest " ++ sha_a ++ " --source-ref refs/heads/main --deny-self-hosted-runners"));
    try t.expectEqual(@as(usize, 1), fake.count("verify dist/SHA256SUMS "));
    for (binhdr.targets) |tg| try t.expectEqual(@as(usize, 1), fake.count(try std.fmt.allocPrint(a, "verify dist/buildrules-cli-0.0.1-{s}.tar.gz ", .{tg})));
    for (debfile.debs) |d| try t.expectEqual(@as(usize, 1), fake.count(try std.fmt.allocPrint(a, "verify dist/buildrules_0.0.1_{s}.deb ", .{d.arch})));
    // and signed: cosign checks each of the seven against the workflow's identity, the commit, the trigger and the repository
    try t.expectEqual(@as(usize, 7), fake.count("cosign verify-blob --bundle dist/"));
    for (debfile.debs) |d| try t.expectEqual(@as(usize, 1), fake.count(try std.fmt.allocPrint(a, "cosign verify-blob --bundle dist/buildrules_0.0.1_{s}.deb.sigstore.json --certificate-identity https://github.com/o/n/.github/workflows/release.yml@refs/heads/main ", .{d.arch})));
    try t.expectEqual(@as(usize, 1), fake.count("cosign verify-blob --bundle dist/buildrules-0.0.1.tar.gz.sigstore.json --certificate-identity https://github.com/o/n/.github/workflows/release.yml@refs/heads/main --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-github-workflow-sha " ++ sha_a ++ " --certificate-github-workflow-trigger push --certificate-github-workflow-repository o/n dist/buildrules-0.0.1.tar.gz"));
    try t.expectEqual(@as(usize, 1), fake.count("--bundle dist/SHA256SUMS.sigstore.json "));
    // the program is run once, as a user runs it
    try t.expectEqual(@as(usize, 1), fake.count(cli_path ++ " --version"));
}

test "verify: a Sigstore trusted-root fetch failure is retried up to 3 tries; a signature mismatch never is" {
    // The defects: no retry (a network flake fails the release), a retry of everything (a bad signature is asked about again and again), a retry
    // without a bound, a fetch failure reported as a verdict on the signature, a marker loose enough to match a mismatch, a marker that never retries,
    // the warning of the legacy bundle mode taken for the verdict, and the "trusted root is required" line retried without the fetch warning before it.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar_bytes = try tar.build(a, &sample_tar_entries);
    const rules = verifyRules(tar_bytes, tree_ok, ok(""), "tag\n", peeled_a);
    const r = try releaseOf(a, tar_bytes, "v0.0.1", "0.0.1");
    var o = opts(r);
    o.retry_ms = 7;
    var waited = Waits{}; // the waits are recorded, not slept
    o.waits = &waited;

    // the stderr of the release run that this retry exists for (cosign v3.0.6, addresses elided): the fetch error is only a warning line and the final
    // line is its consequence
    const incident = "WARNING: Could not fetch trusted_root.json from the TUF repository. Continuing with individual targets. Error from TUF: error getting live trusted root: failed to create TUF client failed to load metadata: tuf refresh failed: Get \"https://tuf-repo-cdn.sigstore.dev/14.root.json\": read tcp ...: read: connection reset by peer\n" ++
        "Error: trusted root is required when using new bundle format\n" ++
        "error during command execution: trusted root is required when using new bundle format";
    const no_warning = "Error: trusted root is required when using new bundle format\nerror during command execution: trusted root is required when using new bundle format";

    // the calls of a clean verify: one per verified file (derived here, not typed in, so a new verified file cannot break this test)
    var clean = Fake{ .a = a, .rules = &rules };
    try expectClean(try verify(a, clean.io(), o));
    const base = clean.count("cosign verify-blob");
    try t.expect(base > 0);

    const Want = enum { clean, fetch_finding, verdicts };
    const TryCase = struct { flaky_n: usize = 0, flaky: []const u8 = "", bad: []const u8 = "", extra_calls: usize, want: Want };
    const warn_then_tuf = "WARNING: Could not fetch trusted_root.json from the TUF repository: tuf refresh failed: Get https://tuf-repo-cdn.sigstore.dev/timestamp.json: i/o timeout\nError: error getting live trusted root: tuf refresh failed";
    const cases = [_]TryCase{
        // the fetch fails twice, then works: no finding, and the flake cost exactly two more calls
        .{ .flaky_n = 2, .flaky = warn_then_tuf, .extra_calls = 2, .want = .clean },
        // it fails 3 times: three tries on that file, then one finding that says it is a fetch failure, not a bad signature
        .{ .flaky_n = 3, .flaky = warn_then_tuf, .extra_calls = 2, .want = .fetch_finding },
        // each of the three markers alone, as the final line, is retried (dropping any one from the list turns exactly its case red)
        .{ .flaky_n = 1, .flaky = "Error: tuf refresh failed: Get https://tuf-repo-cdn.sigstore.dev/timestamp.json: i/o timeout", .extra_calls = 1, .want = .clean },
        .{ .flaky_n = 1, .flaky = "Error: Could not fetch trusted_root.json from the TUF repository", .extra_calls = 1, .want = .clean },
        .{ .flaky_n = 1, .flaky = "Error: error getting live trusted root: boom", .extra_calls = 1, .want = .clean },
        // the incident is retried: its final line needs the fetch warning before it, and it has one
        .{ .flaky_n = 1, .flaky = incident, .extra_calls = 1, .want = .clean },
        // a mismatch whose text says "tuf" and "trusted root" in another context is a verdict: one call per file, each a finding
        .{ .bad = "Error: invalid signature when validating ASN.1 encoded signature: the tuf client and the trusted root of this bundle disagree", .extra_calls = 0, .want = .verdicts },
        // the legacy-bundle warning followed by a real mismatch is a verdict too: only the final line counts
        .{ .bad = "WARNING: Could not fetch trusted_root.json from the TUF repository: tuf refresh failed: i/o timeout. Continuing\nError: invalid signature when validating ASN.1 encoded signature", .extra_calls = 0, .want = .verdicts },
        // the incident's final lines with no fetch warning before them say nothing about why the root is missing: a verdict
        .{ .bad = no_warning, .extra_calls = 0, .want = .verdicts },
    };
    for (cases) |c| {
        var rs = rules;
        if (c.bad.len > 0) rs[6].out = fail(1, c.bad);
        var fake = Fake{ .a = a, .rules = &rs, .flaky_n = c.flaky_n, .flaky_out = fail(1, c.flaky) };
        waited.n = 0;
        const got = try verify(a, fake.io(), o);
        switch (c.want) {
            .clean => try expectClean(got),
            .fetch_finding => {
                try expectFinding(got, "could not fetch the Sigstore trusted root in 3 tries");
                try t.expectEqual(@as(usize, 1), got.items.len);
            },
            .verdicts => {
                try expectFinding(got, "the signature of buildrules-0.0.1.tar.gz does not verify");
                try t.expectEqual(base, got.items.len);
            },
        }
        try t.expectEqual(base + c.extra_calls, fake.count("cosign verify-blob"));
        // every extra call waited first, and the wait grows with the try: 7 ms, then 14 ms
        try t.expectEqual(c.extra_calls, waited.n);
        for (waited.ms[0..waited.n], 0..) |ms, i| try t.expectEqual(@as(u64, 7 * (i + 1)), ms);
    }

    // The default wait is the named 2000 ms (which the docs state), and the waits of all the retries of one run together stay within the budget: with the fetch
    // never working and each wait large (5 s, then 10 s), the first file waits once, its second wait would pass the budget, so it stops after 2 tries,
    // and the files after it do not wait on and on either.
    comptime std.debug.assert(default_retry_ms == 2000 and max_total_wait_ms == 12_000);
    const default_is_named = (opts(r)).retry_ms == default_retry_ms;
    waited = Waits{};
    o.retry_ms = 5000;
    var down = Fake{ .a = a, .rules = &rules, .flaky_n = 1000, .flaky_out = fail(1, "Error: tuf refresh failed: i/o timeout") };
    const got = try verify(a, down.io(), o);
    const total = @reduce(.Add, @as(@Vector(16, u64), waited.ms)); // the unused entries are 0
    // every file is a finding, the waits were made but stayed within the budget, and the calls are fewer than the unbounded 3 tries of each file
    const held = [_]bool{ default_is_named, got.items.len == base, std.mem.indexOf(u8, got.items[0], "could not fetch the Sigstore trusted root in 2 tries") != null, total > 0, total <= max_total_wait_ms, down.count("cosign verify-blob") < 3 * base };
    var n_held: u8 = 0;
    for (held) |h| n_held += @intFromBool(h);
    try t.expectEqual(@as(u8, held.len), n_held);
}

test "verify --dry checks everything but the signatures and attestations, which a pull request does not make" {
    // The defect: a dry run that skips more than those (it would be green where the real one is red), or a real run that skips them.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar_bytes = try tar.build(a, &sample_tar_entries);
    const rules = verifyRules(tar_bytes, tree_ok, fail(1, "no attestations"), "tag\n", peeled_a);
    var fake = Fake{ .a = a, .rules = &rules };
    const r = try releaseOf(a, tar_bytes, "v0.0.1", "0.0.1");
    var o = opts(r);
    o.dry = true;
    try expectClean(try verify(a, fake.io(), o));
    try t.expectEqual(@as(usize, 0), fake.count("gh attestation"));
    try t.expectEqual(@as(usize, 0), fake.count("cosign"));
    // the checks that remain are all made: a second build that differs is still red in a dry run
    var rebuilt = try a.dupe(Blob, r.tarballs);
    rebuilt[2].bytes = "another build";
    o.rebuilt = rebuilt;
    try expectFinding(try verify(a, fake.io(), o), "buildrules-cli-0.0.1-macos-arm64.tar.gz does not reproduce");
    // and the real run, with the same failing gh, is red on every file
    const real = try verify(a, fake.io(), opts(r));
    var n: usize = 0;
    for (real.items) |m| {
        if (std.mem.indexOf(u8, m, "does not verify") != null) n += 1;
    }
    try t.expectEqual(@as(usize, 7), n);
}

test "verify mutants: each defect is a finding" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar_bytes = try tar.build(a, &sample_tar_entries);
    const good = verifyRules(tar_bytes, tree_ok, ok(""), "tag\n", peeled_a);
    const r = try releaseOf(a, tar_bytes, "v0.0.1", "0.0.1");

    // SHA256SUMS: another digest for the archive or a tarball, another name, a missing line, a line twice, the one-line file of the old releases
    var o = opts(r);
    o.sums = try assets.formatSumsFiles(a, &.{ .{ .name = r.b.name, .bytes = "other bytes" }, r.tarballs[0], r.tarballs[1], r.tarballs[2], r.debs[0], r.debs[1] });
    var fake = Fake{ .a = a, .rules = &good };
    try expectFinding(try verify(a, fake.io(), o), "SHA256SUMS does not match the release files: WrongDigest");
    o = opts(r);
    var tb = try a.dupe(Blob, r.tarballs);
    tb[2].bytes = "a tarball changed after the sums were written";
    o.tarballs = tb;
    o.rebuilt = tb;
    try expectFinding(try verify(a, fake.io(), o), "SHA256SUMS does not match the release files: WrongDigest");
    o = opts(r);
    o.sums = try assets.formatSums(a, r.b.name, r.b.archive);
    try expectFinding(try verify(a, fake.io(), o), "SHA256SUMS does not match the release files: MissingLine");
    o = opts(r);
    o.sums = try std.mem.concat(a, u8, &.{ r.sums, r.sums[0..66 + r.b.name.len + 1] });
    try expectFinding(try verify(a, fake.io(), o), "SHA256SUMS does not match the release files: NotSorted");
    o = opts(r);
    o.sums = try assets.formatSums(a, "buildrules-0.0.2.tar.gz", r.b.archive);
    try expectFinding(try verify(a, fake.io(), o), "WrongName");

    // the checkout is another commit than the one released (the tag does not exist yet, so there is none to check)
    const other = verifyRules(tar_bytes, tree_ok, ok(""), "tag\n", sha_b ++ "\n");
    fake = Fake{ .a = a, .rules = &other };
    try expectFinding(try verify(a, fake.io(), opts(r)), "the checkout is not commit " ++ sha_a);

    // an attestation does not verify: each of the seven files is checked
    const bad_attest = verifyRules(tar_bytes, tree_ok, fail(1, "no matching attestations"), "tag\n", peeled_a);
    fake = Fake{ .a = a, .rules = &bad_attest };
    const f_att = try verify(a, fake.io(), opts(r));
    try expectFinding(f_att, "attestation of buildrules-0.0.1.tar.gz does not verify");
    try expectFinding(f_att, "attestation of SHA256SUMS does not verify");
    for (binhdr.targets) |tg| try expectFinding(f_att, try std.fmt.allocPrint(a, "attestation of buildrules-cli-0.0.1-{s}.tar.gz does not verify", .{tg}));
    for (debfile.debs) |d| try expectFinding(f_att, try std.fmt.allocPrint(a, "attestation of buildrules_0.0.1_{s}.deb does not verify", .{d.arch}));

    // a signature does not verify (a bundle of another identity, another commit, or none)
    var bad_sig = good;
    bad_sig[6].out = fail(1, "none of the expected identities matched");
    fake = Fake{ .a = a, .rules = &bad_sig };
    const f_sig = try verify(a, fake.io(), opts(r));
    try expectFinding(f_sig, "the signature of buildrules-0.0.1.tar.gz does not verify");
    try expectFinding(f_sig, "the signature of SHA256SUMS does not verify");
    try expectFinding(f_sig, "the signature of buildrules-cli-0.0.1-linux-aarch64.tar.gz does not verify");
    try expectFinding(f_sig, "the signature of buildrules_0.0.1_arm64.deb does not verify");

    // the source archive is not what the commit builds (another tar, so other bytes)
    const tar2 = try tar.build(a, sample_tar_entries[0..2]);
    const rebuilt_src = verifyRules(tar2, tree_ok, ok(""), "tag\n", peeled_a);
    fake = Fake{ .a = a, .rules = &rebuilt_src };
    try expectFinding(try verify(a, fake.io(), opts(r)), "does not reproduce");

    // the commit tracks a file the archive lacks, or the archive holds one the commit does not track
    const more = verifyRules(tar_bytes, tree_ok ++ "extra.txt\x00", ok(""), "tag\n", peeled_a);
    fake = Fake{ .a = a, .rules = &more };
    try expectFinding(try verify(a, fake.io(), opts(r)), "lacks extra.txt");
    const fewer = verifyRules(tar_bytes, "BUCK\x00", ok(""), "tag\n", peeled_a);
    fake = Fake{ .a = a, .rules = &fewer };
    try expectFinding(try verify(a, fake.io(), opts(r)), "holds rules/zig.bzl, which the tag does not track");

    // the file name does not match the tag; the tag is not a release tag
    o = opts(r);
    o.archive_name = "buildrules-0.0.2.tar.gz";
    fake = Fake{ .a = a, .rules = &good };
    try expectFinding(try verify(a, fake.io(), o), "the archive is named");
    o = opts(r);
    o.tag = "v1";
    try expectFinding(try verify(a, fake.io(), o), "is not a release tag");

    // not a gzip file
    o = opts(r);
    o.archive = "not gzip at all";
    o.sums = try assets.formatSumsFiles(a, &.{ .{ .name = r.b.name, .bytes = o.archive }, r.tarballs[0], r.tarballs[1], r.tarballs[2], r.debs[0], r.debs[1] });
    fake = Fake{ .a = a, .rules = &good };
    try expectFinding(try verify(a, fake.io(), o), "not a gzip file");

    // the built program does not print the release's version: the constant it used to be, the version of another release, a
    // dev stamp (built without the planned version), nothing at all, a failure, or a program that cannot be run
    for ([_][]const u8{ "buildrules 0.0.3-poc\n", "buildrules 0.0.2\n", "buildrules 0.0-dev\n", "0.0.1\n", "buildrules 0.0.1 extra\n", "" }) |said| {
        const wrong = verifyRulesCli(tar_bytes, tree_ok, ok(""), "tag\n", peeled_a, ok(said));
        fake = Fake{ .a = a, .rules = &wrong };
        try expectFinding(try verify(a, fake.io(), opts(r)), "the program was not built with the release's version");
    }
    const crashed = verifyRulesCli(tar_bytes, tree_ok, ok(""), "tag\n", peeled_a, fail(3, "boom"));
    fake = Fake{ .a = a, .rules = &crashed };
    try expectFinding(try verify(a, fake.io(), opts(r)), "--version` exited 3: boom");
    var no_cli = good;
    no_cli[5].needle = "nothing-matches-this";
    fake = Fake{ .a = a, .rules = &no_cli };
    try expectFinding(try verify(a, fake.io(), opts(r)), "cannot be run: UnscriptedCommand");
}

test "verify: the command-line tarballs are the three of this version, once each, and the second build gives the same bytes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar_bytes = try tar.build(a, &sample_tar_entries);
    const good = verifyRules(tar_bytes, tree_ok, ok(""), "tag\n", peeled_a);
    var fake = Fake{ .a = a, .rules = &good };
    const r = try releaseOf(a, tar_bytes, "v0.0.1", "0.0.1");
    // a second build that differs in one target: named, with both digests
    for (0..3) |i| {
        var rebuilt = try a.dupe(Blob, r.tarballs);
        rebuilt[i].bytes = "bytes of a build that is not reproducible";
        var o = opts(r);
        o.rebuilt = rebuilt;
        const f = try verify(a, fake.io(), o);
        try expectFinding(f, try std.fmt.allocPrint(a, "{s} does not reproduce: a second build from the commit gives sha256 ", .{r.tarballs[i].name}));
        try t.expectEqual(@as(usize, 1), f.items.len);
    }
    // a second build with a tarball missing, or with a stray one
    var o = opts(r);
    o.rebuilt = r.tarballs[0..2];
    try expectFinding(try verify(a, fake.io(), o), "the second build holds no buildrules-cli-0.0.1-macos-arm64.tar.gz");
    try expectFinding(try verify(a, fake.io(), o), "the second build holds 2 tarballs, not 3");
    var four = try a.dupe(Blob, r.tarballs);
    four = try std.mem.concat(a, Blob, &.{ four, &.{.{ .name = "buildrules-cli-0.0.1-windows.tar.gz", .bytes = "x" }} });
    o = opts(r);
    o.rebuilt = four;
    try expectFinding(try verify(a, fake.io(), o), "the second build holds 4 tarballs, not 3");
    // dist: a tarball missing (its sums line is missing too), one of another version, a fourth file
    o = opts(r);
    o.tarballs = r.tarballs[1..];
    try expectFinding(try verify(a, fake.io(), o), "dist holds 0 files named buildrules-cli-0.0.1-linux-x86_64.tar.gz");
    o = opts(r);
    o.tarballs = four;
    try expectFinding(try verify(a, fake.io(), o), "dist holds 4 command-line tarballs, not 3");
    const twice = try std.mem.concat(a, Blob, &.{ r.tarballs, r.tarballs[0..1] });
    o = opts(r);
    o.tarballs = twice;
    try expectFinding(try verify(a, fake.io(), o), "dist holds 2 files named buildrules-cli-0.0.1-linux-x86_64.tar.gz");
    // a tarball of the wrong version is no tarball of this release
    const old = try cliTarballs(a, "0.0.0");
    o = opts(r);
    o.tarballs = old;
    o.rebuilt = old;
    try expectFinding(try verify(a, fake.io(), o), "dist holds 0 files named buildrules-cli-0.0.1-macos-arm64.tar.gz");
}

test "verify: the program that printed the version is the very file the linux-x86_64 tarball ships" {
    // The defect: a version checked on a build that is not the one packaged (a second build, a debug build): the check would say nothing about the file that ships.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar_bytes = try tar.build(a, &sample_tar_entries);
    const good = verifyRules(tar_bytes, tree_ok, ok(""), "tag\n", peeled_a);
    var fake = Fake{ .a = a, .rules = &good };
    const r = try releaseOf(a, tar_bytes, "v0.0.1", "0.0.1");
    var o = opts(r);
    o.cli_bytes = "a different program";
    try expectFinding(try verify(a, fake.io(), o), "is not the `buildrules` inside buildrules-cli-0.0.1-linux-x86_64.tar.gz");
    // a tarball with no program in it
    const empty_tar = try gz.gzip(a, try tar.build(a, &.{.{ .name = "buildrules-cli-0.0.1-linux-x86_64/LICENSE", .kind = .file, .data = "l" }}));
    var tb = try a.dupe(Blob, r.tarballs);
    tb[0].bytes = empty_tar;
    o = opts(r);
    o.tarballs = tb;
    o.rebuilt = tb;
    o.sums = try assets.formatSumsFiles(a, &.{ .{ .name = r.b.name, .bytes = r.b.archive }, tb[0], tb[1], tb[2], r.debs[0], r.debs[1] });
    try expectFinding(try verify(a, fake.io(), o), "holds no readable `buildrules`: NoBinaryInTarball");
}

test "verify: the .debs are the two of this version, once each, reproduce, and hold the program of their tarball" {
    // The defects: a release without a .deb, with one of last release's, with a .deb the second build does not give, or with a .deb that packs another
    // program than the tarball of its architecture (the tarball is what the user beta ran).
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar_bytes = try tar.build(a, &sample_tar_entries);
    const good = verifyRules(tar_bytes, tree_ok, ok(""), "tag\n", peeled_a);
    var fake = Fake{ .a = a, .rules = &good };
    const r = try releaseOf(a, tar_bytes, "v0.0.1", "0.0.1");
    try expectClean(try verify(a, fake.io(), opts(r)));

    // a second build that differs in one .deb: named, with both digests, and nothing else
    for (0..2) |i| {
        var rebuilt = try a.dupe(Blob, r.debs);
        rebuilt[i].bytes = "bytes of a build that is not reproducible";
        var o = opts(r);
        o.rebuilt_debs = rebuilt;
        const f = try verify(a, fake.io(), o);
        try expectFinding(f, try std.fmt.allocPrint(a, "{s} does not reproduce: a second build from the commit gives sha256 ", .{r.debs[i].name}));
        try t.expectEqual(@as(usize, 1), f.items.len);
    }
    // a second build with a .deb missing, or a third one
    var o = opts(r);
    o.rebuilt_debs = r.debs[0..1];
    try expectFinding(try verify(a, fake.io(), o), "the second build holds no buildrules_0.0.1_arm64.deb");
    try expectFinding(try verify(a, fake.io(), o), "the second build holds 1 .debs, not 2");
    o = opts(r);
    o.rebuilt_debs = try std.mem.concat(a, Blob, &.{ r.debs, &.{.{ .name = "buildrules_0.0.1_i386.deb", .bytes = "x" }} });
    try expectFinding(try verify(a, fake.io(), o), "the second build holds 3 .debs, not 2");

    // dist: a .deb missing (its sums line is missing too), one twice, a third, one of another version
    o = opts(r);
    o.debs = r.debs[1..];
    try expectFinding(try verify(a, fake.io(), o), "dist holds 0 files named buildrules_0.0.1_amd64.deb, not one");
    try expectFinding(try verify(a, fake.io(), o), "dist holds 1 .debs, not 2");
    o = opts(r);
    o.debs = try std.mem.concat(a, Blob, &.{ r.debs, r.debs[0..1] });
    try expectFinding(try verify(a, fake.io(), o), "dist holds 2 files named buildrules_0.0.1_amd64.deb, not one");
    const old = try cliDebs(a, "0.0.0");
    o = opts(r);
    o.debs = old;
    o.rebuilt_debs = old;
    try expectFinding(try verify(a, fake.io(), o), "dist holds 0 files named buildrules_0.0.1_arm64.deb, not one");

    // a .deb that packs another program than the tarball of its architecture, the sums and the second build agreeing with it
    var other = try a.dupe(Blob, r.debs);
    other[0].bytes = try debs_sample.sample(a, "0.0.1", "amd64", "a program nobody ran");
    o = opts(r);
    o.debs = other;
    o.rebuilt_debs = other;
    o.sums = try assets.formatSumsFiles(a, &.{ .{ .name = r.b.name, .bytes = r.b.archive }, r.tarballs[0], r.tarballs[1], r.tarballs[2], other[0], other[1] });
    const f_other = try verify(a, fake.io(), o);
    try expectFinding(f_other, "buildrules_0.0.1_amd64.deb is not the package of the `buildrules` inside buildrules-cli-0.0.1-linux-x86_64.tar.gz: WrongBinary");
    try t.expectEqual(@as(usize, 1), f_other.items.len);
    // a .deb that says another architecture than its name
    var mislabelled = try a.dupe(Blob, r.debs);
    mislabelled[1].bytes = try debs_sample.sample(a, "0.0.1", "amd64", "linux-aarch64");
    o = opts(r);
    o.debs = mislabelled;
    o.rebuilt_debs = mislabelled;
    o.sums = try assets.formatSumsFiles(a, &.{ .{ .name = r.b.name, .bytes = r.b.archive }, r.tarballs[0], r.tarballs[1], r.tarballs[2], mislabelled[0], mislabelled[1] });
    try expectFinding(try verify(a, fake.io(), o), "buildrules_0.0.1_arm64.deb is not the package of the `buildrules` inside buildrules-cli-0.0.1-linux-aarch64.tar.gz: WrongControl");
    // a file named like a .deb that is not one
    var junk = try a.dupe(Blob, r.debs);
    junk[0].bytes = "not a package";
    o = opts(r);
    o.debs = junk;
    o.rebuilt_debs = junk;
    o.sums = try assets.formatSumsFiles(a, &.{ .{ .name = r.b.name, .bytes = r.b.archive }, r.tarballs[0], r.tarballs[1], r.tarballs[2], junk[0], junk[1] });
    try expectFinding(try verify(a, fake.io(), o), "is not the package of the `buildrules` inside buildrules-cli-0.0.1-linux-x86_64.tar.gz: NotADeb");
    // a tarball with no readable program: named once for the tarball, and the .deb is skipped, not blamed
    const empty_tar = try gz.gzip(a, try tar.build(a, &.{.{ .name = "buildrules-cli-0.0.1-linux-aarch64/LICENSE", .kind = .file, .data = "l" }}));
    var tb = try a.dupe(Blob, r.tarballs);
    tb[1].bytes = empty_tar;
    o = opts(r);
    o.tarballs = tb;
    o.rebuilt = tb;
    o.sums = try assets.formatSumsFiles(a, &.{ .{ .name = r.b.name, .bytes = r.b.archive }, tb[0], tb[1], tb[2], r.debs[0], r.debs[1] });
    const f_empty = try verify(a, fake.io(), o);
    try expectFinding(f_empty, "buildrules-cli-0.0.1-linux-aarch64.tar.gz holds no readable `buildrules`: NoBinaryInTarball");
    try t.expectEqual(@as(usize, 1), f_empty.items.len);
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
    const r = try releaseOf(a, tar_bytes, "v0.0.1", "0.0.1");
    const f = try verify(a, fake.io(), opts(r));
    try expectFinding(f, "scrub: [");
    try expectFinding(f, "NOTES.txt:1");
    // the binary file is not scanned (as in the repository's own scrub)
    for (f.items) |m| try t.expect(std.mem.indexOf(u8, m, "blob.bin") == null);
}

const Case = struct { r: Release, o: PublishOpts, bundles: []Blob };

fn publishCase(a: std.mem.Allocator) !Case {
    const tar_bytes = try tar.build(a, &sample_tar_entries);
    const r = try releaseOf(a, tar_bytes, "v0.0.2", "0.0.2");
    // the seven files, in order, and a bundle for each
    var names = std.ArrayList([]const u8).empty;
    try names.append(a, r.b.name);
    for (r.tarballs) |tb| try names.append(a, tb.name);
    for (r.debs) |d| try names.append(a, d.name);
    try names.append(a, sums_name);
    var bundles = std.ArrayList(Blob).empty;
    for (names.items) |n| try bundles.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.sigstore.json", .{n}), .bytes = try std.fmt.allocPrint(a, "{{\"bundle\": \"{s}\"}}", .{n}) });
    return .{ .r = r, .bundles = bundles.items, .o = .{
        .root = "/w",
        .repo = "o/n",
        .tag = "v0.0.2",
        .sha = sha_a,
        .previous = "v0.0.1",
        .dist = "dist",
        .archive_name = r.b.name,
        .archive = r.b.archive,
        .sums = r.sums,
        .notes_path = "dist/notes.md",
        .tarballs = r.tarballs,
        .debs = r.debs,
        .bundles = bundles.items,
    } };
}

/// The fourteen paths `gh release create` is given, in order.
const fourteen = "dist/buildrules-0.0.2.tar.gz dist/buildrules-cli-0.0.2-linux-x86_64.tar.gz dist/buildrules-cli-0.0.2-linux-aarch64.tar.gz dist/buildrules-cli-0.0.2-macos-arm64.tar.gz " ++
    "dist/buildrules_0.0.2_amd64.deb dist/buildrules_0.0.2_arm64.deb dist/SHA256SUMS " ++
    "dist/buildrules-0.0.2.tar.gz.sigstore.json dist/buildrules-cli-0.0.2-linux-x86_64.tar.gz.sigstore.json dist/buildrules-cli-0.0.2-linux-aarch64.tar.gz.sigstore.json dist/buildrules-cli-0.0.2-macos-arm64.tar.gz.sigstore.json " ++
    "dist/buildrules_0.0.2_amd64.deb.sigstore.json dist/buildrules_0.0.2_arm64.deb.sigstore.json dist/SHA256SUMS.sigstore.json";

test "publish: with no release yet, one is created with all fourteen files, the notes and a verified tag" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try publishCase(a);
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = fail(1, "gh: Not Found (HTTP 404)") },
        .{ .needle = "log --no-merges", .out = ok("rules: one thing\nci: another\n") },
        .{ .needle = "releases?per_page", .out = ok("v0.0.1\n") },
        .{ .needle = "release create" },
    } };
    try t.expectEqual(PublishResult.created, try publish(a, fake.io(), c.o));
    try t.expectEqual(@as(usize, 1), fake.count("gh release create v0.0.2 " ++ fourteen ++ " --repo o/n --verify-tag --title buildrules 0.0.2 --notes-file dist/notes.md --latest"));
    try t.expectEqual(@as(usize, 1), fake.count("refs/tags/v0.0.1..refs/tags/v0.0.2"));
    try t.expectEqual(@as(usize, 1), fake.files.items.len);
    try t.expect(std.mem.startsWith(u8, fake.files.items[0], "dist/notes.md\n"));
    try t.expect(std.mem.indexOf(u8, fake.files.items[0], "- rules: one thing\n- ci: another\n") != null);
    // the notes list the three tarballs and the two .debs with the sha256 the release holds
    const h = assets.sha256Hex(c.r.tarballs[2].bytes);
    try t.expect(std.mem.indexOf(u8, fake.files.items[0], try std.fmt.allocPrint(a, "buildrules-cli-0.0.2-macos-arm64.tar.gz sha256 `{s}`", .{&h})) != null);
    const hd = assets.sha256Hex(c.r.debs[1].bytes);
    try t.expect(std.mem.indexOf(u8, fake.files.items[0], try std.fmt.allocPrint(a, "buildrules_0.0.2_arm64.deb sha256 `{s}`", .{&hd})) != null);
    try t.expect(std.mem.indexOf(u8, fake.files.items[0], "as a Debian package") != null);
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
        .{ .needle = "releases?per_page", .out = ok("v0.0.1\n") },
        .{ .needle = "release create" },
    } };
    try t.expectEqual(PublishResult.created, try publish(a, fake.io(), c.o));
    try t.expect(std.mem.indexOf(u8, fake.files.items[0], "This is the first release.") != null);
}

const Listed = struct { name: []const u8, digest: ?[]const u8 };

/// `GET releases/tags/<tag>`: the assets named, with a sha256 digest, none (`null`) or a given one.
fn releaseJson(a: std.mem.Allocator, listed: []const Listed) ![]u8 {
    var s = std.ArrayList(u8).empty;
    try s.appendSlice(a, "{\"assets\": [");
    for (listed, 0..) |l, i| {
        if (i != 0) try s.appendSlice(a, ", ");
        try s.print(a, "{{\"name\": \"{s}\", \"digest\": {s}}}", .{ l.name, if (l.digest) |h| try std.fmt.allocPrint(a, "\"sha256:{s}\"", .{h}) else "null" });
    }
    try s.appendSlice(a, "]}");
    return s.toOwnedSlice(a);
}

/// What the release of `c` holds when every file is there with the right bytes, in the order of `fourteen`.
fn allListed(a: std.mem.Allocator, c: Case) ![]Listed {
    var out = std.ArrayList(Listed).empty;
    var payload = std.ArrayList(Blob).empty;
    try payload.append(a, .{ .name = c.r.b.name, .bytes = c.r.b.archive });
    try payload.appendSlice(a, c.r.tarballs);
    try payload.appendSlice(a, c.r.debs);
    try payload.append(a, .{ .name = sums_name, .bytes = c.r.sums });
    for (payload.items) |p| try out.append(a, .{ .name = p.name, .digest = try a.dupe(u8, &assets.sha256Hex(p.bytes)) });
    for (c.bundles) |b| try out.append(a, .{ .name = b.name, .digest = try a.dupe(u8, &assets.sha256Hex(b.bytes)) });
    return out.items;
}

test "publish: a re-run changes nothing, adds only the missing files, and refuses a different one" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try publishCase(a);
    const all = try allListed(a, c);

    // all fourteen there, same bytes: no call that writes
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = ok(try releaseJson(a, all)) },
    } };
    try t.expectEqual(PublishResult.unchanged, try publish(a, fake.io(), c.o));
    try t.expectEqual(@as(usize, 0), fake.count("release create"));
    try t.expectEqual(@as(usize, 0), fake.count("release upload"));
    try t.expectEqual(@as(usize, 0), fake.files.items.len);

    // a run that died between uploads: the .debs, the sums file and every bundle are missing, and only they are added, never with --clobber
    const part = try releaseJson(a, all[0..4]);
    fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = ok(part) },
        .{ .needle = "release upload" },
    } };
    try t.expectEqual(PublishResult.uploaded, try publish(a, fake.io(), c.o));
    try t.expectEqual(@as(usize, 1), fake.count("gh release upload v0.0.2 dist/buildrules_0.0.2_amd64.deb dist/buildrules_0.0.2_arm64.deb dist/SHA256SUMS dist/buildrules-0.0.2.tar.gz.sigstore.json dist/buildrules-cli-0.0.2-linux-x86_64.tar.gz.sigstore.json dist/buildrules-cli-0.0.2-linux-aarch64.tar.gz.sigstore.json dist/buildrules-cli-0.0.2-macos-arm64.tar.gz.sigstore.json dist/buildrules_0.0.2_amd64.deb.sigstore.json dist/buildrules_0.0.2_arm64.deb.sigstore.json dist/SHA256SUMS.sigstore.json --repo o/n"));
    try t.expectEqual(@as(usize, 0), fake.count("clobber"));

    // any one of the seven files there with other bytes: the job fails, nothing is uploaded or created, and a new signing of it does not excuse that
    for (0..all.len) |i| {
        if (std.mem.endsWith(u8, all[i].name, assets.bundle_suffix)) continue;
        for ([_]bool{ false, true }) |and_its_bundle| {
            var differs = try a.dupe(Listed, all);
            differs[i].digest = "0" ** 64;
            if (and_its_bundle) {
                const bundle = try std.fmt.allocPrint(a, "{s}" ++ assets.bundle_suffix, .{all[i].name});
                for (differs) |*d| {
                    if (std.mem.eql(u8, d.name, bundle)) d.digest = "1" ** 64;
                }
            }
            fake = Fake{ .a = a, .rules = &.{
                .{ .needle = "rev-parse", .out = ok(peeled_a) },
                .{ .needle = "releases/tags/v0.0.2", .out = ok(try releaseJson(a, differs)) },
            } };
            try t.expectError(error.AssetDiffers, publish(a, fake.io(), c.o));
            try t.expectEqual(@as(usize, 0), fake.count("release "));
        }
    }

    // the re-run of a released commit (v0.0.11): the seven files are the same bytes and every one of the seven bundles is a new signing of them. The release is
    // intact, so nothing is created, uploaded or replaced, and the job ends green; one bundle at a time and all together
    for (0..all.len + 1) |i| {
        const resigned = try a.dupe(Listed, all);
        for (resigned, 0..) |*d, k| {
            if (std.mem.endsWith(u8, d.name, assets.bundle_suffix) and (i == all.len or i == k)) d.digest = "2" ** 64;
        }
        fake = Fake{ .a = a, .rules = &.{
            .{ .needle = "rev-parse", .out = ok(peeled_a) },
            .{ .needle = "releases/tags/v0.0.2", .out = ok(try releaseJson(a, resigned)) },
        } };
        try t.expectEqual(PublishResult.unchanged, try publish(a, fake.io(), c.o));
        try t.expectEqual(@as(usize, 0), fake.count("release "));
        try t.expectEqual(@as(usize, 0), fake.files.items.len);
    }

    // a digest GitHub does not report is not taken to match
    var unknown = try a.dupe(Listed, all);
    unknown[3].digest = null;
    fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = ok(try releaseJson(a, unknown)) },
    } };
    try t.expectError(error.AssetDigestUnknown, publish(a, fake.io(), c.o));
}

test "publish: refuses before any release call when the files, the tag or the API are wrong" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try publishCase(a);
    var fake = Fake{ .a = a, .rules = &.{} };
    // SHA256SUMS does not match the archive, lists a tarball with another digest, or has only the archive's line (the one-line file of the old releases)
    var o = c.o;
    o.sums = try assets.formatSums(a, c.r.b.name, c.r.b.archive);
    try t.expectError(error.MissingLine, publish(a, fake.io(), o));
    o = c.o;
    o.sums = try assets.formatSumsFiles(a, &.{ .{ .name = c.r.b.name, .bytes = "other" }, c.r.tarballs[0], c.r.tarballs[1], c.r.tarballs[2], c.r.debs[0], c.r.debs[1] });
    try t.expectError(error.WrongDigest, publish(a, fake.io(), o));
    // a SHA256SUMS written before the .debs were in the release lists none of them
    o = c.o;
    o.sums = try assets.formatSumsFiles(a, &.{ .{ .name = c.r.b.name, .bytes = c.r.b.archive }, c.r.tarballs[0], c.r.tarballs[1], c.r.tarballs[2] });
    try t.expectError(error.MissingLine, publish(a, fake.io(), o));
    // a tarball is missing, a fifth one is there, a bundle is missing, empty or not expected
    o = c.o;
    o.tarballs = c.r.tarballs[1..];
    try t.expectError(error.MissingTarball, publish(a, fake.io(), o));
    o = c.o;
    o.tarballs = try std.mem.concat(a, Blob, &.{ c.r.tarballs, &.{.{ .name = "buildrules-cli-0.0.2-plan9.tar.gz", .bytes = "x" }} });
    try t.expectError(error.StrayTarball, publish(a, fake.io(), o));
    // a .deb is missing, or a third one is there
    o = c.o;
    o.debs = c.r.debs[1..];
    try t.expectError(error.MissingDeb, publish(a, fake.io(), o));
    o = c.o;
    o.debs = try std.mem.concat(a, Blob, &.{ c.r.debs, &.{.{ .name = "buildrules_0.0.2_i386.deb", .bytes = "x" }} });
    try t.expectError(error.StrayDeb, publish(a, fake.io(), o));
    o = c.o;
    o.bundles = c.bundles[1..];
    try t.expectError(error.MissingBundle, publish(a, fake.io(), o));
    var hollow = try a.dupe(Blob, c.bundles);
    hollow[6].bytes = "";
    o = c.o;
    o.bundles = hollow;
    try t.expectError(error.MissingBundle, publish(a, fake.io(), o));
    o = c.o;
    o.bundles = try std.mem.concat(a, Blob, &.{ c.bundles, &.{.{ .name = "extra.sigstore.json", .bytes = "{}" }} });
    try t.expectError(error.StrayBundle, publish(a, fake.io(), o));
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

test "publish: a release is never created below one that exists, however the jobs are re-run" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try publishCase(a); // v0.0.2
    // v0.0.3 is already released: creating v0.0.2 now would take "Latest" from it, so nothing is created
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = fail(1, "gh: Not Found (HTTP 404)") },
        .{ .needle = "releases?per_page", .out = ok("v0.0.3\nv0.0.1\n") },
        .{ .needle = "release create" },
    } };
    try t.expectError(error.HigherReleaseExists, publish(a, fake.io(), c.o));
    try t.expectEqual(@as(usize, 0), fake.count("release create"));
    try t.expectEqual(@as(usize, 0), fake.files.items.len);
    // a higher number on a later page of the listing, and with a non-release tag among them, is still found
    fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = fail(1, "HTTP 404") },
        .{ .needle = "releases?per_page", .out = ok("v0.0.1\nlatest\nv0.0.2-rc1\nv0.1.1\n") },
        .{ .needle = "release create" },
    } };
    try t.expectError(error.HigherReleaseExists, publish(a, fake.io(), c.o));
    // lower releases, a non-release tag name and an empty listing do not block; the new release is made the latest
    fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = fail(1, "HTTP 404") },
        .{ .needle = "releases?per_page", .out = ok("v0.0.1\nv0.0.2-rc1\n") },
        .{ .needle = "log --no-merges", .out = ok("x\n") },
        .{ .needle = "release create" },
    } };
    try t.expectEqual(PublishResult.created, try publish(a, fake.io(), c.o));
    try t.expectEqual(@as(usize, 1), fake.count(" --latest"));
    // the listing failing is not "no higher release": the job fails and creates nothing
    fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = fail(1, "HTTP 404") },
        .{ .needle = "releases?per_page", .out = fail(1, "HTTP 502") },
    } };
    try t.expectError(error.CommandFailed, publish(a, fake.io(), c.o));
    try t.expectEqual(@as(usize, 0), fake.count("release create"));
    // a release that exists keeps getting its missing files added, even when a higher one exists: only creating is guarded
    const all = try allListed(a, c);
    fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = ok(try releaseJson(a, all[0..13])) },
        .{ .needle = "release upload" },
    } };
    try t.expectEqual(PublishResult.uploaded, try publish(a, fake.io(), c.o));
    try t.expectEqual(@as(usize, 0), fake.count("releases?per_page"));
}

test "a tag with no release does not block the next tag: the next version is the highest tag plus one, and no release is looked at" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // v0.0.2 is tagged (its run died before publishing) and the tag job of a later commit still takes v0.0.3
    const refs = "v0.0.1\ttag\t" ++ "1" ** 40 ++ "\t" ++ sha_b ++ "\nv0.0.2\ttag\t" ++ "2" ** 40 ++ "\t" ++ sha_c ++ "\n";
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "for-each-ref", .out = ok(refs) },
        .{ .needle = "merge-base", .out = ok("") },
        .{ .needle = "diff --name-only", .out = ok("rules/x.bzl\x00") },
        .{ .needle = "git/tags", .out = ok(sha_c ++ "\n") },
        .{ .needle = "git/refs" },
    } };
    const r = try plan(a, fake.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0\n" });
    try t.expect(r.released and r.new);
    try t.expectEqualStrings("v0.0.3", r.tag);
    try t.expectEqualStrings("v0.0.2", r.previous);
    try t.expectEqual(@as(usize, 0), fake.count("releases"));
}

test "busybox tar, an independent reader, lists the archive this tool writes, with its prefix" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar_bytes = try tar.build(a, &sample_tar_entries);
    const rules = [_]Fake.Rule{.{ .needle = " archive ", .out = ok(tar_bytes) }};
    var fake = Fake{ .a = a, .rules = &rules };
    const b = try archive(a, fake.io(), "/w", "v0.0.1", sha_a);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = b.name, .data = b.archive });
    const path = try std.fs.path.join(a, &.{ try tmp.dir.realpathAlloc(a, "."), b.name });
    const r = try std.process.Child.run(.{ .allocator = a, .argv = &.{ "tar", "-tzf", path } });
    try t.expectEqual(@as(u8, 0), r.term.Exited);
    try t.expectEqualStrings("buildrules-0.0.1/\nbuildrules-0.0.1/BUCK\nbuildrules-0.0.1/rules/zig.bzl\n", r.stdout);
}

/// Runs `ctx.call(allocator)` with the allocator failing at its 1st, 2nd, ... allocation, until a run meets no failure. `call` answers whether the step
/// reported success (a plan, a tag, an archive, a publish that returned; a verify with no finding). A run in which an allocation failed must
/// not have reported success: an out-of-memory that a step swallowed would pass a release no check had finished.
fn sweepOutOfMemory(ctx: anytype) !void {
    var backing = std.heap.ArenaAllocator.init(t.allocator);
    defer backing.deinit();
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        _ = backing.reset(.retain_capacity);
        var fa = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = i });
        const reported = ctx.call(fa.allocator()) catch false;
        if (!fa.has_induced_failure) {
            try t.expect(reported);
            try t.expect(i > 0);
            return;
        }
        if (reported) {
            std.debug.print("the step reported success although allocation {d} failed\n", .{i});
            return error.SwallowedOutOfMemory;
        }
    }
    return error.SweepDidNotEnd;
}

test "out of memory: plan, tag, archive, verify and publish fail or find, and never report success" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar_bytes = try tar.build(a, &sample_tar_entries);

    const Plan_ = struct {
        a: std.mem.Allocator,
        fn call(self: @This(), x: std.mem.Allocator) !bool {
            const refs = "v0.0.2\ttag\t" ++ "2" ** 40 ++ "\t" ++ sha_b ++ "\n" ++ tags_v1 ++ "latest\ttag\t" ++ "3" ** 40 ++ "\t" ++ sha_c ++ "\nv1\tcommit\t" ++ sha_c ++ "\t\n";
            var fake = Fake{ .a = self.a, .rules = &.{
                .{ .needle = "for-each-ref", .out = ok(refs) },
                .{ .needle = "merge-base --is-ancestor " ++ sha_b ++ " " ++ sha_a },
                .{ .needle = "diff --name-only -z " ++ sha_b ++ " " ++ sha_a, .out = ok("README.md\x00rules/zig/zig.bzl\x00") },
            } };
            const r = try plan(x, fake.io(), .{ .root = "/w", .sha = sha_a, .version_file = "0.0" });
            _ = try planOutputs(x, r);
            return r.released;
        }
    };
    try sweepOutOfMemory(Plan_{ .a = a });

    const Tag_ = struct {
        a: std.mem.Allocator,
        fn call(self: @This(), x: std.mem.Allocator) !bool {
            var fake = Fake{ .a = self.a, .rules = &.{
                .{ .needle = "rev-parse", .out = fail(1, "") },
                .{ .needle = "git/tags", .out = ok(sha_c ++ "\n") },
                .{ .needle = "git/refs" },
            } };
            return (try createTag(x, fake.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.1", .sha = sha_a })) == .created;
        }
    };
    try sweepOutOfMemory(Tag_{ .a = a });

    const Settle_ = struct {
        a: std.mem.Allocator,
        refs: []const u8,
        code: u8,
        fn call(self: @This(), x: std.mem.Allocator) !bool {
            const rules = creatingRules(self.refs, .{ .code = self.code, .stdout = "", .stderr = "" });
            var fake = Fake{ .a = self.a, .rules = &rules };
            const r = try settleTag(x, fake.io(), .{ .root = "/w", .repo = "o/n", .tag = "v0.0.6", .sha = sha_a });
            _ = try settleOutputs(x, r);
            return r.superseded or r.made != null;
        }
    };
    try sweepOutOfMemory(Settle_{ .a = a, .refs = tags_1_to_5, .code = 1 });
    try sweepOutOfMemory(Settle_{ .a = a, .refs = tags_1_to_6_at_b, .code = 0 });

    const Archive_ = struct {
        a: std.mem.Allocator,
        tar_bytes: []const u8,
        fn call(self: @This(), x: std.mem.Allocator) !bool {
            var fake = Fake{ .a = self.a, .rules = &.{.{ .needle = " archive ", .out = ok(self.tar_bytes) }} };
            const b = try archive(x, fake.io(), "/w", "v0.0.1", sha_a);
            return b.name.len != 0;
        }
    };
    try sweepOutOfMemory(Archive_{ .a = a, .tar_bytes = tar_bytes });

    const r = try releaseOf(a, tar_bytes, "v0.0.1", "0.0.1");
    const Verify_ = struct {
        a: std.mem.Allocator,
        tar_bytes: []const u8,
        r: Release,
        fn call(self: @This(), x: std.mem.Allocator) !bool {
            const rules = verifyRules(self.tar_bytes, tree_ok, ok(""), "tag\n", peeled_a);
            var fake = Fake{ .a = self.a, .rules = &rules };
            const f = try verify(x, fake.io(), opts(self.r));
            return f.items.len == 0;
        }
    };
    try sweepOutOfMemory(Verify_{ .a = a, .tar_bytes = tar_bytes, .r = r });

    const c = try publishCase(a);
    const Publish_ = struct {
        a: std.mem.Allocator,
        c: Case,
        fn call(self: @This(), x: std.mem.Allocator) !bool {
            var fake = Fake{ .a = self.a, .rules = &.{
                .{ .needle = "rev-parse", .out = ok(peeled_a) },
                .{ .needle = "releases/tags/v0.0.2", .out = fail(1, "gh: Not Found (HTTP 404)") },
                .{ .needle = "log --no-merges", .out = ok("rules: one thing\nci: another\n") },
                .{ .needle = "releases?per_page", .out = ok("v0.0.1\n") },
                .{ .needle = "release create" },
            } };
            return (try publish(x, fake.io(), self.c.o)) == PublishResult.created;
        }
    };
    try sweepOutOfMemory(Publish_{ .a = a, .c = c });
}
