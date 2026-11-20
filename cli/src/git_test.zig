//! Git sources (docs/contract.md, "Git sources"): which Cargo.lock sources are taken and which are refused (git_source.zig), a git
//! package in the unit graph (unitgen.zig), its targets (buckgen.zig), its archive compared with cargo's checkout and recorded
//! (git_archive.zig), and `buildrules check` naming a commit Cargo.lock moved. The end-to-end `sync` runs are in sync_check_test.zig.
//! Every test says the defect it catches.

const std = @import("std");
const buckgen = @import("buckgen.zig");
const fetch = @import("fetch.zig");
const git_archive = @import("git_archive.zig");
const git_source = @import("git_source.zig");
const kit = @import("testkit.zig");
const unitgen = @import("unitgen.zig");
const val = @import("val.zig");
const Diag = @import("diag.zig").Diag;
const t = std.testing;

const pins = @embedFile("fixture/rules_rust_pins.bzl.fixture");
const REV = "0123456789abcdef0123456789abcdef01234567";
const REV2 = "fedcba9876543210fedcba9876543210fedcba98";
const H = "c" ** 64;

const Env = struct {
    ar: std.heap.ArenaAllocator,
    fn init() Env {
        return .{ .ar = std.heap.ArenaAllocator.init(t.allocator) };
    }
    fn deinit(e: *Env) void {
        e.ar.deinit();
    }
    fn a(e: *Env) std.mem.Allocator {
        return e.ar.allocator();
    }
};

fn refusedWith(d: *Diag, needle: []const u8) !void {
    try t.expect(d.count() > 0);
    for (d.msgs.items) |m| if (std.mem.indexOf(u8, m, needle) != null) return;
    std.debug.print("no message holds `{s}`: {s}\n", .{ needle, d.msgs.items[0] });
    return error.TestExpectedMessage;
}

// ---- git_source: what Cargo.lock may say -------------------------------------------------------------------------

fn judged(e: *Env, source: []const u8) !git_source.Judged {
    return git_source.judge(e.a(), source);
}

/// `judge` with the allocator failing at each allocation: it answers, or fails with OutOfMemory; it never crashes.
const JudgeCall = struct {
    src: []const u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        _ = git_source.judge(a, self.src) catch return false;
        return true;
    }
};

fn expectBad(e: *Env, source: []const u8, want: []const u8) !void {
    switch (try judged(e, source)) {
        .ok => {
            std.debug.print("accepted: {s}\n", .{source});
            return error.TestExpectedRefusal;
        },
        .bad => |why| try t.expectEqualStrings(want, why),
    }
    try kit.sweepOom(JudgeCall{ .src = source }, false);
}

test "git source: a github.com repository pinned by its full commit is taken, with or without `.git`; the archive is GitHub's tarball of the commit" {
    var e = Env.init();
    defer e.deinit();
    const g = (try judged(&e, "git+https://github.com/o/r?rev=" ++ REV ++ "#" ++ REV)).ok;
    try t.expectEqualStrings("github.com/o/r", g.repo);
    try t.expectEqualStrings("o", g.owner);
    try t.expectEqualStrings("r", g.name);
    try t.expectEqualStrings(REV, g.rev);
    try t.expectEqualStrings("git+https://github.com/o/r?rev=" ++ REV, g.id);
    try t.expectEqualStrings("https://github.com/o/r/archive/" ++ REV ++ ".tar.gz", try git_source.archiveUrl(e.a(), g));
    try t.expectEqualStrings("github.com/o/r@" ++ REV, try git_source.key(e.a(), g.repo, g.rev));
    // cargo keeps the URL as Cargo.toml wrote it; the repository is the same one
    const d = (try judged(&e, "git+https://github.com/Owner-1/re_po.rs.git?rev=" ++ REV ++ "#" ++ REV)).ok;
    try t.expectEqualStrings("github.com/Owner-1/re_po.rs", d.repo);
    try t.expectEqualStrings("re_po.rs", d.name);
    try t.expectEqualStrings("git+https://github.com/Owner-1/re_po.rs.git?rev=" ++ REV, d.id);
    try kit.sweepOom(JudgeCall{ .src = "git+https://github.com/o/r?rev=" ++ REV ++ "#" ++ REV }, false);
    try t.expect(git_source.isGit("git+https://x"));
    try t.expect(!git_source.isGit("registry+https://github.com/rust-lang/crates.io-index"));
}

test "git source: a branch, a tag, the default branch and a short rev can move, and each is refused with the fix" {
    var e = Env.init();
    defer e.deinit();
    const fix = "pin it by commit: `rev = \"<the 40-hex commit>\"` in Cargo.toml, then `buildrules sync`";
    try expectBad(&e, "git+https://github.com/o/r?branch=main#" ++ REV, "the git source git+https://github.com/o/r?branch=main follows branch `main`, which can move: " ++ fix);
    try expectBad(&e, "git+https://github.com/o/r?tag=v1.0#" ++ REV, "the git source git+https://github.com/o/r?tag=v1.0 follows tag `v1.0`, which can move: " ++ fix);
    try expectBad(&e, "git+https://github.com/o/r?ref=dev#" ++ REV, "the git source git+https://github.com/o/r?ref=dev follows branch `dev`, which can move: " ++ fix);
    try expectBad(&e, "git+https://github.com/o/r#" ++ REV, "the git source git+https://github.com/o/r follows the repository's default branch, which moves: " ++ fix);
    try expectBad(&e, "git+https://github.com/o/r?rev=0123456#" ++ REV, "the git source git+https://github.com/o/r?rev=0123456 names rev `0123456`, which is not a full commit id (40 lower-case hex digits): " ++ fix);
    // upper case is the same commit spelled another way: refused rather than compared case-blind
    try expectBad(&e, "git+https://github.com/o/r?rev=0123456789ABCDEF0123456789abcdef01234567#" ++ REV, "the git source git+https://github.com/o/r?rev=0123456789ABCDEF0123456789abcdef01234567 names rev `0123456789ABCDEF0123456789abcdef01234567`, which is not a full commit id (40 lower-case hex digits): " ++ fix);
    try expectBad(&e, "git+https://github.com/o/r?rev=" ++ REV ++ "&branch=main#" ++ REV, "the git source git+https://github.com/o/r?rev=" ++ REV ++ "&branch=main has more than one query parameter: " ++ fix);
    try expectBad(&e, "git+https://github.com/o/r?depth=1#" ++ REV, "the git source git+https://github.com/o/r?depth=1 has an unknown reference `depth=1`: " ++ fix);
}

