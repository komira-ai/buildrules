//! The no-shell lint (`//ci:no_shell`): the build rules are leaving busybox and every shell, one action at a time, and this check keeps them from coming back
//! while they go. It reads every file of every package (the `scrub_files` outputs, as the scrub does) and refuses, outside comments:
//!
//!  - `busybox`: the word, in a BUCK, .bzl, .bxl or .zig file (an attribute, a call, a path, a string);
//!  - `shell-word`: a shell interpreter as a whole string (the first word of an argv: `sh`, `bash`, `dash`, `ash`, `zsh`, `ksh`, or a path ending in one);
//!  - `shell-c`: the flag that hands a shell a script (`-c`, `-euc`, `-ec`, ...) as the string that directly follows a shell word. `zig cc -c` and a
//!    cdk `-c context=...` follow other words and stay green;
//!  - `bin-sh`: a longer string that names `/bin/sh`, `/bin/bash` or `/bin/dash` (a path built for a shell);
//!  - `heredoc`: a triple-quoted string of a BUCK, .bzl or .bxl file that is a shell script (a line `set -eu`, `case "`, `export `, or a quoted `$1`, `$@`, `${`);
//!  - `shebang`: a file whose first line names a shell interpreter, directly or through `env`;
//!  - `sh-file`: any file named `*.sh` or `*.bash`.
//!
//! Not read: `.github/` (the CI `run:` blocks are bash by nature and linted by workflow_check.zig), `docs/`, `third_party/`, and `tools/held/` until the held
//! scripts are gone (`exclude_held`). Comments are not read: a BUCK or .bzl `#` comment, a Zig `//` comment. A word inside a string is read, and so is a docstring.
//!
//! The allow-list (ci/no_shell_allow.tsv): one row per `file<TAB>rule<TAB>max`, no line numbers, so an edit that moves a line conflicts with nothing. A file with a
//! use that no row allows is red, and so is a count above its row's max. A row whose count has fallen below its max is stale: a warning while the migration runs,
//! red when `strict_stale` is true (the last step of the migration flips it and empties the list). Each pull request of the migration lowers or deletes the rows
//! it makes stale. `permanent` holds what stays for good, each entry with its reason: the shipped installer is run as `curl | sh`, so it needs a shell.
//!
//! A pure function of the files' text, tested below against planted text; ci/no_shell_main.zig reads the tree.
const std = @import("std");
const t = std.testing;

/// Flip to true (and empty the allow-list) when the last shell use is gone: a stale row is then red, and so is any row at all.
pub const strict_stale = false;
/// Drop (set false) when tools/held holds no shell script any more.
pub const exclude_held = true;

pub const Findings = std.ArrayList([]const u8);

fn add(a: std.mem.Allocator, f: *Findings, comptime fmt: []const u8, args: anytype) !void {
    try f.append(try std.fmt.allocPrint(a, fmt, args));
}

pub const Rule = enum {
    busy_box,
    shell_word,
    shell_c,
    bin_sh,
    heredoc,
    shebang,
    sh_file,

    pub fn name(r: Rule) []const u8 {
        return switch (r) {
            .busy_box => bb_word,
            .shell_word => "shell-word",
            .shell_c => "shell-c",
            .bin_sh => "bin-sh",
            .heredoc => "heredoc",
            .shebang => "shebang",
            .sh_file => "sh-file",
        };
    }

    pub fn what(r: Rule) []const u8 {
        return switch (r) {
            .busy_box => "names " ++ bb_word,
            .shell_word => "runs a shell interpreter",
            .shell_c => "hands a shell a script with -c",
            .bin_sh => "names a path of a shell",
            .heredoc => "holds a shell script as a string",
            .shebang => "starts with a shell shebang",
            .sh_file => "is a shell script file",
        };
    }

    pub fn parse(s: []const u8) ?Rule {
        for (std.enums.values(Rule)) |r| if (std.mem.eql(u8, r.name(), s)) return r;
        return null;
    }
};

pub const Permanent = struct { file: []const u8, rule: Rule, max: usize, why: []const u8 };

/// What stays after the migration, each with its reason. A permanent entry that no longer applies is red: delete it.
pub const permanent = [_]Permanent{
    .{ .file = "site/static/install.sh", .rule = .sh_file, .max = 1, .why = "the installer people run as `curl | sh`: the one file that needs a shell on a machine we know nothing about" },
    .{ .file = "site/static/install.sh", .rule = .shebang, .max = 1, .why = "the same installer: its first line names the shell that runs it" },
    .{ .file = "tools/install/install_script_test.zig", .rule = .shell_word, .max = 1, .why = "the installer's test runs it with the absolute path of the system shell and an empty PATH" },
};

// ---- the vocabulary (in parts, so that this file does not hold what it refuses) ---------------------------------------------------

const bb_word = "busy" ++ "box";
const BB = bb_word ++ "@";
const shells = [_][]const u8{ "s" ++ "h", "bas" ++ "h", "das" ++ "h", "as" ++ "h", "zs" ++ "h", "ks" ++ "h" };
const bin_paths = [_][]const u8{ "/bin/s" ++ "h", "/bin/bas" ++ "h", "/bin/das" ++ "h" };
const env_word = "e" ++ "nv";

fn isShellName(base: []const u8) bool {
    for (shells) |s| if (std.mem.eql(u8, base, s)) return true;
    return false;
}

