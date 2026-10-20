//! `release`: the steps of the automatic release (RELEASING.md). The logic is in cmds.zig, version.zig, assets.zig, gz.zig and tar.zig, each
//! tested; this file reads the command line and runs the real `git` and `gh`.
//!
//!   release plan    --root DIR --sha SHA [--output FILE] [--freeze true|false|] [--dry true|false]
//!   release tag     --root DIR --repo OWNER/NAME --tag TAG --sha SHA
//!   release archive --root DIR --tag TAG --sha SHA --out DIR
//!   release verify  --root DIR --repo OWNER/NAME --tag TAG --sha SHA --dist DIR --workflow PATH --cli PATH --rebuilt DIR --dry true|false
//!   release publish --root DIR --repo OWNER/NAME --tag TAG --sha SHA --previous TAG --dist DIR
//!   release site    --repo OWNER/NAME --tag TAG --sha SHA --dist DIR --out DIR
//!   release bump-check    --internal-repo OWNER/NAME
//!   release bump-internal --repo OWNER/NAME --tag TAG --sha SHA --internal-repo OWNER/NAME --submodule PATH --workdir EMPTYDIR   (GH_TOKEN: the release bot's)
//!   release package --version V --target T --binary PATH --license PATH --out DIR --exec native|none   (binaries.zig: buildrules-cli-V-T.tar.gz)
//!   release package-all --version V --bins DIR --license PATH --out DIR [--native T,T]   the four, from DIR/<target>/buildrules
//!   release record  --tarball PATH --out DIR [--ran-binary PATH]   the sha256 of a tarball a user-beta leg ran (and the file it ran is the tarball's)
//!   release tested  --dist DIR --tested DIR [--targets T,T]   the tarballs to attest are the ones the user beta ran
//!   release sums    --dist DIR                      SHA256SUMS over the source archive and the four tarballs
//!   release sign    --dist DIR [--cosign PATH] [--dry true|false]   a keyless cosign bundle per file (dry: the checks, no signing)
//!
//! Exit 0 when the step succeeded (`plan` also when it decided there is nothing to release), 1 when a check failed, 2 on a bad command line.
const std = @import("std");
const cmds = @import("cmds.zig");
const bump = @import("bump.zig");
const version = @import("version.zig");
const page = @import("page.zig");
const binaries = @import("binaries.zig");

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

/// A refused binaries step: the step has said why on stderr; the exit code is 1 (a check failed).
fn failed(cmd: []const u8, e: anyerror) u8 {
    std.debug.print("release {s}: refused ({s})\n", .{ cmd, @errorName(e) });
    return 1;
}

fn appendFile(path: []const u8, bytes: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(bytes);
}

/// `true` or `false`, exactly; a missing flag is `default` (null: the flag is required). Anything else is a usage error, not a guess: a dry run is never taken for
/// a real one, or the other way round, by a typo.
fn boolFlag(g: Args, name: []const u8, default: ?bool) !bool {
    const v = g.get(name) orelse return default orelse {
        std.debug.print("release: --{s} is required (true or false)\n", .{name});
        return error.Usage;
    };
    if (std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "false")) return false;
    std.debug.print("release: --{s} is `true` or `false`, not `{s}`\n", .{ name, v });
    return error.Usage;
}

fn lessName(_: void, x: cmds.Blob, y: cmds.Blob) bool {
    return std.mem.lessThan(u8, x.name, y.name);
}

/// The files of `dir` whose names start with `prefix` and end with `suffix`, with their bytes, by name.
fn readMatching(a: std.mem.Allocator, dir: []const u8, prefix: []const u8, suffix: []const u8) ![]cmds.Blob {
    var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer d.close();
    var out = std.ArrayList(cmds.Blob).empty;
    var it = d.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file or !std.mem.startsWith(u8, e.name, prefix) or !std.mem.endsWith(u8, e.name, suffix)) continue;
        const name = try a.dupe(u8, e.name);
        try out.append(a, .{ .name = name, .bytes = try d.readFileAlloc(a, name, 1 << 30) });
    }
    std.mem.sort(cmds.Blob, out.items, {}, lessName);
    return out.toOwnedSlice(a);
}

