//! scrub: the public-repository check. It reads every file of the repository (the inputs the rule `scrub_test` collects from every
//! package) and fails on what must not be published:
//!
//!   - a date before 2026-09-01 in any spelling (ISO, compact, month names, the two bare years before the cutoff year);
//!   - a person's name, an email address, a home path, a host name of a private network, an IPv4 address (loopback and the
//!     documentation ranges excepted), a remote-execution endpoint;
//!   - the vocabulary of a private control plane, and the name of the project this one grew out of (case-insensitive), except in the
//!     two public repository paths this repository and its mopm releases live at.
//!
//! The only allowances are facts that are not ours and not dates: the Rust edition "2024" (the name of a language edition) and the
//! address of a third-party package author inside npm's own metadata in a lock file. They are reported as `allowed`, with the reason, and
//! never silently: the report ends with the count of each reason. A release date of a pinned artifact is a hit: pins use versioned URLs.
//!
//! usage: scrub <out> [--require <name>]... (<name> <file>)...
//! Writes <out> (the report) and exits 0 only when no hit is left. `--require` names files that must be among the inputs, so a rule
//! whose globs came up empty is red and not green.
//!
//! The banned words are spelled in parts here and in the tests, so this file does not hold them.

const std = @import("std");

pub const Hit = struct {
    file: []const u8,
    line: usize,
    rule: []const u8,
    /// Set when the hit is a fact about an upstream artifact: the reason it is allowed.
    allowed: ?[]const u8,
    text: []const u8,
};

// ---- the vocabulary (in parts, so that this file does not contain it) ------------------------------------------------------

const words_ci = [_][]const u8{
    "ad" ++ "i",
    "sur" ++ "esh",
    "ad" ++ "itya",
    "ash" ++ "win",
    "jer" ++ "ry",
    "mi" ++ "ra",
    "k" ++ "bf",
    "fl" ++ "eet",
    "engin" ++ "eering",
    "sa" ++ "les",
    "tho" ++ "rium",
};
const words_cs = [_][]const u8{"C" ++ "EO"};
const subs_ci = [_][]const u8{ "tail" ++ "scale", "tail" ++ "net", ".ts" ++ ".net", "/ho" ++ "me/", "/Us" ++ "ers/", ".inter" ++ "nal", ".co" ++ "rp" };
const project_ci = "kom" ++ "ira";
/// The exact public addresses that may carry the project name: this repository, and the release downloads of its sibling tool.
const url_head = "https://github.com/";
const repo_url = url_head ++ "kom" ++ "ira-ai/build" ++ "rules";
const releases_url = url_head ++ "kom" ++ "ira-ai/mo" ++ "pm/releases/";

pub const cutoff_year = 2026;
pub const cutoff_month = 9;

