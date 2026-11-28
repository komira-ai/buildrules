//! cargo_walk.zig: the manifest cargo takes for a package of a git checkout that holds several manifests of it. Each case is an
//! archive's entries (below its top directory) and the directory `pick` gives, against what cargo 0.96.0's walk of the same
//! checkout takes (src/cargo/sources/path.rs, `read_packages`).

const std = @import("std");
const cw = @import("cargo_walk.zig");
const kit = @import("testkit.zig");
const Entry = @import("sources.zig").Entry;
const t = std.testing;

const lib = "pub fn x() {}\n";

fn file(rel: []const u8, data: []const u8) Entry {
    return .{ .rel = rel, .kind = .file, .data = data };
}

fn link(rel: []const u8, target: []const u8) Entry {
    return .{ .rel = rel, .kind = .link, .data = target };
}

fn dir(rel: []const u8) Entry {
    return .{ .rel = rel, .kind = .dir };
}

/// `[package]` of `name` at version 0.1.0.
inline fn pkg(comptime name: []const u8) []const u8 {
    return "[package]\nname = \"" ++ name ++ "\"\nversion = \"0.1.0\"\n";
}

/// `first` and then `rest`.
fn with(a: std.mem.Allocator, first: []const Entry, rest: []const Entry) ![]const Entry {
    return std.mem.concat(a, Entry, &.{ first, rest });
}

fn pickIn(a: std.mem.Allocator, entries: []const Entry, name: []const u8, version: []const u8) !cw.Pick {
    var c = try cw.Checkout.init(a, entries);
    return c.pick(name, version);
}

fn expectDir(want: []const u8, got: cw.Pick) !void {
    switch (got) {
        .dir => |d| try t.expectEqualStrings(want, d),
        else => {
            std.debug.print("expected the directory `{s}`, got {any}\n", .{ want, got });
            return error.TestUnexpectedResult;
        },
    }
}