/// A comma-separated list of targets.
fn targetList(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |w| try out.append(a, w);
    return out.toOwnedSlice(a);
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) {
        std.debug.print("usage: release plan|tag|archive|verify|publish|site|bump-check|bump-internal|package|package-all|record|tested|sums|sign --flag value ...\n", .{});
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
        const g = try parseArgs(a, rest, &.{ "root", "sha", "output", "freeze", "dry" });
        const dry = try boolFlag(g, "dry", false);
        const root = try g.need("root");
        const version_path = try join(a, root, "VERSION");
        const version_file = try std.fs.cwd().readFileAlloc(a, version_path, 1024);
        const r = try cmds.plan(a, io, .{ .root = root, .sha = try g.need("sha"), .version_file = version_file, .freeze = g.get("freeze") orelse "", .dry = dry });
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
        const g = try parseArgs(a, rest, &.{ "root", "repo", "tag", "sha", "dist", "workflow", "cli", "rebuilt", "dry", "cosign" });
        const dry = try boolFlag(g, "dry", null);
        const tag = try g.need("tag");
        const v = version.parseTag(tag) orelse {
            std.debug.print("release: `{s}` is not a release tag\n", .{tag});
            return 1;
        };
        const dist = try g.need("dist");
        const name = try std.fmt.allocPrint(a, "buildrules-{s}.tar.gz", .{try version.numberText(a, v)});
        const archive = try std.fs.cwd().readFileAlloc(a, try join(a, dist, name), 1 << 30);
        const sums = try std.fs.cwd().readFileAlloc(a, try join(a, dist, cmds.sums_name), 1 << 20);
        const cli_path = try g.need("cli");
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
            .cli = cli_path,
            .cli_bytes = try std.fs.cwd().readFileAlloc(a, cli_path, 1 << 30),
            .tarballs = try readMatching(a, dist, "buildrules-cli-", ".tar.gz"),
            .rebuilt = try readMatching(a, try g.need("rebuilt"), "buildrules-cli-", ".tar.gz"),
            .dry = dry,
            .cosign = g.get("cosign") orelse "cosign",
        });
        for (f.items) |m| std.debug.print("release verify: {s}\n", .{m});
        if (f.items.len != 0) return 1;
        say("release verify: {s} is the archive of {s}; checked: sums, checkout, {s}, reproduction of the archive and the four command-line tarballs, the built program's version, file list, scrub\n", .{ name, g.get("sha").?, if (dry) "no attestations or signatures (dry run)" else "attestations and signatures" });
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
            .tarballs = try readMatching(a, dist, "buildrules-cli-", ".tar.gz"),
            .bundles = try readMatching(a, dist, "", ".sigstore.json"),
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
    if (std.mem.eql(u8, cmd, "bump-check")) {
        const g = try parseArgs(a, rest, &.{"internal-repo"});
        const name = try g.need("internal-repo");
        if (!bump.ownerName(name)) {
            std.debug.print("release bump-check: `{s}` is not OWNER/NAME: the repository variable that names the internal repository is empty or malformed, and a token minted without it would reach more than that repository\n", .{name});
            return 1;
        }
        say("release bump-check: {s}\n", .{name});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "bump-internal")) {
        const g = try parseArgs(a, rest, &.{ "repo", "tag", "sha", "internal-repo", "submodule", "workdir" });
        const env = try std.process.getEnvMap(a);
        const o = bump.Options{
            .repo = try g.need("repo"),
            .tag = try g.need("tag"),
            .sha = try g.need("sha"),
            .dest_repo = try g.need("internal-repo"),
            .submodule = try g.need("submodule"),
            .workdir = try g.need("workdir"),
            .token = std.process.getEnvVarOwned(a, "GH_TOKEN") catch "",
            .base_env = &env,
        };
        const r = bump.run(a, bump.real_runner, o);
        if (r.ok) {
            say("{s}", .{r.text});
            return 0;
        }
        std.debug.print("{s}\n", .{r.text});
        return 1;
    }
    if (std.mem.eql(u8, cmd, "package")) {
        const g = try parseArgs(a, rest, &.{ "version", "target", "binary", "license", "out", "exec" });
        const exec_text = try g.need("exec");
        const exec: binaries.Exec = if (std.mem.eql(u8, exec_text, "native")) .native else if (std.mem.eql(u8, exec_text, "none")) .none else {
            std.debug.print("release: --exec is `native` (run the binary) or `none` (it cannot run on this machine), not `{s}`\n", .{exec_text});
            return error.Usage;
        };
        const p = binaries.package(a, io, .{
            .version = try g.need("version"),
            .target = try g.need("target"),
            .binary = try g.need("binary"),
            .license = try g.need("license"),
            .out = try g.need("out"),
            .exec = exec,
        }) catch |e| return failed("package", e);
        say("release package: {s} {s}\n", .{ p.name, p.sha256 });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "package-all")) {
        const g = try parseArgs(a, rest, &.{ "version", "bins", "license", "out", "native" });
        const done = binaries.packageAll(a, io, .{
            .version = try g.need("version"),
            .bins = try g.need("bins"),
            .license = try g.need("license"),
            .out = try g.need("out"),
            .native = try targetList(a, g.get("native") orelse "linux-x86_64"),
        }) catch |e| return failed("package-all", e);
        for (done) |p| say("release package-all: {s} {s}\n", .{ p.name, p.sha256 });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "record")) {
        const g = try parseArgs(a, rest, &.{ "tarball", "out", "ran-binary" });
        const name = binaries.record(a, try g.need("tarball"), try g.need("out"), g.get("ran-binary")) catch |e| return failed("record", e);
        say("release record: {s}\n", .{name});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "tested")) {
        const g = try parseArgs(a, rest, &.{ "dist", "tested", "targets" });
        const walked: []const []const u8 = if (g.get("targets")) |text| try targetList(a, text) else &binaries.tested_targets;
        binaries.testedFor(a, try g.need("dist"), try g.need("tested"), walked) catch |e| return failed("tested", e);
        say("release tested: the tarballs of {s} are the ones the user beta ran\n", .{g.get("dist").?});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "sums")) {
        const g = try parseArgs(a, rest, &.{"dist"});
        const d = binaries.sums(a, try g.need("dist")) catch |e| return failed("sums", e);
        say("release sums: SHA256SUMS over {d} files of {s}\n", .{ d.files.len, d.version });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "sign")) {
        const g = try parseArgs(a, rest, &.{ "dist", "cosign", "dry" });
        const dry = try boolFlag(g, "dry", false);
        const n = binaries.signWith(a, io, try g.need("dist"), g.get("cosign") orelse "cosign", dry) catch |e| return failed("sign", e);
        say("release sign: {d} {s}\n", .{ n, if (dry) "files would be signed (dry run: nothing signed)" else "bundles" });
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
    try t.expectError(error.Usage, run(a, io, "bump-internal", &.{ "--repo", "org/name" }));
    try t.expectError(error.Usage, run(a, io, "bump-internal", &.{ "--repo", "org/name", "--tag", "v0.0.1", "--sha", "e" ** 40, "--internal-repo", "org/other", "--submodule", "name", "--workdir", "w", "--bogus", "x" }));
    try t.expectError(error.Usage, run(a, io, "bump-check", &.{}));
}

