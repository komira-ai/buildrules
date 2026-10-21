//! No pinned download depends on a host other than github.com without saying so. buck2's `download_file` takes one URL, so a pin whose upstream is down cannot fall back:
//! a pin is either hosted on github.com (a release asset of this repository, or an upstream that is itself a GitHub release), or its host is listed in `allow` below with the reason
//! it is not mirrored yet. A pure function of the text of the pin tables (the zig_test's `data`, under BUILDRULES_TEST_WORK), tested against planted text.
//!
//! What the rules catch:
//!  - a `https://` URL in the code of a pin table (comment lines are not read, so a row may name its upstream) whose host is not github.com and not in `allow`
//!    (a new pin on a single origin, or the busybox row pointing back at busybox.net);
//!  - an `allow` entry with no real reason, for github.com itself, for a host no table uses any more, or listed twice (the list stays what the tables need);
//!  - the busybox rows of rules/pins/pins.bzl and rules/rust/pins.bzl: both pin the one mirror asset, and name the upstream in a comment (provenance);
//!  - tools/held/mirror-busybox.sh: it names the same release tag and upstream, is a dry run unless `--apply`, and never passes the flags that replace an asset.
const std = @import("std");
const wc = @import("workflow_check.zig");
const t = std.testing;

const Findings = wc.Findings;
const add = wc.add;

/// The mirror asset of busybox 1.35.0 and the upstream it is a copy of.
pub const mirror_url = "https://github.com/komira-ai/buildrules/releases/download/mirror-busybox-1.35.0/busybox";
pub const upstream_url = "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox";
pub const tag = "mirror-busybox-1.35.0";

pub const Allow = struct { host: []const u8, reason: []const u8 };

/// Hosts a pin may name without a mirror on github.com, each with the reason. Remove a line when its pins are hosted; the check fails on a line no table needs.
pub const allow = [_]Allow{
    .{ .host = "ziglang.org", .reason = "zig compilers: the beta stage retries through zig.linus.dev (docs/pins.md); no release asset yet" },
    .{ .host = "conda.anaconda.org", .reason = "conda-forge runtime libraries and kcov's static libraries: the beta stage retries through repo.prefix.dev; no release asset yet" },
    .{ .host = "nodejs.org", .reason = "the node tarballs: the beta stage retries through registry.npmmirror.com; no release asset yet" },
    .{ .host = "static.rust-lang.org", .reason = "the Rust distribution (CloudFront): no mirror found or checked; no release asset yet" },
    .{ .host = "registry.npmjs.org", .reason = "npm packages, each pinned by sha256 and integrity; no mirror found or checked; no release asset yet" },
};

pub const File = struct { name: []const u8, text: []const u8 };

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn isComment(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), "#");
}

fn urlEnd(c: u8) bool {
    return c == '"' or c == '\'' or c == ' ' or c == ')' or c == '`' or c == '>' or c == ',' or c == '\r';
}

/// The hosts named by the `https://` URLs of the code lines of `text`, in order (repeats kept). Each is a slice of `text`.
fn hostsOf(a: std.mem.Allocator, text: []const u8) !std.ArrayList([]const u8) {
    var out = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (isComment(line)) continue;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, line, pos, "https://")) |i| {
            const from = i + "https://".len;
            var j = from;
            while (j < line.len and line[j] != '/' and !urlEnd(line[j])) j += 1;
            if (j > from) try out.append(line[from..j]);
            pos = j;
        }
    }
    return out;
}

/// The lines of the `"busybox": {` row of a pin table, or null.
fn busyboxRow(text: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, "\"busybox\": {") orelse return null;
    const rest = text[at..];
    const end = std.mem.indexOf(u8, rest, "\n    },") orelse rest.len;
    return rest[0..end];
}

