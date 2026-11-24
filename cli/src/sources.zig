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
//!     directory, and beside them a link to the repository's root manifest, from which a member inherits workspace keys.
//! A package Cargo.lock does not name cannot be resolved this way: cargo names it, and a sync with the network adds it.

const std = @import("std");
const cargo_lock = @import("cargo_lock.zig");
const contract = @import("contract.zig");
const git_archive = @import("git_archive.zig");
const git_source = @import("git_source.zig");
const toml = @import("toml.zig");
const val = @import("val.zig");
const Diag = @import("diag.zig").Diag;

pub const Error = anyerror;

/// The source Cargo.lock names crates.io by.
pub const crates_io = "registry+https://github.com/rust-lang/crates.io-index";

/// Below the repository root (sync.zig's work directory).
pub const vendor_dir = "buck-out/buildrules/vendor";
pub const crates_dir = vendor_dir ++ "/registry/src/crates-io";
pub const git_vendor_dir = vendor_dir ++ "/git";
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
    var out = std.ArrayList(Source).empty;
    for (w.crates) |e| {
        try out.append(a, .{
            .file = try crateFile(a, e.name, e.version),
            .url = try std.fmt.allocPrint(a, "https://static.crates.io/crates/{s}/{s}-{s}.crate", .{ e.name, e.name, e.version }),
            .sha256 = e.checksum,
            .size = null,
        });
    }
    for (w.gits.values()) |s| {
        try out.append(a, .{ .file = try git_source.archiveFile(a, s.git), .url = try git_source.archiveUrl(a, s.git), .sha256 = s.row.sha256, .size = s.row.size });
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

/// Unpacks the gzip tar `bytes`, every entry of which lies in one top directory, into `dest` without that directory (files and
/// symbolic links; directories are made as needed, modes are not kept). Returns the top directory's name.
pub fn unpack(a: std.mem.Allocator, d: *Diag, what: []const u8, bytes: []const u8, dest: std.fs.Dir) Error![]const u8 {
    var in: std.Io.Reader = .fixed(bytes);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    var gz = std.compress.flate.Decompress.init(&in, .gzip, window);
    const name_buf = try a.alloc(u8, std.fs.max_path_bytes);
    const link_buf = try a.alloc(u8, std.fs.max_path_bytes);
    var it = std.tar.Iterator.init(&gz.reader, .{ .file_name_buffer = name_buf, .link_name_buffer = link_buf });
    var top: ?[]const u8 = null;
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
        if (slash == null) continue; // the top directory itself
        const rel = name[slash.? + 1 ..];
        if (!plainRel(rel)) return die(d, "{s}: holds the path {s}, which is not a plain relative path", .{ what, name });
        if (f.kind == .directory) {
            try dest.makePath(rel);
            continue;
        }
        if (std.fs.path.dirname(rel)) |parent| try dest.makePath(parent);
        if (f.kind == .sym_link) {
            try dest.symLink(f.link_name, rel, .{});
            continue;
        }
        var body = std.Io.Writer.Allocating.init(a);
        defer body.deinit();
        it.streamRemaining(f, &body.writer) catch |e| return die(d, "{s}: cut short in {s} ({s})", .{ what, name, @errorName(e) });
        try dest.writeFile(.{ .sub_path = rel, .data = body.written() });
    }
    return top orelse return die(d, "{s}: the archive is empty", .{what});
}

// ---- the sources cargo reads ---------------------------------------------------------------------------------------------

/// A TOML basic string.
fn quoted(a: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]const u8 {
    var o = std.ArrayList(u8).empty;
    try o.append(a, '"');
    for (s) |c| {
        if (c == '"' or c == '\\') try o.append(a, '\\');
        try o.append(a, c);
    }
    try o.append(a, '"');
    return o.items;
}

