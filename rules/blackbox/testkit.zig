//! Test support: a scripted platform (no process is started, the clock is a number the runner's own sleeps move, so no case waits or measures time), a
//! case with a temporary directory and buffers for the streams, and the paths of the programs the process cases start for real.

const std = @import("std");
const io_mod = @import("io.zig");
const debkit = @import("debkit");

pub const t = std.testing;
pub const Alloc = std.mem.Allocator;
pub const Pid = io_mod.Pid;

/// What a scripted process does, chosen by the base name of its program.
pub const Behave = struct {
    /// It takes a connection at the n-th look (1 = the first); null: never.
    ready_at: ?u32 = 1,
    /// It exits with this status at the first look before it is ready.
    exits_early: ?u8 = null,
    /// It is gone, with this status, at the first look after the driver ended.
    dies: ?u8 = null,
    /// It stays after SIGTERM (only SIGKILL ends it).
    stays: bool = false,
    /// The status `wait` gives (the driver's).
    status: u8 = 0,
    /// It cannot be started: this error.
    refuse: ?anyerror = null,
    /// What it writes to its log when it starts.
    says: []const u8 = "",
    /// It leaves a directory in the run's directory that this user cannot empty (`locked`, mode 0500), so the run's directory cannot be removed.
    locks: bool = false,
};

const Proc = struct { pid: Pid, name: []const u8, b: Behave, looks: u32 = 0, ready: bool = false, alive: bool = true, termed: bool = false };

