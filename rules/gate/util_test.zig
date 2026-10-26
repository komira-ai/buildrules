//! The tail every banner prints (util.zig): it must print what busybox
//! `tail -n N` printed in the shell runners, byte for byte, including a final
//! line with no newline. Each case is compared against the busybox of the
//! test action's PATH, run on the same file.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const util = @import("util.zig");
const kit = @import("testkit.zig");
const proctab = @import("proctab.zig");
const supervise = @import("supervise.zig");

fn busyboxTail(alloc: std.mem.Allocator, bb: []const u8, n: usize, path: []const u8, out_path: []const u8) ![]u8 {
    const pid = try posix.fork();
    if (pid == 0) {
        const fd = posix.open(out_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch posix.exit(99);
        posix.dup2(fd, 1) catch posix.exit(99);
        var nbuf: [32]u8 = undefined;
        const ns = std.fmt.bufPrintZ(&nbuf, "{d}", .{n}) catch posix.exit(99);
        const argv = [_:null]?[*:0]const u8{ (alloc.dupeZ(u8, bb) catch posix.exit(99)).ptr, "tail", "-n", ns.ptr, (alloc.dupeZ(u8, path) catch posix.exit(99)).ptr };
        const envp = [_:null]?[*:0]const u8{};
        _ = posix.execveZ(argv[0].?, &argv, &envp) catch {};
        posix.exit(99);
    }
    const st = sys.waitpid(pid, false);
    try std.testing.expectEqual(@as(?u8, 0), st);
    return kit.readFile(alloc, out_path);
}

fn ourTail(alloc: std.mem.Allocator, n: usize, path: []const u8, out_path: []const u8) ![]u8 {
    const fd = try posix.open(out_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    util.writeTail(fd, path, n);
    posix.close(fd);
    return kit.readFile(alloc, out_path);
}

test "tail: 0, 1, 200, 201 and 10,000 lines, with and without a final newline, match busybox tail -n" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bb = try kit.busybox(a);
    const dir = try kit.tempDir(a);
    // Lines long enough that 10,000 of them cross the 64 KiB read block.
    for ([_]usize{ 0, 1, 2, 199, 200, 201, 10_000 }) |lines| {
        for ([_]bool{ true, false }) |final_nl| {
            var text = std.ArrayList(u8).empty;
            var k: usize = 1;
            while (k <= lines) : (k += 1) {
                try text.writer(a).print("line {d} of the test's output, padded to be long\n", .{k});
            }
            if (!final_nl and text.items.len > 0) text.items.len -= 1;
            // An empty line in the middle counts as a line.
            const path = try std.fmt.allocPrint(a, "{s}/log_{d}_{}", .{ dir, lines, final_nl });
            try kit.writeFile(path, text.items);
            for ([_]usize{ 0, 1, 50, 60, 100, 200 }) |n| {
                const want = try busyboxTail(a, bb, n, path, try std.fmt.allocPrint(a, "{s}.bb", .{path}));
                const got = try ourTail(a, n, path, try std.fmt.allocPrint(a, "{s}.ours", .{path}));
                if (!std.mem.eql(u8, want, got)) {
                    std.debug.print("tail -n {d} of {d} lines (final newline {}): busybox {d} bytes, ours {d}\n", .{ n, lines, final_nl, want.len, got.len });
                    return error.TestExpectedEqual;
                }
            }
        }
    }
}

test "tail: blank lines and a lone newline match busybox" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bb = try kit.busybox(a);
    const dir = try kit.tempDir(a);
    for ([_][]const u8{ "\n", "\n\n\n", "a\n\nb", "a\n\n\nb\n", "x" }) |body| {
        const path = try std.fmt.allocPrint(a, "{s}/b{d}", .{ dir, body.len });
        try kit.writeFile(path, body);
        for ([_]usize{ 1, 2, 3 }) |n| {
            const want = try busyboxTail(a, bb, n, path, try std.fmt.allocPrint(a, "{s}.bb", .{path}));
            const got = try ourTail(a, n, path, try std.fmt.allocPrint(a, "{s}.ours", .{path}));
            try std.testing.expectEqualStrings(want, got);
        }
    }
}

