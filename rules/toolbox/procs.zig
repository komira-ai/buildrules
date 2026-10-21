//! The applets about the environment: `env` and `printenv`.

const std = @import("std");
const io_mod = @import("io.zig");
const Io = io_mod.Io;
const Alloc = io_mod.Alloc;
const Buf = io_mod.Buf;
const Strings = io_mod.Strings;
const describe = io_mod.describe;

/// Where `env` looks for a command that has no `/` when the environment it builds has no PATH.
const default_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

/// The name of an `NAME=VALUE` entry: what is before the first `=`.
fn nameOf(entry: []const u8) []const u8 {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse entry.len;
    return entry[0..eq];
}

/// The entries of `list` without those named `name`.
fn without(list: *Strings, name: []const u8) void {
    var kept: usize = 0;
    for (list.list.items) |entry| {
        if (!std.mem.eql(u8, nameOf(entry), name)) {
            list.list.items[kept] = entry;
            kept += 1;
        }
    }
    list.list.shrinkRetainingCapacity(kept);
}

/// The value of `name` among the entries, the first of that name; null when there is none.
fn lookup(entries: []const []const u8, name: []const u8) ?[]const u8 {
    for (entries) |entry| {
        if (entry.len > name.len and entry[name.len] == '=' and std.mem.eql(u8, entry[0..name.len], name)) {
            return entry[name.len + 1 ..];
        }
    }
    return null;
}

/// The path of `command` as `execvp` finds it in `path` (a `:`-separated list; an empty element is the current directory): the first
/// element holding an executable file of that name. Null when there is none.
fn search(a: Alloc, path: []const u8, command: []const u8) ?[]const u8 {
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        const candidate = io_mod.join(a, &.{ if (dir.len == 0) "." else dir, command });
        if (std.posix.access(candidate, std.posix.X_OK)) |_| {
            return candidate;
        } else |_| {}
    }
    return null;
}

/// `env [-i] [-u NAME]... [NAME=VALUE]... [COMMAND [ARG]...]`: with a command, runs it in the environment that is the process's own
/// without those named by -u (all of it with -i) and with the assignments, and exits with its status; a command with no `/` is looked for
/// in the PATH of that environment. Without a command, writes the environment, one `NAME=VALUE` a line.
pub fn env(a: Alloc, io: Io, args: []const []const u8) u8 {
    var entries = Strings{ .a = a };
    var unset = Strings{ .a = a };
    var clear = false;
    var i: usize = 0;
    // The options come first, and an option may follow another; -i empties the environment whatever its place among them.
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "-i")) {
            clear = true;
        } else if (std.mem.eql(u8, args[i], "-u") and i + 1 < args.len) {
            i += 1;
            unset.add(args[i]);
        } else {
            io.say("env", &.{ "invalid option '", args[i], "'" });
            return 125;
        }
    }
    if (!clear) {
        for (io.environ) |entry| entries.add(entry);
    }
    for (unset.list.items) |name| without(&entries, name);
    while (i < args.len and std.mem.indexOfScalar(u8, args[i], '=') != null) : (i += 1) {
        without(&entries, nameOf(args[i]));
        entries.add(args[i]);
    }
    if (i == args.len) {
        var out = Buf{ .a = a };
        for (entries.list.items) |entry| {
            out.add(entry);
            out.byte('\n');
        }
        return if (io.put(out.list.items)) 0 else 1;
    }
    return runCommand(a, io, entries.list.items, args[i..]);
}

/// Runs `argv` with exactly `entries` as its environment, in the working directory, and returns its status: 127 when the command is not
/// there, 126 when it cannot be run.
fn runCommand(a: Alloc, io: Io, entries: []const []const u8, argv: []const []const u8) u8 {
    var map = std.process.EnvMap.init(a);
    for (entries) |entry| {
        const name = nameOf(entry);
        if (name.len < entry.len) putEnv(&map, name, entry[name.len + 1 ..]);
    }
    var program = argv[0];
    if (std.mem.indexOfScalar(u8, program, '/') == null) {
        program = search(a, lookup(entries, "PATH") orelse default_path, program) orelse return notRun(io, argv[0], "No such file or directory", 127);
    }
    var full = Strings{ .a = a };
    full.add(program);
    for (argv[1..]) |arg| full.add(arg);
    // What the command writes goes after what was written before it.
    io.out.flush() catch {};
    return io.spawn(a, full.list.items, &map, here(a, io)) catch |err| notRun(io, argv[0], describe(err), if (err == error.FileNotFound) 127 else 126);
}

fn putEnv(map: *std.process.EnvMap, name: []const u8, value: []const u8) void {
    map.put(name, value) catch io_mod.oom();
}

/// The absolute path of the working directory.
fn here(a: Alloc, io: Io) []const u8 {
    return io.cwd.realpathAlloc(a, ".") catch io_mod.oom();
}

fn notRun(io: Io, name: []const u8, why: []const u8, status: u8) u8 {
    io.say("env", &.{ "can't execute '", name, "': ", why });
    return status;
}

/// `printenv [NAME]...`: with names, the value of each, a line each; the status is 1 if one is not set. Without, the whole environment.
pub fn printenv(a: Alloc, io: Io, args: []const []const u8) u8 {
    var out = Buf{ .a = a };
    var status: u8 = 0;
    if (args.len == 0) {
        for (io.environ) |entry| {
            out.add(entry);
            out.byte('\n');
        }
    }
    for (args) |name| {
        if (lookup(io.environ, name)) |value| {
            out.add(value);
            out.byte('\n');
        } else {
            status = 1;
        }
    }
    return if (!io.put(out.list.items)) 1 else status;
}
