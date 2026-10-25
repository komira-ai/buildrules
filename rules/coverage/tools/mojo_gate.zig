//! mojo_gate: platform-gated functions, the functions of the uncompiled report that no build for the measured target can reach, because every use of
//! them sits in a compile-time arm that build dropped (the full-source checker's rule, its platform_gate.mojo:1-30).
//!
//! A function the report lists as uncompiled and whose uses are all inside `comptime if` / `@parameter` arms that were not compiled here (an AVX-512
//! path on a machine without AVX-512, a NEON path on x86) is not an uncalled function: its callers exist and are dropped on this target. It is left
//! out of the numbers and listed, whatever its class. The proof is from the uses, found in the sources of the function's package (its tests
//! included). This direction hides code, so a use is anything that could be one:
//!
//! * a **use** is any occurrence of the function's name as an identifier in the code of the package: a call (`name(`, `x.name(`, `mod.name(`), a
//!   function passed as a value, a method reference. Comments, strings (a multi-line string's interior too), import lines and the function's own
//!   declaration name are not uses. An alias (`from x import name as z`) makes every use of `z` a use of `name`. Every use of the name counts, so a
//!   same-named function elsewhere in the package that is used live keeps the function counted;
//! * a use is **dropped** when it is in a function the reports show compiled (one of its own lines has a record), inside one of that function's
//!   compile-time arms, **and no line of that arm has a record**: the arm was not compiled. One line without a record is not enough: a continuation
//!   line of a multi-line call, or a line the compiler attributed elsewhere, sits in an arm that was compiled. A use on the line of the `comptime if`
//!   condition itself is live (the condition runs whichever arm is compiled). A use inside a function that is itself platform-gated is dropped too (a
//!   chain: computed to a fixpoint);
//! * any other use is live: a line outside every arm, an arm with a record, a function no report shows compiled that is not gated, a line outside any
//!   function.
//!
//! A name the package declares more than once is never gated. A function qualifies only with at least one use (not counting its own body) and every use
//! dropped; with no use it counts as uncovered, as an uncalled function does. A group of functions that call only each other, reachable only from a
//! dropped arm, is not gated either: the fixpoint starts from nothing gated and each function needs a dropped use, so such a cycle stays counted.

const std = @import("std");
const src = @import("mojo_src.zig");
const calls = @import("mojo_calls.zig");
const Alloc = std.mem.Allocator;

/// A function with lines in the uncompiled report: its file, name, `def` line and the number of its own lines the report lists
/// (the full-source checker's platform_gate.mojo:37-50).
pub const Cand = struct { path: []const u8, name: []const u8, line: usize, lines: usize };

/// Per path, the lines some report gives a record (whatever their hits).
pub const Recorded = std.StringArrayHashMapUnmanaged(src.LineSet);

const Site = struct {
    path: []const u8,
    line: usize,
    /// The index of the innermost function of the file around the use; null at the top level.
    owner: ?usize,
};

const FileInfo = struct { fns: []src.Fn, compiled: []bool };

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The identifiers of the code of `line`, in order: not those in a comment or inside a quoted string, and no number (the full-source checker's platform_gate.mojo:78-113).
fn tokens(a: Alloc, line: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    const n = line.len;
    var quote: u8 = 0;
    var i: usize = 0;
    var start: ?usize = null;
    while (i <= n) {
        const c: ?u8 = if (i < n) line[i] else null;
        if (quote != 0) {
            if (c != null and c.? == '\\') {
                i += 2;
                continue;
            }
            if (c != null and c.? == quote) quote = 0;
            i += 1;
            continue;
        }
        if (c != null and isIdent(c.?)) {
            if (start == null) start = i;
        } else {
            if (start) |s| {
                if (!std.ascii.isDigit(line[s])) try out.append(a, line[s..i]);
                start = null;
            }
            if (c != null and c.? == '#') break;
            if (c != null and (c.? == '"' or c.? == '\'')) quote = c.?;
        }
        i += 1;
    }
    return out.toOwnedSlice(a);
}

fn keyOf(a: Alloc, path: []const u8, line: usize) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}:{d}", .{ path, line });
}

fn recordedHas(recorded: *const Recorded, path: []const u8, ln: usize) bool {
    const set = recorded.get(path) orelse return false;
    return set.contains(ln);
}

