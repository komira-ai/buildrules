//! `check same`, `check copy` and `check digest`: comparing, copying and hashing files.

const std = @import("std");
const common = @import("common.zig");
const Io = common.Io;
const Alloc = common.Alloc;
const Oom = common.Oom;

/// The options `same` and `digest` share, which come first: where the success stamp goes and what it says.
const Stamped = struct {
    out: ?[]const u8 = null,
    stamp: []const u8,
    /// The arguments after the options.
    rest: []const []const u8,
};

/// Reads `--out FILE` and `--stamp TEXT`, in any order, from the front of `args`. Null, with the reason said, for an option that is not one of
/// those or has no value.
fn stamped(io: Io, sub: []const u8, args: []const []const u8, default_stamp: []const u8) ?Stamped {
    var s = Stamped{ .stamp = default_stamp, .rest = args };
    while (s.rest.len > 0 and std.mem.startsWith(u8, s.rest[0], "--")) {
        if (s.rest.len < 2) {
            io.say(sub, &.{ s.rest[0], " needs a value" });
            return null;
        }
        if (std.mem.eql(u8, s.rest[0], "--out")) {
            s.out = s.rest[1];
        } else if (std.mem.eql(u8, s.rest[0], "--stamp")) {
            s.stamp = s.rest[1];
        } else {
            io.say(sub, &.{ "unknown option ", s.rest[0] });
            return null;
        }
        s.rest = s.rest[2..];
    }
    return s;
}

// ---- same -------------------------------------------------------------------------------------------------------

/// Where two files first differ.
const Difference = union(enum) {
    /// The byte (counting from 1) at which they differ.
    byte: u64,
    /// The first file ends, after this many bytes, where the second goes on.
    first_ends: u64,
    second_ends: u64,
};

const same_usage = "usage: check same --out FILE [--stamp TEXT] A B";

/// `check same --out FILE [--stamp TEXT] A B`: the two files are the same bytes. Then FILE is written (`same` and a newline, or TEXT) and the
/// status is 0; otherwise the first difference is said, FILE is not written and the status is 1 (2 when a file cannot be read).
pub fn same(_: Alloc, io: Io, args: []const []const u8) Oom!u8 {
    const s = stamped(io, "same", args, "same\n") orelse return 2;
    const out = s.out orelse {
        io.say("same", &.{same_usage});
        return 2;
    };
    if (s.rest.len != 2) {
        io.say("same", &.{same_usage});
        return 2;
    }
    const names = [2][]const u8{ s.rest[0], s.rest[1] };
    var x = io.cwd.openFile(names[0], .{}) catch |err| return unreadable(io, names[0], err);
    defer x.close();
    var y = io.cwd.openFile(names[1], .{}) catch |err| return unreadable(io, names[1], err);
    defer y.close();
    const diff = firstDifference(x, y) catch |err| {
        io.say("same", &.{ "cannot compare ", names[0], " and ", names[1], ": ", @errorName(err) });
        return 2;
    };
    if (diff) |d| {
        const where = switch (d) {
            .byte => |at| try common.concat(io.a, &.{ "differ at byte ", try common.num(io.a, at) }),
            .first_ends => |n| try endsAfter(io, names[0], n),
            .second_ends => |n| try endsAfter(io, names[1], n),
        };
        io.say("same", &.{ names[0], " and ", names[1], " ", where });
        return 1;
    }
    return if (common.writeFile(io, "same", out, s.stamp)) 0 else 1;
}

fn endsAfter(io: Io, shorter: []const u8, n: u64) Oom![]const u8 {
    return try common.concat(io.a, &.{ "differ: ", shorter, " ends after ", try common.num(io.a, n), " bytes and the other goes on" });
}

fn unreadable(io: Io, path: []const u8, err: anyerror) u8 {
    io.say("same", &.{ "cannot read ", path, ": ", @errorName(err) });
    return 2;
}

fn firstDifference(x: std.fs.File, y: std.fs.File) !?Difference {
    var bx: [8192]u8 = undefined;
    var by: [8192]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const nx = try readFull(x, &bx);
        const ny = try readFull(y, &by);
        const n = @min(nx, ny);
        if (std.mem.indexOfDiff(u8, bx[0..n], by[0..n])) |k| return .{ .byte = offset + k + 1 };
        if (nx < ny) return .{ .first_ends = offset + n };
        if (ny < nx) return .{ .second_ends = offset + n };
        if (n == 0) return null;
        offset += n;
    }
}

/// Reads until `buf` is full or the file ends.
fn readFull(file: std.fs.File, buf: []u8) !usize {
    var have: usize = 0;
    while (have < buf.len) {
        const n = try file.read(buf[have..]);
        if (n == 0) break;
        have += n;
    }
    return have;
}

// ---- copy -------------------------------------------------------------------------------------------------------

