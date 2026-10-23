//! cov_branch_common: what the subcommands of cov_branch (link, run, annotate) share: their flags, their paths, the scratch
//! directory, how a process is run (a `Runner`, so a test can stand in for lld and llvm-profdata) and where.

const std = @import("std");
const proc = @import("proc.zig");

/// The values of the flags `names`, in the order of `names`, from `argv` (flag, value, flag, value...). Null, with the reason in
/// `why`, when a flag is unknown, has no value, is given twice, has an empty value, or is missing.
pub fn parseFlags(alloc: std.mem.Allocator, names: []const []const u8, argv: []const []const u8, why: *[]const u8) !?[]const []const u8 {
    const vals = try alloc.alloc(?[]const u8, names.len);
    @memset(vals, null);
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        const flag = argv[i];
        const k = for (names, 0..) |n, j| {
            if (std.mem.eql(u8, n, flag)) break j;
        } else {
            why.* = try std.fmt.allocPrint(alloc, "unknown argument {s}", .{flag});
            return null;
        };
        if (i + 1 >= argv.len) {
            why.* = try std.fmt.allocPrint(alloc, "{s} needs a value", .{flag});
            return null;
        }
        if (vals[k] != null) {
            why.* = try std.fmt.allocPrint(alloc, "{s} given twice", .{flag});
            return null;
        }
        if (argv[i + 1].len == 0) {
            why.* = try std.fmt.allocPrint(alloc, "{s} is empty", .{flag});
            return null;
        }
        vals[k] = argv[i + 1];
    }
    const out = try alloc.alloc([]const u8, names.len);
    for (names, vals, out) |n, v, *o| {
        o.* = v orelse {
            why.* = try std.fmt.allocPrint(alloc, "{s} is missing", .{n});
            return null;
        };
    }
    return out;
}

/// `p` absolute: as given, or under `cwd`.
pub fn abs(alloc: std.mem.Allocator, cwd: []const u8, p: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(p)) return p;
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ cwd, p });
}

/// The scratch directory of subcommand `name`: $BUCK_SCRATCH_PATH/cov_branch_<name> (relative to the working directory when it is
/// relative), or .cov_branch_<name> in the working directory without one.
pub fn scratchDir(alloc: std.mem.Allocator, name: []const u8, cwd: []const u8, buck_scratch: ?[]const u8) ![]const u8 {
    const s = buck_scratch orelse "";
    if (s.len == 0) return std.fmt.allocPrint(alloc, "{s}/.cov_branch_{s}", .{ cwd, name });
    if (std.fs.path.isAbsolute(s)) return std.fmt.allocPrint(alloc, "{s}/cov_branch_{s}", .{ s, name });
    return std.fmt.allocPrint(alloc, "{s}/{s}/cov_branch_{s}", .{ cwd, s, name });
}

/// How a step's process is run: proc.run in the tool, a stand-in in tests.
pub const Runner = struct {
    ptr: *anyopaque,
    runFn: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator, spec: proc.Spec) anyerror!proc.Outcome,

    pub fn run(self: Runner, alloc: std.mem.Allocator, spec: proc.Spec) anyerror!proc.Outcome {
        return self.runFn(self.ptr, alloc, spec);
    }
};

fn realRun(_: *anyopaque, alloc: std.mem.Allocator, spec: proc.Spec) anyerror!proc.Outcome {
    return proc.run(alloc, spec);
}

var real_ctx: u8 = 0;
pub const real_runner = Runner{ .ptr = &real_ctx, .runFn = &realRun };

pub const Where = struct {
    /// The working directory, absolute.
    cwd: []const u8,
    /// The scratch directory, absolute (scratchDir).
    k: []const u8,
    /// This tool's environment, NAME=VALUE.
    env: []const []const u8,
};

/// A file (a symbolic link followed) of size above 0.
pub fn nonEmpty(path: []const u8) bool {
    const st = std.fs.cwd().statFile(path) catch return false;
    return st.size > 0;
}

/// The first 4 bytes of `path`, fewer if it is shorter, none if it cannot be read.
pub fn head4(path: []const u8, buf: *[4]u8) []const u8 {
    var f = std.fs.cwd().openFile(path, .{}) catch return buf[0..0];
    defer f.close();
    const n = f.readAll(buf) catch return buf[0..0];
    return buf[0..n];
}

/// The last `n` lines of `text`.
pub fn lastLines(text: []const u8, n: usize) []const u8 {
    if (text.len == 0) return text;
    var end = text.len;
    if (text[end - 1] == '\n') end -= 1;
    var seen: usize = 0;
    var i = end;
    while (i > 0) : (i -= 1) {
        if (text[i - 1] == '\n') {
            seen += 1;
            if (seen == n) return text[i..];
        }
    }
    return text;
}

/// `base` with every PATH (and LC_ALL) entry replaced: PATH=`path`, and LC_ALL=C when `c_locale`.
pub fn childEnv(alloc: std.mem.Allocator, base: []const []const u8, path: []const u8, c_locale: bool) ![]const []const u8 {
    var v = std.ArrayList([]const u8).empty;
    for (base) |e| {
        if (std.mem.startsWith(u8, e, "PATH=")) continue;
        if (c_locale and std.mem.startsWith(u8, e, "LC_ALL=")) continue;
        try v.append(alloc, e);
    }
    try v.append(alloc, try std.fmt.allocPrint(alloc, "PATH={s}", .{path}));
    if (c_locale) try v.append(alloc, "LC_ALL=C");
    return v.toOwnedSlice(alloc);
}
