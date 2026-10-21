//! toolbox: the small programs a test expects on its PATH, as one executable (README.md).
//!
//! One program, named by how it is called: a link named `rm` (or any applet) runs that applet, and `toolbox <applet> ARG...` runs it by name.
//! The applets are rm, mkdir, sleep, echo, cat, env, printenv, true and false, each as the C library tools of the same names behave for the
//! arguments the tests use. `toolbox --list` writes their names, one a line. A name that is none of them is `applet not found` (exit 127).
//!
//! `main` only gathers the process's own streams, arguments and environment and calls `entry`, which holds everything else; the tests call
//! `entry` as main does.

const std = @import("std");
const io_mod = @import("io.zig");
const files = @import("files.zig");
const text = @import("text.zig");
const procs = @import("procs.zig");
const Io = io_mod.Io;
const Alloc = io_mod.Alloc;

fn yes(_: Alloc, _: Io, _: []const []const u8) u8 {
    return 0;
}

fn no(_: Alloc, _: Io, _: []const []const u8) u8 {
    return 1;
}

const Applet = struct {
    name: []const u8,
    run: *const fn (Alloc, Io, []const []const u8) u8,
};

pub const applets = [_]Applet{
    .{ .name = "rm", .run = files.rm },
    .{ .name = "mkdir", .run = files.mkdir },
    .{ .name = "sleep", .run = text.sleep },
    .{ .name = "echo", .run = text.echo },
    .{ .name = "cat", .run = text.cat },
    .{ .name = "env", .run = procs.env },
    .{ .name = "printenv", .run = procs.printenv },
    .{ .name = "true", .run = yes },
    .{ .name = "false", .run = no },
};

/// `args` is the command line with the program's name first. The applet is that name's last component, or, when that is `toolbox`, the
/// first argument.
pub fn entry(a: Alloc, io: Io, args: []const []const u8) u8 {
    const program = if (args.len > 0) std.fs.path.basename(args[0]) else "toolbox";
    var rest: []const []const u8 = if (args.len > 0) args[1..] else args;
    var name = program;
    if (std.mem.eql(u8, program, "toolbox")) {
        if (rest.len == 0) {
            io.say("toolbox", &.{"usage: toolbox APPLET [ARG]... (or run through a link named for the applet); --list names them"});
            return 1;
        }
        name = rest[0];
        rest = rest[1..];
        if (std.mem.eql(u8, name, "--list")) return list(a, io);
    }
    for (applets) |applet| {
        if (std.mem.eql(u8, applet.name, name)) return applet.run(a, io, rest);
    }
    io.say("toolbox", &.{ "applet not found: ", name });
    return 127;
}

fn list(a: Alloc, io: Io) u8 {
    var out = io_mod.Buf{ .a = a };
    for (applets) |applet| {
        out.add(applet.name);
        out.byte('\n');
    }
    return if (io.put(out.list.items)) 0 else 1;
}

fn realSpawn(a: Alloc, argv: []const []const u8, env: *const std.process.EnvMap, cwd: []const u8) anyerror!u8 {
    var child = std.process.Child.init(argv, a);
    child.env_map = env;
    child.cwd = cwd;
    return io_mod.statusOf(try child.spawnAndWait());
}

fn realSleep(ns: u64) void {
    std.Thread.sleep(ns);
}

pub fn main() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = std.process.argsAlloc(a) catch io_mod.oom();
    const environ = a.alloc([]const u8, std.os.environ.len) catch io_mod.oom();
    for (std.os.environ, 0..) |entry_z, k| environ[k] = std.mem.span(entry_z);
    var out_buf: [16384]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);
    var err_buf: [0]u8 = undefined;
    var err = std.fs.File.stderr().writer(&err_buf);
    var in_buf: [16384]u8 = undefined;
    var in = std.fs.File.stdin().reader(&in_buf);
    const io = Io{
        .a = a,
        .out = &out.interface,
        .err = &err.interface,
        .in = &in.interface,
        .cwd = std.fs.cwd(),
        .environ = environ,
        .sleep = realSleep,
        .spawn = realSpawn,
    };
    const status = entry(a, io, argv);
    // A status that is a success is a failure when what was written could not be flushed.
    io.out.flush() catch return 1;
    return status;
}
