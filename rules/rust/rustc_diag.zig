//! rustc_diag: a diagnostics run of rustc, what an editor's check on save reads (a member's `:flycheck`, rules/rust/cargo.bzl).
//!
//! usage: rustc_diag <file> -- <program> [arguments...]
//!
//! Runs the program (rustc_launch with a lint unit's arguments) with `--error-format=json -o <scratch>/diag/out` added at the end: rustc
//! writes its diagnostics to standard error as JSON, one per line, and its own output into the action's scratch directory. Standard error
//! is copied to <file>. A run in which rustc only found errors in the code (its status 1) succeeds, so the diagnostics are a build output
//! like any other, cached on the inputs; any other status (an internal compiler error, a signal, a refusal of the launcher) is the run's,
//! with what was written shown on standard error. A tool of its own beside rustc_launch, which every rustc action runs: changing the
//! launcher would change the key of every compile.
//!
//! Exit status: 0 for rustc's 0 or 1; the program's other status (128 + N for signal N); 2 for a usage error or a program that cannot run.

const std = @import("std");

/// The status of the run for rustc's: 1 means it reported errors in the code, which is what the run is for.
pub fn status(code: u8) u8 {
    return if (code == 1) 0 else code;
}

/// Runs `argv` and the arguments that make the run a diagnostics run, with its standard error copied to `file`. Returns the run's status.
pub fn run(a: std.mem.Allocator, file: []const u8, scratch: []const u8, argv: []const []const u8) !u8 {
    const out_dir = try std.fs.path.join(a, &.{ scratch, "diag" });
    try std.fs.cwd().makePath(out_dir);
    var full = std.ArrayList([]const u8).empty;
    try full.appendSlice(a, argv);
    try full.appendSlice(a, &.{ "--error-format=json", "-o", try std.fs.path.join(a, &.{ out_dir, "out" }) });
    const f = try std.fs.cwd().createFile(file, .{});
    defer f.close();
    var child = std.process.Child.init(full.items, a);
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var rbuf: [4096]u8 = undefined;
    var r = child.stderr.?.reader(&rbuf);
    var wbuf: [4096]u8 = undefined;
    var w = f.writer(&wbuf);
    _ = try r.interface.streamRemaining(&w.interface);
    try w.interface.flush();
    return status(codeOf(try child.wait()));
}

/// A finished child as an exit status: its own, 128 + N for signal N, 1 for anything else.
pub fn codeOf(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| @truncate(128 +% s),
        else => 1,
    };
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 4 or !std.mem.eql(u8, args[2], "--")) {
        std.debug.print("usage: rustc_diag <file> -- <program> [arguments...]\n", .{});
        std.process.exit(2);
    }
    const scratch_env = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch "";
    const scratch = if (scratch_env.len == 0) ".br_scratch" else scratch_env;
    const code = run(a, args[1], scratch, args[3..]) catch |e| {
        std.debug.print("rustc_diag: cannot run {s}: {s}\n", .{ args[3], @errorName(e) });
        std.process.exit(2);
    };
    if (code != 0) {
        // Not a finding of the code: show what was said (an internal compiler error is text, not JSON).
        const text = std.fs.cwd().readFileAlloc(a, args[1], 1 << 26) catch "";
        std.debug.print("rustc_diag: the run exited {d}:\n{s}\n", .{ code, text });
    }
    std.process.exit(code);
}
