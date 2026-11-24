//! The archives of the table's git sources: `third_party/buildrules/git_archives.tsv` (docs/contract.md, "Git sources").
//!
//! Cargo.lock pins a git package by commit and records no hash of anything a download could check, so `buildrules sync`
//! measures one itself. For every repository and commit the units come from it downloads GitHub's archive of the commit
//! (`https://github.com/<owner>/<repo>/archive/<rev>.tar.gz`), proves the archive holds exactly the files of cargo's own
//! checkout of that commit (so it is the source cargo resolved: a submodule, an `export-ignore` or an `export-subst` makes the
//! two differ, and such a source is refused), and records the archive's sha256, size and top directory. `crate_src` downloads
//! it by those. A recorded row is never rewritten: when the archive of a recorded commit no longer has its recorded sha256 or
//! size, sync refuses it by name.

const std = @import("std");
const fetch = @import("fetch.zig");
const git_source = @import("git_source.zig");
const unitgen = @import("unitgen.zig");
const Diag = @import("diag.zig").Diag;

pub const Error = anyerror;

pub const file_label = @import("contract.zig").git_archives_file;

pub const header = "# repository commit sha256 bytes top-directory; each archive was compared with cargo's checkout of the commit by `buildrules sync`\n";

pub const Row = struct { repo: []const u8, rev: []const u8, sha256: []const u8, size: u64, top: []const u8 };

/// The rows by `repo@rev`.
pub const Record = std.StringArrayHashMap(Row);

/// The largest archive sync reads.
pub const max_bytes: usize = 1 << 30;

fn die(d: *Diag, comptime fmt: []const u8, args: anytype) error{Refused} {
    d.add("git: " ++ fmt, args);
    return error.Refused;
}

fn isSha256(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

fn isTop(s: []const u8) bool {
    if (s.len == 0 or s[0] == '.') return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return false;
    return true;
}

/// The record file: `repo rev sha256 bytes top` per line; blank lines and `#` comments skipped.
pub fn parse(a: std.mem.Allocator, d: *Diag, text: []const u8) Error!Record {
    var out = Record.init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (it.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        var fields: [5][]const u8 = undefined;
        var n: usize = 0;
        var extra = false;
        while (f.next()) |x| : (n += 1) {
            if (n == fields.len) {
                extra = true;
                break;
            }
            fields[n] = x;
        }
        if (n != fields.len or extra) return die(d, "{s}:{d}: not `repository commit sha256 bytes top-directory`", .{ file_label, line_no });
        const repo = fields[0];
        if (!std.mem.startsWith(u8, repo, "github.com/") or std.mem.count(u8, repo, "/") != 2) return die(d, "{s}:{d}: `{s}` is not github.com/<owner>/<repository>", .{ file_label, line_no, repo });
        if (!git_source.isRev(fields[1])) return die(d, "{s}:{d}: `{s}` is not a 40-hex commit", .{ file_label, line_no, fields[1] });
        if (!isSha256(fields[2])) return die(d, "{s}:{d}: `{s}` is not a sha256", .{ file_label, line_no, fields[2] });
        const size = std.fmt.parseInt(u64, fields[3], 10) catch return die(d, "{s}:{d}: `{s}` is not a size in bytes", .{ file_label, line_no, fields[3] });
        if (!isTop(fields[4])) return die(d, "{s}:{d}: `{s}` is not a directory name", .{ file_label, line_no, fields[4] });
        const k = try git_source.key(a, repo, fields[1]);
        if (out.contains(k)) return die(d, "{s}:{d}: {s} at {s} is recorded twice", .{ file_label, line_no, repo, fields[1] });
        try out.put(k, .{ .repo = repo, .rev = fields[1], .sha256 = fields[2], .size = size, .top = fields[4] });
    }
    return out;
}

// ---- the network ---------------------------------------------------------------------------------------------------

/// The seam to the network: the body at `url`. Tests replace it.
pub const Fetch = *const fn (a: std.mem.Allocator, url: []const u8) anyerror![]const u8;
pub var fetcher: Fetch = &httpBody;

/// Set by `buildrules sync --sources DIR`: the archives are read from DIR (named by git_source.archiveFile), never downloaded.
pub var local_dir: ?[]const u8 = null;

fn archiveBytes(a: std.mem.Allocator, g: git_source.Git, url: []const u8) anyerror![]const u8 {
    const dir = local_dir orelse return fetcher(a, url);
    return std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ dir, try git_source.archiveFile(a, g) }), max_bytes);
}

fn httpBody(a: std.mem.Allocator, url: []const u8) anyerror![]const u8 {
    var http = fetch.HttpFetcher{ .allocator = a };
    return bodyOf(a, http.fetcher(), url, max_bytes);
}

/// The body `f` answers for `url`, at most `max` bytes.
pub fn bodyOf(a: std.mem.Allocator, f: fetch.Fetcher, url: []const u8, max: usize) anyerror![]const u8 {
    var body = fetch.Collect{ .a = a, .max = max };
    try f.get(url, body.sink());
    return body.buf.items;
}