test "git source: a source buildrules cannot fetch as a GitHub archive of the commit cargo resolved is refused by what is wrong" {
    var e = Env.init();
    defer e.deinit();
    const pin = "?rev=" ++ REV ++ "#" ++ REV;
    try expectBad(&e, "git+https://gitlab.com/o/r" ++ pin, "the git source git+https://gitlab.com/o/r?rev=" ++ REV ++ " is not on github.com: buildrules fetches a git dependency as the GitHub archive of its commit, so only github.com repositories are supported");
    try expectBad(&e, "git+ssh://git@github.com/o/r" ++ pin, "the git source git+ssh://git@github.com/o/r?rev=" ++ REV ++ " is not https: buildrules fetches the GitHub archive of a commit over https only");
    try expectBad(&e, "git+https://github.com/o/r/sub" ++ pin, "the git source git+https://github.com/o/r/sub?rev=" ++ REV ++ " is not https://github.com/<owner>/<repository>");
    try expectBad(&e, "git+https://github.com" ++ pin, "the git source git+https://github.com?rev=" ++ REV ++ " is not https://github.com/<owner>/<repository>");
    try expectBad(&e, "git+https://github.com/o" ++ pin, "the git source git+https://github.com/o?rev=" ++ REV ++ " is not https://github.com/<owner>/<repository>");
    try expectBad(&e, "git+https://github.com/o_x/r" ++ pin, "the git source git+https://github.com/o_x/r?rev=" ++ REV ++ " is not https://github.com/<owner>/<repository>");
    try expectBad(&e, "git+https://github.com/../r" ++ pin, "the git source git+https://github.com/../r?rev=" ++ REV ++ " is not https://github.com/<owner>/<repository>");
    try expectBad(&e, "git+https://github.com/o/r%20x" ++ pin, "the git source git+https://github.com/o/r%20x?rev=" ++ REV ++ " is not https://github.com/<owner>/<repository>");
    try expectBad(&e, "git+https://github.com/o/r?rev=" ++ REV, "the git source git+https://github.com/o/r?rev=" ++ REV ++ " has no resolved commit (`#<commit>`); let cargo write Cargo.lock");
    try expectBad(&e, "git+https://github.com/o/r?rev=" ++ REV ++ "#" ++ REV2, "the git source git+https://github.com/o/r?rev=" ++ REV ++ " resolved to commit " ++ REV2 ++ ", not to its rev: let cargo rewrite Cargo.lock");
    // a trailing slash is the same repository
    try t.expectEqualStrings("github.com/o/r", (try judged(&e, "git+https://github.com/o/r/" ++ pin)).ok.repo);
}

// ---- unitgen: a git package in cargo's graph -----------------------------------------------------------------------

const profile_dev =
    "{\"name\":\"dev\",\"opt_level\":\"0\",\"lto\":\"false\",\"codegen_backend\":null,\"codegen_units\":null,\"debuginfo\":2," ++
    "\"split_debuginfo\":null,\"debug_assertions\":true,\"overflow_checks\":true,\"rpath\":false,\"incremental\":false," ++
    "\"panic\":\"unwind\",\"strip\":{\"deferred\":\"None\"}}";

const checkout = "cargo/git/checkouts/r-0123456789abcdef/0123456";

fn libUnit(comptime pid: []const u8, comptime name: []const u8, comptime src: []const u8, comptime deps: []const u8) []const u8 {
    return "{\"pkg_id\":\"" ++ pid ++ "\",\"target\":{\"kind\":[\"lib\"],\"crate_types\":[\"lib\"],\"name\":\"" ++ name ++ "\"," ++
        "\"src_path\":\"" ++ src ++ "\",\"edition\":\"2021\",\"doctest\":true,\"test\":true}," ++
        "\"profile\":" ++ profile_dev ++ ",\"platform\":\"x86_64-unknown-linux-gnu\",\"mode\":\"build\",\"features\":[],\"dependencies\":[" ++ deps ++ "]}";
}

/// `app` depending on two packages of one git repository at one commit: `r` at its top (pkg_id `#0.1.0`: the URL's last segment is
/// the name) and `rsub` in `sub/` (pkg_id `#rsub@0.2.0`).
const graph_git =
    "{\"version\":1,\"units\":[" ++
    libUnit("git+https://github.com/o/r?rev=" ++ REV ++ "#0.1.0", "r", "@ROOT@/" ++ checkout ++ "/src/lib.rs", "") ++ "," ++
    libUnit("git+https://github.com/o/r?rev=" ++ REV ++ "#rsub@0.2.0", "rsub", "@ROOT@/" ++ checkout ++ "/sub/src/lib.rs", "") ++ "," ++
    libUnit("path+file://@ROOT@/crates/app#0.1.0", "app", "@ROOT@/crates/app/src/lib.rs", "{\"index\":0,\"extern_crate_name\":\"r\",\"public\":false,\"noprelude\":false}," ++
        "{\"index\":1,\"extern_crate_name\":\"rsub\",\"public\":false,\"noprelude\":false}") ++
    "],\"roots\":[2]}";

fn lockFor(comptime source: []const u8) []const u8 {
    return "version = 4\n\n[[package]]\nname = \"app\"\nversion = \"0.1.0\"\n\n" ++
        "[[package]]\nname = \"r\"\nversion = \"0.1.0\"\nsource = \"" ++ source ++ "\"\n\n" ++
        "[[package]]\nname = \"rsub\"\nversion = \"0.2.0\"\nsource = \"" ++ source ++ "\"\n";
}

const lock_git = lockFor("git+https://github.com/o/r?rev=" ++ REV ++ "#" ++ REV);

const Repo = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,

    fn create(e: *Env) !Repo {
        var tmp = std.testing.tmpDir(.{});
        try tmp.dir.makePath("crates/app/src");
        try tmp.dir.makePath(checkout ++ "/src");
        try tmp.dir.makePath(checkout ++ "/sub/src");
        try tmp.dir.writeFile(.{ .sub_path = "Cargo.toml", .data = "[workspace]\nmembers = [\"crates/app\"]\n" });
        try tmp.dir.writeFile(.{ .sub_path = "crates/app/Cargo.toml", .data = "[package]\nname = \"app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n" });
        try tmp.dir.writeFile(.{ .sub_path = "rust-toolchain.toml", .data = "[toolchain]\nchannel = \"1.95.0\"\n" });
        // the repository is itself a workspace with a package at its top, and one in sub/
        try tmp.dir.writeFile(.{ .sub_path = checkout ++ "/Cargo.toml", .data = "[workspace]\nmembers = [\"sub\"]\n\n[package]\nname = \"r\"\nversion = \"0.1.0\"\n" });
        try tmp.dir.writeFile(.{ .sub_path = checkout ++ "/sub/Cargo.toml", .data = "[package]\nname = \"rsub\"\nversion = \"0.2.0\"\nlinks = \"rsubnative\"\n" });
        // directories on the way up whose manifest is not TOML, or names no package: passed over, like a directory with none
        try tmp.dir.writeFile(.{ .sub_path = checkout ++ "/sub/src/Cargo.toml", .data = "[package\n" });
        try tmp.dir.writeFile(.{ .sub_path = checkout ++ "/src/Cargo.toml", .data = "[workspace]\n" });
        return .{ .tmp = tmp, .root = try tmp.dir.realpathAlloc(e.a(), ".") };
    }

    fn input(r: Repo, lock: []const u8, gs: []const unitgen.GraphIn) unitgen.Input {
        return .{ .cargo_lock = lock, .root = r.root, .graphs = gs, .rustc = "1.95.0", .target = "x86_64-unknown-linux-gnu", .rust_pins = pins, .manifests = &.{ "Cargo.toml", "crates/app/Cargo.toml", "rust-toolchain.toml" } };
    }

    fn graph(r: Repo, e: *Env, template: []const u8) ![]const u8 {
        return std.mem.replaceOwned(u8, e.a(), template, "@ROOT@", r.root);
    }
};

