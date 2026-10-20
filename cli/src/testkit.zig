//! Test support: a temporary directory, in-memory output streams and a context
//! over them, so a test runs `main.run` the way the binary does.

const std = @import("std");
const ctxm = @import("ctx.zig");
const main = @import("main.zig");
const t = std.testing;

pub const Run = struct { code: u8, out: []const u8, err: []const u8 };

pub const Harness = struct {
    ar: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,
    ctx: ctxm.Ctx,

    pub fn create() !*Harness {
        const self = try t.allocator.create(Harness);
        self.ar = std.heap.ArenaAllocator.init(t.allocator);
        self.tmp = std.testing.tmpDir(.{});
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

    /// Runs the command line and returns what it printed.
    pub fn run(self: *Harness, argv: []const []const u8) Run {
        self.out.clearRetainingCapacity();
        self.err.clearRetainingCapacity();
        const code = main.run(&self.ctx, argv);
        return .{ .code = code, .out = self.out.written(), .err = self.err.written() };
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

pub fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// How many times `needle` occurs in `hay`.
pub fn count(hay: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, hay, needle);
}
