//! What the gate's tests share (not part of the tool).
//!
//! `runGate` forks a child H that calls `gate.entry` with the given argv in
//! a working directory of the test's own, its stdout and stderr in files, and
//! the platform's exec replaced by `fixture`: the "test" the gate supervises
//! is then a child of the test binary that runs a behaviour picked by its
//! program name (the path's last component) and its arguments, with the
//! argv and environment the gate built for it. No shell stand-in is used.
//!
//! No test waits for a time to pass or measures one. What a test would have
//! slept for is an event instead:
//!   * the fixture reports readiness (a pid written, a "ready" byte) on a
//!     pipe, and whoever must act after it (a signal, a clock that jumps)
//!     blocks on that pipe;
//!   * the fixture's "held" behaviours block on a second pipe until the
//!     supervisor has taken a set number of readings (`release_at`,
//!     `pace_per_tick`), so a run lasts as many supervisor ticks as the test
//!     needs and no wall-clock time;
//!   * time-dependent decisions (a limit, a grace period, the wait for
//!     survivors) read a manual clock (`useClock`) that only moves when the
//!     test's script says so or a fake sleep advances it;
//!   * a process that must be gone is waited for through its pidfd.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const gate = @import("gate.zig");
const supervise = @import("supervise.zig");
const proctab = @import("proctab.zig");
const proctab_darwin = if (sys.is_darwin) @import("proctab_darwin.zig") else struct {};

pub const Result = struct {
    status: u8,
    out: []const u8,
    err: []const u8,
    /// A file that exists when a process the fixture left in the gate's
    /// session came back from its hold (see `expectKilled`).
    survivors_file: []const u8,
};

pub const Opts = struct {
    /// Called in H before the gate runs: replace `supervise.plat` fields.
    setup: ?*const fn () void = null,
    /// H's environment; null keeps the test binary's.
    env: ?[]const []const u8 = null,
    /// Sent to H once the fixture has reported readiness this many times
    /// (a pid written to a report file counts once).
    /// `tether_pids`: for a signal that the gate cannot act on (SIGKILL), the
    /// report file whose first pid is the supervised process: the other child
    /// of H is the tether, and the run is not over until the tether has
    /// exited, as it kills the session only after the gate is gone.
    signal: ?struct { sig: u8, after_ready: usize, tether_pids: ?[]const u8 = null } = null,
};

// The channels between the test, H and the fixture. runGate makes them before
// it forks, so H and everything below it inherit the descriptors and the
// fixture finds them here.
var ready_r: sys.fd_t = -1;
var ready_w: sys.fd_t = -1;
var hold_r: sys.fd_t = -1;
var hold_w: sys.fd_t = -1;
var survivors_file: []const u8 = "";

/// A fresh directory under $TMPDIR.
pub fn tempDir(alloc: std.mem.Allocator) ![]const u8 {
    const base = std.posix.getenv("TMPDIR") orelse "/tmp";
    var suffix: [6]u8 = undefined;
    sys.randomSuffix(&suffix);
    const p = try std.fmt.allocPrint(alloc, "{s}/gate_test.{s}", .{ base, suffix });
    try std.fs.cwd().makePath(p);
    return p;
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(bytes);
}

pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, 1 << 28);
}

pub fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// The busybox the zig_test action's PATH holds applets of.
pub fn busybox(alloc: std.mem.Allocator) ![]const u8 {
    const path = std.posix.getenv("PATH") orelse return error.NoPath;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |d| {
        const sh = try std.fmt.allocPrint(alloc, "{s}/sh", .{d});
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = std.fs.cwd().readLink(sh, &buf) catch continue;
        return alloc.dupe(u8, target);
    }
    return error.NoBusybox;
}

