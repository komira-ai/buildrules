//! `buildrules sync --sources DIR` and `--list-sources FILE` (sources.zig): a sync that reads the packages of Cargo.lock from files
//! fetched by hash, never from the network. cargo is a fake behind the exec seam (it prints the unit graph real cargo prints for the
//! layout sources.zig makes); the generator is the real one, so a test compares what it writes with what a sync with the network writes.

const std = @import("std");
const cargo_lock = @import("cargo_lock.zig");
const ctxm = @import("ctx.zig");
const git_archive = @import("git_archive.zig");
const git_source = @import("git_source.zig");
const kit = @import("testkit.zig");
const sources = @import("sources.zig");
const Diag = @import("diag.zig").Diag;
const t = std.testing;

const crates_io = sources.crates_io;
const rev = "0123456789abcdef0123456789abcdef01234567";
const git_src = "git+https://github.com/o/r?rev=" ++ rev ++ "#" ++ rev;
const record_file = "third_party/buildrules/git_archives.tsv";

const itoa_manifest = "[package]\nname = \"itoa\"\nversion = \"1.0.15\"\n";
const r_root = "[package]\nname = \"r\"\nversion = \"0.1.0\"\n\n[workspace]\nmembers = [\"impl\"]\n\n[workspace.package]\nedition = \"2021\"\n";
const r_impl = "[package]\nname = \"r-impl\"\nversion = \"0.1.0\"\nedition.workspace = true\n";

fn itoaCrate(a: std.mem.Allocator) ![]u8 {
    return kit.tarGz(a, &.{
        .{ .path = "itoa-1.0.15/" },
        .{ .path = "itoa-1.0.15/Cargo.toml", .data = itoa_manifest },
        .{ .path = "itoa-1.0.15/src/lib.rs", .data = "pub fn itoa() {}\n" },
    }, 0);
}

/// GitHub's archive of github.com/o/r at `rev`: a root package `r` with a member `r-impl` in impl/, which inherits its edition, and
/// a README that links to a file of the repository.
fn rArchive(a: std.mem.Allocator) ![]u8 {
    const top = "r-" ++ rev;
    return kit.tarGz(a, &.{
        .{ .path = top ++ "/" },
        .{ .path = top ++ "/Cargo.toml", .data = r_root },
        .{ .path = top ++ "/src/lib.rs", .data = "pub fn r() {}\n" },
        .{ .path = top ++ "/impl/" },
        .{ .path = top ++ "/impl/Cargo.toml", .data = r_impl },
        .{ .path = top ++ "/impl/src/lib.rs", .data = "pub fn i() {}\n" },
        .{ .path = top ++ "/NOTES", .data = "notes\n" },
        .{ .path = top ++ "/impl/NOTES", .link = "../NOTES" },
    }, 0);
}

fn lockOf(a: std.mem.Allocator, itoa_sum: []const u8, with_git: bool) ![]const u8 {
    var o = std.ArrayList(u8).empty;
    try o.appendSlice(a, "version = 4\n\n[[package]]\nname = \"hello\"\nversion = \"0.1.0\"\ndependencies = [\n \"itoa\",\n]\n\n");
    try o.print(a, "[[package]]\nname = \"itoa\"\nversion = \"1.0.15\"\nsource = \"" ++ crates_io ++ "\"\nchecksum = \"{s}\"\n", .{itoa_sum});
    if (with_git) {
        try o.appendSlice(a, "\n[[package]]\nname = \"r\"\nversion = \"0.1.0\"\nsource = \"" ++ git_src ++ "\"\ndependencies = [\n \"r-impl\",\n]\n");
        try o.appendSlice(a, "\n[[package]]\nname = \"r-impl\"\nversion = \"0.1.0\"\nsource = \"" ++ git_src ++ "\"\n");
    }
    return o.items;
}

fn recordOf(a: std.mem.Allocator, archive: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, git_archive.header ++ "github.com/o/r " ++ rev ++ " {s} {d} r-" ++ rev ++ "\n", .{ try ctxm.sha256Hex(a, archive), archive.len });
}

fn entriesOf(a: std.mem.Allocator, lock: []const u8) ![]const cargo_lock.Entry {
    var d = Diag.init(a);
    return cargo_lock.parse(a, "Cargo.lock", lock, &d);
}

fn recordParsed(a: std.mem.Allocator, text: []const u8) !git_archive.Record {
    var d = Diag.init(a);
    return git_archive.parse(a, &d, text);
}

fn joinedMsgs(a: std.mem.Allocator, d: *const Diag) ![]const u8 {
    return std.mem.join(a, "\n", d.msgs.items);
}

// ---- the list ------------------------------------------------------------------------------------------------------------

