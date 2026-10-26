//! What the beta directory must be, checked as a build action (`//beta:beta_check`): the directory is read by the beta job, never by this
//! repository's Buck2 graph, and each language starts the way a user does.
//!
//!  - every language directory has a `STEPS` file that parses (tools/stage/steps.zig), and the languages are exactly the expected ones, so a
//!    language cannot be dropped without this test saying so;
//!  - the first `run` of every STEPS is `buildrules init . --git {origin} --commit {commit}`: a beta starts from a new repository, with the candidate
//!    commit as an external cell, and nothing in it names a repository or a commit of its own;
//!  - no file is named `BUCK` and no `.buckconfig` or `.buckconfig.local` is kept: a `BUCK` file would make the directory packages of this repository's
//!    graph (the user's BUCK is `BUCK.beta`), and `init` and the job write the configuration;
//!  - ci/all.bzl says why the directory is not built by `//ci:all`.
const std = @import("std");
const steps = @import("stage_steps");
const t = std.testing;

pub const expected_langs = [_][]const u8{ "cxx", "mixed", "mojo", "node", "rust", "zig" };

const Findings = std.ArrayList([]const u8);

fn add(a: std.mem.Allocator, f: *Findings, comptime fmt: []const u8, args: anytype) !void {
    try f.append(a, try std.fmt.allocPrint(a, fmt, args));
}

pub fn checkTree(a: std.mem.Allocator, beta: std.fs.Dir, all_bzl: []const u8) !Findings {
    var f = Findings.empty;
    var langs = std.ArrayList([]const u8).empty;
    var it = beta.iterate();
    while (try it.next()) |e| {
        if (e.kind == .directory) try langs.append(a, try a.dupe(u8, e.name));
    }
    for (expected_langs) |want| {
        var have = false;
        for (langs.items) |l| {
            if (std.mem.eql(u8, l, want)) have = true;
        }
        if (!have) try add(a, &f, "the language `{s}` has no directory under beta/", .{want});
    }
    for (langs.items) |l| {
        var known = false;
        for (expected_langs) |w| {
            if (std.mem.eql(u8, l, w)) known = true;
        }
        if (!known) try add(a, &f, "beta/{s} is not an expected language (add it to expected_langs in beta/check.zig and to RELEASING.md)", .{l});
        var d = try beta.openDir(l, .{ .iterate = true });
        defer d.close();
        const text = d.readFileAlloc(a, "STEPS", 1 << 20) catch {
            try add(a, &f, "beta/{s} has no STEPS file", .{l});
            continue;
        };
        if (steps.parse(a, text)) |spec| {
            var first_run: ?[]const []const u8 = null;
            for (spec.steps) |s| switch (s) {
                .run => |w| {
                    if (first_run == null) first_run = w;
                },
                else => {},
            };
            const want = [_][]const u8{ "buildrules", "init", ".", "--git", "{origin}", "--commit", "{commit}" };
            var ok = first_run != null and first_run.?.len == want.len;
            if (ok) {
                for (first_run.?, want) |x, y| {
                    if (!std.mem.eql(u8, x, y)) ok = false;
                }
            }
            if (!ok) try add(a, &f, "beta/{s}/STEPS does not start with `run buildrules init . --git {{origin}} --commit {{commit}}`", .{l});
        } else |_| try add(a, &f, "beta/{s}/STEPS does not parse (the reason is printed above)", .{l});

        var w = try d.walk(a);
        defer w.deinit();
        while (try w.next()) |e| {
            if (e.kind != .file) continue;
            if (std.mem.eql(u8, e.basename, "BUCK")) try add(a, &f, "beta/{s}/{s} is named BUCK: it would be a package of this repository's graph; name it BUCK.beta", .{ l, e.path });
            if (std.mem.startsWith(u8, e.basename, ".buckconfig")) try add(a, &f, "beta/{s}/{s} is kept: `buildrules init` and the job write the configuration", .{ l, e.path });
        }
    }
    if (std.mem.indexOf(u8, all_bzl, "beta/") == null or std.mem.indexOf(u8, all_bzl, "OUTSIDE_THE_GRAPH") == null)
        try add(a, &f, "ci/all.bzl does not list beta/ in OUTSIDE_THE_GRAPH with its reason", .{});
    return f;
}

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    return std.fs.path.join(a, &.{ w, sub });
}

