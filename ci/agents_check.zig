//! AGENTS.md (the rules every change is written and reviewed against) and CLAUDE.md (which imports it). A pure function of the texts, so each
//! rule is tested against an edited copy as well as against the real files (the zig_test's `data`, under BUILDRULES_TEST_WORK).
//!
//! What the rules catch:
//!  - a shared core that drifted: the text between the two marker lines of AGENTS.md is, byte for byte, ci/shared_core.md (the first line
//!    that differs is named, in both files);
//!  - a copy edited along with it: ci/shared_core.sha256 is `<sha256 of ci/shared_core.md, lowercase hex>  shared_core.md` and one newline, the
//!    form `sha256sum` writes, and the digest is the copy's;
//!  - markers that cannot delimit the core: each of the two is a line of its own, exactly once, the begin before the end;
//!  - a CLAUDE.md that no longer imports AGENTS.md: its first line is exactly `@AGENTS.md` (anything before or after it on that line, a carriage
//!    return included, or the import on a later line, is not one). Nothing precedes the first line, so no code block, code span or comment can
//!    hold it, and the rest of the file is the repository's own notes.
const std = @import("std");
const t = std.testing;

pub const Findings = std.ArrayList([]const u8);

pub const begin_marker = "<!-- shared-core:begin -->";
pub const end_marker = "<!-- shared-core:end -->";
pub const import_line = "@AGENTS.md";
const copy_name = "shared_core.md";

fn add(a: std.mem.Allocator, f: *Findings, comptime fmt: []const u8, args: anytype) !void {
    try f.append(try std.fmt.allocPrint(a, fmt, args));
}

/// A marker line of `text`: its 1-based line number, where the line starts and where the text after it starts.
const Marker = struct { line: usize, start: usize, after: usize };

/// Every line of `text` that is exactly `marker`.
fn markers(a: std.mem.Allocator, text: []const u8, marker: []const u8) ![]Marker {
    var out = std.ArrayList(Marker).init(a);
    var start: usize = 0;
    var n: usize = 1;
    while (start <= text.len) : (n += 1) {
        const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
        const stop = nl orelse text.len;
        if (std.mem.eql(u8, text[start..stop], marker)) try out.append(.{ .line = n, .start = start, .after = if (nl) |i| i + 1 else text.len });
        start = stop + 1;
    }
    return out.items;
}

/// The shared core of AGENTS.md (the text after the begin line, up to the end line) and the line it starts on, or null with findings.
pub fn core(a: std.mem.Allocator, f: *Findings, agents: []const u8) !?struct { text: []const u8, first_line: usize } {
    const b = try markers(a, agents, begin_marker);
    const e = try markers(a, agents, end_marker);
    if (b.len != 1) try add(a, f, "AGENTS.md: the line `{s}` is there {d} times, not once", .{ begin_marker, b.len });
    if (e.len != 1) try add(a, f, "AGENTS.md: the line `{s}` is there {d} times, not once", .{ end_marker, e.len });
    if (b.len != 1 or e.len != 1) return null;
    if (e[0].start < b[0].after) {
        try add(a, f, "AGENTS.md:{d}: the end of the shared core comes before its begin (line {d})", .{ e[0].line, b[0].line });
        return null;
    }
    return .{ .text = agents[b[0].after..e[0].start], .first_line = b[0].line + 1 };
}

/// The lines of a text, without their newlines: an empty text has none, and a final newline ends the last line rather than starting one.
const Lines = struct {
    rest: ?[]const u8,

    fn of(text: []const u8) Lines {
        if (text.len == 0) return .{ .rest = null };
        return .{ .rest = if (text[text.len - 1] == '\n') text[0 .. text.len - 1] else text };
    }

    fn next(self: *Lines) ?[]const u8 {
        const r = self.rest orelse return null;
        if (std.mem.indexOfScalar(u8, r, '\n')) |i| {
            self.rest = r[i + 1 ..];
            return r[0..i];
        }
        self.rest = null;
        return r;
    }
};

