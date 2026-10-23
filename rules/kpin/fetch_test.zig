//! fetch.zig: how a response body is moved to its sink. The body here is an in-memory reader that answers exactly as the standard library's
//! body reader does for a declared length: once the count reaches zero it reports the end of the stream once, and a further call is a panic
//! (the library trips over a union field). So the cases below do not depend on timing or on the size of a segment.

const std = @import("std");
const fetch = @import("fetch.zig");
const t = std.testing;

fn payload(a: std.mem.Allocator, n: usize) ![]u8 {
    const b = try a.alloc(u8, n);
    for (b, 0..) |*x, i| x.* = @intCast((i * 7 + i / 251) % 256);
    return b;
}

/// A body of `data`. `declared` is the Content-Length (null: the body runs to the end of `data`). `per_call` bounds what one stream call
/// hands over (a body arriving in small segments). `short` is what it answers when `data` ends before `declared`.
const EndingBody = struct {
    interface: std.Io.Reader,
    data: []const u8,
    declared: ?u64,
    per_call: usize = std.math.maxInt(usize),
    short: anyerror = error.EndOfStream,
    pos: usize = 0,
    ended: bool = false,

    fn init(self: *EndingBody, buffer: []u8, data: []const u8, declared: ?u64) void {
        self.* = .{
            .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
            .data = data,
            .declared = declared,
        };
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *EndingBody = @alignCast(@fieldParentPtr("interface", r));
        if (self.ended) @panic("the body was read again after its end was reported");
        const have = self.data.len - self.pos;
        if (self.declared) |d| {
            if (self.pos >= d) {
                self.ended = true;
                return error.EndOfStream;
            }
            if (have == 0) {
                if (self.short == error.ReadFailed) return error.ReadFailed;
                self.ended = true;
                return error.EndOfStream;
            }
        } else if (have == 0) {
            self.ended = true;
            return error.EndOfStream;
        }
        var n = @min(have, self.per_call, @intFromEnum(limit));
        if (self.declared) |d| n = @min(n, @as(usize, @intCast(d - self.pos)));
        const wrote = try w.write(self.data[self.pos..][0..n]);
        self.pos += wrote;
        return wrote;
    }
};

fn sha256Hex(data: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

fn pumpedDigest(data: []const u8, declared: ?u64, per_call: usize) !fetch.Digest.Result {
    var tb: [64]u8 = undefined;
    var body: EndingBody = undefined;
    body.init(&tb, data, declared);
    body.per_call = per_call;
    var dg = fetch.Digest{ .max = 1 << 30 };
    try fetch.pump(&body.interface, declared, dg.sink());
    return dg.finish(t.allocator);
}

test "pump: a body of declared length is read whole and the reader is never asked past its end, at every size around a buffer" {
    const buf = 64 * 1024;
    // Exact multiples of the buffer are where a read loop that asks for a full buffer asks once more after the last byte.
    const sizes = [_]usize{ 0, 1, 63, 64, 65, buf - 1, buf, buf + 1, 2 * buf, 2 * buf + 1, 3 * buf, 200 * 1024 + 17 };
    for (sizes) |size| {
        for ([_]usize{ std.math.maxInt(usize), 4096, 1000, 7 }) |per_call| {
            if (per_call == 7 and size > 2 * buf) continue;
            const data = try payload(t.allocator, size);
            defer t.allocator.free(data);
            const r = try pumpedDigest(data, size, per_call);
            defer t.allocator.free(r.sha256);
            defer t.allocator.free(r.sri512);
            try t.expectEqual(@as(u64, size), r.size);
            const want = sha256Hex(data);
            try t.expectEqualStrings(&want, r.sha256);
        }
    }
}

test "pump: a body with no declared length is read to the end of the stream, whole, in segments of any size" {
    const buf = 64 * 1024;
    for ([_]usize{ 0, 1, buf - 1, buf, buf + 1, 2 * buf }) |size| {
        for ([_]usize{ std.math.maxInt(usize), 1000 }) |per_call| {
            const data = try payload(t.allocator, size);
            defer t.allocator.free(data);
            const r = try pumpedDigest(data, null, per_call);
            defer t.allocator.free(r.sha256);
            defer t.allocator.free(r.sri512);
            try t.expectEqual(@as(u64, size), r.size);
            const want = sha256Hex(data);
            try t.expectEqualStrings(&want, r.sha256);
        }
    }
}

test "pump: a body that ends before its declared length is TruncatedBody, however the reader says it ended" {
    const data = try payload(t.allocator, 100 * 1024);
    defer t.allocator.free(data);
    for ([_]anyerror{ error.EndOfStream, error.ReadFailed }) |how| {
        for ([_]u64{ data.len + 1, data.len + 64 * 1024, 2 * data.len }) |declared| {
            var tb: [64]u8 = undefined;
            var body: EndingBody = undefined;
            body.init(&tb, data, declared);
            body.short = how;
            var dg = fetch.Digest{ .max = 1 << 30 };
            try t.expectError(error.TruncatedBody, fetch.pump(&body.interface, declared, dg.sink()));
        }
    }
}

test "pump: a read that fails with no declared length is ReadFailed, and a sink's error is passed on as it is" {
    const data = try payload(t.allocator, 10);
    defer t.allocator.free(data);
    var tb: [64]u8 = undefined;
    var body: EndingBody = undefined;
    body.init(&tb, data, null);
    const Failing = struct {
        fn write(_: *anyopaque, _: []const u8) anyerror!void {
            return error.SinkFull;
        }
    };
    var dummy: u8 = 0;
    const sink = fetch.Sink{ .ctx = &dummy, .writeFn = Failing.write };
    try t.expectError(error.SinkFull, fetch.pump(&body.interface, null, sink));
    // An empty reader that fails, not ends.
    var failing = std.Io.Reader.failing;
    try t.expectError(error.ReadFailed, fetch.pump(&failing, null, sink));
}
