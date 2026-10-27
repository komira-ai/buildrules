//! cov_unmeasured: the sources of a package that kcov cannot record, named in the package's committed `coverage_unmeasured.txt` (cov_summary --unmeasured).
//!
//! A Mojo source whose functions are all `@always_inline("nodebug")` (behind a `comptime if`, say) has no line in any report although the tests run it, and
//! cov_summary refuses a source that is in no report. Counting it 0/0 would say nothing was there; this file is the explicit way out: a source listed in it
//! with its reason is accepted when no report names it, printed as `unmeasured: <path>: <reason>`, and left out of the line and branch totals and floors.
//!
//! The file: one entry per line, `<source path relative to the package>`, then a TAB or two spaces, then the reason (not empty). A blank line and a line
//! whose first character is `#` are skipped. Refused, with the line or the path named: a line with no reason, a path listed twice, a path that is not a
//! library source of the package (no such file, or a test or another file), a path some report names ("listed as unmeasured but measured: remove the entry":
//! the entry went stale when the tool began recording it), and a source with no statement at all (a re-export file, which `:coverage` lists 0/0 already), a path starting with `/`, and a source
//! that kcov can record. A source is accepted only if every function or method it defines is `@always_inline("nodebug")` and it defines one, and outside the bodies of those
//! functions it holds nothing but declarations (`strictScan`): no `;` and no backslash outside a string or comment anywhere; each statement outside a body is exactly one of an
//! import, an `alias` / `comptime` constant with no `(` in it, a `struct` / `trait` header with nothing after its colon, a field `var NAME: Type` with no initializer, a decorator
//! (`@always_inline("nodebug")`, `@fieldwise_init`, `@value`, `@register_passable`, `@deprecated`), a docstring, a `def` / `fn` whose whole body is `...`, or `pass`, and anything else is
//! refused naming its line. In a nodebug function the words `fn`, `def` and `lambda` are refused unless the `def` starts a nested nodebug function the lister (mojo_src) also found. A
//! `@fieldwise_init` or `@value` struct is accepted: its synthesized methods have no source line for kcov to record. Fail-closed: a source that only looks like a declaration is refused.
//! The first TAB or two-space run splits the line, whichever comes first, so a TAB inside the reason stays in it.

const std = @import("std");
const mojo_src = @import("mojo_src.zig");

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
        // The first separator of either kind ends the path: a TAB inside the reason stays in the reason.
        const tab = std.mem.indexOfScalar(u8, line, '\t');
        const sp2 = std.mem.indexOf(u8, line, "  ");
        const cut = (if (tab != null and sp2 != null) @min(tab.?, sp2.?) else tab orelse sp2) orelse
            return .{ .refused = try std.fmt.allocPrint(a, "{s}:{d}: `{s}` has no reason: write `<source path>`, a TAB or two spaces, and why kcov cannot record it", .{ name, n, line }) };
        const path = std.mem.trimEnd(u8, line[0..cut], " \t");
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
        if (e.path[0] == '/') return .{ .refused = try std.fmt.allocPrint(a, "{s}: {s} is an absolute path: write it relative to the package", .{ name, e.path }) };
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

/// Why the source `text` of an entry is not unrecordable, or null when every function it defines is `@always_inline("nodebug")` (other decorators may
/// stand beside it) and it defines one: the first function that is not, or a file with no function at all, is the refusal.
fn recordable(a: std.mem.Allocator, name: []const u8, path: []const u8, text: []const u8) !?[]const u8 {
    const fns = try mojo_src.declaredFunctions(a, text);
    for (fns) |f| {
        if (!f.nodebug) return try std.fmt.allocPrint(a, "{s}: {s} listed as unmeasured but {s} at line {d} is not @always_inline(\"nodebug\"): kcov can record it; test it instead", .{ name, path, f.name, f.line });
    }
    if (fns.len == 0) return try std.fmt.allocPrint(a, "{s}: {s} listed as unmeasured but it defines no @always_inline(\"nodebug\") function: kcov can record it; test it instead", .{ name, path });
    if (try strictScan(a, text, fns)) |s| {
        return try std.fmt.allocPrint(a, "{s}: {s} listed as unmeasured but line {d} {s}: kcov can record it; test it instead", .{ name, path, s.line, s.what });
    }
    return null;
}

const Stray = struct { line: usize, what: []const u8 };

