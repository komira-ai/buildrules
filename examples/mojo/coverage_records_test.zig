//! What `:coverage` of a mojo_package gives a consumer (docs/contract.md, section 12.4): `coverage.txt`, the count per file, and `:coverage[reports]`, the
//! records it was counted from, one kcov Cobertura file per test. Both are the zig_test's `data` (under BUILDRULES_TEST_WORK), the real outputs of two
//! example packages: `reexport` (its `__init__.mojo` only re-exports, so the report omits it) and `partial` (a test that takes one arm of a function,
//! so a line is recorded and does not run).
//!
//! A consumer reads the records, not the count, so the cases hold the two to each other: every file with a line in the summary has a class in the
//! records with the same lines hit and recorded, a file with none has no class, and the records hold no file the summary lacks.

const std = @import("std");
const t = std.testing;

const Row = struct { path: []const u8, hit: usize, total: usize, counted: bool };

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

/// The file rows of a coverage.txt: `<path> <hit>/<total> <n>%`, with ` (not counted)` after a test's own source. The `total` row is left out.
fn rowsOf(a: std.mem.Allocator, text: []const u8) ![]Row {
    var out = std.ArrayList(Row).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or std.mem.startsWith(u8, line, "total ")) continue;
        var f = std.mem.splitScalar(u8, line, ' ');
        const path = f.next() orelse return error.BadRow;
        const frac = f.next() orelse return error.BadRow;
        const slash = std.mem.indexOfScalar(u8, frac, '/') orelse return error.BadRow;
        try out.append(a, .{
            .path = path,
            .hit = try std.fmt.parseInt(usize, frac[0..slash], 10),
            .total = try std.fmt.parseInt(usize, frac[slash + 1 ..], 10),
            .counted = !std.mem.endsWith(u8, line, "(not counted)"),
        });
    }
    return out.toOwnedSlice(a);
}

const Class = struct { hit: usize, total: usize };

fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, " {s}=\"", .{name}) catch return null;
    const at = std.mem.indexOf(u8, tag, needle) orelse return null;
    const rest = tag[at + needle.len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse return null];
}

/// The `<line>` records of the class for `path`: how many have hits, how many there are. Null when the records have no such class.
fn classOf(a: std.mem.Allocator, xml: []const u8, path: []const u8) !?Class {
    const open = try std.fmt.allocPrint(a, "<class name=\"{s}\" filename=\"{s}\">", .{ path, path });
    const at = std.mem.indexOf(u8, xml, open) orelse return null;
    const end = std.mem.indexOfPos(u8, xml, at, "</class>") orelse return error.BadRecords;
    var c = Class{ .hit = 0, .total = 0 };
    var it = std.mem.splitScalar(u8, xml[at..end], '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "<line ")) continue;
        _ = try std.fmt.parseInt(usize, attr(line, "number") orelse return error.BadRecords, 10);
        const hits = try std.fmt.parseInt(usize, attr(line, "hits") orelse return error.BadRecords, 10);
        c.total += 1;
        if (hits > 0) c.hit += 1;
    }
    return c;
}

/// Holds one package's summary and records to each other. Returns the rows, for the cases that look further.
fn holdsTogether(a: std.mem.Allocator, summary: []const u8, records: []const u8) ![]Row {
    const rows = try rowsOf(a, summary);
    var with_lines: usize = 0;
    for (rows) |r| {
        const got = try classOf(a, records, r.path);
        if (r.total == 0) {
            // nothing recorded, so nothing in the records: the summary says 0/0 and the records have no class
            try t.expect(got == null);
            continue;
        }
        with_lines += 1;
        try t.expect(got != null);
        try t.expectEqual(r.hit, got.?.hit);
        try t.expectEqual(r.total, got.?.total);
    }
    // and the records hold no file the summary does not list
    try t.expectEqual(with_lines, std.mem.count(u8, records, "<class "));
    return rows;
}

test "the records of a package hold the lines the summary counts, file by file" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "reexport", "partial" }) |pkg| {
        const summary = try work(a, try std.fmt.allocPrint(a, "{s}/coverage.txt", .{pkg}));
        const records = try work(a, try std.fmt.allocPrint(a, "{s}/reports.cobertura.xml", .{pkg}));
        const rows = try holdsTogether(a, summary, records);
        try t.expect(rows.len >= 2);
    }
}

test "a package whose test leaves a line unrun has that line in the records, unhit" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const records = try work(a, "partial/reports.cobertura.xml");
    const c = (try classOf(a, records, "examples/mojo/partial/src/partial/__init__.mojo")).?;
    try t.expect(c.hit > 0);
    try t.expect(c.hit < c.total);
    try t.expect(std.mem.indexOf(u8, records, "hits=\"0\"") != null);
}

test "a source with no executable line is 0/0 in the summary and has no class in the records" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const summary = try work(a, "reexport/coverage.txt");
    const records = try work(a, "reexport/reports.cobertura.xml");
    try t.expect(std.mem.indexOf(u8, summary, "examples/mojo/reexport/src/reexport/__init__.mojo 0/0 0%\n") != null);
    try t.expect(std.mem.indexOf(u8, records, "reexport/__init__.mojo") == null);
    // a file of alias declarations only is listed, not refused, and likewise has no class
    try t.expect(std.mem.indexOf(u8, summary, "examples/mojo/reexport/src/reexport/aliases.mojo 0/0 0%\n") != null);
    try t.expect(std.mem.indexOf(u8, records, "reexport/aliases.mojo") == null);
    try t.expect((try classOf(a, records, "examples/mojo/reexport/src/reexport/ops.mojo")) != null);
}

test "the records name files by repository path, not by the directory an action ran in" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "reexport", "partial" }) |pkg| {
        const records = try work(a, try std.fmt.allocPrint(a, "{s}/reports.cobertura.xml", .{pkg}));
        try t.expect(std.mem.indexOf(u8, records, "filename=\"examples/mojo/") != null);
        try t.expect(std.mem.indexOf(u8, records, "filename=\"/") == null);
        try t.expect(std.mem.indexOf(u8, records, "buck-out") == null);
    }
}

test "the records carry no branch data and the summary claims none" {
    // kcov writes no `branch` attribute for a Mojo executable (rules/coverage/README.md): branch records are not something these reports hold.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "reexport", "partial" }) |pkg| {
        const summary = try work(a, try std.fmt.allocPrint(a, "{s}/coverage.txt", .{pkg}));
        const records = try work(a, try std.fmt.allocPrint(a, "{s}/reports.cobertura.xml", .{pkg}));
        try t.expect(std.mem.indexOf(u8, records, "branch=") == null);
        try t.expect(std.mem.indexOf(u8, records, "condition-coverage") == null);
        try t.expect(std.mem.indexOf(u8, summary, "branches") == null);
    }
}

test "a package without a floor file has the summary it always had" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "examples/mojo/reexport/src/reexport/__init__.mojo 0/0 0%\n" ++
            "examples/mojo/reexport/src/reexport/aliases.mojo 0/0 0%\n" ++
            "examples/mojo/reexport/src/reexport/ops.mojo 10/10 100%\n" ++
            "examples/mojo/reexport/tests/test_ops.mojo 16/16 100% (not counted)\n" ++
            "total 10/10 100%\n",
        try work(a, "reexport/coverage.txt"),
    );
}