pub const Plat = struct {
    a: Alloc,
    now: u64 = 0,
    next_pid: Pid = 100,
    next_port: u16 = 40000,
    behaviours: std.StringHashMapUnmanaged(Behave) = .empty,
    procs: std.ArrayList(Proc) = .empty,
    /// Every command line started, its words joined by one space, and every signal sent, as `<name> <signal>`.
    started: std.ArrayList([]const u8) = .empty,
    signals: std.ArrayList([]const u8) = .empty,
    /// TMPDIR in the environment the last process was given.
    last_tmpdir: ?[]const u8 = null,
    /// The command line `runInherit` was given, and what it answers.
    inherited: ?[]const u8 = null,
    inherit_answer: anyerror!u8 = 0,
    reserve_fails: bool = false,
    /// The ports `reservePort` gives, in order, before it counts up from 40001.
    port_script: []const u16 = &.{},
    driver_done: bool = false,

    pub fn behave(p: *Plat, name: []const u8, b: Behave) void {
        p.behaviours.put(p.a, name, b) catch @panic("oom");
    }

    pub fn real(p: *Plat) io_mod.Plat {
        return .{
            .ctx = p,
            .spawn = spawn,
            .runInherit = runInherit,
            .poll = poll,
            .wait = wait,
            .kill = kill,
            .sleepMs = sleepMs,
            .nowMs = nowMs,
            .randomHex = randomHex,
            .reservePort = reservePort,
            .accepts = accepts,
        };
    }

    fn of(ctx: *anyopaque) *Plat {
        return @ptrCast(@alignCast(ctx));
    }

    fn find(p: *Plat, pid: Pid) *Proc {
        for (p.procs.items) |*q| {
            if (q.pid == pid) return q;
        }
        @panic("no such pid");
    }

    fn joined(a: Alloc, argv: []const []const u8) []const u8 {
        return std.mem.join(a, " ", argv) catch @panic("oom");
    }

    fn spawn(ctx: *anyopaque, a: Alloc, argv: []const []const u8, env: *const std.process.EnvMap, log: []const u8) anyerror!Pid {
        const p = of(ctx);
        const name = std.fs.path.basename(argv[0]);
        const b = p.behaviours.get(name) orelse Behave{};
        if (b.refuse) |e| return e;
        p.started.append(p.a, joined(p.a, argv)) catch @panic("oom");
        p.last_tmpdir = if (env.get("TMPDIR")) |v| (p.a.dupe(u8, v) catch @panic("oom")) else null;
        std.fs.cwd().writeFile(.{ .sub_path = log, .data = b.says }) catch @panic("cannot write the log");
        if (b.locks) {
            const locked = std.fs.path.join(p.a, &.{ std.fs.path.dirname(std.fs.path.dirname(log).?).?, "locked" }) catch @panic("oom");
            var d = std.fs.cwd().makeOpenPath(locked, .{}) catch @panic("mkdir");
            d.writeFile(.{ .sub_path = "f", .data = "" }) catch @panic("write");
            d.close();
            std.posix.fchmodat(std.fs.cwd().fd, locked, 0o500, 0) catch @panic("chmod");
        }
        _ = a;
        p.next_pid += 1;
        p.procs.append(p.a, .{ .pid = p.next_pid, .name = name, .b = b }) catch @panic("oom");
        return p.next_pid;
    }

    fn runInherit(ctx: *anyopaque, _: Alloc, argv: []const []const u8, _: *const std.process.EnvMap) anyerror!u8 {
        const p = of(ctx);
        p.inherited = joined(p.a, argv);
        return p.inherit_answer;
    }

    fn poll(ctx: *anyopaque, pid: Pid) ?u8 {
        const p = of(ctx);
        const q = p.find(pid);
        if (!q.alive) @panic("a look at a process that was reaped");
        if (!q.ready) {
            if (q.b.exits_early) |s| {
                q.alive = false;
                return s;
            }
        }
        if (p.driver_done and !q.termed) {
            if (q.b.dies) |s| {
                q.alive = false;
                return s;
            }
        }
        if (q.termed and !q.b.stays) {
            q.alive = false;
            return 143;
        }
        return null;
    }

    fn wait(ctx: *anyopaque, pid: Pid) u8 {
        const p = of(ctx);
        const q = p.find(pid);
        q.alive = false;
        p.driver_done = true;
        return if (q.termed) 137 else q.b.status;
    }

    fn kill(ctx: *anyopaque, pid: Pid, sig: u8) void {
        const p = of(ctx);
        const q = p.find(pid);
        p.signals.append(p.a, std.fmt.allocPrint(p.a, "{s} {d}", .{ q.name, sig }) catch @panic("oom")) catch @panic("oom");
        if (sig == io_mod.sigterm) q.termed = true;
        if (sig == io_mod.sigkill) q.b.stays = false;
    }

    fn sleepMs(ctx: *anyopaque, ms: u64) void {
        of(ctx).now += ms;
    }

    fn nowMs(ctx: *anyopaque) u64 {
        return of(ctx).now;
    }

    fn randomHex(_: *anyopaque, out: *[8]u8) void {
        out.* = "0badc0de".*;
    }

    fn reservePort(ctx: *anyopaque) u16 {
        const p = of(ctx);
        if (p.reserve_fails) return 0;
        if (p.port_script.len > 0) {
            const port = p.port_script[0];
            p.port_script = p.port_script[1..];
            return port;
        }
        p.next_port += 1;
        return p.next_port;
    }

    /// The last process started is the one the runner waits for.
    fn accepts(ctx: *anyopaque, _: u16) bool {
        const p = of(ctx);
        const q = &p.procs.items[p.procs.items.len - 1];
        q.looks += 1;
        const at = q.b.ready_at orelse return false;
        if (q.looks >= at) q.ready = true;
        return q.ready;
    }
};