fn isAlnum(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn lowerEq(hay: []const u8, at: usize, needle: []const u8) bool {
    if (at + needle.len > hay.len) return false;
    for (needle, 0..) |c, i| if (std.ascii.toLower(hay[at + i]) != std.ascii.toLower(c)) return false;
    return true;
}

fn boundedAt(line: []const u8, at: usize, len: usize) bool {
    if (at > 0 and isAlnum(line[at - 1])) return false;
    if (at + len < line.len and isAlnum(line[at + len])) return false;
    return true;
}

// ---- allowed dates ----------------------------------------------------------------------------------------------------------

/// Why a date on `line` is a fact about an upstream artifact, or null.
pub const why_edition = "a Rust edition";
pub const why_npm = "an author's address inside the metadata of a third-party npm package";
/// The one address that is ours: the maintainer of the .deb packages (packaging/deb/control), a no-reply address of the code host, spelled in parts.
pub const why_maintainer = "the no-reply maintainer address of the .deb packages";
const maintainer_address = "buildrules@" ++ "users.noreply." ++ "github.com";

/// Why a date on `line` is not a date, or null. Only the Rust edition ("2024" is the name of a language edition).
pub fn upstreamReason(line: []const u8) ?[]const u8 {
    if (std.ascii.indexOfIgnoreCase(line, "edition") != null) return why_edition;
    return null;
}

fn pre(y: u32, m: u32) bool {
    return y < cutoff_year or (y == cutoff_year and m < cutoff_month);
}

fn digitsAt(s: []const u8, at: usize, n: usize) ?u32 {
    if (at + n > s.len) return null;
    var v: u32 = 0;
    for (s[at .. at + n]) |c| {
        if (!isDigit(c)) return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

const months = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
const month_names = [_][]const u8{ "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december" };

fn monthOf(word: []const u8) ?u32 {
    for (months, month_names, 1..) |ab, full, n| {
        if (std.ascii.eqlIgnoreCase(word, ab) or std.ascii.eqlIgnoreCase(word, full)) return @intCast(n);
    }
    if (std.ascii.eqlIgnoreCase(word, "sept")) return 9;
    return null;
}

/// The month (1-12) named just before the year at `at`: a month name, then an optional day, then the year.
fn monthBefore(line: []const u8, at: usize) ?u32 {
    var j = at;
    while (j > 0 and (line[j - 1] == ' ' or line[j - 1] == ',')) j -= 1;
    if (j == at) return null;
    // an optional day ("20,", "3rd,") between the month and the year
    var k = j;
    while (k > 0 and (isDigit(line[k - 1]) or std.ascii.isAlphabetic(line[k - 1]))) k -= 1;
    if (k < j and isDigit(line[k])) {
        var m = k;
        while (m > 0 and line[m - 1] == ' ') m -= 1;
        if (m == k) return null;
        j = m;
    }
    var w = j;
    while (w > 0 and std.ascii.isAlphabetic(line[w - 1])) w -= 1;
    const word = line[w..j];
    return monthOf(word);
}

/// Offsets of the dates before the cutoff on `line`.
fn dateHits(a: std.mem.Allocator, line: []const u8, out: *std.ArrayList(usize)) !void {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (!isDigit(line[i])) continue;
        if (i > 0 and isDigit(line[i - 1])) continue;
        // the digit run
        var e = i;
        while (e < line.len and isDigit(line[e])) e += 1;
        const run = e - i;
        if (run == 4) {
            const y = digitsAt(line, i, 4).?;
            if (i > 0 and isAlnum(line[i - 1])) {
                i = e;
                continue;
            }
            if (e < line.len and isAlnum(line[e])) {
                i = e;
                continue;
            }
            // ISO: YYYY-MM-DD, YYYY/MM/DD, YYYY.MM.DD, YYYY-MM
            if (y >= 2000 and y <= 2099 and e + 3 <= line.len and (line[e] == '-' or line[e] == '/' or line[e] == '.')) {
                if (digitsAt(line, e + 1, 2)) |m| {
                    if (m >= 1 and m <= 12) {
                        if (pre(y, m)) {
                            // a version like 2025.1.3 is not a date: demand a day or the end of the token for '.'
                            if (line[e] != '.' or (e + 6 <= line.len and line[e + 3] == '.' and digitsAt(line, e + 4, 2) != null)) {
                                try out.append(a, i);
                                i = e;
                                continue;
                            }
                        }
                    }
                }
            }
            const versionish = e + 1 < line.len and line[e] == '.' and isDigit(line[e + 1]);
            if ((y == cutoff_year - 2 or y == cutoff_year - 1) and !versionish) {
                try out.append(a, i);
            } else if (y >= 2000 and y <= 2026) {
                // a month of the cutoff year is before it or not; any month of an earlier year is.
                if (monthBefore(line, i)) |m| if (pre(y, m)) try out.append(a, i);
            }
        } else if (run == 8) {
            const y = digitsAt(line, i, 4).?;
            const m = digitsAt(line, i + 4, 2).?;
            const d = digitsAt(line, i + 6, 2).?;
            if (y >= 2000 and y <= 2099 and m >= 1 and m <= 12 and d >= 1 and d <= 31 and pre(y, m) and !(i > 0 and isAlnum(line[i - 1])) and !(e < line.len and isAlnum(line[e]))) {
                try out.append(a, i);
            }
        }
        i = e;
    }
}

// ---- other detectors -----------------------------------------------------------------------------------------------------

fn emailAt(line: []const u8, at: usize) ?struct { start: usize, end: usize } {
    if (line[at] != '@') return null;
    var s = at;
    while (s > 0 and (isAlnum(line[s - 1]) or line[s - 1] == '.' or line[s - 1] == '_' or line[s - 1] == '%' or line[s - 1] == '+' or line[s - 1] == '-')) s -= 1;
    if (s == at) return null;
    // "scheme://user@host" is the userinfo of a URL, not an address
    if (s >= 2 and line[s - 1] == '/' and line[s - 2] == '/') return null;
    var e = at + 1;
    var last_dot: ?usize = null;
    while (e < line.len and (isAlnum(line[e]) or line[e] == '.' or line[e] == '-')) : (e += 1) {
        if (line[e] == '.') last_dot = e;
    }
    const d = last_dot orelse return null;
    // trailing dot is punctuation
    var end = e;
    if (line[end - 1] == '.') end -= 1;
    if (end <= d + 1) return null;
    const tld = line[d + 1 .. end];
    if (tld.len < 2) return null;
    for (tld) |c| if (!std.ascii.isAlphabetic(c)) return null;
    return .{ .start = s, .end = end };
}

fn ipv4At(line: []const u8, at: usize) ?usize {
    if (!isDigit(line[at])) return null;
    if (at > 0 and (isAlnum(line[at - 1]) or line[at - 1] == '.')) return null;
    var p = at;
    var parts: [4]u32 = undefined;
    var n: usize = 0;
    while (n < 4) : (n += 1) {
        const s = p;
        var v: u32 = 0;
        while (p < line.len and isDigit(line[p]) and p - s < 3) : (p += 1) v = v * 10 + (line[p] - '0');
        if (p == s or v > 255) return null;
        parts[n] = v;
        if (n < 3) {
            if (p >= line.len or line[p] != '.') return null;
            p += 1;
        }
    }
    if (p < line.len and (isAlnum(line[p]) or (line[p] == '.' and p + 1 < line.len and isDigit(line[p + 1])))) return null;
    if (parts[0] == 127 or (parts[0] == 0 and parts[1] == 0 and parts[2] == 0 and parts[3] == 0)) return null;
    if (parts[0] == 192 and parts[1] == 0 and parts[2] == 2) return null;
    if (parts[0] == 198 and parts[1] == 51 and parts[2] == 100) return null;
    if (parts[0] == 203 and parts[1] == 0 and parts[2] == 113) return null;
    return p;
}

fn endpointAt(line: []const u8, at: usize) bool {
    const schemes = [_][]const u8{ "grpc:" ++ "//", "grpcs:" ++ "//" };
    for (schemes) |sc| {
        if (!lowerEq(line, at, sc)) continue;
        const rest = line[at + sc.len ..];
        const ok = [_][]const u8{ "127.0.0.1", "localhost", "<", "example", "re.example", "[", "{", "%" };
        for (ok) |o| if (std.mem.startsWith(u8, rest, o)) return false;
        return true;
    }
    return false;
}

fn push(a: std.mem.Allocator, hits: *std.ArrayList(Hit), file: []const u8, ln: usize, rule: []const u8, allowed: ?[]const u8, line: []const u8) !void {
    const t = std.mem.trim(u8, line, " \t\r");
    const shown = if (t.len > 140) t[0..140] else t;
    try hits.append(a, .{ .file = file, .line = ln, .rule = rule, .allowed = allowed, .text = try a.dupe(u8, shown) });
}

/// The hits of one text. `file` names it in the report.
pub fn scanText(a: std.mem.Allocator, file: []const u8, text: []const u8, hits: *std.ArrayList(Hit)) !void {
    const is_license = std.mem.eql(u8, file, "LICENSE");
    var it = std.mem.splitScalar(u8, text, '\n');
    var ln: usize = 0;
    while (it.next()) |line| {
        ln += 1;
        // words
        for (words_ci) |w| {
            var from: usize = 0;
            while (std.ascii.indexOfIgnoreCasePos(line, from, w)) |at| : (from = at + 1) {
                if (boundedAt(line, at, w.len)) {
                    try push(a, hits, file, ln, "control-plane word or personal name", null, line);
                    break;
                }
            }
        }
        for (words_cs) |w| {
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, line, from, w)) |at| : (from = at + 1) {
                if (boundedAt(line, at, w.len)) {
                    try push(a, hits, file, ln, "control-plane word or personal name", null, line);
                    break;
                }
            }
        }
        for (subs_ci) |s| {
            if (std.ascii.indexOfIgnoreCase(line, s) != null) try push(a, hits, file, ln, "host, home path or private network", null, line);
        }
        // the project name
        {
            var from: usize = 0;
            while (std.ascii.indexOfIgnoreCasePos(line, from, project_ci)) |at| : (from = at + 1) {
                var ok = false;
                if (at >= url_head.len) {
                    const start = at - url_head.len;
                    if (lowerEq(line, start, releases_url)) ok = true;
                    if (lowerEq(line, start, repo_url)) {
                        // the repository address, then the end, a path, ".git", a quote or a space; never a longer name
                        const end = start + repo_url.len;
                        if (end == line.len) ok = true else switch (line[end]) {
                            '/', '"', '\'', '`', ' ' => ok = true,
                            '.' => ok = std.mem.startsWith(u8, line[end..], ".git") and (end + 4 == line.len or !(isAlnum(line[end + 4]) or line[end + 4] == '-' or line[end + 4] == '_')),
                            else => {},
                        }
                    }
                }
                if (!ok) {
                    try push(a, hits, file, ln, "the name of the project this one grew out of", null, line);
                    break;
                }
            }
        }
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (emailAt(line, i)) |m| {
                // The maintainer address is ours and allowed (reported, with its reason), and it does not hide another address on the same line.
                const own = std.ascii.eqlIgnoreCase(line[m.start..m.end], maintainer_address);
                const meta = std.mem.eql(u8, std.fs.path.basename(file), "package-lock.json") and std.mem.indexOf(u8, line, "\"deprecated\"") != null;
                try push(a, hits, file, ln, "email address", if (own) why_maintainer else if (meta) why_npm else null, line);
                if (!own) break;
                i = m.end - 1;
            }
        }
        i = 0;
        while (i < line.len) : (i += 1) {
            if (ipv4At(line, i)) |_| {
                try push(a, hits, file, ln, "IPv4 address", null, line);
                break;
            }
        }
        i = 0;
        while (i < line.len) : (i += 1) {
            if (endpointAt(line, i)) {
                try push(a, hits, file, ln, "remote-execution endpoint", null, line);
                break;
            }
        }
        if (!is_license) {
            var ds = std.ArrayList(usize).empty;
            try dateHits(a, line, &ds);
            if (ds.items.len != 0) try push(a, hits, file, ln, "date before 2026-09-01", upstreamReason(line), line);
        }
    }
}

