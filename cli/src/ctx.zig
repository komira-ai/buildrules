//! What every subcommand runs in: an allocator, the directory its relative
//! paths are under, the two output streams and the seam that starts a child
//! process. Tests give a temporary directory, in-memory streams and a fake
//! runner; `main` gives the working directory, the real streams and `spawn`.

const std = @import("std");

pub const exit_ok: u8 = 0;
/// A failed check, a refused input, a command that did not finish.
pub const exit_fail: u8 = 1;
pub const exit_usage: u8 = 2;

pub const Runner = *const fn (ctx: *Ctx, argv: []const []const u8) anyerror!u8;

/// A child process with an environment and its standard output captured (`sync` runs cargo, buck2
/// and the generator through this seam; tests give a fake).
pub const Exec = struct {
    argv: []const []const u8,
    /// Variables added to the inherited environment.
    env: []const [2][]const u8 = &.{},
    /// Capture the child's standard output into `ExecResult.stdout` (otherwise it is inherited).
    capture: bool = false,
};

pub const ExecResult = struct { code: u8, stdout: []const u8 = "" };

pub const Execer = *const fn (ctx: *Ctx, spec: Exec) anyerror!ExecResult;

pub const Ctx = struct {
    a: std.mem.Allocator,
    dir: std.fs.Dir,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    runner: Runner = &spawn,
    execer: Execer = &execReal,

    pub fn say(self: *Ctx, comptime fmt: []const u8, args: anytype) void {
        self.out.print(fmt ++ "\n", args) catch {};
    }

    /// Prints the message and returns `exit_fail`.
    pub fn fail(self: *Ctx, comptime fmt: []const u8, args: anytype) u8 {
        self.err.print("buildrules: " ++ fmt ++ "\n", args) catch {};
        return exit_fail;
    }

    /// Prints the message and returns `exit_usage`.
    pub fn usage(self: *Ctx, comptime fmt: []const u8, args: anytype) u8 {
        self.err.print("buildrules: " ++ fmt ++ "\n", args) catch {};
        return exit_usage;
    }

    pub fn read(self: *Ctx, path: []const u8) ![]u8 {
        return self.dir.readFileAlloc(self.a, path, 64 << 20);
    }

    /// The file, or null when it does not exist.
    pub fn readOpt(self: *Ctx, path: []const u8) !?[]u8 {
        return self.read(path) catch |e| switch (e) {
            error.FileNotFound => null,
            else => e,
        };
    }

    pub fn exists(self: *Ctx, path: []const u8) bool {
        self.dir.access(path, .{}) catch return false;
        return true;
    }

    /// Writes through a sibling file and a rename (a crash never leaves half
    /// a file) and makes the parent directories.
    pub fn write(self: *Ctx, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |d| try self.dir.makePath(d);
        const tmp = try std.fmt.allocPrint(self.a, "{s}.buildrules-tmp", .{path});
        try self.dir.writeFile(.{ .sub_path = tmp, .data = data });
        try self.dir.rename(tmp, path);
    }

    /// The context for the directory `sub` of this one.
    pub fn into(self: *Ctx, sub: []const u8) !Ctx {
        var c = self.*;
        c.dir = try self.dir.openDir(sub, .{});
        return c;
    }
};

/// Runs `argv` with the context's directory as the child's working directory,
/// output inherited. Returns its exit code (1 when it was killed).
pub fn spawn(ctx: *Ctx, argv: []const []const u8) anyerror!u8 {
    ctx.out.flush() catch {};
    ctx.err.flush() catch {};
    var child = std.process.Child.init(argv, ctx.a);
    child.cwd_dir = ctx.dir;
    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |c| c,
        else => 1,
    };
}

/// Runs the spec with the context's directory as the working directory. Standard error is inherited;
/// the exit code is 1 when the child was killed.
pub fn execReal(ctx: *Ctx, spec: Exec) anyerror!ExecResult {
    ctx.out.flush() catch {};
    ctx.err.flush() catch {};
    var env = try std.process.getEnvMap(ctx.a);
    for (spec.env) |kv| try env.put(kv[0], kv[1]);
    var child = std.process.Child.init(spec.argv, ctx.a);
    child.cwd_dir = ctx.dir;
    child.env_map = &env;
    child.stdout_behavior = if (spec.capture) .Pipe else .Inherit;
    try child.spawn();
    var captured: []u8 = &.{};
    if (spec.capture) {
        var buf: [4096]u8 = undefined;
        var r = child.stdout.?.reader(&buf);
        captured = try r.interface.allocRemaining(ctx.a, .unlimited);
    }
    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 1,
    };
    return .{ .code = code, .stdout = captured };
}

/// The lines of `text` that are not in `have`, as a flat list; used to append
/// to line files (.gitignore) without duplicating a line.
pub fn missingLines(a: std.mem.Allocator, have: []const u8, want: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (want) |w| {
        var found = false;
        var it = std.mem.splitScalar(u8, have, '\n');
        while (it.next()) |l| {
            if (std.mem.eql(u8, std.mem.trim(u8, l, " \t\r"), w)) found = true;
        }
        if (!found) try out.append(a, w);
    }
    return out.toOwnedSlice(a);
}

pub fn sha256Hex(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
}

/// Args parsing: the value after `flag` at `i.*` (advancing it), or null when
/// there is none.
pub fn flagValue(args: []const []const u8, i: *usize) ?[]const u8 {
    if (i.* + 1 >= args.len) return null;
    i.* += 1;
    return args[i.*];
}
