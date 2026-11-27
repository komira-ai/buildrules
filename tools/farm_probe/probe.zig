//! farm_probe: what an action may do where it runs. It prints one `<name> <value>` line per fact (tools/farm_probe/README.md lists
//! them) and never fails because of what it finds: a refused call is a value (`EPERM`), not an error. It only reads its own status and
//! makes the system calls a build might make; every file and directory it creates is in its working directory, named
//! `farm_probe_<pid>...`, and removed again; its one mount is in a mount namespace of its own, which ends with the process.
//!
//! Every system call goes through `os`, a value with one method per call that returns the kernel's raw result (main.zig: the kernel;
//! probe_test.zig: a fake), so each outcome of each step is driven by the unit tests.

const std = @import("std");
const linux = std.os.linux;

/// Text built in a fixed buffer. Nothing it does fails: what does not fit is dropped and `full` says so. The last byte is kept for
/// the NUL of `z`.
pub const Text = struct {
    buf: []u8,
    n: usize = 0,
    full: bool = false,

    pub fn put(t: *Text, bytes: []const u8) void {
        if (t.n + bytes.len >= t.buf.len) {
            t.full = true;
            return;
        }
        @memcpy(t.buf[t.n..][0..bytes.len], bytes);
        t.n += bytes.len;
    }

    /// `v` in decimal.
    pub fn num(t: *Text, v: u64) void {
        var digits: [20]u8 = undefined;
        var i: usize = digits.len;
        var x = v;
        while (true) {
            i -= 1;
            digits[i] = '0' + @as(u8, @intCast(x % 10));
            x /= 10;
            if (x == 0) break;
        }
        t.put(digits[i..]);
    }

    /// A raw result's error name (`EACCES`), `ok` for none, `E<number>` for a number the kernel has no name for here.
    pub fn result(t: *Text, rc: usize) void {
        const e = linux.E.init(rc);
        if (e == .SUCCESS) return t.put("ok");
        t.put("E");
        if (std.enums.tagName(linux.E, e)) |name| t.put(name) else t.num(@intFromEnum(e));
    }

    pub fn text(t: *const Text) []const u8 {
        return t.buf[0..t.n];
    }

    /// The text as a NUL-terminated path.
    pub fn z(t: *Text) [*:0]const u8 {
        t.buf[t.n] = 0;
        return t.buf[0..t.n :0].ptr;
    }
};

/// What the command line asks for.
pub const Args = struct {
    /// `build` or `test`: which kind of action runs the probe, printed on the first line.
    kind: []const u8,
    /// Where the report is also written (a build action's output); null: stdout only.
    out: ?[*:0]const u8 = null,
    /// The one outside address to try a TCP connect to; null: not tried.
    egress: ?linux.sockaddr.in = null,
    /// The text of `--egress`, printed with its result.
    egress_text: []const u8 = "",
    /// Printed and otherwise unused: a new value is a new command line, so the build action runs again instead of being a cache hit.
    run: []const u8 = "",
};

pub const usage = "usage: farm_probe build|test [--out FILE] [--egress A.B.C.D:PORT] [--run ID]\n";

/// The command line after the program's name, or null when it is not one `usage` describes.
pub fn parseArgs(argv: []const [*:0]const u8) ?Args {
    if (argv.len == 0) return null;
    const kind = std.mem.span(argv[0]);
    if (!std.mem.eql(u8, kind, "build") and !std.mem.eql(u8, kind, "test")) return null;
    var args = Args{ .kind = kind };
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        if (i + 1 == argv.len) return null;
        const flag = std.mem.span(argv[i]);
        const value = argv[i + 1];
        if (std.mem.eql(u8, flag, "--out")) {
            args.out = value;
        } else if (std.mem.eql(u8, flag, "--egress")) {
            args.egress_text = std.mem.span(value);
            args.egress = parseAddress(args.egress_text) orelse return null;
        } else if (std.mem.eql(u8, flag, "--run")) {
            args.run = std.mem.span(value);
        } else return null;
    }
    return args;
}

