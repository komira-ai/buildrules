//! Unit tests of pg_prefix.zig on `.conda` files built in memory (conda_fixture.zig), written into a temporary directory.
//!
//! What is held:
//!   - every payload of every package comes out as one tree: files with 0755 when the header has an execute bit and 0644 otherwise, directories,
//!     links as links, `./` and `//` in names tidied, and what a server never reads (headers, manuals, static archives ...) is not written;
//!   - the placeholder of bin/postgres and bin/initdb is written to buildrules-placeholder.txt exactly;
//!   - a path two packages hold is kept once when the bytes agree and refused, naming both packages, when they differ;
//!   - each refusal (names, links, hard links, sizes, archives, info/paths.json, the output directory) is one exact line on stderr, exit 1, and no
//!     tree is left behind; the command line's refusals are exit 2;
//!   - every allocation failing in turn is `out of memory` and exit 1, never a leak or a half tree.

const std = @import("std");
const P = @import("pg_prefix.zig");
const fx = @import("conda_fixture.zig");
const t = std.testing;
const Ent = fx.Ent;

const ph = "/opt/cbuild/feedstock_root/build_artifacts/_h_env_placehold_placehold";

const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: t.TmpDir,

    fn init() Case {
        return .{ .arena = std.heap.ArenaAllocator.init(t.allocator), .tmp = t.tmpDir(.{ .iterate = true }) };
    }
    fn deinit(c: *Case) void {
        c.tmp.cleanup();
        c.arena.deinit();
    }
    fn a(c: *Case) std.mem.Allocator {
        return c.arena.allocator();
    }
    fn put(c: *Case, name: []const u8, bytes: []const u8) !void {
        try c.tmp.dir.writeFile(.{ .sub_path = name, .data = bytes });
    }
    /// A package `name` with `files`, whose info is a `paths.json` with the placeholder `ph`.
    fn pkg(c: *Case, name: []const u8, files: []const Ent) !void {
        try c.put(name, try fx.conda(c.a(), files, try fx.info(c.a(), try fx.pathsJson(c.a(), ph))));
    }
    fn read(c: *Case, name: []const u8) ![]u8 {
        return c.tmp.dir.readFileAlloc(c.a(), name, 1 << 20);
    }
    fn exists(c: *Case, name: []const u8) bool {
        c.tmp.dir.access(name, .{}) catch return false;
        return true;
    }
    fn mode(c: *Case, name: []const u8) !u32 {
        return @intCast((try c.tmp.dir.statFile(name)).mode & 0o777);
    }
    const Result = struct { status: u8, err: []const u8 };
    fn run(c: *Case, args: []const []const u8) !Result {
        var err = std.Io.Writer.Allocating.init(c.a());
        const status = P.run(c.a(), .{ .cwd = c.tmp.dir, .err = &err.writer, .window_len = 1 << 16, .max_member = 1 << 20 }, args);
        return .{ .status = status, .err = err.written() };
    }
    fn expectRefused(c: *Case, args: []const []const u8, line: []const u8) !void {
        const r = try c.run(args);
        try t.expectEqualStrings(line, r.err);
        try t.expectEqual(@as(u8, 1), r.status);
        try t.expect(!c.exists("out"));
    }
};

const base = [_][]const u8{ "--out", "out", "--postgres", "pg.conda" };
const two = base ++ [_][]const u8{"other.conda"};