/// One logical statement of a source: brackets joined, comments gone. `raw` keeps the string literals; `col` has each literal collapsed to one `"`, so
/// a word found in it is code. `line` is the first physical line (1-based), `indent` the count of leading blanks of it.
const Stmt = struct { line: usize, indent: usize, raw: []const u8, col: []const u8 };

const Split = union(enum) { stmts: []const Stmt, stray: Stray };

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Whether the word `w` stands in `code` between non-identifier bytes.
fn hasWord(code: []const u8, w: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, code, from, w)) |at| : (from = at + 1) {
        const before = at == 0 or !isIdentByte(code[at - 1]);
        const after = at + w.len >= code.len or !isIdentByte(code[at + w.len]);
        if (before and after) return true;
    }
    return false;
}

fn startsWord(code: []const u8, w: []const u8) bool {
    return std.mem.startsWith(u8, code, w) and (code.len == w.len or !isIdentByte(code[w.len]));
}

/// Whether `code` makes or names a function value: the word `fn`, `def` or `lambda`.
fn functionWord(code: []const u8) bool {
    return hasWord(code, "fn") or hasWord(code, "def") or hasWord(code, "lambda");
}

fn bad(line: usize, what: []const u8) Split {
    return .{ .stray = .{ .line = line, .what = what } };
}

/// Splits `text_in` into logical statements. A `;` or a backslash outside a string and a comment, anywhere in the file, is the refusal (a second statement on
/// a line, or a line the lexer of the lister would read differently), as is a string or a bracket that never closes.
fn splitStatements(a: std.mem.Allocator, text_in: []const u8) !Split {
    var text = text_in;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];
    var out = std.ArrayList(Stmt).empty;
    var raw = std.ArrayList(u8).empty;
    var col = std.ArrayList(u8).empty;
    var quote: u8 = 0;
    var triple = false;
    var depth: i32 = 0;
    var open = false;
    var start: usize = 0;
    var indent: usize = 0;
    var lineno: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |phys| {
        lineno += 1;
        const ln = std.mem.trimRight(u8, phys, "\r");
        var i: usize = 0;
        var escaped_end = false;
        while (i < ln.len) {
            const c = ln[i];
            if (quote != 0) {
                try raw.append(a, c);
                if (c == '\\') {
                    if (i + 1 < ln.len) try raw.append(a, ln[i + 1]) else escaped_end = true;
                    i += 2;
                    continue;
                }
                if (c == quote) {
                    if (!triple) {
                        quote = 0;
                        try col.append(a, '"');
                    } else if (i + 2 < ln.len and ln[i + 1] == c and ln[i + 2] == c) {
                        try raw.appendSlice(a, ln[i + 1 .. i + 3]);
                        quote = 0;
                        triple = false;
                        try col.append(a, '"');
                        i += 3;
                        continue;
                    }
                }
                i += 1;
                continue;
            }
            if (c == '#') break;
            if (c == ';') return bad(lineno, "has a `;`");
            if (c == '\\') return bad(lineno, "continues with a backslash or has one outside a string");
            if (c == ' ' or c == '\t') {
                if (open) {
                    try raw.append(a, ' ');
                    try col.append(a, ' ');
                }
                i += 1;
                continue;
            }
            if (!open) {
                open = true;
                start = lineno;
                indent = std.mem.indexOfNone(u8, ln, " \t") orelse 0;
            }
            if (c == '"' or c == '\'') {
                quote = c;
                triple = i + 2 < ln.len and ln[i + 1] == c and ln[i + 2] == c;
                const n: usize = if (triple) 3 else 1;
                try raw.appendSlice(a, ln[i .. i + n]);
                i += n;
                continue;
            }
            switch (c) {
                '(', '[', '{' => depth += 1,
                ')', ']', '}' => depth -= 1,
                else => {},
            }
            if (depth < 0) return bad(lineno, "closes a bracket that was not open");
            try raw.append(a, c);
            try col.append(a, c);
            i += 1;
        }
        if (quote != 0 and !triple and !escaped_end) return bad(lineno, "has a string that does not end on its line");
        if (open) {
            try raw.append(a, ' ');
            try col.append(a, ' ');
        }
        if (open and quote == 0 and depth == 0) {
            try out.append(a, .{
                .line = start,
                .indent = indent,
                .raw = std.mem.trim(u8, try raw.toOwnedSlice(a), " "),
                .col = std.mem.trim(u8, try col.toOwnedSlice(a), " "),
            });
            raw = std.ArrayList(u8).empty;
            col = std.ArrayList(u8).empty;
            open = false;
        }
    }
    if (open) return bad(start, "starts a string or a bracket that never closes");
    return .{ .stmts = try out.toOwnedSlice(a) };
}

