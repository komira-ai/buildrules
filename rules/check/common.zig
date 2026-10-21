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
        var line = Buf{ .a = io.a };
        line.add("check ");
        line.add(sub);
        line.add(": ");
        for (parts) |part| line.add(part);
        line.byte('\n');
        io.err.writeAll(line.list.items) catch {};
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

pub fn oom() noreturn {
    std.debug.print("check: out of memory\n", .{});
    std.process.exit(1);
}

/// A growing byte buffer whose one allocation failure is the process's end.
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

/// The parts, one after another.
pub fn concat(a: Alloc, parts: []const []const u8) []const u8 {
    return std.mem.concat(a, u8, parts) catch oom();
}

/// The path of `p` made absolute against `base` (itself absolute): `p` when it starts with `/`, else `base/p`.
pub fn absolute(a: Alloc, base: []const u8, p: []const u8) []const u8 {
    if (p.len > 0 and p[0] == '/') return p;
    return join(a, &.{ base, p });
}

/// `n` in decimal.
pub fn num(a: Alloc, n: u64) []const u8 {
    return std.fmt.allocPrint(a, "{d}", .{n}) catch oom();
}

/// The bytes as lowercase hexadecimal.
pub fn hex(a: Alloc, bytes: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    var out = Buf{ .a = a };
    for (bytes) |b| {
        out.byte(digits[b >> 4]);
        out.byte(digits[b & 15]);
    }
    return out.list.items;
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
