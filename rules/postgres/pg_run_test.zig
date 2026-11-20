//! Unit tests of pg_run.zig with a fake platform: a clock that only counts, a "server" that writes `postmaster.pid` into the data directory and an
//! "initdb" and a test program that only answer. The real platform is tested in pg_plat_test.zig, the real programs in pg_exe_test.zig.
//!
//! What is held:
//!   - the command line, the environment's variable names, the encoding of the socket directory in the URL, and the binary patch (several occurrences,
//!     one at the very end of the file without a NUL, a prefix too long, none);
//!   - the whole run: the install (patched copies, links), initdb and the server with their exact command lines, the readiness test, the program with
//!     the URL in its environment (replacing a variable of that name), the stop, and both directories removed, whatever happened;
//!   - every failure of the fixture is one exact line and exit 1; the program's own status otherwise (127 not there, 126 not runnable);
//!   - every allocation failing in turn is `out of memory` and exit 1 with the directories removed.

const std = @import("std");
const R = @import("pg_run.zig");
const t = std.testing;

const placeholder = "/opt/cbuild/" ++ "h" ** 243;
const ready_text = "123\n/data\n1700000000\n5432\n/tmp\n\n  123 456\nready   \n";
const starting_text = "123\n/data\n1700000000\n5432\n/tmp\n\n  123 456\nstarting\n";

const PgMode = enum { ready, exits_early, never_ready, dies_during_test, ignores_sigint, bad_stop };

const init_pid: R.Pid = 100;
const pg_pid: R.Pid = 200;
const test_pid: R.Pid = 300;

