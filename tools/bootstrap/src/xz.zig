//! An xz file decoded into a `Sink`: the standard library's decoder (LZMA2, and the container's block, index and footer checks), over the file in memory. The
//! errors are this tool's: `Truncated` for a stream that ends early, `Corrupt` for any other defect, `TrailingData` for bytes after the stream.
//! Memory: the standard library's decoder decodes a whole xz block before it returns any of it, so the memory is about the size of the largest block (an archive that is
//! one block, as `xz -9` makes of a tarball, is held decompressed whole) on top of the archive itself; tools/bootstrap/README.md has the figures measured on real archives.
const std = @import("std");
const Sink = @import("stream.zig").Sink;

pub fn unxz(a: std.mem.Allocator, input: []const u8, sink: Sink) !void {
    var fbs = std.io.fixedBufferStream(input);
    var dec = std.compress.xz.decompress(a, fbs.reader()) catch |e| return map(e);
    defer dec.deinit();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = dec.reader().read(&buf) catch |e| return map(e);
        if (n == 0) break;
        try sink.write(buf[0..n]);
    }
    if (fbs.pos != input.len) return error.TrailingData;
}

fn map(e: anyerror) anyerror {
    return switch (e) {
        error.EndOfStream => error.Truncated,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Corrupt,
    };
}
