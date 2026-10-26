//! //tools/deploy:apt_rotation_driver: the `apt-check` half of tools/deploy/apt_rotation.zig, run against a fake `apt-get` and `dpkg-query` (fake_apt.zig) whose answers are files
//! of a directory. The real gpg, gpgv and apt run in the hosted workflow .github/workflows/apt-rotation.yml; what is proved here is the program's judgement of what apt did, so
//! that a run in which apt misbehaved cannot come out green.
//!
//! What it proves, and the defect each check would catch:
//!   - the good run: apt is given the repository alone (the system's source list is /dev/null, the source directory and the list directory are the program's own, for the update
//!     and for the install), the source it writes names the copy of the repository and the copy of the keyring in `Signed-By` and no other key, the copies are the bytes given,
//!     and the verdict is green only after the update, the binary-all index, the install, dpkg's status and the installed file;
//!   - `ok` is red when any one of those fails: the update fails, the update warns, no binary-all index was fetched, the install fails, dpkg does not list the package although the
//!     install said yes, the package's file is not on the disk;
//!   - `refused` is green only when the update fails with apt's words about the signature, the install fails and dpkg does not have the package; it is red when the update
//!     succeeds (the keyring that must be refused was accepted), when the update fails for another reason (the failure proves nothing about signatures), and when the package
//!     installs anyway;
//!   - the usage: an --expect other than ok or refused, and a work directory that is not absolute, are refused.

const std = @import("std");
const h = @import("harness");
const Allocator = std.mem.Allocator;

const package = "rotation-test";
const no_pubkey = "Err:1 file:/x stable InRelease\n  The following signatures couldn't be verified because the public key is not available: NO_PUBKEY 0123456789ABCDEF\nW: GPG error: file:/x stable InRelease: NO_PUBKEY 0123456789ABCDEF\n";
const unrelated = "E: Failed to fetch file:/x/dists/stable/InRelease  File not found\n";
const release_text = "Origin: test\nSuite: stable\n";
const keyring_bytes = "keyring bytes, not a key\n";

const Tools = struct { rotation: []const u8, apt: []const u8 };

const World = struct {
    a: Allocator,
    t: Tools,
    root: []const u8,

    fn path(w: World, name: []const u8) []const u8 {
        return h.join(w.a, &.{ w.root, name }) catch @panic("oom");
    }
    fn read(w: World, name: []const u8) []const u8 {
        return h.readFile(w.a, w.path(name)) catch "";
    }
    fn has(w: World, name: []const u8) bool {
        std.fs.cwd().access(w.path(name), .{}) catch return false;
        return true;
    }

    /// A repository of two files, a keyring, and the fake's state with the given flag files (name, text).
    fn setup(w: World, flags: []const [2][]const u8) !void {
        try h.writeFile(w.path("repo/dists/stable/Release"), release_text);
        try h.writeFile(w.path("repo/dists/stable/InRelease"), "signed " ++ release_text);
        try h.writeFile(w.path("key.gpg"), keyring_bytes);
        try std.fs.cwd().makePath(w.path("state"));
        for (flags) |f| try h.writeFile(try h.join(w.a, &.{ w.path("state"), f[0] }), f[1]);
    }

    fn runWith(w: World, expect: []const u8, work: []const u8) !h.Ran {
        var e = try h.environ(w.a);
        try e.put("FAKE_APT_DIR", w.path("state"));
        try e.put("FAKE_APT_FILE", w.path("installed/hello"));
        return h.run(w.a, &.{ w.t.rotation, "apt-check", "--repo", w.path("repo"), "--keyring", w.path("key.gpg"), "--package", package, "--installed-file", w.path("installed/hello"), "--work", work, "--expect", expect, "--apt-get", w.t.apt, "--dpkg-query", w.t.apt }, &e, .{});
    }

    fn check(w: World, expect: []const u8) !h.Ran {
        return w.runWith(expect, w.path("work"));
    }
};

fn world(a: Allocator, t: Tools, tmp: *std.testing.TmpDir, n: *usize) !World {
    n.* += 1;
    return .{ .a = a, .t = t, .root = try h.join(a, &.{ try h.tmpPath(a, tmp), try h.fmt(a, "w{d}", .{n.*}) }) };
}

fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}

