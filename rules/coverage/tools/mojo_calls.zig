//! mojo_calls: the call evidence that leaves part of the code no test compiled out of the numbers (cov_summary's uncompiled report).
//!
//! A function with no line of its own in any report reads as uncompiled. Three different things look like that: a function nobody calls, a function
//! the compiler inlined into its callers (a test calls it, and what is left of it is attributed to a caller's line), and a function whose code is in a
//! `comptime if` arm dropped on this platform. The first is uncovered code; the other two are not. They are told apart only by evidence that a test
//! reached the function, so a line is left out of the numbers only with it (the full-source checker's rule, its uncompiled.mojo:1-28):
//!
//! * an `@always_inline` function: every own line, when a line outside it that calls it was hit in a test's report;
//! * a function with compile-time arms: the lines inside those arms, on the same evidence; the lines outside the arms are counted.
//!
//! Anything else is counted, as it is without this report: a plain function, a gated function no test calls, an inlined function no test calls, and
//! a nested closure by its own class (never its outer function's).
//!
//! What is **a call**: an identifier of the code of a hit line followed by `(` or `[`; `name` for a bare call of a free function, `.name` for a method
//! call, and `Receiver.name` where the receiver is an identifier (`T.name(`, `x.name(`) or the identifier before the `(` of a call (`T(a).name(`)
//! (the full-source checker's uncompiled.mojo:114-161). A comment and the inside of a quoted string are not code; a declaration (`def` / `fn` first on the line)
//! calls nothing, so `def f(` is no evidence that `f` is called (:122-127). **A test-hit line** is a line some test's report records with hits above 0;
//! a line that starts inside a string or holds no code is no call (:183-191). The evidence is per package: only the hit lines of the files given
//! as sources, which are the package's own library and tests, count; a call from a file whose text is not given is none.
//!
//! **Whom a call is evidence for** (the full-source checker's uncompiled.mojo:298-337), counting when in doubt:
//! * a method (a function indented under a `struct`) only by a call that names its declaring type as the receiver: `T(x).m(` or `T.m(`; any other
//!   receiver, an unknown one included, is none;
//! * a free function only by a hit call `f(` in the same file, or in a file whose import lines mention the name or the module (the file name without
//!   `.mojo`); and not at all when the package declares the name more than once (a call could be either).

const std = @import("std");
const src = @import("mojo_src.zig");
const Alloc = std.mem.Allocator;

/// A source file of the package: its repository path and its text.
pub const Source = struct { path: []const u8, text: []const u8 };

/// A set of strings.
pub const Keys = std.StringArrayHashMapUnmanaged(void);

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn startsWord(line: []const u8, at: usize, word: []const u8) bool {
    if (at + word.len >= line.len) return false;
    if (!std.mem.eql(u8, line[at .. at + word.len], word)) return false;
    return line[at + word.len] == ' ' or line[at + word.len] == '\t';
}

fn indentOf(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return i;
}

