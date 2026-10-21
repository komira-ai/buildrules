//! The applets about the environment: `env` and `printenv`.

const std = @import("std");
const io_mod = @import("io.zig");
const Io = io_mod.Io;
const Alloc = io_mod.Alloc;
const Buf = io_mod.Buf;
const Strings = io_mod.Strings;
const Oom = io_mod.Oom;
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
    for (list.items) |entry| {
        if (!std.mem.eql(u8, nameOf(entry), name)) {
            list.items[kept] = entry;
            kept += 1;
        }
    }
    list.items = list.items[0..kept];
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
fn search(a: Alloc, path: []const u8, command: []const u8) Oom!?[]const u8 {
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        const candidate = try io_mod.join(a, &.{ if (dir.len == 0) "." else dir, command });
        if (std.posix.access(candidate, std.posix.X_OK)) |_| {
            return candidate;
        } else |_| {}
    }
    return null;
}

/// `env [-i] [-u NAME]... [NAME=VALUE]... [COMMAND [ARG]...]`: with a command, runs it in the environment that is the process's own
/// without those named by -u (all of it with -i) and with the assignments, and exits with its status; a command with no `/` is looked for
/// in the PATH of that environment. Without a command, writes the environment, one `NAME=VALUE` a line.
pub fn env(a: Alloc, io: Io, args: []const []const u8) Oom!u8 {
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
            try unset.add(args[i]);
        } else {
            io.say("env", &.{ "invalid option '", args[i], "'" });
            return 125;
        }
    }
    if (!clear) {
        for (io.environ) |entry| try entries.add(entry);
    }
    for (unset.items) |name| without(&entries, name);
    while (i < args.len and std.mem.indexOfScalar(u8, args[i], '=') != null) : (i += 1) {
        without(&entries, nameOf(args[i]));
        try entries.add(args[i]);
    }
    if (i == args.len) {
        var out = Buf{ .a = a };
        for (entries.items) |entry| {
            try out.add(entry);
            try out.byte('\n');
        }
        return if (io.put(out.items)) 0 else 1;
    }
    return try runCommand(a, io, entries.items, args[i..]);
}

/// Runs `argv` with exactly `entries` as its environment, in the working directory, and returns its status: 127 when the command is not
/// there, 126 when it cannot be run.
fn runCommand(a: Alloc, io: Io, entries: []const []const u8, argv: []const []const u8) Oom!u8 {
    var map = std.process.EnvMap.init(a);
    for (entries) |entry| {
        const name = nameOf(entry);
        if (name.len < entry.len) try map.put(name, entry[name.len + 1 ..]);
    }
    var program = argv[0];
    if (std.mem.indexOfScalar(u8, program, '/') == null) {
        program = (try search(a, lookup(entries, "PATH") orelse default_path, program)) orelse return notRun(io, argv[0], "No such file or directory", 127);
    }
    var full = Strings{ .a = a };
    try full.add(program);
    for (argv[1..]) |arg| try full.add(arg);
    // What the command writes goes after what was written before it.
    io.out.flush() catch {};
    return io.spawn(a, full.items, &map, try here(a, io)) catch |err| notRun(io, argv[0], describe(err), if (err == error.FileNotFound) 127 else 126);
}

/// The absolute path of the working directory.
fn here(a: Alloc, io: Io) Oom![]const u8 {
    return io.cwd.realpathAlloc(a, ".") catch error.OutOfMemory;
}

fn notRun(io: Io, name: []const u8, why: []const u8, status: u8) u8 {
    io.say("env", &.{ "can't execute '", name, "': ", why });
    return status;
}

/// `printenv [NAME]...`: with names, the value of each, a line each; the status is 1 if one is not set. Without, the whole environment.
pub fn printenv(a: Alloc, io: Io, args: []const []const u8) Oom!u8 {
    var out = Buf{ .a = a };
    var status: u8 = 0;
    if (args.len == 0) {
        for (io.environ) |entry| {
            try out.add(entry);
            try out.byte('\n');
        }
    }
    for (args) |name| {
        if (lookup(io.environ, name)) |value| {
            try out.add(value);
            try out.byte('\n');
        } else {
            status = 1;
        }
    }
    return if (!io.put(out.items)) 1 else status;
}
