//! pg_run: a private Postgres for one test run.
//!
//!   pg_run --prefix DIR --url-env NAME -- PROGRAM [ARG]...
//!
//! DIR is the tree `pg_prefix` made. pg_run makes a run directory (in BUCK_SCRATCH_PATH, else TMPDIR, else /tmp) holding a copy of `bin/postgres` and
//! `bin/initdb` whose conda prefix placeholder is replaced by the run directory, and links to the tree's `lib` and `share`; runs `initdb` on a data
//! directory of its own; starts the server on a Unix socket in a directory of its own (in TMPDIR, which is short: a socket path holds 107 bytes at
//! most), no TCP, no fsync; waits until `postmaster.pid` says `ready`; runs PROGRAM (a path, never looked for in PATH) with NAME set to the server's URL,
//! `postgresql://postgres@<socket directory, percent-encoded>:5432/postgres`; stops the server (SIGINT, the fast shutdown; SIGKILL after 120 s); removes
//! both directories; and exits with PROGRAM's status. A fixture failure (initdb or the server failing, the server not ready within 300 s, the server
//! gone while the test ran or failing when stopped) is said on stderr, one line `pg_run: ...`, and is exit 1 whatever PROGRAM did. The status of a
//! PROGRAM that cannot be started is 127 (not there) or 126; a wrong command line is exit 2.
//!
//! Everything that touches processes or time goes through `Plat` (the tests replace it with a server and a clock of their own; pg_plat.zig is the real
//! one). `main` only forwards to `run`.

const std = @import("std");

pub const Alloc = std.mem.Allocator;
pub const Oom = error{OutOfMemory};
pub const Pid = std.posix.pid_t;

/// The signals pg_run sends (Linux numbers: pg_run is a linux program).
pub const sigint: u8 = 2;
pub const sigkill: u8 = 9;

/// How long the server is given to become ready, and to stop after SIGINT, in milliseconds of the platform's clock; and the pause between two looks.
pub const ready_ms: u64 = 300_000;
pub const stop_ms: u64 = 120_000;
pub const poll_ms: u64 = 20;

/// The longest path a Unix socket takes (sun_path is 108 bytes with its NUL).
pub const sun_path_max: usize = 107;

pub const Plat = struct {
    ctx: *anyopaque,
    /// Starts `argv[0]` (a path) with exactly `env` as its environment, stdout and stderr inherited, stdin /dev/null or inherited; its pid, or the reason it
    /// could not be started (`FileNotFound`: it is not there).
    spawn: *const fn (ctx: *anyopaque, a: Alloc, argv: []const []const u8, env: *const std.process.EnvMap, stdin_null: bool) anyerror!Pid,
    /// The exit status (shell form: 128+N for signal N) of the process if it has ended, else null; reaps it.
    poll: *const fn (ctx: *anyopaque, pid: Pid) ?u8,
    /// Waits for the process to end and gives its exit status.
    wait: *const fn (ctx: *anyopaque, pid: Pid) u8,
    kill: *const fn (ctx: *anyopaque, pid: Pid, sig: u8) void,
    sleepMs: *const fn (ctx: *anyopaque, ms: u64) void,
    nowMs: *const fn (ctx: *anyopaque) u64,
    /// Eight random lowercase hexadecimal digits.
    randomHex: *const fn (ctx: *anyopaque, out: *[8]u8) void,
};

/// What `run` is given: where messages go, the process's environment (`NAME=VALUE`), its working directory (absolute), and the platform.
pub const Io = struct {
    err: *std.Io.Writer,
    environ: []const []const u8,
    cwd: []const u8,
    plat: Plat,
    /// The longest socket path accepted (the tests move it to hit the bound exactly).
    sock_path_max: usize = sun_path_max,
};

const usage = "usage: pg_run --prefix DIR --url-env NAME -- PROGRAM [ARG]...";

