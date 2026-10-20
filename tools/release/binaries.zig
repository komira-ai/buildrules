//! The command-line binaries of a release (RELEASING.md): `release package`, `record`, `tested`, `sums` and `sign`. Each release carries, besides the
//! source archive `buildrules-<V>.tar.gz`, four tarballs `buildrules-cli-<V>-<target>.tar.gz` (the name keeps them apart from the source archive,
//! which the pipeline finds by the glob `buildrules-*.tar.gz` minus `cli-`), each holding `buildrules-cli-<V>-<target>/{buildrules,LICENSE}`.
//!
//!   package   one binary and the LICENSE into its tarball, after checking the file header is the target's (binhdr.zig) and that it says it is version V
//!   record    the sha256 of a tarball the user beta ran, to a file beside the others
//!   tested    refuses unless every tarball the user beta ran is, byte for byte, the tarball to be attested
//!   sums      SHA256SUMS over the source archive and the four tarballs, then read back
//!   sign      a keyless `cosign sign-blob` bundle per file (the five and SHA256SUMS), none empty, none stale
//!
//! A program that is not run here (the Intel macOS binary on a Linux runner) is not run by `package`: its header and its stamped version text are
//! checked, and the beta legs that do run it on its own platform are what prove it works. Nothing here uploads anything. The commands it runs go through
//! `cmds.Io`, so a test scripts them.
const std = @import("std");
const cmds = @import("cmds.zig");
const version = @import("version.zig");
const assets = @import("assets.zig");
const gz = @import("gz.zig");
const tar = @import("tar.zig");
const binhdr = @import("binhdr");

pub const targets = binhdr.targets;

