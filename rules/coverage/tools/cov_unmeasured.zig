//! cov_unmeasured: the sources of a package that kcov cannot record, named in the package's committed `coverage_unmeasured.txt` (cov_summary --unmeasured).
//!
//! A Mojo source whose functions are all `@always_inline("nodebug")` (behind a `comptime if`, say) has no line in any report although the tests run it, and
//! cov_summary refuses a source that is in no report. Counting it 0/0 would say nothing was there; this file is the explicit way out: a source listed in it
//! with its reason is accepted when no report names it, printed as `unmeasured: <path>: <reason>`, and left out of the line and branch totals and floors.
//!
//! The file: one entry per line, `<source path relative to the package>`, then a TAB or two spaces, then the reason (not empty). A blank line and a line
//! whose first character is `#` are skipped. Refused, with the line or the path named: a line with no reason, a path listed twice, a path that is not a
//! library source of the package (no such file, or a test or another file), a path some report names ("listed as unmeasured but measured: remove the entry":
//! the entry went stale when the tool began recording it), and a source with no statement at all (a re-export file, which `:coverage` lists 0/0 already).

const std = @import("std");

pub const Entry = struct { path: []const u8, reason: []const u8 };

pub const Parsed = union(enum) { entries: []const Entry, refused: []const u8 };

/// The entries of the file's `text` (`name` in messages): refused for a line with no path-and-reason split or an empty reason, and for a duplicate path.
pub fn parse(a: std.mem.Allocator, name: []const u8, text: []const u8) !Parsed {
    var out = std.ArrayList(Entry).empty;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trimRight(u8, raw, " \t\r");
        const lead = std.mem.trimStart(u8, line, " \t");
        if (lead.len == 0 or lead[0] == '#') continue;
        const cut = std.mem.indexOfScalar(u8, line, '\t') orelse std.mem.indexOf(u8, line, "  ") orelse
            return .{ .refused = try std.fmt.allocPrint(a, "{s}:{d}: `{s}` has no reason: write `<source path>`, a TAB or two spaces, and why kcov cannot record it", .{ name, n, line }) };
        const path = line[0..cut];
        const reason = std.mem.trim(u8, line[cut..], " \t");
        const no_path = std.mem.trim(u8, path, " \t").len == 0;
        if (no_path or reason.len == 0) return .{ .refused = try std.fmt.allocPrint(a, "{s}:{d}: `{s}` has no {s}: write `<source path>`, a TAB or two spaces, and why kcov cannot record it", .{ name, n, line, if (no_path) "path" else "reason" }) };
        for (out.items) |e| {
            if (std.mem.eql(u8, e.path, path)) return .{ .refused = try std.fmt.allocPrint(a, "{s}:{d}: {s} is listed twice", .{ name, n, path }) };
        }
        try out.append(a, .{ .path = path, .reason = reason });
    }
    return .{ .entries = try out.toOwnedSlice(a) };
}

fn contains(set: []const []const u8, path: []const u8) bool {
    for (set) |s| if (std.mem.eql(u8, s, path)) return true;
    return false;
}

pub const Resolved = union(enum) {
    /// `expect` without the unmeasured sources, and the text that closes the summary (empty when no entry).
    ok: struct { expect: []const []const u8, listing: []const u8 },
    refused: []const u8,
};

/// Checks `entries` (package-relative paths; `root` is the package's directory from the repository root, "" at the root) against the package:
/// `expect` its library sources (repository paths), `reported` every path some report names, `empty` the expected sources with no statement.
pub fn resolve(a: std.mem.Allocator, name: []const u8, entries: []const Entry, root: []const u8, expect: []const []const u8, reported: []const []const u8, empty: []const []const u8) !Resolved {
    var left = std.ArrayList([]const u8).empty;
    var listing = std.ArrayList(u8).empty;
    var gone = std.ArrayList([]const u8).empty;
    for (entries) |e| {
        const repo = if (root.len == 0) e.path else try std.fs.path.join(a, &.{ root, e.path });
        if (!contains(expect, repo)) return .{ .refused = try std.fmt.allocPrint(a, "{s}: {s} is not a library source of the package (no such file, or a test or another file): remove the entry", .{ name, e.path }) };
        if (contains(reported, repo)) return .{ .refused = try std.fmt.allocPrint(a, "{s}: {s} listed as unmeasured but measured: remove the entry", .{ name, e.path }) };
        if (contains(empty, repo)) return .{ .refused = try std.fmt.allocPrint(a, "{s}: {s} has no statement, so `:coverage` lists it 0/0 and there is nothing to be unmeasured: remove the entry", .{ name, e.path }) };
        try gone.append(a, repo);
        try listing.print(a, "unmeasured: {s}: {s}\n", .{ repo, e.reason });
    }
    if (entries.len != 0) try listing.print(a, "unmeasured total {d} files: left out of the line and branch totals and the floors\n", .{entries.len});
    for (expect) |x| if (!contains(gone.items, x)) try left.append(a, x);
    return .{ .ok = .{ .expect = try left.toOwnedSlice(a), .listing = try listing.toOwnedSlice(a) } };
}

/// The whole step of a summary: reads the file `path`, checks it (`resolve`) and reads the sources behind `srcs` (expected path, then the file to read) for
/// those with no statement (`noStatements` says which). `root` is the package's directory from the repository root, `reported` the paths the reports name.
pub fn load(
    a: std.mem.Allocator,
    root: []const u8,
    path: []const u8,
    expect: []const []const u8,
    reported: []const []const u8,
    srcs: []const [2][]const u8,
    read: *const fn (std.mem.Allocator, []const u8) []const u8,
    noStatements: *const fn ([]const u8) bool,
) !Resolved {
    var empty = std.ArrayList([]const u8).empty;
    for (srcs) |s| if (contains(expect, s[0]) and noStatements(read(a, s[1]))) try empty.append(a, s[0]);
    const name = std.fs.path.basename(path);
    return switch (try parse(a, name, read(a, path))) {
        .refused => |m| .{ .refused = m },
        .entries => |es| try resolve(a, name, es, root, expect, reported, empty.items),
    };
}
