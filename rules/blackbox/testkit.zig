//! Test support: a scripted platform (no process is started), a case with a temporary directory and buffers for the streams, and the paths of the
//! programs the process cases start for real.

const std = @import("std");
const io_mod = @import("io.zig");
const debkit = @import("debkit");

pub const t = std.testing;
pub const Alloc = std.mem.Allocator;

/// The scripted platform: `runInherit` records the driver's command line and the environment it was given, notes whether the root (its one argument)
/// held `usr/bin/svc` then, and answers `answer`.
pub const Plat = struct {
    a: Alloc,
    /// The command line the driver was run with, its words joined by one space; null when it was not run.
    ran: ?[]const u8 = null,
    /// HOME in the environment the driver was given.
    home: ?[]const u8 = null,
    /// Whether `<root>/usr/bin/svc` was there, and what it held, when the driver ran.
    service: ?[]const u8 = null,
    answer: anyerror!u8 = 0,

    pub fn real(p: *Plat) io_mod.Plat {
        return .{ .ctx = p, .runInherit = runInherit };
    }

    fn runInherit(ctx: *anyopaque, _: Alloc, argv: []const []const u8, env: *const std.process.EnvMap) anyerror!u8 {
        const p: *Plat = @ptrCast(@alignCast(ctx));
        p.ran = std.mem.join(p.a, " ", argv) catch @panic("oom");
        p.home = if (env.get("HOME")) |v| (p.a.dupe(u8, v) catch @panic("oom")) else null;
        const svc = std.fs.path.join(p.a, &.{ argv[1], "usr/bin/svc" }) catch @panic("oom");
        p.service = std.fs.cwd().readFileAlloc(p.a, svc, 1 << 20) catch null;
        return p.answer;
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
        // The root the packages are put onto (a farm job's is `/`).
        try tmp.dir.makePath("root");
        const out = try a.create(std.Io.Writer.Allocating);
        out.* = std.Io.Writer.Allocating.init(a);
        const err = try a.create(std.Io.Writer.Allocating);
        err.* = std.Io.Writer.Allocating.init(a);
        const plat = try a.create(Plat);
        plat.* = .{ .a = a };
        // The environment the processes are given; an entry with no `=` is not one (it is left out).
        const environ = try a.dupe([]const u8, &.{ "A=1", "HOME=/nonexistent", "PREFIX=/p", "NOT_AN_ASSIGNMENT" });
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
    out.appendSlice(c.a, &.{ "--image", image, "--root", c.path("root"), "--package", c.path("pkg.deb"), "--driver", "/d/drv" }) catch @panic("oom");
    out.appendSlice(c.a, extra) catch @panic("oom");
    return out.items;
}
