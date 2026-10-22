//! cov_summary: the line coverage of a package, from the normalized Cobertura reports of its tests (cov_normalize's output).
//!
//!   cov_summary --out <file> [--expect <repository path>]... [--src <repository path>=<file>]... [--blocks <blocks file>]...
//!               [--branch-lcov <branch records>]... <report.xml>...
//!
//! `--src` gives the file behind an `--expect` path (Mojo only). The Mojo report omits a source with no executable line, so an expected source that
//! no report names but whose text has no statement beyond comments, docstrings and `import` lines (a re-export `__init__.mojo`) is listed as 0/0
//! instead of refused; one with any other statement stays refused (`hasNoStatements`).
//!
//! `--blocks` is a zig_cover.zig block report (Zig's branch figure: the compiler's basic blocks, `<file> TAB <line> TAB <column> TAB <hit> TAB <total>`).
//! With any, the output continues after the line total with the same listing prefixed `branches `: the blocks at a position that ran are the most
//! any report hit, `--expect` limits the total to the package's own sources, and a source in no block report is refused as it is in no line report.
//!
//! `--branch-lcov` is a branch record file of one Mojo test (cov_branch_classify's output; branch_lcov.zig has the format and what is
//! refused): lcov `BRDA` lines keyed by decision and arm. With any, the output continues after the line total with the same listing
//! prefixed `branches ` (as with `--blocks`; a package has one kind of branch figure, so the two do not mix): an arm is hit when any test
//! took it, the records of all the tests are summed by id, `--expect` limits the total to the package's own sources, and an expected source
//! that has lines and no record is refused, as one in no line report is (a source with no executable line is `0/0` in both).
//!
//! A line counts as hit when any report records it with hits above 0. The output lists every file the reports name with its hit and
//! recorded lines, then the total. `--expect` names the package's own sources: the tool fails (exit 1, nothing written) when one is not in any
//! report, because kcov drops a file it cannot open without an error and a package whose library no test compiled must not read as
//! covered. What is recorded is what the compiler emitted code for: a function no test reaches emits no lines, so the percentage is an
//! upper bound (a coverage checker may list such functions; this tool does not).

const std = @import("std");
const branch_lcov = @import("branch_lcov.zig");

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

/// The blocks at one source position: how many ran, how many there are.
pub const BlockCount = struct { hit: u32, total: u32 };
pub const BlockPositions = std.AutoArrayHashMapUnmanaged(u64, BlockCount);

/// Folds one block report (zig_cover.zig's) into `files` (path -> `line << 32 | column` -> counts). Two reports of one position (two tests of a
/// package compile the same code) keep the larger of each count: they are the same blocks run by different tests, so the blocks of a position
/// that ran in one report or the other are the larger count, not the sum.
pub fn addBlocks(a: std.mem.Allocator, files: *std.StringArrayHashMapUnmanaged(BlockPositions), text: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    const first = it.next() orelse return error.BadReport;
    if (!std.mem.eql(u8, first, "# blocks v2")) return error.BadReport;
    while (it.next()) |row| {
        if (row.len == 0) continue;
        var f = std.mem.splitScalar(u8, row, '\t');
        const file = f.next() orelse return error.BadReport;
        const line = std.fmt.parseInt(u32, f.next() orelse return error.BadReport, 10) catch return error.BadReport;
        const col = std.fmt.parseInt(u32, f.next() orelse return error.BadReport, 10) catch return error.BadReport;
        const hit = std.fmt.parseInt(u32, f.next() orelse return error.BadReport, 10) catch return error.BadReport;
        const total = std.fmt.parseInt(u32, f.next() orelse return error.BadReport, 10) catch return error.BadReport;
        if (f.next() != null or total == 0 or hit > total) return error.BadReport;
        const gop = try files.getOrPut(a, file);
        if (!gop.found_existing) {
            gop.key_ptr.* = try a.dupe(u8, file);
            gop.value_ptr.* = .empty;
        }
        const pos = try gop.value_ptr.getOrPut(a, (@as(u64, line) << 32) | col);
        if (pos.found_existing) {
            pos.value_ptr.hit = @max(pos.value_ptr.hit, hit);
            pos.value_ptr.total = @max(pos.value_ptr.total, total);
        } else pos.value_ptr.* = .{ .hit = hit, .total = total };
    }
}

