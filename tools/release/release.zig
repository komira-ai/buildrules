//! `release`: the steps of the automatic release (RELEASING.md). The logic is in cmds.zig, version.zig, assets.zig, gz.zig and tar.zig, each
//! tested; this file reads the command line and runs the real `git` and `gh`.
//!
//!   release plan    --root DIR --sha SHA [--output FILE]
//!   release tag     --root DIR --repo OWNER/NAME --tag TAG --sha SHA
//!   release archive --root DIR --tag TAG --sha SHA --out DIR
//!   release verify  --root DIR --repo OWNER/NAME --tag TAG --sha SHA --dist DIR --workflow PATH
//!   release publish --root DIR --repo OWNER/NAME --tag TAG --sha SHA --previous TAG --dist DIR
//!   release site    --repo OWNER/NAME --tag TAG --sha SHA --dist DIR --out DIR
//!
//! Exit 0 when the step succeeded (`plan` also when it decided there is nothing to release), 1 when a check failed, 2 on a bad command line.
const std = @import("std");
const cmds = @import("cmds.zig");
const version = @import("version.zig");
const page = @import("page.zig");

const Args = struct {
    names: []const []const u8,
    values: []const []const u8,

    fn get(self: Args, name: []const u8) ?[]const u8 {
        for (self.names, self.values) |n, v| {
            if (std.mem.eql(u8, n, name)) return v;
        }
        return null;
    }

    fn need(self: Args, name: []const u8) ![]const u8 {
        return self.get(name) orelse {
            std.debug.print("release: --{s} is required\n", .{name});
            return error.Usage;
        };
    }
};

fn parseArgs(a: std.mem.Allocator, argv: []const []const u8, allowed: []const []const u8) !Args {
    var names = std.ArrayList([]const u8).empty;
    var values = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        const flag = argv[i];
        if (!std.mem.startsWith(u8, flag, "--") or i + 1 >= argv.len) {
            std.debug.print("release: expected --flag VALUE, got `{s}`\n", .{flag});
            return error.Usage;
        }
        var known = false;
        for (allowed) |n| {
            if (std.mem.eql(u8, flag[2..], n)) known = true;
        }
        if (!known) {
            std.debug.print("release: unknown flag {s}\n", .{flag});
            return error.Usage;
        }
        try names.append(a, flag[2..]);
        try values.append(a, argv[i + 1]);
    }
    return .{ .names = names.items, .values = values.items };
}

fn realRun(_: *anyopaque, a: std.mem.Allocator, argv: []const []const u8) anyerror!cmds.Out {
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv, .max_output_bytes = 1 << 30 });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
}

fn realWrite(_: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void {
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
}

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stdout().writeAll(s) catch {};
}

fn join(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ dir, name });
}

fn appendFile(path: []const u8, bytes: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(bytes);
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) {
        std.debug.print("usage: release plan|tag|archive|verify|publish|site --flag value ...\n", .{});
        return 2;
    }
    var unused: u8 = 0;
    const io = cmds.Io{ .ctx = &unused, .run_fn = realRun, .write_fn = realWrite };
    const cmd = argv[1];
    const rest = argv[2..];
    return run(a, io, cmd, rest) catch |e| switch (e) {
        error.Usage => 2,
        else => {
            std.debug.print("release {s}: {s}\n", .{ cmd, @errorName(e) });
            return 1;
        },
    };
}

