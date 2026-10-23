//! Unit tests of cov_run.zig: its command line, and the two lines it builds for kcov and cov_normalize. The run itself (kcov tracing a test
//! binary) is held by the examples' coverage targets.
const std = @import("std");
const C = @import("cov_run.zig");
const t = std.testing;
const ir = @import("install_root");

fn args(a: std.mem.Allocator, extra: []const []const u8) ![]const []const u8 {
    const base = [_][]const u8{ "--kcov", "/k", "--normalize", "/n", "--compiler", "/c", "--binary", "/b/t", "--share", "/s", "--out", "o.xml", "--must-contain", "pkg/tests/test_x.mojo", "--include", "base" };
    return std.mem.concat(a, []const u8, &.{ &base, extra });
}

test "parse: the whole command line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    const r = try C.parse(a, try args(a, &.{ "--include", "tests/test_x.mojo", "--map", "base/=pkg/src/base/", "--map", "tests/=pkg/tests/", "--refuse-in-binary", ".stage/src/" }), &d);
    try t.expectEqualStrings("/k", r.kcov);
    try t.expectEqual(@as(usize, 2), r.includes.len);
    try t.expectEqualStrings("tests/test_x.mojo", r.includes[1]);
    try t.expectEqual(@as(usize, 2), r.maps.len);
    try t.expectEqualStrings("pkg/tests/", r.maps[1].repo);
    try t.expectEqualStrings(".stage/src/", r.refuse[0]);
}

test "parse: refusals name the option" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--include", "a,b" }), &d));
    try t.expect(std.mem.indexOf(u8, d, "--include a,b") != null);
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--map", "base=pkg/" }), &d));
    try t.expect(std.mem.indexOf(u8, d, "both sides are relative directories ending in /") != null);
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--map", "/abs/=pkg/" }), &d));
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{"--bogus"}), &d));
    try t.expectError(error.Usage, C.parse(a, &.{ "--kcov", "/k" }, &d));
    try t.expect(std.mem.indexOf(u8, d, "is required") != null);
    // No include path: kcov would measure nothing, and say nothing.
    try t.expectError(error.Usage, C.parse(a, &.{ "--kcov", "/k", "--normalize", "/n", "--compiler", "/c", "--binary", "/b", "--share", "/s", "--out", "o", "--must-contain", "x" }, &d));
    try t.expect(std.mem.indexOf(u8, d, "at least one --include") != null);
}

test "kcov's command line measures exactly the included paths under the tree, with full paths in the report" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    const r = try C.parse(a, try args(a, &.{ "--include", "tests/test_x.mojo" }), &d);
    const k = try C.kcovArgv(a, r, "/real/share", "/work");
    try t.expectEqualStrings("/k/bin/kcov", k[0]);
    try t.expectEqualStrings("--cobertura-only", k[1]);
    try t.expectEqualStrings("--configure=cobertura-full-paths=1", k[3]);
    try t.expectEqualStrings("--include-path=/real/share/base,/real/share/tests/test_x.mojo", k[4]);
    try t.expectEqualStrings("/work", k[5]);
    try t.expectEqualStrings("/b/t", k[6]);
}

test "kcov's command line passes the test binary its arguments, after the binary" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    var r = try C.parse(a, try args(a, &.{}), &d);
    r.binary_args = &.{ "--cov-out=/w/blocks", "--x" };
    const k = try C.kcovArgv(a, r, "/real/share", "/work");
    try t.expectEqual(@as(usize, 9), k.len);
    try t.expectEqualStrings("/b/t", k[6]);
    try t.expectEqualStrings("--cov-out=/w/blocks", k[7]);
    try t.expectEqualStrings("--x", k[8]);
    // cov_run's own command line gives the binary none.
    const plain = try C.kcovArgv(a, try C.parse(a, try args(a, &.{}), &d), "/real/share", "/work");
    try t.expectEqual(@as(usize, 7), plain.len);
}

test "cov_normalize's command line maps the tree's absolute names to repository paths and forbids the action's directory" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    const r = try C.parse(a, try args(a, &.{ "--map", "base/=pkg/src/base/" }), &d);
    const n = try C.normalizeArgv(a, r, "/real/share", "/work/cov.xml", "/exec/root");
    try t.expectEqualStrings("/n", n[0]);
    try t.expectEqualStrings("/work/cov.xml", n[2]);
    try t.expectEqualStrings("--map", n[5]);
    try t.expectEqualStrings("/real/share/base/=pkg/src/base/", n[6]);
    try t.expectEqualStrings("--must-contain", n[7]);
    try t.expectEqualStrings("pkg/tests/test_x.mojo", n[8]);
    try t.expectEqualStrings("--forbid", n[9]);
    try t.expectEqualStrings("/exec/root", n[10]);
}

