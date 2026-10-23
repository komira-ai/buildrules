//! The private directories a test run is given, and the installed layout it can be run in (docs/contract.md, section 12.9).
//!
//! `make` creates one fresh directory per run, named at random inside a parent that is the action's own scratch path, and in it
//!
//!     tmp/         TMPDIR and TEST_TMPDIR of the run: empty at the start
//!     home/        HOME of the run: empty at the start
//!     root/        the installed layout, when the run asks for one
//!     root/share/  made with the root and empty: the data of the run goes here
//!
//! `installBinary` then puts `root/bin/<exe>` in the root. Nothing here is shared between two runs, and `remove` takes the whole directory away after the run.
//! Both `check` (the test run) and `cov_run` (the coverage run) build their runs from this one file, so the two see the same layout.
//!
//! No function reads the process's environment or working directory: the caller passes what it knows, and every path is absolute.

const std = @import("std");

pub const Alloc = std.mem.Allocator;

/// The directories of one run; every path is absolute, and has no link in it.
pub const Scratch = struct {
    /// The directory that holds the rest; `remove` deletes it.
    dir: []const u8,
    tmp: []const u8,
    home: []const u8,
    root: []const u8,
    share: []const u8,
};

fn join(a: Alloc, parts: []const []const u8) Alloc.Error![]const u8 {
    return std.fs.path.join(a, parts);
}

/// The parent of the private directory: `buck_scratch` (the action's scratch path) when it is not empty, else `tmpdir`, else `/tmp`; a relative
/// one is made absolute against `here`, which is absolute.
pub fn parent(a: Alloc, here: []const u8, buck_scratch: ?[]const u8, tmpdir: ?[]const u8) Alloc.Error![]const u8 {
    const chosen = for ([_]?[]const u8{ buck_scratch, tmpdir }) |candidate| {
        if (candidate) |c| {
            if (c.len > 0) break c;
        }
    } else @as([]const u8, "/tmp");
    if (chosen[0] == '/') return chosen;
    return join(a, &.{ here, chosen });
}

/// A fresh directory named `buildrules_test.<random>` in `where` (absolute, made when it is not there), with `tmp`, `home`, `root` and `root/share` in it, all
/// empty.
pub fn make(a: Alloc, where: []const u8) anyerror!Scratch {
    var random: [8]u8 = undefined;
    std.crypto.random.bytes(&random);
    const hex = std.fmt.bytesToHex(random, .lower);
    return makeNamed(a, where, try std.fmt.allocPrint(a, "buildrules_test.{s}", .{&hex}));
}

/// `make` with the name of the run's directory given. The paths returned are the real ones, with no link in them, so what the run reads back from the system
/// (its working directory, `/proc/self/exe`) is the very string it was given. A directory of that name that is there already belongs to another run: it is
/// an error (`PathAlreadyExists`), never reused, and left as it is.
pub fn makeNamed(a: Alloc, where: []const u8, name: []const u8) anyerror!Scratch {
    try std.fs.cwd().makePath(where);
    const dir = try join(a, &.{ try std.fs.cwd().realpathAlloc(a, where), name });
    const s = Scratch{
        .dir = dir,
        .tmp = try join(a, &.{ dir, "tmp" }),
        .home = try join(a, &.{ dir, "home" }),
        .root = try join(a, &.{ dir, "root" }),
        .share = try join(a, &.{ dir, "root", "share" }),
    };
    for ([_][]const u8{ s.dir, s.tmp, s.home, s.root, s.share }) |path| try std.fs.makeDirAbsolute(path);
    return s;
}

/// Takes the run's directory away; one that is gone already is no error.
pub fn remove(s: Scratch) void {
    std.fs.cwd().deleteTree(s.dir) catch {};
}

/// Installs the test binary `exe` (absolute) under `root`: the directory that holds it is copied to `root/bin`, so that the binary is `root/bin/<name>`, with its
/// permission bits, what the running program reports as its own path (`/proc/self/exe`) is that path, its `$ORIGIN` is `root/bin`, and what sits beside it (the
/// `lib/` of its native libraries, which its runpath names) is found there. Returns the path of the copy. A binary directly in `/` is refused: its directory is
/// the whole file system.
pub fn installBinary(a: Alloc, root: []const u8, exe: []const u8) anyerror![]const u8 {
    const name = std.fs.path.basename(exe);
    const from = exe[0 .. exe.len - name.len];
    if (from.len <= 1) return error.NotInADirectory;
    const bin = try join(a, &.{ root, "bin" });
    try copyTree(a, from, bin);
    const installed = try join(a, &.{ bin, name });
    // The directory is copied whole; the binary has to be one of its entries.
    try std.fs.cwd().access(installed, .{});
    return installed;
}

/// Copies the tree `from` (absolute) into `to` (absolute, made): directories, files with their permission bits, and what a link names (a link is
/// followed, so the copy holds no link into the build's outputs). An entry that is already there is replaced; a kind of file that is none of those (a named
/// pipe) is an error.
pub fn copyTree(a: Alloc, from: []const u8, to: []const u8) anyerror!void {
    try std.fs.cwd().makePath(to);
    var dir = try std.fs.openDirAbsolute(from, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const source = try join(a, &.{ from, entry.name });
        const target = try join(a, &.{ to, entry.name });
        const kind = if (entry.kind == .sym_link) (try dir.statFile(entry.name)).kind else entry.kind;
        switch (kind) {
            .directory => try copyTree(a, source, target),
            .file => try std.fs.copyFileAbsolute(source, target, .{}),
            else => return error.UnsupportedFileKind,
        }
    }
}
