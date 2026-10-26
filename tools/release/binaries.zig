//! The command-line binaries of a release (RELEASING.md): `release package`, `record`, `tested`, `sums` and `sign`. Each release carries, besides the
//! source archive `buildrules-<V>.tar.gz`, three tarballs `buildrules-cli-<V>-<target>.tar.gz` (the name keeps them apart from the source archive,
//! which the pipeline finds by the glob `buildrules-*.tar.gz` minus `cli-`), each holding `buildrules-cli-<V>-<target>/{buildrules,LICENSE}`.
//!
//!   package   one binary and the LICENSE into its tarball, after checking the file header is the target's (binhdr.zig) and that it says it is version V
//!   record    the sha256 of a tarball the user beta ran, to a file beside the others
//!   tested    refuses unless every tarball the user beta ran is, byte for byte, the tarball to be attested
//!   debs      `buildrules_<V>_amd64.deb` and `buildrules_<V>_arm64.deb` from the same binaries (`channels deb-package`, tools/channels), and `checkDebs`: each .deb
//!             is the package of its version and architecture and holds, byte for byte, the program inside the tarball of its target (debs.zig)
//!   sums      SHA256SUMS over the source archive, the three tarballs and the two .debs, then read back
//!   sign      a keyless `cosign sign-blob` bundle per file (the six and SHA256SUMS), none empty, none stale
//!
//! A program that is not run here (the macOS binary on a Linux runner) is not run by `package`: its header and its stamped version text are
//! checked, and the beta legs that do run it on its own platform are what prove it works. Nothing here uploads anything. The commands it runs go through
//! `cmds.Io`, so a test scripts them.
const std = @import("std");
const cmds = @import("cmds.zig");
const version = @import("version.zig");
const assets = @import("assets.zig");
const gz = @import("gz.zig");
const tar = @import("tar.zig");
const binhdr = @import("binhdr");
const debs = @import("debs.zig");

pub const targets = binhdr.targets;

/// The targets whose tarball the user beta walks on a machine of its own (every release target).
pub const tested_targets = [_][]const u8{ "linux-x86_64", "linux-aarch64", "macos-arm64" };

const cli_prefix = "buildrules-cli-";
const tar_suffix = ".tar.gz";

/// `buildrules-cli-<V>-<target>.tar.gz`
pub fn assetName(a: std.mem.Allocator, v: []const u8, target: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, cli_prefix ++ "{s}-{s}" ++ tar_suffix, .{ v, target });
}

/// `MAJOR.MINOR.PATCH` as the scheme writes it (no `v`).
fn goodVersion(a: std.mem.Allocator, v: []const u8) !bool {
    const tag = try std.fmt.allocPrint(a, "v{s}", .{v});
    return version.parseTag(tag) != null;
}

pub const Named = struct { version: []const u8, target: []const u8 };

/// The version and target an asset name spells; null for any other name (a source archive, a bundle, a misspelling).
pub fn parseAssetName(a: std.mem.Allocator, name: []const u8) !?Named {
    if (!std.mem.startsWith(u8, name, cli_prefix) or !std.mem.endsWith(u8, name, tar_suffix)) return null;
    const mid = name[cli_prefix.len .. name.len - tar_suffix.len];
    for (targets) |tg| {
        const suffix = try std.fmt.allocPrint(a, "-{s}", .{tg});
        if (!std.mem.endsWith(u8, mid, suffix)) continue;
        const v = mid[0 .. mid.len - suffix.len];
        if (!try goodVersion(a, v)) return null;
        return .{ .version = v, .target = tg };
    }
    return null;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn readFile(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(a, path, 1 << 30) catch |e| {
        std.debug.print("release: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        return e;
    };
}

fn join(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ dir, name });
}

// ---- package ----------------------------------------------------------------------------------------------------------------------------

/// How the binary is asked for its version: run on this machine, or (a binary this machine cannot run) read for the stamped text.
pub const Exec = enum { native, none };

pub const PackageOpts = struct {
    /// `0.0.7`
    version: []const u8,
    /// one of `binhdr.targets`
    target: []const u8,
    binary: []const u8,
    license: []const u8,
    /// The directory the tarball is written to (created).
    out: []const u8,
    exec: Exec,
};

pub const Packaged = struct { name: []const u8, sha256: [64]u8 };

/// Whether `bin` holds the stamped version as a string of its own, exactly (binhdr.zig, `holdsVersion`, where it is tested): NUL before and after.
const holdsVersion = binhdr.holdsVersion;

/// Writes `<out>/buildrules-cli-<V>-<target>.tar.gz`: the directory `buildrules-cli-<V>-<target>/` with `buildrules` (0755) and `LICENSE` (0644),
/// every entry with mtime 0 and the tool's own gzip, so the same inputs make the same bytes. Refuses a binary whose header is another target's, whose
/// `--version` (or, for `Exec.none`, whose text) is not `buildrules <V>`, and a version that is not MAJOR.MINOR.PATCH.
pub fn package(a: std.mem.Allocator, io: cmds.Io, o: PackageOpts) !Packaged {
    if (!try goodVersion(a, o.version)) {
        std.debug.print("release package: `{s}` is not MAJOR.MINOR.PATCH (no leading v)\n", .{o.version});
        return error.BadVersion;
    }
    var known = false;
    for (targets) |tg| {
        if (std.mem.eql(u8, tg, o.target)) known = true;
    }
    if (!known) {
        std.debug.print("release package: `{s}` is not a release target\n", .{o.target});
        return error.UnknownTarget;
    }
    const bin = try readFile(a, o.binary);
    if (binhdr.problem(bin, o.target)) |why| {
        std.debug.print("release package: {s} is not the binary of {s}: {s}\n", .{ o.binary, o.target, why });
        return error.WrongBinary;
    }
    const want = try std.fmt.allocPrint(a, "buildrules {s}", .{o.version});
    switch (o.exec) {
        .native => {
            const abs = try std.fs.cwd().realpathAlloc(a, o.binary);
            const r = try io.run(a, &.{ abs, "--version" });
            const got = std.mem.trim(u8, r.stdout, " \r\n");
            if (r.code != 0 or !std.mem.eql(u8, got, want)) {
                std.debug.print("release package: the binary reports `{s}` (exit {d}), not `{s}`; refusing to package\n", .{ got, r.code, want });
                return error.WrongVersion;
            }
        },
        .none => if (!holdsVersion(bin, o.version)) {
            std.debug.print("release package: the binary does not hold the version `{s}` as its own NUL-terminated string (what `--version` prints after `buildrules `); refusing to package\n", .{o.version});
            return error.WrongVersion;
        },
    }
    const license = try readFile(a, o.license);
    const dir_name = try std.fmt.allocPrint(a, cli_prefix ++ "{s}-{s}", .{ o.version, o.target });
    const tar_bytes = try tar.build(a, &.{
        .{ .name = try std.fmt.allocPrint(a, "{s}/", .{dir_name}), .kind = .dir, .data = "", .mode = 0o755 },
        .{ .name = try std.fmt.allocPrint(a, "{s}/buildrules", .{dir_name}), .kind = .file, .data = bin, .mode = 0o755 },
        .{ .name = try std.fmt.allocPrint(a, "{s}/LICENSE", .{dir_name}), .kind = .file, .data = license },
    });
    const gz_bytes = try gz.gzip(a, tar_bytes);
    const name = try assetName(a, o.version, o.target);
    try std.fs.cwd().makePath(o.out);
    try std.fs.cwd().writeFile(.{ .sub_path = try join(a, o.out, name), .data = gz_bytes });
    return .{ .name = name, .sha256 = assets.sha256Hex(gz_bytes) };
}

pub const PackageAllOpts = struct {
    /// `0.0.7`
    version: []const u8,
    /// A directory holding `<target>/buildrules` for each of the three release targets (what `//cli:release_binaries` builds).
    bins: []const u8,
    license: []const u8,
    out: []const u8,
    /// The targets whose binary this machine runs for its `--version` (`Exec.native`); the others are checked by header and version text (`Exec.none`).
    native: []const []const u8,
};

/// `package` for each of the three release targets, from `<bins>/<target>/buildrules`. A target missing from `bins` is an error, and so is a `native` that
/// names no release target (a typo would quietly turn the run of a binary into the weaker text check).
pub fn packageAll(a: std.mem.Allocator, io: cmds.Io, o: PackageAllOpts) ![]Packaged {
    for (o.native) |n| {
        var known = false;
        for (targets) |tg| {
            if (std.mem.eql(u8, tg, n)) known = true;
        }
        if (!known) {
            std.debug.print("release package-all: `{s}` is not a release target\n", .{n});
            return error.UnknownTarget;
        }
    }
    var done = std.ArrayList(Packaged).empty;
    for (targets) |tg| {
        var exec: Exec = .none;
        for (o.native) |n| {
            if (std.mem.eql(u8, tg, n)) exec = .native;
        }
        const dir = try join(a, o.bins, tg);
        const binary = try join(a, dir, "buildrules");
        try done.append(a, try package(a, io, .{ .version = o.version, .target = tg, .binary = binary, .license = o.license, .out = o.out, .exec = exec }));
    }
    return done.toOwnedSlice(a);
}

// ---- debs -------------------------------------------------------------------------------------------------------------------------------

pub const PackageDebsOpts = struct {
    /// `0.0.7`
    version: []const u8,
    /// A directory holding `<target>/buildrules` for each release target (what `//cli:release_binaries` builds): the binaries the tarballs were packaged from.
    bins: []const u8,
    /// The `channels` program (tools/channels), which writes the package.
    channels: []const u8,
    /// The directory of the package metadata: `control`, `copyright` and `lintian-overrides` (packaging/deb).
    packaging: []const u8,
    out: []const u8,
};

/// One .deb for each target that has one, `<out>/buildrules_<V>_<arch>.deb`, written by `channels deb-package` from `<bins>/<target>/buildrules`. A `channels`
/// that fails, or that leaves no file or an empty one, is an error: a deb that is not there would be a release without it.
pub fn packageDebs(a: std.mem.Allocator, io: cmds.Io, o: PackageDebsOpts) ![]Packaged {
    if (!try goodVersion(a, o.version)) {
        std.debug.print("release debs: `{s}` is not MAJOR.MINOR.PATCH (no leading v)\n", .{o.version});
        return error.BadVersion;
    }
    try std.fs.cwd().makePath(o.out);
    var done = std.ArrayList(Packaged).empty;
    for (debs.debs) |d| {
        const binary = try join(a, try join(a, o.bins, d.target), "buildrules");
        const file = try debs.name(a, o.version, d.arch);
        const path = try join(a, o.out, file);
        const r = try io.run(a, &.{ o.channels, "deb-package", "--binary", binary, "--name", debs.package_name, "--version", o.version, "--arch", d.arch, "--packaging", o.packaging, "--out", path });
        if (r.code != 0) {
            std.debug.print("release debs: `channels deb-package` failed for {s} (exit {d}): {s}\n", .{ file, r.code, r.stderr });
            return error.ChannelsFailed;
        }
        const bytes = std.fs.cwd().readFileAlloc(a, path, 1 << 30) catch |e| {
            std.debug.print("release debs: `channels deb-package` wrote no {s}: {s}\n", .{ path, @errorName(e) });
            return error.NoDeb;
        };
        if (bytes.len == 0) {
            std.debug.print("release debs: {s} is empty\n", .{path});
            return error.NoDeb;
        }
        try done.append(a, .{ .name = file, .sha256 = assets.sha256Hex(bytes) });
    }
    return done.toOwnedSlice(a);
}

