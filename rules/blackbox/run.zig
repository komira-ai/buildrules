//! `blackbox_run run`: one black-box test of a released package (README.md, defs.bzl).
//!
//!   blackbox_run run --image REF --package FILE [--sha256 HEX --size N] --work-dir DIR --service PATH [--flag ARG]...
//!                    [--fake NAME=PROGRAM [--fake-flag NAME=ARG]...]... --driver PROGRAM [--driver-flag ARG]... [--ready-s N]
//!                    [--farm | --docker DOCKER]
//!
//! In order: with `--docker`, it starts itself inside REF through DOCKER with the same arguments and exits with that run's status (nothing else happens
//! outside the image). With `--farm`, it requires to be a farm job whose frontend received REF as `container-image`, and prints the job's action digest
//! (farm.zig). It checks the package's size and sha256 when they are given, unpacks it (deb.zig) into a directory of its own in DIR (relative: to the working
//! directory; given more than once, the last),
//! gives each fake and the service a loopback port nothing listens on, puts the addresses into the flags (`{addr:NAME}` is `127.0.0.1:PORT`,
//! `{port:NAME}` the port, `{root}` the unpacked package, `{work}` the run's directory, `{{` a `{`), starts each fake and waits until its port takes a
//! connection, starts the service's program (PATH inside the package) the same way, runs the driver, and stops everything (SIGTERM to each process
//! group, SIGKILL when one is still there after `stop_ms`). Every process writes to a log of its own.
//!
//! The status is the driver's when it failed, 1 when anything else failed (a package that is not the pinned one or cannot be unpacked, a process that
//! cannot start, exits before it is ready or is not ready within `--ready-s`, or exits while the driver runs), 2 for a wrong command line, and 0 when the
//! driver passed and everything lived through it. On a failure every log is printed, each under a line naming it; on a pass only the driver's.

const std = @import("std");
const io_mod = @import("io.zig");
const deb = @import("deb.zig");
const farm = @import("farm.zig");
const probe = @import("probe.zig");

const Alloc = io_mod.Alloc;
const Oom = io_mod.Oom;
const Io = io_mod.Io;
const Pid = io_mod.Pid;

/// How long a process is given to stop after SIGTERM, and the pause between two looks at a process, in milliseconds of the platform's clock.
pub const stop_ms: u64 = 30_000;
pub const poll_ms: u64 = 20;

/// The run's directory inside docker: a tmpfs of the container (programs run from it, so it is not `noexec`).
pub const docker_work = "/blackbox-work";

/// The longest `--ready-s` (a day), and how many times a port is asked for before the run gives up finding one no other process of it has.
pub const max_ready_s: u64 = 86_400;
pub const max_port_tries: usize = 16;

/// The largest package read (a service's package is tens of MiB).
pub const max_package: usize = 1 << 31;

pub const Fake = struct { name: []const u8, program: []const u8, flags: std.ArrayList([]const u8) = .empty };

pub const Options = struct {
    image: []const u8 = "",
    package: []const u8 = "",
    sha256: ?[]const u8 = null,
    size: ?u64 = null,
    service: []const u8 = "",
    /// Where the run makes its own directory (the rule gives it; inside docker it is a private tmpfs, `docker_work`).
    work_dir: []const u8 = "",
    flags: std.ArrayList([]const u8) = .empty,
    fakes: std.ArrayList(Fake) = .empty,
    driver: []const u8 = "",
    driver_flags: std.ArrayList([]const u8) = .empty,
    ready_s: u64 = 60,
    farm: bool = false,
    docker: ?[]const u8 = null,
    /// Where `--docker` is among the arguments (what the run inside the image is given without it).
    docker_at: usize = 0,
};

fn usage(io: Io, comptime fmt: []const u8, args: anytype) ?Options {
    io.say("run: " ++ fmt, args);
    return null;
}