const Fake = struct {
    a: std.mem.Allocator,
    now: u64 = 0,
    sleeps: u64 = 0,
    hex_counter: u32 = 0,
    // the script
    initdb_status: u8 = 0,
    initdb_error: ?anyerror = null,
    pg_error: ?anyerror = null,
    pg: PgMode = .ready,
    pg_status: u8 = 0,
    program_status: u8 = 0,
    program_error: ?anyerror = null,
    /// What `postmaster.pid` holds after the server is started, and after each following sleep (the last one stays).
    stages: []const []const u8 = &.{ready_text},
    // what happened
    events: std.ArrayList([]const u8) = .empty,
    initdb_argv: []const []const u8 = &.{},
    pg_argv: []const []const u8 = &.{},
    program_argv: []const []const u8 = &.{},
    initdb_env: ?[]const u8 = null,
    program_url: ?[]const u8 = null,
    program_old: ?[]const u8 = null,
    program_path: ?[]const u8 = null,
    stdin_null: [3]bool = .{ false, false, false },
    sigint_sent: bool = false,
    killed: bool = false,
    program_done: bool = false,
    stage: usize = 0,
    pid_file: []const u8 = "",
    // what the install had made when initdb was started
    snap_initdb: []const u8 = "",
    snap_postgres: []const u8 = "",
    snap_mode: u32 = 0,
    snap_lib: []const u8 = "",
    snap_share: []const u8 = "",
    sock_dir_there: bool = false,

    fn log(f: *Fake, text: []const u8) void {
        f.events.append(f.a, f.a.dupe(u8, text) catch unreachable) catch unreachable;
    }

    /// A copy of a command line: the caller may build it on its stack.
    fn keep(f: *Fake, argv: []const []const u8) []const []const u8 {
        const out = f.a.alloc([]const u8, argv.len) catch unreachable;
        for (argv, out) |arg, *slot| slot.* = f.a.dupe(u8, arg) catch unreachable;
        return out;
    }

    fn plat(f: *Fake) R.Plat {
        return .{ .ctx = f, .spawn = spawn, .poll = poll, .wait = wait, .kill = kill, .sleepMs = sleepMs, .nowMs = nowMs, .randomHex = randomHex };
    }

    fn self(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }

    fn dataDir(argv: []const []const u8) []const u8 {
        for (argv, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "-D")) return argv[i + 1];
        }
        unreachable;
    }

    fn writeStage(f: *Fake) void {
        if (f.stage >= f.stages.len) return;
        const text = f.stages[f.stage];
        std.fs.cwd().writeFile(.{ .sub_path = f.pid_file, .data = text }) catch unreachable;
    }

    fn spawn(ctx: *anyopaque, a: std.mem.Allocator, argv: []const []const u8, env: *const std.process.EnvMap, stdin_null: bool) anyerror!R.Pid {
        const f = self(ctx);
        _ = a;
        const name = std.fs.path.basename(argv[0]);
        if (std.mem.eql(u8, name, "initdb")) {
            f.log("initdb");
            f.initdb_argv = f.keep(argv);
            f.stdin_null[0] = stdin_null;
            f.initdb_env = env.get("LC_ALL");
            if (f.initdb_error) |e| return e;
            const cwd = std.fs.cwd();
            f.snap_initdb = cwd.readFileAlloc(f.a, argv[0], 1 << 20) catch "";
            const pg_bin = std.fs.path.dirname(argv[0]).?;
            f.snap_postgres = cwd.readFileAlloc(f.a, std.fmt.allocPrint(f.a, "{s}/postgres", .{pg_bin}) catch unreachable, 1 << 20) catch "";
            f.snap_mode = if (cwd.statFile(argv[0])) |st| @intCast(st.mode & 0o777) else |_| 0;
            const pg_dir = std.fs.path.dirname(pg_bin).?;
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            f.snap_lib = f.a.dupe(u8, cwd.readLink(std.fmt.allocPrint(f.a, "{s}/lib", .{pg_dir}) catch unreachable, &buf) catch "") catch unreachable;
            f.snap_share = f.a.dupe(u8, cwd.readLink(std.fmt.allocPrint(f.a, "{s}/share", .{pg_dir}) catch unreachable, &buf) catch "") catch unreachable;
            cwd.makePath(dataDir(argv)) catch unreachable;
            return init_pid;
        }
        if (std.mem.eql(u8, name, "postgres")) {
            f.log("postgres");
            f.pg_argv = f.keep(argv);
            f.stdin_null[1] = stdin_null;
            if (f.pg_error) |e| return e;
            f.sock_dir_there = if (std.fs.cwd().access(argv[4], .{})) |_| true else |_| false;
            f.pid_file = std.fmt.allocPrint(f.a, "{s}/postmaster.pid", .{dataDir(argv)}) catch unreachable;
            f.stage = 0;
            f.sigint_sent = false;
            f.killed = false;
            f.program_done = false;
            f.writeStage();
            return pg_pid;
        }
        f.log("program");
        f.program_argv = f.keep(argv);
        f.stdin_null[2] = stdin_null;
        f.program_url = if (env.get("PGDEMO_URL")) |v| f.a.dupe(u8, v) catch unreachable else null;
        f.program_old = env.get("KEEP");
        if (f.program_error) |e| return e;
        return test_pid;
    }

    fn poll(ctx: *anyopaque, pid: R.Pid) ?u8 {
        const f = self(ctx);
        std.debug.assert(pid == pg_pid);
        return switch (f.pg) {
            .exits_early => f.pg_status,
            .dies_during_test => if (f.program_done) f.pg_status else null,
            .ready => if (f.sigint_sent) 0 else null,
            .bad_stop => if (f.sigint_sent) f.pg_status else null,
            .never_ready, .ignores_sigint => if (f.killed) 137 else null,
        };
    }

    fn wait(ctx: *anyopaque, pid: R.Pid) u8 {
        const f = self(ctx);
        switch (pid) {
            init_pid => {
                f.log("wait initdb");
                return f.initdb_status;
            },
            test_pid => {
                f.log("wait program");
                f.program_done = true;
                return f.program_status;
            },
            else => {
                f.log("wait postgres");
                return 137;
            },
        }
    }

    fn kill(ctx: *anyopaque, pid: R.Pid, sig: u8) void {
        const f = self(ctx);
        std.debug.assert(pid == pg_pid);
        f.log(if (sig == R.sigint) "kill INT" else "kill KILL");
        if (sig == R.sigint) f.sigint_sent = true else f.killed = true;
    }

    fn sleepMs(ctx: *anyopaque, ms: u64) void {
        const f = self(ctx);
        f.now += ms;
        f.sleeps += 1;
        f.stage += 1;
        f.writeStage();
    }

    fn nowMs(ctx: *anyopaque) u64 {
        return self(ctx).now;
    }

    fn randomHex(ctx: *anyopaque, out: *[8]u8) void {
        const f = self(ctx);
        f.hex_counter += 1;
        out.* = std.fmt.bytesToHex(std.mem.toBytes(std.mem.nativeToBig(u32, f.hex_counter)), .lower);
    }
};