/// For each candidate (functions of one package whose files are `texts`), whether it is platform-gated. `recorded` holds, per path, the lines any
/// test report gives a record (the full-source checker's platform_gate.mojo:129-253).
pub fn platformGated(a: Alloc, texts: []const calls.Source, recorded: *const Recorded, cands: []const Cand) ![]bool {
    var files = std.StringArrayHashMapUnmanaged(FileInfo).empty;
    var sites = std.StringArrayHashMapUnmanaged(std.ArrayList(Site)).empty;
    var track: calls.Keys = .empty;
    for (cands) |c| try track.put(a, c.name, {});
    // The aliases of the package: a use of one is a use of the name it stands for.
    var alias_of = std.StringArrayHashMapUnmanaged([]const u8).empty;
    for (texts) |t| {
        for (try src.lexSource(a, t.text)) |l| {
            if (!l.is_import) continue;
            const tk = try tokens(a, l.text);
            var k: usize = 0;
            while (k + 2 < tk.len) : (k += 1) {
                if (std.mem.eql(u8, tk[k + 1], "as") and track.contains(tk[k])) try alias_of.put(a, tk[k + 2], tk[k]);
            }
        }
    }
    for (texts) |t| {
        const ls = try src.lexSource(a, t.text);
        const fns = try src.declaredFunctions(a, t.text);
        const compiled = try a.alloc(bool, fns.len);
        for (fns, compiled) |f, *c| {
            c.* = false;
            for (f.lines) |ln| c.* = c.* or recordedHas(recorded, t.path, ln);
        }
        for (ls, 1..) |l, ln| {
            if (!l.code or l.in_string or l.is_import) continue;
            const toks = try tokens(a, l.text);
            if (toks.len == 0) continue;
            // The name a declaration gives is no use: `def name(` / `fn name(`.
            var skip: ?usize = null;
            if (toks.len >= 2 and (std.mem.eql(u8, toks[0], "def") or std.mem.eql(u8, toks[0], "fn"))) skip = 1;
            // The innermost function whose range holds the line.
            var inner: ?usize = null;
            for (fns, 0..) |f, k| {
                if (ln > f.line and ln <= f.end and (inner == null or f.line > fns[inner.?].line)) inner = k;
            }
            for (toks, 0..) |tok, q| {
                if (skip != null and q == skip.?) continue;
                const key = alias_of.get(tok) orelse tok;
                if (!track.contains(key)) continue;
                const gop = try sites.getOrPut(a, key);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(a, .{ .path = t.path, .line = ln, .owner = inner });
            }
        }
        try files.put(a, t.path, .{ .fns = fns, .compiled = compiled });
    }
    // A name the package declares more than once is told apart from nothing here either: it is counted, as the call evidence counts it.
    const dups = try calls.declaredTwice(a, texts);
    var gated: calls.Keys = .empty; // "<path>:<def line>"
    const out = try a.alloc(bool, cands.len);
    @memset(out, false);
    var changed = true;
    while (changed) {
        changed = false;
        for (cands, 0..) |cand, c| {
            if (out[c] or !files.contains(cand.path) or dups.contains(cand.name)) continue;
            const list = sites.get(cand.name) orelse continue;
            var n_sites: usize = 0;
            var all_dropped = true;
            for (list.items) |st| {
                // A use inside the function itself (recursion) says nothing about its callers.
                if (st.owner) |o| {
                    if (std.mem.eql(u8, st.path, cand.path) and files.get(st.path).?.fns[o].line == cand.line) continue;
                }
                n_sites += 1;
                var dropped = false;
                if (st.owner) |o| {
                    const info = files.get(st.path).?;
                    const g = info.fns[o];
                    if (gated.contains(try keyOf(a, st.path, g.line))) {
                        dropped = true;
                    } else if (info.compiled[o]) {
                        // Dropped when an arm around the line has no record on any of its lines.
                        for (g.arm_blocks) |blk| {
                            var holds = false;
                            var recorded_any = false;
                            for (blk) |ln| {
                                if (ln == st.line) holds = true;
                                if (recordedHas(recorded, st.path, ln)) recorded_any = true;
                            }
                            if (holds and !recorded_any) dropped = true;
                        }
                    }
                }
                if (!dropped) {
                    all_dropped = false;
                    break;
                }
            }
            if (n_sites > 0 and all_dropped) {
                out[c] = true;
                try gated.put(a, try keyOf(a, cand.path, cand.line), {});
                changed = true;
            }
        }
    }
    return out;
}