/// Refuses unless `dist_dir` holds, for each target that has a .deb, the tarball of the source archive's version and the .deb of that version, and the .deb is
/// the package of its version and architecture and holds exactly the `buildrules` that tarball holds (debs.zig). This is what lets the release attest a .deb
/// "like the tarball": the very program the user beta ran, in the other packaging.
pub fn checkDebs(a: std.mem.Allocator, dist_dir: []const u8) !void {
    const d = try collect(a, dist_dir);
    for (debs.debs) |want| {
        const tar_name = try assetName(a, d.version, want.target);
        const deb_name = try debs.name(a, d.version, want.arch);
        const binary = binaryOf(a, tar_name, try readFile(a, try join(a, dist_dir, tar_name))) catch |e| {
            std.debug.print("release debs: cannot read the binary inside {s}: {s}\n", .{ tar_name, @errorName(e) });
            return e;
        };
        debs.check(a, try readFile(a, try join(a, dist_dir, deb_name)), d.version, want.arch, binary) catch |e| {
            std.debug.print("release debs: {s} is not the package of {s}'s program for {s}: {s}\n", .{ deb_name, tar_name, want.arch, @errorName(e) });
            return e;
        };
    }
}

// ---- record, tested -----------------------------------------------------------------------------------------------------------------------

/// The bytes of the file `buildrules-cli-<V>-<target>/buildrules` inside a tarball `package` wrote.
pub fn binaryOf(a: std.mem.Allocator, name: []const u8, tarball: []const u8) ![]const u8 {
    const named = (try parseAssetName(a, name)) orelse return error.NotAnAsset;
    const plain = try gz.gunzip(a, tarball);
    const entries = try tar.parse(a, plain);
    const want = try std.fmt.allocPrint(a, cli_prefix ++ "{s}-{s}/buildrules", .{ named.version, named.target });
    for (entries) |e| {
        if (e.kind == .file and std.mem.eql(u8, e.name, want)) return e.data;
    }
    return error.NoBinaryInTarball;
}

/// Writes `<outdir>/<tarball name>.sha256` holding `<sha256>  <name>`: the bytes a user-beta leg ran. With `ran_binary` (the file the leg ran), the tarball's
/// `buildrules` must be exactly those bytes: a record says "this tarball was tested", and a tarball that holds another program than the one the leg ran was not.
pub fn record(a: std.mem.Allocator, tarball: []const u8, outdir: []const u8, ran_binary: ?[]const u8) ![]const u8 {
    const name = std.fs.path.basename(tarball);
    if (try parseAssetName(a, name) == null) {
        std.debug.print("release record: {s} is not a buildrules-cli-<V>-<target>.tar.gz\n", .{name});
        return error.NotAnAsset;
    }
    const tarball_bytes = try readFile(a, tarball);
    if (ran_binary) |path| {
        const ran = try readFile(a, path);
        const inside = binaryOf(a, name, tarball_bytes) catch |e| {
            std.debug.print("release record: cannot read the binary inside {s}: {s}\n", .{ name, @errorName(e) });
            return e;
        };
        if (!std.mem.eql(u8, ran, inside)) {
            std.debug.print("release record: the binary inside {s} is not the file the user beta ran ({s}): the tarball was not tested\n", .{ name, path });
            return error.NotTheBinaryThatRan;
        }
    }
    const hex = assets.sha256Hex(tarball_bytes);
    try std.fs.cwd().makePath(outdir);
    try std.fs.cwd().writeFile(.{
        .sub_path = try join(a, outdir, try std.fmt.allocPrint(a, "{s}.sha256", .{name})),
        .data = try std.fmt.allocPrint(a, "{s}  {s}\n", .{ hex, name }),
    });
    return name;
}

/// Refuses unless, for each of `tested_targets`, `tested_dir` holds exactly one record and `dist_dir` holds the tarball it names with exactly the
/// recorded sha256, all of one version; and `tested_dir` holds no other file.
pub fn tested(a: std.mem.Allocator, dist_dir: []const u8, tested_dir: []const u8) !void {
    return testedFor(a, dist_dir, tested_dir, &tested_targets);
}

/// As `tested`, for the targets a user beta walked on a machine of its own so far (a subset of `tested_targets`, not empty): the others are attested
/// untested by a user beta, which RELEASING.md says.
pub fn testedFor(a: std.mem.Allocator, dist_dir: []const u8, tested_dir: []const u8, targets_walked: []const []const u8) !void {
    if (targets_walked.len == 0) return error.NoTargets;
    for (targets_walked) |tg| {
        var known = false;
        for (tested_targets) |k| {
            if (std.mem.eql(u8, k, tg)) known = true;
        }
        if (!known) {
            std.debug.print("release tested: `{s}` is not a target a user beta walks (one of linux-x86_64, linux-aarch64, macos-arm64)\n", .{tg});
            return error.UnknownTarget;
        }
    }
    var dir = std.fs.cwd().openDir(tested_dir, .{ .iterate = true }) catch |e| {
        std.debug.print("release tested: cannot open {s}: {s}\n", .{ tested_dir, @errorName(e) });
        return e;
    };
    defer dir.close();
    var files = std.ArrayList([]const u8).empty;
    var it = dir.iterate();
    while (try it.next()) |e| try files.append(a, try a.dupe(u8, e.name));
    var matched: usize = 0;
    var seen_version: ?[]const u8 = null;
    for (targets_walked) |tg| {
        const suffix = try std.fmt.allocPrint(a, "-{s}" ++ tar_suffix ++ ".sha256", .{tg});
        var found: ?[]const u8 = null;
        for (files.items) |n| {
            if (!std.mem.endsWith(u8, n, suffix)) continue;
            if (found != null) {
                std.debug.print("release tested: two records for {s} in {s}\n", .{ tg, tested_dir });
                return error.TwoRecords;
            }
            found = n;
        }
        const rec = found orelse {
            std.debug.print("release tested: the user beta recorded nothing for {s}: that tarball was not tested\n", .{tg});
            return error.NotTested;
        };
        matched += 1;
        const name = rec[0 .. rec.len - ".sha256".len];
        const named = (try parseAssetName(a, name)) orelse {
            std.debug.print("release tested: {s} does not name a release tarball\n", .{rec});
            return error.BadRecord;
        };
        if (seen_version) |sv| {
            if (!std.mem.eql(u8, sv, named.version)) {
                std.debug.print("release tested: records of two versions: {s} and {s}\n", .{ sv, named.version });
                return error.TwoVersions;
            }
        } else seen_version = named.version;
        const text = try dir.readFileAlloc(a, rec, 4096);
        const line = std.mem.trimRight(u8, text, "\n");
        if (line.len != 66 + name.len or !std.mem.eql(u8, line[64..66], "  ") or !std.mem.eql(u8, line[66..], name)) {
            std.debug.print("release tested: malformed record {s}\n", .{rec});
            return error.BadRecord;
        }
        const have = assets.sha256Hex(try readFile(a, try join(a, dist_dir, name)));
        if (!std.mem.eql(u8, line[0..64], &have)) {
            std.debug.print("release tested: {s}: the user beta tested sha256 {s}, but the file to attest has {s}\n", .{ name, line[0..64], &have });
            return error.NotTheTestedBytes;
        }
    }
    if (files.items.len != matched) {
        std.debug.print("release tested: {s} holds {d} files, expected exactly the {d} records of the tested targets\n", .{ tested_dir, files.items.len, matched });
        return error.ExtraRecords;
    }
}

// ---- sums, sign -------------------------------------------------------------------------------------------------------------------------

pub const Dist = struct {
    /// `0.0.7`
    version: []const u8,
    /// The source archive, the three tarballs and the two .debs, sorted by name.
    files: []const []const u8,
};

/// The release files of `dist_dir`: exactly one source archive `buildrules-<V>.tar.gz`, one tarball per target and one .deb per architecture, all of the version
/// V. Any other `buildrules-*.tar.gz` or `buildrules_*.deb` is refused (a stray or stale file would be signed).
pub fn collect(a: std.mem.Allocator, dist_dir: []const u8) !Dist {
    var dir = std.fs.cwd().openDir(dist_dir, .{ .iterate = true }) catch |e| {
        std.debug.print("release: cannot open {s}: {s}\n", .{ dist_dir, @errorName(e) });
        return e;
    };
    defer dir.close();
    var names = std.ArrayList([]const u8).empty;
    var source: ?[]const u8 = null;
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (std.mem.startsWith(u8, e.name, "buildrules_") and std.mem.endsWith(u8, e.name, ".deb")) {
            if (debs.parseName(e.name) == null) {
                std.debug.print("release: {s} is not a buildrules_<V>_<arch>.deb\n", .{e.name});
                return error.StrayDeb;
            }
            try names.append(a, try a.dupe(u8, e.name));
            continue;
        }
        if (!std.mem.startsWith(u8, e.name, "buildrules-") or !std.mem.endsWith(u8, e.name, tar_suffix)) continue;
        const name = try a.dupe(u8, e.name);
        if (std.mem.startsWith(u8, name, cli_prefix)) {
            if (try parseAssetName(a, name) == null) {
                std.debug.print("release: {s} is not a buildrules-cli-<V>-<target>.tar.gz\n", .{name});
                return error.StrayTarball;
            }
        } else {
            const v = name["buildrules-".len .. name.len - tar_suffix.len];
            if (!try goodVersion(a, v)) {
                std.debug.print("release: {s} is not the source archive buildrules-<V>.tar.gz\n", .{name});
                return error.StrayTarball;
            }
            if (source != null) {
                std.debug.print("release: two source archives in {s}\n", .{dist_dir});
                return error.TwoSources;
            }
            source = name;
        }
        try names.append(a, name);
    }
    const src = source orelse {
        std.debug.print("release: {s} holds no source archive buildrules-<V>.tar.gz\n", .{dist_dir});
        return error.NoSource;
    };
    const v = src["buildrules-".len .. src.len - tar_suffix.len];
    for (targets) |tg| {
        const want = try assetName(a, v, tg);
        var n: usize = 0;
        for (names.items) |have| {
            if (std.mem.eql(u8, have, want)) n += 1;
        }
        if (n != 1) {
            std.debug.print("release: {s} holds no {s} (every tarball must be of the source archive's version {s})\n", .{ dist_dir, want, v });
            return error.MissingTarball;
        }
    }
    for (debs.debs) |d| {
        const want = try debs.name(a, v, d.arch);
        var n: usize = 0;
        for (names.items) |have| {
            if (std.mem.eql(u8, have, want)) n += 1;
        }
        if (n != 1) {
            std.debug.print("release: {s} holds no {s} (every .deb must be of the source archive's version {s})\n", .{ dist_dir, want, v });
            return error.MissingDeb;
        }
    }
    if (names.items.len != targets.len + 1 + debs.debs.len) {
        std.debug.print("release: {s} holds {d} release files, expected {d}\n", .{ dist_dir, names.items.len, targets.len + 1 + debs.debs.len });
        return error.StrayTarball;
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return .{ .version = v, .files = names.items };
}

