//! The stand-ins the test of site/static/install.sh runs it with (install_script_test.zig). One program that is several: it does what its own name says, so
//! the test links it as `curl`, `uname`, `shasum` and `cosign`, and packs a copy of it as the `buildrules` program inside the fake release tarballs.
//!
//!   curl        the few options the script uses (-f -s -S -L, --retry N, -o FILE, -w '%{url_effective}') and one `http://` URL: a GET over a plain socket,
//!               redirects followed with -L, an error status refused with -f (exit 22). It is the test's HTTP client for its loopback server; the real
//!               curl is not on the PATH of a build action, and a script is tested with what it does with the answers, not with TLS.
//!   uname       `-s` prints $FAKE_OS and `-m` prints $FAKE_ARCH, so a Linux machine can be any platform.
//!   shasum      `-a 256 FILE`, the way a Mac prints it (the script falls back to it when there is no sha256sum).
//!   cosign      `verify-blob --bundle B ... FILE`: appends its arguments to the file $FAKE_COSIGN_LOG, refuses (exit 1) when the bundle or the file does not
//!               exist, and exits with $FAKE_COSIGN_EXIT (default 0, after printing a reason on stderr when it is not 0).
//!   buildrules  `--version` prints `buildrules $FAKE_BUILDRULES_VERSION`.

const std = @import("std");

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn out(bytes: []const u8) void {
    std.io.getStdOut().writeAll(bytes) catch {};
}

fn err(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn envOrNull(a: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(a, name) catch null;
}

fn uname(a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len != 1) {
        err("uname: only -s and -m\n", .{});
        return 2;
    }
    const var_name: []const u8 = if (eql(args[0], "-s")) "FAKE_OS" else if (eql(args[0], "-m")) "FAKE_ARCH" else {
        err("uname: only -s and -m\n", .{});
        return 2;
    };
    const v = envOrNull(a, var_name) orelse {
        err("uname: {s} is not set\n", .{var_name});
        return 2;
    };
    out(v);
    out("\n");
    return 0;
}

fn buildrules(a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len != 1 or !eql(args[0], "--version")) {
        err("buildrules: only --version\n", .{});
        return 2;
    }
    const v = envOrNull(a, "FAKE_BUILDRULES_VERSION") orelse {
        err("buildrules: FAKE_BUILDRULES_VERSION is not set\n", .{});
        return 2;
    };
    out("buildrules ");
    out(v);
    out("\n");
    return 0;
}

fn shasum(a: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len != 3 or !eql(args[0], "-a") or !eql(args[1], "256")) {
        err("shasum: only -a 256 FILE\n", .{});
        return 2;
    }
    const bytes = std.fs.cwd().readFileAlloc(a, args[2], 1 << 28) catch {
        err("shasum: {s}: cannot read\n", .{args[2]});
        return 1;
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const line = std.fmt.allocPrint(a, "{s}  {s}\n", .{ std.fmt.fmtSliceHexLower(&digest), args[2] }) catch return 2;
    out(line);
    return 0;
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn cosign(a: std.mem.Allocator, args: []const []const u8) u8 {
    if (envOrNull(a, "FAKE_COSIGN_LOG")) |log| {
        const joined = std.mem.join(a, " ", args) catch return 2;
        const line = std.fmt.allocPrint(a, "{s}\n", .{joined}) catch return 2;
        const f = std.fs.cwd().createFile(log, .{ .truncate = false }) catch return 2;
        defer f.close();
        f.seekFromEnd(0) catch return 2;
        f.writeAll(line) catch return 2;
    }
    if (args.len < 2 or !eql(args[0], "verify-blob")) {
        err("cosign: only verify-blob\n", .{});
        return 2;
    }
    var bundle: ?[]const u8 = null;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 1) {
        if (eql(args[i], "--bundle")) bundle = args[i + 1];
    }
    const file = args[args.len - 1];
    if (bundle == null or !exists(bundle.?) or !exists(file)) {
        err("cosign: the bundle or the file to verify does not exist\n", .{});
        return 1;
    }
    if (envOrNull(a, "FAKE_COSIGN_EXIT")) |code| {
        const n = std.fmt.parseInt(u8, code, 10) catch return 2;
        if (n != 0) err("Error: none of the expected identities matched what was in the certificate\n", .{});
        return n;
    }
    return 0;
}

const Response = struct {
    status: u16,
    location: ?[]const u8,
    body: []const u8,
};

const Parsed = struct { host: []const u8, port: u16, path: []const u8, origin: []const u8 };

