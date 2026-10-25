//! cov_summary: the line coverage of a package, from the normalized Cobertura reports of its tests (cov_normalize's output).
//!
//!   cov_summary --out <file> [--expect <repository path>]... [--src <repository path>=<file>]... [--blocks <blocks file>]...
//!               [--branch-lcov <branch records>]... [--uncompiled-lines <file>] [--uncompiled-branches <file>] [--uncompiled-report <file>] <report.xml>...
//!
//! `--src` gives the file behind an `--expect` path (Mojo only); a `--src` path that is no `--expect` path is another source of the package (a
//! test), read for the calls that reach the code no test compiled and never counted. The Mojo report omits a source with no executable line, so an expected source that
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
//! covered.
//!
//! What is recorded is what the compiler emitted code for, and a function no test reaches emits none. With `--src` (Mojo) the tool reads the
//! source of each expected file too and counts what the reports lack (mojo_src.zig has the rules): the own lines of every function none of whose
//! lines has a record are found and not hit, and so are the two arms of every decision word (`if`, `elif`, `while`, `for`, `and`, `or`) on them
//! when branch records are given. So a test that is deleted can take hits away and leaves the denominator where it was. A source whose first line
//! is exactly `# @generated` (then the end of the line, a space or a tab) is machine-written: it is neither required in a report nor counted (its row, if a report names it, says
//! `(not counted)`). `--uncompiled-lines <file>` writes those lines as a Cobertura report (hits 0), `--uncompiled-branches <file>` those arms
//! as a branch record file, so a consumer that takes the reports and the branch records plus these two files counts what the summary did.
//!
//! Not all of those lines are counted. A function with no record of its own is also what a function looks like that the compiler inlined into its
//! callers, and one whose code sits in a `comptime if` arm dropped on this target; only evidence that a test reached it tells those from an uncalled
//! function (mojo_calls.zig: a hit line outside it that calls it, for an `@always_inline` function's lines and a compile-time arm's lines), or that
//! every use of it is in an arm no report records (mojo_gate.zig: a platform-gated function, all of whose lines go). Those lines and the branch arms
//! on them are in neither the figure nor the two files, and `--uncompiled-report <file>` lists them: `excluded <path> <lines> lines <arms> arms`
//! per source, `excluded total ...`, `gated <path> <function> <def line> <lines> lines` per function, `gated total <n> functions <lines> lines
//! <arms> arms`. Everything else is counted, as it is without that evidence.

const std = @import("std");
const branch_lcov = @import("branch_lcov.zig");
const mojo_src = @import("mojo_src.zig");
const mojo_calls = @import("mojo_calls.zig");
const mojo_gate = @import("mojo_gate.zig");

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
    return branchListingScoped(a, origins, texts, lines, expect, expect.len != 0);
}

/// `branchListing`, `scoped` saying whether `expect` limits the total (see `renderScoped`).
pub fn branchListingScoped(a: std.mem.Allocator, origins: []const []const u8, texts: []const []const u8, lines: []const FileCov, expect: []const []const u8, scoped: bool) !Branch {
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
        .rows => |brows| return .{ .text = try renderScoped(a, brows, expect, "branches ", scoped) },
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
    return renderScoped(a, rows, expect, prefix, expect.len != 0);
}

