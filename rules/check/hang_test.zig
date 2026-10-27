//! The cases of the hang limit of `check marker` (`--hang-limit-s N --hang-label L`, runspec.zig `startLimited`, docs/contract.md section 12.8): a test that has
//! not finished within the limit is stopped with its whole process group, the status is 125, no file is written, and one line says so. How the supervisor does
//! it (the kill, the survivors, the signals) is tested in rules/gate; these cases hold that `marker` runs the test under it and says what the contract says.
//!
//! No case waits for a time to pass. The supervisor's clock is replaced by one that reads 0 and then far past any limit, so the limit passes at the supervisor's
//! first look, and the program it stops (`toolbox sleep 1d`) could not have finished on its own: the verdict does not depend on how fast the host is.

const std = @import("std");
const t = std.testing;
const posix = std.posix;
const kit = @import("checkkit.zig");
const supervise = @import("supervise");
const rs = @import("runspec.zig");

const label = "//pkg:test_x";
const hang_line = "hang limit: //pkg:test_x did not finish within 5 s and was stopped; a test never waits on time, so this means it hung (an event that never came)\n";

// ---- the supervisor's clock and kill, replaced ----------------------------------------------------------------------

var clock_reads: u32 = 0;
var clock_now: u64 = 0;

/// 0 at the first reading (the start), a thousand seconds from the second on: past every limit these cases give.
fn clockPastTheLimit() ?u64 {
    clock_reads += 1;
    if (clock_reads == 2) clock_now = 1_000_000;
    return clock_now;
}

/// A sleep that takes no time: the clock moves on by `ms` (the supervisor sleeps between two looks for survivors of the kill).
fn sleepMovesTheClock(ms: u64) void {
    clock_now += ms;
}

/// A clock that cannot be read.
fn clockFails() ?u64 {
    return null;
}

/// A clock that stays at 0 and, at the second reading, has this process sent SIGTERM (the signal the supervisor must answer by ending the run).
fn clockThatSignals() ?u64 {
    clock_reads += 1;
    if (clock_reads == 2) posix.raise(posix.SIG.TERM) catch {};
    return 0;
}

fn fakeSurvivor(alloc: std.mem.Allocator, pgid: i32) ?[]supervise.Member {
    _ = pgid;
    const m = alloc.alloc(supervise.Member, 1) catch return null;
    m[0] = .{ .pid = 4242, .state = 'S', .comm = "stuck" };
    return m;
}

const KillFn = @TypeOf(supervise.plat.kill);
var real_kill: KillFn = undefined;

/// The first signal sent to a process group, and how many live members the group had when it was sent.
var group_killed: posix.pid_t = 0;
var group_killed_with: u8 = 0;
var members_at_kill: usize = 0;

/// Before the group is killed, waits until the group has two members (the program and the child it started), so the kill is known to have had a grandchild
/// to reach: the wait is for that state to exist, not for a time to pass. The state is looked at 50 million times at most; a program that never starts its
/// child leaves `members_at_kill` at 1 and the case fails on it.
fn recordingKill(pid: posix.pid_t, sig: u8) void {
    if (pid < 0 and group_killed == 0) {
        group_killed = -pid;
        group_killed_with = sig;
        var looks: usize = 0;
        while (looks < 50_000_000) : (looks += 1) {
            const members = supervise.plat.group_members(std.heap.page_allocator, -pid) orelse break;
            members_at_kill = members.len;
            if (members.len >= 2) break;
            std.Thread.yield() catch {};
        }
    }
    real_kill(pid, sig);
}

/// Passes every signal on, and when the last of a run goes out (the one to the tether, a process and not a group) puts the clock back to the start, so a
/// test that runs the same command line over and over (the allocation sweep) starts every run at 0.
fn killThenRestart(pid: posix.pid_t, sig: u8) void {
    real_kill(pid, sig);
    if (pid > 0) {
        clock_reads = 0;
        clock_now = 0;
    }
}

fn reset() void {
    clock_reads = 0;
    clock_now = 0;
    group_killed = 0;
    group_killed_with = 0;
    members_at_kill = 0;
}

