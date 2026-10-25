//! mojo_src: what a Mojo source says about the code no test compiled (cov_summary's uncompiled lines and decisions).
//!
//! A Mojo compiler emits a function only when something the test reaches calls it, so a function no test calls has no line in kcov's report and
//! no branch in the IR, and a figure counted from the reports alone drops those lines when a test is deleted. This module reads the source
//! instead: the functions it declares, the lines of each that hold code, and the words of those lines that make a decision. The rules are the
//! ones of covcheck, the full-source coverage checker this rule set replaced (its lexer's executable lines, its declaration reader's functions):
//!
//! * **Lexing.** A line is read once, with the string state of the lines before it: `"..."` and `'...'` end at the same quote or at the line end
//!   (a backslash as the last byte continues them), triple-quoted strings span lines, a backslash keeps the next byte from closing a string, one
//!   or two of the letters `r b f u t` right before a quote (not after an identifier byte) belong to the string, the first `#` outside every
//!   string starts a comment, a trailing carriage return and a leading byte-order mark are dropped. A line holds **code** when it has a byte
//!   outside every string and its comment other than a space, a tab or a form feed.
//! * **Executable lines**: lines holding code that are not part of an import (`import x`, `from x import y`, a parenthesised list over lines,
//!   or a backslash continuation), plus an import line with a statement that is not an import after a `;`.
//! * **A function** is a line holding code, not starting inside a string, whose first word is `def` or `fn` followed by a space or tab. Its
//!   signature runs to the line at which the brackets it opened are closed; the body is the one-line text after the signature's `:`, or every
//!   following line up to the first code line indented no deeper than the declaration. A declaration whose body is only `...`, or that has no
//!   body, is a requirement of a trait, not a function. Its **own lines** are the executable lines of that range without those of the functions
//!   nested in it (a closure is a function of its own).
//! * A function is **recorded** when any of its own lines is in the set of lines the reports (or the branch records) give a record for.
//!   An unrecorded function is one no test compiled: its own lines count as found and not hit.
//! * **Decisions** are the words `if`, `elif`, `while`, `for`, `and`, `or` in the code of those lines, outside strings and comments (the
//!   decision words of rules/coverage/branch/README.md), except on a line that is compile-time: one that starts with `comptime` or `alias`, or
//!   follows a line that is only `@parameter`. Each is two arms, neither taken; an `and` / `or` on a line that starts with `if`, `elif` or
//!   `while` has a second two for its right operand (the compiler's `rhs` record, which an `if` that tests the result gives).
//!
//! What this cannot see (the figure is a heuristic, as covcheck's was): a `comptime if` arm the compiler dropped inside a function a test
//! compiled; a function the compiler inlines into every caller, whose lines may carry no record of their own (counted as not compiled); the
//! raising calls and subscripts that are branches in the IR but no word of the source.

const std = @import("std");
const Alloc = std.mem.Allocator;

/// The string a line starts in: `quote` is 0 outside any, else the quote byte.
const State = struct { quote: u8 = 0, triple: bool = false };

/// A decision word: its 1-based column.
pub const Word = struct { col: usize, logical: bool };

pub const Line = struct {
    /// The line without a trailing carriage return.
    text: []const u8,
    /// Byte offset of the comment's `#`.
    comment: ?usize = null,
    code: bool = false,
    opens: i32 = 0,
    closes: i32 = 0,
    brackets: i32 = 0,
    /// Byte offset of the first `;` in code.
    semi: ?usize = null,
    continued: bool = false,
    is_import: bool = false,
    tail_code: bool = false,
    in_string: bool = false,
    /// The identifier the line's code starts with (empty when it starts with anything else).
    first: []const u8 = "",
    words: []const Word = &.{},
};

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 128;
}

fn isPrefixLetter(c: u8) bool {
    return switch (c) {
        'r', 'R', 'b', 'B', 'f', 'F', 'u', 'U', 't', 'T' => true,
        else => false,
    };
}

/// How many string-prefix letters start at byte `i` (0, 1 or 2): letters right before a quote, not continuing an identifier.
fn prefixLen(text: []const u8, i: usize) usize {
    if (i > 0 and isIdent(text[i - 1])) return 0;
    var k: usize = 0;
    while (k < 2 and i + k < text.len and isPrefixLetter(text[i + k])) {
        k += 1;
        if (i + k < text.len and (text[i + k] == '"' or text[i + k] == '\'')) return k;
    }
    return 0;
}

