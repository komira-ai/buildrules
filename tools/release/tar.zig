//! Reading the tar that `git archive` writes (ustar headers, and pax extended headers for a long path), to list and read what an archive
//! holds; and `build`, the small writer the tests use to make a tar of known content.
const std = @import("std");

pub const Kind = enum { file, symlink, dir, other };

pub const Entry = struct {
    /// The path as the archive spells it (a directory keeps no trailing slash).
    name: []const u8,
    kind: Kind,
    data: []const u8,
    /// The permission bits `build` writes (`parse` leaves the default: it does not read them).
    mode: u32 = 0o644,
};

pub const Error = error{ BadTar, OutOfMemory };

fn octal(field: []const u8) ?u64 {
    var end: usize = 0;
    while (end < field.len and field[end] != 0 and field[end] != ' ') end += 1;
    var start: usize = 0;
    while (start < end and field[start] == ' ') start += 1;
    if (start == end) return 0;
    return std.fmt.parseInt(u64, field[start..end], 8) catch null;
}

fn cstr(field: []const u8) []const u8 {
    return field[0 .. std.mem.indexOfScalar(u8, field, 0) orelse field.len];
}

fn isZero(block: []const u8) bool {
    for (block) |c| if (c != 0) return false;
    return true;
}

/// The checksum of a header: the sum of its bytes with the checksum field read as spaces.
fn checksum(h: []const u8) u64 {
    var s: u64 = 0;
    for (h, 0..) |c, i| s += if (i >= 148 and i < 156) ' ' else c;
    return s;
}

/// `key` of the pax records (`<len> <key>=<value>\n`) in `data`, or null.
fn paxValue(data: []const u8, key: []const u8) ?[]const u8 {
    var rest = data;
    var found: ?[]const u8 = null;
    while (rest.len > 0) {
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return found;
        const len = std.fmt.parseInt(usize, rest[0..sp], 10) catch return found;
        if (len < sp + 2 or len > rest.len) return found;
        const rec = rest[sp + 1 .. len - 1];
        if (std.mem.indexOfScalar(u8, rec, '=')) |eq| {
            if (std.mem.eql(u8, rec[0..eq], key)) found = rec[eq + 1 ..];
        }
        rest = rest[len..];
    }
    return found;
}

/// Every entry of `bytes`, in order. The slices point into `bytes` except for names that a pax header or a ustar prefix made (allocated
/// with `a`). A header whose checksum is wrong, a size beyond the data, or a missing end-of-archive block is `BadTar`.
pub fn parse(a: std.mem.Allocator, bytes: []const u8) Error![]Entry {
    var out = std.ArrayList(Entry).empty;
    errdefer out.deinit(a);
    var pos: usize = 0;
    var pax_path: ?[]const u8 = null;
    var ended = false;
    while (pos + 512 <= bytes.len) {
        const h = bytes[pos .. pos + 512];
        if (isZero(h)) {
            ended = true;
            break;
        }
        const want = octal(h[148..156]) orelse return error.BadTar;
        if (want != checksum(h)) return error.BadTar;
        const size = octal(h[124..136]) orelse return error.BadTar;
        const data_at = pos + 512;
        if (size > bytes.len - data_at) return error.BadTar;
        const data = bytes[data_at .. data_at + @as(usize, @intCast(size))];
        pos = data_at + ((@as(usize, @intCast(size)) + 511) / 512) * 512;
        const type_flag = h[156];
        switch (type_flag) {
            'g' => continue,
            'x' => {
                pax_path = if (paxValue(data, "path")) |p| try a.dupe(u8, p) else null;
                continue;
            },
            else => {},
        }
        var name: []const u8 = undefined;
        if (pax_path) |p| {
            name = p;
            pax_path = null;
        } else {
            const base = cstr(h[0..100]);
            const prefix = if (std.mem.eql(u8, h[257..262], "ustar")) cstr(h[345..500]) else "";
            name = if (prefix.len == 0) base else try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, base });
        }
        const kind: Kind = switch (type_flag) {
            '0', 0 => .file,
            '2' => .symlink,
            '5' => .dir,
            else => .other,
        };
        if (kind == .dir) name = std.mem.trimRight(u8, name, "/");
        try out.append(a, .{ .name = name, .kind = kind, .data = if (kind == .file) data else "" });
    }
    if (!ended) return error.BadTar;
    return out.toOwnedSlice(a);
}

// ---- writer (tests) ---------------------------------------------------------------------------------------------------------------------

fn putOctal(field: []u8, value: u64) void {
    @memset(field, '0');
    var v = value;
    var i: usize = field.len - 1; // the last byte stays 0
    field[i] = 0;
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
}