/// One message line on stderr. A failed write of it is not reported anywhere. (The formatting is generic and has no error path of its own, so the one place a failed write is
/// dropped, `emit`, is one block however many messages there are.)
fn say(io: Io, comptime fmt: []const u8, args: anytype) void {
    const Line = struct {
        args: @TypeOf(args),
        fn write(p: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *const @This() = @ptrCast(@alignCast(p));
            return w.print("pg_run: " ++ fmt ++ "\n", self.args);
        }
    };
    const line = Line{ .args = args };
    emit(io, &line, Line.write);
}

fn emit(io: Io, line: *const anyopaque, write: *const fn (*const anyopaque, *std.Io.Writer) std.Io.Writer.Error!void) void {
    write(line, io.err) catch {};
}

/// Says the message and answers false, for the steps that report whether they went through.
fn no(io: Io, comptime fmt: []const u8, args: anytype) bool {
    say(io, fmt, args);
    return false;
}

const Parsed = struct { prefix: []const u8, url_env: []const u8, program: []const []const u8 };

/// What is wrong with the command line: `arg` followed by `why`.
const Usage = struct { arg: []const u8, why: []const u8 };

const Parse = union(enum) { ok: Parsed, bad: Usage };

fn parse(args: []const []const u8) Parse {
    var prefix: ?[]const u8 = null;
    var url_env: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len and !std.mem.eql(u8, args[i], "--")) : (i += 2) {
        const slot = if (std.mem.eql(u8, args[i], "--prefix")) &prefix else if (std.mem.eql(u8, args[i], "--url-env")) &url_env else null;
        const s = slot orelse return .{ .bad = .{ .arg = args[i], .why = "is not an option pg_run takes" } };
        if (i + 1 >= args.len) return .{ .bad = .{ .arg = args[i], .why = "needs a value" } };
        if (s.* != null) return .{ .bad = .{ .arg = args[i], .why = "is given twice" } };
        s.* = args[i + 1];
    }
    const p = prefix orelse return .{ .bad = .{ .arg = "--prefix", .why = "is required" } };
    const name = url_env orelse return .{ .bad = .{ .arg = "--url-env", .why = "is required" } };
    if (!isName(name)) return .{ .bad = .{ .arg = name, .why = "is not an environment variable name" } };
    if (i + 1 >= args.len) return .{ .bad = .{ .arg = "the program", .why = "is missing after --" } };
    return .{ .ok = .{ .prefix = p, .url_env = name, .program = args[i + 1 ..] } };
}

/// `[A-Za-z_][A-Za-z0-9_]*`.
pub fn isName(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// The value of `name` in the environment `environ` when it is there and not empty.
fn getenv(environ: []const []const u8, name: []const u8) ?[]const u8 {
    for (environ) |entry| {
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name)) return entry[name.len + 1 ..];
    }
    return null;
}

/// `p` made absolute against `base`.
fn absolute(a: Alloc, base: []const u8, p: []const u8) Oom![]const u8 {
    if (std.fs.path.isAbsolute(p)) return p;
    return std.fs.path.join(a, &.{ base, p });
}

/// The environment `environ` with the variables of `extra` set (replacing those of the same name).
fn envMap(a: Alloc, environ: []const []const u8, extra: []const [2][]const u8) Oom!std.process.EnvMap {
    var map = std.process.EnvMap.init(a);
    for (environ) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        try map.put(entry[0..eq], entry[eq + 1 ..]);
    }
    for (extra) |kv| try map.put(kv[0], kv[1]);
    return map;
}

/// `bytes` with every byte outside `[A-Za-z0-9._~-]` as `%XX` (uppercase hexadecimal).
pub fn percentEncode(a: Alloc, bytes: []const u8) Oom![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (bytes) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '~' or c == '-') {
            try out.append(a, c);
        } else {
            try out.appendSlice(a, &.{ '%', "0123456789ABCDEF"[c >> 4], "0123456789ABCDEF"[c & 15] });
        }
    }
    return out.items;
}

pub const PatchError = error{ PrefixTooLong, EmptyPlaceholder } || Oom;