const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: t.TmpDir,
    root: []const u8 = "",
    environ: []const []const u8 = &.{},
    fake: Fake,

    fn init(c: *Case) !void {
        c.arena = std.heap.ArenaAllocator.init(t.allocator);
        c.tmp = t.tmpDir(.{ .iterate = true });
        const al = c.arena.allocator();
        c.fake = .{ .a = al };
        c.root = try c.tmp.dir.realpathAlloc(al, ".");
        try c.tmp.dir.makePath("scratch");
        try c.tmp.dir.makePath("tmp");
        try c.tmp.dir.makePath("prefix/bin");
        try c.tmp.dir.makePath("prefix/lib");
        try c.tmp.dir.makePath("prefix/share");
        try c.tmp.dir.writeFile(.{ .sub_path = "prefix/buildrules-placeholder.txt", .data = placeholder });
        try c.tmp.dir.writeFile(.{ .sub_path = "prefix/bin/initdb", .data = binary("INITDB") });
        try c.tmp.dir.writeFile(.{ .sub_path = "prefix/bin/postgres", .data = binary("POSTGRES") });
        c.environ = try c.env(&.{ "PATH=/usr/bin", "NOEQUALS", "PGDEMO_URL=old", "KEEP=kept" });
        c.fake.stages = &.{ready_text};
    }

    fn deinit(c: *Case) void {
        c.tmp.cleanup();
        c.arena.deinit();
    }

    fn a(c: *Case) std.mem.Allocator {
        return c.arena.allocator();
    }

    fn p(c: *Case, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(c.a(), fmt, args) catch unreachable;
    }

    /// The process environment of a run: `extra` and the scratch path and TMPDIR of the case.
    fn env(c: *Case, extra: []const []const u8) ![]const []const u8 {
        var list = std.ArrayList([]const u8).empty;
        try list.appendSlice(c.a(), extra);
        try list.append(c.a(), c.p("BUCK_SCRATCH_PATH={s}/scratch", .{c.root}));
        try list.append(c.a(), c.p("TMPDIR={s}/tmp", .{c.root}));
        return list.items;
    }

    const Result = struct { status: u8, err: []const u8 };

    fn runIo(c: *Case, args: []const []const u8, mutate: ?*const fn (*R.Io) void) !Result {
        var err = std.Io.Writer.Allocating.init(c.a());
        var io = R.Io{ .err = &err.writer, .environ = c.environ, .cwd = c.root, .plat = c.fake.plat(), .sock_path_max = 4000 };
        if (mutate) |m| m(&io);
        const status = R.run(c.a(), io, args);
        return .{ .status = status, .err = err.written() };
    }

    fn run(c: *Case, args: []const []const u8) !Result {
        return c.runIo(args, null);
    }

    /// The usual command line with `program` as the program.
    fn line(c: *Case, program: []const u8) []const []const u8 {
        const out = c.a().alloc([]const u8, 8) catch unreachable;
        @memcpy(out, &[_][]const u8{ "--prefix", "prefix", "--url-env", "PGDEMO_URL", "--", program, "one", "two" });
        return out;
    }

    /// An environment of a run with the scratch path and TMPDIR given.
    fn envOf(c: *Case, scratch: []const u8, tmp: []const u8) []const []const u8 {
        const out = c.a().alloc([]const u8, 3) catch unreachable;
        out[0] = "PATH=/usr/bin";
        out[1] = c.p("BUCK_SCRATCH_PATH={s}", .{scratch});
        out[2] = c.p("TMPDIR={s}", .{tmp});
        return out;
    }

    fn exists(c: *Case, name: []const u8) bool {
        c.tmp.dir.access(name, .{}) catch return false;
        return true;
    }

    /// The run directory and the socket directory are gone, and the scratch path and TMPDIR hold nothing.
    fn expectClean(c: *Case) !void {
        for ([_][]const u8{ "scratch", "tmp" }) |d| {
            var dir = try c.tmp.dir.openDir(d, .{ .iterate = true });
            defer dir.close();
            var it = dir.iterate();
            try t.expect((try it.next()) == null);
        }
    }
};

/// The content of a fake binary: the placeholder at the start of a C string, twice in another, and at the very end of the file with no NUL.
fn binary(comptime name: []const u8) []const u8 {
    return "\x7fELF" ++ name ++ "\x00" ++ placeholder ++ "/share/zoneinfo\x00mid\x00-L" ++ placeholder ++ "/lib:" ++ placeholder ++ "/x\x00tail\x00" ++ placeholder;
}

fn nuls(a: std.mem.Allocator, n: usize) ![]const u8 {
    const out = try a.alloc(u8, n);
    @memset(out, 0);
    return out;
}

/// `binary(name)` as it is when the placeholder is replaced by `prefix`.
fn patched(a: std.mem.Allocator, comptime name: []const u8, prefix: []const u8) ![]const u8 {
    const pad = try nuls(a, placeholder.len - prefix.len);
    const two_pad = try nuls(a, 2 * (placeholder.len - prefix.len));
    return std.mem.concat(a, u8, &.{ "\x7fELF" ++ name ++ "\x00", prefix, "/share/zoneinfo", pad, "\x00mid\x00-L", prefix, "/lib:", prefix, "/x", two_pad, "\x00tail\x00", prefix, pad });
}

test "isName takes [A-Za-z_][A-Za-z0-9_]* and nothing else" {
    for ([_][]const u8{ "A", "_", "PGDEMO_URL", "a1", "_9" }) |s| try t.expect(R.isName(s));
    for ([_][]const u8{ "", "1A", "A-B", "A B", "A=", "É" }) |s| try t.expect(!R.isName(s));
}