fn failed(c: *kit.Case) ![]const u8 {
    return std.fmt.allocPrint(c.alloc(), "check marker: TEST FAILED: {s}\n", .{c.toolbox});
}

// ---- a test within its limit -----------------------------------------------------------------------------------------

// Defect caught: the limit changes the result of a test that finishes (a marker not written, a line said, a status other than the test's).
test "marker --hang-limit-s: a test that finishes within the limit passes as it does without one: the file, no output" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o", "--hang-limit-s", "1800", "--hang-label", label }, &.{"true"}), 0, "", "");
    try t.expectEqualStrings("passed\n", try c.read("o"));
}

// Defect caught: a failing test under the limit is given the hang status or the hang line, or its own status is lost.
test "marker --hang-limit-s: a test that fails within the limit is red with its own status and TEST FAILED, and no hang line" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o", "--hang-limit-s", "1800", "--hang-label", label }, &.{"false"}), 1, "", try failed(&c));
    try t.expect(!c.exists("o"));
    // its own status, not always 1; a program that is not there is 127
    try kit.expectFailure(try c.runTool(&.{ "marker", "--out", "o", "--hang-limit-s", "1800", "--hang-label", label }, &.{"nosuchapplet"}), 127, "TEST FAILED");
    try t.expect(!c.exists("o"));
}

// Defect caught: the supervised program is started in another directory than the options say (they are shared with the start without a limit).
test "marker --hang-limit-s: the program runs in the working directory the options say" {
    var c = try kit.Case.init();
    defer c.deinit();
    try c.tmp.dir.makePath("data");
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o", "--cwd", "data", "--hang-limit-s", "1800", "--hang-label", label }, &.{ "mkdir", "-p", "made" }), 0, "", "");
    try t.expect(c.exists("data/made"));
    try t.expect(!c.exists("made"));
}

// Defect caught: a variable dropped, doubled or cut at an `=` on its way to the supervised program's environment.
test "the environment of a supervised program is one NAME=VALUE entry per variable, values kept whole" {
    var c = try kit.Case.init();
    defer c.deinit();
    var env = std.process.EnvMap.init(c.alloc());
    try env.put("A", "1");
    try env.put("EMPTY", "");
    try env.put("EQ", "x=y z");
    const entries = try rs.environmentEntries(c.alloc(), &env);
    try t.expectEqual(@as(usize, 3), entries.len);
    var seen = [_]bool{ false, false, false };
    for (entries) |e| {
        const text = std.mem.span(e.?);
        if (std.mem.eql(u8, text, "A=1")) seen[0] = true;
        if (std.mem.eql(u8, text, "EMPTY=")) seen[1] = true;
        if (std.mem.eql(u8, text, "EQ=x=y z")) seen[2] = true;
    }
    try t.expectEqualSlices(bool, &.{ true, true, true }, &seen);
    try t.expect(entries[3] == null);
}

// ---- a test that hangs ---------------------------------------------------------------------------------------------------

// Defect caught: no limit (the run never ends), a status other than 125 (the test's 137), a marker written, the line missing, said twice, or saying the test was
// slow; an earlier marker file removed.
test "marker --hang-limit-s: a test past the limit is stopped: status 125, no file, TEST FAILED, then the one hang line" {
    var c = try kit.Case.init();
    defer c.deinit();
    const saved = supervise.plat;
    defer supervise.plat = saved;
    reset();
    supervise.plat.now_ms = clockPastTheLimit;
    try c.put("o", "from an earlier run");
    const r = try c.runTool(&.{ "marker", "--out", "o", "--hang-limit-s", "5", "--hang-label", label }, &.{ "sleep", "1d" });
    try kit.expectResult(r, 125, "", try std.fmt.allocPrint(c.alloc(), "{s}{s}", .{ try failed(&c), hang_line }));
    try t.expectEqualStrings("from an earlier run", try c.read("o"));
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, r.err, "hang limit:"));
    try t.expect(std.mem.indexOf(u8, r.err, "slow") == null);
    try t.expect(std.mem.indexOf(u8, r.err, "timed out") == null);
}