/// The options of `args`, or null when they are wrong (said on stderr).
pub fn parse(a: Alloc, io: Io, args: []const []const u8) Oom!?Options {
    var o = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const opt = args[i];
        if (std.mem.eql(u8, opt, "--farm")) {
            o.farm = true;
            continue;
        }
        if (i + 1 == args.len) return usage(io, "`{s}` is not an option, or it has no value", .{opt});
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, opt, "--image")) {
            o.image = v;
        } else if (std.mem.eql(u8, opt, "--package")) {
            o.package = v;
        } else if (std.mem.eql(u8, opt, "--sha256")) {
            o.sha256 = v;
        } else if (std.mem.eql(u8, opt, "--size")) {
            o.size = std.fmt.parseInt(u64, v, 10) catch return usage(io, "`--size {s}` is not a number of bytes", .{v});
        } else if (std.mem.eql(u8, opt, "--work-dir")) {
            o.work_dir = v;
        } else if (std.mem.eql(u8, opt, "--service")) {
            o.service = v;
        } else if (std.mem.eql(u8, opt, "--flag")) {
            try o.flags.append(a, v);
        } else if (std.mem.eql(u8, opt, "--fake")) {
            const eq = std.mem.indexOfScalar(u8, v, '=') orelse return usage(io, "`--fake {s}` is not NAME=PROGRAM", .{v});
            const name = v[0..eq];
            if (std.mem.eql(u8, name, "service") or findFake(o.fakes.items, name) != null) return usage(io, "the fake `{s}` is named twice, or is named `service`", .{name});
            try o.fakes.append(a, .{ .name = name, .program = v[eq + 1 ..] });
        } else if (std.mem.eql(u8, opt, "--fake-flag")) {
            const eq = std.mem.indexOfScalar(u8, v, '=') orelse return usage(io, "`--fake-flag {s}` is not NAME=ARG", .{v});
            const k = findFake(o.fakes.items, v[0..eq]) orelse return usage(io, "`--fake-flag {s}` names no fake given before it", .{v});
            try o.fakes.items[k].flags.append(a, v[eq + 1 ..]);
        } else if (std.mem.eql(u8, opt, "--driver")) {
            o.driver = v;
        } else if (std.mem.eql(u8, opt, "--driver-flag")) {
            try o.driver_flags.append(a, v);
        } else if (std.mem.eql(u8, opt, "--ready-s")) {
            o.ready_s = std.fmt.parseInt(u64, v, 10) catch return usage(io, "`--ready-s {s}` is not a number of seconds", .{v});
            if (o.ready_s == 0 or o.ready_s > max_ready_s) return usage(io, "`--ready-s` must be from 1 to {d} seconds", .{max_ready_s});
        } else if (std.mem.eql(u8, opt, "--docker")) {
            o.docker = v;
            o.docker_at = i - 1;
        } else {
            return usage(io, "`{s}` is not an option", .{opt});
        }
    }
    for ([_]struct { []const u8, []const u8 }{ .{ "--image", o.image }, .{ "--package", o.package }, .{ "--work-dir", o.work_dir }, .{ "--service", o.service }, .{ "--driver", o.driver } }) |req| {
        if (req[1].len == 0) return usage(io, "`{s}` is required", .{req[0]});
    }
    if ((o.sha256 == null) != (o.size == null)) return usage(io, "`--sha256` and `--size` go together: the package is pinned by both or by neither", .{});
    if (o.farm and o.docker != null) return usage(io, "`--farm` and `--docker` are two places to run; a run has one", .{});
    return o;
}

/// The index of the fake named `name`, or null.
fn findFake(fakes: []const Fake, name: []const u8) ?usize {
    var k: usize = 0;
    while (k < fakes.len and !std.mem.eql(u8, fakes[k].name, name)) k += 1;
    return if (k < fakes.len) k else null;
}

/// The image reference as docker takes it (no `docker://`), and as the farm's property says it (with it).
fn dockerRef(image: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, image, "docker://")) image["docker://".len..] else image;
}