test "percentEncode leaves [A-Za-z0-9._~-] and writes every other byte as %XX in uppercase" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("%2Ftmp%2Fbuildrules_pgs.1a2b3c4d-x~y", try R.percentEncode(a, "/tmp/buildrules_pgs.1a2b3c4d-x~y"));
    try t.expectEqualStrings("a%20b%25c%3A%40%7F%C3%A9", try R.percentEncode(a, "a b%c:@\x7f\xc3\xa9"));
    try t.expectEqualStrings("", try R.percentEncode(a, ""));
    var fail = t.FailingAllocator.init(a, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, R.percentEncode(fail.allocator(), "ab"));
    var fail2 = t.FailingAllocator.init(a, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, R.percentEncode(fail2.allocator(), "/"));
}

test "patch replaces the placeholder conda's way: each C string that holds it is rewritten and padded with NULs to its old length, the file keeps its size" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const ph = "/PLACEHOLDER";
    const out = try R.patch(a, "A\x00" ++ ph ++ "/share\x00B" ++ ph ++ "x" ++ ph ++ "y\x00C" ++ ph, ph, "/run/pg");
    try t.expectEqualSlices(u8, "A\x00/run/pg/share\x00\x00\x00\x00\x00\x00B" ++ "/run/pg" ++ "x/run/pgy" ++ "\x00" ** 10 ++ "\x00C" ++ "/run/pg" ++ "\x00" ** 5, out);
    try t.expectEqual(@as(usize, 2 + 18 + 1 + (1 + 12 + 1 + 12 + 1) + 1 + 1 + 12), out.len);
    // a prefix as long as the placeholder fills the string exactly
    try t.expectEqualSlices(u8, "xx/ABCDEFGHIJxx\x00", try R.patch(a, "xx" ++ ph ++ "x\x00", ph, "/ABCDEFGHIJx"));
    // no occurrence: the same bytes, as a copy
    const same = try R.patch(a, "nothing here\x00", ph, "/run");
    try t.expectEqualStrings("nothing here\x00", same);
    try t.expectEqualStrings("", try R.patch(a, "", ph, "/run"));
}

test "patch refuses a prefix longer than the placeholder and an empty placeholder, and fails cleanly when memory runs out" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectError(error.PrefixTooLong, R.patch(a, "x", "/short", "/much/longer"));
    try t.expectError(error.EmptyPlaceholder, R.patch(a, "x", "", "/p"));
    var fail = t.FailingAllocator.init(a, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, R.patch(fail.allocator(), "x", "/s", "/p"));
}

test "isReady is true only when the 8th line, trimmed of spaces, is ready" {
    try t.expect(R.isReady(ready_text));
    try t.expect(R.isReady("1\n2\n3\n4\n5\n6\n7\nready"));
    try t.expect(R.isReady("1\n2\n3\n4\n5\n6\n7\n  ready  \nmore\n"));
    try t.expect(!R.isReady(starting_text));
    try t.expect(!R.isReady(""));
    try t.expect(!R.isReady("1\n2\n3\n"));
    try t.expect(!R.isReady("1\n2\n3\n4\n5\n6\nready\n"));
    try t.expect(!R.isReady("1\n2\n3\n4\n5\n6\n7\nnot ready\n"));
}

test "the command line: wrong ones are exit 2 with one exact line" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    const usage = "; usage: pg_run --prefix DIR --url-env NAME -- PROGRAM [ARG]...\n";
    const cases = [_]struct { args: []const []const u8, line: []const u8 }{
        .{ .args = &.{}, .line = "pg_run: --prefix is required" ++ usage },
        .{ .args = &.{ "--url-env", "X", "--", "/p" }, .line = "pg_run: --prefix is required" ++ usage },
        .{ .args = &.{ "--prefix", "d", "--", "/p" }, .line = "pg_run: --url-env is required" ++ usage },
        .{ .args = &.{ "--prefix", "d", "--url-env", "X" }, .line = "pg_run: the program is missing after --" ++ usage },
        .{ .args = &.{ "--prefix", "d", "--url-env", "X", "--" }, .line = "pg_run: the program is missing after --" ++ usage },
        .{ .args = &.{ "--prefix", "d", "--url-env", "X", "--prefix", "e", "--", "/p" }, .line = "pg_run: --prefix is given twice" ++ usage },
        .{ .args = &.{ "--prefix", "d", "--url-env", "X", "--url-env", "Y", "--", "/p" }, .line = "pg_run: --url-env is given twice" ++ usage },
        .{ .args = &.{ "--prefix", "d", "--bogus", "e", "--", "/p" }, .line = "pg_run: --bogus is not an option pg_run takes" ++ usage },
        .{ .args = &.{ "--prefix", "d", "--url-env" }, .line = "pg_run: --url-env needs a value" ++ usage },
        .{ .args = &.{ "--prefix", "d", "--url-env", "1X", "--", "/p" }, .line = "pg_run: 1X is not an environment variable name" ++ usage },
        .{ .args = &.{ "--prefix", "d", "--url-env", "A-B", "--", "/p" }, .line = "pg_run: A-B is not an environment variable name" ++ usage },
        .{ .args = &.{ "--prefix", "d", "--url-env", "", "--", "/p" }, .line = "pg_run:  is not an environment variable name" ++ usage },
        .{ .args = &.{ "--prefix", "d", "--url-env", "X", "--", "prog", "a" }, .line = "pg_run: prog is not a path: a program is never looked for in a PATH, give its path\n" },
    };
    for (cases) |case| {
        const r = try c.run(case.args);
        try t.expectEqualStrings(case.line, r.err);
        try t.expectEqual(@as(u8, 2), r.status);
    }
    try t.expectEqual(@as(usize, 0), c.fake.events.items.len);
    try c.expectClean();
}

