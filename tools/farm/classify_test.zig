//! The cases of classify.zig's `classify` (//tools/farm:farm_unit):
//! which failed runs are a cut connection to the farm, run once more, and
//! which are final. Each case is a log the tool must read right; the ones that
//! must be final are the ones a wrong reading would pass over.
//!
//! The logs in fixtures/ are recorded buck2 output, excerpts of failed runs on
//! the farm: build_cut.log (a build whose every failure was a cut, whole but
//! for its progress lines), build_cut_and_compile_error.log (a build with a
//! compile error and cuts: the first of each, the run's summary and its end),
//! test_failed.log (a test run with one failed test) and
//! build_cut_after_file_changes.log (a build whose every failure was a cut,
//! started after a step had written files the daemon saw change: its progress
//! and warning lines cut to two each, the action digests zeroed). A log buck2
//! printed in another run (a cut beside a test failure, a line quoting the
//! phrase) is a recorded one with lines added or changed, in the case.
//! test_cut.log is a test run whose every test failed because the connection
//! to the farm was cut before it ran: its progress lines cut to two, the
//! action digests zeroed.
const std = @import("std");
const fr = @import("classify.zig");
const t = std.testing;

const build_cut = @embedFile("fixtures/build_cut.log");
const build_cut_after_file_changes = @embedFile("fixtures/build_cut_after_file_changes.log");
const test_cut = @embedFile("fixtures/test_cut.log");

const build_mixed = @embedFile("fixtures/build_cut_and_compile_error.log");
const test_failed = @embedFile("fixtures/test_failed.log");
const build_unknown_target = @embedFile("fixtures/build_failed_unknown_target.log");

/// The first failed test of fixtures/test_cut.log and its output, as buck2 printed them.
const unrun_fail = "[2026-11-25T02:24:32.807+00:00] \xe2\x9c\x97 Fail: app//tools/build/third_party_srcs:aws_lc_mini_files_check (0.0s)";
const unrun_stdout = "[2026-11-25T02:24:32.807+00:00] ---- STDOUT ----\n";
const unrun_stderr = "[2026-11-25T02:24:32.807+00:00] ---- STDERR ----\n";
const unrun_execute = "[2026-11-25T02:24:32.807+00:00] Remote Execution Error on Execute with digest 0000000000000000000000000000000000000000000000000000000000000000:147 for ReSession GRPC-SESSION-ID\n";
const unrun_cut = "[2026-11-25T02:24:32.807+00:00] Error: (Error was returned on the stream by RE: RE channel error: code: 'Unknown error', message: \"h2 protocol error: error reading a body from connection\", source: hyper::Error(Body, Error { kind: Io(Custom { kind: BrokenPipe, error: \"stream closed because of a broken pipe\" }) }): error reading a body from connection: stream closed because of a broken pipe)\n";
/// The second failed test of fixtures/test_cut.log, the line after the first's output.
const unrun_next = "[2026-11-25T02:24:32.807+00:00] \xe2\x9c\x97 Fail: app//tests/scan_binding_links:test_scan_binding_links (0.0s)";
/// A line of the test's own.
const own = "[2026-11-25T02:24:32.807+00:00] the test's own line\n";

const cut_error = "Error: (Error was returned on the stream by RE: RE channel error: code: 'Unknown error', message: \"h2 protocol error: error reading a body from connection\", source: None)";

/// One cut block, as buck2 prints it (the lines of fixtures/build_cut.log).
const cut_block =
    "[2026-11-21T16:48:35.653+00:00] Action failed: app//src/a:a (app//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (mojo_build)\n" ++
    "[2026-11-21T16:48:35.653+00:00] Internal error (stage: remote_call_error): Remote Execution Error on Execute with digest 00:141 for ReSession GRPC-SESSION-ID\n" ++
    "[2026-11-21T16:48:35.653+00:00] " ++ cut_error ++ "\n" ++
    "[2026-11-21T16:48:35.653+00:00] Remote action digest: '00:141'\n" ++
    "[2026-11-21T16:48:35.653+00:00] Stdout: <empty>\n" ++
    "[2026-11-21T16:48:35.653+00:00] Stderr: <empty>\n\n";