/// A string that is one shell interpreter: no blank in it, and its last path segment is a shell's name.
fn isShellWord(s: []const u8) bool {
    if (s.len == 0 or std.mem.indexOfAny(u8, s, " \t\n") != null) return false;
    return isShellName(std.fs.path.basename(s));
}

/// `-c`, `-euc`, `-ec`, `-lc`: option letters of a shell, c among them.
fn isCFlag(s: []const u8) bool {
    if (s.len < 2 or s[0] != '-') return false;
    var has_c = false;
    for (s[1..]) |c| {
        if (std.mem.indexOfScalar(u8, "euxlfc", c) == null) return false;
        if (c == 'c') has_c = true;
    }
    return has_c;
}

fn hasBinPath(s: []const u8) bool {
    for (bin_paths) |p| if (std.mem.indexOf(u8, s, p) != null) return true;
    return false;
}

/// A triple-quoted string that is a script: a line that opens like one, or a quoted positional parameter.
fn looksLikeScript(body: []const u8) bool {
    if (std.mem.indexOf(u8, body, "\"$1\"") != null or std.mem.indexOf(u8, body, "\"$@\"") != null or std.mem.indexOf(u8, body, "\"${") != null) return true;
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |raw| {
        const ln = std.mem.trimLeft(u8, raw, " \t");
        if (std.mem.startsWith(u8, ln, "set -") or std.mem.startsWith(u8, ln, "case \"") or std.mem.startsWith(u8, ln, "export ")) return true;
    }
    return false;
}

/// The first line of `text` is `#!` and names a shell, directly or after `env` (and its options).
fn shellShebang(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "#!")) return false;
    const eol = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    var words = std.mem.tokenizeAny(u8, text[2..eol], " \t\r");
    const first = words.next() orelse return false;
    const base = std.fs.path.basename(first);
    if (isShellName(base)) return true;
    if (!std.mem.eql(u8, base, env_word)) return false;
    while (words.next()) |w| {
        if (w[0] == '-') continue;
        return isShellName(std.fs.path.basename(w));
    }
    return false;
}

fn isShFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".s" ++ "h") or std.mem.endsWith(u8, path, ".bas" ++ "h");
}

// ---- the scan ----------------------------------------------------------------------------------------------------------------------

pub const Hit = struct { path: []const u8, rule: Rule, line: usize };

const Lang = enum { starlark, zig };

fn langOf(path: []const u8) ?Lang {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "BUCK") or std.mem.startsWith(u8, base, "BUCK.") or std.mem.endsWith(u8, base, ".bzl") or std.mem.endsWith(u8, base, ".bxl")) return .starlark;
    if (std.mem.endsWith(u8, base, ".zig")) return .zig;
    return null;
}

const Scanner = struct {
    hits: *std.ArrayList(Hit),
    path: []const u8,
    lang: Lang,
    text: []const u8,
    line: usize = 1,
    bb_line: usize = 0,
    /// The last string was a shell word and only blanks, commas and comments have come since.
    prev_shell: bool = false,

    fn hit(s: *Scanner, rule: Rule, line: usize) !void {
        try s.hits.append(.{ .path = s.path, .rule = rule, .line = line });
    }

    /// One hit per line that names " ++ bb_word ++ ", however often.
    fn bbAt(s: *Scanner, line: usize) !void {
        if (s.bb_line == line) return;
        s.bb_line = line;
        try s.hit(.busy_box, line);
    }

    fn bbIn(s: *Scanner, body: []const u8, first_line: usize) !void {
        var l = first_line;
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |ln| : (l += 1) {
            if (std.mem.indexOf(u8, ln, bb_word) != null) try s.bbAt(l);
        }
    }

    fn eol(s: *Scanner, from: usize) usize {
        return std.mem.indexOfScalarPos(u8, s.text, from, '\n') orelse s.text.len;
    }

    /// The string that opens at `start` (a quote `q`); returns the index after it.
    fn string(s: *Scanner, start: usize, q: u8) !usize {
        const text = s.text;
        const first_line = s.line;
        const multi = s.lang == .starlark and start + 2 < text.len and text[start + 1] == q and text[start + 2] == q;
        const from = start + (if (multi) @as(usize, 3) else 1);
        var j = from;
        var to = text.len;
        var end = text.len;
        while (j < text.len) {
            const ch = text[j];
            if (ch == '\\') {
                j += 2;
                continue;
            }
            if (multi) {
                if (ch == q and j + 2 < text.len and text[j + 1] == q and text[j + 2] == q) {
                    to = j;
                    end = j + 3;
                    break;
                }
            } else if (ch == q) {
                to = j;
                end = j + 1;
                break;
            } else if (ch == '\n') {
                to = j;
                end = j;
                break;
            }
            j += 1;
        }
        const body = text[from..to];
        try s.bbIn(body, first_line);
        if (isShellWord(body)) {
            try s.hit(.shell_word, first_line);
            s.prev_shell = true;
        } else {
            if (s.prev_shell and isCFlag(body)) {
                try s.hit(.shell_c, first_line);
            } else if (hasBinPath(body)) {
                try s.hit(.bin_sh, first_line);
            }
            s.prev_shell = false;
        }
        if (multi and looksLikeScript(body)) try s.hit(.heredoc, first_line);
        s.line += std.mem.count(u8, text[start..end], "\n");
        return end;
    }

    fn run(s: *Scanner) !void {
        const text = s.text;
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            const next: u8 = if (i + 1 < text.len) text[i + 1] else 0;
            if (c == '\n') {
                s.line += 1;
                i += 1;
            } else if (c == ' ' or c == '\t' or c == '\r' or c == ',') {
                i += 1;
            } else if ((s.lang == .starlark and c == '#') or (s.lang == .zig and c == '/' and next == '/')) {
                i = s.eol(i);
            } else if (s.lang == .zig and c == '\\' and next == '\\') {
                // a line of a multi-line string literal: text, not a comment
                const e = s.eol(i);
                try s.bbIn(text[i + 2 .. e], s.line);
                s.prev_shell = false;
                i = e;
            } else if (c == '"' or c == '\'') {
                i = try s.string(i, c);
            } else {
                s.prev_shell = false;
                if (std.mem.startsWith(u8, text[i..], bb_word)) {
                    try s.bbAt(s.line);
                    i += bb_word.len;
                } else i += 1;
            }
        }
    }
};