fn sumsText(a: std.mem.Allocator, dist_dir: []const u8, files: []const []const u8) ![]u8 {
    var text = std.ArrayList(u8).empty;
    for (files) |n| {
        const hex = assets.sha256Hex(try readFile(a, try join(a, dist_dir, n)));
        try text.appendSlice(a, try std.fmt.allocPrint(a, "{s}  {s}\n", .{ hex, n }));
    }
    return text.items;
}

/// The SHA256SUMS file must be exactly what `files` hash to: one line per file in name order, nothing else.
pub fn checkSums(a: std.mem.Allocator, dist_dir: []const u8, files: []const []const u8) !void {
    const have = try readFile(a, try join(a, dist_dir, cmds.sums_name));
    const want = try sumsText(a, dist_dir, files);
    if (!std.mem.eql(u8, have, want)) {
        std.debug.print("release: {s} is not the sha256 of exactly the {d} release files, in name order\n", .{ cmds.sums_name, files.len });
        return error.WrongSums;
    }
}

/// Writes `<dist>/SHA256SUMS` over the source archive, the three tarballs and the two .debs, then reads it back. If the file exists (the archive step wrote the
/// source archive's line), the line of the source archive in it must be the one computed now.
pub fn sums(a: std.mem.Allocator, dist_dir: []const u8) !Dist {
    const d = try collect(a, dist_dir);
    const text = try sumsText(a, dist_dir, d.files);
    const path = try join(a, dist_dir, cmds.sums_name);
    if (std.fs.cwd().readFileAlloc(a, path, 1 << 20)) |old| {
        const src = try std.fmt.allocPrint(a, "buildrules-{s}" ++ tar_suffix, .{d.version});
        const line = try std.fmt.allocPrint(a, "{s}  {s}\n", .{ assets.sha256Hex(try readFile(a, try join(a, dist_dir, src))), src });
        if (std.mem.indexOf(u8, old, src) != null and std.mem.indexOf(u8, old, line) == null) {
            std.debug.print("release sums: the existing {s} lists another digest for {s} than the file has\n", .{ cmds.sums_name, src });
            return error.WrongSums;
        }
    } else |_| {}
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = text });
    try checkSums(a, dist_dir, d.files);
    return d;
}

/// Tries of `cosign sign-blob` per file when it fails the way a network flake does (`isTransientSignFailure`).
pub const sign_tries: u32 = 3;

/// The deadline cosign gives one `sign-blob` (its `--timeout`, default 3m). A token fetch that hangs ends in this long, not in minutes.
pub const sign_timeout = "90s";

/// The time `signRetry` reads and the waiting it does. The default is the real clock; a test gives a manual one whose `sleepFn` only records the wait and
/// moves its own `nowFn` forward, so no test measures or spends real time.
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    nowFn: *const fn (?*anyopaque) i64 = realNow,
    sleepFn: *const fn (?*anyopaque, u64) void = realSleep,

    fn now(c: Clock) i64 {
        return c.nowFn(c.ctx);
    }

    fn sleep(c: Clock, ms: u64) void {
        c.sleepFn(c.ctx, ms);
    }
};

fn realNow(_: ?*anyopaque) i64 {
    return std.time.milliTimestamp();
}

fn realSleep(_: ?*anyopaque, ms: u64) void {
    std.Thread.sleep(ms * std.time.ns_per_ms);
}

/// The delay before the second try of a `cosign sign-blob`; the third waits twice as long. `clock` is the time it reads and the sleep it makes (a test seam).
pub const SignRetry = struct {
    base_ms: u32 = 5000,
    clock: Clock = .{},
    /// No new try is started once this long has passed since `signRetry` began (a try in flight is not cut short, cosign's own `--timeout` bounds it). The whole
    /// step then fits the attest job's 15 minutes: 10 minutes of tries plus the one in flight (90 s) and the backoff.
    budget_ms: i64 = 600_000,
};

/// The argv of one `cosign sign-blob`, and nothing in it can ask a person for anything:
///   --yes                           no confirmation prompt
///   --fulcio-auth-flow token        the real guard: when the Actions endpoint hands back no token, cosign fails at once; unset, it falls back to the OAuth
///                                   device flow ("Non-interactive mode detected, using device flow") and waits for a human until the device code expires
///   --oidc-provider github-actions  defence in depth only: cosign v3.0.6's `sign-blob` ignores it (cmd/cosign/cli/signblob.go builds its KeyOpts without
///                                   OIDCProvider; only sign, attest and attest-blob set it). Kept so that a cosign that honours it takes the Actions token alone
///   --timeout 90s                   cosign's own deadline for the whole call
fn signArgv(cosign: []const u8, bundle: []const u8, file: []const u8) [12][]const u8 {
    return .{
        cosign,
        "sign-blob",
        "--yes",
        "--oidc-provider",
        "github-actions",
        "--fulcio-auth-flow",
        "token",
        "--timeout",
        sign_timeout,
        "--bundle",
        bundle,
        file,
    };
}

/// A `cosign sign-blob` failure that says the network (the Actions token endpoint, Fulcio, Rekor or the timestamp authority) did not answer, and nothing about
/// the file or the identity. Only these retry; any other refusal is final.
fn isTransientSignFailure(stderr: []const u8) bool {
    const markers = [_][]const u8{
        "fetching ambient OIDC credentials",
        "i/o timeout",
        "context deadline exceeded",
        "TLS handshake timeout",
        "connection reset",
        "connection refused",
        "no such host",
        "unexpected EOF",
        "[502]",
        "[503]",
        "[504]",
        "[429]",
        "502 Bad Gateway",
        "503 Service Unavailable",
        "504 Gateway Timeout",
    };
    for (markers) |m| {
        if (std.mem.indexOf(u8, stderr, m) != null) return true;
    }
    return false;
}

/// The wait after the `tries`-th failed try: `base_ms` times `tries`, slept through `retry.clock`.
fn backoff(retry: SignRetry, tries: u32) void {
    retry.clock.sleep(@as(u64, retry.base_ms) * tries);
}

/// `cosign sign-blob` (`signArgv`) with `--bundle <file>.sigstore.json <file>` for the six release files and SHA256SUMS, after SHA256SUMS is checked. A bundle that
/// exists beforehand is refused (a command that wrote nothing would pass on it), and one that is empty afterwards is refused.
pub fn sign(a: std.mem.Allocator, io: cmds.Io, dist_dir: []const u8, cosign: []const u8) !usize {
    return signWith(a, io, dist_dir, cosign, false);
}

/// `sign`, or with `dry` the dry run (the release workflow no longer asks for it): every check `sign` makes before it signs (the six release files and a SHA256SUMS that is exactly their
/// sha256, no stray tarball, no bundle already there) and the list of files it would sign, and then no `cosign` is run and no bundle is written. The count is the
/// number of files that would be signed.
pub fn signWith(a: std.mem.Allocator, io: cmds.Io, dist_dir: []const u8, cosign: []const u8, dry: bool) !usize {
    return signRetry(a, io, dist_dir, cosign, dry, .{});
}

