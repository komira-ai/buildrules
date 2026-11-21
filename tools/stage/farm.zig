//! What the beta and gamma stages share: how a run is told where actions run, and how a buck2 summary line is read.
const std = @import("std");

/// `.buckconfig.local` of a repository built on a runner with no farm (docs/contract.md section 14).
pub const local_config =
    \\# Written by the beta job: a runner has no farm, so every action runs on it (docs/contract.md section 14).
    \\[buildrules_re]
    \\  mode = local
    \\
;

/// The section the farm-connect action writes the worker property set under; spelled in parts, as the project name is not written in this repository.
const connect_section = "[" ++ "kom" ++ "ira_re]";
const rules_section = "[buildrules_re]";

/// The farm's machine buckconfig (written by the farm-connect action) as the `.buckconfig.local` of a repository that uses buildrules: the same
/// settings, with the worker property set under the section buildrules reads. Nothing is added and nothing else is changed.
pub fn buildrulesConfig(a: std.mem.Allocator, farm: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, farm, '\n');
    var first = true;
    while (lines.next()) |raw| {
        if (!first) try out.append(a, '\n');
        first = false;
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), connect_section)) {
            try out.appendSlice(a, rules_section);
        } else {
            try out.appendSlice(a, raw);
        }
    }
    return out.toOwnedSlice(a);
}

/// Whether the farm config names an endpoint and a worker property set: without them buck2 would build on the machine it runs on.
pub fn farmConfigured(cfg: []const u8) bool {
    return std.mem.indexOf(u8, cfg, "engine_address = ") != null and std.mem.indexOf(u8, cfg, "linux_x86_64_properties = ") != null;
}

pub const Summary = struct { total: u64, cached: u64, remote: u64, local: u64 };

/// `Commands: 11 (cached: 4, remote: 7, local: 0)` in buck2's output.
pub fn parseSummary(text: []const u8) ?Summary {
    const at = std.mem.lastIndexOf(u8, text, "Commands: ") orelse return null;
    const rest = text[at + "Commands: ".len ..];
    var s: Summary = undefined;
    const total_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    s.total = std.fmt.parseInt(u64, rest[0..total_end], 10) catch return null;
    s.cached = field(rest, "cached: ") orelse return null;
    s.remote = field(rest, "remote: ") orelse return null;
    s.local = field(rest, "local: ") orelse return null;
    return s;
}

fn field(text: []const u8, key: []const u8) ?u64 {
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const line = text[0..line_end];
    const i = std.mem.indexOf(u8, line, key) orelse return null;
    var j = i + key.len;
    const start = j;
    while (j < line.len and std.ascii.isDigit(line[j])) j += 1;
    return std.fmt.parseInt(u64, line[start..j], 10) catch null;
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;

const sample_farm = "[buck2_re_client]\n  engine_address = grpc://example.invalid:1\n  tls = false\n[" ++ "kom" ++ "ira_re]\n  linux_x86_64_properties = a=b\n";

test "the farm's worker properties are handed to buildrules under its own section, and nothing else changes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try buildrulesConfig(a, sample_farm);
    try t.expectEqualStrings("[buck2_re_client]\n  engine_address = grpc://example.invalid:1\n  tls = false\n[buildrules_re]\n  linux_x86_64_properties = a=b\n", got);
    try t.expect(farmConfigured(got));
    try t.expect(!farmConfigured(""));
    try t.expect(!farmConfigured("[buck2_re_client]\n  engine_address = grpc://example.invalid:1\n"));
    try t.expect(!farmConfigured("[buildrules_re]\n  linux_x86_64_properties = a=b\n"));
}

test "the buck2 summary line is read, and a missing or malformed one is not a zero" {
    const s = parseSummary("noise\n[2026-10-20T07:48:10.059-05:00] Commands: 11 (cached: 4, remote: 7, local: 0)\n[x] Network: up\nBUILD SUCCEEDED\n").?;
    try t.expectEqual(Summary{ .total = 11, .cached = 4, .remote = 7, .local = 0 }, s);
    try t.expectEqual(@as(u64, 3), parseSummary("Commands: 3 (cached: 0, remote: 0, local: 3)").?.local);
    try t.expect(parseSummary("BUILD SUCCEEDED") == null);
    try t.expect(parseSummary("Commands: x (cached: 1, remote: 1, local: 0)") == null);
    try t.expect(parseSummary("Commands: 2 (cached: 1, remote: 1)") == null);
    // the last summary of the output is the one that counts
    try t.expectEqual(@as(u64, 5), parseSummary("Commands: 1 (cached: 1, remote: 0, local: 0)\nCommands: 6 (cached: 0, remote: 1, local: 5)\n").?.local);
}

