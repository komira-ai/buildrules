//! The tests of probe.zig: the probe run against `Fake`, a stand-in for the kernel that answers each call from a table and logs it, so
//! every outcome of every step is driven here and the whole report is compared byte for byte. No test makes a real system call.

const std = @import("std");
const linux = std.os.linux;
const probe = @import("probe.zig");
const testing = std.testing;

/// A file the fake can open for reading.
const File = struct { path: []const u8, text: []const u8 };

/// The call whose `nth` occurrence (1 is the first, 0 every one) fails with `e`. A call's key is its name and, for most, what it is
/// about: `open /proc/self/status`, `socket stream`, `connect nonblocking`, `read accepted` (Fake.key).
const Fail = struct { key: []const u8, e: linux.E, nth: usize = 0 };

const Kind = enum { file, sink, dgram, stream, nonblocking, accepted, stdout, stderr };

const Fd = struct { kind: Kind, path: []const u8 = "", text: []const u8 = "", pos: usize = 0, open: bool = true, written: std.ArrayList(u8) = .empty };

const default_files = [_]File{
    .{ .path = "/proc/self/status", .text = "Name:\tfarm_probe\nUid:\t1000\t1000\t1000\t1000\nGid:\t1000\t1000\t1000\t1000\nGroups:\t\nCapInh:\t0000000000000000\nCapPrm:\t0000000000000000\nCapEff:\t0000000000000000\nCapBnd:\t0000000000000000\nCapAmb:\t0000000000000000\nNoNewPrivs:\t1\nSeccomp:\t2\nSeccomp_filters:\t1\n" },
    .{ .path = "/proc/self/uid_map", .text = "         0     100000      65536\n" },
    .{ .path = "/proc/self/gid_map", .text = "         0     200000      65536\n" },
    .{ .path = "/proc/self/cgroup", .text = "0::/\n" },
    .{ .path = "/sys/fs/cgroup/memory.max", .text = "8589934592\n" },
    .{ .path = "/sys/fs/cgroup/memory.high", .text = "max\n" },
    .{ .path = "/sys/fs/cgroup/memory.swap.max", .text = "0\n" },
    .{ .path = "/sys/fs/cgroup/pids.max", .text = "4096\n" },
    .{ .path = "/sys/fs/cgroup/cpu.max", .text = "400000 100000\n" },
    .{ .path = "/proc/net/dev", .text = "Inter-|   Receive\n face |bytes\n    lo: 0 0 0\n  eth0: 1 2 3\n" },
    .{ .path = "/proc/sys/user/max_user_namespaces", .text = "63452\n" },
    .{ .path = "/proc/sys/kernel/apparmor_restrict_unprivileged_userns", .text = "0\n" },
};

