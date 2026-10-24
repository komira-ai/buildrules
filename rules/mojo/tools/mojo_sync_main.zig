//! The command line of `mojo_sync` (rules/mojo/tools/mojo_sync.zig has the steps and their tests; rules/mojo/sync.bzl runs it).
//!
//! usage: mojo_sync stage --src DIR --work DIR --out DIR --buildrules EXE --mopm EXE --mopm-version V [--toolchains DIR] [--committed DIR] [--hint TEXT] PACKAGE...
//!        mojo_sync apply --from DIR [--to DIR]
//! Exit codes: 0 ok, 1 the sync failed or the committed files are stale, 2 usage.

const std = @import("std");
const S = @import("mojo_sync.zig");

const usage = "usage: mojo_sync stage --src DIR --work DIR --out DIR --buildrules EXE --mopm EXE --mopm-version V [--toolchains DIR] [--committed DIR] [--hint TEXT] PACKAGE...\n       mojo_sync apply --from DIR [--to DIR]\n";

fn real(a: std.mem.Allocator, p: []const u8) ![]u8 {
    return std.fs.cwd().realpathAlloc(a, p);
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    const args = S.parseArgs(a, argv[1..]) catch |e| {
        std.debug.print("mojo_sync: {s}\n{s}", .{ @errorName(e), usage });
        return 2;
    };
    if (args.mode == .apply) return runApply(a, args);
    return runStage(a, args);
}

fn runApply(a: std.mem.Allocator, args: S.Args) !u8 {
    var from = try std.fs.cwd().openDir(args.from, .{ .iterate = true });
    defer from.close();
    var to = std.fs.cwd().openDir(args.to, .{}) catch |e| {
        std.debug.print("mojo_sync: cannot open {s}: {s}\n", .{ args.to, @errorName(e) });
        return 2;
    };
    defer to.close();
    var wrote = std.ArrayList([]const u8).empty;
    S.apply(a, from, to, &wrote) catch |e| switch (e) {
        error.NotARoot => {
            std.debug.print("mojo_sync: {s} has no .buckconfig: run this from the repository root (or pass --to DIR)\n", .{args.to});
            return 2;
        },
        else => return e,
    };
    for (wrote.items) |p| std.debug.print("wrote   {s}\n", .{p});
    if (wrote.items.len == 0) std.debug.print("mojo_sync: every generated file was already what a sync writes\n", .{});
    return 0;
}

fn runStage(a: std.mem.Allocator, args: S.Args) !u8 {
    try S.stage(a, args);
    var work = try std.fs.cwd().openDir(args.work, .{});
    defer work.close();
    if (try S.toolchainMismatch(a, work, args.packages, args.mopm_version)) |why| {
        std.debug.print("mojo_sync: {s}\n", .{why});
        return 1;
    }
    var cmd = std.ArrayList([]const u8).empty;
    try cmd.appendSlice(a, &.{ try real(a, args.buildrules), "mojo", "sync", "--dir", try real(a, args.work), "--toolchains", args.toolchains, "--mopm", try real(a, args.mopm) });
    try cmd.appendSlice(a, args.packages);
    var child = std.process.Child.init(cmd.items, a);
    const term = try child.spawnAndWait();
    const code: u8 = switch (term) {
        .Exited => |c| c,
        else => 1,
    };
    if (code != 0) return code;
    try std.fs.cwd().makePath(args.out);
    var out = try std.fs.cwd().openDir(args.out, .{ .iterate = true });
    defer out.close();
    var missing: []const u8 = "";
    S.harvest(a, work, out, args.packages, args.toolchains, &missing) catch |e| switch (e) {
        error.NotWritten => {
            std.debug.print("mojo_sync: the sync did not write {s}\n", .{missing});
            return 1;
        },
        else => return e,
    };
    if (args.committed) |c| {
        var committed = try std.fs.cwd().openDir(c, .{ .iterate = true });
        defer committed.close();
        const hint = if (args.hint.len == 0) "" else try std.fmt.allocPrint(a, "\n  fix: {s}", .{args.hint});
        const bad = try S.compare(a, out, committed, hint);
        for (bad) |m| std.debug.print("{s}\n", .{m});
        if (bad.len != 0) return 1;
    }
    return 0;
}