test "list: every crates.io package by Cargo.lock's sha256 (no size), every git commit by the record's sha256 and size, as JSON" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const crate = try itoaCrate(a);
    const archive = try rArchive(a);
    const sum = try ctxm.sha256Hex(a, crate);
    var d = Diag.init(a);
    const items = try sources.list(a, &d, try entriesOf(a, try lockOf(a, sum, true)), try recordParsed(a, try recordOf(a, archive)));
    try t.expectEqual(@as(usize, 2), items.len);
    const want = try std.fmt.allocPrint(a, "{{\"sources\":[" ++
        "{{\"file\":\"itoa-1.0.15.crate\",\"url\":\"https://static.crates.io/crates/itoa/itoa-1.0.15.crate\",\"sha256\":\"{s}\",\"size\":null}}," ++
        "{{\"file\":\"o_r_" ++ rev ++ ".tar.gz\",\"url\":\"https://github.com/o/r/archive/" ++ rev ++ ".tar.gz\",\"sha256\":\"{s}\",\"size\":{d}}}]}}\n", .{ sum, try ctxm.sha256Hex(a, archive), archive.len });
    try t.expectEqualStrings(want, try sources.listJson(a, items));
    // two packages of one commit are one archive
    try t.expectEqual(@as(usize, 0), d.count());
}

test "list: what cannot be fetched by hash is refused by package name, every one in one run" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const lock = "version = 4\n\n" ++
        "[[package]]\nname = \"nosum\"\nversion = \"1.0.0\"\nsource = \"" ++ crates_io ++ "\"\n\n" ++
        "[[package]]\nname = \"other\"\nversion = \"1.0.0\"\nsource = \"sparse+https://example.invalid/index/\"\nchecksum = \"" ++ ("ab" ** 32) ++ "\"\n\n" ++
        "[[package]]\nname = \"branchy\"\nversion = \"0.1.0\"\nsource = \"git+https://github.com/o/b?branch=main#" ++ rev ++ "\"\n\n" ++
        "[[package]]\nname = \"r\"\nversion = \"0.1.0\"\nsource = \"" ++ git_src ++ "\"\n";
    var d = Diag.init(a);
    try t.expectError(error.Refused, sources.list(a, &d, try entriesOf(a, lock), null));
    const msgs = try joinedMsgs(a, &d);
    try t.expectEqual(@as(usize, 4), d.count());
    try t.expect(kit.contains(msgs, "nosum 1.0.0: Cargo.lock has no sha256 checksum for it, so it cannot be fetched by hash"));
    try t.expect(kit.contains(msgs, "other 1.0.0: the source sparse+https://example.invalid/index/ is not crates.io or a git repository"));
    try t.expect(kit.contains(msgs, "branchy 0.1.0: the git source git+https://github.com/o/b?branch=main follows branch `main`"));
    try t.expect(kit.contains(msgs, "r 0.1.0: github.com/o/r at " ++ rev ++ " has no row in third_party/buildrules/git_archives.tsv, and a sync without the network cannot measure a new archive"));
}

// ---- unpacking -----------------------------------------------------------------------------------------------------------

test "unpack: files and links land below the destination without the top directory, which is returned" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var d = Diag.init(a);
    try t.expectEqualStrings("r-" ++ rev, try sources.unpack(a, &d, "r", try rArchive(a), tmp.dir));
    try t.expectEqualStrings(r_impl, try tmp.dir.readFileAlloc(a, "impl/Cargo.toml", 1 << 10));
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("../NOTES", try tmp.dir.readLink("impl/NOTES", &buf));
    try t.expectEqualStrings("notes\n", try tmp.dir.readFileAlloc(a, "impl/NOTES", 1 << 10));
}

test "unpack: an archive with two top directories, an unsafe path, no entries or no gzip is refused, naming what it unpacked" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct { bytes: []const u8, msg: []const u8 }{
        .{ .bytes = try kit.tarGz(a, &.{ .{ .path = "a/x", .data = "1" }, .{ .path = "b/y", .data = "2" } }, 0), .msg = "thing: more than one top directory (a, b)" },
        .{ .bytes = try kit.tarGz(a, &.{.{ .path = "a/./x", .data = "1" }}, 0), .msg = "thing: holds the path a/./x, which is not a plain relative path" },
        .{ .bytes = try kit.tarGz(a, &.{.{ .path = "./x", .data = "1" }}, 0), .msg = "thing: the top directory `.` is not a plain name" },
        .{ .bytes = try kit.tarGz(a, &.{}, 0), .msg = "thing: the archive is empty" },
        .{ .bytes = "not a gzip stream", .msg = "thing: not a gzip tar (" },
    };
    for (cases) |c| {
        var d = Diag.init(a);
        try t.expectError(error.Refused, sources.unpack(a, &d, "thing", c.bytes, tmp.dir));
        try t.expect(kit.contains(try joinedMsgs(a, &d), c.msg));
    }
}