const Fake = struct {
    a: std.mem.Allocator = testing.allocator,
    files: []const File = &default_files,
    fails: []const Fail = &.{},
    /// Every call, by its key, in order.
    log: std.ArrayList([]u8) = .empty,
    fds: std.ArrayList(Fd) = .empty,
    uid: u32 = 1000,
    gid: u32 = 1000,
    limit: linux.rlimit = .{ .cur = 1024, .max = linux.RLIM.INFINITY },
    cpus: usize = 3,
    lo_up: bool = true,
    /// What `poll` returns: the number of ready descriptors.
    ready: usize = 1,
    /// What `getsockopt(SO_ERROR)` gives.
    so_error: i32 = 0,
    /// The byte the accepted socket reads.
    byte: u8 = 'x',
    /// Bytes a write takes at most (0: all of them).
    short_write: usize = 0,
    /// A nonblocking connect that completes at once instead of returning EINPROGRESS.
    connect_now: bool = false,

    fn deinit(f: *Fake) void {
        for (f.log.items) |k| f.a.free(k);
        f.log.deinit(f.a);
        for (f.fds.items) |*d| {
            d.written.deinit(f.a);
            f.a.free(d.path);
        }
        f.fds.deinit(f.a);
    }

    /// Logs `key` and gives the raw result of the failure the table names for this occurrence, or null.
    fn call(f: *Fake, comptime fmt: []const u8, args: anytype) ?usize {
        const k = std.fmt.allocPrint(f.a, fmt, args) catch @panic("out of memory");
        var seen: usize = 0;
        for (f.log.items) |prev| seen += @intFromBool(std.mem.eql(u8, prev, k));
        f.log.append(f.a, k) catch @panic("out of memory");
        for (f.fails) |fail| {
            if (std.mem.eql(u8, fail.key, k) and (fail.nth == 0 or fail.nth == seen + 1)) return errRc(fail.e);
        }
        return null;
    }

    /// The first two entries are stdout and stderr (fds 1 and 2); every other fd is its index plus 8.
    fn ensure(f: *Fake) void {
        if (f.fds.items.len > 0) return;
        f.fds.append(f.a, .{ .kind = .stdout, .open = false, .path = f.a.dupe(u8, "") catch @panic("out of memory") }) catch @panic("out of memory");
        f.fds.append(f.a, .{ .kind = .stderr, .open = false, .path = f.a.dupe(u8, "") catch @panic("out of memory") }) catch @panic("out of memory");
    }

    /// A new fd; its path is copied, as the probe's buffer for it is reused.
    fn newFd(f: *Fake, d: Fd) usize {
        f.ensure();
        var own = d;
        own.path = f.a.dupe(u8, d.path) catch @panic("out of memory");
        f.fds.append(f.a, own) catch @panic("out of memory");
        return f.fds.items.len - 1 + 8;
    }

    fn fd(f: *Fake, n: i32) *Fd {
        f.ensure();
        return &f.fds.items[@intCast(if (n < 10) n - 1 else n - 8)];
    }

    /// What was written to an fd of `kind` (stdout, stderr) or to the file at `path`.
    fn written(f: *Fake, kind: Kind, path: []const u8) []const u8 {
        for (f.fds.items) |d| {
            if (d.kind == kind and std.mem.eql(u8, d.path, path)) return d.written.items;
        }
        return "";
    }

    fn openCount(f: *Fake) usize {
        var n: usize = 0;
        for (f.fds.items) |d| n += @intFromBool(d.open);
        return n;
    }

    /// How many calls with `key` the table made fail.
    fn failedCount(f: *Fake, key: []const u8) usize {
        var n: usize = 0;
        var seen: usize = 0;
        for (f.log.items) |k| {
            if (!std.mem.eql(u8, k, key)) continue;
            seen += 1;
            for (f.fails) |fail| {
                if (std.mem.eql(u8, fail.key, k) and (fail.nth == 0 or fail.nth == seen)) {
                    n += 1;
                    break;
                }
            }
        }
        return n;
    }

    fn count(f: *Fake, key: []const u8) usize {
        var n: usize = 0;
        for (f.log.items) |k| n += @intFromBool(std.mem.eql(u8, k, key));
        return n;
    }

    pub fn open(f: *Fake, path: [*:0]const u8, flags: linux.O, mode: linux.mode_t) usize {
        _ = mode;
        const p = std.mem.span(path);
        if (f.call("open {s}", .{p})) |rc| return rc;
        if (flags.ACCMODE != .RDONLY) return f.newFd(.{ .kind = .sink, .path = p });
        for (f.files) |file| {
            if (std.mem.eql(u8, file.path, p)) return f.newFd(.{ .kind = .file, .path = p, .text = file.text });
        }
        return errRc(.NOENT);
    }
    pub fn read(f: *Fake, n: i32, buf: []u8) usize {
        const d = f.fd(n);
        if (d.kind == .accepted) {
            if (f.call("read accepted", .{})) |rc| return rc;
            buf[0] = f.byte;
            return 1;
        }
        if (f.call("read {s}", .{d.path})) |rc| return rc;
        const left = d.text[d.pos..];
        const got = @min(left.len, buf.len);
        @memcpy(buf[0..got], left[0..got]);
        d.pos += got;
        return got;
    }
    pub fn write(f: *Fake, n: i32, bytes: []const u8) usize {
        const d = f.fd(n);
        const what = if (d.path.len > 0) d.path else @tagName(d.kind);
        if (f.call("write {s}", .{what})) |rc| return rc;
        const took = if (f.short_write > 0) @min(f.short_write, bytes.len) else bytes.len;
        d.written.appendSlice(f.a, bytes[0..took]) catch @panic("out of memory");
        return took;
    }
    pub fn close(f: *Fake, n: i32) usize {
        _ = f.call("close", .{});
        const d = f.fd(n);
        if (!d.open) @panic("closed twice");
        d.open = false;
        return 0;
    }
    pub fn unlink(f: *Fake, path: [*:0]const u8) usize {
        return f.call("unlink {s}", .{path}) orelse 0;
    }
    pub fn mkdir(f: *Fake, path: [*:0]const u8, mode: linux.mode_t) usize {
        _ = mode;
        return f.call("mkdir {s}", .{path}) orelse 0;
    }
    pub fn rmdir(f: *Fake, path: [*:0]const u8) usize {
        return f.call("rmdir {s}", .{path}) orelse 0;
    }
    pub fn access(f: *Fake, path: [*:0]const u8, mode: u32) usize {
        return f.call("access {s} {d}", .{ path, mode }) orelse 0;
    }
    pub fn uname(f: *Fake, uts: *linux.utsname) usize {
        if (f.call("uname", .{})) |rc| return rc;
        uts.* = std.mem.zeroes(linux.utsname);
        @memcpy(uts.release[0..10], "6.1.0-test");
        @memcpy(uts.machine[0..6], "x86_64");
        return 0;
    }
    pub fn getrlimit(f: *Fake, res: linux.rlimit_resource, lim: *linux.rlimit) usize {
        if (f.call("getrlimit {s}", .{@tagName(res)})) |rc| return rc;
        lim.* = f.limit;
        return 0;
    }
    pub fn affinity(f: *Fake, set: *linux.cpu_set_t) usize {
        if (f.call("affinity", .{})) |rc| return rc;
        set.* = std.mem.zeroes(linux.cpu_set_t);
        set[0] = (@as(usize, 1) << @intCast(f.cpus)) - 1;
        return @sizeOf(linux.cpu_set_t);
    }
    pub fn getcwd(f: *Fake, buf: []u8) usize {
        if (f.call("getcwd", .{})) |rc| return rc;
        @memcpy(buf[0..10], "/work/dir\x00");
        return 10;
    }
    pub fn getpid(_: *Fake) i32 {
        return 7;
    }
    pub fn getuid(f: *Fake) u32 {
        return f.uid;
    }
    pub fn getgid(f: *Fake) u32 {
        return f.gid;
    }
    pub fn socket(f: *Fake, domain: u32, kind: u32, protocol: u32) usize {
        std.debug.assert(domain == linux.AF.INET and protocol == 0);
        const k: Kind = if (kind & linux.SOCK.DGRAM != 0) .dgram else if (kind & linux.SOCK.NONBLOCK != 0) .nonblocking else .stream;
        if (f.call("socket {s}", .{@tagName(k)})) |rc| return rc;
        return f.newFd(.{ .kind = k });
    }
    pub fn ioctl(f: *Fake, n: i32, request: u32, req: *linux.ifreq) usize {
        std.debug.assert(f.fd(n).kind == .dgram and request == linux.SIOCGIFFLAGS);
        if (f.call("ioctl {s}", .{std.mem.sliceTo(&req.ifrn.name, 0)})) |rc| return rc;
        req.ifru.flags = .{ .UP = f.lo_up, .RUNNING = f.lo_up, .LOOPBACK = true };
        return 0;
    }
    pub fn bind(f: *Fake, n: i32, addr: *const linux.sockaddr.in) usize {
        _ = n;
        std.debug.assert(addr.addr == std.mem.nativeToBig(u32, 0x7f000001) and addr.port == 0);
        return f.call("bind", .{}) orelse 0;
    }
    pub fn listen(f: *Fake, n: i32, backlog: u32) usize {
        _ = .{ n, backlog };
        return f.call("listen", .{}) orelse 0;
    }
    pub fn getsockname(f: *Fake, n: i32, addr: *linux.sockaddr.in) usize {
        _ = n;
        if (f.call("getsockname", .{})) |rc| return rc;
        addr.port = std.mem.nativeToBig(u16, 4321);
        return 0;
    }
    pub fn connect(f: *Fake, n: i32, addr: *const linux.sockaddr.in) usize {
        const k = f.fd(n).kind;
        if (f.call("connect {s}", .{@tagName(k)})) |rc| return rc;
        if (k == .nonblocking) return if (f.connect_now) 0 else errRc(.INPROGRESS);
        std.debug.assert(addr.port == std.mem.nativeToBig(u16, 4321));
        return 0;
    }
    pub fn accept(f: *Fake, n: i32) usize {
        _ = n;
        if (f.call("accept", .{})) |rc| return rc;
        return f.newFd(.{ .kind = .accepted });
    }
    pub fn poll(f: *Fake, fds: []linux.pollfd, timeout_ms: i32) usize {
        std.debug.assert(fds.len == 1 and fds[0].events == linux.POLL.OUT and timeout_ms == probe.egress_wait_ms);
        return f.call("poll", .{}) orelse f.ready;
    }
    pub fn sockError(f: *Fake, n: i32, err: *i32) usize {
        _ = n;
        if (f.call("getsockopt", .{})) |rc| return rc;
        err.* = f.so_error;
        return 0;
    }
    pub fn unshare(f: *Fake, flags: usize) usize {
        const what = if (flags == linux.CLONE.NEWUSER) "user" else if (flags == linux.CLONE.NEWNS) "mount" else "other";
        return f.call("unshare {s}", .{what}) orelse 0;
    }
    pub fn mount(f: *Fake, source: [*:0]const u8, dir: [*:0]const u8, fstype: [*:0]const u8, flags: u32, data: [*:0]const u8) usize {
        std.debug.assert(std.mem.eql(u8, std.mem.span(fstype), "tmpfs") and std.mem.eql(u8, std.mem.span(source), "tmpfs"));
        std.debug.assert(flags == linux.MS.NOSUID | linux.MS.NODEV and std.mem.eql(u8, std.mem.span(data), "size=1m"));
        return f.call("mount {s}", .{dir}) orelse 0;
    }
    pub fn umount(f: *Fake, dir: [*:0]const u8) usize {
        return f.call("umount {s}", .{dir}) orelse 0;
    }
};