/// The first line where `got` (the core of AGENTS.md, starting on line `first_line`) and `want` (ci/shared_core.md) differ.
pub fn sameCore(a: std.mem.Allocator, f: *Findings, got: []const u8, first_line: usize, want: []const u8) !void {
    if (std.mem.eql(u8, got, want)) return;
    var g = Lines.of(got);
    var w = Lines.of(want);
    var n: usize = 1;
    while (true) : (n += 1) {
        const gl = g.next();
        const wl = w.next();
        if (gl == null and wl == null) {
            // every line the same: the texts differ in the newline after the last one
            try add(a, f, "AGENTS.md:{d}: the shared core differs from ci/{s} in the newline after its last line", .{ first_line + n - 2, copy_name });
            return;
        }
        if (gl != null and wl != null and std.mem.eql(u8, gl.?, wl.?)) continue;
        try add(a, f, "AGENTS.md:{d}: the shared core differs from ci/{s}:{d}: `{s}` against `{s}` (change the core in AGENTS.md, ci/{s} and ci/shared_core.sha256 together)", .{
            first_line + n - 1, copy_name, n, gl orelse "(the end of the core)", wl orelse "(the end of the copy)", copy_name,
        });
        return;
    }
}

/// ci/shared_core.sha256 is the `sha256sum` line of ci/shared_core.md, and its digest is the copy's.
pub fn sameHash(a: std.mem.Allocator, f: *Findings, sums: []const u8, copy: []const u8) !void {
    const tail = "  " ++ copy_name ++ "\n";
    const well_formed = sums.len == 64 + tail.len and std.mem.eql(u8, sums[64..], tail) and for (sums[0..64]) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) break false;
    } else true;
    if (!well_formed) {
        try add(a, f, "ci/shared_core.sha256 is not one line `<64 lowercase hex>  {s}` (what `sha256sum {s}` writes): `{s}`", .{ copy_name, copy_name, sums });
        return;
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(copy, &digest, .{});
    const have = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, sums[0..64], &have)) try add(a, f, "ci/shared_core.sha256 names {s}, but ci/{s} hashes to {s}: the canonical core changed", .{ sums[0..64], copy_name, &have });
}

/// CLAUDE.md imports AGENTS.md on its first line, which is exactly `@AGENTS.md`. The first line, because nothing comes before it that could
/// open a code block, a code span or a comment around it: what follows it, the repository's own notes, needs no reading.
pub fn imports(a: std.mem.Allocator, f: *Findings, claude: []const u8) !void {
    const first = claude[0 .. std.mem.indexOfScalar(u8, claude, '\n') orelse claude.len];
    if (!std.mem.eql(u8, first, import_line)) try add(a, f, "CLAUDE.md does not import AGENTS.md: its first line is not exactly `{s}`", .{import_line});
}

/// Everything wrong with AGENTS.md, ci/shared_core.md, ci/shared_core.sha256 and CLAUDE.md.
pub fn check(a: std.mem.Allocator, agents: []const u8, copy: []const u8, sums: []const u8, claude: []const u8) !Findings {
    var f = Findings.init(a);
    if (try core(a, &f, agents)) |c| try sameCore(a, &f, c.text, c.first_line, copy);
    try sameHash(a, &f, sums, copy);
    try imports(a, &f, claude);
    return f;
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

fn work(a: std.mem.Allocator, sub: []const u8) ![]const u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    return std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ w, sub }), 1 << 20);
}

const Real = struct { agents: []const u8, copy: []const u8, sums: []const u8, claude: []const u8 };

fn real(a: std.mem.Allocator) !Real {
    return .{ .agents = try work(a, "AGENTS.md"), .copy = try work(a, "ci/shared_core.md"), .sums = try work(a, "ci/shared_core.sha256"), .claude = try work(a, "CLAUDE.md") };
}

