//! mojo_decl: whether a Mojo source declares and nothing else (`hasNoStatements`), which cov_summary uses to tell a file the coverage report left out
//! because it has no executable line from a file with code that no test compiled.
const std = @import("std");

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

/// The result of reading one line of a signature (or a trait header): its brackets are tracked in `depth`; `colon` is the body colon, the first `:`
/// outside every bracket and string, with `rest` the text after it.
const SigEnd = union(enum) { bad, open, colon: []const u8 };

fn sigScan(line: []const u8, depth: *i32) SigEnd {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (quote != 0) {
            if (c == '\\') {
                i += 1;
                if (i >= line.len) return .bad;
            } else if (c == quote) quote = 0;
            continue;
        }
        switch (c) {
            '"', '\'' => {
                if (std.mem.startsWith(u8, line[i..], "\"\"\"") or std.mem.startsWith(u8, line[i..], "'''")) return .bad;
                quote = c;
            },
            '#' => return .open,
            ';', '\\' => return .bad,
            '(', '[', '{' => depth.* += 1,
            ')', ']', '}' => {
                depth.* -= 1;
                if (depth.* < 0) return .bad;
            },
            ':' => if (depth.* == 0) return .{ .colon = line[i + 1 ..] },
            else => {},
        }
    }
    return if (quote == 0) .open else .bad;
}

/// What follows the body colon of a trait member or header: nothing (the block follows), a body that is only `pass`, `...` or a one-line docstring
/// (`done`), or anything else (`bad`: a statement, or a docstring that runs over lines).
const BodyRest = enum { empty, done, bad };

fn tailIsEmpty(t: []const u8) bool {
    const r = std.mem.trim(u8, t, " \t\r");
    return r.len == 0 or r[0] == '#';
}

fn declBody(rest: []const u8) BodyRest {
    const t = std.mem.trim(u8, rest, " \t\r");
    if (tailIsEmpty(t)) return .empty;
    for ([_][]const u8{ "pass", "..." }) |w| {
        if (std.mem.startsWith(u8, t, w) and tailIsEmpty(t[w.len..])) return .done;
    }
    if (std.mem.startsWith(u8, t, "\"\"\"") or std.mem.startsWith(u8, t, "'''")) {
        if (std.mem.indexOf(u8, t[3..], t[0..3])) |at| {
            if (tailIsEmpty(t[3 + at + 3 ..]) and !hasLineBreakChar(t)) return .done;
        }
    }
    return .bad;
}

/// Reads the docstring that begins `line`: a one-line one must be followed by nothing but a comment; one that does not close opens `in_doc`.
fn docLine(line: []const u8, in_doc: *?[]const u8) bool {
    const q = line[0..3];
    if (std.mem.indexOf(u8, line[3..], q)) |at| {
        const rest = line[3 + at + 3 ..];
        return tailIsEmpty(rest) and !hasLineBreakChar(rest);
    }
    in_doc.* = q;
    return true;
}

fn isDocStart(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "\"\"\"") or std.mem.startsWith(u8, line, "'''");
}