/// The status of `blackbox_run run ARGS`.
pub fn run(a: Alloc, io: Io, args: []const []const u8) Oom!u8 {
    const o = (try parse(a, io, args)) orelse return 2;
    if (o.docker) |docker| return inDocker(a, io, args, o.docker_at, docker, o.image);
    if (o.farm) {
        if (!(try onFarm(a, io, o.image))) return 1;
    }
    var hex: [8]u8 = undefined;
    io.plat.randomHex(io.plat.ctx, &hex);
    const work = try std.fs.path.resolve(a, &.{ io.cwd, o.work_dir, try std.fmt.allocPrint(a, "blackbox.{s}", .{hex}) });
    // The package is read and checked before anything is written: a package that is not the pinned one leaves nothing behind.
    const bytes = std.fs.cwd().readFileAlloc(a, o.package, max_package) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            io.say("run: cannot read the package {s}: {s}", .{ o.package, @errorName(e) });
            return 1;
        },
    };
    if (o.sha256) |want| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const got = std.fmt.bytesToHex(digest, .lower);
        if (bytes.len != o.size.? or !std.mem.eql(u8, &got, want)) {
            io.say("run: the package {s} is {d} bytes of sha256 {s}, not the pinned {d} bytes of sha256 {s}", .{ o.package, bytes.len, &got, o.size.?, want });
            return 1;
        }
    }
    std.fs.cwd().makePath(work) catch |e| {
        io.say("run: cannot make the run's directory {s}: {s}", .{ work, @errorName(e) });
        return 1;
    };
    const status = withWork(a, io, o, work, bytes);
    removeWork(io, work);
    return status;
}

/// Removes the run's directory; one that cannot be removed is said, and the run's status is what it was.
fn removeWork(io: Io, work: []const u8) void {
    std.fs.cwd().deleteTree(work) catch |e| io.say("run: cannot remove the run's directory {s}: {s}", .{ work, @errorName(e) });
}

/// Starts this same program inside `image` through `docker`, with the same arguments but `--docker`, and gives that run's status. The working directory
/// is mounted read-only at its own path and is the run's working directory, so every path of the command line means what it meant here; the run has no
/// network but its loopback, and runs as this process's user.
fn inDocker(a: Alloc, io: Io, args: []const []const u8, docker_at: usize, docker: []const u8, image: []const u8) Oom!u8 {
    if (docker.len == 0 or !std.fs.path.isAbsolute(docker)) {
        io.say("run: this test runs inside {s}, and off the farm it runs there through docker: pass the absolute path of the docker program as " ++
            "`-c blackbox.docker=<path>` (`--docker` is {s})", .{ image, if (docker.len == 0) "empty" else "not an absolute path" });
        return 2;
    }
    const self = try std.fs.path.resolve(a, &.{ io.cwd, io.argv[0] });
    var argv = try std.ArrayList([]const u8).initCapacity(a, 19 + args.len);
    argv.appendSliceAssumeCapacity(&.{
        docker,                                            "run",         "--rm",  "--network", "none",
        "--user",                                          try std.fmt.allocPrint(a, "{d}:{d}", .{ io.uid, io.gid }),
        "--volume",                                        try std.fmt.allocPrint(a, "{s}:{s}:ro", .{ io.cwd, io.cwd }),
        "--tmpfs",                                         docker_work ++ ":rw,exec,nosuid",
        "--workdir",                                       io.cwd,
        "--entrypoint",                                    self,
        dockerRef(image),                                  "run",
    });
    // Every argument but the option `--docker` and its value, where the command line had them (a flag whose value is `--docker` is kept).
    argv.appendSliceAssumeCapacity(args[0..docker_at]);
    argv.appendSliceAssumeCapacity(args[docker_at + 2 ..]);
    // The checkout is read-only in there: the run's directory is the container's own tmpfs (the last `--work-dir` is the one a run takes).
    argv.appendSliceAssumeCapacity(&.{ "--work-dir", docker_work });
    var env = std.process.EnvMap.init(a);
    for (io.environ) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        try env.put(entry[0..eq], entry[eq + 1 ..]);
    }
    io.say("run: running inside {s} through {s}", .{ dockerRef(image), docker });
    return io.plat.runInherit(io.plat.ctx, a, argv.items, &env) catch |e| {
        io.say("run: cannot run {s}: {s}", .{ docker, @errorName(e) });
        return 1;
    };
}