test "a run: the install, initdb and the server with their command lines, the program with the URL in its environment, the stop, everything removed" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    c.fake.program_status = 0;
    const r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings("", r.err);
    try t.expectEqual(@as(u8, 0), r.status);
    const run_dir = c.p("{s}/scratch/buildrules_pg.00000001", .{c.root});
    const sock_dir = c.p("{s}/tmp/buildrules_pgs.00000002", .{c.root});
    const data = c.p("{s}/data", .{run_dir});
    const bin = c.p("{s}/pg/bin", .{run_dir});

    const want_events = [_][]const u8{ "initdb", "wait initdb", "postgres", "program", "wait program", "kill INT" };
    try t.expectEqual(want_events.len, c.fake.events.items.len);
    for (want_events, c.fake.events.items) |w, got| try t.expectEqualStrings(w, got);

    const init_want = [_][]const u8{ c.p("{s}/initdb", .{bin}), "-D", data, "-U", "postgres", "-A", "trust", "-E", "UTF8", "--locale=C", "--no-sync", "--no-instructions" };
    try t.expectEqual(init_want.len, c.fake.initdb_argv.len);
    for (init_want, c.fake.initdb_argv) |w, got| try t.expectEqualStrings(w, got);
    try t.expectEqualStrings("C", c.fake.initdb_env.?);

    const pg_want = [_][]const u8{ c.p("{s}/postgres", .{bin}), "-D", data, "-k", sock_dir, "-p", "5432", "-c", "listen_addresses=", "-c", "fsync=off", "-c", "synchronous_commit=off", "-c", "full_page_writes=off" };
    try t.expectEqual(pg_want.len, c.fake.pg_argv.len);
    for (pg_want, c.fake.pg_argv) |w, got| try t.expectEqualStrings(w, got);
    try t.expect(c.fake.sock_dir_there);

    try t.expectEqual(@as(usize, 3), c.fake.program_argv.len);
    try t.expectEqualStrings("/bin/prog", c.fake.program_argv[0]);
    try t.expectEqualStrings("one", c.fake.program_argv[1]);
    try t.expectEqualStrings("two", c.fake.program_argv[2]);
    // the URL replaces the variable of that name; the rest of the environment is the process's
    try t.expectEqualStrings(c.p("postgresql://postgres@{s}:5432/postgres", .{try R.percentEncode(c.a(), sock_dir)}), c.fake.program_url.?);
    try t.expectEqualStrings("kept", c.fake.program_old.?);
    try t.expectEqual([3]bool{ true, true, false }, c.fake.stdin_null);

    // what the install had made when initdb started
    const prefix = c.p("{s}/prefix", .{c.root});
    try t.expectEqualSlices(u8, try patched(c.a(), "INITDB", c.p("{s}/pg", .{run_dir})), c.fake.snap_initdb);
    try t.expectEqualSlices(u8, try patched(c.a(), "POSTGRES", c.p("{s}/pg", .{run_dir})), c.fake.snap_postgres);
    try t.expectEqual(@as(u32, 0o755), c.fake.snap_mode);
    try t.expectEqualStrings(c.p("{s}/lib", .{prefix}), c.fake.snap_lib);
    try t.expectEqualStrings(c.p("{s}/share", .{prefix}), c.fake.snap_share);
    try c.expectClean();
    // the tree itself is untouched
    try t.expect(c.exists("prefix/bin/postgres"));
}

test "the program's status is the run's status, and a relative program is made absolute against the working directory" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    c.fake.program_status = 42;
    const r = try c.run(c.line("./sub/prog"));
    try t.expectEqual(@as(u8, 42), r.status);
    try t.expectEqualStrings("", r.err);
    try t.expectEqualStrings(c.p("{s}/./sub/prog", .{c.root}), c.fake.program_argv[0]);
    try c.expectClean();
}