/// `text` with its one `from` replaced by `to`.
fn edit(a: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, text, from));
    const at = std.mem.indexOf(u8, text, from).?;
    return std.mem.concat(a, u8, &.{ text[0..at], to, text[at + from.len ..] });
}

fn sumsOf(a: std.mem.Allocator, copy: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(copy, &digest, .{});
    return std.fmt.allocPrint(a, "{s}  shared_core.md\n", .{std.fmt.bytesToHex(digest, .lower)});
}

/// The findings of `check` are exactly `want`, in order.
fn expectFindings(agents: []const u8, copy: []const u8, sums: []const u8, claude: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const f = try check(arena.allocator(), agents, copy, sums, claude);
    for (f.items) |x| std.debug.print("finding: {s}\n", .{x});
    try t.expectEqual(want.len, f.items.len);
    for (want, f.items) |w, g| try t.expectEqualStrings(w, g);
}

const small_core = "## Core\n\n- X1 BLOCK. One rule.\n- X2 SHOULD. Another.\n";
const small_agents = "# AGENTS.md\n\nIntro.\n\n" ++ begin_marker ++ "\n" ++ small_core ++ end_marker ++ "\n\n## Repo\n";

test "the real AGENTS.md, its core copy, the copy's hash and CLAUDE.md agree" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const r = try real(arena.allocator());
    try expectFindings(r.agents, r.copy, r.sums, r.claude, &.{});
}

test "the real core is the canonical core, and a change in it is found in the real files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try real(a);
    const from = "never demand above 99.";
    const to = "never demand above 95.";
    const changed = try edit(a, r.agents, from, to);
    // the line of T1 in each file, and its text
    const in_agents = std.mem.indexOf(u8, r.agents, from).?;
    const in_copy = std.mem.indexOf(u8, r.copy, from).?;
    const start = std.mem.lastIndexOfScalar(u8, r.copy[0..in_copy], '\n').? + 1;
    const line = r.copy[start..std.mem.indexOfScalarPos(u8, r.copy, in_copy, '\n').?];
    try expectFindings(changed, r.copy, r.sums, r.claude, &.{
        try std.fmt.allocPrint(a, "AGENTS.md:{d}: the shared core differs from ci/shared_core.md:{d}: `{s}` against `{s}` (change the core in AGENTS.md, ci/shared_core.md and ci/shared_core.sha256 together)", .{
            std.mem.count(u8, r.agents[0..in_agents], "\n") + 1, std.mem.count(u8, r.copy[0..in_copy], "\n") + 1, try edit(a, line, from, to), line,
        }),
    });
    // the same change in the copy too: the hash finds it
    const changed_copy = try edit(a, r.copy, from, to);
    try expectFindings(changed, changed_copy, r.sums, r.claude, &.{
        try std.fmt.allocPrint(a, "ci/shared_core.sha256 names {s}, but ci/shared_core.md hashes to {s}: the canonical core changed", .{ r.sums[0..64], (try sumsOf(a, changed_copy))[0..64] }),
    });
}

test "a small AGENTS.md whose core is its copy, with the copy's hash, has no finding" {
    const s = try sumsOf(t.allocator, small_core);
    defer t.allocator.free(s);
    try expectFindings(small_agents, small_core, s, "@AGENTS.md\n", &.{});
}

test "a changed line of the core is named with its line in both files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sumsOf(a, small_core);
    try expectFindings(try edit(a, small_agents, "Another.", "Another one."), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md:9: the shared core differs from ci/shared_core.md:4: `- X2 SHOULD. Another one.` against `- X2 SHOULD. Another.` (change the core in AGENTS.md, ci/shared_core.md and ci/shared_core.sha256 together)",
    });
}