/// Every use in one file, in file order.
pub fn scanFile(path: []const u8, text: []const u8, hits: *std.ArrayList(Hit)) !void {
    if (isShFile(path)) try hits.append(.{ .path = path, .rule = .sh_file, .line = 1 });
    if (shellShebang(text)) try hits.append(.{ .path = path, .rule = .shebang, .line = 1 });
    const lang = langOf(path) orelse return;
    var s = Scanner{ .hits = hits, .path = path, .lang = lang, .text = text };
    try s.run();
}

// ---- the allow-list and the verdict ------------------------------------------------------------------------------------------------

pub const Entry = struct { path: []const u8, text: []const u8 };
pub const Options = struct { strict: bool = strict_stale, held_excluded: bool = exclude_held };
pub const Row = struct { file: []const u8, rule: Rule, max: usize };

const excluded_prefixes = [_][]const u8{ ".github/", "docs/", "third_party/" };
const held_prefix = "tools/held/";

pub fn excluded(path: []const u8, opt: Options) bool {
    for (excluded_prefixes) |p| if (std.mem.startsWith(u8, path, p)) return true;
    return opt.held_excluded and std.mem.startsWith(u8, path, held_prefix);
}

fn parseAllow(a: std.mem.Allocator, text: []const u8, errs: *Findings) ![]Row {
    var rows = std.ArrayList(Row).init(a);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        n += 1;
        const ln = std.mem.trimRight(u8, raw, "\r");
        if (ln.len == 0 or ln[0] == '#') continue;
        var cols = std.mem.splitScalar(u8, ln, '\t');
        const file = cols.next().?;
        const rule_s = cols.next() orelse {
            try add(a, errs, "ci/no_shell_allow.tsv:{d}: a row is file<TAB>rule<TAB>max", .{n});
            continue;
        };
        const max_s = cols.next() orelse {
            try add(a, errs, "ci/no_shell_allow.tsv:{d}: a row is file<TAB>rule<TAB>max", .{n});
            continue;
        };
        if (cols.next() != null) {
            try add(a, errs, "ci/no_shell_allow.tsv:{d}: a row is file<TAB>rule<TAB>max: no fourth column", .{n});
            continue;
        }
        const rule = Rule.parse(rule_s) orelse {
            try add(a, errs, "ci/no_shell_allow.tsv:{d}: `{s}` is not a rule", .{ n, rule_s });
            continue;
        };
        const max = std.fmt.parseInt(usize, max_s, 10) catch 0;
        if (max == 0) {
            try add(a, errs, "ci/no_shell_allow.tsv:{d}: max `{s}` is not a number above zero (delete the row instead)", .{ n, max_s });
            continue;
        }
        var dup = false;
        for (rows.items) |r| if (r.rule == rule and std.mem.eql(u8, r.file, file)) {
            dup = true;
        };
        if (dup) {
            try add(a, errs, "ci/no_shell_allow.tsv:{d}: {s} {s} is listed twice", .{ n, file, rule_s });
            continue;
        }
        try rows.append(.{ .file = file, .rule = rule, .max = max });
    }
    return rows.items;
}

const Count = struct { path: []const u8, rule: Rule, n: usize, first: usize };

fn hitLess(_: void, x: Hit, y: Hit) bool {
    const c = std.mem.order(u8, x.path, y.path);
    if (c != .eq) return c == .lt;
    if (x.rule != y.rule) return @intFromEnum(x.rule) < @intFromEnum(y.rule);
    return x.line < y.line;
}

fn countOf(counts: []const Count, path: []const u8, rule: Rule) usize {
    for (counts) |c| if (c.rule == rule and std.mem.eql(u8, c.path, path)) return c.n;
    return 0;
}

fn permanentMax(path: []const u8, rule: Rule) usize {
    for (permanent) |p| if (p.rule == rule and std.mem.eql(u8, p.file, path)) return p.max;
    return 0;
}

pub const Report = struct {
    errors: Findings,
    warnings: Findings,
    /// The allow-list that would make the tree green exactly (rows sorted, max = what the permanent entries do not cover).
    current: []const u8,
    scanned: usize,
};