test "unpacks every package into one tree: modes, links, directories, tidied names; drops what a server never reads" {
    var c = Case.init();
    defer c.deinit();
    try c.pkg("pg.conda", &.{
        .{ .name = "./", .flag = '5' },
        .{ .name = "bin/postgres", .body = "POSTGRES", .mode = 0o755 },
        .{ .name = "./bin//initdb", .body = "INITDB", .mode = 0o750 },
        .{ .name = "share/postgres.bki", .body = "BKI", .mode = 0o600 },
        .{ .name = "lib/", .flag = '5' },
        .{ .name = "lib/libpq.so.5", .flag = '2', .link = "libpq.so.5.17" },
        .{ .name = "empty/", .flag = '5' },
        .{ .name = "etc/same", .body = "SAME" },
        .{ .name = "README", .body = "top level" },
        .{ .name = "include/", .flag = '5' },
        .{ .name = "include/pg.h", .body = "HEADER" },
        .{ .name = "share/doc/pg/readme", .body = "DOC" },
        .{ .name = "share/man/man1/psql.1", .body = "MAN" },
        .{ .name = "share/info/dir", .body = "INFO" },
        .{ .name = "share/locale/de/x.mo", .body = "MO" },
        .{ .name = "lib/pkgconfig/libpq.pc", .body = "PC" },
        .{ .name = "lib/cmake/x/y.cmake", .body = "CMAKE" },
        .{ .name = "lib/pgxs/Makefile.global", .body = "PGXS" },
        .{ .name = "info/licenses/COPYING", .body = "LICENSE" },
        .{ .name = "lib/libpq.a", .body = "ARCHIVE" },
        .{ .name = "lib/libpq-static.a", .flag = '2', .link = "libpq.a" },
        .{ .name = "share/documentation/kept", .body = "KEPT" },
    });
    try c.pkg("other.conda", &.{
        .{ .name = "lib/", .flag = '5' },
        .{ .name = "lib/libpq.so.5.17", .body = "LIBPQ", .mode = 0o755 },
        .{ .name = "etc/same", .body = "SAME" },
        .{ .name = "lib/libpq.so.5", .flag = '2', .link = "libpq.so.5.17" },
    });
    try c.tmp.dir.makeDir("out");
    const r = try c.run(&two);
    try t.expectEqualStrings("", r.err);
    try t.expectEqual(@as(u8, 0), r.status);
    try t.expectEqualStrings("POSTGRES", try c.read("out/bin/postgres"));
    try t.expectEqualStrings("INITDB", try c.read("out/bin/initdb"));
    try t.expectEqualStrings("BKI", try c.read("out/share/postgres.bki"));
    try t.expectEqualStrings("LIBPQ", try c.read("out/lib/libpq.so.5.17"));
    try t.expectEqualStrings("SAME", try c.read("out/etc/same"));
    try t.expectEqualStrings("top level", try c.read("out/README"));
    try t.expectEqualStrings("KEPT", try c.read("out/share/documentation/kept"));
    try t.expectEqual(@as(u32, 0o755), try c.mode("out/bin/postgres"));
    try t.expectEqual(@as(u32, 0o755), try c.mode("out/bin/initdb"));
    try t.expectEqual(@as(u32, 0o644), try c.mode("out/share/postgres.bki"));
    try t.expectEqual(@as(u32, 0o755), try c.mode("out/lib/libpq.so.5.17"));
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("libpq.so.5.17", try c.tmp.dir.readLink("out/lib/libpq.so.5", &buf));
    try t.expectEqual(std.fs.File.Kind.directory, (try c.tmp.dir.statFile("out/empty")).kind);
    try t.expectEqualStrings(ph, try c.read("out/buildrules-placeholder.txt"));
    for ([_][]const u8{ "out/info", "out/include", "out/share/doc", "out/share/man", "out/share/info", "out/share/locale", "out/lib/pkgconfig", "out/lib/cmake", "out/lib/pgxs", "out/lib/libpq.a", "out/lib/libpq-static.a" }) |gone| {
        try t.expect(!c.exists(gone));
    }
}