fn expectUnsure(want: []const []const u8, got: cw.Pick) !void {
    switch (got) {
        .unsure => |dirs| {
            try t.expectEqual(want.len, dirs.len);
            for (want, dirs) |w, d| try t.expectEqualStrings(w, d);
        },
        else => {
            std.debug.print("expected unsure, got {any}\n", .{got});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectMissing(got: cw.Pick) !void {
    try t.expect(got == .missing);
}

test "pick: of two manifests of a package, the one cargo's walk meets first: a directory before those below it, names in byte order, depth first" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    // the root before a directory below it
    try expectDir("", try pickIn(a, &.{
        file("copy/Cargo.toml", pkg("p")), file("copy/src/lib.rs", lib),
        file("Cargo.toml", pkg("p")),      file("src/lib.rs", lib),
    }, "p", "0.1.0"));
    // by whole names: `a` (and what is below it) before `a-b`, although `a-b/` sorts before `a/c` as one string
    try expectDir("a/c", try pickIn(a, &.{
        file("a-b/Cargo.toml", pkg("p")), file("a-b/src/lib.rs", lib),
        file("a/c/Cargo.toml", pkg("p")), file("a/c/src/lib.rs", lib),
    }, "p", "0.1.0"));
    // bytes: an upper-case name before a lower-case one
    try expectDir("B", try pickIn(a, &.{
        file("a/Cargo.toml", pkg("p")), file("a/src/lib.rs", lib),
        file("B/Cargo.toml", pkg("p")), file("B/src/lib.rs", lib),
    }, "p", "0.1.0"));
    // depth first: everything below `a` before `b`
    try expectDir("a/z/y", try pickIn(a, &.{
        file("b/Cargo.toml", pkg("p")),     file("b/src/lib.rs", lib),
        file("a/z/y/Cargo.toml", pkg("p")), file("a/z/y/src/lib.rs", lib),
    }, "p", "0.1.0"));
    // a crate and a test fixture's copy of it below another crate's tests, the copy listed first in the archive; directories
    // listed explicitly, one after what is below it
    try expectDir("crates/p", try pickIn(a, &.{
        file("crates/xtask/tests/fixtures/clean/Cargo.toml", "[workspace]\nmembers = [\"crates/*\"]\n"),
        file("crates/xtask/tests/fixtures/clean/crates/p/Cargo.toml", pkg("p")),
        file("crates/xtask/tests/fixtures/clean/crates/p/src/lib.rs", lib),
        file("crates/xtask/Cargo.toml", pkg("xtask")),
        file("crates/xtask/src/main.rs", lib),
        file("crates/p/Cargo.toml", pkg("p")),
        file("crates/p/src/lib.rs", lib),
        dir("crates/p"),
        dir("crates"),
        file("Cargo.toml", "[workspace]\nmembers = [\"crates/*\"]\n"),
    }, "p", "0.1.0"));
}

test "pick: cargo reads a package's path dependencies when it meets the package, before walking on: tables in cargo's order, names in order" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const copies = [_]Entry{
        file("b/p/Cargo.toml", pkg("p")), file("b/p/src/lib.rs", lib),
        file("m/p/Cargo.toml", pkg("p")), file("m/p/src/lib.rs", lib),
        file("n/p/Cargo.toml", pkg("p")), file("n/p/src/lib.rs", lib),
    };
    // `a`, met first, depends on n/p: n/p is read before the walk reaches b/p
    try expectDir("n/p", try pickIn(a, try with(a, &.{file("a/Cargo.toml", pkg("a") ++ "\n[dependencies]\np = { path = \"./../n/p\" }\n")}, &copies), "p", "0.1.0"));
    // build-dependencies before dev-dependencies, whatever their order in the file and the names of the dependencies
    try expectDir("n/p", try pickIn(a, try with(a, &.{file("a/Cargo.toml", pkg("a") ++ "\n[dev-dependencies]\nm = { path = \"../m/p\" }\n\n[build-dependencies]\nn = { path = \"../n/p\" }\n")}, &copies), "p", "0.1.0"));
    // within one table, by name
    try expectDir("n/p", try pickIn(a, try with(a, &.{file("a/Cargo.toml", pkg("a") ++ "\n[dependencies]\nzz = { path = \"../m/p\" }\naa = { path = \"../n/p\" }\n")}, &copies), "p", "0.1.0"));
    // the tables of a target after the manifest's own, and the targets by name
    try expectDir("m/p", try pickIn(a, try with(a, &.{file("a/Cargo.toml", pkg("a") ++ "\n[target.zz.dependencies]\nx = { path = \"../n/p\" }\n\n[target.aa.dev-dependencies]\nx = { path = \"../m/p\" }\n")}, &copies), "p", "0.1.0"));
    // a dependency inherited from the workspace, at the workspace's path
    try expectDir("n/p", try pickIn(a, try with(a, &.{
        file("Cargo.toml", "[workspace]\nmembers = [\"a\"]\n\n[workspace.dependencies]\np = { path = \"n/p\" }\n"),
        file("a/Cargo.toml", pkg("a") ++ "\n[dependencies]\np.workspace = true\n"),
    }, &copies), "p", "0.1.0"));
    // dependencies that lead nowhere cargo reads a package from are passed over, and the walk goes on to b/p
    try expectDir("b/p", try pickIn(a, try with(a, &.{
        file("Cargo.toml", "[workspace]\nmembers = [\"a\", \"c\"]\n\n[workspace.dependencies]\ns = \"1\"\n"),
        file("a/Cargo.toml", "target = 1\n" ++ pkg("a") ++
            \\
            \\[dependencies]
            \\out = { path = "../../out" }
            \\abs = { path = "/abs/p" }
            \\none = { path = "../nothing" }
            \\virt = { path = ".." }
            \\s = { workspace = true }
            \\gone = { workspace = true }
            \\plain = "1"
            \\off = { workspace = false }
            \\odd = { workspace = "x" }
            \\
        ),
        file("c/Cargo.toml", "dependencies = 1\n" ++ pkg("c") ++ "\n[target.x]\ndependencies = 2\n"),
        file("c/n/Cargo.toml", pkg("c-n") ++ "\n[dependencies]\nv = { workspace = true }\n"),
    }, &copies), "p", "0.1.0"));
    // a dependency inherited with no workspace in the archive leads nowhere
    try expectDir("b/p", try pickIn(a, try with(a, &.{file("a/Cargo.toml", pkg("a") ++ "\n[dependencies]\np.workspace = true\n")}, &copies), "p", "0.1.0"));
    // the older underscore spelling of a table is read when the hyphen one is absent, and passed over when it is there
    try expectDir("n/p", try pickIn(a, try with(a, &.{file("a/Cargo.toml", pkg("a") ++ "\n[dev_dependencies]\nn = { path = \"../n/p\" }\n")}, &copies), "p", "0.1.0"));
    try expectDir("b/p", try pickIn(a, try with(a, &.{file("a/Cargo.toml", pkg("a") ++ "\n[build-dependencies]\n\n[build_dependencies]\nn = { path = \"../n/p\" }\n")}, &copies), "p", "0.1.0"));
    // a directory reached twice is read once
    try expectDir("n/p", try pickIn(a, try with(a, &.{
        file("a/Cargo.toml", pkg("a") ++ "\n[dependencies]\nn = { path = \"../n/p\" }\nn2 = { path = \"../n/p/\" }\n"),
    }, &copies), "p", "0.1.0"));
}

test "pick: the directories cargo's walk does not enter hold no package it meets, unless a path dependency leads there" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try expectMissing(try pickIn(a, &.{ file(".hidden/Cargo.toml", pkg("p")), file(".hidden/src/lib.rs", lib) }, "p", "0.1.0"));
    try expectMissing(try pickIn(a, &.{ file("sub/.git", "gitdir: x\n"), file("sub/Cargo.toml", pkg("p")) }, "p", "0.1.0"));
    try expectMissing(try pickIn(a, &.{ file("w/Cargo.toml", pkg("w")), file("w/target/Cargo.toml", pkg("p")) }, "p", "0.1.0"));
    try expectMissing(try pickIn(a, &.{ file("Cargo.toml", pkg("w")), file("target/p/Cargo.toml", pkg("p")) }, "p", "0.1.0"));
    // a `target` with no manifest beside it is walked
    try expectDir("t/target", try pickIn(a, &.{file("t/target/Cargo.toml", pkg("p"))}, "p", "0.1.0"));
    // a symbolic link to a directory is not walked: the package is where the directory is
    try expectDir("real", try pickIn(a, &.{ link("alias", "real"), file("real/Cargo.toml", pkg("p")) }, "p", "0.1.0"));
    // a path dependency into a hidden directory is read
    try expectDir(".hidden", try pickIn(a, &.{
        file("a/Cargo.toml", pkg("a") ++ "\n[dependencies]\np = { path = \"../.hidden\" }\n"),
        file(".hidden/Cargo.toml", pkg("p")),
    }, "p", "0.1.0"));
}