/// Scan `entries` (path from the repository root, text), hold the uses to `allow` (the text of ci/no_shell_allow.tsv) and `permanent`.
pub fn run(a: std.mem.Allocator, entries: []const Entry, allow: []const u8, opt: Options) !Report {
    var rep = Report{ .errors = Findings.init(a), .warnings = Findings.init(a), .current = "", .scanned = 0 };
    var hits = std.ArrayList(Hit).init(a);
    for (entries) |e| {
        if (excluded(e.path, opt)) continue;
        rep.scanned += 1;
        try scanFile(e.path, e.text, &hits);
    }
    std.mem.sort(Hit, hits.items, {}, hitLess);
    var counts = std.ArrayList(Count).init(a);
    for (hits.items) |h| {
        if (counts.items.len > 0) {
            const last = &counts.items[counts.items.len - 1];
            if (last.rule == h.rule and std.mem.eql(u8, last.path, h.path)) {
                last.n += 1;
                continue;
            }
        }
        try counts.append(.{ .path = h.path, .rule = h.rule, .n = 1, .first = h.line });
    }

    const rows = try parseAllow(a, allow, &rep.errors);
    if (opt.strict and rows.len > 0) try add(a, &rep.errors, "ci/no_shell_allow.tsv: {d} row(s) remain, and the migration is over: the list must be empty (the permanent entries live in ci/no_shell_check.zig)", .{rows.len});

    var cur = std.ArrayList(u8).init(a);
    for (counts.items) |c| {
        const perm = permanentMax(c.path, c.rule);
        var row_max: usize = 0;
        for (rows) |r| if (r.rule == c.rule and std.mem.eql(u8, r.file, c.path)) {
            row_max = r.max;
        };
        if (c.n > perm) try cur.writer().print("{s}\t{s}\t{d}\n", .{ c.path, c.rule.name(), c.n - perm });
        if (c.n > perm + row_max) {
            try add(a, &rep.errors, "{s}:{d}: [{s}] {d} use(s) {s}, {d} allowed", .{ c.path, c.first, c.rule.name(), c.n, c.rule.what(), perm + row_max });
        }
    }
    rep.current = cur.items;
    for (rows) |r| {
        const n = countOf(counts.items, r.file, r.rule);
        const debt = if (n > permanentMax(r.file, r.rule)) n - permanentMax(r.file, r.rule) else 0;
        if (debt >= r.max) continue;
        const msg = try std.fmt.allocPrint(a, "ci/no_shell_allow.tsv: stale row `{s} {s} {d}`: {d} use(s) remain; lower the max or delete the row", .{ r.file, r.rule.name(), r.max, debt });
        const dst = if (opt.strict) &rep.errors else &rep.warnings;
        try dst.append(msg);
    }
    for (permanent) |p| {
        if (countOf(counts.items, p.file, p.rule) >= p.max) continue;
        try add(a, &rep.errors, "permanent entry {s} {s}: the file no longer needs it ({s}); delete the entry from ci/no_shell_check.zig", .{ p.file, p.rule.name(), p.why });
    }
    return rep;
}

// ---- tests -------------------------------------------------------------------------------------------------------------------------

const Arena = std.heap.ArenaAllocator;

fn hitsOf(a: std.mem.Allocator, path: []const u8, text: []const u8) ![]Hit {
    var hits = std.ArrayList(Hit).init(a);
    try scanFile(path, text, &hits);
    return hits.items;
}

/// The rules hit, in order, as one string `rule@line rule@line`.
fn shape(a: std.mem.Allocator, path: []const u8, text: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    for (try hitsOf(a, path, text)) |h| try out.writer().print("{s}@{d} ", .{ h.rule.name(), h.line });
    return std.mem.trimRight(u8, out.items, " ");
}

fn expectShape(path: []const u8, text: []const u8, want: []const u8) !void {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings(want, try shape(arena.allocator(), path, text));
}


test "busy box: a row, an attribute, a call, an identifier and a string are each a use" {
    try expectShape("a/BUCK", "zig_exe(\n    busy" ++ "box = \"x//pins:busy" ++ "box\",\n)\n", BB ++ "2");
    try expectShape("a/x.bzl", "cmd = busy" ++ "box_sh(script)\n", BB ++ "1");
    try expectShape("a/x.zig", "const p = \"/opt/busy" ++ "box\";\n", BB ++ "1");
    try expectShape("a/x.bzl", "x = \"\"\"a\nb busy" ++ "box\nc\"\"\"\ny = busy" ++ "box\n", BB ++ "2 " ++ BB ++ "4");
}

test "busy box: two on one line are one use; one on each of two lines are two" {
    try expectShape("a/BUCK", "x = [busy" ++ "box, busy" ++ "box]\n", BB ++ "1");
    try expectShape("a/BUCK", "x = [busy" ++ "box,\n busy" ++ "box]\n", BB ++ "1 " ++ BB ++ "2");
}

test "GREEN control: a comment that names busy box is not a use, in BUCK, .bzl and Zig" {
    try expectShape("a/BUCK", "# the busy" ++ "box rows\nx = 1  # busy" ++ "box\n", "");
    try expectShape("a/x.bzl", "x = 1  # busy" ++ "box_sh\n", "");
    try expectShape("a/x.zig", "// busy" ++ "box\n/// busy" ++ "box\n//! busy" ++ "box\nconst x = 1; // busy" ++ "box\n", "");
}

test "GREEN control: a Zig '#' is not a comment, a '//' inside a string is not one, and a BUCK '#' inside a string is not one" {
    try expectShape("a/x.zig", "const a = '#'; const b = \"https://x/busy" ++ "box\";\n", BB ++ "1");
    try expectShape("a/BUCK", "x = \"a # busy" ++ "box\"\n", BB ++ "1");
}

test "a line of a Zig multi-line string is text, and is read" {
    try expectShape("a/x.zig", "const s =\n    \\\\echo busy" ++ "box\n    \\\\done\n;\n", BB ++ "2");
    try expectShape("a/x.zig", "const s =\n    \\\\x // not a comment\n    ;\nconst y = 1; busy" ++ "box\n", BB ++ "4");
}

