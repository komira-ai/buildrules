//! The steps of the automatic release (RELEASING.md), each a function of an `Io` (the commands it runs and the files it writes), so the
//! tests drive them with a fake that records the calls. The order is plan, archive, verify, tag, publish: nothing is tagged until the archive
//! of the tested commit is built, attested and verified, so a failure before the tag leaves no tag behind.
//!
//!  - `plan`: which version, if any, this commit is released as (reads tags, writes nothing);
//!  - `archive`: the deterministic source archive of a commit under the planned version's prefix, and its SHA256SUMS;
//!  - `verify`: everything that must hold before a file is published (nothing here writes);
//!  - `tag`: the annotated tag of the verified commit (the one step that writes the repository, with publish);
//!  - `publish`: the GitHub release of the verified files, created once and never changed.
const std = @import("std");
const version = @import("version.zig");
const gz = @import("gz.zig");
const tar = @import("tar.zig");
const assets = @import("assets.zig");
const binhdr = @import("binhdr");
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
    /// The dry run of a pull request: the version the commit would be released as, whatever the commit changed, with nothing created.
    dry: bool = false,
};

pub const Plan = struct {
    released: bool,
    /// The commit has no tag yet, so the tag job creates it (false when the commit already has one: a re-run).
    new: bool = false,
    tag: []const u8 = "",
    number: []const u8 = "",
    previous: []const u8 = "",
    reason: []const u8,
};

