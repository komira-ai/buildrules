//! Writing the entries of an archive below the destination directory, and the rules that keep them there. Tar and zip both extract through it, so the rules are
//! one set:
//!  - an entry's path is cleaned first (paths.zig): no absolute name, no `..`;
//!  - the directories above an entry are real directories this run made or found: an entry is never written through a symbolic link, whatever the archive's earlier
//!    entries made;
//!  - a symbolic link is kept as the archive has it, if its target stays inside the destination (paths.zig);
//!  - a file is created new (an earlier entry of the same name is replaced, the way tar does), and gets the archive's permission bits `0o777` (the umask does
//!    not apply: an executable stays executable); set-uid, set-gid and sticky bits are dropped;
//!  - directories are made with the default mode, and times, owners and groups are not restored.
//! With no directory (a dry run, `--check`) every rule is still applied and nothing is written.
const std = @import("std");
const paths = @import("paths.zig");

pub const Stats = struct { files: u64 = 0, dirs: u64 = 0, links: u64 = 0, bytes: u64 = 0 };

/// An open output file (or nothing, in a dry run).
pub const Out = struct {
    file: ?std.fs.File,

    pub fn write(self: *Out, bytes: []const u8) !void {
        if (self.file) |f| try f.writeAll(bytes);
    }

    pub fn close(self: *Out) void {
        if (self.file) |f| f.close();
        self.file = null;
    }
};

pub const Extractor = struct {
    dir: ?std.fs.Dir,
    strip: usize,
    stats: Stats = .{},
    /// Entries seen, extracted or skipped.
    entries: u64 = 0,
    /// The name of the entry being handled, for the message of a refusal.
    last: [200]u8 = undefined,
    last_len: usize = 0,
    arena: std.heap.ArenaAllocator,
    made: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(a: std.mem.Allocator, dir: ?std.fs.Dir, strip: usize) Extractor {
        return .{ .dir = dir, .strip = strip, .arena = std.heap.ArenaAllocator.init(a) };
    }

    pub fn deinit(self: *Extractor) void {
        self.arena.deinit();
    }

    /// Counts the entry and remembers its name.
    pub fn note(self: *Extractor, name: []const u8) void {
        self.entries += 1;
        self.last_len = @min(name.len, self.last.len);
        @memcpy(self.last[0..self.last_len], name[0..self.last_len]);
    }

    pub fn lastName(self: *const Extractor) []const u8 {
        return self.last[0..self.last_len];
    }

    /// `rel` is a real directory below the destination: made, or already one (not a link).
    fn ensureDir(self: *Extractor, rel: []const u8) !void {
        const d = self.dir orelse return;
        if (self.made.contains(rel)) return;
        d.makeDir(rel) catch |e| switch (e) {
            error.PathAlreadyExists => {
                // opened without following a link: only a real directory opens
                var sub = d.openDir(rel, .{ .no_follow = true }) catch |oe| {
                    var lb: [std.fs.max_path_bytes]u8 = undefined;
                    return if (oe == error.NotDir or oe == error.SymLinkLoop) (if (d.readLink(rel, &lb)) |_| error.ThroughSymlink else |_| error.NotADirectory) else oe;
                };
                sub.close();
            },
            else => return e,
        };
        const owned = try self.arena.allocator().dupe(u8, rel);
        try self.made.put(self.arena.allocator(), owned, {});
    }

    fn parents(self: *Extractor, rel: []const u8) !void {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |at| {
            try self.ensureDir(rel[0..at]);
            i = at + 1;
        }
    }

    /// Whatever is at `rel` (a file or a link, not a directory) is removed so the entry is created new.
    fn clear(self: *Extractor, rel: []const u8) !void {
        const d = self.dir orelse return;
        d.deleteFile(rel) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }

    pub fn mkdir(self: *Extractor, rel: []const u8) !void {
        try self.parents(rel);
        try self.ensureDir(rel);
        self.stats.dirs += 1;
    }

    /// A new file at `rel` with the permission bits of `mode`; the caller writes its content and closes it.
    pub fn createFile(self: *Extractor, rel: []const u8, mode: u32) !Out {
        const d = self.dir orelse {
            self.stats.files += 1;
            return .{ .file = null };
        };
        try self.parents(rel);
        try self.clear(rel);
        const f = try d.createFile(rel, .{ .exclusive = true, .mode = 0o600 });
        errdefer f.close();
        try f.chmod(@intCast(mode & 0o777));
        self.stats.files += 1;
        return .{ .file = f };
    }

    pub fn symlink(self: *Extractor, rel: []const u8, target: []const u8) !void {
        try paths.checkLinkTarget(rel, target);
        if (self.dir) |d| {
            try self.parents(rel);
            try self.clear(rel);
            try d.symLink(target, rel, .{});
        }
        self.stats.links += 1;
    }

    /// A hard link in an archive names an entry extracted before it: the new file is a copy of that one's bytes and mode.
    pub fn hardlink(self: *Extractor, rel: []const u8, target: []const u8) !void {
        const d = self.dir orelse {
            self.stats.files += 1;
            return;
        };
        try self.parents(rel);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (d.readLink(target, &buf)) |_| {
            return error.LinkToLink;
        } else |e| if (e != error.NotLink) return e;
        const st = try d.statFile(target);
        if (st.kind != .file) return error.NotAFile;
        try self.clear(rel);
        try d.copyFile(target, d, rel, .{});
        self.stats.files += 1;
    }
};