test "bump-check refuses an internal repository name that is empty or malformed, so no token is minted without it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var unused_ctx: u8 = 0;
    const io = cmds.Io{ .ctx = &unused_ctx, .run_fn = realRun, .write_fn = realWrite };
    try t.expectEqual(@as(u8, 0), try run(a, io, "bump-check", &.{ "--internal-repo", "org/internal-repo" }));
    // an empty variable makes `<owner>/`; a token minted for an empty `repositories` list reaches every repository of the installation
    try t.expectEqual(@as(u8, 1), try run(a, io, "bump-check", &.{ "--internal-repo", "org/" }));
    try t.expectEqual(@as(u8, 1), try run(a, io, "bump-check", &.{ "--internal-repo", "" }));
    try t.expectEqual(@as(u8, 1), try run(a, io, "bump-check", &.{ "--internal-repo", "org/a b" }));
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

test "the binaries commands: usage errors run nothing, a refused step exits 1, a good one 0" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var unused_ctx: u8 = 0;
    const io = cmds.Io{ .ctx = &unused_ctx, .run_fn = realRun, .write_fn = realWrite };
    try t.expectError(error.Usage, run(a, io, "package", &.{ "--version", "0.0.7" }));
    try t.expectError(error.Usage, run(a, io, "record", &.{"--tarball"}));
    try t.expectError(error.Usage, run(a, io, "tested", &.{ "--dist", "d", "--bogus", "x" }));
    try t.expectError(error.Usage, run(a, io, "sums", &.{}));
    try t.expectError(error.Usage, run(a, io, "sign", &.{ "--cosign", "c" }));
    // --exec is native or none: anything else is a usage error, not a guess
    try t.expectError(error.Usage, run(a, io, "package", &.{ "--version", "0.0.7", "--target", "linux-x86_64", "--binary", "b", "--license", "l", "--out", "o", "--exec", "maybe" }));
    // a directory with no release in it is a refusal (1), not a crash
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dist = try tmp.dir.realpathAlloc(a, ".");
    try t.expectEqual(@as(u8, 1), try run(a, io, "sums", &.{ "--dist", dist }));
    try t.expectEqual(@as(u8, 1), try run(a, io, "sign", &.{ "--dist", dist, "--cosign", "/nonexistent/cosign" }));
    try t.expectEqual(@as(u8, 1), try run(a, io, "tested", &.{ "--dist", dist, "--tested", dist }));
    try t.expectEqual(@as(u8, 1), try run(a, io, "record", &.{ "--tarball", "buildrules-0.0.7.tar.gz", "--out", dist }));
}