fn errRc(e: linux.E) usize {
    return @bitCast(-@as(isize, @intFromEnum(e)));
}

const environ = [_][*:0]const u8{ "PATH=/bb/bin", "TMPDIR=/t/mp", "HOME=/h", "ODD" };

/// The report of `f` for `argv`, exit status `want`; the caller frees the returned stdout.
fn runProbe(f: *Fake, argv: []const [*:0]const u8, want: u8) ![]const u8 {
    var buf: [65536]u8 = undefined;
    try testing.expectEqual(want, probe.run(f, argv, &environ, &buf));
    return f.written(.stdout, "");
}

/// Every file and directory the probe made was removed, every mount taken down, every descriptor closed.
fn expectCleanedUp(f: *Fake) !void {
    try testing.expectEqual(f.count("open farm_probe_7.tmp") - f.failedCount("open farm_probe_7.tmp"), f.count("unlink farm_probe_7.tmp"));
    try testing.expectEqual(f.count("open farm_probe_7_userns.tmp") - f.failedCount("open farm_probe_7_userns.tmp"), f.count("unlink farm_probe_7_userns.tmp"));
    try testing.expectEqual(f.count("mkdir farm_probe_7_mnt") - f.failedCount("mkdir farm_probe_7_mnt"), f.count("rmdir farm_probe_7_mnt"));
    try testing.expectEqual(f.count("mount farm_probe_7_mnt") - f.failedCount("mount farm_probe_7_mnt"), f.count("umount farm_probe_7_mnt"));
    try testing.expectEqual(@as(usize, 0), f.openCount());
}

