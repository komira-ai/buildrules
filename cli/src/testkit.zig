//! Test support: a temporary directory, in-memory output streams and a context
//! over them, so a test runs `main.run` the way the binary does.
//!
//! Every command line a test runs is also replayed (`Harness.run`, "Replays" below): on a copy of the directory as it was before the run, once with output
//! streams that fail and then with the allocator failing from its 1st, 2nd, ... allocation on. The tests thereby cover the error exits that no input reaches
//! (a stream that cannot be written, an allocation that fails in the middle of a command), and each of them is held to what a command promises then.

const std = @import("std");
const ctxm = @import("ctx.zig");
const main = @import("main.zig");
const t = std.testing;

/// Set while a command is run as a replay on a copy of the directory: a fake that keeps a record of what it was asked leaves its record alone.
pub var replaying = false;
/// Whether `Harness.run` makes the replays.
pub var sweep = true;
/// Print what each replay set did (its allocation failures, its milliseconds) and the commands that exit 0 although an allocation failed.
pub var trace = false;

pub const Run = struct { code: u8, out: []const u8, err: []const u8 };

var seen_scenarios: std.AutoHashMapUnmanaged(u64, void) = .empty;

const max_failure_index: usize = 100_000;

/// A command line, the files it ran on and what it did: two runs with the same key replay the same way.
fn scenarioKey(argv: []const []const u8, dir: std.fs.Dir, real: Run) u64 {
    var h = std.hash.Wyhash.init(0);
    for (argv) |x| {
        h.update(x);
        h.update("\x00");
    }
    h.update(&.{real.code});
    h.update(real.out);
    h.update("\x00");
    h.update(real.err);
    var tree: u64 = 0;
    var w = dir.walk(t.allocator) catch return h.final();
    defer w.deinit();
    while (w.next() catch null) |e| {
        if (e.kind != .file) continue;
        var f = std.hash.Wyhash.init(1);
        f.update(e.path);
        const data = dir.readFileAlloc(t.allocator, e.path, 64 << 20) catch continue;
        defer t.allocator.free(data);
        f.update(data);
        tree +%= f.final();
    }
    h.update(std.mem.asBytes(&tree));
    return h.final();
}

/// The first file of `dir` that is a write `ctx.write` began and did not finish (its sibling file is named `.buildrules-tmp`); null when there is none.
fn firstUnfinishedWrite(a: std.mem.Allocator, dir: std.fs.Dir) ?[]const u8 {
    var w = dir.walk(a) catch return null;
    defer w.deinit();
    while (w.next() catch null) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.path, ".buildrules-tmp")) return a.dupe(u8, e.path) catch "(out of memory)";
    }
    return null;
}

fn joined(argv: []const []const u8) []const u8 {
    const S = struct {
        var buf: [512]u8 = undefined;
    };
    var n: usize = 0;
    for (argv) |x| {
        if (n + x.len + 1 > S.buf.len) break;
        @memcpy(S.buf[n..][0..x.len], x);
        n += x.len;
        S.buf[n] = ' ';
        n += 1;
    }
    return S.buf[0..n];
}

/// Copies the files of `src` into `dst`.
fn cloneInto(a: std.mem.Allocator, src: std.fs.Dir, dst: std.fs.Dir) !void {
    var w = try src.walk(a);
    defer w.deinit();
    while (try w.next()) |e| switch (e.kind) {
        .directory => try dst.makePath(e.path),
        .file => {
            if (std.fs.path.dirname(e.path)) |d| try dst.makePath(d);
            try src.copyFile(e.path, dst, e.path, .{});
        },
        .sym_link => {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const target = try src.readLink(e.path, &buf);
            try dst.symLink(target, e.path, .{});
        },
        else => {},
    };
}

