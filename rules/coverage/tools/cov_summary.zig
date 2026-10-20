//! cov_summary: the line coverage of a package, from the normalized Cobertura reports of its tests (cov_normalize's output).
//!
//!   cov_summary --out <file> [--expect <repository path>]... <report.xml>...
//!
//! A line counts as hit when any report records it with hits above 0. The output lists every file the reports name with its hit and
//! recorded lines, then the total. `--expect` names the package's own sources: the tool fails (exit 1, nothing written) when one is not in any
//! report, because kcov drops a file it cannot open without an error and a package whose library no test compiled must not read as
//! covered. What is recorded is what the compiler emitted code for: a function no test reaches emits no lines, so the percentage is an
//! upper bound (a coverage checker may list such functions; this tool does not).

const std = @import("std");

pub const FileCov = struct { path: []const u8, hit: usize, total: usize };

fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var needle_buf: [32]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, " {s}=\"", .{name}) catch return null;
    const at = std.mem.indexOf(u8, tag, needle) orelse return null;
    const rest = tag[at + needle.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

const Lines = std.AutoArrayHashMapUnmanaged(usize, bool);

/// Folds one report into `files` (path -> line number -> hit).
pub fn addReport(a: std.mem.Allocator, files: *std.StringArrayHashMapUnmanaged(Lines), text: []const u8) !void {
    var cur: ?*Lines = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "<class ")) {
            const fname = attr(line, "filename") orelse return error.BadReport;
            const gop = try files.getOrPut(a, try a.dupe(u8, fname));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            cur = gop.value_ptr;
        } else if (std.mem.startsWith(u8, line, "</class>")) {
            cur = null;
        } else if (std.mem.startsWith(u8, line, "<line ")) {
            const lines = cur orelse return error.BadReport;
            const n = std.fmt.parseInt(usize, attr(line, "number") orelse return error.BadReport, 10) catch return error.BadReport;
            const h = std.fmt.parseInt(usize, attr(line, "hits") orelse return error.BadReport, 10) catch return error.BadReport;
            const gop = try lines.getOrPut(a, n);
            gop.value_ptr.* = (gop.found_existing and gop.value_ptr.*) or h > 0;
        }
    }
}

pub fn summarize(a: std.mem.Allocator, files: *std.StringArrayHashMapUnmanaged(Lines)) ![]FileCov {
    var out = std.ArrayList(FileCov).empty;
    var it = files.iterator();
    while (it.next()) |e| {
        var hit: usize = 0;
        for (e.value_ptr.values()) |h| {
            if (h) hit += 1;
        }
        try out.append(a, .{ .path = e.key_ptr.*, .hit = hit, .total = e.value_ptr.count() });
    }
    std.mem.sort(FileCov, out.items, {}, struct {
        fn lt(_: void, x: FileCov, y: FileCov) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    return out.toOwnedSlice(a);
}

fn isExpected(expect: []const []const u8, path: []const u8) bool {
    for (expect) |e| if (std.mem.eql(u8, e, path)) return true;
    return false;
}

/// The text of the summary: one line per file, then the total. With `expect` (the package's own sources) the total counts those
/// files only (the tests' own lines are listed but not counted, as covcheck leaves them out); without, every file.
pub fn render(a: std.mem.Allocator, rows: []const FileCov, expect: []const []const u8) ![]u8 {
    var o = std.ArrayList(u8).empty;
    var hit: usize = 0;
    var total: usize = 0;
    for (rows) |r| {
        const counted = expect.len == 0 or isExpected(expect, r.path);
        try o.print(a, "{s} {d}/{d} {d}%{s}\n", .{ r.path, r.hit, r.total, pct(r.hit, r.total), if (counted) "" else " (not counted)" });
        if (counted) {
            hit += r.hit;
            total += r.total;
        }
    }
    try o.print(a, "total {d}/{d} {d}%\n", .{ hit, total, pct(hit, total) });
    return o.toOwnedSlice(a);
}

fn pct(hit: usize, total: usize) usize {
    return if (total == 0) 0 else hit * 100 / total;
}

/// The first of `expect` that no row names.
pub fn missing(rows: []const FileCov, expect: []const []const u8) ?[]const u8 {
    for (expect) |e| {
        var found = false;
        for (rows) |r| found = found or std.mem.eql(u8, r.path, e);
        if (!found) return e;
    }
    return null;
}

fn die(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cov_summary: " ++ fmt ++ "\n", args);
    std.process.exit(code);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    var out_path: ?[]const u8 = null;
    var expect = std.ArrayList([]const u8).empty;
    var reports = std.ArrayList([]const u8).empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--out") and i + 1 < argv.len) {
            i += 1;
            out_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--expect") and i + 1 < argv.len) {
            i += 1;
            try expect.append(a, argv[i]);
        } else if (argv[i].len > 0 and argv[i][0] == '-') {
            die(2, "unknown option {s}", .{argv[i]});
        } else {
            try reports.append(a, argv[i]);
        }
    }
    if (out_path == null or reports.items.len == 0) die(2, "usage: cov_summary --out <file> [--expect <path>]... <report.xml>...", .{});
    var files: std.StringArrayHashMapUnmanaged(Lines) = .empty;
    for (reports.items) |p| {
        const text = std.fs.cwd().readFileAlloc(a, p, 64 << 20) catch |e| die(1, "cannot read {s}: {s}", .{ p, @errorName(e) });
        addReport(a, &files, text) catch die(1, "{s} is not a normalized Cobertura report", .{p});
    }
    const rows = try summarize(a, &files);
    if (missing(rows, expect.items)) |m| die(1, "{s} is in no report: no test compiled it, or kcov could not open it", .{m});
    const text = try render(a, rows, expect.items);
    std.fs.cwd().writeFile(.{ .sub_path = out_path.?, .data = text }) catch |e| die(1, "cannot write {s}: {s}", .{ out_path.?, @errorName(e) });
}