/// True when this is a farm job whose frontend received `image` as the job's `container-image` (said, with the job's action digest); false, said, when
/// it is not.
fn onFarm(a: Alloc, io: Io, image: []const u8) Oom!bool {
    const job = (farm.read(a, io.root) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            io.say("run: the farm job's Action or Command cannot be read: {s}", .{@errorName(e)});
            return false;
        },
    }) orelse {
        io.say("run: `--farm`, but this is not a farm job: the root holds no {s}", .{farm.job_dir});
        return false;
    };
    try probe.report(a, io, job);
    const want = try std.fmt.allocPrint(a, "docker://{s}", .{dockerRef(image)});
    const got: []const u8 = if (farm.value(job.properties, "container-image")) |v| v else "";
    if (!std.mem.eql(u8, got, want)) {
        io.say("run: the job's container-image is `{s}`, not the test's `{s}`", .{ got, want });
        return false;
    }
    return true;
}

/// One process the run started: its name (a fake's, `service` or `driver`), its port (none for the driver), its log and its pid while it runs.
const Proc = struct { name: []const u8, port: u16 = 0, log: []const u8, pid: ?Pid = null };

const Run = struct {
    a: Alloc,
    io: Io,
    o: Options,
    work: []const u8,
    root: []const u8,
    procs: std.ArrayList(Proc) = .empty,
    env: std.process.EnvMap,

    fn port(r: *const Run, name: []const u8) ?u16 {
        for (r.procs.items) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.port;
        }
        return null;
    }

    /// `flag` with its placeholders replaced, or null when one is unknown (said). Allocated once: a placeholder is at least six bytes (`{root}`) and
    /// becomes at most the longest of the root, the run's directory and an address.
    fn expand(r: *const Run, flag: []const u8) Oom!?[]const u8 {
        const longest = @max(r.root.len, r.work.len, "127.0.0.1:65535".len);
        var out = try std.ArrayList(u8).initCapacity(r.a, flag.len + (flag.len / 6 + 1) * longest);
        var i: usize = 0;
        while (i < flag.len) {
            if (flag[i] != '{') {
                out.appendAssumeCapacity(flag[i]);
                i += 1;
                continue;
            }
            if (i + 1 < flag.len and flag[i + 1] == '{') {
                out.appendAssumeCapacity('{');
                i += 2;
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, flag, i, '}') orelse {
                r.io.say("run: the flag `{s}` opens a `{{` it does not close (`{{{{` is a `{{`)", .{flag});
                return null;
            };
            const p = flag[i + 1 .. end];
            i = end + 1;
            if (std.mem.eql(u8, p, "root")) {
                out.appendSliceAssumeCapacity(r.root);
                continue;
            }
            if (std.mem.eql(u8, p, "work")) {
                out.appendSliceAssumeCapacity(r.work);
                continue;
            }
            const colon = std.mem.indexOfScalar(u8, p, ':') orelse p.len;
            const kind = p[0..colon];
            const name = if (colon < p.len) p[colon + 1 ..] else "";
            const found = if (std.mem.eql(u8, kind, "addr") or std.mem.eql(u8, kind, "port")) r.port(name) else null;
            const n = found orelse {
                r.io.say("run: the flag `{s}` says `{{{s}}}`, which is not {{addr:NAME}}, {{port:NAME}}, {{root}} or {{work}} of a fake or the service", .{ flag, p });
                return null;
            };
            if (std.mem.eql(u8, kind, "addr")) out.appendSliceAssumeCapacity("127.0.0.1:");
            var digits: [5]u8 = undefined;
            out.appendSliceAssumeCapacity(digits[0..std.fmt.printInt(&digits, n, 10, .lower, .{})]);
        }
        return out.items;
    }

    fn argv(r: *const Run, program: []const u8, flags: []const []const u8) Oom!?[]const []const u8 {
        var out = try std.ArrayList([]const u8).initCapacity(r.a, flags.len + 1);
        out.appendAssumeCapacity(program);
        for (flags) |f| out.appendAssumeCapacity((try r.expand(f)) orelse return null);
        return out.items;
    }

    /// Starts the process `k` with `argv`; false (said) when it cannot be started.
    fn start(r: *Run, k: usize, cmd: []const []const u8) bool {
        const p = &r.procs.items[k];
        p.pid = r.io.plat.spawn(r.io.plat.ctx, r.a, cmd, &r.env, p.log) catch |e| {
            r.io.say("run: cannot start the {s} `{s}`: {s}", .{ p.name, cmd[0], @errorName(e) });
            return false;
        };
        return true;
    }

    /// Waits until the process `k` takes a connection on its port; false (said) when it exits first or is not ready within `--ready-s`.
    fn waitReady(r: *Run, k: usize) bool {
        const plat = r.io.plat;
        const p = &r.procs.items[k];
        const start_ms = plat.nowMs(plat.ctx);
        while (true) {
            if (plat.accepts(plat.ctx, p.port)) return true;
            if (plat.poll(plat.ctx, p.pid.?)) |status| {
                p.pid = null;
                r.io.say("run: the {s} exited {d} before it took a connection on 127.0.0.1:{d}", .{ p.name, status, p.port });
                return false;
            }
            if (plat.nowMs(plat.ctx) - start_ms >= r.o.ready_s * 1000) {
                r.io.say("run: the {s} took no connection on 127.0.0.1:{d} within {d} s", .{ p.name, p.port, r.o.ready_s });
                return false;
            }
            plat.sleepMs(plat.ctx, poll_ms);
        }
    }

    /// Stops every process still running, the last started first: SIGTERM to its group, SIGKILL to it when it is still there after `stop_ms`.
    fn stopAll(r: *Run) void {
        const plat = r.io.plat;
        var k = r.procs.items.len;
        while (k > 0) {
            k -= 1;
            const p = &r.procs.items[k];
            const pid = p.pid orelse continue;
            plat.kill(plat.ctx, pid, io_mod.sigterm);
            const start_ms = plat.nowMs(plat.ctx);
            var stopped = false;
            while (!stopped and plat.nowMs(plat.ctx) - start_ms < stop_ms) {
                stopped = plat.poll(plat.ctx, pid) != null;
                if (!stopped) plat.sleepMs(plat.ctx, poll_ms);
            }
            // What is left of the group is killed: the process itself when it did not stop, and whatever it started that outlived it.
            plat.kill(plat.ctx, pid, io_mod.sigkill);
            if (!stopped) {
                r.io.say("run: the {s} was still there {d} s after SIGTERM; it was killed", .{ p.name, stop_ms / 1000 });
                _ = plat.wait(plat.ctx, pid);
            }
            p.pid = null;
        }
    }

    /// Every log, each under a line naming it (a log nothing was written to says so).
    fn printLogs(r: *const Run) Oom!void {
        for (r.procs.items) |p| try r.printLog(p);
    }

    fn printLog(r: *const Run, p: Proc) Oom!void {
        const text = std.fs.cwd().readFileAlloc(r.a, p.log, max_package) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try std.fmt.allocPrint(r.a, "(no log: {s})\n", .{@errorName(e)}),
        };
        const nl: []const u8 = if (text.len > 0 and text[text.len - 1] != '\n') "\n" else "";
        r.io.put(try std.fmt.allocPrint(r.a, "---- the log of the {s} ----\n{s}{s}", .{ p.name, if (text.len == 0) "(empty)\n" else text, nl }));
    }

    /// Fails the run: stops what runs, prints every log, and gives `status`.
    fn failed(r: *Run, status: u8) Oom!u8 {
        r.stopAll();
        try r.printLogs();
        return status;
    }
};