// ---- the layout cargo reads ----------------------------------------------------------------------------------------------

const Layout = struct {
    a: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    root: []const u8,
    home: []const u8,
    src: []const u8,
    crate: []const u8,
    archive: []const u8,

    fn init(a: std.mem.Allocator) !Layout {
        var l: Layout = undefined;
        l.a = a;
        l.tmp = std.testing.tmpDir(.{ .iterate = true });
        try l.tmp.dir.makePath("repo/buck-out/buildrules/cargo-home");
        try l.tmp.dir.makePath("fetched");
        l.root = try l.tmp.dir.realpathAlloc(a, "repo");
        l.home = try l.tmp.dir.realpathAlloc(a, "repo/buck-out/buildrules/cargo-home");
        l.src = try l.tmp.dir.realpathAlloc(a, "fetched");
        l.crate = try itoaCrate(a);
        l.archive = try rArchive(a);
        try l.tmp.dir.writeFile(.{ .sub_path = "fetched/itoa-1.0.15.crate", .data = l.crate });
        try l.tmp.dir.writeFile(.{ .sub_path = "fetched/o_r_" ++ rev ++ ".tar.gz", .data = l.archive });
        return l;
    }

    fn vendor(l: *Layout, d: *Diag, lock: []const u8, record: ?[]const u8) !void {
        const rec = if (record) |r| try recordParsed(l.a, r) else null;
        return sources.vendor(l.a, d, l.src, l.root, l.home, try entriesOf(l.a, lock), rec);
    }

    fn read(l: *Layout, rel: []const u8) ![]const u8 {
        return l.tmp.dir.readFileAlloc(l.a, rel, 1 << 20);
    }
};

test "vendor: a crate is unpacked where the generator reads registry packages, with cargo's checksum file and a copy in the cache" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var l = try Layout.init(a);
    defer l.tmp.cleanup();
    const sum = try ctxm.sha256Hex(a, l.crate);
    var d = Diag.init(a);
    try l.vendor(&d, try lockOf(a, sum, false), null);
    const pkg = "repo/" ++ sources.crates_dir ++ "/itoa-1.0.15";
    try t.expectEqualStrings(itoa_manifest, try l.read(pkg ++ "/Cargo.toml"));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{{\"files\":{{}},\"package\":\"{s}\"}}\n", .{sum}), try l.read(pkg ++ "/.cargo-checksum.json"));
    try t.expectEqualStrings(l.crate, try l.read("repo/buck-out/buildrules/cargo-home/" ++ sources.cache_subdir ++ "/itoa-1.0.15.crate"));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "# Written by `buildrules sync --sources`: cargo reads the packages of Cargo.lock from the files of that directory, never from the network.\n" ++
        "[net]\noffline = true\n\n[source.crates-io]\nreplace-with = \"buildrules-crates\"\n\n[source.buildrules-crates]\ndirectory = \"{s}/" ++ sources.crates_dir ++ "\"\n", .{l.root}), try l.read("repo/buck-out/buildrules/cargo-home/config.toml"));
    // a second run replaces the layout: what an earlier run left is gone
    try l.tmp.dir.writeFile(.{ .sub_path = pkg ++ "/stale", .data = "x" });
    try l.vendor(&d, try lockOf(a, sum, false), null);
    try t.expectError(error.FileNotFound, l.tmp.dir.access(pkg ++ "/stale", .{}));
}

test "vendor: each package of a git commit is a directory of links into the unpacked archive, a member beside a link to the root manifest" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var l = try Layout.init(a);
    defer l.tmp.cleanup();
    var d = Diag.init(a);
    try l.vendor(&d, try lockOf(a, try ctxm.sha256Hex(a, l.crate), true), try recordOf(a, l.archive));
    const co = try std.fmt.allocPrint(a, "{s}/git/checkouts/o_r/" ++ rev, .{l.home});
    const v_rel = sources.git_vendor_dir ++ "/o_r_" ++ rev;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // the checkout holds the archive's files and nothing else (git_archive.zig compares the two)
    try t.expectEqualStrings(r_root, try l.read("repo/buck-out/buildrules/cargo-home/git/checkouts/o_r/" ++ rev ++ "/Cargo.toml"));
    try t.expectError(error.FileNotFound, l.tmp.dir.access("repo/buck-out/buildrules/cargo-home/git/checkouts/o_r/" ++ rev ++ "/.cargo-checksum.json", .{}));
    // the root package: every entry of the repository's root
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/src", .{co}), try l.tmp.dir.readLink("repo/" ++ v_rel ++ "/r-0.1.0/src", &buf));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/impl", .{co}), try l.tmp.dir.readLink("repo/" ++ v_rel ++ "/r-0.1.0/impl", &buf));
    try t.expectEqualStrings("{\"files\":{},\"package\":null}\n", try l.read("repo/" ++ v_rel ++ "/r-0.1.0/.cargo-checksum.json"));
    // the member: the entries of impl/, and the root manifest one level up for its inherited edition
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/impl/Cargo.toml", .{co}), try l.tmp.dir.readLink("repo/" ++ v_rel ++ "/r-impl-0.1.0/Cargo.toml", &buf));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}/Cargo.toml", .{co}), try l.tmp.dir.readLink("repo/" ++ v_rel ++ "/Cargo.toml", &buf));
    try t.expectEqualStrings("pub fn i() {}\n", try l.read("repo/" ++ v_rel ++ "/r-impl-0.1.0/src/lib.rs"));
    const cfg = try l.read("repo/buck-out/buildrules/cargo-home/config.toml");
    try t.expect(kit.contains(cfg, try std.fmt.allocPrint(a, "\n[source.buildrules-git-0]\ngit = \"https://github.com/o/r\"\nrev = \"" ++ rev ++ "\"\nreplace-with = \"buildrules-git-0-files\"\n\n" ++
        "[source.buildrules-git-0-files]\ndirectory = \"{s}/" ++ v_rel ++ "\"\n", .{l.root})));
}

