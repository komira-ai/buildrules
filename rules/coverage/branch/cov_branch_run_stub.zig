//! cov_branch_run_stub: the stand-in test binary and llvm-profdata of the process tests of `cov_branch run`
//! (cov_branch_run_exe_test.zig), reached through a symbolic link named as the program it stands in for.
//!
//! usage: <dir>/<name> <arguments...>
//!
//! <dir> is the directory argv[0] names. It writes its arguments (argv[1..]), one per line, to `<dir>/argv`, its environment, one
//! NAME=VALUE per line, to `<dir>/env`, and its working directory to `<dir>/cwd`. Then:
//!   - when LLVM_PROFILE_FILE is set and `<dir>/raw` exists, it writes the bytes of `<dir>/raw` to the file LLVM_PROFILE_FILE names,
//!     `%p` replaced by its process id, as the profile runtime does;
//!   - `merge -o <file> ...` writes the bytes of `<dir>/merged` to <file>; `show <file>` writes `<dir>/show` to stdout;
//!   - when `<dir>/say` exists, it writes `stdout: <say>` to stdout and `stderr: <say>` to stderr;
//!   - it exits with the decimal status in `<dir>/stub_rc`, 0 when there is none.
//! A test-only program: no rule hands it out.

const std = @import("std");

fn readOpt(alloc: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) !?[]const u8 {
    return dir.readFileAlloc(alloc, name, 1 << 20) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);
    var dir = try std.fs.cwd().openDir(std.fs.path.dirname(argv[0]) orelse return error.NoDirectory, .{});
    defer dir.close();

    var rec = std.ArrayList(u8).empty;
    for (argv[1..]) |a| {
        try rec.appendSlice(alloc, a);
        try rec.append(alloc, '\n');
    }
    try dir.writeFile(.{ .sub_path = "argv", .data = rec.items });

    var env = std.ArrayList(u8).empty;
    var profile: ?[]const u8 = null;
    for (std.os.environ) |e| {
        const line = std.mem.span(e);
        try env.appendSlice(alloc, line);
        try env.append(alloc, '\n');
        if (std.mem.startsWith(u8, line, "LLVM_PROFILE_FILE=")) profile = line["LLVM_PROFILE_FILE=".len..];
    }
    try dir.writeFile(.{ .sub_path = "env", .data = env.items });
    try dir.writeFile(.{ .sub_path = "cwd", .data = try std.process.getCwdAlloc(alloc) });

    if (profile) |tmpl| {
        if (try readOpt(alloc, dir, "raw")) |bytes| {
            const pid = try std.fmt.allocPrint(alloc, "{d}", .{std.os.linux.getpid()});
            const path = try std.mem.replaceOwned(u8, alloc, tmpl, "%p", pid);
            if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
            try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
        }
    }
    if (argv.len >= 4 and std.mem.eql(u8, argv[1], "merge") and std.mem.eql(u8, argv[2], "-o")) {
        if (try readOpt(alloc, dir, "merged")) |bytes| try std.fs.cwd().writeFile(.{ .sub_path = argv[3], .data = bytes });
    }
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "show")) {
        if (try readOpt(alloc, dir, "show")) |text| try std.fs.File.stdout().writeAll(text);
    }
    if (try readOpt(alloc, dir, "say")) |say| {
        try std.fs.File.stdout().deprecatedWriter().print("stdout: {s}\n", .{say});
        try std.fs.File.stderr().deprecatedWriter().print("stderr: {s}\n", .{say});
    }
    const rc = (try readOpt(alloc, dir, "stub_rc")) orelse return 0;
    return try std.fmt.parseUnsigned(u8, std.mem.trim(u8, rc, " \n"), 10);
}
