//! branch_lcov: the branch records of a Mojo package's tests, read and summed by id (cov_summary --branch-lcov).
//!
//! The records are what cov_branch_classify writes for one test (rules/coverage/branch/README.md): lcov `BRDA` lines whose block field is
//! `<col>:<kind>:<n>/<N>` instead of a block number. A file holds records `SF:<path>`, then
//! `BRDA:<line>,<col>:<kind>:<n>/<N>,<arm>,<taken|->` lines, then `end_of_record`; an empty file (a test that ran none of the library's
//! code) holds none. `<kind>` is `br`, `select`, `switch`, `try` (a raising call in a `try:` body: returned, raised into the handler) or
//! `rhs`; `<N>` is how many decisions of that kind one copy of the code holds at that line and column, `<n>` which one (0 to N-1); `<arm>`
//! numbers the decision's outcomes from 0. `-` means the decision's code never ran: the arm counts, not taken, so it adds 0 to a sum. A
//! branch is keyed `<line>,<col>:<kind>:<n>/<N>,<arm>`, its numbers written in decimal without leading zeros, so the same arm read from two
//! tests is one key and its counts are summed.
//!
//! Line data never comes from these files: they hold branches only, and the Cobertura reports hold the lines. Refused, with
//! `<origin>:<line>:`: a carriage return, a blank line, any record but `SF`, `BRDA` and `end_of_record` (a `DA`, `LF`, `FN`, `TN`, `BRF`...
//! included), a record outside `SF` .. `end_of_record`, an `SF` naming no file or naming a file a second time, a `BRDA` without exactly
//! four fields, a block field that is not `<col>:<kind>:<n>/<N>`, an unknown kind, a column or line of 0 or above 10^9, `<n>` not below
//! `<N>`, a malformed arm or count, the same arm twice, and a last record without `end_of_record`. At each `end_of_record`: every decision
//! has arms 0 to k-1 (two for `br`, `select`, `try` and `rhs`, at least two for `switch`), and every location has each of its `N` decisions.
//!
//! Across files (`Shapes`): one test's classifier sees only its own copies of the code, so two tests whose copies hold the same number of
//! decisions at a location but different ones are summed crosswise unnoticed; what can be seen is two tests giving one location (line,
//! column, kind) a different `N`, or one decision a different number of arms, and both are refused naming the file, the line and the two
//! reports.

const std = @import("std");
const Alloc = std.mem.Allocator;

pub const Error = error{ Refused, OutOfMemory };

/// Why a refusal was made (set before `error.Refused` is returned).
pub const Diag = struct { msg: []const u8 = "" };

fn refuse(a: Alloc, d: *Diag, comptime fmt: []const u8, args: anytype) Error {
    d.msg = std.fmt.allocPrint(a, fmt, args) catch return error.OutOfMemory;
    return error.Refused;
}

const MAX_LINE: u64 = 1_000_000_000;
const MAX_DIGITS = 18;

/// `s` as a decimal integer, or null when it is not one: empty, a sign, any non-digit, or more than 18 digits.
fn parseCount(s: []const u8) ?u64 {
    if (s.len == 0 or s.len > MAX_DIGITS) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}

fn kindOk(kind: []const u8) bool {
    for ([_][]const u8{ "br", "select", "switch", "try", "rhs" }) |k| {
        if (std.mem.eql(u8, kind, k)) return true;
    }
    return false;
}

fn num(a: Alloc, d: *Diag, origin: []const u8, n: usize, field: []const u8, what: []const u8, lo: u64) Error!u64 {
    const v = parseCount(field) orelse return refuse(a, d, "{s}:{d}: {s} '{s}' is not a decimal number", .{ origin, n, what, field });
    if (v < lo) return refuse(a, d, "{s}:{d}: {s} {s} is below {d}", .{ origin, n, what, field, lo });
    if (v > MAX_LINE) return refuse(a, d, "{s}:{d}: {s} {s} is above 10^9", .{ origin, n, what, field });
    return v;
}

/// One file's branches: key -> times taken (`-` is 0), in the order given.
pub const Taken = std.StringArrayHashMapUnmanaged(u64);

pub const File = struct { path: []const u8, branches: Taken };

