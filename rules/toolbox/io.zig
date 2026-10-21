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
        sayOrFail(io, applet, parts) catch {};
    }

    fn sayOrFail(io: Io, applet: []const u8, parts: []const []const u8) Oom!void {
        var line = Buf{ .a = io.a };
        try line.add(applet);
        try line.add(": ");
        for (parts) |part| try line.add(part);
        try line.byte(0x0a);
        io.err.writeAll(line.items) catch {};
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

/// The one way an applet can fail by itself: an allocation that failed. The applet ends, the program says so and exits 1.
pub const Oom = error{OutOfMemory};

/// A byte buffer that grows by a new allocation at every addition: the sizes here are small, and every addition is a place an allocation can
/// fail, which the tests fail one at a time.
pub const Buf = struct {
    items: []const u8 = "",
    a: Alloc,

    pub fn add(b: *Buf, bytes: []const u8) Oom!void {
        const grown = try b.a.alloc(u8, b.items.len + bytes.len);
        @memcpy(grown[0..b.items.len], b.items);
        @memcpy(grown[b.items.len..], bytes);
        b.items = grown;
    }

    pub fn byte(b: *Buf, c: u8) Oom!void {
        try b.add(&.{c});
    }
};

/// A list of strings, the same.
pub const Strings = struct {
    items: [][]const u8 = &.{},
    a: Alloc,

    pub fn add(s: *Strings, item: []const u8) Oom!void {
        const grown = try s.a.alloc([]const u8, s.items.len + 1);
        @memcpy(grown[0..s.items.len], s.items);
        grown[s.items.len] = item;
        s.items = grown;
    }
};

/// The path made of `parts`, joined by `/`.
pub fn join(a: Alloc, parts: []const []const u8) Oom![]const u8 {
    return std.fs.path.join(a, parts);
}
