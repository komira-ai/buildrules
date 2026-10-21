//! How `check run`, `check marker` and `check expect` start a program: the options that say in what environment and where, the preparation
//! (a private scratch directory, the environment, the working directory) and the start itself.
//!
//! The environment the program gets is built in this order, each step on the result of the one before:
//!   1. the process's own, or nothing with --clear-env;
//!   2. each --env NAME=VALUE;
//!   3. each --dir NAME=SUB: NAME is the absolute path of SUB in the scratch directory (`.` is the scratch directory), made;
//!   4. --tmpdir: TMPDIR is the action's scratch path (BUCK_SCRATCH_PATH of the process's environment) made absolute; without one TMPDIR is
//!      kept, and is /tmp if it is empty or not set;
//!   5. --ld-library-path DIR: LD_LIBRARY_PATH is DIR made absolute (it replaces, it does not append);
//!   6. each --abs NAME and --abs-prefix PREFIX: a variable that is set to a relative path is made absolute against the working directory
//!      (every variable whose name starts with PREFIX, for --abs-prefix);
//!   7. each --mkdir-env NAME: the directory NAME names is made, with its parents.
//! The program runs in the directory --cwd names (made absolute), or --cwd-env's variable names, or the working directory. It is never looked
//! for in a PATH: its name must contain a `/`, and a relative one is made absolute first, so it is found whatever the directory it runs in.
//! --scratch NAME makes the private scratch directory the --dir variables are in: `$BUCK_SCRATCH_PATH/NAME` (made absolute) or, when the
//! process has no scratch path, `.buildrules_NAME` in the working directory. It is emptied before the run and removed after it.

const std = @import("std");
const common = @import("common.zig");
const Io = common.Io;
const Alloc = common.Alloc;
const Oom = common.Oom;

pub const Kind = enum { run, marker, expect };

pub const Spec = struct {
    // How the program is started.
    refuse: ?[]const u8 = null,
    clear_env: bool = false,
    tmpdir: bool = false,
    scratch: ?[]const u8 = null,
    ld_library_path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    cwd_env: ?[]const u8 = null,
    sets: []const []const u8 = &.{},
    dirs: []const []const u8 = &.{},
    abs: []const []const u8 = &.{},
    abs_prefix: []const []const u8 = &.{},
    mkdir_env: []const []const u8 = &.{},
    // What `marker` and `expect` do with the result.
    out: ?[]const u8 = null,
    capture: bool = false,
    stamp: ?[]const u8 = null,
    stamp_log: bool = false,
    want: ?[]const u8 = null,
    prefix: bool = false,
    name: ?[]const u8 = null,
    // The program and its arguments: what follows `--`.
    argv: []const []const u8 = &.{},
};

/// Which commands take an option, as bits of `Kind`.
const R = 1 << @intFromEnum(Kind.run);
const M = 1 << @intFromEnum(Kind.marker);
const E = 1 << @intFromEnum(Kind.expect);

const Options = enum {
    @"--refuse",
    @"--clear-env",
    @"--tmpdir",
    @"--scratch",
    @"--ld-library-path",
    @"--cwd",
    @"--cwd-env",
    @"--env",
    @"--dir",
    @"--abs",
    @"--abs-prefix",
    @"--mkdir-env",
    @"--out",
    @"--capture",
    @"--stamp",
    @"--stamp-log",
    @"--want",
    @"--prefix",
    @"--name",
};

/// The commands an option belongs to; a command given an option that is not its own is a usage error (a `run` told `--out` would otherwise
/// look as if it wrote one).
fn belongs(opt: Options) u8 {
    return switch (opt) {
        .@"--refuse" => R,
        .@"--clear-env", .@"--tmpdir", .@"--scratch", .@"--ld-library-path", .@"--cwd", .@"--cwd-env", .@"--env", .@"--dir", .@"--abs", .@"--abs-prefix", .@"--mkdir-env" => R | M | E,
        .@"--out" => M | E,
        .@"--capture", .@"--stamp", .@"--stamp-log" => M,
        .@"--want", .@"--prefix", .@"--name" => E,
    };
}

fn takesValue(opt: Options) bool {
    return switch (opt) {
        .@"--clear-env", .@"--tmpdir", .@"--capture", .@"--stamp-log", .@"--prefix" => false,
        else => true,
    };
}