/// Per file, the blocks that ran and the blocks there are, sorted by path.
pub fn summarizeBlocks(a: std.mem.Allocator, files: *std.StringArrayHashMapUnmanaged(BlockPositions)) ![]FileCov {
    var out = std.ArrayList(FileCov).empty;
    var it = files.iterator();
    while (it.next()) |e| {
        var hit: usize = 0;
        var total: usize = 0;
        for (e.value_ptr.values()) |c| {
            hit += c.hit;
            total += c.total;
        }
        try out.append(a, .{ .path = e.key_ptr.*, .hit = hit, .total = total });
    }
    std.mem.sort(FileCov, out.items, {}, struct {
        fn lt(_: void, x: FileCov, y: FileCov) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    return out.toOwnedSlice(a);
}

/// The branch rows of a Mojo package: one per file the summed records name, and a 0/0 row for each expected source they do not name whose line
/// row has no line (the classifier writes no record for a file with no code). An expected source that has lines and no record is `lacking`.
pub const BranchRows = union(enum) { rows: []FileCov, lacking: []const u8 };

pub fn branchRows(a: std.mem.Allocator, counts: []const branch_lcov.Count, lines: []const FileCov, expect: []const []const u8) !BranchRows {
    var out = std.ArrayList(FileCov).empty;
    for (counts) |c| try out.append(a, .{ .path = c.path, .hit = c.hit, .total = c.total });
    for (expect) |e| {
        var named = false;
        for (out.items) |r| named = named or std.mem.eql(u8, r.path, e);
        if (named) continue;
        for (lines) |l| {
            if (std.mem.eql(u8, l.path, e) and l.total > 0) return .{ .lacking = e };
        }
        try out.append(a, .{ .path = e, .hit = 0, .total = 0 });
    }
    std.mem.sort(FileCov, out.items, {}, struct {
        fn lt(_: void, x: FileCov, y: FileCov) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    return .{ .rows = try out.toOwnedSlice(a) };
}

/// The branch listing of the record files `texts` (named `origins` in errors): `text` is the `branches `-prefixed rows and total to follow the
/// line listing, or `refused` says why the records cannot be used.
pub const Branch = union(enum) { text: []const u8, refused: []const u8 };

pub fn branchListing(a: std.mem.Allocator, origins: []const []const u8, texts: []const []const u8, lines: []const FileCov, expect: []const []const u8) !Branch {
    var sum = branch_lcov.Sum{};
    var diag = branch_lcov.Diag{};
    for (origins, texts) |o, t| {
        sum.add(a, &diag, t, o) catch |e| switch (e) {
            error.Refused => return .{ .refused = diag.msg },
            error.OutOfMemory => return e,
        };
    }
    switch (try branchRows(a, try sum.counts(a), lines, expect)) {
        .lacking => |m| return .{ .refused = try std.fmt.allocPrint(a, "{s} is in no branch record: its tests ran no code of it, or the classifier found none", .{m}) },
        .rows => |brows| return .{ .text = try renderWith(a, brows, expect, "branches ") },
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
    return renderWith(a, rows, expect, "");
}

/// `render`, every row starting with `prefix` (the branch listing's is `branches `).
pub fn renderWith(a: std.mem.Allocator, rows: []const FileCov, expect: []const []const u8, prefix: []const u8) ![]u8 {
    var o = std.ArrayList(u8).empty;
    var hit: usize = 0;
    var total: usize = 0;
    for (rows) |r| {
        const counted = expect.len == 0 or isExpected(expect, r.path);
        try o.print(a, "{s}{s} {d}/{d} {d}%{s}\n", .{ prefix, r.path, r.hit, r.total, pct(r.hit, r.total), if (counted) "" else " (not counted)" });
        if (counted) {
            hit += r.hit;
            total += r.total;
        }
    }
    try o.print(a, "{s}total {d}/{d} {d}%\n", .{ prefix, hit, total, pct(hit, total) });
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

/// Whether a continuation line of a parenthesised import holds only what one may hold: names, dots, commas, `as`, parentheses, and a comment.
fn importContinuation(line: []const u8) bool {
    for (line) |c| {
        if (c == '#') return true;
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == ' ' or c == '\t' or c == ',' or c == '.' or c == '(' or c == ')' or c == '\\';
        if (!ok) return false;
    }
    return true;
}

/// Folds the parentheses of one import line into `depth`. The only `(` an import has opens its name list, right after `import` and not inside
/// another (`from a import f()` and `from a import (f(), g)` are calls); a `)` with nothing open is refused.
fn parens(code: []const u8, depth: *i32) bool {
    for (code, 0..) |c, i| {
        if (c == '(') {
            if (depth.* != 0 or !std.mem.endsWith(u8, std.mem.trimRight(u8, code[0..i], " \t"), "import")) return false;
            depth.* += 1;
        } else if (c == ')') {
            depth.* -= 1;
            if (depth.* < 0) return false;
        }
    }
    return true;
}

fn hasLineBreakChar(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "\x0b\x0c") != null;
}

/// Whether a Mojo source has no executable line: only blank lines, comments, docstrings (a triple-quoted string on its own lines) and top-level
/// `from ... import ...` / `import ...` statements (a re-export file, `__init__.mojo`). The Mojo coverage report omits such a file, and so it
/// does a file with code that no test compiled; this is what tells them apart, so it is strict: any other statement, a `;`, a quote on an import,
/// or an unclosed docstring or parenthesis makes it false.
pub fn hasNoStatements(text: []const u8) bool {
    var in_doc: ?[]const u8 = null; // the closing triple quote while inside a docstring
    var depth: i32 = 0; // open parentheses of an import
    var cont = false; // the previous import line ended with a backslash
    // A carriage return that does not end a CRLF is a line break to some readers and not to this one: refuse the file rather than guess.
    for (text, 0..) |c, i| {
        if (c == '\r' and (i + 1 >= text.len or text[i + 1] != '\n')) return false;
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (in_doc) |q| {
            const at = std.mem.indexOf(u8, line, q) orelse continue;
            const rest = std.mem.trim(u8, line[at + 3 ..], " \t");
            if (rest.len != 0 and rest[0] != '#') return false;
            if (hasLineBreakChar(rest)) return false;
            in_doc = null;
            continue;
        }
        // A vertical tab or form feed outside a string is a line break to some readers (Python's splitlines) and not to others.
        const doc_start = std.mem.startsWith(u8, line, "\"\"\"") or std.mem.startsWith(u8, line, "'''");
        if (!doc_start and hasLineBreakChar(raw)) return false;
        if (depth > 0 or cont) {
            if (!importContinuation(line)) return false;
            const code = line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len];
            if (!parens(code, &depth)) return false;
            cont = std.mem.endsWith(u8, std.mem.trimRight(u8, code, " \t"), "\\");
            continue;
        }
        if (line.len == 0 or line[0] == '#') continue;
        if (doc_start) {
            const q = line[0..3];
            if (std.mem.indexOf(u8, line[3..], q)) |at| {
                const rest = std.mem.trim(u8, line[3 + at + 3 ..], " \t");
                if (rest.len != 0 and rest[0] != '#') return false;
                if (hasLineBreakChar(rest)) return false;
            } else in_doc = q;
            continue;
        }
        // Only a statement at column 0 is an import of the module.
        if (raw[0] == ' ' or raw[0] == '\t') return false;
        const is_import = (std.mem.startsWith(u8, line, "from ") and std.mem.indexOf(u8, line, " import ") != null) or std.mem.startsWith(u8, line, "import ");
        if (!is_import or !importContinuation(line)) return false;
        const code = line[0 .. std.mem.indexOfScalar(u8, line, '#') orelse line.len];
        if (!parens(code, &depth)) return false;
        cont = std.mem.endsWith(u8, std.mem.trimRight(u8, code, " \t"), "\\");
    }
    return in_doc == null and depth == 0 and !cont;
}

/// `rows` plus a 0/0 row for each file of `expect` that no row names and whose source (`srcs`: expected path, then the file to read) has no
/// statement. A file the report lacks that has statements stays missing, so `missing` still refuses it.
pub fn withEmptySources(a: std.mem.Allocator, rows: []const FileCov, expect: []const []const u8, srcs: []const [2][]const u8, read: *const fn (std.mem.Allocator, []const u8) []const u8) ![]FileCov {
    var out = std.ArrayList(FileCov).empty;
    try out.appendSlice(a, rows);
    for (expect) |e| {
        var found = false;
        for (rows) |r| found = found or std.mem.eql(u8, r.path, e);
        if (found) continue;
        for (srcs) |s| {
            if (std.mem.eql(u8, s[0], e) and hasNoStatements(read(a, s[1]))) try out.append(a, .{ .path = e, .hit = 0, .total = 0 });
        }
    }
    std.mem.sort(FileCov, out.items, {}, struct {
        fn lt(_: void, x: FileCov, y: FileCov) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    return out.toOwnedSlice(a);
}

fn readSource(a: std.mem.Allocator, p: []const u8) []const u8 {
    return std.fs.cwd().readFileAlloc(a, p, 64 << 20) catch |e| die(1, "cannot read {s}: {s}", .{ p, @errorName(e) });
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
    var block_reports = std.ArrayList([]const u8).empty;
    var branch_files = std.ArrayList([]const u8).empty;
    var srcs = std.ArrayList([2][]const u8).empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--out") and i + 1 < argv.len) {
            i += 1;
            out_path = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--expect") and i + 1 < argv.len) {
            i += 1;
            try expect.append(a, argv[i]);
        } else if (std.mem.eql(u8, argv[i], "--src") and i + 1 < argv.len) {
            i += 1;
            const eq = std.mem.indexOfScalar(u8, argv[i], '=') orelse die(2, "--src wants <expected path>=<file>, got {s}", .{argv[i]});
            try srcs.append(a, .{ argv[i][0..eq], argv[i][eq + 1 ..] });
        } else if (std.mem.eql(u8, argv[i], "--blocks") and i + 1 < argv.len) {
            i += 1;
            try block_reports.append(a, argv[i]);
        } else if (std.mem.eql(u8, argv[i], "--branch-lcov") and i + 1 < argv.len) {
            i += 1;
            try branch_files.append(a, argv[i]);
        } else if (argv[i].len > 0 and argv[i][0] == '-') {
            die(2, "unknown option {s}", .{argv[i]});
        } else {
            try reports.append(a, argv[i]);
        }
    }
    if (out_path == null or reports.items.len == 0) die(2, "usage: cov_summary --out <file> [--expect <path>]... [--blocks <file>]... [--branch-lcov <file>]... <report.xml>...", .{});
    if (block_reports.items.len != 0 and branch_files.items.len != 0) die(2, "--blocks (Zig) and --branch-lcov (Mojo) are two kinds of branch figure: a package has one", .{});
    var files: std.StringArrayHashMapUnmanaged(Lines) = .empty;
    for (reports.items) |p| {
        const text = std.fs.cwd().readFileAlloc(a, p, 64 << 20) catch |e| die(1, "cannot read {s}: {s}", .{ p, @errorName(e) });
        addReport(a, &files, text) catch die(1, "{s} is not a normalized Cobertura report", .{p});
    }
    const rows = try withEmptySources(a, try summarize(a, &files), expect.items, srcs.items, readSource);
    if (missing(rows, expect.items)) |m| die(1, "{s} is in no report: no test compiled it, or kcov could not open it", .{m});
    var text = try render(a, rows, expect.items);
    if (block_reports.items.len != 0) {
        var blocks: std.StringArrayHashMapUnmanaged(BlockPositions) = .empty;
        for (block_reports.items) |p| {
            const btext = std.fs.cwd().readFileAlloc(a, p, 64 << 20) catch |e| die(1, "cannot read {s}: {s}", .{ p, @errorName(e) });
            addBlocks(a, &blocks, btext) catch die(1, "{s} is not a block report", .{p});
        }
        const brows = try summarizeBlocks(a, &blocks);
        if (missing(brows, expect.items)) |m| die(1, "{s} is in no block report: no test compiled it with block counters", .{m});
        text = try std.mem.concat(a, u8, &.{ text, try renderWith(a, brows, expect.items, "branches ") });
    }
    if (branch_files.items.len != 0) {
        const texts = try a.alloc([]const u8, branch_files.items.len);
        for (branch_files.items, texts) |p, *t| t.* = readSource(a, p);
        switch (try branchListing(a, branch_files.items, texts, rows, expect.items)) {
            .refused => |m| die(1, "{s}", .{m}),
            .text => |t| text = try std.mem.concat(a, u8, &.{ text, t }),
        }
    }
    std.fs.cwd().writeFile(.{ .sub_path = out_path.?, .data = text }) catch |e| die(1, "cannot write {s}: {s}", .{ out_path.?, @errorName(e) });
}
