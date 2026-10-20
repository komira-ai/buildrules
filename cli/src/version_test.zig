//! `buildrules --version`: it prints the version the program was built as, and that version is the one the build stamped (cli/version.bzl):
//! the release workflow's planned number, or the VERSION file's MAJOR.MINOR with `-dev` for any other build. Every test is named for the defect it catches.

const std = @import("std");
const kit = @import("testkit.zig");
const main = @import("main.zig");
const t = std.testing;

/// Why `v` cannot be what a build of a tree whose VERSION file reads `file` stamps; null when it can: `<MAJOR.MINOR>-dev`, or
/// `<MAJOR.MINOR>.<PATCH>` with PATCH digits only, no leading zero.
fn problem(v: []const u8, file: []const u8) ?[]const u8 {
    const mm = std.mem.trim(u8, file, " \r\n");
    if (mm.len == 0) return "the VERSION file is empty";
    if (std.mem.endsWith(u8, v, "-dev")) {
        if (std.mem.eql(u8, v[0 .. v.len - "-dev".len], mm)) return null;
        return "a -dev version is not the VERSION file's MAJOR.MINOR";
    }
    if (!std.mem.startsWith(u8, v, mm) or v.len <= mm.len + 1 or v[mm.len] != '.') return "a release version is not the VERSION file's MAJOR.MINOR and a patch";
    const patch = v[mm.len + 1 ..];
    if (patch.len > 9 or (patch.len > 1 and patch[0] == '0')) return "the patch has a leading zero or is too long";
    for (patch) |c| {
        if (c < '0' or c > '9') return "the patch is not digits";
    }
    return null;
}

test "--version prints the stamped version, and nothing else" {
    // The defect: the old hard-coded constant (a number that is no release's) printed whatever the build stamped.
    const h = try kit.Harness.create();
    defer h.destroy();
    const r = h.run(&.{"--version"});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("buildrules " ++ main.version ++ "\n", r.out);
    try t.expect(kit.contains(main.version, "poc") == false);
}

test "the stamp of this build is -dev of the VERSION file, or a release number of its MAJOR.MINOR" {
    // The defect: a stamp that ignores VERSION (a dev build claiming a release; a release of another MAJOR.MINOR than the file's).
    const work = try std.process.getEnvVarOwned(t.allocator, "BUILDRULES_TEST_WORK");
    defer t.allocator.free(work);
    const path = try std.fs.path.join(t.allocator, &.{ work, "VERSION" });
    defer t.allocator.free(path);
    const file = try std.fs.cwd().readFileAlloc(t.allocator, path, 1 << 10);
    defer t.allocator.free(file);
    if (problem(main.version, file)) |why| {
        std.debug.print("version {s}, VERSION file {s}: {s}\n", .{ main.version, std.mem.trim(u8, file, "\n"), why });
        return error.BadStamp;
    }
}

test "problem: every wrong stamp is refused, the two right shapes are not" {
    try t.expectEqual(@as(?[]const u8, null), problem("0.0-dev", "0.0\n"));
    try t.expectEqual(@as(?[]const u8, null), problem("0.0.7", "0.0\n"));
    try t.expectEqual(@as(?[]const u8, null), problem("1.12.0", "1.12"));
    // the old constant, a dev build of another MAJOR.MINOR, a release of another one
    try t.expect(problem("0.0.3-poc", "0.0\n") != null);
    try t.expect(problem("0.1-dev", "0.0\n") != null);
    try t.expect(problem("0.1.2", "0.0\n") != null);
    try t.expect(problem("1.0.2", "1.00\n") != null);
    // a release with no patch, with a leading zero, with a suffix; the bare file
    try t.expect(problem("0.0", "0.0\n") != null);
    try t.expect(problem("0.0.", "0.0\n") != null);
    try t.expect(problem("0.0.07", "0.0\n") != null);
    try t.expect(problem("0.0.7rc1", "0.0\n") != null);
    try t.expect(problem("0.0.7-dev", "0.0\n") != null);
    try t.expect(problem("0.0-dev", "") != null);
}