/// `check copy SOURCE DESTINATION`: DESTINATION becomes a copy of the file SOURCE, its bytes and its permission bits. It is there whole or
/// not at all, and one that was there is replaced. A source that is missing, or is not a file, is status 1 and nothing is written.
pub fn copy(_: Alloc, io: Io, args: []const []const u8) Oom!u8 {
    if (args.len != 2) {
        io.say("copy", &.{"usage: check copy SOURCE DESTINATION"});
        return 2;
    }
    io.cwd.copyFile(args[0], io.cwd, args[1], .{}) catch |err| {
        io.say("copy", &.{ "cannot copy ", args[0], " to ", args[1], ": ", @errorName(err) });
        return 1;
    };
    return 0;
}

// ---- digest -----------------------------------------------------------------------------------------------------

const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha512 = std.crypto.hash.sha2.Sha512;

const Algorithm = enum { sha256, sha512 };

/// An expected digest: the algorithm, and its bytes (the first `len` of `bytes`).
const Want = struct {
    algorithm: Algorithm,
    bytes: [64]u8,
    len: usize,
};

/// Reads `sha256:<hex>` or `sha512:<hex>`, or an integrity string `sha256-<base64>` or `sha512-<base64>` (the form of a lockfile). Null when
/// it is neither, or the digest has not the length of its algorithm.
fn parseWant(text: []const u8) ?Want {
    const sep = std.mem.indexOfAny(u8, text, ":-") orelse return null;
    const algorithm = std.meta.stringToEnum(Algorithm, text[0..sep]) orelse return null;
    var want = Want{ .algorithm = algorithm, .bytes = undefined, .len = if (algorithm == .sha256) Sha256.digest_length else Sha512.digest_length };
    const body = text[sep + 1 ..];
    if (text[sep] == ':') {
        if (body.len != want.len * 2) return null;
        _ = std.fmt.hexToBytes(want.bytes[0..want.len], body) catch return null;
    } else {
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(body) catch return null;
        if (size != want.len) return null;
        decoder.decode(want.bytes[0..want.len], body) catch return null;
    }
    return want;
}

/// The digest of the whole file, written to the front of `raw`.
fn hashInto(comptime H: type, file: std.fs.File, raw: *[64]u8) !void {
    var h = H.init(.{});
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    h.final(raw[0..H.digest_length]);
}

/// `check digest [--out FILE] [--stamp TEXT] (EXPECTED FILE NAME)...`: each FILE hashes to its EXPECTED digest (`sha256:<hex>`, `sha512:<hex>`,
/// or an integrity string `sha512-<base64>`). Every mismatch is said, by NAME, with the digest the file has, and the status is 1, as it is for a
/// file that cannot be read; an EXPECTED that is none of those forms is status 2. When all match, FILE is written if given (`ok` and a
/// newline, or TEXT).
pub fn digest(_: Alloc, io: Io, args: []const []const u8) Oom!u8 {
    const s = stamped(io, "digest", args, "ok\n") orelse return 2;
    if (s.rest.len == 0 or s.rest.len % 3 != 0) {
        io.say("digest", &.{"usage: check digest [--out FILE] [--stamp TEXT] (EXPECTED FILE NAME)..."});
        return 2;
    }
    var status: u8 = 0;
    var row: usize = 0;
    while (row < s.rest.len) : (row += 3) {
        status = @max(status, try verify(io, s.rest[row], s.rest[row + 1], s.rest[row + 2]));
    }
    if (status != 0) return status;
    const out = s.out orelse return 0;
    return if (common.writeFile(io, "digest", out, s.stamp)) 0 else 1;
}

/// One file against one expected digest: 0 when they match, 1 when they do not or the file cannot be read, 2 when EXPECTED is not a digest.
fn verify(io: Io, expected: []const u8, path: []const u8, name: []const u8) Oom!u8 {
    const want = parseWant(expected) orelse {
        io.say("digest", &.{ name, ": '", expected, "' is not sha256:<hex>, sha512:<hex>, sha256-<base64> or sha512-<base64>" });
        return 2;
    };
    var file = io.cwd.openFile(path, .{}) catch |err| return cannotRead(io, name, path, err);
    defer file.close();
    var raw: [64]u8 = undefined;
    const hashed = switch (want.algorithm) {
        .sha256 => hashInto(Sha256, file, &raw),
        .sha512 => hashInto(Sha512, file, &raw),
    };
    hashed catch |err| return cannotRead(io, name, path, err);
    if (std.mem.eql(u8, raw[0..want.len], want.bytes[0..want.len])) return 0;
    io.say("digest", &.{ name, ": the ", @tagName(want.algorithm), " of ", path, " is ", try common.hex(io.a, raw[0..want.len]), "; expected ", try common.hex(io.a, want.bytes[0..want.len]) });
    return 1;
}

fn cannotRead(io: Io, name: []const u8, path: []const u8, err: anyerror) u8 {
    io.say("digest", &.{ name, ": cannot read ", path, ": ", @errorName(err) });
    return 1;
}