fn run(a: std.mem.Allocator, io: cmds.Io, cmd: []const u8, rest: []const []const u8) !u8 {
    if (std.mem.eql(u8, cmd, "plan")) {
        const g = try parseArgs(a, rest, &.{ "root", "sha", "output" });
        const root = try g.need("root");
        const version_path = try join(a, root, "VERSION");
        const version_file = try std.fs.cwd().readFileAlloc(a, version_path, 1024);
        const r = try cmds.plan(a, io, .{ .root = root, .sha = try g.need("sha"), .version_file = version_file });
        const out = try cmds.planOutputs(a, r);
        say("{s}", .{out});
        if (g.get("output")) |p| try appendFile(p, out);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "tag")) {
        const g = try parseArgs(a, rest, &.{ "root", "repo", "tag", "sha" });
        const tag = try g.need("tag");
        const made = try cmds.createTag(a, io, .{ .root = try g.need("root"), .repo = try g.need("repo"), .tag = tag, .sha = try g.need("sha") });
        say("release tag: {s} {s}\n", .{ tag, @tagName(made) });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "archive")) {
        const g = try parseArgs(a, rest, &.{ "root", "tag", "sha", "out" });
        const b = try cmds.archive(a, io, try g.need("root"), try g.need("tag"), try g.need("sha"));
        const dir = try g.need("out");
        try std.fs.cwd().makePath(dir);
        try std.fs.cwd().writeFile(.{ .sub_path = try join(a, dir, b.name), .data = b.archive });
        try std.fs.cwd().writeFile(.{ .sub_path = try join(a, dir, cmds.sums_name), .data = b.sums });
        say("{s}", .{b.sums});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "verify")) {
        const g = try parseArgs(a, rest, &.{ "root", "repo", "tag", "sha", "dist", "workflow" });
        const tag = try g.need("tag");
        const v = version.parseTag(tag) orelse {
            std.debug.print("release: `{s}` is not a release tag\n", .{tag});
            return 1;
        };
        const dist = try g.need("dist");
        const name = try std.fmt.allocPrint(a, "buildrules-{s}.tar.gz", .{try version.numberText(a, v)});
        const archive = try std.fs.cwd().readFileAlloc(a, try join(a, dist, name), 1 << 30);
        const sums = try std.fs.cwd().readFileAlloc(a, try join(a, dist, cmds.sums_name), 1 << 20);
        const f = try cmds.verify(a, io, .{
            .root = try g.need("root"),
            .repo = try g.need("repo"),
            .tag = tag,
            .sha = try g.need("sha"),
            .dist = dist,
            .archive_name = name,
            .archive = archive,
            .sums = sums,
            .workflow = try g.need("workflow"),
        });
        for (f.items) |m| std.debug.print("release verify: {s}\n", .{m});
        if (f.items.len != 0) return 1;
        say("release verify: {s} is the archive of {s}; checked: sums, checkout, attestations, reproduction, file list, scrub\n", .{ name, g.get("sha").? });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "publish")) {
        const g = try parseArgs(a, rest, &.{ "root", "repo", "tag", "sha", "previous", "dist" });
        const tag = try g.need("tag");
        const v = version.parseTag(tag) orelse {
            std.debug.print("release: `{s}` is not a release tag\n", .{tag});
            return 1;
        };
        const dist = try g.need("dist");
        const name = try std.fmt.allocPrint(a, "buildrules-{s}.tar.gz", .{try version.numberText(a, v)});
        const archive = try std.fs.cwd().readFileAlloc(a, try join(a, dist, name), 1 << 30);
        const sums = try std.fs.cwd().readFileAlloc(a, try join(a, dist, cmds.sums_name), 1 << 20);
        const r = try cmds.publish(a, io, .{
            .root = try g.need("root"),
            .repo = try g.need("repo"),
            .tag = tag,
            .sha = try g.need("sha"),
            .previous = try g.need("previous"),
            .dist = dist,
            .archive_name = name,
            .archive = archive,
            .sums = sums,
            .notes_path = try join(a, dist, "notes.md"),
        });
        say("release publish: {s} {s}\n", .{ tag, @tagName(r) });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "site")) {
        const g = try parseArgs(a, rest, &.{ "repo", "tag", "sha", "dist", "out" });
        const tag = try g.need("tag");
        const v = version.parseTag(tag) orelse {
            std.debug.print("release: `{s}` is not a release tag\n", .{tag});
            return 1;
        };
        const name = try std.fmt.allocPrint(a, "buildrules-{s}.tar.gz", .{try version.numberText(a, v)});
        const sums = try std.fs.cwd().readFileAlloc(a, try join(a, try g.need("dist"), cmds.sums_name), 1 << 20);
        const digest = try page.digestOf(sums, name);
        const html = try page.render(a, .{ .repo = try g.need("repo"), .tag = tag, .sha = try g.need("sha"), .archive_name = name, .sha256 = digest });
        const dir = try join(a, try g.need("out"), try std.fmt.allocPrint(a, "releases/{s}", .{tag}));
        try std.fs.cwd().makePath(dir);
        try std.fs.cwd().writeFile(.{ .sub_path = try join(a, dir, "index.html"), .data = html });
        say("release site: {s}/index.html for {s}\n", .{ dir, tag });
        return 0;
    }
    std.debug.print("release: unknown command `{s}`\n", .{cmd});
    return error.Usage;
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;