/// A copy of the binary `bytes` with conda's prefix placeholder replaced by `prefix`, as conda does it for a binary file: every occurrence starts a
/// NUL-terminated C string (the occurrence and what follows it up to the NUL, or the end of the file); in it each occurrence becomes `prefix`, and the
/// string is padded with NULs to its old length. The size and every offset stay. A `prefix` longer than the placeholder cannot be fitted.
pub fn patch(a: Alloc, bytes: []const u8, placeholder: []const u8, prefix: []const u8) PatchError![]u8 {
    if (placeholder.len == 0) return error.EmptyPlaceholder;
    if (prefix.len > placeholder.len) return error.PrefixTooLong;
    const out = try a.dupe(u8, bytes);
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, out, at, placeholder)) |start| {
        const end = std.mem.indexOfScalarPos(u8, out, start, 0) orelse out.len;
        var r = start;
        var w = start;
        while (r < end) {
            if (std.mem.startsWith(u8, out[r..end], placeholder)) {
                @memcpy(out[w..][0..prefix.len], prefix);
                w += prefix.len;
                r += placeholder.len;
            } else {
                out[w] = out[r];
                w += 1;
                r += 1;
            }
        }
        @memset(out[w..end], 0);
        at = end;
    }
    return out;
}

/// Whether the text of a `postmaster.pid` says the server is ready: its 8th line, trimmed of spaces, is `ready`.
pub fn isReady(text: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (n == 7) return std.mem.eql(u8, std.mem.trim(u8, line, " "), "ready");
    }
    return false;
}

/// `run` and its failures: an allocation that fails is `out of memory`, exit 1 (the directories made are removed, no server is left running).
pub fn run(a: Alloc, io: Io, args: []const []const u8) u8 {
    return exec(a, io, args) catch {
        say(io, "out of memory", .{});
        return 1;
    };
}

fn exec(a: Alloc, io: Io, args: []const []const u8) Oom!u8 {
    const o = switch (parse(args)) {
        .ok => |p| p,
        .bad => |b| {
            say(io, "{s} {s}; {s}", .{ b.arg, b.why, usage });
            return 2;
        },
    };
    if (std.mem.indexOfScalar(u8, o.program[0], '/') == null) {
        say(io, "{s} is not a path: a program is never looked for in a PATH, give its path", .{o.program[0]});
        return 2;
    }
    const prefix = try absolute(a, io.cwd, o.prefix);
    const argv = try a.dupe([]const u8, o.program);
    argv[0] = try absolute(a, io.cwd, o.program[0]);

    const tmp = try absolute(a, io.cwd, nonEmpty(getenv(io.environ, "TMPDIR")) orelse "/tmp");
    const base = try absolute(a, io.cwd, nonEmpty(getenv(io.environ, "BUCK_SCRATCH_PATH")) orelse tmp);
    var hex: [8]u8 = undefined;
    io.plat.randomHex(io.plat.ctx, &hex);
    const run_dir = try std.fmt.allocPrint(a, "{s}/buildrules_pg.{s}", .{ base, &hex });
    io.plat.randomHex(io.plat.ctx, &hex);
    const sock_dir = try std.fmt.allocPrint(a, "{s}/buildrules_pgs.{s}", .{ tmp, &hex });
    const sock_len = sock_dir.len + "/.s.PGSQL.5432".len;
    if (sock_len > io.sock_path_max) {
        say(io, "the server's socket path {s}/.s.PGSQL.5432 is {d} bytes, more than the {d} a Unix socket path holds; give the action a shorter TMPDIR", .{ sock_dir, sock_len, io.sock_path_max });
        return 1;
    }
    const url = try std.fmt.allocPrint(a, "postgresql://postgres@{s}:5432/postgres", .{try percentEncode(a, sock_dir)});
    const test_env = try envMap(a, io.environ, &.{.{ o.url_env, url }});

    const cwd = std.fs.cwd();
    cwd.makePath(run_dir) catch |e| return fixtureFailed(io, "cannot make {s}: {s}", .{ run_dir, @errorName(e) });
    defer cwd.deleteTree(run_dir) catch {};
    cwd.makePath(sock_dir) catch |e| return fixtureFailed(io, "cannot make {s}: {s}", .{ sock_dir, @errorName(e) });
    defer cwd.deleteTree(sock_dir) catch {};

    return fixture(a, io, .{ .prefix = prefix, .run_dir = run_dir, .sock_dir = sock_dir, .argv = argv, .test_env = &test_env });
}

