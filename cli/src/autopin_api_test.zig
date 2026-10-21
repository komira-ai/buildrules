//! The artifact download: the API answers 302, the program follows it by hand, once, without `Authorization`, to a
//! host on the literal allow-list. The API is a fake that answers from a list and records every request.

const std = @import("std");
const api_mod = @import("autopin_api.zig");
const t = std.testing;

const Logged = struct { path: []const u8, url: ?[]const u8, auth: bool, accept: []const u8, max_body: usize };

const Fake = struct {
    answers: []const api_mod.Response,
    next: usize = 0,
    log: std.ArrayList(Logged) = .empty,
    a: std.mem.Allocator,

    fn api(self: *Fake) api_mod.Api {
        return .{ .ctx = self, .sendFn = send };
    }

    fn send(ctx: *anyopaque, a: std.mem.Allocator, req: api_mod.Request) anyerror!api_mod.Response {
        _ = a;
        const self: *Fake = @ptrCast(@alignCast(ctx));
        try self.log.append(self.a, .{ .path = req.path, .url = req.url, .auth = req.auth, .accept = req.accept, .max_body = req.max_body });
        if (self.next >= self.answers.len) return error.NoMoreAnswers;
        defer self.next += 1;
        return self.answers[self.next];
    }
};

const blob = "https://pipelinesghubeus1.blob.core.windows.net/artifacts/abc?sv=v1&sig=a%2Bb%3D";

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

test "download: follows the 302 by hand, once, and the second request carries no Authorization" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var f = Fake{ .a = a, .answers = &.{ .{ .status = 302, .location = blob }, .{ .status = 200, .body = "ZIPBYTES" } } };
    const got = try api_mod.download(a, f.api(), "repos/o/r/actions/artifacts/9/zip", 1024);
    try t.expectEqualStrings("ZIPBYTES", got);
    try t.expectEqual(@as(usize, 2), f.log.items.len);
    try t.expect(f.log.items[0].auth);
    try t.expectEqualStrings("repos/o/r/actions/artifacts/9/zip", f.log.items[0].path);
    try t.expect(f.log.items[0].url == null);
    try t.expect(!f.log.items[1].auth);
    try t.expectEqualStrings(blob, f.log.items[1].url.?);
    try t.expectEqual(@as(usize, 1024), f.log.items[1].max_body);
}

test "download: a Location off the allow-list is refused and never requested" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const evil = [_][]const u8{
        "https://evil.example/x",
        "https://evilblob.core.windows.net/x",
        "https://blob.core.windows.net/x",
        "https://.blob.core.windows.net/x",
        "https://a..blob.core.windows.net/x",
        "https://x.blob.core.windows.net.evil.example/x",
        "https://x.actions.githubusercontent.com@evil.example/x",
        "https://x.blob.core.windows.net:8443/x",
        "https://X.blob.core.windows.net/x",
        "http://x.blob.core.windows.net/x",
        "https://x.blob.core.windows.net/x#frag",
        "https://x.blob.core.windows.net\\@evil.example/x",
        "https://githubusercontent.com/x",
        "https://api.github.com/x",
        "//x.blob.core.windows.net/x",
        "/relative",
        "",
    };
    for (evil) |loc| {
        const answers = [_]api_mod.Response{ .{ .status = 302, .location = loc }, .{ .status = 200, .body = "x" } };
        var f = Fake{ .a = a, .answers = &answers };
        try t.expectError(error.RedirectNotAllowed, api_mod.download(a, f.api(), "p", 1024));
        try t.expectEqual(@as(usize, 1), f.log.items.len);
    }
}

test "download: both literal suffixes are accepted, on a label boundary" {
    try t.expect(api_mod.hostAllowed("a.blob.core.windows.net"));
    try t.expect(api_mod.hostAllowed("x-1.y.blob.core.windows.net"));
    try t.expect(api_mod.hostAllowed("pipelines.actions.githubusercontent.com"));
    try t.expect(!api_mod.hostAllowed("actions.githubusercontent.com"));
    try t.expect(!api_mod.hostAllowed("blob.core.windows.net"));
    try t.expect(!api_mod.hostAllowed("xblob.core.windows.net"));
    try t.expect(!api_mod.hostAllowed(""));
    try t.expect(!api_mod.hostAllowed("a_b.blob.core.windows.net"));
    try t.expect(!api_mod.hostAllowed("a.blob.core.windows.net."));
    try t.expect(api_mod.redirectAllowed("https://a.actions.githubusercontent.com/path?x=1&y=%2F"));
    try t.expect(!api_mod.redirectAllowed("https://a.actions.githubusercontent.com:443/path"));
}

test "download: the API's first answer must be a 302 with a Location" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var ok200 = Fake{ .a = a, .answers = &.{.{ .status = 200, .body = "inline bytes" }} };
    try t.expectError(error.NotARedirect, api_mod.download(a, ok200.api(), "p", 1024));
    var no_loc = Fake{ .a = a, .answers = &.{.{ .status = 302 }} };
    try t.expectError(error.NotARedirect, api_mod.download(a, no_loc.api(), "p", 1024));
    var forbidden = Fake{ .a = a, .answers = &.{.{ .status = 403, .body = "{}" }} };
    try t.expectError(error.NotARedirect, api_mod.download(a, forbidden.api(), "p", 1024));
}

test "download: a second redirect is refused, not followed; a non-200 is a failure" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var chain = Fake{ .a = a, .answers = &.{ .{ .status = 302, .location = blob }, .{ .status = 302, .location = "https://evil.example/" }, .{ .status = 200, .body = "x" } } };
    try t.expectError(error.RedirectChain, api_mod.download(a, chain.api(), "p", 1024));
    try t.expectEqual(@as(usize, 2), chain.log.items.len);
    var gone = Fake{ .a = a, .answers = &.{ .{ .status = 302, .location = blob }, .{ .status = 404 } } };
    try t.expectError(error.DownloadFailed, api_mod.download(a, gone.api(), "p", 1024));
}
