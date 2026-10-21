//! The pin tables `autopin` reads from an artifact and writes into a repository: `buildrules.lock.bzl` (made by
//! `buildrules npm sync`) and `pins.lock.bzl` (made by kpin). Both end in an `NPM = {...}` block of rows; what
//! comes before it is a header and a block that no pull request may change.
//!
//! The reader is the generator's own grammar and nothing wider: the NPM block is read line by line against the
//! exact layout (indentation, field order, one field per line, sorted unique keys, every value inside its
//! character set), so a `load(`, a call, `native.`, an extra field or a reordered row is an error, not input.
//! What a caller keeps are the rows (values), and the bytes it writes are FRESH ones, re-emitted from those rows
//! by the generator's own renderer in front of the prefix it derived itself (`freshBuildrules`, `freshPins`).

const std = @import("std");
const ctxm = @import("ctx.zig");
const npm_cmd = @import("npm_cmd.zig");
const lock_mod = @import("autopin_lock.zig");
const valid = @import("valid.zig");
const sets_mod = @import("autopin_sets.zig");
const Diag = @import("diag.zig").Diag;

pub const max_rows = 20000;
/// A tarball larger than this is not pinned (the compute job refuses to download one).
pub const max_size: u64 = 64 << 20;

pub const Row = struct {
    key: []const u8,
    name: []const u8,
    version: []const u8,
    url: []const u8,
    sri512: []const u8,
    sha256: []const u8,
    size: u64,
    os: ?[]const []const u8 = null,
    cpu: ?[]const []const u8 = null,
    libc: ?[]const []const u8 = null,
};

pub const Error = error{ NoNpmBlock, BadNpmBlock, OutOfMemory };

pub const Split = struct { prefix: []const u8, npm: []const u8 };

pub const npm_marker = "\nNPM = {";

/// The table before the NPM block (it ends with the newline before `NPM = {`) and the NPM block from there.
pub fn split(text: []const u8) ?Split {
    const i = std.mem.indexOf(u8, text, npm_marker) orelse return null;
    return .{ .prefix = text[0 .. i + 1], .npm = text[i + 1 ..] };
}

const Lines = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    n: usize = 0,
    diag: *Diag,

    fn next(self: *Lines) Error![]const u8 {
        self.n += 1;
        return self.it.next() orelse {
            self.diag.add("NPM block: ends in the middle of a row (line {d})", .{self.n});
            return error.BadNpmBlock;
        };
    }

    fn bad(self: *Lines, comptime what: []const u8) Error {
        self.diag.add("NPM block line {d}: " ++ what, .{self.n});
        return error.BadNpmBlock;
    }
};

/// The value of a line `<indent>"<name>": "<value>",`.
fn strField(l: *Lines, line: []const u8, comptime name: []const u8) Error![]const u8 {
    const pre = "        \"" ++ name ++ "\": \"";
    if (!std.mem.startsWith(u8, line, pre) or !std.mem.endsWith(u8, line, "\",")) return l.bad("expected the field " ++ name);
    const v = line[pre.len .. line.len - 2];
    for (v) |c| if (c == '"' or c == '\\' or c < 0x20 or c > 0x7e) return l.bad("a value with a quote, a backslash or a control byte in " ++ name);
    return v;
}

fn listField(a: std.mem.Allocator, l: *Lines, line: []const u8, comptime name: []const u8) Error!?[]const []const u8 {
    const pre = "        \"" ++ name ++ "\": [";
    if (!std.mem.startsWith(u8, line, pre)) return null;
    if (!std.mem.endsWith(u8, line, "],")) return l.bad("a list that does not end in `],`");
    const inner = line[pre.len .. line.len - 2];
    if (inner.len == 0) return l.bad("an empty list");
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitSequence(u8, inner, ", ");
    while (it.next()) |item| {
        if (item.len < 3 or item[0] != '"' or item[item.len - 1] != '"') return l.bad("a list item that is not a quoted token");
        const tok = item[1 .. item.len - 1];
        if (!valid.isToken(if (tok[0] == '!') tok[1..] else tok)) return l.bad("a list item outside the token set");
        try out.append(a, tok);
    }
    return out.items;
}