/// `signWith`, with the delays between the tries of one file given (a test passes a recording seam).
pub fn signRetry(a: std.mem.Allocator, io: cmds.Io, dist_dir: []const u8, cosign: []const u8, dry: bool, retry: SignRetry) !usize {
    const began = retry.clock.now();
    const d = try collect(a, dist_dir);
    try checkSums(a, dist_dir, d.files);
    var all = std.ArrayList([]const u8).empty;
    try all.appendSlice(a, d.files);
    try all.append(a, cmds.sums_name);
    for (all.items) |n| {
        const bundle = try join(a, dist_dir, try std.fmt.allocPrint(a, "{s}.sigstore.json", .{n}));
        if (std.fs.cwd().statFile(bundle)) |_| {
            std.debug.print("release sign: {s} exists already\n", .{bundle});
            return error.StaleBundle;
        } else |_| {}
    }
    if (dry) {
        for (all.items) |n| std.debug.print("release sign: dry run, would sign {s}\n", .{n});
        return all.items.len;
    }
    for (all.items) |n| {
        const file = try join(a, dist_dir, n);
        const bundle = try std.fmt.allocPrint(a, "{s}.sigstore.json", .{file});
        const argv = signArgv(cosign, bundle, file);
        var tries: u32 = 1;
        const r = while (true) : (tries += 1) {
            const got = try io.run(a, &argv);
            if (got.code == 0 or tries >= sign_tries or !isTransientSignFailure(got.stderr)) break got;
            if (retry.clock.now() - began >= retry.budget_ms) break got;
            std.debug.print("release sign: cosign sign-blob failed for {s} (try {d} of {d}), trying again: {s}\n", .{ n, tries, sign_tries, got.stderr });
            backoff(retry, tries);
        };
        if (r.code != 0) {
            std.debug.print("release sign: cosign sign-blob failed for {s} after {d} tries: {s}\n", .{ n, tries, r.stderr });
            return error.CosignFailed;
        }
        const st = std.fs.cwd().statFile(bundle) catch {
            std.debug.print("release sign: cosign wrote no bundle for {s}\n", .{n});
            return error.NoBundle;
        };
        if (st.size == 0) {
            std.debug.print("release sign: the bundle of {s} is empty\n", .{n});
            return error.NoBundle;
        }
    }
    return all.items.len;
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;
const debs_sample = @import("debs_test.zig");

const V = "0.0.7";

/// A tmp dir holding the files of a release of version `V`; each tarball's and each .deb's bytes are its own name (distinct), the source archive too.
const Dir = struct {
    tmp: t.TmpDir,
    path: []const u8,

    fn make(a: std.mem.Allocator) !Dir {
        var tmp = t.tmpDir(.{});
        const path = try tmp.dir.realpathAlloc(a, ".");
        return .{ .tmp = tmp, .path = path };
    }

    fn put(self: *Dir, name: []const u8, bytes: []const u8) !void {
        try self.tmp.dir.writeFile(.{ .sub_path = name, .data = bytes });
    }

    fn release(self: *Dir, a: std.mem.Allocator) !void {
        try self.put("buildrules-" ++ V ++ ".tar.gz", "source archive");
        for (targets) |tg| {
            const n = try assetName(a, V, tg);
            try self.put(n, n);
        }
        for (debs.debs) |d| {
            const n = try debs.name(a, V, d.arch);
            try self.put(n, n);
        }
    }
};

/// A scripted `cosign`: records its argv and writes the bundle it is told to (`bundle` is the path after --bundle).
const FakeCosign = struct {
    a: std.mem.Allocator,
    calls: std.ArrayList([]const u8) = .empty,
    /// Write no bundle for a file whose name contains this.
    skip: []const u8 = "",
    /// Write an empty bundle for a file whose name contains this.
    empty: []const u8 = "",
    /// Exit 1 for a file whose name contains this.
    fail: []const u8 = "",
    /// Exit 1 with `flaky_stderr` for the first `flaky_n` calls (in all, not per file) on a file whose name contains `flaky`, then behave.
    flaky: []const u8 = "",
    flaky_n: u32 = 0,
    flaky_stderr: []const u8 = "",
    version_says: []const u8 = "buildrules " ++ V ++ "\n",
    version_code: u8 = 0,

    fn run(ctx: *anyopaque, a: std.mem.Allocator, argv: []const []const u8) anyerror!cmds.Out {
        const self: *FakeCosign = @ptrCast(@alignCast(ctx));
        try self.calls.append(self.a, try std.mem.join(self.a, " ", argv));
        if (argv.len == 2 and std.mem.eql(u8, argv[1], "--version")) {
            return .{ .code = self.version_code, .stdout = self.version_says, .stderr = "" };
        }
        // cosign <sign-blob flags..> --bundle <bundle> <file>
        if (argv.len != 12 or !std.mem.eql(u8, argv[1], "sign-blob") or !std.mem.eql(u8, argv[9], "--bundle")) {
            std.debug.print("unscripted command: {s}\n", .{try std.mem.join(a, " ", argv)});
            return error.UnscriptedCommand;
        }
        const file = argv[11];
        if (self.fail.len != 0 and std.mem.indexOf(u8, file, self.fail) != null) return .{ .code = 1, .stdout = "", .stderr = "boom" };
        if (self.flaky_n > 0 and self.flaky.len != 0 and std.mem.indexOf(u8, file, self.flaky) != null) {
            self.flaky_n -= 1;
            return .{ .code = 1, .stdout = "", .stderr = self.flaky_stderr };
        }
        if (self.skip.len != 0 and std.mem.indexOf(u8, file, self.skip) != null) return .{ .code = 0, .stdout = "", .stderr = "" };
        const body: []const u8 = if (self.empty.len != 0 and std.mem.indexOf(u8, file, self.empty) != null) "" else "{\"bundle\":1}";
        try std.fs.cwd().writeFile(.{ .sub_path = argv[10], .data = body });
        return .{ .code = 0, .stdout = "", .stderr = "" };
    }

    fn write(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}

    fn io(self: *FakeCosign) cmds.Io {
        return .{ .ctx = self, .run_fn = run, .write_fn = write };
    }
};

fn elfBytes(a: std.mem.Allocator, machine: u16, ptype: u32, tail: []const u8) ![]u8 {
    var b = [_]u8{0} ** (64 + 56);
    @memcpy(b[0..4], "\x7fELF");
    b[4] = 2;
    b[5] = 1;
    std.mem.writeInt(u16, b[16..18], 2, .little);
    std.mem.writeInt(u16, b[18..20], machine, .little);
    std.mem.writeInt(u64, b[32..40], 64, .little);
    std.mem.writeInt(u16, b[54..56], 56, .little);
    std.mem.writeInt(u16, b[56..58], 1, .little);
    std.mem.writeInt(u32, b[64..68], ptype, .little);
    return std.mem.concat(a, u8, &.{ &b, tail });
}

fn machoBytes(a: std.mem.Allocator, cputype: u32, tail: []const u8) ![]u8 {
    var b = [_]u8{0} ** 64;
    @memcpy(b[0..4], "\xcf\xfa\xed\xfe");
    std.mem.writeInt(u32, b[4..8], cputype, .little);
    std.mem.writeInt(u32, b[12..16], 2, .little);
    return std.mem.concat(a, u8, &.{ &b, tail });
}

const Fixture = struct {
    dir: Dir,
    out: []const u8,
    fake: FakeCosign,

    fn make(a: std.mem.Allocator) !Fixture {
        var dir = try Dir.make(a);
        try dir.put("LICENSE", "license text\n");
        try dir.put("linux", try elfBytes(a, 62, 1, "buildrules " ++ V));
        return .{ .dir = dir, .out = try join(a, dir.path, "out"), .fake = .{ .a = a } };
    }

    fn opts(self: *Fixture, a: std.mem.Allocator, binary: []const u8, target: []const u8, exec: Exec) !PackageOpts {
        return .{ .version = V, .target = target, .binary = try join(a, self.dir.path, binary), .license = try join(a, self.dir.path, "LICENSE"), .out = self.out, .exec = exec };
    }
};

test "package writes the tarball: the directory, the binary at 0755, the LICENSE, mtime 0, and the same bytes every time" {
    // The defects: a binary that is not executable after unpacking (mode 0644), a tarball whose bytes differ between two builds (verify rebuilds and compares),
    // a layout other than buildrules-cli-<V>-<target>/buildrules.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();
    const p = try package(a, fx.fake.io(), try fx.opts(a, "linux", "linux-x86_64", .native));
    try t.expectEqualStrings("buildrules-cli-" ++ V ++ "-linux-x86_64.tar.gz", p.name);
    const bytes = try fx.dir.tmp.dir.readFileAlloc(a, "out/buildrules-cli-" ++ V ++ "-linux-x86_64.tar.gz", 1 << 20);
    try t.expectEqualSlices(u8, &assets.sha256Hex(bytes), &p.sha256);
    const raw = try gz.gunzip(a, bytes);
    const es = try tar.parse(a, raw);
    try t.expectEqual(@as(usize, 3), es.len);
    try t.expectEqualStrings("buildrules-cli-" ++ V ++ "-linux-x86_64", es[0].name);
    try t.expectEqual(tar.Kind.dir, es[0].kind);
    try t.expectEqualStrings("buildrules-cli-" ++ V ++ "-linux-x86_64/buildrules", es[1].name);
    try t.expectEqualStrings("buildrules-cli-" ++ V ++ "-linux-x86_64/LICENSE", es[2].name);
    try t.expectEqualStrings("license text\n", es[2].data);
    // the binary's entry is the second header block after the directory's: its mode field reads 0000755, the LICENSE's 0000644
    try t.expectEqualStrings("0000755", raw[512 + 100 ..][0..7]);
    try t.expectEqualStrings("0000755", raw[0 + 100 ..][0..7]);
    const at: usize = 512 + 512 + ((es[1].data.len + 511) / 512) * 512;
    try t.expectEqualStrings("0000644", raw[at + 100 ..][0..7]);
    // mtime 0 in every header, and a second run writes the same bytes
    try t.expectEqualStrings("00000000000", raw[136..147]);
    const again = try package(a, fx.fake.io(), try fx.opts(a, "linux", "linux-x86_64", .native));
    try t.expectEqualSlices(u8, &p.sha256, &again.sha256);
    // it ran the binary by its absolute path, with --version
    try t.expectEqual(@as(usize, 2), fx.fake.calls.items.len);
    try t.expect(std.mem.startsWith(u8, fx.fake.calls.items[0], "/"));
    try t.expect(std.mem.endsWith(u8, fx.fake.calls.items[0], "/linux --version"));
}

test "package refuses a binary whose --version is not the release's, and one that cannot report it" {
    // The defect: a binary stamped with another version than the tarball's name (the pre-stamp constant `0.0.3-poc`, or a stale build) shipped as a release.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();
    fx.fake.version_says = "buildrules 0.0.3-poc\n";
    try t.expectError(error.WrongVersion, package(a, fx.fake.io(), try fx.opts(a, "linux", "linux-x86_64", .native)));
    fx.fake.version_says = "buildrules " ++ V ++ " extra\n";
    try t.expectError(error.WrongVersion, package(a, fx.fake.io(), try fx.opts(a, "linux", "linux-x86_64", .native)));
    fx.fake.version_says = "buildrules " ++ V ++ "\n";
    fx.fake.version_code = 3; // the right text, but the program failed
    try t.expectError(error.WrongVersion, package(a, fx.fake.io(), try fx.opts(a, "linux", "linux-x86_64", .native)));
    // nothing was written for any of the refusals
    try t.expectError(error.FileNotFound, fx.dir.tmp.dir.access("out", .{}));
}

test "package refuses a binary of another target, and a dynamic one, before it runs anything" {
    // The defect: the arm64 binary packaged as linux-x86_64, or a glibc-linked one (PT_INTERP) as a static musl one.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();
    try fx.dir.put("arm", try elfBytes(a, 183, 1, "buildrules " ++ V));
    try fx.dir.put("dyn", try elfBytes(a, 62, 3, "buildrules " ++ V));
    try t.expectError(error.WrongBinary, package(a, fx.fake.io(), try fx.opts(a, "arm", "linux-x86_64", .native)));
    try t.expectError(error.WrongBinary, package(a, fx.fake.io(), try fx.opts(a, "dyn", "linux-x86_64", .native)));
    try t.expectError(error.WrongBinary, package(a, fx.fake.io(), try fx.opts(a, "linux", "macos-arm64", .none)));
    try t.expectEqual(@as(usize, 0), fx.fake.calls.items.len);
}

test "package of a binary this machine cannot run checks its header and its version text, and runs nothing" {
    // The defect: the macOS binary stamped with another version, which only a run on a Mac would show.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();
    try fx.dir.put("mac", try machoBytes(a, 0x0100000c, "buildrules \x00\x00" ++ V ++ "\x00file:"));
    try fx.dir.put("mac_old", try machoBytes(a, 0x0100000c, "...0.0.3-poc..."));
    // The version is a prefix, a suffix or a middle of another one, or has no terminator: not this version.
    try fx.dir.put("mac_070", try machoBytes(a, 0x0100000c, "buildrules \x00\x00" ++ V ++ "0\x00file:"));
    try fx.dir.put("mac_1007", try machoBytes(a, 0x0100000c, "\x0010." ++ V[2..] ++ "\x00"));
    try fx.dir.put("mac_dotted", try machoBytes(a, 0x0100000c, "\x001." ++ V ++ "\x00"));
    try fx.dir.put("mac_open", try machoBytes(a, 0x0100000c, "buildrules " ++ V));
    // Text glued to the front of the version: a longer string that ends with it (the NUL before is what makes the string its own).
    try fx.dir.put("mac_prefixed", try machoBytes(a, 0x0100000c, "\x00x" ++ V ++ "\x00"));
    try fx.dir.put("mac_spaced", try machoBytes(a, 0x0100000c, "\x00 " ++ V ++ "\x00"));
    try fx.dir.put("mac_text", try machoBytes(a, 0x0100000c, "...buildrules " ++ V ++ " extra\n"));
    // A longer version first and the real one after it: the search goes on past the first hit.
    try fx.dir.put("mac_both", try machoBytes(a, 0x0100000c, "\x00" ++ V ++ "0\x00\x00" ++ V ++ "\x00"));
    for ([_][]const u8{ "mac_070", "mac_1007", "mac_dotted", "mac_open", "mac_text", "mac_prefixed", "mac_spaced" }) |bad| {
        try t.expectError(error.WrongVersion, package(a, fx.fake.io(), try fx.opts(a, bad, "macos-arm64", .none)));
    }
    _ = try package(a, fx.fake.io(), try fx.opts(a, "mac_both", "macos-arm64", .none));
    const p = try package(a, fx.fake.io(), try fx.opts(a, "mac", "macos-arm64", .none));
    try t.expectEqualStrings("buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz", p.name);
    try t.expectError(error.WrongVersion, package(a, fx.fake.io(), try fx.opts(a, "mac_old", "macos-arm64", .none)));
    try t.expectError(error.WrongBinary, package(a, fx.fake.io(), try fx.opts(a, "mac", "linux-aarch64", .none)));
    try t.expectEqual(@as(usize, 0), fx.fake.calls.items.len);
}

test "package refuses a version that is not MAJOR.MINOR.PATCH, a leading v, and an unknown target" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();
    for ([_][]const u8{ "v0.0.7", "0.0", "0.0.7-rc1", "0.0.07", "", "0.0.7/../x" }) |bad| {
        var o = try fx.opts(a, "linux", "linux-x86_64", .native);
        o.version = bad;
        try t.expectError(error.BadVersion, package(a, fx.fake.io(), o));
    }
    try t.expectError(error.UnknownTarget, package(a, fx.fake.io(), try fx.opts(a, "linux", "windows-x86_64", .native)));
}