// Defect caught: the limit kills the program alone (a child it started lives on), or kills a process and not the group, or kills the group before the child
// exists (then the case does not hold what it says). The group is the program and the child `env` started; both are gone when the run ends, and the
// supervisor's own scan for survivors (its second line, absent here) found nothing.
test "marker --hang-limit-s: the whole process group is stopped, a grandchild included" {
    var c = try kit.Case.init();
    defer c.deinit();
    const saved = supervise.plat;
    defer supervise.plat = saved;
    reset();
    real_kill = supervise.plat.kill;
    supervise.plat.now_ms = clockPastTheLimit;
    supervise.plat.kill = recordingKill;
    // `env` starts `toolbox sleep 1d` and waits for it: the program (env) has a child that is a grandchild of the supervisor.
    const r = try c.runTool(&.{ "marker", "--out", "o", "--hang-limit-s", "5", "--hang-label", label }, &.{ "env", c.toolbox, "sleep", "1d" });
    try kit.expectResult(r, 125, "", try std.fmt.allocPrint(c.alloc(), "{s}{s}", .{ try failed(&c), hang_line }));
    try t.expect(!c.exists("o"));
    try t.expect(group_killed > 0);
    try t.expectEqual(@as(u8, posix.SIG.KILL), group_killed_with);
    try t.expect(members_at_kill >= 2);
    // Nothing of the group is alive now.
    const left = supervise.plat.group_members(std.heap.page_allocator, group_killed) orelse return error.GroupNotReadable;
    try t.expectEqual(@as(usize, 0), left.len);
}

// Defect caught: a process the kill did not reach goes unreported (the line names it), or the report is mistaken for the verdict (a second line that starts with
// `hang limit:`), or it changes the status.
test "marker --hang-limit-s: a process that survives the kill is named on a line of its own before the one hang line, and the status is still 125" {
    var c = try kit.Case.init();
    defer c.deinit();
    const saved = supervise.plat;
    defer supervise.plat = saved;
    reset();
    supervise.plat.now_ms = clockPastTheLimit;
    supervise.plat.sleep_ms = sleepMovesTheClock;
    supervise.plat.group_members = fakeSurvivor;
    const note = "check marker: after the hang limit, processes of the test survived the kill of its process group (pid state comm: 4242 S stuck;); they are killed now\n";
    const r = try c.runTool(&.{ "marker", "--out", "o", "--hang-limit-s", "5", "--hang-label", label }, &.{ "sleep", "1d" });
    try kit.expectResult(r, 125, "", try std.fmt.allocPrint(c.alloc(), "{s}{s}{s}", .{ try failed(&c), note, hang_line }));
    try t.expect(!c.exists("o"));
    // The same with the allocator failing at each of its allocations in turn (the note is built from several), and with a stderr that cannot be written: the status is
    // 125 whenever the run got that far.
    real_kill = supervise.plat.kill;
    supervise.plat.kill = killThenRestart;
    reset();
    c.environ = &.{ "HANG_A=1", "HANG_B=two" };
    try kit.sweep(&c, try c.line(&.{ "marker", "--out", "o", "--hang-limit-s", "5", "--hang-label", label }, &.{ "sleep", "1d" }), &.{"o"});
    c.stderr_closed = true;
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o", "--hang-limit-s", "5", "--hang-label", label }, &.{ "sleep", "1d" }), 125, "", "");
}

// Defect caught: a signal to the tool (the executor cancelling the action) leaves the test running, or is reported as a hang or as a pass.
test "marker --hang-limit-s: a SIGTERM to the tool ends the test's group and is 128+15, not a hang" {
    var c = try kit.Case.init();
    defer c.deinit();
    const saved = supervise.plat;
    defer supervise.plat = saved;
    reset();
    supervise.plat.now_ms = clockThatSignals;
    const r = try c.runTool(&.{ "marker", "--out", "o", "--hang-limit-s", "5", "--hang-label", label }, &.{ "sleep", "1d" });
    try kit.expectResult(r, 143, "", try failed(&c));
    try t.expect(!c.exists("o"));
}