test "heldText: the staged-path leak is found in a binary, and a clean binary passes" {
    try t.expectEqualStrings(".stage/src/", C.heldText("..\x00/exec/root/x/out.stage/src/base\x00..", &.{".stage/src/"}).?);
    try t.expect(C.heldText("base/__init__.mojo", &.{".stage/src/"}) == null);
    try t.expect(C.heldText("anything", &.{}) == null);
}

test "parse: the test's own variables and the variable that names its data tree" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    const r = try C.parse(a, try args(a, &.{ "--env", "A=1", "--env", "B=x=y", "--env", "EMPTY=", "--data-env", "BUILDRULES_TEST_DATA" }), &d);
    try t.expectEqual(@as(usize, 3), r.env.len);
    try t.expectEqualStrings("B=x=y", r.env[1]);
    try t.expectEqualStrings("BUILDRULES_TEST_DATA", r.data_env);
    // Without either option the test gets nothing of its own.
    const none = try C.parse(a, try args(a, &.{}), &d);
    try t.expectEqual(@as(usize, 0), none.env.len);
    try t.expectEqualStrings("", none.data_env);
}

test "parse: a variable cov_run sets itself, or one that is not NAME=VALUE, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--env", "PATH=/x" }), &d));
    try t.expect(std.mem.indexOf(u8, d, "cov_run sets PATH itself") != null);
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--env", "LD_LIBRARY_PATH=/x" }), &d));
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--env", "NOEQUALS" }), &d));
    try t.expect(std.mem.indexOf(u8, d, "is not NAME=VALUE") != null);
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--env", "=v" }), &d));
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--data-env", "" }), &d));
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--data-env", "A=B" }), &d));
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--data-env", "PATH" }), &d));
    try t.expect(std.mem.indexOf(u8, d, "not a variable name cov_run may set") != null);
}

test "testEnv: the compiler's lib, the fixed PATH, the test's variables, and the data tree under its variable" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    const r = try C.parse(a, try args(a, &.{ "--env", "MODE=on", "--env", "EQ=a=b", "--data-env", "BUILDRULES_TEST_DATA" }), &d);
    const env = try C.testEnv(a, r, "/real/compiler", "/real/share", null);
    try t.expectEqualStrings("/real/compiler/lib", env.get("LD_LIBRARY_PATH").?);
    try t.expectEqualStrings("/usr/bin:/bin", env.get("PATH").?);
    try t.expectEqualStrings("on", env.get("MODE").?);
    try t.expectEqualStrings("a=b", env.get("EQ").?);
    try t.expectEqualStrings("/real/share", env.get("BUILDRULES_TEST_DATA").?);
    try t.expectEqual(@as(u32, 5), env.count());
    // No options: only what a coverage run always had.
    const plain = try C.testEnv(a, try C.parse(a, try args(a, &.{}), &d), "/real/compiler", "/real/share", null);
    try t.expectEqual(@as(u32, 2), plain.count());
}

test "parse: --private-scratch and --installed take no value, whatever the order; --data takes a directory" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    const none = try C.parse(a, try args(a, &.{}), &d);
    try t.expect(!none.private_scratch and !none.installed);
    try t.expectEqualStrings("", none.data);
    const p = try C.parse(a, try args(a, &.{"--private-scratch"}), &d);
    try t.expect(p.private_scratch and !p.installed);
    // a valueless option first, in the middle and last: the options around it still read their values
    const all = try C.parse(a, try args(a, &.{ "--installed", "--env", "A=1", "--private-scratch", "--data", "/d", "--installed" }), &d);
    try t.expect(all.private_scratch and all.installed);
    try t.expectEqualStrings("/d", all.data);
    try t.expectEqual(@as(usize, 1), all.env.len);
    try t.expectEqualStrings("/k", all.kcov);
    try t.expectEqualStrings("/s", all.share);
}