test "a path two packages hold is kept once when they agree, and refused naming both when they differ in bytes, in kind, or in a link's target" {
    var c = Case.init();
    defer c.deinit();
    try c.pkg("pg.conda", &.{ .{ .name = "etc/x", .body = "ONE" }, .{ .name = "lib/l", .flag = '2', .link = "a" }, .{ .name = "d/", .flag = '5' }, .{ .name = "e", .body = "E" } });
    try c.pkg("other.conda", &.{.{ .name = "etc/x", .body = "TWO" }});
    try c.expectRefused(&two, "pg_prefix: etc/x is in both pg.conda and other.conda with different contents\n");
    try c.pkg("other.conda", &.{.{ .name = "lib/l", .flag = '2', .link = "b" }});
    try c.expectRefused(&two, "pg_prefix: lib/l is in both pg.conda and other.conda with different contents\n");
    try c.pkg("other.conda", &.{.{ .name = "d", .body = "" }});
    try c.expectRefused(&two, "pg_prefix: d is in both pg.conda and other.conda with different contents\n");
    try c.pkg("other.conda", &.{.{ .name = "e/", .flag = '5' }});
    try c.expectRefused(&two, "pg_prefix: e is in both pg.conda and other.conda with different contents\n");
    // the same package twice on the command line is two packages with the same paths: they agree
    const r = try c.run(&(base ++ [_][]const u8{"pg.conda"}));
    try t.expectEqual(@as(u8, 0), r.status);
}

test "a member that is not a plain relative path, a link out of the tree, a hard link, an oversized member: refused naming it, nothing left" {
    var c = Case.init();
    defer c.deinit();
    try c.pkg("pg.conda", &.{.{ .name = "/etc/passwd", .body = "x" }});
    try c.expectRefused(&base, "pg_prefix: pg.conda: member /etc/passwd is not a relative path without .. components\n");
    try c.pkg("pg.conda", &.{.{ .name = "lib/../../x", .body = "x" }});
    try c.expectRefused(&base, "pg_prefix: pg.conda: member lib/../../x is not a relative path without .. components\n");
    try c.pkg("pg.conda", &.{.{ .name = "lib/l", .flag = '2', .link = "/usr/lib/libc.so" }});
    try c.expectRefused(&base, "pg_prefix: pg.conda: member lib/l is a link to /usr/lib/libc.so, which is not inside the tree\n");
    try c.pkg("pg.conda", &.{.{ .name = "lib/l", .flag = '2', .link = "../../x" }});
    try c.expectRefused(&base, "pg_prefix: pg.conda: member lib/l is a link to ../../x, which is not inside the tree\n");
    // links that each stay inside on their own but chain out of it (`a/b` is the root, so `c` is its parent): nothing is written through a link
    try c.pkg("pg.conda", &.{ .{ .name = "a/b", .flag = '2', .link = ".." }, .{ .name = "c", .flag = '2', .link = "a/b/.." }, .{ .name = "c/x", .body = "x" } });
    try c.expectRefused(&base, "pg_prefix: pg.conda: member c/x is under the link c; nothing is written through a link\n");
    try c.pkg("pg.conda", &.{ .{ .name = "lib/real", .flag = '5' }, .{ .name = "lib/real/f", .body = "f" }, .{ .name = "lib/alias", .flag = '2', .link = "real" }, .{ .name = "lib/alias/g", .body = "g" } });
    try c.expectRefused(&base, "pg_prefix: pg.conda: member lib/alias/g is under the link lib/alias; nothing is written through a link\n");
    try c.pkg("pg.conda", &.{ .{ .name = "bin/a", .body = "a" }, .{ .name = "bin/b", .flag = '1', .link = "bin/a" } });
    try c.expectRefused(&base, "pg_prefix: pg.conda: a member that is not a file, directory or symbolic link (a hard link?) is not taken\n");
    try c.pkg("pg.conda", &.{.{ .name = "big", .body = "x", .claim = 2 << 20 }});
    try c.expectRefused(&base, "pg_prefix: pg.conda: member big is 2097152 bytes, more than 1048576\n");
    // a member that is dropped is not held to the bound: it is not read
    try c.pkg("pg.conda", &.{.{ .name = "include/big", .body = "x" }});
    const ok = try c.run(&base);
    try t.expectEqual(@as(u8, 0), ok.status);
}

