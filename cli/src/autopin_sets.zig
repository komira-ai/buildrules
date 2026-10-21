//! SETS: the directories `buildrules autopin` may read and write, and the table file each holds. The list is
//! given by the caller as `--set DIR=KIND` flags, which a workflow carries as literals in the copy of the file
//! on the default branch, so nothing a pull request edits decides where this program writes. Every output path
//! the program writes, and every member of an artifact it accepts, is one of `outputs`; no path is ever taken
//! from an artifact or from a manifest.

const std = @import("std");
const valid = @import("valid.zig");
const npm_cmd = @import("npm_cmd.zig");

/// Which generator made the table of a directory.
pub const Kind = enum {
    /// `buildrules npm sync`: `buildrules.lock.bzl` (a PACKAGE block and the NPM rows).
    buildrules_lock,
    /// `kpin`: `pins.lock.bzl` (a PINS block that is not derived from the lock, and the NPM rows).
    pins_lock,
};

pub const Set = struct { dir: []const u8, kind: Kind };

pub const max_sets = 8;

pub const pins_lock_file = "pins.lock.bzl";
pub const package_json = "package.json";
pub const package_lock = "package-lock.json";

pub const SetError = error{ BadSet, DuplicateSet, TooManySets, NoSets };

pub fn kindName(k: Kind) []const u8 {
    return switch (k) {
        .buildrules_lock => "buildrules-lock",
        .pins_lock => "pins-lock",
    };
}

pub fn tableFile(k: Kind) []const u8 {
    return switch (k) {
        .buildrules_lock => npm_cmd.lock_file,
        .pins_lock => pins_lock_file,
    };
}

/// `DIR=KIND`: DIR is `.` or a relative path of `valid.isRelPath`, KIND one of the names above.
pub fn parseSet(s: []const u8) SetError!Set {
    const eq = std.mem.lastIndexOfScalar(u8, s, '=') orelse return error.BadSet;
    const dir = s[0..eq];
    const kind_text = s[eq + 1 ..];
    const kind: Kind = if (std.mem.eql(u8, kind_text, "buildrules-lock")) .buildrules_lock else if (std.mem.eql(u8, kind_text, "pins-lock")) .pins_lock else return error.BadSet;
    if (!std.mem.eql(u8, dir, ".") and !valid.isRelPath(dir)) return error.BadSet;
    return .{ .dir = dir, .kind = kind };
}

pub const Sets = struct {
    items: []const Set,

    /// The sets of the `--set` values: at least one, at most `max_sets`, no directory twice.
    pub fn parse(a: std.mem.Allocator, values: []const []const u8) (SetError || error{OutOfMemory})!Sets {
        if (values.len == 0) return error.NoSets;
        if (values.len > max_sets) return error.TooManySets;
        var list = std.ArrayList(Set).empty;
        for (values) |v| {
            const s = try parseSet(v);
            for (list.items) |have| if (std.mem.eql(u8, have.dir, s.dir)) return error.DuplicateSet;
            try list.append(a, s);
        }
        return .{ .items = list.items };
    }

    pub fn path(a: std.mem.Allocator, set: Set, name: []const u8) ![]u8 {
        if (std.mem.eql(u8, set.dir, ".")) return a.dupe(u8, name);
        return std.fmt.allocPrint(a, "{s}/{s}", .{ set.dir, name });
    }

    pub fn tablePath(a: std.mem.Allocator, set: Set) ![]u8 {
        return path(a, set, tableFile(set.kind));
    }

    /// The index of the set whose table output is `p`, by exact equality.
    pub fn outputIndex(self: Sets, a: std.mem.Allocator, p: []const u8) !?usize {
        for (self.items, 0..) |s, i| {
            const want = try tablePath(a, s);
            if (std.mem.eql(u8, want, p)) return i;
        }
        return null;
    }

    /// True when a pull request may change the file `p`: a SETS directory's package.json, package-lock.json
    /// or table output, by exact equality (never a prefix, never a case-insensitive match).
    pub fn prMayTouch(self: Sets, a: std.mem.Allocator, p: []const u8) !bool {
        for (self.items) |s| {
            const names = [_][]const u8{ package_json, package_lock, tableFile(s.kind) };
            for (names) |n| {
                const want = try path(a, s, n);
                if (std.mem.eql(u8, want, p)) return true;
            }
        }
        return false;
    }
};