test "parse: --installed without --private-scratch, --data without --installed and an empty --data are usage errors" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{"--installed"}), &d));
    try t.expect(std.mem.indexOf(u8, d, "--installed needs --private-scratch") != null);
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--private-scratch", "--data", "/d" }), &d));
    try t.expect(std.mem.indexOf(u8, d, "--data needs --installed") != null);
    try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--private-scratch", "--installed", "--data", "" }), &d));
    try t.expect(std.mem.indexOf(u8, d, "--data needs a directory") != null);
}

test "parse: TMPDIR, TEST_TMPDIR and HOME are the runner's, a test's --env may not set them" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    for ([_][]const u8{ "TMPDIR=/x", "TEST_TMPDIR=/x", "HOME=/x" }) |entry| {
        try t.expectError(error.Usage, C.parse(a, try args(a, &.{ "--env", entry }), &d));
        try t.expect(std.mem.indexOf(u8, d, "cov_run sets ") != null);
    }
}

test "testEnv: with a private scratch directory TMPDIR and TEST_TMPDIR are its tmp and HOME its home" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: []const u8 = "";
    const r = try C.parse(a, try args(a, &.{ "--data-env", "BUILDRULES_TEST_DATA" }), &d);
    const s = ir.Scratch{ .dir = "/p", .tmp = "/p/tmp", .home = "/p/home", .root = "/p/root", .share = "/p/root/share" };
    const env = try C.testEnv(a, r, "/real/compiler", "/p/root/share", s);
    try t.expectEqualStrings("/p/tmp", env.get("TMPDIR").?);
    try t.expectEqualStrings("/p/tmp", env.get("TEST_TMPDIR").?);
    try t.expectEqualStrings("/p/home", env.get("HOME").?);
    try t.expectEqualStrings("/p/root/share", env.get("BUILDRULES_TEST_DATA").?);
    try t.expectEqual(@as(u32, 6), env.count());
}

const Tmp = struct {
    tmp: std.testing.TmpDir,
    here: []const u8,

    fn init(a: std.mem.Allocator) !Tmp {
        var x = Tmp{ .tmp = std.testing.tmpDir(.{ .iterate = true }), .here = "" };
        x.here = try x.tmp.dir.realpathAlloc(a, ".");
        return x;
    }

    fn put(x: *Tmp, name: []const u8, bytes: []const u8) !void {
        if (std.fs.path.dirname(name)) |dir| try x.tmp.dir.makePath(dir);
        try x.tmp.dir.writeFile(.{ .sub_path = name, .data = bytes });
    }

    fn at(x: *Tmp, a: std.mem.Allocator, name: []const u8) ![]const u8 {
        return std.fs.path.join(a, &.{ x.here, name });
    }
};

fn parsed(a: std.mem.Allocator, extra: []const []const u8) !C.Args {
    var d: []const u8 = "";
    return C.parse(a, try args(a, extra), &d);
}

test "stage: without --private-scratch nothing is made and the run is on the tree and the binary as they are" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try C.stage(a, try parsed(a, &.{}), "/real/share", "/real/bin/test", "/never/made");
    try t.expectEqualStrings("/real/share", s.tree);
    try t.expectEqualStrings("/real/share", s.data);
    try t.expectEqualStrings("/real/bin/test", s.binary);
    try t.expect(s.scratch == null);
}

test "stage: --private-scratch alone makes empty directories of the run's own and leaves the tree and the binary where they are" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var x = try Tmp.init(a);
    defer x.tmp.cleanup();
    const s = try C.stage(a, try parsed(a, &.{"--private-scratch"}), "/real/share", "/real/bin/test", try x.at(a, "parent"));
    defer ir.remove(s.scratch.?);
    try t.expectEqualStrings("/real/share", s.tree);
    try t.expectEqualStrings("/real/share", s.data);
    try t.expectEqualStrings("/real/bin/test", s.binary);
    try t.expect(std.mem.startsWith(u8, s.scratch.?.tmp, try x.at(a, "parent/buildrules_test.")));
    var home = try std.fs.openDirAbsolute(s.scratch.?.home, .{ .iterate = true });
    defer home.close();
    var it = home.iterate();
    try t.expect((try it.next()) == null);
}

