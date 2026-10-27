//! The driver of the committed-graph check (ci/lock_hashes_check.zig, `//ci:lock_hashes`).
//!
//! usage: lock_hashes <out> [--require <name>]... (<name> <file>)...
//! `<name>` is the path from the repository root. `--require` names files that must be among the inputs, so a rule whose packages came up empty is red.
//! Writes <out> (the report) and exits 0 only when every lock agrees with the files it lists.
const std = @import("std");
const chk = @import("lock_hashes_check.zig");

fn die(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("lock_hashes: " ++ fmt ++ "\n", args);
    return 2;
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) return die("usage: lock_hashes <out> [--require <name>]... (<name> <file>)...", .{});
    var required = std.ArrayList([]const u8).init(a);
    var entries = std.ArrayList(chk.Entry).init(a);
    var k: usize = 2;
    while (k < argv.len) : (k += 2) {
        if (k + 1 >= argv.len) return die("the arguments are <name> <file> pairs", .{});
        if (std.mem.eql(u8, argv[k], "--require")) {
            try required.append(argv[k + 1]);
            continue;
        }
        try entries.append(.{ .path = argv[k], .file = argv[k + 1] });
    }
    for (required.items) |r| {
        var found = false;
        for (entries.items) |e| if (std.mem.eql(u8, e.path, r)) {
            found = true;
        };
        if (!found) return die("the required file {s} is not among the inputs: a package is missing its scrub_files", .{r});
    }
    const rep = try chk.run(a, entries.items);
    if (rep.locks == 0) return die("no {s} among {d} files: the packages came up empty", .{ chk.lock_suffix, entries.items.len });
    var out = std.ArrayList(u8).init(a);
    try out.writer().print("lock_hashes: {d} locks, {d} sources, {d} red\n", .{ rep.locks, rep.sources, rep.errors.items.len });
    for (rep.errors.items) |e| try out.writer().print("RED: {s}\n", .{e});
    const of = try std.fs.cwd().createFile(argv[1], .{});
    defer of.close();
    try of.writeAll(out.items);
    std.debug.print("{s}", .{out.items});
    return if (rep.errors.items.len == 0) 0 else 1;
}
