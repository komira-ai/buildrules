//! cov_summary: the line coverage of a package, from the normalized Cobertura reports of its tests (cov_normalize's output).
//!
//!   cov_summary --out <file> [--expect <repository path>]... [--src <repository path>=<file>]... [--blocks <blocks file>]... <report.xml>...
//!
//! `--src` gives the file behind an `--expect` path (Mojo only). The Mojo report omits a source with no executable line, so an expected source that
//! no report names but whose text has no statement beyond comments, docstrings and `import` lines (a re-export `__init__.mojo`) is listed as 0/0
//! instead of refused; one with any other statement stays refused (`hasNoStatements`).
//!
//! `--blocks` is a zig_cover.zig block report (Zig's branch figure: the compiler's basic blocks, `<file> TAB <line> TAB <column> TAB <hit> TAB <total>`).
//! With any, the output continues after the line total with the same listing prefixed `branches `: the blocks at a position that ran are the most
//! any report hit, `--expect` limits the total to the package's own sources, and a source in no block report is refused as it is in no line report.
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

/// The text of a top-level alias declaration after its name, when `line` is one: `alias NAME ...` or `comptime NAME ...` where NAME is followed by a
/// parameter list (`[`), an annotation (`:`) or the `=` itself. `comptime if`, `comptime for`, `comptime assert` and every other `comptime` that does
/// not declare a name are statements of the compile-time evaluator, not declarations, and give null.
fn aliasTail(line: []const u8) ?[]const u8 {
    const kw: usize = if (std.mem.startsWith(u8, line, "alias ")) 6 else if (std.mem.startsWith(u8, line, "comptime ")) 9 else return null;
    var i = kw;
    while (i < line.len and line[i] == ' ') i += 1;
    const start = i;
    while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) i += 1;
    const name = line[start..i];
    if (name.len == 0 or std.ascii.isDigit(name[0])) return null;
    for ([_][]const u8{ "if", "for", "while", "assert", "else", "elif", "with", "try", "except", "raise", "return" }) |k| {
        if (std.mem.eql(u8, name, k)) return null;
    }
    while (i < line.len and line[i] == ' ') i += 1;
    if (i >= line.len) return null;
    if (line[i] == '=' and i + 1 < line.len and line[i + 1] == '=') return null;
    if (line[i] != '[' and line[i] != ':' and line[i] != '=') return null;
    return line[i..];
}

/// Folds one line of an alias declaration into the state of its statement: `depth` (open brackets), `saw_eq` (the `=` of the declaration, outside every
/// bracket) and `cont` (the line ends with a backslash). False for what a declaration does not hold: a `;`, a triple-quoted string, a string that does not
/// end on its line, a backslash that is not the last character, a bracket closed before it was opened.
fn scanExpr(line: []const u8, depth: *i32, saw_eq: *bool, cont: *bool) bool {
    cont.* = false;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == '\\') {
                i += 1;
                if (i >= line.len) return false;
            } else if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => {
                if (std.mem.startsWith(u8, line[i..], "\"\"\"") or std.mem.startsWith(u8, line[i..], "'''")) return false;
                quote = c;
            },
            '#' => return true,
            ';' => return false,
            '(', '[', '{' => depth.* += 1,
            ')', ']', '}' => {
                depth.* -= 1;
                if (depth.* < 0) return false;
            },
            '=' => {
                if (i + 1 < line.len and line[i + 1] == '=') {
                    i += 1;
                } else if (depth.* == 0 and (i == 0 or std.mem.indexOfScalar(u8, "!<>=:", line[i - 1]) == null)) saw_eq.* = true;
            },
            '\\' => {
                if (std.mem.trim(u8, line[i + 1 ..], " \t").len != 0) return false;
                cont.* = true;
            },
            else => {},
        }
    }
    return quote == 0;
}

/// Whether a Mojo source has no executable line: only blank lines, comments, docstrings (a triple-quoted string on its own lines), top-level
/// `from ... import ...` / `import ...` statements (a re-export file, `__init__.mojo`) and top-level alias declarations (`alias` or `comptime NAME = ...`,
/// with an annotation or a parameter list, the value running over several lines inside brackets or after a backslash), which emit no code. The Mojo
/// coverage report omits such a file, and so it does a file with code that no test compiled; this is what tells them apart, so it is strict: any other
/// statement (a function, a struct, a `var`, a `comptime if` / `for` / `assert`), a `;`, an indented line outside a continuation, or an unclosed
/// docstring or bracket makes it false.
pub fn hasNoStatements(text: []const u8) bool {
    var in_doc: ?[]const u8 = null; // the closing triple quote while inside a docstring
    var depth: i32 = 0; // open parentheses of an import, or brackets of an alias
    var cont = false; // the previous import or alias line ended with a backslash
    var in_alias = false; // inside an alias declaration that runs over more lines
    var saw_eq = false; // the alias declaration has its `=`
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
            if (in_alias) {
                // A backslash joins the next line: a blank line (or the end of the text) after it leaves the statement unfinished.
                if (depth == 0 and line.len == 0) return false;
                if (!scanExpr(line, &depth, &saw_eq, &cont)) return false;
                if (depth == 0 and !cont) {
                    if (!saw_eq) return false;
                    in_alias = false;
                }
                continue;
            }
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
        if (std.mem.startsWith(u8, line, "alias ") or std.mem.startsWith(u8, line, "comptime ")) {
            const tail = aliasTail(line) orelse return false;
            saw_eq = false;
            if (!scanExpr(tail, &depth, &saw_eq, &cont)) return false;
            if (depth == 0 and !cont) {
                if (!saw_eq) return false;
            } else in_alias = true;
            continue;
        }
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
        } else if (argv[i].len > 0 and argv[i][0] == '-') {
            die(2, "unknown option {s}", .{argv[i]});
        } else {
            try reports.append(a, argv[i]);
        }
    }
    if (out_path == null or reports.items.len == 0) die(2, "usage: cov_summary --out <file> [--expect <path>]... [--blocks <file>]... <report.xml>...", .{});
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
    std.fs.cwd().writeFile(.{ .sub_path = out_path.?, .data = text }) catch |e| die(1, "cannot write {s}: {s}", .{ out_path.?, @errorName(e) });
}