// ---- the comparison ------------------------------------------------------------------------------------------------

/// What `compare` found: the archive's top directory, and its first differences from the checkout (at most `max_shown`).
const Found = struct { top: []const u8, diffs: std.ArrayList([]const u8), more: usize };

const max_shown = 3;

fn note(a: std.mem.Allocator, f: *Found, comptime fmt: []const u8, args: anytype) !void {
    if (f.diffs.items.len == max_shown) {
        f.more += 1;
        return;
    }
    try f.diffs.append(a, try std.fmt.allocPrint(a, fmt, args));
}

/// Whether `rel` is cargo's own, not the commit's: the clone's `.git` and the `.cargo-ok` marker at the top of a checkout.
fn cargoOwn(rel: []const u8) bool {
    return std.mem.eql(u8, rel, ".cargo-ok") or std.mem.eql(u8, rel, ".git") or std.mem.startsWith(u8, rel, ".git/");
}

/// The bytes of the gzip stream `bytes`, inflated whole. The decompressor runs in its direct mode (no window of its own) into a
/// writer that grows: its buffered mode reaches an unreachable rebase in the 0.15 standard library once a back-reference crosses
/// the end of its window, which a real archive of some size does.
pub fn gunzip(a: std.mem.Allocator, bytes: []const u8) error{ OutOfMemory, ReadFailed }![]const u8 {
    var in: std.Io.Reader = .fixed(bytes);
    var gz = std.compress.flate.Decompress.init(&in, .gzip, &.{});
    var plain = std.Io.Writer.Allocating.init(a);
    _ = gz.reader.streamRemaining(&plain.writer) catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
        error.ReadFailed => return error.ReadFailed,
    };
    return plain.written();
}

/// Reads the gzip tar `bytes` and compares every file and symbolic link in it with the directory `checkout`, and every file and
/// link of the checkout with it. Directories are not compared (git records none), nor file modes.
fn compare(a: std.mem.Allocator, d: *Diag, what: []const u8, bytes: []const u8, checkout: []const u8) Error!Found {
    var dir = std.fs.cwd().openDir(checkout, .{ .iterate = true }) catch |e| return die(d, "{s}: cannot open cargo's checkout {s}: {s}", .{ what, checkout, @errorName(e) });
    defer dir.close();
    const plain = gunzip(a, bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return die(d, "{s}: the archive is not a gzip tar ({s})", .{ what, @errorName(e) }),
    };
    var in: std.Io.Reader = .fixed(plain);
    const name_buf = try a.alloc(u8, std.fs.max_path_bytes);
    const link_buf = try a.alloc(u8, std.fs.max_path_bytes);
    var it = std.tar.Iterator.init(&in, .{ .file_name_buffer = name_buf, .link_name_buffer = link_buf });
    var found = Found{ .top = "", .diffs = .empty, .more = 0 };
    var seen = std.StringHashMap(void).init(a);
    var have_top = false;
    const link_have = try a.alloc(u8, std.fs.max_path_bytes);
    while (it.next() catch |e| return die(d, "{s}: the archive is not a gzip tar ({s})", .{ what, @errorName(e) })) |f| {
        const name = std.mem.trimRight(u8, f.name, "/");
        const slash = std.mem.indexOfScalar(u8, name, '/');
        const top = name[0 .. slash orelse name.len];
        if (!have_top) {
            if (!isTop(top)) return die(d, "{s}: the archive's top directory `{s}` is not a plain name", .{ what, top });
            found.top = try a.dupe(u8, top);
            have_top = true;
        } else if (!std.mem.eql(u8, found.top, top)) {
            return die(d, "{s}: the archive has more than one top directory ({s}, {s})", .{ what, found.top, top });
        }
        if (slash == null) continue; // the top directory itself
        const rel = name[slash.? + 1 ..];
        var parts = std.mem.splitScalar(u8, rel, '/');
        while (parts.next()) |p| if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..")) {
            return die(d, "{s}: the archive holds the path {s}, which is not a plain relative path", .{ what, name });
        };
        switch (f.kind) {
            .directory => continue,
            .file => {
                // Each file's two copies are freed before the next is read: an archive is never held whole.
                var body = std.Io.Writer.Allocating.init(a);
                defer body.deinit();
                it.streamRemaining(f, &body.writer) catch |e| return die(d, "{s}: the archive is cut short in {s} ({s})", .{ what, name, @errorName(e) });
                if (dir.readLink(rel, link_have)) |_| {
                    try note(a, &found, "{s} is a file in the archive and a symbolic link in the checkout", .{rel});
                } else |_| {
                    const mine = dir.readFileAlloc(a, rel, max_bytes) catch |e| switch (e) {
                        error.OutOfMemory => return e,
                        else => null,
                    };
                    defer if (mine) |m| a.free(m);
                    if (mine == null) {
                        try note(a, &found, "{s} is in the archive and not in the checkout", .{rel});
                    } else if (!std.mem.eql(u8, mine.?, body.written())) {
                        try note(a, &found, "{s} differs", .{rel});
                    }
                }
            },
            .sym_link => {
                const target = dir.readLink(rel, link_have) catch null;
                if (target == null) {
                    try note(a, &found, "{s} is a symbolic link in the archive and not one in the checkout", .{rel});
                } else if (!std.mem.eql(u8, target.?, f.link_name)) {
                    try note(a, &found, "{s} links to {s} in the archive and to {s} in the checkout", .{ rel, f.link_name, target.? });
                }
            },
        }
        try seen.put(try a.dupe(u8, rel), {});
    }
    if (!have_top) return die(d, "{s}: the archive is empty", .{what});
    var walk = try dir.walk(a);
    defer walk.deinit();
    while (try walk.next()) |e| {
        if (e.kind == .directory or cargoOwn(e.path)) continue;
        if (!seen.contains(e.path)) try note(a, &found, "{s} is in the checkout and not in the archive", .{e.path});
    }
    return found;
}