/// Every finding of `files` (the pin tables), `script` (tools/held/mirror-busybox.sh) and the allow list `list`.
pub fn check(a: std.mem.Allocator, files: []const File, script: []const u8, list: []const Allow) !Findings {
    var f = Findings.init(a);
    const used = try a.alloc(bool, list.len);
    @memset(used, false);

    for (files) |file| {
        const hosts = try hostsOf(a, file.text);
        for (hosts.items) |h| {
            if (std.mem.eql(u8, h, "github.com")) continue;
            var known = false;
            for (list, 0..) |e, k| {
                if (std.mem.eql(u8, e.host, h)) {
                    used[k] = true;
                    known = true;
                }
            }
            if (!known) try add(a, &f, "{s}: a download from {s}, which is not github.com and not in the allow list of ci/pin_mirrors_check.zig (host it as a release asset, or list it with the reason)", .{ file.name, h });
        }
    }

    for (list, 0..) |e, k| {
        if (std.mem.eql(u8, e.host, "github.com")) try add(a, &f, "allow list: github.com needs no entry", .{});
        if (std.mem.trim(u8, e.reason, " ").len < 20) try add(a, &f, "allow list: {s} has no real reason", .{e.host});
        if (!used[k]) try add(a, &f, "allow list: {s} is named by no pin table (remove the entry)", .{e.host});
        for (list[0..k]) |before| {
            if (std.mem.eql(u8, before.host, e.host)) try add(a, &f, "allow list: {s} is listed twice", .{e.host});
        }
    }

    for (files) |file| {
        const row = busyboxRow(file.text) orelse continue;
        const want = try std.fmt.allocPrint(a, "\"url\": \"{s}\",", .{mirror_url});
        if (!has(row, want)) try add(a, &f, "{s}: the busybox row does not pin the mirror asset {s}", .{ file.name, mirror_url });
        var from_comment = false;
        var it = std.mem.splitScalar(u8, row, '\n');
        while (it.next()) |line| {
            if (isComment(line) and has(line, upstream_url)) from_comment = true;
        }
        if (!from_comment) try add(a, &f, "{s}: the busybox row does not name its upstream {s} in a comment", .{ file.name, upstream_url });
    }

    if (!has(script, "TAG=\"" ++ tag ++ "\"")) try add(a, &f, "tools/held/mirror-busybox.sh: the release tag is not {s}", .{tag});
    if (!has(script, "UPSTREAM=\"" ++ upstream_url ++ "\"")) try add(a, &f, "tools/held/mirror-busybox.sh: the upstream is not {s}", .{upstream_url});
    if (!has(script, "--apply")) try add(a, &f, "tools/held/mirror-busybox.sh: no --apply (a held script is a dry run unless told)", .{});
    if (!has(script, "apply=0")) try add(a, &f, "tools/held/mirror-busybox.sh: the dry run is not the default", .{});
    if (has(script, "--force") or has(script, "--clobber")) try add(a, &f, "tools/held/mirror-busybox.sh: --force and --clobber are never used", .{});
    try uploadRule(a, &f, script);
    try curlRule(a, &f, script);
    return f;
}

/// Every curl of the held script (a non-comment line with the word `curl`) carries --max-time, --connect-timeout and --max-redirs, so no download can hang.
fn curlRule(a: std.mem.Allocator, f: *Findings, script: []const u8) !void {
    var seen: usize = 0;
    var it = std.mem.splitScalar(u8, script, '\n');
    while (it.next()) |line| {
        if (isComment(line) or !has(line, "curl ")) continue;
        seen += 1;
        for ([_][]const u8{ "--max-time ", "--connect-timeout ", "--max-redirs " }) |flag| {
            if (!has(line, flag)) try add(a, f, "tools/held/mirror-busybox.sh: a curl without {s}: {s}", .{ std.mem.trim(u8, flag, " "), std.mem.trim(u8, line, " ") });
        }
    }
    if (seen == 0) try add(a, f, "tools/held/mirror-busybox.sh: no curl line (the downloads moved; update curlRule)", .{});
}

/// The file argument of every `gh release upload` line of the held script must end in `/busybox` (the asset name is the basename; `path#text` is only a label), contain no `#`, and there must be one.
fn uploadRule(a: std.mem.Allocator, f: *Findings, script: []const u8) !void {
    const who = "tools/held/mirror-busybox.sh";
    var seen: usize = 0;
    var it = std.mem.splitScalar(u8, script, '\n');
    while (it.next()) |line| {
        if (isComment(line)) continue;
        const at = std.mem.indexOf(u8, line, "gh release upload ") orelse continue;
        seen += 1;
        const rest = line[at + "gh release upload ".len ..];
        const q1 = std.mem.indexOfScalar(u8, rest, '"') orelse {
            try add(a, f, "{s}: an upload line without a quoted tag", .{who});
            continue;
        };
        const q2 = std.mem.indexOfScalarPos(u8, rest, q1 + 1, '"') orelse rest.len;
        const q3 = std.mem.indexOfScalarPos(u8, rest, q2 + 1, '"') orelse {
            try add(a, f, "{s}: an upload line without a quoted file argument", .{who});
            continue;
        };
        const q4 = std.mem.indexOfScalarPos(u8, rest, q3 + 1, '"') orelse rest.len;
        const arg = rest[q3 + 1 .. q4];
        if (has(arg, "#")) try add(a, f, "{s}: the upload file argument {s} has a #label; the asset name is the file's basename, so the pinned url would 404", .{ who, arg });
        if (!std.mem.endsWith(u8, arg, "/$ASSET") and !std.mem.endsWith(u8, arg, "/busybox")) try add(a, f, "{s}: the upload file argument {s} must end in /$ASSET or /busybox (the asset name is the basename)", .{ who, arg });
    }
    if (seen == 0) try add(a, f, "{s}: no gh release upload line", .{who});
}