/// The targets whose tarball the user beta walks on a machine of its own (the Intel macOS binary has no runner).
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
        .none => if (std.mem.indexOf(u8, bin, o.version) == null) {
            std.debug.print("release package: the binary does not hold the version text `{s}`; refusing to package\n", .{o.version});
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

// ---- record, tested -----------------------------------------------------------------------------------------------------------------------

/// Writes `<outdir>/<tarball name>.sha256` holding `<sha256>  <name>`: the bytes a user-beta leg ran.
pub fn record(a: std.mem.Allocator, tarball: []const u8, outdir: []const u8) ![]const u8 {
    const name = std.fs.path.basename(tarball);
    if (try parseAssetName(a, name) == null) {
        std.debug.print("release record: {s} is not a buildrules-cli-<V>-<target>.tar.gz\n", .{name});
        return error.NotAnAsset;
    }
    const hex = assets.sha256Hex(try readFile(a, tarball));
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
    for (tested_targets) |tg| {
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
    /// The source archive and the four tarballs, sorted by name.
    files: []const []const u8,
};

/// The release files of `dist_dir`: exactly one source archive `buildrules-<V>.tar.gz` and one tarball per target, all of the version V. Any
/// other `buildrules-*.tar.gz` is refused (a stray or stale file would be signed).
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
    if (names.items.len != targets.len + 1) {
        std.debug.print("release: {s} holds {d} release tarballs, expected {d}\n", .{ dist_dir, names.items.len, targets.len + 1 });
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
        std.debug.print("release: {s} is not the sha256 of exactly the {d} release tarballs, in name order\n", .{ cmds.sums_name, files.len });
        return error.WrongSums;
    }
}

/// Writes `<dist>/SHA256SUMS` over the source archive and the four tarballs, then reads it back. If the file exists (the archive step wrote the
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

/// `cosign sign-blob --yes --bundle <file>.sigstore.json <file>` for the five release files and SHA256SUMS, after SHA256SUMS is checked. A bundle that
/// exists beforehand is refused (a command that wrote nothing would pass on it), and one that is empty afterwards is refused.
pub fn sign(a: std.mem.Allocator, io: cmds.Io, dist_dir: []const u8, cosign: []const u8) !usize {
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
    for (all.items) |n| {
        const file = try join(a, dist_dir, n);
        const bundle = try std.fmt.allocPrint(a, "{s}.sigstore.json", .{file});
        const r = try io.run(a, &.{ cosign, "sign-blob", "--yes", "--bundle", bundle, file });
        if (r.code != 0) {
            std.debug.print("release sign: cosign sign-blob failed for {s}: {s}\n", .{ n, r.stderr });
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

const V = "0.0.7";

/// A tmp dir holding the files of a release of version `V`; each tarball's bytes are its own name (distinct), the source archive too.
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
    version_says: []const u8 = "buildrules " ++ V ++ "\n",
    version_code: u8 = 0,

    fn run(ctx: *anyopaque, a: std.mem.Allocator, argv: []const []const u8) anyerror!cmds.Out {
        const self: *FakeCosign = @ptrCast(@alignCast(ctx));
        try self.calls.append(self.a, try std.mem.join(self.a, " ", argv));
        if (argv.len == 2 and std.mem.eql(u8, argv[1], "--version")) {
            return .{ .code = self.version_code, .stdout = self.version_says, .stderr = "" };
        }
        if (argv.len != 6 or !std.mem.eql(u8, argv[1], "sign-blob") or !std.mem.eql(u8, argv[2], "--yes") or !std.mem.eql(u8, argv[3], "--bundle")) {
            std.debug.print("unscripted command: {s}\n", .{try std.mem.join(a, " ", argv)});
            return error.UnscriptedCommand;
        }
        const file = argv[5];
        if (self.fail.len != 0 and std.mem.indexOf(u8, file, self.fail) != null) return .{ .code = 1, .stdout = "", .stderr = "boom" };
        if (self.skip.len != 0 and std.mem.indexOf(u8, file, self.skip) != null) return .{ .code = 0, .stdout = "", .stderr = "" };
        const body: []const u8 = if (self.empty.len != 0 and std.mem.indexOf(u8, file, self.empty) != null) "" else "{\"bundle\":1}";
        try std.fs.cwd().writeFile(.{ .sub_path = argv[4], .data = body });
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
    // The defect: the Intel macOS binary stamped with another version, which only a run on a Mac would show.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try Fixture.make(a);
    defer fx.dir.tmp.cleanup();
    try fx.dir.put("mac", try machoBytes(a, 0x01000007, "...buildrules " ++ V ++ "..."));
    try fx.dir.put("mac_old", try machoBytes(a, 0x01000007, "...0.0.3-poc..."));
    const p = try package(a, fx.fake.io(), try fx.opts(a, "mac", "macos-x86_64", .none));
    try t.expectEqualStrings("buildrules-cli-" ++ V ++ "-macos-x86_64.tar.gz", p.name);
    try t.expectError(error.WrongVersion, package(a, fx.fake.io(), try fx.opts(a, "mac_old", "macos-x86_64", .none)));
    try t.expectError(error.WrongBinary, package(a, fx.fake.io(), try fx.opts(a, "mac", "macos-arm64", .none)));
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
    const name = try record(a, tb, rec);
    try t.expectEqualStrings("buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz", name);
    const got = try dir.tmp.dir.readFileAlloc(a, "rec/buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz.sha256", 4096);
    const want = try std.fmt.allocPrint(a, "{s}  {s}\n", .{ assets.sha256Hex("buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz"), name });
    try t.expectEqualStrings(want, got);
    try t.expectError(error.NotAnAsset, record(a, try join(a, dir.path, "buildrules-" ++ V ++ ".tar.gz"), rec));
    try t.expectError(error.FileNotFound, record(a, try join(a, dir.path, "nodir/buildrules-cli-" ++ V ++ "-macos-arm64.tar.gz"), rec));
}

/// Records for the three tested targets of `dir` into `dir/rec`.
fn recordTested(a: std.mem.Allocator, dir: *Dir) !void {
    for (tested_targets) |tg| {
        _ = try record(a, try join(a, dir.path, try assetName(a, V, tg)), try join(a, dir.path, "rec"));
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
    // a record for a target the beta did not run is not allowed either: the set is exactly the tested targets
    _ = try record(a, try join(a, dir.path, "buildrules-cli-" ++ V ++ "-macos-x86_64.tar.gz"), rec);
    try t.expectError(error.ExtraRecords, tested(a, dir.path, rec));
    try dir.tmp.dir.deleteFile("rec/buildrules-cli-" ++ V ++ "-macos-x86_64.tar.gz.sha256");
    // a second record of one target (another version's) is ambiguous
    try dir.put("buildrules-cli-0.0.6-linux-x86_64.tar.gz", "old");
    _ = try record(a, try join(a, dir.path, "buildrules-cli-0.0.6-linux-x86_64.tar.gz"), rec);
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
    _ = try record(a, try join(a, dir.path, "buildrules-cli-0.0.6-linux-aarch64.tar.gz"), rec);
    try t.expectError(error.TwoVersions, tested(a, dir.path, rec));
    // a record whose content names another file
    try dir.tmp.dir.deleteFile("rec/buildrules-cli-0.0.6-linux-aarch64.tar.gz.sha256");
    try dir.put("rec/buildrules-cli-" ++ V ++ "-linux-aarch64.tar.gz.sha256", "e" ** 64 ++ "  other.tar.gz\n");
    try t.expectError(error.BadRecord, tested(a, dir.path, rec));
}

test "sums lists the source archive and the four tarballs in name order, and reads the file back" {
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
    try t.expectEqual(@as(usize, 5), lines);
    try t.expect(std.mem.indexOf(u8, text, assets.sha256Hex("source archive")[0..]) != null);
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
    try dir.tmp.dir.deleteFile("buildrules-cli-" ++ V ++ "-macos-x86_64.tar.gz");
    try t.expectError(error.MissingTarball, sums(a, dir.path));
    try dir.put("buildrules-cli-" ++ V ++ "-macos-x86_64.tar.gz", "back");
    try dir.put("buildrules-cli-0.0.6-macos-x86_64.tar.gz", "stale");
    try t.expectError(error.StrayTarball, sums(a, dir.path));
    try dir.tmp.dir.deleteFile("buildrules-cli-0.0.6-macos-x86_64.tar.gz");
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
    // the digest the archive step would have written is accepted, and replaced by the five lines
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

test "sign runs cosign sign-blob on the five files and SHA256SUMS, and leaves a bundle for each" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = try Dir.make(a);
    defer dir.tmp.cleanup();
    try dir.release(a);
    _ = try sums(a, dir.path);
    var fake = FakeCosign{ .a = a };
    try t.expectEqual(@as(usize, 6), try sign(a, fake.io(), dir.path, "cosign"));
    try t.expectEqual(@as(usize, 6), fake.calls.items.len);
    for (fake.calls.items) |c| try t.expect(std.mem.startsWith(u8, c, "cosign sign-blob --yes --bundle "));
    for (targets) |tg| {
        const n = try std.fmt.allocPrint(a, "buildrules-cli-{s}-{s}.tar.gz.sigstore.json", .{ V, tg });
        _ = try dir.tmp.dir.statFile(n);
    }
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