/// The checks of one `SF` .. `end_of_record`.
const Record = struct {
    totals: std.StringArrayHashMapUnmanaged(u64) = .empty, // site -> N
    decisions: std.StringArrayHashMapUnmanaged(u64) = .empty, // site -> decisions seen
    arms: std.StringArrayHashMapUnmanaged(u64) = .empty, // decision -> arms seen
    max_arm: std.StringArrayHashMapUnmanaged(u64) = .empty, // decision -> highest arm
};

fn brda(a: Alloc, d: *Diag, origin: []const u8, n: usize, body: []const u8, f: *File, r: *Record) Error!void {
    var fs = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, body, ',');
    while (it.next()) |x| try fs.append(a, x);
    if (fs.items.len != 4) return refuse(a, d, "{s}:{d}: BRDA needs <line>,<col>:<kind>:<n>/<N>,<arm>,<taken|-> (4 fields), not {d}", .{ origin, n, fs.items.len });
    const line = try num(a, d, origin, n, fs.items[0], "BRDA line", 1);
    var parts = std.ArrayList([]const u8).empty;
    var pit = std.mem.splitScalar(u8, fs.items[1], ':');
    while (pit.next()) |x| try parts.append(a, x);
    if (parts.items.len != 3) return refuse(a, d, "{s}:{d}: BRDA block '{s}' is not <col>:<kind>:<n>/<N> (a branch record of cov_branch_classify)", .{ origin, n, fs.items[1] });
    const col = try num(a, d, origin, n, parts.items[0], "BRDA column", 1);
    const kind = parts.items[1];
    if (!kindOk(kind)) return refuse(a, d, "{s}:{d}: BRDA kind '{s}' is not br, select, switch, try or rhs", .{ origin, n, kind });
    var nn = std.ArrayList([]const u8).empty;
    var nit = std.mem.splitScalar(u8, parts.items[2], '/');
    while (nit.next()) |x| try nn.append(a, x);
    if (nn.items.len != 2) return refuse(a, d, "{s}:{d}: BRDA decision '{s}' is not <n>/<N>", .{ origin, n, parts.items[2] });
    const idx = try num(a, d, origin, n, nn.items[0], "BRDA decision number", 0);
    const total = try num(a, d, origin, n, nn.items[1], "BRDA decision count", 1);
    if (idx >= total) return refuse(a, d, "{s}:{d}: BRDA decision {d}/{d}: <n> must be below <N>", .{ origin, n, idx, total });
    const arm = try num(a, d, origin, n, fs.items[2], "BRDA arm", 0);
    var taken: u64 = 0;
    if (!std.mem.eql(u8, fs.items[3], "-")) {
        taken = parseCount(fs.items[3]) orelse return refuse(a, d, "{s}:{d}: BRDA taken '{s}' is not a decimal number or -", .{ origin, n, fs.items[3] });
    }
    const site = try std.fmt.allocPrint(a, "{d},{d}:{s}", .{ line, col, kind });
    const decision = try std.fmt.allocPrint(a, "{s}:{d}/{d}", .{ site, idx, total });
    const key = try std.fmt.allocPrint(a, "{s},{d}", .{ decision, arm });
    if (f.branches.contains(key)) return refuse(a, d, "{s}:{d}: BRDA {s} is given twice in one record", .{ origin, n, key });
    if (r.totals.get(site)) |seen| {
        if (seen != total) return refuse(a, d, "{s}:{d}: BRDA {s}: the location {s} has {d} decisions in an earlier record line, not {d}", .{ origin, n, key, site, seen, total });
    } else try r.totals.put(a, site, total);
    if (r.arms.getPtr(decision)) |count| {
        count.* += 1;
        const m = r.max_arm.getPtr(decision).?;
        m.* = @max(m.*, arm);
    } else {
        try r.arms.put(a, decision, 1);
        try r.max_arm.put(a, decision, arm);
        const slot = try r.decisions.getOrPut(a, site);
        slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* + 1 else 1;
    }
    try f.branches.put(a, key, taken);
}