/// `A.B.C.D:PORT` as a socket address, or null.
pub fn parseAddress(text: []const u8) ?linux.sockaddr.in {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return null;
    const address = std.net.Address.parseIp4(text[0..colon], port) catch return null;
    return address.in.sa;
}

fn failed(rc: usize) bool {
    return linux.E.init(rc) != .SUCCESS;
}

/// The raw result of a call that failed with `e`.
fn errRc(e: u16) usize {
    return @bitCast(-@as(isize, e));
}

/// The fd of a successful open, socket or accept.
fn fdOf(rc: usize) i32 {
    return @intCast(rc);
}

/// One line: `name value`.
fn line(out: *Text, name: []const u8, value: []const u8) void {
    out.put(name);
    out.put(" ");
    out.put(value);
    out.put("\n");
}

/// One line whose value is a raw result's name.
fn resultLine(out: *Text, name: []const u8, rc: usize) void {
    out.put(name);
    out.put(" ");
    out.result(rc);
    out.put("\n");
}

/// The words of `text` (split at spaces, tabs and newlines) joined by one space.
pub fn words(out: *Text, text: []const u8) void {
    var it = std.mem.tokenizeAny(u8, text, " \t\n");
    var first = true;
    while (it.next()) |word| {
        if (!first) out.put(" ");
        out.put(word);
        first = false;
    }
}

pub const Read = union(enum) { bytes: []const u8, failed: usize };

/// The bytes of a small file (what fits in `buf`), or the raw result of the open or read that failed.
pub fn readFile(os: anytype, path: [*:0]const u8, buf: []u8) Read {
    const rc = os.open(path, .{ .CLOEXEC = true }, 0);
    if (failed(rc)) return .{ .failed = rc };
    const fd = fdOf(rc);
    defer _ = os.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const got = os.read(fd, buf[n..]);
        if (failed(got)) return .{ .failed = got };
        if (got == 0) break;
        n += got;
    }
    return .{ .bytes = buf[0..n] };
}

/// One line with a file's words, or the error that stopped the read.
fn fileLine(os: anytype, out: *Text, name: []const u8, path: [*:0]const u8) void {
    var buf: [4096]u8 = undefined;
    switch (readFile(os, path, &buf)) {
        .bytes => |bytes| {
            out.put(name);
            out.put(" ");
            words(out, bytes);
            out.put("\n");
        },
        .failed => |rc| resultLine(out, name, rc),
    }
}

/// The fields of /proc/self/status the report prints, in this order.
pub const status_fields = [_][]const u8{ "Uid", "Gid", "Groups", "CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb", "NoNewPrivs", "Seccomp", "Seccomp_filters" };

/// The value of `field` in the text of a status file (`Uid:\t0\t0\t0\t0` gives `\t0\t0\t0\t0`), or null when it has none.
pub fn statusField(text: []const u8, field: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (l.len > field.len and std.mem.startsWith(u8, l, field) and l[field.len] == ':') return l[field.len + 1 ..];
    }
    return null;
}

fn status(os: anytype, out: *Text) void {
    var buf: [8192]u8 = undefined;
    switch (readFile(os, "/proc/self/status", &buf)) {
        .bytes => |text| for (status_fields) |field| {
            out.put("status.");
            out.put(field);
            out.put(" ");
            if (statusField(text, field)) |value| {
                const before = out.n;
                words(out, value);
                if (out.n == before) out.put("none");
            } else out.put("absent");
            out.put("\n");
        },
        .failed => |rc| resultLine(out, "status", rc),
    }
}

/// The interface names of a /proc/net/dev text (its two header lines skipped), joined by one space.
pub fn interfaces(out: *Text, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next();
    _ = lines.next();
    var first = true;
    while (lines.next()) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
        if (!first) out.put(" ");
        out.put(std.mem.trim(u8, l[0..colon], " "));
        first = false;
    }
}

