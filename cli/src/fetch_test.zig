//! fetch.zig: the one place the program reaches a socket. A download is pinned by its hash, so what matters here is that a body is kept whole (a short
//! body is an error, not a pin), that the URL policy is checked on every hop, and that nothing but https (and, for the tests, a named loopback) is reached.
//! The server is a thread of the test on a port the system picks, answering a request per connection from a table of paths.

const std = @import("std");
const fetch = @import("fetch.zig");
const t = std.testing;

// ---- the URL policy --------------------------------------------------------------------------------------------

test "urlAllowed: https always, http only to this machine and only when asked, and never a user@ in the authority" {
    const yes = [_][]const u8{
        "https://registry.example/a.tgz",
        "https://registry.example",
        "https://registry.example:8443/a?b=c#d",
        "https://a",
    };
    for (yes) |u| {
        try t.expect(fetch.urlAllowed(u, false));
        try t.expect(fetch.urlAllowed(u, true));
    }
    const only_loopback = [_][]const u8{ "http://127.0.0.1/a", "http://127.0.0.1:8080/a", "http://localhost/a", "http://localhost:1/", "http://127.0.0.1" };
    for (only_loopback) |u| {
        try t.expect(!fetch.urlAllowed(u, false));
        try t.expect(fetch.urlAllowed(u, true));
    }
    const never = [_][]const u8{
        "http://registry.example/a",
        "http://127.0.0.2/a",
        "http://localhost.example/a",
        "http://[::1]/a",
        "https://user@registry.example/a",
        "https://registry.example@evil.example/a",
        "http://user@127.0.0.1/a",
        "https:///path",
        "https://",
        "http://",
        "ftp://registry.example/a",
        "registry.example/a",
        "file:///etc/passwd",
        "",
        "HTTPS://registry.example/",
    };
    for (never) |u| {
        try t.expect(!fetch.urlAllowed(u, false));
        try t.expect(!fetch.urlAllowed(u, true));
    }
    // The authority ends at the first of `/`, `?`, `#`: a user@ after it is part of the path, not the authority.
    try t.expect(fetch.urlAllowed("https://registry.example/a@b", false));
    try t.expect(fetch.urlAllowed("https://registry.example?u=a@b", false));
    try t.expect(fetch.urlAllowed("https://registry.example#a@b", false));
}

// ---- the sinks -------------------------------------------------------------------------------------------------

test "Collect keeps the body up to its limit and refuses the byte after it" {
    var c = fetch.Collect{ .a = t.allocator, .max = 5 };
    defer c.buf.deinit(t.allocator);
    const s = c.sink();
    try s.write("ab");
    try s.write("cde");
    try t.expectEqualStrings("abcde", c.buf.items);
    try t.expectError(error.ResponseTooLarge, s.write("f"));
    try t.expectEqualStrings("abcde", c.buf.items);
    // The limit is on the total, not on one write.
    var c2 = fetch.Collect{ .a = t.allocator, .max = 3 };
    defer c2.buf.deinit(t.allocator);
    try t.expectError(error.ResponseTooLarge, c2.sink().write("abcd"));
    try t.expectEqual(@as(usize, 0), c2.buf.items.len);
}

test "Digest: sha256 as hex, sha512 as npm writes it, the count; the limit is on the total" {
    var d = fetch.Digest{ .max = 3 };
    const s = d.sink();
    try s.write("a");
    try s.write("bc");
    try t.expectError(error.ResponseTooLarge, s.write("d"));
    const r = try d.finish(t.allocator);
    defer t.allocator.free(r.sha256);
    defer t.allocator.free(r.sri512);
    try t.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", r.sha256);
    try t.expectEqualStrings("sha512-3a81oZNherrMQXNJriBBMRLm+k6JqX6iCp7u5ktV05ohkpkqJ0/BqDa6PCOj/uu9RU1EI2Q86A4qmslPpUyknw==", r.sri512);
    try t.expectEqual(@as(u64, 3), r.size);
    // The same bytes in one write give the same answer.
    var d2 = fetch.Digest{ .max = 100 };
    try d2.sink().write("abc");
    const r2 = try d2.finish(t.allocator);
    defer t.allocator.free(r2.sha256);
    defer t.allocator.free(r2.sri512);
    try t.expectEqualStrings(r.sha256, r2.sha256);
    // A body that is exactly the limit is accepted.
    var d3 = fetch.Digest{ .max = 3 };
    try d3.sink().write("abc");
}

// ---- a server on loopback ---------------------------------------------------------------------------------------

/// `n` bytes of a body that is not all one byte, so a chunk read out of order or twice is a different hash.
fn payload(a: std.mem.Allocator, n: usize) ![]u8 {
    const b = try a.alloc(u8, n);
    for (b, 0..) |*x, i| x.* = @intCast((i * 7 + i / 251) % 256);
    return b;
}

const big_len = 200 * 1024 + 17;

