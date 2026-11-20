//! pg_prefix: the pinned Postgres packages as one tree.
//!
//!   pg_prefix --out DIR --postgres POSTGRESQL.conda [OTHER.conda]...
//!
//! Every payload of every package is written into DIR (which does not exist yet, or is empty): regular files with mode 0755 when the tar header has any
//! execute bit and 0644 otherwise, directories, and symbolic links as links. A member path that is absolute or has a `..` component, a hard link, a symbolic
//! link that is absolute or climbs out of DIR, a member under a link the tree holds (links that chain could name a directory outside DIR), a member over 512 MiB, and a path two packages hold with different contents are refused, naming the member.
//! What a server never reads is not written: `info/` (package metadata, which conda never installs), `include/`, `share/doc/`, `share/man/`, `share/info/`, `share/locale/`, `lib/pkgconfig/`, `lib/cmake/`,
//! `lib/pgxs/` and static archives (`*.a`).
//!
//! DIR also gets `buildrules-placeholder.txt`: the prefix placeholder conda-forge compiled into `bin/postgres` and `bin/initdb`, read from the
//! `info/paths.json` of the `--postgres` package (both must be listed, `file_mode` "binary", with the same placeholder). pg_run replaces it in its own
//! copy of the binaries.
//!
//! A refusal is one line on stderr, `pg_prefix: ...`, exit 1, and DIR is removed (a tree that looks complete is never left behind); a wrong command
//! line is exit 2. `main` only forwards to `run`.

const std = @import("std");
const conda = @import("conda.zig");

pub const Alloc = std.mem.Allocator;

/// What `run` is given: where a relative path is resolved, where messages go, and the two bounds the tests make small.
pub const Io = struct {
    cwd: std.fs.Dir,
    err: *std.Io.Writer,
    window_len: u32 = conda.window_max,
    max_member: u64 = conda.max_member,
};

const usage = "pg_prefix: usage: pg_prefix --out DIR --postgres POSTGRESQL.conda [OTHER.conda]...\n";

const Options = struct { out: []const u8, packages: []const []const u8 };

/// The command line; null when it is wrong. The `--postgres` package is the first of `packages`.
fn parse(a: Alloc, args: []const []const u8) Alloc.Error!?Options {
    var out: ?[]const u8 = null;
    var postgres: ?[]const u8 = null;
    var others = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const slot = if (std.mem.eql(u8, args[i], "--out")) &out else if (std.mem.eql(u8, args[i], "--postgres")) &postgres else null;
        if (slot) |s| {
            if (s.* != null or i + 1 >= args.len) return null;
            i += 1;
            s.* = args[i];
        } else {
            if (std.mem.startsWith(u8, args[i], "--")) return null;
            try others.append(a, args[i]);
        }
    }
    if (postgres == null or out == null) return null;
    try others.insert(a, 0, postgres.?);
    return .{ .out = out.?, .packages = others.items };
}

const Fail = error{ Refused, OutOfMemory };

/// One message line on stderr. A failed write of it is not reported anywhere. (The formatting is generic and has no error path of its own, so the one place a failed write is
/// dropped, `emit`, is one block however many messages there are.)
fn say(io: Io, comptime fmt: []const u8, args: anytype) void {
    const Line = struct {
        args: @TypeOf(args),
        fn write(p: *const anyopaque, w: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *const @This() = @ptrCast(@alignCast(p));
            return w.print("pg_prefix: " ++ fmt ++ "\n", self.args);
        }
    };
    const line = Line{ .args = args };
    emit(io, &line, Line.write);
}

fn emit(io: Io, line: *const anyopaque, write: *const fn (*const anyopaque, *std.Io.Writer) std.Io.Writer.Error!void) void {
    write(line, io.err) catch {};
}

fn refuse(io: Io, comptime fmt: []const u8, args: anytype) error{Refused} {
    say(io, fmt, args);
    return error.Refused;
}

const Package = struct { path: []const u8, bytes: []const u8 };

/// What the tree holds at a path: its kind and a digest of the contents (of the link target for a link), to tell the same thing twice from two things.
const Held = struct { package: []const u8, kind: std.tar.FileKind, digest: [32]u8 };

