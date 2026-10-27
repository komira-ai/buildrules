//! The committed unit graphs hold the bytes of the sources they name (`//ci:lock_hashes`). Every `buildrules.mojo.lock.bzl` lists, for each unit, its source files as
//! `{"path": P, "sha256": H}`; a commit that edits one of those files and does not regenerate the graph (`buildrules mojo sync`) leaves a stale hash, and the build of the
//! Mojo examples (`//ci:mojo`, which the public runner cannot build: it has no package channel) is red while this one is green. This reads each lock, hashes each file it
//! lists, and is red for a hash that differs and for a file that is not there, naming the lock, the path, the declared hash and the actual hash. It needs no Mojo compiler and
//! no network: its inputs are the lock files and the files they list (the `scrub_files` of every package, as the no-shell lint reads them).
//!
//! A pure function of the entries (`run`), tested below against fixture locks written to a scratch directory: a wrong hash and a missing file are each refused, and the
//! green controls are accepted. ci/lock_hashes_main.zig reads the arguments; ci/completeness.bxl holds the list of packages to every package of the tree, so a lock
//! in a new package is read.
const std = @import("std");
const t = std.testing;

pub const lock_suffix = ".mojo.lock.bzl";

/// A file of the tree: its path from the repository root, and where to read it.
pub const Entry = struct { path: []const u8, file: []const u8 };

pub const Report = struct {
    locks: usize = 0,
    sources: usize = 0,
    errors: std.ArrayList([]const u8),
};

fn add(a: std.mem.Allocator, r: *Report, comptime fmt: []const u8, args: anytype) !void {
    try r.errors.append(try std.fmt.allocPrint(a, fmt, args));
}

/// The sha256 of the file, lowercase hex; null when it cannot be read.
fn hashFile(path: []const u8) ?[64]u8 {
    var f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [1 << 16]u8 = undefined;
    while (true) {
        const n = f.read(&buf) catch return null;
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

const path_key = "{\"path\": \"";
const hash_key = "\", \"sha256\": \"";

/// One `{"path": P, "sha256": H}` of a line, or null when the line holds none (other `"path"` keys of a lock have no `sha256` after them).
fn parseLine(line: []const u8) ?struct { path: []const u8, sha: []const u8 } {
    const i = std.mem.indexOf(u8, line, path_key) orelse return null;
    const rest = line[i + path_key.len ..];
    const j = std.mem.indexOf(u8, rest, hash_key) orelse return null;
    const tail = rest[j + hash_key.len ..];
    const k = std.mem.indexOfScalar(u8, tail, '"') orelse return null;
    return .{ .path = rest[0..j], .sha = tail[0..k] };
}

/// Every lock among `entries` against the files it lists.
pub fn run(a: std.mem.Allocator, entries: []const Entry) !Report {
    var r = Report{ .errors = std.ArrayList([]const u8).init(a) };
    var by_path = std.StringHashMap([]const u8).init(a);
    for (entries) |e| try by_path.put(e.path, e.file);
    for (entries) |e| {
        if (!std.mem.endsWith(u8, e.path, lock_suffix)) continue;
        r.locks += 1;
        const text = std.fs.cwd().readFileAlloc(a, e.file, 64 << 20) catch |err| {
            try add(a, &r, "{s}: cannot read the lock: {s}", .{ e.path, @errorName(err) });
            continue;
        };
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const p = parseLine(line) orelse continue;
            r.sources += 1;
            const file = by_path.get(p.path) orelse {
                try add(a, &r, "{s}: the source {s} is not among the files of the tree (declared sha256 {s}): the lock names a file that is not there; run `buildrules mojo sync`", .{ e.path, p.path, p.sha });
                continue;
            };
            const actual = hashFile(file) orelse {
                try add(a, &r, "{s}: the source {s} cannot be read (declared sha256 {s})", .{ e.path, p.path, p.sha });
                continue;
            };
            if (!std.mem.eql(u8, p.sha, &actual)) {
                try add(a, &r, "{s}: the source {s} has sha256 {s}, the lock declares {s}: the file changed and the graph was not regenerated; run `buildrules mojo sync`", .{ e.path, p.path, actual, p.sha });
            }
        }
    }
    return r;
}

// ---- tests -----------------------------------------------------------------------------------------------------------------------------

const hello_sha = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"; // sha256 of "hello\n"

fn lockText(a: std.mem.Allocator, path: []const u8, sha: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "SCHEMA = 1\nGRAPH_JSON = r'''{{\n  \"units\": [{{\n      \"srcs\": [\n        {{\"path\": \"{s}\", \"sha256\": \"{s}\"}}\n      ],\n      \"path\": \"unrelated\"\n  }}]\n}}\n'''\n", .{ path, sha });
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,

    fn init() Fixture {
        return .{ .tmp = std.testing.tmpDir(.{}), .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    }
    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }
    fn write(self: *Fixture, name: []const u8, text: []const u8) !void {
        try self.tmp.dir.writeFile(name, text);
    }
    fn real(self: *Fixture, name: []const u8) ![]const u8 {
        return self.tmp.dir.realpathAlloc(self.arena.allocator(), name);
    }
    /// The report of a tree of one lock (`pkg/buildrules.mojo.lock.bzl`) over `src` (`pkg/src.mojo`, absent when null), the lock declaring `sha` for it.
    fn report(self: *Fixture, sha: []const u8, src: ?[]const u8) !Report {
        const a = self.arena.allocator();
        try self.write("lock", try lockText(a, "pkg/src.mojo", sha));
        var entries = std.ArrayList(Entry).init(a);
        try entries.append(.{ .path = "pkg/buildrules.mojo.lock.bzl", .file = try self.real("lock") });
        if (src) |s| {
            try self.write("src", s);
            try entries.append(.{ .path = "pkg/src.mojo", .file = try self.real("src") });
        }
        return run(a, entries.items);
    }
};

