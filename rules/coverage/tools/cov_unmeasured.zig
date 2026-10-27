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
//! that kcov can record: every function or method it defines must be `@always_inline("nodebug")` (other decorators may stand beside it), and it must define one.
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
    const ls = try mojo_src.lexSource(a, text);
    if (try strayLine(a, ls, fns)) |s| {
        return try std.fmt.allocPrint(a, "{s}: {s} listed as unmeasured but line {d} {s}: kcov can record it; test it instead", .{ name, path, s.line, s.what });
    }
    return null;
}

const Stray = struct { line: usize, what: []const u8 };

fn isIdentByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn codeText(l: mojo_src.Line) []const u8 {
    const t = if (l.comment) |c| l.text[0..c] else l.text;
    return std.mem.trim(u8, t, " \t\r");
}

/// Whether the word `w` stands in `code` between non-identifier bytes (inside a string too: the scan errs toward refusing).
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

/// Whether `code`, a statement outside every function, only declares: a decorator, a `struct` or `trait` header, a field, an `alias` or a `comptime`
/// constant (not a `comptime if` / `for` / `while` block, which is code), a docstring or a bare string.
fn declares(code: []const u8) bool {
    if (code[0] == '@' or code[0] == '"' or code[0] == '\'') return true;
    for ([_][]const u8{ "struct", "trait", "var", "alias" }) |w| if (startsWord(code, w)) return true;
    // A `def` that mojo_src.declaredFunctions did not list has no body or `...` alone for one (a requirement of a trait): it is a declaration.
    if (std.mem.eql(u8, code, "...") or std.mem.startsWith(u8, code, "def ") or std.mem.startsWith(u8, code, "fn ")) return true;
    if (startsWord(code, "comptime")) {
        const rest = std.mem.trimLeft(u8, code["comptime".len..], " \t");
        for ([_][]const u8{ "if", "elif", "else", "for", "while", "assert" }) |w| if (startsWord(rest, w)) return false;
        return true;
    }
    return false;
}

/// The first line that is code the report could count and that is not in the body of a nodebug function: a statement outside every function (the
/// declarations of `declares` and imports are not), or in a nodebug body a function value (`fn`, `def` or `lambda` that does not start a declared
/// function of its own). Null when there is none.
fn strayLine(a: std.mem.Allocator, ls: []const mojo_src.Line, fns: []const mojo_src.Fn) !?Stray {
    var depth: i32 = 0;
    var cont = false;
    var sig_depth: i32 = 0;
    for (ls, 0..) |l, i| {
        const n = i + 1;
        if (!l.code or l.in_string) continue;
        const code = codeText(l);
        if (code.len == 0) continue;
        var owner: ?mojo_src.Fn = null;
        var is_def = false;
        for (fns) |f| {
            if (f.line == n) is_def = true;
            if (n >= f.line and n <= f.end) owner = f;
        }
        if (owner) |f| {
            // Past the signature of the function (a nested declared function has its own checks), its code may not make a function value.
            if (f.line == n) sig_depth = 0;
            if (is_def) {
                sig_depth = l.opens - l.closes + l.brackets;
            } else if (sig_depth > 0) {
                sig_depth += l.opens - l.closes + l.brackets;
            } else if (hasWord(code, "fn") or hasWord(code, "def") or hasWord(code, "lambda")) {
                return .{ .line = n, .what = try a.dupe(u8, "makes a function value inside a function, which may be run without a record") };
            }
            continue;
        }
        const inside = depth > 0 or cont;
        depth += l.opens - l.closes + l.brackets;
        cont = l.continued;
        if (inside or l.is_import and !l.tail_code) continue;
        if (!declares(code)) return .{ .line = n, .what = try a.dupe(u8, "is a statement outside every @always_inline(\"nodebug\") function") };
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