/// `renderWith`, with `scoped` saying whether `expect` limits the total (an empty `expect` limits it to nothing when every expected source was
/// left out as generated).
pub fn renderScoped(a: std.mem.Allocator, rows: []const FileCov, expect: []const []const u8, prefix: []const u8, scoped: bool) ![]u8 {
    var o = std.ArrayList(u8).empty;
    var hit: usize = 0;
    var total: usize = 0;
    for (rows) |r| {
        const counted = !scoped or isExpected(expect, r.path);
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

fn srcOf(srcs: []const [2][]const u8, path: []const u8) ?[]const u8 {
    for (srcs) |s| {
        if (std.mem.eql(u8, s[0], path)) return s[1];
    }
    return null;
}

/// `expect` without the sources whose first line marks them `@generated` (`srcs`: expected path, then the file to read).
pub fn withoutGenerated(a: std.mem.Allocator, expect: []const []const u8, srcs: []const [2][]const u8, read: *const fn (std.mem.Allocator, []const u8) []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (expect) |e| {
        if (srcOf(srcs, e)) |file| {
            if (mojo_src.isGenerated(read(a, file))) continue;
        }
        try out.append(a, e);
    }
    return out.toOwnedSlice(a);
}

/// Path -> the lines some branch record sits on.
pub const BranchLines = std.StringArrayHashMapUnmanaged(mojo_src.LineSet);

/// The lines of each file that carry a branch record of `sum`.
pub fn branchLines(a: std.mem.Allocator, sum: *const branch_lcov.Sum) !BranchLines {
    var out: BranchLines = .empty;
    var it = sum.files.iterator();
    while (it.next()) |f| {
        const gop = try out.getOrPut(a, f.key_ptr.*);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (f.value_ptr.keys()) |key| {
            const comma = std.mem.indexOfScalar(u8, key, ',') orelse continue;
            const line = std.fmt.parseInt(usize, key[0..comma], 10) catch continue;
            try gop.value_ptr.put(a, line, {});
        }
    }
    return out;
}

/// What the sources hold that no test compiled, as the two files a consumer adds to the reports, and what was left out of them: `listing` is the text
/// (`--uncompiled-report`), `excluded` the sources that had lines or arms left out by the call evidence (sorted by path), `gated` the platform-gated
/// functions (by path, then line; `lines` is the number of their lines the report would have listed) and `gated_arms` the branch arms on their lines.
pub const Uncompiled = struct {
    cobertura: []const u8,
    branches: []const u8,
    listing: []const u8 = "",
    excluded: []const Excluded = &.{},
    gated: []const mojo_gate.Cand = &.{},
    gated_arms: usize = 0,
};

fn xmlEscape(a: std.mem.Allocator, o: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try o.appendSlice(a, "&amp;"),
        '<' => try o.appendSlice(a, "&lt;"),
        '>' => try o.appendSlice(a, "&gt;"),
        '"' => try o.appendSlice(a, "&quot;"),
        '\'' => try o.appendSlice(a, "&apos;"),
        else => try o.append(a, c),
    };
}

/// What `addUncompiled` found for one expected source: the functions no test compiled, which of them are candidates for the platform gate, and the
/// lines the call evidence leaves out (mojo_calls.zig).
const Plan = struct {
    path: []const u8,
    ls: []const mojo_src.Line,
    un: []const mojo_src.Fn,
    by_evidence: mojo_src.LineSet,
    /// For each of `un`, its index in the candidates given to the gate, or null when the evidence covers all its lines.
    cand: []?usize,
};

fn setOf(a: std.mem.Allocator, lines: ?*const Lines, branch_lines: ?*const mojo_src.LineSet) !mojo_src.LineSet {
    var s: mojo_src.LineSet = .empty;
    if (lines) |l| for (l.keys()) |ln| try s.put(a, ln, {});
    if (branch_lines) |bl| for (bl.keys()) |ln| try s.put(a, ln, {});
    return s;
}

/// Adds to `files` (path -> line -> hit) the own lines, as not hit, of every function of each expected source (`srcs`) that no line of `files`
/// and no branch record (`branches`) sits in; returns them as a Cobertura report, with the arms of their decision words as branch records
/// (`with_branches`). A source `files` does not name is left alone: it is in no report, and `missing` refuses it.
///
/// Two kinds of those lines are left out and listed (`Uncompiled.listing`), the rest are counted: the lines of a function a test is seen to
/// reach (mojo_calls.zig: an inlined function's lines, a compile-time arm's), and every line of a platform-gated function (mojo_gate.zig). The
/// evidence is the hit lines of `files`, read before this adds anything, in the package's sources: `srcs` holds the expected sources and may hold
/// more (the package's tests), which are read for calls and never counted.
pub fn addUncompiled(
    a: std.mem.Allocator,
    files: *std.StringArrayHashMapUnmanaged(Lines),
    branches: *const BranchLines,
    with_branches: bool,
    expect: []const []const u8,
    srcs: []const [2][]const u8,
    read: *const fn (std.mem.Allocator, []const u8) []const u8,
) !Uncompiled {
    // The package's sources, and what each file's reports record (before anything is added to `files`).
    var texts = std.ArrayList(mojo_calls.Source).empty;
    var recorded: mojo_gate.Recorded = .empty;
    var ev = mojo_calls.Evidence{};
    for (srcs) |s| {
        const text = read(a, s[1]);
        try texts.append(a, .{ .path = s[0], .text = text });
        const lines: ?*const Lines = files.getPtr(s[0]);
        try recorded.put(a, s[0], try setOf(a, lines, branches.getPtr(s[0])));
        if (lines) |l| {
            var hit: mojo_src.LineSet = .empty;
            for (l.keys(), l.values()) |ln, h| if (h) try hit.put(a, ln, {});
            if (hit.count() != 0) try ev.add(a, s[0], text, &hit);
        }
    }
    const dups = try mojo_calls.declaredTwice(a, texts.items);
    // The functions no test compiled of each expected source named by a report; those the evidence does not cover whole are the gate's candidates.
    var plans = std.ArrayList(Plan).empty;
    var cands = std.ArrayList(mojo_gate.Cand).empty;
    for (expect) |e| {
        const file = srcOf(srcs, e) orelse continue;
        if (!files.contains(e)) continue;
        const text = read(a, file);
        const ls = try mojo_src.lexSource(a, text);
        const rec = recorded.get(e).?;
        const un = try mojo_src.unrecorded(a, try mojo_src.declaredFunctions(a, text), &rec);
        const by_ev = try mojo_calls.unreliableLines(a, text, e, &ev, &dups);
        const idx = try a.alloc(?usize, un.len);
        for (un, idx) |f, *slot| {
            slot.* = null;
            var evidenced = true;
            for (f.lines) |ln| evidenced = evidenced and by_ev.contains(ln);
            if (f.lines.len == 0 or evidenced) continue;
            slot.* = cands.items.len;
            try cands.append(a, .{ .path = e, .name = f.name, .line = f.line, .lines = f.lines.len });
        }
        try plans.append(a, .{ .path = e, .ls = ls, .un = un, .by_evidence = by_ev, .cand = idx });
    }
    const gated = try mojo_gate.platformGated(a, texts.items, &recorded, cands.items);

    var xml = std.ArrayList(u8).empty;
    var lcov = std.ArrayList(u8).empty;
    var left = std.ArrayList(Excluded).empty;
    var gated_fns = std.ArrayList(mojo_gate.Cand).empty;
    var gated_arms: usize = 0;
    try xml.appendSlice(a, "<?xml version=\"1.0\" ?>\n<coverage timestamp=\"0\">\n\t<packages>\n\t\t<package name=\"\">\n\t\t\t<classes>\n");
    for (plans.items) |p| {
        // The lines of the functions the gate dropped, and every line and decision of the uncompiled functions.
        var gated_lines: mojo_src.LineSet = .empty;
        var all = std.ArrayList(usize).empty;
        var decisions = std.ArrayList(mojo_src.Decision).empty;
        for (p.un, p.cand) |f, slot| {
            if (slot) |c| {
                if (gated[c]) {
                    try gated_fns.append(a, cands.items[c]);
                    for (f.lines) |ln| try gated_lines.put(a, ln, {});
                }
            }
            try all.appendSlice(a, f.lines);
            try mojo_src.decisionsOn(a, p.ls, f.lines, &decisions);
        }
        std.mem.sort(usize, all.items, {}, std.sort.asc(usize));
        mojo_src.sortDecisions(decisions.items);
        var out = Excluded{ .path = p.path, .lines = 0, .arms = 0 };
        var kept = std.ArrayList(usize).empty;
        for (all.items) |ln| {
            if (p.by_evidence.contains(ln)) {
                out.lines += 1;
            } else if (!gated_lines.contains(ln)) try kept.append(a, ln);
        }
        var kept_decisions = std.ArrayList(mojo_src.Decision).empty;
        for (decisions.items) |d| {
            if (!with_branches) continue;
            if (p.by_evidence.contains(d.line)) {
                out.arms += 2;
            } else if (gated_lines.contains(d.line)) {
                gated_arms += 2;
            } else try kept_decisions.append(a, d);
        }
        if (out.lines != 0 or out.arms != 0) try left.append(a, out);
        if (kept.items.len != 0) {
            const lines = files.getPtr(p.path).?;
            try xml.appendSlice(a, "\t\t\t\t<class name=\"");
            try xmlEscape(a, &xml, p.path);
            try xml.appendSlice(a, "\" filename=\"");
            try xmlEscape(a, &xml, p.path);
            try xml.appendSlice(a, "\">\n\t\t\t\t\t<lines>\n");
            for (kept.items) |ln| {
                try lines.put(a, ln, false);
                try xml.print(a, "\t\t\t\t\t\t<line number=\"{d}\" hits=\"0\"/>\n", .{ln});
            }
            try xml.appendSlice(a, "\t\t\t\t\t</lines>\n\t\t\t\t</class>\n");
        }
        if (kept_decisions.items.len != 0) {
            try lcov.print(a, "SF:{s}\n", .{p.path});
            for (kept_decisions.items) |d| {
                const kind = if (d.rhs) "rhs" else "br";
                try lcov.print(a, "BRDA:{d},{d}:{s}:0/1,0,-\nBRDA:{d},{d}:{s}:0/1,1,-\n", .{ d.line, d.col, kind, d.line, d.col, kind });
            }
            try lcov.appendSlice(a, "end_of_record\n");
        }
    }
    try xml.appendSlice(a, "\t\t\t</classes>\n\t\t</package>\n\t</packages>\n</coverage>\n");
    return .{
        .cobertura = try xml.toOwnedSlice(a),
        .branches = try lcov.toOwnedSlice(a),
        .listing = try listing(a, left.items, gated_fns.items, gated_arms),
        .excluded = left.items,
        .gated = gated_fns.items,
        .gated_arms = gated_arms,
    };
}

/// The lines and arms of one source that the call evidence left out of the numbers.
pub const Excluded = struct { path: []const u8, lines: usize, arms: usize };

/// The text of what was left out (`--uncompiled-report`): the files with lines or arms the call evidence left out, then their total; the platform-gated
/// functions (every line of one is left out, and the arms on them), then their total. Sorted by path, then by line; always ends in the two totals.
fn listing(a: std.mem.Allocator, left: []Excluded, gated: []mojo_gate.Cand, gated_arms: usize) ![]const u8 {
    std.mem.sort(Excluded, left, {}, struct {
        fn lt(_: void, x: Excluded, y: Excluded) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    std.mem.sort(mojo_gate.Cand, gated, {}, struct {
        fn lt(_: void, x: mojo_gate.Cand, y: mojo_gate.Cand) bool {
            if (!std.mem.eql(u8, x.path, y.path)) return std.mem.lessThan(u8, x.path, y.path);
            return x.line < y.line;
        }
    }.lt);
    var o = std.ArrayList(u8).empty;
    var lines: usize = 0;
    var arms: usize = 0;
    for (left) |l| {
        try o.print(a, "excluded {s} {d} lines {d} arms\n", .{ l.path, l.lines, l.arms });
        lines += l.lines;
        arms += l.arms;
    }
    try o.print(a, "excluded total {d} lines {d} arms\n", .{ lines, arms });
    var glines: usize = 0;
    for (gated) |g| {
        try o.print(a, "gated {s} {s} {d} {d} lines\n", .{ g.path, g.name, g.line, g.lines });
        glines += g.lines;
    }
    try o.print(a, "gated total {d} functions {d} lines {d} arms\n", .{ gated.len, glines, gated_arms });
    return o.toOwnedSlice(a);
}

pub const Found = struct { counted: []const []const u8, unc: Uncompiled };

/// The step of a Mojo summary that follows the reading of the line reports (`files`): the branch records are read first (a function with a
/// branch record on one of its lines was compiled, whatever the line reports say), then the sources left out as generated, then what no test
/// compiled is added to `files`. `error.Refused` is a branch record file that cannot be used (`diag`).
pub fn countUncompiled(
    a: std.mem.Allocator,
    files: *std.StringArrayHashMapUnmanaged(Lines),
    branch_origins: []const []const u8,
    branch_texts: []const []const u8,
    expect: []const []const u8,
    srcs: []const [2][]const u8,
    read: *const fn (std.mem.Allocator, []const u8) []const u8,
    diag: *branch_lcov.Diag,
) branch_lcov.Error!Found {
    var sum = branch_lcov.Sum{};
    for (branch_origins, branch_texts) |o, t| try sum.add(a, diag, t, o);
    const blines = try branchLines(a, &sum);
    const counted = try withoutGenerated(a, expect, srcs, read);
    return .{ .counted = counted, .unc = try addUncompiled(a, files, &blines, branch_origins.len != 0, counted, srcs, read) };
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
    var unc_lines_out: ?[]const u8 = null;
    var unc_branches_out: ?[]const u8 = null;
    var unc_report_out: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, argv[i], "--uncompiled-lines") and i + 1 < argv.len) {
            i += 1;
            unc_lines_out = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--uncompiled-branches") and i + 1 < argv.len) {
            i += 1;
            unc_branches_out = argv[i];
        } else if (std.mem.eql(u8, argv[i], "--uncompiled-report") and i + 1 < argv.len) {
            i += 1;
            unc_report_out = argv[i];
        } else if (argv[i].len > 0 and argv[i][0] == '-') {
            die(2, "unknown option {s}", .{argv[i]});
        } else {
            try reports.append(a, argv[i]);
        }
    }
    if (out_path == null or reports.items.len == 0) die(2, "usage: cov_summary --out <file> [--expect <path>]... [--blocks <file>]... [--branch-lcov <file>]... [--src <path>=<file>]... [--uncompiled-lines <file>] [--uncompiled-branches <file>] [--uncompiled-report <file>] <report.xml>...", .{});
    if (block_reports.items.len != 0 and branch_files.items.len != 0) die(2, "--blocks (Zig) and --branch-lcov (Mojo) are two kinds of branch figure: a package has one", .{});
    var files: std.StringArrayHashMapUnmanaged(Lines) = .empty;
    for (reports.items) |p| {
        const text = std.fs.cwd().readFileAlloc(a, p, 64 << 20) catch |e| die(1, "cannot read {s}: {s}", .{ p, @errorName(e) });
        addReport(a, &files, text) catch die(1, "{s} is not a normalized Cobertura report", .{p});
    }
    const branch_texts = try a.alloc([]const u8, branch_files.items.len);
    for (branch_files.items, branch_texts) |p, *t| t.* = readSource(a, p);
    var diag = branch_lcov.Diag{};
    const found = countUncompiled(a, &files, branch_files.items, branch_texts, expect.items, srcs.items, readSource, &diag) catch |e| switch (e) {
        error.Refused => die(1, "{s}", .{diag.msg}),
        error.OutOfMemory => return e,
    };
    const counted = found.counted;
    const unc = found.unc;
    if (unc_lines_out) |p| std.fs.cwd().writeFile(.{ .sub_path = p, .data = unc.cobertura }) catch |e| die(1, "cannot write {s}: {s}", .{ p, @errorName(e) });
    if (unc_branches_out) |p| std.fs.cwd().writeFile(.{ .sub_path = p, .data = unc.branches }) catch |e| die(1, "cannot write {s}: {s}", .{ p, @errorName(e) });
    if (unc_report_out) |p| std.fs.cwd().writeFile(.{ .sub_path = p, .data = unc.listing }) catch |e| die(1, "cannot write {s}: {s}", .{ p, @errorName(e) });
    const rows = try withEmptySources(a, try summarize(a, &files), counted, srcs.items, readSource);
    if (missing(rows, counted)) |m| die(1, "{s} is in no report: no test compiled it, or kcov could not open it", .{m});
    var text = try renderScoped(a, rows, counted, "", expect.items.len != 0);
    if (block_reports.items.len != 0) {
        var blocks: std.StringArrayHashMapUnmanaged(BlockPositions) = .empty;
        for (block_reports.items) |p| {
            const btext = std.fs.cwd().readFileAlloc(a, p, 64 << 20) catch |e| die(1, "cannot read {s}: {s}", .{ p, @errorName(e) });
            addBlocks(a, &blocks, btext) catch die(1, "{s} is not a block report", .{p});
        }
        const brows = try summarizeBlocks(a, &blocks);
        if (missing(brows, counted)) |m| die(1, "{s} is in no block report: no test compiled it with block counters", .{m});
        text = try std.mem.concat(a, u8, &.{ text, try renderScoped(a, brows, counted, "branches ", expect.items.len != 0) });
    }
    if (branch_files.items.len != 0) {
        // The arms of the decisions no test compiled are one more record file; they join the rest before any count.
        const origins = try std.mem.concat(a, []const u8, &.{ branch_files.items, &.{"uncompiled"} });
        const texts = try std.mem.concat(a, []const u8, &.{ branch_texts, &.{unc.branches} });
        switch (try branchListingScoped(a, origins, texts, rows, counted, expect.items.len != 0)) {
            .refused => |m| die(1, "{s}", .{m}),
            .text => |t| text = try std.mem.concat(a, u8, &.{ text, t }),
        }
    }
    std.fs.cwd().writeFile(.{ .sub_path = out_path.?, .data = text }) catch |e| die(1, "cannot write {s}: {s}", .{ out_path.?, @errorName(e) });
}
