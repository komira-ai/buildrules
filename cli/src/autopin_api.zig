//! The GitHub API, behind one seam. `autopin` reads pull requests, commit lists, file lists and file contents and
//! writes a commit through `Api.send`; tests give a fake that answers from a table and records every request,
//! so a test can say which calls were made, with which method, body and `Authorization` decision.
//!
//! `Http` is the real one: https only, the token sent only when a request says `auth`, and redirects are NEVER
//! followed by the client. The one redirect the program wants, the artifact download (the API answers 302 to a
//! storage host), is followed by `download`: manually, one hop, the `Authorization` header dropped, the host
//! checked against a literal allow-list on a label boundary.

const std = @import("std");
const fetch = @import("fetch.zig");
const valid = @import("valid.zig");

pub const Method = enum { GET, POST, PATCH };

pub const json_accept = "application/vnd.github+json";
pub const raw_accept = "application/vnd.github.raw+json";

pub const Request = struct {
    method: Method = .GET,
    /// A path below `https://api.github.com/` (used when `url` is null).
    path: []const u8 = "",
    /// An absolute https URL: the target of a redirect.
    url: ?[]const u8 = null,
    accept: []const u8 = json_accept,
    body: ?[]const u8 = null,
    /// Send the `Authorization` header. False for the second hop of a download.
    auth: bool = true,
    /// More bytes than this in the response body is an error.
    max_body: usize = 16 << 20,
};

pub const Response = struct {
    status: u16,
    body: []const u8 = "",
    /// The `Location` header of a redirect.
    location: ?[]const u8 = null,
};

pub const Api = struct {
    ctx: *anyopaque,
    sendFn: *const fn (ctx: *anyopaque, a: std.mem.Allocator, req: Request) anyerror!Response,

    pub fn send(self: Api, a: std.mem.Allocator, req: Request) anyerror!Response {
        return self.sendFn(self.ctx, a, req);
    }
};

/// The hosts an artifact may be downloaded from after the API's 302, each with the leading dot that makes the
/// match fall on a label boundary (`evilblob.core.windows.net` and the bare apex do not end in either).
/// The first is a broad blob-storage suffix: acceptable only because GitHub supplies the URL and the bytes
/// fetched from it are untrusted and validated whatever host served them.
pub const download_host_suffixes = [_][]const u8{ ".blob.core.windows.net", ".actions.githubusercontent.com" };

/// A host name: lower-case letters, digits, `-` and `.`, no empty label, ending in one of the literal suffixes
/// with at least one label in front of it.
pub fn hostAllowed(host: []const u8) bool {
    if (host.len == 0 or host.len > 253) return false;
    for (host) |c| if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '.')) return false;
    if (host[0] == '.' or host[host.len - 1] == '.' or std.mem.indexOf(u8, host, "..") != null) return false;
    for (download_host_suffixes) |s| {
        if (host.len > s.len and std.mem.endsWith(u8, host, s)) return true;
    }
    return false;
}

