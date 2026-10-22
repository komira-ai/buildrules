//! Process tests of proc.zig, run by `zig test` as a build action (`:cov_branch_proc_test`). They run a stand-in program
//! (proc_stub.zig; its path is in the environment as PROC_STUB, the `zig_test`'s `env_tools`, and every test fails, never passes, without
//! it) through proc.run and check what the process step promises: the exact environment, the working directory, the files stdout and
//! stderr go to, the exit status a shell would see, and a program that cannot start.

const std = @import("std");
const proc = @import("proc.zig");
const testing = std.testing;

fn stub(a: std.mem.Allocator) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, "PROC_STUB") catch {
        std.debug.print("the test target does not pass PROC_STUB (env_tools), so the stand-in program cannot be run\n", .{});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

const Dir = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8,

    fn init() !*Dir {
        const d = try testing.allocator.create(Dir);
        d.* = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .tmp = testing.tmpDir(.{}), .root = "" };
        d.root = try d.tmp.dir.realpathAlloc(d.arena.allocator(), ".");
        return d;
    }

    fn deinit(self: *Dir) void {
        self.tmp.cleanup();
        self.arena.deinit();
        testing.allocator.destroy(self);
    }

    fn a(self: *Dir) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn path(self: *Dir, rel: []const u8) []const u8 {
        return std.fs.path.join(self.a(), &.{ self.root, rel }) catch unreachable;
    }

    fn read(self: *Dir, rel: []const u8) ![]const u8 {
        return self.tmp.dir.readFileAlloc(self.a(), rel, 1 << 20);
    }
};

test "the environment is exactly the one given" {
    var d = try Dir.init();
    defer d.deinit();
    const o = try proc.run(d.a(), .{
        .argv = &.{ try stub(d.a()), "env" },
        .env = &.{ "ONLY=1", "B=two words" },
        .stdout_path = d.path("env"),
    });
    try testing.expectEqual(proc.Status{ .exited = 0 }, o.status);
    // Nothing of the test's own environment (PROC_STUB, its TMPDIR) reaches the program.
    try testing.expectEqualStrings("B=two words\nONLY=1\n", try d.read("env"));
}

test "the program starts in the directory given, and in the caller's without one" {
    var d = try Dir.init();
    defer d.deinit();
    try d.tmp.dir.makePath("sub");
    _ = try proc.run(d.a(), .{ .argv = &.{ try stub(d.a()), "cwd" }, .env = &.{}, .cwd = d.path("sub"), .stdout_path = d.path("in_sub") });
    try testing.expectEqualStrings(d.path("sub"), try d.read("in_sub"));
    _ = try proc.run(d.a(), .{ .argv = &.{ try stub(d.a()), "cwd" }, .env = &.{}, .stdout_path = d.path("here") });
    const mine = try std.process.getCwdAlloc(d.a());
    try testing.expectEqualStrings(mine, try d.read("here"));
}

test "a directory that does not exist is a program that cannot start: 127, reported on the child's stderr" {
    var d = try Dir.init();
    defer d.deinit();
    const o = try proc.run(d.a(), .{ .argv = &.{ try stub(d.a()), "cwd" }, .env = &.{}, .cwd = d.path("absent"), .stderr_path = d.path("err") });
    try testing.expectEqual(@as(u8, 127), o.shellStatus());
    try testing.expect(std.mem.indexOf(u8, try d.read("err"), "proc: cannot run ") != null);
}

test "the arguments are passed whole, empty and spaced ones included" {
    var d = try Dir.init();
    defer d.deinit();
    _ = try proc.run(d.a(), .{ .argv = &.{ try stub(d.a()), "argv", "a b", "", "$HOME" }, .env = &.{}, .stdout_path = d.path("argv") });
    try testing.expectEqualStrings("a b\n\n$HOME\n", try d.read("argv"));
}

