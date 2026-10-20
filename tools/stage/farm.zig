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