fn header(type_flag: u8, name: []const u8, size: u64, mode: u32) [512]u8 {
    var h = [_]u8{0} ** 512;
    @memcpy(h[0..@min(name.len, 100)], name[0..@min(name.len, 100)]);
    putOctal(h[100..108], mode);
    putOctal(h[108..116], 0);
    putOctal(h[116..124], 0);
    putOctal(h[124..136], size);
    putOctal(h[136..148], 0);
    h[156] = type_flag;
    @memcpy(h[257..263], "ustar\x00");
    @memcpy(h[263..265], "00");
    const sum = checksum(&h);
    putOctal(h[148..155], sum);
    h[154] = 0;
    h[155] = ' ';
    return h;
}

/// A tar of `entries` (a name longer than 100 bytes goes in a pax header, as git does), ended by two zero blocks. Caller frees.
pub fn build(a: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    for (entries) |e| {
        if (e.name.len > 100) {
            // the record length counts its own digits: iterate to the fixed point
            var total: usize = e.name.len + 7;
            for (0..3) |_| total = e.name.len + 7 + @as(usize, @intCast(std.fmt.count("{d}", .{total})));
            const body = try std.fmt.allocPrint(a, "{d} path={s}\n", .{ total, e.name });
            defer a.free(body);
            const ph = header('x', "pax", body.len, 0o644);
            try out.appendSlice(a, &ph);
            try out.appendSlice(a, body);
            try out.appendNTimes(a, 0, (512 - body.len % 512) % 512);
        }
        const flag: u8 = switch (e.kind) {
            .file => '0',
            .symlink => '2',
            .dir => '5',
            .other => '3',
        };
        const h = header(flag, e.name, e.data.len, e.mode);
        try out.appendSlice(a, &h);
        try out.appendSlice(a, e.data);
        try out.appendNTimes(a, 0, (512 - e.data.len % 512) % 512);
    }
    try out.appendNTimes(a, 0, 1024);
    return out.toOwnedSlice(a);
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;

test "what build writes, parse reads: names, kinds and contents" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = "buildrules-0.0.1/" ++ "d" ** 60 ++ "/" ++ "e" ** 60 ++ "/file.txt";
    const tar = try build(a, &.{
        .{ .name = "buildrules-0.0.1/", .kind = .dir, .data = "" },
        .{ .name = "buildrules-0.0.1/README.md", .kind = .file, .data = "hello\n" },
        .{ .name = "buildrules-0.0.1/empty", .kind = .file, .data = "" },
        .{ .name = "buildrules-0.0.1/exact", .kind = .file, .data = "x" ** 512 },
        .{ .name = long, .kind = .file, .data = "long\n" },
    });
    const es = try parse(a, tar);
    try t.expectEqual(@as(usize, 5), es.len);
    try t.expectEqualStrings("buildrules-0.0.1", es[0].name);
    try t.expectEqual(Kind.dir, es[0].kind);
    try t.expectEqualStrings("buildrules-0.0.1/README.md", es[1].name);
    try t.expectEqualStrings("hello\n", es[1].data);
    try t.expectEqualStrings("", es[2].data);
    try t.expectEqual(@as(usize, 512), es[3].data.len);
    try t.expectEqualStrings(long, es[4].name);
    try t.expectEqualStrings("long\n", es[4].data);
}

test "git's global pax header (the commit id) is skipped, not listed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rec = "52 comment=0123456789012345678901234567890123456789\n";
    var tar = std.ArrayList(u8).empty;
    const gh = header('g', "pax_global_header", rec.len, 0o644);
    try tar.appendSlice(a, &gh);
    try tar.appendSlice(a, rec);
    try tar.appendNTimes(a, 0, 512 - rec.len);
    const rest = try build(a, &.{.{ .name = "p/a", .kind = .file, .data = "a" }});
    try tar.appendSlice(a, rest);
    const es = try parse(a, tar.items);
    try t.expectEqual(@as(usize, 1), es.len);
    try t.expectEqualStrings("p/a", es[0].name);
}

test "a damaged tar is refused: bad checksum, truncated data, no end block" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar = try build(a, &.{.{ .name = "p/a", .kind = .file, .data = "abc" }});
    const bad = try a.dupe(u8, tar);
    bad[0] ^= 1; // the name changes, the checksum does not
    try t.expectError(error.BadTar, parse(a, bad));
    try t.expectError(error.BadTar, parse(a, tar[0..600])); // the data block is cut
    try t.expectError(error.BadTar, parse(a, tar[0..1024])); // header and data, no end block
    const huge = try a.dupe(u8, tar);
    @memcpy(huge[124..135], "77777777777");
    try t.expectError(error.BadTar, parse(a, huge)); // a size beyond the data (and a wrong checksum)
}

test "kinds: a symlink and an unknown type are told apart from files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar = try build(a, &.{
        .{ .name = "p/link", .kind = .symlink, .data = "" },
        .{ .name = "p/hard", .kind = .other, .data = "" },
    });
    const es = try parse(a, tar);
    try t.expectEqual(Kind.symlink, es[0].kind);
    try t.expectEqual(Kind.other, es[1].kind);
}