test "vendor: a file missing from DIR, or with bytes other than the pinned ones, is refused by name and cargo is given no config" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var l = try Layout.init(a);
    defer l.tmp.cleanup();
    const sum = try ctxm.sha256Hex(a, l.crate);
    const changed = "ab" ** 32;
    // Cargo.lock names other bytes than the file has
    var d = Diag.init(a);
    try t.expectError(error.Refused, l.vendor(&d, try lockOf(a, changed, false), null));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "itoa 1.0.15: {s}/itoa-1.0.15.crate has sha256 {s}, but Cargo.lock records " ++ changed ++ ": a file whose bytes are not the pinned ones is refused", .{ l.src, sum }), try joinedMsgs(a, &d));
    try t.expectError(error.FileNotFound, l.tmp.dir.access("repo/buck-out/buildrules/cargo-home/config.toml", .{}));
    // the archive differs from the record, in its sha256 or its size
    const rec = try recordOf(a, l.archive);
    d = Diag.init(a);
    try t.expectError(error.Refused, l.vendor(&d, try lockOf(a, sum, true), try std.mem.replaceOwned(u8, a, rec, try ctxm.sha256Hex(a, l.archive), changed)));
    try t.expect(kit.contains(try joinedMsgs(a, &d), "github.com/o/r at " ++ rev ++ ": "));
    try t.expect(kit.contains(try joinedMsgs(a, &d), "but third_party/buildrules/git_archives.tsv records " ++ changed));
    d = Diag.init(a);
    const sized = try std.mem.replaceOwned(u8, a, rec, try std.fmt.allocPrint(a, " {d} ", .{l.archive.len}), " 7 ");
    try t.expectError(error.Refused, l.vendor(&d, try lockOf(a, sum, true), sized));
    try t.expect(kit.contains(try joinedMsgs(a, &d), try std.fmt.allocPrint(a, "o_r_" ++ rev ++ ".tar.gz is {d} bytes, but third_party/buildrules/git_archives.tsv records 7", .{l.archive.len})));
    // a file that is not there
    try l.tmp.dir.deleteFile("fetched/itoa-1.0.15.crate");
    d = Diag.init(a);
    try t.expectError(error.Refused, l.vendor(&d, try lockOf(a, sum, false), null));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "itoa 1.0.15: {s}/itoa-1.0.15.crate cannot be read (FileNotFound): every source --list-sources names must be there", .{l.src}), try joinedMsgs(a, &d));
    // and DIR itself
    d = Diag.init(a);
    const none = try std.fmt.allocPrint(a, "{s}/none", .{l.root});
    try t.expectError(error.Refused, sources.vendor(a, &d, none, l.root, l.home, try entriesOf(a, try lockOf(a, sum, false)), null));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "--sources {s}: FileNotFound", .{none}), try joinedMsgs(a, &d));
}