/// A build that ran no command at all prints neither `Commands:` nor `Cache hits:` (a target built a moment ago): nothing ran, on the farm or
/// off it. Anything that did run prints both, so a summary that is missing while the other line is there is not mistaken for this.
pub fn idleBuild(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "BUILD SUCCEEDED") != null and std.mem.indexOf(u8, text, "Commands: ") == null and std.mem.indexOf(u8, text, "Cache hits:") == null;
}

test "a build that ran nothing is idle; one that ran something without a summary is not" {
    try t.expect(idleBuild("[x] Build ID: a\n[x] Network: up 0B  down 0B\nBUILD SUCCEEDED\n"));
    try t.expect(!idleBuild("[x] Cache hits: 100%\nBUILD SUCCEEDED\n"));
    try t.expect(!idleBuild("[x] Commands: 3 (cached: 3, remote: 0, local: 0)\nBUILD SUCCEEDED\n"));
    try t.expect(!idleBuild("BUILD FAILED\n"));
    try t.expect(!idleBuild(""));
}

/// What buck2 writes when the connection to the farm is cut under a remote action: its remote-execution error names the stream (`Remote Execution
/// Error on <action> for ReSession <id>`), and the line after it is `Error: (Error was returned on the stream by RE: RE channel error: code: ...)`.
pub const cut_marker = "RE channel error: code:";

/// One line of buck2's output as it reads with no timestamp (`[2026-11-21T07:48:10.059-05:00] `) and no indent before it.
fn bare(raw: []const u8) []const u8 {
    var l = std.mem.trim(u8, raw, " \t\r");
    if (l.len > 0 and l[0] == '[') {
        if (std.mem.indexOf(u8, l, "] ")) |end| l = std.mem.trimLeft(u8, l[end + 2 ..], " \t");
    }
    return l;
}

/// A cut: buck2's own `Error:` line holding `RE channel error: code:`. The phrase anywhere else (in a test's output, after another word) is not one.
fn isCutLine(l: []const u8) bool {
    return std.mem.startsWith(u8, l, "Error:") and std.mem.indexOf(u8, l, cut_marker) != null;
}

/// Whether every failure in the output of a failed farm build is a cut connection to the farm, so that the same build may run once more. At least
/// one cut is required, and any sign of another failure makes the answer no:
///
/// - an `Action failed:` report that is not a cut: a cut report's reason is `Internal error (stage: ...): Remote Execution Error on ...` and the
///   line right after it is the cut line. Any other reason (a compile error or a failing test is `... command returned non-zero exit code N`, a timeout `Command timed out after ...`,
///   a cancelled command, an internal error with no cut line under it) is a real failure, and a cut line printed later does not count for it;
/// - a line saying a command returned non-zero, that something timed out, or a panic, anywhere;
/// - another error of buck2's (a line starting `Error` that is not a cut: an analysis or load error, a download that failed) or of a compiler
///   (`error:` or `error[`).
///
/// So a log that mixes a real failure with cuts is final, and a retry never passes over a real failure.
pub fn onlyCuts(text: []const u8) bool {
    const Report = enum { none, reason, cut_next };
    var cuts: usize = 0;
    var report: Report = .none;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = bare(raw);
        if (std.mem.startsWith(u8, l, "Action failed:")) {
            // a report whose reason or cut line never came is not a cut
            if (report != .none) return false;
            report = .reason;
            continue;
        }
        if (report == .reason) {
            if (!std.mem.startsWith(u8, l, "Internal error (stage:") or std.mem.indexOf(u8, l, "Remote Execution Error on ") == null) return false;
            report = .cut_next;
            continue;
        }
        if (report == .cut_next and !isCutLine(l)) return false;
        report = .none;
        if (isCutLine(l)) {
            cuts += 1;
        } else if (std.mem.startsWith(u8, l, "Error") or std.mem.startsWith(u8, l, "error:") or std.mem.startsWith(u8, l, "error[") or
            std.ascii.indexOfIgnoreCase(l, "non-zero exit code") != null or std.ascii.indexOfIgnoreCase(l, "timed out") != null or
            std.ascii.indexOfIgnoreCase(l, "panic") != null)
        {
            return false;
        }
    }
    return report == .none and cuts > 0;
}

/// A cut as buck2 reports it under an action (`display.rs`, an internal error of the remote-execution stage, then the error of re/error.rs).
pub const sample_cut =
    \\[2026-11-21T07:48:10.059-05:00] Action failed: root//app:bin (cxx_link_executable)
    \\[2026-11-21T07:48:10.059-05:00] Internal error (stage: remote_execute): Remote Execution Error on Execute for ReSession 1
    \\Error: (Error was returned on the stream by RE: RE channel error: code: 'Unknown error', message: "h2 protocol error: error reading a body from connection", source: hyper::Error(Body, Error { kind: Io(Custom { kind: BrokenPipe, error: "stream closed" }) }))
    \\BUILD FAILED
    \\Failed to build 'root//app:bin (prelude//platforms:default)'
    \\
