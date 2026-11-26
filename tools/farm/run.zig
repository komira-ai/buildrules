//! `farm run`: runs one buck2 command on the farm, and runs it once more after a cut connection to the farm, once the farm answers again.
//!
//!     farm run --config <buckconfig> --log <file> --summary <file> [--wait-minutes N] -- <buck2> <subcommand> [args...]
//!
//! It runs the command with its stdout and stderr copied to this program's stdout (the job log) and to `--log` as they arrive, as `2>&1 | tee`
//! would. Then:
//!   * a run that exits 0 passes only when every action ran on the farm or came from its cache (remote.zig, `local: 0`): a runner that lost
//!     the farm's configuration must not turn green by building on itself;
//!   * a failed run of `build`, `test` or `bxl` whose every failure is a cut connection to the farm (classify.zig) runs once more, after the
//!     farm answers on the port `engine_address` of `--config` names (wait.zig: probed every 5 seconds for `--wait-minutes`, 20 by default).
//!     The first log is kept beside `--log` as `<name>.first.log`, and one line goes to `--summary` (the job summary) saying the command ran
//!     again after a cut connection and how long it waited for the farm. When the farm does not answer within the wait, the step fails
//!     saying so. The second run is final: when it is cut too, the step fails saying that; there is never a third run;
//!   * anything else is final, and says why: a failure that is not a cut (a log that mixes one real failure with any number of cuts), a run
//!     ended by a signal, a run that also ran an action on the runner, or a subcommand other than build, test or bxl. Nothing else is ever run
//!     twice, so a publish or an upload cut half way stays a failed step.
//! The exit code is buck2's own, of the last run; 1 for a passing run that is not all on the farm or a cut run whose farm did not answer; 2
//! for a wrong command line or a log that cannot be written or read.
const std = @import("std");
const classify = @import("classify.zig");
const remote = @import("remote.zig");
const wait = @import("wait.zig");
const connect = @import("connect.zig");
const args_mod = @import("args.zig");

pub const usage = "usage: farm run --config <buckconfig> --log <file> --summary <file> [--wait-minutes N] -- <buck2> <subcommand> [args...]\n";

/// How a run ended.
pub const End = union(enum) {
    exited: u8,
    signal: u32,
};

/// What runs the command and writes its log: the real one is `runTee`, the tests' play recorded output.
pub const Runner = struct {
    ctx: *anyopaque,
    run_fn: *const fn (ctx: *anyopaque, a: std.mem.Allocator, argv: []const []const u8, log: []const u8) anyerror!End,

    fn run(self: Runner, a: std.mem.Allocator, argv: []const []const u8, log: []const u8) !End {
        return self.run_fn(self.ctx, a, argv, log);
    }
};

/// Runs `argv` with stdout and stderr read as they arrive, each chunk copied to fd 1 and to a new file at `log`, and waits for it.
pub fn runTee(_: *anyopaque, a: std.mem.Allocator, argv: []const []const u8, log: []const u8) !End {
    var file = try std.fs.cwd().createFile(log, .{});
    defer file.close();
    var child = std.process.Child.init(argv, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    errdefer if (child.kill()) |_| {} else |_| {};

    var poller = std.Io.poll(a, enum { stdout, stderr }, .{ .stdout = child.stdout.?, .stderr = child.stderr.? });
    defer poller.deinit();
    var write_error: ?anyerror = null;
    while (try poller.poll()) {
        tee(poller.reader(.stdout), &file, &write_error);
        tee(poller.reader(.stderr), &file, &write_error);
    }
    tee(poller.reader(.stdout), &file, &write_error);
    tee(poller.reader(.stderr), &file, &write_error);
    const term = try child.wait();
    if (write_error) |e| return e;
    return switch (term) {
        .Exited => |c| .{ .exited = c },
        .Signal => |s| .{ .signal = s },
        .Stopped => |s| .{ .signal = s },
        .Unknown => |s| .{ .signal = s },
    };
}

/// What a reader holds, copied to fd 1 (the job log: a closed stdout must not stop the run or its log) and to the log file, then dropped.
fn tee(r: *std.Io.Reader, file: *std.fs.File, write_error: *?anyerror) void {
    const chunk = r.buffered();
    if (chunk.len == 0) return;
    std.fs.File.stdout().writeAll(chunk) catch {};
    if (write_error.* == null) file.writeAll(chunk) catch |e| {
        write_error.* = e;
    };
    r.toss(chunk.len);
}

/// `<dir>/<name>.first.log` for `<dir>/<name>.log` (`<log>.first` for a name without `.log`).
pub fn firstLogPath(a: std.mem.Allocator, log: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, log, ".log")) return std.fmt.allocPrint(a, "{s}.first.log", .{log[0 .. log.len - 4]});
    return std.fmt.allocPrint(a, "{s}.first", .{log});
}

