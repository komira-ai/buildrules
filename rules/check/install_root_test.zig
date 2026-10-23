//! The cases of install_root.zig: the parent of the private directory, the directory itself (fresh, empty, never shared between two runs), the installed
//! binary and the copy of a tree.

const std = @import("std");
const builtin = @import("builtin");
const t = std.testing;
const ir = @import("install_root");

const Env = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    /// The absolute path of the temporary directory.
    here: []const u8,

    fn init() !Env {
        var e = Env{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .tmp = std.testing.tmpDir(.{ .iterate = true }), .here = "" };
        e.here = try e.tmp.dir.realpathAlloc(e.arena.allocator(), ".");
        return e;
    }

    fn deinit(e: *Env) void {
        e.tmp.cleanup();
        e.arena.deinit();
    }

    fn a(e: *Env) std.mem.Allocator {
        return e.arena.allocator();
    }

    fn at(e: *Env, name: []const u8) ![]const u8 {
        return std.fs.path.join(e.a(), &.{ e.here, name });
    }

    fn put(e: *Env, name: []const u8, bytes: []const u8, mode: std.fs.File.Mode) !void {
        if (std.fs.path.dirname(name)) |d| try e.tmp.dir.makePath(d);
        var f = try e.tmp.dir.createFile(name, .{ .mode = mode });
        defer f.close();
        try f.writeAll(bytes);
    }

    fn read(e: *Env, name: []const u8) ![]u8 {
        return e.tmp.dir.readFileAlloc(e.a(), name, 1 << 20);
    }
};

fn isEmpty(dir: []const u8) !bool {
    var d = try std.fs.openDirAbsolute(dir, .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    return (try it.next()) == null;
}

test "parent: BUCK_SCRATCH_PATH first, then TMPDIR, then /tmp; empty is unset; a relative one is made absolute against the working directory" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("/abs/scratch", try ir.parent(a, "/work", "/abs/scratch", "/old"));
    try t.expectEqualStrings("/work/rel/scratch", try ir.parent(a, "/work", "rel/scratch", "/old"));
    try t.expectEqualStrings("/old", try ir.parent(a, "/work", "", "/old"));
    try t.expectEqualStrings("/old", try ir.parent(a, "/work", null, "/old"));
    try t.expectEqualStrings("/work/reltmp", try ir.parent(a, "/work", null, "reltmp"));
    try t.expectEqualStrings("/tmp", try ir.parent(a, "/work", "", ""));
    try t.expectEqualStrings("/tmp", try ir.parent(a, "/work", null, null));
}

test "make: a fresh directory with an empty tmp, home and root, an empty root/share, all absolute, in a parent that is made when it is not there" {
    var e = try Env.init();
    defer e.deinit();
    const where = try e.at("not/yet/there");
    const s = try ir.make(e.a(), where);
    defer ir.remove(s);
    for ([_][]const u8{ s.dir, s.tmp, s.home, s.root, s.share }) |p| try t.expect(std.fs.path.isAbsolute(p));
    try t.expect(std.mem.startsWith(u8, s.dir, where));
    try t.expect(std.mem.startsWith(u8, std.fs.path.basename(s.dir), "buildrules_test."));
    try t.expectEqualStrings(s.dir, std.fs.path.dirname(s.tmp).?);
    try t.expectEqualStrings("tmp", std.fs.path.basename(s.tmp));
    try t.expectEqualStrings("home", std.fs.path.basename(s.home));
    try t.expectEqualStrings("root", std.fs.path.basename(s.root));
    try t.expectEqualStrings(s.root, std.fs.path.dirname(s.share).?);
    try t.expectEqualStrings("share", std.fs.path.basename(s.share));
    for ([_][]const u8{ s.tmp, s.home, s.share }) |p| try t.expect(try isEmpty(p));
    // root holds only share/ until the binary is installed
    var root = try std.fs.openDirAbsolute(s.root, .{ .iterate = true });
    defer root.close();
    var it = root.iterate();
    try t.expectEqualStrings("share", (try it.next()).?.name);
    try t.expect((try it.next()) == null);
}

test "make: the paths have no link in them, whatever the parent was given as" {
    var e = try Env.init();
    defer e.deinit();
    try e.tmp.dir.makePath("real/dir");
    try e.tmp.dir.symLink(try e.at("real"), "link", .{ .is_directory = true });
    const s = try ir.make(e.a(), try e.at("link/dir"));
    defer ir.remove(s);
    try t.expect(std.mem.startsWith(u8, s.dir, try e.at("real/dir/")));
    try t.expectEqualStrings(s.dir, try std.fs.cwd().realpathAlloc(e.a(), s.dir));
}