test "pick: Cargo.lock's version tells apart packages of one name: written, inherited from the workspace cargo finds, or absent (0.0.0)" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const versions = [_]Entry{
        file("a/Cargo.toml", "[package]\nname = \"p\"\nversion = \"0.2.0\"\n"),
        file("b/Cargo.toml", pkg("p")),
        file("c/Cargo.toml", "[package]\nname = \"q\"\n"),
    };
    try expectDir("b", try pickIn(a, &versions, "p", "0.1.0"));
    try expectDir("a", try pickIn(a, &versions, "p", "0.2.0"));
    try expectMissing(try pickIn(a, &versions, "p", "0.3.0"));
    try expectDir("c", try pickIn(a, &versions, "q", "0.0.0"));
    try expectMissing(try pickIn(a, &versions, "q", "1.0.0"));
    try expectMissing(try pickIn(a, &versions, "nobody", "0.1.0"));

    const inherit = "[package]\nname = \"r\"\nversion.workspace = true\n";
    const ws = [_]Entry{
        // the root workspace excludes ex/ and fx/, but lists ex/keep
        file("Cargo.toml", "[workspace]\nmembers = [\"m\", \"ex/keep\", 1]\nexclude = [\"ex/\", \"fx\", 2]\n\n[workspace.package]\nversion = \"1.0.0\"\n"),
        file("m/Cargo.toml", inherit),
        file("ex/keep/Cargo.toml", inherit),
        file("fxx/Cargo.toml", inherit),
        // fx is a workspace of its own, nearer than the root
        file("fx/Cargo.toml", "[workspace]\n\n[workspace.package]\nversion = \"2.0.0\"\n"),
        file("fx/s/Cargo.toml", inherit),
        // its own workspace
        file("own/Cargo.toml", inherit ++ "\n[workspace]\n\n[workspace.package]\nversion = \"3.0.0\"\n"),
        // the workspace package.workspace names
        file("named/w/Cargo.toml", "[workspace]\n\n[workspace.package]\nversion = \"4.0.0\"\n"),
        file("named/r/Cargo.toml", inherit ++ "workspace = \"../w\"\n"),
        // a package above that names its workspace by package.workspace gives it to the packages below
        file("pt/Cargo.toml", "[package]\nname = \"pt\"\nworkspace = \"../named/w\"\n"),
        file("pt/s/Cargo.toml", "[package]\nname = \"r4\"\nversion.workspace = true\n"),
        // an exclude of "." excludes everything below that workspace: the root's is taken
        file("fy/Cargo.toml", "[workspace]\nexclude = [\".\"]\n\n[workspace.package]\nversion = \"6.0.0\"\n"),
        file("fy/s/Cargo.toml", "[package]\nname = \"r3\"\nversion.workspace = true\n"),
    };
    try expectUnsure(&.{ "ex/keep", "fxx", "m" }, try pickIn(a, &ws, "r", "1.0.0"));
    try expectDir("fx/s", try pickIn(a, &ws, "r", "2.0.0"));
    try expectDir("own", try pickIn(a, &ws, "r", "3.0.0"));
    try expectDir("named/r", try pickIn(a, &ws, "r", "4.0.0"));
    try expectMissing(try pickIn(a, &ws, "r", "9.9.9"));
    try expectDir("pt/s", try pickIn(a, &ws, "r4", "4.0.0"));
    try expectMissing(try pickIn(a, &ws, "r4", "1.0.0"));
    try expectDir("fy/s", try pickIn(a, &ws, "r3", "1.0.0"));
    try expectMissing(try pickIn(a, &ws, "r3", "6.0.0"));

    // no workspace cargo would take, so no version to tell packages apart by: the one manifest of the name is taken whatever
    // Cargo.lock's version (a second one would make it unsure): a member the root excludes, and package.workspace that leaves the
    // archive, names a directory with no manifest, or names a package that is not a workspace
    const lone = [_]Entry{
        file("Cargo.toml", "[workspace]\nexclude = [\"ex\"]\n\n[workspace.package]\nversion = \"1.0.0\"\n"),
        file("ex/other/Cargo.toml", "[package]\nname = \"s0\"\nversion.workspace = true\n"),
        file("x/Cargo.toml", "[package]\nname = \"s1\"\nversion.workspace = true\nworkspace = \"../../out\"\n"),
        file("y/Cargo.toml", "[package]\nname = \"s2\"\nversion.workspace = true\nworkspace = \"../nothing\"\n"),
        file("z/Cargo.toml", "[package]\nname = \"s3\"\nversion.workspace = true\nworkspace = \"../y\"\n"),
    };
    for ([_][]const u8{ "s0", "s1", "s2", "s3" }, [_][]const u8{ "ex/other", "x", "y", "z" }) |name, want| {
        try expectDir(want, try pickIn(a, &lone, name, "7.7.7"));
    }
}