/// `args` is the command line after the program's name. Returns the exit status.
pub fn run(a: Alloc, io: Io, args: []const []const u8) u8 {
    const o = (parse(a, args) catch return oom(io)) orelse {
        io.err.writeAll(usage) catch {};
        return 2;
    };
    var dir = prepare(io, o.out) catch |e| return failed(io, e);
    defer dir.close();
    unpackAll(a, io, o, dir) catch |e| {
        io.cwd.deleteTree(o.out) catch {};
        return failed(io, e);
    };
    return 0;
}

fn failed(io: Io, e: Fail) u8 {
    if (e == error.OutOfMemory) say(io, "out of memory", .{});
    return 1;
}

fn oom(io: Io) u8 {
    return failed(io, error.OutOfMemory);
}

/// DIR must not be there, or be empty; it is made, and opened.
fn prepare(io: Io, out: []const u8) Fail!std.fs.Dir {
    io.cwd.deleteDir(out) catch |e| switch (e) {
        error.FileNotFound => {},
        error.DirNotEmpty => return refuse(io, "{s} is not empty", .{out}),
        else => return refuse(io, "cannot use {s}: {s}", .{ out, @errorName(e) }),
    };
    return io.cwd.makeOpenPath(out, .{}) catch |e| return refuse(io, "cannot make {s}: {s}", .{ out, @errorName(e) });
}

fn unpackAll(a: Alloc, io: Io, o: Options, dir: std.fs.Dir) Fail!void {
    var pkgs = std.ArrayList(Package).empty;
    for (o.packages) |path| {
        const bytes = io.cwd.readFileAlloc(a, path, 1 << 30) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return refuse(io, "cannot read {s}: {s}", .{ path, @errorName(e) }),
        };
        try pkgs.append(a, .{ .path = path, .bytes = bytes });
    }
    const ph = try placeholderOf(a, io, pkgs.items[0]);
    var held = std.StringHashMap(Held).init(a);
    for (pkgs.items) |p| try unpack(a, io, dir, &held, p);
    dir.writeFile(.{ .sub_path = "buildrules-placeholder.txt", .data = ph }) catch |e| return refuse(io, "cannot write {s}/buildrules-placeholder.txt: {s}", .{ o.out, @errorName(e) });
}

/// The placeholder of the `--postgres` package, from its `info/paths.json`.
fn placeholderOf(a: Alloc, io: Io, p: Package) Fail![]const u8 {
    const tar = conda.infoPayload(p.bytes) catch |e| return refuse(io, "{s}: {s}", .{ p.path, @errorName(e) });
    var w: conda.Walk = undefined;
    try w.open(a, tar, io.window_len);
    defer w.close(a);
    var json = std.Io.Writer.Allocating.init(a);
    var seen = false;
    while (try next(io, p.path, &w)) |f| {
        const name = try cleaned(a, io, p, f.name);
        const wanted = f.kind == .file and std.mem.eql(u8, name, "info/paths.json");
        if (wanted and f.size > io.max_member) return refuse(io, "{s}: info/paths.json is {d} bytes, more than {d}", .{ p.path, f.size, io.max_member });
        try consume(io, p, name, &w, f, if (wanted) &json else null);
        if (wanted) seen = true;
    }
    if (!seen) return refuse(io, "{s}: has no info/paths.json", .{p.path});
    var why: []const u8 = "";
    return conda.placeholder(a, json.written(), &why) catch |e| switch (e) {
        error.Refused => return refuse(io, "{s}: info/paths.json {s}", .{ p.path, why }),
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// The next member of the tar of package `p`; a tar this tool cannot read is refused.
fn next(io: Io, path: []const u8, w: *conda.Walk) Fail!?std.tar.Iterator.File {
    return w.next() catch |e| switch (e) {
        error.TarUnsupportedHeader => return refuse(io, "{s}: a member that is not a file, directory or symbolic link (a hard link?) is not taken", .{path}),
        else => return refuse(io, "{s}: cannot read the archive: {s}", .{ path, @errorName(e) }),
    };
}

/// The clean path of member `name` of package `p`.
fn cleaned(a: Alloc, io: Io, p: Package, name: []const u8) Fail![]const u8 {
    return conda.cleanPath(a, name) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BadPath => return refuse(io, "{s}: member {s} is not a relative path without .. components", .{ p.path, name }),
    };
}

/// Reads the body of member `f` into `out`, or passes over it.
fn consume(io: Io, p: Package, name: []const u8, w: *conda.Walk, f: std.tar.Iterator.File, out: ?*std.Io.Writer.Allocating) Fail!void {
    w.take(f, out) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return refuse(io, "{s}: cannot read member {s}: {s}", .{ p.path, name, @errorName(e) }),
    };
}