test "a core longer or shorter than its copy is found where one of them ends" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sumsOf(a, small_core);
    // a rule added at the end of the core in AGENTS.md alone
    try expectFindings(try edit(a, small_agents, "Another.\n", "Another.\n- X3 SHOULD. New.\n"), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md:10: the shared core differs from ci/shared_core.md:5: `- X3 SHOULD. New.` against `(the end of the copy)` (change the core in AGENTS.md, ci/shared_core.md and ci/shared_core.sha256 together)",
    });
    // the last rule of the core removed from AGENTS.md alone
    try expectFindings(try edit(a, small_agents, "- X2 SHOULD. Another.\n", ""), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md:9: the shared core differs from ci/shared_core.md:4: `(the end of the core)` against `- X2 SHOULD. Another.` (change the core in AGENTS.md, ci/shared_core.md and ci/shared_core.sha256 together)",
    });
    // a core that is empty, against a copy that is not
    const empty = "# AGENTS.md\n" ++ begin_marker ++ "\n" ++ end_marker ++ "\n";
    try expectFindings(empty, small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md:3: the shared core differs from ci/shared_core.md:1: `(the end of the core)` against `## Core` (change the core in AGENTS.md, ci/shared_core.md and ci/shared_core.sha256 together)",
    });
    // an empty line added at the end of the core: a line, not the end
    try expectFindings(try edit(a, small_agents, "Another.\n", "Another.\n\n"), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md:10: the shared core differs from ci/shared_core.md:5: `` against `(the end of the copy)` (change the core in AGENTS.md, ci/shared_core.md and ci/shared_core.sha256 together)",
    });
}

test "empty and blank cores are compared like any other" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const around = struct {
        fn of(comptime core_text: []const u8) []const u8 {
            return "# AGENTS.md\n" ++ begin_marker ++ "\n" ++ core_text ++ end_marker ++ "\n";
        }
    }.of;
    // adjacent markers and an empty copy: the same, no finding
    try expectFindings(around(""), "", try sumsOf(a, ""), "@AGENTS.md\n", &.{});
    // a core against an empty copy
    try expectFindings(small_agents, "", try sumsOf(a, ""), "@AGENTS.md\n", &.{
        "AGENTS.md:6: the shared core differs from ci/shared_core.md:1: `## Core` against `(the end of the copy)` (change the core in AGENTS.md, ci/shared_core.md and ci/shared_core.sha256 together)",
    });
    // blank-only cores: the same two empty lines, no finding
    try expectFindings(around("\n\n"), "\n\n", try sumsOf(a, "\n\n"), "@AGENTS.md\n", &.{});
    // two empty lines against one
    try expectFindings(around("\n\n"), "\n", try sumsOf(a, "\n"), "@AGENTS.md\n", &.{
        "AGENTS.md:4: the shared core differs from ci/shared_core.md:2: `` against `(the end of the copy)` (change the core in AGENTS.md, ci/shared_core.md and ci/shared_core.sha256 together)",
    });
    // one empty line against none
    try expectFindings(around("\n"), "", try sumsOf(a, ""), "@AGENTS.md\n", &.{
        "AGENTS.md:3: the shared core differs from ci/shared_core.md:1: `` against `(the end of the copy)` (change the core in AGENTS.md, ci/shared_core.md and ci/shared_core.sha256 together)",
    });
}

test "a core that differs only in its final newline is found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the copy lost its last newline (an editor that strips it), the core in AGENTS.md did not
    const short = small_core[0 .. small_core.len - 1];
    try expectFindings(small_agents, short, try sumsOf(a, short), "@AGENTS.md\n", &.{
        "AGENTS.md:9: the shared core differs from ci/shared_core.md in the newline after its last line",
    });
}

test "a line ending changed to CRLF is a difference" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sumsOf(a, small_core);
    try expectFindings(try edit(a, small_agents, "One rule.\n", "One rule.\r\n"), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md:8: the shared core differs from ci/shared_core.md:3: `- X1 BLOCK. One rule.\r` against `- X1 BLOCK. One rule.` (change the core in AGENTS.md, ci/shared_core.md and ci/shared_core.sha256 together)",
    });
}