test "tailStart agrees with writeTail" {
    try std.testing.expectEqual(@as(usize, 4), util.tailStart("a\nb\nc\n", 1));
    try std.testing.expectEqual(@as(usize, 4), util.tailStart("a\nb\nc", 1));
    try std.testing.expectEqual(@as(usize, 0), util.tailStart("a\nb\nc", 9));
    try std.testing.expectEqual(@as(usize, 5), util.tailStart("a\nb\nc", 0));
}

test "positiveStrict refuses empty, non-digits and a leading zero" {
    try std.testing.expectEqual(@as(?u64, 30), util.positiveStrict("30"));
    for ([_][]const u8{ "", "0", "007", "1a", "-1", " 1" }) |s| {
        try std.testing.expectEqual(@as(?u64, null), util.positiveStrict(s));
    }
}

test "the process table: status and stat parsing" {
    const st = "Name:\tcat\nState:\tS (sleeping)\nTgid:\t42\nPid:\t42\nPPid:\t7\nTracerPid:\t0\nVmRSS:\t    1234 kB\n";
    const p = proctab.parseStatus(st).?;
    try std.testing.expectEqual(@as(i32, 42), p.pid);
    try std.testing.expectEqual(@as(i32, 7), p.ppid);
    try std.testing.expectEqual(@as(u8, 'S'), p.state);
    try std.testing.expectEqual(@as(u64, 1234), p.rss_kib);
    const s = proctab.parseStat("99 (a b) c)) Z 1 77 77 0").?;
    try std.testing.expectEqual(@as(i32, 99), s.pid);
    try std.testing.expectEqualStrings("a b) c)", s.comm);
    try std.testing.expectEqual(@as(u8, 'Z'), s.state);
    try std.testing.expectEqual(@as(i32, 77), s.pgrp);
}

test "the process table: the tree of a root, and a zombie root is gone" {
    var procs = [_]proctab.Proc{
        .{ .pid = 1, .ppid = 0, .state = 'S', .rss_kib = 5 },
        .{ .pid = 10, .ppid = 1, .state = 'S', .rss_kib = 100 },
        .{ .pid = 11, .ppid = 10, .state = 'R', .rss_kib = 200 },
        .{ .pid = 12, .ppid = 11, .state = 'S', .rss_kib = 300 },
        .{ .pid = 13, .ppid = 1, .state = 'S', .rss_kib = 400 },
        .{ .pid = 14, .ppid = 1, .state = 'Z', .rss_kib = 0 },
    };
    const t = proctab.Table{ .procs = &procs };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const tree = t.tree(arena.allocator(), 10).?;
    try std.testing.expectEqual(@as(usize, 3), tree.len);
    try std.testing.expectEqual(@as(u64, 600), t.rss(tree));
    try std.testing.expectEqual(@as(?[]i32, null), t.tree(arena.allocator(), 14));
    try std.testing.expectEqual(@as(?[]i32, null), t.tree(arena.allocator(), 99));
}

test "the real process table shows this process" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const t = proctab.read(arena.allocator()).?;
    try std.testing.expect(t.has(sys.getpid()));
    const seen = proctab.selfSeen();
    try std.testing.expectEqual(@as(i64, sys.getpid()), seen[0]);
    try std.testing.expectEqual(@as(i64, sys.getpid()), seen[1]);
}

