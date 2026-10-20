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
