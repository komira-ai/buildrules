//! busybox_macos: the busybox calling convention over the macOS base system.
//!
//! A Mac that runs Buck2 itself (`[buildrules_re] mode = local`) has no static busybox, and every Zig rule runs its scripts through one (`busybox sh -euc`, the
//! applets as the PATH of a test). This program stands in for it. It accepts exactly the forms the rules use:
//!
//!   busybox_macos <applet> <args...>      run one applet
//!   busybox_macos --install -s <dir>      link every applet in <dir> to this program
//!   <dir>/<applet> <args...>              (such a link) run that applet
//!
//! An applet is resolved in /bin and /usr/bin only, which on macOS belong to the operating system (the sealed system volume), never to a developer tool
//! installation, and only if it is in the fixed list `applets`. Anything else is refused (exit 127), so a script cannot reach a tool the platform does not
//! declare. It is built by the pinned zig (`zig_bootstrap_exe`, no shell), so nothing here needs the thing it replaces.
//!
//! Exit status: the applet's (it replaces this process); 127 for an applet outside the list or missing from /bin and /usr/bin; 2 for a usage error or a failure
//! to link.

const std = @import("std");

/// The applets the Zig rules and their tests run, by name. Sorted.
pub const applets = [_][]const u8{
    "awk",   "basename", "cat",   "chmod", "cmp",  "cp",    "cut",   "dirname", "env", "expr", "find", "grep",
    "head",  "ln",       "ls",    "mkdir", "mkfifo", "mktemp", "mv",   "printf",  "ps",  "readlink", "rm",   "rmdir",
    "sed",   "sh",       "sleep", "sort",  "tail", "tar",   "tee",   "test",    "touch", "tr", "uname", "wc",
};

/// The directories an applet is looked for in, in this order: the operating system's.
pub const dirs = [_][]const u8{ "/bin", "/usr/bin" };

pub fn isApplet(name: []const u8) bool {
    for (applets) |a| if (std.mem.eql(u8, a, name)) return true;
    return false;
}

pub const Action = union(enum) {
    /// `--install -s <dir>`: link every applet into the directory.
    install: []const u8,
    /// Run one applet with these arguments.
    run: struct { applet: []const u8, args: []const []const u8 },
    /// An applet outside the list.
    refuse: []const u8,
    usage,
};

/// What `<name> <args...>` asks for, `name` being the last component of how this program was invoked: an applet's name (a link made by `--install`) runs that applet
/// with all of `args`; any other name is the program itself, whose first argument is `--install` or an applet.
pub fn plan(name: []const u8, args: []const []const u8) Action {
    if (isApplet(name)) return .{ .run = .{ .applet = name, .args = args } };
    if (args.len == 0) return .usage;
    if (std.mem.eql(u8, args[0], "--install")) {
        if (args.len != 3 or !std.mem.eql(u8, args[1], "-s")) return .usage;
        return .{ .install = args[2] };
    }
    if (!isApplet(args[0])) return .{ .refuse = args[0] };
    return .{ .run = .{ .applet = args[0], .args = args[1..] } };
}

/// The path of `applet` in the first of `dirs` where `exists` says it is, written into `buf`; null when it is in none.
pub fn resolve(buf: []u8, applet: []const u8, search: []const []const u8, exists: *const fn ([]const u8) bool) ?[]const u8 {
    for (search) |d| {
        const p = std.fmt.bufPrint(buf, "{s}/{s}", .{ d, applet }) catch return null;
        if (exists(p)) return p;
    }
    return null;
}

/// Links every applet in `dir` to `self` (an existing link of the name is replaced, as `ln -sf` does).
pub fn install(dir: std.fs.Dir, self: []const u8) !void {
    for (applets) |a| {
        dir.deleteFile(a) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        try dir.symLink(self, a, .{});
    }
}

fn executable(path: []const u8) bool {
    std.posix.access(path, std.posix.X_OK) catch return false;
    return true;
}

fn say(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print("busybox_macos: " ++ fmt ++ "\n", args) catch {};
}

pub fn main() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = std.process.argsAlloc(a) catch {
        say("out of memory", .{});
        return 2;
    };
    switch (plan(std.fs.path.basename(argv[0]), argv[1..])) {
        .usage => {
            say("usage: busybox_macos <applet> <args...> | --install -s <dir>", .{});
            return 2;
        },
        .refuse => |name| {
            say("REFUSING: '{s}' is not an applet of this platform", .{name});
            return 127;
        },
        .install => |d| {
            const self = std.fs.selfExePathAlloc(a) catch |e| {
                say("cannot find itself: {s}", .{@errorName(e)});
                return 2;
            };
            var dir = std.fs.cwd().openDir(d, .{}) catch |e| {
                say("cannot open {s}: {s}", .{ d, @errorName(e) });
                return 2;
            };
            defer dir.close();
            install(dir, self) catch |e| {
                say("cannot link into {s}: {s}", .{ d, @errorName(e) });
                return 2;
            };
            return 0;
        },
        .run => |r| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = resolve(&buf, r.applet, &dirs, &executable) orelse {
                say("REFUSING: '{s}' is not in /bin or /usr/bin on this host", .{r.applet});
                return 127;
            };
            const full = a.alloc([]const u8, r.args.len + 1) catch return 2;
            full[0] = path;
            @memcpy(full[1..], r.args);
            const err = std.process.execv(a, full);
            say("cannot run {s}: {s}", .{ path, @errorName(err) });
            return 127;
        },
    }
}