fn unitOf(units: val.Value, crate: []const u8) !val.Value {
    for (units.object.values()) |u| if (std.mem.eql(u8, val.getStr(u, "crate").?, crate)) return u;
    return error.NoSuchUnit;
}

test "generate: a git package is a unit of source `git` with its repository, commit and directory in the repository; its checkout is reported, never tabled" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e);
    defer repo.tmp.cleanup();
    var d = Diag.init(e.a());
    const gs = [_]unitgen.GraphIn{.{ .scope = "app", .verb = "build", .json = try repo.graph(&e, graph_git) }};
    const res = try unitgen.generate(e.a(), &d, repo.input(lock_git, &gs));
    try t.expectEqual(@as(usize, 3), res.units.object.count());
    const r = try unitOf(res.units, "r");
    try t.expectEqualStrings("git", val.getStr(r, "source").?);
    try t.expectEqualStrings("github.com/o/r", val.getStr(r, "repo").?);
    try t.expectEqualStrings(REV, val.getStr(r, "rev").?);
    try t.expectEqualStrings("", val.getStr(r, "subdir").?);
    try t.expectEqualStrings("src/lib.rs", val.getStr(r, "crate_root").?);
    // no registry hash and no workspace path: the archive's hash is git_archives.tsv's
    try t.expect(val.get(r, "sha256") == null);
    try t.expect(val.get(r, "path") == null);
    const sub = try unitOf(res.units, "rsub");
    try t.expectEqualStrings("sub", val.getStr(sub, "subdir").?);
    try t.expectEqualStrings("src/lib.rs", val.getStr(sub, "crate_root").?);
    try t.expectEqualStrings("0.2.0", val.getStr(sub, "version").?);
    // `links` is read from the package's own manifest in the checkout
    try t.expectEqualStrings("rsubnative", val.getStr(sub, "links").?);
    // one checkout for the two packages: one archive
    try t.expectEqual(@as(usize, 1), res.checkouts.count());
    const c = res.checkouts.get("github.com/o/r@" ++ REV).?;
    try t.expectEqualStrings(try std.fmt.allocPrint(e.a(), "{s}/" ++ checkout ++ "/", .{repo.root}), c.dir);
    try t.expectEqualStrings("github.com/o/r", c.git.repo);
    // the table carries no absolute path
    try t.expect(std.mem.indexOf(u8, res.text, repo.root) == null);
    try t.expect(std.mem.indexOf(u8, res.text, "\"source\": \"git\"") != null);
    // with the allocator failing at each allocation: an error, never a wrong table
    try kit.sweepOom(GenerateOk{ .in = repo.input(lock_git, &gs) }, false);
}

const GenerateOk = struct {
    in: unitgen.Input,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        var d = Diag.init(a);
        const res = unitgen.generate(a, &d, self.in) catch return false;
        return res.units.object.count() == 3 and res.checkouts.count() == 1;
    }
};

test "generate: a git URL written with `.git` is the same repository; cargo then names the package in its pkg_id" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e);
    defer repo.tmp.cleanup();
    var json = try std.mem.replaceOwned(u8, e.a(), try repo.graph(&e, graph_git), "github.com/o/r?", "github.com/o/r.git?");
    json = try std.mem.replaceOwned(u8, e.a(), json, "?rev=" ++ REV ++ "#0.1.0\"", "?rev=" ++ REV ++ "#r@0.1.0\"");
    var d = Diag.init(e.a());
    const gs = [_]unitgen.GraphIn{.{ .scope = "app", .verb = "build", .json = json }};
    const res = try unitgen.generate(e.a(), &d, repo.input(lockFor("git+https://github.com/o/r.git?rev=" ++ REV ++ "#" ++ REV), &gs));
    try t.expectEqualStrings("github.com/o/r", val.getStr(try unitOf(res.units, "r"), "repo").?);
    try t.expectEqualStrings("git+https://github.com/o/r.git?rev=" ++ REV, res.checkouts.get("github.com/o/r@" ++ REV).?.git.id);
}

fn generateRefused(e: *Env, repo: Repo, lock: []const u8, json: []const u8, needle: []const u8) !void {
    var d = Diag.init(e.a());
    const gs = [_]unitgen.GraphIn{.{ .scope = "app", .verb = "build", .json = json }};
    try t.expectError(error.Refused, unitgen.generate(e.a(), &d, repo.input(lock, &gs)));
    try refusedWith(&d, needle);
    try kit.sweepRefusal(unitgen.generate, .{repo.input(lock, &gs)});
}

test "generate: a git package that is not pinned by commit, or that cannot be found in cargo's checkout, is refused by name" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e);
    defer repo.tmp.cleanup();
    const ok = try repo.graph(&e, graph_git);
    // a branch, in Cargo.lock and so in the pkg_id
    const branch = try std.mem.replaceOwned(u8, e.a(), ok, "?rev=" ++ REV, "?branch=main");
    try generateRefused(&e, repo, lockFor("git+https://github.com/o/r?branch=main#" ++ REV), branch, "r 0.1.0: the git source git+https://github.com/o/r?branch=main follows branch `main`, which can move");
    // a pkg_id whose source is not the one Cargo.lock has
    try generateRefused(&e, repo, lockFor("git+https://github.com/o/other?rev=" ++ REV ++ "#" ++ REV), ok, "r 0.1.0 is in the unit graph and not in Cargo.lock");
    // a target outside cargo's checkouts
    try generateRefused(&e, repo, lock_git, try std.mem.replaceOwned(u8, e.a(), ok, "/git/checkouts/", "/git/elsewhere/"), "is not in cargo's git checkouts");
    try generateRefused(&e, repo, lock_git, try std.mem.replaceOwned(u8, e.a(), ok, checkout ++ "/src/lib.rs", "cargo/git/checkouts/lib.rs"), "is not in cargo's git checkouts");
    try generateRefused(&e, repo, lock_git, try std.mem.replaceOwned(u8, e.a(), ok, checkout ++ "/src/lib.rs", "cargo/git/checkouts/r-0123456789abcdef/lib.rs"), "is not in cargo's git checkouts");
    // no manifest of the package on the way up from its target
    try generateRefused(&e, repo, lock_git, try std.mem.replaceOwned(u8, e.a(), ok, "#rsub@0.2.0", "#nosuch@0.2.0"), "no Cargo.toml of package nosuch above sub/src/lib.rs");
    // a target at the top of the checkout, which is not the package's
    try generateRefused(&e, repo, lock_git, try std.mem.replaceOwned(u8, e.a(), ok, checkout ++ "/sub/src/lib.rs", checkout ++ "/lib.rs"), "no Cargo.toml of package rsub above lib.rs");
    // a pkg_id cargo would not write
    try generateRefused(&e, repo, lock_git, try std.mem.replaceOwned(u8, e.a(), ok, "?rev=" ++ REV ++ "#rsub@0.2.0", "?rev=" ++ REV), "no #version in the package id");
    try generateRefused(&e, repo, lock_git, try std.mem.replaceOwned(u8, e.a(), ok, "git+https://github.com/o/r?rev=" ++ REV ++ "#0.1.0", "git+nowhere#0.1.0"), "no repository name in the package id");
}