test "a package that is not readable, a zip with no payload, a corrupt archive, a body cut short: refused naming the package" {
    var c = Case.init();
    defer c.deinit();
    try c.expectRefused(&base, "pg_prefix: cannot read pg.conda: FileNotFound\n");
    try c.put("pg.conda", "not a zip");
    try c.expectRefused(&base, "pg_prefix: pg.conda: NoPayload\n");
    try c.put("pg.conda", try fx.zipEntry(c.a(), "info-p.tar.zst", "x", .{ .flags = 8 }));
    try c.expectRefused(&base, "pg_prefix: pg.conda: BadZip\n");
    // a payload that is not zstd, in the info tar and in the package tar
    const info = try fx.zipStored(c.a(), "info-p-1.0-0.tar.zst", try fx.zstdRaw(c.a(), try fx.tar(c.a(), try fx.info(c.a(), try fx.pathsJson(c.a(), ph)))));
    try c.put("pg.conda", try std.mem.concat(c.a(), u8, &.{ info, try fx.zipStored(c.a(), "pkg-p-1.0-0.tar.zst", "this is not zstd at all") }));
    var r = try c.run(&base);
    try t.expectEqual(@as(u8, 1), r.status);
    try t.expect(std.mem.startsWith(u8, r.err, "pg_prefix: pg.conda: cannot read the archive: "));
    try t.expect(!c.exists("out"));
    try c.put("pg.conda", try std.mem.concat(c.a(), u8, &.{ try fx.zipStored(c.a(), "info-p-1.0-0.tar.zst", "this is not zstd at all"), try fx.zipStored(c.a(), "pkg-p-1.0-0.tar.zst", "x") }));
    r = try c.run(&base);
    try t.expect(std.mem.startsWith(u8, r.err, "pg_prefix: pg.conda: cannot read the archive: "));
    // a body that ends before the size its header gives
    try c.pkg("pg.conda", &.{.{ .name = "cut", .body = "x", .claim = 100000 }});
    r = try c.run(&base);
    try t.expectEqual(@as(u8, 1), r.status);
    try t.expect(std.mem.startsWith(u8, r.err, "pg_prefix: pg.conda: cannot read member cut: "));
    // the same in a member that is skipped, and in the info tar
    try c.pkg("pg.conda", &.{.{ .name = "include/cut", .body = "x", .claim = 100000 }});
    r = try c.run(&base);
    try t.expect(std.mem.startsWith(u8, r.err, "pg_prefix: pg.conda: cannot read member include/cut: "));
    try c.put("pg.conda", try fx.conda(c.a(), &.{}, &.{.{ .name = "info/paths.json", .body = "x", .claim = 100000 }}));
    r = try c.run(&base);
    try t.expect(std.mem.startsWith(u8, r.err, "pg_prefix: pg.conda: cannot read member info/paths.json: "));
}

