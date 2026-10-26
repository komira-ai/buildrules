//! How `check run`, `check marker` and `check expect` start a program: the options that say in what environment and where, the preparation
//! (a private scratch directory, the environment, the working directory) and the start itself.
//!
//! The environment the program gets is built in this order, each step on the result of the one before:
//!   1. the process's own, or nothing with --clear-env;
//!   2. each --env NAME=VALUE;
//!   3. each --dir NAME=SUB: NAME is the absolute path of SUB in the scratch directory (`.` is the scratch directory), made;
//!   4. --tmpdir: TMPDIR is the action's scratch path (BUCK_SCRATCH_PATH of the process's environment) made absolute; without one TMPDIR is
//!      kept, and is /tmp if it is empty or not set;
//!   5. --ld-library-path DIR: LD_LIBRARY_PATH (DYLD_LIBRARY_PATH on macOS, whose loader reads no other) is DIR made absolute (it replaces, it does not append);
//!      on macOS DYLD_FALLBACK_LIBRARY_PATH is also set, to `/opt/homebrew/lib:/usr/local/lib:/usr/lib`, so a library the program opens by its bare name
//!      (`dlopen("liblz4.dylib")`) is found where the host installs it, as the Linux loader finds `liblz4.so.1` in the system directories;
//!   6. each --abs NAME and --abs-prefix PREFIX: a variable that is set to a relative path is made absolute against the working directory
//!      (every variable whose name starts with PREFIX, for --abs-prefix);
//!   7. each --mkdir-env NAME: the directory NAME names is made, with its parents.
//! --private-scratch makes a directory of the run's own (install_root.zig), fresh and named at random, in BUCK_SCRATCH_PATH (made absolute), else
//! TMPDIR, else /tmp, and removes it after the run. It holds `tmp` (TMPDIR and TEST_TMPDIR are its absolute path, empty at the start), `home` (HOME,
//! the same) and `root`. They are set after --tmpdir and before --ld-library-path, so they replace whatever --env or --tmpdir gave.
//! --installed (needs --private-scratch) runs the program from `root`: the directory that holds the program is copied to `root/bin` (so `root/bin/<name>` is a copy of
//! it, and what sits beside it, such as its `lib/`, is there too), `root/share` holds a copy of the tree --install-share names, --share-env NAME is the absolute
//! path of `root/share`, and the working directory is `root` unless --cwd or --cwd-env says another.
//! The program runs in the directory --cwd names (made absolute), or --cwd-env's variable names, or the working directory. It is never looked
//! for in a PATH: its name must contain a `/`, and a relative one is made absolute first, so it is found whatever the directory it runs in.
//! --scratch NAME makes the private scratch directory the --dir variables are in: `$BUCK_SCRATCH_PATH/NAME` (made absolute) or, when the
//! process has no scratch path, `.buildrules_NAME` in the working directory. It is emptied before the run and removed after it.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
const Io = common.Io;
const Alloc = common.Alloc;
const Oom = common.Oom;
const ir = @import("install_root");

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
    private_scratch: bool = false,
    installed: bool = false,
    install_share: ?[]const u8 = null,
    share_env: ?[]const u8 = null,
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
    @"--private-scratch",
    @"--installed",
    @"--install-share",
    @"--share-env",
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
        .@"--clear-env", .@"--tmpdir", .@"--scratch", .@"--ld-library-path", .@"--cwd", .@"--cwd-env", .@"--env", .@"--dir", .@"--abs", .@"--abs-prefix", .@"--mkdir-env", .@"--private-scratch", .@"--installed", .@"--install-share", .@"--share-env" => R | M | E,
        .@"--out" => M | E,
        .@"--capture", .@"--stamp", .@"--stamp-log" => M,
        .@"--want", .@"--prefix", .@"--name" => E,
    };
}