test "the real clock and sleep, which the supervisor uses unless a test replaces them: a reading exists and never goes back, a zero sleep returns, and the platform defaults are these" {
    const first = sys.monotonicMs().?;
    sys.sleepMs(0);
    const second = sys.monotonicMs().?;
    try std.testing.expect(second >= first);
    const plat = @import("supervise.zig").Platform{};
    try std.testing.expect(plat.now_ms == &sys.monotonicMs);
    try std.testing.expect(plat.sleep_ms == &sys.sleepMs);
    plat.sleep_ms(0);
    try std.testing.expect(plat.now_ms().? >= second);
}

/// An allocator that refuses exactly one allocation, the `fail_at`-th (from 0), and serves every other (std's FailingAllocator keeps refusing after its first).
const OneFailure = struct {
    backing: std.mem.Allocator,
    fail_at: usize,
    n: usize = 0,

    fn allocator(self: *OneFailure) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        defer self.n += 1;
        if (self.n == self.fail_at) return null;
        return self.backing.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        return self.backing.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *OneFailure = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
    }
};

test "the members of a process group: a live member is listed with its name, a zombie is not, an empty group is empty, and a list that cannot be built is null" {
    if (!sys.is_linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const go = try posix.pipe();
    // The child holds still by reading `hold`, which this process never writes: it ends only when killed.
    const hold = try posix.pipe();
    const pid = try posix.fork();
    if (pid == 0) {
        posix.close(go[0]);
        posix.close(hold[1]);
        sys.setsid();
        sys.writeAll(go[1], "s");
        var held: [1]u8 = undefined;
        _ = sys.readFull(hold[0], &held);
        posix.exit(0);
    }
    posix.close(go[1]);
    posix.close(hold[0]);
    defer posix.close(hold[1]);
    // The child leads a group of its own once it has called setsid; it says so when it has.
    var b: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), sys.readFull(go[0], &b));
    var members = proctab.groupMembers(a, pid).?;
    try std.testing.expectEqual(@as(usize, 1), members.len);
    try std.testing.expectEqual(pid, members[0].pid);
    try std.testing.expect(members[0].state != 'Z' and members[0].state != 'X');
    try std.testing.expect(members[0].comm.len > 0);

    // The same group, with an allocator that fails once: at the name, then at the list. Either way the answer is "cannot list", not a member without its name.
    for ([_]usize{ 0, 1 }) |fail_at| {
        var once = OneFailure{ .backing = a, .fail_at = fail_at };
        try std.testing.expectEqual(@as(?[]proctab.Member, null), proctab.groupMembers(once.allocator(), pid));
        try std.testing.expect(once.n > fail_at);
    }

    // Dead but not reaped is a zombie, which is not a member.
    sys.kill(pid, posix.SIG.KILL);
    try kit.waitZombie(pid);
    members = proctab.groupMembers(a, pid).?;
    try std.testing.expectEqual(@as(usize, 0), members.len);
    try std.testing.expectEqual(@as(?u8, 137), sys.waitpid(pid, false));
    // No process leads a group with this id.
    try std.testing.expectEqual(@as(usize, 0), proctab.groupMembers(a, 0x3fffffff).?.len);
}

test "waiting for a process that is not a child of this one reports nothing, with or without reaping" {
    try std.testing.expectEqual(@as(?u8, null), sys.waitpid(sys.getpid(), false));
    try std.testing.expectEqual(@as(?u8, null), sys.waitpid(sys.getpid(), true));
    if (sys.is_linux) try std.testing.expectEqual(@as(?u8, null), sys.exitedNoReap(sys.getpid()));
}

test "a pipe is readable once it has data or has ended, and not before" {
    const p = try posix.pipe();
    defer posix.close(p[0]);
    try std.testing.expect(!sys.readable(p[0]));
    sys.writeAll(p[1], "x");
    try std.testing.expect(sys.readable(p[0]));
    posix.close(p[1]);
    try std.testing.expect(sys.readable(p[0]));
    try std.testing.expect(!sys.readable(-1));
}

