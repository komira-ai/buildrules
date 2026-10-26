//! The real client of `autopin_api.zig` against a server on loopback that records what it received. This is where
//! the wire is looked at: the token is sent only when a request says so, a 302 is handed back and never followed,
//! a body goes out as given, and a response over its cap is an error. Every test is named for the defect it catches.

const std = @import("std");
const api_mod = @import("autopin_api.zig");
const t = std.testing;

const Seen = struct {
    method: []const u8,
    target: []const u8,
    authorization: ?[]const u8,
    accept: ?[]const u8,
    content_type: ?[]const u8,
    body: []const u8,
};

const Route = struct {
    target: []const u8,
    status: u16 = 200,
    body: []const u8 = "",
    location: ?[]const u8 = null,
    /// Read the request, then never answer (until the server stops).
    stall: bool = false,
    /// Claim a longer body than is sent (the connection then ends early).
    claim_len: ?usize = null,
};

const Server = struct {
    server: std.net.Server,
    thread: std.Thread = undefined,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    port: u16,
    routes: []const Route,
    seen: std.ArrayList(Seen) = .empty,
    mutex: std.Thread.Mutex = .{},
    /// Set by `stop`: a stalled connection is held until then.
    release: std.Thread.ResetEvent = .{},

    const gpa = std.heap.page_allocator;

    fn start(routes: []const Route) !*Server {
        const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
        const self = try gpa.create(Server);
        self.* = .{ .server = try addr.listen(.{ .reuse_address = true }), .port = 0, .routes = routes };
        self.port = self.server.listen_address.getPort();
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn stop(self: *Server) void {
        self.stopping.store(true, .release);
        self.release.set();
        if (std.net.tcpConnectToAddress(self.server.listen_address)) |s| s.close() else |_| {}
        self.thread.join();
        self.server.deinit();
    }

    fn base(self: *Server, a: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{self.port});
    }

    fn count(self: *Server, target: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        for (self.seen.items) |s| if (std.mem.eql(u8, s.target, target)) {
            n += 1;
        };
        return n;
    }

    fn first(self: *Server, target: []const u8) ?Seen {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.seen.items) |s| if (std.mem.eql(u8, s.target, target)) return s;
        return null;
    }

    fn serve(self: *Server) void {
        while (!self.stopping.load(.acquire)) {
            const conn = self.server.accept() catch continue;
            defer conn.stream.close();
            if (self.stopping.load(.acquire)) return;
            var rbuf: [8192]u8 = undefined;
            var wbuf: [1024]u8 = undefined;
            var reader = conn.stream.reader(&rbuf);
            var writer = conn.stream.writer(&wbuf);
            const w = &writer.interface;
            var srv = std.http.Server.init(reader.interface(), w);
            var req = srv.receiveHead() catch continue;
            // Copy what is wanted from the head before the body is read: reading may reuse the buffer.
            const target = gpa.dupe(u8, req.head.target) catch continue;
            const method = gpa.dupe(u8, @tagName(req.head.method)) catch continue;
            var authorization: ?[]const u8 = null;
            var accept: ?[]const u8 = null;
            var content_type: ?[]const u8 = null;
            var it = req.iterateHeaders();
            while (it.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "authorization")) authorization = gpa.dupe(u8, h.value) catch null;
                if (std.ascii.eqlIgnoreCase(h.name, "accept")) accept = gpa.dupe(u8, h.value) catch null;
                if (std.ascii.eqlIgnoreCase(h.name, "content-type")) content_type = gpa.dupe(u8, h.value) catch null;
            }
            var body: []const u8 = "";
            if (req.head.content_length) |n| {
                var bbuf: [4096]u8 = undefined;
                const body_reader = req.readerExpectNone(&bbuf);
                body = body_reader.readAlloc(gpa, @intCast(n)) catch continue;
            }
            self.mutex.lock();
            self.seen.append(gpa, .{ .method = method, .target = target, .authorization = authorization, .accept = accept, .content_type = content_type, .body = body }) catch {};
            self.mutex.unlock();
            var found: ?Route = null;
            for (self.routes) |r| if (std.mem.eql(u8, r.target, target)) {
                found = r;
            };
            var head_buf: [512]u8 = undefined;
            if (found) |r| {
                if (r.stall) {
                    // Held, with the request read and no answer sent, until the test stops the server: no clock is involved.
                    self.release.wait();
                    continue;
                }
                const loc = if (r.location) |l| std.fmt.bufPrint(head_buf[256..], "Location: {s}\r\n", .{l}) catch "" else "";
                const head = std.fmt.bufPrint(head_buf[0..256], "HTTP/1.1 {d} X\r\nContent-Length: {d}\r\nConnection: close\r\n", .{ r.status, r.claim_len orelse r.body.len }) catch continue;
                w.writeAll(head) catch continue;
                w.writeAll(loc) catch continue;
                w.writeAll("\r\n") catch continue;
                w.writeAll(r.body) catch continue;
            } else {
                w.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") catch continue;
            }
            w.flush() catch continue;
        }
    }
};