// Defect caught: a clock that cannot be read runs the test with no limit (the run would wait for the test), or passes.
test "marker --hang-limit-s: a clock that cannot be read is red and says so, and the test is not left running" {
    var c = try kit.Case.init();
    defer c.deinit();
    const saved = supervise.plat;
    defer supervise.plat = saved;
    supervise.plat.now_ms = clockFails;
    const r = try c.runTool(&.{ "marker", "--out", "o", "--hang-limit-s", "5", "--hang-label", label }, &.{ "sleep", "1d" });
    const said = try std.fmt.allocPrint(c.alloc(), "check marker: the clock cannot be read, so {s} could not be held to its hang limit and was not left running\n{s}", .{ c.toolbox, try failed(&c) });
    try kit.expectResult(r, 1, "", said);
    try t.expect(!c.exists("o"));
}

// ---- the options ----------------------------------------------------------------------------------------------------------

// Defect caught: a limit without a label (the verdict would name nothing) or a label without a limit is accepted; a limit of 0, a sign, a leading zero, a
// fraction or text is taken as a number; the limit is taken with --capture (whose output the supervisor does not hold back); another command takes it.
test "marker --hang-limit-s: the limit and the label go together, the limit is a positive whole number, and not with --capture" {
    var c = try kit.Case.init();
    defer c.deinit();
    const prog: kit.Args = &.{"true"};
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o", "--hang-limit-s", "5" }, prog), 2, "", "check marker: --hang-limit-s and --hang-label go together: the limit and the label the verdict names\n");
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o", "--hang-label", label }, prog), 2, "", "check marker: --hang-limit-s and --hang-label go together: the limit and the label the verdict names\n");
    for ([_][]const u8{ "0", "-5", "+5", "05", "5.5", "5s", "", "five", "99999999999999999999" }) |bad| {
        const want = try std.fmt.allocPrint(c.alloc(), "check marker: --hang-limit-s {s}: expected a positive whole number of seconds\n", .{bad});
        try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o", "--hang-limit-s", bad, "--hang-label", label }, prog), 2, "", want);
    }
    try kit.expectResult(try c.runTool(&.{ "marker", "--out", "o", "--capture", "--hang-limit-s", "5", "--hang-label", label }, prog), 2, "", "check marker: --hang-limit-s does not go with --capture: the supervised test writes where the process does\n");
    try kit.expectResult(try c.runTool(&.{ "run", "--hang-limit-s", "5", "--hang-label", label }, prog), 2, "", "check run: --hang-limit-s is not an option of this command\n");
    try kit.expectResult(try c.runTool(&.{ "expect", "--want", "", "--out", "o", "--hang-limit-s", "5", "--hang-label", label }, prog), 2, "", "check expect: --hang-limit-s is not an option of this command\n");
    try t.expect(!c.exists("o"));
    try kit.expectResult(try c.run(&.{ "marker", "--out", "o", "--hang-limit-s" }), 2, "", "check marker: --hang-limit-s needs a value\n");
}

// Defect caught: an allocation that fails while the supervised start is prepared is swallowed (the test runs, or the marker is written).
test "marker --hang-limit-s: an allocation that fails is out of memory, not a pass, and leaves no file" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.environ = &.{ "HANG_A=1", "HANG_B=two" };
    try kit.sweep(&c, try c.line(&.{ "marker", "--out", "o", "--hang-limit-s", "1800", "--hang-label", label }, &.{"true"}), &.{"o"});
}

// Defect caught: a program that cannot be started under a hang limit is given the hang verdict or a pass, or loses the status (127 not there, 126 not runnable) it has
// without a limit.
test "marker --hang-limit-s: a program that cannot be started keeps its status 127 and is red, with no hang line" {
    var c = try kit.Case.init();
    defer c.deinit();
    const r = try c.run(&.{ "marker", "--out", "o", "--hang-limit-s", "5", "--hang-label", label, "--", "/no/such/program" });
    try kit.expectResult(r, 127, "", "check marker: TEST FAILED: /no/such/program\n");
    try t.expect(!c.exists("o"));
}