test "package refuses a binary or a LICENSE it cannot read" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();
    try t.expectError(error.FileNotFound, package(a, fx.fake.io(), try fx.opts(a, "missing", "linux-x86_64", .native)));
    var o = try fx.opts(a, "linux", "linux-x86_64", .native);
    o.license = try join(a, fx.dir.path, "no_license");
    try t.expectError(error.FileNotFound, package(a, fx.fake.io(), o));
}

test "parseAssetName reads exactly the names package writes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for (targets) |tg| {
        const n = (try parseAssetName(a, try assetName(a, "10.2.345", tg))).?;
        try t.expectEqualStrings("10.2.345", n.version);
        try t.expectEqualStrings(tg, n.target);
    }
    for ([_][]const u8{
        "buildrules-0.0.7.tar.gz", // the source archive
        "buildrules-cli-0.0.7-linux-x86_64.tar.gz.sha256",
        "buildrules-cli-0.0.7-linux-x86_64.tar.gz.sigstore.json",
        "buildrules-cli-0.0.7-windows-x86_64.tar.gz",
        "buildrules-cli-0.0-linux-x86_64.tar.gz",
        "buildrules-cli-v0.0.7-linux-x86_64.tar.gz",
        "buildrules-cli--linux-x86_64.tar.gz",
        "other-0.0.7-linux-x86_64.tar.gz",
    }) |n| {
        try t.expect(try parseAssetName(a, n) == null);
    }
}

test "record writes the sha256 of the tarball beside the others, and refuses what is not a release tarball" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    const tb = try join(a, dir.path, "buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz");
    const rec = try join(a, dir.path, "rec");
    const name = try record(a, tb, rec, null);
    try t.expectEqualStrings("buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz", name);
    const got = try dir.tmp.dir.readFileAlloc(a, "rec/buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz.sha256", 4096);
    const want = try std.fmt.allocPrint(a, "{s}  {s}\n", .{ assets.sha256Hex("buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz"), name });
    try t.expectEqualStrings(want, got);
    try t.expectError(error.NotAnAsset, record(a, try join(a, dir.path, "buildrules-" ++ V ++ ".tar.gz"), rec, null));
    try t.expectError(error.FileNotFound, record(a, try join(a, dir.path, "nodir/buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz"), rec, null));
}

/// Records for the three tested targets of `dir` into `dir/rec`.
fn recordTested(a: std.mem.Allocator, dir: *Dir) !void {
    for (tested_targets) |tg| {
        _ = try record(a, try join(a, dir.path, try assetName(a, V, tg)), try join(a, dir.path, "rec"), null);
    }
}

test "tested accepts the records of the three tested targets over the very tarballs, and nothing else" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    try recordTested(a, &dir);
    try tested(a, dir.path, try join(a, dir.path, "rec"));
}

test "tested refuses a tarball other than the one the beta ran" {
    // The defect: the attested tarball is rebuilt after the user beta, so the bytes users get were never tested.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    try recordTested(a, &dir);
    try dir.put("buildrules-cli-" ++ V ++ "-linux-aarch64.tar.gz", "rebuilt, other bytes");
    try t.expectError(error.NotTheTestedBytes, tested(a, dir.path, try join(a, dir.path, "rec")));
}

test "tested refuses a missing record, a missing tarball, a stray record, a second record and records of two versions" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    try recordTested(a, &dir);
    const rec = try join(a, dir.path, "rec");
    // `record` writes none for a target that is no release target (the Intel macOS one, dropped); a record put there by hand is not allowed either: the set is exactly the tested targets
    try dir.put("buildrules-cli-" ++ V ++ "-macos-x86_64.tar.gz", "intel");
    try t.expectError(error.NotAnAsset, record(a, try join(a, dir.path, "buildrules-cli-" ++ V ++ "-macos-x86_64.tar.gz"), rec, null));
    try dir.put("rec/buildrules-cli-" ++ V ++ "-macos-x86_64.tar.gz.sha256", "e" ** 64 ++ "  buildrules-cli-" ++ V ++ "-macos-x86_64.tar.gz\n");
    try t.expectError(error.ExtraRecords, tested(a, dir.path, rec));
    try dir.tmp.dir.deleteFile("rec/buildrules-cli-" ++ V ++ "-macos-x86_64.tar.gz.sha256");
    // a second record of one target (another version's) is ambiguous
    try dir.put("buildrules-cli-0.0.6-linux-x86_64.tar.gz", "old");
    _ = try record(a, try join(a, dir.path, "buildrules-cli-0.0.6-linux-x86_64.tar.gz"), rec, null);
    try t.expectError(error.TwoRecords, tested(a, dir.path, rec));
    try dir.tmp.dir.deleteFile("rec/buildrules-cli-0.0.6-linux-x86_64.tar.gz.sha256");
    // a tarball missing from dist
    try dir.tmp.dir.deleteFile("buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz");
    try t.expectError(error.FileNotFound, tested(a, dir.path, rec));
    // a record missing
    try dir.tmp.dir.deleteFile("rec/buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz.sha256");
    try t.expectError(error.NotTested, tested(a, dir.path, rec));
}

test "tested refuses records of two versions and a malformed record" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    const rec = try join(a, dir.path, "rec");
    try recordTested(a, &dir);
    // the linux-aarch64 record names 0.0.6
    try dir.tmp.dir.deleteFile("rec/buildrules-cli-" ++ V ++ "-linux-aarch64.tar.gz.sha256");
    try dir.put("buildrules-cli-0.0.6-linux-aarch64.tar.gz", "x");
    _ = try record(a, try join(a, dir.path, "buildrules-cli-0.0.6-linux-aarch64.tar.gz"), rec, null);
    try t.expectError(error.TwoVersions, tested(a, dir.path, rec));
    // a record whose content names another file
    try dir.tmp.dir.deleteFile("rec/buildrules-cli-0.0.6-linux-aarch64.tar.gz.sha256");
    try dir.put("rec/buildrules-cli-" ++ V ++ "-linux-aarch64.tar.gz.sha256", "e" ** 64 ++ "  other.tar.gz\n");
    try t.expectError(error.BadRecord, tested(a, dir.path, rec));
}

test "sums lists the source archive, the three tarballs and the two debs in name order, and reads the file back" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    const d = try sums(a, dir.path);
    try t.expectEqualStrings(V, d.version);
    const text = try dir.tmp.dir.readFileAlloc(a, "SHA256SUMS", 1 << 20);
    var lines: usize = 0;
    var prev: []const u8 = "";
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        lines += 1;
        try t.expectEqualStrings("  ", line[64..66]);
        try t.expect(std.mem.lessThan(u8, prev, line[66..]));
        prev = line[66..];
    }
    try t.expectEqual(@as(usize, 6), lines);
    try t.expect(std.mem.indexOf(u8, text, assets.sha256Hex("source archive")[0..]) != null);
    for (debs.debs) |dd| try t.expect(std.mem.indexOf(u8, text, try debs.name(a, V, dd.arch)) != null);
    // a second run is the same file
    _ = try sums(a, dir.path);
    try t.expectEqualStrings(text, try dir.tmp.dir.readFileAlloc(a, "SHA256SUMS", 1 << 20));
}

test "sums refuses a missing tarball, a stray one, a second source archive, and tarballs of another version" {
    // The defect: a release with three binaries, or one carrying last release's tarball, signed as complete.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    try dir.tmp.dir.deleteFile("buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz");
    try t.expectError(error.MissingTarball, sums(a, dir.path));
    try dir.put("buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz", "back");
    try dir.put("buildrules-cli-0.0.6-macos-arm64.tar.gz", "stale");
    try t.expectError(error.StrayTarball, sums(a, dir.path));
    try dir.tmp.dir.deleteFile("buildrules-cli-0.0.6-macos-arm64.tar.gz");
    // the Intel macOS tarball of an earlier plan is no release target either
    try dir.put("buildrules-cli-" ++ V ++ "-macos-x86_64.tar.gz", "intel");
    try t.expectError(error.StrayTarball, sums(a, dir.path));
    try dir.tmp.dir.deleteFile("buildrules-cli-" ++ V ++ "-macos-x86_64.tar.gz");
    try dir.put("buildrules-0.0.6.tar.gz", "second source");
    try t.expectError(error.TwoSources, sums(a, dir.path));
    try dir.tmp.dir.deleteFile("buildrules-0.0.6.tar.gz");
    try dir.put("buildrules-cli-" ++ V ++ "-linux-riscv.tar.gz", "unknown target");
    try t.expectError(error.StrayTarball, sums(a, dir.path));
    try dir.tmp.dir.deleteFile("buildrules-cli-" ++ V ++ "-linux-riscv.tar.gz");
    // no source archive at all
    try dir.tmp.dir.deleteFile("buildrules-" ++ V ++ ".tar.gz");
    try t.expectError(error.NoSource, sums(a, dir.path));
}

test "sums refuses when the archive step's SHA256SUMS lists another digest for the source archive" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    try dir.put("SHA256SUMS", "d" ** 64 ++ "  buildrules-" ++ V ++ ".tar.gz\n");
    try t.expectError(error.WrongSums, sums(a, dir.path));
    // the digest the archive step would have written is accepted, and replaced by the six lines
    try dir.put("SHA256SUMS", try std.fmt.allocPrint(a, "{s}  buildrules-{s}.tar.gz\n", .{ assets.sha256Hex("source archive"), V }));
    _ = try sums(a, dir.path);
}