// ---- buckgen: the targets of git units -----------------------------------------------------------------------------

fn gitUnits(e: *Env, repo: Repo) !val.Value {
    var d = Diag.init(e.a());
    const gs = [_]unitgen.GraphIn{.{ .scope = "app", .verb = "build", .json = try repo.graph(e, graph_git) }};
    return (try unitgen.generate(e.a(), &d, repo.input(lock_git, &gs))).units;
}

fn record(e: *Env, text: []const u8) !git_archive.Record {
    var d = Diag.init(e.a());
    return git_archive.parse(e.a(), &d, text);
}

test "buckgen: one crate_src per repository and commit, by GitHub's archive with the recorded sha256, size and top directory; each git unit names it and its directory" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e);
    defer repo.tmp.cleanup();
    const units = try gitUnits(&e, repo);
    const rec = try record(&e, "github.com/o/r " ++ REV ++ " " ++ H ++ " 4242 r-" ++ REV ++ "\n");
    var d = Diag.init(e.a());
    const out = try buckgen.generate(e.a(), &d, units, buckgen.Sizes.init(e.a()), null, .{ .git_archives = &rec });
    const want_src =
        "crate_src(\n    name = \"git-o_r-" ++ REV ++ "\",\n    pkg = \"r\",\n    version = \"" ++ REV ++ "\",\n" ++
        "    url = \"https://github.com/o/r/archive/" ++ REV ++ ".tar.gz\",\n    sha256 = \"" ++ H ++ "\",\n    size_bytes = 4242,\n" ++
        "    top = \"r-" ++ REV ++ "\",\n)\n";
    try t.expectEqual(@as(usize, 1), kit.count(out, want_src));
    try t.expectEqual(@as(usize, 1), kit.count(out, "crate_src("));
    try t.expectEqual(@as(usize, 2), kit.count(out, "    src = \":git-o_r-" ++ REV ++ "\",\n"));
    // only the package below the top of the repository has a directory
    try t.expectEqual(@as(usize, 1), kit.count(out, "    src_dir = \"sub\",\n"));
    try t.expect(kit.contains(out, "srcs = [\"BUCK\", \"crate_sizes.tsv\", \"git_archives.tsv\"],"));
    try t.expect(kit.contains(out, "# 2 cargo units, 0 registry crates"));
    try t.expect(kit.contains(out, "# 2 of the units come from 1 git commit(s) (GitHub archives, sha256 and size from git_archives.tsv)."));
    // the member's unit is cargo_package's, not this package's
    try t.expectEqual(@as(usize, 2), kit.count(out, "cargo_unit("));
    try kit.sweepOom(BuckOk{ .units = units, .rec = &rec, .want = want_src }, false);
}

const BuckOk = struct {
    units: val.Value,
    rec: *const git_archive.Record,
    want: []const u8,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        var d = Diag.init(a);
        const out = buckgen.generate(a, &d, self.units, buckgen.Sizes.init(a), null, .{ .git_archives = self.rec }) catch return false;
        return kit.contains(out, self.want);
    }
};

fn setGit(units: val.Value, crate: []const u8, repo: []const u8, rev: []const u8) !void {
    for (units.object.values()) |*u| {
        if (!std.mem.eql(u8, val.getStr(u.*, "crate").?, crate)) continue;
        try val.put(u, "repo", val.str(repo));
        try val.put(u, "rev", val.str(rev));
    }
}

test "buckgen: units of several commits get one crate_src each, in the order of repository and commit, whatever the order of the units" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e);
    defer repo.tmp.cleanup();
    const units = try gitUnits(&e, repo);
    const rec = try record(&e, "github.com/o/r " ++ REV ++ " " ++ H ++ " 1 r-" ++ REV ++ "\ngithub.com/o/r " ++ REV2 ++ " " ++ H ++ " 2 r-" ++ REV2 ++ "\n" ++
        "github.com/a/z " ++ REV2 ++ " " ++ H ++ " 3 z-" ++ REV2 ++ "\n");
    // the same repository at two commits: the commit orders them
    try setGit(units, "r", "github.com/o/r", REV2);
    try setGit(units, "rsub", "github.com/o/r", REV);
    var d = Diag.init(e.a());
    var out = try buckgen.generate(e.a(), &d, units, buckgen.Sizes.init(e.a()), null, .{ .git_archives = &rec });
    try t.expect(std.mem.indexOf(u8, out, "name = \"git-o_r-" ++ REV ++ "\"").? < std.mem.indexOf(u8, out, "name = \"git-o_r-" ++ REV2 ++ "\"").?);
    try t.expect(kit.contains(out, "# 2 of the units come from 2 git commit(s)"));
    // two repositories: the repository orders them
    try setGit(units, "rsub", "github.com/a/z", REV2);
    out = try buckgen.generate(e.a(), &d, units, buckgen.Sizes.init(e.a()), null, .{ .git_archives = &rec });
    try t.expect(std.mem.indexOf(u8, out, "name = \"git-a_z-" ++ REV2 ++ "\"").? < std.mem.indexOf(u8, out, "name = \"git-o_r-" ++ REV2 ++ "\"").?);
    try t.expect(kit.contains(out, "    pkg = \"z\",\n    version = \"" ++ REV2 ++ "\",\n    url = \"https://github.com/a/z/archive/" ++ REV2 ++ ".tar.gz\",\n"));
    // two unrecorded commits are both named
    const none = try record(&e, "");
    var d2 = Diag.init(e.a());
    try t.expectError(error.Refused, buckgen.generate(e.a(), &d2, units, buckgen.Sizes.init(e.a()), null, .{ .git_archives = &none }));
    try refusedWith(&d2, "lacks: github.com/a/z at " ++ REV2 ++ ", github.com/o/r at " ++ REV2 ++ " (run `buildrules sync`)");
}