fn network(os: anytype, out: *Text) void {
    var buf: [4096]u8 = undefined;
    switch (readFile(os, "/proc/net/dev", &buf)) {
        .bytes => |text| {
            out.put("net.interfaces ");
            interfaces(out, text);
            out.put("\n");
        },
        .failed => |rc| resultLine(out, "net.interfaces", rc),
    }
}

fn kernel(os: anytype, out: *Text) void {
    var uts: linux.utsname = undefined;
    const rc = os.uname(&uts);
    if (failed(rc)) return resultLine(out, "kernel", rc);
    line(out, "kernel", std.mem.sliceTo(&uts.release, 0));
    line(out, "machine", std.mem.sliceTo(&uts.machine, 0));
}

/// The rlimits the report prints, in this order.
pub const rlimits = [_]linux.rlimit_resource{ .CPU, .AS, .FSIZE, .NOFILE, .NPROC, .CORE };

fn limitValue(out: *Text, v: linux.rlim_t) void {
    if (v == linux.RLIM.INFINITY) return out.put("unlimited");
    out.num(v);
}

fn limits(os: anytype, out: *Text) void {
    for (rlimits) |res| {
        out.put("rlimit.");
        out.put(@tagName(res));
        out.put(" ");
        var lim: linux.rlimit = undefined;
        const rc = os.getrlimit(res, &lim);
        if (failed(rc)) {
            out.result(rc);
        } else {
            out.put("soft=");
            limitValue(out, lim.cur);
            out.put(" hard=");
            limitValue(out, lim.max);
        }
        out.put("\n");
    }
}

fn cpus(os: anytype, out: *Text) void {
    var set: linux.cpu_set_t = undefined;
    const rc = os.affinity(&set);
    if (failed(rc)) return resultLine(out, "cpus", rc);
    var n: u64 = 0;
    for (set) |word| n += @popCount(word);
    out.put("cpus ");
    out.num(n);
    out.put("\n");
}

/// The cgroup files the report prints, in this order.
pub const cgroup_files = [_][]const u8{ "memory.max", "memory.high", "memory.swap.max", "pids.max", "cpu.max" };

/// The cgroup v2 path of a /proc/self/cgroup text (`0::/a/b` gives `/a/b`), or null when it has no v2 line.
pub fn cgroupPath(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "0::")) return l[3..];
    }
    return null;
}

fn cgroup(os: anytype, out: *Text) void {
    var buf: [4096]u8 = undefined;
    const text = switch (readFile(os, "/proc/self/cgroup", &buf)) {
        .bytes => |bytes| bytes,
        .failed => |rc| return resultLine(out, "cgroup", rc),
    };
    const path = cgroupPath(text) orelse return line(out, "cgroup", "no v2 line");
    line(out, "cgroup", path);
    // A path of "/" is the cgroup namespace's root: the action's own cgroup is the whole of /sys/fs/cgroup.
    const dir = if (std.mem.eql(u8, path, "/")) "" else path;
    for (cgroup_files) |file| {
        var full: [1100]u8 = undefined;
        var at = Text{ .buf = &full };
        at.put("/sys/fs/cgroup");
        at.put(dir);
        at.put("/");
        at.put(file);
        var key: [40]u8 = undefined;
        var name = Text{ .buf = &key };
        name.put("cgroup.");
        name.put(file);
        if (at.full) {
            resultLine(out, name.text(), errRc(@intFromEnum(linux.E.NAMETOOLONG)));
        } else fileLine(os, out, name.text(), at.z());
    }
}

/// The names of the environment's variables in the order given, the value of PATH, and the length of TMPDIR (its value is a path of
/// the worker, which the report leaves out).
fn env(out: *Text, environ: []const [*:0]const u8) void {
    out.put("env.names");
    var path: ?[]const u8 = null;
    var tmpdir: ?[]const u8 = null;
    for (environ) |entry| {
        const text = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, text, '=') orelse text.len;
        const name = text[0..eq];
        const value = text[@min(eq + 1, text.len)..];
        out.put(" ");
        out.put(name);
        if (std.mem.eql(u8, name, "PATH")) path = value;
        if (std.mem.eql(u8, name, "TMPDIR")) tmpdir = value;
    }
    out.put("\n");
    line(out, "env.PATH", path orelse "unset");
    out.put("env.TMPDIR.length ");
    if (tmpdir) |t| out.num(t.len) else out.put("unset");
    out.put("\n");
}

