//! `buildrules sync --sources DIR`: a sync that downloads nothing (docs/contract.md, "Sync without the network").
//!
//! A farm action has no network, so cargo cannot fetch crates.io or clone a git repository in it. Everything a sync of a
//! repository fetches is pinned already: Cargo.lock records the sha256 of every crates.io package, and
//! third_party/buildrules/git_archives.tsv the sha256 and size of GitHub's archive of every git commit. So the files can be
//! downloaded by hash before the action (rules/rust/sync.bzl asks `--list-sources` which), and the sync reads them from DIR:
//!
//!   <name>-<version>.crate              each crates.io package of Cargo.lock, whose sha256 must be Cargo.lock's checksum
//!   <owner>_<repository>_<commit>.tar.gz   each git commit of Cargo.lock, whose sha256 and size must be the record's
//!
//! cargo is pointed at them as *directory sources* (what `cargo vendor` writes; `[source]` replacement in cargo's own config,
//! under buck-out/buildrules/cargo-home), so every id it prints is still crates.io's or the git source's, and the files a sync
//! writes are the ones a sync with the network writes:
//!   - a crate is unpacked to buck-out/buildrules/vendor/registry/src/crates-io/<name>-<version>/, a path of the form the
//!     generator reads a registry package from (unitgen.zig), and copied to cargo's registry cache, where the sizes are read;
//!   - an archive is unpacked to cargo-home/git/checkouts/<owner>_<repository>/<commit>/, the form of cargo's own checkout,
//!     which the generator and git_archive.zig read. Each package of it gets a directory of symbolic links to its files in
//!     buck-out/buildrules/vendor/git/<owner>_<repository>_<commit>/, since a directory source holds one package per
//!     directory, and beside them a link to the repository's root manifest, from which a member inherits workspace keys. A
//!     package's files are those of the manifest cargo takes for it, also when the repository holds the package's manifest more
//!     than once (a test fixture that copies a crate): cargo_walk.zig.
//! A package Cargo.lock does not name cannot be resolved this way: cargo names it, and a sync with the network adds it.

const std = @import("std");
const cargo_lock = @import("cargo_lock.zig");
const cargo_walk = @import("cargo_walk.zig");
const contract = @import("contract.zig");
const git_archive = @import("git_archive.zig");
const git_source = @import("git_source.zig");
const Diag = @import("diag.zig").Diag;

pub const Error = anyerror;

/// The source Cargo.lock names crates.io by.
pub const crates_io = "registry+https://github.com/rust-lang/crates.io-index";

/// Below the repository root (sync.zig's work directory).
pub const vendor_dir = "buck-out/buildrules/vendor";
pub const crates_dir = vendor_dir ++ "/registry/src/crates-io";
pub const git_vendor_dir = vendor_dir ++ "/git";
/// Cargo's home below the repository root (sync.zig's work directory).
pub const cargo_home_dir = "buck-out/buildrules/cargo-home";
/// Below cargo's home.
pub const cache_subdir = "registry/cache/vendor";
pub const checkouts_subdir = "git/checkouts";
pub const config_file = "config.toml";

/// The largest file read from DIR.
pub const max_bytes: usize = 1 << 30;

/// One file of DIR: its name there, where it is downloaded from, and its sha256 and size (null: not recorded, as for a crate,
/// whose size Cargo.lock does not hold).
pub const Source = struct { file: []const u8, url: []const u8, sha256: []const u8, size: ?u64 };

pub fn crateFile(a: std.mem.Allocator, name: []const u8, version: []const u8) error{OutOfMemory}![]const u8 {
    return std.fmt.allocPrint(a, "{s}-{s}.crate", .{ name, version });
}

fn die(d: *Diag, comptime fmt: []const u8, args: anytype) error{Refused} {
    d.add(fmt, args);
    return error.Refused;
}

