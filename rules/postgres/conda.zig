//! What pg_prefix reads of a `.conda`: the zip of stored members (`pkg-<name>.tar.zst`, the payload; `info-<name>.tar.zst`, the facts about
//! it), the tar inside the zstd frame, the shape of a member path, and the prefix placeholder `info/paths.json` names for a file.
//!
//! The zip walk and the zstd/tar reading are those of rules/mojo/tools/prebuilt_unpack.zig, written again here: a package may not import another's
//! sources, and this one needs the whole payload, not named members.

const std = @import("std");

pub const Alloc = std.mem.Allocator;
pub const Oom = error{OutOfMemory};

/// The zstd window the reader is given: the largest a conda-forge package uses, 128 MiB.
pub const window_max: u32 = 1 << 27;

/// The largest member taken: 512 MiB, on the size its tar header declares.
pub const max_member: u64 = 512 << 20;

fn le16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}
fn le32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn le64(b: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, b[at..][0..8], .little);
}

fn zip64CompressedSize(extra: []const u8, usize_is_64: bool) ?u64 {
    var i: usize = 0;
    while (i + 4 <= extra.len) {
        const id = le16(extra, i);
        const len = le16(extra, i + 2);
        if (i + 4 + len > extra.len) return null;
        if (id == 0x0001) {
            var at = i + 4;
            if (usize_is_64) at += 8;
            if (at + 8 > i + 4 + len) return null;
            return le64(extra, at);
        }
        i += 4 + len;
    }
    return null;
}

pub const ZipError = error{ BadZip, DuplicatePayload, NoPayload };

/// The body of the `pkg-*.tar.zst` member of a `.conda` (a zip of stored members).
pub fn payload(data: []const u8) ZipError![]const u8 {
    return tarOf(data, "pkg-");
}

/// The body of the `info-*.tar.zst` member: `info/index.json`, `info/paths.json` and the other facts about the package.
pub fn infoPayload(data: []const u8) ZipError![]const u8 {
    return tarOf(data, "info-");
}

fn tarOf(data: []const u8, prefix: []const u8) ZipError![]const u8 {
    var found: ?[]const u8 = null;
    var off: usize = 0;
    while (off + 30 <= data.len and le32(data, off) == 0x04034b50) {
        const flags = le16(data, off + 6);
        const method = le16(data, off + 8);
        var csize: u64 = le32(data, off + 18);
        const usize32 = le32(data, off + 22);
        const nlen = le16(data, off + 26);
        const xlen = le16(data, off + 28);
        const start = off + 30 + nlen + xlen;
        if (start > data.len) return error.BadZip;
        const name = data[off + 30 .. off + 30 + nlen];
        const extra = data[off + 30 + nlen .. start];
        if (flags & 0x8 != 0 or method != 0) return error.BadZip;
        if (csize == 0xffffffff) csize = zip64CompressedSize(extra, usize32 == 0xffffffff) orelse return error.BadZip;
        if (start + csize > data.len) return error.BadZip;
        const body = data[start .. start + @as(usize, @intCast(csize))];
        off = start + @as(usize, @intCast(csize));
        if (std.mem.startsWith(u8, name, prefix) and std.mem.endsWith(u8, name, ".tar.zst")) {
            // A `.conda` has one of each; with two, which one an unpacker takes is its own business, so there is no right answer.
            if (found != null) return error.DuplicatePayload;
            found = body;
        }
    }
    return found orelse error.NoPayload;
}

/// A zstd-compressed tar read member by member. The tar is decompressed whole first and then walked from memory: the tar iterator passes over each
/// member's padding by discarding it, and the discard of this release's zstd reader asserts (`Decompress.rebase`), on the padding of real conda-forge
/// packages as well as on a skipped body. A payload is tens of megabytes. The readers point into the struct, so it is never moved after `open`.
pub const Walk = struct {
    data: []const u8,
    /// Why the tar could not be decompressed; `next` returns it.
    failed: ?anyerror,
    name_buf: [std.fs.max_path_bytes]u8,
    link_buf: [std.fs.max_path_bytes]u8,
    rin: std.Io.Reader,
    it: std.tar.Iterator,

    /// Decompresses `tar_zst` and starts the walk over it; `window_len` is the zstd window it accepts (`window_max` in the program).
    pub fn open(w: *Walk, a: Alloc, tar_zst: []const u8, window_len: u32) Oom!void {
        const window = try a.alloc(u8, @as(usize, window_len) + std.compress.zstd.block_size_max);
        defer a.free(window);
        var zin: std.Io.Reader = .fixed(tar_zst);
        var dz = std.compress.zstd.Decompress.init(&zin, window, .{ .window_len = window_len });
        w.failed = null;
        w.data = dz.reader.allocRemaining(a, .unlimited) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => fail: {
                w.failed = e;
                break :fail &.{};
            },
        };
        w.rin = .fixed(w.data);
        w.it = std.tar.Iterator.init(&w.rin, .{ .file_name_buffer = &w.name_buf, .link_name_buffer = &w.link_buf });
    }

    pub fn close(w: *Walk, a: Alloc) void {
        a.free(w.data);
    }

    /// The next member; its name is valid until the next call.
    pub fn next(w: *Walk) anyerror!?std.tar.Iterator.File {
        if (w.failed) |e| return e;
        return w.it.next();
    }

    /// Reads the body of member `f` into `out`, or passes over it when `out` is null.
    pub fn take(w: *Walk, f: std.tar.Iterator.File, out: ?*std.Io.Writer.Allocating) anyerror!void {
        if (f.size == 0) return;
        if (out) |o| {
            try o.ensureUnusedCapacity(@intCast(f.size));
            try w.it.streamRemaining(f, &o.writer);
        } else {
            var sink = std.Io.Writer.Discarding.init(&.{});
            try w.it.streamRemaining(f, &sink.writer);
        }
    }
};

