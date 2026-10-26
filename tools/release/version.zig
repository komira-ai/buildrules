//! The version scheme of the automatic release (RELEASING.md): `v<MAJOR>.<MINOR>.<PATCH>`.
//!
//!  - MAJOR.MINOR is the committed `VERSION` file (`0.0`), changed by a pull request.
//!  - PATCH is the highest existing `v<MAJOR>.<MINOR>.N` plus one, and 1 when there is none: the first release is v0.0.1.
//!  - A commit is released when it touches more than documentation or CI (`releaseWorthy`).
//!
//! Everything here is a pure function of text, so each rule is tested against faulty input.
const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }
};

pub const MajorMinor = struct { major: u32, minor: u32 };

/// A number as the scheme writes it: digits only, no sign, no leading zero (except `0` itself), small enough to be a version.
fn number(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 9) return null;
    if (s.len > 1 and s[0] == '0') return null;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
    }
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// The content of the `VERSION` file: `<MAJOR>.<MINOR>` and one optional newline, nothing else (no `v`, no patch, no space).
pub fn parseMajorMinor(text: []const u8) error{BadVersionFile}!MajorMinor {
    const body = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    const dot = std.mem.indexOfScalar(u8, body, '.') orelse return error.BadVersionFile;
    const major = number(body[0..dot]) orelse return error.BadVersionFile;
    const minor = number(body[dot + 1 ..]) orelse return error.BadVersionFile;
    return .{ .major = major, .minor = minor };
}

/// `v<MAJOR>.<MINOR>.<PATCH>` and nothing else: a tag such as `v1`, `v0.0.1-rc1`, `0.0.1` or `v01.0.0` is not a release.
pub fn parseTag(name: []const u8) ?Version {
    if (name.len < 6 or name[0] != 'v') return null;
    const body = name[1..];
    const d1 = std.mem.indexOfScalar(u8, body, '.') orelse return null;
    const d2 = std.mem.indexOfScalarPos(u8, body, d1 + 1, '.') orelse return null;
    const major = number(body[0..d1]) orelse return null;
    const minor = number(body[d1 + 1 .. d2]) orelse return null;
    const patch = number(body[d2 + 1 ..]) orelse return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}

/// `0.0.1` (no `v`): what names the archive and its directory.
pub fn numberText(a: std.mem.Allocator, v: Version) ![]u8 {
    return std.fmt.allocPrint(a, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
}

/// `v0.0.1`: the tag.
pub fn tagName(a: std.mem.Allocator, v: Version) ![]u8 {
    return std.fmt.allocPrint(a, "v{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
}

pub const NextError = error{TagsAheadOfVersionFile};

/// The version the next release takes: patch = the highest existing patch of `mm` plus one (1 when there is none). A tag whose
/// MAJOR.MINOR is above the file's means the file went backwards, and no release is made until it is fixed.
pub fn next(existing: []const Version, mm: MajorMinor) NextError!Version {
    var highest: u32 = 0;
    for (existing) |v| {
        if (v.major > mm.major or (v.major == mm.major and v.minor > mm.minor)) return error.TagsAheadOfVersionFile;
        if (v.major == mm.major and v.minor == mm.minor and v.patch > highest) highest = v.patch;
    }
    return .{ .major = mm.major, .minor = mm.minor, .patch = highest + 1 };
}

/// The greatest of `existing`, or null.
pub fn latest(existing: []const Version) ?Version {
    var best: ?Version = null;
    for (existing) |v| {
        if (best == null or Version.order(v, best.?) == .gt) best = v;
    }
    return best;
}

/// The greatest of `existing` that is below `v`, or null.
pub fn previousOf(existing: []const Version, v: Version) ?Version {
    var best: ?Version = null;
    for (existing) |e| {
        if (Version.order(e, v) != .lt) continue;
        if (best == null or Version.order(e, best.?) == .gt) best = e;
    }
    return best;
}

/// Whether a changed path is documentation or CI, which alone never make a release:
///  - `docs/` (the documents), `*.md` anywhere (READMEs, RELEASING.md), `LICENSE`, `.gitignore`;
///  - `.github/` (the workflows) and `ci/` (the CI target groups, the completeness check, the workflow check).
/// Everything else is released: the rules, the toolchain pins, the command line, `VERSION`, `tools/` (the release tool included),
/// the examples, and also `site/` and `infra/`, which are code that is built and tested.
pub fn isDocOrCi(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "docs/")) return true;
    if (std.mem.startsWith(u8, path, ".github/")) return true;
    if (std.mem.startsWith(u8, path, "ci/")) return true;
    if (std.mem.endsWith(u8, path, ".md")) return true;
    if (std.mem.eql(u8, path, "LICENSE")) return true;
    if (std.mem.eql(u8, path, ".gitignore")) return true;
    return false;
}