test "stage: --installed puts the binary at root/bin, the sources in root, the data in root/share, and root is the tree" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var x = try Tmp.init(a);
    defer x.tmp.cleanup();
    try x.put("out/test", "binary");
    try x.put("out/lib/libn.so", "native");
    try x.put("tree/tests/test_x.mojo", "source");
    try x.put("tree/pkg/mod.mojo", "library source");
    try x.put("data/golden.txt", "golden");
    const r = try parsed(a, &.{ "--private-scratch", "--installed", "--data", try x.at(a, "data") });
    const s = try C.stage(a, r, try x.at(a, "tree"), try x.at(a, "out/test"), try x.at(a, "parent"));
    defer ir.remove(s.scratch.?);
    const root = s.scratch.?.root;
    try t.expectEqualStrings(root, s.tree);
    try t.expectEqualStrings(try std.fs.path.join(a, &.{ root, "bin/test" }), s.binary);
    try t.expectEqualStrings(try std.fs.path.join(a, &.{ root, "share" }), s.data);
    var dir = try std.fs.openDirAbsolute(root, .{});
    defer dir.close();
    try t.expectEqualStrings("binary", try dir.readFileAlloc(a, "bin/test", 1 << 20));
    try t.expectEqualStrings("native", try dir.readFileAlloc(a, "bin/lib/libn.so", 1 << 20));
    try t.expectEqualStrings("source", try dir.readFileAlloc(a, "tests/test_x.mojo", 1 << 20));
    try t.expectEqualStrings("library source", try dir.readFileAlloc(a, "pkg/mod.mojo", 1 << 20));
    try t.expectEqualStrings("golden", try dir.readFileAlloc(a, "share/golden.txt", 1 << 20));
}

test "stage: --installed without --data still makes root/share" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var x = try Tmp.init(a);
    defer x.tmp.cleanup();
    try x.put("out/test", "binary");
    try x.put("tree/tests/test_x.mojo", "source");
    const s = try C.stage(a, try parsed(a, &.{ "--private-scratch", "--installed" }), try x.at(a, "tree"), try x.at(a, "out/test"), try x.at(a, "parent"));
    defer ir.remove(s.scratch.?);
    var share = try std.fs.openDirAbsolute(s.data, .{ .iterate = true });
    defer share.close();
    var it = share.iterate();
    try t.expect((try it.next()) == null);
}

test "stage: a parent that cannot be made, a binary, a tree or data that are not there, are errors, and the run's directory is not left behind" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var x = try Tmp.init(a);
    defer x.tmp.cleanup();
    try x.put("out/test", "binary");
    try x.put("tree/tests/test_x.mojo", "source");
    try x.put("file", "a file where a parent goes");
    const base = try parsed(a, &.{ "--private-scratch", "--installed" });
    const with_data = try parsed(a, &.{ "--private-scratch", "--installed", "--data", try x.at(a, "no-such-data") });
    try t.expectError(error.NotDir, C.stage(a, base, try x.at(a, "tree"), try x.at(a, "out/test"), try x.at(a, "file/parent")));
    try t.expectError(error.FileNotFound, C.stage(a, base, try x.at(a, "tree"), try x.at(a, "out/missing"), try x.at(a, "parent")));
    try t.expectError(error.FileNotFound, C.stage(a, base, try x.at(a, "no-such-tree"), try x.at(a, "out/test"), try x.at(a, "parent")));
    try t.expectError(error.FileNotFound, C.stage(a, with_data, try x.at(a, "tree"), try x.at(a, "out/test"), try x.at(a, "parent")));
    var parent = try x.tmp.dir.openDir("parent", .{ .iterate = true });
    defer parent.close();
    var it = parent.iterate();
    try t.expect((try it.next()) == null);
}

test "stage: a tree that holds a bin or a share is refused, and the run's directory is not left behind" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var x = try Tmp.init(a);
    defer x.tmp.cleanup();
    try x.put("out/test", "binary");
    for ([_][]const u8{ "bin", "share" }) |name| {
        const tree = try std.fmt.allocPrint(a, "tree_{s}/{s}/f", .{ name, name });
        try x.put(tree, "x");
        const r = try parsed(a, &.{ "--private-scratch", "--installed" });
        try t.expectError(error.TreeHoldsLayoutName, C.stage(a, r, try x.at(a, std.fs.path.dirname(std.fs.path.dirname(tree).?).?), try x.at(a, "out/test"), try x.at(a, "parent")));
    }
    var parent = try x.tmp.dir.openDir("parent", .{ .iterate = true });
    defer parent.close();
    var it = parent.iterate();
    try t.expect((try it.next()) == null);
}