/// The `key=value` lines the job appends to $GITHUB_OUTPUT.
pub fn planOutputs(a: std.mem.Allocator, r: Plan) ![]u8 {
    return std.fmt.allocPrint(a, "released={s}\nnew={s}\ntag={s}\nnumber={s}\nprevious={s}\nreason={s}\n", .{
        if (r.released) "true" else "false",
        if (r.new) "true" else "false",
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

    // The dry run of a pull request walks every stage that creates nothing, so it takes the next number whatever the commit changed and whatever the freeze says
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

    return .{ .released = true, .new = true, .tag = try version.tagName(a, next), .number = try version.numberText(a, next), .previous = previous, .reason = "a release commit" };
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
const bundle_suffix = ".sigstore.json";

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

pub const VerifyOpts = struct {
    root: []const u8,
    repo: []const u8,
    tag: []const u8,
    sha: []const u8,
    /// The directory holding the release files (the attestations and signatures are checked on these files).
    dist: []const u8,
    archive_name: []const u8,
    archive: []const u8,
    /// The SHA256SUMS of the source archive and the three command-line tarballs.
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
    /// The dry run of a pull request: nothing is signed or attested there, so the signatures and attestations are not checked. Everything else is.
    dry: bool = false,
    cosign: []const u8 = "cosign",
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

    // 1. the archive and the tarballs are the files SHA256SUMS lists, each once, in name order.
    var listed = std.ArrayList(Blob).empty;
    try listed.append(a, .{ .name = o.archive_name, .bytes = o.archive });
    try listed.appendSlice(a, o.tarballs);
    assets.checkSumsFiles(o.sums, listed.items) catch |e| try assets.add(a, &f, "SHA256SUMS does not match the release files: {s}", .{@errorName(e)});

    // 2. the checkout is the commit being released (no tag exists yet: it is made after this).
    const head = try io.run(a, &.{ "git", "-C", o.root, "rev-parse", "--verify", "HEAD^{commit}" });
    if (head.code != 0 or !std.mem.eql(u8, trimNl(head.stdout), o.sha)) try assets.add(a, &f, "the checkout is not commit {s}", .{o.sha});

    // 3. every file carries an attestation of this workflow, for this commit, on main, and a keyless signature of the same identity. The dry run of a pull
    // request signs nothing and has none to check.
    var signed = std.ArrayList([]const u8).empty;
    try signed.append(a, o.archive_name);
    try signed.appendSlice(a, want_tarballs.items);
    try signed.append(a, sums_name);
    if (!o.dry) {
        const signer = try std.fmt.allocPrint(a, "{s}/{s}", .{ o.repo, o.workflow });
        const identity = try std.fmt.allocPrint(a, "https://github.com/{s}/{s}@refs/heads/main", .{ o.repo, o.workflow });
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
            const c = try io.run(a, &.{
                o.cosign,                             "verify-blob",                  "--bundle",                                   bundle,
                "--certificate-identity",             identity,                       "--certificate-oidc-issuer",                  oidc_issuer,
                "--certificate-github-workflow-sha",  o.sha,                          "--certificate-github-workflow-trigger",      "push",
                "--certificate-github-workflow-repository", o.repo,                   path,
            });
            if (c.code != 0) try assets.add(a, &f, "the signature of {s} does not verify (identity {s}, commit {s}): {s}", .{ file, identity, o.sha, trimNl(c.stderr) });
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
    /// The `<file>.sigstore.json` of each of the five files above (the archive, the three tarballs and SHA256SUMS).
    bundles: []const Blob = &.{},
};

pub const PublishResult = enum { created, uploaded, unchanged };

/// The files a release holds, in the order they are listed: the source archive, the three tarballs (target order), SHA256SUMS, then the signature bundle of each
/// of those five. A tarball or a bundle that is missing, empty or not expected is an error: a release is made of exactly these ten files.
fn releaseFiles(a: std.mem.Allocator, o: PublishOpts, number: []const u8) ![]Blob {
    var out = std.ArrayList(Blob).empty;
    try out.append(a, .{ .name = o.archive_name, .bytes = o.archive });
    for (binhdr.targets) |tg| {
        const n = try cliName(a, number, tg);
        try out.append(a, blobNamed(o.tarballs, n) orelse return error.MissingTarball);
    }
    if (o.tarballs.len != binhdr.targets.len) return error.StrayTarball;
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

/// Creates the release of the tag with the archive, the three command-line tarballs, SHA256SUMS, a signature bundle for each of them and the notes, or adds
/// the files an existing release lacks, or does nothing. A release that already holds a file with other bytes fails the job and changes nothing: no asset
/// is replaced.
pub fn publish(a: std.mem.Allocator, io: Io, o: PublishOpts) !PublishResult {
    const v = version.parseTag(o.tag) orelse return error.BadTag;
    const number = try version.numberText(a, v);
    const files = try releaseFiles(a, o, number);
    try assets.checkSumsFiles(o.sums, files[0 .. binhdr.targets.len + 1]);

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
    try t.expectEqualStrings("released=true\nnew=true\ntag=v0.0.1\nnumber=0.0.1\nprevious=\nreason=a release commit\n", out);
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
    try t.expect(std.mem.startsWith(u8, try planOutputs(a, r), "released=false\nnew=false\ntag=\n"));
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

/// A release's files: the source archive (built through a fake git), the three tarballs and the SHA256SUMS of those five.
const Release = struct { b: Built, tarballs: []Blob, sums: []const u8 };

fn releaseOf(a: std.mem.Allocator, tar_bytes: []const u8, tag: []const u8, number: []const u8) !Release {
    const rules = [_]Fake.Rule{.{ .needle = " archive ", .out = ok(tar_bytes) }};
    var fake = Fake{ .a = a, .rules = &rules };
    const b = try archive(a, fake.io(), "/w", tag, sha_a);
    const tarballs = try cliTarballs(a, number);
    var listed = std.ArrayList(Blob).empty;
    try listed.append(a, .{ .name = b.name, .bytes = b.archive });
    try listed.appendSlice(a, tarballs);
    return .{ .b = b, .tarballs = tarballs, .sums = try assets.formatSumsFiles(a, listed.items) };
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
    // all five files are attested, pinned to the workflow, the commit twice (signer and source) and main
    try t.expectEqual(@as(usize, 5), fake.count("gh attestation verify dist/"));
    try t.expectEqual(@as(usize, 1), fake.count("verify dist/buildrules-0.0.1.tar.gz --repo o/n --signer-workflow o/n/.github/workflows/release.yml --signer-digest " ++ sha_a ++ " --source-digest " ++ sha_a ++ " --source-ref refs/heads/main --deny-self-hosted-runners"));
    try t.expectEqual(@as(usize, 1), fake.count("verify dist/SHA256SUMS "));
    for (binhdr.targets) |tg| try t.expectEqual(@as(usize, 1), fake.count(try std.fmt.allocPrint(a, "verify dist/buildrules-cli-0.0.1-{s}.tar.gz ", .{tg})));
    // and signed: cosign checks each of the five against the workflow's identity, the commit, the trigger and the repository
    try t.expectEqual(@as(usize, 5), fake.count("cosign verify-blob --bundle dist/"));
    try t.expectEqual(@as(usize, 1), fake.count("cosign verify-blob --bundle dist/buildrules-0.0.1.tar.gz.sigstore.json --certificate-identity https://github.com/o/n/.github/workflows/release.yml@refs/heads/main --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-github-workflow-sha " ++ sha_a ++ " --certificate-github-workflow-trigger push --certificate-github-workflow-repository o/n dist/buildrules-0.0.1.tar.gz"));
    try t.expectEqual(@as(usize, 1), fake.count("--bundle dist/SHA256SUMS.sigstore.json "));
    // the program is run once, as a user runs it
    try t.expectEqual(@as(usize, 1), fake.count(cli_path ++ " --version"));
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
    try t.expectEqual(@as(usize, 5), n);
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
    o.sums = try assets.formatSumsFiles(a, &.{ .{ .name = r.b.name, .bytes = "other bytes" }, .{ .name = r.tarballs[0].name, .bytes = r.tarballs[0].bytes }, .{ .name = r.tarballs[1].name, .bytes = r.tarballs[1].bytes }, .{ .name = r.tarballs[2].name, .bytes = r.tarballs[2].bytes } });
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

    // an attestation does not verify: each of the five files is checked
    const bad_attest = verifyRules(tar_bytes, tree_ok, fail(1, "no matching attestations"), "tag\n", peeled_a);
    fake = Fake{ .a = a, .rules = &bad_attest };
    const f_att = try verify(a, fake.io(), opts(r));
    try expectFinding(f_att, "attestation of buildrules-0.0.1.tar.gz does not verify");
    try expectFinding(f_att, "attestation of SHA256SUMS does not verify");
    for (binhdr.targets) |tg| try expectFinding(f_att, try std.fmt.allocPrint(a, "attestation of buildrules-cli-0.0.1-{s}.tar.gz does not verify", .{tg}));

    // a signature does not verify (a bundle of another identity, another commit, or none)
    var bad_sig = good;
    bad_sig[6].out = fail(1, "none of the expected identities matched");
    fake = Fake{ .a = a, .rules = &bad_sig };
    const f_sig = try verify(a, fake.io(), opts(r));
    try expectFinding(f_sig, "the signature of buildrules-0.0.1.tar.gz does not verify");
    try expectFinding(f_sig, "the signature of SHA256SUMS does not verify");
    try expectFinding(f_sig, "the signature of buildrules-cli-0.0.1-linux-aarch64.tar.gz does not verify");

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
    o.sums = try assets.formatSumsFiles(a, &.{ .{ .name = r.b.name, .bytes = o.archive }, .{ .name = r.tarballs[0].name, .bytes = r.tarballs[0].bytes }, .{ .name = r.tarballs[1].name, .bytes = r.tarballs[1].bytes }, .{ .name = r.tarballs[2].name, .bytes = r.tarballs[2].bytes } });
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
    o.sums = try assets.formatSumsFiles(a, &.{ .{ .name = r.b.name, .bytes = r.b.archive }, tb[0], tb[1], tb[2] });
    try expectFinding(try verify(a, fake.io(), o), "holds no readable `buildrules`: NoBinaryInTarball");
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
    // the five files, in order, and a bundle for each
    var names = std.ArrayList([]const u8).empty;
    try names.append(a, r.b.name);
    for (r.tarballs) |tb| try names.append(a, tb.name);
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
        .bundles = bundles.items,
    } };
}

/// The ten paths `gh release create` is given, in order.
const ten = "dist/buildrules-0.0.2.tar.gz dist/buildrules-cli-0.0.2-linux-x86_64.tar.gz dist/buildrules-cli-0.0.2-linux-aarch64.tar.gz dist/buildrules-cli-0.0.2-macos-arm64.tar.gz dist/SHA256SUMS " ++
    "dist/buildrules-0.0.2.tar.gz.sigstore.json dist/buildrules-cli-0.0.2-linux-x86_64.tar.gz.sigstore.json dist/buildrules-cli-0.0.2-linux-aarch64.tar.gz.sigstore.json dist/buildrules-cli-0.0.2-macos-arm64.tar.gz.sigstore.json dist/SHA256SUMS.sigstore.json";

test "publish: with no release yet, one is created with all ten files, the notes and a verified tag" {
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
    try t.expectEqual(@as(usize, 1), fake.count("gh release create v0.0.2 " ++ ten ++ " --repo o/n --verify-tag --title buildrules 0.0.2 --notes-file dist/notes.md --latest"));
    try t.expectEqual(@as(usize, 1), fake.count("refs/tags/v0.0.1..refs/tags/v0.0.2"));
    try t.expectEqual(@as(usize, 1), fake.files.items.len);
    try t.expect(std.mem.startsWith(u8, fake.files.items[0], "dist/notes.md\n"));
    try t.expect(std.mem.indexOf(u8, fake.files.items[0], "- rules: one thing\n- ci: another\n") != null);
    // the notes list the three tarballs with the sha256 the release holds
    const h = assets.sha256Hex(c.r.tarballs[2].bytes);
    try t.expect(std.mem.indexOf(u8, fake.files.items[0], try std.fmt.allocPrint(a, "buildrules-cli-0.0.2-macos-arm64.tar.gz sha256 `{s}`", .{&h})) != null);
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

/// What the release of `c` holds when every file is there with the right bytes, in the order of `ten`.
fn allListed(a: std.mem.Allocator, c: Case) ![]Listed {
    var out = std.ArrayList(Listed).empty;
    var payload = std.ArrayList(Blob).empty;
    try payload.append(a, .{ .name = c.r.b.name, .bytes = c.r.b.archive });
    try payload.appendSlice(a, c.r.tarballs);
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

    // all ten there, same bytes: no call that writes
    var fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = ok(try releaseJson(a, all)) },
    } };
    try t.expectEqual(PublishResult.unchanged, try publish(a, fake.io(), c.o));
    try t.expectEqual(@as(usize, 0), fake.count("release create"));
    try t.expectEqual(@as(usize, 0), fake.count("release upload"));
    try t.expectEqual(@as(usize, 0), fake.files.items.len);

    // a run that died between uploads: the sums file and the last two bundles are missing, and only they are added, never with --clobber
    const part = try releaseJson(a, all[0..4]);
    fake = Fake{ .a = a, .rules = &.{
        .{ .needle = "rev-parse", .out = ok(peeled_a) },
        .{ .needle = "releases/tags/v0.0.2", .out = ok(part) },
        .{ .needle = "release upload" },
    } };
    try t.expectEqual(PublishResult.uploaded, try publish(a, fake.io(), c.o));
    try t.expectEqual(@as(usize, 1), fake.count("gh release upload v0.0.2 dist/SHA256SUMS dist/buildrules-0.0.2.tar.gz.sigstore.json dist/buildrules-cli-0.0.2-linux-x86_64.tar.gz.sigstore.json dist/buildrules-cli-0.0.2-linux-aarch64.tar.gz.sigstore.json dist/buildrules-cli-0.0.2-macos-arm64.tar.gz.sigstore.json dist/SHA256SUMS.sigstore.json --repo o/n"));
    try t.expectEqual(@as(usize, 0), fake.count("clobber"));

    // any one of the ten there with other bytes: the job fails, nothing is uploaded or created
    for (0..all.len) |i| {
        var differs = try a.dupe(Listed, all);
        differs[i].digest = "0" ** 64;
        fake = Fake{ .a = a, .rules = &.{
            .{ .needle = "rev-parse", .out = ok(peeled_a) },
            .{ .needle = "releases/tags/v0.0.2", .out = ok(try releaseJson(a, differs)) },
        } };
        try t.expectError(error.AssetDiffers, publish(a, fake.io(), c.o));
        try t.expectEqual(@as(usize, 0), fake.count("release "));
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
    o.sums = try assets.formatSumsFiles(a, &.{ .{ .name = c.r.b.name, .bytes = "other" }, c.r.tarballs[0], c.r.tarballs[1], c.r.tarballs[2] });
    try t.expectError(error.WrongDigest, publish(a, fake.io(), o));
    // a tarball is missing, a fifth one is there, a bundle is missing, empty or not expected
    o = c.o;
    o.tarballs = c.r.tarballs[1..];
    try t.expectError(error.MissingTarball, publish(a, fake.io(), o));
    o = c.o;
    o.tarballs = try std.mem.concat(a, Blob, &.{ c.r.tarballs, &.{.{ .name = "buildrules-cli-0.0.2-plan9.tar.gz", .bytes = "x" }} });
    try t.expectError(error.StrayTarball, publish(a, fake.io(), o));
    o = c.o;
    o.bundles = c.bundles[1..];
    try t.expectError(error.MissingBundle, publish(a, fake.io(), o));
    var hollow = try a.dupe(Blob, c.bundles);
    hollow[4].bytes = "";
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
        .{ .needle = "releases/tags/v0.0.2", .out = ok(try releaseJson(a, all[0..9])) },
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