pub const Harness = struct {
    ar: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,
    ctx: ctxm.Ctx,

    pub fn create() !*Harness {
        const self = try t.allocator.create(Harness);
        self.ar = std.heap.ArenaAllocator.init(t.allocator);
        self.tmp = std.testing.tmpDir(.{ .iterate = true });
        self.out = std.Io.Writer.Allocating.init(self.ar.allocator());
        self.err = std.Io.Writer.Allocating.init(self.ar.allocator());
        self.ctx = .{ .a = self.ar.allocator(), .dir = self.tmp.dir, .out = &self.out.writer, .err = &self.err.writer };
        return self;
    }

    pub fn destroy(self: *Harness) void {
        self.tmp.cleanup();
        self.ar.deinit();
        t.allocator.destroy(self);
    }

    pub fn a(self: *Harness) std.mem.Allocator {
        return self.ar.allocator();
    }

    /// Runs the command line and returns what it printed; then replays it (see the top of this file).
    pub fn run(self: *Harness, argv: []const []const u8) Run {
        var snap = std.testing.tmpDir(.{ .iterate = true });
        defer snap.cleanup();
        if (sweep) cloneInto(t.allocator, self.tmp.dir, snap.dir) catch |e| std.debug.panic("replay: cannot copy the directory: {s}", .{@errorName(e)});
        self.out.clearRetainingCapacity();
        self.err.clearRetainingCapacity();
        const code = main.run(&self.ctx, argv);
        const r: Run = .{ .code = code, .out = self.out.written(), .err = self.err.written() };
        if (sweep) self.replays(argv, snap.dir, r);
        return r;
    }

    // ---- Replays ------------------------------------------------------------------------------------------

    /// What the command line (run just now as `real` on this directory, which `before` is a copy of, from before the run) promises when it is run again:
    ///  - with an output stream that fails on every write, it ends with the exit code it ended with when the streams worked;
    ///  - with the allocator failing at its Nth allocation and at every later one, for N = 0, 1, 2, ... until a run meets no failure, it ends (it does not
    ///    crash or loop) and leaves no write half done (the `.buildrules-tmp` file `Ctx.write` renames into place).
    /// Runs that fail an allocation are not held to an exit code: a command that records its error in a `Diag` loses the record when the allocation of it
    /// fails (diag.zig), and that is how some of them end 0; `trace` lists them.
    fn replays(self: *Harness, argv: []const []const u8, before: std.fs.Dir, real: Run) void {
        const key = scenarioKey(argv, before, real);
        if (seen_scenarios.contains(key)) return;
        seen_scenarios.put(std.heap.page_allocator, key, {}) catch return;
        replaying = true;
        defer replaying = false;
        const t0 = std.time.milliTimestamp();
        {
            var work = std.testing.tmpDir(.{ .iterate = true });
            defer work.cleanup();
            cloneInto(t.allocator, before, work.dir) catch |e| std.debug.panic("replay: cannot copy the directory: {s}", .{@errorName(e)});
            var arena = std.heap.ArenaAllocator.init(t.allocator);
            defer arena.deinit();
            var out = std.Io.Writer.failing;
            var err = std.Io.Writer.failing;
            var c = self.ctx;
            c.dir = work.dir;
            c.a = arena.allocator();
            c.out = &out;
            c.err = &err;
            const code = main.run(&c, argv);
            if (code != real.code) std.debug.panic("`{s}`: exit {d} when the output streams fail, {d} when they work", .{ joined(argv), code, real.code });
        }
        var failures: usize = 0;
        var exit_zero: usize = 0;
        var i: usize = 0;
        while (i < max_failure_index) : (i += if (i < 300) 1 else 7) {
            var work = std.testing.tmpDir(.{ .iterate = true });
            defer work.cleanup();
            cloneInto(t.allocator, before, work.dir) catch |e| std.debug.panic("replay: cannot copy the directory: {s}", .{@errorName(e)});
            var arena = std.heap.ArenaAllocator.init(t.allocator);
            defer arena.deinit();
            var fa = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = i });
            var out_buf: [64]u8 = undefined;
            var err_buf: [64]u8 = undefined;
            var out = std.Io.Writer.Discarding.init(&out_buf);
            var err = std.Io.Writer.Discarding.init(&err_buf);
            var c = self.ctx;
            c.dir = work.dir;
            c.a = fa.allocator();
            c.out = &out.writer;
            c.err = &err.writer;
            const code = main.run(&c, argv);
            if (!fa.has_induced_failure) break;
            failures += 1;
            if (code == 0) exit_zero += 1;
            if (firstUnfinishedWrite(t.allocator, work.dir)) |path| {
                std.debug.panic("`{s}`: with allocation {d} failing, the run left {s}, a write it began and did not finish", .{ joined(argv), i, path });
            }
        }
        if (trace) std.debug.print("replay {s}: {d} allocation failures ({d} exit 0), {d} ms\n", .{ joined(argv), failures, exit_zero, std.time.milliTimestamp() - t0 });
    }

    pub fn put(self: *Harness, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |d| try self.tmp.dir.makePath(d);
        try self.tmp.dir.writeFile(.{ .sub_path = path, .data = data });
    }

    pub fn read(self: *Harness, path: []const u8) []const u8 {
        return self.tmp.dir.readFileAlloc(self.a(), path, 1 << 20) catch |e| std.debug.panic("read {s}: {s}", .{ path, @errorName(e) });
    }

    pub fn has(self: *Harness, path: []const u8) bool {
        self.tmp.dir.access(path, .{}) catch return false;
        return true;
    }
};

/// Runs `ctx.call(allocator)` with the allocator failing at its 1st, 2nd, ... allocation (and at every one after it), until a run meets no failure.
/// `call` answers whether the step reported success (a parse that returned, a render that returned). The run that meets no failure must report
/// success. With `strict`, a run in which an allocation failed must not have reported success: an out-of-memory that a function swallowed
/// would otherwise hand the caller a wrong answer as a right one. Without it, the sweep proves only that each failing allocation ends the call.
pub fn sweepOom(ctx: anytype, strict: bool) !void {
    return allocSweep(ctx, strict, true);
}

/// `sweepOom` for a call that is meant to refuse (its answer is false, with a message) and not to succeed: the run that meets no failure may answer either.
pub fn sweepOomRefusal(ctx: anytype) !void {
    return allocSweep(ctx, false, false);
}

fn allocSweep(ctx: anytype, strict: bool, must_succeed: bool) !void {
    var backing = std.heap.ArenaAllocator.init(t.allocator);
    defer backing.deinit();
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        _ = backing.reset(.retain_capacity);
        var fa = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = i });
        const reported = ctx.call(fa.allocator()) catch false;
        if (!fa.has_induced_failure) {
            if (must_succeed) try t.expect(reported);
            return;
        }
        if (strict and reported) {
            std.debug.print("the call reported success although allocation {d} failed\n", .{i});
            return error.SwallowedOutOfMemory;
        }
    }
    return error.SweepDidNotEnd;
}

pub fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// How many times `needle` occurs in `hay`.
pub fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}