const full_report =
    \\probe build
    \\run 42
    \\kernel 6.1.0-test
    \\machine x86_64
    \\status.Uid 1000 1000 1000 1000
    \\status.Gid 1000 1000 1000 1000
    \\status.Groups none
    \\status.CapInh 0000000000000000
    \\status.CapPrm 0000000000000000
    \\status.CapEff 0000000000000000
    \\status.CapBnd 0000000000000000
    \\status.CapAmb 0000000000000000
    \\status.NoNewPrivs 1
    \\status.Seccomp 2
    \\status.Seccomp_filters 1
    \\uid_map 0 100000 65536
    \\gid_map 0 200000 65536
    \\env.names PATH TMPDIR HOME ODD
    \\env.PATH /bb/bin
    \\env.TMPDIR.length 5
    \\cwd.length 9
    \\rlimit.CPU soft=1024 hard=unlimited
    \\rlimit.AS soft=1024 hard=unlimited
    \\rlimit.FSIZE soft=1024 hard=unlimited
    \\rlimit.NOFILE soft=1024 hard=unlimited
    \\rlimit.NPROC soft=1024 hard=unlimited
    \\rlimit.CORE soft=1024 hard=unlimited
    \\cpus 3
    \\cgroup /
    \\cgroup.memory.max 8589934592
    \\cgroup.memory.high max
    \\cgroup.memory.swap.max 0
    \\cgroup.pids.max 4096
    \\cgroup.cpu.max 400000 100000
    \\root.access_w ok
    \\cwd.access_w ok
    \\cwd.create ok
    \\dev.fuse.exists ok
    \\dev.fuse.open ok
    \\net.interfaces lo eth0
    \\lo.flags up=yes running=yes
    \\loopback ok
    \\egress 192.0.2.1:443 connected
    \\sysctl.user.max_user_namespaces 63452
    \\sysctl.kernel.unprivileged_userns_clone ENOENT
    \\sysctl.kernel.apparmor_restrict_unprivileged_userns 0
    \\userns.unshare ok
    \\userns.setgroups ok
    \\userns.uid_map ok
    \\userns.gid_map ok
    \\userns.uid 1000
    \\userns.write_own_file ok
    \\userns.unshare_mount ok
    \\userns.mount_tmpfs ok
    \\
;

const full_argv = [_][*:0]const u8{ "build", "--out", "report.txt", "--egress", "192.0.2.1:443", "--run", "42" };