fn classify(a: std.mem.Allocator, log: []const u8) !fr.Verdict {
    return fr.classify(a, log);
}

fn edit(a: std.mem.Allocator, log: []const u8, from: []const u8, to: []const u8) ![]u8 {
    try t.expect(std.mem.indexOf(u8, log, from) != null); // the recorded log has the text the case changes
    return std.mem.replaceOwned(u8, a, log, from, to);
}

/// `log` without each block whose first line holds `marker`: its lines up to
/// and with the empty line that ends it.
fn dropBlocks(a: std.mem.Allocator, log: []const u8, marker: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var dropping = false;
    var dropped: usize = 0;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |l| {
        if (std.mem.indexOf(u8, l, marker) != null) {
            dropping = true;
            dropped += 1;
        }
        if (dropping) {
            if (l.len == 0) dropping = false;
            continue;
        }
        try out.appendSlice(a, l);
        try out.append(a, '\n');
    }
    try t.expect(dropped > 0);
    return out.toOwnedSlice(a);
}

fn expectCut(log: []const u8, blocks: usize) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try classify(arena.allocator(), log);
    try t.expectEqualDeep(fr.Verdict{ .cut = blocks }, v);
}

/// The log is final, for the reason `tag`, with `line` the line that says so.
fn expectFinal(log: []const u8, tag: std.meta.Tag(fr.Verdict), line: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try classify(arena.allocator(), log);
    try t.expectEqual(tag, std.meta.activeTag(v));
    const got = switch (v) {
        .failure, .test_status, .unexplained, .unmatched_target => |l| l,
        .cut, .no_failure => "",
    };
    try t.expectEqualStrings(line, got);
}

// ---- a cut, run again --------------------------------------------------------

test "a recorded build whose every failure is a cut is a cut, counting each block" {
    // two actions in flight, each printed once as it failed and once under BUILD ERRORS
    try expectCut(build_cut, 4);
}

test "buck2's own warning lines beside the cut are not errors" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const warn = "[2026-11-21T15:40:33.203+00:00] \x1b[2m2026-11-21T15:40:33.120769Z\x1b[0m \x1b[33m WARN\x1b[0m \x1b[2mremote_execution::client\x1b[0m\x1b[2m:\x1b[0m Transient error (attempt 1/5), retrying in 120ms\n";
    try expectCut(try edit(arena.allocator(), build_cut, "[2026-11-21T16:48:35.702+00:00] Cache hits", warn ++ "[2026-11-21T16:48:35.702+00:00] Cache hits"), 4);
}

test "CRLF line ends read the same" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try expectCut(try std.mem.replaceOwned(u8, arena.allocator(), build_cut, "\n", "\r\n"), 4);
}

test "a recorded cut build that starts with buck2's changed-file lines is a cut" {
    // thirteen actions in flight, each printed once as it failed and once under BUILD ERRORS
    try expectCut(build_cut_after_file_changes, 26);
}

/// The changed-file lines buck2 printed before the run of fixtures/build_cut_after_file_changes.log.
const file_changes =
    "[2026-11-25T00:07:53.435+00:00] File changed: app//src/anomaly/mopm.toml\n" ++
    "[2026-11-25T00:07:53.435+00:00] 415 additional file change events\n";

test "buck2's changed-file lines beside the cut are not errors" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try expectCut(try edit(arena.allocator(), build_cut, "[2026-11-21T16:23:14.887+00:00] RE Session", file_changes ++ "[2026-11-21T16:23:14.887+00:00] RE Session"), 4);
}

test "a recorded test run whose every test failed for a cut before it ran is a cut, counting each test" {
    try expectCut(test_cut, 56);
}

test "the list of failed tests that buck2 cuts short is one of its lines" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectCut(try edit(a, test_cut, "  ...and 46 more not shown...\n", ""), 56);
    inline for ([_][]const u8{ "  ...and more not shown...", "  ...and 46 more not shown", "  ...and 46 more not shown... and an error" }) |line| {
        try expectFinal(try edit(a, test_cut, "  ...and 46 more not shown...", line), .unexplained, line);
    }
}