// ---- tests -------------------------------------------------------------------------------------------------------------------------------

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

const names = [_][]const u8{ "rules/pins/pins.bzl", "rules/pins/hosts.bzl", "rules/rust/pins.bzl", "rules/node/pins.bzl", "rules/coverage/pins.bzl", "rules/mopm/pins.bzl" };

fn realFiles(a: std.mem.Allocator) ![]File {
    const out = try a.alloc(File, names.len);
    for (names, 0..) |n, i| out[i] = .{ .name = n, .text = try work(a, n) };
    return out;
}

/// `text` with the first `from` replaced by `to`; fails the test if `from` is absent (a mutant that changes nothing proves nothing).
fn mutate(a: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const i = std.mem.indexOf(u8, text, from) orelse return error.MutantDidNotApply;
    return std.mem.concat(a, u8, &.{ text[0..i], to, text[i + from.len ..] });
}

fn expectFinding(a: std.mem.Allocator, files: []const File, script: []const u8, list: []const Allow, needle: []const u8) !void {
    const f = try check(a, files, script, list);
    for (f.items) |m| {
        if (has(m, needle)) return;
    }
    std.debug.print("expected a finding with `{s}`, got {d}:\n", .{ needle, f.items.len });
    for (f.items) |m| std.debug.print("  {s}\n", .{m});
    return error.MutantSurvived;
}

/// `files` with `files[i].text` replaced.
fn with(a: std.mem.Allocator, files: []const File, i: usize, text: []const u8) ![]File {
    const out = try a.dupe(File, files);
    out[i].text = text;
    return out;
}

test "the real pin tables have no finding" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const files = try realFiles(a);
    const f = try check(a, files, try work(a, "tools/held/mirror-busybox.sh"), &allow);
    for (f.items) |m| std.debug.print("finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "the reader is not blind: github.com is read, busybox.net only in a comment, and a host ends at its first slash" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const files = try realFiles(a);
    var gh: usize = 0;
    var other: usize = 0;
    for (files) |file| {
        const hosts = try hostsOf(a, file.text);
        for (hosts.items) |h| {
            if (std.mem.eql(u8, h, "github.com")) gh += 1 else other += 1;
            try t.expect(!std.mem.eql(u8, h, "busybox.net"));
        }
    }
    try t.expect(gh >= 3);
    try t.expect(other >= 10);
    try t.expect(has(files[0].text, "busybox.net"));
    const h = try hostsOf(a, "x = \"https://a.example/b/https://c.example/\"\n# \"https://comment.example/\"\n");
    try t.expectEqual(@as(usize, 2), h.items.len);
    try t.expectEqualStrings("a.example", h.items[0]);
    try t.expectEqualStrings("c.example", h.items[1]);
}

test "mutant: the busybox pin points back at busybox.net" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const files = try realFiles(a);
    const script = try work(a, "tools/held/mirror-busybox.sh");
    for ([_]usize{ 0, 2 }) |i| {
        const m = try with(a, files, i, try mutate(a, files[i].text, "\"url\": \"" ++ mirror_url ++ "\"", "\"url\": \"" ++ upstream_url ++ "\""));
        try expectFinding(a, m, script, &allow, "a download from busybox.net");
        try expectFinding(a, m, script, &allow, "does not pin the mirror asset");
    }
}

test "mutant: a new pin on a host that is neither github.com nor listed" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const files = try realFiles(a);
    const script = try work(a, "tools/held/mirror-busybox.sh");
    const m = try with(a, files, 3, try mutate(a, files[3].text, "https://nodejs.org/dist/", "https://downloads.example/dist/"));
    try expectFinding(a, m, script, &allow, "a download from downloads.example");
    const h = try with(a, files, 1, try mutate(a, files[1].text, "https://static.rust-lang.org/dist/", "https://cdn.example/dist/"));
    try expectFinding(a, h, script, &allow, "a download from cdn.example");
}

