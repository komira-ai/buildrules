//! A tar archive (ustar, with the GNU long-name and the POSIX pax extensions) read as a stream of bytes the decoders push, and extracted through an `Extractor`.
//!
//! What is read: regular files, directories, symbolic links and hard links; the GNU `L`/`K` entries and the pax `x` entry's `path`, `linkpath` and `size`
//! (a pax global header `g` is skipped). What is refused, naming the entry: a character or block device, a FIFO, a sparse file, any other type, a header whose
//! checksum is wrong, a lone zero block, data after the end of the archive, and an archive that ends inside an entry, inside its padding, or between the two
//! zero blocks of its end: a cut-off archive is never a smaller one. An archive with no entry at all is refused too.
const std = @import("std");
const paths = @import("paths.zig");
const extract = @import("extract.zig");
const stream = @import("stream.zig");

pub const Error = error{
    BadChecksum,
    BadNumber,
    BadPax,
    HeaderTooLarge,
    UnsupportedType,
    LoneZeroBlock,
    DataAfterEnd,
    TruncatedArchive,
    EmptyArchive,
};

const block = 512;
/// The most a GNU long name or a pax header may hold.
const capture_max = 1 << 20;

const State = enum { header, data, pad, end };
const Mode = enum { skip, file, capture };

pub const Parser = struct {
    a: std.mem.Allocator,
    ex: *extract.Extractor,
    state: State = .header,
    hdr: [block]u8 = undefined,
    hdr_len: usize = 0,
    zero_blocks: u8 = 0,
    mode: Mode = .skip,
    out: extract.Out = .{ .file = null },
    /// The bytes of the entry's data still to come, and its whole size (for the padding).
    remaining: u64 = 0,
    data_size: u64 = 0,
    pad: usize = 0,
    capture: std.ArrayList(u8) = .empty,
    capture_kind: u8 = 0,
    /// What a long-name entry or a pax header says about the next entry.
    name_override: ?[]u8 = null,
    link_override: ?[]u8 = null,
    size_override: ?u64 = null,

    pub fn init(a: std.mem.Allocator, ex: *extract.Extractor) Parser {
        return .{ .a = a, .ex = ex };
    }

    pub fn deinit(self: *Parser) void {
        self.out.close();
        self.capture.deinit(self.a);
        self.clearOverrides();
    }

    pub fn sink(self: *Parser) stream.Sink {
        return stream.sinkOf(Parser, self);
    }

    fn clearOverrides(self: *Parser) void {
        if (self.name_override) |s| self.a.free(s);
        if (self.link_override) |s| self.a.free(s);
        self.name_override = null;
        self.link_override = null;
        self.size_override = null;
    }

    /// The next bytes of the archive.
    pub fn write(self: *Parser, bytes_in: []const u8) !void {
        var bytes = bytes_in;
        while (bytes.len > 0) {
            switch (self.state) {
                .header => {
                    const n = @min(block - self.hdr_len, bytes.len);
                    @memcpy(self.hdr[self.hdr_len .. self.hdr_len + n], bytes[0..n]);
                    self.hdr_len += n;
                    bytes = bytes[n..];
                    if (self.hdr_len == block) {
                        self.hdr_len = 0;
                        try self.header();
                    }
                },
                .data => {
                    const n: usize = @intCast(@min(self.remaining, bytes.len));
                    try self.data(bytes[0..n]);
                    self.remaining -= n;
                    bytes = bytes[n..];
                    if (self.remaining == 0) try self.endData();
                },
                .pad => {
                    const n = @min(self.pad, bytes.len);
                    self.pad -= n;
                    bytes = bytes[n..];
                    if (self.pad == 0) self.state = .header;
                },
                .end => {
                    for (bytes) |c| {
                        if (c != 0) return error.DataAfterEnd;
                    }
                    return;
                },
            }
        }
    }

    /// The archive is over: it must have ended between entries, as an archive ends.
    pub fn finish(self: *Parser) !void {
        if (self.state == .data or self.state == .pad or self.hdr_len != 0 or self.zero_blocks == 1) return error.TruncatedArchive;
        if (self.name_override != null or self.link_override != null or self.size_override != null) return error.TruncatedArchive;
        if (self.ex.entries == 0) return error.EmptyArchive;
    }

    fn data(self: *Parser, bytes: []const u8) !void {
        switch (self.mode) {
            .skip => {},
            .file => {
                try self.out.write(bytes);
                self.ex.stats.bytes += bytes.len;
            },
            .capture => try self.capture.appendSlice(self.a, bytes),
        }
    }

    fn startData(self: *Parser, size: u64) !void {
        self.remaining = size;
        self.data_size = size;
        if (size == 0) {
            try self.endData();
        } else {
            self.state = .data;
        }
    }

    fn endData(self: *Parser) !void {
        const was = self.mode;
        self.mode = .skip;
        switch (was) {
            .file => self.out.close(),
            .capture => try self.finishCapture(),
            .skip => {},
        }
        self.pad = @intCast((block - self.data_size % block) % block);
        self.state = if (self.pad > 0) .pad else .header;
    }

    fn header(self: *Parser) !void {
        const h = &self.hdr;
        if (std.mem.allEqual(u8, h, 0)) {
            self.zero_blocks += 1;
            if (self.zero_blocks == 2) self.state = .end;
            return;
        }
        if (self.zero_blocks != 0) return error.LoneZeroBlock;
        var sum: u64 = 0;
        for (h, 0..) |c, i| sum += if (i >= 148 and i < 156) ' ' else c;
        if (sum != try number(h[148..156])) return error.BadChecksum;
        const typeflag = h[156];
        const size = try number(h[124..136]);
        switch (typeflag) {
            'x', 'g', 'L', 'K' => {
                if (size > capture_max) return error.HeaderTooLarge;
                self.capture.clearRetainingCapacity();
                self.capture_kind = typeflag;
                self.mode = .capture;
                try self.startData(size);
            },
            '0', 0, '7', '5', '2', '1' => try self.entry(typeflag, size),
            else => {
                self.ex.note(cstr(h[0..100]));
                return error.UnsupportedType;
            },
        }
    }

    fn entry(self: *Parser, typeflag: u8, header_size: u64) !void {
        const h = &self.hdr;
        var joined: [100 + 1 + 155]u8 = undefined;
        var name = cstr(h[0..100]);
        if (std.mem.eql(u8, h[257..263], "ustar\x00")) {
            const prefix = cstr(h[345..500]);
            if (prefix.len > 0) {
                @memcpy(joined[0..prefix.len], prefix);
                joined[prefix.len] = '/';
                @memcpy(joined[prefix.len + 1 ..][0..name.len], name);
                name = joined[0 .. prefix.len + 1 + name.len];
            }
        }
        if (self.name_override) |n| name = n;
        const link = self.link_override orelse cstr(h[157..257]);
        const size = self.size_override orelse header_size;
        const mode: u32 = @truncate(try number(h[100..108]));
        self.ex.note(name);
        defer self.clearOverrides();

        var buf: [paths.max_path]u8 = undefined;
        const rel = try paths.clean(name, self.ex.strip, &buf);
        const is_dir = typeflag == '5' or (typeflag == 0 and name[name.len - 1] == '/');
        if (is_dir) {
            if (rel) |r| try self.ex.mkdir(r);
            return self.startData(0);
        }
        switch (typeflag) {
            '2' => {
                if (rel) |r| try self.ex.symlink(r, link);
                return self.startData(0);
            },
            '1' => {
                var tbuf: [paths.max_path]u8 = undefined;
                const target = try paths.clean(link, self.ex.strip, &tbuf);
                if (rel) |r| try self.ex.hardlink(r, target orelse return error.EmptyName);
                return self.startData(0);
            },
            else => {
                if (rel) |r| {
                    self.out = try self.ex.createFile(r, mode);
                    self.mode = .file;
                }
                return self.startData(size);
            },
        }
    }

    fn finishCapture(self: *Parser) !void {
        const bytes = self.capture.items;
        switch (self.capture_kind) {
            'L' => try self.setName(&self.name_override, std.mem.sliceTo(bytes, 0)),
            'K' => try self.setName(&self.link_override, std.mem.sliceTo(bytes, 0)),
            'x' => try self.pax(bytes),
            else => {},
        }
    }

    fn setName(self: *Parser, slot: *?[]u8, value: []const u8) !void {
        const copy = try self.a.dupe(u8, value);
        if (slot.*) |old| self.a.free(old);
        slot.* = copy;
    }

    /// The records `<length> <key>=<value>\n` of a pax header: `path`, `linkpath` and `size` are used, the rest (times, owners) is not.
    fn pax(self: *Parser, text: []const u8) !void {
        var pos: usize = 0;
        while (pos < text.len) {
            const sp = std.mem.indexOfScalarPos(u8, text, pos, ' ') orelse return error.BadPax;
            const len = std.fmt.parseInt(usize, text[pos..sp], 10) catch return error.BadPax;
            if (len <= sp - pos + 1 or len > text.len - pos) return error.BadPax;
            const rec = text[sp + 1 .. pos + len];
            if (rec[rec.len - 1] != '\n') return error.BadPax;
            const kv = rec[0 .. rec.len - 1];
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadPax;
            const key = kv[0..eq];
            const value = kv[eq + 1 ..];
            if (std.mem.eql(u8, key, "path")) {
                try self.setName(&self.name_override, value);
            } else if (std.mem.eql(u8, key, "linkpath")) {
                try self.setName(&self.link_override, value);
            } else if (std.mem.eql(u8, key, "size")) {
                self.size_override = std.fmt.parseInt(u64, value, 10) catch return error.BadPax;
            }
            pos += len;
        }
    }
};

/// The bytes of a header field up to its first NUL.
fn cstr(field: []const u8) []const u8 {
    return std.mem.sliceTo(field, 0);
}

/// A numeric header field (twelve bytes at most, so octal digits never overflow 64 bits): octal digits between spaces and NULs, or (high bit of the first byte set) big-endian binary, which is how a size over 8 GiB is written.
fn number(field: []const u8) !u64 {
    if (field[0] & 0x80 != 0) {
        var v: u64 = field[0] & 0x7f;
        for (field[1..]) |c| {
            if (v >> 56 != 0) return error.BadNumber;
            v = (v << 8) | c;
        }
        return v;
    }
    var v: u64 = 0;
    var i: usize = 0;
    while (i < field.len and field[i] == ' ') i += 1;
    while (i < field.len and field[i] >= '0' and field[i] <= '7') : (i += 1) {
        v = v * 8 + (field[i] - '0');
    }
    while (i < field.len and (field[i] == 0 or field[i] == ' ')) i += 1;
    if (i != field.len) return error.BadNumber;
    return v;
}