test "a test run whose only failure is a cut build of a test is a cut" {
    const log = "[2026-11-21T16:00:00.000+00:00] Build ID: 00000000-0000-0000-0000-000000000000\n" ++ cut_block ++
        "[2026-11-21T16:00:01.000+00:00] \xe2\x9c\x93 Pass: app//src/b:test_b (0.4s)\n" ++
        "[2026-11-21T16:00:01.000+00:00] ---- STDOUT ----\n" ++
        "[2026-11-21T16:00:01.000+00:00]\n" ++
        "[2026-11-21T16:00:01.000+00:00] ---- STDERR ----\n" ++
        "[2026-11-21T16:00:01.000+00:00]\n" ++
        "Tests finished: \x1b[38;5;10mPass 1\x1b[39m. Fail 0. Timeout 0. Fatal 0. Skip 0. Omit 0. Infra Failure 0. Build failure 1\n" ++
        "1 BUILDS FAILED\n";
    try expectCut(log, 1);
}

test "a failed test whose head, before its output, has buck2's cut line is a cut" {
    const log = "[2026-11-21T16:00:01.000+00:00] \xe2\x9c\x97 Fail: app//src/b:test_b (0.4s)\n" ++
        "[2026-11-21T16:00:01.000+00:00] " ++ cut_error ++ "\n" ++
        "[2026-11-21T16:00:01.000+00:00] ---- STDOUT ----\n" ++
        "[2026-11-21T16:00:01.000+00:00]\n" ++
        "[2026-11-21T16:00:01.000+00:00] ---- STDERR ----\n" ++
        "[2026-11-21T16:00:01.000+00:00]\n" ++
        "Tests finished: Pass 0. Fail 1. Timeout 0. Fatal 0. Skip 0. Omit 0. Infra Failure 0. Build failure 0\n" ++
        "1 TESTS FAILED\n" ++
        "  \xe2\x9c\x97 app//src/b:test_b (cfg)\n";
    try expectCut(log, 1);
}

// ---- a real failure, final ---------------------------------------------------

const compile_error = "[2026-11-21T13:40:17.627+00:00] Action failed: app//tools/build/examples/cshim:add (app//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (c_compile add_files/add.c (pic))";

test "a recorded build with a compile error beside cuts is final, naming the compile error" {
    try expectFinal(build_mixed, .failure, compile_error);
}

test "a recorded test failure is final" {
    try expectFinal(test_failed, .failure, "[2026-10-25T13:04:11.131+00:00] \xe2\x9c\x97 Fail: app//src/app_proto_codec:test_float32_json_binades (9:00.5s)");
}

test "a test failure beside a cut is final: the cut does not excuse it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), test_failed, "[2026-10-25T13:04:11.131+00:00] \xe2\x9c\x97 Fail:", cut_block ++ "[2026-10-25T13:04:11.131+00:00] \xe2\x9c\x97 Fail:");
    try expectFinal(log, .failure, "[2026-10-25T13:04:11.131+00:00] \xe2\x9c\x97 Fail: app//src/app_proto_codec:test_float32_json_binades (9:00.5s)");
}

test "a failed test whose own output prints buck2's cut line is final: the line is the test's, after its output marker" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), test_failed, "[2026-10-25T13:04:11.131+00:00] The library's package", "[2026-10-25T13:04:11.131+00:00] " ++ cut_error ++ "\n[2026-10-25T13:04:11.131+00:00] The library's package");
    try expectFinal(log, .failure, "[2026-10-25T13:04:11.131+00:00] \xe2\x9c\x97 Fail: app//src/app_proto_codec:test_float32_json_binades (9:00.5s)");
}

test "a cut test with any output of its own is final: the test ran" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = unrun_fail ++ "\n" ++ unrun_stdout;
    // stdout that is not empty
    try expectFinal(try edit(a, test_cut, head, head ++ own), .failure, unrun_fail);
    // a line before the two lines of buck2's, between them, after them
    try expectFinal(try edit(a, test_cut, head ++ "[2026-11-25T02:24:32.807+00:00]\n" ++ unrun_stderr, head ++ "[2026-11-25T02:24:32.807+00:00]\n" ++ unrun_stderr ++ own), .failure, unrun_fail);
    try expectFinal(try edit(a, test_cut, unrun_execute ++ unrun_cut ++ unrun_next, unrun_execute ++ own ++ unrun_cut ++ unrun_next), .failure, unrun_fail);
    try expectFinal(try edit(a, test_cut, unrun_execute ++ unrun_cut ++ unrun_next, unrun_execute ++ unrun_cut ++ own ++ unrun_next), .failure, unrun_fail);
}

