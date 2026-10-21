//! unpack: extract a tar, tar.gz, tar.xz or zip archive, checking it first.
//!
//!     unpack [--strip-components N] [--sha256 HEX] [--size BYTES] [--format F] [--max-output BYTES] <archive> <dest>
//!     unpack --check [--strip-components N] [--sha256 HEX] [--size BYTES] [--format F] [--max-output BYTES] <archive>
//!
//! The archive's size and sha256 are checked before anything is read (a wrong one writes nothing). The format is told by the file's magic, or given as `tar`,
//! `tar.gz`, `tar.xz` or `zip`. `--strip-components N` drops the first N components of every path, counting a leading `./` as one, as GNU tar's does. `--max-output N` refuses an archive that holds
//! more than N decompressed bytes (the tar stream, or the sizes the zip declares; the tar.xz decoder decodes a whole xz block before it hands any of it on, so for it the limit
//! stops the writing and not the memory). A failed extraction leaves a partly written destination, which the caller discards. `--check` reads the archive to the
//! end, checking every header, checksum and length, and writes nothing. Entries that would leave the destination, a cut-off or corrupt archive and every
//! other refusal are exit status 2 and a message naming the archive and the entry; nothing here asks the host for a tool.
//! The rules of what is written, and what is refused, are in extract.zig, tar.zig and zip.zig.
const std = @import("std");
pub const archive = @import("archive.zig");
const extract = @import("extract.zig");
const inflate = @import("inflate.zig");
const paths = @import("paths.zig");
const tar = @import("tar.zig");
const zip = @import("zip.zig");

/// The most an archive may be: it is read into memory.
pub const max_archive: u64 = 1 << 30;

pub const Options = struct {
    archive: []const u8,
    /// Where to extract; null with `--check`.
    dest: ?[]const u8,
    strip: usize = 0,
    sha256: ?[32]u8 = null,
    size: ?u64 = null,
    format: ?archive.Format = null,
    /// The most decompressed bytes the archive may hold; null for no limit.
    max_output: ?u64 = null,
};

pub const usage_text =
    "usage: unpack [--strip-components N] [--sha256 HEX] [--size BYTES] [--format tar|tar.gz|tar.xz|zip] [--max-output BYTES] <archive> <dest>\n" ++
    "       unpack --check [options] <archive>\n";

/// Parses the command line (without the program name). On `error.Usage`, `diag` says what is wrong.
pub fn parse(args: []const []const u8, diag: *[]const u8) !Options {
    var check = false;
    var o = Options{ .archive = "", .dest = null };
    var positional: [2][]const u8 = undefined;
    var np: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--check")) {
            check = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            i += 1;
            if (i >= args.len) return fail(diag, "an option has no value");
            const v = args[i];
            if (std.mem.eql(u8, arg, "--strip-components")) {
                o.strip = std.fmt.parseInt(usize, v, 10) catch return fail(diag, "--strip-components takes a number");
            } else if (std.mem.eql(u8, arg, "--size")) {
                o.size = std.fmt.parseInt(u64, v, 10) catch return fail(diag, "--size takes a number of bytes");
            } else if (std.mem.eql(u8, arg, "--max-output")) {
                o.max_output = std.fmt.parseInt(u64, v, 10) catch return fail(diag, "--max-output takes a number of bytes");
            } else if (std.mem.eql(u8, arg, "--sha256")) {
                var d: [32]u8 = undefined;
                if (v.len != 64 or !isLowerHex(v)) return fail(diag, "--sha256 takes 64 lower-case hex digits");
                _ = std.fmt.hexToBytes(&d, v) catch return fail(diag, "--sha256 takes 64 lower-case hex digits");
                o.sha256 = d;
            } else if (std.mem.eql(u8, arg, "--format")) {
                o.format = for (archive.names) |n| {
                    if (std.mem.eql(u8, n.text, v)) break n.format;
                } else return fail(diag, "--format is tar, tar.gz, tar.xz or zip");
            } else {
                return fail(diag, "unknown option");
            }
        } else {
            if (np == positional.len) return fail(diag, "too many arguments");
            positional[np] = arg;
            np += 1;
        }
    }
    if (np == 0) return fail(diag, "no archive given");
    o.archive = positional[0];
    if (check) {
        if (np != 1) return fail(diag, "--check takes the archive and no destination");
    } else {
        if (np != 2) return fail(diag, "the archive and the destination are both required");
        o.dest = positional[1];
    }
    return o;
}

fn fail(diag: *[]const u8, text: []const u8) error{Usage} {
    diag.* = text;
    return error.Usage;
}