pub const PathError = error{BadPath} || Oom;

/// The member name as a relative path of plain components joined by `/`: `.` components and empty ones (`a//b`, a trailing `/`) are dropped; an
/// absolute name or a `..` component is `BadPath`. The root itself (`.`, `./`) is the empty path.
pub fn cleanPath(a: Alloc, name: []const u8) PathError![]const u8 {
    if (std.fs.path.isAbsolute(name)) return error.BadPath;
    var out = std.ArrayList(u8).empty;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.BadPath;
        if (out.items.len != 0) try out.append(a, '/');
        try out.appendSlice(a, part);
    }
    return out.items;
}

/// Whether the fixture does not need the member `path` (clean): headers, manuals, static archives and the other things only a build reads.
pub fn dropped(path: []const u8) bool {
    return under(path, "info") or under(path, "include") or under(path, "share/doc") or under(path, "share/man") or under(path, "share/info") or
        under(path, "share/locale") or under(path, "lib/pkgconfig") or under(path, "lib/cmake") or under(path, "lib/pgxs") or
        std.mem.endsWith(u8, path, ".a");
}

fn under(path: []const u8, dir: []const u8) bool {
    return std.mem.startsWith(u8, path, dir) and (path.len == dir.len or path[dir.len] == '/');
}

/// Whether a symbolic link at `path` (clean) to `target` leaves the tree: an absolute target, or a relative one that climbs above the root. Lexical.
pub fn linkEscapes(path: []const u8, target: []const u8) bool {
    if (std.fs.path.isAbsolute(target)) return true;
    var depth: usize = 0;
    var dir = std.mem.splitScalar(u8, std.fs.path.dirname(path) orelse "", '/');
    while (dir.next()) |c| depth += @intFromBool(c.len != 0);
    var parts = std.mem.splitScalar(u8, target, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (!std.mem.eql(u8, part, "..")) {
            depth += 1;
        } else if (depth == 0) {
            return true;
        } else {
            depth -= 1;
        }
    }
    return false;
}

pub const PlaceholderError = error{ Refused, OutOfMemory };

/// The prefix placeholder of `bin/postgres` and `bin/initdb` in the text of an `info/paths.json`: both are listed, both `file_mode` "binary", and
/// they name the same placeholder. When not, `why.*` says what is wrong (the caller names the file).
pub fn placeholder(a: Alloc, json: []const u8, why: *[]const u8) PlaceholderError![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(why, "is not JSON"),
    };
    const list = switch (parsed.value) {
        .object => |o| if (o.get("paths")) |p| p else return refuse(why, "has no paths list"),
        else => return refuse(why, "has no paths list"),
    };
    if (list != .array) return refuse(why, "has no paths list");
    var found: []const u8 = "";
    for ([_][]const u8{ "bin/postgres", "bin/initdb" }) |want| {
        const ph = try placeholderOf(a, list.array.items, want, why);
        if (found.len != 0 and !std.mem.eql(u8, found, ph)) return refuse(why, "gives bin/postgres and bin/initdb different prefix placeholders");
        found = ph;
    }
    return found;
}

fn placeholderOf(a: Alloc, items: []const std.json.Value, want: []const u8, why: *[]const u8) PlaceholderError![]const u8 {
    for (items) |item| {
        if (item != .object) continue;
        const name = item.object.get("_path") orelse continue;
        if (name != .string or !std.mem.eql(u8, name.string, want)) continue;
        const mode = item.object.get("file_mode") orelse std.json.Value{ .null = {} };
        if (mode != .string or !std.mem.eql(u8, mode.string, "binary")) {
            why.* = try std.fmt.allocPrint(a, "lists {s} with a file_mode that is not \"binary\"", .{want});
            return error.Refused;
        }
        const ph = item.object.get("prefix_placeholder") orelse std.json.Value{ .null = {} };
        if (ph != .string or ph.string.len == 0) {
            why.* = try std.fmt.allocPrint(a, "lists {s} without a prefix_placeholder", .{want});
            return error.Refused;
        }
        return ph.string;
    }
    why.* = try std.fmt.allocPrint(a, "does not list {s}", .{want});
    return error.Refused;
}

fn refuse(why: *[]const u8, text: []const u8) error{Refused} {
    why.* = text;
    return error.Refused;
}