test "vendor: an archive whose top directory is not the recorded one, a crate whose top is not name-version, and a package the archive lacks or holds twice" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var l = try Layout.init(a);
    defer l.tmp.cleanup();
    const sum = try ctxm.sha256Hex(a, l.crate);
    const rec = try recordOf(a, l.archive);
    var d = Diag.init(a);
    try t.expectError(error.Refused, l.vendor(&d, try lockOf(a, sum, true), try std.mem.replaceOwned(u8, a, rec, " r-" ++ rev, " other-top")));
    try t.expectEqualStrings("github.com/o/r at " ++ rev ++ ": the archive's top directory is r-" ++ rev ++ ", but third_party/buildrules/git_archives.tsv records other-top", try joinedMsgs(a, &d));

    const odd = try kit.tarGz(a, &.{.{ .path = "itoa/Cargo.toml", .data = itoa_manifest }}, 0);
    try l.tmp.dir.writeFile(.{ .sub_path = "fetched/itoa-1.0.15.crate", .data = odd });
    d = Diag.init(a);
    try t.expectError(error.Refused, l.vendor(&d, try lockOf(a, try ctxm.sha256Hex(a, odd), false), null));
    try t.expectEqualStrings("itoa 1.0.15: the top directory of itoa-1.0.15.crate is itoa, not itoa-1.0.15", try joinedMsgs(a, &d));
    try l.tmp.dir.writeFile(.{ .sub_path = "fetched/itoa-1.0.15.crate", .data = l.crate });

    // Cargo.lock names a package of the commit that no manifest of the archive is, or names one of another version
    const missing = try std.mem.replaceOwned(u8, a, try lockOf(a, sum, true), "name = \"r-impl\"", "name = \"r-gone\"");
    d = Diag.init(a);
    try t.expectError(error.Refused, l.vendor(&d, missing, rec));
    try t.expectEqualStrings("r-gone 0.1.0: no Cargo.toml in the archive of github.com/o/r at " ++ rev ++ " is that package", try joinedMsgs(a, &d));

    const top = "r-" ++ rev;
    const twice = try kit.tarGz(a, &.{
        .{ .path = top ++ "/Cargo.toml", .data = "[package]\nname = \"r\"\nversion = \"0.1.0\"\n" },
        .{ .path = top ++ "/copy/Cargo.toml", .data = "[package]\nname = \"r\"\nversion = \"0.1.0\"\n" },
        .{ .path = top ++ "/old/Cargo.toml", .data = "[package]\nname = \"r\"\nversion = \"0.0.1\"\n" },
        .{ .path = top ++ "/bad/Cargo.toml", .data = "[package\n" },
    }, 0);
    try l.tmp.dir.writeFile(.{ .sub_path = "fetched/o_r_" ++ rev ++ ".tar.gz", .data = twice });
    const only_r = try std.mem.replaceOwned(u8, a, try lockOf(a, sum, true), "\n[[package]]\nname = \"r-impl\"\nversion = \"0.1.0\"\nsource = \"" ++ git_src ++ "\"\n", "");
    d = Diag.init(a);
    try t.expectError(error.Refused, l.vendor(&d, only_r, try recordOf(a, twice)));
    const msg = try joinedMsgs(a, &d);
    try t.expect(kit.contains(msg, "r 0.1.0: the archive of github.com/o/r at " ++ rev ++ " has two Cargo.toml of the package ("));
    try t.expect(kit.contains(msg, "copy/Cargo.toml"));
    try t.expect(!kit.contains(msg, "old/"));
}

test "vendor: a package with no member beside it gets no root-manifest link, and a repository with no root manifest gets none either" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var l = try Layout.init(a);
    defer l.tmp.cleanup();
    const sum = try ctxm.sha256Hex(a, l.crate);
    const top = "r-" ++ rev;
    const no_root = try kit.tarGz(a, &.{
        .{ .path = top ++ "/crates/r/Cargo.toml", .data = "[package]\nname = \"r\"\nversion = \"0.1.0\"\n" },
        .{ .path = top ++ "/crates/r/.cargo-checksum.json", .data = "{}" },
    }, 0);
    try l.tmp.dir.writeFile(.{ .sub_path = "fetched/o_r_" ++ rev ++ ".tar.gz", .data = no_root });
    const only_r = try std.mem.replaceOwned(u8, a, try lockOf(a, sum, true), "\n[[package]]\nname = \"r-impl\"\nversion = \"0.1.0\"\nsource = \"" ++ git_src ++ "\"\n", "");
    var d = Diag.init(a);
    try l.vendor(&d, only_r, try recordOf(a, no_root));
    const v_rel = "repo/" ++ sources.git_vendor_dir ++ "/o_r_" ++ rev;
    try t.expectError(error.FileNotFound, l.tmp.dir.access(v_rel ++ "/Cargo.toml", .{}));
    // a checksum file the package itself has is not linked: cargo's own is written in its place
    try t.expectEqualStrings("{\"files\":{},\"package\":null}\n", try l.read(v_rel ++ "/r-0.1.0/.cargo-checksum.json"));
}

test "vendor and list: the refusals of the list are the vendor's too, and allocation failures end both with an error or a message" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var l = try Layout.init(a);
    defer l.tmp.cleanup();
    const lock = "version = 4\n\n[[package]]\nname = \"nosum\"\nversion = \"1.0.0\"\nsource = \"" ++ crates_io ++ "\"\n";
    var d = Diag.init(a);
    try t.expectError(error.Refused, l.vendor(&d, lock, null));
    try t.expect(kit.contains(try joinedMsgs(a, &d), "nosum 1.0.0: Cargo.lock has no sha256 checksum"));
    const entries = try entriesOf(a, try lockOf(a, try ctxm.sha256Hex(a, l.crate), true));
    const record = try recordParsed(a, try recordOf(a, l.archive));
    try kit.sweepRefusal(sources.list, .{ entries, record });
    try kit.sweepRefusal(sources.vendor, .{ l.src, l.root, l.home, entries, record });
}