test "the base of the run directory is BUCK_SCRATCH_PATH, else TMPDIR, else /tmp (an empty value is unset); the socket directory is in TMPDIR, else /tmp" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    // an empty BUCK_SCRATCH_PATH is as if unset: the run directory is in TMPDIR with the socket directory
    c.environ = c.envOf("", c.p("{s}/tmp", .{c.root}));
    var r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings("", r.err);
    try t.expectEqual(@as(u8, 0), r.status);
    try t.expect(std.mem.startsWith(u8, c.fake.initdb_argv[0], c.p("{s}/tmp/buildrules_pg.00000001/pg/bin/", .{c.root})));
    try c.expectClean();
    // a relative TMPDIR is resolved against the working directory
    c.fake.hex_counter = 0;
    c.environ = c.envOf("", "tmp");
    r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings("", r.err);
    try t.expectEqual(@as(u8, 0), r.status);
    try t.expectEqualStrings(c.p("{s}/tmp/buildrules_pgs.00000002", .{c.root}), c.fake.pg_argv[4]);
    try c.expectClean();
    // no TMPDIR, or an empty one: /tmp (shown by the refusal of a socket path that does not fit, so that nothing is made there)
    const Small = struct {
        fn set(io: *R.Io) void {
            io.sock_path_max = 10;
        }
    };
    const none = [_][]const u8{ "PATH=/usr/bin", "BUCK_SCRATCH_PATH=" };
    const empty = [_][]const u8{"TMPDIR="};
    for ([_][]const []const u8{ &none, &empty }) |environ| {
        c.fake.hex_counter = 0;
        c.environ = environ;
        r = try c.runIo(c.line("/bin/prog"), Small.set);
        try t.expectEqualStrings("pg_run: the server's socket path /tmp/buildrules_pgs.00000002/.s.PGSQL.5432 is 42 bytes, more than the 10 a Unix socket path holds; give the action a shorter TMPDIR\n", r.err);
        try t.expectEqual(@as(u8, 1), r.status);
    }
}

test "the server is ready only when postmaster.pid says so: a missing file, a short one and a starting one are waited through, on the clock" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    c.fake.stages = &.{ "", "1\n2\n3\n", starting_text, starting_text, ready_text };
    const r = try c.run(c.line("/bin/prog"));
    try t.expectEqual(@as(u8, 0), r.status);
    try t.expectEqual(@as(u64, 4), c.fake.sleeps);
    try t.expectEqual(@as(u64, 80), c.fake.now);
    try c.expectClean();
}

test "a server that is not ready within 300 s of the clock is killed and the run fails with exit 1 whatever the program would have said" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    c.fake.pg = .never_ready;
    c.fake.stages = &.{starting_text};
    const r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings("pg_run: postgres was not ready within 300 s; it was stopped\n", r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    try t.expectEqual(@as(u64, 300_000), c.fake.now);
    try t.expectEqual(@as(u64, 15_000), c.fake.sleeps);
    try t.expect(c.fake.killed);
    try t.expectEqualStrings("wait postgres", c.fake.events.items[c.fake.events.items.len - 1]);
    try t.expectEqualStrings("kill KILL", c.fake.events.items[c.fake.events.items.len - 2]);
    try t.expect(c.fake.program_argv.len == 0);
    try c.expectClean();
}

test "a server that exits before it is ready fails the run, with its status" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    c.fake.pg = .exits_early;
    c.fake.pg_status = 1;
    c.fake.stages = &.{};
    const r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings("pg_run: postgres exited 1 before it was ready\n", r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    try t.expect(c.fake.program_argv.len == 0);
    try t.expectEqual(@as(u64, 0), c.fake.sleeps);
    try c.expectClean();
}

test "initdb failing, or not startable, or the server not startable: one line, exit 1, no server started after initdb" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    c.fake.initdb_status = 3;
    var r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings("pg_run: initdb exited 3\n", r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    try t.expect(c.fake.pg_argv.len == 0);
    try c.expectClean();
    c.fake.initdb_status = 0;
    c.fake.initdb_error = error.FileNotFound;
    r = try c.run(c.line("/bin/prog"));
    try t.expect(std.mem.startsWith(u8, r.err, "pg_run: cannot run "));
    try t.expect(std.mem.endsWith(u8, r.err, "/pg/bin/initdb: FileNotFound\n"));
    try t.expectEqual(@as(u8, 1), r.status);
    c.fake.initdb_error = null;
    c.fake.pg_error = error.AccessDenied;
    r = try c.run(c.line("/bin/prog"));
    try t.expect(std.mem.endsWith(u8, r.err, "/pg/bin/postgres: AccessDenied\n"));
    try t.expectEqual(@as(u8, 1), r.status);
    try c.expectClean();
}

