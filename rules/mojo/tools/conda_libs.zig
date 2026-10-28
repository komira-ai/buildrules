//! conda_libs: every shared library in the `lib/` directory of a `.conda` package, written flat into a directory (`conda_unpack --all-libs <package.conda> <out_dir>`).
//!
//! This is what a test run puts on its library path for a package that the unit graph's `system_libs` pins (docs/contract.md, section 12.11): a program that opens
//! `libsqlite3.so.0` or `libsqlite3.dylib` by its bare name finds the pinned file, whatever the worker has.
//!
//! What is written, and what is not:
//!   * the members `lib/<leaf>` (a direct child of `lib/`) whose leaf is a shared object (`.so`, `.so.<...>`) or a dynamic library (`.dylib`, `.dylib.<...>`). Static
//!     archives, pkg-config files, headers, cmake files and everything below `lib/<dir>/` are left out;
//!   * a member that is a symbolic link (a library's SONAME and its unversioned name usually are) is written as a regular file holding the bytes of the file it
//!     resolves to, so the output holds no link and a bare name of any of them opens. A link that leaves `lib/` or that loops is refused;
//!   * the files are named by their leaf, in `<out_dir>` itself, and have the executable bit when the package's file has it.
//!
//! Noted, not refused (docs/contract.md section 12.11; a pin of a package is policy-free: whatever conda-forge calls a package, it unpacks): a package with no shared
//! library (a metapackage, a tool, a package of headers) unpacks to an empty directory, and a link to a file the package does not hold (the unversioned name of a
//! `-devel` package, whose library is in the runtime package) is left out; each says so on the standard error of the action, naming the package, and is no error.
//! Refused, with nothing written at all (integrity, not policy): an archive that is corrupt or truncated or has no `info/paths.json`, a member named twice, a file that
//! is empty or over 512 MiB, and a member (or the file a link resolves to) that carries an install-prefix placeholder in `info/paths.json` (the bytes are copied
//! verbatim, so a library that embeds its install prefix would name a directory of the machine that built it; such a library cannot be listed until the placeholder
//! is rewritten, as modular.cfg's is).

const std = @import("std");
const pu = @import("prebuilt_unpack.zig");

const window_len: u32 = 1 << 27;

pub const Error = anyerror;

pub const Lib = struct {
    /// The leaf under `lib/`.
    name: []const u8,
    bytes: []const u8,
    executable: bool,
};

/// Whether the leaf of a `lib/` member is a shared library: `lib*.so`, `lib*.so.<version...>`, `lib*.dylib` or `lib*.dylib.<...>`.
pub fn isSharedLib(leaf: []const u8) bool {
    if (!std.mem.startsWith(u8, leaf, "lib")) return false;
    return endsOrFollowedByDot(leaf, ".so") or endsOrFollowedByDot(leaf, ".dylib");
}

fn endsOrFollowedByDot(leaf: []const u8, ext: []const u8) bool {
    if (std.mem.endsWith(u8, leaf, ext)) return true;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, leaf, from, ext)) |at| : (from = at + 1) {
        const after = at + ext.len;
        if (after < leaf.len and leaf[after] == '.') return true;
    }
    return false;
}

const Entry = struct { link: ?[]const u8, bytes: []const u8, executable: bool };

/// The leaf of a member that is a direct child of `lib/`, or null.
fn leafOf(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "lib/")) return null;
    const leaf = name["lib/".len..];
    if (leaf.len == 0 or std.mem.indexOfScalar(u8, leaf, '/') != null) return null;
    return leaf;
}