test "pick: two manifests remain and buildrules cannot show that cargo reads the one it meets first: unsure, every manifest named in cargo's order" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const second = [_]Entry{ file("b/Cargo.toml", pkg("p")), file("b/src/lib.rs", lib) };
    const root = file("Cargo.toml", "[workspace]\nmembers = [\"a\", \"b\"]\n\n[workspace.package]\nversion = \"0.1.0\"\n\n[workspace.dependencies]\nhere = \"1\"\n");
    // no target in the archive: no src/lib.rs or src/main.rs, a [lib] path that is not there, a [[bin]] path out of the archive
    try expectUnsure(&.{ "a", "b" }, try pickIn(a, try with(a, &.{file("a/Cargo.toml", pkg("p") ++ "\n[lib]\npath = \"gone.rs\"\n\n[[bin]]\nname = \"x\"\npath = \"../../x.rs\"\n")}, &second), "p", "0.1.0"));
    // a key inherited from a workspace that does not have it
    try expectUnsure(&.{ "a", "b" }, try pickIn(a, try with(a, &.{ root, file("a/Cargo.toml", pkg("p") ++ "edition.workspace = true\n"), file("a/src/lib.rs", lib) }, &second), "p", "0.1.0"));
    // a dependency inherited from a workspace that does not have it (in a target's table)
    try expectUnsure(&.{ "a", "b" }, try pickIn(a, try with(a, &.{ root, file("a/Cargo.toml", pkg("p") ++ "\n[target.x.dependencies]\nhere.workspace = true\nthere.workspace = true\n\n[target.y]\ndependencies = 1\n"), file("a/src/lib.rs", lib) }, &second), "p", "0.1.0"));
    // a version inherited with no workspace above, or one cargo does not take
    try expectUnsure(&.{ "a", "b" }, try pickIn(a, try with(a, &.{ file("a/Cargo.toml", "[package]\nname = \"p\"\nversion.workspace = true\n"), file("a/src/lib.rs", lib) }, &second), "p", "0.1.0"));
    try expectUnsure(&.{ "a", "b" }, try pickIn(a, try with(a, &.{ file("a/Cargo.toml", "[package]\nname = \"p\"\nversion = 1\n"), file("a/src/lib.rs", lib) }, &second), "p", "0.1.0"));
    // a workspace version that is not a string
    try expectUnsure(&.{ "a", "b" }, try pickIn(a, try with(a, &.{ file("Cargo.toml", "[workspace]\n\n[workspace.package]\nversion = 1\n"), file("a/Cargo.toml", "[package]\nname = \"p\"\nversion.workspace = true\n"), file("a/src/lib.rs", lib) }, &second), "p", "0.1.0"));
    // three manifests: all three named
    try expectUnsure(&.{ "a", "b", "c" }, try pickIn(a, try with(a, &.{ file("a/Cargo.toml", pkg("p")), file("c/Cargo.toml", pkg("p")) }, &second), "p", "0.1.0"));
    // the first plainly read, the second not: the first is cargo's
    try expectDir("b", try pickIn(a, try with(a, &.{file("c/Cargo.toml", pkg("p"))}, &second), "p", "0.1.0"));
    // with everything it inherits in the workspace, the first is cargo's
    try expectDir("a", try pickIn(a, try with(a, &.{ root, file("a/Cargo.toml", "[package]\nname = \"p\"\nversion.workspace = true\n\n[dependencies]\nhere.workspace = true\n"), file("a/src/lib.rs", lib) }, &second), "p", "0.1.0"));
    // one manifest of the package is taken although buildrules cannot show cargo reads it: there is nothing to choose between
    try expectDir("a", try pickIn(a, &.{file("a/Cargo.toml", pkg("p"))}, "p", "0.1.0"));
}