/// The run of the package `bytes` in its directory `work` (made, and removed after).
fn withWork(a: Alloc, io: Io, o: Options, work: []const u8, bytes: []const u8) Oom!u8 {
    const root = try std.fs.path.join(a, &.{ work, "root" });
    const logs = try std.fs.path.join(a, &.{ work, "logs" });
    {
        var dir = std.fs.cwd().makeOpenPath(root, .{}) catch |e| {
            io.say("run: cannot make {s}: {s}", .{ root, @errorName(e) });
            return 1;
        };
        defer dir.close();
        if (try deb.unpack(a, bytes, dir)) |why| {
            io.say("run: the package {s} cannot be unpacked: {s}", .{ o.package, why });
            return 1;
        }
    }
    std.fs.cwd().makePath(logs) catch |e| {
        io.say("run: cannot make {s}: {s}", .{ logs, @errorName(e) });
        return 1;
    };
    var r = Run{ .a = a, .io = io, .o = o, .work = work, .root = root, .env = std.process.EnvMap.init(a) };
    for (io.environ) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        try r.env.put(entry[0..eq], entry[eq + 1 ..]);
    }
    // The fakes, then the service, then the driver: the order they start in, and the reverse of the order they stop in.
    try r.procs.ensureTotalCapacity(a, o.fakes.items.len + 2);
    for (o.fakes.items) |f| r.procs.appendAssumeCapacity(.{ .name = f.name, .log = try logPath(a, logs, f.name) });
    r.procs.appendAssumeCapacity(.{ .name = "service", .log = try logPath(a, logs, "service") });
    for (r.procs.items, 0..) |*p, k| {
        // A port is released once it is read, so the next one asked for can be the same: each process gets one no other process of the run has.
        var tries: usize = 0;
        p.port = while (tries < max_port_tries) : (tries += 1) {
            const port = io.plat.reservePort(io.plat.ctx);
            if (port == 0) {
                io.say("run: no loopback port could be bound for the {s}", .{p.name});
                return 1;
            }
            if (!portTaken(r.procs.items[0..k], port)) break port;
        } else {
            io.say("run: the loopback ports given for the {s} were those of the run's other processes {d} times", .{ p.name, max_port_tries });
            return 1;
        };
    }
    r.procs.appendAssumeCapacity(.{ .name = "driver", .log = try logPath(a, logs, "driver") });
    const driver_k = r.procs.items.len - 1;
    const service_k = driver_k - 1;

    // Every command line first: a flag that names nothing fails the run before anything starts.
    const cmds = try a.alloc([]const []const u8, r.procs.items.len);
    for (o.fakes.items, 0..) |f, k| cmds[k] = (try r.argv(f.program, f.flags.items)) orelse return 2;
    cmds[service_k] = (try r.argv(try std.fs.path.join(a, &.{ root, o.service }), o.flags.items)) orelse return 2;
    cmds[driver_k] = (try r.argv(o.driver, o.driver_flags.items)) orelse return 2;

    for (0..driver_k) |k| {
        if (!r.start(k, cmds[k]) or !r.waitReady(k)) return try r.failed(1);
    }
    if (!r.start(driver_k, cmds[driver_k])) return try r.failed(1);
    const status = io.plat.wait(io.plat.ctx, r.procs.items[driver_k].pid.?);
    r.procs.items[driver_k].pid = null;
    var gone = false;
    for (r.procs.items[0 .. service_k + 1]) |*p| {
        if (io.plat.poll(io.plat.ctx, p.pid.?)) |s| {
            p.pid = null;
            io.say("run: the {s} exited {d} while the driver ran", .{ p.name, s });
            gone = true;
        }
    }
    if (status != 0) {
        io.say("run: the driver exited {d}", .{status});
        return try r.failed(status);
    }
    if (gone) return try r.failed(1);
    r.stopAll();
    try r.printLog(r.procs.items[driver_k]);
    io.say("run: passed: the driver exited 0 and the {d} fake(s) and the service lived through it", .{o.fakes.items.len});
    return 0;
}

fn portTaken(procs: []const Proc, port: u16) bool {
    for (procs) |p| {
        if (p.port == port) return true;
    }
    return false;
}

fn logPath(a: Alloc, logs: []const u8, name: []const u8) Oom![]const u8 {
    return std.fs.path.join(a, &.{ logs, try std.fmt.allocPrint(a, "{s}.log", .{name}) });
}
