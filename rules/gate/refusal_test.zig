//! What `gate` says when it is called wrongly, as a person is shown it: the mode that does not exist, each required option left out, the limits that cannot go
//! together, an option after the environment, a status file that is not there. The cases in mojo_test.zig, rust_test.zig and step_test.zig hold the other usage
//! errors and read most messages by their first words; these are the ones they leave to a prefix or do not reach, and each reads the whole sentence and the exit status,
//! and requires that nothing was written (no marker, no status file, nothing on stdout).
//!
//! Mutant (one per row): remove the check, or the `return` of its message, and the row's case goes red.

const std = @import("std");
const kit = @import("testkit.zig");

const Env = struct {
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    dir: []const u8,

    fn init() !*Env {
        const e = try std.heap.page_allocator.create(Env);
        e.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        e.a = e.arena.allocator();
        e.dir = try kit.tempDir(e.a);
        return e;
    }

    fn deinit(e: *Env) void {
        e.arena.deinit();
        std.heap.page_allocator.destroy(e);
    }

    /// The gate over `argv`: it must refuse with `status` and exactly `msg` on stderr, and write nothing.
    fn refuses(e: *Env, name: []const u8, argv: []const []const u8, status: u8, msg: []const u8) !void {
        const r = try kit.runGate(e.a, e.dir, argv, .{});
        if (r.status != status or !std.mem.eql(u8, r.err, msg) or r.out.len != 0) {
            std.debug.print("{s}: exit {d} (want {d}), stderr:\n{s}\nwant:\n{s}\nstdout:\n{s}\n", .{ name, r.status, status, r.err, msg, r.out });
            return error.TestUnexpectedResult;
        }
        for ([_][]const u8{ "passed", "status" }) |f| {
            const p = try std.fmt.allocPrint(e.a, "{s}/{s}", .{ e.dir, f });
            try std.testing.expect(!kit.exists(p));
        }
    }
};

const MOJO = [_][]const u8{ "--busybox", "bb", "--runtime-lib", "rt/lib", "--label", "//x:y", "--test", "root/bin/t", "--marker", "passed" };

/// `gate mojo` with the options of MOJO, but the pair that starts with `skip`; then `more`.
fn mojo(a: std.mem.Allocator, skip: ?[]const u8, more: []const []const u8) ![]const []const u8 {
    var l = std.ArrayList([]const u8).empty;
    try l.append(a, "mojo");
    var i: usize = 0;
    while (i < MOJO.len) : (i += 2) {
        if (skip != null and std.mem.eql(u8, MOJO[i], skip.?)) continue;
        try l.appendSlice(a, MOJO[i .. i + 2]);
    }
    try l.appendSlice(a, more);
    return l.items;
}

test "a mode that is not one is refused, naming the modes" {
    const e = try Env.init();
    defer e.deinit();
    try e.refuses("an unknown mode", &.{"frobnicate"}, 2, "gate: unknown mode frobnicate; the modes are mojo, rust and step\n");
    try e.refuses("a mode in the wrong case", &.{ "Mojo", "--label", "x" }, 2, "gate: unknown mode Mojo; the modes are mojo, rust and step\n");
    try e.refuses("no mode", &.{}, 2, "gate: usage: gate mojo|rust|step <options> (README.md)\n");
}

test "mojo: each required option left out is named" {
    const e = try Env.init();
    defer e.deinit();
    for ([_][]const u8{ "--busybox", "--runtime-lib", "--label", "--test", "--marker" }) |flag| {
        const msg = try std.fmt.allocPrint(e.a, "gate_runner: usage error: {s} is required\n", .{flag});
        try e.refuses(flag, try mojo(e.a, flag, &.{}), 2, msg);
    }
}

test "mojo: the limits that go together, and the ones that cannot" {
    const e = try Env.init();
    defer e.deinit();
    try e.refuses("a deadline with no runner timeout", try mojo(e.a, null, &.{ "--deadline-s", "30" }), 2, "test_deadline: usage error: --deadline-s and --runner-timeout-s go together\n");
    try e.refuses("a runner timeout with no deadline", try mojo(e.a, null, &.{ "--runner-timeout-s", "90" }), 2, "test_deadline: usage error: --deadline-s and --runner-timeout-s go together\n");
    try e.refuses("a limit with no report", try mojo(e.a, null, &.{ "--limit-s", "5" }), 2, "gate_runner: usage error: --limit-s and --limit-report go together\n");
    try e.refuses("a report with no limit", try mojo(e.a, null, &.{ "--limit-report", "coverage" }), 2, "gate_runner: usage error: --limit-s and --limit-report go together\n");
    try e.refuses("a deadline and a coverage limit", try mojo(e.a, null, &.{ "--deadline-s", "30", "--runner-timeout-s", "90", "--limit-s", "5", "--limit-report", "coverage" }), 2, "gate_runner: usage error: --limit-s and --deadline-s are two limits\n");
}

test "mojo: an option after the environment or the arguments is refused, whatever it is" {
    const e = try Env.init();
    defer e.deinit();
    // The order is part of the contract: the environment and the arguments come last, so a flag after them cannot be taken for the test's own argument.
    try e.refuses("a label after --env", try mojo(e.a, "--label", &.{ "--env", "A=b", "--label", "//x:z" }), 2, "gate_runner: --label after an --env or --arg\n");
    try e.refuses("the marker after --arg", try mojo(e.a, "--marker", &.{ "--arg", "x", "--marker", "passed" }), 2, "gate_runner: --marker after an --env or --arg\n");
    try e.refuses("a limit after --env", try mojo(e.a, null, &.{ "--env", "A=b", "--limit-s", "5" }), 2, "gate_runner: --limit-s after an --env or --arg\n");
}

test "step: a status file to wait for that is not there is named, and the step does not run" {
    const e = try Env.init();
    defer e.deinit();
    try e.refuses("an --after file that is not there", &.{ "step", "--status", "status", "--limit-s", "5", "--after", "nope", "--", "x/exit" }, 1, "mut_step: cannot read nope\n");
    try e.refuses("no --status", &.{ "step", "--limit-s", "5", "--", "x/exit" }, 2, "mut_step: usage error\n");
    try e.refuses("no --limit-s", &.{ "step", "--status", "status", "--", "x/exit" }, 2, "mut_step: usage error\n");
    try e.refuses("--status given twice", &.{ "step", "--status", "a", "--status", "b", "--limit-s", "5", "--", "x/exit" }, 2, "mut_step: usage error\n");
}

test "rust: a timeout is a positive number of seconds, and the options are exactly the five" {
    const e = try Env.init();
    defer e.deinit();
    const five = [_][]const u8{ "--busybox", "bb", "--label", "//r:t", "--test", "h/rust_ok", "--marker", "passed", "--timeout-s" };
    for ([_][]const u8{ "", "0", "-1", "1.5", "ten", "1s" }) |t| {
        const msg = try std.fmt.allocPrint(e.a, "rust test_runner: timeout must be a positive number of seconds, not '{s}'\n", .{t});
        var argv = std.ArrayList([]const u8).empty;
        try argv.append(e.a, "rust");
        try argv.appendSlice(e.a, &five);
        try argv.append(e.a, t);
        try e.refuses(t, argv.items, 2, msg);
    }
    // one option twice and another not at all is still ten arguments
    try e.refuses("an option twice", &.{ "rust", "--busybox", "bb", "--busybox", "bb", "--test", "t", "--marker", "m", "--timeout-s", "5" }, 2, "rust test_runner: usage error\n");
}