test "a failed test whose stderr has only one of buck2's two cut-run lines, or both out of order, is final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = unrun_execute ++ unrun_cut ++ unrun_next;
    try expectFinal(try edit(a, test_cut, first, unrun_cut ++ unrun_next), .failure, unrun_fail);
    try expectFinal(try edit(a, test_cut, first, unrun_execute ++ unrun_next), .failure, unrun_fail);
    try expectFinal(try edit(a, test_cut, first, unrun_cut ++ unrun_execute ++ unrun_next), .failure, unrun_fail);
}

test "a failed test whose output is only buck2's stderr of a cut run is a cut, with or without its stdout" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the first test's stdout section dropped: its head goes straight to STDERR
    try expectCut(try edit(a, test_cut, unrun_fail ++ "\n" ++ unrun_stdout ++ "[2026-11-25T02:24:32.807+00:00]\n", unrun_fail ++ "\n"), 56);
    // the log ends right after the first test's output, with no counts after it
    const end = std.mem.indexOf(u8, test_cut, unrun_next).?;
    try expectCut(test_cut[0..end], 1);
}

test "a cut test with a line of its own without buck2's prefix is final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = unrun_fail ++ "\n" ++ unrun_stdout;
    try expectFinal(try edit(a, test_cut, head, head ++ "the test's own line\n"), .failure, unrun_fail);
    try expectFinal(try edit(a, test_cut, unrun_cut ++ unrun_next, unrun_cut ++ "the test's own line\n" ++ unrun_next), .failure, unrun_fail);
}

test "a cut test whose two lines are not back to back, or come twice, is final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFinal(try edit(a, test_cut, unrun_execute ++ unrun_cut ++ unrun_next, unrun_execute ++ "[2026-11-25T02:24:32.807+00:00]\n" ++ unrun_cut ++ unrun_next), .failure, unrun_fail);
    try expectFinal(try edit(a, test_cut, unrun_execute ++ unrun_cut ++ unrun_next, unrun_execute ++ unrun_cut ++ unrun_cut ++ unrun_next), .failure, unrun_fail);
    try expectFinal(try edit(a, test_cut, unrun_execute ++ unrun_cut ++ unrun_next, unrun_execute ++ unrun_cut ++ unrun_stdout ++ unrun_next), .failure, unrun_fail);
}

test "a passing test whose output is buck2's cut-run lines is judged as before: its cut line is outside the block" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const pass = "[2026-11-25T02:24:32.807+00:00] \xe2\x9c\x93 Pass: app//tools/build/third_party_srcs:aws_lc_mini_files_check (0.0s)";
    const log = try edit(arena.allocator(), test_cut, unrun_fail ++ "\n", pass ++ "\n");
    try expectFinal(log, .unexplained, unrun_cut[0 .. unrun_cut.len - 1]);
}

test "a compile error whose output quotes the phrase is final: an action's output is not buck2's line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the compile error alone: the recorded run without its cut blocks
    const alone = try dropBlocks(a, build_mixed, "Action failed: app//tools/build/proto-codegen");
    try t.expect(std.mem.indexOf(u8, alone, "RE channel error") == null);
    try expectFinal(alone, .failure, compile_error);
    try expectFinal(try edit(a, alone, "1 error generated.\n", cut_error ++ "\n1 error generated.\n"), .failure, compile_error);
}

test "an action that failed on its own and quotes the cut line after Stderr is final" {
    const log = "[2026-11-21T16:00:00.000+00:00] Action failed: app//src/a:a (cfg) (zig_test)\n" ++
        "[2026-11-21T16:00:00.000+00:00] Remote command returned non-zero exit code 1\n" ++
        "[2026-11-21T16:00:00.000+00:00] Stdout: <empty>\n" ++
        "[2026-11-21T16:00:00.000+00:00] Stderr:\n" ++
        "[2026-11-21T15:59:59.000+00:00] " ++ cut_error ++ "\n\n" ++
        "BUILD FAILED\n";
    try expectFinal(log, .failure, "[2026-11-21T16:00:00.000+00:00] Action failed: app//src/a:a (cfg) (zig_test)");
}