test "the info/paths.json of the postgres package: missing, not a file, too large, absolute, wrong in content: each refused naming the package" {
    var c = Case.init();
    defer c.deinit();
    const files = [_]Ent{.{ .name = "bin/postgres", .body = "x" }};
    try c.put("pg.conda", try fx.conda(c.a(), &files, &.{.{ .name = "info/index.json", .body = "{}" }}));
    try c.expectRefused(&base, "pg_prefix: pg.conda: has no info/paths.json\n");
    try c.put("pg.conda", try fx.conda(c.a(), &files, &.{.{ .name = "info/paths.json/", .flag = '5' }}));
    try c.expectRefused(&base, "pg_prefix: pg.conda: has no info/paths.json\n");
    try c.put("pg.conda", try fx.conda(c.a(), &files, &.{.{ .name = "info/paths.json", .body = "x", .claim = 2 << 20 }}));
    try c.expectRefused(&base, "pg_prefix: pg.conda: info/paths.json is 2097152 bytes, more than 1048576\n");
    try c.put("pg.conda", try fx.conda(c.a(), &files, &.{.{ .name = "/info/paths.json", .body = "x" }}));
    try c.expectRefused(&base, "pg_prefix: pg.conda: member /info/paths.json is not a relative path without .. components\n");
    try c.put("pg.conda", try fx.conda(c.a(), &files, &.{.{ .name = "info/paths.json", .body = "{\"paths\": []}" }}));
    try c.expectRefused(&base, "pg_prefix: pg.conda: info/paths.json does not list bin/postgres\n");
    try c.put("pg.conda", try fx.conda(c.a(), &files, &.{.{ .name = "info/paths.json", .body = "{" }}));
    try c.expectRefused(&base, "pg_prefix: pg.conda: info/paths.json is not JSON\n");
    // a package with no info member at all
    try c.put("pg.conda", try fx.zipStored(c.a(), "pkg-p-1.0-0.tar.zst", "x"));
    try c.expectRefused(&base, "pg_prefix: pg.conda: NoPayload\n");
    // a package with an info member and no payload
    try c.put("pg.conda", try fx.zipStored(c.a(), "info-p-1.0-0.tar.zst", try fx.zstdRaw(c.a(), try fx.tar(c.a(), try fx.info(c.a(), try fx.pathsJson(c.a(), ph))))));
    try c.expectRefused(&base, "pg_prefix: pg.conda: NoPayload\n");
    // info/paths.json twice: the two bodies are read as one text
    try c.put("pg.conda", try fx.conda(c.a(), &files, &.{ .{ .name = "info/paths.json", .body = "{}" }, .{ .name = "info/paths.json", .body = "{}" } }));
    try c.expectRefused(&base, "pg_prefix: pg.conda: info/paths.json is not JSON\n");
}