test "make: two runs never share a directory, even in one parent" {
    var e = try Env.init();
    defer e.deinit();
    const first = try ir.make(e.a(), e.here);
    defer ir.remove(first);
    const second = try ir.make(e.a(), e.here);
    defer ir.remove(second);
    try t.expect(!std.mem.eql(u8, first.dir, second.dir));
    try t.expect(!std.mem.eql(u8, first.tmp, second.tmp));
    try t.expect(!std.mem.eql(u8, first.home, second.home));
    // what one run leaves is not seen by the other
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(e.a(), &.{ first.tmp, "left" }), .data = "x" });
    try t.expect(try isEmpty(second.tmp));
}

test "makeNamed: a directory of that name that is there already is another run's: an error, and it is left as it is" {
    var e = try Env.init();
    defer e.deinit();
    const first = try ir.makeNamed(e.a(), e.here, "buildrules_test.fixed");
    defer ir.remove(first);
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(e.a(), &.{ first.tmp, "mine" }), .data = "x" });
    try t.expectError(error.PathAlreadyExists, ir.makeNamed(e.a(), e.here, "buildrules_test.fixed"));
    try t.expectEqualStrings("x", try e.read("buildrules_test.fixed/tmp/mine"));
}

test "make: a parent that cannot be made is an error; remove takes the whole directory, and a second remove is no error" {
    var e = try Env.init();
    defer e.deinit();
    try e.put("blocked", "a file where the parent goes", 0o644);
    try t.expectError(error.NotDir, ir.make(e.a(), try e.at("blocked/inside")));
    const s = try ir.make(e.a(), e.here);
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(e.a(), &.{ s.home, "file" }), .data = "x" });
    ir.remove(s);
    try t.expectError(error.FileNotFound, std.fs.cwd().access(s.dir, .{}));
    ir.remove(s);
}

test "installBinary: the directory of the binary is copied to root/bin, the binary in it with its permission bits, and what sits beside it with it" {
    var e = try Env.init();
    defer e.deinit();
    try e.put("out/test", "binary bytes", 0o755);
    try e.put("out/lib/libx.so", "library", 0o644);
    try e.put("out/extra", "file", 0o644);
    const root = try e.at("root");
    const installed = try ir.installBinary(e.a(), root, try e.at("out/test"));
    try t.expectEqualStrings(try e.at("root/bin/test"), installed);
    const st = try e.tmp.dir.statFile("root/bin/test");
    try t.expectEqual(std.fs.File.Kind.file, st.kind);
    try t.expect(st.mode & 0o111 != 0);
    try t.expectEqualStrings("binary bytes", try e.read("root/bin/test"));
    // the runpath of a binary is $ORIGIN/lib
    try t.expectEqualStrings("library", try e.read("root/bin/lib/libx.so"));
    try t.expectEqualStrings("file", try e.read("root/bin/extra"));
    // a copy: not a link to the original, which can change without the copy changing
    var link: [std.fs.max_path_bytes]u8 = undefined;
    try t.expectError(error.NotLink, e.tmp.dir.readLink("root/bin/test", &link));
    try e.put("out/test", "changed", 0o755);
    try t.expectEqualStrings("binary bytes", try e.read("root/bin/test"));
}

test "installBinary: a binary that is not there, one in a directory that is a file, one directly in /, and a bin that cannot be made, are errors" {
    var e = try Env.init();
    defer e.deinit();
    const root = try e.at("root");
    try t.expectError(error.FileNotFound, ir.installBinary(e.a(), root, try e.at("out/missing")));
    // its directory is there but it is not in it
    try e.put("beside/other", "x", 0o644);
    try t.expectError(error.FileNotFound, ir.installBinary(e.a(), root, try e.at("beside/missing")));
    try e.put("plain", "x", 0o644);
    try t.expectError(error.NotDir, ir.installBinary(e.a(), root, try e.at("plain/under-a-file")));
    try t.expectError(error.NotInADirectory, ir.installBinary(e.a(), root, "/binary-in-the-root-directory"));
    try e.put("out/test", "x", 0o755);
    try e.put("blocked/bin", "a file where bin/ goes", 0o644);
    try t.expectError(error.NotDir, ir.installBinary(e.a(), try e.at("blocked"), try e.at("out/test")));
}