test "everything allowed: the whole report, byte for byte, on stdout and in --out, and everything the probe made is gone" {
    var f = Fake{};
    defer f.deinit();
    const out = try runProbe(&f, &full_argv, 0);
    try testing.expectEqualStrings(full_report, out);
    try testing.expectEqualStrings(full_report, f.written(.sink, "report.txt"));
    try testing.expectEqualStrings("0 1000 1", f.written(.sink, "/proc/self/uid_map"));
    try testing.expectEqualStrings("0 1000 1", f.written(.sink, "/proc/self/gid_map"));
    try testing.expectEqualStrings("deny", f.written(.sink, "/proc/self/setgroups"));
    try testing.expectEqualStrings("x", f.written(.sink, "farm_probe_7.tmp"));
    try testing.expectEqual(@as(usize, 1), f.count("umount farm_probe_7_mnt"));
    try expectCleanedUp(&f);
}

test "nothing allowed: every step reports its error, the probe goes on and exits 0" {
    var f = Fake{
        .files = &.{},
        .fails = &.{
            .{ .key = "uname", .e = .PERM },
            .{ .key = "getcwd", .e = .NOENT },
            .{ .key = "getrlimit CPU", .e = .INVAL },
            .{ .key = "affinity", .e = .PERM },
            .{ .key = "access / 2", .e = .ROFS },
            .{ .key = "access . 2", .e = .ACCES },
            .{ .key = "open farm_probe_7.tmp", .e = .ACCES },
            .{ .key = "access /dev/fuse 0", .e = .NOENT },
            .{ .key = "open /dev/fuse", .e = .NOENT },
            .{ .key = "socket dgram", .e = .AFNOSUPPORT },
            .{ .key = "socket stream", .e = .ACCES },
            .{ .key = "socket nonblocking", .e = .ACCES },
            .{ .key = "unshare user", .e = .PERM },
        },
    };
    defer f.deinit();
    const out = try runProbe(&f, &.{ "test", "--egress", "192.0.2.1:443" }, 0);
    try testing.expectEqualStrings(
        \\probe test
        \\kernel EPERM
        \\status ENOENT
        \\uid_map ENOENT
        \\gid_map ENOENT
        \\env.names PATH TMPDIR HOME ODD
        \\env.PATH /bb/bin
        \\env.TMPDIR.length 5
        \\cwd.length ENOENT
        \\rlimit.CPU EINVAL
        \\rlimit.AS soft=1024 hard=unlimited
        \\rlimit.FSIZE soft=1024 hard=unlimited
        \\rlimit.NOFILE soft=1024 hard=unlimited
        \\rlimit.NPROC soft=1024 hard=unlimited
        \\rlimit.CORE soft=1024 hard=unlimited
        \\cpus EPERM
        \\cgroup ENOENT
        \\root.access_w EROFS
        \\cwd.access_w EACCES
        \\cwd.create EACCES
        \\dev.fuse.exists ENOENT
        \\dev.fuse.open ENOENT
        \\net.interfaces ENOENT
        \\lo.flags EAFNOSUPPORT
        \\loopback failed at=socket EACCES
        \\egress 192.0.2.1:443 failed at=socket EACCES
        \\sysctl.user.max_user_namespaces ENOENT
        \\sysctl.kernel.unprivileged_userns_clone ENOENT
        \\sysctl.kernel.apparmor_restrict_unprivileged_userns ENOENT
        \\userns.unshare EPERM
        \\
    , out);
    try testing.expectEqual(@as(usize, 0), f.count("unshare mount"));
    try expectCleanedUp(&f);
}

/// The report's lines that start with `prefix`, joined by newlines, into `buf`.
fn linesOf(buf: []u8, report: []const u8, prefix: []const u8) []const u8 {
    var t = probe.Text{ .buf = buf };
    var it = std.mem.splitScalar(u8, report, '\n');
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, prefix)) {
            t.put(l);
            t.put("\n");
        }
    }
    return t.text();
}

/// The lines of the report starting with `prefix`, for a fake that fails `fails`; the cleanup is checked as well.
fn reportLines(fake: Fake, argv: []const [*:0]const u8, prefix: []const u8, want: []const u8) !void {
    var f = fake;
    defer f.deinit();
    const out = try runProbe(&f, argv, 0);
    var buf: [4096]u8 = undefined;
    try testing.expectEqualStrings(want, linesOf(&buf, out, prefix));
    try expectCleanedUp(&f);
}