// The supervisor takes C's exit from waitid, and from the pidfd when waitid shows nothing although the pidfd says C is
// gone (a coverage tool that traces C holds its exit back from its parent): it waits for waitid then, where it used to
// go round its loop, reading the clock, until the tracer let go. Here the pidfd is readable and waitid shows nothing
// because the child has already been reaped: the call returns at once with nothing, it does not wait.
test "a child's exit: seen by waitid, or by its pidfd with waitid showing nothing; without a pidfd, by waitid alone" {
    if (!sys.is_linux) return error.SkipZigTest;
    const gate = try posix.pipe();
    const pid = try posix.fork();
    if (pid == 0) {
        posix.close(gate[1]);
        var b: [1]u8 = undefined;
        _ = posix.read(gate[0], &b) catch {};
        posix.exit(7);
    }
    posix.close(gate[0]);
    var bare = supervise.Child{ .c = pid, .q = 0, .tether_w = -1, .pidfd = null };
    var fd = supervise.Child{ .c = pid, .q = 0, .tether_w = -1, .pidfd = sys.pidfdOpen(pid) };
    try std.testing.expect(fd.pidfd != null);
    defer posix.close(fd.pidfd.?);
    // Running: neither sees an exit.
    try std.testing.expectEqual(@as(?u8, null), supervise.exited(&bare));
    try std.testing.expectEqual(@as(?u8, null), supervise.exited(&fd));
    // Gone (the gate is closed): both see the status, and the child is still there to be reaped.
    posix.close(gate[1]);
    try std.testing.expectEqual(@as(?u8, 7), sys.waitExitedNoReap(pid));
    try std.testing.expectEqual(@as(?u8, 7), supervise.exited(&bare));
    try std.testing.expectEqual(@as(?u8, 7), supervise.exited(&fd));
    try std.testing.expectEqual(@as(?u8, 7), sys.waitpid(pid, false));
    // Reaped: the pidfd stays readable and waitid has nothing to show; neither call waits.
    try std.testing.expectEqual(@as(?u8, null), supervise.exited(&bare));
    try std.testing.expectEqual(@as(?u8, null), supervise.exited(&fd));
}

test "a directory that cannot be made is an error, not a retry: a missing parent is FileNotFound for one directory and for a list" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try kit.tempDir(a);
    const missing = try std.fmt.allocPrint(a, "{s}/not/there", .{dir});
    try std.testing.expectError(error.FileNotFound, util.makeTempDir(a, missing, ".t."));
    try std.testing.expectError(error.FileNotFound, util.mkdirs(a, missing, &.{ "bin", "tmp" }));
    // A directory that exists is left alone, a new one is made, and two temporary directories are two directories.
    try util.mkdirs(a, dir, &.{ "one", "one", "two" });
    try std.testing.expect(kit.exists(try std.fmt.allocPrint(a, "{s}/two", .{dir})));
    const t1 = try util.makeTempDir(a, dir, ".t.");
    const t2 = try util.makeTempDir(a, dir, ".t.");
    try std.testing.expect(!std.mem.eql(u8, t1, t2));
    try std.testing.expect(kit.exists(t1) and kit.exists(t2));
}

/// Runs `actionDir` with $PWD set to `pwd` (or unset), then restores the environment.
fn actionDirWith(a: std.mem.Allocator, pwd: ?[]const u8) ![]const u8 {
    const saved = std.os.environ;
    defer std.os.environ = saved;
    const z = try a.alloc([*:0]u8, if (pwd == null) 0 else 1);
    if (pwd) |p| z[0] = (try std.fmt.allocPrintSentinel(a, "PWD={s}", .{p}, 0)).ptr;
    std.os.environ = z;
    return util.actionDir(a);
}