fn noteLess(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn lessThan(_: void, x: Lib, y: Lib) bool {
    return std.mem.lessThan(u8, x.name, y.name);
}

pub const Collected = struct {
    /// The members `conda_unpack --all-libs` writes, sorted by name; empty for a package that has no shared library.
    libs: []Lib,
    /// What was left out, one sentence each, without the package's name (the caller says whose they are).
    notes: []const []const u8,
};

/// The members of `conda` `lib/` that `conda_unpack --all-libs` writes, sorted by name, and the notes of what it leaves out; every refusal is made before anything is
/// returned. On an error `why.*` says what is wrong. Allocates from `a`; the caller drops an arena.
pub fn collect(a: std.mem.Allocator, conda: []const u8, why: *[]const u8) Error!Collected {
    const pkg = pu.payload(conda) catch |e| {
        why.* = try std.fmt.allocPrint(a, "{s}", .{@errorName(e)});
        return e;
    };
    var entries = std.StringHashMap(Entry).init(a);
    const window = try a.alloc(u8, window_len + std.compress.zstd.block_size_max);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var zin: std.Io.Reader = .fixed(pkg);
    var dz = std.compress.zstd.Decompress.init(&zin, window, .{ .window_len = window_len });
    var it = std.tar.Iterator.init(&dz.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    while (try it.next()) |f| {
        const leaf = leafOf(f.name) orelse {
            try skip(&it, f);
            continue;
        };
        const name = try a.dupe(u8, leaf);
        if (entries.contains(name)) {
            why.* = try std.fmt.allocPrint(a, "lib/{s} is in the package twice", .{name});
            return error.DuplicateMember;
        }
        switch (f.kind) {
            .file => {
                if (f.size > pu.max_member) {
                    why.* = try std.fmt.allocPrint(a, "lib/{s} is {d} bytes, over the {d} a member may have", .{ name, f.size, pu.max_member });
                    return error.TooLarge;
                }
                const bytes = try it.reader.readAlloc(a, @intCast(f.size));
                it.unread_file_bytes = 0;
                try entries.put(name, .{ .link = null, .bytes = bytes, .executable = f.mode & 0o111 != 0 });
            },
            .sym_link => try entries.put(name, .{ .link = try a.dupe(u8, f.link_name), .bytes = "", .executable = false }),
            else => try skip(&it, f),
        }
    }

    var libs = std.ArrayList(Lib).empty;
    var notes = std.ArrayList([]const u8).empty;
    var selected = std.ArrayList([]const u8).empty;
    var iter = entries.iterator();
    while (iter.next()) |kv| {
        const name = kv.key_ptr.*;
        if (!isSharedLib(name)) continue;
        var at: []const u8 = name;
        var e = kv.value_ptr.*;
        var hops: usize = 0;
        var dangling: ?[]const u8 = null;
        while (e.link) |target| {
            if (target.len == 0 or std.mem.indexOfScalar(u8, target, '/') != null) {
                why.* = try std.fmt.allocPrint(a, "lib/{s} is a link to {s}, which is not a file beside it", .{ at, target });
                return error.LinkLeavesDirectory;
            }
            hops += 1;
            if (hops > 8) {
                why.* = try std.fmt.allocPrint(a, "too many links resolving lib/{s}", .{name});
                return error.LinkLoop;
            }
            at = target;
            e = entries.get(target) orelse {
                dangling = target;
                break;
            };
        }
        if (dangling) |target| {
            try notes.append(a, try std.fmt.allocPrint(a, "lib/{s} is a link to {s}, which the package does not hold: left out", .{ name, target }));
            continue;
        }
        if (e.bytes.len == 0) {
            why.* = try std.fmt.allocPrint(a, "lib/{s} is empty", .{at});
            return error.EmptyMember;
        }
        try libs.append(a, .{ .name = name, .bytes = e.bytes, .executable = e.executable });
        try selected.append(a, name);
        if (!std.mem.eql(u8, at, name)) try selected.append(a, at);
    }
    std.mem.sort([]const u8, notes.items, {}, noteLess);
    if (libs.items.len == 0) {
        try notes.append(a, "the package has no shared library (lib/*.so*, lib/*.dylib*): its directory is empty");
        return .{ .libs = libs.items, .notes = notes.items };
    }
    try refusePlaceholders(a, conda, selected.items, why);
    std.mem.sort(Lib, libs.items, {}, lessThan);
    return .{ .libs = libs.items, .notes = notes.items };
}

fn skip(it: *std.tar.Iterator, f: std.tar.Iterator.File) !void {
    // The iterator would discard the body itself, but the discard of this release's zstd reader asserts: stream it into nothing.
    if (f.size == 0) return;
    var sink = std.Io.Writer.Discarding.init(&.{});
    try it.streamRemaining(f, &sink.writer);
}

/// A library whose bytes embed the install prefix is refused: `info/paths.json` names the entries that do (`prefix_placeholder`).
fn refusePlaceholders(a: std.mem.Allocator, conda: []const u8, leaves: []const []const u8, why: *[]const u8) Error!void {
    const info = pu.infoPayload(conda) catch |e| {
        why.* = try std.fmt.allocPrint(a, "{s}", .{@errorName(e)});
        return e;
    };
    var bad: []const u8 = "";
    const body = pu.members(a, info, &.{"info/paths.json"}, &bad) catch |e| {
        why.* = try std.fmt.allocPrint(a, "{s}: {s}", .{ bad, @errorName(e) });
        return e;
    };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, body[0], .{}) catch {
        why.* = "info/paths.json is not JSON";
        return error.BadPathsJson;
    };
    const paths = if (parsed == .object) parsed.object.get("paths") else null;
    if (paths == null or paths.? != .array) {
        why.* = "info/paths.json has no `paths` list";
        return error.BadPathsJson;
    }
    for (paths.?.array.items) |p| {
        if (p != .object) continue;
        const path = p.object.get("_path") orelse continue;
        if (path != .string) continue;
        const leaf = leafOf(path.string) orelse continue;
        for (leaves) |l| {
            if (!std.mem.eql(u8, l, leaf)) continue;
            if (p.object.get("prefix_placeholder")) |ph| {
                if (ph == .string and ph.string.len > 0) {
                    why.* = try std.fmt.allocPrint(a, "lib/{s} carries an install-prefix placeholder; the bytes are copied as they are, so it cannot be listed", .{leaf});
                    return error.PrefixPlaceholder;
                }
            }
        }
    }
}

/// The program: `args` are `[--package <name>] <package.conda> <out_dir>`. Reads the package, refuses before writing, then writes each library into `out_dir` (made,
/// and left empty for a package with none). `notes.*` is what was left out, each line naming the package (`<name>` when given, else the file).
pub fn run(a: std.mem.Allocator, cwd: std.fs.Dir, args_in: []const []const u8, why: *[]const u8, notes: *[]const []const u8) Error!void {
    var args = args_in;
    var who: ?[]const u8 = null;
    if (args.len == 4 and std.mem.eql(u8, args[0], "--package")) {
        who = args[1];
        args = args[2..];
    }
    if (args.len != 2) {
        why.* = "usage: conda_unpack --all-libs [--package <name>] <package.conda> <out_dir>";
        return error.Usage;
    }
    const conda = cwd.readFileAlloc(a, args[0], 1 << 31) catch |e| {
        why.* = try std.fmt.allocPrint(a, "cannot read {s}: {s}", .{ args[0], @errorName(e) });
        return e;
    };
    const got = collect(a, conda, why) catch |e| {
        why.* = try std.fmt.allocPrint(a, "{s}: {s}", .{ args[0], if (why.len != 0) why.* else @errorName(e) });
        return e;
    };
    const libs = got.libs;
    const named = try a.alloc([]const u8, got.notes.len);
    for (got.notes, named) |n, *out_note| out_note.* = try std.fmt.allocPrint(a, "{s}: {s}", .{ who orelse args[0], n });
    notes.* = named;
    cwd.makePath(args[1]) catch |e| {
        why.* = try std.fmt.allocPrint(a, "cannot create {s}: {s}", .{ args[1], @errorName(e) });
        return e;
    };
    var out = try cwd.openDir(args[1], .{});
    defer out.close();
    for (libs) |l| {
        const file = out.createFile(l.name, .{ .exclusive = true, .mode = if (l.executable) 0o755 else 0o644 }) catch |e| {
            why.* = try std.fmt.allocPrint(a, "cannot create {s}/{s}: {s}", .{ args[1], l.name, @errorName(e) });
            return e;
        };
        defer file.close();
        file.writeAll(l.bytes) catch |e| {
            why.* = try std.fmt.allocPrint(a, "cannot write {s}/{s}: {s}", .{ args[1], l.name, @errorName(e) });
            return e;
        };
    }
}