fn parseUrl(url: []const u8) ?Parsed {
    const scheme = "http://";
    if (!std.mem.startsWith(u8, url, scheme)) return null;
    const rest = url[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const hostport = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";
    var host = hostport;
    var port: u16 = 80;
    if (std.mem.indexOfScalar(u8, hostport, ':')) |c| {
        host = hostport[0..c];
        port = std.fmt.parseInt(u16, hostport[c + 1 ..], 10) catch return null;
    }
    return .{ .host = host, .port = port, .path = path, .origin = url[0 .. scheme.len + slash] };
}

fn get(a: std.mem.Allocator, p: Parsed) !Response {
    const stream = try std.net.tcpConnectToHost(a, p.host, p.port);
    defer stream.close();
    const req = try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: fake-curl\r\nConnection: close\r\n\r\n", .{ p.path, p.host });
    try stream.writeAll(req);
    var all = std.ArrayList(u8).init(a);
    var chunk: [16384]u8 = undefined;
    while (true) {
        const n = try stream.read(&chunk);
        if (n == 0) break;
        try all.appendSlice(chunk[0..n]);
    }
    const head_end = std.mem.indexOf(u8, all.items, "\r\n\r\n") orelse return error.BadResponse;
    const head = all.items[0..head_end];
    var body = all.items[head_end + 4 ..];
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const status_line = lines.next() orelse return error.BadResponse;
    var parts = std.mem.splitScalar(u8, status_line, ' ');
    _ = parts.next();
    const status = std.fmt.parseInt(u16, parts.next() orelse return error.BadResponse, 10) catch return error.BadResponse;
    var location: ?[]const u8 = null;
    var length: ?usize = null;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " ");
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(key, "location")) location = value;
        if (std.ascii.eqlIgnoreCase(key, "content-length")) length = std.fmt.parseInt(usize, value, 10) catch return error.BadResponse;
    }
    if (length) |l| {
        if (body.len < l) return error.ShortBody;
        body = body[0..l];
    }
    return .{ .status = status, .location = location, .body = body };
}

fn writeBody(path: []const u8, body: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(body);
}

fn curl(a: std.mem.Allocator, args: []const []const u8) u8 {
    var fail_on_error = false;
    var follow = false;
    var out_path: ?[]const u8 = null;
    var write_out: ?[]const u8 = null;
    var url: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eql(arg, "--retry")) {
            i += 1;
        } else if (eql(arg, "-o") or eql(arg, "-w")) {
            i += 1;
            if (i >= args.len) {
                err("curl: {s} needs a value\n", .{arg});
                return 2;
            }
            if (eql(arg, "-o")) out_path = args[i] else write_out = args[i];
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            for (arg[1..]) |c| switch (c) {
                'f' => fail_on_error = true,
                'L' => follow = true,
                's', 'S' => {},
                else => {
                    err("curl: option -{c} is not supported by this stand-in\n", .{c});
                    return 2;
                },
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            err("curl: option {s} is not supported by this stand-in\n", .{arg});
            return 2;
        } else {
            url = arg;
        }
    }
    var current = url orelse {
        err("curl: no URL\n", .{});
        return 2;
    };
    var hops: usize = 0;
    while (true) : (hops += 1) {
        const p = parseUrl(current) orelse {
            err("curl: (1) Protocol not supported by this stand-in: {s}\n", .{current});
            return 1;
        };
        const r = get(a, p) catch |e| {
            err("curl: (7) {s} for {s}\n", .{ @errorName(e), current });
            return if (e == error.ConnectionRefused) 7 else 18;
        };
        if (follow and r.location != null and r.status >= 300 and r.status < 400) {
            if (hops >= 10) {
                err("curl: (47) Maximum redirects followed\n", .{});
                return 47;
            }
            const loc = r.location.?;
            current = if (std.mem.startsWith(u8, loc, "/"))
                std.fmt.allocPrint(a, "{s}{s}", .{ p.origin, loc }) catch return 2
            else
                loc;
            continue;
        }
        if (fail_on_error and r.status >= 400) {
            err("curl: (22) The requested URL returned error: {d}\n", .{r.status});
            return 22;
        }
        if (out_path) |path| {
            writeBody(path, r.body) catch {
                err("curl: (23) cannot write {s}\n", .{path});
                return 23;
            };
        } else out(r.body);
        if (write_out) |fmt| {
            const text = std.mem.replaceOwned(u8, a, fmt, "%{url_effective}", current) catch return 2;
            out(text);
        }
        return 0;
    }
}

pub fn main() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = std.process.argsAlloc(a) catch return 2;
    const name = std.fs.path.basename(argv[0]);
    const args = argv[1..];
    if (eql(name, "uname")) return uname(a, args);
    // The script runs the program under a temporary name (.buildrules.new.<pid>) before it moves it into place.
    if (eql(name, "buildrules") or std.mem.startsWith(u8, name, ".buildrules.new.")) return buildrules(a, args);
    if (eql(name, "shasum")) return shasum(a, args);
    if (eql(name, "cosign")) return cosign(a, args);
    if (eql(name, "curl")) return curl(a, args);
    err("fakes: run as curl, uname, shasum, cosign or buildrules, not '{s}'\n", .{name});
    return 2;
}