test "a program that is not there is 127, one that cannot be run is 126, each said and the server stopped" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    c.fake.program_error = error.FileNotFound;
    var r = try c.run(c.line("/no/such"));
    try t.expectEqualStrings("pg_run: cannot run /no/such: FileNotFound\n", r.err);
    try t.expectEqual(@as(u8, 127), r.status);
    try t.expect(c.fake.sigint_sent);
    c.fake.program_error = error.AccessDenied;
    c.fake.sigint_sent = false;
    r = try c.run(c.line("/etc/passwd"));
    try t.expectEqualStrings("pg_run: cannot run /etc/passwd: AccessDenied\n", r.err);
    try t.expectEqual(@as(u8, 126), r.status);
    try t.expect(c.fake.sigint_sent);
    try c.expectClean();
}

test "a server that is gone when the test ends fails the run even if the program passed, and is not sent a signal" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    c.fake.pg = .dies_during_test;
    c.fake.pg_status = 7;
    const r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings("pg_run: postgres exited 7 while the test ran\n", r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    try t.expect(!c.fake.sigint_sent);
    try c.expectClean();
}

test "a server that fails when it is stopped fails the run even if the program passed" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    c.fake.pg = .bad_stop;
    c.fake.pg_status = 2;
    const r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings("pg_run: postgres exited 2 when it was stopped\n", r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    try c.expectClean();
}

test "a server that ignores SIGINT is killed after 120 s of the clock, and that is a failure of the run" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    c.fake.pg = .ignores_sigint;
    c.fake.program_status = 5;
    const r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings("pg_run: postgres exited 137 when it was stopped\n", r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    try t.expect(c.fake.killed);
    try t.expectEqual(@as(u64, 120_000), c.fake.now);
    try c.expectClean();
}

test "a socket path over the bound is refused before anything is made, and one of exactly the bound is taken" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    const sock_len = c.p("{s}/tmp/buildrules_pgs.00000002/.s.PGSQL.5432", .{c.root}).len;
    const Bound = struct {
        var at: usize = 0;
        fn set(io: *R.Io) void {
            io.sock_path_max = at;
        }
    };
    Bound.at = sock_len - 1;
    var r = try c.runIo(c.line("/bin/prog"), Bound.set);
    try t.expectEqualStrings(c.p("pg_run: the server's socket path {s}/tmp/buildrules_pgs.00000002/.s.PGSQL.5432 is {d} bytes, more than the {d} a Unix socket path holds; give the action a shorter TMPDIR\n", .{ c.root, sock_len, sock_len - 1 }), r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    try t.expectEqual(@as(usize, 0), c.fake.events.items.len);
    try c.expectClean();
    c.fake.hex_counter = 0;
    Bound.at = sock_len;
    r = try c.runIo(c.line("/bin/prog"), Bound.set);
    try t.expectEqualStrings("", r.err);
    try t.expectEqual(@as(u8, 0), r.status);
    // the real bound is the one of sun_path
    try t.expectEqual(@as(usize, 107), R.sun_path_max);
}