test "apt_rotation apt-check: the verdict on apt's behaviour, each refusal one thing gone wrong in an otherwise good run" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = Tools{ .rotation = try h.toolPath(a, "APT_ROTATION"), .apt = try h.toolPath(a, "FAKE_APT") };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rep = h.Report{};
    var n: usize = 0;

    // ---- the good run -----------------------------------------------------------------------------------------------------
    {
        const w = try world(a, t, &tmp, &n);
        try w.setup(&.{});
        const r = try w.check("ok");
        rep.check("ok: the good run is green", r.code == 0 and h.contains(r.text, "ok: dpkg says the package is installed") and h.contains(r.text, "ok: the package's file is on the disk"), r.text);
        const log = w.read("state/log");
        const lists = try h.fmt(a, "Dir::State::lists={s}/work/lists", .{w.root});
        const parts = try h.fmt(a, "Dir::Etc::sourceparts={s}/work/sources", .{w.root});
        rep.check("ok: the update and the install are both given an empty system source list, the program's source directory and its list directory", count(log, "-o Dir::Etc::sourcelist=/dev/null") == 2 and count(log, parts) == 2 and count(log, lists) == 2 and h.contains(log, "update -o") and h.contains(log, "install -y --no-install-recommends rotation-test -o"), log);
        const want_source = try h.fmt(a, "Types: deb\nURIs: file://{s}/work/repo\nSuites: stable\nComponents: main\nSigned-By: {s}/work/key.gpg\n", .{ w.root, w.root });
        rep.same("ok: the source names the copy of the repository and the copy of the keyring, and no other key", want_source, w.read("work/sources/rotation.sources"));
        rep.same("ok: the keyring copy is the keyring given", keyring_bytes, w.read("work/key.gpg"));
        rep.same("ok: the repository copy is the repository given (InRelease)", "signed " ++ release_text, w.read("work/repo/dists/stable/InRelease"));
        rep.same("ok: the repository copy is the repository given (Release)", release_text, w.read("work/repo/dists/stable/Release"));
        rep.check("ok: dpkg was asked about the package", h.contains(log, "-W -f=${Status} rotation-test"), log);
    }

    // ---- ok is red when apt did not do all of it ---------------------------------------------------------------------------
    const bad_ok = [_]struct { name: []const u8, flags: []const [2][]const u8, words: []const u8 }{
        .{ .name = "the update fails", .flags = &.{.{ "update_fail", unrelated }}, .words = "EXPECTATION FAILED: apt-get update succeeds" },
        .{ .name = "the update warns", .flags = &.{.{ "update_warn", "" }}, .words = "EXPECTATION FAILED: apt-get update prints no warning and no error" },
        .{ .name = "no binary-all index is fetched", .flags = &.{.{ "no_all_index", "" }}, .words = "EXPECTATION FAILED: apt fetched the binary-all index" },
        .{ .name = "the install fails", .flags = &.{.{ "install_fail", "" }}, .words = "EXPECTATION FAILED: apt-get install of the all package succeeds" },
        .{ .name = "dpkg does not list the package after an install that said yes", .flags = &.{.{ "install_noop", "" }}, .words = "EXPECTATION FAILED: dpkg says the package is installed" },
        .{ .name = "the package's file is not on the disk", .flags = &.{.{ "no_file", "" }}, .words = "EXPECTATION FAILED: the package's file is on the disk" },
    };
    for (bad_ok) |c| {
        const w = try world(a, t, &tmp, &n);
        try w.setup(c.flags);
        const r = try w.check("ok");
        rep.check(try h.fmt(a, "ok is red when {s}", .{c.name}), r.code == 1 and h.contains(r.text, c.words), r.text);
    }

    // ---- refused ---------------------------------------------------------------------------------------------------------
    {
        const w = try world(a, t, &tmp, &n);
        try w.setup(&.{ .{ "update_fail", no_pubkey }, .{ "install_fail", "" } });
        const r = try w.check("refused");
        rep.check("refused: green when the update fails for the signature, the install fails and dpkg does not have the package", r.code == 0 and h.contains(r.text, "ok: and apt says the signature is why") and h.contains(r.text, "ok: and dpkg does not have it"), r.text);
    }
    const bad_refused = [_]struct { name: []const u8, flags: []const [2][]const u8, words: []const u8 }{
        .{ .name = "the update succeeds (the keyring that must be refused was accepted)", .flags = &.{.{ "install_fail", "" }}, .words = "EXPECTATION FAILED: apt-get update fails when Signed-By holds a key that signed nothing" },
        .{ .name = "the update fails for a reason that is not the signature", .flags = &.{ .{ "update_fail", unrelated }, .{ "install_fail", "" } }, .words = "EXPECTATION FAILED: and apt says the signature is why" },
        .{ .name = "the package installs anyway", .flags = &.{.{ "update_fail", no_pubkey }}, .words = "EXPECTATION FAILED: the package does not install from the refused repository" },
    };
    for (bad_refused) |c| {
        const w = try world(a, t, &tmp, &n);
        try w.setup(c.flags);
        const r = try w.check("refused");
        rep.check(try h.fmt(a, "refused is red when {s}", .{c.name}), r.code == 1 and h.contains(r.text, c.words), r.text);
    }

    // ---- the usage ----------------------------------------------------------------------------------------------------------
    {
        const w = try world(a, t, &tmp, &n);
        try w.setup(&.{});
        const other = try w.check("maybe");
        rep.check("an --expect other than ok or refused is refused", other.code == 1 and h.contains(other.text, "--expect is ok or refused"), other.text);
        const relative = try w.runWith("ok", "relative/work");
        rep.check("a work directory that is not absolute is refused", relative.code == 1 and h.contains(relative.text, "--work must be an absolute path"), relative.text);
        rep.check("and neither ran apt", !w.has("state/log"), w.read("state/log"));
    }

    try rep.finish();
}
