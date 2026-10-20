//! The `STEPS` file of a beta repository (`beta/<lang>/STEPS`): the commands a user types, one per line, and what must come of them. The beta job
//! runs exactly these lines in a copy of the directory, so the file is also the documentation of how a user starts with buildrules in that language.
//!
//!   # a comment
//!   planned-until mopm-release          the leg is planned (skipped, with the reason) while the pinned mopm is a stand-in; first line only
//!   run buildrules init . --git {origin} --commit {commit}
//!                                       the one program a step may run is `buildrules` (the command line built from the candidate); no shell.
//!                                       `{origin}` and `{commit}` are the candidate's repository URL and commit
//!   config                              writes .buckconfig.local: where actions run (local mode on a runner, the farm's settings otherwise)
//!   build //pkg:a //pkg:b               `buck2 build` of the targets; their outputs are what the determinism check hashes
//!   expect //pkg:bin => Hello, world!   runs the output of a built target; its standard output (a trailing newline aside) must be the text
//!   expect-file //pkg:dist hello.txt => Hello, world!
//!                                       a file inside the output directory of a built target must hold the text
const std = @import("std");

pub const Step = union(enum) {
    run: []const []const u8,
    config,
    build: []const []const u8,
    expect: struct { target: []const u8, text: []const u8 },
    expect_file: struct { target: []const u8, path: []const u8, text: []const u8 },
};

pub const Spec = struct {
    /// The condition the leg waits for, when it is planned.
    planned_until: ?[]const u8 = null,
    steps: []const Step,
};

pub const known_conditions = [_][]const u8{"mopm-release"};

pub const ParseError = error{BadSteps} || std.mem.Allocator.Error;

fn bad(comptime fmt: []const u8, args: anytype) ParseError {
    std.debug.print("STEPS: " ++ fmt ++ "\n", args);
    return error.BadSteps;
}

fn isTarget(w: []const u8) bool {
    return std.mem.startsWith(u8, w, "//") and std.mem.indexOfScalar(u8, w, ':') != null;
}

pub fn parse(a: std.mem.Allocator, text: []const u8) ParseError!Spec {
    var steps = std.ArrayList(Step).empty;
    var spec = Spec{ .steps = &.{} };
    var built = std.ArrayList([]const u8).empty;
    var configured = false;
    var any = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        const head = words.next().?;
        if (std.mem.eql(u8, head, "planned-until")) {
            if (any) return bad("line {d}: planned-until is the first line", .{n});
            const cond = words.next() orelse return bad("line {d}: planned-until needs a condition", .{n});
            var known = false;
            for (known_conditions) |k| {
                if (std.mem.eql(u8, k, cond)) known = true;
            }
            if (!known or words.next() != null) return bad("line {d}: `{s}` is not a condition (mopm-release)", .{ n, cond });
            spec.planned_until = cond;
            any = true;
            continue;
        }
        any = true;
        if (std.mem.eql(u8, head, "run")) {
            var argv = std.ArrayList([]const u8).empty;
            while (words.next()) |w| try argv.append(a, w);
            if (argv.items.len == 0 or !std.mem.eql(u8, argv.items[0], "buildrules"))
                return bad("line {d}: a run step runs `buildrules` and nothing else (no shell, no other program)", .{n});
            try steps.append(a, .{ .run = argv.items });
        } else if (std.mem.eql(u8, head, "config")) {
            if (words.next() != null) return bad("line {d}: config takes no arguments", .{n});
            if (configured) return bad("line {d}: config twice", .{n});
            configured = true;
            try steps.append(a, .config);
        } else if (std.mem.eql(u8, head, "build")) {
            if (!configured) return bad("line {d}: build before config: the actions would have nowhere to run", .{n});
            var ts = std.ArrayList([]const u8).empty;
            while (words.next()) |w| {
                if (!isTarget(w)) return bad("line {d}: `{s}` is not a //pkg:name target", .{ n, w });
                try ts.append(a, w);
                try built.append(a, w);
            }
            if (ts.items.len == 0) return bad("line {d}: build names no target", .{n});
            try steps.append(a, .{ .build = ts.items });
        } else if (std.mem.eql(u8, head, "expect") or std.mem.eql(u8, head, "expect-file")) {
            const file = std.mem.eql(u8, head, "expect-file");
            const rest = std.mem.trim(u8, line[head.len..], " ");
            const arrow = std.mem.indexOf(u8, rest, " => ") orelse return bad("line {d}: `{s}` needs ` => <text>`", .{ n, head });
            const lhs = std.mem.trim(u8, rest[0..arrow], " ");
            const text_out = rest[arrow + 4 ..];
            if (text_out.len == 0) return bad("line {d}: the expected text is empty", .{n});
            var lw = std.mem.tokenizeScalar(u8, lhs, ' ');
            const target = lw.next() orelse return bad("line {d}: no target", .{n});
            var was_built = false;
            for (built.items) |b| {
                if (std.mem.eql(u8, b, target)) was_built = true;
            }
            if (!was_built) return bad("line {d}: {s} is not built by an earlier build step", .{ n, target });
            if (file) {
                const p = lw.next() orelse return bad("line {d}: expect-file needs a path", .{n});
                if (lw.next() != null or std.mem.startsWith(u8, p, "/") or std.mem.indexOf(u8, p, "..") != null) return bad("line {d}: `{s}` is not a relative path inside the output", .{ n, p });
                try steps.append(a, .{ .expect_file = .{ .target = target, .path = p, .text = text_out } });
            } else {
                if (lw.next() != null) return bad("line {d}: expect takes one target", .{n});
                try steps.append(a, .{ .expect = .{ .target = target, .text = text_out } });
            }
        } else {
            return bad("line {d}: unknown step `{s}`", .{ n, head });
        }
    }
    if (built.items.len == 0) return bad("no build step: a beta that builds nothing proves nothing", .{});
    spec.steps = steps.items;
    return spec;
}

