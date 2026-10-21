//! fetch_tool: GET one URL and publish its bytes only if their sha512 is the one stated.
//!
//!   fetch_tool --url <url> --sri sha512-<base64> --out <path> --allow-host <host> [--allow-host <host>]...
//!              [--max-bytes <n>] [--ca-file <pem>]
//!
//! Exit 0 published; 3 integrity mismatch (nothing written); 4 network or HTTP failure; 5 usage;
//! 6 a host (the URL's or a redirect's) is not allowed. The action that runs this has no input files:
//! its key is this binary, the URL, the integrity string and the output path.
const std = @import("std");
const fetch = @import("fetch.zig");

fn say(comptime fmt: []const u8, args: anytype) void {
    std.fs.File.stderr().deprecatedWriter().print("fetch_tool: " ++ fmt ++ "\n", args) catch {};
}

const Got = union(enum) { body: []u8, redirect: []u8 };

fn get(a: std.mem.Allocator, client: *std.http.Client, url: []const u8, max: usize) !Got {
    const uri = std.Uri.parse(url) catch return error.BadUrl;
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    });
    defer req.deinit();
    try req.sendBodiless();
    var rbuf: [16 * 1024]u8 = undefined;
    var resp = try req.receiveHead(&rbuf);
    const st = resp.head.status;
    if (st.class() == .redirect) {
        const loc = resp.head.location orelse return error.RedirectWithoutLocation;
        return .{ .redirect = try fetch.resolveRedirect(a, url, loc) };
    }
    if (st != .ok) {
        say("HTTP {d} for {s}", .{ @intFromEnum(st), url });
        return error.HttpStatus;
    }
    var tbuf: [4096]u8 = undefined;
    const r = resp.reader(&tbuf);
    const body = r.allocRemaining(a, .limited(max)) catch |e| switch (e) {
        error.StreamTooLong => return error.TooLarge,
        error.OutOfMemory => return e,
        error.ReadFailed => return resp.bodyErr() orelse error.ReadFailed,
    };
    return .{ .body = body };
}

fn download(a: std.mem.Allocator, client: *std.http.Client, url0: []const u8, allow: []const []const u8, max: usize, allow_data: bool) ![]u8 {
    if (allow_data and std.mem.startsWith(u8, url0, "data:")) return fetch.dataPayload(a, url0);
    var url = url0;
    var hops: u8 = 0;
    while (true) {
        // Every hop: a redirect is a URL the server chose.
        if (!fetch.hostAllowed(url, allow)) {
            say("host of {s} is not in the allowed hosts", .{url});
            return error.HostNotAllowed;
        }
        switch (try get(a, client, url, max)) {
            .body => |b| return b,
            .redirect => |next| {
                hops += 1;
                if (hops > 5) return error.TooManyRedirects;
                url = next;
            },
        }
    }
}

pub fn main() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = std.process.argsAlloc(a) catch return 5;
    var url: ?[]const u8 = null;
    var sri: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var ca: ?[]const u8 = null;
    var max: usize = 512 << 20;
    var allow_data = false;
    var allow: std.ArrayListUnmanaged([]const u8) = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) {
            say("{s} needs a value", .{argv[i]});
            return 5;
        }
        const v = argv[i + 1];
        if (std.mem.eql(u8, argv[i], "--url")) url = v else if (std.mem.eql(u8, argv[i], "--sri")) sri = v else if (std.mem.eql(u8, argv[i], "--out")) out = v else if (std.mem.eql(u8, argv[i], "--ca-file")) ca = v else if (std.mem.eql(u8, argv[i], "--allow-host")) allow.append(a, v) catch return 5 else if (std.mem.eql(u8, argv[i], "--allow-data")) allow_data = std.mem.eql(u8, v, "true") else if (std.mem.eql(u8, argv[i], "--max-bytes")) max = std.fmt.parseInt(usize, v, 10) catch return 5 else {
            say("unknown flag {s}", .{argv[i]});
            return 5;
        }
    }
    if (url == null or sri == null or out == null or allow.items.len == 0) {
        say("usage: fetch_tool --url U --sri sha512-B64 --out PATH --allow-host H [--allow-host H]... [--max-bytes N] [--ca-file PEM]", .{});
        return 5;
    }
    const want = fetch.parseSri(sri.?) catch {
        say("--sri {s} is not sha512- followed by the base64 of 64 bytes", .{sri.?});
        return 5;
    };
    var client = std.http.Client{ .allocator = a };
    defer client.deinit();
    if (ca) |path| {
        client.ca_bundle.addCertsFromFilePath(a, std.fs.cwd(), path) catch |e| {
            say("cannot read the CA file {s}: {s}", .{ path, @errorName(e) });
            return 5;
        };
        client.next_https_rescan_certs = false;
    }
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        const body = download(a, &client, url.?, allow.items, max, allow_data) catch |e| {
            if (e == error.HostNotAllowed) return 6;
            say("attempt {d}: {s}: {s}", .{ attempt + 1, url.?, @errorName(e) });
            if (attempt < 3) {
                std.Thread.sleep(std.time.ns_per_s * (@as(u64, attempt) + 1));
                continue;
            }
            return 4;
        };
        var got: [64]u8 = undefined;
        const res = fetch.publish(std.fs.cwd(), out.?, body, want, &got) catch |e| {
            say("cannot write {s}: {s}", .{ out.?, @errorName(e) });
            return 4;
        };
        if (res == .mismatch) {
            say("integrity mismatch for {s}: expected {s}, got {s}", .{ url.?, sri.?, &fetch.sriOf(got) });
            return 3;
        }
        return 0;
    }
}