/// The checks at `end_of_record` (module comment).
fn close(a: Alloc, d: *Diag, origin: []const u8, n: usize, f: File, r: Record) Error!void {
    var it = r.arms.iterator();
    while (it.next()) |e| {
        const dec = e.key_ptr.*;
        const k = e.value_ptr.*;
        const hi = r.max_arm.get(dec).?;
        if (hi != k - 1) return refuse(a, d, "{s}:{d}: {s}: the arms of {s} are not 0 to {d} (highest {d})", .{ origin, n, f.path, dec, k - 1, hi });
        const two = std.mem.indexOf(u8, dec, ":switch:") == null;
        if ((two and k != 2) or k < 2) return refuse(a, d, "{s}:{d}: {s}: {s} has {d} arms, not {s}", .{ origin, n, f.path, dec, k, if (two) "2" else "2 or more" });
    }
    var tit = r.totals.iterator();
    while (tit.next()) |e| {
        const seen = r.decisions.get(e.key_ptr.*) orelse 0;
        if (seen != e.value_ptr.*) return refuse(a, d, "{s}:{d}: {s}: the location {s} has {d} of its {d} decisions", .{ origin, n, f.path, e.key_ptr.*, seen, e.value_ptr.* });
    }
}

/// The files of the branch record file `text` (`origin` names it in errors), each path once.
pub fn parse(a: Alloc, d: *Diag, text: []const u8, origin: []const u8) Error![]File {
    if (std.mem.indexOfScalar(u8, text, '\r') != null) return refuse(a, d, "{s}:1: carriage return (the file must use LF line ends)", .{origin});
    var files = std.ArrayList(File).empty;
    var named = std.StringHashMapUnmanaged(void).empty;
    var current = File{ .path = "", .branches = .empty };
    var rec = Record{};
    var in_record = false;
    var body = text;
    if (body.len > 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];
    var n: usize = 0;
    if (text.len > 0) {
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            n += 1;
            if (std.mem.eql(u8, line, "end_of_record")) {
                if (!in_record) return refuse(a, d, "{s}:{d}: end_of_record outside a record", .{ origin, n });
                try close(a, d, origin, n, current, rec);
                try files.append(a, current);
                in_record = false;
                continue;
            }
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse 0;
            if (colon == 0) return refuse(a, d, "{s}:{d}: not a record: '{s}' (a branch record file holds SF, BRDA and end_of_record only)", .{ origin, n, line });
            const kind = line[0..colon];
            const rest = line[colon + 1 ..];
            if (std.mem.eql(u8, kind, "SF")) {
                if (in_record) return refuse(a, d, "{s}:{d}: SF before the end_of_record of the previous file", .{ origin, n });
                if (rest.len == 0) return refuse(a, d, "{s}:{d}: SF names no file", .{ origin, n });
                if (named.contains(rest)) return refuse(a, d, "{s}:{d}: SF {s} is named a second time", .{ origin, n, rest });
                try named.put(a, rest, {});
                current = .{ .path = rest, .branches = .empty };
                rec = .{};
                in_record = true;
            } else if (std.mem.eql(u8, kind, "BRDA")) {
                if (!in_record) return refuse(a, d, "{s}:{d}: BRDA outside SF .. end_of_record", .{ origin, n });
                try brda(a, d, origin, n, rest, &current, &rec);
            } else {
                return refuse(a, d, "{s}:{d}: '{s}' record in a branch record file, which holds SF, BRDA and end_of_record only (line data comes from the line reports)", .{ origin, n, kind });
            }
        }
    }
    if (in_record) return refuse(a, d, "{s}:{d}: the last record has no end_of_record", .{ origin, n });
    return files.toOwnedSlice(a);
}

/// A key's parts: `site` `<line>,<col>:<kind>`, `decision` `<site>:<n>/<N>`, the decision count `total` (N) and the line.
const Parts = struct { line: u64, site: []const u8, decision: []const u8, total: u64 };

/// The parts of a key `parse` wrote.
fn split(key: []const u8) Parts {
    const c1 = std.mem.indexOfScalar(u8, key, ',').?;
    const c2 = std.mem.lastIndexOfScalar(u8, key, ',').?;
    const block = key[c1 + 1 .. c2];
    const slash = std.mem.lastIndexOfScalar(u8, block, '/').?;
    const colon = std.mem.lastIndexOfScalar(u8, block, ':').?;
    return .{
        .line = parseCount(key[0..c1]).?,
        .site = key[0 .. c1 + 1 + colon],
        .decision = key[0..c2],
        .total = parseCount(block[slash + 1 ..]).?,
    };
}

