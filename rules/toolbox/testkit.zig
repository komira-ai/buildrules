//! What the tests of the toolbox share: a directory of its own where an applet runs, its streams as buffers, and a clock that only records.

const std = @import("std");
const toolbox = @import("toolbox.zig");
const Io = @import("io.zig").Io;

pub const Result = struct { status: u8, out: []const u8, err: []const u8 };

/// What the recording clock was asked to wait for since the last run, in nanoseconds, and how many times.
pub var slept: u64 = 0;
pub var sleeps: u32 = 0;

fn recordSleep(ns: u64) void {
    slept +|= ns;
    sleeps += 1;
}

/// What the recording spawner was asked to run, and what it answers: the program and arguments, the environment as sorted `NAME=VALUE`
/// lines, the directory.
pub var ran_argv: []const []const u8 = &.{};
pub var ran_env: []const []const u8 = &.{};
pub var ran_cwd: []const u8 = "";
pub var ran_count: u32 = 0;
pub var spawn_answer: anyerror!u8 = 0;

fn recordSpawn(a: std.mem.Allocator, argv: []const []const u8, env: *const std.process.EnvMap, cwd: []const u8) anyerror!u8 {
    var lines = std.ArrayList([]const u8).empty;
    var it = env.iterator();
    while (it.next()) |kv| try lines.append(a, try std.fmt.allocPrint(a, "{s}={s}", .{ kv.key_ptr.*, kv.value_ptr.* }));
    std.mem.sort([]const u8, lines.items, {}, lessThan);
    ran_argv = argv;
    ran_env = lines.items;
    ran_cwd = cwd;
    ran_count += 1;
    return spawn_answer;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

pub const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    /// The environment the applet is given.
    environ: []const []const u8 = &.{},
    /// What stdin holds.
    stdin: []const u8 = "",
    /// When set, every write to stdout fails (a closed pipe).
    stdout_closed: bool = false,
    /// When set, every write to stderr fails.
    stderr_closed: bool = false,

    pub fn init() Case {
        return .{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator), .tmp = std.testing.tmpDir(.{ .iterate = true }) };
    }

    pub fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    pub fn alloc(self: *Case) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn put(self: *Case, name: []const u8, bytes: []const u8) !void {
        var f = try self.tmp.dir.createFile(name, .{});
        defer f.close();
        try f.writeAll(bytes);
    }

    pub fn read(self: *Case, name: []const u8) ![]u8 {
        return self.tmp.dir.readFileAlloc(self.alloc(), name, 1 << 24);
    }

    pub fn exists(self: *Case, name: []const u8) bool {
        self.tmp.dir.access(name, .{}) catch return false;
        return true;
    }

    /// The absolute path of `name` in the directory.
    pub fn path(self: *Case, name: []const u8) ![]u8 {
        return self.tmp.dir.realpathAlloc(self.alloc(), name);
    }

    /// The path of `name` in the directory, the directory resolved and `name` not (a link is not followed).
    pub fn at(self: *Case, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.alloc(), "{s}/{s}", .{ try self.path("."), name });
    }

    /// Runs the toolbox as main does, with `args` (the program's name first), in the directory.
    pub fn run(self: *Case, args: []const []const u8) !Result {
        const a = self.alloc();
        var out = std.Io.Writer.Allocating.init(a);
        var err = std.Io.Writer.Allocating.init(a);
        var shut: [0]u8 = undefined;
        var closed = std.Io.Writer.fixed(&shut);
        var in = std.Io.Reader.fixed(self.stdin);
        slept = 0;
        ran_count = 0;
        sleeps = 0;
        const io = Io{
            .a = a,
            .out = if (self.stdout_closed) &closed else &out.writer,
            .err = if (self.stderr_closed) &closed else &err.writer,
            .in = &in,
            .cwd = self.tmp.dir,
            .environ = self.environ,
            .sleep = recordSleep,
            .spawn = recordSpawn,
        };
        const status = toolbox.entry(a, io, args);
        return .{ .status = status, .out = out.written(), .err = err.written() };
    }
};

/// The toolbox executable the test target passes (`env_tools`) as an absolute path. Without it a test fails loudly.
pub fn exe(a: std.mem.Allocator) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, "TOOLBOX") catch {
        std.debug.print("the test target does not pass TOOLBOX (env_tools), so the executable cannot be run\n", .{});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}
