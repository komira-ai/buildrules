//! The path an archive entry is extracted to, and the refusals that keep an entry inside the destination (what is called a tar-slip).
const std = @import("std");

pub const max_path = 4096;

pub const Error = error{
    /// The name is empty.
    EmptyName,
    /// The name starts with `/`.
    AbsolutePath,
    /// A component of the name is `..` (refused wherever it is and whatever `--strip-components` drops).
    ParentComponent,
    /// The name holds a NUL byte (a C program would read a shorter path).
    NulInName,
    /// The name is longer than `max_path`.
    NameTooLong,
    /// The target of a symbolic link is empty, absolute, or climbs out of the destination.
    LinkEscapes,
};

/// The path of `name` below the destination after dropping its first `strip` components, written to `buf` with `/` between components: empty components and `.`
/// are dropped. `null` when nothing is left (the entry is the stripped directory itself, or has fewer components than are stripped): the entry is skipped.
/// A name with a `..` component, a leading `/` or a NUL byte is an error, whatever `strip` drops of it.
pub fn clean(name: []const u8, strip: usize, buf: []u8) Error!?[]const u8 {
    if (name.len == 0) return error.EmptyName;
    if (name[0] == '/') return error.AbsolutePath;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.NulInName;
    var it = std.mem.tokenizeScalar(u8, name, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, "..")) return error.ParentComponent;
    }
    it.reset();
    var seen: usize = 0;
    var n: usize = 0;
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        seen += 1;
        if (seen <= strip) continue;
        const need = c.len + @intFromBool(n > 0);
        if (n + need > buf.len or n + need > max_path) return error.NameTooLong;
        if (n > 0) {
            buf[n] = '/';
            n += 1;
        }
        @memcpy(buf[n .. n + c.len], c);
        n += c.len;
    }
    if (n == 0) return null;
    return buf[0..n];
}

/// A symbolic link at `rel` (a cleaned path) may point at `target` only if the target is relative, `..` is used only as a leading run of components, and that run
/// does not climb above the destination from the directory the link is in. Then however the links of an archive are chained, none leads out of the destination, and
/// the targets are kept as they are.
pub fn checkLinkTarget(rel: []const u8, target: []const u8) Error!void {
    if (target.len == 0 or target[0] == '/') return error.LinkEscapes;
    if (std.mem.indexOfScalar(u8, target, 0) != null) return error.NulInName;
    var depth: usize = 0;
    var d = std.mem.tokenizeScalar(u8, rel, '/');
    while (d.next()) |_| depth += 1;
    depth -|= 1; // the link's own name is not a directory of its path
    var ups: usize = 0;
    var named = false;
    var it = std.mem.tokenizeScalar(u8, target, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, "..")) {
            if (named) return error.LinkEscapes;
            ups += 1;
        } else if (!std.mem.eql(u8, c, ".")) {
            named = true;
        }
    }
    if (ups > depth) return error.LinkEscapes;
}