test "shell word: sh, bash, a path to one, as a whole string" {
    try expectShape("a/x.bzl", "cmd_args(bb, \"s" ++ "h\")\n", "shell-word@1");
    try expectShape("a/x.bzl", "cmd_args(\"/usr/bin/ba" ++ "sh\")\n", "shell-word@1");
    try expectShape("a/x.zig", "const argv = &.{ \"/bin/s" ++ "h\" };\n", "shell-word@1");
    try expectShape("a/x.zig", "const argv = &.{ \"da" ++ "sh\" };\n", "shell-word@1");
}

test "GREEN control: a word that merely contains a shell's name, or a string of several words, is not a shell word" {
    try expectShape("a/x.bzl", "x = [\"shell\", \"bashful\", \"sh " ++ "-x\", \"\", \"a.s" ++ "h\", \"fish\"]\n", "");
    try expectShape("a/x.bzl", "x = ['bash --version']\n", "");
}

test "shell -c: the flag directly after a shell word, on one line or across lines and comments" {
    try expectShape("a/x.bzl", "cmd_args(bb, \"s" ++ "h\", \"-euc\", script)\n", "shell-word@1 shell-c@1");
    try expectShape("a/BUCK", "x = [\n    \"s" ++ "h\",\n    # the script follows\n    \"-c\",\n]\n", "shell-word@2 shell-c@4");
    try expectShape("a/x.zig", "const a = &.{ \"/bin/s" ++ "h\", \"-c\", s };\n", "shell-word@1 shell-c@1");
    try expectShape("a/x.bzl", "x = [\"s" ++ "h\", \"-ec\", \"-xc\", \"-lc\"]\n", "shell-word@1 shell-c@1");
}

test "GREEN control: -c after a word that is not a shell (zig cc -c, the cdk context) is not a use" {
    try expectShape("a/x.zig", "const a = &.{ \"cc\", \"-c\", \"a.c\", \"-o\", \"a.o\" };\nconst b = &.{ \"-c\", \"-S\", \"-E\" };\n", "");
    try expectShape("a/x.bzl", "args = [\"cdk\", \"synth\", \"-c\", \"env=prod\"]\n", "");
}

test "GREEN control: a shell word followed by something else before -c is not a direct -c; a flag that is not a shell's option is not one" {
    try expectShape("a/x.bzl", "x = [\"s" ++ "h\", script, \"-c\"]\n", "shell-word@1");
    try expectShape("a/x.bzl", "x = [\"s" ++ "h\", \"-C\", \"-cat\", \"-\", \"-e\"]\n", "shell-word@1");
    try expectShape("a/x.bzl", "x = [\"s" ++ "h\", \"x\", \"-c\"]\n", "shell-word@1");
}

test "bin-sh: a longer string that names a shell's path; a path that ends in a shell is a shell word, once" {
    try expectShape("a/x.zig", "const p = \"{s}/../bin/" ++ "sh\";\n", "shell-word@1");
    try expectShape("a/x.zig", "const p = \"X=/bin/s" ++ "h:Y\";\n", "bin-sh@1");
    try expectShape("a/x.bzl", "x = \"exec /bin/ba" ++ "sh -x\"\n", "bin-sh@1");
    try expectShape("a/x.zig", "const p = \"/bin/" ++ "sh\";\n", "shell-word@1");
}

test "heredoc: a triple-quoted script, however it opens; a docstring is not one" {
    try expectShape("a/x.bzl", "_S = \"\"\"set -eu\necho hi\n\"\"\"\n", "heredoc@1");
    try expectShape("a/x.bzl", "_S = \"\"\"\n  set -e\n\"\"\"\n", "heredoc@1");
    try expectShape("a/x.bzl", "_S = \"\"\"\ncase \"$X\" in\nesac\n\"\"\"\n", "heredoc@1");
    try expectShape("a/x.bzl", "_S = '''\nexport A=1\n'''\n", "heredoc@1");
    try expectShape("a/x.bzl", "_S = \"\"\"\nBB=\"$1\"; shift\n\"\"\"\n", "heredoc@1");
    try expectShape("a/x.bzl", "_S = \"\"\"\nrm \"$@\"\n\"\"\"\n", "heredoc@1");
    try expectShape("a/x.bzl", "_S = \"\"\"\nx=\"${HOME}\"\n\"\"\"\n", "heredoc@1");
    try expectShape("a/x.bzl", "def f():\n    \"\"\"One file built into an executable.\n\n    A second paragraph.\n    \"\"\"\n    return 1\n", "");
}

test "GREEN control: a one-line string that looks like a script is not a heredoc; a Zig multi-line string is not read as one" {
    try expectShape("a/x.bzl", "x = \"set -eu\"\n", "");
    try expectShape("a/x.zig", "const s =\n    \\\\set -eu\n    \\\\echo hi\n;\n", "");
}

test "a triple-quoted string with an escaped quote, a lone quote and an unterminated end are read to their end" {
    try expectShape("a/x.bzl", "x = \"\"\"a \\\" b \" c \"\" d\"\"\"\ny = busy" ++ "box\n", BB ++ "2");
    try expectShape("a/x.bzl", "x = \"\"\"never closed busy" ++ "box\n", BB ++ "1");
    try expectShape("a/x.bzl", "x = \"never closed busy" ++ "box\ny = 1\n", BB ++ "1");
    try expectShape("a/x.bzl", "x = \"ends with a backslash\\", "");
    try expectShape("a/x.bzl", "x = \"\"\"abc\"\"", "");
}

