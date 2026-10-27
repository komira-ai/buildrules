//! system_probe: a stand-in for a compiled Mojo test that opens shared libraries by their bare names. The fixtures of ci/mojo_syslibs run it as the test, so the system
//! libraries a test is given (rules/mojo/system_libs.bzl, docs/contract.md section 12.11) are proven end to end without a Mojo compiler: the pinned `.conda` is downloaded,
//! `conda_unpack --all-libs` unpacks it, and `check run` puts the directory on LD_LIBRARY_PATH, where a bare name resolves.
//!
//! PROBE_NEEDS is a comma-separated list of the library file names the test opens. The probe passes only when each of them is a regular, non-empty ELF file in one of the
//! directories of LD_LIBRARY_PATH that follow the first (the first is the compiler's lib, which these fixtures do not have), the way the loader finds it. It says which
//! name it did not find (the build is red with that line).

const std = @import("std");

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    // Standard output, which a failed run shows (the standard error of a test run is not part of what the failure reports).
    const line = std.fmt.allocPrint(std.heap.page_allocator, "system_probe: " ++ fmt ++ "\n", args) catch std.process.exit(1);
    _ = std.posix.write(1, line) catch {};
    std.process.exit(1);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const path = std.process.getEnvVarOwned(a, "LD_LIBRARY_PATH") catch fail("LD_LIBRARY_PATH is not set", .{});
    const needs = std.process.getEnvVarOwned(a, "PROBE_NEEDS") catch fail("PROBE_NEEDS is not set", .{});
    var dirs = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, path, ':');
    _ = it.next();
    while (it.next()) |d| {
        if (d.len == 0 or d[0] != '/') fail("the directory {s} of LD_LIBRARY_PATH is not absolute", .{d});
        try dirs.append(a, d);
    }
    var names = std.mem.splitScalar(u8, needs, ',');
    while (names.next()) |name| {
        var found = false;
        for (dirs.items) |d| {
            var dir = std.fs.openDirAbsolute(d, .{}) catch continue;
            defer dir.close();
            const st = dir.statFile(name) catch continue;
            if (st.kind != .file) fail("{s} in {s} is not a regular file (a link was not written as a copy)", .{ name, d });
            if (st.size == 0) fail("{s} in {s} is empty", .{ name, d });
            const f = try dir.openFile(name, .{});
            defer f.close();
            var magic: [4]u8 = undefined;
            const n = try f.readAll(&magic);
            if (n != 4 or !std.mem.eql(u8, &magic, "\x7fELF")) fail("{s} in {s} is not an ELF file", .{ name, d });
            found = true;
            break;
        }
        if (!found) fail("no directory after the compiler's lib on LD_LIBRARY_PATH holds {s}", .{name});
    }
}