const Server = struct {
    server: std.net.Server = undefined,
    port: u16 = 0,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: std.Thread = undefined,
    big: []u8 = &.{},

    fn start(self: *Server) !void {
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        self.server = try addr.listen(.{ .reuse_address = true });
        self.port = self.server.listen_address.getPort();
        self.big = try payload(t.allocator, big_len);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn finish(self: *Server) void {
        self.stop.store(true, .release);
        // One more connection wakes the accept; the thread sees the flag and ends.
        if (std.net.tcpConnectToAddress(self.server.listen_address)) |s| s.close() else |_| {}
        self.thread.join();
        self.server.deinit();
        t.allocator.free(self.big);
    }

    fn run(self: *Server) void {
        while (true) {
            const conn = self.server.accept() catch return;
            defer conn.stream.close();
            if (self.stop.load(.acquire)) return;
            self.handle(conn.stream) catch {};
        }
    }

    fn handle(self: *Server, s: std.net.Stream) !void {
        var buf: [4096]u8 = undefined;
        var n: usize = 0;
        while (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n") == null) {
            const got = try s.read(buf[n..]);
            if (got == 0) return;
            n += got;
        }
        const line_end = std.mem.indexOf(u8, buf[0..n], "\r\n").?;
        const line = buf[0..line_end];
        const path_start = std.mem.indexOfScalar(u8, line, ' ').? + 1;
        const path_end = std.mem.indexOfScalarPos(u8, line, path_start, ' ').?;
        const path = line[path_start..path_end];
        var out: [512]u8 = undefined;
        const ok_head = "HTTP/1.1 200 OK\r\nConnection: close\r\n";
        if (std.mem.eql(u8, path, "/abc")) {
            try s.writeAll(ok_head ++ "Content-Length: 3\r\n\r\nabc");
        } else if (std.mem.eql(u8, path, "/big")) {
            const head = try std.fmt.bufPrint(&out, "{s}Content-Length: {d}\r\n\r\n", .{ ok_head, self.big.len });
            try s.writeAll(head);
            try s.writeAll(self.big);
        } else if (std.mem.eql(u8, path, "/no-length")) {
            // The body ends when the connection does.
            try s.writeAll(ok_head ++ "\r\nrest of the connection");
        } else if (std.mem.eql(u8, path, "/short")) {
            try s.writeAll(ok_head ++ "Content-Length: 100\r\n\r\nonly ten b");
        } else if (std.mem.eql(u8, path, "/redirect")) {
            const head = try std.fmt.bufPrint(&out, "HTTP/1.1 302 Found\r\nConnection: close\r\nLocation: http://127.0.0.1:{d}/abc\r\nContent-Length: 0\r\n\r\n", .{self.port});
            try s.writeAll(head);
        } else if (std.mem.eql(u8, path, "/loop")) {
            const head = try std.fmt.bufPrint(&out, "HTTP/1.1 301 Moved\r\nConnection: close\r\nLocation: http://127.0.0.1:{d}/loop\r\nContent-Length: 0\r\n\r\n", .{self.port});
            try s.writeAll(head);
        } else if (std.mem.eql(u8, path, "/no-location")) {
            try s.writeAll("HTTP/1.1 302 Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
        } else if (std.mem.eql(u8, path, "/to-other-host")) {
            try s.writeAll("HTTP/1.1 302 Found\r\nConnection: close\r\nLocation: http://registry.example/abc\r\nContent-Length: 0\r\n\r\n");
        } else if (std.mem.eql(u8, path, "/to-user")) {
            const head = try std.fmt.bufPrint(&out, "HTTP/1.1 302 Found\r\nConnection: close\r\nLocation: http://user@127.0.0.1:{d}/abc\r\nContent-Length: 0\r\n\r\n", .{self.port});
            try s.writeAll(head);
        } else if (std.mem.eql(u8, path, "/to-relative")) {
            try s.writeAll("HTTP/1.1 302 Found\r\nConnection: close\r\nLocation: /abc\r\nContent-Length: 0\r\n\r\n");
        } else {
            try s.writeAll("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
        }
    }
};

var url_buf: [128]u8 = undefined;

/// The URL of `path` on the server, in a buffer that holds it until the next call.
fn urlOf(_: std.mem.Allocator, s: *const Server, path: []const u8) ![]u8 {
    return std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ s.port, path });
}

fn getBody(h: *fetch.HttpFetcher, url: []const u8) ![]u8 {
    var c = fetch.Collect{ .a = t.allocator, .max = 1 << 20 };
    errdefer c.buf.deinit(t.allocator);
    try h.fetcher().get(url, c.sink());
    return c.buf.toOwnedSlice(t.allocator);
}

test "HttpFetcher: a body is read whole, with or without a length, however many buffers it takes" {
    var srv = Server{};
    try srv.start();
    defer srv.finish();
    var h = fetch.HttpFetcher{ .allocator = t.allocator, .allow_http_loopback = true };
    const abc = try getBody(&h, try urlOf(t.allocator, &srv, "/abc"));
    defer t.allocator.free(abc);
    try t.expectEqualStrings("abc", abc);
    const rest = try getBody(&h, try urlOf(t.allocator, &srv, "/no-length"));
    defer t.allocator.free(rest);
    try t.expectEqualStrings("rest of the connection", rest);
    // 200 KiB and a bit: three reads of the 64 KiB buffer and a partial one, as the digest of the whole.
    var dg = fetch.Digest{ .max = 1 << 30 };
    try h.fetcher().get(try urlOf(t.allocator, &srv, "/big"), dg.sink());
    const r = try dg.finish(t.allocator);
    defer t.allocator.free(r.sha256);
    defer t.allocator.free(r.sri512);
    try t.expectEqual(@as(u64, big_len), r.size);
    var want: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(srv.big, &want, .{});
    try t.expectEqualStrings(&std.fmt.bytesToHex(want, .lower), r.sha256);
}

test "HttpFetcher: a body longer than the sink takes is an error from the sink, and a body that ends early is TruncatedBody" {
    var srv = Server{};
    try srv.start();
    defer srv.finish();
    var h = fetch.HttpFetcher{ .allocator = t.allocator, .allow_http_loopback = true };
    var dg = fetch.Digest{ .max = 1000 };
    try t.expectError(error.ResponseTooLarge, h.fetcher().get(try urlOf(t.allocator, &srv, "/big"), dg.sink()));
    var c = fetch.Collect{ .a = t.allocator, .max = 1 << 20 };
    defer c.buf.deinit(t.allocator);
    try t.expectError(error.TruncatedBody, h.fetcher().get(try urlOf(t.allocator, &srv, "/short"), c.sink()));
}

test "HttpFetcher: a status that is not 200 is an error, a redirect is followed under the policy, five hops are the most" {
    var srv = Server{};
    try srv.start();
    defer srv.finish();
    var h = fetch.HttpFetcher{ .allocator = t.allocator, .allow_http_loopback = true };
    var c = fetch.Collect{ .a = t.allocator, .max = 1 << 20 };
    defer c.buf.deinit(t.allocator);
    try t.expectError(error.HttpStatusNotOk, h.fetcher().get(try urlOf(t.allocator, &srv, "/missing"), c.sink()));
    try h.fetcher().get(try urlOf(t.allocator, &srv, "/redirect"), c.sink());
    try t.expectEqualStrings("abc", c.buf.items);
    try t.expectError(error.TooManyRedirects, h.fetcher().get(try urlOf(t.allocator, &srv, "/loop"), c.sink()));
    try t.expectError(error.RedirectWithoutLocation, h.fetcher().get(try urlOf(t.allocator, &srv, "/no-location"), c.sink()));
    // Where a redirect points is checked like the first URL: another host over http, a user@, and a path with no scheme are not followed.
    try t.expectError(error.UrlNotAllowed, h.fetcher().get(try urlOf(t.allocator, &srv, "/to-other-host"), c.sink()));
    try t.expectError(error.UrlNotAllowed, h.fetcher().get(try urlOf(t.allocator, &srv, "/to-user"), c.sink()));
    try t.expectError(error.UrlNotAllowed, h.fetcher().get(try urlOf(t.allocator, &srv, "/to-relative"), c.sink()));
    // With fewer hops allowed the loop ends sooner (the limit is the field's).
    var h2 = fetch.HttpFetcher{ .allocator = t.allocator, .allow_http_loopback = true, .max_redirects = 0 };
    try t.expectError(error.TooManyRedirects, h2.fetcher().get(try urlOf(t.allocator, &srv, "/redirect"), c.sink()));
}

test "HttpFetcher: loopback over http is refused unless asked for, other schemes are refused, and a trust file that is not there is an error" {
    var srv = Server{};
    try srv.start();
    defer srv.finish();
    var h = fetch.HttpFetcher{ .allocator = t.allocator };
    var c = fetch.Collect{ .a = t.allocator, .max = 1 << 20 };
    defer c.buf.deinit(t.allocator);
    try t.expectError(error.UrlNotAllowed, h.fetcher().get(try urlOf(t.allocator, &srv, "/abc"), c.sink()));
    try t.expectError(error.UrlNotAllowed, h.fetcher().get("ftp://127.0.0.1/abc", c.sink()));
    try t.expectError(error.UrlNotAllowed, h.fetcher().get("https://user@registry.example/abc", c.sink()));
    var tls = fetch.HttpFetcher{ .allocator = t.allocator, .ca_file = "/no/such/ca.pem" };
    if (tls.fetcher().get("https://registry.example/abc", c.sink())) |_| {
        return error.ReachedTheNetworkWithoutTheTrustFile;
    } else |_| {}
    // And a URL that is allowed but cannot be parsed or reached is an error, not a hang.
    var h3 = fetch.HttpFetcher{ .allocator = t.allocator, .allow_http_loopback = true };
    if (h3.fetcher().get("http://127.0.0.1:1/abc", c.sink())) |_| return error.Reached else |_| {}
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