test "the action's directory is $PWD where that names the working directory, else what the kernel says" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = try a.dupe(u8, try posix.getcwd(&buf));
    const dir = try kit.tempDir(a);
    // A second name for the working directory: the shell would have kept it.
    const link = try std.fmt.allocPrint(a, "{s}/alias", .{dir});
    try posix.symlink(real, link);
    try std.testing.expectEqualStrings(link, try actionDirWith(a, link));
    // $PWD that is another directory, a relative path, empty, or nothing there is not believed.
    try std.testing.expectEqualStrings(real, try actionDirWith(a, dir));
    // Another directory on the very device of the working directory (its parent, by a link): same device, other inode.
    if (real.len > 1) {
        const up = try std.fmt.allocPrint(a, "{s}/up", .{dir});
        try posix.symlink(std.fs.path.dirname(real) orelse "/", up);
        try std.testing.expectEqualStrings(real, try actionDirWith(a, up));
    }
    try std.testing.expectEqualStrings(real, try actionDirWith(a, "relative/path"));
    try std.testing.expectEqualStrings(real, try actionDirWith(a, ""));
    try std.testing.expectEqualStrings(real, try actionDirWith(a, "/nonexistent/pwd"));
    try std.testing.expectEqualStrings(real, try actionDirWith(a, null));
}

fn Payload(comptime f: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(f)).@"fn".return_type.?).error_union.payload;
}

/// Calls `f(alloc, extra...)` with an allocator that fails at its first allocation, then its second, and so on: every failure must come back as
/// OutOfMemory (nothing else, no crash), and the first call that gets all its memory is returned with the number of calls that did not.
fn afterFailures(comptime f: anytype, backing: std.mem.Allocator, extra: anytype) !struct { failures: usize, value: Payload(f) } {
    var index: usize = 0;
    while (index < 200) : (index += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = index });
        if (@call(.auto, f, .{failing.allocator()} ++ extra)) |value| {
            return .{ .failures = index, .value = value };
        } else |e| try std.testing.expectEqual(error.OutOfMemory, e);
    }
    return error.TestUnexpectedResult;
}

test "an allocation that fails is an OutOfMemory for the caller, at each of the allocations of a helper, and the helper's answer is the same once it succeeds" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try kit.tempDir(a);
    const file = try std.fmt.allocPrint(a, "{s}/f", .{dir});
    try kit.writeFile(file, "contents");

    const abs = try afterFailures(util.abs, a, .{ "/base", "rel" });
    try std.testing.expectEqualStrings("/base/rel", abs.value);
    try std.testing.expect(abs.failures >= 1);
    const abs2 = try afterFailures(util.abs, a, .{ "/base", "/already" });
    try std.testing.expectEqualStrings("/already", abs2.value);

    const rep = try afterFailures(util.replaceAll, a, .{ "a@T@b@T@c", "@T@", "--" });
    try std.testing.expectEqualStrings("a--b--c", rep.value);
    try std.testing.expect(rep.failures >= 1);

    const z = try afterFailures(util.zList, a, .{&[_][]const u8{ "one", "two" }});
    try std.testing.expectEqual(@as(usize, 2), z.value.len);
    try std.testing.expectEqualStrings("two", std.mem.span(z.value[1].?));
    try std.testing.expect(z.failures >= 2);

    const read = try afterFailures(util.readFileAlloc, a, .{file});
    try std.testing.expectEqualStrings("contents", read.value);
    try std.testing.expect(read.failures >= 1);

    const made = try afterFailures(util.makeTempDir, a, .{ dir, ".t." });
    try std.testing.expect(kit.exists(made.value));
    try std.testing.expect(made.failures >= 2);

    const listed = try afterFailures(struct {
        fn f(alloc: std.mem.Allocator, base: []const u8) !void {
            try util.mkdirs(alloc, base, &.{ "m1", "m2" });
        }
    }.f, a, .{dir});
    _ = listed;
    try std.testing.expect(kit.exists(try std.fmt.allocPrint(a, "{s}/m2", .{dir})));

    const here = try afterFailures(util.actionDir, a, .{});
    try std.testing.expect(here.value.len > 0 and here.value[0] == '/');
    try std.testing.expect(here.failures >= 1);
}