/// The name a call's receiver ends in, before the `.` at `dot`: an identifier, or the identifier before the `(` of a call (`T(a).name(`); empty when
/// it is neither (the full-source checker's uncompiled.mojo:80-111).
fn receiverBefore(line: []const u8, dot: usize) []const u8 {
    if (dot == 0) return "";
    const j = dot - 1;
    var e: usize = undefined;
    if (line[j] == ')') {
        var depth: i32 = 0;
        var p: isize = @intCast(j);
        while (p >= 0) : (p -= 1) {
            const c = line[@intCast(p)];
            if (c == ')') {
                depth += 1;
            } else if (c == '(') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (p <= 0) return "";
        e = @intCast(p);
    } else if (isIdent(line[j])) {
        e = j + 1;
    } else return "";
    var s = e;
    while (s > 0 and isIdent(line[s - 1])) s -= 1;
    if (s >= e) return "";
    return line[s..e];
}

/// Adds to `into` each call the code of `line` makes (see the header): `name`, `.name`, and `Receiver.name`.
pub fn callKeys(a: Alloc, line: []const u8, into: *Keys) !void {
    const n = line.len;
    const first = indentOf(line);
    if (startsWord(line, first, "def") or startsWord(line, first, "fn")) return;
    var quote: u8 = 0;
    var i: usize = 0;
    var start: ?usize = null;
    while (i < n) {
        const c = line[i];
        if (quote != 0) {
            if (c == '\\') {
                i += 2;
                continue;
            }
            if (c == quote) quote = 0;
            i += 1;
            continue;
        }
        if (c == '#') break;
        if (c == '"' or c == '\'') {
            quote = c;
            start = null;
            i += 1;
            continue;
        }
        if (isIdent(c)) {
            if (start == null) start = i;
        } else {
            if (start) |s| {
                if (c == '(' or c == '[') {
                    // `.name(` is a method call, a bare `name(` a call of a free function.
                    const dotted = s > 0 and line[s - 1] == '.';
                    const name = line[s..i];
                    try into.put(a, if (dotted) try std.fmt.allocPrint(a, ".{s}", .{name}) else name, {});
                    if (dotted) {
                        const recv = receiverBefore(line, s - 1);
                        if (recv.len > 0) try into.put(a, try std.fmt.allocPrint(a, "{s}.{s}", .{ recv, name }), {});
                    }
                }
            }
            start = null;
        }
        i += 1;
    }
}

/// What the hit lines of a package say about calls: `callers` maps a call key to the files with a hit line that makes it, `imports` a file to the
/// identifiers of its import lines (the full-source checker's uncompiled.mojo:245-286).
pub const Evidence = struct {
    callers: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
    imports: std.StringArrayHashMapUnmanaged(Keys) = .empty,

    /// Records the calls the lines of `text` (file `path`) in `hit` make, and its imports.
    pub fn add(self: *Evidence, a: Alloc, path: []const u8, text: []const u8, hit: *const src.LineSet) !void {
        const ls = try src.lexSource(a, text);
        var keys: Keys = .empty;
        for (hit.keys()) |ln| {
            if (ln < 1 or ln > ls.len) continue;
            const l = ls[ln - 1];
            if (l.in_string or !l.code) continue;
            try callKeys(a, l.text, &keys);
        }
        for (keys.keys()) |k| {
            const gop = try self.callers.getOrPut(a, k);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (gop.value_ptr.items) |p| {
                if (std.mem.eql(u8, p, path)) break;
            } else try gop.value_ptr.append(a, path);
        }
        var toks: Keys = .empty;
        for (ls) |l| {
            if (!l.is_import) continue;
            var start: ?usize = null;
            var p: usize = 0;
            while (p <= l.text.len) : (p += 1) {
                if (p < l.text.len and isIdent(l.text[p])) {
                    if (start == null) start = p;
                } else {
                    if (start) |s| try toks.put(a, l.text[s..p], {});
                    start = null;
                }
            }
        }
        try self.imports.put(a, path, toks);
    }
};

/// The names the sources declare more than once among them: a call of such a name is not told from a call of another function of it, so the name is
/// no evidence for any (the full-source checker's uncompiled.mojo:194-206).
pub fn declaredTwice(a: Alloc, texts: []const Source) !Keys {
    var seen = std.StringArrayHashMapUnmanaged(usize).empty;
    for (texts) |t| {
        for (try src.declaredFunctions(a, t.text)) |f| {
            const gop = try seen.getOrPut(a, f.name);
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        }
    }
    var out: Keys = .empty;
    for (seen.keys(), seen.values()) |k, v| {
        if (v > 1) try out.put(a, k, {});
    }
    return out;
}

/// The name of the `struct` a method declared at `def_line` (1-based) sits in, or empty: the nearest line above it that starts with `struct` and is
/// indented less (the full-source checker's uncompiled.mojo:209-228).
fn structOf(lines: []const src.Line, def_line: usize) []const u8 {
    const ind = indentOf(lines[def_line - 1].text);
    var i: isize = @as(isize, @intCast(def_line)) - 2;
    while (i >= 0) : (i -= 1) {
        const t = lines[@intCast(i)].text;
        const k = indentOf(t);
        if (k < ind and k < t.len and startsWord(t, k, "struct")) {
            const s = k + 7;
            var e = s;
            while (e < t.len and isIdent(t[e])) e += 1;
            return t[s..e];
        }
    }
    return "";
}

/// The file name of `path` without `.mojo`: the module a `from pkg.module import` names.
fn moduleOf(path: []const u8) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, path, '/')) |s| path[s + 1 ..] else path;
    return if (std.mem.endsWith(u8, base, ".mojo")) base[0 .. base.len - 5] else base;
}

/// The lines of `text` (file `path`) an uncompiled report may not count: the own lines of an `@always_inline` function, the lines in the arms of a
/// function with compile-time arms, each only with evidence (`ev`, `dups`: the names the package declares more than once).
pub fn unreliableLines(a: Alloc, text: []const u8, path: []const u8, ev: *const Evidence, dups: *const Keys) !src.LineSet {
    var out: src.LineSet = .empty;
    const ls = try src.lexSource(a, text);
    for (try src.declaredFunctions(a, text)) |f| {
        const method = f.line >= 1 and f.line <= ls.len and indentOf(ls[f.line - 1].text) > 0;
        var ok = false;
        if (method) {
            const owner = structOf(ls, f.line);
            if (owner.len > 0) ok = ev.callers.contains(try std.fmt.allocPrint(a, "{s}.{s}", .{ owner, f.name }));
        } else if (!dups.contains(f.name)) {
            if (ev.callers.get(f.name)) |callers| {
                for (callers.items) |caller| {
                    if (std.mem.eql(u8, caller, path)) {
                        ok = true;
                    } else if (ev.imports.get(caller)) |imp| {
                        if (imp.contains(f.name) or imp.contains(moduleOf(path))) ok = true;
                    }
                }
            }
        }
        if (!ok) continue;
        switch (f.kind) {
            .always_inline => for (f.lines) |ln| try out.put(a, ln, {}),
            .comptime_if => for (f.arms) |ln| try out.put(a, ln, {}),
            .plain => {},
        }
    }
    return out;
}