pub fn runGate(alloc: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, opts: Opts) !Result {
    const io = try tempDir(alloc);
    const out_path = try std.fmt.allocPrint(alloc, "{s}/out", .{io});
    const err_path = try std.fmt.allocPrint(alloc, "{s}/err", .{io});
    const survivors_path = try std.fmt.allocPrint(alloc, "{s}/survivors", .{io});
    survivors_file = survivors_path;
    const ready = try posix.pipe();
    const hold_pipe = try posix.pipe();
    ready_r = ready[0];
    ready_w = ready[1];
    hold_r = hold_pipe[0];
    hold_w = hold_pipe[1];
    defer {
        ready_r = -1;
        ready_w = -1;
        hold_r = -1;
        hold_w = -1;
        survivors_file = "";
    }
    const h = try posix.fork();
    if (h == 0) {
        posix.chdir(cwd) catch posix.exit(250);
        const o = posix.open(out_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch posix.exit(250);
        const e = posix.open(err_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch posix.exit(250);
        posix.dup2(o, 1) catch posix.exit(250);
        posix.dup2(e, 2) catch posix.exit(250);
        sys.devNullOnto(0, false);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const a = arena.allocator();
        if (opts.env) |env| {
            const z = a.alloc([*:0]u8, env.len + 1) catch posix.exit(250);
            for (env, 0..) |kv, i| z[i] = (a.dupeZ(u8, kv) catch posix.exit(250)).ptr;
            std.os.environ = z[0..env.len];
        }
        // PWD names the test's directory, as a shell's would.
        // The supervisor's clock starts as one that cannot pass any limit: a verdict never depends on how long a
        // machine takes. A test that needs a limit to pass sets a manual clock (`useClock`) in `setup`.
        supervise.plat = .{ .exec = fixture, .now_ms = frozenClock };
        if (opts.setup) |f| f();
        posix.exit(gate.entry(a, argv));
    }
    // The test keeps the read end of the readiness pipe only; the write ends
    // belong to H and the fixture, so that end of file means none is left.
    posix.close(ready[1]);
    posix.close(hold_pipe[0]);
    defer posix.close(hold_pipe[1]);
    defer posix.close(ready[0]);
    var tether: ?i32 = null;
    if (opts.signal) |sg| {
        if (awaitReady(sg.after_ready)) {
            if (sg.tether_pids) |file| tether = try tetherOf(alloc, h, file);
            sys.kill(h, sg.sig);
        }
    }
    const status = sys.waitpid(h, false) orelse return error.NoStatus;
    if (tether) |q| try waitExit(q);
    // The gate is gone and everything it started should be: release every
    // process still held. One that comes back from its wait has survived the
    // gate's kill, and says so in the survivors file; a killed one cannot.
    sys.writeAll(hold_pipe[1], "rrrrrrrrrrrrrrrr");
    return .{
        .status = status,
        .out = try readFile(alloc, out_path),
        .err = try readFile(alloc, err_path),
        .survivors_file = survivors_path,
    };
}

/// The child of `h` that is not the supervised process (the first pid in
/// `file`): the tether; null when there is none.
fn tetherOf(alloc: std.mem.Allocator, h: i32, file: []const u8) !?i32 {
    const c = (try pidsFrom(alloc, file, 1))[0];
    const t = proctab.read(alloc) orelse return error.NoTable;
    for (t.procs) |p| {
        if (p.ppid == h and p.pid != c) return p.pid;
    }
    return null;
}

/// Fails when a process of the run that `pids` names came back from its hold
/// after the gate was done: it was not killed. It waits for the pids to exit
/// first; they are released when the run ends, so one that was never killed
/// exits too and is reported, instead of being waited for for ever.
pub fn expectKilled(r: Result, pids: []const i32) !void {
    try waitGone(pids);
    try std.testing.expect(!exists(r.survivors_file));
}

/// Blocks until `n` readiness bytes have been read from the run's readiness
/// pipe; false when every writer is gone first.
fn awaitReady(n: usize) bool {
    var left = n;
    var b: [64]u8 = undefined;
    while (left > 0) {
        const got = posix.read(ready_r, b[0..@min(left, b.len)]) catch return false;
        if (got == 0) return false;
        left -= got;
    }
    return true;
}

fn signalReady() void {
    if (ready_w >= 0) sys.writeAll(ready_w, "r");
}

/// Blocks until the supervisor releases the process (`release_at`,
/// `pace_per_tick`), or for ever where there is no channel: only a kill ends
/// it then.
fn holdWait() void {
    var b: [1]u8 = undefined;
    while (true) {
        if (hold_r < 0) {
            _ = posix.poll(&[0]posix.pollfd{}, -1) catch {};
            continue;
        }
        _ = posix.read(hold_r, &b) catch return;
        return;
    }
}

/// A process that was to be killed and was not: it came back from its hold
/// (the run is over and `runGate` released it) and says so.
fn markSurvived() void {
    const f = std.fs.cwd().createFile(survivors_file, .{}) catch return;
    f.close();
}

// ---- the manual clock and the events that stand in for waiting -------------

/// The clock every `runGate` run starts with: always the start of the run, so no limit passes however slowly the
/// run goes, and no reading is counted (unlike `manualClock`).
fn frozenClock() ?u64 {
    return 0;
}

/// The readings `manualClock` returns, one per call; after the last it keeps
/// returning the last (moved on by `manualSleep`).
var clock_script: []const u64 = &.{};
/// Readiness bytes to wait for before the second reading (the first is the
/// start of the run, taken before the fixture exists).
var clock_wait: usize = 0;
var clock_at: usize = 0;
var clock_now: u64 = 0;
var clock_reads: u32 = 0;
/// A run that reads the clock more often than this is looping on a clock that
/// does not move: it ends the gate with status 251, which fails the test, in
/// place of a wait for ever. (A reading is one supervisor tick; a correct run
/// needs a handful.)
const clock_guard = 300;
/// The supervisor's N-th reading (clock or process table) releases one
/// "held" process; 0: none. A test sets it in `setup`; the default release
/// is for a run that should end by itself, and a defect that keeps it from
/// ending then shows as a wrong status, not a hang.
pub var release_at: u32 = 0;
/// Every reading releases this many bytes: a paced hog touches one MiB per
/// byte.
pub var pace_per_tick: u32 = 0;
var ticks: u32 = 0;

/// One reading of the supervisor, for a hook that is not `countingTable`
/// (`release_at`, `pace_per_tick`).
pub fn tick() void {
    ticks += 1;
    if (hold_w < 0) return;
    var i: u32 = 0;
    while (i < pace_per_tick) : (i += 1) sys.writeAll(hold_w, "p");
    if (release_at != 0 and ticks == release_at) sys.writeAll(hold_w, "r");
}

fn guardReads() void {
    clock_reads += 1;
    if (clock_reads > clock_guard) {
        sys.writeAll(2, "testkit: the clock was read over and over without the run ending\n");
        posix.exit(251);
    }
}

/// For `setup`: the supervisor's clock reads `script` (milliseconds), one
/// element per reading, and stays at the last. `wait_ready` readiness bytes
/// are awaited before the second reading, so the clock cannot pass a limit
/// before the fixture is where the test needs it. `supervise.plat.sleep_ms`
/// moves the clock instead of waiting.
pub fn useClock(script: []const u64, wait_ready: usize) void {
    clock_script = script;
    clock_wait = wait_ready;
    clock_at = 0;
    clock_now = 0;
    clock_reads = 0;
    ticks = 0;
    supervise.plat.now_ms = manualClock;
    supervise.plat.sleep_ms = manualSleep;
}

fn manualClock() ?u64 {
    guardReads();
    tick();
    if (clock_at == 1 and clock_wait > 0) {
        _ = awaitReady(clock_wait);
        clock_wait = 0;
    }
    if (clock_at < clock_script.len) {
        clock_now = clock_script[clock_at];
        clock_at += 1;
    }
    return clock_now;
}

/// A sleep that takes no time: the clock moves on by `ms` and the sleep is
/// written to stderr, for the test to read back.
fn manualSleep(ms: u64) void {
    clock_now += ms;
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "slept {d} ms\n", .{ms}) catch return;
    sys.writeAll(2, s);
}

/// `supervise.plat.read_table` for a test that counts the supervisor's
/// readings (`release_at`, `pace_per_tick`) and otherwise reads the real
/// table.
pub fn countingTable(alloc: std.mem.Allocator) ?proctab.Table {
    const t = proctab.read(alloc);
    tick();
    return t;
}

/// Blocks (in a hook, in H) until the fixture has reported readiness `n`
/// times.
pub fn waitReady(n: usize) void {
    _ = awaitReady(n);
}

/// What `loggingKill` writes for a signal, a group or one process, and the
/// reading of the manual clock.
pub fn killLine(alloc: std.mem.Allocator, sig: u8, group: bool, clock: u64) ![]const u8 {
    return std.fmt.allocPrint(alloc, kill_fmt, .{ sig, if (group) "a group" else "a process", clock });
}

const kill_fmt = "kill: signal {d} to {s} at clock {d}\n";

/// `supervise.plat.kill` that writes every kill to stderr with the reading
/// of the manual clock it happened at (`killLine`), then kills.
pub fn loggingKill(pid: sys.pid_t, sig: u8) void {
    var buf: [128]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, kill_fmt, .{ sig, if (pid < 0) "a group" else "a process", clock_now }) catch "";
    sys.writeAll(2, s);
    sys.kill(pid, sig);
}

