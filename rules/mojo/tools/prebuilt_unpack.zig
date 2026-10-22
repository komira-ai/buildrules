//! prebuilt_unpack: the `.mojoc` of a registry package, and its static native libraries, out of its `.conda`.
//!
//! usage: prebuilt_unpack <package.conda> <name> <out.mojoc> [--natives <out-dir> [--native <soname>=<sha256>]...]
//!
//! A registry package is a `.conda` holding `lib/mojo/<name>.mojoc` (and `lib/mojo/<name>.mopm.json`), written by
//! `mopm pack` (spec/package-metadata.schema.json). The zip walk and the zstd/tar reading are those of
//! conda_unpack.zig (the compiler closure's unpacker), which cannot be used here: it insists on the compiler's
//! members and on `info/paths.json`, which a mopm package does not carry. Only the named members are written. A `.conda`
//! with more than one `pkg-*.tar.zst` is refused.
//!
//! What is pinned. The `.mojoc` is NOT hashed against anything here: the lock pins the `.conda` as a whole, its sha256 and
//! size were checked when it was downloaded (pinned_file), and that is the only guard of the `.mojoc`; here only its shape
//! is checked (a regular file that is not empty). The native libraries are pinned one by one: each `--native` is one the
//! package's lock entry records (`soname`, `sha256`, from mopm's unit graph), and the member's bytes are hashed against that
//! value before anything is written.
//!
//! A static native library is the member `lib/<soname>` of the same file (`lib/lib<stem>.a`; mopm packs one `.conda` per
//! subdir). A soname that is not `lib<stem>.a`, a member that is missing, duplicated, empty, not a regular file (a symlink, a
//! hard link, a directory) or whose declared size is over 512 MiB (the bound is on each member, not on the file, and on the size
//! the tar header declares), and a hash that differs are all refused, and when any one is, no output file is written at all.
//! The natives are written flat, by soname, into `<out-dir>`, which is the layout of `mopm unit build --natives`.

const std = @import("std");

const window_len: u32 = 1 << 27;

/// The largest member taken: 512 MiB, per member and on the size its tar header declares (the registry bounds a whole unpacked package at 512 MB).
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

pub const Error = anyerror;

/// The body of the `pkg-*.tar.zst` member of a `.conda` (a zip of stored members).
pub fn payload(data: []const u8) Error![]const u8 {
    var pkg: ?[]const u8 = null;
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
        if (std.mem.startsWith(u8, name, "pkg-") and std.mem.endsWith(u8, name, ".tar.zst")) {
            // A `.conda` has one; with two, which one an unpacker takes is its own business, so there is no right answer.
            if (pkg != null) return error.DuplicatePayload;
            pkg = body;
        }
    }
    return pkg orelse error.NoPayload;
}

/// The bytes of each member of `wants` (full member names) in the zstd-compressed tar `tar_zst`, in the order of `wants`, in one pass over
/// the archive. Refused, with `bad.*` naming the member: `NoMember` (absent), `DuplicateMember` (named twice in the archive: which one a
/// tar extractor keeps is its own business, so there is no right answer), `NotAFile` (a symlink or a directory; a hard link is the tar
/// reader's `TarUnsupportedHeader`), `EmptyMember`, `TooLarge`. On an error nothing is left allocated.
pub fn members(a: std.mem.Allocator, tar_zst: []const u8, wants: []const []const u8, bad: *[]const u8) Error![][]u8 {
    const found = try a.alloc(?[]u8, wants.len);
    defer a.free(found);
    @memset(found, null);
    errdefer for (found) |f| if (f) |bytes| a.free(bytes);
    const window = try a.alloc(u8, window_len + std.compress.zstd.block_size_max);
    defer a.free(window);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var zin: std.Io.Reader = .fixed(tar_zst);
    var dz = std.compress.zstd.Decompress.init(&zin, window, .{ .window_len = window_len });
    var it = std.tar.Iterator.init(&dz.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    while (true) {
        bad.* = "(the tar)";
        const f = (try it.next()) orelse break;
        const at = indexOf(wants, f.name) orelse {
            // The iterator would discard the body itself, but the discard of this release's zstd reader asserts: stream it into nothing.
            if (f.size != 0) {
                var sink = std.Io.Writer.Discarding.init(&.{});
                try it.streamRemaining(f, &sink.writer);
            }
            continue;
        };
        bad.* = wants[at];
        if (found[at] != null) return error.DuplicateMember;
        if (f.kind != .file) return error.NotAFile;
        if (f.size == 0) return error.EmptyMember;
        if (f.size > max_member) return error.TooLarge;
        found[at] = try it.reader.readAlloc(a, @intCast(f.size));
        it.unread_file_bytes = 0;
    }
    const out = try a.alloc([]u8, wants.len);
    for (found, 0..) |f, i| {
        out[i] = f orelse {
            bad.* = wants[i];
            a.free(out);
            return error.NoMember;
        };
    }
    return out;
}

fn indexOf(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

/// One static native library the lock pins: `lib/<soname>` in the package, `sha256` of its bytes.
pub const Native = struct { soname: []const u8, sha256: [32]u8 };

/// `lib<stem>.a`, one path component of the plain characters a library name has. A name that could leave the output directory
/// (`/`, `..`), start a dotfile, or name something that is not a static archive is refused before it is used as a path.
pub fn checkSoname(soname: []const u8) error{BadSoname}!void {
    if (!std.mem.startsWith(u8, soname, "lib") or !std.mem.endsWith(u8, soname, ".a") or soname.len <= "lib.a".len) return error.BadSoname;
    for (soname) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '+';
        if (!ok) return error.BadSoname;
    }
    if (std.mem.indexOf(u8, soname, "..") != null) return error.BadSoname;
}

/// `<soname>=<64 lowercase hex digits>`.
pub fn parseNative(arg: []const u8) error{ BadNative, BadSoname }!Native {
    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return error.BadNative;
    try checkSoname(arg[0..eq]);
    const digits = arg[eq + 1 ..];
    if (digits.len != 64) return error.BadNative;
    var sha: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&sha, digits) catch return error.BadNative;
    for (digits) |c| if (std.ascii.isUpper(c)) return error.BadNative;
    return .{ .soname = arg[0..eq], .sha256 = sha };
}