fn parseSize(l: *Lines, line: []const u8) Error!u64 {
    const pre = "        \"size\": ";
    if (!std.mem.startsWith(u8, line, pre) or !std.mem.endsWith(u8, line, ",")) return l.bad("expected the field size");
    const digits = line[pre.len .. line.len - 1];
    if (digits.len == 0 or digits.len > 12 or (digits.len > 1 and digits[0] == '0')) return l.bad("a size that is not a plain decimal");
    for (digits) |c| if (c < '0' or c > '9') return l.bad("a size that is not a plain decimal");
    const n = std.fmt.parseInt(u64, digits, 10) catch return l.bad("a size that is not a number");
    if (n > max_size) return l.bad("a size over the cap");
    return n;
}

/// The rows of the NPM block `npm` (from `NPM = {` to the end of the file). Problems go to `diag`; any problem is
/// `error.BadNpmBlock`.
pub fn parseRows(a: std.mem.Allocator, npm: []const u8, kind: sets_mod.Kind, diag: *Diag) Error![]Row {
    var l = Lines{ .it = std.mem.splitScalar(u8, npm, '\n'), .diag = diag };
    const first = try l.next();
    if (std.mem.eql(u8, first, "NPM = {}")) {
        if (!std.mem.eql(u8, try l.next(), "") or l.it.next() != null) return l.bad("text after the NPM block");
        return &.{};
    }
    if (!std.mem.eql(u8, first, "NPM = {")) return l.bad("the block does not open with `NPM = {{`");
    var rows = std.ArrayList(Row).empty;
    while (true) {
        const head = try l.next();
        if (std.mem.eql(u8, head, "}")) {
            if (!std.mem.eql(u8, try l.next(), "") or l.it.next() != null) return l.bad("text after the NPM block");
            break;
        }
        if (rows.items.len >= max_rows) return l.bad("more rows than the cap");
        if (head.len < 10) return l.bad("a line too short to be a row header");
        if (!std.mem.startsWith(u8, head, "    \"") or !std.mem.endsWith(u8, head, "\": {")) return l.bad("expected a row `    \"name@version\": {{`");
        const key = head[5 .. head.len - 4];
        for (key) |c| if (c == '"' or c == '\\' or c < 0x20 or c > 0x7e) return l.bad("a key with a quote, a backslash or a control byte");
        const name = try strField(&l, try l.next(), "name");
        const version = try strField(&l, try l.next(), "version");
        const url = try strField(&l, try l.next(), "url");
        const sri = try strField(&l, try l.next(), "sri512");
        const sha = try strField(&l, try l.next(), "sha256");
        const size = try parseSize(&l, try l.next());
        var row = Row{ .key = key, .name = name, .version = version, .url = url, .sri512 = sri, .sha256 = sha, .size = size };
        var line = try l.next();
        if (kind == .buildrules_lock) {
            if (try listField(a, &l, line, "os")) |v| {
                row.os = v;
                line = try l.next();
            }
            if (try listField(a, &l, line, "cpu")) |v| {
                row.cpu = v;
                line = try l.next();
            }
            if (try listField(a, &l, line, "libc")) |v| {
                row.libc = v;
                line = try l.next();
            }
        }
        if (!std.mem.eql(u8, line, "    },")) return l.bad("expected the end of the row `    }},` (an extra or reordered field?)");
        if (!lock_mod.isNpmName(name) or !lock_mod.isStrictSemver(version)) return l.bad("a name or version outside the registry's sets");
        if (!valid.isUrl(url) or !valid.isSri512(sri) or !valid.isSha256(sha)) return l.bad("a url, sri512 or sha256 outside its set");
        const want_key = try std.fmt.allocPrint(a, "{s}@{s}", .{ name, version });
        if (!std.mem.eql(u8, key, want_key)) return l.bad("a key that is not name@version");
        if (rows.items.len > 0 and !std.mem.lessThan(u8, rows.items[rows.items.len - 1].key, key)) return l.bad("rows not sorted by key, or a key twice");
        try rows.append(a, row);
    }
    return rows.items;
}

fn toPin(r: Row) npm_cmd.Pin {
    return .{ .key = r.key, .name = r.name, .version = r.version, .url = r.url, .sri512 = r.sri512, .sha256 = r.sha256, .size = r.size, .os = r.os, .cpu = r.cpu, .libc = r.libc };
}