test "checkSums refuses a file that is not exactly the sha256 of the release files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    const d = try sums(a, dir.path);
    const good = try dir.tmp.dir.readFileAlloc(a, "SHA256SUMS", 1 << 20);
    // a changed tarball, a dropped line, a duplicated line, one space, a missing final newline
    try dir.put("buildrules-cli-" ++ V ++ "-linux-x86_64.tar.gz", "changed after sums");
    try t.expectError(error.WrongSums, checkSums(a, dir.path, d.files));
    try dir.put("buildrules-cli-" ++ V ++ "-linux-x86_64.tar.gz", "buildrules-cli-" ++ V ++ "-linux-x86_64.tar.gz");
    try checkSums(a, dir.path, d.files);
    const first_end = std.mem.indexOfScalar(u8, good, '\n').? + 1;
    try dir.put("SHA256SUMS", good[first_end..]);
    try t.expectError(error.WrongSums, checkSums(a, dir.path, d.files));
    try dir.put("SHA256SUMS", try std.mem.concat(a, u8, &.{ good, good[0..first_end] }));
    try t.expectError(error.WrongSums, checkSums(a, dir.path, d.files));
    try dir.put("SHA256SUMS", good[0 .. good.len - 1]);
    try t.expectError(error.WrongSums, checkSums(a, dir.path, d.files));
    var one_space = try a.dupe(u8, good);
    one_space[65] = '*';
    try dir.put("SHA256SUMS", one_space);
    try t.expectError(error.WrongSums, checkSums(a, dir.path, d.files));
}

test "sign runs cosign sign-blob on the six files and SHA256SUMS, and leaves a bundle for each" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    _ = try sums(a, dir.path);
    var fake = FakeCosign{ .a = a };
    try t.expectEqual(@as(usize, 7), try sign(a, fake.io(), dir.path, "cosign"));
    try t.expectEqual(@as(usize, 7), fake.calls.items.len);
    for (fake.calls.items) |c| try t.expect(std.mem.startsWith(u8, c, "cosign sign-blob --yes --oidc-provider github-actions --fulcio-auth-flow token --timeout 90s --bundle "));
    for (targets) |tg| {
        const n = try std.fmt.allocPrint(a, "buildrules-cli-{s}-{s}.tar.gz.sigstore.json", .{ V, tg });
        _ = try dir.tmp.dir.statFile(n);
    }
    for (debs.debs) |dd| _ = try dir.tmp.dir.statFile(try std.fmt.allocPrint(a, "buildrules_{s}_{s}.deb.sigstore.json", .{ V, dd.arch }));
    _ = try dir.tmp.dir.statFile("buildrules-" ++ V ++ ".tar.gz.sigstore.json");
    _ = try dir.tmp.dir.statFile("SHA256SUMS.sigstore.json");
}

test "sign refuses a cosign that fails, one that writes no bundle, and an empty bundle" {
    // The defect: a release published with a file that has no signature, because the signer exited 0 and wrote nothing.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    _ = try sums(a, dir.path);
    var failing = FakeCosign{ .a = a, .fail = "macos-arm64" };
    try t.expectError(error.CosignFailed, sign(a, failing.io(), dir.path, "cosign"));
    try clearBundles(a, &dir);
    var silent = FakeCosign{ .a = a, .skip = "SHA256SUMS" };
    try t.expectError(error.NoBundle, sign(a, silent.io(), dir.path, "cosign"));
    try clearBundles(a, &dir);
    var hollow = FakeCosign{ .a = a, .empty = "linux-aarch64" };
    try t.expectError(error.NoBundle, sign(a, hollow.io(), dir.path, "cosign"));
}

test "sign gives cosign the argv that cannot ask a person for anything, bundle and file last" {
    // The defect: cosign, with no token from the Actions endpoint, falls back to the OAuth device flow and waits for a human until the device code expires.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    _ = try sums(a, dir.path);
    var fake = FakeCosign{ .a = a };
    _ = try sign(a, fake.io(), dir.path, "/opt/cosign");
    const sums_file = try join(a, dir.path, "SHA256SUMS");
    const want = try std.fmt.allocPrint(a, "/opt/cosign sign-blob --yes --oidc-provider github-actions --fulcio-auth-flow token --timeout 90s --bundle {s}.sigstore.json {s}", .{ sums_file, sums_file });
    try t.expectEqualStrings(want, fake.calls.items[fake.calls.items.len - 1]);
}

test "sign tries a call again when the network failed it, with growing delays, and then signs" {
    // The defect: one dropped connection to the Actions token endpoint ended the whole release.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    _ = try sums(a, dir.path);
    const seen = "Generating ephemeral keys...\nerror fetching GitHub OIDC token (will retry): Get \"https://example.invalid/idtoken\": dial tcp 192.0.2.1:443: i/o timeout\n";
    var flaky = FakeCosign{ .a = a, .flaky = "macos-arm64", .flaky_n = 2, .flaky_stderr = seen };
    const s = try signSummary(a, &dir, &flaky, "macos-arm64", 600_000);
    // two failed calls and the third that signs; the delays are 7 ms and 14 ms
    try t.expectEqualStrings("signed on=3 waits=2 sum=21", s);
}

test "sign gives up after three tries of a network failure, and tries a refusal once" {
    // The defects: a retry without a bound, and a retry of a refusal that is a verdict (the same bad call made three times).
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    _ = try sums(a, dir.path);
    var down = FakeCosign{ .a = a, .flaky = "linux-x86_64", .flaky_n = 100, .flaky_stderr = "Error: signing: getting keypair and token: context deadline exceeded" };
    var refused = FakeCosign{ .a = a, .flaky = "linux-x86_64", .flaky_n = 100, .flaky_stderr = "Error: signing: getting keypair and token: oidc: malformed jwt" };
    var boom = FakeCosign{ .a = a, .fail = "linux-x86_64" };
    var spent = FakeCosign{ .a = a, .flaky = "linux-x86_64", .flaky_n = 100, .flaky_stderr = "Error: signing: getting keypair and token: context deadline exceeded" };
    var late = FakeCosign{ .a = a, .flaky = "linux-x86_64", .flaky_n = 100, .flaky_stderr = "Error: signing: getting keypair and token: context deadline exceeded" };
    var roomy = FakeCosign{ .a = a, .flaky = "linux-x86_64", .flaky_n = 100, .flaky_stderr = "Error: signing: getting keypair and token: context deadline exceeded" };
    const got = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
        try signSummary(a, &dir, &down, "linux-x86_64", 600_000),
        try signSummary(a, &dir, &refused, "linux-x86_64", 600_000),
        try signSummary(a, &dir, &boom, "linux-x86_64", 600_000),
        // a network failure, but the time budget of the whole step is used up: no second try
        try signSummary(a, &dir, &spent, "linux-x86_64", 0),
        // the budget (5 ms) is used up by the first wait (7 ms of the manual clock): the second try is made, and no third
        try signSummary(a, &dir, &late, "linux-x86_64", 5),
        // the budget (8 ms) outlasts the first wait (7 ms) and not the second (7 + 14 ms): all three tries, as the tries bound them
        try signSummary(a, &dir, &roomy, "linux-x86_64", 8),
    });
    try t.expectEqualStrings("CosignFailed on=3 waits=2 sum=21\nCosignFailed on=1 waits=0 sum=0\nCosignFailed on=1 waits=0 sum=0\nCosignFailed on=1 waits=0 sum=0\nCosignFailed on=2 waits=1 sum=7\nCosignFailed on=3 waits=2 sum=21", got);
}

/// A clock that only moves when it is told to sleep: `sleep` records the wait and advances `now` by it. Nothing in it reads or spends real time.
const ManualClock = struct {
    t: i64 = 0,
    waits: cmds.Waits = .{},

    fn clock(self: *ManualClock) Clock {
        return .{ .ctx = self, .nowFn = nowAt, .sleepFn = sleepFor };
    }

    fn nowAt(ctx: ?*anyopaque) i64 {
        const self: *ManualClock = @ptrCast(@alignCast(ctx.?));
        return self.t;
    }

    fn sleepFor(ctx: ?*anyopaque, ms: u64) void {
        const self: *ManualClock = @ptrCast(@alignCast(ctx.?));
        self.waits.ms[self.waits.n] = ms;
        self.waits.n += 1;
        self.t += @intCast(ms);
    }
};

/// Signs `dir` with `fake` (delays of 7 ms and 14 ms on a manual clock) and says, in one line, how it ended, how many calls the fake saw on files whose name contains `part`, and
/// the delays it was asked to wait. Clears the bundles after, so the next run starts clean.
fn signSummary(a: std.mem.Allocator, dir: *Dir, fake: *FakeCosign, part: []const u8, budget_ms: i64) ![]const u8 {
    var mc = ManualClock{};
    const w = &mc.waits;
    const res = signRetry(a, fake.io(), dir.path, "cosign", false, .{ .base_ms = 7, .clock = mc.clock(), .budget_ms = budget_ms });
    var on: usize = 0;
    for (fake.calls.items) |c| {
        if (std.mem.indexOf(u8, c, part) != null) on += 1;
    }
    var sum: u64 = 0;
    for (w.ms[0..w.n]) |ms| sum += ms;
    const how = if (res) |_| "signed" else |e| @errorName(e);
    try clearBundles(a, dir);
    return std.fmt.allocPrint(a, "{s} on={d} waits={d} sum={d}", .{ how, on, w.n, sum });
}

test "backoff waits base_ms times the try, records it when asked, and records nothing otherwise" {
    var mc = ManualClock{};
    backoff(.{ .base_ms = 10, .clock = mc.clock() }, 3);
    try t.expect(mc.waits.n == 1 and mc.waits.ms[0] == 30 and mc.t == 30);
    backoff(.{ .base_ms = 0, .clock = mc.clock() }, 1);
    try t.expect(mc.waits.n == 2 and mc.waits.ms[1] == 0 and mc.t == 30);
}

test "the default Clock is the system clock: it reads a time after the epoch, and a wait of 0 ms returns at once" {
    // Only the wiring is checked here (the default is not a manual clock); no duration is measured.
    const c = Clock{};
    try t.expect(c.now() > 0);
    c.sleep(0);
    try t.expect(c.nowFn == &realNow and c.sleepFn == &realSleep);
}

test "isTransientSignFailure: the shape of the failed release run retries, a device-flow wait on its own does not" {
    try t.expect(allTransient(&.{
        "Generating ephemeral keys...\nerror fetching GitHub OIDC token (will retry): Get \"https://x\": dial tcp 192.0.2.1:443: i/o timeout\nNon-interactive mode detected, using device flow.\nError: signing: getting keypair and token: retrieving ID token: authenticating caller: error obtaining token: expired_token",
        "Error: reading ID token: fetching ambient OIDC credentials: Get \"https://x\": EOF",
        "Error: signing: [POST /api/v2/signingCert][503] createSigningCertificate",
        "Error: Post \"https://x\": net/http: TLS handshake timeout",
        "Error: context deadline exceeded",
        "Error: read tcp: connection reset by peer",
        "Error: dial tcp 192.0.2.1:443: connect: connection refused",
        "Error: dial tcp: lookup example.invalid: no such host",
        "Error: Post \"https://x\": unexpected EOF",
        "Error: signing: [502] bad",
        "Error: signing: [504] bad",
        "Error: signing: [429] slow down",
        "Error: unexpected status: 502 Bad Gateway",
        "Error: unexpected status: 503 Service Unavailable",
        "Error: unexpected status: 504 Gateway Timeout",
    }));
    try t.expect(!anyTransient(&.{
        "Error: signing: error obtaining token: expired_token",
        "Error: signing: [400] createSigningCertificate",
        // cosign prints this line even when its own retry then succeeds; it says nothing by itself
        "error fetching GitHub OIDC token (will retry): Get \"https://x\": 401 Unauthorized\nError: signing: [400] createSigningCertificate",
        "boom",
        "",
    }));
}