fn decisionWord(w: []const u8) bool {
    for ([_][]const u8{ "if", "elif", "while", "for", "and", "or" }) |d| {
        if (std.mem.eql(u8, w, d)) return true;
    }
    return false;
}

fn lexLine(a: Alloc, raw: []const u8, st: *State) !Line {
    const text = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
    var l = Line{ .text = text };
    var words = std.ArrayList(Word).empty;
    var string_continues = false;
    const n = text.len;
    var i: usize = 0;
    while (i < n) {
        const c = text[i];
        if (st.quote != 0) {
            if (c == '\\') {
                if (i + 1 >= n) string_continues = true;
                i += 2;
                continue;
            }
            if (c == st.quote) {
                if (!st.triple) {
                    st.quote = 0;
                    i += 1;
                    continue;
                }
                if (i + 2 < n and text[i + 1] == c and text[i + 2] == c) {
                    st.quote = 0;
                    st.triple = false;
                    i += 3;
                    continue;
                }
            }
            i += 1;
            continue;
        }
        if (c == '#') {
            l.comment = i;
            break;
        }
        if (c == '"' or c == '\'') {
            st.quote = c;
            st.triple = i + 2 < n and text[i + 1] == c and text[i + 2] == c;
            i += if (st.triple) 3 else 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == 12) {
            i += 1;
            continue;
        }
        const p = prefixLen(text, i);
        if (p > 0) {
            i += p;
            continue;
        }
        const first_code = !l.code;
        l.code = true;
        if (isIdent(c)) {
            var j = i;
            while (j < n and isIdent(text[j])) j += 1;
            const w = text[i..j];
            if (first_code) l.first = w;
            if (decisionWord(w)) try words.append(a, .{ .col = i + 1, .logical = std.mem.eql(u8, w, "and") or std.mem.eql(u8, w, "or") });
            i = j;
            continue;
        }
        switch (c) {
            '(' => l.opens += 1,
            ')' => l.closes += 1,
            '[' => l.brackets += 1,
            ']' => l.brackets -= 1,
            ';' => if (l.semi == null) {
                l.semi = i;
            },
            '\\' => if (i == n - 1) {
                l.continued = true;
            },
            else => {},
        }
        i += 1;
    }
    if (st.quote != 0 and !st.triple and !string_continues) st.quote = 0;
    l.words = try words.toOwnedSlice(a);
    return l;
}

fn keywordThenBlank(rest: []const u8, word: []const u8) bool {
    return std.mem.startsWith(u8, rest, word) and rest.len > word.len and (rest[word.len] == ' ' or rest[word.len] == '\t');
}

fn startsImport(text: []const u8) bool {
    const rest = std.mem.trimLeft(u8, text, " \t");
    return keywordThenBlank(rest, "import") or keywordThenBlank(rest, "from");
}

const ImportState = struct { continues: bool, depth: i32 };

/// An import statement on `l` ended at its `;`: reads each statement after it. One that is not an import sets `tail_code` and ends the import.
fn afterSemicolons(a: Alloc, l: *Line) !ImportState {
    var st = State{};
    var seg = try lexLine(a, l.text[l.semi.? + 1 ..], &st);
    while (seg.code and startsImport(seg.text) and seg.semi != null) {
        var fresh = State{};
        seg = try lexLine(a, seg.text[seg.semi.? + 1 ..], &fresh);
    }
    if (!seg.code) return .{ .continues = false, .depth = 0 };
    if (!startsImport(seg.text)) {
        l.tail_code = true;
        return .{ .continues = false, .depth = 0 };
    }
    const depth = seg.opens - seg.closes;
    return .{ .continues = depth > 0 or seg.continued, .depth = depth };
}