fn expectRed(r: Report, needles: []const []const u8) !void {
    try t.expectEqual(@as(usize, 1), r.errors.items.len);
    for (needles) |n| {
        if (std.mem.indexOf(u8, r.errors.items[0], n) == null) {
            std.debug.print("the finding lacks `{s}`: {s}\n", .{ n, r.errors.items[0] });
            return error.FindingLacksName;
        }
    }
}

test "a lock whose hash is the file's is accepted" {
    var f = Fixture.init();
    defer f.deinit();
    const r = try f.report(hello_sha, "hello\n");
    try t.expectEqual(@as(usize, 0), r.errors.items.len);
    try t.expectEqual(@as(usize, 1), r.locks);
    try t.expectEqual(@as(usize, 1), r.sources);
}

test "a lock with a wrong hash is refused, naming the lock, the path, the declared and the actual hash" {
    var f = Fixture.init();
    defer f.deinit();
    const stale = "0891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03";
    const r = try f.report(stale, "hello\n");
    try expectRed(r, &.{ "pkg/buildrules.mojo.lock.bzl", "pkg/src.mojo", stale, hello_sha });
}

test "a file edited after the lock was written is refused" {
    var f = Fixture.init();
    defer f.deinit();
    const r = try f.report(hello_sha, "hello, with a docstring edit\n");
    try expectRed(r, &.{ "pkg/buildrules.mojo.lock.bzl", "pkg/src.mojo", hello_sha });
}

test "a lock that lists a file that is not there is refused" {
    var f = Fixture.init();
    defer f.deinit();
    const r = try f.report(hello_sha, null);
    try expectRed(r, &.{ "pkg/buildrules.mojo.lock.bzl", "pkg/src.mojo", hello_sha, "not among the files" });
}

test "a listed file that cannot be read is refused" {
    var f = Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.write("lock", try lockText(a, "pkg/src.mojo", hello_sha));
    const entries = [_]Entry{
        .{ .path = "pkg/buildrules.mojo.lock.bzl", .file = try f.real("lock") },
        .{ .path = "pkg/src.mojo", .file = "/nonexistent/lock_hashes_fixture" },
    };
    const r = try run(a, &entries);
    try expectRed(r, &.{ "pkg/src.mojo", "cannot be read", hello_sha });
}

test "a file that is not a lock is not read as one" {
    var f = Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.write("other", try lockText(a, "pkg/gone.mojo", hello_sha));
    const entries = [_]Entry{.{ .path = "pkg/notes.txt", .file = try f.real("other") }};
    const r = try run(a, &entries);
    try t.expectEqual(@as(usize, 0), r.locks);
    try t.expectEqual(@as(usize, 0), r.errors.items.len);
}

test "every lock is read, and each stale one is a finding of its own" {
    var f = Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    try f.write("l1", try lockText(a, "a/x.mojo", hello_sha));
    try f.write("l2", try lockText(a, "b/y.mojo", hello_sha));
    try f.write("x", "hello\n");
    try f.write("y", "other\n");
    const entries = [_]Entry{
        .{ .path = "a/buildrules.mojo.lock.bzl", .file = try f.real("l1") },
        .{ .path = "b/buildrules.mojo.lock.bzl", .file = try f.real("l2") },
        .{ .path = "a/x.mojo", .file = try f.real("x") },
        .{ .path = "b/y.mojo", .file = try f.real("y") },
    };
    const r = try run(a, &entries);
    try t.expectEqual(@as(usize, 2), r.locks);
    try expectRed(r, &.{ "b/buildrules.mojo.lock.bzl", "b/y.mojo" });
}
