//! The toy's driver (README.md, "The toy"): the program a `blackbox_test` runs once the toy service's and the toy fake's packages are on the image. Its one
//! argument is the root they were put onto (`/` on a farm). It gives the fake and the service a loopback port each, starts the fake
//! (`usr/bin/toy-fake fake`, answering `from the fake`), waits until it takes a connection, starts the service (`usr/bin/toy-service service`) with its
//! upstream pointed at the fake, waits the same way, sends the service `hello`, and stops both. It exits 0 when the service answered `EXPECT`, and 1
//! when it did not or when either did not start. What they printed is on the test's own output (their streams are this program's). A fixture of the
//! tests: it is not measured (rules/blackbox/BUCK).

const std = @import("std");
const posix = std.posix;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "driver: " ++ fmt ++ "\n", args) catch return;
    std.fs.File.stdout().writeAll(line) catch {};
}

/// A loopback port nothing listens on now (bound with port 0, read back, released).
fn freePort() !u16 {
    var server = try std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0).listen(.{});
    defer server.deinit();
    return server.listen_address.getPort();
}

/// Waits until `port` takes a connection; false when the process exits first or after 30 s.
fn ready(child: *std.process.Child, port: u16, name: []const u8) bool {
    var tries: usize = 0;
    while (tries < 1500) : (tries += 1) {
        if (std.net.tcpConnectToAddress(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port))) |s| {
            s.close();
            return true;
        } else |_| {}
        const r = posix.waitpid(child.id, posix.W.NOHANG);
        if (r.pid == child.id) {
            say("the {s} exited before it took a connection", .{name});
            child.id = 0;
            return false;
        }
        posix.nanosleep(0, 20 * std.time.ns_per_ms);
    }
    say("the {s} took no connection within 30 s", .{name});
    return false;
}

fn stop(child: *std.process.Child) void {
    if (child.id == 0) return;
    _ = child.kill() catch {};
}

fn ask(port: u16, buf: []u8) []const u8 {
    const s = std.net.tcpConnectToAddress(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port)) catch return "(no connection)";
    defer s.close();
    s.writeAll("hello\n") catch return "(not sent)";
    var n: usize = 0;
    while (n < buf.len) {
        const got = s.read(buf[n .. n + 1]) catch return "(no answer)";
        if (got == 0 or buf[n] == '\n') break;
        n += 1;
    }
    return buf[0..n];
}

/// The driver's run, expecting the service to answer `expect`.
pub fn drive(expect: []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = std.process.argsAlloc(a) catch return 1;
    if (argv.len != 2) {
        say("the one argument is the root the packages were put onto", .{});
        return 2;
    }
    const fake_port = freePort() catch return 1;
    var service_port = freePort() catch return 1;
    while (service_port == fake_port) service_port = freePort() catch return 1;
    const fake_addr = std.fmt.allocPrint(a, "127.0.0.1:{d}", .{fake_port}) catch return 1;
    const service_addr = std.fmt.allocPrint(a, "127.0.0.1:{d}", .{service_port}) catch return 1;
    const fake_bin = std.fs.path.join(a, &.{ argv[1], "usr/bin/toy-fake" }) catch return 1;
    const service_bin = std.fs.path.join(a, &.{ argv[1], "usr/bin/toy-service" }) catch return 1;

    var fake = std.process.Child.init(&.{ fake_bin, "fake", "--listen", fake_addr, "--answer", "from the fake" }, a);
    fake.stdin_behavior = .Ignore;
    fake.spawn() catch |e| {
        say("cannot start {s}: {s}", .{ fake_bin, @errorName(e) });
        return 1;
    };
    defer stop(&fake);
    if (!ready(&fake, fake_port, "fake")) return 1;
    var service = std.process.Child.init(&.{ service_bin, "service", "--listen", service_addr, "--upstream", fake_addr }, a);
    service.stdin_behavior = .Ignore;
    service.spawn() catch |e| {
        say("cannot start {s}: {s}", .{ service_bin, @errorName(e) });
        return 1;
    };
    defer stop(&service);
    if (!ready(&service, service_port, "service")) return 1;
    var buf: [512]u8 = undefined;
    const got = ask(service_port, &buf);
    if (!std.mem.eql(u8, got, expect)) {
        say("the service answered `{s}`, not `{s}`", .{ got, expect });
        return 1;
    }
    say("the service answered `{s}`", .{got});
    return 0;
}

pub fn main() u8 {
    return drive("service saw: from the fake");
}