test "a scratch path or a TMPDIR that cannot be made is one line, exit 1, nothing left" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    try c.tmp.dir.writeFile(.{ .sub_path = "afile", .data = "x" });
    c.environ = c.envOf(c.p("{s}/afile/x", .{c.root}), c.p("{s}/tmp", .{c.root}));
    var r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings(c.p("pg_run: cannot make {s}/afile/x/buildrules_pg.00000001: NotDir\n", .{c.root}), r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    c.fake.hex_counter = 0;
    c.environ = c.envOf(c.p("{s}/scratch", .{c.root}), c.p("{s}/afile/y", .{c.root}));
    r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings(c.p("pg_run: cannot make {s}/afile/y/buildrules_pgs.00000002: NotDir\n", .{c.root}), r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    try c.expectClean();
    try t.expectEqual(@as(usize, 0), c.fake.events.items.len);
}

test "a placeholder file or binary of the tree that is missing, an empty placeholder, a run directory longer than the placeholder: one line, exit 1, nothing left" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    try c.tmp.dir.rename("prefix/buildrules-placeholder.txt", "prefix/ph");
    var r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings(c.p("pg_run: cannot read {s}/prefix/buildrules-placeholder.txt: FileNotFound\n", .{c.root}), r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    c.fake.hex_counter = 0;
    try c.tmp.dir.writeFile(.{ .sub_path = "prefix/buildrules-placeholder.txt", .data = "" });
    r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings(c.p("pg_run: {s}/prefix/buildrules-placeholder.txt is empty\n", .{c.root}), r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    c.fake.hex_counter = 0;
    try c.tmp.dir.writeFile(.{ .sub_path = "prefix/buildrules-placeholder.txt", .data = "/short" });
    r = try c.run(c.line("/bin/prog"));
    const pg = c.p("{s}/scratch/buildrules_pg.00000001/pg", .{c.root});
    try t.expectEqualStrings(c.p("pg_run: the run directory {s} ({d} bytes) is longer than the prefix placeholder of {s}/prefix/bin/postgres (6 bytes); give the action a shorter scratch path\n", .{ pg, pg.len, c.root }), r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    c.fake.hex_counter = 0;
    try c.tmp.dir.writeFile(.{ .sub_path = "prefix/buildrules-placeholder.txt", .data = placeholder });
    try c.tmp.dir.rename("prefix/bin/initdb", "prefix/bin/initdb.moved");
    r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings(c.p("pg_run: cannot read {s}/prefix/bin/initdb: FileNotFound\n", .{c.root}), r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    try c.expectClean();
    try t.expectEqual(@as(usize, 0), c.fake.events.items.len);
}

test "what is already in the run directory is in the way: a pg that is a file, a binary that is a directory, a lib that is there" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    const dir = "scratch/buildrules_pg.00000001";
    try c.tmp.dir.makePath(dir);
    try c.tmp.dir.writeFile(.{ .sub_path = dir ++ "/pg", .data = "x" });
    var r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings(c.p("pg_run: cannot make {s}/{s}/pg/bin: NotDir\n", .{ c.root, dir }), r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    c.fake.hex_counter = 0;
    try c.tmp.dir.makePath(dir ++ "/pg/bin/postgres");
    r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings(c.p("pg_run: cannot write {s}/{s}/pg/bin/postgres: IsDir\n", .{ c.root, dir }), r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    c.fake.hex_counter = 0;
    try c.tmp.dir.makePath(dir ++ "/pg/lib");
    r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings(c.p("pg_run: cannot link {s}/{s}/pg/lib: PathAlreadyExists\n", .{ c.root, dir }), r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    try c.expectClean();
    try t.expectEqual(@as(usize, 0), c.fake.events.items.len);
}

test "messages go nowhere when stderr is closed, and the status is still right" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    var shut: [0]u8 = undefined;
    var closed = std.Io.Writer.fixed(&shut);
    const io = R.Io{ .err = &closed, .environ = c.environ, .cwd = c.root, .plat = c.fake.plat() };
    try t.expectEqual(@as(u8, 2), R.run(c.a(), io, &.{}));
    c.fake.initdb_status = 1;
    try t.expectEqual(@as(u8, 1), R.run(c.a(), io, c.line("/bin/prog")));
}

test "every allocation failing in turn is out of memory and exit 1, with both directories removed and no server left" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        c.fake = .{ .a = c.a(), .stages = &.{ready_text} };
        c.environ = c.envOf("scratch", "tmp");
        var inner = std.heap.ArenaAllocator.init(t.allocator);
        defer inner.deinit();
        var fail = t.FailingAllocator.init(inner.allocator(), .{ .fail_index = i });
        var err = std.Io.Writer.Allocating.init(c.a());
        const io = R.Io{ .err = &err.writer, .environ = c.environ, .cwd = c.root, .plat = c.fake.plat(), .sock_path_max = 4000 };
        const status = R.run(fail.allocator(), io, c.line("./prog"));
        try c.expectClean();
        if (!fail.has_induced_failure) {
            try t.expectEqual(@as(u8, 0), status);
            return;
        }
        try t.expectEqual(@as(u8, 1), status);
        try t.expectEqualStrings("pg_run: out of memory\n", err.written());
        // a server that was started was stopped
        try t.expect(c.fake.pg_argv.len == 0 or c.fake.sigint_sent);
    }
    return error.SweepDidNotEnd;
}

test "a socket directory that cannot be made is refused naming it, and the run directory made before it is removed" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    try c.tmp.dir.writeFile(.{ .sub_path = "file", .data = "x" });
    c.environ = c.envOf(c.p("{s}/scratch", .{c.root}), c.p("{s}/file/sub", .{c.root}));
    const r = try c.run(c.line("/bin/prog"));
    try t.expectEqualStrings(c.p("pg_run: cannot make {s}/file/sub/buildrules_pgs.00000002: NotDir\n", .{c.root}), r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    try t.expectEqual(@as(usize, 0), c.fake.events.items.len);
    try c.expectClean();
}

test "an empty --prefix is the working directory, which holds no placeholder file: refused naming the file" {
    var c: Case = undefined;
    try c.init();
    defer c.deinit();
    const r = try c.run(&.{ "--prefix", "", "--url-env", "PGDEMO_URL", "--", "/bin/prog" });
    try t.expectEqualStrings(c.p("pg_run: cannot read {s}/buildrules-placeholder.txt: FileNotFound\n", .{c.root}), r.err);
    try t.expectEqual(@as(u8, 1), r.status);
    try c.expectClean();
}
