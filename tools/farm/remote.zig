//! Whether a buck2 run that passed ran every action on the farm or took it from its cache: `farm run` (run.zig) fails a passing run unless
//! this says so, so a runner whose buckconfig lost the farm cannot turn green by building on itself.
//!
//! What buck2 prints (recorded in fixtures/):
//!   * a run that executed any action ends with `Commands: N (cached: N, remote: N, local: N)`, for `build` and for `bxl` alike;
//!   * `Cache hits: N%` is printed beside `Commands:`, and only then: both count build actions, and a cache hit is one;
//!   * a run that touched NO build action (everything already built, or a query-only script) prints neither line. A build or bxl run of that
//!     kind prints `Network: up 0B  down 0B`. A test run of that kind can still move bytes, because it looks its test results up in the
//!     farm's cache, and it ends with `Tests finished:`. Test executions themselves are never counted in `Commands:`;
//!   * `BUILD FAILED` / `BXL FAILED` end a failed run.
//! So a missing summary is accepted only when the log shows that no build action was touched: the zero-network line, or a finished test run
//! with no `Cache hits:` line. A missing summary beside network traffic in any other log, or beside a `Cache hits:` line, means buck2's output
//! changed shape, and that is a failure: the check must not pass by not finding what it looks for.
const std = @import("std");

pub const Verdict = union(enum) {
    ok,
    /// `Commands:` lines whose `local:` counts add up to this, more than zero.
    local_execution: u64,
    /// A `Commands:` line with no readable `local: N`.
    unreadable_summary,
    /// No `Commands:` line, and the log does not show that no build action was touched.
    missing_summary,
    /// buck2 said the run failed.
    run_failed,
};

/// The line without buck2's `[timestamp] ` prefix, and without a trailing CR.
fn content(line: []const u8) []const u8 {
    var s = std.mem.trimRight(u8, line, "\r");
    if (s.len > 0 and s[0] == '[') {
        if (std.mem.indexOf(u8, s, "] ")) |i| s = s[i + 2 ..];
    }
    return s;
}

/// The number after `local: ` in a summary line, if it is there and ends at a non-digit.
fn localField(summary: []const u8) ?u64 {
    const key = "local: ";
    const at = std.mem.indexOf(u8, summary, key) orelse return null;
    const rest = summary[at + key.len ..];
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

fn isZeroNetwork(c: []const u8) bool {
    const zero = "Network: up 0B  down 0B";
    if (!std.mem.startsWith(u8, c, zero)) return false;
    return c.len == zero.len or c[zero.len] == ' ';
}

/// The actions the `Commands:` lines of `log` say ran on the runner (0 when there is none, or none can be read).
pub fn localActions(log: []const u8) u64 {
    var local: u64 = 0;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |raw| {
        const c = content(raw);
        if (std.mem.startsWith(u8, c, "Commands: ")) local +|= localField(c) orelse 0;
    }
    return local;
}

pub fn verdict(log: []const u8) Verdict {
    var summaries: usize = 0;
    var zero_network = false;
    var cache_hits_line = false;
    var tests_finished = false;
    var failed = false;
    var unreadable = false;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |raw| {
        const c = content(raw);
        if (std.mem.startsWith(u8, c, "Commands: ")) {
            summaries += 1;
            if (localField(c) == null) unreadable = true;
        } else if (isZeroNetwork(c)) {
            zero_network = true;
        } else if (std.mem.startsWith(u8, c, "Cache hits: ")) {
            cache_hits_line = true;
        } else if (std.mem.startsWith(u8, c, "Tests finished: ")) {
            tests_finished = true;
        } else if (std.mem.eql(u8, c, "BUILD FAILED") or std.mem.eql(u8, c, "BXL FAILED")) {
            failed = true;
        }
    }
    if (failed) return .run_failed;
    if (unreadable) return .unreadable_summary;
    const local = localActions(log);
    if (local != 0) return .{ .local_execution = local };
    if (summaries == 0) {
        const no_build_action = zero_network or (tests_finished and !cache_hits_line);
        if (!no_build_action) return .missing_summary;
    }
    return .ok;
}

/// Why a passing run fails this check, for the job log (`ok` says it passed).
pub fn describe(v: Verdict, w: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (v) {
        .ok => try w.writeAll("every action ran on the farm or came from its cache (`local: 0`)"),
        .local_execution => |n| try w.print("{d} action(s) ran on this runner (`local: {d}` in the Commands summary); a farm build runs every action on the farm", .{ n, n }),
        .unreadable_summary => try w.writeAll("a `Commands:` line has no `local: N` field; buck2's summary changed shape"),
        .missing_summary => try w.writeAll("no `Commands:` summary line, and the log does not show that no build action ran; it cannot show the build was on the farm"),
        .run_failed => try w.writeAll("the log ends a failed buck2 run (BUILD FAILED / BXL FAILED)"),
    }
}