// ---- `buildrules sync --sources` and `--list-sources` ---------------------------------------------------------------------

const buckgen = @import("buckgen.zig");

const fx = struct {
    const root_cargo = @embedFile("fixture/root.Cargo.toml");
    const hello_cargo = @embedFile("fixture/hello.Cargo.toml");
    const hello_buck = @embedFile("fixture/hello.BUCK");
    const toolchain = @embedFile("fixture/rust-toolchain.toml");
    const rust_pins = @embedFile("fixture/rules_rust_pins.bzl.fixture");
};

const profile_dev =
    "{\"name\":\"dev\",\"opt_level\":\"0\",\"lto\":\"false\",\"codegen_backend\":null,\"codegen_units\":null,\"debuginfo\":2," ++
    "\"split_debuginfo\":null,\"debug_assertions\":true,\"overflow_checks\":true,\"rpath\":false,\"incremental\":false," ++
    "\"panic\":\"unwind\",\"strip\":{\"deferred\":\"None\"}}";

fn libUnit(comptime pid: []const u8, comptime name: []const u8, comptime src: []const u8, comptime deps: []const u8) []const u8 {
    return "{\"pkg_id\":\"" ++ pid ++ "\",\"target\":{\"kind\":[\"lib\"],\"crate_types\":[\"lib\"],\"name\":\"" ++ name ++ "\"," ++
        "\"src_path\":\"" ++ src ++ "\",\"edition\":\"2021\",\"doctest\":true,\"test\":true}," ++
        "\"profile\":" ++ profile_dev ++ ",\"platform\":\"x86_64-unknown-linux-gnu\",\"mode\":\"build\",\"features\":[],\"dependencies\":[" ++ deps ++ "]}";
}

fn dep(comptime index: []const u8, comptime name: []const u8) []const u8 {
    return "{\"index\":" ++ index ++ ",\"extern_crate_name\":\"" ++ name ++ "\",\"public\":false,\"noprelude\":false}";
}

/// The unit graph cargo prints for hello -> itoa, r -> r_impl, with the packages where `itoa_dir` and `r_dir` say (below @ROOT@).
fn graphOf(comptime itoa_dir: []const u8, comptime r_dir: []const u8, comptime impl_dir: []const u8) []const u8 {
    return "{\"version\":1,\"units\":[" ++
        libUnit("registry+https://github.com/rust-lang/crates.io-index#itoa@1.0.15", "itoa", "@ROOT@/" ++ itoa_dir ++ "/src/lib.rs", "") ++ "," ++
        libUnit("git+https://github.com/o/r?rev=" ++ rev ++ "#r-impl@0.1.0", "r_impl", "@ROOT@/" ++ impl_dir ++ "/src/lib.rs", "") ++ "," ++
        libUnit("git+https://github.com/o/r?rev=" ++ rev ++ "#0.1.0", "r", "@ROOT@/" ++ r_dir ++ "/src/lib.rs", dep("1", "r_impl")) ++ "," ++
        libUnit("path+file://@ROOT@/crates/hello#0.1.0", "hello", "@ROOT@/crates/hello/src/lib.rs", dep("0", "itoa") ++ "," ++ dep("2", "r")) ++
        "],\"roots\":[3]}";
}

/// What cargo prints with the network: the crate in cargo's registry sources, the commit in cargo's checkout.
const net_checkout = "cargo/git/checkouts/r-0123456789abcdef/0123456";
const graph_net = graphOf("cargo/registry/src/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15", net_checkout, net_checkout ++ "/impl");
/// What cargo prints against the layout of sources.zig: the directory sources.
const v_git = sources.git_vendor_dir ++ "/o_r_" ++ rev;
const graph_vendored = graphOf(sources.crates_dir ++ "/itoa-1.0.15", v_git ++ "/r-0.1.0", v_git ++ "/r-impl-0.1.0");

var graph: []const u8 = graph_net;
var cargo_calls: usize = 0;
var cargo_offline: bool = false;
var net_fetches: usize = 0;