/// The directory of the package `e` in the unpacked archive `checkout` ("" for its root): the one Cargo.toml whose
/// [package] has `e`'s name (and its version, unless the version is inherited from the workspace).
fn packageDir(a: std.mem.Allocator, d: *Diag, s: GitSrc, e: cargo_lock.Entry, checkout: std.fs.Dir) Error![]const u8 {
    var found: ?[]const u8 = null;
    var w = try checkout.walk(a);
    defer w.deinit();
    while (try w.next()) |f| {
        if (f.kind != .file or !std.mem.eql(u8, f.basename, "Cargo.toml")) continue;
        const text = checkout.readFileAlloc(a, f.path, 8 << 20) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const doc = toml.parse(a, text);
        if (doc.msg.len != 0) continue;
        const n = val.asStr(toml.at(doc.value, &.{ "package", "name" })) orelse continue;
        if (!std.mem.eql(u8, n, e.name)) continue;
        if (val.asStr(toml.at(doc.value, &.{ "package", "version" }))) |v| if (!std.mem.eql(u8, v, e.version)) continue;
        if (found) |other| return die(d, "{s} {s}: the archive of {s} at {s} has two Cargo.toml of the package ({s}, {s})", .{ e.name, e.version, s.git.repo, s.git.rev, other, f.path });
        found = try a.dupe(u8, f.path);
    }
    const manifest = found orelse return die(d, "{s} {s}: no Cargo.toml in the archive of {s} at {s} is that package", .{ e.name, e.version, s.git.repo, s.git.rev });
    return std.fs.path.dirname(manifest) orelse "";
}

/// `<into>/<entry>` -> `<from>/<entry>` (absolute) for every entry of `from`, then cargo's checksum file of a directory source.
fn linkPackage(a: std.mem.Allocator, from: []const u8, into: std.fs.Dir, package_sum: []const u8) Error!void {
    var dir = try std.fs.cwd().openDir(from, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (std.mem.eql(u8, e.name, ".cargo-checksum.json")) continue;
        try into.symLink(try std.fs.path.join(a, &.{ from, e.name }), e.name, .{});
    }
    try into.writeFile(.{ .sub_path = ".cargo-checksum.json", .data = try std.fmt.allocPrint(a, "{{\"files\":{{}},\"package\":{s}}}\n", .{package_sum}) });
}