fn cwd(os: anytype, out: *Text) void {
    var buf: [4096]u8 = undefined;
    const rc = os.getcwd(&buf);
    if (failed(rc)) return resultLine(out, "cwd.length", rc);
    // The kernel's length counts the terminating NUL.
    out.put("cwd.length ");
    out.num(rc - 1);
    out.put("\n");
}

/// A name in the working directory for the probe's own files: `farm_probe_<pid><suffix>`.
fn ownName(buf: []u8, pid: i32, suffix: []const u8) [*:0]const u8 {
    var t = Text{ .buf = buf };
    t.put("farm_probe_");
    t.num(@intCast(pid));
    t.put(suffix);
    return t.z();
}

/// Writable: `access(W_OK)` of the root and of the working directory (EROFS is a read-only mount, EACCES a writable mount the user may
/// not write), then a file made, written and removed in the working directory.
fn files(os: anytype, out: *Text, pid: i32) void {
    resultLine(out, "root.access_w", os.access("/", linux.W_OK));
    resultLine(out, "cwd.access_w", os.access(".", linux.W_OK));
    var name: [48]u8 = undefined;
    resultLine(out, "cwd.create", writeOwnFile(os, ownName(&name, pid, ".tmp")));
}

/// Makes `path` (it must not exist), writes one byte, closes it and removes it: the raw result of the first failed step, else 0.
fn writeOwnFile(os: anytype, path: [*:0]const u8) usize {
    const rc = os.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600);
    if (failed(rc)) return rc;
    const fd = fdOf(rc);
    const wrote = os.write(fd, "x");
    _ = os.close(fd);
    const removed = os.unlink(path);
    if (failed(wrote)) return wrote;
    return removed;
}

