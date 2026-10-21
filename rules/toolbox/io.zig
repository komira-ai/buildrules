//! What every applet of the toolbox is given: the streams, the working directory, the environment and the clock. The program
//! passes the process's own; the tests pass buffers and a temporary directory, so an applet is run in-process and its exact bytes
//! and messages are read back.

const std = @import("std");

pub const Alloc = std.mem.Allocator;

pub const Io = struct {
    /// Where an applet allocates; nothing is freed before the process ends.
    a: Alloc,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    in: *std.Io.Reader,
    /// Where a relative path is resolved.
    cwd: std.fs.Dir,
    /// The environment, `NAME=VALUE` entries in the order the process was given them.
    environ: []const []const u8,
    /// Sleeps for that many nanoseconds.
    sleep: *const fn (ns: u64) void,
    /// Runs `argv` with exactly `env` as its environment in the directory `cwd`, standard streams inherited, and returns its exit status
    /// (`statusOf`); an error when it cannot be run.
    spawn: *const fn (a: Alloc, argv: []const []const u8, env: *const std.process.EnvMap, cwd: []const u8) anyerror!u8,

    /// Writes `bytes` to stdout; false when the write failed (a closed pipe, a full disk).
    pub fn put(io: Io, bytes: []const u8) bool {
        io.out.writeAll(bytes) catch return false;
        return true;
    }

    /// One message line on stderr, `<applet>: <parts>`; the parts are written one after another. A failed write of a message is not
    /// reported anywhere. (Parts rather than a format: one function, whatever the message.)
    pub fn say(io: Io, applet: []const u8, parts: []const []const u8) void {
        var line = Buf{ .a = io.a };
        line.add(applet);
        line.add(": ");
        for (parts) |part| line.add(part);
        line.byte('\n');
        io.err.writeAll(line.list.items) catch {};
    }
};

/// What a failed file-system call says, in the words of the C library's `strerror` for the errors an applet meets, the error's own
/// name for the rest.
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "No such file or directory",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        error.AccessDenied => "Permission denied",
        error.PathAlreadyExists => "File exists",
        else => @errorName(err),
    };
}

/// The exit status of a child that ended as `term`: its own status, 128 and the signal for one killed by a signal (as a shell reports
/// it), 255 for anything else.
pub fn statusOf(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| @intCast(128 + (s & 0x7f)),
        else => 255,
    };
}

pub fn oom() noreturn {
    std.debug.print("toolbox: out of memory\n", .{});
    std.process.exit(1);
}

/// A growing byte buffer whose one allocation failure is the process's end: every applet builds its output in one.
pub const Buf = struct {
    list: std.ArrayList(u8) = .empty,
    a: Alloc,

    pub fn add(b: *Buf, bytes: []const u8) void {
        b.list.appendSlice(b.a, bytes) catch oom();
    }

    pub fn byte(b: *Buf, c: u8) void {
        b.add(&.{c});
    }
};

/// A growing list of strings, the same.
pub const Strings = struct {
    list: std.ArrayList([]const u8) = .empty,
    a: Alloc,

    pub fn add(s: *Strings, item: []const u8) void {
        s.list.append(s.a, item) catch oom();
    }
};

/// The path made of `parts`, joined by `/`.
pub fn join(a: Alloc, parts: []const []const u8) []const u8 {
    return std.fs.path.join(a, parts) catch oom();
}