test "markers that are missing, doubled, not a line of their own or out of order are found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sumsOf(a, small_core);
    const begin_twice = "The begin `" ++ begin_marker ++ "` once more.\n";
    try expectFindings(try edit(a, small_agents, begin_marker ++ "\n", ""), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md: the line `<!-- shared-core:begin -->` is there 0 times, not once",
    });
    try expectFindings(try edit(a, small_agents, end_marker ++ "\n", ""), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md: the line `<!-- shared-core:end -->` is there 0 times, not once",
    });
    // both missing: both named
    try expectFindings("# AGENTS.md\n", small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md: the line `<!-- shared-core:begin -->` is there 0 times, not once",
        "AGENTS.md: the line `<!-- shared-core:end -->` is there 0 times, not once",
    });
    // a second begin line
    try expectFindings(try edit(a, small_agents, "## Repo\n", "## Repo\n" ++ begin_marker ++ "\n"), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md: the line `<!-- shared-core:begin -->` is there 2 times, not once",
    });
    // a second end line
    try expectFindings(try edit(a, small_agents, "## Repo\n", "## Repo\n" ++ end_marker ++ "\n"), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md: the line `<!-- shared-core:end -->` is there 2 times, not once",
    });
    // both doubled: both named
    try expectFindings(try edit(a, small_agents, "## Repo\n", "## Repo\n" ++ begin_marker ++ "\n" ++ end_marker ++ "\n"), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md: the line `<!-- shared-core:begin -->` is there 2 times, not once",
        "AGENTS.md: the line `<!-- shared-core:end -->` is there 2 times, not once",
    });
    // a marker inside a sentence is not a marker line, so it is neither counted nor taken for the core's edge
    try expectFindings(try edit(a, small_agents, "Intro.\n", begin_twice), small_core, s, "@AGENTS.md\n", &.{});
    // a marker with a trailing space is not the marker
    try expectFindings(try edit(a, small_agents, end_marker ++ "\n", end_marker ++ " \n"), small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md: the line `<!-- shared-core:end -->` is there 0 times, not once",
    });
    // the end before the begin
    const swapped = "# AGENTS.md\n" ++ end_marker ++ "\n" ++ small_core ++ begin_marker ++ "\n";
    try expectFindings(swapped, small_core, s, "@AGENTS.md\n", &.{
        "AGENTS.md:2: the end of the shared core comes before its begin (line 7)",
    });
}

test "an end marker on the last line without a newline still ends the core" {
    const s = try sumsOf(t.allocator, small_core);
    defer t.allocator.free(s);
    try expectFindings(begin_marker ++ "\n" ++ small_core ++ end_marker, small_core, s, "@AGENTS.md\n", &.{});
}

test "a hash file that is not the sha256sum line of the copy is found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try sumsOf(a, small_core);
    const malformed = [_][]const u8{
        s[0 .. s.len - 1], // no newline
        try std.mem.concat(a, u8, &.{ s, "\n" }), // a second line
        try std.mem.concat(a, u8, &.{ try std.ascii.allocUpperString(a, s[0..64]), s[64..] }), // uppercase hex, the name as it is
        try edit(a, s, "  shared_core.md", " shared_core.md"), // one space
        try edit(a, s, "  shared_core.md", "  AGENTS.md"), // another file
        try std.mem.concat(a, u8, &.{ "g", s[1..] }), // a character that is not hex
        s[1..], // 63 digits
        "",
    };
    for (malformed) |m| {
        const want = try std.fmt.allocPrint(a, "ci/shared_core.sha256 is not one line `<64 lowercase hex>  shared_core.md` (what `sha256sum shared_core.md` writes): `{s}`", .{m});
        try expectFindings(small_agents, small_core, m, "@AGENTS.md\n", &.{want});
    }
    // well formed, but another digest
    const zeros = "0" ** 64 ++ "  shared_core.md\n";
    try expectFindings(small_agents, small_core, zeros, "@AGENTS.md\n", &.{
        try std.fmt.allocPrint(a, "ci/shared_core.sha256 names {s}, but ci/shared_core.md hashes to {s}: the canonical core changed", .{ "0" ** 64, s[0..64] }),
    });
}