test "pick: a target is plain from src/main.rs, a [lib] path or a [[bin]] path in the archive" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const second = [_]Entry{ file("b/Cargo.toml", pkg("p")), file("b/src/lib.rs", lib) };
    try expectDir("a", try pickIn(a, try with(a, &.{ file("a/Cargo.toml", "target = 1\n" ++ pkg("p")), file("a/src/main.rs", lib) }, &second), "p", "0.1.0"));
    try expectDir("a", try pickIn(a, try with(a, &.{ file("a/Cargo.toml", pkg("p") ++ "\n[lib]\npath = \"l.rs\"\n"), file("a/l.rs", lib) }, &second), "p", "0.1.0"));
    try expectDir("a", try pickIn(a, try with(a, &.{ file("a/Cargo.toml", pkg("p") ++ "\n[[bin]]\nname = \"x\"\n\n[[bin]]\nname = \"y\"\npath = \"tools/y.rs\"\n"), file("a/tools/y.rs", lib) }, &second), "p", "0.1.0"));
}

test "pick: what cargo cannot read is passed over: a manifest that does not parse, a [package] that is not a table or has no name, a virtual manifest, and their path dependencies" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const copies = [_]Entry{
        file("b/p/Cargo.toml", pkg("p")), file("b/p/src/lib.rs", lib),
        file("z/p/Cargo.toml", pkg("p")), file("z/p/src/lib.rs", lib),
    };
    const dep = "\n[dependencies]\np = { path = \"../z/p\" }\n";
    try expectDir("b/p", try pickIn(a, try with(a, &.{file("a/Cargo.toml", pkg("p") ++ dep ++ "[broken\n")}, &copies), "p", "0.1.0"));
    try expectDir("b/p", try pickIn(a, try with(a, &.{file("a/Cargo.toml", "package = 1\n" ++ dep)}, &copies), "p", "0.1.0"));
    try expectDir("b/p", try pickIn(a, try with(a, &.{file("a/Cargo.toml", "[package]\nversion = \"0.1.0\"\n" ++ dep)}, &copies), "p", "0.1.0"));
    try expectDir("b/p", try pickIn(a, try with(a, &.{file("a/Cargo.toml", "[workspace]\n" ++ dep)}, &copies), "p", "0.1.0"));
}