const table_routes = [_]Route{
    .{ .target = "/repos/o/r", .body = "{\"ok\":true}" },
    .{ .target = "/big", .body = "x" ** 5000 },
    .{ .target = "/artifact", .status = 302, .location = "https://x.blob.core.windows.net/a" },
    .{ .target = "/created", .status = 201, .body = "{\"sha\":\"abc\"}" },
};

fn client(a: std.mem.Allocator, s: *Server) !api_mod.Http {
    return .{ .allocator = a, .token = "SECRET-TOKEN", .base_url = try s.base(a), .allow_http_loopback = true };
}

test "http: a request that says auth carries the bearer token and the media type, and the body comes back" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Server.start(&table_routes);
    defer s.stop();
    var http = try client(a, s);
    const r = try http.api().send(a, .{ .path = "repos/o/r" });
    try t.expectEqual(@as(u16, 200), r.status);
    try t.expectEqualStrings("{\"ok\":true}", r.body);
    const seen = s.first("/repos/o/r").?;
    try t.expectEqualStrings("GET", seen.method);
    try t.expectEqualStrings("Bearer SECRET-TOKEN", seen.authorization.?);
    try t.expectEqualStrings(api_mod.json_accept, seen.accept.?);
}

test "http: a request that says no auth carries no Authorization header at all" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Server.start(&table_routes);
    defer s.stop();
    var http = try client(a, s);
    _ = try http.api().send(a, .{ .path = "repos/o/r", .auth = false });
    try t.expect(s.first("/repos/o/r").?.authorization == null);
}

test "http: an absolute URL is requested as it is, without the token when the request says so" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Server.start(&table_routes);
    defer s.stop();
    var http = try client(a, s);
    const url = try std.fmt.allocPrint(a, "{s}/repos/o/r", .{try s.base(a)});
    const r = try http.api().send(a, .{ .url = url, .auth = false, .accept = "*/*" });
    try t.expectEqual(@as(u16, 200), r.status);
    const seen = s.first("/repos/o/r").?;
    try t.expect(seen.authorization == null);
    try t.expectEqualStrings("*/*", seen.accept.?);
}

test "http: a 302 is handed back with its Location and is not followed" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Server.start(&table_routes);
    defer s.stop();
    var http = try client(a, s);
    const r = try http.api().send(a, .{ .path = "artifact" });
    try t.expectEqual(@as(u16, 302), r.status);
    try t.expectEqualStrings("https://x.blob.core.windows.net/a", r.location.?);
    try t.expectEqual(@as(usize, 1), s.count("/artifact"));
}

test "http: a POST sends its body and says it is JSON; a PATCH too" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Server.start(&table_routes);
    defer s.stop();
    var http = try client(a, s);
    const r = try http.api().send(a, .{ .method = .POST, .path = "created", .body = "{\"content\":\"x\"}" });
    try t.expectEqual(@as(u16, 201), r.status);
    try t.expectEqualStrings("{\"sha\":\"abc\"}", r.body);
    const seen = s.first("/created").?;
    try t.expectEqualStrings("POST", seen.method);
    try t.expectEqualStrings("{\"content\":\"x\"}", seen.body);
    try t.expectEqualStrings("application/json", seen.content_type.?);
    try t.expectEqualStrings("Bearer SECRET-TOKEN", seen.authorization.?);
    _ = try http.api().send(a, .{ .method = .PATCH, .path = "repos/o/r", .body = "{\"force\":false}" });
    var found_patch = false;
    s.mutex.lock();
    for (s.seen.items) |x| if (std.mem.eql(u8, x.method, "PATCH")) {
        found_patch = std.mem.eql(u8, x.body, "{\"force\":false}");
    };
    s.mutex.unlock();
    try t.expect(found_patch);
}

test "http: a response over the cap is an error, not a truncated body" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Server.start(&table_routes);
    defer s.stop();
    var http = try client(a, s);
    try t.expectError(error.ResponseTooLarge, http.api().send(a, .{ .path = "big", .max_body = 4000 }));
    const ok = try http.api().send(a, .{ .path = "big", .max_body = 5000 });
    try t.expectEqual(@as(usize, 5000), ok.body.len);
}

