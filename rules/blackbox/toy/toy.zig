//! The toy a `blackbox_test` of this repository runs (README.md, "The toy"): a service with one outside call, a fake of that call, a driver, and the
//! packer that makes the service a Debian package. One program, the first argument naming the part:
//!
//!   toy service --listen ADDR --upstream ADDR   answers each line it is sent with `service saw: <what the upstream answered to "ask">`
//!   toy fake --listen ADDR --answer TEXT        answers each line it is sent with TEXT
//!   toy driver --service ADDR --expect TEXT     sends `hello` to the service; exit 0 when the answer is TEXT, 1 when it is not
//!   toy pack --out FILE --file PATH=SOURCE...   writes the package holding each SOURCE at PATH (mode 0755), its data member data.tar.gz
//!
//! ADDR is `127.0.0.1:PORT`. Every line read and written is said on stdout, so the logs of a run say what happened. A fixture of the tests: it is not
//! measured (rules/blackbox/BUCK).

const std = @import("std");
const debkit = @import("debkit");

fn flag(args: []const []const u8, name: []const u8) []const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name)) return args[i + 1];
    }
    std.debug.print("toy: `{s}` is required\n", .{name});
    std.process.exit(2);
}

fn address(text: []const u8) std.net.Address {
    return std.net.Address.parseIpAndPort(text) catch {
        std.debug.print("toy: `{s}` is not IP:PORT\n", .{text});
        std.process.exit(2);
    };
}

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    std.fs.File.stdout().writeAll(line) catch {};
}

/// One line of `s` (without its newline), or null when the peer closed first.
fn readLine(s: std.net.Stream, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    while (n < buf.len) {
        const got = s.read(buf[n .. n + 1]) catch return null;
        if (got == 0) return null;
        if (buf[n] == '\n') return buf[0..n];
        n += 1;
    }
    return buf[0..n];
}

fn ask(upstream: std.net.Address, buf: []u8) ?[]const u8 {
    const s = std.net.tcpConnectToAddress(upstream) catch return null;
    defer s.close();
    s.writeAll("ask\n") catch return null;
    return readLine(s, buf);
}

fn serve(listen: []const u8, comptime answer: fn (ctx: []const []const u8, line: []const u8, out: []u8) []const u8, ctx: []const []const u8) u8 {
    var server = address(listen).listen(.{ .reuse_address = true }) catch |e| {
        std.debug.print("toy: cannot listen on {s}: {s}\n", .{ listen, @errorName(e) });
        return 1;
    };
    say("listening on {s}", .{listen});
    while (true) {
        const conn = server.accept() catch continue;
        defer conn.stream.close();
        var line_buf: [256]u8 = undefined;
        // A connection that sends nothing (the runner's look at whether the port is taken) is closed with no answer.
        const line = readLine(conn.stream, &line_buf) orelse continue;
        var out_buf: [512]u8 = undefined;
        const reply = answer(ctx, line, &out_buf);
        say("got `{s}`, answered `{s}`", .{ line, reply });
        conn.stream.writeAll(reply) catch {};
        conn.stream.writeAll("\n") catch {};
    }
}

fn serviceAnswer(ctx: []const []const u8, _: []const u8, out: []u8) []const u8 {
    var buf: [256]u8 = undefined;
    const from = ask(address(ctx[0]), &buf) orelse "(the upstream did not answer)";
    return std.fmt.bufPrint(out, "service saw: {s}", .{from}) catch "service saw: (too long)";
}

fn fakeAnswer(ctx: []const []const u8, _: []const u8, _: []u8) []const u8 {
    return ctx[0];
}

fn driver(args: []const []const u8) u8 {
    const want = flag(args, "--expect");
    const s = std.net.tcpConnectToAddress(address(flag(args, "--service"))) catch |e| {
        say("driver: cannot connect to the service: {s}", .{@errorName(e)});
        return 1;
    };
    defer s.close();
    s.writeAll("hello\n") catch {};
    var buf: [512]u8 = undefined;
    const got = readLine(s, &buf) orelse "(no answer)";
    if (!std.mem.eql(u8, got, want)) {
        say("driver: the service answered `{s}`, not `{s}`", .{ got, want });
        return 1;
    }
    say("driver: the service answered `{s}`", .{got});
    return 0;
}

fn pack(a: std.mem.Allocator, args: []const []const u8) u8 {
    var files: std.ArrayList(debkit.Entry) = .empty;
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--file")) continue;
        const v = args[i + 1];
        const eq = std.mem.indexOfScalar(u8, v, '=') orelse return 2;
        const data = std.fs.cwd().readFileAlloc(a, v[eq + 1 ..], 1 << 30) catch return 1;
        files.append(a, .{ .name = v[0..eq], .mode = 0o755, .data = data }) catch return 1;
    }
    const bytes = debkit.packageOf(a, files.items) catch return 1;
    std.fs.cwd().writeFile(.{ .sub_path = flag(args, "--out"), .data = bytes }) catch return 1;
    return 0;
}

pub fn main() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = std.process.argsAlloc(a) catch return 1;
    const part = if (argv.len > 1) argv[1] else "";
    const args = if (argv.len > 1) argv[2..] else argv[0..0];
    if (std.mem.eql(u8, part, "service")) return serve(flag(args, "--listen"), serviceAnswer, &.{flag(args, "--upstream")});
    if (std.mem.eql(u8, part, "fake")) return serve(flag(args, "--listen"), fakeAnswer, &.{flag(args, "--answer")});
    if (std.mem.eql(u8, part, "driver")) return driver(args);
    if (std.mem.eql(u8, part, "pack")) return pack(a, args);
    std.debug.print("toy: the parts are service, fake, driver and pack\n", .{});
    return 2;
}
