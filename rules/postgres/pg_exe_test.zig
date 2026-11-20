//! The shipped executables as processes (`zig test` of this file run by `:pg_exe_test`; PG_RUN, PG_PREFIX, FAKE_PG and TOOLBOX are the paths the
//! `zig_test`'s `env_tools` pass). The cases in the other files call `run` in-process; these run what `main` adds around it: the command line from argv,
//! the real environment and working directory, the real platform, and the exit status. Without the variables every case fails.
//!
//! pg_run starts fake_pg.zig as the server: a "postgres" that writes `postmaster.pid` as a ready one does and stops on SIGINT, and an "initdb" that
//! makes its data directory; the real Postgres is started by the Rust tests that use the fixture, not here.

const std = @import("std");
const fx = @import("conda_fixture.zig");
const t = std.testing;

fn tool(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, name) catch {
        std.debug.print("the test target does not pass {s} (env_tools), so the executable cannot be run\n", .{name});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

const Run = struct { code: u8, stderr: []const u8 };

/// Runs `argv` in `dir` with exactly `env` as its environment.
fn run(a: std.mem.Allocator, dir: std.fs.Dir, argv: []const []const u8, env: []const [2][]const u8) !Run {
    var map = std.process.EnvMap.init(a);
    for (env) |kv| try map.put(kv[0], kv[1]);
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv, .cwd_dir = dir, .env_map = &map, .max_output_bytes = 1 << 22 });
    const code: u8 = switch (r.term) {
        .Exited => |x| x,
        else => {
            std.debug.print("did not exit: {any}\n", .{r.term});
            return error.TestUnexpectedResult;
        },
    };
    return .{ .code = code, .stderr = r.stderr };
}

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: t.TmpDir,
    root: []const u8,
    env: []const [2][]const u8,

    /// A prefix tree whose bin/postgres and bin/initdb are copies of `fake_pg` (or of `initdb_from` for initdb), and the scratch and tmp directories.
    fn init(f: *Fixture, initdb_from: ?[]const u8) !void {
        f.arena = std.heap.ArenaAllocator.init(t.allocator);
        const al = f.arena.allocator();
        f.tmp = t.tmpDir(.{ .iterate = true });
        f.root = try f.tmp.dir.realpathAlloc(al, ".");
        try f.tmp.dir.makePath("scratch");
        try f.tmp.dir.makePath("tmp");
        try f.tmp.dir.makePath("prefix/bin");
        try f.tmp.dir.makePath("prefix/lib");
        try f.tmp.dir.makePath("prefix/share");
        try f.tmp.dir.writeFile(.{ .sub_path = "prefix/buildrules-placeholder.txt", .data = "/opt/cbuild/" ++ "h" ** 243 });
        const fake = try tool(al, "FAKE_PG");
        try std.fs.cwd().copyFile(fake, f.tmp.dir, "prefix/bin/postgres", .{});
        try std.fs.cwd().copyFile(initdb_from orelse fake, f.tmp.dir, "prefix/bin/initdb", .{});
        const env = try al.alloc([2][]const u8, 2);
        env[0] = .{ "BUCK_SCRATCH_PATH", try std.fmt.allocPrint(al, "{s}/scratch", .{f.root}) };
        env[1] = .{ "TMPDIR", try std.fmt.allocPrint(al, "{s}/tmp", .{f.root}) };
        f.env = env;
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena.deinit();
    }

    fn a(f: *Fixture) std.mem.Allocator {
        return f.arena.allocator();
    }

    /// `pg_run --prefix prefix --url-env PGDEMO_URL -- program...`
    fn pgRun(f: *Fixture, program: []const []const u8) !Run {
        var argv = std.ArrayList([]const u8).empty;
        try argv.appendSlice(f.a(), &.{ try tool(f.a(), "PG_RUN"), "--prefix", "prefix", "--url-env", "PGDEMO_URL", "--" });
        try argv.appendSlice(f.a(), program);
        return run(f.a(), f.tmp.dir, argv.items, f.env);
    }

    fn expectClean(f: *Fixture) !void {
        for ([_][]const u8{ "scratch", "tmp" }) |d| {
            var dir = try f.tmp.dir.openDir(d, .{ .iterate = true });
            defer dir.close();
            var it = dir.iterate();
            try t.expect((try it.next()) == null);
        }
    }
};