/// The exit code for a run that ended as `end`: buck2's own, or 128 plus the signal.
fn exitCode(end: End) u8 {
    return switch (end) {
        .exited => |c| c,
        .signal => |s| @truncate(128 +% s),
    };
}

const Options = struct {
    config: []const u8,
    log: []const u8,
    summary: []const u8,
    wait_ms: u64,
    command: []const []const u8,
};

const flags = [_][]const u8{ "config", "log", "summary", "wait-minutes" };

fn parse(args: []const []const u8, w: *std.Io.Writer) !?Options {
    const dash = for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--")) break i;
    } else {
        try w.writeAll("farm run: no `--` before the command\n");
        return null;
    };
    const command = args[dash + 1 ..];
    // The command is a program and its buck2 subcommand at least.
    if (command.len < 2) {
        try w.writeAll("farm run: the command after `--` is a buck2 and its subcommand at least\n");
        return null;
    }
    var got = args_mod.Flags(flags.len).init(&flags);
    if (!try got.parse(args[0..dash], w)) return null;
    for ([_][]const u8{ "config", "log", "summary" }) |name| {
        const v = got.get(name) orelse "";
        if (v.len == 0) {
            try w.print("farm run: --{s} is required\n", .{name});
            return null;
        }
    }
    const wait_ms = (try args_mod.waitMs(got.get("wait-minutes"), "farm run", w)) orelse return null;
    return .{ .config = got.get("config").?, .log = got.get("log").?, .summary = got.get("summary").?, .wait_ms = wait_ms, .command = command };
}

/// Reads the log a run wrote, or null after the reason is on `w`.
fn readLog(a: std.mem.Allocator, path: []const u8, w: *std.Io.Writer) !?[]u8 {
    return std.fs.cwd().readFileAlloc(a, path, max_log_bytes) catch |e| {
        try w.print("farm run: cannot read {s}: {s}\n", .{ path, @errorName(e) });
        return null;
    };
}

/// The largest log read. A log over it is refused unread, never truncated: a verdict on part of a log would pass a run it had not seen.
pub const max_log_bytes: usize = 2048 * 1024 * 1024;

/// The end of a run that exited 0: 0 when it was all on the farm, 1 (and why) when not.
fn passed(a: std.mem.Allocator, log_path: []const u8, w: *std.Io.Writer) !u8 {
    const log = try readLog(a, log_path, w) orelse return 2;
    const v = remote.verdict(log);
    if (v == .ok) return 0;
    try w.writeAll("farm run: FAILED: buck2 passed, but ");
    try remote.describe(v, w);
    try w.writeAll("\n");
    return 1;
}