/// Every line of `text` (split at LF, a final LF ending the last line, a leading byte-order mark dropped), lexed in order.
pub fn lexSource(a: Alloc, text_in: []const u8) ![]Line {
    var text = text_in;
    if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text = text[3..];
    var out = std.ArrayList(Line).empty;
    var st = State{};
    var in_import = false;
    var depth: i32 = 0;
    if (text.len == 0) return out.toOwnedSlice(a);
    var body = text;
    if (body[body.len - 1] == '\n') body = body[0 .. body.len - 1];
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const starts_in_string = st.quote != 0;
        var l = try lexLine(a, raw, &st);
        l.in_string = starts_in_string;
        const starts = !in_import and !starts_in_string and l.code and startsImport(l.text);
        if (in_import or starts) {
            l.is_import = true;
            if (l.semi != null) {
                const s = try afterSemicolons(a, &l);
                in_import = s.continues;
                depth = s.depth;
            } else {
                depth = (if (in_import) depth else 0) + l.opens - l.closes;
                in_import = depth > 0 or l.continued;
            }
        }
        try out.append(a, l);
    }
    return out.toOwnedSlice(a);
}

fn executable(l: Line) bool {
    return l.code and (!l.is_import or l.tail_code);
}

/// The 1-based numbers of the executable lines of `text`, ascending.
pub fn executableLines(a: Alloc, text: []const u8) ![]usize {
    const ls = try lexSource(a, text);
    var out = std.ArrayList(usize).empty;
    for (ls, 0..) |l, i| {
        if (executable(l)) try out.append(a, i + 1);
    }
    return out.toOwnedSlice(a);
}

/// Whether `text` begins with the marker `# @generated` (exactly, from byte 0) followed by the end of the line, a space, a tab or a CR:
/// the source is machine-written, and nothing of it is counted. A leading blank, `#@generated` or a comment that names the word later
/// does not mark a file, so a hand-written source cannot leave the denominator by accident.
pub fn isGenerated(text: []const u8) bool {
    const word = text[@min(2, text.len)..];
    const end = std.mem.indexOfAny(u8, word, " \t\r\n") orelse word.len;
    return std.mem.startsWith(u8, text, "# ") and std.mem.eql(u8, word[0..end], "@generated");
}

/// A function with a body: its name, its `def` line, its last line (1-based, inclusive) and its own executable lines.
pub const Fn = struct { name: []const u8, line: usize, end: usize, lines: []usize };

fn indentOf(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i;
}

/// The byte offset of the name after a leading `def` or `fn` word (followed by a space or tab), or null.
fn defNameAt(text: []const u8) ?usize {
    const i = indentOf(text);
    var w: usize = 0;
    if (i + 3 < text.len and std.mem.eql(u8, text[i .. i + 3], "def")) {
        w = 3;
    } else if (i + 2 < text.len and std.mem.eql(u8, text[i .. i + 2], "fn")) {
        w = 2;
    } else return null;
    if (text[i + w] != ' ' and text[i + w] != '\t') return null;
    var k = i + w;
    while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
    return k;
}

fn codeOf(l: Line) []const u8 {
    const t = if (l.comment) |c| l.text[0..c] else l.text;
    return std.mem.trim(u8, t, " \t");
}

/// What follows the signature's `:` on its last line `code`: a one-line body, or empty. `depth_before` is how many brackets the signature's
/// earlier lines left open; the signature's `:` is the first one outside every bracket and string.
fn afterColon(code: []const u8, depth_before: i32) []const u8 {
    var depth = depth_before;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < code.len) {
        const c = code[i];
        if (quote != 0) {
            if (c == '\\') {
                i += 2;
                continue;
            }
            if (c == quote) quote = 0;
        } else switch (c) {
            '"', '\'' => quote = c,
            '(', '[' => depth += 1,
            ')', ']' => depth -= 1,
            ':' => if (depth <= 0) return std.mem.trim(u8, code[i + 1 ..], " \t"),
            else => {},
        }
        i += 1;
    }
    return "";
}

fn nested(fns: []const Fn, k: usize, ln: usize) bool {
    for (fns, 0..) |m, mi| {
        if (mi != k and m.line > fns[k].line and m.line <= fns[k].end and ln >= m.line and ln <= m.end) return true;
    }
    return false;
}