test "flags are --name VALUE pairs of a known name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try parseArgs(a, &.{ "--root", "/w", "--previous", "" }, &.{ "root", "previous", "tag" });
    try t.expectEqualStrings("/w", g.get("root").?);
    try t.expectEqualStrings("", g.get("previous").?);
    try t.expect(g.get("tag") == null);
    try t.expectError(error.Usage, g.need("tag"));
    try t.expectError(error.Usage, parseArgs(a, &.{ "--bogus", "x" }, &.{"root"}));
    try t.expectError(error.Usage, parseArgs(a, &.{"--root"}, &.{"root"}));
    try t.expectError(error.Usage, parseArgs(a, &.{ "root", "x" }, &.{"root"}));
}

test "an unknown command, and a command missing a flag, are usage errors that run nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var unused_ctx: u8 = 0;
    const io = cmds.Io{ .ctx = &unused_ctx, .run_fn = realRun, .write_fn = realWrite };
    try t.expectError(error.Usage, run(a, io, "frobnicate", &.{}));
    try t.expectError(error.Usage, run(a, io, "archive", &.{ "--root", "/w" }));
    try t.expectError(error.Usage, run(a, io, "publish", &.{ "--tag", "v0.0.1", "--bogus", "x" }));
}

test "site writes the page of the verified release from its SHA256SUMS, and refuses what is not a release" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("dist");
    try tmp.dir.writeFile(.{ .sub_path = "dist/SHA256SUMS", .data = "d" ** 64 ++ "  buildrules-0.0.7.tar.gz\n" });
    const base = try tmp.dir.realpathAlloc(a, ".");
    const dist = try join(a, base, "dist");
    const out = try join(a, base, "site");
    var unused: u8 = 0;
    const io = cmds.Io{ .ctx = &unused, .run_fn = realRun, .write_fn = realWrite };
    const args = [_][]const u8{ "--repo", "org/name", "--tag", "v0.0.7", "--sha", "e" ** 40, "--dist", dist, "--out", out };
    try t.expectEqual(@as(u8, 0), try run(a, io, "site", &args));
    const html = try tmp.dir.readFileAlloc(a, "site/releases/v0.0.7/index.html", 1 << 20);
    try t.expect(std.mem.indexOf(u8, html, "sha256 <code>" ++ "d" ** 64 ++ "</code>") != null);
    try t.expect(std.mem.indexOf(u8, html, "commit_hash = " ++ "e" ** 40) != null);
    // a tag that is not a release writes nothing
    const bad_tag = [_][]const u8{ "--repo", "org/name", "--tag", "v0.0", "--sha", "e" ** 40, "--dist", dist, "--out", out };
    try t.expectEqual(@as(u8, 1), try run(a, io, "site", &bad_tag));
    // sums that name another archive, or a commit that is not 40 hex, are errors
    const other_tag = [_][]const u8{ "--repo", "org/name", "--tag", "v0.0.8", "--sha", "e" ** 40, "--dist", dist, "--out", out };
    try t.expectError(error.WrongName, run(a, io, "site", &other_tag));
    const bad_sha = [_][]const u8{ "--repo", "org/name", "--tag", "v0.0.7", "--sha", "e" ** 39, "--dist", dist, "--out", out };
    try t.expectError(error.BadSha, run(a, io, "site", &bad_sha));
    try t.expectError(error.Usage, run(a, io, "site", &.{ "--repo", "org/name" }));
}
