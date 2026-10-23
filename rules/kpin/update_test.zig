//! `kpin update` against a registry on loopback, through the real HTTP
//! client. The registry is registry.zig: a thread on 127.0.0.1 answering from
//! a table, so nothing here leaves the machine.

const std = @import("std");
const fetch = @import("fetch.zig");
const fx = @import("fixtures.zig");
const lockfmt = @import("lockfmt.zig");
const npm = @import("npm.zig");
const registry = @import("registry.zig");
const update = @import("update.zig");
const Report = @import("diag.zig").Report;
const Diag = @import("diag.zig").Diag;
const t = std.testing;

const Env = struct {
    ar: std.heap.ArenaAllocator,
    reg: *registry.Registry,
    http: fetch.HttpFetcher,

    fn init(routes: []registry.Route) !*Env {
        const self = try t.allocator.create(Env);
        self.ar = std.heap.ArenaAllocator.init(t.allocator);
        self.reg = try registry.Registry.start(self.ar.allocator(), routes);
        self.http = .{ .allocator = self.ar.allocator(), .allow_http_loopback = true };
        return self;
    }

    fn deinit(self: *Env) void {
        self.reg.stop();
        self.ar.deinit();
        t.allocator.destroy(self);
    }

    fn a(self: *Env) std.mem.Allocator {
        return self.ar.allocator();
    }

    fn url(self: *Env, path: []const u8) []const u8 {
        return self.reg.url(self.a(), path) catch @panic("oom");
    }
};

fn pkg(e: *Env, name: []const u8, path: []const u8, sri: []const u8) npm.Pkg {
    return .{
        .key = std.fmt.allocPrint(e.a(), "{s}@1.0.0", .{name}) catch @panic("oom"),
        .name = name,
        .version = "1.0.0",
        .url = e.url(path),
        .sri512 = sri,
    };
}

fn toolToml(e: *Env, version: []const u8, extra: []const u8) []const u8 {
    return std.fmt.allocPrint(e.a(),
        \\[tool]
        \\version = "{s}"
        \\url = "http://127.0.0.1:{d}/tool-{{version}}-{{platform}}.bin"
        \\{s}
        \\[tool.platform.linux-x86_64]
        \\[tool.platform.macos-aarch64]
        \\token = "darwin"
        \\
    , .{ version, e.reg.port, extra }) catch @panic("oom");
}