fn isSha256(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// A git source of Cargo.lock with the packages that come from it.
const GitSrc = struct { git: git_source.Git, row: git_archive.Row, packages: std.ArrayList(cargo_lock.Entry) };

/// What Cargo.lock needs fetched: its crates.io packages, and its git sources by repository and commit.
const Wanted = struct { crates: []const cargo_lock.Entry, gits: std.StringArrayHashMap(GitSrc) };

/// Sorts the packages of the lock out, refusing (each into `d`, then `error.Refused`) one that cannot be fetched by hash: a
/// crates.io package without a sha256, another registry, a git source not pinned by commit or not in the record.
fn wanted(a: std.mem.Allocator, d: *Diag, entries: []const cargo_lock.Entry, record: ?git_archive.Record) Error!Wanted {
    const before = d.count();
    var crates = std.ArrayList(cargo_lock.Entry).empty;
    var gits = std.StringArrayHashMap(GitSrc).init(a);
    for (entries) |e| {
        if (e.source.len == 0) continue; // a workspace member
        if (std.mem.eql(u8, e.source, crates_io)) {
            if (!isSha256(e.checksum)) {
                d.add("{s} {s}: Cargo.lock has no sha256 checksum for it, so it cannot be fetched by hash: let cargo write Cargo.lock", .{ e.name, e.version });
                continue;
            }
            try crates.append(a, e);
            continue;
        }
        if (!git_source.isGit(e.source)) {
            d.add("{s} {s}: the source {s} is not crates.io or a git repository; buildrules fetches only those", .{ e.name, e.version, e.source });
            continue;
        }
        const g = switch (try git_source.judge(a, e.source)) {
            .ok => |g| g,
            .bad => |why| {
                d.add("{s} {s}: {s}", .{ e.name, e.version, why });
                continue;
            },
        };
        const k = try git_source.key(a, g.repo, g.rev);
        const row = (if (record) |r| r.get(k) else null) orelse {
            d.add("{s} {s}: {s} at {s} has no row in {s}, and a sync without the network cannot measure a new archive. A sync with the network records it when a unit of the table comes from the commit (then commit the record); a git package only another platform uses is never recorded, so such a workspace cannot be synced without the network", .{ e.name, e.version, g.repo, g.rev, contract.git_archives_file });
            continue;
        };
        const slot = try gits.getOrPut(k);
        if (!slot.found_existing) slot.value_ptr.* = .{ .git = g, .row = row, .packages = .empty };
        try slot.value_ptr.packages.append(a, e);
    }
    if (d.count() != before) return error.Refused;
    return .{ .crates = crates.items, .gits = gits };
}

/// The files `--sources` needs, in Cargo.lock's order: the crates, then the archives.
pub fn list(a: std.mem.Allocator, d: *Diag, entries: []const cargo_lock.Entry, record: ?git_archive.Record) Error![]const Source {
    const w = try wanted(a, d, entries, record);
    var out = try std.ArrayList(Source).initCapacity(a, w.crates.len + w.gits.count());
    for (w.crates) |e| {
        out.appendAssumeCapacity(.{
            .file = try crateFile(a, e.name, e.version),
            .url = try std.fmt.allocPrint(a, "https://static.crates.io/crates/{s}/{s}-{s}.crate", .{ e.name, e.name, e.version }),
            .sha256 = e.checksum,
            .size = null,
        });
    }
    for (w.gits.values()) |s| {
        out.appendAssumeCapacity(.{ .file = try git_source.archiveFile(a, s.git), .url = try git_source.archiveUrl(a, s.git), .sha256 = s.row.sha256, .size = s.row.size });
    }
    return out.items;
}

/// `list` as the JSON file `--list-sources` writes: `{"sources": [{"file", "url", "sha256", "size"}, ...]}`.
pub fn listJson(a: std.mem.Allocator, items: []const Source) error{OutOfMemory}![]const u8 {
    const text = try std.json.Stringify.valueAlloc(a, .{ .sources = items }, .{});
    return std.mem.concat(a, u8, &.{ text, "\n" });
}

// ---- reading DIR ---------------------------------------------------------------------------------------------------------

/// The bytes of `file` in `dir`, which must have the sha256 `sha` (and the size `size`, when it is known).
fn readPinned(a: std.mem.Allocator, d: *Diag, what: []const u8, dir: std.fs.Dir, dir_path: []const u8, file: []const u8, pinned_by: []const u8, sha: []const u8, size: ?u64) Error![]const u8 {
    const bytes = dir.readFileAlloc(a, file, max_bytes) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return die(d, "{s}: {s}/{s} cannot be read ({s}): every source --list-sources names must be there", .{ what, dir_path, file, @errorName(e) }),
    };
    var dg: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &dg, .{});
    const got = std.fmt.bytesToHex(dg, .lower);
    if (!std.mem.eql(u8, &got, sha)) {
        return die(d, "{s}: {s}/{s} has sha256 {s}, but {s} records {s}: a file whose bytes are not the pinned ones is refused", .{ what, dir_path, file, &got, pinned_by, sha });
    }
    if (size) |n| if (n != bytes.len) {
        return die(d, "{s}: {s}/{s} is {d} bytes, but {s} records {d}", .{ what, dir_path, file, bytes.len, contract.git_archives_file, n });
    };
    return bytes;
}