test "http: http is refused unless loopback was allowed, and an unknown path is a 404" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Server.start(&table_routes);
    defer s.stop();
    var http = try client(a, s);
    const r = try http.api().send(a, .{ .path = "nothing/here" });
    try t.expectEqual(@as(u16, 404), r.status);
    http.allow_http_loopback = false;
    try t.expectError(error.UrlNotAllowed, http.api().send(a, .{ .path = "repos/o/r" }));
    try t.expectEqual(@as(usize, 1), s.count("/repos/o/r") + s.count("/nothing/here"));
}

/// What the stand-in for the kernel's timer was asked, and what the real call put on the socket. Zig runs the tests of a binary one after
/// another; each test that uses these resets them first.
var deadline_calls: usize = 0;
var deadline_seconds: u32 = 0;
var deadline_rcv_sec: i64 = -1;
var deadline_snd_sec: i64 = -1;

fn readBackTimeout(handle: std.posix.socket_t, which: u32) !i64 {
    var tv: std.posix.timeval = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.posix.timeval);
    const rc = std.posix.system.getsockopt(handle, std.posix.SOL.SOCKET, @intCast(which), @ptrCast(&tv), &len);
    if (std.posix.errno(rc) != .SUCCESS) return error.GetSockOptFailed;
    return @intCast(tv.sec);
}

/// The real deadlines, then a look at what the kernel holds.
fn recordRealDeadlines(handle: std.posix.socket_t, seconds: u32) anyerror!void {
    deadline_calls += 1;
    deadline_seconds = seconds;
    try api_mod.Http.setDeadlines(handle, seconds);
    deadline_rcv_sec = try readBackTimeout(handle, std.posix.SO.RCVTIMEO);
    deadline_snd_sec = try readBackTimeout(handle, std.posix.SO.SNDTIMEO);
}

/// A socket whose timer has already run out: a read that has nothing to read ends at once with `WouldBlock`, which is what the kernel's
/// receive timeout does when the time is up. No time passes in the test; the server has read the request and is silent.
fn expiredDeadlines(handle: std.posix.socket_t, seconds: u32) anyerror!void {
    deadline_calls += 1;
    deadline_seconds = seconds;
    const flags = try std.posix.fcntl(handle, std.posix.F.GETFL, 0);
    const nonblock: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
    _ = try std.posix.fcntl(handle, std.posix.F.SETFL, flags | nonblock);
}

test "http: the configured timeout is what is put on the connection, as both the read and the write deadline, once per request" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Server.start(&table_routes);
    defer s.stop();
    var http = try client(a, s);
    http.timeout_seconds = 7;
    http.deadlines_fn = recordRealDeadlines;
    deadline_calls = 0;
    deadline_rcv_sec = -1;
    deadline_snd_sec = -1;
    const r = try http.api().send(a, .{ .path = "repos/o/r" });
    try t.expectEqual(@as(u16, 200), r.status);
    try t.expectEqual(@as(usize, 1), deadline_calls);
    try t.expectEqual(@as(u32, 7), deadline_seconds);
    try t.expectEqual(@as(i64, 7), deadline_rcv_sec);
    try t.expectEqual(@as(i64, 7), deadline_snd_sec);
}

test "http: the default deadline is sixty seconds" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const s = try Server.start(&table_routes);
    defer s.stop();
    var http = try client(a, s);
    http.deadlines_fn = recordRealDeadlines;
    deadline_calls = 0;
    deadline_rcv_sec = -1;
    _ = try http.api().send(a, .{ .path = "repos/o/r" });
    try t.expectEqual(@as(i64, 60), deadline_rcv_sec);
}

test "http: a server that reads the request and never answers ends the call when the read deadline runs out, with an error and no answer" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const stall_routes = [_]Route{.{ .target = "/repos/o/r", .stall = true }};
    const s = try Server.start(&stall_routes);
    defer s.stop();
    var http = try client(a, s);
    http.timeout_seconds = 1;
    http.deadlines_fn = expiredDeadlines;
    deadline_calls = 0;
    try t.expect(std.meta.isError(http.api().send(a, .{ .path = "repos/o/r" })));
    // The deadline was put on the connection from the configured value; the stalled server was not what ended the call.
    try t.expectEqual(@as(usize, 1), deadline_calls);
    try t.expectEqual(@as(u32, 1), deadline_seconds);
}

test "http: a body that ends before its Content-Length is an error, not a short body taken for the whole" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const routes = [_]Route{.{ .target = "/repos/o/r", .body = "only ten b", .claim_len = 100 }};
    const s = try Server.start(&routes);
    defer s.stop();
    var http = try client(a, s);
    try t.expect(std.meta.isError(http.api().send(a, .{ .path = "repos/o/r" })));
}