const Deco = enum { nodebug, listed, other };

fn squeeze(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var o = std.ArrayList(u8).empty;
    for (s) |c| if (c != ' ' and c != '\t') try o.append(a, c);
    return o.toOwnedSlice(a);
}

/// A decorator line: `@always_inline("nodebug")` (double quotes, blanks anywhere: the lister reads only that spelling), or one of `@fieldwise_init`, `@value`,
/// `@register_passable` and `@deprecated` (each with at most one string literal argument for the last two). Any other is `.other`.
fn decorator(a: std.mem.Allocator, s: Stmt) !Deco {
    const r = try squeeze(a, s.raw);
    if (std.mem.eql(u8, r, "@always_inline(\"nodebug\")")) return .nodebug;
    const c = try squeeze(a, s.col);
    for ([_][]const u8{ "@fieldwise_init", "@value", "@register_passable", "@register_passable(\")", "@deprecated", "@deprecated(\")" }) |ok| {
        if (std.mem.eql(u8, c, ok)) return .listed;
    }
    return .other;
}

fn isHeader(c: []const u8) bool {
    return startsWord(c, "def") or startsWord(c, "fn");
}

/// The byte offset of the first `:` of `c` outside every bracket, or null.
fn colonAt(c: []const u8) ?usize {
    var d: i32 = 0;
    for (c, 0..) |ch, i| switch (ch) {
        '(', '[', '{' => d += 1,
        ')', ']', '}' => d -= 1,
        ':' => if (d == 0) return i,
        else => {},
    };
    return null;
}

/// Whether the function whose header is `ss[i]` has `...` and nothing else for a body: after its colon on the line, or alone on the next statement.
fn bodyIsEllipsis(ss: []const Stmt, i: usize) bool {
    const c = ss[i].col;
    const at = colonAt(c) orelse return false;
    const rest = std.mem.trim(u8, c[at + 1 ..], " ");
    if (rest.len > 0) return std.mem.eql(u8, rest, "...");
    if (i + 1 >= ss.len or ss[i + 1].indent <= ss[i].indent or !std.mem.eql(u8, ss[i + 1].col, "...")) return false;
    return i + 2 >= ss.len or ss[i + 2].indent <= ss[i].indent;
}

fn listerHas(fns: []const mojo_src.Fn, line: usize) bool {
    for (fns) |f| if (f.line == line and f.nodebug) return true;
    return false;
}

fn isName(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| if (!isIdentByte(c)) return false;
    return true;
}

/// `alias NAME = expr`, `alias NAME: Type = expr`, the same with `comptime`: no call (no `(`), no function word, and `NAME` is not a keyword of a block.
fn constantDecl(c: []const u8) bool {
    const w: []const u8 = if (startsWord(c, "alias")) "alias" else if (startsWord(c, "comptime")) "comptime" else return false;
    const rest = std.mem.trimLeft(u8, c[w.len..], " ");
    var e: usize = 0;
    while (e < rest.len and isIdentByte(rest[e])) e += 1;
    const name = rest[0..e];
    if (!isName(name)) return false;
    for ([_][]const u8{ "if", "elif", "else", "for", "while", "assert", "try", "with" }) |k| if (std.mem.eql(u8, name, k)) return false;
    const after = std.mem.trimLeft(u8, rest[e..], " ");
    if (after.len == 0 or (after[0] != '=' and after[0] != ':')) return false;
    if (std.mem.indexOfScalar(u8, c, '(') != null or functionWord(c)) return false;
    return std.mem.indexOfScalar(u8, after, '=') != null;
}

fn importDecl(c: []const u8) bool {
    return startsWord(c, "import") or startsWord(c, "from");
}

/// `struct` or `trait`, a header whose first colon outside brackets is its last byte and which names no function value.
fn blockHeader(c: []const u8) bool {
    if (!startsWord(c, "struct") and !startsWord(c, "trait")) return false;
    const at = colonAt(c) orelse return false;
    return at + 1 == c.len and !functionWord(c);
}