test "CLAUDE.md imports AGENTS.md only on its first line, exactly" {
    const s = try sumsOf(t.allocator, small_core);
    defer t.allocator.free(s);
    const missing = [_][]const u8{
        "",
        "\n" ++ import_line ++ "\n", // an empty first line
        "# CLAUDE.md\n\n" ++ import_line ++ "\n", // on a later line
        "# CLAUDE.md\n\nRead AGENTS.md.\n",
        "Read @AGENTS.md first.\n", // inside a sentence
        "@AGENTS.md.bak\n", // another file
        "@AGENTS.md \n", // anything after it
        "@AGENTS.md\t\n",
        " @AGENTS.md\n", // anything before it
        "`@AGENTS.md`\n", // a code span
        "<!-- @AGENTS.md -->\n", // a comment
        "@agents.md\n", // another case
        "@AGENTS.md\r\n", // a CRLF line: strict, as the core is
        "```\n" ++ import_line ++ "\n```\n", // inside a fence
        "~~~\n~~~text\n" ++ import_line ++ "\n~~~\n", // inside a fence whose closing-looking line does not close it
        "`\n" ++ import_line ++ "\n`\n", // inside a code span over lines
        "``\n" ++ import_line ++ "\n``\n",
    };
    for (missing) |c| try expectFindings(small_agents, small_core, s, c, &.{"CLAUDE.md does not import AGENTS.md: its first line is not exactly `@AGENTS.md`"});
    const present = [_][]const u8{
        "@AGENTS.md\n",
        "@AGENTS.md", // no newline
        "@AGENTS.md\n\n# The repository's own notes\n\nMore text.\n", // followed by notes
        "@AGENTS.md\n```\nan unclosed fence after it\n", // what follows is never read
        "@AGENTS.md\n`\n", // nor a backtick after it
    };
    for (present) |c| try expectFindings(small_agents, small_core, s, c, &.{});
}

test "every problem of the four files is reported together" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFindings(try edit(a, small_agents, "One rule.", "One changed rule."), small_core, "", "", &.{
        "AGENTS.md:8: the shared core differs from ci/shared_core.md:3: `- X1 BLOCK. One changed rule.` against `- X1 BLOCK. One rule.` (change the core in AGENTS.md, ci/shared_core.md and ci/shared_core.sha256 together)",
        "ci/shared_core.sha256 is not one line `<64 lowercase hex>  shared_core.md` (what `sha256sum shared_core.md` writes): ``",
        "CLAUDE.md does not import AGENTS.md: its first line is not exactly `@AGENTS.md`",
    });
    // markers that cannot delimit the core, with a bad hash and no import: every problem, and no comparison of a core there is none of
    const bad = "# CLAUDE.md\n";
    try expectFindings("# AGENTS.md\n" ++ end_marker ++ "\n" ++ end_marker ++ "\n", small_core, "x", bad, &.{
        "AGENTS.md: the line `<!-- shared-core:begin -->` is there 0 times, not once",
        "AGENTS.md: the line `<!-- shared-core:end -->` is there 2 times, not once",
        "ci/shared_core.sha256 is not one line `<64 lowercase hex>  shared_core.md` (what `sha256sum shared_core.md` writes): `x`",
        "CLAUDE.md does not import AGENTS.md: its first line is not exactly `@AGENTS.md`",
    });
    try expectFindings(end_marker ++ "\n" ++ begin_marker ++ "\n", small_core, "", bad, &.{
        "AGENTS.md:1: the end of the shared core comes before its begin (line 2)",
        "ci/shared_core.sha256 is not one line `<64 lowercase hex>  shared_core.md` (what `sha256sum shared_core.md` writes): ``",
        "CLAUDE.md does not import AGENTS.md: its first line is not exactly `@AGENTS.md`",
    });
}