/// `loggingKill` that returns from a group SIGKILL only once every live
/// member of the group has exited, as the kernel's delivery is not instant:
/// what the survivor scan looks at is then the kill's effect, not a race with
/// it. A group that is not killed has nothing to wait for.
pub fn settlingKill(pid: sys.pid_t, sig: u8) void {
    if (pid >= 0 or sig != posix.SIG.KILL) return loggingKill(pid, sig);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const members: []const proctab.Member = proctab.groupMembers(arena.allocator(), -pid) orelse &.{};
    loggingKill(pid, sig);
    for (members) |m| waitExit(m.pid) catch {};
}

/// Blocks until `pid` has exited (a zombie counts), through its pidfd: the
/// kernel makes it readable at the exit. Linux only.
pub fn waitExit(pid: i32) !void {
    if (!sys.is_linux) return error.SkipZigTest;
    const rc = std.os.linux.pidfd_open(pid, 0);
    switch (std.os.linux.E.init(rc)) {
        .SUCCESS => {},
        .SRCH => return,
        else => return error.NoPidfd,
    }
    const fd: posix.fd_t = @intCast(rc);
    defer posix.close(fd);
    var fds = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    while ((posix.poll(&fds, -1) catch 0) == 0) {}
}

/// A `setup` for `runGate`: removes the directory the gate runs in, so that the
/// kernel no longer has a path for it (getcwd then fails).
pub fn unlinkCwd() void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = posix.getcwd(&buf) catch posix.exit(249);
    posix.rmdir(cwd) catch posix.exit(249);
}