/// `buildrules.lock.bzl` as the generator renders it: PACKAGE from the package.json bytes `pj_text`, the two
/// digests of the files, and `rows`. Null with a message in `diag` when package.json is not one the generator
/// accepts.
pub fn freshBuildrules(a: std.mem.Allocator, pj_text: []const u8, lock_text: []const u8, rows: []const Row, diag: *Diag) !?[]u8 {
    const man = (try npm_cmd.readManifest(a, pj_text, diag)) orelse return null;
    if (diag.count() > 0) return null;
    const pins = try a.alloc(npm_cmd.Pin, rows.len);
    for (rows, 0..) |r, i| pins[i] = toPin(r);
    const pj_sha = try ctxm.sha256Hex(a, pj_text);
    const lk_sha = try ctxm.sha256Hex(a, lock_text);
    return try npm_cmd.render(a, man, pj_sha, lk_sha, pins);
}

/// The NPM block kpin writes for `rows`.
pub fn emitPinsNpm(a: std.mem.Allocator, rows: []const Row) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, "NPM = {");
    if (rows.len == 0) {
        try out.appendSlice(a, "}\n");
        return out.items;
    }
    try out.appendSlice(a, "\n");
    for (rows) |r| {
        try out.print(
            a,
            "    \"{s}\": {{\n        \"name\": \"{s}\",\n        \"version\": \"{s}\",\n        \"url\": \"{s}\",\n        \"sri512\": \"{s}\",\n        \"sha256\": \"{s}\",\n        \"size\": {d},\n    }},\n",
            .{ r.key, r.name, r.version, r.url, r.sri512, r.sha256, r.size },
        );
    }
    try out.appendSlice(a, "}\n");
    return out.items;
}

/// `pins.lock.bzl`: `prefix` (the header and the PINS block of the table already in the repository, which no
/// pull request may change) and the NPM block for `rows`.
pub fn freshPins(a: std.mem.Allocator, prefix: []const u8, rows: []const Row) ![]u8 {
    return std.mem.concat(a, u8, &.{ prefix, try emitPinsNpm(a, rows) });
}

fn listEql(x: ?[]const []const u8, y: ?[]const []const u8) bool {
    if (x == null or y == null) return x == null and y == null;
    if (x.?.len != y.?.len) return false;
    for (x.?, y.?) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

/// The row-to-lock binding. `entries` (sorted, collapsed, from `lock_mod.read`) and `rows` (sorted, from
/// `parseRows`) must pair one to one: equal name, version and sri512; the row's url equal to the URL DERIVED from
/// name and version (never trusted from the row); for a `buildrules.lock.bzl` table also equal os, cpu and libc;
/// no row without an entry, no entry without a row. What is NOT proved here is each row's sha256 and size.
pub fn bind(a: std.mem.Allocator, entries: []const lock_mod.Entry, rows: []const Row, kind: sets_mod.Kind, diag: *Diag) !void {
    var i: usize = 0;
    var j: usize = 0;
    while (i < entries.len or j < rows.len) {
        if (j >= rows.len or (i < entries.len and std.mem.lessThan(u8, entries[i].key, rows[j].key))) {
            diag.add("{s} is in package-lock.json ({s}) and has no row in the table", .{ entries[i].key, entries[i].path });
            i += 1;
            continue;
        }
        if (i >= entries.len or std.mem.lessThan(u8, rows[j].key, entries[i].key)) {
            diag.add("{s} has a row in the table and no entry in package-lock.json", .{rows[j].key});
            j += 1;
            continue;
        }
        const e = entries[i];
        const r = rows[j];
        i += 1;
        j += 1;
        if (!std.mem.eql(u8, e.name, r.name) or !std.mem.eql(u8, e.version, r.version)) diag.add("{s}: the row's name or version differs from the lock's", .{e.key});
        if (!std.mem.eql(u8, e.sri512, r.sri512)) diag.add("{s}: the row's sri512 is not the lock's integrity", .{e.key});
        const want = try lock_mod.canonicalUrl(a, r.name, r.version);
        if (!std.mem.eql(u8, r.url, want)) diag.add("{s}: the row's url is not {s}", .{ e.key, want });
        if (kind == .buildrules_lock and !(listEql(e.os, r.os) and listEql(e.cpu, r.cpu) and listEql(e.libc, r.libc)))
            diag.add("{s}: the row's os, cpu or libc differs from the lock's", .{e.key});
    }
}