test "loopback: the first step that fails is named with its error, and every socket opened is closed" {
    const Case = struct { fail: Fail, want: []const u8 };
    const cases = [_]Case{
        .{ .fail = .{ .key = "bind", .e = .ADDRNOTAVAIL }, .want = "loopback failed at=bind EADDRNOTAVAIL\n" },
        .{ .fail = .{ .key = "listen", .e = .OPNOTSUPP }, .want = "loopback failed at=listen EOPNOTSUPP\n" },
        .{ .fail = .{ .key = "getsockname", .e = .BADF }, .want = "loopback failed at=getsockname EBADF\n" },
        .{ .fail = .{ .key = "socket stream", .e = .MFILE, .nth = 2 }, .want = "loopback failed at=client_socket EMFILE\n" },
        .{ .fail = .{ .key = "connect stream", .e = .CONNREFUSED }, .want = "loopback failed at=connect ECONNREFUSED\n" },
        .{ .fail = .{ .key = "accept", .e = .AGAIN }, .want = "loopback failed at=accept EAGAIN\n" },
        .{ .fail = .{ .key = "write stream", .e = .PIPE }, .want = "loopback failed at=write EPIPE\n" },
        .{ .fail = .{ .key = "read accepted", .e = .CONNRESET }, .want = "loopback failed at=read ECONNRESET\n" },
    };
    for (cases) |c| try reportLines(.{ .fails = &.{c.fail} }, &.{"test"}, "loopback", c.want);
    // A byte other than the one sent is a failed read.
    try reportLines(.{ .byte = 'y' }, &.{"test"}, "loopback", "loopback failed at=read EIO\n");
}

test "lo flags: a failed ioctl, and an interface that is down" {
    try reportLines(.{ .fails = &.{.{ .key = "ioctl lo", .e = .NODEV }} }, &.{"test"}, "lo.", "lo.flags ENODEV\n");
    try reportLines(.{ .lo_up = false }, &.{"test"}, "lo.", "lo.flags up=no running=no\n");
}

test "egress: not asked for, refused at once, connected at once, timed out, or failed after the wait" {
    const e = [_][*:0]const u8{ "test", "--egress", "192.0.2.1:443" };
    try reportLines(.{}, &.{"test"}, "egress", "egress not tried (no --egress)\n");
    try reportLines(.{ .fails = &.{.{ .key = "connect nonblocking", .e = .NETUNREACH }} }, &e, "egress", "egress 192.0.2.1:443 failed at=connect ENETUNREACH\n");
    try reportLines(.{ .fails = &.{.{ .key = "poll", .e = .INTR }} }, &e, "egress", "egress 192.0.2.1:443 failed at=poll EINTR\n");
    try reportLines(.{ .ready = 0 }, &e, "egress", "egress 192.0.2.1:443 failed at=timeout ETIMEDOUT\n");
    try reportLines(.{ .fails = &.{.{ .key = "getsockopt", .e = .BADF }} }, &e, "egress", "egress 192.0.2.1:443 failed at=getsockopt EBADF\n");
    try reportLines(.{ .so_error = @intFromEnum(linux.E.CONNREFUSED) }, &e, "egress", "egress 192.0.2.1:443 failed at=connect ECONNREFUSED\n");
}

test "egress: a connect that completes at once is connected" {
    try reportLines(.{ .connect_now = true }, &.{ "test", "--egress", "192.0.2.1:443" }, "egress", "egress 192.0.2.1:443 connected\n");
}

test "user namespace: each later step is reported, or not tried when the one before it failed" {
    const argv = [_][*:0]const u8{"test"};
    try reportLines(.{ .fails = &.{.{ .key = "unshare mount", .e = .PERM }} }, &argv, "userns.", 
        \\userns.unshare ok
        \\userns.setgroups ok
        \\userns.uid_map ok
        \\userns.gid_map ok
        \\userns.uid 1000
        \\userns.write_own_file ok
        \\userns.unshare_mount EPERM
        \\
    );
    try reportLines(.{ .fails = &.{.{ .key = "mkdir farm_probe_7_mnt", .e = .ACCES }} }, &argv, "userns.mount", "userns.mount_tmpfs EACCES\n");
    try reportLines(.{ .fails = &.{.{ .key = "mount farm_probe_7_mnt", .e = .PERM }} }, &argv, "userns.mount", "userns.mount_tmpfs EPERM\n");
    try reportLines(.{ .fails = &.{
        .{ .key = "open /proc/self/setgroups", .e = .NOENT },
        .{ .key = "write /proc/self/uid_map", .e = .PERM },
        // The first open of gid_map is the read near the top of the report; the second is the write.
        .{ .key = "open /proc/self/gid_map", .e = .PERM, .nth = 2 },
    } }, &argv, "userns.", 
        \\userns.unshare ok
        \\userns.setgroups ENOENT
        \\userns.uid_map EPERM
        \\userns.gid_map EPERM
        \\userns.uid 1000
        \\userns.write_own_file ok
        \\userns.unshare_mount ok
        \\userns.mount_tmpfs ok
        \\
    );
}