test "a cut line without buck2's prefix in a block's head does not make it a cut" {
    const log = "[2026-11-21T16:00:00.000+00:00] Action failed: app//src/a:a (cfg) (zig_test)\n" ++ cut_error ++ "\n" ++
        "[2026-11-21T16:00:00.000+00:00] Stdout: <empty>\n\nBUILD FAILED\n";
    try expectFinal(log, .failure, "[2026-11-21T16:00:00.000+00:00] Action failed: app//src/a:a (cfg) (zig_test)");
}

test "a block whose head has an error other than the channel's is final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), build_cut, "RE channel error: code: 'Unknown error'", "RE upload error: code: 'Unknown error'");
    try expectFinal(log, .failure, "[2026-11-21T16:48:35.653+00:00] Action failed: app//src/bench_q6_phases:app_bench_q6_phases_main (app//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (mojo_build)");
}

test "an error outside every block is final, though every block is a cut" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const other = "[2026-11-21T15:40:34.803+00:00] Error: (Failed to make BatchReadBlobs request: code: 'The operation was cancelled', message: \"operation was canceled\")";
    const log = try edit(arena.allocator(), build_cut, "[2026-11-21T16:48:35.702+00:00] Cache hits", other ++ "\n[2026-11-21T16:48:35.702+00:00] Cache hits");
    try expectFinal(log, .unexplained, other);
}

test "a compile error after buck2's changed-file lines is final: the lines excuse no failure" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try expectFinal(try edit(arena.allocator(), build_mixed, compile_error, file_changes ++ compile_error), .failure, compile_error);
}

test "a line only shaped like buck2's changed-file lines is final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const at = "[2026-11-21T16:23:14.887+00:00] RE Session";
    inline for ([_][]const u8{
        "[2026-11-25T00:07:53.435+00:00] File changed: ",
        "[2026-11-25T00:07:53.435+00:00] File changed: app//src/a/mopm.toml Error: boom",
        "[2026-11-25T00:07:53.435+00:00] additional file change events",
        "[2026-11-25T00:07:53.435+00:00] 415 additional file change events, and an error",
        "[2026-11-25T00:07:53.435+00:00] x415 additional file change events",
        "File changed: app//src/anomaly/mopm.toml",
    }) |line| {
        try expectFinal(try edit(arena.allocator(), build_cut, at, line ++ "\n" ++ at), .unexplained, line);
    }
}

test "a bare cut line outside every block is not a block: the log is final" {
    try expectFinal("[2026-11-21T16:00:00.000+00:00] " ++ cut_error ++ "\nBUILD FAILED\n", .unexplained, "[2026-11-21T16:00:00.000+00:00] " ++ cut_error);
}

test "an error of buck2's own log at ERROR level is not a warning: final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const line = "[2026-11-21T15:40:33.203+00:00] 2026-11-21T15:40:33.120769Z ERROR buck2_server: the daemon lost its state";
    try expectFinal(try edit(arena.allocator(), build_cut, "[2026-11-21T16:48:35.702+00:00] Cache hits", line ++ "\n[2026-11-21T16:48:35.702+00:00] Cache hits"), .unexplained, line);
}

test "an error after a passing test's output is judged outside the block: final, though the test may have printed it" {
    const log = "[2026-11-21T16:00:01.000+00:00] \xe2\x9c\x93 Pass: app//src/b:test_b (0.4s)\n" ++
        "[2026-11-21T16:00:01.000+00:00] ---- STDOUT ----\n" ++
        "[2026-11-21T16:00:01.000+00:00] checking the error path\n" ++
        "[2026-11-21T16:00:01.000+00:00] Error: the analysis of app//src/c:c failed\n" ++ cut_block ++
        "Tests finished: Pass 1. Fail 0. Timeout 0. Fatal 0. Skip 0. Omit 0. Infra Failure 0. Build failure 1\n";
    try expectFinal(log, .unexplained, "[2026-11-21T16:00:01.000+00:00] Error: the analysis of app//src/c:c failed");
}