test "npm: the tarball is fetched once, sha256 and size computed, sha512 checked against package-lock.json" {
    var routes = [_]registry.Route{
        .{ .path = "/a.tgz", .body = fx.ABC },
        .{ .path = "/b.tgz", .body = fx.ABC },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    var rep = Report.init(e.a());
    const pkgs = [_]npm.Pkg{ pkg(e, "a", "/a.tgz", fx.ABC_SRI512), pkg(e, "b", "/b.tgz", fx.ABC_SRI512) };
    const o = try update.run(e.a(), e.http.fetcher(), "", &pkgs, .{}, .{}, &rep);
    try t.expect(rep.clean());
    try t.expectEqual(@as(usize, 2), o.fetched);
    var d = Diag.init(e.a());
    const lock = try lockfmt.parse(e.a(), o.lock_text.?, &d);
    try t.expectEqual(@as(usize, 2), lock.npm.len);
    // Independent of kpin's own hashing: the known sha256 and sha512 of "abc".
    try t.expectEqualStrings(fx.ABC_SHA256, lock.npm[0].sha256);
    try t.expectEqualStrings(fx.ABC_SRI512, lock.npm[0].sri512);
    try t.expectEqual(@as(u64, 3), lock.npm[0].size);
    try t.expect(!std.mem.eql(u8, lock.npm[0].sha256, lock.npm[0].sri512));
}

test "npm: a tarball that is not what package-lock.json says is an error and writes nothing" {
    var routes = [_]registry.Route{.{ .path = "/a.tgz", .body = fx.ABD }};
    const e = try Env.init(&routes);
    defer e.deinit();
    var rep = Report.init(e.a());
    const pkgs = [_]npm.Pkg{pkg(e, "a", "/a.tgz", fx.ABC_SRI512)};
    const o = try update.run(e.a(), e.http.fetcher(), "", &pkgs, .{}, .{}, &rep);
    try t.expectEqual(@as(usize, 1), rep.errors.count());
    try t.expect(std.mem.indexOf(u8, rep.errors.msgs.items[0], "package-lock.json says") != null);
    try t.expect(o.lock_text == null);
}

test "what the lock holds is not fetched again; --verify fetches it and finds it unchanged" {
    var routes = [_]registry.Route{.{ .path = "/a.tgz", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    const pkgs = [_]npm.Pkg{pkg(e, "a", "/a.tgz", fx.ABC_SRI512)};
    var rep = Report.init(e.a());
    const first = try update.run(e.a(), e.http.fetcher(), "", &pkgs, .{}, .{}, &rep);
    try t.expect(rep.clean());
    var d = Diag.init(e.a());
    const lock = try lockfmt.parse(e.a(), first.lock_text.?, &d);
    try t.expectEqual(@as(usize, 1), e.reg.hitsOf("/a.tgz"));

    var rep2 = Report.init(e.a());
    const second = try update.run(e.a(), e.http.fetcher(), "", &pkgs, lock, .{}, &rep2);
    try t.expect(rep2.clean());
    try t.expectEqual(@as(usize, 0), second.fetched);
    try t.expectEqual(@as(usize, 1), e.reg.hitsOf("/a.tgz"));
    try t.expectEqualStrings(first.lock_text.?, second.lock_text.?);

    var rep3 = Report.init(e.a());
    const third = try update.run(e.a(), e.http.fetcher(), "", &pkgs, lock, .{ .verify = true }, &rep3);
    try t.expect(rep3.clean());
    try t.expectEqual(@as(usize, 1), third.fetched);
    try t.expectEqual(@as(usize, 2), e.reg.hitsOf("/a.tgz"));
    try t.expectEqualStrings(first.lock_text.?, third.lock_text.?);
}

test "ALARM: --verify finds a file that now serves other bytes under the same version" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }, .{ .path = "/tool-1.0.0-darwin.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    const text = toolToml(e, "1.0.0", "");
    var rep = Report.init(e.a());
    const first = try update.run(e.a(), e.http.fetcher(), text, &.{}, .{}, .{}, &rep);
    try t.expect(rep.clean());
    var d = Diag.init(e.a());
    const lock = try lockfmt.parse(e.a(), first.lock_text.?, &d);

    routes[0].body = fx.ABD; // republished
    var rep2 = Report.init(e.a());
    const second = try update.run(e.a(), e.http.fetcher(), text, &.{}, lock, .{ .verify = true }, &rep2);
    try t.expectEqual(@as(usize, 1), rep2.alarms.count());
    try t.expect(second.lock_text == null);
    try t.expect(second.pins_text == null);
    // The same version is not "refreshed" by a plain update either: the old bytes stay pinned.
    var rep3 = Report.init(e.a());
    const third = try update.run(e.a(), e.http.fetcher(), text, &.{}, lock, .{}, &rep3);
    try t.expect(rep3.clean());
    try t.expectEqualStrings(first.lock_text.?, third.lock_text.?);
}

test "a newer version named by latest_url moves pins.toml and is pinned by the bytes served for it" {
    var routes = [_]registry.Route{
        .{ .path = "/latest", .body = "{\"tag_name\":\"v1.2.0\"}" },
        .{ .path = "/tool-1.2.0-linux-x86_64.bin", .body = fx.ABD },
        .{ .path = "/tool-1.2.0-darwin.bin", .body = fx.ABD },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    const extra = std.fmt.allocPrint(e.a(), "latest_url = \"{s}\"\nlatest_field = \"tag_name\"\nversion_prefix = \"v\"", .{e.url("/latest")}) catch @panic("oom");
    const text = toolToml(e, "1.0.0", extra);
    var rep = Report.init(e.a());
    const o = try update.run(e.a(), e.http.fetcher(), text, &.{}, .{}, .{}, &rep);
    try t.expect(rep.clean());
    try t.expect(std.mem.indexOf(u8, o.pins_text.?, "version = \"1.2.0\"") != null);
    try t.expect(std.mem.indexOf(u8, o.pins_text.?, "latest_field = \"tag_name\"") != null);
    var d = Diag.init(e.a());
    const lock = try lockfmt.parse(e.a(), o.lock_text.?, &d);
    try t.expectEqualStrings("1.2.0", lock.pins[0].version);
    try t.expectEqualStrings(try fx.sha256Hex(e.a(), fx.ABD), lockfmt.findFile(lock.pins[0], "macos-aarch64").?.sha256);
    try t.expectEqual(@as(usize, 1), e.reg.hitsOf("/tool-1.2.0-darwin.bin"));
    try t.expectEqual(@as(usize, 1), o.notes.count());
}

test "an older or equal newest version moves nothing and fetches nothing" {
    var routes = [_]registry.Route{
        .{ .path = "/latest", .body = "{\"tag_name\":\"v0.9.0\"}" },
        .{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC },
        .{ .path = "/tool-1.0.0-darwin.bin", .body = fx.ABC },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    const extra = std.fmt.allocPrint(e.a(), "latest_url = \"{s}\"\nlatest_field = \"tag_name\"\nversion_prefix = \"v\"", .{e.url("/latest")}) catch @panic("oom");
    var rep = Report.init(e.a());
    const o = try update.run(e.a(), e.http.fetcher(), toolToml(e, "1.0.0", extra), &.{}, .{}, .{}, &rep);
    try t.expect(rep.clean());
    try t.expect(o.pins_text == null);
    try t.expectEqual(@as(usize, 0), e.reg.hitsOf("/tool-0.9.0-darwin.bin"));
}

test "--only touches one pin" {
    var routes = [_]registry.Route{.{ .path = "/a.tgz", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    var rep = Report.init(e.a());
    const pkgs = [_]npm.Pkg{pkg(e, "a", "/a.tgz", fx.ABC_SRI512)};
    _ = try update.run(e.a(), e.http.fetcher(), toolToml(e, "1.0.0", ""), &pkgs, .{}, .{ .only = "nope" }, &rep);
    try t.expectEqual(@as(usize, 1), rep.errors.count());
    try t.expectEqual(@as(usize, 0), e.reg.hitsOf("/a.tgz"));
}

test "failures of the network are errors that write nothing: 404, truncated, oversize" {
    var routes = [_]registry.Route{
        .{ .path = "/short.tgz", .body = fx.ABC, .claim_length = 100 },
        .{ .path = "/big.tgz", .body = "0123456789" },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    for ([_][]const u8{ "/missing.tgz", "/short.tgz" }) |p| {
        var rep = Report.init(e.a());
        const pkgs = [_]npm.Pkg{pkg(e, "a", p, fx.ABC_SRI512)};
        const o = try update.run(e.a(), e.http.fetcher(), "", &pkgs, .{}, .{}, &rep);
        try t.expectEqual(@as(usize, 1), rep.errors.count());
        try t.expect(o.lock_text == null);
    }
    var rep = Report.init(e.a());
    const pkgs = [_]npm.Pkg{pkg(e, "a", "/big.tgz", fx.ABC_SRI512)};
    const o = try update.run(e.a(), e.http.fetcher(), "", &pkgs, .{}, .{ .max_blob = 5 }, &rep);
    try t.expect(std.mem.indexOf(u8, rep.errors.msgs.items[0], "ResponseTooLarge") != null);
    try t.expect(o.lock_text == null);
}

test "a redirect is followed, and one to plain http elsewhere is refused before any connection" {
    var routes = [_]registry.Route{
        .{ .path = "/a.tgz", .body = fx.ABC },
        .{ .path = "/hop", .status = 302, .location = "/a.tgz" },
        .{ .path = "/bad", .status = 302, .location = "http://example.invalid/a.tgz" },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    // A relative Location is not followed: the policy sees absolute URLs only.
    var c = fetch.Collect{ .a = e.a(), .max = 100 };
    try t.expectError(error.UrlNotAllowed, e.http.fetcher().get(e.url("/hop"), c.sink()));
    routes[1].location = e.url("/a.tgz");
    var c2 = fetch.Collect{ .a = e.a(), .max = 100 };
    try e.http.fetcher().get(e.url("/hop"), c2.sink());
    try t.expectEqualStrings("abc", c2.buf.items);
    var c3 = fetch.Collect{ .a = e.a(), .max = 100 };
    try t.expectError(error.UrlNotAllowed, e.http.fetcher().get(e.url("/bad"), c3.sink()));
}

test "without --allow-http-loopback the loopback registry is refused" {
    var routes = [_]registry.Route{.{ .path = "/a.tgz", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.http.allow_http_loopback = false;
    var c = fetch.Collect{ .a = e.a(), .max = 100 };
    try t.expectError(error.UrlNotAllowed, e.http.fetcher().get(e.url("/a.tgz"), c.sink()));
    try t.expectEqual(@as(usize, 0), e.reg.hitsOf("/a.tgz"));
}

test "urlAllowed" {
    try t.expect(fetch.urlAllowed("https://registry.npmjs.org/a/-/a-1.tgz", false));
    try t.expect(!fetch.urlAllowed("http://registry.npmjs.org/a.tgz", false));
    try t.expect(!fetch.urlAllowed("http://127.0.0.1:80/a", false));
    try t.expect(fetch.urlAllowed("http://127.0.0.1:8080/a", true));
    try t.expect(fetch.urlAllowed("http://localhost/a", true));
    try t.expect(!fetch.urlAllowed("http://example.org/a", true));
    // A host that merely starts with the loopback address, or hides behind user@.
    try t.expect(!fetch.urlAllowed("http://127.0.0.1.evil.example/a", true));
    try t.expect(!fetch.urlAllowed("http://127.0.0.1@evil.example/a", true));
    try t.expect(!fetch.urlAllowed("https://user@host.example/a", false));
    try t.expect(!fetch.urlAllowed("https:///a", false));
    try t.expect(!fetch.urlAllowed("ftp://h.example/a", false));
    try t.expect(!fetch.urlAllowed("file:///etc/passwd", true));
}

test "Digest: sha256 and sha512 of the same bytes however they arrive; the cap" {
    var d = fetch.Digest{ .max = 10 };
    for (fx.ABC) |c| try d.sink().write(&.{c});
    const r = try d.finish(t.allocator);
    defer t.allocator.free(r.sha256);
    defer t.allocator.free(r.sri512);
    try t.expectEqualStrings(fx.ABC_SHA256, r.sha256);
    try t.expectEqualStrings(fx.ABC_SRI512, r.sri512);
    try t.expectEqual(@as(u64, 3), r.size);
    var d2 = fetch.Digest{ .max = 2 };
    try t.expectError(error.ResponseTooLarge, d2.sink().write(fx.ABC));
}

test "versions: isNewer compares numbers, not strings, and leaves anything else alone" {
    try t.expect(update.isNewer("1.9.0", "1.10.0"));
    try t.expect(!update.isNewer("1.10.0", "1.9.0"));
    try t.expect(update.isNewer("1.0", "1.0.1"));
    try t.expect(!update.isNewer("1.0.0", "1.0"));
    try t.expect(!update.isNewer("1.0.0", "1.0.0"));
    try t.expect(!update.isNewer("1.0.0", "2.0.0-rc1"));
    try t.expect(!update.isNewer("nightly", "1.0.0"));
}

test "jsonString: a dotted path to a string, nothing else" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("1.2", update.jsonString(a, "{\"info\":{\"version\":\"1.2\",\"n\":3}}", "info.version").?);
    try t.expect(update.jsonString(a, "{\"info\":{\"n\":3}}", "info.n") == null);
    try t.expect(update.jsonString(a, "{\"info\":1}", "info.version") == null);
    try t.expect(update.jsonString(a, "not json", "a") == null);
}

fn fetchFails(e: *Env, path: []const u8, want: anyerror) !void {
    var c = fetch.Collect{ .a = e.a(), .max = 100 };
    try t.expectError(want, e.http.fetcher().get(e.url(path), c.sink()));
}

test "redirect limits: a loop stops, a 302 without Location is an error, a redirect to a user@ URL is refused" {
    var routes = [_]registry.Route{
        .{ .path = "/loop", .status = 302, .location = null },
        .{ .path = "/nolocation", .status = 302 },
        .{ .path = "/userinfo", .status = 302, .location = "http://127.0.0.1:1@localhost/x" },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    routes[0].location = e.url("/loop");
    try fetchFails(e, "/loop", error.TooManyRedirects);
    // 1 + max_redirects requests, no more.
    try t.expectEqual(@as(usize, 6), e.reg.hitsOf("/loop"));
    try fetchFails(e, "/nolocation", error.RedirectWithoutLocation);
    try fetchFails(e, "/userinfo", error.UrlNotAllowed);
}

test "only 200 is a download: 204, 206 and 500 are refused" {
    var routes = [_]registry.Route{
        .{ .path = "/204", .status = 204 },
        .{ .path = "/206", .status = 206, .body = fx.ABC },
        .{ .path = "/500", .status = 500, .body = fx.ABC },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    try fetchFails(e, "/204", error.HttpStatusNotOk);
    try fetchFails(e, "/206", error.HttpStatusNotOk);
    try fetchFails(e, "/500", error.HttpStatusNotOk);
}

test "the metadata cap: a latest_url document larger than max_meta is refused and nothing moves" {
    var routes = [_]registry.Route{.{ .path = "/latest", .body = "{\"tag_name\":\"v9.0.0\"}" }};
    const e = try Env.init(&routes);
    defer e.deinit();
    const extra = std.fmt.allocPrint(e.a(), "latest_url = \"{s}\"\nlatest_field = \"tag_name\"\nversion_prefix = \"v\"", .{e.url("/latest")}) catch @panic("oom");
    var rep = Report.init(e.a());
    const o = try update.run(e.a(), e.http.fetcher(), toolToml(e, "1.0.0", extra), &.{}, .{}, .{ .max_meta = 5 }, &rep);
    try t.expect(std.mem.indexOf(u8, rep.errors.msgs.items[0], "ResponseTooLarge") != null);
    try t.expect(o.pins_text == null and o.lock_text == null);
}

test "a newest version from the registry that fails the version charset is refused" {
    const bad = [_][]const u8{ "{\"tag_name\":\"v1.2.0$x\"}", "{\"tag_name\":\"v1.2.0 x\"}", "{\"tag_name\":\"v-1\"}", "{\"tag_name\":\"v\"}" };
    for (bad) |body| {
        var routes = [_]registry.Route{
            .{ .path = "/latest", .body = body },
            .{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC },
            .{ .path = "/tool-1.0.0-darwin.bin", .body = fx.ABC },
        };
        const e = try Env.init(&routes);
        defer e.deinit();
        const extra = std.fmt.allocPrint(e.a(), "latest_url = \"{s}\"\nlatest_field = \"tag_name\"\nversion_prefix = \"v\"", .{e.url("/latest")}) catch @panic("oom");
        var rep = Report.init(e.a());
        const o = try update.run(e.a(), e.http.fetcher(), toolToml(e, "1.0.0", extra), &.{}, .{}, .{}, &rep);
        // The files are served, so the only error possible is the version.
        try t.expectEqual(@as(usize, 1), rep.errors.count());
        try t.expect(std.mem.indexOf(u8, rep.errors.msgs.items[0], "unsupported characters") != null);
        try t.expect(o.pins_text == null);
    }
}

test "ALARM: npm --verify finds other bytes for a locked name@version (not a package-lock error)" {
    var routes = [_]registry.Route{.{ .path = "/a.tgz", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    const pkgs = [_]npm.Pkg{pkg(e, "a", "/a.tgz", fx.ABC_SRI512)};
    var rep = Report.init(e.a());
    const first = try update.run(e.a(), e.http.fetcher(), "", &pkgs, .{}, .{}, &rep);
    var d = Diag.init(e.a());
    const lock = try lockfmt.parse(e.a(), first.lock_text.?, &d);
    routes[0].body = fx.ABD;
    var rep2 = Report.init(e.a());
    const o = try update.run(e.a(), e.http.fetcher(), "", &pkgs, lock, .{ .verify = true }, &rep2);
    try t.expectEqual(@as(usize, 1), rep2.alarms.count());
    try t.expectEqual(@as(usize, 0), rep2.errors.count());
    try t.expect(o.lock_text == null);
}

fn claimedToml(e: *Env, sha: []const u8, size: u64) []const u8 {
    return std.fmt.allocPrint(e.a(),
        \\[tool]
        \\version = "1.0.0"
        \\url = "http://127.0.0.1:{d}/tool-{{version}}-{{platform}}.bin"
        \\[tool.platform.linux-x86_64]
        \\sha256 = "{s}"
        \\size = {d}
        \\
    , .{ e.reg.port, sha, size }) catch @panic("oom");
}

test "a hash written in pins.toml is checked against the bytes served: right is pinned, wrong sha256 or wrong size is an error that writes nothing" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    var rep = Report.init(e.a());
    const ok = try update.run(e.a(), e.http.fetcher(), claimedToml(e, fx.ABC_SHA256, 3), &.{}, .{}, .{}, &rep);
    try t.expect(rep.clean());
    try t.expect(ok.lock_text != null);
    try t.expectEqual(@as(usize, 1), ok.fetched);
    const wrong = [_]struct { sha: []const u8, size: u64, say: []const u8 }{
        .{ .sha = "0000000000000000000000000000000000000000000000000000000000000000", .size = 3, .say = "pins.toml says sha256 0000" },
        .{ .sha = fx.ABC_SHA256, .size = 4, .say = "size 4, the bytes are sha256 " ++ fx.ABC_SHA256 ++ " size 3" },
    };
    for (wrong) |w| {
        var rep2 = Report.init(e.a());
        const o = try update.run(e.a(), e.http.fetcher(), claimedToml(e, w.sha, w.size), &.{}, .{}, .{}, &rep2);
        try t.expectEqual(@as(usize, 1), rep2.errors.count());
        try t.expectEqual(@as(usize, 0), rep2.alarms.count());
        try t.expect(std.mem.indexOf(u8, rep2.errors.msgs.items[0], w.say) != null);
        try t.expect(o.lock_text == null and o.pins_text == null);
    }
}

test "a latest_url that answers 404, or whose field is not a string, is one error and moves nothing" {
    var routes = [_]registry.Route{
        .{ .path = "/number", .body = "{\"tag_name\":5}" },
        .{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC },
        .{ .path = "/tool-1.0.0-darwin.bin", .body = fx.ABC },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    const cases = [_]struct { path: []const u8, say: []const u8 }{
        .{ .path = "/number", .say = "has no string at `tag_name`" },
        .{ .path = "/missing", .say = "HttpStatusNotOk" },
    };
    for (cases) |c| {
        const extra = std.fmt.allocPrint(e.a(), "latest_url = \"{s}\"\nlatest_field = \"tag_name\"", .{e.url(c.path)}) catch @panic("oom");
        var rep = Report.init(e.a());
        const o = try update.run(e.a(), e.http.fetcher(), toolToml(e, "1.0.0", extra), &.{}, .{}, .{}, &rep);
        try t.expectEqual(@as(usize, 1), rep.errors.count());
        try t.expect(std.mem.indexOf(u8, rep.errors.msgs.items[0], c.say) != null);
        try t.expect(o.pins_text == null and o.lock_text == null);
    }
}

test "a file that cannot be fetched is an error naming the pin, the platform and the URL; the others are still fetched" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    var rep = Report.init(e.a());
    const o = try update.run(e.a(), e.http.fetcher(), toolToml(e, "1.0.0", ""), &.{}, .{}, .{}, &rep);
    try t.expectEqual(@as(usize, 1), rep.errors.count());
    const m = rep.errors.msgs.items[0];
    try t.expect(std.mem.indexOf(u8, m, "tool 1.0.0 (macos-aarch64): fetching ") != null);
    try t.expect(std.mem.indexOf(u8, m, "/tool-1.0.0-darwin.bin: HttpStatusNotOk") != null);
    try t.expectEqual(@as(usize, 1), o.fetched);
    try t.expect(o.lock_text == null);
}

test "a platform added to a locked version is fetched alone; the locked one keeps its bytes" {
    var routes = [_]registry.Route{
        .{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC },
        .{ .path = "/tool-1.0.0-darwin.bin", .body = fx.ABD },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    var rep = Report.init(e.a());
    const first = try update.run(e.a(), e.http.fetcher(), claimedToml(e, fx.ABC_SHA256, 3), &.{}, .{}, .{}, &rep);
    var d = Diag.init(e.a());
    const lock = try lockfmt.parse(e.a(), first.lock_text.?, &d);
    var rep2 = Report.init(e.a());
    const second = try update.run(e.a(), e.http.fetcher(), toolToml(e, "1.0.0", ""), &.{}, lock, .{}, &rep2);
    try t.expect(rep2.clean());
    try t.expectEqual(@as(usize, 1), second.fetched);
    try t.expectEqual(@as(usize, 1), e.reg.hitsOf("/tool-1.0.0-linux-x86_64.bin"));
    var d2 = Diag.init(e.a());
    const both = try lockfmt.parse(e.a(), second.lock_text.?, &d2);
    try t.expectEqual(@as(usize, 2), both.pins[0].files.len);
    try t.expectEqualStrings(try fx.sha256Hex(e.a(), fx.ABD), lockfmt.findFile(both.pins[0], "macos-aarch64").?.sha256);
}

test "a pins.toml that does not load stops update before any request, with the line in the report" {
    var routes = [_]registry.Route{.{ .path = "/a.tgz", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    var rep = Report.init(e.a());
    const pkgs = [_]npm.Pkg{pkg(e, "a", "/a.tgz", fx.ABC_SRI512)};
    const o = try update.run(e.a(), e.http.fetcher(), "[tool\n", &pkgs, .{}, .{}, &rep);
    try t.expectEqual(@as(usize, 1), rep.errors.count());
    try t.expect(std.mem.indexOf(u8, rep.errors.msgs.items[0], "line 1: malformed table header") != null);
    try t.expect(o.lock_text == null);
    try t.expectEqual(@as(usize, 0), e.reg.hitsOf("/a.tgz"));
}

test "--only names a pin that exists: the others are not fetched" {
    var routes = [_]registry.Route{
        .{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC },
        .{ .path = "/tool-1.0.0-darwin.bin", .body = fx.ABC },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    var rep = Report.init(e.a());
    // `tool` is selected, and there is nothing else to leave alone: both platforms are fetched.
    const o = try update.run(e.a(), e.http.fetcher(), toolToml(e, "1.0.0", ""), &.{}, .{}, .{ .only = "tool" }, &rep);
    try t.expect(rep.clean());
    try t.expectEqual(@as(usize, 2), o.fetched);
}

test "npm packages are not fetched when --only names a pin" {
    var routes = [_]registry.Route{
        .{ .path = "/a.tgz", .body = fx.ABC },
        .{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC },
        .{ .path = "/tool-1.0.0-darwin.bin", .body = fx.ABC },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    var rep = Report.init(e.a());
    const pkgs = [_]npm.Pkg{pkg(e, "a", "/a.tgz", fx.ABC_SRI512)};
    _ = try update.run(e.a(), e.http.fetcher(), toolToml(e, "1.0.0", ""), &pkgs, .{}, .{ .only = "tool" }, &rep);
    // The package has no lock entry and was not fetched, so the lock cannot be made: `compute` says to run update.
    try t.expectEqual(@as(usize, 0), e.reg.hitsOf("/a.tgz"));
    try t.expectEqual(@as(usize, 1), rep.errors.count());
    try t.expect(std.mem.indexOf(u8, rep.errors.msgs.items[0], "a@1.0.0 has no sha256 yet") != null);
}

fn closedPort() !u16 {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var s = try addr.listen(.{ .reuse_address = true });
    defer s.deinit();
    return s.listen_address.getPort();
}

/// The name of the error a download of `path` ends in; no byte may have reached the sink.
fn getError(e: *Env, path: []const u8) ![]const u8 {
    var c = fetch.Collect{ .a = e.a(), .max = 100 };
    if (e.http.fetcher().get(e.url(path), c.sink())) |_| {
        return error.TestExpectedAnError;
    } else |err| {
        try t.expectEqual(@as(usize, 0), c.buf.items.len);
        return @errorName(err);
    }
}

test "a server that is not there, says nothing, or does not speak HTTP is an error and delivers no bytes" {
    var routes = [_]registry.Route{
        .{ .path = "/silent", .raw = "" },
        .{ .path = "/garbage", .raw = "this is not http\r\n\r\nabc" },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    var c = fetch.Collect{ .a = e.a(), .max = 100 };
    const url = try std.fmt.allocPrint(e.a(), "http://127.0.0.1:{d}/x", .{try closedPort()});
    try t.expectError(error.ConnectionRefused, e.http.fetcher().get(url, c.sink()));
    _ = try getError(e, "/silent");
    _ = try getError(e, "/garbage");
    try t.expectEqual(@as(usize, 1), e.reg.hitsOf("/silent"));
    try t.expectEqual(@as(usize, 1), e.reg.hitsOf("/garbage"));
}

test "a chunked body has no length to check: it is read to its end, and a chunk that is not one is an error" {
    var routes = [_]registry.Route{
        .{ .path = "/chunked", .raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n2\r\nab\r\n1\r\nc\r\n0\r\n\r\n" },
        .{ .path = "/badchunk", .raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\nzz\r\nabc\r\n0\r\n\r\n" },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    var c = fetch.Collect{ .a = e.a(), .max = 100 };
    try e.http.fetcher().get(e.url("/chunked"), c.sink());
    try t.expectEqualStrings("abc", c.buf.items);
    var d = fetch.Digest{ .max = 100 };
    try e.http.fetcher().get(e.url("/chunked"), d.sink());
    const r = try d.finish(e.a());
    try t.expectEqualStrings(fx.ABC_SHA256, r.sha256);
    const err = try getError(e, "/badchunk");
    try t.expect(std.mem.startsWith(u8, err, "HttpChunk"));
}

test "a CA file that cannot be read is an error before any connection, not a fall back to the system's roots" {
    var routes = [_]registry.Route{.{ .path = "/a.tgz", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.http.ca_file = "/kpin-test-no-such-directory/ca.pem";
    try t.expectEqualStrings("FileNotFound", try getError(e, "/a.tgz"));
    try t.expectEqual(@as(usize, 0), e.reg.hitsOf("/a.tgz"));
}

test "a body larger than the read buffer is hashed whole, at the buffer's size and either side of it" {
    const small = "x" ** 65535;
    const exact = "x" ** 65536;
    const more = "x" ** 70001;
    const twice = "x" ** 131072;
    var routes = [_]registry.Route{
        .{ .path = "/small", .body = small },
        .{ .path = "/exact", .body = exact },
        .{ .path = "/more", .body = more },
        .{ .path = "/twice", .body = twice },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    inline for (.{ .{ "/small", small }, .{ "/exact", exact }, .{ "/more", more }, .{ "/twice", twice } }) |c| {
        var d = fetch.Digest{ .max = 1 << 20 };
        try e.http.fetcher().get(e.url(c[0]), d.sink());
        const r = try d.finish(e.a());
        try t.expectEqual(@as(u64, c[1].len), r.size);
        try t.expectEqualStrings(try fx.sha256Hex(e.a(), c[1]), r.sha256);
        try t.expectEqualStrings(try fx.sri512(e.a(), c[1]), r.sri512);
    }
}

test "urlAllowed: a URL without a path, and the only two hosts plain http may reach" {
    try t.expect(fetch.urlAllowed("https://registry.example", false));
    try t.expect(fetch.urlAllowed("https://registry.example?x=1", false));
    try t.expect(fetch.urlAllowed("https://registry.example#f", false));
    try t.expect(fetch.urlAllowed("http://127.0.0.1", true));
    try t.expect(fetch.urlAllowed("http://localhost:9", true));
    try t.expect(!fetch.urlAllowed("http://127.0.0.1", false));
    try t.expect(!fetch.urlAllowed("http://[::1]:80/a", true));
    try t.expect(!fetch.urlAllowed("http://0.0.0.0:80/a", true));
    try t.expect(!fetch.urlAllowed("http://", true));
    try t.expect(!fetch.urlAllowed("", true));
}

test "versions: at most eight dotted numbers, none empty, none too large to compare" {
    try t.expect(update.isNewer("1.2.3.4.5.6.7.8", "1.2.3.4.5.6.7.9"));
    // Nine parts, an empty part and a part that is not a u64 are not versions kpin compares.
    try t.expect(!update.isNewer("1.2.3.4.5.6.7.8", "1.2.3.4.5.6.7.8.9"));
    try t.expect(!update.isNewer("1.2.3.4.5.6.7.8.9", "2"));
    try t.expect(!update.isNewer("1.0", "1..1"));
    try t.expect(!update.isNewer("1.0", "1.1."));
    try t.expect(!update.isNewer("1.0", ""));
    try t.expect(!update.isNewer("1.0", "99999999999999999999999"));
    try t.expect(update.isNewer("0", "0.0.1"));
    try t.expect(!update.isNewer("0.0.1", "0"));
}

test "jsonString: a path that names a key that is not there is nothing, as is a string-valued key's child" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expect(update.jsonString(a, "{\"info\":{\"version\":\"1.2\"}}", "info.missing") == null);
    try t.expect(update.jsonString(a, "{\"info\":{\"version\":\"1.2\"}}", "nothing.version") == null);
    try t.expect(update.jsonString(a, "{\"info\":{\"version\":\"1.2\"}}", "info.version.deeper") == null);
    try t.expect(update.jsonString(a, "[\"1.2\"]", "0") == null);
    try t.expectEqualStrings("1.2", update.jsonString(a, "{\"version\":\"1.2\"}", "version").?);
}

test "a version_prefix that the newest version does not start with is not stripped, and the version is taken as it is" {
    var routes = [_]registry.Route{
        .{ .path = "/latest", .body = "{\"tag_name\":\"1.2.0\"}" },
        .{ .path = "/tool-1.2.0-linux-x86_64.bin", .body = fx.ABD },
        .{ .path = "/tool-1.2.0-darwin.bin", .body = fx.ABD },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    const extra = std.fmt.allocPrint(e.a(), "latest_url = \"{s}\"\nlatest_field = \"tag_name\"\nversion_prefix = \"v\"", .{e.url("/latest")}) catch @panic("oom");
    var rep = Report.init(e.a());
    const o = try update.run(e.a(), e.http.fetcher(), toolToml(e, "1.0.0", extra), &.{}, .{}, .{}, &rep);
    try t.expect(rep.clean());
    try t.expect(std.mem.indexOf(u8, o.pins_text.?, "version = \"1.2.0\"") != null);
}