test "a file of the probe's own: a failed write and a failed removal are reported, and the file is removed even after a failed write" {
    try reportLines(.{ .fails = &.{.{ .key = "write farm_probe_7.tmp", .e = .NOSPC }} }, &.{"test"}, "cwd.create", "cwd.create ENOSPC\n");
    try reportLines(.{ .fails = &.{.{ .key = "unlink farm_probe_7_userns.tmp", .e = .BUSY }} }, &.{"test"}, "userns.write", "userns.write_own_file EBUSY\n");
}

test "status: a field the kernel does not print is absent; a file that cannot be read is its error" {
    try reportLines(.{ .files = &.{.{ .path = "/proc/self/status", .text = "Uid:\t5\t5\t5\t5\nUidx:\t9\n" }} }, &.{"test"}, "status.",
        \\status.Uid 5 5 5 5
        \\status.Gid absent
        \\status.Groups absent
        \\status.CapInh absent
        \\status.CapPrm absent
        \\status.CapEff absent
        \\status.CapBnd absent
        \\status.CapAmb absent
        \\status.NoNewPrivs absent
        \\status.Seccomp absent
        \\status.Seccomp_filters absent
        \\
    );
    try reportLines(.{ .fails = &.{.{ .key = "read /proc/self/status", .e = .IO }} }, &.{"test"}, "status", "status EIO\n");
}

test "cgroup: no v2 line, a path below the namespace's root, and a path too long for the buffer" {
    try reportLines(.{ .files = &.{.{ .path = "/proc/self/cgroup", .text = "1:name=systemd:/\n" }} }, &.{"test"}, "cgroup", "cgroup no v2 line\n");
    try reportLines(.{ .files = &.{
        .{ .path = "/proc/self/cgroup", .text = "0::/a/b\n" },
        .{ .path = "/sys/fs/cgroup/a/b/memory.max", .text = "max\n" },
    } }, &.{"test"}, "cgroup",
        \\cgroup /a/b
        \\cgroup.memory.max max
        \\cgroup.memory.high ENOENT
        \\cgroup.memory.swap.max ENOENT
        \\cgroup.pids.max ENOENT
        \\cgroup.cpu.max ENOENT
        \\
    );
    const long = "0::/" ++ "d" ** 1090 ++ "\n";
    var f = Fake{ .files = &.{.{ .path = "/proc/self/cgroup", .text = long }} };
    defer f.deinit();
    const out = try runProbe(&f, &.{"test"}, 0);
    var lines: [512]u8 = undefined;
    try testing.expectEqualStrings(
        \\cgroup.memory.max ENAMETOOLONG
        \\cgroup.memory.high ENAMETOOLONG
        \\cgroup.memory.swap.max ENAMETOOLONG
        \\cgroup.pids.max ENAMETOOLONG
        \\cgroup.cpu.max ENAMETOOLONG
        \\
    , linesOf(&lines, out, "cgroup."));
    // No file of a shorter path (the namespace root's) is opened in its place.
    try testing.expectEqual(@as(usize, 0), f.count("open /sys/fs/cgroup/memory.max"));
}

test "environment: PATH and TMPDIR unset" {
    var f = Fake{};
    defer f.deinit();
    var buf: [65536]u8 = undefined;
    try testing.expectEqual(@as(u8, 0), probe.run(&f, &.{"test"}, &.{"HOME=/h"}, &buf));
    var lines: [256]u8 = undefined;
    try testing.expectEqualStrings("env.names HOME\nenv.PATH unset\nenv.TMPDIR.length unset\n", linesOf(&lines, f.written(.stdout, ""), "env."));
}

test "rlimits: soft and hard values, and a failed read" {
    try reportLines(.{ .limit = .{ .cur = 0, .max = 4096 }, .fails = &.{.{ .key = "getrlimit CORE", .e = .FAULT }} }, &.{"test"}, "rlimit.",
        \\rlimit.CPU soft=0 hard=4096
        \\rlimit.AS soft=0 hard=4096
        \\rlimit.FSIZE soft=0 hard=4096
        \\rlimit.NOFILE soft=0 hard=4096
        \\rlimit.NPROC soft=0 hard=4096
        \\rlimit.CORE EFAULT
        \\
    );
}

test "network interfaces: a line without a colon is not an interface" {
    try reportLines(.{ .files = &.{.{ .path = "/proc/net/dev", .text = "h1\nh2\nnot one\n  lo: 1\n" }} }, &.{"test"}, "net.", "net.interfaces lo\n");
}