/// Reads the options of `kind` and the program after `--`. Null, with the reason said, when the command line is wrong.
pub fn parse(io: Io, sub: []const u8, kind: Kind, args: []const []const u8) Oom!?Spec {
    var spec = Spec{};
    var sets = common.Strings{ .a = io.a };
    var dirs = common.Strings{ .a = io.a };
    var abs = common.Strings{ .a = io.a };
    var abs_prefix = common.Strings{ .a = io.a };
    var mkdir_env = common.Strings{ .a = io.a };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--")) {
            spec.argv = args[i + 1 ..];
            break;
        }
        const opt = std.meta.stringToEnum(Options, args[i]) orelse {
            io.say(sub, &.{ "unknown option ", args[i] });
            return null;
        };
        if (belongs(opt) & (@as(u8, 1) << @intFromEnum(kind)) == 0) {
            io.say(sub, &.{ args[i], " is not an option of this command" });
            return null;
        }
        var value: []const u8 = "";
        if (takesValue(opt)) {
            if (i + 1 >= args.len) {
                io.say(sub, &.{ args[i], " needs a value" });
                return null;
            }
            i += 1;
            value = args[i];
        }
        switch (opt) {
            .@"--refuse" => spec.refuse = value,
            .@"--clear-env" => spec.clear_env = true,
            .@"--tmpdir" => spec.tmpdir = true,
            .@"--scratch" => spec.scratch = value,
            .@"--ld-library-path" => spec.ld_library_path = value,
            .@"--cwd" => spec.cwd = value,
            .@"--cwd-env" => spec.cwd_env = value,
            .@"--env" => try sets.add(value),
            .@"--dir" => try dirs.add(value),
            .@"--abs" => try abs.add(value),
            .@"--abs-prefix" => try abs_prefix.add(value),
            .@"--mkdir-env" => try mkdir_env.add(value),
            .@"--out" => spec.out = value,
            .@"--capture" => spec.capture = true,
            .@"--stamp" => spec.stamp = value,
            .@"--stamp-log" => spec.stamp_log = true,
            .@"--want" => spec.want = value,
            .@"--prefix" => spec.prefix = true,
            .@"--name" => spec.name = value,
        }
    }
    spec.sets = sets.items;
    spec.dirs = dirs.items;
    spec.abs = abs.items;
    spec.abs_prefix = abs_prefix.items;
    spec.mkdir_env = mkdir_env.items;
    return spec;
}

/// A program ready to start: what `prepare` made.
pub const Prepared = struct {
    argv: []const []const u8,
    env: std.process.EnvMap,
    cwd: []const u8,
    /// The scratch directory to remove after the run, if one was made.
    scratch: ?[]const u8,
};

/// The result of `prepare`: the program ready, or the exit status to end with (the reason is already said).
pub const Preparation = union(enum) { ready: Prepared, fail: u8 };

/// Splits `NAME=VALUE`; null when there is no `=` or the name is empty.
fn split(entry: []const u8) ?[2][]const u8 {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return null;
    if (eq == 0) return null;
    return .{ entry[0..eq], entry[eq + 1 ..] };
}

fn putEnv(env: *std.process.EnvMap, name: []const u8, value: []const u8) Oom!void {
    try env.put(name, value);
}

pub fn prepare(io: Io, sub: []const u8, spec: Spec) Oom!Preparation {
    const a = io.a;
    if (spec.argv.len == 0) {
        io.say(sub, &.{"no program: it follows `--`"});
        return .{ .fail = 2 };
    }
    if (std.mem.indexOfScalar(u8, spec.argv[0], '/') == null) {
        io.say(sub, &.{ spec.argv[0], " is not a path: a program is never looked for in a PATH, give its path" });
        return .{ .fail = 2 };
    }
    const here = io.cwd.realpathAlloc(a, ".") catch |err| {
        io.say(sub, &.{ "cannot find the working directory: ", @errorName(err) });
        return .{ .fail = 1 };
    };
    var env = std.process.EnvMap.init(a);
    if (!spec.clear_env) {
        for (io.environ) |entry| {
            if (split(entry)) |kv| try putEnv(&env, kv[0], kv[1]);
        }
    }
    for (spec.sets) |entry| {
        const kv = split(entry) orelse {
            io.say(sub, &.{ "--env ", entry, ": expected NAME=VALUE" });
            return .{ .fail = 2 };
        };
        try putEnv(&env, kv[0], kv[1]);
    }

    var scratch: ?[]const u8 = null;
    if (spec.scratch) |name| {
        const bs = io.getenv("BUCK_SCRATCH_PATH") orelse "";
        const dir = if (bs.len == 0)
            try common.join(a, &.{ here, try common.concat(a, &.{ ".buildrules_", name }) })
        else
            try common.join(a, &.{ try common.absolute(a, here, bs), name });
        io.cwd.deleteTree(dir) catch {};
        io.cwd.makePath(dir) catch |err| {
            io.say(sub, &.{ "cannot make the scratch directory ", dir, ": ", @errorName(err) });
            return .{ .fail = 1 };
        };
        scratch = dir;
    }
    var prepared = Prepared{ .argv = &.{}, .env = env, .cwd = here, .scratch = scratch };
    const failed = fill(io, sub, spec, here, &prepared) catch |e| {
        cleanup(io, prepared);
        return e;
    };
    if (failed != 0) {
        cleanup(io, prepared);
        return .{ .fail = failed };
    }
    return .{ .ready = prepared };
}