test "a passing test's other output stays in its block beside a cut" {
    const log = "[2026-11-21T16:00:01.000+00:00] \xe2\x9c\x93 Pass: app//src/b:test_b (0.4s)\n" ++
        "[2026-11-21T16:00:01.000+00:00] ---- STDOUT ----\n" ++
        "[2026-11-21T16:00:01.000+00:00] FAIL is what this test checks the parser rejects\n" ++
        "[2026-11-21T16:00:01.000+00:00]\n" ++ cut_block ++
        "Tests finished: Pass 1. Fail 0. Timeout 0. Fatal 0. Skip 0. Omit 0. Infra Failure 0. Build failure 1\n";
    try expectCut(log, 1);
}

test "a line of buck2's between an action's Stdout and Stderr ends the block" {
    const line = "[2026-11-21T16:00:00.000+00:00] Error: the daemon went away";
    const log = "[2026-11-21T16:00:00.000+00:00] Action failed: app//src/a:a (cfg) (mojo_build)\n" ++
        "[2026-11-21T16:00:00.000+00:00] " ++ cut_error ++ "\n" ++
        "[2026-11-21T16:00:00.000+00:00] Stdout:\nsome output\n" ++ line ++ "\nBUILD FAILED\n";
    try expectFinal(log, .unexplained, line);
}

test "an error after BUILD FAILED is final: an analysis error is not a cut" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), build_cut, "BUILD FAILED\n", "BUILD FAILED\nError running analysis for `app//src/c:c`\n");
    try expectFinal(log, .unexplained, "Error running analysis for `app//src/c:c`");
}

test "a recorded analysis failure with no block is final" {
    try expectFinal(build_unknown_target, .unexplained, "Unknown target `nonexistent` from package `app//tools/build/ci/parity`.");
}

test "a target buck2 failed to build with no failed action of its own is final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const line = "Failed to build 'app//src/other:other (app//tools/build/platforms:linux-x86_64#03cc1a891c89e4be)'";
    try expectFinal(try edit(arena.allocator(), build_cut, "BUILD FAILED\n", "BUILD FAILED\n" ++ line ++ "\n"), .unmatched_target, line);
}

test "a target named by a prefix of a cut block's target is not matched by it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const line = "Failed to build 'app//src/bench_q6_phases:app_bench_q6'";
    try expectFinal(try edit(arena.allocator(), build_cut, "BUILD FAILED\n", "BUILD FAILED\n" ++ line ++ "\n"), .unmatched_target, line);
}

test "a fatal test is final, even beside cuts" {
    const fatal = "[2026-11-21T16:00:02.000+00:00] \xe2\x9a\xa0 Fatal: app//src/b:test_b";
    try expectFinal(cut_block ++ fatal ++ "\n", .test_status, fatal);
}

test "a timed-out, fatal or infrastructure-failed count on the test line is final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const counts = "Tests finished: Pass 1. Fail 0. Timeout 0. Fatal 0. Skip 0. Omit 0. Infra Failure 0. Build failure 1";
    try expectCut(cut_block ++ counts ++ "\n", 1);
    for ([_][]const u8{ "Timeout 0", "Fatal 0", "Infra Failure 0" }) |zero| {
        const one = try std.mem.replaceOwned(u8, a, zero, "0", "2");
        const line = try std.mem.replaceOwned(u8, a, counts, zero, one);
        try expectFinal(try std.mem.concat(a, u8, &.{ cut_block, line, "\n" }), .test_status, line);
    }
    // a line without one of the counts cannot show it is zero
    const short = "Tests finished: Pass 1. Fail 0. Timeout 0. Skip 0. Omit 0. Infra Failure 0. Build failure 1";
    try expectFinal(cut_block ++ short ++ "\n", .test_status, short);
    const listing = "Tests finished: Listing failed 1. Pass 1. Fail 0. Timeout 0. Fatal 0. Skip 0. Omit 0. Infra Failure 0. Build failure 1";
    try expectFinal(cut_block ++ listing ++ "\n", .test_status, listing);
}