/// The state of a `trait` block while `hasNoStatements` reads it. A trait declares: its header (`trait T[...](Bases):`), docstrings, alias
/// declarations (with or without a value), decorators, and methods (`fn` / `def`, the signature over any number of lines) whose body is only
/// `pass`, `...` and docstrings. A method with any other statement in its body is code and makes the file need coverage.
const TraitScan = struct {
    active: bool = false,
    is_header: bool = false, // the header is still being read
    in_sig: bool = false, // inside a signature or header, until its body colon
    depth: i32 = 0, // open brackets of the signature or a decorator
    member_indent: usize = 0, // the indent of the trait's members, 0 until the first one
    sig_indent: usize = 0, // the indent of the method whose block is being read
    need_body: bool = false, // a method's signature ended in `:` and its block follows
    in_body: bool = false, // that block has a statement
    dec: bool = false, // a decorator waits for its method
    adepth: i32 = 0, // open brackets of an alias declaration
    asaw: bool = false,
    acont: bool = false, // the alias line ended with a backslash

    fn start(s: *TraitScan, line: []const u8) bool {
        s.* = .{ .active = true };
        var i: usize = 6;
        while (i < line.len and line[i] == ' ') i += 1;
        const at = i;
        while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) i += 1;
        if (i == at or std.ascii.isDigit(line[at])) return false;
        while (i < line.len and line[i] == ' ') i += 1;
        if (i >= line.len or std.mem.indexOfScalar(u8, "[(:", line[i]) == null) return false;
        s.is_header = true;
        return s.sig(line[i..]);
    }

    /// One line of a signature or header.
    fn sig(s: *TraitScan, line: []const u8) bool {
        s.in_sig = true;
        switch (sigScan(line, &s.depth)) {
            .bad => return false,
            .open => return true,
            .colon => |rest| {
                if (s.depth != 0) return false;
                s.in_sig = false;
                const body = declBody(rest);
                if (body == .bad) return false;
                if (s.is_header) {
                    s.is_header = false;
                    if (body == .done) s.active = false;
                    return true;
                }
                s.need_body = body == .empty;
                s.in_body = false;
                return true;
            },
        }
    }

    fn feed(s: *TraitScan, line: []const u8, indent: usize, in_doc: *?[]const u8) bool {
        if (s.adepth > 0 or s.acont) {
            if (line.len == 0) return false;
            if (!scanExpr(line, &s.adepth, &s.asaw, &s.acont)) return false;
            return true;
        }
        if (s.in_sig) return s.sig(line);
        if (s.need_body) {
            if (indent > s.sig_indent) {
                if (isDocStart(line)) {
                    s.in_body = true;
                    return docLine(line, in_doc);
                }
                const body = declBody(line);
                if (body != .done or isDocStart(line)) return false;
                s.in_body = true;
                return true;
            }
            if (!s.in_body) return false;
            s.need_body = false;
        }
        if (s.member_indent == 0) s.member_indent = indent;
        if (indent != s.member_indent) return false;
        if (isDocStart(line)) return docLine(line, in_doc);
        if (line[0] == '@') {
            s.dec = true;
            var d: i32 = 0;
            return switch (sigScan(line, &d)) {
                .open => d == 0,
                else => false,
            };
        }
        if (std.mem.startsWith(u8, line, "fn ") or std.mem.startsWith(u8, line, "def ")) {
            s.dec = false;
            s.sig_indent = indent;
            s.depth = 0;
            return s.sig(line);
        }
        if (s.dec) return false;
        if (std.mem.startsWith(u8, line, "alias ") or std.mem.startsWith(u8, line, "comptime ")) {
            const tail = aliasTail(line) orelse return false;
            s.asaw = false;
            return scanExpr(tail, &s.adepth, &s.asaw, &s.acont);
        }
        return false;
    }

    /// Whether the trait ended well: members read, no signature, alias, decorator or block left open.
    fn finish(s: *const TraitScan) bool {
        if (s.in_sig or s.adepth != 0 or s.acont or s.dec or s.member_indent == 0) return false;
        return !s.need_body or s.in_body;
    }
};

/// Whether a Mojo source has no executable line: only blank lines, comments, docstrings (a triple-quoted string on its own lines), top-level
/// `from ... import ...` / `import ...` statements (a re-export file, `__init__.mojo`), top-level alias declarations (`alias` or `comptime NAME = ...`,
/// with an annotation or a parameter list, the value running over several lines inside brackets or after a backslash) and `trait` blocks that only
/// declare (`TraitScan`: methods whose body is `pass`, `...` or a docstring), which emit no code. The Mojo
/// coverage report omits such a file, and so it does a file with code that no test compiled; this is what tells them apart, so it is strict: any other
/// statement (a function, a struct, a `var`, a `comptime if` / `for` / `assert`), a `;`, an indented line outside a continuation, or an unclosed
/// docstring or bracket makes it false.
pub fn hasNoStatements(text: []const u8) bool {
    var in_doc: ?[]const u8 = null; // the closing triple quote while inside a docstring
    var depth: i32 = 0; // open parentheses of an import, or brackets of an alias
    var cont = false; // the previous import or alias line ended with a backslash
    var in_alias = false; // inside an alias declaration that runs over more lines
    var saw_eq = false; // the alias declaration has its `=`
    var ts = TraitScan{}; // the trait block being read, if any
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
        if (ts.active) {
            if (line.len == 0 and ts.acont) return false;
            if (line.len == 0 or (line[0] == '#' and !ts.acont)) continue;
            var indent: usize = 0;
            while (indent < raw.len and (raw[indent] == ' ' or raw[indent] == '\t')) indent += 1;
            if (ts.in_sig or ts.adepth > 0 or ts.acont or indent > 0) {
                if (!ts.feed(line, indent, &in_doc)) return false;
                continue;
            }
            if (!ts.finish()) return false;
            ts.active = false;
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
        if (std.mem.startsWith(u8, line, "trait ")) {
            if (!ts.start(line)) return false;
            continue;
        }
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
    if (ts.active and !ts.finish()) return false;
    return in_doc == null and depth == 0 and !cont;
}