fn fakeExec(ctx: *ctxm.Ctx, spec: ctxm.Exec) anyerror!ctxm.ExecResult {
    if (!std.mem.endsWith(u8, spec.argv[0], "cargo")) return .{ .code = 99 };
    if (!kit.replaying) cargo_calls += 1;
    // cargo reads its home's config: the offline one only after a sync with --sources wrote it
    if (!kit.replaying) cargo_offline = ctx.exists("buck-out/buildrules/cargo-home/config.toml");
    if (!spec.capture) return .{ .code = 0 };
    const root = try ctx.dir.realpathAlloc(ctx.a, ".");
    return .{ .code = 0, .stdout = try std.mem.replaceOwned(u8, ctx.a, graph, "@ROOT@", root) };
}

fn noCrateDownload(_: std.mem.Allocator, url: []const u8) anyerror!@import("fetch.zig").Digest.Result {
    if (!kit.replaying) net_fetches += 1;
    std.debug.print("unexpected download of {s}\n", .{url});
    return error.NoNetworkInThisTest;
}

var served_archive: []const u8 = "";

fn archiveFromNetwork(_: std.mem.Allocator, _: []const u8) anyerror![]const u8 {
    if (!kit.replaying) net_fetches += 1;
    return served_archive;
}

fn noArchiveDownload(_: std.mem.Allocator, url: []const u8) anyerror![]const u8 {
    if (!kit.replaying) net_fetches += 1;
    std.debug.print("unexpected download of {s}\n", .{url});
    return error.NoNetworkInThisTest;
}

/// A repository of one member, hello, depending on itoa (crates.io) and r (git, with its member r-impl).
fn repo(h: *kit.Harness, lock: []const u8) !void {
    try h.put(".buckconfig", "[cells]\n");
    try h.put("Cargo.toml", fx.root_cargo);
    try h.put("Cargo.lock", lock);
    try h.put("crates/hello/Cargo.toml", fx.hello_cargo);
    try h.put("crates/hello/BUCK", fx.hello_buck);
    try h.put("rust-toolchain.toml", fx.toolchain);
    try h.put("fake/pins.bzl", fx.rust_pins);
    h.ctx.execer = &fakeExec;
    cargo_calls = 0;
    net_fetches = 0;
}

const tools = [_][]const u8{ "--cargo", "/fake/cargo", "--rustc", "/fake/rustc", "--pins", "fake/pins.bzl" };

fn syncArgs(a: std.mem.Allocator, extra: []const []const u8) ![]const []const u8 {
    return std.mem.concat(a, []const u8, &.{ &.{"sync"}, &tools, extra });
}

const generated_files = [_][]const u8{ "buildrules.lock.bzl", "buildrules.bzl", "BUCK", "toolchains/rust_pins.bzl", "third_party/buildrules/BUCK", "third_party/buildrules/crate_sizes.tsv", record_file };

test "sync --sources writes, byte for byte, the files a sync with the network writes, downloading nothing; --check agrees, and a later sync with the network drops the offline config" {
    const saved_crate = buckgen.fetcher;
    const saved_archive = git_archive.fetcher;
    defer buckgen.fetcher = saved_crate;
    defer git_archive.fetcher = saved_archive;
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var l = try Layout.init(a);
    defer l.tmp.cleanup();
    const lock = try lockOf(a, try ctxm.sha256Hex(a, l.crate), true);

    // with the network: cargo's cache and checkout, the archive downloaded
    const net = try kit.Harness.create();
    defer net.destroy();
    try repo(net, lock);
    try net.put("buck-out/buildrules/cargo-home/registry/cache/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15.crate", l.crate);
    {
        var co = try net.tmp.dir.makeOpenPath(net_checkout, .{});
        defer co.close();
        var d = Diag.init(a);
        _ = try sources.unpack(a, &d, "r", l.archive, co);
    }
    try net.put("cargo/registry/src/index.crates.io-1949cf8c6b5b557f/itoa-1.0.15/Cargo.toml", itoa_manifest);
    graph = graph_net;
    served_archive = l.archive;
    buckgen.fetcher = &noCrateDownload;
    git_archive.fetcher = &archiveFromNetwork;
    try t.expectEqual(@as(u8, 0), net.run(try syncArgs(a, &.{})).code);
    try t.expectEqual(@as(usize, 1), net_fetches);

    // without it: the files of DIR only
    const off = try kit.Harness.create();
    defer off.destroy();
    try repo(off, lock);
    try off.put(record_file, net.read(record_file));
    graph = graph_vendored;
    git_archive.fetcher = &noArchiveDownload;
    const r = off.run(try syncArgs(a, &.{ "--sources", l.src }));
    try t.expectEqualStrings("", r.err);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqual(@as(usize, 0), net_fetches);
    try t.expect(cargo_offline);
    for (generated_files) |f| try t.expectEqualStrings(net.read(f), off.read(f));
    try t.expectEqualStrings(lock, off.read("Cargo.lock"));
    try t.expect(kit.contains(off.read("buildrules.lock.bzl"), "\"rev\": \"" ++ rev ++ "\""));

    // --check, with and without the network, finds them in sync
    try t.expectEqual(@as(u8, 0), off.run(try syncArgs(a, &.{ "--sources", l.src, "--check" })).code);
    try t.expectEqual(@as(u8, 0), off.run(try syncArgs(a, &.{"--check"})).code);
    try t.expect(!cargo_offline);
    try t.expect(!off.has("buck-out/buildrules/cargo-home/config.toml"));
    try t.expectEqual(@as(usize, 0), net_fetches);
}