fn plainRel(rel: []const u8) bool {
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |p| if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..")) return false;
    return true;
}

/// An entry of an archive, below its top directory: a directory, a file and its bytes, or a symbolic link and its target.
pub const Entry = struct { rel: []const u8, kind: enum { dir, file, link }, data: []const u8 = "" };
pub const Archive = struct { top: []const u8, entries: []const Entry };

/// Reads the gzip tar `bytes`, every entry of which must lie in one top directory, into memory. Refused (into `d`): no gzip or no
/// tar, two top directories, a path that is not plain, an archive cut short or empty.
pub fn readTar(a: std.mem.Allocator, d: *Diag, what: []const u8, bytes: []const u8) Error!Archive {
    const plain = git_archive.gunzip(a, bytes) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return die(d, "{s}: not a gzip tar ({s})", .{ what, @errorName(e) }),
    };
    var tar_in: std.Io.Reader = .fixed(plain);
    const name_buf = try a.alloc(u8, std.fs.max_path_bytes);
    const link_buf = try a.alloc(u8, std.fs.max_path_bytes);
    var it = std.tar.Iterator.init(&tar_in, .{ .file_name_buffer = name_buf, .link_name_buffer = link_buf });
    var top: ?[]const u8 = null;
    var out = std.ArrayList(Entry).empty;
    while (it.next() catch |e| return die(d, "{s}: not a gzip tar ({s})", .{ what, @errorName(e) })) |f| {
        const name = std.mem.trimRight(u8, f.name, "/");
        const slash = std.mem.indexOfScalar(u8, name, '/');
        const first = name[0 .. slash orelse name.len];
        if (top) |tp| {
            if (!std.mem.eql(u8, tp, first)) return die(d, "{s}: more than one top directory ({s}, {s})", .{ what, tp, first });
        } else {
            if (!plainRel(first)) return die(d, "{s}: the top directory `{s}` is not a plain name", .{ what, first });
            top = try a.dupe(u8, first);
        }
        const rel = if (slash) |i| name[i + 1 ..] else continue; // the top directory itself
        if (!plainRel(rel)) return die(d, "{s}: holds the path {s}, which is not a plain relative path", .{ what, name });
        switch (f.kind) {
            .directory => try out.append(a, .{ .rel = try a.dupe(u8, rel), .kind = .dir }),
            .sym_link => try out.append(a, .{ .rel = try a.dupe(u8, rel), .kind = .link, .data = try a.dupe(u8, f.link_name) }),
            .file => {
                var body = std.Io.Writer.Allocating.init(a);
                it.streamRemaining(f, &body.writer) catch |e| return die(d, "{s}: cut short in {s} ({s})", .{ what, name, @errorName(e) });
                try out.append(a, .{ .rel = try a.dupe(u8, rel), .kind = .file, .data = body.written() });
            },
        }
    }
    return .{ .top = top orelse return die(d, "{s}: the archive is empty", .{what}), .entries = out.items };
}

