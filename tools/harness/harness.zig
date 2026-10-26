//! Shared by the Zig test drivers of tools/channels and tools/deploy: run a program and capture its output, read and write files, and report `ok` /
//! `FAIL` per check. Standard library only. The drivers are run by Buck2 as zig_tests that get the built programs as environment variables
//! (`env_tools` in the BUCK file); there is no shell and no Python. Vendored from the sibling tool's test harness (the functions these drivers use).

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

/// `ok   <name>` / `FAIL <name>: <detail>` lines, and the number of failures.
pub const Report = struct {
    failures: usize = 0,

    pub fn check(self: *Report, name: []const u8, ok: bool, detail: []const u8) void {
        if (ok) {
            std.debug.print("ok   {s}\n", .{name});
        } else {
            std.debug.print("FAIL {s}: {s}\n", .{ name, detail });
            self.failures += 1;
        }
    }

    /// `want` and `got` are the same bytes; a difference prints both.
    pub fn same(self: *Report, name: []const u8, want: []const u8, got: []const u8) void {
        if (std.mem.eql(u8, want, got)) {
            std.debug.print("ok   {s}\n", .{name});
        } else {
            std.debug.print("FAIL {s}: output differs\n--- want\n{s}--- got\n{s}---\n", .{ name, want, got });
            self.failures += 1;
        }
    }

    pub fn finish(self: *Report) !void {
        if (self.failures != 0) {
            std.debug.print("{d} failure(s)\n", .{self.failures});
            return error.ChecksFailed;
        }
    }
};

pub const Capture = enum { both, stdout, stderr, none };

pub const Ran = struct {
    /// The exit status, or the signal number when `signaled`.
    code: u8,
    signaled: bool,
    text: []u8,
};

pub const Options = struct {
    stdin_path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    capture: Capture = .both,
    /// With `.stdout` capture: standard error goes to this file (created or
    /// truncated) instead of being dropped.
    stderr_path: ?[]const u8 = null,
    /// With `.stderr` or no capture: standard output goes to this file.
    stdout_path: ?[]const u8 = null,
};

/// The environment of this process.
pub fn environ(a: Allocator) !std.process.EnvMap {
    return std.process.getEnvMap(a);
}

/// An environment variable the BUCK target sets (a built program's path),
/// made absolute so a child with another working directory can use it.
pub fn toolPath(a: Allocator, name: []const u8) ![]u8 {
    const v = std.process.getEnvVarOwned(a, name) catch {
        std.debug.print("the environment variable {s} is not set (BUCK gives it with env_tools)\n", .{name});
        return error.MissingTool;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

/// Runs `argv` (argv[0] is a path) with exactly `env`, the working directory
/// and standard input of `opt`, and returns what it wrote to the captured
/// stream(s); `.both` is one pipe for both, in the order written, as `2>&1`.
pub fn run(a: Allocator, argv: []const []const u8, env: *const std.process.EnvMap, opt: Options) !Ran {
    const argv_z = try a.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |s, i| argv_z[i] = (try a.dupeZ(u8, s)).ptr;
    const envp = try a.allocSentinel(?[*:0]u8, env.count(), null);
    {
        var it = env.iterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) {
            envp[i] = (try std.fmt.allocPrintZ(a, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* })).ptr;
        }
    }
    const stdin_z: ?[:0]const u8 = if (opt.stdin_path) |p| try a.dupeZ(u8, p) else null;
    const cwd_z: ?[:0]const u8 = if (opt.cwd) |p| try a.dupeZ(u8, p) else null;
    const out_z: ?[:0]const u8 = if (opt.stdout_path) |p| try a.dupeZ(u8, p) else null;
    const err_z: ?[:0]const u8 = if (opt.stderr_path) |p| try a.dupeZ(u8, p) else null;
    const fds = try posix.pipe();
    const pid = try posix.fork();
    if (pid == 0) {
        posix.close(fds[0]);
        const devnull = posix.openZ("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch posix.exit(127);
        const in_fd = if (stdin_z) |p| (posix.openZ(p, .{ .ACCMODE = .RDONLY }, 0) catch posix.exit(127)) else devnull;
        posix.dup2(in_fd, 0) catch posix.exit(127);
        const out_fd = if (out_z) |p|
            (posix.openZ(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch posix.exit(127))
        else if (opt.capture == .stderr or opt.capture == .none) devnull else fds[1];
        const err_fd = if (err_z) |p|
            (posix.openZ(p, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch posix.exit(127))
        else if (opt.capture == .stdout or opt.capture == .none) devnull else fds[1];
        posix.dup2(out_fd, 1) catch posix.exit(127);
        posix.dup2(err_fd, 2) catch posix.exit(127);
        // The write end of the capture pipe stays open only as fd 1 or 2: a
        // descendant that outlives this child must not keep the capture open
        // through a third descriptor.
        if (fds[1] > 2) posix.close(fds[1]);
        if (devnull > 2) posix.close(devnull);
        if (cwd_z) |p| posix.chdirZ(p) catch posix.exit(127);
        const exec_err = posix.execvpeZ(argv_z[0].?, argv_z.ptr, envp.ptr);
        std.debug.print("exec {s}: {s}\n", .{ argv[0], @errorName(exec_err) });
        posix.exit(127);
    }
    posix.close(fds[1]);
    var text = std.ArrayList(u8).init(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try posix.read(fds[0], &buf);
        if (n == 0) break;
        try text.appendSlice(buf[0..n]);
    }
    posix.close(fds[0]);
    const w = posix.waitpid(pid, 0);
    if (posix.W.IFEXITED(w.status)) {
        return .{ .code = posix.W.EXITSTATUS(w.status), .signaled = false, .text = text.items };
    }
    return .{ .code = @truncate(posix.W.TERMSIG(w.status)), .signaled = true, .text = text.items };
}

/// The driver's data directory (BUILDRULES_TEST_WORK, where the BUCK target's `data` is staged at the paths it names) becomes the working
/// directory, so the driver reads its fixtures by their repository paths. Call it before the first relative path is used.
pub fn enterWork(a: Allocator) !void {
    const w = std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK") catch {
        std.debug.print("BUILDRULES_TEST_WORK is not set (the BUCK target gives it with `data`)\n", .{});
        return error.MissingWork;
    };
    try posix.chdir(w);
}

pub fn readFile(a: Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(a, path, 64 << 20);
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
    try std.fs.cwd().writeFile(path, bytes);
}

pub fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// Whether some line of `text` is exactly `line`.
pub fn hasLine(text: []const u8, line: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| if (std.mem.eql(u8, l, line)) return true;
    return false;
}

/// The directory `tmp` as an absolute path.
pub fn tmpPath(a: Allocator, tmp: *std.testing.TmpDir) ![]u8 {
    return tmp.dir.realpathAlloc(a, ".");
}

pub fn join(a: Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(a, parts);
}

pub fn fmt(a: Allocator, comptime f: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(a, f, args);
}