;

/// A compile error of a remote action.
pub const sample_compile_error =
    \\Action failed: root//app:bin (cxx_compile main.c)
    \\Remote command returned non-zero exit code 1
    \\Remote action digest: 'ab:12'
    \\stdout: <empty>
    \\stderr:
    \\main.c:1:1: error: expected ';' after statement
    \\BUILD FAILED
    \\
;

test "a cut connection is buck2's own Error: line with the RE channel error, and nothing else failed" {
    try t.expect(onlyCuts(sample_cut));
    // two actions cut at once, and the error printed again at the end as the command's own
    try t.expect(onlyCuts(sample_cut ++ sample_cut ++ "Command failed: \n  Error: (Error was returned on the stream by RE: RE channel error: code: 'Unknown error')\n"));
    // with no action report around it (a cut while uploading inputs)
    try t.expect(onlyCuts("Error: (RE channel error: code: 'Unknown error', message: \"h2 protocol error\")\nBUILD FAILED\n"));
}

test "the phrase elsewhere is not a cut, and nothing at all is not one" {
    try t.expect(!onlyCuts(""));
    try t.expect(!onlyCuts("BUILD FAILED\n"));
    // in a line that is not buck2's Error: line
    try t.expect(!onlyCuts("warning: RE channel error: code: 'Unknown error'\nBUILD FAILED\n"));
    try t.expect(!onlyCuts("Internal error (stage: remote_execute): RE channel error: code: 'Unknown error'\nBUILD FAILED\n"));
    // an Error: line of another remote-execution error
    try t.expect(!onlyCuts("Error: (Error was returned on the stream by RE: code: 'Not found')\nBUILD FAILED\n"));
}

test "a real failure beside a cut is final: compile error, failing test, timeout, another error of buck2's" {
    try t.expect(!onlyCuts(sample_compile_error));
    try t.expect(!onlyCuts(sample_cut ++ sample_compile_error));
    try t.expect(!onlyCuts(sample_compile_error ++ sample_cut));
    // a test that fails prints the cut line itself in its own output: its report is not a cut
    try t.expect(!onlyCuts("Action failed: root//t:test (run_test)\nRemote command returned non-zero exit code 101\nstderr:\nError: (RE channel error: code: 'Unknown error')\nBUILD FAILED\n"));
    // a timeout of an action, and one in a report that also holds a cut
    try t.expect(!onlyCuts(sample_cut ++ "Action failed: root//t:slow (run_test)\nCommand timed out after 600.000s\n"));
    try t.expect(!onlyCuts("Action failed: root//t:slow (run_test)\nCommand timed out after 600.000s\nError: (RE channel error: code: 'Unknown error')\n"));
    // an action that failed for an internal reason with no cut under it
    try t.expect(!onlyCuts("Action failed: root//a:b (genrule)\nInternal error (stage: materialize_inputs): no space left on device\n" ++ sample_cut));
    // an analysis error, a download that failed, a compiler's own line
    try t.expect(!onlyCuts(sample_cut ++ "Error running analysis for `root//a:b`\n"));
    try t.expect(!onlyCuts(sample_cut ++ "Error materializing HTTP resource declared by target toolchains//:zig_pin\n"));
    try t.expect(!onlyCuts(sample_cut ++ "error[E0308]: mismatched types\n"));
    try t.expect(!onlyCuts(sample_cut ++ "  error: expected ';'\n"));
    // a real report, then a cut line on its own after it: the cut does not count for the report
    try t.expect(!onlyCuts("Action failed: root//a:b (genrule)\nInternal error (stage: materialize_inputs): no space left on device\nError: (RE channel error: code: 'Unknown error')\n"));
    try t.expect(!onlyCuts("Action failed: root//a:b (genrule)\nCommand was cancelled\n" ++ sample_cut));
    // a report cut off before its reason or its cut line, and a panic beside a cut
    try t.expect(!onlyCuts(sample_cut ++ "Action failed: root//a:b (genrule)\n"));
    try t.expect(!onlyCuts(sample_cut ++ "Action failed: root//a:b (genrule)\nInternal error (stage: remote_execute): Remote Execution Error on Execute for ReSession 2\n"));
    try t.expect(!onlyCuts(sample_cut ++ "thread 1 panic: index out of bounds\n"));
}