test "the output directory: an empty one is used, one with anything in it or that is a file is refused and left alone, one that cannot be made is refused" {
    var c = Case.init();
    defer c.deinit();
    try c.pkg("pg.conda", &.{.{ .name = "bin/postgres", .body = "x" }});
    try c.tmp.dir.makePath("out/deep");
    var r = try c.run(&base);
    try t.expectEqualStrings("pg_prefix: out is not empty\n", r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    try t.expect(c.exists("out/deep"));
    try c.tmp.dir.deleteTree("out");
    try c.put("out", "a file");
    r = try c.run(&base);
    try t.expectEqualStrings("pg_prefix: cannot use out: NotDir\n", r.err);
    try t.expectEqualStrings("a file", try c.read("out"));
    try c.tmp.dir.deleteFile("out");
    // a parent that cannot be written to: the directory is not there, and making it is refused
    try c.tmp.dir.makeDir("ro");
    var ro = try c.tmp.dir.openDir("ro", .{ .iterate = true });
    defer ro.close();
    try ro.chmod(0o500);
    r = try c.run(&.{ "--out", "ro/out", "--postgres", "pg.conda" });
    try ro.chmod(0o700);
    try t.expectEqualStrings("pg_prefix: cannot make ro/out: AccessDenied\n", r.err);
    try t.expectEqual(@as(u8, 1), r.status);
}

test "a path that cannot be written is refused naming the package and the path: a file under a file, a file that is a directory, a link that is there" {
    var c = Case.init();
    defer c.deinit();
    try c.pkg("pg.conda", &.{ .{ .name = "a", .body = "x" }, .{ .name = "a/b", .body = "y" } });
    try c.expectRefused(&base, "pg_prefix: pg.conda: cannot write a/b: NotDir\n");
    try c.pkg("pg.conda", &.{ .{ .name = "a/b", .body = "y" }, .{ .name = "a", .body = "x" } });
    try c.expectRefused(&base, "pg_prefix: pg.conda: cannot write a: IsDir\n");
    try c.pkg("pg.conda", &.{ .{ .name = "a/b", .body = "y" }, .{ .name = "a", .flag = '2', .link = "c" } });
    try c.expectRefused(&base, "pg_prefix: pg.conda: cannot write a: PathAlreadyExists\n");
    try c.pkg("pg.conda", &.{.{ .name = "buildrules-placeholder.txt/x", .body = "y" }});
    try c.expectRefused(&base, "pg_prefix: cannot write out/buildrules-placeholder.txt: IsDir\n");
}

test "the command line: a missing or repeated option, an unknown one, a missing value are exit 2 with the usage line, and nothing is made" {
    var c = Case.init();
    defer c.deinit();
    const usage = "pg_prefix: usage: pg_prefix --out DIR --postgres POSTGRESQL.conda [OTHER.conda]...\n";
    const bad = [_][]const []const u8{
        &.{},
        &.{ "--out", "out" },
        &.{ "--postgres", "pg.conda" },
        &.{ "--out", "out", "--out", "o2", "--postgres", "pg.conda" },
        &.{ "--out", "out", "--postgres", "pg.conda", "--postgres", "p2.conda" },
        &.{ "--out", "out", "--postgres", "pg.conda", "--bogus" },
        &.{ "--out", "out", "--postgres" },
    };
    for (bad) |args| {
        const r = try c.run(args);
        try t.expectEqualStrings(usage, r.err);
        try t.expectEqual(@as(u8, 2), r.status);
        try t.expect(!c.exists("out"));
    }
}

test "messages go nowhere when stderr is closed, and the status is still right" {
    var c = Case.init();
    defer c.deinit();
    var shut: [0]u8 = undefined;
    var closed = std.Io.Writer.fixed(&shut);
    const io = P.Io{ .cwd = c.tmp.dir, .err = &closed, .window_len = 1 << 16 };
    try t.expectEqual(@as(u8, 2), P.run(c.a(), io, &.{}));
    try t.expectEqual(@as(u8, 1), P.run(c.a(), io, &base));
}

fn sweep(c: *Case, args: []const []const u8, want_lib: []const u8, want_body: []const u8) !void {
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        var inner = std.heap.ArenaAllocator.init(t.allocator);
        defer inner.deinit();
        var fail = t.FailingAllocator.init(inner.allocator(), .{ .fail_index = i });
        var err = std.Io.Writer.Allocating.init(c.a());
        const status = P.run(fail.allocator(), .{ .cwd = c.tmp.dir, .err = &err.writer, .window_len = 1 << 16 }, args);
        if (!fail.has_induced_failure) {
            try t.expectEqual(@as(u8, 0), status);
            try t.expectEqualStrings(want_body, try c.read(want_lib));
            try c.tmp.dir.deleteTree("out");
            return;
        }
        try t.expectEqual(@as(u8, 1), status);
        try t.expectEqualStrings("pg_prefix: out of memory\n", err.written());
        try t.expect(!c.exists("out"));
    }
    return error.SweepDidNotEnd;
}

test "every allocation failing in turn is out of memory and exit 1, and no tree is left, with one package and with two" {
    var c = Case.init();
    defer c.deinit();
    try c.pkg("pg.conda", &.{ .{ .name = "bin/postgres", .body = "POSTGRES", .mode = 0o755 }, .{ .name = "lib/l", .flag = '2', .link = "m" }, .{ .name = "include/h", .body = "H" }, .{ .name = "d/", .flag = '5' } });
    try c.pkg("other.conda", &.{ .{ .name = "lib/m", .body = "M" }, .{ .name = "bin/postgres", .body = "POSTGRES", .mode = 0o755 } });
    try sweep(&c, &two, "out/lib/m", "M");
    try sweep(&c, &base, "out/bin/postgres", "POSTGRES");
}