test "copyTree: directories, files with their permission bits, and what a link names; an entry already there is replaced" {
    var e = try Env.init();
    defer e.deinit();
    try e.put("from/a.txt", "a", 0o644);
    try e.put("from/deep/er/b.sh", "b", 0o755);
    try e.put("from/real_dir/c.txt", "c", 0o644);
    try e.put("target.txt", "linked file", 0o644);
    try e.tmp.dir.symLink(try e.at("target.txt"), "from/link_to_file", .{});
    try e.tmp.dir.symLink(try e.at("from/real_dir"), "from/link_to_dir", .{ .is_directory = true });
    try e.put("to/a.txt", "stale", 0o644);
    try ir.copyTree(e.a(), try e.at("from"), try e.at("to"));
    try t.expectEqualStrings("a", try e.read("to/a.txt"));
    try t.expectEqualStrings("b", try e.read("to/deep/er/b.sh"));
    try t.expect((try e.tmp.dir.statFile("to/deep/er/b.sh")).mode & 0o111 != 0);
    try t.expect((try e.tmp.dir.statFile("to/a.txt")).mode & 0o111 == 0);
    try t.expectEqualStrings("linked file", try e.read("to/link_to_file"));
    try t.expectEqualStrings("c", try e.read("to/link_to_dir/c.txt"));
    // copies, not links
    var link: [std.fs.max_path_bytes]u8 = undefined;
    try t.expectError(error.NotLink, e.tmp.dir.readLink("to/link_to_file", &link));
    try t.expectError(error.NotLink, e.tmp.dir.readLink("to/link_to_dir", &link));
}

test "copyTree: a tree that is not there, a destination under a file, a link that leads nowhere (here or below), and a file that cannot be written are errors" {
    var e = try Env.init();
    defer e.deinit();
    try t.expectError(error.FileNotFound, ir.copyTree(e.a(), try e.at("missing"), try e.at("to")));
    try e.put("from/a.txt", "a", 0o644);
    try e.put("file", "x", 0o644);
    try t.expectError(error.NotDir, ir.copyTree(e.a(), try e.at("from"), try e.at("file/under")));
    // a directory where the file goes cannot be replaced by it
    try e.tmp.dir.makePath("to/a.txt");
    if (ir.copyTree(e.a(), try e.at("from"), try e.at("to"))) |_| return error.TestExpectedError else |_| {}
    try e.tmp.dir.makePath("dangling/sub");
    try e.tmp.dir.symLink(try e.at("nowhere"), "dangling/sub/link", .{});
    try t.expectError(error.FileNotFound, ir.copyTree(e.a(), try e.at("dangling/sub"), try e.at("to2")));
    try t.expectError(error.FileNotFound, ir.copyTree(e.a(), try e.at("dangling"), try e.at("to3")));
}

test "copyTree: a kind of file that is neither a file nor a directory (a named pipe) is an error" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var e = try Env.init();
    defer e.deinit();
    try e.tmp.dir.makePath("from");
    const pipe = try e.a().dupeZ(u8, try e.at("from/pipe"));
    try t.expectEqual(@as(usize, 0), std.os.linux.mknodat(std.posix.AT.FDCWD, pipe.ptr, std.os.linux.S.IFIFO | 0o644, 0));
    try t.expectError(error.UnsupportedFileKind, ir.copyTree(e.a(), try e.at("from"), try e.at("to")));
}

test "copyTree, installBinary and make: every allocation failed in turn is an error, never a success on a partial result" {
    var e = try Env.init();
    defer e.deinit();
    try e.put("from/a.txt", "a", 0o644);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(e.a(), .{ .fail_index = i });
        ir.copyTree(fa.allocator(), try e.at("from"), try e.at("to")) catch |err| {
            try t.expect(err == error.OutOfMemory);
            continue;
        };
        try t.expect(!fa.has_induced_failure);
        break;
    }
    try e.put("out/test", "binary", 0o755);
    i = 0;
    while (i < 1000) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(e.a(), .{ .fail_index = i });
        _ = ir.installBinary(fa.allocator(), try e.at("root"), try e.at("out/test")) catch |err| {
            try t.expect(err == error.OutOfMemory);
            continue;
        };
        try t.expect(!fa.has_induced_failure);
        break;
    }
    i = 0;
    while (i < 1000) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(e.a(), .{ .fail_index = i });
        const s = ir.make(fa.allocator(), e.here) catch |err| {
            try t.expect(err == error.OutOfMemory);
            continue;
        };
        ir.remove(s);
        try t.expect(!fa.has_induced_failure);
        break;
    }
}