fn unpack(a: Alloc, io: Io, dir: std.fs.Dir, held: *std.StringHashMap(Held), p: Package) Fail!void {
    const tar = conda.payload(p.bytes) catch |e| return refuse(io, "{s}: {s}", .{ p.path, @errorName(e) });
    var w: conda.Walk = undefined;
    try w.open(a, tar, io.window_len);
    defer w.close(a);
    while (try next(io, p.path, &w)) |f| {
        const path = try cleaned(a, io, p, f.name);
        const keep = path.len != 0 and !conda.dropped(path);
        if (keep and f.size > io.max_member) return refuse(io, "{s}: member {s} is {d} bytes, more than {d}", .{ p.path, path, f.size, io.max_member });
        var data = std.Io.Writer.Allocating.init(a);
        defer data.deinit();
        try consume(io, p, path, &w, f, if (keep) &data else null);
        if (!keep) continue;
        if (throughLink(held, path)) |link| return refuse(io, "{s}: member {s} is under the link {s}; nothing is written through a link", .{ p.path, path, link });
        var digest = [_]u8{0} ** 32;
        if (f.kind == .file) std.crypto.hash.sha2.Sha256.hash(data.written(), &digest, .{});
        if (f.kind == .sym_link) {
            if (conda.linkEscapes(path, f.link_name)) return refuse(io, "{s}: member {s} is a link to {s}, which is not inside the tree", .{ p.path, path, f.link_name });
            std.crypto.hash.sha2.Sha256.hash(f.link_name, &digest, .{});
        }
        const slot = try held.getOrPut(path);
        if (slot.found_existing) {
            const was = slot.value_ptr.*;
            if (was.kind == f.kind and std.mem.eql(u8, &was.digest, &digest)) continue;
            return refuse(io, "{s} is in both {s} and {s} with different contents", .{ path, was.package, p.path });
        }
        slot.value_ptr.* = .{ .package = p.path, .kind = f.kind, .digest = digest };
        try place(io, dir, p, path, f, data.written());
    }
}

/// The first parent directory of `path` (clean) that is a symbolic link the tree holds, or null. A link is checked on its own (`conda.linkEscapes`, lexically),
/// so links that chain (`a/b -> ..`, then `c -> a/b/..`) can name a directory outside the tree; refusing to write through any link keeps every member inside it.
fn throughLink(held: *const std.StringHashMap(Held), path: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, from, '/')) |i| : (from = i + 1) {
        const h = held.get(path[0..i]) orelse continue;
        if (h.kind == .sym_link) return path[0..i];
    }
    return null;
}

/// Writes the member at `path` of the tree.
fn place(io: Io, dir: std.fs.Dir, p: Package, path: []const u8, f: std.tar.Iterator.File, bytes: []const u8) Fail!void {
    const parent = if (f.kind == .directory) path else std.fs.path.dirname(path) orelse "";
    if (parent.len != 0) dir.makePath(parent) catch |e| return wrote(io, p, path, e);
    switch (f.kind) {
        .directory => {},
        .sym_link => dir.symLink(f.link_name, path, .{}) catch |e| return wrote(io, p, path, e),
        .file => {
            const mode: std.fs.File.Mode = if (f.mode & 0o111 != 0) 0o755 else 0o644;
            dir.writeFile(.{ .sub_path = path, .data = bytes, .flags = .{ .mode = mode } }) catch |e| return wrote(io, p, path, e);
        },
    }
}

fn wrote(io: Io, p: Package, path: []const u8, e: anyerror) error{Refused} {
    return refuse(io, "{s}: cannot write {s}: {s}", .{ p.path, path, @errorName(e) });
}

/// The program: the process's own arguments and the working directory, the real bounds. It only forwards to `run`.
pub fn main() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = std.process.argsAlloc(a) catch return 1;
    var err_buf: [0]u8 = undefined;
    var err = std.fs.File.stderr().writer(&err_buf);
    return run(a, .{ .cwd = std.fs.cwd(), .err = &err.interface }, args[1..]);
}