test "stdout and stderr go to their files, or interleave in one" {
    var d = try Dir.init();
    defer d.deinit();
    const o1 = d.path("o1");
    const e1 = d.path("e1");
    _ = try proc.run(d.a(), .{ .argv = &.{ try stub(d.a()), "say", "out", "err" }, .env = &.{}, .stdout_path = o1, .stderr_path = e1 });
    try testing.expectEqualStrings("out", try d.read("o1"));
    try testing.expectEqualStrings("err", try d.read("e1"));
    _ = try proc.run(d.a(), .{ .argv = &.{ try stub(d.a()), "say", "out", "err" }, .env = &.{}, .stdout_path = d.path("both"), .stderr_to_stdout = true });
    try testing.expectEqualStrings("outerr", try d.read("both"));
}

test "stderr_to_stdout wins over stderr_path, whose file is still created empty" {
    var d = try Dir.init();
    defer d.deinit();
    _ = try proc.run(d.a(), .{ .argv = &.{ try stub(d.a()), "say", "out", "err" }, .env = &.{}, .stdout_path = d.path("both"), .stderr_path = d.path("unused"), .stderr_to_stdout = true });
    try testing.expectEqualStrings("outerr", try d.read("both"));
    try testing.expectEqualStrings("", try d.read("unused"));
}

test "an exit status is the program's own, and 128 + N for a signal" {
    var d = try Dir.init();
    defer d.deinit();
    const ok = try proc.run(d.a(), .{ .argv = &.{ try stub(d.a()), "exit", "0" }, .env = &.{} });
    try testing.expectEqual(proc.Status{ .exited = 0 }, ok.status);
    const three = try proc.run(d.a(), .{ .argv = &.{ try stub(d.a()), "exit", "3" }, .env = &.{} });
    try testing.expectEqual(proc.Status{ .exited = 3 }, three.status);
    try testing.expectEqual(@as(u8, 3), three.shellStatus());
    const killed = try proc.run(d.a(), .{ .argv = &.{ try stub(d.a()), "kill" }, .env = &.{} });
    try testing.expectEqual(proc.Status{ .signaled = 9 }, killed.status);
    try testing.expectEqual(@as(u8, 137), killed.shellStatus());
}

test "a program that cannot start is 127, its reason on stderr; no PATH is searched" {
    var d = try Dir.init();
    defer d.deinit();
    const o = try proc.run(d.a(), .{ .argv = &.{"stub-that-is-not-a-path"}, .env = &.{"PATH=/usr/bin:/bin"}, .stderr_path = d.path("err") });
    try testing.expectEqual(@as(u8, 127), o.shellStatus());
    const text = try d.read("err");
    try testing.expect(std.mem.startsWith(u8, text, "proc: cannot run stub-that-is-not-a-path: errno "));
    // Not executable: another errno, the same status.
    try d.tmp.dir.writeFile(.{ .sub_path = "plain", .data = "text" });
    const p = try proc.run(d.a(), .{ .argv = &.{d.path("plain")}, .env = &.{}, .stderr_path = d.path("err2") });
    try testing.expectEqual(@as(u8, 127), p.shellStatus());
    try testing.expect(std.mem.indexOf(u8, try d.read("err2"), "proc: cannot run ") != null);
}

test "a file that cannot be created is an error, not a started program" {
    var d = try Dir.init();
    defer d.deinit();
    try testing.expectError(error.FileNotFound, proc.run(d.a(), .{ .argv = &.{ try stub(d.a()), "exit", "0" }, .env = &.{}, .stdout_path = d.path("no/such/dir/out") }));
}

test "envFromMap lists NAME=VALUE sorted by name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = std.process.EnvMap.init(a);
    try m.put("B", "2");
    try m.put("A", "1");
    try m.put("C", "x=y");
    const got = try proc.envFromMap(a, &m);
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("A=1", got[0]);
    try testing.expectEqualStrings("B=2", got[1]);
    try testing.expectEqualStrings("C=x=y", got[2]);
}