test "sync --sources: a crate whose bytes are not Cargo.lock's is refused by name before cargo runs, and nothing is written" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var l = try Layout.init(a);
    defer l.tmp.cleanup();
    const h = try kit.Harness.create();
    defer h.destroy();
    const changed = "cd" ** 32;
    try repo(h, try lockOf(a, changed, false));
    const r = h.run(try syncArgs(a, &.{ "--sources", l.src }));
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, try std.fmt.allocPrint(a, "buildrules: itoa 1.0.15: {s}/itoa-1.0.15.crate has sha256 {s}, but Cargo.lock records " ++ changed, .{ l.src, try ctxm.sha256Hex(a, l.crate) })));
    try t.expectEqual(@as(usize, 0), cargo_calls);
    try t.expect(!h.has("buildrules.lock.bzl"));
    try t.expect(!h.has("buck-out/buildrules/cargo-home/config.toml"));
}

test "sync --sources: no Cargo.lock, a record that cannot be read, or a DIR that is not there stops the sync before cargo" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var l = try Layout.init(a);
    defer l.tmp.cleanup();
    const h = try kit.Harness.create();
    defer h.destroy();
    try repo(h, "");
    try h.tmp.dir.deleteFile("Cargo.lock");
    var r = h.run(try syncArgs(a, &.{ "--sources", l.src }));
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "Cargo.lock is missing: a sync without the network resolves only the packages Cargo.lock names; run `buildrules sync` where there is a network"));
    try h.put("Cargo.lock", "version = 9\n");
    r = h.run(try syncArgs(a, &.{ "--sources", l.src }));
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "Cargo.lock: lock version 9 is not 3 or 4"));
    try h.put("Cargo.lock", try lockOf(a, try ctxm.sha256Hex(a, l.crate), true));
    try h.put(record_file, "github.com/o/r " ++ rev ++ " nothex 1 top\n");
    r = h.run(try syncArgs(a, &.{ "--sources", l.src }));
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "git: third_party/buildrules/git_archives.tsv:1: `nothex` is not a sha256"));
    try t.expectEqual(@as(usize, 0), cargo_calls);
    r = h.run(try syncArgs(a, &.{ "--sources", "no-such-dir" }));
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "cannot open --sources no-such-dir: FileNotFound"));
}

test "sync --list-sources writes the downloads and runs nothing; it needs Cargo.lock and a readable record, and refuses what cannot be fetched by hash" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var l = try Layout.init(a);
    defer l.tmp.cleanup();
    const h = try kit.Harness.create();
    defer h.destroy();
    const lock = try lockOf(a, try ctxm.sha256Hex(a, l.crate), true);
    try repo(h, lock);
    try h.put(record_file, try recordOf(a, l.archive));
    var r = h.run(&.{ "sync", "--list-sources", "plan.json" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, "wrote   plan.json: 2 source(s)"));
    var d = Diag.init(a);
    try t.expectEqualStrings(try sources.listJson(a, try sources.list(a, &d, try entriesOf(a, lock), try recordParsed(a, try recordOf(a, l.archive)))), h.read("plan.json"));
    try t.expectEqual(@as(usize, 0), cargo_calls);
    // a git commit the record lacks
    try h.put(record_file, git_archive.header);
    r = h.run(&.{ "sync", "--list-sources", "plan2.json" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "buildrules: r 0.1.0: github.com/o/r at " ++ rev ++ " has no row in third_party/buildrules/git_archives.tsv"));
    try t.expect(kit.contains(r.err, "buildrules: r-impl 0.1.0: github.com/o/r at " ++ rev ++ " has no row"));
    try t.expect(!h.has("plan2.json"));
    try h.put(record_file, "nonsense\n");
    r = h.run(&.{ "sync", "--list-sources", "plan2.json" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "git_archives.tsv:1: not `repository commit sha256 bytes top-directory`"));
    try h.tmp.dir.deleteFile("Cargo.lock");
    r = h.run(&.{ "sync", "--list-sources", "plan2.json" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "Cargo.lock is missing: the sources to fetch are the packages it names"));
    // the two flags exclude each other; each needs its value
    try t.expectEqual(@as(u8, 2), h.run(&.{ "sync", "--list-sources", "p.json", "--sources", "d" }).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "sync", "--sources" }).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{ "sync", "--list-sources" }).code);
    try t.expectEqual(@as(usize, 0), cargo_calls);
}