/// Lays out the sources of `entries` (Cargo.lock's packages) from the files in `sources_path` for cargo, under `root_path`
/// (the repository, absolute) and `cargo_home` (absolute), and writes cargo's config there. Refuses by name a file that is
/// missing or not the pinned bytes.
pub fn vendor(a: std.mem.Allocator, d: *Diag, sources_path: []const u8, root_path: []const u8, cargo_home: []const u8, entries: []const cargo_lock.Entry, record: ?git_archive.Record) Error!void {
    const w = try wanted(a, d, entries, record);
    var sources = std.fs.cwd().openDir(sources_path, .{}) catch |e| return die(d, "--sources {s}: {s}", .{ sources_path, @errorName(e) });
    defer sources.close();
    var root = try std.fs.cwd().openDir(root_path, .{});
    defer root.close();
    var home = try std.fs.cwd().openDir(cargo_home, .{});
    defer home.close();
    // A layout left by an earlier run is replaced whole.
    try root.deleteTree(vendor_dir);
    try root.makePath(crates_dir);
    try root.makePath(git_vendor_dir);
    try home.deleteTree(cache_subdir);
    try home.makePath(cache_subdir);
    var crates = try root.openDir(crates_dir, .{});
    defer crates.close();
    var cache = try home.openDir(cache_subdir, .{});
    defer cache.close();

    var config = std.ArrayList(u8).empty;
    try config.appendSlice(a, "# Written by `buildrules sync --sources`: cargo reads the packages of Cargo.lock from the files of that directory, never from the network.\n" ++
        "[net]\noffline = true\n\n[source.crates-io]\nreplace-with = \"buildrules-crates\"\n\n[source.buildrules-crates]\ndirectory = ");
    try config.appendSlice(a, try quoted(a, try std.fs.path.join(a, &.{ root_path, crates_dir })));
    try config.append(a, '\n');

    for (w.crates) |e| {
        const what = try std.fmt.allocPrint(a, "{s} {s}", .{ e.name, e.version });
        const file = try crateFile(a, e.name, e.version);
        const bytes = try readPinned(a, d, what, sources, sources_path, file, "Cargo.lock", e.checksum, null);
        try cache.writeFile(.{ .sub_path = file, .data = bytes });
        const dir_name = file[0 .. file.len - ".crate".len];
        try crates.makePath(dir_name);
        var pkg = try crates.openDir(dir_name, .{});
        defer pkg.close();
        const top = try unpack(a, d, what, bytes, pkg);
        if (!std.mem.eql(u8, top, dir_name)) return die(d, "{s}: the top directory of {s} is {s}, not {s}", .{ what, file, top, dir_name });
        try pkg.writeFile(.{ .sub_path = ".cargo-checksum.json", .data = try std.fmt.allocPrint(a, "{{\"files\":{{}},\"package\":\"{s}\"}}\n", .{e.checksum}) });
    }

    for (w.gits.values(), 0..) |s, i| {
        const g = s.git;
        const what = try std.fmt.allocPrint(a, "{s} at {s}", .{ g.repo, g.rev });
        const bytes = try readPinned(a, d, what, sources, sources_path, try git_source.archiveFile(a, g), contract.git_archives_file, s.row.sha256, s.row.size);
        const co_rel = try std.fmt.allocPrint(a, "{s}/{s}_{s}/{s}", .{ checkouts_subdir, g.owner, g.name, g.rev });
        try home.deleteTree(co_rel);
        try home.makePath(co_rel);
        var co = try home.openDir(co_rel, .{ .iterate = true });
        defer co.close();
        const top = try unpack(a, d, what, bytes, co);
        if (!std.mem.eql(u8, top, s.row.top)) return die(d, "{s}: the archive's top directory is {s}, but {s} records {s}", .{ what, top, contract.git_archives_file, s.row.top });
        const co_abs = try std.fs.path.join(a, &.{ cargo_home, co_rel });
        const v_rel = try std.fmt.allocPrint(a, "{s}/{s}_{s}_{s}", .{ git_vendor_dir, g.owner, g.name, g.rev });
        try root.makePath(v_rel);
        var v = try root.openDir(v_rel, .{});
        defer v.close();
        var root_link = false;
        for (s.packages.items) |e| {
            const sub = try packageDir(a, d, s, e, co);
            const pkg_name = try std.fmt.allocPrint(a, "{s}-{s}", .{ e.name, e.version });
            try v.makePath(pkg_name);
            var pkg = try v.openDir(pkg_name, .{});
            defer pkg.close();
            try linkPackage(a, if (sub.len == 0) co_abs else try std.fs.path.join(a, &.{ co_abs, sub }), pkg, "null");
            // A member reads the workspace's keys from the nearest Cargo.toml above its own that has a [workspace].
            if (sub.len != 0 and !root_link) {
                if (co.access("Cargo.toml", .{})) |_| {
                    try v.symLink(try std.fs.path.join(a, &.{ co_abs, "Cargo.toml" }), "Cargo.toml", .{});
                    root_link = true;
                } else |_| {}
            }
        }
        const url = g.id[git_source.prefix.len .. std.mem.indexOfScalar(u8, g.id, '?') orelse g.id.len];
        try config.print(a, "\n[source.buildrules-git-{d}]\ngit = {s}\nrev = {s}\nreplace-with = \"buildrules-git-{d}-files\"\n\n[source.buildrules-git-{d}-files]\ndirectory = {s}\n", .{
            i, try quoted(a, url), try quoted(a, g.rev), i, i, try quoted(a, try std.fs.path.join(a, &.{ root_path, v_rel })),
        });
    }
    try home.writeFile(.{ .sub_path = config_file, .data = config.items });
}