/// Every function with a body that `text` declares, in order of their `def` lines.
pub fn declaredFunctions(a: Alloc, text: []const u8) ![]Fn {
    const ls = try lexSource(a, text);
    const n = ls.len;
    var out = std.ArrayList(Fn).empty;
    for (ls, 0..) |li, i| {
        if (!li.code or li.in_string) continue;
        const at = defNameAt(li.text) orelse continue;
        var e = at;
        while (e < li.text.len and isIdent(li.text[e])) e += 1;
        if (e == at) continue;
        const name = li.text[at..e];
        const ind = indentOf(li.text);
        // The signature: until its ( ) and [ ] are closed.
        var depth: i32 = 0;
        var before: i32 = 0;
        var h = i;
        while (h < n) : (h += 1) {
            before = depth;
            depth += ls[h].opens - ls[h].closes + ls[h].brackets;
            if (depth <= 0) break;
        }
        if (h >= n) h = n - 1;
        const inline_body = afterColon(codeOf(ls[h]), before);
        var end = h;
        var body_n: usize = 0;
        var body_first: []const u8 = "";
        if (inline_body.len > 0) {
            body_n = 1;
            body_first = inline_body;
        } else {
            var j = h + 1;
            while (j < n) : (j += 1) {
                if (ls[j].code and !ls[j].in_string and indentOf(ls[j].text) <= ind) break;
                // Code, or string text (a docstring's lines); not a blank or comment-only line.
                if (ls[j].code or (ls[j].comment == null and std.mem.trim(u8, ls[j].text, " \t").len > 0)) end = j;
                if (ls[j].code) {
                    body_n += 1;
                    if (body_n == 1) body_first = codeOf(ls[j]);
                }
            }
        }
        // A trait's requirement: no body, or `...` alone.
        if (body_n == 0 or (body_n == 1 and std.mem.eql(u8, body_first, "..."))) continue;
        try out.append(a, .{ .name = name, .line = i + 1, .end = end + 1, .lines = &.{} });
    }
    const fns = try out.toOwnedSlice(a);
    for (fns, 0..) |*f, k| {
        var own = std.ArrayList(usize).empty;
        var ln = f.line;
        while (ln <= f.end) : (ln += 1) {
            if (executable(ls[ln - 1]) and !nested(fns, k, ln)) try own.append(a, ln);
        }
        f.lines = try own.toOwnedSlice(a);
    }
    return fns;
}

/// A line set, for the lines a report gives a record.
pub const LineSet = std.AutoArrayHashMapUnmanaged(usize, void);

/// What no test compiled: `lines` (the own executable lines of every function none of whose own lines is in `recorded`) and `decisions`
/// (the 1-based line and column of each decision word on them).
pub const Uncompiled = struct { lines: []usize, decisions: []Decision };
/// A decision at a line and column: `rhs` is the right operand of an `and` / `or` that an `if`, `elif` or `while` tests, which the compiler's
/// branch records count apart from the `and` / `or` itself (rules/coverage/branch/README.md, "And, or").
pub const Decision = struct { line: usize, col: usize, rhs: bool = false };

pub fn uncompiled(a: Alloc, text: []const u8, recorded: *const LineSet) !Uncompiled {
    const ls = try lexSource(a, text);
    const fns = try declaredFunctions(a, text);
    var lines = std.ArrayList(usize).empty;
    var decisions = std.ArrayList(Decision).empty;
    for (fns, 0..) |f, k| {
        var has_record = false;
        var ln = f.line;
        while (ln <= f.end and !has_record) : (ln += 1) {
            has_record = recorded.contains(ln) and !nested(fns, k, ln);
        }
        if (has_record) continue;
        for (f.lines) |own| {
            try lines.append(a, own);
            const l = ls[own - 1];
            if (std.mem.eql(u8, l.first, "comptime") or std.mem.eql(u8, l.first, "alias")) continue;
            if (own >= 2 and std.mem.eql(u8, codeOf(ls[own - 2]), "@parameter")) continue;
            const tested = std.mem.eql(u8, l.first, "if") or std.mem.eql(u8, l.first, "elif") or std.mem.eql(u8, l.first, "while");
            for (l.words) |w| {
                try decisions.append(a, .{ .line = own, .col = w.col });
                if (w.logical and tested) try decisions.append(a, .{ .line = own, .col = w.col, .rhs = true });
            }
        }
    }
    std.mem.sort(usize, lines.items, {}, std.sort.asc(usize));
    std.mem.sort(Decision, decisions.items, {}, struct {
        fn lt(_: void, x: Decision, y: Decision) bool {
            if (x.line != y.line) return x.line < y.line;
            if (x.col != y.col) return x.col < y.col;
            return !x.rhs and y.rhs;
        }
    }.lt);
    return .{ .lines = try lines.toOwnedSlice(a), .decisions = try decisions.toOwnedSlice(a) };
}
