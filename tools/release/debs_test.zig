//! The tests of debs.zig, and `sample`, a package of the shape `tools/channels` writes for the tests of the steps that read a .deb (binaries.zig, cmds.zig): an `ar`
//! archive of `debian-binary`, `control.tar.gz` and `data.tar.gz`. A `_test.zig` file is not counted in the coverage of the tool (like bump_test.zig).
const std = @import("std");
const gz = @import("gz.zig");
const tar = @import("tar.zig");
const debs_mod = @import("debs.zig");

const package_name = debs_mod.package_name;
const check = debs_mod.check;
const name = debs_mod.name;
const parseName = debs_mod.parseName;
const archOf = debs_mod.archOf;
const t = std.testing;

pub fn arMember(a: std.mem.Allocator, out: *std.ArrayList(u8), member: []const u8, data: []const u8) !void {
    var h: [60]u8 = undefined;
    @memset(&h, ' ');
    @memcpy(h[0..member.len], member);
    _ = try std.fmt.bufPrint(h[48..58], "{d}", .{data.len});
    h[58] = '`';
    h[59] = '\n';
    try out.appendSlice(a, &h);
    try out.appendSlice(a, data);
    if (data.len % 2 == 1) try out.append(a, '\n');
}

/// A package of the shape `tools/channels` writes, for the tests of this file and of the steps that read a .deb: the control file says what it is told,
/// and `/usr/bin/buildrules` holds `binary`.
pub fn sample(a: std.mem.Allocator, v: []const u8, arch: []const u8, binary: []const u8) ![]u8 {
    const ctrl = try std.fmt.allocPrint(a, "Package: {s}\nVersion: {s}\nArchitecture: {s}\nMaintainer: nobody\nDescription: d\n", .{ package_name, v, arch });
    const control_tar = try tar.build(a, &.{
        .{ .name = "./", .kind = .dir, .data = "", .mode = 0o755 },
        .{ .name = "./control", .kind = .file, .data = ctrl },
    });
    const data_tar = try tar.build(a, &.{
        .{ .name = "./usr/", .kind = .dir, .data = "", .mode = 0o755 },
        .{ .name = "./usr/bin/", .kind = .dir, .data = "", .mode = 0o755 },
        .{ .name = "./usr/bin/" ++ package_name, .kind = .file, .data = binary, .mode = 0o755 },
    });
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, "!<arch>\n");
    try arMember(a, &out, "debian-binary", "2.0\n");
    try arMember(a, &out, "control.tar.gz", try gz.gzip(a, control_tar));
    try arMember(a, &out, "data.tar.gz", try gz.gzip(a, data_tar));
    return out.toOwnedSlice(a);
}


test "names: buildrules_<version>_<arch>.deb, read back, and nothing else is a deb of this release" {
    const a = t.allocator;
    const n = try name(a, "0.0.7", "amd64");
    defer a.free(n);
    try t.expectEqualStrings("buildrules_0.0.7_amd64.deb", n);
    const parsed = parseName(n).?;
    try t.expectEqualStrings("0.0.7", parsed.version);
    try t.expectEqualStrings("amd64", parsed.arch);
    try t.expectEqualStrings("arm64", parseName("buildrules_1.2.3_arm64.deb").?.arch);
    for ([_][]const u8{ "buildrules_0.0.7_i386.deb", "buildrules_0.0.7_amd64.deb.sigstore.json", "buildrules-0.0.7.tar.gz", "buildrules_amd64.deb", "other_0.0.7_amd64.deb", "buildrules_0.0.7_amd64.rpm", "" }) |bad| {
        try t.expect(parseName(bad) == null);
    }
    try t.expectEqualStrings("amd64", archOf("linux-x86_64").?);
    try t.expectEqualStrings("arm64", archOf("linux-aarch64").?);
    try t.expect(archOf("macos-arm64") == null);
    try t.expect(archOf("") == null);
}

test "check: the package of this version and architecture whose program is the tarball's is accepted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deb = try sample(a, "0.0.7", "amd64", "the program");
    try check(a, deb, "0.0.7", "amd64", "the program");
}

test "check: each defect is refused for its own reason" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try sample(a, "0.0.7", "amd64", "the program");
    // another program than the tarball's: one byte differs
    try t.expectError(error.WrongBinary, check(a, good, "0.0.7", "amd64", "the programs"));
    try t.expectError(error.WrongBinary, check(a, try sample(a, "0.0.7", "amd64", "the prograM"), "0.0.7", "amd64", "the program"));
    // another version or architecture than the name says
    try t.expectError(error.WrongControl, check(a, good, "0.0.8", "amd64", "the program"));
    try t.expectError(error.WrongControl, check(a, good, "0.0.7", "arm64", "the program"));
    try t.expectError(error.WrongControl, check(a, try sample(a, "0.0.70", "amd64", "the program"), "0.0.7", "amd64", "the program"));
    // not an ar archive, a cut one, a member order that is not a package's
    try t.expectError(error.NotADeb, check(a, "not a deb", "0.0.7", "amd64", "the program"));
    try t.expectError(error.NotADeb, check(a, good[0 .. good.len - 5], "0.0.7", "amd64", "the program"));
    try t.expectError(error.NotADeb, check(a, good[0..8], "0.0.7", "amd64", "the program"));
    try t.expectError(error.NotADeb, check(a, good[0 .. 8 + 30], "0.0.7", "amd64", "the program"));
    var bad_header = try a.dupe(u8, good);
    bad_header[8 + 58] = 'x';
    try t.expectError(error.NotADeb, check(a, bad_header, "0.0.7", "amd64", "the program"));
    var bad_size = try a.dupe(u8, good);
    @memcpy(bad_size[8 + 48 .. 8 + 58], "9999999999");
    try t.expectError(error.NotADeb, check(a, bad_size, "0.0.7", "amd64", "the program"));
    var bad_version = try a.dupe(u8, good);
    bad_version[8 + 60] = '3'; // debian-binary says 3.0
    try t.expectError(error.NotADeb, check(a, bad_version, "0.0.7", "amd64", "the program"));
    var bad_name = try a.dupe(u8, good);
    @memcpy(bad_name[8 .. 8 + 13], "debian-binarz");
    try t.expectError(error.NotADeb, check(a, bad_name, "0.0.7", "amd64", "the program"));
    // a size that is not a number
    var text_size = try a.dupe(u8, good);
    @memcpy(text_size[8 + 48 .. 8 + 58], "abcdefghij");
    try t.expectError(error.NotADeb, check(a, text_size, "0.0.7", "amd64", "the program"));
    // the second and third members are not named control.tar.gz and data.tar.gz (the offsets of the headers are those of `good`)
    const second = std.mem.indexOf(u8, good, "control.tar.gz").?;
    var bad_control_name = try a.dupe(u8, good);
    bad_control_name[second] = 'C';
    try t.expectError(error.NotADeb, check(a, bad_control_name, "0.0.7", "amd64", "the program"));
    const third = std.mem.indexOf(u8, good, "data.tar.gz").?;
    var bad_data_name = try a.dupe(u8, good);
    bad_data_name[third] = 'D';
    try t.expectError(error.NotADeb, check(a, bad_data_name, "0.0.7", "amd64", "the program"));
}