test "pg_run starts the server, runs the program with the URL of its socket directory in the environment, stops the server and leaves nothing" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    const fake = try tool(f.a(), "FAKE_PG");
    const r = try f.pgRun(&.{ fake, "check-url", "PGDEMO_URL" });
    try t.expectEqualStrings("", r.stderr);
    try t.expectEqual(@as(u8, 0), r.code);
    try f.expectClean();
}

test "pg_run exits with the program's status, 127 when the program is not there, and 126 when it cannot be run" {
    var f: Fixture = undefined;
    try f.init(null);
    defer f.deinit();
    const fake = try tool(f.a(), "FAKE_PG");
    var r = try f.pgRun(&.{ fake, "exit", "7" });
    try t.expectEqual(@as(u8, 7), r.code);
    try t.expectEqualStrings("", r.stderr);
    r = try f.pgRun(&.{ fake, "check-env", "PGDEMO_URL", "nothing" });
    try t.expectEqual(@as(u8, 1), r.code);
    r = try f.pgRun(&.{"/no/such/program"});
    try t.expectEqual(@as(u8, 127), r.code);
    try t.expectEqualStrings("pg_run: cannot run /no/such/program: FileNotFound\n", r.stderr);
    try f.tmp.dir.writeFile(.{ .sub_path = "plain", .data = "x" });
    r = try f.pgRun(&.{"./plain"});
    try t.expectEqual(@as(u8, 126), r.code);
    try t.expect(std.mem.endsWith(u8, r.stderr, "/plain: AccessDenied\n"));
    try f.expectClean();
}

test "pg_run: a wrong command line is exit 2 with the usage line, and a failing initdb is exit 1 with its status said, nothing left" {
    var f: Fixture = undefined;
    try f.init(try tool(std.heap.page_allocator, "TOOLBOX"));
    defer f.deinit();
    const exe = try tool(f.a(), "PG_RUN");
    const bad = try run(f.a(), f.tmp.dir, &.{exe}, f.env);
    try t.expectEqual(@as(u8, 2), bad.code);
    try t.expectEqualStrings("pg_run: --prefix is required; usage: pg_run --prefix DIR --url-env NAME -- PROGRAM [ARG]...\n", bad.stderr);
    // the toolbox run as `initdb` is an applet that is not there: it says so and exits 127
    const r = try f.pgRun(&.{ try tool(f.a(), "TOOLBOX"), "true" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(std.mem.endsWith(u8, r.stderr, "pg_run: initdb exited 127\n"));
    try f.expectClean();
}

test "pg_prefix unpacks the packages named on its command line into the output directory, and refuses what it cannot take with exit 1 and no tree" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const exe = try tool(a, "PG_PREFIX");
    const ph = "/opt/cbuild/placeholder";
    const info = try fx.info(a, try fx.pathsJson(a, ph));
    try tmp.dir.writeFile(.{ .sub_path = "pg.conda", .data = try fx.conda(a, &.{.{ .name = "bin/postgres", .body = "PG", .mode = 0o755 }}, info) });
    try tmp.dir.writeFile(.{ .sub_path = "other.conda", .data = try fx.conda(a, &.{ .{ .name = "lib/x.so", .body = "X" }, .{ .name = "include/x.h", .body = "H" } }, info) });
    const none: []const [2][]const u8 = &.{};
    var r = try run(a, tmp.dir, &.{ exe, "--out", "out", "--postgres", "pg.conda", "other.conda" }, none);
    try t.expectEqualStrings("", r.stderr);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("PG", try tmp.dir.readFileAlloc(a, "out/bin/postgres", 100));
    try t.expectEqualStrings("X", try tmp.dir.readFileAlloc(a, "out/lib/x.so", 100));
    try t.expectEqualStrings(ph, try tmp.dir.readFileAlloc(a, "out/buildrules-placeholder.txt", 100));
    try t.expectError(error.FileNotFound, tmp.dir.access("out/include", .{}));
    try tmp.dir.deleteTree("out");
    r = try run(a, tmp.dir, &.{ exe, "--out", "out", "--postgres", "missing.conda" }, none);
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("pg_prefix: cannot read missing.conda: FileNotFound\n", r.stderr);
    try t.expectError(error.FileNotFound, tmp.dir.access("out", .{}));
    r = try run(a, tmp.dir, &.{exe}, none);
    try t.expectEqual(@as(u8, 2), r.code);
    try t.expectEqualStrings("pg_prefix: usage: pg_prefix --out DIR --postgres POSTGRESQL.conda [OTHER.conda]...\n", r.stderr);
}
