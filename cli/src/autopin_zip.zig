//! A zip reader for one purpose: the artifact a workflow run uploaded, which is untrusted bytes. It has no
//! `unzip` behind it and extracts nothing to disk; it returns the names and the inflated bytes of at most
//! `Limits.max_entries` members, or an error naming the first thing wrong. It refuses, rather than tolerates:
//!   - zip64 (any sentinel, a zip64 locator, a zip64 extra field), a multi-disk archive, an archive comment;
//!   - encryption, any flag other than the compression-option bits, the data-descriptor bit and the UTF-8 bit,
//!     and any method but stored and deflate;
//!   - bytes after the end-of-central-directory record, a second such record, and any byte between the entries,
//!     the central directory and that record that no entry accounts for (the entries must tile the file
//!     exactly, so two entries cannot overlap and no entry can hide data between them);
//!   - a local header that disagrees with the central directory (name, flags, method, crc, sizes), except that
//!     a local header written with the data-descriptor bit set may hold zeros: the sizes then come from the
//!     central directory, and the descriptor must agree with it (a descriptor that lies is refused);
//!   - a symlink or any other special file, a directory, a name with a backslash, a NUL, a byte above 0x7e (so
//!     no Unicode normalization twin can exist), a leading `/`, a drive colon, an empty, `.` or `..` component;
//!   - a name twice, and two names that differ only by ASCII case;
//!   - a member whose name is not in the caller's list;
//!   - more inflated bytes than the entry's declared size (the inflater never writes past the declared
//!     size, so a bomb under a small declared size is cut off), a crc that is not the declared one, a size over
//!     a cap (per file, for the manifest, in total), and a ratio of declared size to stored size over 100:1.

const std = @import("std");
const inflate = @import("autopin_inflate.zig");

pub const Limits = struct {
    max_entries: usize = 12,
    /// Inflated bytes of one member.
    max_file: usize = 2 << 20,
    /// Inflated bytes of all members.
    max_total: usize = 8 << 20,
    /// Inflated bytes of the member named `manifest_name`.
    max_manifest: usize = 64 << 10,
    manifest_name: []const u8 = "manifest.json",
    /// Declared size over stored size.
    max_ratio: usize = 100,
};

pub const Entry = struct { name: []const u8, data: []const u8 };

pub const Error = error{
    TooShort,
    NotAZip,
    TrailingBytes,
    CommentPresent,
    Zip64,
    MultiDisk,
    Empty,
    TooManyEntries,
    CentralDirectoryTruncated,
    CentralDirectoryMisplaced,
    MultipleEocd,
    BadCentralHeader,
    Encrypted,
    BadFlags,
    BadMethod,
    BadExtra,
    SymlinkOrSpecial,
    DirectoryEntry,
    NulInName,
    BackslashInName,
    NonAsciiName,
    AbsoluteName,
    DotDotName,
    BadName,
    DuplicateName,
    CaseFoldTwin,
    UnexpectedMember,
    BadLocalHeader,
    LocalHeaderMismatch,
    DescriptorMismatch,
    DataOutOfRange,
    OverlappingEntries,
    GapBetweenEntries,
    FileTooLarge,
    ManifestTooLarge,
    TotalTooLarge,
    RatioTooHigh,
    SizeMismatch,
    InflateFailed,
    InflatedBeyondDeclared,
    CrcMismatch,
    OutOfMemory,
};

const sig_eocd: u32 = 0x06054b50;
const sig_zip64_locator: u32 = 0x07064b50;
const sig_central: u32 = 0x02014b50;
const sig_local: u32 = 0x04034b50;
const sig_descriptor: u32 = 0x08074b50;

const flag_encrypted: u16 = 0x0001;
const flag_strong: u16 = 0x0040;
const flag_descriptor: u16 = 0x0008;
/// Bits 1 and 2 (the deflate option bits) and 11 (UTF-8 names) are harmless.
const flags_allowed: u16 = 0x0006 | flag_descriptor | 0x0800;

fn rd16(b: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, b[o..][0..2], .little);
}

fn rd32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}

const Cd = struct {
    name: []const u8,
    flags: u16,
    method: u16,
    crc: u32,
    csize: u32,
    usize_: u32,
    lfh: u32,
    data_start: usize = 0,
    ext_end: usize = 0,
};

/// Walks the extra field: every record must fit, and none may be the zip64 record (id 1).
fn checkExtra(extra: []const u8) Error!void {
    var i: usize = 0;
    while (i < extra.len) {
        if (i + 4 > extra.len) return error.BadExtra;
        const id = rd16(extra, i);
        const n = rd16(extra, i + 2);
        if (i + 4 + n > extra.len) return error.BadExtra;
        if (id == 0x0001) return error.Zip64;
        i += 4 + n;
    }
}