/// One step of a layout, in the order given: `clear` removes a tree, `dir` makes one, `file` writes `data`, `link` makes a symbolic
/// link to `data` (the parents of a file or a link are made first).
pub const Op = struct { kind: enum { clear, dir, file, link }, path: []const u8, data: []const u8 = "" };

/// Carries out `ops` below `dir`. Every filesystem call of a layout is made here, so a failure has one place to come from.
pub fn apply(dir: std.fs.Dir, ops: []const Op) !void {
    for (ops) |op| switch (op.kind) {
        .clear => try dir.deleteTree(op.path),
        .dir => try dir.makePath(op.path),
        .file, .link => {
            if (std.fs.path.dirname(op.path)) |parent| try dir.makePath(parent);
            if (op.kind == .file) try dir.writeFile(.{ .sub_path = op.path, .data = op.data }) else try dir.symLink(op.data, op.path, .{});
        },
    };
}

/// The steps that put the entries of `ar` below `under`, between the steps `before` and `after`.
fn place(a: std.mem.Allocator, ops: *std.ArrayList(Op), before: []const Op, under: []const u8, ar: Archive, after: []const Op) error{OutOfMemory}!void {
    try ops.ensureUnusedCapacity(a, before.len + ar.entries.len + 1 + after.len);
    ops.appendSliceAssumeCapacity(before);
    ops.appendAssumeCapacity(.{ .kind = .dir, .path = under });
    for (ar.entries) |e| {
        const path = try std.fs.path.join(a, &.{ under, e.rel });
        ops.appendAssumeCapacity(.{ .kind = switch (e.kind) {
            .dir => .dir,
            .file => .file,
            .link => .link,
        }, .path = path, .data = e.data });
    }
    ops.appendSliceAssumeCapacity(after);
}

/// Unpacks the gzip tar `bytes` into `dest` without its top directory (files and symbolic links; directories are made as needed,
/// modes are not kept). Returns the top directory's name.
pub fn unpack(a: std.mem.Allocator, d: *Diag, what: []const u8, bytes: []const u8, dest: std.fs.Dir) Error![]const u8 {
    const ar = try readTar(a, d, what, bytes);
    var ops = std.ArrayList(Op).empty;
    try place(a, &ops, &.{}, ".", ar, &.{});
    try apply(dest, ops.items);
    return ar.top;
}

// ---- the sources cargo reads ---------------------------------------------------------------------------------------------

/// A TOML basic string.
pub fn quoted(a: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    const slashes = try std.mem.replaceOwned(u8, a, s, "\\", "\\\\");
    return std.fmt.allocPrint(a, "\"{s}\"", .{try std.mem.replaceOwned(u8, a, slashes, "\"", "\\\"")});
}

/// The directory of the package `e` in the archive ("" for its root): the manifest cargo takes for it (cargo_walk.zig). Refused
/// by name when no manifest of the archive is the package, or when several are and buildrules cannot show that cargo reads the
/// one its walk meets first.
fn packageDir(a: std.mem.Allocator, d: *Diag, s: GitSrc, e: cargo_lock.Entry, co: *cargo_walk.Checkout) Error![]const u8 {
    return switch (try co.pick(e.name, e.version)) {
        .dir => |dir| dir,
        .missing => die(d, "{s} {s}: no Cargo.toml in the archive of {s} at {s} is that package", .{ e.name, e.version, s.git.repo, s.git.rev }),
        .unsure => |dirs| {
            const manifests = try a.alloc([]const u8, dirs.len);
            for (dirs, manifests) |dir, *m| m.* = if (dir.len == 0) "Cargo.toml" else try std.fmt.allocPrint(a, "{s}/Cargo.toml", .{dir});
            return die(d, "{s} {s}: the archive of {s} at {s} has {d} Cargo.toml of the package ({s}). cargo takes the first one its walk of the checkout reads; the first it meets is {s}, and buildrules cannot show that cargo reads it: it inherits a key, the version or a dependency its workspace does not hold, or it has no src/lib.rs, src/main.rs, [lib] path or [[bin]] path in the archive (buildrules checks nothing else of a manifest). Give that manifest what it lacks, or remove the other copies from the repository", .{
                e.name, e.version, s.git.repo, s.git.rev, dirs.len, try std.mem.join(a, ", ", manifests), manifests[0],
            });
        },
    };
}