pub fn isBinary(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, 8192)], 0) != null;
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) {
        std.debug.print("usage: scrub <out> [--require <name>]... (<name> <file>)...\n", .{});
        return 2;
    }
    var required = std.ArrayList([]const u8).empty;
    var names = std.ArrayList([]const u8).empty;
    var paths = std.ArrayList([]const u8).empty;
    var k: usize = 2;
    while (k < argv.len) {
        if (std.mem.eql(u8, argv[k], "--require")) {
            if (k + 1 >= argv.len) return 2;
            try required.append(a, argv[k + 1]);
            k += 2;
        } else {
            if (k + 1 >= argv.len) {
                std.debug.print("scrub: arguments are <name> <file> pairs\n", .{});
                return 2;
            }
            try names.append(a, argv[k]);
            try paths.append(a, argv[k + 1]);
            k += 2;
        }
    }
    var hits = std.ArrayList(Hit).empty;
    var scanned: usize = 0;
    var skipped: usize = 0;
    for (names.items, paths.items) |n, p| {
        const bytes = std.fs.cwd().readFileAlloc(a, p, 64 << 20) catch |e| {
            std.debug.print("scrub: cannot read {s} ({s})\n", .{ n, @errorName(e) });
            return 1;
        };
        if (isBinary(bytes)) {
            skipped += 1;
            continue;
        }
        scanned += 1;
        try scanText(a, n, bytes, &hits);
    }
    var missing: usize = 0;
    for (required.items) |r| {
        var found = false;
        for (names.items) |n| if (std.mem.eql(u8, n, r)) {
            found = true;
        };
        if (!found) {
            std.debug.print("scrub: the required file {s} is not among the inputs: a package is missing its scrub_files\n", .{r});
            missing += 1;
        }
    }
    var out = std.ArrayList(u8).empty;
    var bad: usize = 0;
    const reasons = [_][]const u8{ why_edition, why_npm, why_maintainer };
    var counts = [_]usize{0} ** reasons.len;
    for (hits.items) |h| {
        if (h.allowed) |why| {
            for (reasons, 0..) |r, ri| if (std.mem.eql(u8, why, r)) {
                counts[ri] += 1;
            };
            try out.print(a, "allowed ({s}) {s}:{d}: {s}\n", .{ why, h.file, h.line, h.text });
        } else {
            bad += 1;
            try out.print(a, "HIT [{s}] {s}:{d}: {s}\n", .{ h.rule, h.file, h.line, h.text });
        }
    }
    try out.print(a, "scrub: {d} files scanned, {d} binary skipped, {d} hits\n", .{ scanned, skipped, bad });
    for (reasons, counts) |r, c| try out.print(a, "scrub: allowed upstream facts, {s}: {d}\n", .{ r, c });
    if (bad != 0 or missing != 0) {
        std.debug.print("{s}", .{out.items});
        return 1;
    }
    try std.fs.cwd().writeFile(.{ .sub_path = argv[1], .data = out.items });
    return 0;
}