test "a github.com release needs no entry, and a comment is never read" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const files = try realFiles(a);
    const script = try work(a, "tools/held/mirror-busybox.sh");
    const m = try with(a, files, 5, try std.mem.concat(a, u8, &.{ files[5].text, "\n# https://nowhere.example/x\nX = \"https://github.com/o/r/releases/download/v1/x\"\n" }));
    const f = try check(a, m, script, &allow);
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "mutant: the allow list is wrong" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const files = try realFiles(a);
    const script = try work(a, "tools/held/mirror-busybox.sh");
    const empty = [_]Allow{ .{ .host = "ziglang.org", .reason = "" }, allow[1], allow[2], allow[3], allow[4] };
    try expectFinding(a, files, script, &empty, "ziglang.org has no real reason");
    const stale = allow ++ [_]Allow{.{ .host = "busybox.net", .reason = "single origin, the upstream of the busybox pin" }};
    try expectFinding(a, files, script, &stale, "busybox.net is named by no pin table");
    const gh = allow ++ [_]Allow{.{ .host = "github.com", .reason = "github.com is the mirror host itself" }};
    try expectFinding(a, files, script, &gh, "github.com needs no entry");
    const twice = allow ++ [_]Allow{allow[0]};
    try expectFinding(a, files, script, &twice, "ziglang.org is listed twice");
    try expectFinding(a, files, script, allow[1..], "a download from ziglang.org");
}

test "mutant: the busybox rows disagree or lose their provenance" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const files = try realFiles(a);
    const script = try work(a, "tools/held/mirror-busybox.sh");
    const other = try with(a, files, 2, try mutate(a, files[2].text, "mirror-busybox-1.35.0/busybox", "mirror-busybox-1.35.1/busybox"));
    try expectFinding(a, other, script, &allow, "rules/rust/pins.bzl: the busybox row does not pin the mirror asset");
    const nocomment = try with(a, files, 0, try mutate(a, files[0].text, "# The upstream file is " ++ upstream_url, "# The upstream file is elsewhere"));
    try expectFinding(a, nocomment, script, &allow, "rules/pins/pins.bzl: the busybox row does not name its upstream");
}

test "mutant: the held script drifts" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const files = try realFiles(a);
    const script = try work(a, "tools/held/mirror-busybox.sh");
    try expectFinding(a, files, try mutate(a, script, "TAG=\"mirror-busybox-1.35.0\"", "TAG=\"mirror-busybox-1.35.1\""), &allow, "the release tag is not");
    try expectFinding(a, files, try mutate(a, script, "UPSTREAM=\"" ++ upstream_url ++ "\"", "UPSTREAM=\"https://mirror.example/busybox\""), &allow, "the upstream is not");
    try expectFinding(a, files, try mutate(a, script, "apply=0", "apply=1"), &allow, "the dry run is not the default");
    try expectFinding(a, files, try std.mem.concat(a, u8, &.{ script, "gh release upload --clobber\n" }), &allow, "--force and --clobber are never used");
    try expectFinding(a, files, try std.mem.concat(a, u8, &.{ script, "gh release create --force\n" }), &allow, "--force and --clobber are never used");
    const noapply = try std.mem.replaceOwned(u8, a, script, "--apply", "--go");
    try expectFinding(a, files, noapply, &allow, "no --apply");
}

test "mutant: the upload names the asset by label or by another basename" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const files = try realFiles(a);
    const script = try work(a, "tools/held/mirror-busybox.sh");
    const up = "\"$work/$ASSET\" --repo";
    const label = try mutate(a, script, up, "\"$work/official#$ASSET\" --repo");
    try expectFinding(a, files, label, &allow, "has a #label");
    try expectFinding(a, files, label, &allow, "must end in /$ASSET or /busybox");
    try expectFinding(a, files, try mutate(a, script, up, "\"$work/official\" --repo"), &allow, "must end in /$ASSET or /busybox");
    try expectFinding(a, files, try mutate(a, script, up, "\"$work/busybox#busybox\" --repo"), &allow, "has a #label");
    try expectFinding(a, files, try std.mem.replaceOwned(u8, a, script, "gh release upload", "gh release up"), &allow, "no gh release upload line");
}

test "mutant: a curl of the held script without a time limit" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const files = try realFiles(a);
    const script = try work(a, "tools/held/mirror-busybox.sh");
    try expectFinding(a, files, try mutate(a, script, "--max-time 60 ", ""), &allow, "a curl without --max-time");
    try expectFinding(a, files, try mutate(a, script, "--connect-timeout 20 ", ""), &allow, "a curl without --connect-timeout");
    try expectFinding(a, files, try mutate(a, script, "--max-redirs 5 ", ""), &allow, "a curl without --max-redirs");
    try expectFinding(a, files, try std.mem.concat(a, u8, &.{ script, "curl -sS -o x https://github.com/x\n" }), &allow, "a curl without --max-time");
}