/// `var NAME: Type` with no initializer, no call and no function word.
fn fieldDecl(c: []const u8) bool {
    if (!startsWord(c, "var")) return false;
    const rest = std.mem.trimLeft(u8, c[3..], " ");
    var e: usize = 0;
    while (e < rest.len and isIdentByte(rest[e])) e += 1;
    if (!isName(rest[0..e])) return false;
    const after = std.mem.trimLeft(u8, rest[e..], " ");
    if (after.len == 0 or after[0] != ':') return false;
    return std.mem.indexOfAny(u8, c, "=(") == null and !functionWord(c);
}

const what_decl = "is not one of the declarations a nodebug-only source may hold outside its functions (import, alias or comptime constant without a call, struct or trait header, field without a value, listed decorator, docstring, bodiless def, pass)";

/// The first statement of `text` that the strict rule refuses, or null. The rule, outside the body of every `@always_inline("nodebug")` function: no `;`
/// and no backslash anywhere; each statement is exactly one of an import, an `alias` / `comptime` constant without a call, a `struct` / `trait` header with
/// nothing after its colon, a field `var NAME: Type` with no initializer, a decorator of `decorator`, a docstring (a string literal alone), a `def` / `fn`
/// whose whole body is `...`, or `pass`; nothing else. In a body (the lines of the function after its header, and the header's own line after its
/// signature), the words `fn`, `def` and `lambda` are refused unless the `def` starts a nested nodebug function the lister (`fns`) also found.
fn strictScan(a: std.mem.Allocator, text: []const u8, fns: []const mojo_src.Fn) !?Stray {
    const ss = switch (try splitStatements(a, text)) {
        .stmts => |s| s,
        .stray => |s| return s,
    };
    var body_indent: ?usize = null;
    var pending = false;
    var i: usize = 0;
    while (i < ss.len) : (i += 1) {
        const s = ss[i];
        const c = s.col;
        if (body_indent) |bi| {
            if (s.indent > bi) {
                if (c[0] == '@') {
                    if (try decorator(a, s) == .nodebug) pending = true;
                    continue;
                }
                const was = pending;
                pending = false;
                if (isHeader(c)) {
                    const kw: usize = if (startsWord(c, "def")) 3 else 2;
                    if (was and !functionWord(c[kw..]) and (bodyIsEllipsis(ss, i) or listerHas(fns, s.line))) continue;
                    return .{ .line = s.line, .what = "defines a function inside a nodebug function that is not itself nodebug and listed" };
                }
                if (functionWord(c)) return .{ .line = s.line, .what = "makes a function value inside a nodebug function" };
                continue;
            }
            body_indent = null;
            pending = false;
        }
        if (c[0] == '@') {
            switch (try decorator(a, s)) {
                .nodebug => pending = true,
                .listed => {},
                .other => return .{ .line = s.line, .what = "has a decorator outside the list a nodebug-only source may hold" },
            }
            continue;
        }
        const was = pending;
        pending = false;
        if (isHeader(c)) {
            const kw: usize = if (startsWord(c, "def")) 3 else 2;
            if (functionWord(c[kw..])) return .{ .line = s.line, .what = "makes a function value in a function header" };
            if (bodyIsEllipsis(ss, i)) {
                if (colonAt(c)) |at| {
                    if (std.mem.trim(u8, c[at + 1 ..], " ").len == 0) i += 1;
                }
                continue;
            }
            if (was and listerHas(fns, s.line)) {
                body_indent = s.indent;
                continue;
            }
            return .{ .line = s.line, .what = "defines a function that is not an @always_inline(\"nodebug\") one the lister found" };
        }
        if (importDecl(c) or constantDecl(c) or blockHeader(c) or fieldDecl(c)) continue;
        if (std.mem.eql(u8, c, "\"") or std.mem.eql(u8, c, "pass")) continue;
        return .{ .line = s.line, .what = what_decl };
    }
    return null;
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
        .entries => |es| {
            const r = try resolve(a, name, es, root, expect, reported, empty.items);
            if (r == .refused) return r;
            for (es) |e| {
                const repo = if (root.len == 0) e.path else try std.fs.path.join(a, &.{ root, e.path });
                for (srcs) |s| {
                    if (!std.mem.eql(u8, s[0], repo)) continue;
                    if (try recordable(a, name, e.path, read(a, s[1]))) |m| return .{ .refused = m };
                }
            }
            return r;
        },
    };
}
