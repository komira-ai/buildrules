//! `apt-get` and `dpkg-query` for apt_rotation_test.zig, in one program (the test gives its path for both). Its state is the directory $FAKE_APT_DIR; every call appends its
//! arguments to `log` there. What it does is set by files in that directory:
//!   apt-get update:   `update_fail` (its text is printed to standard error, then exit 100), `update_warn` (a `W:` line), `no_all_index` (the list directory gets no binary-all index);
//!                     otherwise it writes a binary-all and a binary-amd64 index into the directory of `-o Dir::State::lists=<dir>` and exits 0.
//!   apt-get install:  `install_fail` (`E: Unable to locate package`, exit 100), `install_noop` (exit 0 and does nothing), `no_file` (installed, but the file is not written);
//!                     otherwise it writes `installed` and the file $FAKE_APT_FILE, and exits 0.
//!   dpkg-query -W:    prints `install ok installed` and exits 0 when `installed` exists; otherwise says so and exits 1.

const std = @import("std");

fn has(dir: std.fs.Dir, name: []const u8) bool {
    dir.access(name, .{}) catch return false;
    return true;
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(a);
    const args = argv[1..];
    const dir_path = std.posix.getenv("FAKE_APT_DIR") orelse @panic("FAKE_APT_DIR");
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    {
        var f = try dir.createFile("log", .{ .truncate = false });
        defer f.close();
        try f.seekFromEnd(0);
        try f.writer().print("{s}\n", .{try std.mem.join(a, " ", args)});
    }
    const out = std.io.getStdOut().writer();
    const err = std.io.getStdErr().writer();
    if (args.len == 0) std.process.exit(2);

    if (std.mem.eql(u8, args[0], "update")) {
        if (has(dir, "update_fail")) {
            try err.writeAll(try dir.readFileAlloc(a, "update_fail", 1 << 16));
            try err.writeAll("E: Some index files failed to download. They have been ignored, or old ones used instead.\n");
            std.process.exit(100);
        }
        var lists: []const u8 = "";
        for (args) |x| {
            if (std.mem.startsWith(u8, x, "Dir::State::lists=")) lists = x["Dir::State::lists=".len..];
        }
        if (lists.len == 0) std.process.exit(3);
        var l = try std.fs.cwd().openDir(lists, .{});
        defer l.close();
        if (!has(dir, "no_all_index")) try l.writeFile("x_dists_stable_main_binary-all_Packages", "Package: rotation-test\n");
        try l.writeFile("x_dists_stable_main_binary-amd64_Packages", "");
        try out.writeAll("Get:1 file:/x stable InRelease [1000 B]\nReading package lists...\n");
        if (has(dir, "update_warn")) try err.writeAll("W: something odd\n");
        return;
    }
    if (std.mem.eql(u8, args[0], "install")) {
        if (has(dir, "install_fail")) {
            try err.writeAll("E: Unable to locate package rotation-test\n");
            std.process.exit(100);
        }
        if (has(dir, "install_noop")) return;
        try dir.writeFile("installed", "");
        if (!has(dir, "no_file")) {
            const path = std.posix.getenv("FAKE_APT_FILE") orelse @panic("FAKE_APT_FILE");
            if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
            try std.fs.cwd().writeFile(path, "installed\n");
        }
        try out.writeAll("Setting up rotation-test (1.0.0) ...\n");
        return;
    }
    if (std.mem.eql(u8, args[0], "-W")) {
        if (has(dir, "installed")) {
            try out.writeAll("install ok installed");
            return;
        }
        try err.writeAll("dpkg-query: no packages found matching rotation-test\n");
        std.process.exit(1);
    }
    std.process.exit(2);
}
