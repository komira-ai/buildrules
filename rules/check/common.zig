//! What every subcommand of `check` is given and shares: the streams, the working directory and the environment (the program passes the
//! process's own; the tests pass buffers and a temporary directory), the messages, and the one way an output file is written.

const std = @import("std");

pub const Alloc = std.mem.Allocator;

pub const Io = struct {
    /// Where a command allocates; nothing is freed before the process ends.
    a: Alloc,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    /// Where a relative path is resolved; also the directory a program is run in unless the command line says another.
    cwd: std.fs.Dir,
    /// The environment, `NAME=VALUE` entries in the order the process was given them.
    environ: []const []const u8,

    /// One message line on stderr, `check <subcommand>: <parts>`; the parts are written one after another. A failed write of a message is
    /// not reported anywhere. (Parts rather than a format: one function, whatever the message.)
    pub fn say(io: Io, sub: []const u8, parts: []const []const u8) void {
        sayOrFail(io, sub, parts) catch {};
    }

    fn sayOrFail(io: Io, sub: []const u8, parts: []const []const u8) Oom!void {
        var line = Buf{ .a = io.a };
        try line.add("check ");
        try line.add(sub);
        try line.add(": ");
        for (parts) |part| try line.add(part);
        try line.byte(0x0a);
        io.err.writeAll(line.items) catch {};
    }

    /// The value of `name` in the process's environment, the first of that name; null when there is none.
    pub fn getenv(io: Io, name: []const u8) ?[]const u8 {
        for (io.environ) |entry| {
            if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name)) {
                return entry[name.len + 1 ..];
            }
        }
        return null;
    }
};

/// The one way a command can fail by itself: an allocation that failed. The command ends, the program says so and exits 1.
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

/// The parts, one after another.
pub fn concat(a: Alloc, parts: []const []const u8) Oom![]const u8 {
    return std.mem.concat(a, u8, parts);
}

/// The path of `p` made absolute against `base` (itself absolute): `p` when it starts with `/`, else `base/p`.
pub fn absolute(a: Alloc, base: []const u8, p: []const u8) Oom![]const u8 {
    if (p.len > 0 and p[0] == '/') return p;
    return join(a, &.{ base, p });
}

/// `n` in decimal.
pub fn num(a: Alloc, n: u64) Oom![]const u8 {
    return std.fmt.allocPrint(a, "{d}", .{n});
}

/// The bytes as lowercase hexadecimal.
pub fn hex(a: Alloc, bytes: []const u8) Oom![]const u8 {
    const digits = "0123456789abcdef";
    var out = Buf{ .a = a };
    for (bytes) |b| {
        try out.byte(digits[b >> 4]);
        try out.byte(digits[b & 15]);
    }
    return out.items;
}

/// Writes `bytes` as the whole of the file `path` (relative to the working directory) through a temporary file in its directory, renamed over
/// it: the file is there complete or not at all, and an existing one is replaced. False, with the reason said, when that failed.
pub fn writeFile(io: Io, sub: []const u8, path: []const u8, bytes: []const u8) bool {
    var buf: [4096]u8 = undefined;
    var af = io.cwd.atomicFile(path, .{ .write_buffer = &buf }) catch |err| return wroteBadly(io, sub, path, "temporary file", err);
    defer af.deinit();
    af.file_writer.interface.writeAll(bytes) catch |err| return wroteBadly(io, sub, path, "write", if (err == error.WriteFailed) (af.file_writer.err orelse err) else err);
    af.finish() catch |err| return wroteBadly(io, sub, path, "rename", err);
    return true;
}

fn wroteBadly(io: Io, sub: []const u8, path: []const u8, step: []const u8, err: anyerror) bool {
    io.say(sub, &.{ "cannot write ", path, ": ", step, ": ", @errorName(err) });
    return false;
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
