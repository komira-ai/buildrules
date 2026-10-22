//! `buildrules autopin verify-pins` against a registry on loopback. The tarballs are real bytes; the lock and the rows are made from
//! their real digests, then one thing at a time is made wrong. Every test is named for the defect it catches.

const std = @import("std");
const compute = @import("autopin_compute.zig");
const fetch = @import("fetch.zig");
const kit = @import("testkit.zig");
const npm = @import("npm_cmd.zig");
const table = @import("autopin_table.zig");
const t = std.testing;
const Diag = @import("diag.zig").Diag;

const reg = "https://registry.npmjs.org/";
const pad_bytes = "the tarball of left-pad";
const scope_bytes = "the tarball of @scope/pkg, a little longer";
const pins_prefix = "# header\n\nPINS = {}\n\n";
const pj = "{\"name\":\"demo\",\"version\":\"1.0.0\",\"scripts\":{\"test\":\"jest\"}}";

const Served = struct { path: []const u8, body: []const u8 };

/// A registry on loopback: it answers each GET for a path it knows with the bytes, 404 for any other, and counts the requests.
const Registry = struct {
    server: std.net.Server = undefined,
    port: u16 = 0,
    thread: std.Thread = undefined,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    served: []const Served,
    requests: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn start(self: *Registry) !void {
        self.server = try (try std.net.Address.parseIp("127.0.0.1", 0)).listen(.{ .reuse_address = true });
        self.port = self.server.listen_address.getPort();
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn serve(self: *Registry) void {
        while (true) {
            const conn = self.server.accept() catch return;
            defer conn.stream.close();
            if (self.stopping.load(.acquire)) return;
            var buf: [2048]u8 = undefined;
            var n: usize = 0;
            while (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n") == null and n < buf.len) {
                const got = conn.stream.read(buf[n..]) catch break;
                if (got == 0) break;
                n += got;
            }
            _ = self.requests.fetchAdd(1, .monotonic);
            const line_end = std.mem.indexOf(u8, buf[0..n], "\r\n") orelse continue;
            const first = buf[0..line_end];
            const p0 = (std.mem.indexOfScalar(u8, first, ' ') orelse continue) + 1;
            const p1 = std.mem.indexOfScalarPos(u8, first, p0, ' ') orelse continue;
            const path = first[p0..p1];
            var body: ?[]const u8 = null;
            for (self.served) |s| if (std.mem.eql(u8, s.path, path)) {
                body = s.body;
            };
            var head: [160]u8 = undefined;
            if (body) |b| {
                const h = std.fmt.bufPrint(&head, "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n", .{b.len}) catch continue;
                conn.stream.writeAll(h) catch continue;
                conn.stream.writeAll(b) catch continue;
            } else {
                conn.stream.writeAll("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n") catch continue;
            }
        }
    }

    fn finish(self: *Registry) void {
        self.stopping.store(true, .release);
        if (std.net.tcpConnectToAddress(self.server.listen_address)) |s| s.close() else |_| {}
        self.thread.join();
        self.server.deinit();
    }
};

var current: ?*Registry = null;
var saved_fetcher: ?npm.Fetch = null;

/// The real download function, with the registry's host replaced by the loopback server (plain http allowed only for the test).
fn viaLoopback(a: std.mem.Allocator, url: []const u8) anyerror!fetch.Digest.Result {
    const reg_server = current.?;
    const local = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/{s}", .{ reg_server.port, url[reg.len..] });
    return compute.fetchWith(a, local, true);
}

fn sriOf(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var h: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(bytes, &h, .{});
    const enc = std.base64.standard.Encoder;
    const b64 = try a.alloc(u8, enc.calcSize(64));
    _ = enc.encode(b64, &h);
    return std.fmt.allocPrint(a, "sha512-{s}", .{b64});
}

fn sha256Of(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &h, .{});
    return std.fmt.allocPrint(a, "{s}", .{std.fmt.bytesToHex(h, .lower)});
}

const Fix = struct { h: *kit.Harness, reg: *Registry, rows: []table.Row, lock: []u8 };