test "name is built from the allocator, and a failing allocator is an error" {
    var fa = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, name(fa.allocator(), "0.0.7", "amd64"));
}

test "check: a package with no program, no control file, or a control member that is not gzip is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const empty_tar = try tar.build(a, &.{});
    const control_tar = try tar.build(a, &.{.{ .name = "./control", .kind = .file, .data = "Package: buildrules\nVersion: 0.0.7\nArchitecture: amd64\n" }});
    const other_tar = try tar.build(a, &.{.{ .name = "./other", .kind = .file, .data = "x" }});
    const cases = [_]struct { control: []const u8, data: []const u8, want: anyerror }{
        .{ .control = control_tar, .data = empty_tar, .want = error.NoBinary },
        .{ .control = control_tar, .data = other_tar, .want = error.NoBinary },
        .{ .control = empty_tar, .data = empty_tar, .want = error.WrongControl },
        .{ .control = other_tar, .data = empty_tar, .want = error.WrongControl },
    };
    for (cases) |c| {
        var out = std.ArrayList(u8).empty;
        try out.appendSlice(a, "!<arch>\n");
        try arMember(a, &out, "debian-binary", "2.0\n");
        try arMember(a, &out, "control.tar.gz", try gz.gzip(a, c.control));
        try arMember(a, &out, "data.tar.gz", try gz.gzip(a, c.data));
        try t.expectError(c.want, check(a, out.items, "0.0.7", "amd64", "the program"));
    }
    // a control member that is not gzip data
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, "!<arch>\n");
    try arMember(a, &out, "debian-binary", "2.0\n");
    try arMember(a, &out, "control.tar.gz", "plainly not gzip");
    try arMember(a, &out, "data.tar.gz", try gz.gzip(a, empty_tar));
    try t.expectError(error.NotADeb, check(a, out.items, "0.0.7", "amd64", "the program"));
    // a control member that is gzip of something that is not a tar
    var out3 = std.ArrayList(u8).empty;
    try out3.appendSlice(a, "!<arch>\n");
    try arMember(a, &out3, "debian-binary", "2.0\n");
    try arMember(a, &out3, "control.tar.gz", try gz.gzip(a, "not a tar either"));
    try arMember(a, &out3, "data.tar.gz", try gz.gzip(a, empty_tar));
    try t.expectError(error.NotADeb, check(a, out3.items, "0.0.7", "amd64", "the program"));
    // a data member that is gzip of something that is not a tar
    var out2 = std.ArrayList(u8).empty;
    try out2.appendSlice(a, "!<arch>\n");
    try arMember(a, &out2, "debian-binary", "2.0\n");
    try arMember(a, &out2, "control.tar.gz", try gz.gzip(a, control_tar));
    try arMember(a, &out2, "data.tar.gz", try gz.gzip(a, "not a tar at all"));
    try t.expectError(error.NotADeb, check(a, out2.items, "0.0.7", "amd64", "the program"));
    // a package with a fourth member, or only two
    var four = std.ArrayList(u8).empty;
    try four.appendSlice(a, "!<arch>\n");
    try arMember(a, &four, "debian-binary", "2.0\n");
    try arMember(a, &four, "control.tar.gz", try gz.gzip(a, control_tar));
    try arMember(a, &four, "data.tar.gz", try gz.gzip(a, empty_tar));
    try arMember(a, &four, "extra", "x");
    try t.expectError(error.NotADeb, check(a, four.items, "0.0.7", "amd64", "the program"));
}

test "out of memory: check fails whenever an allocation fails, and never reports a pass" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deb = try sample(a, "0.0.7", "amd64", "the program");
    var backing = std.heap.ArenaAllocator.init(t.allocator);
    defer backing.deinit();
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        _ = backing.reset(.retain_capacity);
        var fa = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = i });
        const passed = if (check(fa.allocator(), deb, "0.0.7", "amd64", "the program")) |_| true else |_| false;
        if (!fa.has_induced_failure) {
            try t.expect(passed);
            try t.expect(i > 0);
            return;
        }
        try t.expect(!passed);
    }
    return error.SweepDidNotEnd;
}
