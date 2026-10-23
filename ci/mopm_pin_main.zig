//! The command line of the mopm pin verification (ci/mopm_pin.zig; .github/workflows/mopm-pin.yml runs it).
//!
//! usage: mopm_pin verify --pins <rules/mopm/pins.bzl> --work <existing dir> [--cosign <program>] [--curl <program>]
//! Reads every pinned mopm release from the table, downloads its tarball and bundle, and exits 0 only when each has the pinned size and sha256 and verifies with
//! `cosign verify-blob` against mopm's release workflow on main. Each failure is printed; any failure exits 1, a usage or table error exits 2.
const std = @import("std");
const pin = @import("mopm_pin.zig");

fn die(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("mopm_pin: " ++ fmt ++ "\n", args);
    return 2;
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    const usage = "usage: mopm_pin verify --pins <pins.bzl> --work <dir> [--cosign <program>] [--curl <program>]";
    if (argv.len < 2 or !std.mem.eql(u8, argv[1], "verify")) return die(usage, .{});
    var pins: ?[]const u8 = null;
    var work: ?[]const u8 = null;
    var cosign: []const u8 = "cosign";
    var curl: []const u8 = "curl";
    var i: usize = 2;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) return die("{s} needs a value\n{s}", .{ argv[i], usage });
        const v = argv[i + 1];
        if (std.mem.eql(u8, argv[i], "--pins")) {
            pins = v;
        } else if (std.mem.eql(u8, argv[i], "--work")) {
            work = v;
        } else if (std.mem.eql(u8, argv[i], "--cosign")) {
            cosign = v;
        } else if (std.mem.eql(u8, argv[i], "--curl")) {
            curl = v;
        } else return die("unknown flag {s}\n{s}", .{ argv[i], usage });
    }
    const pins_path = pins orelse return die("--pins is required\n{s}", .{usage});
    const work_dir = work orelse return die("--work is required\n{s}", .{usage});
    const text = std.fs.cwd().readFileAlloc(a, pins_path, 1 << 20) catch |e| return die("cannot read {s}: {s}", .{ pins_path, @errorName(e) });
    const table = pin.parse(a, text) catch |e| return die("{s} is not a table this can read: {s}", .{ pins_path, @errorName(e) });
    var io = pin.RealIo{ .curl = curl };
    const failures = try pin.verifyAll(pin.RealIo, &io, a, table, work_dir, cosign);
    for (failures) |f| std.debug.print("mopm_pin: {s}\n", .{f});
    if (failures.len != 0) {
        std.debug.print("mopm_pin: {d} of {d} pinned mopm release(s) did not verify\n", .{ failures.len, table.rows.len });
        return 1;
    }
    std.debug.print("mopm_pin: {d} pinned mopm release(s) verified (size, sha256, and a signature of {s})\n", .{ table.rows.len, pin.identity });
    return 0;
}