/// The first of `paths` that is neither documentation nor CI (the reason to release), or null.
pub fn releaseWorthy(paths: []const []const u8) ?[]const u8 {
    for (paths) |p| {
        if (!isDocOrCi(p)) return p;
    }
    return null;
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;

fn ver(major: u32, minor: u32, patch: u32) Version {
    return .{ .major = major, .minor = minor, .patch = patch };
}

test "the VERSION file is MAJOR.MINOR and nothing else" {
    try t.expectEqual(MajorMinor{ .major = 0, .minor = 0 }, try parseMajorMinor("0.0\n"));
    try t.expectEqual(MajorMinor{ .major = 0, .minor = 0 }, try parseMajorMinor("0.0"));
    try t.expectEqual(MajorMinor{ .major = 12, .minor = 305 }, try parseMajorMinor("12.305\n"));
    for ([_][]const u8{ "", "\n", "0", "0.", ".0", "v0.0", "0.0.1", "0.0\n\n", " 0.0", "0.0 ", "00.1", "1.01", "-1.0", "1.+0", "a.b", "0,0", "1234567890.0" }) |bad| {
        try t.expectError(error.BadVersionFile, parseMajorMinor(bad));
    }
}

test "a tag is a release only as vMAJOR.MINOR.PATCH" {
    try t.expectEqual(ver(0, 0, 1), parseTag("v0.0.1").?);
    try t.expectEqual(ver(3, 14, 159), parseTag("v3.14.159").?);
    for ([_][]const u8{ "", "v", "v1", "v1.2", "1.2.3", "v1.2.3-rc1", "v1.2.3.4", "v01.2.3", "v1.02.3", "v1.2.03", "v1..3", "vx.y.z", "V1.2.3", "v1.2.3+b", "latest", "v-1.0.0" }) |bad| {
        try t.expect(parseTag(bad) == null);
    }
}

test "the first release is v0.0.1, then the highest patch plus one" {
    const mm = MajorMinor{ .major = 0, .minor = 0 };
    try t.expectEqual(ver(0, 0, 1), try next(&.{}, mm));
    try t.expectEqual(ver(0, 0, 2), try next(&.{ver(0, 0, 1)}, mm));
    // the highest, not the count and not the last listed
    try t.expectEqual(ver(0, 0, 11), try next(&.{ ver(0, 0, 10), ver(0, 0, 2), ver(0, 0, 9) }, mm));
    // a gap is not filled
    try t.expectEqual(ver(0, 0, 8), try next(&.{ ver(0, 0, 1), ver(0, 0, 7) }, mm));
}

test "a bumped MAJOR.MINOR starts again at patch 1, and an older line does not count" {
    try t.expectEqual(ver(0, 1, 1), try next(&.{ ver(0, 0, 1), ver(0, 0, 40) }, .{ .major = 0, .minor = 1 }));
    try t.expectEqual(ver(0, 1, 3), try next(&.{ ver(0, 0, 40), ver(0, 1, 1), ver(0, 1, 2) }, .{ .major = 0, .minor = 1 }));
    try t.expectEqual(ver(1, 0, 1), try next(&.{ ver(0, 9, 9) }, .{ .major = 1, .minor = 0 }));
}

test "a VERSION file behind the tags is refused, not released" {
    try t.expectError(error.TagsAheadOfVersionFile, next(&.{ver(0, 2, 1)}, .{ .major = 0, .minor = 1 }));
    try t.expectError(error.TagsAheadOfVersionFile, next(&.{ver(1, 0, 1)}, .{ .major = 0, .minor = 9 }));
    try t.expectError(error.TagsAheadOfVersionFile, next(&.{ ver(0, 0, 1), ver(0, 5, 1) }, .{ .major = 0, .minor = 1 }));
}

test "latest and previousOf order by MAJOR, MINOR, PATCH, not by text" {
    const all = [_]Version{ ver(0, 0, 9), ver(0, 0, 10), ver(0, 1, 1), ver(0, 0, 2) };
    try t.expectEqual(ver(0, 1, 1), latest(&all).?);
    try t.expect(latest(&.{}) == null);
    try t.expectEqual(ver(0, 0, 10), previousOf(&all, ver(0, 1, 1)).?);
    try t.expectEqual(ver(0, 0, 2), previousOf(&all, ver(0, 0, 9)).?);
    try t.expect(previousOf(&all, ver(0, 0, 2)) == null);
}

test "text forms" {
    const a = t.allocator;
    const n = try numberText(a, ver(0, 0, 7));
    defer a.free(n);
    const tg = try tagName(a, ver(0, 0, 7));
    defer a.free(tg);
    try t.expectEqualStrings("0.0.7", n);
    try t.expectEqualStrings("v0.0.7", tg);
    try t.expectEqual(ver(0, 0, 7), parseTag(tg).?);
}

test "documentation and CI alone are not released; anything else is" {
    const skipped = [_][]const u8{
        "README.md",             "RELEASING.md",       "docs/contract.md",           "docs/pins.md",    "rules/rust/README.md", "tools/scrub/README.md",
        "examples/mojo/README.md", "LICENSE",            ".gitignore",                 ".github/workflows/ci.yml", ".github/workflows/release.yml", "ci/BUCK",
        "ci/all.bzl",            "ci/workflow_check.zig", "ci/negative/BUCK",        "site/README.md",
    };
    for (skipped) |p| try t.expect(isDocOrCi(p));
    const released = [_][]const u8{
        "VERSION",        "rules/zig/zig.bzl", "rules/rust/pins.bzl", "cli/src/main.zig", "tools/release/release.zig", "tools/buck2",
        "toolchains/BUCK", "site/tools/content/home.ts", "infra/site/main.tf", "examples/hello/BUCK", ".buckconfig", "BUCK",
        // look-alikes: a prefix that is not the directory, a suffix that is not .md
        "docs", "docsx/a.zig", "ci", "cix/BUCK", "notes.md.zig", "rules/md", ".github", "LICENSE.txt", "sub/LICENSE", "sub/.gitignore",
    };
    for (released) |p| try t.expect(!isDocOrCi(p));
}

test "a push is released when any one path is more than docs or CI" {
    try t.expect(releaseWorthy(&.{}) == null);
    try t.expect(releaseWorthy(&.{ "README.md", "docs/a.md", ".github/workflows/ci.yml", "ci/BUCK" }) == null);
    try t.expectEqualStrings("rules/zig/zig.bzl", releaseWorthy(&.{ "README.md", "rules/zig/zig.bzl", "ci/BUCK" }).?);
    try t.expectEqualStrings("VERSION", releaseWorthy(&.{"VERSION"}).?);
}