test "package then record then sums through the command line, with a binary this machine does not run" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(a, ".");
    var unused_ctx: u8 = 0;
    const io = cmds.Io{ .ctx = &unused_ctx, .run_fn = realRun, .write_fn = realWrite };
    // an arm64 Mach-O header and the stamped version string (NUL-terminated): enough for `--exec none`
    var mach = [_]u8{0} ** 64;
    @memcpy(mach[0..4], "\xcf\xfa\xed\xfe");
    std.mem.writeInt(u32, mach[4..8], 0x0100000c, .little);
    std.mem.writeInt(u32, mach[12..16], 2, .little);
    try tmp.dir.writeFile(.{ .sub_path = "bin", .data = try std.mem.concat(a, u8, &.{ &mach, "buildrules \x00\x00" ++ "0.0.7" ++ "\x00" }) });
    try tmp.dir.writeFile(.{ .sub_path = "LICENSE", .data = "l\n" });
    const args = [_][]const u8{ "--version", "0.0.7", "--target", "macos-arm64", "--binary", try join(a, base, "bin"), "--license", try join(a, base, "LICENSE"), "--out", try join(a, base, "dist"), "--exec", "none" };
    try t.expectEqual(@as(u8, 0), try run(a, io, "package", &args));
    // the same binary under another target's name is refused
    var wrong = args;
    wrong[3] = "linux-aarch64";
    try t.expectEqual(@as(u8, 1), try run(a, io, "package", &wrong));
    try t.expectEqual(@as(u8, 0), try run(a, io, "record", &.{ "--tarball", try join(a, base, "dist/buildrules-cli-0.0.7-macos-arm64.tar.gz"), "--out", try join(a, base, "rec") }));
    _ = try tmp.dir.statFile("rec/buildrules-cli-0.0.7-macos-arm64.tar.gz.sha256");
}

/// A `run` that answers every command with `says` and counts the commands.
const Says = struct {
    says: []const u8,
    calls: usize = 0,

    fn answer(ctx: *anyopaque, _: std.mem.Allocator, _: []const []const u8) anyerror!cmds.Out {
        const self: *Says = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        return .{ .code = 0, .stdout = self.says, .stderr = "" };
    }

    fn io(self: *Says) cmds.Io {
        return .{ .ctx = self, .run_fn = answer, .write_fn = realWrite };
    }
};