/// `{origin}` and `{commit}` in one word.
pub fn substitute(a: std.mem.Allocator, word: []const u8, origin: []const u8, commit: []const u8) ![]u8 {
    const one = try std.mem.replaceOwned(u8, a, word, "{origin}", origin);
    return std.mem.replaceOwned(u8, a, one, "{commit}", commit);
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;

fn expectBad(text: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.BadSteps, parse(arena.allocator(), text));
}

test "a STEPS file is read into its steps" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try parse(a,
        \\# a comment
        \\planned-until mopm-release
        \\
        \\run buildrules init . --git {origin} --commit {commit}
        \\config
        \\build //crates/hello:bin //crates/hello:test
        \\expect //crates/hello:bin => Hello, world!
        \\expect-file //crates/hello:bin out.txt => text with spaces
        \\
    );
    try t.expectEqualStrings("mopm-release", s.planned_until.?);
    try t.expectEqual(@as(usize, 5), s.steps.len);
    try t.expectEqualStrings("init", s.steps[0].run[1]);
    try t.expectEqual(@as(usize, 2), s.steps[2].build.len);
    try t.expectEqualStrings("Hello, world!", s.steps[3].expect.text);
    try t.expectEqualStrings("out.txt", s.steps[4].expect_file.path);
    try t.expectEqualStrings("text with spaces", s.steps[4].expect_file.text);
}

test "placeholders are the origin and the commit" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("https://h/r", try substitute(a, "{origin}", "https://h/r", "c"));
    try t.expectEqualStrings("c", try substitute(a, "{commit}", "https://h/r", "c"));
    try t.expectEqualStrings("plain", try substitute(a, "plain", "o", "c"));
}

test "a STEPS file with a defect is refused, each defect for its own reason" {
    // a program other than buildrules (there is no shell in a step)
    try expectBad("run sh -c true\nconfig\nbuild //a:b\n");
    try expectBad("run\nconfig\nbuild //a:b\n");
    // build before config; config twice; a build with no target or with a word that is no target
    try expectBad("build //a:b\nconfig\n");
    try expectBad("config\nconfig\nbuild //a:b\n");
    try expectBad("config\nbuild\n");
    try expectBad("config\nbuild a:b\n");
    try expectBad("config\nbuild //a\n");
    // nothing built
    try expectBad("config\nrun buildrules check\n");
    try expectBad("");
    // expect: a target nothing built, no arrow, no text, a path that escapes
    try expectBad("config\nbuild //a:b\nexpect //a:c => x\n");
    try expectBad("config\nbuild //a:b\nexpect //a:b\n");
    try expectBad("config\nbuild //a:b\nexpect //a:b => \n");
    try expectBad("config\nbuild //a:b\nexpect-file //a:b ../x => y\n");
    try expectBad("config\nbuild //a:b\nexpect-file //a:b /x => y\n");
    try expectBad("config\nbuild //a:b\nexpect-file //a:b => y\n");
    // planned-until: unknown condition, not first
    try expectBad("planned-until tomorrow\nconfig\nbuild //a:b\n");
    try expectBad("config\nplanned-until mopm-release\nbuild //a:b\n");
    // an unknown step
    try expectBad("config\nbuild //a:b\nfrobnicate\n");
}
