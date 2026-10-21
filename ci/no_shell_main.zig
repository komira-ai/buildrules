//! The driver of the no-shell lint (ci/no_shell_check.zig, `//ci:no_shell`): reads the files the rule hands it, the allow-list, and exits 1 on a finding.
//!
//! usage: no_shell <out> <allow-list> [--require <name>]... (<name> <file>)...
//! `<name>` is the path from the repository root. `--require` names files that must be among the inputs, so a rule whose packages came up empty is red.
//! Writes <out> (the report) and exits 0 only when nothing is red; a red run prints each finding, then the allow-list the tree stands at.
const std = @import("std");
const chk = @import("no_shell_check.zig");

fn die(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("no_shell: " ++ fmt ++ "\n", args);
    return 2;
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 3) return die("usage: no_shell <out> <allow-list> [--require <name>]... (<name> <file>)...", .{});
    const allow = std.fs.cwd().readFileAlloc(a, argv[2], 1 << 20) catch |e| return die("cannot read {s}: {s}", .{ argv[2], @errorName(e) });
    var required = std.ArrayList([]const u8).init(a);
    var entries = std.ArrayList(chk.Entry).init(a);
    var k: usize = 3;
    while (k < argv.len) : (k += 2) {
        if (k + 1 >= argv.len) return die("the arguments are <name> <file> pairs", .{});
        if (std.mem.eql(u8, argv[k], "--require")) {
            try required.append(argv[k + 1]);
            continue;
        }
        const text = std.fs.cwd().readFileAlloc(a, argv[k + 1], 64 << 20) catch |e| return die("cannot read {s}: {s}", .{ argv[k], @errorName(e) });
        try entries.append(.{ .path = argv[k], .text = text });
    }
    for (required.items) |r| {
        var found = false;
        for (entries.items) |e| if (std.mem.eql(u8, e.path, r)) {
            found = true;
        };
        if (!found) return die("the required file {s} is not among the inputs: a package is missing its scrub_files", .{r});
    }
    const rep = try chk.run(a, entries.items, allow, .{});
    var out = std.ArrayList(u8).init(a);
    try out.writer().print("no_shell: {d} files scanned, {d} red, {d} stale rows (warnings)\n", .{ rep.scanned, rep.errors.items.len, rep.warnings.items.len });
    for (rep.warnings.items) |w| try out.writer().print("warning: {s}\n", .{w});
    for (rep.errors.items) |e| try out.writer().print("RED: {s}\n", .{e});
    const of = try std.fs.cwd().createFile(argv[1], .{});
    defer of.close();
    try of.writeAll(out.items);
    std.debug.print("{s}", .{out.items});
    if (rep.errors.items.len == 0) return 0;
    std.debug.print("no_shell: the allow-list that matches this tree now (ci/no_shell_allow.tsv):\n{s}", .{rep.current});
    return 1;
}