pub const Options = struct {
    conda: []const u8,
    name: []const u8,
    out: []const u8,
    natives_dir: ?[]const u8 = null,
    natives: []const Native = &.{},
};

const usage = "usage: prebuilt_unpack <package.conda> <name> <out.mojoc> [--natives <out-dir> [--native <soname>=<sha256>]...]";

/// The command line, or `BadUsage` / `BadNative` / `BadSoname` / `DuplicateNative` with the reason in `why.*`.
pub fn parseArgs(a: std.mem.Allocator, args: []const []const u8, why: *[]const u8) Error!Options {
    if (args.len < 3) return refuse(why, error.BadUsage, usage);
    var o = Options{ .conda = args[0], .name = args[1], .out = args[2] };
    var natives = std.ArrayList(Native).empty;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        const is_dir = std.mem.eql(u8, flag, "--natives");
        const is_native = std.mem.eql(u8, flag, "--native");
        if ((!is_dir and !is_native) or i + 1 >= args.len) return refuse(why, error.BadUsage, usage);
        i += 1;
        if (is_dir) {
            if (o.natives_dir != null) return refuse(why, error.BadUsage, usage);
            o.natives_dir = args[i];
            continue;
        }
        const n = parseNative(args[i]) catch |e| {
            why.* = try std.fmt.allocPrint(a, "--native {s}: expected <soname>=<64 lowercase hex digits> with a soname lib<stem>.a ({s})", .{ args[i], @errorName(e) });
            return e;
        };
        for (natives.items) |m| {
            if (std.mem.eql(u8, m.soname, n.soname)) {
                why.* = try std.fmt.allocPrint(a, "--native names {s} twice", .{n.soname});
                return error.DuplicateNative;
            }
        }
        try natives.append(a, n);
    }
    if (natives.items.len != 0 and o.natives_dir == null) return refuse(why, error.BadUsage, usage);
    o.natives = natives.items;
    return o;
}

fn refuse(why: *[]const u8, e: anyerror, msg: []const u8) anyerror {
    why.* = msg;
    return e;
}

fn hex(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

/// Unpack: every refusal happens before the first write.
pub fn run(a: std.mem.Allocator, cwd: std.fs.Dir, args: []const []const u8, why: *[]const u8) Error!void {
    const o = try parseArgs(a, args, why);
    const data = cwd.readFileAlloc(a, o.conda, 1 << 30) catch |e| {
        why.* = try std.fmt.allocPrint(a, "cannot read {s}: {s}", .{ o.conda, @errorName(e) });
        return e;
    };
    const pkg = payload(data) catch |e| {
        why.* = try std.fmt.allocPrint(a, "{s}: {s}", .{ o.conda, @errorName(e) });
        return e;
    };
    const names = try a.alloc([]const u8, 1 + o.natives.len);
    names[0] = try std.fmt.allocPrint(a, "lib/mojo/{s}.mojoc", .{o.name});
    for (o.natives, 1..) |n, i| names[i] = try std.fmt.allocPrint(a, "lib/{s}", .{n.soname});
    var bad: []const u8 = "";
    const bodies = members(a, pkg, names, &bad) catch |e| {
        why.* = try std.fmt.allocPrint(a, "{s}: {s}: {s}", .{ o.conda, bad, @errorName(e) });
        return e;
    };
    for (o.natives, 1..) |n, i| {
        const got = hex(bodies[i]);
        const want = std.fmt.bytesToHex(n.sha256, .lower);
        if (!std.mem.eql(u8, &got, &want)) {
            why.* = try std.fmt.allocPrint(a, "{s}: {s} hashes to {s}, the lock pins {s}", .{ o.conda, names[i], got, want });
            return error.Sha256Mismatch;
        }
    }
    cwd.writeFile(.{ .sub_path = o.out, .data = bodies[0] }) catch |e| {
        why.* = try std.fmt.allocPrint(a, "cannot write {s}: {s}", .{ o.out, @errorName(e) });
        return e;
    };
    if (o.natives_dir) |dir| {
        cwd.makePath(dir) catch |e| {
            why.* = try std.fmt.allocPrint(a, "cannot create {s}: {s}", .{ dir, @errorName(e) });
            return e;
        };
        for (o.natives, 1..) |n, i| {
            const path = try std.fs.path.join(a, &.{ dir, n.soname });
            cwd.writeFile(.{ .sub_path = path, .data = bodies[i] }) catch |e| {
                why.* = try std.fmt.allocPrint(a, "cannot write {s}: {s}", .{ path, @errorName(e) });
                return e;
            };
        }
    }
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    var why: []const u8 = "";
    run(a, std.fs.cwd(), args[1..], &why) catch |e| {
        std.debug.print("prebuilt_unpack: {s}\n", .{if (why.len != 0) why else @errorName(e)});
        std.process.exit(2);
    };
}