/// The gate over `argv` in THIS process, from `cwd`, with stdout and stderr read back: for a command line the gate refuses before it starts anything (a
/// usage error, a missing file), so that nothing is forked and nothing outlives the call. The branch counters belong to the process that runs the code, so
/// only the code run here is counted as run (rules/coverage/README.md, "Code that runs in another process").
pub fn runInline(alloc: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !Result {
    return runInlineWith(alloc, alloc, cwd, argv);
}

/// `runInline` where the gate allocates from `gate_alloc` (a failing allocator, say) and the harness from `alloc`.
pub fn runInlineWith(alloc: std.mem.Allocator, gate_alloc: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !Result {
    const io = try tempDir(alloc);
    const out_path = try std.fmt.allocPrint(alloc, "{s}/out", .{io});
    const err_path = try std.fmt.allocPrint(alloc, "{s}/err", .{io});
    const was_here = try posix.open(".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    defer posix.close(was_here);
    const saved_out = try posix.dup(1);
    defer posix.close(saved_out);
    const saved_err = try posix.dup(2);
    defer posix.close(saved_err);
    const o = try posix.open(out_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer posix.close(o);
    const e = try posix.open(err_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    defer posix.close(e);
    try posix.chdir(cwd);
    try posix.dup2(o, 1);
    try posix.dup2(e, 2);
    const status = gate.entry(gate_alloc, argv);
    try posix.dup2(saved_out, 1);
    try posix.dup2(saved_err, 2);
    try posix.fchdir(was_here);
    return .{ .status = status, .out = try readFile(alloc, out_path), .err = try readFile(alloc, err_path), .survivors_file = "" };
}

const darwin_wait = struct {
    extern "c" fn waitid(idtype: c_int, id: c_int, info: *align(8) [128]u8, options: c_int) c_int;
};

/// Blocks until child `pid` has exited, without reaping it: it is then a
/// zombie (waitid WEXITED | WNOWAIT), whatever the machine's speed. This is
/// the progress event the process-table tests wait on instead of polling.
pub fn waitZombie(pid: i32) !void {
    var info: [128]u8 align(8) = [_]u8{0} ** 128;
    while (true) {
        if (sys.is_linux) {
            const rc = sys.linux.waitid(.PID, pid, @ptrCast(&info), sys.linux.W.EXITED | sys.linux.W.NOWAIT);
            switch (sys.linux.E.init(rc)) {
                .SUCCESS => return,
                .INTR => continue,
                else => return error.WaitFailed,
            }
        } else {
            // P_PID = 1, WEXITED = 0x4, WNOWAIT = 0x20 (macOS <sys/wait.h>).
            if (darwin_wait.waitid(1, pid, &info, 0x4 | 0x20) == 0) return;
            if (std.c._errno().* == @intFromEnum(posix.E.INTR)) continue;
            return error.WaitFailed;
        }
    }
}

/// Whether `pid` is alive and not a zombie (a zombie has exited).
pub fn alive(pid: i32) bool {
    if (sys.is_darwin) return proctab_darwin.alive(pid);
    var buf: [64]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{pid}) catch return false;
    const f = std.fs.cwd().openFile(p, .{}) catch return false;
    defer f.close();
    var b: [512]u8 = undefined;
    const n = f.readAll(&b) catch return false;
    const close = std.mem.lastIndexOfScalar(u8, b[0..n], ')') orelse return false;
    if (close + 2 >= n) return false;
    return b[close + 2] != 'Z' and b[close + 2] != 'X';
}

/// Blocks until every pid has exited, then checks that none is alive (a
/// zombie has exited). It waits for the exit itself (`waitExit`), however
/// long the gate's kill takes to arrive; a kill that never arrives is a hang
/// that the build action's own limit ends.
pub fn waitGone(pids: []const i32) !void {
    for (pids) |p| try waitExit(p);
    for (pids) |p| try std.testing.expect(!alive(p));
}

/// Reads the pids a fixture wrote (one per line) to `path`. The fixture has
/// written them before it reports readiness, so a run that waited for the
/// readiness (a signal, the clock) or ended has them all; fewer than `n` is
/// an error, not a wait.
pub fn pidsFrom(alloc: std.mem.Allocator, path: []const u8, n: usize) ![]i32 {
    const text = std.fs.cwd().readFileAlloc(alloc, path, 4096) catch return error.NoPids;
    var out = std.ArrayList(i32).empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |t| try out.append(alloc, try std.fmt.parseInt(i32, t, 10));
    if (out.items.len < n) return error.NoPids;
    return out.items;
}

// ---- the fixture ------------------------------------------------------------

fn say(comptime fmt: []const u8, a: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, a) catch return;
    sys.writeAll(1, s);
}

fn num(s: ?[]const u8, default: u64) u64 {
    const v = s orelse return default;
    return std.fmt.parseInt(u64, v, 10) catch default;
}

fn appendPid(path: []const u8, pid: i32) void {
    const f = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch return;
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}\n", .{pid}) catch return;
    f.writeAll(s) catch return;
    signalReady();
}

/// Says it starts (while it is still small, so the line is in the log
/// whenever the cap kills it mid-touch), touches `mib` MiB, waiting after
/// each MiB for one byte of `pace_per_tick` when `paced`, says it holds them,
/// and holds them until it is released or killed.
fn hold(mib: u64, paced: bool, survivor: bool) noreturn {
    say("hog touches {d} MiB\n", .{mib});
    const mem = std.heap.page_allocator.alloc(u8, mib << 20) catch posix.exit(99);
    var i: usize = 0;
    while (i < mem.len) : (i += 4096) {
        mem[i] = 1;
        if (paced and (i + 4096) % (1 << 20) == 0) holdWait();
    }
    say("hog holds {d} MiB\n", .{mib});
    holdWait();
    if (survivor) markSurvived();
    posix.exit(0);
}

/// The supervised "test". Program names (the path's last component):
///   exit N             exits N
///   signal N           kills itself with signal N
///   held [N]          stays until released (`release_at`) or killed, exits N
///   clock              prints `clock N`, N the supervisor's clock reading, exits 0
///   hog MiB [PACED]    says "hog touches MiB", touches MiB of memory (PACED
///                      1: one MiB per released byte, `pace_per_tick`), says
///                      "hog holds MiB", holds them until released or killed,
///                      exits 0
///   daemon FILE KIND   forks a child (KIND: held or hog) that stays in the
///                      group, writes its pid to FILE, and exits 0 at once
///   spawnwait FILE     forks a child that stays until killed, writes its pid
///                      and its own, and waits for it
///   treehog P C        forks a child that holds C MiB, then holds P MiB
///                      itself and waits for the child, exits 0 (the fork
///                      comes first, so neither counts the other's pages)
///   env [N]            prints its environment, exits N (default 3)
///   args               prints `[arg]` per argument (argv[0] too), exits 3
///   where              prints its cwd and the bytes on stdin, exits 3
///   lines N NL RC      prints `line 1`..`line N` (NL 0: no final newline), exits RC
///   pid FILE ...       writes its pid to FILE, then runs the next behaviour
///   rust_* ...         fake libtest harnesses (rust_test.zig)
pub fn fixture(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) noreturn {
    sys.defaultSignals();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    var args = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (argv[i]) |p| : (i += 1) args.append(a, std.mem.span(p)) catch posix.exit(99);
    var env = std.ArrayList([]const u8).empty;
    i = 0;
    while (envp[i]) |p| : (i += 1) env.append(a, std.mem.span(p)) catch posix.exit(99);
    behave(a, std.fs.path.basename(std.mem.span(path)), args.items, env.items);
}

fn behave(a: std.mem.Allocator, name: []const u8, args: []const []const u8, env: []const []const u8) noreturn {
    const arg = struct {
        fn at(xs: []const []const u8, k: usize) ?[]const u8 {
            return if (k < xs.len) xs[k] else null;
        }
    }.at;
    if (std.mem.eql(u8, name, "exit")) posix.exit(@intCast(num(arg(args, 1), 0)));
    if (std.mem.eql(u8, name, "signal")) {
        posix.raise(@intCast(num(arg(args, 1), 9))) catch {};
        posix.exit(99);
    }
    if (std.mem.eql(u8, name, "held")) {
        holdWait();
        posix.exit(@intCast(num(arg(args, 1), 0)));
    }
    if (std.mem.eql(u8, name, "clock")) {
        // The clock the supervisor of this run reads (this process is forked from it, so it has the same one).
        say("clock {d}\n", .{supervise.plat.now_ms() orelse 999});
        posix.exit(0);
    }
    if (std.mem.eql(u8, name, "hog")) hold(num(arg(args, 1), 64), num(arg(args, 2), 0) != 0, false);
    if (std.mem.eql(u8, name, "daemon")) {
        const file = arg(args, 1) orelse posix.exit(99);
        const kind = arg(args, 2) orelse "held";
        const pid = posix.fork() catch posix.exit(99);
        if (pid == 0) {
            if (std.mem.eql(u8, kind, "hog")) hold(64, false, true);
            holdWait();
            markSurvived();
            posix.exit(0);
        }
        appendPid(file, pid);
        posix.exit(0);
    }
    if (std.mem.eql(u8, name, "spawnwait")) {
        const file = arg(args, 1) orelse posix.exit(99);
        const pid = posix.fork() catch posix.exit(99);
        if (pid == 0) {
            holdWait();
            markSurvived();
            posix.exit(0);
        }
        appendPid(file, sys.getpid());
        appendPid(file, pid);
        _ = sys.waitpid(-1, false);
        posix.exit(0);
    }
    if (std.mem.eql(u8, name, "treehog")) {
        const pid = posix.fork() catch posix.exit(99);
        if (pid == 0) hold(num(arg(args, 2), 24), false, false);
        const mem = std.heap.page_allocator.alloc(u8, num(arg(args, 1), 16) << 20) catch posix.exit(99);
        var k: usize = 0;
        while (k < mem.len) : (k += 4096) mem[k] = 1;
        say("parent holds {d} MiB\n", .{mem.len >> 20});
        _ = sys.waitpid(pid, false);
        posix.exit(0);
    }
    if (std.mem.eql(u8, name, "env")) {
        for (env) |kv| say("{s}\n", .{kv});
        posix.exit(@intCast(num(arg(args, 1), 3)));
    }
    if (std.mem.eql(u8, name, "args")) {
        for (args) |x| say("[{s}]\n", .{x});
        posix.exit(3);
    }
    if (std.mem.eql(u8, name, "where")) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = posix.getcwd(&buf) catch "?";
        var b: [64]u8 = undefined;
        const n = posix.read(0, &b) catch 999;
        say("cwd {s}\nstdin {d}\n", .{ cwd, n });
        posix.exit(3);
    }
    if (std.mem.eql(u8, name, "rundir")) {
        // The run directory as the test sees it: TMPDIR, TEST_TMPDIR, what
        // TMPDIR holds, and whether the applets are installed beside it.
        var tmp: []const u8 = "";
        for (env) |kv| {
            if (std.mem.startsWith(u8, kv, "TMPDIR=")) tmp = kv["TMPDIR=".len..];
            if (std.mem.startsWith(u8, kv, "TMPDIR=") or std.mem.startsWith(u8, kv, "TEST_TMPDIR=")) say("{s}\n", .{kv});
        }
        var n: usize = 0;
        if (std.fs.openDirAbsolute(tmp, .{ .iterate = true })) |dir| {
            var d = dir;
            var it = d.iterate();
            while (it.next() catch null) |_| n += 1;
            d.close();
        } else |_| n = 999;
        say("entries {d}\n", .{n});
        const sh = std.fmt.allocPrint(a, "{s}/../bin/sh", .{tmp}) catch posix.exit(99);
        say("applets {}\n", .{exists(sh)});
        const mine = std.fmt.allocPrint(a, "{s}/left_by_test", .{tmp}) catch posix.exit(99);
        writeFile(mine, "x") catch {};
        posix.exit(3);
    }
    if (std.mem.eql(u8, name, "lines")) {
        const n = num(arg(args, 1), 0);
        const nl = num(arg(args, 2), 1);
        var k: u64 = 1;
        while (k <= n) : (k += 1) {
            if (k == n and nl == 0) say("line {d}", .{k}) else say("line {d}\n", .{k});
        }
        posix.exit(@intCast(num(arg(args, 3), 1)));
    }
    if (std.mem.eql(u8, name, "pid")) {
        appendPid(arg(args, 1) orelse posix.exit(99), sys.getpid());
        if (args.len < 3) posix.exit(99);
        behave(a, args[2], args[2..], env);
    }
    if (std.mem.startsWith(u8, name, "rust_")) rustFake(name, args, env);
    say("fixture: unknown behaviour {s}\n", .{name});
    posix.exit(98);
}

/// Fake libtest harnesses: `--list --format terse` lists, no argument runs.
fn rustFake(name: []const u8, args: []const []const u8, env: []const []const u8) noreturn {
    const listing = args.len > 1 and std.mem.eql(u8, args[1], "--list");
    const eq = std.mem.eql;
    if (eq(u8, name, "rust_ok")) {
        if (listing) {
            say("a::one: test\na::two: test\nb::three: test\n", .{});
        } else say("running 3 tests\ntest a::one ... ok\ntest result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_empty")) {
        if (listing) say("\n", .{}) else say("test result: ok. 0 passed; 0 failed; 0 ignored;\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_listfails")) {
        if (listing) {
            sys.writeAll(2, "cannot list\n");
            posix.exit(5);
        }
        posix.exit(0);
    }
    if (eq(u8, name, "rust_ignored")) {
        if (listing) say("a: test\nb: test\n", .{}) else say("test a ... ok\ntest b ... ignored\ntest result: ok. 1 passed; 0 failed; 1 ignored;\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_mismatch")) {
        if (listing) say("a: test\nb: test\n", .{}) else say("test result: ok. 1 passed; 0 failed; 0 ignored;\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_nosummary")) {
        if (listing) say("a: test\n", .{}) else say("test a ... ok\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_fails")) {
        if (listing) {
            say("a: test\n", .{});
            posix.exit(0);
        }
        say("test a ... FAILED\ntest result: FAILED. 0 passed; 1 failed; 0 ignored;\n", .{});
        posix.exit(101);
    }
    if (eq(u8, name, "rust_killed")) {
        if (!listing) posix.raise(posix.SIG.KILL) catch {};
        say("a: test\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_killedlist")) {
        posix.raise(posix.SIG.KILL) catch {};
        posix.exit(0);
    }
    if (eq(u8, name, "rust_hangs")) {
        if (listing) {
            say("a: test\n", .{});
            posix.exit(0);
        }
        // Progress event for the manual clock (rust_test.zig): this file,
        // two levels above the harness's cwd, is the gate's directory.
        const f = posix.open("../../hang_started", .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644) catch posix.exit(97);
        posix.close(f);
        // Blocks until a signal arrives; no timer to race.
        holdWait();
        posix.exit(0);
    }
    if (eq(u8, name, "rust_env")) {
        if (listing) {
            say("a: test\n", .{});
            posix.exit(0);
        }
        for (env) |kv| say("{s}\n", .{kv});
        posix.exit(7);
    }
    posix.exit(98);
}