test "the real beta directory has no finding" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var beta = try std.fs.cwd().openDir(try work(a, "beta"), .{ .iterate = true });
    defer beta.close();
    const all_bzl = try std.fs.cwd().readFileAlloc(a, try work(a, "ci/all.bzl"), 1 << 20);
    const f = try checkTree(a, beta, all_bzl);
    for (f.items) |m| std.debug.print("finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

const good_steps = "run buildrules init . --git {origin} --commit {commit}\nconfig\nbuild //:a\n";
const good_all = "OUTSIDE_THE_GRAPH = {\"beta/\": \"why\"}\n";

/// A synthetic beta directory of the expected languages, with the `STEPS` of `lang` replaced and `extra` files added.
fn fixture(tmp: *t.TmpDir, lang_steps: ?[2][]const u8, extra: []const [2][]const u8, drop: ?[]const u8) !void {
    for (expected_langs) |l| {
        if (drop != null and std.mem.eql(u8, drop.?, l)) continue;
        try tmp.dir.makePath(l);
        const p = try std.fmt.allocPrint(t.allocator, "{s}/STEPS", .{l});
        defer t.allocator.free(p);
        const body = if (lang_steps != null and std.mem.eql(u8, lang_steps.?[0], l)) lang_steps.?[1] else good_steps;
        try tmp.dir.writeFile(.{ .sub_path = p, .data = body });
    }
    for (extra) |e| {
        if (std.fs.path.dirname(e[0])) |d| try tmp.dir.makePath(d);
        try tmp.dir.writeFile(.{ .sub_path = e[0], .data = e[1] });
    }
}

fn expectFinding(f: Findings, needle: []const u8) !void {
    for (f.items) |m| {
        if (std.mem.indexOf(u8, m, needle) != null) return;
    }
    std.debug.print("expected a finding with `{s}`, got {d}:\n", .{ needle, f.items.len });
    for (f.items) |m| std.debug.print("  {s}\n", .{m});
    return error.DefectSurvived;
}

fn run(a: std.mem.Allocator, tmp: *t.TmpDir, all_bzl: []const u8) !Findings {
    var d = try tmp.dir.openDir(".", .{ .iterate = true });
    defer d.close();
    return checkTree(a, d, all_bzl);
}

test "the synthetic beta directory has no finding, so each variant below is red for its own rule" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try fixture(&tmp, null, &.{}, null);
    const f = try run(a, &tmp, good_all);
    for (f.items) |m| std.debug.print("finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "a dropped language, an unknown one, a missing or bad STEPS, a BUCK file, a kept buckconfig and a missing reason are each found" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var tmp = t.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try fixture(&tmp, null, &.{}, "zig");
        try expectFinding(try run(a, &tmp, good_all), "the language `zig` has no directory");
    }
    {
        var tmp = t.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try fixture(&tmp, null, &.{.{ "go/STEPS", good_steps }}, null);
        try expectFinding(try run(a, &tmp, good_all), "beta/go is not an expected language");
    }
    {
        var tmp = t.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try fixture(&tmp, null, &.{}, null);
        try tmp.dir.deleteFile("rust/STEPS");
        try expectFinding(try run(a, &tmp, good_all), "beta/rust has no STEPS file");
    }
    {
        var tmp = t.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try fixture(&tmp, .{ "rust", "run sh -c true\nconfig\nbuild //:a\n" }, &.{}, null);
        try expectFinding(try run(a, &tmp, good_all), "beta/rust/STEPS does not parse");
    }
    {
        // a repository or a commit of its own, or a first command that is not init
        var tmp = t.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try fixture(&tmp, .{ "node", "run buildrules init . --git https://example.invalid/r --commit " ++ "a" ** 40 ++ "\nconfig\nbuild //:a\n" }, &.{}, null);
        try expectFinding(try run(a, &tmp, good_all), "beta/node/STEPS does not start with");
    }
    {
        var tmp = t.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try fixture(&tmp, .{ "cxx", "run buildrules check\nrun buildrules init . --git {origin} --commit {commit}\nconfig\nbuild //:a\n" }, &.{}, null);
        try expectFinding(try run(a, &tmp, good_all), "beta/cxx/STEPS does not start with");
    }
    {
        var tmp = t.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try fixture(&tmp, null, &.{.{ "zig/sub/BUCK", "" }}, null);
        try expectFinding(try run(a, &tmp, good_all), "is named BUCK");
    }
    {
        var tmp = t.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try fixture(&tmp, null, &.{.{ "mixed/.buckconfig.local", "" }}, null);
        try expectFinding(try run(a, &tmp, good_all), "is kept");
    }
    {
        var tmp = t.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try fixture(&tmp, null, &.{}, null);
        try expectFinding(try run(a, &tmp, "EXCLUDED = {}\n"), "does not list beta/");
        try expectFinding(try run(a, &tmp, "OUTSIDE_THE_GRAPH = {}\n"), "does not list beta/");
    }
}