test "a failed run with no failure block is final" {
    try expectFinal("", .no_failure, "");
    try expectFinal("[2026-11-21T16:00:00.000+00:00] Build ID: 00000000-0000-0000-0000-000000000000\nBUILD FAILED\n", .no_failure, "");
    // a buck2 that exited non-zero after it said the build succeeded
    try expectFinal(@embedFile("fixtures/build_remote.log"), .no_failure, "");
}

test "the verdict says why, for the job log" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try fr.describe(.{ .cut = 4 }, &w);
    try t.expectEqualStrings("every failure (4 block(s)) is a cut connection to the farm (buck2's `RE channel error`)", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fr.describe(.{ .failure = "X" }, &w);
    try t.expectEqualStrings("a failure that is not a cut connection: X", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fr.describe(.{ .test_status = "X" }, &w);
    try t.expectEqualStrings("a test result a cut connection does not explain: X", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fr.describe(.{ .unexplained = "X" }, &w);
    try t.expectEqualStrings("an error outside the failed actions and tests: X", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fr.describe(.{ .unmatched_target = "X" }, &w);
    try t.expectEqualStrings("a target failed with no failed action of its own: X", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fr.describe(.no_failure, &w);
    try t.expectEqualStrings("no failed action or test in the log", w.buffered());
}

// ---- recorded runs of the Rust workspaces and mopm on the farm -----------------------------------------------------------------------
//
// cut_chunk_connect.log, clippy.log, rustfmt.log and cut_skipped.log are the buck2 output of farm builds of a Rust workspace and of mopm
// (`buck2 build //:ci`, `buck2 build --skip-incompatible-targets @targets`), with the address of the farm, its instance name and the build ids
// replaced.

const cut_chunk_connect = @embedFile("fixtures/cut_chunk_connect.log");
const cut_skipped = @embedFile("fixtures/cut_skipped.log");
const clippy = @embedFile("fixtures/clippy.log");
const rustfmt = @embedFile("fixtures/rustfmt.log");

test "a recorded Rust build cut while buck2's client retried writing chunks and connecting is a cut: its warnings are not failures" {
    // the client's own retries are in the log, warnings of `Error writing chunk of` and of `tcp connect error ... Connection timed out`
    try t.expect(std.mem.indexOf(u8, cut_chunk_connect, "Error writing chunk of: ") != null);
    try t.expect(std.mem.indexOf(u8, cut_chunk_connect, "Connection timed out") != null);
    // 47 actions in flight, each printed once as it failed and once under BUILD ERRORS
    try expectCut(cut_chunk_connect, 94);
}

test "a recorded build with buck2's list of skipped incompatible targets is a cut" {
    try expectCut(cut_skipped, 2);
}

test "the list of skipped targets is passed over only in its own shape, after its own head" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = "[2026-11-26T20:18:27.976+00:00] Skipped 27 incompatible targets:\n";
    const entry = "[2026-11-26T20:18:27.976+00:00]   mopm//:cli_test_macos (mopm//platforms:linux_x86_64#fc5c3458a61941da)";
    // one target skipped, as buck2 words it
    try expectCut(try edit(a, cut_skipped, head, "[2026-11-26T20:18:27.976+00:00] Skipped 1 incompatible target:\n"), 2);
    // the entries without their head are lines buck2 does not print around a cut
    try expectFinal(try edit(a, cut_skipped, head, ""), .unexplained, entry);
    // a head without a count, or with more after it
    inline for ([_][]const u8{
        "[2026-11-26T20:18:27.976+00:00] Skipped incompatible targets:",
        "[2026-11-26T20:18:27.976+00:00] Skipped 27 incompatible targets: and an error",
    }) |line| {
        try expectFinal(try edit(a, cut_skipped, head, line ++ "\n"), .unexplained, line);
    }
    // an entry of another shape ends the list, and is judged outside it
    inline for ([_][]const u8{
        "[2026-11-26T20:18:27.976+00:00]   error: mopm//:cli_test_macos (mopm//platforms:linux_x86_64#fc5c3458a61941da)",
        "[2026-11-26T20:18:27.976+00:00]   mopm//:cli_test_macos (mopm//platforms:linux_x86_64 and more)",
        "[2026-11-26T20:18:27.976+00:00]   mopm//:cli_test_macos",
        "[2026-11-26T20:18:27.976+00:00]   cli_test_macos (cfg)",
        "[2026-11-26T20:18:27.976+00:00]   mopm//:cli_test_macos ()",
        "[2026-11-26T20:18:27.976+00:00] mopm//:cli_test_macos (cfg)",
    }) |line| {
        try expectFinal(try edit(a, cut_skipped, entry ++ "\n", line ++ "\n"), .unexplained, line);
    }
    // a line without buck2's prefix ends the list too
    try expectFinal(try edit(a, cut_skipped, entry ++ "\n", "  mopm//:cli_test_macos (cfg)\n"), .unexplained, "  mopm//:cli_test_macos (cfg)");
    // the head ends a failed test's output: the cut test before it is still a cut
    const unrun = "[2026-11-26T20:18:27.976+00:00] \xe2\x9c\x97 Fail: mopm//:t (0.0s)\n" ++
        "[2026-11-26T20:18:27.976+00:00] ---- STDOUT ----\n" ++
        "[2026-11-26T20:18:27.976+00:00] ---- STDERR ----\n" ++
        "[2026-11-26T20:18:27.976+00:00] Remote Execution Error on Execute with digest 00:1 for ReSession GRPC-SESSION-ID\n" ++
        "[2026-11-26T20:18:27.976+00:00] " ++ cut_error ++ "\n";
    try expectCut(try edit(a, cut_skipped, head, unrun ++ head), 3);
}

test "a recorded clippy error of a Rust build is final" {
    try expectFinal(clippy, .failure, "[2026-11-26T17:05:08.074+00:00] Action failed: tierstore//crates/tierstore:tierstore-0.3.0_fb2de23c28_lint (buildrules//platforms:linux_x86_64#27db57317ae2fec7) (rustc tierstore-0.3.0_fb2de23c28_lint)");
}

test "a recorded rustfmt difference is final, beside a cut or not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const first = "[2026-11-26T17:23:32.513+00:00] Action failed: jobscheduler//crates/js-agent:fmt_rustfmt (buildrules//platforms:linux_x86_64#27db57317ae2fec7) (rustfmt edition_2024)";
    try expectFinal(rustfmt, .failure, first);
    try expectFinal(try edit(arena.allocator(), rustfmt, first, cut_block ++ first), .failure, first);
}

// ---- buck2's warning of a target without outputs -------------------------------------------------------------------------------------

/// The warning, as buck2 printed it before the run of fixtures/build_cut.log (its address is put together here: the scrub reads a path of
/// that shape as a home directory).
const no_outputs = "[2026-11-21T16:23:13.295+00:00] Target app//:test_weld (app//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) does not have any outputs. This means the rule did not define any outputs. See https://buck2.build/docs/" ++ "us" ++ "ers/faq/common_issues/#why-does-my-target-not-have-any-outputs for more information";

test "buck2's warning of a target without outputs beside the cut is not an error, and a line only shaped like it is" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const at = "[2026-11-21T16:23:14.887+00:00] RE Session";
    try expectCut(try edit(a, build_cut, at, no_outputs ++ "\n" ++ at), 4);
    inline for ([_][]const u8{
        "[2026-11-21T16:23:13.295+00:00] Target app//:test_weld (app//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) does not have any outputs.",
        "[2026-11-21T16:23:13.295+00:00] Target  does not have any outputs. This means the rule did not define any outputs. See https://buck2.build/docs/" ++ "us" ++ "ers/faq/common_issues/#why-does-my-target-not-have-any-outputs for more information",
        "[2026-11-21T16:23:13.295+00:00] Target app//:x (cfg) does not have any outputs. This means the rule did not define any outputs. See https://buck2.build/docs/ for more information",
        "[2026-11-21T16:23:13.295+00:00] Targets app//:x (cfg) does not have any outputs.",
    }) |line| {
        try expectFinal(try edit(a, build_cut, at, line ++ "\n" ++ at), .unexplained, line);
    }
}