test "shebang: a shell named directly or through env, on the first line only" {
    try expectShape("a/tool", "#!/bin/s" ++ "h\necho\n", "shebang@1");
    try expectShape("a/tool", "#!/usr/bin/env ba" ++ "sh\n", "shebang@1");
    try expectShape("a/tool", "#!/usr/bin/env -S da" ++ "sh -e\n", "shebang@1");
    try expectShape("a/tool", "#! /bin/bas" ++ "h", "shebang@1");
}

test "GREEN control: other interpreters, a bare env, an empty shebang and a shebang below line one are not a shell shebang" {
    try expectShape("a/tool", "#!/usr/bin/env python3\n", "");
    try expectShape("a/tool", "#!/usr/bin/env\n", "");
    try expectShape("a/tool", "#!/usr/bin/env -S\n", "");
    try expectShape("a/tool", "#!\n", "");
    try expectShape("a/tool", "#!/usr/bin/perl\n", "");
    try expectShape("a/tool", "x\n#!/bin/s" ++ "h\n", "");
    try expectShape("a/tool", "", "");
}

test "sh-file: any *.sh or *.bash, wherever it is; a name that only ends alike is not" {
    try expectShape("tools/new.s" ++ "h", "", "sh-file@1");
    try expectShape("a/b/c.bas" ++ "h", "echo\n", "sh-file@1");
    try expectShape("a/mush", "", "");
    try expectShape("a/x.shx", "", "");
}

test "a file that is no BUCK, .bzl, .bxl or .zig is read only for a shebang and its name" {
    try expectShape("a/notes.txt", "busy" ++ "box\n\"s" ++ "h\"\n", "");
    try expectShape("a/BUCK.beta", "x = busy" ++ "box\n", BB ++ "1");
    try expectShape("a/x.bxl", "x = busy" ++ "box\n", BB ++ "1");
}

fn entryOf(path: []const u8, text: []const u8) Entry {
    return .{ .path = path, .text = text };
}

const opt_loose = Options{ .strict = false, .held_excluded = true };
const opt_strict = Options{ .strict = true, .held_excluded = true };

/// The tree of the permanent entries, so that a test can be about its own file.
const perm_tree = [_]Entry{
    .{ .path = "site/static/install.s" ++ "h", .text = "#!/bin/s" ++ "h\necho\n" },
    .{ .path = "tools/install/install_script_test.zig", .text = "const x = &.{ \"/bin/s" ++ "h\" };\n" },
};

fn runWith(a: std.mem.Allocator, extra: []const Entry, allow: []const u8, opt: Options) !Report {
    var all = std.ArrayList(Entry).init(a);
    try all.appendSlice(&perm_tree);
    try all.appendSlice(extra);
    return run(a, all.items, allow, opt);
}

fn holds(list: Findings, sub: []const u8) bool {
    for (list.items) |e| if (std.mem.indexOf(u8, e, sub) != null) return true;
    return false;
}

fn expectErr(rep: Report, sub: []const u8) !void {
    try t.expect(holds(rep.errors, sub));
}

fn expectWarn(rep: Report, sub: []const u8) !void {
    try t.expect(holds(rep.warnings, sub));
}

const one_bb = Entry{ .path = "rules/x/BUCK", .text = "x = busy" ++ "box\n" };

test "MUTANT: a new busy box use in a file nothing allows is red" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const rep = try runWith(arena.allocator(), &.{one_bb}, "", opt_loose);
    try t.expectEqual(@as(usize, 1), rep.errors.items.len);
    try expectErr(rep, "rules/x/BUCK:1: [" ++ bb_word ++ "] 1 use(s) names " ++ bb_word ++ ", 0 allowed");
}

test "MUTANT: a new shell -c in a .bzl nothing allows is red, as a shell word and as the flag" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const rep = try runWith(arena.allocator(), &.{entryOf("rules/x/new.bzl", "cmd_args(\"s" ++ "h\", \"-c\", s)\n")}, "", opt_loose);
    try t.expectEqual(@as(usize, 2), rep.errors.items.len);
    try expectErr(rep, "[shell-word]");
    try expectErr(rep, "[shell-c]");
}

test "MUTANT: a new .sh file is red, however empty" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const rep = try runWith(arena.allocator(), &.{entryOf("tools/new.s" ++ "h", "")}, "", opt_loose);
    try t.expectEqual(@as(usize, 1), rep.errors.items.len);
    try expectErr(rep, "tools/new." ++ "sh:1: [sh-file]");
}

test "MUTANT: a new shell shebang and a new heredoc are red" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const rep = try runWith(arena.allocator(), &.{ entryOf("tools/run", "#!/usr/bin/env ba" ++ "sh\n"), entryOf("rules/y.bzl", "_S = \"\"\"set -eu\n\"\"\"\n") }, "", opt_loose);
    try expectErr(rep, "tools/run:1: [shebang]");
    try expectErr(rep, "rules/y.bzl:1: [heredoc]");
}

test "MUTANT: a raised count is red: the row allows one, the file now has two" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const two = Entry{ .path = "rules/x/BUCK", .text = "x = busy" ++ "box\ny = busy" ++ "box\n" };
    const rep = try runWith(arena.allocator(), &.{two}, "rules/x/BUCK\t" ++ bb_word ++ "\t1\n", opt_loose);
    try t.expectEqual(@as(usize, 1), rep.errors.items.len);
    try expectErr(rep, "rules/x/BUCK:1: [" ++ bb_word ++ "] 2 use(s) names " ++ bb_word ++ ", 1 allowed");
}