test "buckgen: a git unit whose archive is not recorded, or whose table entry is not a github.com repository or a known source, is refused" {
    var e = Env.init();
    defer e.deinit();
    var repo = try Repo.create(&e);
    defer repo.tmp.cleanup();
    var units = try gitUnits(&e, repo);
    var d = Diag.init(e.a());
    try t.expectError(error.Refused, buckgen.generate(e.a(), &d, units, buckgen.Sizes.init(e.a()), null, .{}));
    try refusedWith(&d, "third_party/buildrules/git_archives.tsv lacks: github.com/o/r at " ++ REV ++ " (run `buildrules sync`)");
    const other = try record(&e, "github.com/o/r " ++ REV2 ++ " " ++ H ++ " 1 r-" ++ REV2 ++ "\n");
    var d2 = Diag.init(e.a());
    try t.expectError(error.Refused, buckgen.generate(e.a(), &d2, units, buckgen.Sizes.init(e.a()), null, .{ .git_archives = &other }));
    try refusedWith(&d2, "lacks: github.com/o/r at " ++ REV);
    const rec = try record(&e, "github.com/o/r " ++ REV ++ " " ++ H ++ " 1 r-" ++ REV ++ "\n");
    // a hand-edited table
    for (units.object.keys(), units.object.values()) |k, *u| {
        if (std.mem.eql(u8, val.getStr(u.*, "crate").?, "rsub")) {
            try val.put(u, "repo", val.str("gitlab.com/o/r"));
            var d3 = Diag.init(e.a());
            try t.expectError(error.Refused, buckgen.generate(e.a(), &d3, units, buckgen.Sizes.init(e.a()), null, .{ .git_archives = &rec }));
            try refusedWith(&d3, try std.fmt.allocPrint(e.a(), "{s}: repo gitlab.com/o/r is not github.com/<owner>/<name>", .{k}));
            try val.put(u, "source", val.str("svn"));
            var d4 = Diag.init(e.a());
            try t.expectError(error.Refused, buckgen.generate(e.a(), &d4, units, buckgen.Sizes.init(e.a()), null, .{ .git_archives = &rec }));
            try refusedWith(&d4, try std.fmt.allocPrint(e.a(), "{s}: source svn is not registry, git or path", .{k}));
        }
    }
}

// ---- git_archive: the record and the comparison --------------------------------------------------------------------

test "record: each line is `repository commit sha256 bytes top`; anything else is refused with its line" {
    var e = Env.init();
    defer e.deinit();
    const rec = try record(&e, git_archive.header ++ "\n# a comment\ngithub.com/o/r " ++ REV ++ " " ++ H ++ " 12 r-" ++ REV ++ "\n");
    try t.expectEqual(@as(usize, 1), rec.count());
    const row = rec.get("github.com/o/r@" ++ REV).?;
    try t.expectEqual(@as(u64, 12), row.size);
    try t.expectEqualStrings("r-" ++ REV, row.top);
    const bad = [_][2][]const u8{
        .{ "github.com/o/r " ++ REV ++ " " ++ H ++ " 12\n", ":1: not `repository commit sha256 bytes top-directory`" },
        .{ "github.com/o/r " ++ REV ++ " " ++ H ++ " 12 top extra\n", ":1: not `repository commit sha256 bytes top-directory`" },
        .{ "gitlab.com/o/r " ++ REV ++ " " ++ H ++ " 12 top\n", ":1: `gitlab.com/o/r` is not github.com/<owner>/<repository>" },
        .{ "github.com/o/r main " ++ H ++ " 12 top\n", ":1: `main` is not a 40-hex commit" },
        .{ "github.com/o/r " ++ REV ++ " abc 12 top\n", ":1: `abc` is not a sha256" },
        .{ "github.com/o/r " ++ REV ++ " " ++ "g" ** 64 ++ " 12 top\n", ":1: `" ++ "g" ** 64 ++ "` is not a sha256" },
        .{ "github.com/o/r " ++ REV ++ " " ++ "C" ** 64 ++ " 12 top\n", ":1: `" ++ "C" ** 64 ++ "` is not a sha256" },
        .{ "github.com/o/r " ++ REV ++ " " ++ H ++ " 12 to*p\n", ":1: `to*p` is not a directory name" },
        .{ "github.com/o/r " ++ REV ++ " " ++ H ++ " twelve top\n", ":1: `twelve` is not a size in bytes" },
        .{ "github.com/o/r " ++ REV ++ " " ++ H ++ " 12 ../top\n", ":1: `../top` is not a directory name" },
        .{ "github.com/o/r " ++ REV ++ " " ++ H ++ " 12 top\ngithub.com/o/r " ++ REV ++ " " ++ H ++ " 12 top\n", ":2: github.com/o/r at " ++ REV ++ " is recorded twice" },
    };
    for (bad) |b| {
        var d = Diag.init(e.a());
        try t.expectError(error.Refused, git_archive.parse(e.a(), &d, b[0]));
        try t.expectEqualStrings(try std.fmt.allocPrint(e.a(), "git: third_party/buildrules/git_archives.tsv{s}", .{b[1]}), d.msgs.items[0]);
        try kit.sweepRefusal(git_archive.parse, .{b[0]});
    }
}

/// The files of the fake repository at REV, as cargo checks them out and as GitHub archives them.
const files = [_][2][]const u8{
    .{ "Cargo.toml", "[package]\nname = \"r\"\nversion = \"0.1.0\"\n" },
    .{ "src/lib.rs", "pub fn r() {}\n" },
    .{ "sub/Cargo.toml", "[package]\nname = \"rsub\"\nversion = \"0.2.0\"\n" },
};

fn archiveOf(e: *Env, top: []const u8, extra: []const kit.TarEntry, skip: ?[]const u8, mtime: u64) ![]u8 {
    var es = std.ArrayList(kit.TarEntry).empty;
    try es.append(e.a(), .{ .path = try std.fmt.allocPrint(e.a(), "{s}/", .{top}) });
    try es.append(e.a(), .{ .path = try std.fmt.allocPrint(e.a(), "{s}/src/", .{top}) });
    for (files) |f| {
        if (skip != null and std.mem.eql(u8, skip.?, f[0])) continue;
        try es.append(e.a(), .{ .path = try std.fmt.allocPrint(e.a(), "{s}/{s}", .{ top, f[0] }), .data = f[1] });
    }
    try es.appendSlice(e.a(), extra);
    return kit.tarGz(e.a(), es.items, mtime);
}

const Checkout = struct {
    tmp: std.testing.TmpDir,
    dir: []const u8,

    fn create(e: *Env) !Checkout {
        var tmp = std.testing.tmpDir(.{});
        for (files) |f| {
            if (std.fs.path.dirname(f[0])) |p| try tmp.dir.makePath(p);
            try tmp.dir.writeFile(.{ .sub_path = f[0], .data = f[1] });
        }
        // cargo's own: the clone and the marker, never compared
        try tmp.dir.makePath(".git/objects");
        try tmp.dir.writeFile(.{ .sub_path = ".git/HEAD", .data = REV ++ "\n" });
        try tmp.dir.writeFile(.{ .sub_path = ".cargo-ok", .data = "{\"v\":1}" });
        return .{ .tmp = tmp, .dir = try tmp.dir.realpathAlloc(e.a(), ".") };
    }

    fn map(c: Checkout, e: *Env) !std.StringArrayHashMap(unitgen.Checkout) {
        var m = std.StringArrayHashMap(unitgen.Checkout).init(e.a());
        const g = (try git_source.judge(e.a(), "git+https://github.com/o/r?rev=" ++ REV ++ "#" ++ REV)).ok;
        try m.put("github.com/o/r@" ++ REV, .{ .git = g, .dir = c.dir });
        return m;
    }
};