fn isLowerHex(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

pub const Error = error{
    ArchiveTooLarge,
    OutputTooLarge,
    SizeMismatch,
    Sha256Mismatch,
    UnknownFormat,
};

/// What went wrong, in a sentence, for each refusal this tool makes; an error not listed is reported by its name.
pub const Explained = struct { err: anyerror, text: []const u8 };

const explain = [_]Explained{
    .{ .err = error.ArchiveTooLarge, .text = "the archive is over 1 GiB" },
    .{ .err = error.OutputTooLarge, .text = "the archive holds more decompressed bytes than --max-output allows" },
    .{ .err = error.SizeMismatch, .text = "the archive's size is not the one given with --size" },
    .{ .err = error.Sha256Mismatch, .text = "the archive's sha256 is not the one given with --sha256" },
    .{ .err = error.UnknownFormat, .text = "not a tar, tar.gz, tar.xz or zip file (--format names one)" },
    .{ .err = error.EmptyName, .text = "an entry has no name" },
    .{ .err = error.AbsolutePath, .text = "an entry's name is an absolute path" },
    .{ .err = error.ParentComponent, .text = "an entry's name has a `..` component" },
    .{ .err = error.NulInName, .text = "an entry's name or link target has a NUL byte" },
    .{ .err = error.NameTooLong, .text = "an entry's name is too long" },
    .{ .err = error.LinkEscapes, .text = "a symbolic link's target is absolute, empty, or leaves the destination" },
    .{ .err = error.ThroughSymlink, .text = "an entry would be written through a symbolic link" },
    .{ .err = error.NotADirectory, .text = "an entry's parent is not a directory" },
    .{ .err = error.LinkToLink, .text = "a hard link names a symbolic link" },
    .{ .err = error.NotAFile, .text = "a hard link names something that is not a file" },
    .{ .err = error.Truncated, .text = "the archive ends too early (it is cut off)" },
    .{ .err = error.TruncatedArchive, .text = "the tar ends inside an entry or before its end" },
    .{ .err = error.Corrupt, .text = "the compressed data is corrupt" },
    .{ .err = error.BadChecksum, .text = "a checksum is wrong" },
    .{ .err = error.BadLength, .text = "a length is wrong" },
    .{ .err = error.NotGzip, .text = "not a gzip file" },
    .{ .err = error.TrailingData, .text = "bytes follow the end of the compressed stream" },
    .{ .err = error.BadNumber, .text = "a number in a tar header is not one" },
    .{ .err = error.BadPax, .text = "a pax header is malformed" },
    .{ .err = error.HeaderTooLarge, .text = "a long-name or pax header is over 1 MiB" },
    .{ .err = error.UnsupportedType, .text = "an entry is of a type that is not extracted (device, FIFO, sparse, or unknown)" },
    .{ .err = error.LoneZeroBlock, .text = "a single zero block, not two, ends the tar" },
    .{ .err = error.DataAfterEnd, .text = "data follows the end of the tar" },
    .{ .err = error.EmptyArchive, .text = "the archive has no entries" },
    .{ .err = error.BadZip, .text = "the zip file is malformed" },
    .{ .err = error.Encrypted, .text = "a zip member is encrypted" },
    .{ .err = error.UnsupportedMethod, .text = "a zip member uses a method other than stored and deflate" },
    .{ .err = error.SplitArchive, .text = "a split zip archive" },
    .{ .err = error.BackslashInName, .text = "a zip member's name has a backslash" },
    .{ .err = error.EntryCorrupt, .text = "a zip member's CRC-32 or length is not its header's" },
};

pub fn explainErrors() []const Explained {
    return &explain;
}

pub fn explainError(e: anyerror) ?[]const u8 {
    for (explain) |x| {
        if (x.err == e) return x.text;
    }
    return null;
}

pub const Summary = extract.Stats;

/// Where a refusal says which entry caused it.
pub const Entry = struct {
    buf: [200]u8 = undefined,
    len: usize = 0,

    pub fn name(self: *const Entry) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Extracts (or with `dest == null`, checks) as `o` says. `entry` receives the name of the entry being handled when it fails.
pub fn run(a: std.mem.Allocator, o: Options, entry: *Entry) !Summary {
    const file = try std.fs.cwd().openFile(o.archive, .{});
    defer file.close();
    const st = try file.stat();
    if (st.size > max_archive) return error.ArchiveTooLarge;
    if (o.size) |want| {
        if (st.size != want) return error.SizeMismatch;
    }
    const bytes = try file.readToEndAlloc(a, @intCast(st.size));
    defer a.free(bytes);
    if (o.sha256) |want| {
        var got: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &got, .{});
        if (!std.mem.eql(u8, &got, &want)) return error.Sha256Mismatch;
    }
    const format = o.format orelse archive.detect(bytes) orelse return error.UnknownFormat;
    var dir: ?std.fs.Dir = null;
    defer if (dir) |*d| d.close();
    if (o.dest) |dest| {
        try std.fs.cwd().makePath(dest);
        dir = try std.fs.cwd().openDir(dest, .{});
    }
    var ex = extract.Extractor.init(a, dir, o.strip);
    defer ex.deinit();
    ex.max_output = o.max_output;
    archive.extractBytes(a, bytes, format, &ex) catch |e| {
        entry.len = ex.lastName().len;
        @memcpy(entry.buf[0..entry.len], ex.lastName());
        return e;
    };
    return ex.stats;
}

/// The program: `args` are the command line without the program name; the result is the exit status.
pub fn mainWith(a: std.mem.Allocator, args: []const []const u8) u8 {
    var diag: []const u8 = "";
    const o = parse(args, &diag) catch {
        std.debug.print("unpack: {s}\n{s}", .{ diag, usage_text });
        return 2;
    };
    var entry = Entry{};
    _ = run(a, o, &entry) catch |e| {
        const why = explainError(e) orelse @errorName(e);
        if (entry.len > 0) {
            std.debug.print("unpack: {s}: {s} (entry {s})\n", .{ o.archive, why, entry.name() });
        } else {
            std.debug.print("unpack: {s}: {s}\n", .{ o.archive, why });
        }
        return 2;
    };
    return 0;
}