/// A repository with directory `site` of this kind, a registry serving the two tarballs, and the rows made from their real digests.
fn setup(kind: []const u8) !Fix {
    const h = try kit.Harness.create();
    const a = h.a();
    const pad_sri = try sriOf(a, pad_bytes);
    const scope_sri = try sriOf(a, scope_bytes);
    const rows = try a.dupe(table.Row, &.{
        .{ .key = "@scope/pkg@2.0.0", .name = "@scope/pkg", .version = "2.0.0", .url = reg ++ "@scope/pkg/-/pkg-2.0.0.tgz", .sri512 = scope_sri, .sha256 = try sha256Of(a, scope_bytes), .size = scope_bytes.len },
        .{ .key = "left-pad@1.3.0", .name = "left-pad", .version = "1.3.0", .url = reg ++ "left-pad/-/left-pad-1.3.0.tgz", .sri512 = pad_sri, .sha256 = try sha256Of(a, pad_bytes), .size = pad_bytes.len },
    });
    const lock = try std.fmt.allocPrint(a, "{{\"name\":\"demo\",\"lockfileVersion\":3,\"packages\":{{\"\":{{\"name\":\"demo\"}},\"node_modules/left-pad\":{{\"version\":\"1.3.0\",\"resolved\":\"{s}left-pad/-/left-pad-1.3.0.tgz\",\"integrity\":\"{s}\"}},\"node_modules/@scope/pkg\":{{\"version\":\"2.0.0\",\"resolved\":\"{s}@scope/pkg/-/pkg-2.0.0.tgz\",\"integrity\":\"{s}\"}}}}}}", .{ reg, pad_sri, reg, scope_sri });
    const served = try a.dupe(Served, &.{
        .{ .path = "/left-pad/-/left-pad-1.3.0.tgz", .body = pad_bytes },
        .{ .path = "/@scope/pkg/-/pkg-2.0.0.tgz", .body = scope_bytes },
    });
    const r = try a.create(Registry);
    r.* = .{ .served = served };
    try r.start();
    try h.put(".buckconfig", "[cells]\n");
    try h.put("site/package.json", pj);
    try h.put("site/package-lock.json", lock);
    var diag = Diag.init(a);
    const text: []const u8 = if (std.mem.eql(u8, kind, "pins-lock"))
        try table.freshPins(a, pins_prefix, rows)
    else
        (try table.freshBuildrules(a, pj, lock, rows, &diag)).?;
    try h.put(if (std.mem.eql(u8, kind, "pins-lock")) "site/pins.lock.bzl" else "site/buildrules.lock.bzl", text);
    current = r;
    saved_fetcher = compute.fetcher;
    compute.fetcher = &viaLoopback;
    return .{ .h = h, .reg = r, .rows = rows, .lock = lock };
}

fn teardown(f: Fix) void {
    if (saved_fetcher) |s| compute.fetcher = s;
    current = null;
    f.reg.finish();
    f.h.destroy();
}

fn verify(f: Fix, kind: []const u8) kit.Run {
    const set = std.fmt.allocPrint(f.h.a(), "site={s}", .{kind}) catch unreachable;
    return f.h.run(&.{ "autopin", "verify-pins", "--set", set });
}

fn putTable(f: Fix, kind: []const u8, rows: []const table.Row) !void {
    const a = f.h.a();
    var diag = Diag.init(a);
    if (std.mem.eql(u8, kind, "pins-lock")) {
        try f.h.put("site/pins.lock.bzl", try table.freshPins(a, pins_prefix, rows));
    } else {
        try f.h.put("site/buildrules.lock.bzl", (try table.freshBuildrules(a, pj, f.lock, rows, &diag)).?);
    }
}

test "verify-pins: a table whose every row is as the registry's bytes say passes, and every row was downloaded" {
    inline for (.{ "buildrules-lock", "pins-lock" }) |kind| {
        const f = try setup(kind);
        defer teardown(f);
        const before = f.reg.requests.load(.monotonic);
        const r = verify(f, kind);
        errdefer std.debug.print("out: {s}\nerr: {s}\n", .{ r.out, r.err });
        try t.expectEqual(@as(u8, 0), r.code);
        try t.expect(kit.contains(r.out, "site: verified 2 row(s)"));
        // Replays of the command (failing streams and allocators) fetch too; the real run fetched both rows at least.
        try t.expect(f.reg.requests.load(.monotonic) - before >= 2);
    }
}

test "verify-pins: a wrong sha256 in a row is refused (the lock and the table agree, nothing changed, and it still fails)" {
    inline for (.{ "buildrules-lock", "pins-lock" }) |kind| {
        const f = try setup(kind);
        defer teardown(f);
        const rows = try f.h.a().dupe(table.Row, f.rows);
        rows[1].sha256 = "0" ** 64;
        try putTable(f, kind, rows);
        const r = verify(f, kind);
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, "left-pad@1.3.0: the bytes at"));
        try t.expect(kit.contains(r.err, "sha256"));
    }
}

test "verify-pins: a wrong size in a row is refused" {
    inline for (.{ "buildrules-lock", "pins-lock" }) |kind| {
        const f = try setup(kind);
        defer teardown(f);
        const rows = try f.h.a().dupe(table.Row, f.rows);
        rows[0].size += 1;
        try putTable(f, kind, rows);
        const r = verify(f, kind);
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, "@scope/pkg@2.0.0"));
        try t.expect(kit.contains(r.err, "bytes; the row says"));
    }
}