// ---- the record ----------------------------------------------------------------------------------------------------

fn lessKey(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// The git commits a table's units come from, as `repo@rev`: each git unit of buildrules.lock.bzl has a `"repo": "..."` line
/// followed by its `"rev": "..."` line (the generator writes the body's keys in that order).
pub fn tableCommits(a: std.mem.Allocator, table: []const u8) error{OutOfMemory}!std.StringArrayHashMap(void) {
    var out = std.StringArrayHashMap(void).init(a);
    var it = std.mem.splitScalar(u8, table, '\n');
    var repo: ?[]const u8 = null;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r,");
        if (quotedValue(line, "\"repo\": ")) |r| {
            repo = r;
        } else if (quotedValue(line, "\"rev\": ")) |rev| {
            if (repo) |r| try out.put(try git_source.key(a, r, rev), {});
            repo = null;
        } else {
            repo = null;
        }
    }
    return out;
}

fn quotedValue(line: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const v = line[prefix.len..];
    if (v.len < 2 or v[0] != '"' or v[v.len - 1] != '"') return null;
    return v[1 .. v.len - 1];
}

/// The record file and its rows.
pub const Recorded = struct { text: []const u8, rows: Record };

/// The record file for `checkouts` (unitgen's: one per repository and commit), checking each archive as the module comment says.
/// `old` is the committed record: a row it holds must still be what the archive measures.
pub fn recordFile(a: std.mem.Allocator, d: *Diag, checkouts: *const std.StringArrayHashMap(unitgen.Checkout), old: ?Record) Error!Recorded {
    const keys = try a.dupe([]const u8, checkouts.keys());
    std.mem.sort([]const u8, keys, {}, lessKey);
    var out = std.ArrayList(u8).empty;
    var rows = Record.init(a);
    try out.appendSlice(a, header);
    for (keys) |k| {
        const c = checkouts.get(k).?;
        const g = c.git;
        const what = try std.fmt.allocPrint(a, "{s} at {s}", .{ g.repo, g.rev });
        const url = try git_source.archiveUrl(a, g);
        const bytes = archiveBytes(a, g, url) catch |e| return die(d, "{s}: cannot download {s}: {s}", .{ what, url, @errorName(e) });
        var dg: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &dg, .{});
        const sha = try a.dupe(u8, &std.fmt.bytesToHex(dg, .lower));
        if (old) |o| if (o.get(k)) |row| {
            if (!std.mem.eql(u8, row.sha256, sha) or row.size != bytes.len) {
                return die(d, "{s}: the archive {s} now has sha256 {s} ({d} bytes), but {s} records sha256 {s} ({d} bytes). " ++
                    "The archive of a pinned commit changed, so it is refused: find out why, and only then delete its line and run `buildrules sync`", .{ what, url, sha, bytes.len, file_label, row.sha256, row.size });
            }
        };
        const found = try compare(a, d, what, bytes, c.dir);
        if (found.diffs.items.len != 0) {
            const all = try std.mem.join(a, "; ", found.diffs.items);
            const more = if (found.more != 0) try std.fmt.allocPrint(a, "; and {d} more", .{found.more}) else "";
            return die(d, "{s}: the archive {s} is not cargo's checkout of the commit ({s}{s}). A submodule, or an export-ignore or export-subst " ++
                "attribute in .gitattributes, makes GitHub's archive differ from the commit; such a source is refused", .{ what, url, all, more });
        }
        try out.print(a, "{s} {s} {s} {d} {s}\n", .{ g.repo, g.rev, sha, bytes.len, found.top });
        try rows.put(k, .{ .repo = g.repo, .rev = g.rev, .sha256 = sha, .size = bytes.len, .top = found.top });
    }
    return .{ .text = try out.toOwnedSlice(a), .rows = rows };
}