test "MUTANT: an unlisted file is red even when another file has a row for the same rule" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const other = Entry{ .path = "rules/y/BUCK", .text = "x = busy" ++ "box\n" };
    const rep = try runWith(arena.allocator(), &.{ one_bb, other }, "rules/x/BUCK\t" ++ bb_word ++ "\t1\n", opt_loose);
    try t.expectEqual(@as(usize, 1), rep.errors.items.len);
    try expectErr(rep, "rules/y/BUCK:1");
}

test "MUTANT: a row for another rule does not allow this one" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const rep = try runWith(arena.allocator(), &.{one_bb}, "rules/x/BUCK\theredoc\t1\n", opt_loose);
    try expectErr(rep, "rules/x/BUCK:1: [" ++ bb_word ++ "]");
    try expectWarn(rep, "stale row `rules/x/BUCK heredoc 1`");
}

test "GREEN: the exact count is green, with no warning, and a count below max is a warning that names the row" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exact = try runWith(a, &.{one_bb}, "# debt\n\nrules/x/BUCK\t" ++ bb_word ++ "\t1\n", opt_loose);
    try t.expectEqual(@as(usize, 0), exact.errors.items.len);
    try t.expectEqual(@as(usize, 0), exact.warnings.items.len);
    try t.expect(!holds(exact.warnings, "stale"));
    const stale = try runWith(a, &.{one_bb}, "rules/x/BUCK\t" ++ bb_word ++ "\t3\n", opt_loose);
    try t.expectEqual(@as(usize, 0), stale.errors.items.len);
    try t.expectEqual(@as(usize, 1), stale.warnings.items.len);
    try expectWarn(stale, "stale row `rules/x/BUCK " ++ bb_word ++ " 3`: 1 use(s) remain");
}

test "a row for a file with no use at all, or no such file, is stale, a warning and then red" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loose = try runWith(a, &.{}, "rules/gone/BUCK\t" ++ bb_word ++ "\t2\n", opt_loose);
    try t.expectEqual(@as(usize, 0), loose.errors.items.len);
    try expectWarn(loose, "stale row `rules/gone/BUCK " ++ bb_word ++ " 2`: 0 use(s) remain");
    const strict = try runWith(a, &.{}, "rules/gone/BUCK\t" ++ bb_word ++ "\t2\n", opt_strict);
    try expectErr(strict, "stale row `rules/gone/BUCK " ++ bb_word ++ " 2`");
    try t.expectEqual(@as(usize, 0), strict.warnings.items.len);
}

test "strict: any row at all is red, and an empty list over a clean tree is green" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try runWith(a, &.{one_bb}, "rules/x/BUCK\t" ++ bb_word ++ "\t1\n", opt_strict);
    try expectErr(rows, "1 row(s) remain");
    const clean = try runWith(a, &.{entryOf("rules/ok/BUCK", "x = 1\n")}, "# nothing\n", opt_strict);
    try t.expectEqual(@as(usize, 0), clean.errors.items.len);
    try t.expectEqual(@as(usize, 0), clean.warnings.items.len);
}

test "the permanent entries are green as they are, and need no row" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const rep = try run(arena.allocator(), &perm_tree, "", opt_strict);
    try t.expectEqual(@as(usize, 0), rep.errors.items.len);
    try t.expectEqual(@as(usize, 0), rep.current.len);
}

test "MUTANT: a second shell use in the installer's test is over the permanent entry, and a row covers only the excess" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const two = [_]Entry{
        perm_tree[0],
        .{ .path = "tools/install/install_script_test.zig", .text = "const x = &.{ \"/bin/s" ++ "h\", \"s" ++ "h\" };\n" },
    };
    const red = try run(a, &two, "", opt_loose);
    try expectErr(red, "tools/install/install_script_test.zig:1: [shell-word] 2 use(s) runs a shell interpreter, 1 allowed");
    const green = try run(a, &two, "tools/install/install_script_test.zig\tshell-word\t1\n", opt_loose);
    try t.expectEqual(@as(usize, 0), green.errors.items.len);
    try t.expectEqual(@as(usize, 0), green.warnings.items.len);
    const generated = try run(a, &two, green.current, opt_loose);
    try t.expectEqual(@as(usize, 0), generated.errors.items.len);
}

test "MUTANT: a permanent entry whose file no longer needs it is red; so is one whose file is gone" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rep = try run(a, &.{perm_tree[1]}, "", opt_loose);
    try expectErr(rep, "permanent entry site/static/install." ++ "sh sh-file: the file no longer needs it");
    try expectErr(rep, "permanent entry site/static/install." ++ "sh shebang");
    try t.expectEqual(@as(usize, 2), rep.errors.items.len);
    const swapped = [_]Entry{ perm_tree[0], .{ .path = "tools/install/install_script_test.zig", .text = "const x = 1;\n" } };
    const rep2 = try run(a, &swapped, "", opt_loose);
    try expectErr(rep2, "permanent entry tools/install/install_script_test.zig shell-word");
}

