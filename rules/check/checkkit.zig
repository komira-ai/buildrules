//! What the tests of `check` share: a directory of its own where a command runs, its streams as buffers, and the toolbox executable as the
//! program the commands start (rules/toolbox, passed by the test target as TOOLBOX): `toolbox echo`, `toolbox printenv NAME`, `toolbox cat FILE`,
//! `toolbox mkdir -p DIR` and `toolbox true|false` are the programs whose environment, working directory and exit status the cases read back.

const std = @import("std");
const check = @import("check.zig");
const common = @import("common.zig");

pub const Args = []const []const u8;

pub const Result = struct { status: u8, out: []const u8, err: []const u8 };

pub const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    /// The environment the command is given.
    environ: []const []const u8 = &.{},
    /// The toolbox executable, absolute.
    toolbox: []const u8,
    /// When set, every write to stdout fails (a closed pipe).
    stdout_closed: bool = false,

    pub fn init() !Case {
        var c = Case{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .tmp = std.testing.tmpDir(.{ .iterate = true }),
            .toolbox = "",
        };
        c.toolbox = try toolboxPath(c.arena.allocator());
        return c;
    }

    pub fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    pub fn alloc(self: *Case) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn put(self: *Case, name: []const u8, bytes: []const u8) !void {
        if (std.fs.path.dirname(name)) |d| try self.tmp.dir.makePath(d);
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

    /// The absolute path of `name` in the directory; it has to be there.
    pub fn path(self: *Case, name: []const u8) ![]u8 {
        return self.tmp.dir.realpathAlloc(self.alloc(), name);
    }

    /// `path` of the directory itself, plus `/name`: for a name that is not there yet.
    pub fn at(self: *Case, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.alloc(), "{s}/{s}", .{ try self.path("."), name });
    }

    /// Runs `check` as main does, with `args` (after the program's name), in the directory.
    pub fn run(self: *Case, args: Args) !Result {
        const a = self.alloc();
        var out = std.Io.Writer.Allocating.init(a);
        var err = std.Io.Writer.Allocating.init(a);
        var shut: [0]u8 = undefined;
        var closed = std.Io.Writer.fixed(&shut);
        const io = common.Io{ .a = a, .out = if (self.stdout_closed) &closed else &out.writer, .err = &err.writer, .cwd = self.tmp.dir, .environ = self.environ };
        const status = check.entry(a, io, args);
        return .{ .status = status, .out = out.written(), .err = err.written() };
    }

    /// `before`, then `--`, the toolbox, and `program`: the command line of a command that starts a toolbox applet.
    pub fn line(self: *Case, before: Args, program: Args) !Args {
        const a = self.alloc();
        var all = std.ArrayList([]const u8).empty;
        try all.appendSlice(a, before);
        try all.append(a, "--");
        try all.append(a, self.toolbox);
        try all.appendSlice(a, program);
        return all.items;
    }

    /// Runs `before -- toolbox program...`.
    pub fn runTool(self: *Case, before: Args, program: Args) !Result {
        return self.run(try self.line(before, program));
    }
};

/// The toolbox executable the test target passes (`env_tools`), absolute. Without it a test fails loudly.
pub fn toolboxPath(a: std.mem.Allocator) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, "TOOLBOX") catch {
        std.debug.print("the test target does not pass TOOLBOX (env_tools), so the programs the cases start are missing\n", .{});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

/// `status`, `out` and `err` are what the run ended with, exactly (`err` null: not looked at).
pub fn expectResult(r: Result, status: u8, out: []const u8, err: ?[]const u8) !void {
    if (r.status != status or !std.mem.eql(u8, r.out, out) or (err != null and !std.mem.eql(u8, r.err, err.?))) {
        std.debug.print("status {d} (want {d}); stdout '{s}' (want '{s}'); stderr '{s}' (want '{s}')\n", .{ r.status, status, r.out, out, r.err, err orelse "(any)" });
        return error.TestUnexpectedResult;
    }
}

/// The run ended with `status`, and its stderr holds `needle`.
pub fn expectFailure(r: Result, status: u8, needle: []const u8) !void {
    if (r.status != status or std.mem.indexOf(u8, r.err, needle) == null) {
        std.debug.print("status {d} (want {d}); stderr '{s}' lacks '{s}'\n", .{ r.status, status, r.err, needle });
        return error.TestUnexpectedResult;
    }
}

/// A pair of buffers and the `Io` that writes to them, for a function that is called directly.
pub const Streams = struct {
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,

    pub fn init(a: std.mem.Allocator) Streams {
        return .{ .out = std.Io.Writer.Allocating.init(a), .err = std.Io.Writer.Allocating.init(a) };
    }

    pub fn io(self: *Streams, c: *Case) common.Io {
        return .{ .a = c.alloc(), .out = &self.out.writer, .err = &self.err.writer, .cwd = c.tmp.dir, .environ = c.environ };
    }
};

/// The value of the variable `name` as a program started by `before -- toolbox printenv NAME` sees it; null when it is not set.
pub fn valueOf(c: *Case, before: Args, name: []const u8) !?[]const u8 {
    var all = std.ArrayList([]const u8).empty;
    const a = c.alloc();
    try all.appendSlice(a, &.{ "marker", "--capture", "--stamp-log", "--out", "valueof.out" });
    try all.appendSlice(a, before);
    const r = try c.runTool(all.items, &.{ "printenv", name });
    if (r.status == 1) return null;
    try expectResult(r, 0, "", "");
    const text = try c.read("valueof.out");
    try std.testing.expect(text.len > 0 and text[text.len - 1] == '\n');
    return text[0 .. text.len - 1];
}