/// True when `location` is an https URL of an allowed host: no user info, no port, no fragment, and only the
/// characters of `valid.isUrl`.
pub fn redirectAllowed(location: []const u8) bool {
    if (!std.mem.startsWith(u8, location, "https://") or !valid.isUrl(location)) return false;
    const rest = location["https://".len..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const authority = rest[0..end];
    if (std.mem.indexOfAny(u8, authority, "@:") != null) return false;
    if (std.mem.indexOfScalar(u8, location, '#') != null) return false;
    return hostAllowed(authority);
}

pub const DownloadError = error{ NotARedirect, RedirectNotAllowed, RedirectChain, DownloadFailed, OutOfMemory };

/// Downloads the artifact at the API path `path` (`repos/O/R/actions/artifacts/ID/zip`): the API's answer must be
/// a 302 whose `Location` passes `redirectAllowed`; that URL is fetched ONCE, without `Authorization`, and must
/// answer 200 (a second redirect is refused, not followed). Returns the body, at most `max_bytes`.
pub fn download(a: std.mem.Allocator, api: Api, path: []const u8, max_bytes: usize) anyerror![]const u8 {
    const first = try api.send(a, .{ .path = path, .max_body = 64 << 10 });
    if (first.status != 302) return error.NotARedirect;
    const loc = first.location orelse return error.NotARedirect;
    if (!redirectAllowed(loc)) return error.RedirectNotAllowed;
    const second = try api.send(a, .{ .url = loc, .auth = false, .accept = "*/*", .max_body = max_bytes });
    if (second.status >= 300 and second.status < 400) return error.RedirectChain;
    if (second.status != 200) return error.DownloadFailed;
    return second.body;
}

/// The real thing: `https://api.github.com`, the token from the caller (the program takes it from `GH_TOKEN`).
pub const Http = struct {
    allocator: std.mem.Allocator,
    token: []const u8,
    base_url: []const u8 = "https://api.github.com",
    /// Tests only: allow http to 127.0.0.1.
    allow_http_loopback: bool = false,
    /// How long one read or one write on the connection may wait, in seconds. The deadlines are set once the connection exists. The
    /// connect and the TLS handshake (done inside the connect) have no deadline of their own in the standard library client: a connect or a
    /// handshake that hangs is ended only by the workflow job's `timeout-minutes`. A server that sends a
    /// byte at a time can keep a body coming for longer than this; the cap on the body and the job's timeout bound that.
    timeout_seconds: u32 = 60,
    /// Puts the read and write deadlines on a connected socket: called once per request, with the connection's socket and `timeout_seconds`.
    /// A field so that a test can stand in for the kernel's timer.
    deadlines_fn: *const fn (std.posix.socket_t, u32) anyerror!void = setDeadlines,

    pub fn api(self: *Http) Api {
        return .{ .ctx = self, .sendFn = send };
    }

    pub fn setDeadlines(handle: std.posix.socket_t, seconds: u32) !void {
        const tv = std.posix.timeval{ .sec = @intCast(seconds), .usec = 0 };
        try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
        try std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
    }

    fn send(ctx: *anyopaque, a: std.mem.Allocator, req: Request) anyerror!Response {
        const self: *Http = @ptrCast(@alignCast(ctx));
        const url = if (req.url) |u| u else try std.fmt.allocPrint(a, "{s}/{s}", .{ self.base_url, req.path });
        if (!fetch.urlAllowed(url, self.allow_http_loopback)) return error.UrlNotAllowed;
        var client = std.http.Client{ .allocator = a, .read_buffer_size = 16 * 1024 };
        defer client.deinit();
        const uri = try std.Uri.parse(url);
        const bearer = if (req.auth) try std.fmt.allocPrint(a, "Bearer {s}", .{self.token}) else "";
        const headers = [_]std.http.Header{.{ .name = "Accept", .value = req.accept }};
        var hreq = try client.request(switch (req.method) {
            .GET => .GET,
            .POST => .POST,
            .PATCH => .PATCH,
        }, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
                .user_agent = .{ .override = "buildrules-autopin" },
                .authorization = if (req.auth) .{ .override = bearer } else .omit,
                .content_type = if (req.body != null) .{ .override = "application/json" } else .default,
            },
            .extra_headers = &headers,
        });
        defer hreq.deinit();
        try self.deadlines_fn(hreq.connection.?.stream_reader.getStream().handle, self.timeout_seconds);
        if (req.body) |b| {
            try hreq.sendBodyComplete(try a.dupe(u8, b));
        } else {
            try hreq.sendBodiless();
        }
        var response = try hreq.receiveHead(&.{});
        const status: u16 = @intFromEnum(response.head.status);
        if (response.head.status.class() == .redirect) {
            const loc = if (response.head.location) |l| try a.dupe(u8, l) else null;
            return .{ .status = status, .location = loc };
        }
        var transfer: [64]u8 = undefined;
        const body_reader = response.reader(&transfer);
        // One byte more than the cap: the reader reports "too long" when it reaches its limit, even at the end of the body.
        const body = body_reader.allocRemaining(a, .limited(req.max_body + 1)) catch |e| return if (e == error.StreamTooLong) error.ResponseTooLarge else if (e == error.OutOfMemory) e else response.bodyErr() orelse error.ReadFailed;
        // A connection that ends before the length it announced is a failure, not a short answer.
        if (response.head.content_length) |n| if (n != body.len) return error.TruncatedBody;
        return .{ .status = status, .body = body };
    }
};
