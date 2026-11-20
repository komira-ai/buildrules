//! A stand-in for the programs pg_run starts, for the process tests (pg_plat_test.zig, pg_exe_test.zig); never shipped. By the name it is run as:
//!   initdb ... -D DIR ...      makes DIR, exit 0
//!   postgres ... -D DIR ...    makes DIR, writes DIR/postmaster.pid as a ready server does, then waits; SIGINT ends it with status 0
//! or by its first argument:
//!   check-env NAME VALUE       exit 0 when the variable NAME is VALUE, else 1
//!   check-url NAME             exit 0 when NAME is a postgresql:// URL of a Unix socket directory (percent-encoded) that is there, else 1
//!   exit N                     exit N

const std = @import("std");
const posix = std.posix;

const ready = "1234\n/data\n1700000000\n5432\n/tmp\n\n  1234 5678\nready   \n";

fn onInt(_: i32) callconv(.c) void {
    posix.exit(0);
}

fn dataDir(args: []const []const u8) []const u8 {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "-D") and i + 1 < args.len) return args[i + 1];
    }
    return ".";
}

fn urlOk(a: std.mem.Allocator, url: []const u8) !bool {
    const head = "postgresql://postgres@";
    const tail = ":5432/postgres";
    if (!std.mem.startsWith(u8, url, head) or !std.mem.endsWith(u8, url, tail)) return false;
    const enc = url[head.len .. url.len - tail.len];
    var dir = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < enc.len) : (i += 1) {
        if (enc[i] == '%') {
            if (i + 3 > enc.len) return false;
            const v = std.fmt.parseInt(u8, enc[i + 1 .. i + 3], 16) catch return false;
            try dir.append(a, v);
            i += 2;
        } else if (std.ascii.isAlphanumeric(enc[i]) or enc[i] == '.' or enc[i] == '_' or enc[i] == '~' or enc[i] == '-') {
            try dir.append(a, enc[i]);
        } else return false;
    }
    std.fs.cwd().access(dir.items, .{}) catch return false;
    return std.fs.path.isAbsolute(dir.items);
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    const name = std.fs.path.basename(args[0]);
    if (std.mem.eql(u8, name, "initdb")) {
        try std.fs.cwd().makePath(dataDir(args));
        return 0;
    }
    if (std.mem.eql(u8, name, "postgres")) {
        const dir = dataDir(args);
        try std.fs.cwd().makePath(dir);
        const sa = posix.Sigaction{ .handler = .{ .handler = onInt }, .mask = posix.sigemptyset(), .flags = 0 };
        posix.sigaction(posix.SIG.INT, &sa, null);
        const file = try std.fmt.allocPrint(a, "{s}/postmaster.pid", .{dir});
        try std.fs.cwd().writeFile(.{ .sub_path = file, .data = ready });
        while (true) std.Thread.sleep(std.time.ns_per_s);
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "check-env")) {
        const v = std.process.getEnvVarOwned(a, args[2]) catch return 1;
        return if (std.mem.eql(u8, v, args[3])) 0 else 1;
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "check-url")) {
        const v = std.process.getEnvVarOwned(a, args[2]) catch return 1;
        return if (try urlOk(a, v)) 0 else 1;
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "exit")) return try std.fmt.parseInt(u8, args[2], 10);
    return 99;
}