test "pick: a manifest or a library that is a symbolic link to a file of the archive is read; a link out of it, a dangling one or a loop is no file" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try expectDir("a", try pickIn(a, &.{
        link("a/Cargo.toml", "../shared/p.toml"), link("a/src/lib.rs", "../../shared/lib.rs"),
        file("shared/p.toml", pkg("p")),          file("shared/lib.rs", lib),
        file("z/Cargo.toml", pkg("p")),           file("z/src/lib.rs", lib),
    }, "p", "0.1.0"));
    for ([_][]const u8{ "../none", "/etc/p.toml", "../../../p.toml", "Cargo.toml" }) |target| {
        try expectMissing(try pickIn(a, &.{ link("a/Cargo.toml", target), file("shared/p.toml", pkg("p")) }, "p", "0.1.0"));
    }
    try expectMissing(try pickIn(a, &.{ link("a/Cargo.toml", "Other.toml"), link("a/Other.toml", "Cargo.toml") }, "p", "0.1.0"));
}

test "normalize: `.` and `..` resolved by name; an absolute path or one that leaves the archive is null" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("a/c", (try cw.normalize(a, "a/b", "./../c/")).?);
    try t.expectEqualStrings("", (try cw.normalize(a, "a", "..")).?);
    try t.expectEqualStrings("x", (try cw.normalize(a, "", "x")).?);
    try t.expect((try cw.normalize(a, "a", "../..")) == null);
    try t.expect((try cw.normalize(a, "a", "/x")) == null);
}

/// A checkout with something of every kind `pick` reads, walked and asked with the allocator failing at each allocation.
const Sweep = struct {
    pub fn call(_: @This(), alloc: std.mem.Allocator) !bool {
        var c = cw.Checkout.init(alloc, &.{
            file("Cargo.toml", "[workspace]\nmembers = [\"crates/*\"]\nexclude = [\"fx\"]\n\n[workspace.package]\nversion = \"0.1.0\"\n\n[workspace.dependencies]\nq = { path = \"crates/q\" }\n"),
            dir("crates"),
            file("crates/p/Cargo.toml", "[package]\nname = \"p\"\nversion.workspace = true\n\n[dependencies]\nq.workspace = true\nz = { path = \"../../z/p\" }\n\n[target.x.dev-dependencies]\nw = { path = \"../w\" }\n"),
            link("crates/p/src/lib.rs", "../../../shared/lib.rs"),
            file("crates/q/Cargo.toml", pkg("q") ++ "workspace = \"../..\"\n\n[lib]\npath = \"q.rs\"\n"),
            file("crates/q/q.rs", lib),
            file("fx/Cargo.toml", "[workspace]\n"),
            file("fx/p/Cargo.toml", pkg("p")),
            file("z/p/Cargo.toml", pkg("p")),
            file("shared/lib.rs", lib),
        }) catch return false;
        const p = c.pick("p", "0.1.0") catch return false;
        const q = c.pick("q", "0.1.0") catch return false;
        const none = c.pick("none", "0.1.0") catch return false;
        return p == .dir and q == .dir and none == .missing;
    }
};

test "pick: a failed allocation anywhere in the walk or the choice ends it with an error, never with an answer" {
    try kit.sweepOom(Sweep{}, true);
}