fn nonEmpty(v: ?[]const u8) ?[]const u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
}

fn fixtureFailed(io: Io, comptime fmt: []const u8, args: anytype) u8 {
    say(io, fmt, args);
    return 1;
}

const Fixture = struct {
    prefix: []const u8,
    run_dir: []const u8,
    sock_dir: []const u8,
    argv: []const []const u8,
    test_env: *const std.process.EnvMap,
};

/// With the directories made: the install, initdb, the server, the program, the stop. The program's status, or 1 when the fixture failed.
fn fixture(a: Alloc, io: Io, f: Fixture) Oom!u8 {
    const plat = io.plat;
    if (!try install(a, io, f)) return 1;
    const data = try std.fmt.allocPrint(a, "{s}/data", .{f.run_dir});
    const bin = try std.fmt.allocPrint(a, "{s}/pg/bin", .{f.run_dir});
    const initdb = try std.fmt.allocPrint(a, "{s}/initdb", .{bin});
    const postgres = try std.fmt.allocPrint(a, "{s}/postgres", .{bin});
    const pid_file = try std.fmt.allocPrint(a, "{s}/postmaster.pid", .{data});
    const env = try envMap(a, io.environ, &.{.{ "LC_ALL", "C" }});

    const init_argv = [_][]const u8{ initdb, "-D", data, "-U", "postgres", "-A", "trust", "-E", "UTF8", "--locale=C", "--no-sync", "--no-instructions" };
    const init_pid = plat.spawn(plat.ctx, a, &init_argv, &env, true) catch |e| return fixtureFailed(io, "cannot run {s}: {s}", .{ initdb, @errorName(e) });
    const init_status = plat.wait(plat.ctx, init_pid);
    if (init_status != 0) return fixtureFailed(io, "initdb exited {d}", .{init_status});

    const server_argv = [_][]const u8{
        postgres,  "-D", data,                    "-k", f.sock_dir, "-p", "5432",
        "-c", "listen_addresses=",
        "-c", "fsync=off",
        "-c", "synchronous_commit=off",
        "-c", "full_page_writes=off",
    };
    const pg = plat.spawn(plat.ctx, a, &server_argv, &env, true) catch |e| return fixtureFailed(io, "cannot run {s}: {s}", .{ postgres, @errorName(e) });
    switch (waitReady(io, pg, pid_file)) {
        .ready => {},
        .exited => |status| return fixtureFailed(io, "postgres exited {d} before it was ready", .{status}),
        .timeout => {
            plat.kill(plat.ctx, pg, sigkill);
            _ = plat.wait(plat.ctx, pg);
            return fixtureFailed(io, "postgres was not ready within {d} s; it was stopped", .{ready_ms / 1000});
        },
    }

    var status: u8 = undefined;
    if (plat.spawn(plat.ctx, a, f.argv, f.test_env, false)) |test_pid| {
        status = plat.wait(plat.ctx, test_pid);
    } else |e| {
        say(io, "cannot run {s}: {s}", .{ f.argv[0], @errorName(e) });
        status = if (e == error.FileNotFound) 127 else 126;
    }

    if (plat.poll(plat.ctx, pg)) |gone| return fixtureFailed(io, "postgres exited {d} while the test ran", .{gone});
    plat.kill(plat.ctx, pg, sigint);
    const stopped = waitStopped(io, pg);
    if (stopped != 0) return fixtureFailed(io, "postgres exited {d} when it was stopped", .{stopped});
    return status;
}

const Ready = union(enum) { ready, exited: u8, timeout };

