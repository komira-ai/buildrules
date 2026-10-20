//! The four command-line binaries of a release are what their names say, read from the bytes of the files the build made (not from the build's
//! own arguments): an ELF of the machine for the two Linux targets, static; a Mach-O of the cpu for the two macOS ones. The rules of the header are
//! tools/release/binhdr.zig (tested there); this file feeds them the four built executables, which the test target gets as data.
const std = @import("std");
const binhdr = @import("binhdr");
const t = std.testing;

fn binary(target: []const u8) ![]u8 {
    const work = try std.process.getEnvVarOwned(t.allocator, "BUILDRULES_TEST_WORK");
    defer t.allocator.free(work);
    const path = try std.fs.path.join(t.allocator, &.{ work, target });
    defer t.allocator.free(path);
    return std.fs.cwd().readFileAlloc(t.allocator, path, 1 << 28);
}

test "each built binary has the header of the target it is built for" {
    // The defect: a zig_exe whose `target` is not the one its name says, or that is not the program (a script, an empty file).
    for (binhdr.targets) |target| {
        const bytes = try binary(target);
        defer t.allocator.free(bytes);
        if (binhdr.problem(bytes, target)) |why| {
            std.debug.print("{s}: {s}\n", .{ target, why });
            return error.WrongHeader;
        }
    }
}

test "the four binaries are four different programs: each is refused as every other target" {
    // The defect: two targets built from one attribute, so a "macos-arm64" file that is really the x86_64 build passes only because it is checked against itself.
    for (binhdr.targets) |target| {
        const bytes = try binary(target);
        defer t.allocator.free(bytes);
        for (binhdr.targets) |other| {
            if (std.mem.eql(u8, other, target)) continue;
            try t.expect(binhdr.problem(bytes, other) != null);
        }
    }
}

fn versionFile() ![]u8 {
    const work = try std.process.getEnvVarOwned(t.allocator, "BUILDRULES_TEST_WORK");
    defer t.allocator.free(work);
    const path = try std.fs.path.join(t.allocator, &.{ work, "VERSION" });
    defer t.allocator.free(path);
    return std.fs.cwd().readFileAlloc(t.allocator, path, 64);
}

test "release_binaries holds each target's binary at the path of its target, byte for byte" {
    // The defect: a directory whose names and contents are crossed (the arm64 program under macos-x86_64), which `release package-all` would then package under the
    // wrong name; each file is held to the header of the path it is at, and is the very file the target built.
    for (binhdr.targets) |target| {
        const work = try std.process.getEnvVarOwned(t.allocator, "BUILDRULES_TEST_WORK");
        defer t.allocator.free(work);
        const path = try std.fs.path.join(t.allocator, &.{ work, "release_binaries", target, "buildrules" });
        defer t.allocator.free(path);
        const in_dir = try std.fs.cwd().readFileAlloc(t.allocator, path, 1 << 28);
        defer t.allocator.free(in_dir);
        const built = try binary(target);
        defer t.allocator.free(built);
        if (binhdr.problem(in_dir, target)) |why| {
            std.debug.print("release_binaries/{s}/buildrules: {s}\n", .{ target, why });
            return error.WrongHeader;
        }
        try t.expectEqualSlices(u8, built, in_dir);
    }
}

test "every built binary holds the version it prints as a string of its own" {
    // The defect: a version the stamp never reached, or reached only inside a longer string, which `release package --exec none` could not tell from the real thing on
    // a binary it cannot run. A build that is not a release is stamped `<MAJOR.MINOR>-dev`; the rule is binhdr.holdsVersion, tested on its own in tools/release.
    const text = try versionFile();
    defer t.allocator.free(text);
    const stamp = try std.fmt.allocPrint(t.allocator, "{s}-dev", .{std.mem.trim(u8, text, " \r\n")});
    defer t.allocator.free(stamp);
    for (binhdr.targets) |target| {
        const bytes = try binary(target);
        defer t.allocator.free(bytes);
        if (!binhdr.holdsVersion(bytes, stamp)) {
            std.debug.print("{s}: no string `{s}` of its own (NUL before and after)\n", .{ target, stamp });
            return error.NoVersionString;
        }
    }
}