test "a file longer than the read buffer is read up to the buffer's end" {
    var f = Fake{ .files = &.{.{ .path = "/f", .text = "abcdef" }} };
    defer f.deinit();
    var buf: [4]u8 = undefined;
    const got = probe.readFile(&f, "/f", &buf);
    try testing.expectEqualStrings("abcd", got.bytes);
    try testing.expectEqual(@as(usize, 0), f.openCount());
}

test "the command line: what usage describes is accepted, anything else is exit status 2 with the usage on stderr" {
    const good = probe.parseArgs(&full_argv).?;
    try testing.expectEqualStrings("build", good.kind);
    try testing.expectEqualStrings("report.txt", std.mem.span(good.out.?));
    try testing.expectEqualStrings("42", good.run);
    try testing.expectEqual(std.mem.nativeToBig(u16, 443), good.egress.?.port);
    try testing.expectEqual(std.mem.nativeToBig(u32, 0xc0000201), good.egress.?.addr);
    const bad = [_][]const [*:0]const u8{
        &.{},
        &.{"run"},
        &.{ "build", "--out" },
        &.{ "build", "--what", "x" },
        &.{ "build", "--egress", "192.0.2.1" },
        &.{ "build", "--egress", "192.0.2.1:http" },
        &.{ "build", "--egress", "192.0.2:443" },
    };
    for (bad) |argv| {
        try testing.expectEqual(@as(?probe.Args, null), probe.parseArgs(argv));
        var f = Fake{};
        defer f.deinit();
        _ = try runProbe(&f, argv, 2);
        try testing.expectEqualStrings(probe.usage, f.written(.stderr, ""));
        try testing.expectEqualStrings("", f.written(.stdout, ""));
    }
}

test "exit status 1: the report does not fit, stdout or --out cannot be written" {
    {
        var f = Fake{};
        defer f.deinit();
        var buf: [64]u8 = undefined;
        try testing.expectEqual(@as(u8, 1), probe.run(&f, &.{"test"}, &environ, &buf));
        try testing.expectEqualStrings("farm_probe: the report is longer than its buffer\n", f.written(.stderr, ""));
        try testing.expectEqualStrings("", f.written(.stdout, ""));
    }
    const Case = struct { fake: Fake, stderr: []const u8 };
    const cases = [_]Case{
        .{ .fake = .{ .fails = &.{.{ .key = "write stdout", .e = .PIPE }} }, .stderr = "" },
        .{ .fake = .{ .fails = &.{.{ .key = "open report.txt", .e = .ACCES }} }, .stderr = "farm_probe: cannot open --out\n" },
        .{ .fake = .{ .fails = &.{.{ .key = "write report.txt", .e = .NOSPC }} }, .stderr = "" },
    };
    for (cases) |c| {
        var f = c.fake;
        defer f.deinit();
        var buf: [65536]u8 = undefined;
        try testing.expectEqual(@as(u8, 1), probe.run(&f, &full_argv, &environ, &buf));
        try testing.expectEqualStrings(c.stderr, f.written(.stderr, ""));
        try testing.expectEqual(@as(usize, 0), f.openCount());
    }
}

test "a write that takes part of the bytes is continued; one that takes none is a failure" {
    {
        var f = Fake{ .short_write = 7 };
        defer f.deinit();
        const out = try runProbe(&f, &full_argv, 0);
        try testing.expectEqualStrings(full_report, out);
    }
    var f = Fake{ .short_write = 7, .fails = &.{.{ .key = "write stdout", .e = .SUCCESS, .nth = 2 }} };
    defer f.deinit();
    var buf: [65536]u8 = undefined;
    try testing.expectEqual(@as(u8, 1), probe.run(&f, &full_argv, &environ, &buf));
    try testing.expectEqualStrings(full_report[0..7], f.written(.stdout, ""));
}

test "an error number the kernel has no name for is printed as its number; numbers of every width" {
    var b: [64]u8 = undefined;
    var t = probe.Text{ .buf = &b };
    t.result(@bitCast(@as(isize, -4000)));
    t.put(" ");
    t.num(0);
    t.put(" ");
    t.num(18446744073709551615);
    try testing.expectEqualStrings("E4000 0 18446744073709551615", t.text());
    try testing.expect(!t.full);
    var small: [4]u8 = undefined;
    var s = probe.Text{ .buf = &small };
    s.put("abc");
    s.put("d");
    try testing.expectEqualStrings("abc", s.text());
    try testing.expect(s.full);
}

test "fuse: a device that opens is closed again" {
    var f = Fake{ .files = &.{} };
    defer f.deinit();
    _ = try runProbe(&f, &.{"test"}, 0);
    try testing.expectEqual(@as(usize, 1), f.count("open /dev/fuse"));
    try expectCleanedUp(&f);
}