fn waitReady(io: Io, pid: Pid, pid_file: []const u8) Ready {
    const plat = io.plat;
    const start = plat.nowMs(plat.ctx);
    var buf: [1024]u8 = undefined;
    while (true) {
        const text: []const u8 = std.fs.cwd().readFile(pid_file, &buf) catch "";
        if (isReady(text)) return .ready;
        if (plat.poll(plat.ctx, pid)) |status| return .{ .exited = status };
        if (plat.nowMs(plat.ctx) - start >= ready_ms) return .timeout;
        plat.sleepMs(plat.ctx, poll_ms);
    }
}

/// The exit status of the server `pid` after the SIGINT: it is given 120 s, then SIGKILL.
fn waitStopped(io: Io, pid: Pid) u8 {
    const plat = io.plat;
    const start = plat.nowMs(plat.ctx);
    while (true) {
        if (plat.poll(plat.ctx, pid)) |status| return status;
        if (plat.nowMs(plat.ctx) - start >= stop_ms) {
            plat.kill(plat.ctx, pid, sigkill);
            return plat.wait(plat.ctx, pid);
        }
        plat.sleepMs(plat.ctx, poll_ms);
    }
}

/// `<run>/pg`: copies of bin/postgres and bin/initdb with the placeholder replaced by `<run>/pg`, and links to the prefix's lib and share. False, with the
/// reason said, when something failed.
fn install(a: Alloc, io: Io, f: Fixture) Oom!bool {
    const cwd = std.fs.cwd();
    const pg = try std.fmt.allocPrint(a, "{s}/pg", .{f.run_dir});
    const ph_path = try std.fmt.allocPrint(a, "{s}/buildrules-placeholder.txt", .{f.prefix});
    const ph = cwd.readFileAlloc(a, ph_path, 1 << 16) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return no(io, "cannot read {s}: {s}", .{ ph_path, @errorName(e) }),
    };
    const bin = try std.fmt.allocPrint(a, "{s}/bin", .{pg});
    cwd.makePath(bin) catch |e| return no(io, "cannot make {s}: {s}", .{ bin, @errorName(e) });
    for ([_][]const u8{ "postgres", "initdb" }) |name| {
        const from = try std.fmt.allocPrint(a, "{s}/bin/{s}", .{ f.prefix, name });
        const to = try std.fmt.allocPrint(a, "{s}/bin/{s}", .{ pg, name });
        const bytes = cwd.readFileAlloc(a, from, 1 << 30) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return no(io, "cannot read {s}: {s}", .{ from, @errorName(e) }),
        };
        const patched = patch(a, bytes, ph, pg) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EmptyPlaceholder => return no(io, "{s} is empty", .{ph_path}),
            error.PrefixTooLong => return no(io, "the run directory {s} ({d} bytes) is longer than the prefix placeholder of {s} ({d} bytes); give the action a shorter scratch path", .{ pg, pg.len, from, ph.len }),
        };
        cwd.writeFile(.{ .sub_path = to, .data = patched, .flags = .{ .mode = 0o755 } }) catch |e| return no(io, "cannot write {s}: {s}", .{ to, @errorName(e) });
    }
    for ([_][]const u8{ "lib", "share" }) |name| {
        const from = try std.fmt.allocPrint(a, "{s}/{s}", .{ f.prefix, name });
        const to = try std.fmt.allocPrint(a, "{s}/{s}", .{ pg, name });
        cwd.symLink(from, to, .{}) catch |e| return no(io, "cannot link {s}: {s}", .{ to, @errorName(e) });
    }
    return true;
}

/// The program: the process's own arguments, environment and working directory, and the real platform. It only forwards to `run`.
pub fn main() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = std.process.argsAlloc(a) catch return 1;
    const environ = a.alloc([]const u8, std.os.environ.len) catch return 1;
    for (std.os.environ, 0..) |entry_z, k| environ[k] = std.mem.span(entry_z);
    const cwd = std.process.getCwdAlloc(a) catch return 1;
    var err_buf: [0]u8 = undefined;
    var err = std.fs.File.stderr().writer(&err_buf);
    return run(a, .{ .err = &err.interface, .environ = environ, .cwd = cwd, .plat = @import("pg_plat.zig").real() }, args[1..]);
}