/// What the files read so far give each location and decision, to refuse a file that disagrees (module comment), and the counts summed.
pub const Sum = struct {
    /// path -> key -> times taken, summed over the files read.
    files: std.StringArrayHashMapUnmanaged(Taken) = .empty,
    /// path NUL site -> N, and path NUL decision -> arms, with the origin that gave it first.
    totals: std.StringHashMapUnmanaged(Seen) = .empty,
    arms: std.StringHashMapUnmanaged(Seen) = .empty,

    const Seen = struct { n: u64, origin: []const u8 };

    /// Reads `text` (named `origin` in errors) and adds its files; raises on a record the module comment refuses, or on a file that
    /// disagrees with an earlier one about the shape of a location or a decision.
    pub fn add(self: *Sum, a: Alloc, d: *Diag, text: []const u8, origin: []const u8) Error!void {
        for (try parse(a, d, text, origin)) |f| try self.addFile(a, d, f, origin);
    }

    fn addFile(self: *Sum, a: Alloc, d: *Diag, f: File, origin: []const u8) Error!void {
        var arms = std.StringArrayHashMapUnmanaged(u64).empty;
        var totals = std.StringArrayHashMapUnmanaged(u64).empty;
        var lines = std.StringArrayHashMapUnmanaged(u64).empty;
        var it = f.branches.iterator();
        while (it.next()) |e| {
            const p = split(e.key_ptr.*);
            const slot = try arms.getOrPut(a, p.decision);
            slot.value_ptr.* = if (slot.found_existing) slot.value_ptr.* + 1 else 1;
            try totals.put(a, p.site, p.total);
            try lines.put(a, p.site, p.line);
        }
        var tit = totals.iterator();
        while (tit.next()) |e| {
            const k = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ f.path, e.key_ptr.* });
            if (self.totals.get(k)) |seen| {
                if (seen.n != e.value_ptr.*) {
                    const site = e.key_ptr.*;
                    const col_kind = site[std.mem.indexOfScalar(u8, site, ',').? + 1 ..];
                    return refuse(a, d, "{s}:{d}: {s} gives {d} decision(s) at {s} and {s} gives {d}: the tests' copies of this code hold different decisions at one location, so their branch records cannot be summed by id", .{ f.path, lines.get(site).?, seen.origin, seen.n, col_kind, origin, e.value_ptr.* });
                }
            } else try self.totals.put(a, k, .{ .n = e.value_ptr.*, .origin = origin });
        }
        var ait = arms.iterator();
        while (ait.next()) |e| {
            const k = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ f.path, e.key_ptr.* });
            if (self.arms.get(k)) |seen| {
                if (seen.n != e.value_ptr.*) {
                    const line = split(try std.fmt.allocPrint(a, "{s},0", .{e.key_ptr.*})).line;
                    return refuse(a, d, "{s}:{d}: {s} gives the decision {s} {d} arms and {s} gives it {d}: its branch records cannot be summed by id", .{ f.path, line, seen.origin, e.key_ptr.*, seen.n, origin, e.value_ptr.* });
                }
            } else try self.arms.put(a, k, .{ .n = e.value_ptr.*, .origin = origin });
        }
        const slot = try self.files.getOrPut(a, f.path);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        var bit = f.branches.iterator();
        while (bit.next()) |e| {
            const t = try slot.value_ptr.getOrPut(a, e.key_ptr.*);
            t.value_ptr.* = if (t.found_existing) t.value_ptr.* +| e.value_ptr.* else e.value_ptr.*;
        }
    }

    /// Per file, the arms taken by some test and the arms there are, sorted by path.
    pub fn counts(self: *const Sum, a: Alloc) Error![]Count {
        var out = std.ArrayList(Count).empty;
        var it = self.files.iterator();
        while (it.next()) |e| {
            var hit: usize = 0;
            for (e.value_ptr.values()) |t| {
                if (t > 0) hit += 1;
            }
            try out.append(a, .{ .path = e.key_ptr.*, .hit = hit, .total = e.value_ptr.count() });
        }
        std.mem.sort(Count, out.items, {}, struct {
            fn lt(_: void, x: Count, y: Count) bool {
                return std.mem.lessThan(u8, x.path, y.path);
            }
        }.lt);
        return out.toOwnedSlice(a);
    }
};

pub const Count = struct { path: []const u8, hit: usize, total: usize };
