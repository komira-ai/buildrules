//! The pin rows of `unpack` (rules/pins/bootstrap.bzl) and their agreement with the programs this tree builds.
//!
//! `unpack` is the one program an action can run before anything else is unpacked, so it is downloaded, as a release asset of this repository: one asset per host,
//! under a release tag of its own, pinned by sha256 and size. The rows are only worth anything if they are the bytes this tree's source builds. The build is
//! reproducible (the same source and the same pinned zig give the same bytes on every worker), so the check is: build the program for each host, hash it, and
//! require the pin to say the same. A source change that does not come with a new tag and new rows is red.
const std = @import("std");

pub const hosts = [_][]const u8{ "linux-x86_64", "linux-aarch64", "macos-aarch64" };
pub const base = "https://github.com/komira-ai/buildrules/releases/download/";

pub const Row = struct { url: []const u8, sha256: []const u8, size: []const u8 };

/// A program this tree built for `host`, as the check hashes it.
pub const Built = struct { host: []const u8, sha256: [64]u8, size: u64 };

/// The value of `name = "..."` in the table's text, outside comments.
fn quoted(text: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const l = std.mem.trimLeft(u8, line, " ");
        if (l.len == 0 or l[0] == '#') continue;
        if (!std.mem.startsWith(u8, l, key)) continue;
        const after = l[key.len..];
        const open = std.mem.indexOfScalar(u8, after, '"') orelse continue;
        const close = std.mem.indexOfScalarPos(u8, after, open + 1, '"') orelse continue;
        return after[open + 1 .. close];
    }
    return null;
}

/// The release tag the rows point into.
pub fn tag(text: []const u8) ?[]const u8 {
    return quoted(text, "UNPACK_TAG");
}

/// The lines of `"<host>": {` up to its closing `},`.
fn block(text: []const u8, host: []const u8, buf: []u8) ?[]const u8 {
    const key = std.fmt.bufPrint(buf, "\"{s}\": {{", .{host}) catch return null;
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at..];
    const end = std.mem.indexOf(u8, rest, "\n    },") orelse rest.len;
    return rest[0..end];
}

pub fn row(text: []const u8, host: []const u8) ?Row {
    var buf: [64]u8 = undefined;
    const b = block(text, host, &buf) orelse return null;
    const size_line = blk: {
        var it = std.mem.splitScalar(u8, b, '\n');
        while (it.next()) |line| {
            const l = std.mem.trim(u8, line, " ");
            if (std.mem.startsWith(u8, l, "\"size\":")) break :blk std.mem.trim(u8, l["\"size\":".len..], " ,");
        }
        break :blk "";
    };
    return .{ .url = quoted(b, "\"url\"") orelse "", .sha256 = quoted(b, "\"sha256\"") orelse "", .size = size_line };
}

fn isHex64(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

fn isTag(s: []const u8) bool {
    const prefix = "unpack-";
    if (!std.mem.startsWith(u8, s, prefix) or s.len == prefix.len) return false;
    for (s[prefix.len..]) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

pub const Findings = std.ArrayList([]u8);

fn add(a: std.mem.Allocator, f: *Findings, comptime fmt: []const u8, args: anytype) !void {
    try f.append(a, try std.fmt.allocPrint(a, fmt, args));
}

/// Every way the table and the built programs disagree. The caller frees each finding and the list.
pub fn check(a: std.mem.Allocator, text: []const u8, built: []const Built) !Findings {
    var f = Findings.empty;
    const tg = tag(text) orelse "";
    if (!isTag(tg)) try add(a, &f, "rules/pins/bootstrap.bzl: UNPACK_TAG is \"{s}\", not `unpack-` and a number", .{tg});
    for (hosts) |host| {
        const r = row(text, host) orelse {
            try add(a, &f, "rules/pins/bootstrap.bzl: no row for {s}", .{host});
            continue;
        };
        const want_url = try std.fmt.allocPrint(a, "{s}{s}/unpack-{s}", .{ base, tg, host });
        defer a.free(want_url);
        if (!std.mem.eql(u8, r.url, want_url)) try add(a, &f, "rules/pins/bootstrap.bzl: the url of {s} is {s}, not {s}", .{ host, r.url, want_url });
        if (!isHex64(r.sha256)) try add(a, &f, "rules/pins/bootstrap.bzl: the sha256 of {s} is not 64 lower-case hex digits", .{host});
        const size = std.fmt.parseInt(u64, r.size, 10) catch 0;
        if (size == 0) try add(a, &f, "rules/pins/bootstrap.bzl: the size of {s} is not a positive number", .{host});
        var found = false;
        for (built) |b| {
            if (!std.mem.eql(u8, b.host, host)) continue;
            found = true;
            if (!std.mem.eql(u8, &b.sha256, r.sha256) or b.size != size) {
                try add(a, &f, "{s}: this tree builds unpack with sha256 {s} ({d} bytes) but rules/pins/bootstrap.bzl pins {s} ({s} bytes): upload the new program under a new tag, set UNPACK_TAG to it and write these values in the row", .{ host, &b.sha256, b.size, r.sha256, r.size });
            }
        }
        if (!found) try add(a, &f, "{s}: no program was built to compare with the row", .{host});
    }
    return f;
}