fn checkName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > 255) return error.BadName;
    for (name) |c| {
        if (c == 0) return error.NulInName;
        if (c == '\\') return error.BackslashInName;
        if (c > 0x7e) return error.NonAsciiName;
        if (c < 0x20) return error.BadName;
    }
    if (name[0] == '/' or std.mem.indexOfScalar(u8, name, ':') != null) return error.AbsoluteName;
    if (name[name.len - 1] == '/') return error.DirectoryEntry;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.DotDotName;
        if (part.len == 0 or std.mem.eql(u8, part, ".")) return error.BadName;
    }
}

fn lowerEql(x: []const u8, y: []const u8) bool {
    return std.ascii.eqlIgnoreCase(x, y);
}

fn lessStart(_: void, x: Cd, y: Cd) bool {
    return x.lfh < y.lfh;
}

/// The members of the zip in `bytes`, in central-directory order. `allowed` lists the exact names a member may
/// have. Every returned `data` is a fresh copy.
pub fn read(a: std.mem.Allocator, bytes: []const u8, allowed: []const []const u8, lim: Limits) Error![]Entry {
    if (bytes.len < 22) return error.TooShort;
    const eocd = bytes.len - 22;
    if (rd32(bytes, eocd) != sig_eocd) {
        // An end record somewhere before the last 22 bytes: something follows it (or it carries a comment).
        if (std.mem.lastIndexOf(u8, bytes, "PK\x05\x06") != null) return error.TrailingBytes;
        return error.NotAZip;
    }
    if (rd16(bytes, eocd + 20) != 0) return error.CommentPresent;
    if (eocd >= 20 and rd32(bytes, eocd - 20) == sig_zip64_locator) return error.Zip64;
    const disk = rd16(bytes, eocd + 4);
    const cd_disk = rd16(bytes, eocd + 6);
    const n_disk = rd16(bytes, eocd + 8);
    const n_total = rd16(bytes, eocd + 10);
    const cd_size = rd32(bytes, eocd + 12);
    const cd_off = rd32(bytes, eocd + 16);
    if (n_disk == 0xFFFF or n_total == 0xFFFF or cd_size == 0xFFFFFFFF or cd_off == 0xFFFFFFFF) return error.Zip64;
    if (disk != 0 or cd_disk != 0 or n_disk != n_total) return error.MultiDisk;
    if (n_total == 0) return error.Empty;
    if (n_total > lim.max_entries) return error.TooManyEntries;
    const cd_end = @as(u64, cd_off) + @as(u64, cd_size);
    if (cd_end > eocd) return error.CentralDirectoryTruncated;
    if (cd_end != eocd) {
        // Bytes between the central directory and the end record: a second end record, or something hidden.
        if (cd_end + 4 <= eocd and rd32(bytes, @intCast(cd_end)) == sig_eocd) return error.MultipleEocd;
        return error.CentralDirectoryMisplaced;
    }

    var cds = std.ArrayList(Cd).empty;
    var p: usize = cd_off;
    var i: usize = 0;
    while (i < n_total) : (i += 1) {
        if (p + 46 > eocd) return error.CentralDirectoryTruncated;
        if (rd32(bytes, p) != sig_central) return error.BadCentralHeader;
        const made_by = rd16(bytes, p + 4);
        const flags = rd16(bytes, p + 8);
        const method = rd16(bytes, p + 10);
        const crc = rd32(bytes, p + 16);
        const csize = rd32(bytes, p + 20);
        const usize_ = rd32(bytes, p + 24);
        const nlen = rd16(bytes, p + 28);
        const elen = rd16(bytes, p + 30);
        const clen = rd16(bytes, p + 32);
        const disk_start = rd16(bytes, p + 34);
        const eattr = rd32(bytes, p + 38);
        const lfh = rd32(bytes, p + 42);
        if (p + 46 + @as(usize, nlen) + elen + clen > eocd) return error.CentralDirectoryTruncated;
        const name = bytes[p + 46 ..][0..nlen];
        try checkExtra(bytes[p + 46 + nlen ..][0..elen]);
        if (flags & (flag_encrypted | flag_strong) != 0) return error.Encrypted;
        if (flags & ~flags_allowed != 0) return error.BadFlags;
        if (method != 0 and method != 8) return error.BadMethod;
        if (csize == 0xFFFFFFFF or usize_ == 0xFFFFFFFF or lfh == 0xFFFFFFFF or disk_start == 0xFFFF) return error.Zip64;
        if (disk_start != 0) return error.MultiDisk;
        if (made_by >> 8 == 3) {
            const file_type = (eattr >> 16) & 0o170000;
            if (file_type == 0o040000) return error.DirectoryEntry;
            if (file_type != 0 and file_type != 0o100000) return error.SymlinkOrSpecial;
        }
        if (eattr & 0x10 != 0) return error.DirectoryEntry;
        try checkName(name);
        try cds.append(a, .{ .name = name, .flags = flags, .method = method, .crc = crc, .csize = csize, .usize_ = usize_, .lfh = lfh });
        p += 46 + @as(usize, nlen) + elen + clen;
    }
    if (@as(u64, p) != cd_end) return error.CentralDirectoryMisplaced;

    for (cds.items, 0..) |x, xi| {
        for (cds.items[0..xi]) |y| {
            if (std.mem.eql(u8, x.name, y.name)) return error.DuplicateName;
            if (lowerEql(x.name, y.name)) return error.CaseFoldTwin;
        }
    }
    for (cds.items) |x| {
        var ok = false;
        for (allowed) |n| if (std.mem.eql(u8, n, x.name)) {
            ok = true;
        };
        if (!ok) return error.UnexpectedMember;
    }

    // Local headers, data and descriptors: where each entry ends.
    for (cds.items) |*c| {
        const lo: usize = c.lfh;
        if (lo + 30 > cd_off) return error.DataOutOfRange;
        if (rd32(bytes, lo) != sig_local) return error.BadLocalHeader;
        const l_flags = rd16(bytes, lo + 6);
        const l_method = rd16(bytes, lo + 8);
        const l_crc = rd32(bytes, lo + 14);
        const l_csize = rd32(bytes, lo + 18);
        const l_usize = rd32(bytes, lo + 22);
        const l_nlen = rd16(bytes, lo + 26);
        const l_elen = rd16(bytes, lo + 28);
        if (l_csize == 0xFFFFFFFF or l_usize == 0xFFFFFFFF) return error.Zip64;
        const data_start = lo + 30 + @as(usize, l_nlen) + l_elen;
        if (data_start > cd_off) return error.DataOutOfRange;
        if (!std.mem.eql(u8, bytes[lo + 30 ..][0..l_nlen], c.name)) return error.LocalHeaderMismatch;
        try checkExtra(bytes[lo + 30 + l_nlen ..][0..l_elen]);
        if (l_flags != c.flags or l_method != c.method) return error.LocalHeaderMismatch;
        const has_descriptor = c.flags & flag_descriptor != 0;
        if (has_descriptor) {
            // upload-artifact writes sizes and crc as zero here and states them after the data.
            if ((l_crc != 0 and l_crc != c.crc) or (l_csize != 0 and l_csize != c.csize) or (l_usize != 0 and l_usize != c.usize_)) return error.LocalHeaderMismatch;
        } else if (l_crc != c.crc or l_csize != c.csize or l_usize != c.usize_) return error.LocalHeaderMismatch;
        const data_end = data_start + c.csize;
        if (data_end > cd_off) return error.DataOutOfRange;
        c.data_start = data_start;
        c.ext_end = data_end;
        if (has_descriptor) {
            var dp = data_end;
            if (dp + 4 <= cd_off and rd32(bytes, dp) == sig_descriptor) dp += 4;
            if (dp + 12 > cd_off) return error.DataOutOfRange;
            if (rd32(bytes, dp) != c.crc or rd32(bytes, dp + 4) != c.csize or rd32(bytes, dp + 8) != c.usize_) return error.DescriptorMismatch;
            c.ext_end = dp + 12;
        }
    }

    // The entries must tile [0, cd_off) exactly.
    const order = try a.dupe(Cd, cds.items);
    std.mem.sort(Cd, order, {}, lessStart);
    var at: usize = 0;
    for (order) |c| {
        if (c.lfh < at) return error.OverlappingEntries;
        if (c.lfh > at) return error.GapBetweenEntries;
        at = c.ext_end;
    }
    if (at != cd_off) return error.GapBetweenEntries;

    var out = std.ArrayList(Entry).empty;
    var total: usize = 0;
    for (cds.items) |c| {
        const is_manifest = std.mem.eql(u8, c.name, lim.manifest_name);
        const cap = if (is_manifest) lim.max_manifest else lim.max_file;
        if (c.usize_ > cap) return if (is_manifest) error.ManifestTooLarge else error.FileTooLarge;
        if (c.usize_ > 0 and @as(u64, c.usize_) > @as(u64, c.csize) * lim.max_ratio) return error.RatioTooHigh;
        total += c.usize_;
        if (total > lim.max_total) return error.TotalTooLarge;
        const stored = bytes[c.data_start..][0..c.csize];
        const data: []u8 = blk: {
            if (c.method == 0) {
                if (c.csize != c.usize_) return error.SizeMismatch;
                break :blk try a.dupe(u8, stored);
            }
            // The inflater never writes past the declared size: more output than that is a bomb, however small the
            // declared size says it is.
            const got = inflate.inflate(a, stored, c.usize_) catch |e| switch (e) {
                error.TooLong => return error.InflatedBeyondDeclared,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InflateFailed,
            };
            if (got.len != c.usize_) return error.SizeMismatch;
            break :blk got;
        };
        if (std.hash.Crc32.hash(data) != c.crc) return error.CrcMismatch;
        try out.append(a, .{ .name = c.name, .data = data });
    }
    return out.items;
}