fn fuse(os: anytype, out: *Text) void {
    resultLine(out, "dev.fuse.exists", os.access("/dev/fuse", linux.F_OK));
    const rc = os.open("/dev/fuse", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (!failed(rc)) _ = os.close(fdOf(rc));
    resultLine(out, "dev.fuse.open", rc);
}

/// The flags of `lo` (SIOCGIFFLAGS on a socket of its own).
fn loFlags(os: anytype, out: *Text) void {
    const s = os.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (failed(s)) return resultLine(out, "lo.flags", s);
    const fd = fdOf(s);
    defer _ = os.close(fd);
    var req = std.mem.zeroes(linux.ifreq);
    @memcpy(req.ifrn.name[0..2], "lo");
    const rc = os.ioctl(fd, linux.SIOCGIFFLAGS, &req);
    if (failed(rc)) return resultLine(out, "lo.flags", rc);
    out.put("lo.flags up=");
    out.put(yesNo(req.ifru.flags.UP));
    out.put(" running=");
    out.put(yesNo(req.ifru.flags.RUNNING));
    out.put("\n");
}

fn yesNo(b: bool) []const u8 {
    return if (b) "yes" else "no";
}

/// A listener on 127.0.0.1 port 0, a client that connects to it, one byte from the client read by the accepted socket: `loopback ok`, or
/// the step that failed and its result.
fn loopback(os: anytype, out: *Text) void {
    var fds: [3]i32 = .{ -1, -1, -1 };
    const step, const rc = loopbackSteps(os, &fds);
    for (fds) |fd| {
        if (fd >= 0) _ = os.close(fd);
    }
    if (!failed(rc)) return line(out, "loopback", "ok");
    out.put("loopback failed at=");
    out.put(step);
    out.put(" ");
    out.result(rc);
    out.put("\n");
}

fn loopbackSteps(os: anytype, fds: *[3]i32) struct { []const u8, usize } {
    const s = os.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (failed(s)) return .{ "socket", s };
    fds[0] = fdOf(s);
    var addr = linux.sockaddr.in{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    var rc = os.bind(fds[0], &addr);
    if (failed(rc)) return .{ "bind", rc };
    rc = os.listen(fds[0], 1);
    if (failed(rc)) return .{ "listen", rc };
    rc = os.getsockname(fds[0], &addr);
    if (failed(rc)) return .{ "getsockname", rc };
    const c = os.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (failed(c)) return .{ "client_socket", c };
    fds[1] = fdOf(c);
    rc = os.connect(fds[1], &addr);
    if (failed(rc)) return .{ "connect", rc };
    const a = os.accept(fds[0]);
    if (failed(a)) return .{ "accept", a };
    fds[2] = fdOf(a);
    rc = os.write(fds[1], "x");
    if (failed(rc)) return .{ "write", rc };
    var byte: [1]u8 = .{0};
    rc = os.read(fds[2], &byte);
    if (failed(rc)) return .{ "read", rc };
    if (byte[0] != 'x') return .{ "read", errRc(@intFromEnum(linux.E.IO)) };
    return .{ "", 0 };
}

/// How long the outside connect may wait for an answer, in milliseconds: a dropped SYN is reported as a timeout, not waited out.
pub const egress_wait_ms = 5000;

/// One TCP connect to the address of `--egress`: `connected`, the error (`ENETUNREACH`, `ECONNREFUSED`), or a timeout.
fn egress(os: anytype, out: *Text, args: Args) void {
    const addr = args.egress orelse return line(out, "egress", "not tried (no --egress)");
    out.put("egress ");
    out.put(args.egress_text);
    out.put(" ");
    const step, const rc = egressSteps(os, &addr);
    if (!failed(rc)) {
        out.put(step);
    } else {
        out.put("failed at=");
        out.put(step);
        out.put(" ");
        out.result(rc);
    }
    out.put("\n");
}

/// The step that ended the connect and its raw result: `connected` and 0, `timeout` and ETIMEDOUT, or the step that failed.
fn egressSteps(os: anytype, addr: *const linux.sockaddr.in) struct { []const u8, usize } {
    const s = os.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
    if (failed(s)) return .{ "socket", s };
    const fd = fdOf(s);
    defer _ = os.close(fd);
    const rc = os.connect(fd, addr);
    if (!failed(rc)) return .{ "connected", 0 };
    if (linux.E.init(rc) != .INPROGRESS) return .{ "connect", rc };
    var pfd = [1]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
    const ready = os.poll(&pfd, egress_wait_ms);
    if (failed(ready)) return .{ "poll", ready };
    if (ready == 0) return .{ "timeout", errRc(@intFromEnum(linux.E.TIMEDOUT)) };
    var err: i32 = 0;
    const got = os.sockError(fd, &err);
    if (failed(got)) return .{ "getsockopt", got };
    if (err != 0) return .{ "connect", errRc(@intCast(err)) };
    return .{ "connected", 0 };
}

/// The settings that decide whether an unprivileged user namespace may be made, where the kernel has them.
pub const userns_settings = [_][2][:0]const u8{
    .{ "sysctl.user.max_user_namespaces", "/proc/sys/user/max_user_namespaces" },
    .{ "sysctl.kernel.unprivileged_userns_clone", "/proc/sys/kernel/unprivileged_userns_clone" },
    .{ "sysctl.kernel.apparmor_restrict_unprivileged_userns", "/proc/sys/kernel/apparmor_restrict_unprivileged_userns" },
};

/// The last step, as it changes the process: a user namespace of its own, with uid and gid 0 mapped to the probe's; in it, a file
/// made, written and removed in the working directory; then a mount namespace and a tmpfs mounted on a new directory there and taken
/// down. The mount namespace is the probe's alone and ends with it.
fn userns(os: anytype, out: *Text, pid: i32) void {
    for (userns_settings) |s| fileLine(os, out, s[0], s[1]);
    const uid = os.getuid();
    const gid = os.getgid();
    const rc = os.unshare(linux.CLONE.NEWUSER);
    resultLine(out, "userns.unshare", rc);
    if (failed(rc)) return;
    resultLine(out, "userns.setgroups", writeProc(os, "/proc/self/setgroups", "deny"));
    var map: [32]u8 = undefined;
    resultLine(out, "userns.uid_map", writeProc(os, "/proc/self/uid_map", mapLine(&map, uid)));
    resultLine(out, "userns.gid_map", writeProc(os, "/proc/self/gid_map", mapLine(&map, gid)));
    out.put("userns.uid ");
    out.num(os.getuid());
    out.put("\n");
    var name: [48]u8 = undefined;
    resultLine(out, "userns.write_own_file", writeOwnFile(os, ownName(&name, pid, "_userns.tmp")));
    const ns = os.unshare(linux.CLONE.NEWNS);
    resultLine(out, "userns.unshare_mount", ns);
    if (failed(ns)) return;
    const dir = ownName(&name, pid, "_mnt");
    const made = os.mkdir(dir, 0o700);
    if (failed(made)) return resultLine(out, "userns.mount_tmpfs", made);
    const mounted = os.mount("tmpfs", dir, "tmpfs", linux.MS.NOSUID | linux.MS.NODEV, "size=1m");
    resultLine(out, "userns.mount_tmpfs", mounted);
    if (!failed(mounted)) _ = os.umount(dir);
    _ = os.rmdir(dir);
}

/// `0 <id> 1`: id 0 of the namespace is `id` outside it.
fn mapLine(buf: []u8, id: u32) []const u8 {
    var t = Text{ .buf = buf };
    t.put("0 ");
    t.num(id);
    t.put(" 1");
    return t.text();
}

/// Writes `text` to a file of /proc that takes one write.
fn writeProc(os: anytype, path: [*:0]const u8, text: []const u8) usize {
    const rc = os.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (failed(rc)) return rc;
    const fd = fdOf(rc);
    const wrote = os.write(fd, text);
    _ = os.close(fd);
    if (failed(wrote)) return wrote;
    return 0;
}

/// The whole report, in the order tools/farm_probe/README.md lists it.
pub fn report(os: anytype, out: *Text, args: Args, environ: []const [*:0]const u8) void {
    line(out, "probe", args.kind);
    if (args.run.len > 0) line(out, "run", args.run);
    kernel(os, out);
    status(os, out);
    fileLine(os, out, "uid_map", "/proc/self/uid_map");
    fileLine(os, out, "gid_map", "/proc/self/gid_map");
    env(out, environ);
    cwd(os, out);
    limits(os, out);
    cpus(os, out);
    cgroup(os, out);
    const pid = os.getpid();
    files(os, out, pid);
    fuse(os, out);
    network(os, out);
    loFlags(os, out);
    loopback(os, out);
    egress(os, out, args);
    userns(os, out, pid);
}

/// The program, its report built in `buf`: the report on stdout, and in `--out` when given. 0; 2 for a command line `usage` does not
/// describe; 1 when the report did not fit in `buf` or could not be written.
pub fn run(os: anytype, argv: []const [*:0]const u8, environ: []const [*:0]const u8, buf: []u8) u8 {
    const args = parseArgs(argv) orelse {
        _ = os.write(2, usage);
        return 2;
    };
    var out = Text{ .buf = buf };
    report(os, &out, args, environ);
    if (out.full) {
        _ = os.write(2, "farm_probe: the report is longer than its buffer\n");
        return 1;
    }
    if (!writeAll(os, 1, out.text())) return 1;
    const path = args.out orelse return 0;
    const rc = os.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
    if (failed(rc)) {
        _ = os.write(2, "farm_probe: cannot open --out\n");
        return 1;
    }
    const fd = fdOf(rc);
    const ok = writeAll(os, fd, out.text());
    _ = os.close(fd);
    return if (ok) 0 else 1;
}

fn writeAll(os: anytype, fd: i32, bytes: []const u8) bool {
    var n: usize = 0;
    while (n < bytes.len) {
        const rc = os.write(fd, bytes[n..]);
        if (failed(rc) or rc == 0) return false;
        n += rc;
    }
    return true;
}