fn takesValue(opt: Options) bool {
    return switch (opt) {
        .@"--clear-env", .@"--tmpdir", .@"--private-scratch", .@"--installed", .@"--capture", .@"--stamp-log", .@"--prefix" => false,
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
            .@"--private-scratch" => spec.private_scratch = true,
            .@"--installed" => spec.installed = true,
            .@"--install-share" => spec.install_share = value,
            .@"--share-env" => spec.share_env = value,
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
    /// The private directories of the run (--private-scratch), removed after it.
    private: ?ir.Scratch = null,
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
    if (spec.installed and !spec.private_scratch) {
        io.say(sub, &.{"--installed needs --private-scratch: the installed layout is made in it"});
        return .{ .fail = 2 };
    }
    if ((spec.install_share != null or spec.share_env != null) and !spec.installed) {
        io.say(sub, &.{"--install-share and --share-env need --installed"});
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
    if (spec.private_scratch) {
        const where = ir.parent(a, here, io.getenv("BUCK_SCRATCH_PATH"), io.getenv("TMPDIR")) catch |err| {
            cleanup(io, prepared);
            return err;
        };
        prepared.private = ir.make(a, where) catch |err| {
            cleanup(io, prepared);
            if (err == error.OutOfMemory) return error.OutOfMemory;
            io.say(sub, &.{ "cannot make a private scratch directory in ", where, ": ", @errorName(err) });
            return .{ .fail = 1 };
        };
    }
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

/// The variable the loader of `os` reads for the directories to search first: dyld reads DYLD_LIBRARY_PATH and ignores LD_LIBRARY_PATH, so a macOS program
/// that names its runtime as `@rpath/lib....dylib` is not found through the Linux spelling.
pub fn libraryPathVar(os: std.Target.Os.Tag) []const u8 {
    return if (os == .macos) "DYLD_LIBRARY_PATH" else "LD_LIBRARY_PATH";
}

/// The directories dyld searches for a library opened by its bare name (`dlopen("liblz4.dylib")`) after DYLD_LIBRARY_PATH and the current directory, as
/// DYLD_FALLBACK_LIBRARY_PATH; null where the loader needs none. On Linux the loader finds such a library (`liblz4.so.1`) in the system directories of the
/// worker; on macOS the system directories hold no lz4, and a library the host installs lives under the package manager's prefix (`/opt/homebrew/lib` on Apple
/// silicon). Setting the variable replaces dyld's default (`$HOME/lib:/usr/local/lib:/usr/lib`), so the default directories are listed after the prefix.
pub fn fallbackLibraryDirs(os: std.Target.Os.Tag) ?[]const u8 {
    return if (os == .macos) "/opt/homebrew/lib:/usr/local/lib:/usr/lib" else null;
}

/// Step 5 for a program of `os`: the library path variable holds `dir` (absolute), and on macOS the fallback directories are set as well.
pub fn setLibraryEnv(env: *std.process.EnvMap, os: std.Target.Os.Tag, dir: []const u8) Oom!void {
    try putEnv(env, libraryPathVar(os), dir);
    if (fallbackLibraryDirs(os)) |dirs| try putEnv(env, "DYLD_FALLBACK_LIBRARY_PATH", dirs);
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
    if (p.private) |s| {
        try putEnv(&p.env, "TMPDIR", s.tmp);
        try putEnv(&p.env, "TEST_TMPDIR", s.tmp);
        try putEnv(&p.env, "HOME", s.home);
    }
    if (spec.ld_library_path) |dir| try setLibraryEnv(&p.env, builtin.os.tag, try common.absolute(a, here, dir));
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
    var program = try common.absolute(a, here, spec.argv[0]);
    p.cwd = here;
    if (spec.installed) {
        const root = p.private.?.root;
        const share = p.private.?.share;
        program = ir.installBinary(a, root, program) catch |err| return notInstalled(io, sub, err, &.{ "cannot install ", program, " under ", root, ": " });
        if (spec.install_share) |dir| {
            const from = try common.absolute(a, here, dir);
            ir.copyTree(a, from, share) catch |err| return notInstalled(io, sub, err, &.{ "cannot copy ", from, " to ", share, ": " });
        }
        if (spec.share_env) |name| try putEnv(&p.env, name, share);
        p.cwd = root;
    }
    if (spec.cwd) |dir| p.cwd = try common.absolute(a, here, dir);
    if (spec.cwd_env) |name| {
        const dir = p.env.get(name) orelse "";
        if (dir.len == 0) {
            io.say(sub, &.{ "--cwd-env ", name, ": the variable is not set" });
            return 2;
        }
        p.cwd = try common.absolute(a, here, dir);
    }
    io.cwd.access(p.cwd, .{}) catch |err| {
        io.say(sub, &.{ "cannot use the working directory ", p.cwd, ": ", @errorName(err) });
        return 1;
    };
    var argv = common.Strings{ .a = a };
    try argv.add(program);
    for (spec.argv[1..]) |arg| try argv.add(arg);
    p.argv = argv.items;
    return 0;
}

/// An installed layout that could not be made: an allocation that failed is the command's failure, anything else is said with `what` and the reason,
/// and the status is 1.
fn notInstalled(io: Io, sub: []const u8, err: anyerror, what: []const []const u8) Oom!u8 {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    var parts = common.Strings{ .a = io.a };
    for (what) |w| try parts.add(w);
    try parts.add(@errorName(err));
    io.say(sub, parts.items);
    return 1;
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
    if (p.private) |s| ir.remove(s);
}