var served: []const u8 = "";
var serve_error = false;
var downloads: usize = 0;
var asked: []const u8 = "";

fn fakeFetch(_: std.mem.Allocator, url: []const u8) anyerror![]const u8 {
    downloads += 1;
    asked = url;
    if (serve_error) return error.ConnectionRefused;
    return served;
}

fn sha(e: *Env, bytes: []const u8) ![]const u8 {
    var dg: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &dg, .{});
    return e.a().dupe(u8, &std.fmt.bytesToHex(dg, .lower));
}

const RecordCall = struct {
    m: *const std.StringArrayHashMap(unitgen.Checkout),
    old: ?git_archive.Record,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        var d = Diag.init(a);
        _ = git_archive.recordFile(a, &d, self.m, self.old) catch return false;
        return true;
    }
};

fn recordRefused(e: *Env, m: *const std.StringArrayHashMap(unitgen.Checkout), old: ?git_archive.Record, want: []const u8) !void {
    var d = Diag.init(e.a());
    try t.expectError(error.Refused, git_archive.recordFile(e.a(), &d, m, old));
    try t.expectEqualStrings(want, d.msgs.items[0]);
    try kit.sweepOomRefusal(RecordCall{ .m = m, .old = old });
}

test "archive: GitHub's archive that holds exactly cargo's checkout is recorded with its sha256, size and top directory; a recorded row that still matches is kept" {
    var e = Env.init();
    defer e.deinit();
    const saved = git_archive.fetcher;
    defer git_archive.fetcher = saved;
    git_archive.fetcher = &fakeFetch;
    serve_error = false;
    var c = try Checkout.create(&e);
    defer c.tmp.cleanup();
    try c.tmp.dir.symLink("src/lib.rs", "lib-link.rs", .{});
    const link = kit.TarEntry{ .path = "r-" ++ REV ++ "/lib-link.rs", .link = "src/lib.rs" };
    served = try archiveOf(&e, "r-" ++ REV, &.{link}, null, 0);
    const m = try c.map(&e);
    var d = Diag.init(e.a());
    downloads = 0;
    const text = (try git_archive.recordFile(e.a(), &d, &m, null)).text;
    const want = try std.fmt.allocPrint(e.a(), git_archive.header ++ "github.com/o/r " ++ REV ++ " {s} {d} r-" ++ REV ++ "\n", .{ try sha(&e, served), served.len });
    try t.expectEqualStrings(want, text);
    try t.expectEqual(@as(usize, 1), downloads);
    try t.expectEqualStrings("https://github.com/o/r/archive/" ++ REV ++ ".tar.gz", asked);
    // two repositories: one line each, in order
    var two = try c.map(&e);
    const q = (try git_source.judge(e.a(), "git+https://github.com/o/q?rev=" ++ REV ++ "#" ++ REV)).ok;
    try two.put("github.com/o/q@" ++ REV, .{ .git = q, .dir = c.dir });
    const both = (try git_archive.recordFile(e.a(), &d, &two, null)).text;
    try t.expect(std.mem.indexOf(u8, both, "github.com/o/q ").? < std.mem.indexOf(u8, both, "github.com/o/r ").?);
    // the same archive against its own record
    const again = try git_archive.recordFile(e.a(), &d, &m, try record(&e, text));
    try t.expectEqualStrings(text, again.text);
    try t.expectEqualStrings(try sha(&e, served), again.rows.get("github.com/o/r@" ++ REV).?.sha256);
    try kit.sweepOom(RecordCall{ .m = &m, .old = try record(&e, text) }, false);
}

test "archive: the archive of a recorded commit with another sha256 or size is refused by name, and nothing is rewritten" {
    var e = Env.init();
    defer e.deinit();
    const saved = git_archive.fetcher;
    defer git_archive.fetcher = saved;
    git_archive.fetcher = &fakeFetch;
    serve_error = false;
    var c = try Checkout.create(&e);
    defer c.tmp.cleanup();
    const m = try c.map(&e);
    // the same files, archived again at another time: other bytes
    served = try archiveOf(&e, "r-" ++ REV, &.{}, null, 7);
    const old = try record(&e, "github.com/o/r " ++ REV ++ " " ++ H ++ " 77 r-" ++ REV ++ "\n");
    try recordRefused(&e, &m, old, try std.fmt.allocPrint(e.a(), "git: github.com/o/r at " ++ REV ++ ": the archive https://github.com/o/r/archive/" ++ REV ++ ".tar.gz now has sha256 {s} ({d} bytes), " ++
        "but third_party/buildrules/git_archives.tsv records sha256 " ++ H ++ " (77 bytes). The archive of a pinned commit changed, so it is refused: find out why, and only then delete its line and run `buildrules sync`", .{ try sha(&e, served), served.len }));
    // the same sha256 with another size is the same refusal
    const same_sha = try record(&e, try std.fmt.allocPrint(e.a(), "github.com/o/r " ++ REV ++ " {s} 1 r-" ++ REV ++ "\n", .{try sha(&e, served)}));
    var d = Diag.init(e.a());
    try t.expectError(error.Refused, git_archive.recordFile(e.a(), &d, &m, same_sha));
    try refusedWith(&d, "The archive of a pinned commit changed");
    // a download that fails names the archive
    serve_error = true;
    try recordRefused(&e, &m, null, "git: github.com/o/r at " ++ REV ++ ": cannot download https://github.com/o/r/archive/" ++ REV ++ ".tar.gz: ConnectionRefused");
    serve_error = false;
}