test "verify-pins: bytes whose sha512 is not the lock's are refused" {
    const f = try setup("pins-lock");
    defer teardown(f);
    const served = try f.h.a().dupe(Served, &.{
        .{ .path = "/left-pad/-/left-pad-1.3.0.tgz", .body = "other bytes" },
        .{ .path = "/@scope/pkg/-/pkg-2.0.0.tgz", .body = scope_bytes },
    });
    f.reg.served = served;
    const r = verify(f, "pins-lock");
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "have sha512"));
}

test "verify-pins: a tarball the registry does not have is a failure, naming the row" {
    const f = try setup("pins-lock");
    defer teardown(f);
    f.reg.served = &.{};
    const r = verify(f, "pins-lock");
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "left-pad@1.3.0: fetching"));
}

test "verify-pins: a table that is not bound to the lock is refused before any download" {
    const f = try setup("pins-lock");
    defer teardown(f);
    try putTable(f, "pins-lock", f.rows[0..1]);
    const before = f.reg.requests.load(.monotonic);
    const r = verify(f, "pins-lock");
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "no row in the table"));
    try t.expectEqual(before, f.reg.requests.load(.monotonic));
}

test "verify-pins: a hostile lock is refused, and what it says reaches the log on one line" {
    const f = try setup("pins-lock");
    defer teardown(f);
    try f.h.put("site/package-lock.json", try std.fmt.allocPrint(f.h.a(), "{{\"name\":\"d\",\"lockfileVersion\":3,\"packages\":{{\"\":{{}},\"node_modules/x\\n::error::boom\":{{\"version\":\"1.0.0\"}}}}}}", .{}));
    const r = verify(f, "pins-lock");
    try t.expectEqual(@as(u8, 1), r.code);
    var lines = std.mem.splitScalar(u8, r.err, '\n');
    while (lines.next()) |l| try t.expect(l.len == 0 or std.mem.startsWith(u8, l, "buildrules: "));
    try t.expect(!kit.contains(r.out, "::"));
}

test "verify-pins: a missing lock, a missing table, and a table with no NPM block are refused" {
    const f = try setup("pins-lock");
    defer teardown(f);
    try f.h.put("site/pins.lock.bzl", "# nothing here\n");
    var r = verify(f, "pins-lock");
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "no NPM block"));
    r = f.h.run(&.{ "autopin", "verify-pins", "--set", "nowhere=pins-lock" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "no nowhere/package-lock.json"));
    try f.h.put("lonely/package-lock.json", f.lock);
    r = f.h.run(&.{ "autopin", "verify-pins", "--set", "lonely=pins-lock" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "no table lonely/pins.lock.bzl"));
}

test "verify-pins: usage errors exit 2, -h prints the usage, --dir names the repository" {
    const f = try setup("pins-lock");
    defer teardown(f);
    try t.expectEqual(@as(u8, 2), f.h.run(&.{ "autopin", "verify-pins" }).code);
    try t.expectEqual(@as(u8, 2), f.h.run(&.{ "autopin", "verify-pins", "--bogus" }).code);
    try t.expectEqual(@as(u8, 2), f.h.run(&.{ "autopin", "verify-pins", "--set" }).code);
    try t.expectEqual(@as(u8, 2), f.h.run(&.{ "autopin", "verify-pins", "--set", "x=other" }).code);
    const help = f.h.run(&.{ "autopin", "verify-pins", "-h" });
    try t.expectEqual(@as(u8, 0), help.code);
    try t.expect(kit.contains(help.out, "EVERY row"));
    try t.expectEqual(@as(u8, 0), f.h.run(&.{ "autopin", "verify-pins", "--dir", ".", "--set", "site=pins-lock" }).code);
    const gone = f.h.run(&.{ "autopin", "verify-pins", "--dir", "no-such-dir", "--set", "site=pins-lock" });
    try t.expectEqual(@as(u8, 1), gone.code);
    try t.expect(kit.contains(gone.err, "cannot open no-such-dir"));
}

test "verify-pins: only the registry host is fetched from, and the caps are compute's per tarball" {
    const f = try setup("pins-lock");
    defer teardown(f);
    const a = f.h.a();
    try t.expectError(error.HostNotAllowed, compute.capped(a, "https://evil.example/x.tgz"));
    compute.resetCounters();
    // A tarball over the per-tarball cap (the fetcher says so) is refused though the row cap is wide.
    const big = struct {
        fn oversize(_: std.mem.Allocator, _: []const u8) anyerror!fetch.Digest.Result {
            return .{ .sha256 = "a" ** 64, .sri512 = "x", .size = (64 << 20) + 1 };
        }
    }.oversize;
    const keep = compute.fetcher;
    compute.fetcher = &big;
    defer compute.fetcher = keep;
    try t.expectError(error.TarballTooLarge, compute.capped(a, reg ++ "x/-/x-1.0.0.tgz"));
    compute.resetCounters();
}
