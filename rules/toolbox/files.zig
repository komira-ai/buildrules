//! The applets that make and remove files: `rm` and `mkdir`.

const std = @import("std");
const io_mod = @import("io.zig");
const Io = io_mod.Io;
const Alloc = io_mod.Alloc;
const describe = io_mod.describe;

/// Whether something is at `path`, a dangling symbolic link included (a `stat` follows the link and does not see it).
fn exists(cwd: std.fs.Dir, path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (cwd.readLink(path, &buf)) |_| {
        return true;
    } else |err| switch (err) {
        error.FileNotFound => return false,
        else => return true,
    }
}

/// `.`, `..`, and the root: what `rm` refuses to remove, as GNU rm does.
fn dangerous(path: []const u8) bool {
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    const trimmed = path[0..end];
    if (std.mem.eql(u8, trimmed, "/")) return true;
    const base = std.fs.path.basename(trimmed);
    return std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..");
}

/// `rm [-r] [-R] [-f] [--] PATH...`: removes files; with -r, directories and what is under them. A path that is not there is an error
/// unless -f. A directory without -r is an error. `.`, `..` and `/` are refused. The remaining paths are still tried after an
/// error, and the exit status is 1 if there was one.
pub fn rm(_: Alloc, io: Io, args: []const []const u8) io_mod.Oom!u8 {
    var recursive = false;
    var force = false;
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        for (args[i][1..], 1..) |c, k| {
            switch (c) {
                'r', 'R' => recursive = true,
                'f' => force = true,
                else => {
                    io.say("rm", &.{ "invalid option -- '", args[i][k .. k + 1], "'" });
                    return 1;
                },
            }
        }
    }
    const paths = args[i..];
    if (paths.len == 0) {
        if (force) return 0;
        io.say("rm", &.{"missing operand"});
        return 1;
    }
    var status: u8 = 0;
    for (paths) |p| {
        if (!removeOne(io, p, recursive, force)) status = 1;
    }
    return status;
}

/// Removes one operand; false when it reported a failure.
fn removeOne(io: Io, path: []const u8, recursive: bool, force: bool) bool {
    if (path.len == 0 or dangerous(path)) {
        io.say("rm", &.{ "refusing to remove '", path, "'" });
        return false;
    }
    if (recursive) {
        if (!exists(io.cwd, path)) return force or missing(io, path);
        io.cwd.deleteTree(path) catch |err| return cannot(io, path, describe(err));
        return true;
    }
    io.cwd.deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => return force or missing(io, path),
        else => return cannot(io, path, describe(err)),
    };
    return true;
}

/// Reports that `path` is not there; always false (a failure).
fn missing(io: Io, path: []const u8) bool {
    return cannot(io, path, "No such file or directory");
}

fn cannot(io: Io, path: []const u8, why: []const u8) bool {
    io.say("rm", &.{ "cannot remove '", path, "': ", why });
    return false;
}

/// `mkdir [-p] [--] DIR...`: makes directories. With -p the parents too, and a directory that is already there is not an error. Without
/// it the parent must exist and so must not the directory. The remaining operands are still tried after an error.
pub fn mkdir(_: Alloc, io: Io, args: []const []const u8) io_mod.Oom!u8 {
    var parents = false;
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        if (!std.mem.eql(u8, args[i], "-p")) {
            io.say("mkdir", &.{ "invalid option '", args[i], "'" });
            return 1;
        }
        parents = true;
    }
    const dirs = args[i..];
    if (dirs.len == 0) {
        io.say("mkdir", &.{"missing operand"});
        return 1;
    }
    var status: u8 = 0;
    for (dirs) |d| {
        if (!makeOne(io, d, parents)) status = 1;
    }
    return status;
}

fn makeOne(io: Io, dir: []const u8, parents: bool) bool {
    if (dir.len == 0) return failed(io, dir, "No such file or directory");
    (if (parents) io.cwd.makePath(dir) else io.cwd.makeDir(dir)) catch |err| return failed(io, dir, describe(err));
    return true;
}

fn failed(io: Io, dir: []const u8, why: []const u8) bool {
    io.say("mkdir", &.{ "cannot create directory '", dir, "': ", why });
    return false;
}

/// `ln -s [-f] [--] TARGET LINK`: makes LINK a symbolic link to TARGET, which need not be there. A LINK that exists is an error unless `-f`, which
/// removes it first (a file or a link; not a directory). The parent of LINK must exist. A link without `-s` (a hard link) is not made.
pub fn ln(_: Alloc, io: Io, args: []const []const u8) io_mod.Oom!u8 {
    var symbolic = false;
    var force = false;
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            i += 1;
            break;
        }
        for (args[i][1..], 1..) |c, k| {
            switch (c) {
                's' => symbolic = true,
                'f' => force = true,
                else => {
                    io.say("ln", &.{ "invalid option -- '", args[i][k .. k + 1], "'" });
                    return 1;
                },
            }
        }
    }
    if (!symbolic) {
        io.say("ln", &.{"only symbolic links are made: give -s"});
        return 1;
    }
    if (args.len - i != 2) {
        io.say("ln", &.{"usage: ln -s [-f] TARGET LINK"});
        return 1;
    }
    const target = args[i];
    const link = args[i + 1];
    io.cwd.symLink(target, link, .{}) catch |err| {
        if (err != error.PathAlreadyExists or !force) return linkFailed(io, link, err);
        io.cwd.deleteFile(link) catch |gone| return linkFailed(io, link, gone);
        io.cwd.symLink(target, link, .{}) catch |again| return linkFailed(io, link, again);
    };
    return 0;
}

fn linkFailed(io: Io, link: []const u8, err: anyerror) u8 {
    io.say("ln", &.{ "failed to create symbolic link '", link, "': ", describe(err) });
    return 1;
}