/// The steps after the scratch directory: --dir, --tmpdir, --ld-library-path, the absolute variables, --mkdir-env, the working directory and
/// the program. Returns 0, or the status to end with.
fn fill(io: Io, sub: []const u8, spec: Spec, here: []const u8, p: *Prepared) Oom!u8 {
    const a = io.a;
    for (spec.dirs) |entry| {
        const kv = split(entry) orelse {
            io.say(sub, &.{ "--dir ", entry, ": expected NAME=SUBDIRECTORY" });
            return 2;
        };
        const root = p.scratch orelse {
            io.say(sub, &.{ "--dir ", entry, " needs --scratch" });
            return 2;
        };
        const dir = if (std.mem.eql(u8, kv[1], ".")) root else try common.join(a, &.{ root, kv[1] });
        io.cwd.makePath(dir) catch |err| {
            io.say(sub, &.{ "cannot make ", dir, ": ", @errorName(err) });
            return 1;
        };
        try putEnv(&p.env, kv[0], dir);
    }
    if (spec.tmpdir) {
        const bs = io.getenv("BUCK_SCRATCH_PATH") orelse "";
        const have = p.env.get("TMPDIR") orelse "";
        if (bs.len > 0) {
            try putEnv(&p.env, "TMPDIR", try common.absolute(a, here, bs));
        } else if (have.len == 0) {
            try putEnv(&p.env, "TMPDIR", "/tmp");
        }
    }
    if (spec.ld_library_path) |dir| try putEnv(&p.env, "LD_LIBRARY_PATH", try common.absolute(a, here, dir));
    for (spec.abs) |name| try makeAbsolute(a, &p.env, here, name);
    for (spec.abs_prefix) |prefix| {
        var names = common.Strings{ .a = a };
        var it = p.env.iterator();
        while (it.next()) |kv| {
            if (std.mem.startsWith(u8, kv.key_ptr.*, prefix)) try names.add(kv.key_ptr.*);
        }
        for (names.items) |name| try makeAbsolute(a, &p.env, here, name);
    }
    for (spec.mkdir_env) |name| {
        const dir = p.env.get(name) orelse "";
        if (dir.len == 0) continue;
        io.cwd.makePath(dir) catch |err| {
            io.say(sub, &.{ "cannot make ", dir, " (named by ", name, "): ", @errorName(err) });
            return 1;
        };
    }
    p.cwd = here;
    if (spec.cwd) |dir| p.cwd = try common.absolute(a, here, dir);
    if (spec.cwd_env) |name| {
        const dir = p.env.get(name) orelse "";
        if (dir.len == 0) {
            io.say(sub, &.{ "--cwd-env ", name, ": the variable is not set" });
            return 2;
        }
        p.cwd = try common.absolute(a, here, dir);
    }
    var argv = common.Strings{ .a = a };
    try argv.add(try common.absolute(a, here, spec.argv[0]));
    for (spec.argv[1..]) |arg| try argv.add(arg);
    p.argv = argv.items;
    return 0;
}

/// A variable that is set to a relative path becomes absolute; one that is not set or is empty is left as it is.
fn makeAbsolute(a: Alloc, env: *std.process.EnvMap, here: []const u8, name: []const u8) Oom!void {
    const value = env.get(name) orelse return;
    if (value.len == 0 or value[0] == '/') return;
    try putEnv(env, name, try common.absolute(a, here, value));
}

/// What a started program did: its exit status, and what it wrote when that was captured.
pub const Outcome = struct { code: u8, stdout: []const u8 = "", stderr: []const u8 = "" };

pub const Mode = enum {
    /// stdin, stdout and stderr are the process's own.
    inherit,
    /// stdout and stderr are captured (and stdin is empty).
    capture,
};

/// Starts the program and waits. A program that cannot be started is 127 when it is not there and 126 otherwise, with the reason said.
pub fn start(io: Io, sub: []const u8, p: Prepared, mode: Mode) Outcome {
    switch (mode) {
        .inherit => {
            var child = std.process.Child.init(p.argv, io.a);
            child.env_map = &p.env;
            child.cwd = p.cwd;
            const term = child.spawnAndWait() catch |err| return notStarted(io, sub, p, err);
            return .{ .code = common.statusOf(term) };
        },
        .capture => {
            const r = std.process.Child.run(.{
                .allocator = io.a,
                .argv = p.argv,
                .cwd = p.cwd,
                .env_map = &p.env,
                .max_output_bytes = 1 << 30,
            }) catch |err| return notStarted(io, sub, p, err);
            return .{ .code = common.statusOf(r.term), .stdout = r.stdout, .stderr = r.stderr };
        },
    }
}

fn notStarted(io: Io, sub: []const u8, p: Prepared, err: anyerror) Outcome {
    io.say(sub, &.{ "cannot run ", p.argv[0], ": ", @errorName(err) });
    return .{ .code = if (err == error.FileNotFound) 127 else 126 };
}

/// Removes the scratch directory, if there was one.
pub fn cleanup(io: Io, p: Prepared) void {
    if (p.scratch) |dir| io.cwd.deleteTree(dir) catch {};
}