/// One case: an arena, a temporary directory (absolute path `dir`), the streams as buffers, the scripted platform, and the Io over them.
pub const Case = struct {
    arena: *std.heap.ArenaAllocator,
    a: Alloc,
    tmp: std.testing.TmpDir,
    dir: []const u8,
    out: *std.Io.Writer.Allocating,
    err: *std.Io.Writer.Allocating,
    plat: *Plat,
    environ: []const []const u8,
    argv: []const []const u8 = &.{ "buck-out/blackbox_run", "run" },

    pub fn init() !Case {
        const arena = try t.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(t.allocator);
        const a = arena.allocator();
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        const dir = try tmp.dir.realpathAlloc(a, ".");
        try tmp.dir.makePath("tmp");
        const out = try a.create(std.Io.Writer.Allocating);
        out.* = std.Io.Writer.Allocating.init(a);
        const err = try a.create(std.Io.Writer.Allocating);
        err.* = std.Io.Writer.Allocating.init(a);
        const plat = try a.create(Plat);
        plat.* = .{ .a = a };
        // Before TMPDIR: an entry shorter than its name, one as long with another character after it, one with `=` there and another name, and one
        // with no `=` at all.
        const environ = try a.dupe([]const u8, &.{ "A=1", "HOME=/nonexistent", "PREFIX=/p", "NOT_AN_ASSIGNMENT", try std.fmt.allocPrint(a, "TMPDIR={s}/tmp", .{dir}) });
        return .{ .arena = arena, .a = a, .tmp = tmp, .dir = dir, .out = out, .err = err, .plat = plat, .environ = environ };
    }

    pub fn deinit(c: *Case) void {
        c.tmp.cleanup();
        c.arena.deinit();
        t.allocator.destroy(c.arena);
    }

    pub fn io(c: *Case) io_mod.Io {
        return .{
            .out = &c.out.writer,
            .err = &c.err.writer,
            .root = c.tmp.dir,
            .argv = c.argv,
            .environ = c.environ,
            .cwd = c.dir,
            .uid = 1000,
            .gid = 1000,
            .plat = c.plat.real(),
        };
    }

    /// The absolute path of `rel` in the case's directory.
    pub fn path(c: *Case, rel: []const u8) []const u8 {
        return std.fs.path.join(c.a, &.{ c.dir, rel }) catch @panic("oom");
    }

    pub fn put(c: *Case, rel: []const u8, data: []const u8) void {
        if (std.fs.path.dirname(rel)) |d| c.tmp.dir.makePath(d) catch @panic("mkdir");
        c.tmp.dir.writeFile(.{ .sub_path = rel, .data = data }) catch @panic("write");
    }

    pub fn stdout(c: *Case) []const u8 {
        return c.out.written();
    }

    pub fn stderr(c: *Case) []const u8 {
        return c.err.written();
    }

    /// The sha256 of `bytes` in lower-case hex.
    pub fn sha256(c: *Case, bytes: []const u8) []const u8 {
        var d: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
        return c.a.dupe(u8, &std.fmt.bytesToHex(d, .lower)) catch @panic("oom");
    }

    /// The toy package: `usr/bin/svc` holding `#!svc`, written to `pkg.deb`; its bytes.
    pub fn toyPackage(c: *Case) []const u8 {
        const bytes = debkit.packageOf(c.a, &.{.{ .name = "usr/bin/svc", .mode = 0o755, .data = "#!svc\n" }}) catch @panic("oom");
        c.put("pkg.deb", bytes);
        return bytes;
    }
};

/// A writer over `buf` whose every write past it, and every flush, fails (a closed pipe, a full disk).
pub fn failingWriter(buf: []u8) std.Io.Writer {
    return .{ .vtable = &.{ .drain = failDrain }, .buffer = buf };
}

fn failDrain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
    return error.WriteFailed;
}

/// The path of the program a test target passes as `name` (`env_tools`), made absolute; the case fails, naming it, when the target passes none.
pub fn tool(a: Alloc, name: []const u8) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, name) catch {
        std.debug.print("the test target does not pass {s} (env_tools), so that program cannot be run\n", .{name});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

/// `haystack` holds `needle`, or the case fails and prints both.
pub fn expectHas(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected to find\n  {s}\nin\n{s}\n", .{ needle, haystack });
        return error.TestExpectedText;
    }
}

// ---- the command line of a run of the toy package (run_test.zig, sweeps_test.zig) ----------------------------------------------------

pub const image = "docker://repo@sha256:" ++ "1" ** 64;

/// The command line of a run of the toy package with one fake, `up`, and the driver, followed by `extra`.
pub fn runArgs(c: *Case, extra: []const []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    out.appendSlice(c.a, &.{
        "--image",       image,
        "--package",     c.path("pkg.deb"),
        "--service",     "usr/bin/svc",
        "--flag",        "--listen",
        "--flag",        "{addr:service}",
        "--flag",        "--up=http://{addr:up}/",
        "--fake",        "up=/fakes/upfake",
        "--fake-flag",   "up=--listen",
        "--fake-flag",   "up={addr:up}",
        "--driver",      "/d/drv",
        "--driver-flag", "{addr:service}",
        "--driver-flag", "{root}/etc {work} {port:up} {{literal}",
        "--ready-s",     "2",
    }) catch @panic("oom");
    out.appendSlice(c.a, extra) catch @panic("oom");
    return out.items;
}