/// `farm run <args>`: the header says what it does. `out` is the job log (stdout); `w` gets the verdicts and errors (stderr).
pub fn main(a: std.mem.Allocator, args: []const []const u8, runner: Runner, waiter: connect.Waiter, out: *std.Io.Writer, w: *std.Io.Writer) !u8 {
    defer w.flush() catch {};
    defer out.flush() catch {};
    const p = (try parse(args, w)) orelse {
        try w.writeAll(usage);
        return 2;
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    // Read before the build: a run cut while the farm is gone must know where to wait for it.
    const cfg = std.fs.cwd().readFileAlloc(ar, p.config, 1 << 20) catch |e| {
        try w.print("farm run: cannot read the farm's buckconfig {s}: {s}\n", .{ p.config, @errorName(e) });
        return 2;
    };
    const target = (if (wait.engineAddress(cfg)) |addr| wait.hostPort(addr) else null) orelse {
        try w.print("farm run: {s} names no engine_address with a host and port: there is no farm to build on\n", .{p.config});
        return 2;
    };

    const first = runner.run(ar, p.command, p.log) catch |e| {
        try w.print("farm run: cannot run the command or write {s}: {s}\n", .{ p.log, @errorName(e) });
        return 2;
    };
    switch (first) {
        .exited => |c| if (c == 0) return passed(ar, p.log, w),
        .signal => |s| {
            try w.print("farm run: not run again: buck2 was ended by signal {d}\n", .{s});
            return exitCode(first);
        },
    }
    const subcommand = p.command[1];
    if (!classify.retriable(subcommand)) {
        try w.print("farm run: not run again: `{s}` is not build, test or bxl\n", .{subcommand});
        return exitCode(first);
    }
    const log1 = try readLog(ar, p.log, w) orelse return 2;
    const v1 = try classify.classify(ar, log1);
    if (v1 != .cut) {
        try w.writeAll("farm run: not run again: ");
        try classify.describe(v1, w);
        try w.writeAll("\n");
        return exitCode(first);
    }
    const local1 = remote.localActions(log1);
    if (local1 != 0) {
        try w.print("farm run: not run again: the cut run also ran {d} action(s) on this runner (`local: {d}`); a farm build runs every action on the farm\n", .{ local1, local1 });
        return exitCode(first);
    }
    const first_log = try firstLogPath(ar, p.log);
    std.fs.cwd().rename(p.log, first_log) catch |e| {
        try w.print("farm run: cannot keep the first log as {s}: {s}\n", .{ first_log, @errorName(e) });
        return 2;
    };
    try out.print("farm run: the connection to the farm was cut ({d} failed block(s), each buck2's `RE channel error`); waiting for the farm to answer before running `{s}` again\n", .{ v1.cut, subcommand });
    try out.flush();

    var note = std.Io.Writer.Allocating.init(ar);
    const waited = try waiter.untilAnswers(target, p.wait_ms, out);
    switch (waited) {
        .gave_up => |spent| {
            try note.writer.print("farm run: `{s}` was cut by a lost connection to the farm ({d} failed block(s)), and the farm did not answer within a wait of ", .{ subcommand, v1.cut });
            try wait.duration(&note.writer, spent);
            try note.writer.print(": not run again; the run's log is {s}", .{std.fs.path.basename(first_log)});
        },
        .answered => |spent| {
            try note.writer.print("farm run: `{s}` ran again after a cut connection to the farm (buck2's `RE channel error` in each of {d} failed block(s)), once the farm answered after a wait of ", .{ subcommand, v1.cut });
            try wait.duration(&note.writer, spent);
            try note.writer.print("; the first run's log is {s}", .{std.fs.path.basename(first_log)});
        },
    }
    connect.appendLine(p.summary, note.written()) catch |e| {
        try w.print("farm run: cannot write the job summary {s}: {s}\n", .{ p.summary, @errorName(e) });
        return 2;
    };
    try w.print("{s}\n", .{note.written()});
    if (waited == .gave_up) {
        try w.writeAll("farm run: FAILED: the farm did not answer again\n");
        return exitCode(first);
    }

    const second = runner.run(ar, p.command, p.log) catch |e| {
        try w.print("farm run: cannot run the command again or write {s}: {s}\n", .{ p.log, @errorName(e) });
        return 2;
    };
    switch (second) {
        .exited => |c| if (c == 0) {
            const code = try passed(ar, p.log, w);
            if (code == 0) try w.writeAll("farm run: the second run passed\n");
            return code;
        },
        .signal => |s| {
            try w.print("farm run: FAILED: the second run was ended by signal {d}\n", .{s});
            return exitCode(second);
        },
    }
    const log2 = try readLog(ar, p.log, w) orelse return 2;
    const v2 = try classify.classify(ar, log2);
    if (v2 == .cut) {
        try w.writeAll("farm run: FAILED: the second run was cut too: the connection to the farm was cut again (buck2's `RE channel error`); not run a third time\n");
    } else {
        try w.writeAll("farm run: FAILED: the second run failed: ");
        try classify.describe(v2, w);
        try w.writeAll("\n");
    }
    return exitCode(second);
}