/// The names directly in the directory `sub` of the archive ("" for its root), directories implied by deeper entries included.
fn children(a: std.mem.Allocator, ar: Archive, sub: []const u8) error{OutOfMemory}![]const []const u8 {
    var out = std.StringArrayHashMap(void).init(a);
    for (ar.entries) |e| {
        const rest = if (sub.len == 0) e.rel else if (std.mem.startsWith(u8, e.rel, sub) and e.rel.len > sub.len and e.rel[sub.len] == '/') e.rel[sub.len + 1 ..] else continue;
        try out.put(rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len], {});
    }
    return out.keys();
}

/// Lays out the sources of `entries` (Cargo.lock's packages) from the files in `sources_path` for cargo, below `root_path` (the
/// repository, absolute; cargo's home is its `cargo_home_dir`), and writes cargo's config last. Everything is read and checked
/// before anything is written: a file that is missing or not the pinned bytes, or an archive that is not as recorded, is refused
/// by name and the layout of an earlier run is left as it was.
pub fn vendor(a: std.mem.Allocator, d: *Diag, sources_path: []const u8, root_path: []const u8, entries: []const cargo_lock.Entry, record: ?git_archive.Record) Error!void {
    const w = try wanted(a, d, entries, record);
    var sources = std.fs.cwd().openDir(sources_path, .{}) catch |e| return die(d, "--sources {s}: {s}", .{ sources_path, @errorName(e) });
    defer sources.close();
    const cache_dir = cargo_home_dir ++ "/" ++ cache_subdir;
    // A layout left by an earlier run is replaced whole.
    var ops = std.ArrayList(Op).empty;
    try ops.appendSlice(a, &.{
        .{ .kind = .clear, .path = vendor_dir },
        .{ .kind = .clear, .path = cache_dir },
        .{ .kind = .dir, .path = crates_dir },
        .{ .kind = .dir, .path = git_vendor_dir },
        .{ .kind = .dir, .path = cache_dir },
    });
    var config = std.ArrayList(u8).fromOwnedSlice(try std.fmt.allocPrint(a, "# Written by `buildrules sync --sources`: cargo reads the packages of Cargo.lock from the files of that directory, never from the network.\n" ++
        "[net]\noffline = true\n\n[source.crates-io]\nreplace-with = \"buildrules-crates\"\n\n[source.buildrules-crates]\ndirectory = {s}\n", .{try quoted(a, try std.fs.path.join(a, &.{ root_path, crates_dir }))}));

    for (w.crates) |e| {
        const what = try std.fmt.allocPrint(a, "{s} {s}", .{ e.name, e.version });
        const file = try crateFile(a, e.name, e.version);
        const bytes = try readPinned(a, d, what, sources, sources_path, file, "Cargo.lock", e.checksum, null);
        const ar = try readTar(a, d, what, bytes);
        const dir_name = file[0 .. file.len - ".crate".len];
        if (!std.mem.eql(u8, ar.top, dir_name)) return die(d, "{s}: the top directory of {s} is {s}, not {s}", .{ what, file, ar.top, dir_name });
        const pkg = try std.fs.path.join(a, &.{ crates_dir, dir_name });
        const cached: Op = .{ .kind = .file, .path = try std.fs.path.join(a, &.{ cache_dir, file }), .data = bytes };
        const sum: Op = .{ .kind = .file, .path = try std.fs.path.join(a, &.{ pkg, ".cargo-checksum.json" }), .data = try std.fmt.allocPrint(a, "{{\"files\":{{}},\"package\":\"{s}\"}}\n", .{e.checksum}) };
        try place(a, &ops, &.{}, pkg, ar, &.{ cached, sum });
    }

    for (w.gits.values(), 0..) |s, i| {
        const g = s.git;
        const what = try std.fmt.allocPrint(a, "{s} at {s}", .{ g.repo, g.rev });
        const bytes = try readPinned(a, d, what, sources, sources_path, try git_source.archiveFile(a, g), contract.git_archives_file, s.row.sha256, s.row.size);
        const ar = try readTar(a, d, what, bytes);
        if (!std.mem.eql(u8, ar.top, s.row.top)) return die(d, "{s}: the archive's top directory is {s}, but {s} records {s}", .{ what, ar.top, contract.git_archives_file, s.row.top });
        // The checkout holds the archive's files and nothing else: git_archive.zig compares the two.
        const co_rel = try std.fmt.allocPrint(a, "{s}/{s}/{s}_{s}/{s}", .{ cargo_home_dir, checkouts_subdir, g.owner, g.name, g.rev });
        const co_abs = try std.fs.path.join(a, &.{ root_path, co_rel });
        const v_rel = try std.fmt.allocPrint(a, "{s}/{s}_{s}_{s}", .{ git_vendor_dir, g.owner, g.name, g.rev });
        var root_link = false;
        try place(a, &ops, &.{.{ .kind = .clear, .path = co_rel }}, co_rel, ar, &.{.{ .kind = .dir, .path = v_rel }});
        // per package: its directory, a link per entry of its directory, its checksum file, and maybe the root manifest's link
        try ops.ensureUnusedCapacity(a, s.packages.items.len * (3 + ar.entries.len));
        var co = try cargo_walk.Checkout.init(a, ar.entries);
        for (s.packages.items) |e| {
            const sub = try packageDir(a, d, s, e, &co);
            const pkg = try std.fmt.allocPrint(a, "{s}/{s}-{s}", .{ v_rel, e.name, e.version });
            ops.appendAssumeCapacity(.{ .kind = .dir, .path = pkg });
            for (try children(a, ar, sub)) |c| {
                if (std.mem.eql(u8, c, ".cargo-checksum.json")) continue;
                ops.appendAssumeCapacity(.{ .kind = .link, .path = try std.fs.path.join(a, &.{ pkg, c }), .data = try std.fs.path.join(a, &.{ co_abs, sub, c }) });
            }
            ops.appendAssumeCapacity(.{ .kind = .file, .path = try std.fs.path.join(a, &.{ pkg, ".cargo-checksum.json" }), .data = "{\"files\":{},\"package\":null}\n" });
            // A member reads the workspace's keys from the nearest Cargo.toml above its own that has a [workspace].
            if (sub.len != 0 and !root_link and hasFile(ar, "Cargo.toml")) {
                ops.appendAssumeCapacity(.{ .kind = .link, .path = try std.fs.path.join(a, &.{ v_rel, "Cargo.toml" }), .data = try std.fs.path.join(a, &.{ co_abs, "Cargo.toml" }) });
                root_link = true;
            }
        }
        // judge() took only `git+https://...?rev=<commit>` sources, so the id has its `?`.
        const url = std.mem.sliceTo(g.id[git_source.prefix.len..], '?');
        try config.print(a, "\n[source.buildrules-git-{d}]\ngit = {s}\nrev = {s}\nreplace-with = \"buildrules-git-{d}-files\"\n\n[source.buildrules-git-{d}-files]\ndirectory = {s}\n", .{
            i, try quoted(a, url), try quoted(a, g.rev), i, i, try quoted(a, try std.fs.path.join(a, &.{ root_path, v_rel })),
        });
    }
    try ops.append(a, .{ .kind = .file, .path = cargo_home_dir ++ "/" ++ config_file, .data = config.items });
    var root = std.fs.cwd().openDir(root_path, .{}) catch |e| return die(d, "{s}: {s}", .{ root_path, @errorName(e) });
    defer root.close();
    try apply(root, ops.items);
}

fn hasFile(ar: Archive, rel: []const u8) bool {
    for (ar.entries) |e| if (e.kind == .file and std.mem.eql(u8, e.rel, rel)) return true;
    return false;
}