fn allTransient(list: []const []const u8) bool {
    for (list) |s| {
        if (!isTransientSignFailure(s)) return false;
    }
    return true;
}

fn anyTransient(list: []const []const u8) bool {
    for (list) |s| {
        if (isTransientSignFailure(s)) return true;
    }
    return false;
}

fn clearBundles(a: std.mem.Allocator, dir: *Dir) !void {
    var it = (try dir.tmp.dir.openDir(".", .{ .iterate = true })).iterate();
    var doomed = std.ArrayList([]const u8).empty;
    while (try it.next()) |e| {
        if (std.mem.endsWith(u8, e.name, ".sigstore.json")) try doomed.append(a, try a.dupe(u8, e.name));
    }
    for (doomed.items) |n| try dir.tmp.dir.deleteFile(n);
}

test "sign refuses a stale bundle, a SHA256SUMS that no longer matches, and a stray tarball; it signs nothing in those cases" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    _ = try sums(a, dir.path);
    var fake = FakeCosign{ .a = a };
    try dir.put("SHA256SUMS.sigstore.json", "{}");
    try t.expectError(error.StaleBundle, sign(a, fake.io(), dir.path, "cosign"));
    try dir.tmp.dir.deleteFile("SHA256SUMS.sigstore.json");
    try dir.put("buildrules-cli-" ++ V ++ "-linux-x86_64.tar.gz", "changed after sums");
    try t.expectError(error.WrongSums, sign(a, fake.io(), dir.path, "cosign"));
    try dir.put("buildrules-cli-" ++ V ++ "-linux-x86_64.tar.gz", "buildrules-cli-" ++ V ++ "-linux-x86_64.tar.gz");
    try dir.put("buildrules-cli-0.0.6-linux-x86_64.tar.gz", "stray");
    try t.expectError(error.StrayTarball, sign(a, fake.io(), dir.path, "cosign"));
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "record --ran-binary: the tarball must hold the very file the user beta ran" {
    // The defect: the beta ran one build and the tarball that is attested holds another (a second build, a stale artifact): the record would vouch for bytes no leg ran.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();
    const p = try package(a, fx.fake.io(), try fx.opts(a, "linux", "linux-x86_64", .native));
    const tb = try join(a, fx.out, p.name);
    const rec = try join(a, fx.dir.path, "rec");
    // the file that ran: accepted, and the record is written
    _ = try record(a, tb, rec, try join(a, fx.dir.path, "linux"));
    _ = try fx.dir.tmp.dir.statFile("rec/" ++ "buildrules-cli-" ++ V ++ "-linux-x86_64.tar.gz.sha256");
    // another program: refused, and nothing is recorded for it
    try fx.dir.put("other", try elfBytes(a, 62, 1, "buildrules " ++ V ++ " but another build"));
    try fx.dir.tmp.dir.deleteFile("rec/" ++ "buildrules-cli-" ++ V ++ "-linux-x86_64.tar.gz.sha256");
    try t.expectError(error.NotTheBinaryThatRan, record(a, tb, rec, try join(a, fx.dir.path, "other")));
    try t.expectError(error.FileNotFound, fx.dir.tmp.dir.statFile("rec/" ++ "buildrules-cli-" ++ V ++ "-linux-x86_64.tar.gz.sha256"));
    // a binary that cannot be read is an error, not a pass
    try t.expectError(error.FileNotFound, record(a, tb, rec, try join(a, fx.dir.path, "nothing")));
    // a tarball without the program inside it (the source archive's name is refused earlier; a tarball of nothing is refused here)
    try fx.dir.put("empty.tar.gz", try gz.gzip(a, try tar.build(a, &.{})));
    const empty = try join(a, fx.dir.path, "buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz");
    try fx.dir.tmp.dir.rename("empty.tar.gz", "buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz");
    try t.expectError(error.NoBinaryInTarball, record(a, empty, rec, try join(a, fx.dir.path, "linux")));
}

test "package-all packages the three targets from <bins>/<target>/buildrules, runs only the native ones, and refuses a typo" {
    // The defects: a target missing from the directory, the run of a binary quietly turned into the weaker text check by a misspelt native target.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();
    const tail = "\x00" ++ V ++ "\x00";
    try fx.dir.tmp.dir.makePath("bins/linux-x86_64");
    try fx.dir.tmp.dir.makePath("bins/linux-aarch64");
    try fx.dir.tmp.dir.makePath("bins/macos-arm64");
    try fx.dir.put("bins/linux-x86_64/buildrules", try elfBytes(a, 62, 1, tail));
    try fx.dir.put("bins/linux-aarch64/buildrules", try elfBytes(a, 183, 1, tail));
    try fx.dir.put("bins/macos-arm64/buildrules", try machoBytes(a, 0x0100000c, tail));
    const o = PackageAllOpts{ .version = V, .bins = try join(a, fx.dir.path, "bins"), .license = try join(a, fx.dir.path, "LICENSE"), .out = fx.out, .native = &.{"linux-x86_64"} };
    const done = try packageAll(a, fx.fake.io(), o);
    try t.expectEqual(@as(usize, 3), done.len);
    for (targets, done) |tg, p| try t.expectEqualStrings(try assetName(a, V, tg), p.name);
    // only the native target was run
    try t.expectEqual(@as(usize, 1), fx.fake.calls.items.len);
    try t.expect(std.mem.endsWith(u8, fx.fake.calls.items[0], "bins/linux-x86_64/buildrules --version"));
    // a typo in native, or a target left out of the directory
    var typo = o;
    typo.native = &.{"linux-x86-64"};
    try t.expectError(error.UnknownTarget, packageAll(a, fx.fake.io(), typo));
    try fx.dir.tmp.dir.deleteFile("bins/macos-arm64/buildrules");
    try t.expectError(error.FileNotFound, packageAll(a, fx.fake.io(), o));
    // each target's binary is held to its own header: the Intel Mach-O file in the arm64 place is refused
    try fx.dir.put("bins/macos-arm64/buildrules", try machoBytes(a, 0x01000007, tail));
    try t.expectError(error.WrongBinary, packageAll(a, fx.fake.io(), o));
}

test "tested for the targets walked so far: a subset, never an unknown or an empty list, and no record outside it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    const rec = try join(a, dir.path, "rec");
    _ = try record(a, try join(a, dir.path, try assetName(a, V, "linux-x86_64")), rec, null);
    try testedFor(a, dir.path, rec, &.{"linux-x86_64"});
    // the full list wants the other records
    try t.expectError(error.NotTested, tested(a, dir.path, rec));
    try t.expectError(error.NoTargets, testedFor(a, dir.path, rec, &.{}));
    try t.expectError(error.UnknownTarget, testedFor(a, dir.path, rec, &.{"macos-x86_64"}));
    try t.expectError(error.UnknownTarget, testedFor(a, dir.path, rec, &.{"linux-x86-64"}));
    // a record for a target outside the walked list is not tolerated
    _ = try record(a, try join(a, dir.path, try assetName(a, V, "macos-arm64")), rec, null);
    try t.expectError(error.ExtraRecords, testedFor(a, dir.path, rec, &.{"linux-x86_64"}));
    // and the tarball that is attested must be the recorded bytes
    try dir.put(try assetName(a, V, "linux-x86_64"), "another build");
    try t.expectError(error.NotTheTestedBytes, testedFor(a, dir.path, rec, &.{ "linux-x86_64", "macos-arm64" }));
}

test "sign --dry makes every check of sign and signs nothing" {
    // The defect: a dry run that does less than the real one (so it is green and the real one is red), or one that signs.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    _ = try sums(a, dir.path);
    var fake = FakeCosign{ .a = a };
    try t.expectEqual(@as(usize, 7), try signWith(a, fake.io(), dir.path, "cosign", true));
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
    try t.expectError(error.FileNotFound, dir.tmp.dir.statFile("SHA256SUMS.sigstore.json"));
    // the same refusals: a stale bundle, sums that no longer match, a stray tarball, and a missing tarball
    try dir.put("SHA256SUMS.sigstore.json", "{}");
    try t.expectError(error.StaleBundle, signWith(a, fake.io(), dir.path, "cosign", true));
    try dir.tmp.dir.deleteFile("SHA256SUMS.sigstore.json");
    try dir.put("buildrules-cli-" ++ V ++ "-linux-x86_64.tar.gz", "changed");
    try t.expectError(error.WrongSums, signWith(a, fake.io(), dir.path, "cosign", true));
    try dir.put("buildrules-stray.tar.gz", "x");
    try t.expectError(error.StrayTarball, signWith(a, fake.io(), dir.path, "cosign", true));
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
}

/// Runs `ctx.call(allocator)` with the allocator failing at its 1st, 2nd, ... allocation, until a run meets no failure. A run in which an allocation
/// failed must not report success: a swallowed out-of-memory would package, record, accept or list a release no check had finished.
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

test "out of memory: package, record, tested and sums fail, and never report success" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();

    const Package_ = struct {
        a: std.mem.Allocator,
        fx: *Fixture,
        fn call(self: @This(), x: std.mem.Allocator) !bool {
            const o = try self.fx.opts(self.a, "linux", "linux-x86_64", .native);
            const p = try package(x, self.fx.fake.io(), o);
            return p.name.len != 0;
        }
    };
    try sweepOutOfMemory(Package_{ .a = a, .fx = &fx });

    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    const tb = try join(a, dir.path, "buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz");
    const rec = try join(a, dir.path, "rec");

    const Record_ = struct {
        tb: []const u8,
        rec: []const u8,
        fn call(self: @This(), x: std.mem.Allocator) !bool {
            return (try record(x, self.tb, self.rec, null)).len != 0;
        }
    };
    try sweepOutOfMemory(Record_{ .tb = tb, .rec = rec });

    try recordTested(a, &dir);
    const Tested_ = struct {
        dir: []const u8,
        rec: []const u8,
        fn call(self: @This(), x: std.mem.Allocator) !bool {
            try tested(x, self.dir, self.rec);
            return true;
        }
    };
    try sweepOutOfMemory(Tested_{ .dir = dir.path, .rec = rec });

    const Sums_ = struct {
        dir: []const u8,
        fn call(self: @This(), x: std.mem.Allocator) !bool {
            const d = try sums(x, self.dir);
            return d.version.len != 0;
        }
    };
    try sweepOutOfMemory(Sums_{ .dir = dir.path });
}

// ---- debs ---------------------------------------------------------------------------------------------------------------------------------