test "archive: an archive that is not cargo's checkout of the commit (a submodule, export-ignore, export-subst, another link) is refused with the paths" {
    var e = Env.init();
    defer e.deinit();
    const saved = git_archive.fetcher;
    defer git_archive.fetcher = saved;
    git_archive.fetcher = &fakeFetch;
    serve_error = false;
    var c = try Checkout.create(&e);
    defer c.tmp.cleanup();
    const m = try c.map(&e);
    const top = "r-" ++ REV;
    const lead = "git: github.com/o/r at " ++ REV ++ ": the archive https://github.com/o/r/archive/" ++ REV ++ ".tar.gz is not cargo's checkout of the commit (";
    const tail = "). A submodule, or an export-ignore or export-subst attribute in .gitattributes, makes GitHub's archive differ from the commit; such a source is refused";
    // a submodule: its files are in the checkout and not in the archive
    try c.tmp.dir.makePath("vendor/sm");
    try c.tmp.dir.writeFile(.{ .sub_path = "vendor/sm/x.c", .data = "int x;\n" });
    served = try archiveOf(&e, top, &.{}, null, 0);
    try recordRefused(&e, &m, null, lead ++ "vendor/sm/x.c is in the checkout and not in the archive" ++ tail);
    try c.tmp.dir.deleteTree("vendor");
    // export-ignore: a file of the commit is missing from the archive
    served = try archiveOf(&e, top, &.{}, "sub/Cargo.toml", 0);
    try recordRefused(&e, &m, null, lead ++ "sub/Cargo.toml is in the checkout and not in the archive" ++ tail);
    // export-subst: the archive's copy differs
    served = try archiveOf(&e, top, &.{.{ .path = top ++ "/VERSION", .data = "$Format:%H$" }}, null, 0);
    try c.tmp.dir.writeFile(.{ .sub_path = "VERSION", .data = REV });
    try recordRefused(&e, &m, null, lead ++ "VERSION differs" ++ tail);
    try c.tmp.dir.deleteFile("VERSION");
    // a file only the archive has
    served = try archiveOf(&e, top, &.{.{ .path = top ++ "/extra.txt", .data = "x" }}, null, 0);
    try recordRefused(&e, &m, null, lead ++ "extra.txt is in the archive and not in the checkout" ++ tail);
    // links: another target, a link where the checkout has a file, a file where it has a link
    try c.tmp.dir.symLink("src/lib.rs", "l1", .{});
    try c.tmp.dir.writeFile(.{ .sub_path = "l2", .data = "a file" });
    try c.tmp.dir.symLink("Cargo.toml", "l3", .{});
    served = try archiveOf(&e, top, &.{
        .{ .path = top ++ "/l1", .link = "Cargo.toml" },
        .{ .path = top ++ "/l2", .link = "src/lib.rs" },
        .{ .path = top ++ "/l3", .data = "a file" },
        .{ .path = top ++ "/l4", .data = "four" },
    }, null, 0);
    try recordRefused(&e, &m, null, lead ++ "l1 links to Cargo.toml in the archive and to src/lib.rs in the checkout; l2 is a symbolic link in the archive and not one in the checkout; " ++
        "l3 is a file in the archive and a symbolic link in the checkout; and 1 more" ++ tail);
}

test "archive: an archive that is not one plain directory of a gzip tar is refused" {
    var e = Env.init();
    defer e.deinit();
    const saved = git_archive.fetcher;
    defer git_archive.fetcher = saved;
    git_archive.fetcher = &fakeFetch;
    serve_error = false;
    var c = try Checkout.create(&e);
    defer c.tmp.cleanup();
    const m = try c.map(&e);
    const what = "git: github.com/o/r at " ++ REV ++ ": ";
    served = "not a gzip stream";
    var d = Diag.init(e.a());
    try t.expectError(error.Refused, git_archive.recordFile(e.a(), &d, &m, null));
    try refusedWith(&d, what ++ "the archive is not a gzip tar (");
    served = try archiveOf(&e, "r-" ++ REV, &.{.{ .path = "other/x", .data = "x" }}, null, 0);
    try recordRefused(&e, &m, null, what ++ "the archive has more than one top directory (r-" ++ REV ++ ", other)");
    served = try kit.tarGz(e.a(), &.{.{ .path = "/x", .data = "x" }}, 0);
    try recordRefused(&e, &m, null, what ++ "the archive's top directory `` is not a plain name");
    served = try kit.tarGz(e.a(), &.{.{ .path = ".hidden/x", .data = "x" }}, 0);
    try recordRefused(&e, &m, null, what ++ "the archive's top directory `.hidden` is not a plain name");
    served = try kit.tarGz(e.a(), &.{ .{ .path = "r/" }, .{ .path = "r/../../etc/x", .data = "x" } }, 0);
    try recordRefused(&e, &m, null, what ++ "the archive holds the path r/../../etc/x, which is not a plain relative path");
    served = try kit.tarGz(e.a(), &.{ .{ .path = "r/" }, .{ .path = "r/./x", .data = "x" } }, 0);
    try recordRefused(&e, &m, null, what ++ "the archive holds the path r/./x, which is not a plain relative path");
    served = try kit.tarGz(e.a(), &.{ .{ .path = "r/" }, .{ .path = "r/a//x", .data = "x" } }, 0);
    try recordRefused(&e, &m, null, what ++ "the archive holds the path r/a//x, which is not a plain relative path");
    served = try kit.tarGz(e.a(), &.{}, 0);
    try recordRefused(&e, &m, null, what ++ "the archive is empty");
    // a tar cut short in a file's bytes
    const whole = try archiveOf(&e, "r-" ++ REV, &.{}, null, 0);
    served = try cutTar(&e, whole);
    var d2 = Diag.init(e.a());
    try t.expectError(error.Refused, git_archive.recordFile(e.a(), &d2, &m, null));
    try refusedWith(&d2, what ++ "the archive is cut short in r-" ++ REV ++ "/Cargo.toml (");
    // a checkout that is gone
    var m2 = try c.map(&e);
    const gone = try std.fmt.allocPrint(e.a(), "{s}/gone", .{c.dir});
    m2.getPtr("github.com/o/r@" ++ REV).?.dir = gone;
    served = whole;
    try recordRefused(&e, &m2, null, try std.fmt.allocPrint(e.a(), what ++ "cannot open cargo's checkout {s}: FileNotFound", .{gone}));
}

/// The tar inside `gz`, cut in the middle of its first file's bytes, gzipped again.
fn cutTar(e: *Env, gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    const window = try e.a().alloc(u8, std.compress.flate.max_window_len);
    var dz = std.compress.flate.Decompress.init(&in, .gzip, window);
    const tar = try dz.reader.allocRemaining(e.a(), .unlimited);
    // pax global header (2 blocks), the top directory, src/ (1 each), then the first file's header and its data block
    return kit.gzipStored(e.a(), tar[0 .. 512 * 5 + 7]);
}

/// A fetcher that answers every URL with `bytes`, in two writes.
const Canned = struct {
    bytes: []const u8,
    fn get(ctx: *anyopaque, _: []const u8, sink: fetch.Sink) anyerror!void {
        const self: *Canned = @ptrCast(@alignCast(ctx));
        try sink.write(self.bytes[0 .. self.bytes.len / 2]);
        try sink.write(self.bytes[self.bytes.len / 2 ..]);
    }
    fn fetcher(self: *Canned) fetch.Fetcher {
        return .{ .ctx = self, .getFn = get };
    }
};

test "archive: a download is the whole body the fetcher answers, and a body over the limit is refused" {
    var e = Env.init();
    defer e.deinit();
    var c = Canned{ .bytes = "the bytes of an archive" };
    try t.expectEqualStrings("the bytes of an archive", try git_archive.bodyOf(e.a(), c.fetcher(), "https://github.com/o/r/archive/x.tar.gz", 64));
    try t.expectError(error.ResponseTooLarge, git_archive.bodyOf(e.a(), c.fetcher(), "https://github.com/o/r/archive/x.tar.gz", 5));
}

test "archive: the fetcher the program starts with reaches only https" {
    var e = Env.init();
    defer e.deinit();
    // every test that replaces the fetcher puts this one back
    try t.expectError(error.UrlNotAllowed, git_archive.fetcher(e.a(), "http://example.invalid/r.tar.gz"));
}

// ---- check: Cargo.lock and the table against the record -----------------------------------------------------------