test "--exec native runs the binary for its version, and --exec none does not run it" {
    // The defect: the two words of --exec swapped, so a binary that can run is never asked its version (or one that cannot is run).
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realpathAlloc(a, ".");
    var elf = [_]u8{0} ** 120;
    @memcpy(elf[0..4], "\x7fELF");
    elf[4] = 2;
    elf[5] = 1;
    std.mem.writeInt(u16, elf[16..18], 2, .little);
    std.mem.writeInt(u16, elf[18..20], 62, .little);
    std.mem.writeInt(u64, elf[32..40], 64, .little);
    std.mem.writeInt(u16, elf[54..56], 56, .little);
    std.mem.writeInt(u16, elf[56..58], 1, .little);
    std.mem.writeInt(u32, elf[64..68], 1, .little);
    try tmp.dir.writeFile(.{ .sub_path = "bin", .data = &elf }); // no version text inside: only a run can vouch for it
    try tmp.dir.writeFile(.{ .sub_path = "LICENSE", .data = "l\n" });
    const out = try join(a, base, "dist");
    var args = [_][]const u8{ "--version", "0.0.7", "--target", "linux-x86_64", "--binary", try join(a, base, "bin"), "--license", try join(a, base, "LICENSE"), "--out", out, "--exec", "native" };
    var good = Says{ .says = "buildrules 0.0.7\n" };
    try t.expectEqual(@as(u8, 0), try run(a, good.io(), "package", &args));
    try t.expectEqual(@as(usize, 1), good.calls);
    var bad = Says{ .says = "buildrules 0.0.3-poc\n" };
    try t.expectEqual(@as(u8, 1), try run(a, bad.io(), "package", &args));
    try t.expectEqual(@as(usize, 1), bad.calls);
    // none: nothing is run, and the missing version text in the bytes is the refusal
    args[11] = "none";
    var idle = Says{ .says = "buildrules 0.0.7\n" };
    try t.expectEqual(@as(u8, 1), try run(a, idle.io(), "package", &args));
    try t.expectEqual(@as(usize, 0), idle.calls);
}

/// `args` and `--dry value`.
fn withDry(a: std.mem.Allocator, args: []const []const u8, value: []const u8) ![]const []const u8 {
    return std.mem.concat(a, []const u8, &.{ args, &.{ "--dry", value } });
}

test "--dry is exact: true or false (verify requires it), and anything else is a usage error before any file is read" {
    // The defect: a dry run taken for a real one by a typo, or the other way round (a real verify that skips the attestations).
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var unused_ctx: u8 = 0;
    const io = cmds.Io{ .ctx = &unused_ctx, .run_fn = realRun, .write_fn = realWrite };
    const base = [_][]const u8{ "--root", "/nowhere", "--repo", "o/n", "--tag", "v0.0.7", "--sha", "e" ** 40, "--dist", "/nowhere/dist", "--workflow", ".github/workflows/release.yml", "--cli", "/nowhere/cli", "--rebuilt", "/nowhere/rebuilt" };
    // missing: required
    try t.expectError(error.Usage, run(a, io, "verify", &base));
    for ([_][]const u8{ "yes", "True", "1", "", "TRUE", "false " }) |bad| {
        try t.expectError(error.Usage, run(a, io, "verify", try withDry(a, &base, bad)));
        try t.expectError(error.Usage, run(a, io, "plan", &.{ "--root", "/nowhere", "--sha", "e" ** 40, "--dry", bad }));
        try t.expectError(error.Usage, run(a, io, "sign", &.{ "--dist", "/nowhere", "--dry", bad }));
    }
    // the two exact values pass the flag (and then fail on the files that are not there, which is not a usage error)
    for ([_][]const u8{ "true", "false" }) |good| {
        const r = run(a, io, "verify", try withDry(a, &base, good));
        try t.expect(if (r) |_| false else |e| e != error.Usage);
    }
    // sign: dry defaults to false
    try t.expectEqual(@as(u8, 1), try run(a, io, "sign", &.{ "--dist", "/nowhere", "--cosign", "/nonexistent/cosign" }));
    try t.expectEqual(@as(u8, 1), try run(a, io, "sign", &.{ "--dist", "/nowhere", "--dry", "true" }));
}

test "the targets of --targets and --native are comma lists, and tested --targets refuses what is not walked" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try targetList(a, "linux-x86_64,macos-arm64");
    try t.expectEqual(@as(usize, 2), l.len);
    try t.expectEqualStrings("macos-arm64", l[1]);
    var unused_ctx: u8 = 0;
    const io = cmds.Io{ .ctx = &unused_ctx, .run_fn = realRun, .write_fn = realWrite };
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    try t.expectEqual(@as(u8, 1), try run(a, io, "tested", &.{ "--dist", dir, "--tested", dir, "--targets", "macos-x86_64" }));
    try t.expectEqual(@as(u8, 1), try run(a, io, "package-all", &.{ "--version", "0.0.7", "--bins", dir, "--license", dir, "--out", dir, "--native", "linux-x86-64" }));
}