/// A scripted `channels`: `deb-package` writes the package a real one would (debs.sample) from the binary it is given, unless told to fail, to write nothing,
/// to write an empty file, or to pack another program than the one it was given.
const FakeChannels = struct {
    a: std.mem.Allocator,
    calls: std.ArrayList([]const u8) = .empty,
    fail: bool = false,
    silent: bool = false,
    empty: bool = false,
    /// Pack this instead of the binary named by --binary (a defect: the .deb holds another program than the tarball).
    other_binary: []const u8 = "",
    /// Label this architecture instead of --arch (a defect: the .deb says it is another package than its name).
    other_arch: []const u8 = "",

    fn flag(argv: []const []const u8, name: []const u8) []const u8 {
        for (argv, 0..) |x, i| {
            if (std.mem.eql(u8, x, name) and i + 1 < argv.len) return argv[i + 1];
        }
        return "";
    }

    fn run(ctx: *anyopaque, a: std.mem.Allocator, argv: []const []const u8) anyerror!cmds.Out {
        const self: *FakeChannels = @ptrCast(@alignCast(ctx));
        try self.calls.append(self.a, try std.mem.join(self.a, " ", argv));
        if (argv.len < 2 or !std.mem.eql(u8, argv[1], "deb-package")) {
            std.debug.print("unscripted command: {s}\n", .{try std.mem.join(a, " ", argv)});
            return error.UnscriptedCommand;
        }
        if (self.fail) return .{ .code = 1, .stdout = "", .stderr = "boom" };
        if (self.silent) return .{ .code = 0, .stdout = "", .stderr = "" };
        const out = flag(argv, "--out");
        if (self.empty) {
            try std.fs.cwd().writeFile(.{ .sub_path = out, .data = "" });
            return .{ .code = 0, .stdout = "", .stderr = "" };
        }
        const binary = if (self.other_binary.len != 0) self.other_binary else try std.fs.cwd().readFileAlloc(a, flag(argv, "--binary"), 1 << 20);
        const arch = if (self.other_arch.len != 0) self.other_arch else flag(argv, "--arch");
        try std.fs.cwd().writeFile(.{ .sub_path = out, .data = try debs_sample.sample(a, flag(argv, "--version"), arch, binary) });
        return .{ .code = 0, .stdout = "", .stderr = "" };
    }

    fn write(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}

    fn io(self: *FakeChannels) cmds.Io {
        return .{ .ctx = self, .run_fn = run, .write_fn = write };
    }
};

/// A fixture with the three binaries of `bins/<target>/buildrules` (each says its version and differs from the others), a source archive, and the three
/// tarballs `packageAll` made of the binaries, all in `dist`.
fn debDist(a: std.mem.Allocator, fx: *Fixture) !PackageDebsOpts {
    const tail = "\x00" ++ V ++ "\x00";
    try fx.dir.tmp.dir.makePath("bins/linux-x86_64");
    try fx.dir.tmp.dir.makePath("bins/linux-aarch64");
    try fx.dir.tmp.dir.makePath("bins/macos-arm64");
    try fx.dir.put("bins/linux-x86_64/buildrules", try elfBytes(a, 62, 1, tail));
    try fx.dir.put("bins/linux-aarch64/buildrules", try elfBytes(a, 183, 1, tail));
    try fx.dir.put("bins/macos-arm64/buildrules", try machoBytes(a, 0x0100000c, tail));
    _ = try packageAll(a, fx.fake.io(), .{ .version = V, .bins = try join(a, fx.dir.path, "bins"), .license = try join(a, fx.dir.path, "LICENSE"), .out = fx.out, .native = &.{"linux-x86_64"} });
    try fx.dir.tmp.dir.writeFile(.{ .sub_path = "out/buildrules-" ++ V ++ ".tar.gz", .data = "source archive" });
    return .{ .version = V, .bins = try join(a, fx.dir.path, "bins"), .channels = "channels", .packaging = "packaging/deb", .out = fx.out };
}

test "debs: channels deb-package runs for each architecture on the binary of its target, and the files are named for the version and the architecture" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();
    const o = try debDist(a, &fx);
    var ch = FakeChannels{ .a = a };
    const done = try packageDebs(a, ch.io(), o);
    try t.expectEqual(@as(usize, 2), done.len);
    try t.expectEqualStrings("buildrules_" ++ V ++ "_amd64.deb", done[0].name);
    try t.expectEqualStrings("buildrules_" ++ V ++ "_arm64.deb", done[1].name);
    try t.expectEqual(@as(usize, 2), ch.calls.items.len);
    // the binary of the target, the name, the version, the architecture and the metadata directory, each as its own word
    const x86 = try std.fmt.allocPrint(a, "channels deb-package --binary {s}/bins/linux-x86_64/buildrules --name buildrules --version {s} --arch amd64 --packaging packaging/deb --out {s}/buildrules_{s}_amd64.deb", .{ fx.dir.path, V, fx.out, V });
    try t.expectEqualStrings(x86, ch.calls.items[0]);
    try t.expect(std.mem.indexOf(u8, ch.calls.items[1], "bins/linux-aarch64/buildrules --name buildrules --version " ++ V ++ " --arch arm64 ") != null);
    // the digests returned are the digests of the files written
    for (done) |p| {
        const bytes = try fx.dir.tmp.dir.readFileAlloc(a, try join(a, "out", p.name), 1 << 20);
        try t.expectEqualSlices(u8, &assets.sha256Hex(bytes), &p.sha256);
    }
    // the same inputs, the same bytes
    const again = try packageDebs(a, ch.io(), o);
    try t.expectEqualSlices(u8, &done[0].sha256, &again[0].sha256);
}

test "debs: a channels that fails, writes nothing or writes an empty file, a missing binary and a bad version are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();
    const o = try debDist(a, &fx);
    var failing = FakeChannels{ .a = a, .fail = true };
    try t.expectError(error.ChannelsFailed, packageDebs(a, failing.io(), o));
    var silent = FakeChannels{ .a = a, .silent = true };
    try t.expectError(error.NoDeb, packageDebs(a, silent.io(), o));
    var hollow = FakeChannels{ .a = a, .empty = true };
    try t.expectError(error.NoDeb, packageDebs(a, hollow.io(), o));
    var ch = FakeChannels{ .a = a };
    try fx.dir.tmp.dir.deleteFile("bins/linux-aarch64/buildrules");
    try t.expectError(error.FileNotFound, packageDebs(a, ch.io(), o)); // the fake reads the binary it is given, as the real one does
    for ([_][]const u8{ "v0.0.7", "0.0", "0.0.7-rc1", "" }) |bad| {
        var b = o;
        b.version = bad;
        try t.expectError(error.BadVersion, packageDebs(a, ch.io(), b));
    }
}

test "checkDebs accepts the debs made from the binaries the tarballs hold" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();
    const o = try debDist(a, &fx);
    var ch = FakeChannels{ .a = a };
    _ = try packageDebs(a, ch.io(), o);
    try checkDebs(a, fx.out);
}

test "checkDebs refuses a .deb that holds another program than its tarball, another package, or no package at all" {
    // The defects: a .deb built from a binary that was not the one packaged and tested; a .deb that says it is another version or architecture than
    // its name; a file named like a .deb that is not one.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();
    const o = try debDist(a, &fx);
    var ch = FakeChannels{ .a = a };
    _ = try packageDebs(a, ch.io(), o);
    try checkDebs(a, fx.out);

    var other = FakeChannels{ .a = a, .other_binary = "another program" };
    _ = try packageDebs(a, other.io(), o);
    try t.expectError(error.WrongBinary, checkDebs(a, fx.out));

    var mislabelled = FakeChannels{ .a = a, .other_arch = "i386" };
    _ = try packageDebs(a, mislabelled.io(), o);
    try t.expectError(error.WrongControl, checkDebs(a, fx.out));

    _ = try packageDebs(a, ch.io(), o);
    try checkDebs(a, fx.out);
    try fx.dir.put("out/buildrules_" ++ V ++ "_arm64.deb", "not a deb");
    try t.expectError(error.NotADeb, checkDebs(a, fx.out));

    // the tarball changed after the deb was made: the deb holds the program the tarball no longer does
    _ = try packageDebs(a, ch.io(), o);
    try fx.dir.put("bins/linux-aarch64/buildrules", try elfBytes(a, 183, 1, "\x00" ++ V ++ "\x00 but rebuilt"));
    _ = try package(a, fx.fake.io(), .{ .version = V, .target = "linux-aarch64", .binary = try join(a, fx.dir.path, "bins/linux-aarch64/buildrules"), .license = try join(a, fx.dir.path, "LICENSE"), .out = fx.out, .exec = .none });
    try t.expectError(error.WrongBinary, checkDebs(a, fx.out));
}

test "checkDebs refuses a release without a .deb, with a .deb of another version, or with a stray one" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();
    const o = try debDist(a, &fx);
    try t.expectError(error.MissingDeb, checkDebs(a, fx.out));
    var ch = FakeChannels{ .a = a };
    _ = try packageDebs(a, ch.io(), o);
    try fx.dir.tmp.dir.deleteFile("out/buildrules_" ++ V ++ "_arm64.deb");
    try t.expectError(error.MissingDeb, checkDebs(a, fx.out));
    try fx.dir.put("out/buildrules_0.0.6_arm64.deb", "last release's");
    try t.expectError(error.MissingDeb, checkDebs(a, fx.out));
    _ = try packageDebs(a, ch.io(), o);
    try t.expectError(error.StrayTarball, checkDebs(a, fx.out));
    try fx.dir.tmp.dir.deleteFile("out/buildrules_0.0.6_arm64.deb");
    try fx.dir.put("out/buildrules_" ++ V ++ "_i386.deb", "an architecture this release has no deb for");
    try t.expectError(error.StrayDeb, checkDebs(a, fx.out));
}

test "sums and sign refuse a release whose .debs are missing, stray or of another version, and sign nothing" {
    // The defect: a release signed and published as complete without its .debs, or carrying last release's.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    try dir.tmp.dir.deleteFile("buildrules_" ++ V ++ "_amd64.deb");
    try t.expectError(error.MissingDeb, sums(a, dir.path));
    try dir.put("buildrules_" ++ V ++ "_amd64.deb", "back");
    _ = try sums(a, dir.path);
    try dir.put("buildrules_0.0.6_amd64.deb", "stale");
    try t.expectError(error.StrayTarball, sums(a, dir.path));
    var fake = FakeCosign{ .a = a };
    try t.expectError(error.StrayTarball, sign(a, fake.io(), dir.path, "cosign"));
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
    try dir.tmp.dir.deleteFile("buildrules_0.0.6_amd64.deb");
    try dir.put("buildrules_" ++ V ++ "_ppc64.deb", "no such architecture");
    try t.expectError(error.StrayDeb, sums(a, dir.path));
}

test "out of memory: the .debs are made and checked, or the step fails, and never reports success" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();
    const o = try debDist(a, &fx);
    var ch = FakeChannels{ .a = a };

    const Debs_ = struct {
        o: PackageDebsOpts,
        ch: *FakeChannels,
        fn call(self: @This(), x: std.mem.Allocator) !bool {
            const done = try packageDebs(x, self.ch.io(), self.o);
            return done.len == debs.debs.len;
        }
    };
    try sweepOutOfMemory(Debs_{ .o = o, .ch = &ch });

    const Check_ = struct {
        dir: []const u8,
        fn call(self: @This(), x: std.mem.Allocator) !bool {
            try checkDebs(x, self.dir);
            return true;
        }
    };
    try sweepOutOfMemory(Check_{ .dir = fx.out });
}