/// The lines of a table that hold a git unit's commit (what `git_archive.tableCommits` reads).
fn tableWith(comptime repo: []const u8, comptime rev: []const u8) []const u8 {
    return "UNITS = {\n    \"r-0.1.0:0123456789\": {\n        \"crate\": \"r\",\n        \"repo\": \"" ++ repo ++ "\",\n        \"rev\": \"" ++ rev ++ "\",\n        \"subdir\": \"\",\n    },\n}\n";
}

fn checked(h: *kit.Harness, lock: []const u8, table: []const u8, rec: ?[]const u8) !kit.Run {
    try h.put("Cargo.lock", lock);
    try h.put("buildrules.lock.bzl", table);
    if (rec) |r| try h.put("third_party/buildrules/git_archives.tsv", r);
    return h.run(&.{"check"});
}

test "check: a commit Cargo.lock moved since the sync is named with the commit it moved from" {
    const h = try kit.Harness.create();
    defer h.destroy();
    const r = try checked(h, lockFor("git+https://github.com/o/r?rev=" ++ REV2 ++ "#" ++ REV2), tableWith("github.com/o/r", REV), "github.com/o/r " ++ REV ++ " " ++ H ++ " 1 r-" ++ REV ++ "\n");
    try t.expectEqual(@as(u8, 1), r.code);
    const moved = "STALE: r 0.1.0: Cargo.lock moved github.com/o/r from commit " ++ REV ++ " to " ++ REV2 ++
        " since `buildrules sync`, and third_party/buildrules/git_archives.tsv records no archive of " ++ REV2 ++ ": run `buildrules sync` and commit the result";
    try t.expect(kit.contains(r.err, moved));
    try t.expect(kit.contains(r.err, "STALE: rsub 0.2.0: Cargo.lock moved github.com/o/r from commit " ++ REV ++ " to " ++ REV2));
    // the old row is the table's commit: said once, as the move
    try t.expect(!kit.contains(r.err, "which no unit of"));
}

test "check: a git package no unit uses (another platform's) needs no archive, and an unused row is stale" {
    const h = try kit.Harness.create();
    defer h.destroy();
    // the lock has a pinned git package, the table has no git unit: nothing to record
    var r = try checked(h, lock_git, "UNITS = {}\n", null);
    try t.expect(!kit.contains(r.err, "git_archives.tsv"));
    try t.expect(!kit.contains(r.err, "git source"));
    // a row for a commit the table does not use is stale, even when the repository has another commit in use
    r = try checked(h, lock_git, tableWith("github.com/o/r", REV), "github.com/o/r " ++ REV ++ " " ++ H ++ " 1 r-" ++ REV ++ "\ngithub.com/o/r " ++ REV2 ++ " " ++ H ++ " 1 r-" ++ REV2 ++ "\n");
    try t.expect(kit.contains(r.err, "STALE: third_party/buildrules/git_archives.tsv records github.com/o/r at " ++ REV2 ++ ", which no unit of buildrules.lock.bzl comes from: run `buildrules sync` and commit the result"));
    try t.expect(!kit.contains(r.err, "at " ++ REV ++ ", which"));
    // beside a recorded one, a pinned git package no unit uses and nothing records is not reported either
    const two = lock_git ++ "\n[[package]]\nname = \"q\"\nversion = \"1.0.0\"\nsource = \"git+https://github.com/o/q?rev=" ++ REV2 ++ "#" ++ REV2 ++ "\"\n";
    try h.tmp.dir.deleteFile("third_party/buildrules/git_archives.tsv");
    r = try checked(h, two, tableWith("github.com/o/r", REV), "github.com/o/r " ++ REV ++ " " ++ H ++ " 1 r-" ++ REV ++ "\n");
    try t.expect(!kit.contains(r.err, "git_archives.tsv"));
    try t.expect(!kit.contains(r.err, "q 1.0.0"));
}

test "check: an unpinned git source, a missing or left-over record, an unrecorded commit and a bad record are each reported" {
    const h = try kit.Harness.create();
    defer h.destroy();
    var r = try checked(h, lockFor("git+https://github.com/o/r?branch=main#" ++ REV), "UNITS = {}\n", null);
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "r 0.1.0: the git source git+https://github.com/o/r?branch=main follows branch `main`, which can move"));
    try t.expect(kit.contains(r.err, "rsub 0.2.0: the git source git+https://github.com/o/r?branch=main follows branch `main`"));
    const table = tableWith("github.com/o/r", REV);
    r = try checked(h, lock_git, table, null);
    try t.expect(kit.contains(r.err, "STALE: buildrules.lock.bzl has git units and third_party/buildrules/git_archives.tsv is missing: run `buildrules sync` and commit the result"));
    r = try checked(h, lock_git, table, "github.com/o/q " ++ REV ++ " " ++ H ++ " 1 q-" ++ REV ++ "\n");
    try t.expect(kit.contains(r.err, "STALE: r 0.1.0: third_party/buildrules/git_archives.tsv records no archive of github.com/o/r at " ++ REV));
    try t.expect(kit.contains(r.err, "STALE: third_party/buildrules/git_archives.tsv records github.com/o/q at " ++ REV ++ ", which no unit of buildrules.lock.bzl comes from"));
    r = try checked(h, lock_git, table, "github.com/o/r " ++ REV ++ "\n");
    try t.expect(kit.contains(r.err, "git: third_party/buildrules/git_archives.tsv:1: not `repository commit sha256 bytes top-directory`"));
    // recorded: nothing about git
    r = try checked(h, lock_git, table, "github.com/o/r " ++ REV ++ " " ++ H ++ " 1 r-" ++ REV ++ "\n");
    try t.expect(!kit.contains(r.err, "git_archives.tsv"));
    try t.expect(!kit.contains(r.err, "git source"));
    // no git unit left
    r = try checked(h, "version = 4\n\n[[package]]\nname = \"app\"\nversion = \"0.1.0\"\n", "UNITS = {}\n", null);
    try t.expect(kit.contains(r.err, "STALE: third_party/buildrules/git_archives.tsv is left from git sources the table no longer has: run `buildrules sync` and commit the result"));
    // a Cargo.lock buildrules cannot read is said (by the lock reader) whatever the record
    r = try checked(h, "version = 2\n", table, null);
    try t.expect(kit.contains(r.err, "Cargo.lock: lock version 2 is not 3 or 4"));
}

test "table commits: the repo and rev lines of each git unit, and nothing from a line between them" {
    var e = Env.init();
    defer e.deinit();
    const text = comptime tableWith("github.com/o/r", REV) ++ "    \"repo\": \"github.com/a/b\",\n    \"crate\": \"x\",\n    \"rev\": \"" ++ REV2 ++ "\",\n    \"rev\": \"" ++ REV2 ++ "\",\n    \"repo\": bad\n    \"repo\": x\n    \"rev\": \"\n";
    const c = try git_archive.tableCommits(e.a(), text);
    try t.expectEqual(@as(usize, 1), c.count());
    try t.expect(c.contains("github.com/o/r@" ++ REV));
}