test "GREEN control: the same text under .github, docs and third_party is not read" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const bad = "x = busy" ++ "box\ny = [\"s" ++ "h\", \"-c\"]\n";
    const rep = try runWith(arena.allocator(), &.{
        entryOf(".github/workflows/ci.yml", "run: busy" ++ "box\n"),
        entryOf(".github/x.bzl", bad),
        entryOf(".github/run.s" ++ "h", "#!/bin/s" ++ "h\n"),
        entryOf("docs/x.bzl", bad),
        entryOf("docs/pins.md", "busy" ++ "box\n"),
        entryOf("third_party/aws-lc/BUCK", bad),
    }, "", opt_strict);
    try t.expectEqual(@as(usize, 0), rep.errors.items.len);
    try t.expectEqual(@as(usize, 0), rep.warnings.items.len);
    try t.expectEqual(@as(usize, 2), rep.scanned);
}

test "GREEN control: tools/held is not read while exclude_held holds, and is read when it does not" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const held = [_]Entry{ entryOf("tools/held/mirror.s" ++ "h", "#!/bin/ba" ++ "sh\n"), entryOf("tools/held/BUCK", "x = busy" ++ "box\n") };
    const skipped = try runWith(a, &held, "", .{ .strict = false, .held_excluded = true });
    try t.expectEqual(@as(usize, 0), skipped.errors.items.len);
    const read = try runWith(a, &held, "", .{ .strict = false, .held_excluded = false });
    try expectErr(read, "tools/held/BUCK:1: [" ++ bb_word ++ "]");
    try expectErr(read, "tools/held/mirror." ++ "sh:1: [sh-file]");
    try expectErr(read, "tools/held/mirror." ++ "sh:1: [shebang]");
    try t.expect(!excluded("tools/heldx/BUCK", opt_loose));
    try t.expect(!excluded("rules/docs/BUCK", opt_loose));
}

test "GREEN control: zig cc -c, the cdk arguments and a Zig comment about busy box leave a tree green" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const rep = try runWith(arena.allocator(), &.{
        entryOf("rules/coverage/tools/kcov_build.zig", "b.zigRun(\"cc\", cflags, &.{ \"-c\", join(a, &.{ g, \"version.c\" }), \"-o\", o });\n"),
        entryOf("rules/node/modules.bzl", "args = [\"cdk\", \"synth\", \"-c\", \"stage=prod\"]\n"),
        entryOf("rules/gate/x.zig", "// the applets of busy" ++ "box are gone: nothing here runs a shell\n"),
    }, "", opt_strict);
    try t.expectEqual(@as(usize, 0), rep.errors.items.len);
    try t.expectEqual(@as(usize, 0), rep.warnings.items.len);
}

test "the allow-list is read strictly: columns, rules, numbers, duplicates" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = try runWith(a, &.{}, "only-a-file\n" ++
        "a\t" ++ bb_word ++ "\n" ++
        "a\t" ++ bb_word ++ "\t1\textra\n" ++
        "a\tnot-a-rule\t1\n" ++
        "a\t" ++ bb_word ++ "\t0\n" ++
        "a\t" ++ bb_word ++ "\tmany\n" ++
        "b\t" ++ bb_word ++ "\t1\r\n" ++
        "b\t" ++ bb_word ++ "\t2\n", opt_loose);
    try expectErr(bad, "tsv:1: a row is file<TAB>rule<TAB>max");
    try expectErr(bad, "tsv:2: a row is file<TAB>rule<TAB>max");
    try expectErr(bad, "tsv:3: a row is file<TAB>rule<TAB>max: no fourth column");
    try expectErr(bad, "tsv:4: `not-a-rule` is not a rule");
    try expectErr(bad, "tsv:5: max `0` is not a number above zero");
    try expectErr(bad, "tsv:6: max `many` is not a number above zero");
    try expectErr(bad, "tsv:8: b " ++ bb_word ++ " is listed twice");
    try t.expectEqual(@as(usize, 7), bad.errors.items.len);
}

test "the list generated from a tree makes that tree green exactly, with no warning" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = [_]Entry{
        .{ .path = "rules/b.bzl", .text = "x = busy" ++ "box\ny = busy" ++ "box\nz = [\"s" ++ "h\", \"-euc\"]\n" },
        .{ .path = "rules/a/BUCK", .text = "x = busy" ++ "box\n" },
        .{ .path = "tools/z.s" ++ "h", .text = "" },
    };
    const first = try runWith(a, &tree, "", opt_loose);
    try t.expect(first.errors.items.len > 0);
    try t.expectEqualStrings(
        "rules/a/BUCK\t" ++ bb_word ++ "\t1\n" ++
            "rules/b.bzl\t" ++ bb_word ++ "\t2\n" ++
            "rules/b.bzl\tshell-word\t1\n" ++
            "rules/b.bzl\tshell-c\t1\n" ++
            "tools/z." ++ "sh\tsh-file\t1\n",
        first.current,
    );
    const second = try runWith(a, &tree, first.current, opt_loose);
    try t.expectEqual(@as(usize, 0), second.errors.items.len);
    try t.expectEqual(@as(usize, 0), second.warnings.items.len);
}


test "the defaults of Options are the constants a later step of the migration flips" {
    const o = Options{};
    try t.expectEqual(strict_stale, o.strict);
    try t.expectEqual(exclude_held, o.held_excluded);
}

test "the vocabulary: every rule has a name and a sentence, and parses back" {
    for (std.enums.values(Rule)) |r| {
        try t.expect(r.name().len > 0 and r.what().len > 0);
        try t.expectEqual(r, Rule.parse(r.name()).?);
    }
    try t.expect(Rule.parse("nope") == null);
    for (permanent) |p| try t.expect(p.why.len > 20);
}

test "this file holds none of what it refuses (its tests spell the words in parts)" {
    try expectShape("ci/no_shell_check.zig", @embedFile("no_shell_check.zig"), "");
}
