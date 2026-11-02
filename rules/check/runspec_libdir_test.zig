//! The cases of `--lib-dir` (runspec.zig): the shared libraries a test opens by their bare name. Linux puts them on LD_LIBRARY_PATH after the compiler's lib;
//! macOS puts them first in DYLD_FALLBACK_LIBRARY_PATH. The environment a run gets without the option is the one runspec_test.zig holds.

const std = @import("std");
const builtin = @import("builtin");
const t = std.testing;
const kit = @import("checkkit.zig");
const rs = @import("runspec.zig");

// Defect caught: a --lib-dir that is not kept (or kept in another order), an empty one accepted, or one refused for a command that starts programs.
test "parse: --lib-dir is repeatable, kept in order, empty is refused, and the three commands take it" {
    var c = try kit.Case.init();
    defer c.deinit();
    var none = kit.Streams.init(c.alloc());
    const bare = (try rs.parse(none.io(&c), "x", .run, &.{ "--", "/p" })).?;
    try t.expectEqual(@as(usize, 0), bare.lib_dirs.len);
    for ([_]rs.Kind{ .run, .marker, .expect }) |kind| {
        var s = kit.Streams.init(c.alloc());
        const spec = (try rs.parse(s.io(&c), "x", kind, &.{ "--lib-dir", "a", "--ld-library-path", "rt", "--lib-dir", "/b/c", "--", "/p" })).?;
        try t.expectEqual(@as(usize, 2), spec.lib_dirs.len);
        try t.expectEqualStrings("a", spec.lib_dirs[0]);
        try t.expectEqualStrings("/b/c", spec.lib_dirs[1]);
    }
    var s = kit.Streams.init(c.alloc());
    try t.expect((try rs.parse(s.io(&c), "x", .run, &.{ "--lib-dir", "", "--", "/p" })) == null);
    try t.expectEqualStrings("check x: --lib-dir is empty\n", s.err.written());
    var s2 = kit.Streams.init(c.alloc());
    try t.expect((try rs.parse(s2.io(&c), "x", .run, &.{ "--lib-dir" })) == null);
    try t.expectEqualStrings("check x: --lib-dir needs a value\n", s2.err.written());
}

// Defect caught: directories given and silently dropped because no library path was asked for (the test would run without them and fail only at its dlopen).
test "--lib-dir without --ld-library-path is refused before anything is started" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectFailure(try c.runTool(&.{ "run", "--lib-dir", "libs" }, &.{"true"}), 2, "--lib-dir needs --ld-library-path: the directories are added to the library path it sets");
    try kit.expectFailure(try c.runTool(&.{ "marker", "--out", "m", "--lib-dir", "libs" }, &.{"true"}), 2, "--lib-dir needs --ld-library-path: the directories are added to the library path it sets");
    try t.expect(!c.exists("m"));
}

// Defect caught: the directories before the compiler's lib (a library of the package shadowing the compiler runtime), replacing it, made absolute against the
// wrong directory, in another order, or a DYLD_* variable in a Linux program's environment. Runs the real program on the host: a Linux one (the macOS variables are the cases below).
test "--lib-dir on the host: the library path is the runtime's, then each directory absolute in the order given; no other variable moves" {
    // The program started is the one of the machine the test runs on: on a Mac it is a macOS program and sets the DYLD_* variables, which the cases below hold.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var c = try kit.Case.init();
    defer c.deinit();
    const here = try c.path(".");
    const want = try std.fmt.allocPrint(c.alloc(), "{s}/rt/lib:{s}/libs/one:/abs/two", .{ here, here });
    try t.expectEqualStrings(want, (try kit.valueOf(&c, &.{ "--ld-library-path", "rt/lib", "--lib-dir", "libs/one", "--lib-dir", "/abs/two" }, "LD_LIBRARY_PATH")).?);
    try t.expect((try kit.valueOf(&c, &.{ "--ld-library-path", "rt/lib", "--lib-dir", "libs/one" }, "DYLD_FALLBACK_LIBRARY_PATH")) == null);
    try t.expect((try kit.valueOf(&c, &.{ "--ld-library-path", "rt/lib", "--lib-dir", "libs/one" }, "DYLD_LIBRARY_PATH")) == null);
    // without the option the variable is the directory alone, as it was
    const alone = try std.fmt.allocPrint(c.alloc(), "{s}/rt/lib", .{here});
    try t.expectEqualStrings(alone, (try kit.valueOf(&c, &.{ "--ld-library-path", "rt/lib" }, "LD_LIBRARY_PATH")).?);
}

fn envOf(a: std.mem.Allocator, os: std.Target.Os.Tag, macos_dirs: ?[]const u8, libs: []const []const u8) !std.process.EnvMap {
    var env = std.process.EnvMap.init(a);
    errdefer env.deinit();
    try rs.setLibraryEnvWith(a, &env, os, "/rt/lib", macos_dirs, libs);
    return env;
}

// Defect caught: on macOS the directories put in DYLD_LIBRARY_PATH (which shadows the operating system's own libraries), put after dyld's defaults or after the
// consumer's directories, or the defaults dropped; on Linux a DYLD_* variable, or a change to the compiler's directory; and an environment that differs
// from setLibraryEnv's when no directory is given.
test "setLibraryEnvWith: macOS puts the directories first in the fallback path; Linux appends them to the library path; none is as setLibraryEnv" {
    const a = t.allocator;
    var mac = try envOf(a, .macos, null, &.{ "/n/one", "/n/two" });
    defer mac.deinit();
    try t.expectEqualStrings("/rt/lib", mac.get("DYLD_LIBRARY_PATH").?);
    try t.expectEqualStrings("/n/one:/n/two:/usr/local/lib:/usr/lib", mac.get("DYLD_FALLBACK_LIBRARY_PATH").?);
    try t.expect(mac.get("LD_LIBRARY_PATH") == null);
    try t.expectEqual(@as(u32, 2), mac.count());

    var both = try envOf(a, .macos, "/opt/x/lib:/opt/y/lib", &.{"/n/one"});
    defer both.deinit();
    try t.expectEqualStrings("/n/one:/opt/x/lib:/opt/y/lib:/usr/local/lib:/usr/lib", both.get("DYLD_FALLBACK_LIBRARY_PATH").?);

    var lin = try envOf(a, .linux, "/opt/x/lib", &.{ "/n/one", "/n/two" });
    defer lin.deinit();
    try t.expectEqualStrings("/rt/lib:/n/one:/n/two", lin.get("LD_LIBRARY_PATH").?);
    try t.expectEqual(@as(u32, 1), lin.count());

    for ([_]std.Target.Os.Tag{ .linux, .macos }) |os| {
        for ([_]?[]const u8{ null, "", "/opt/x/lib" }) |dirs| {
            var with = try envOf(a, os, dirs, &.{});
            defer with.deinit();
            var plain = std.process.EnvMap.init(a);
            defer plain.deinit();
            try rs.setLibraryEnv(a, &plain, os, "/rt/lib", dirs);
            try t.expectEqual(plain.count(), with.count());
            var it = plain.iterator();
            while (it.next()) |kv| try t.expectEqualStrings(kv.value_ptr.*, with.get(kv.key_ptr.*).?);
        }
    }
}

test "setLibraryEnvWith: an allocation that fails ends it with out of memory and leaks nothing, for each shape of the environment" {
    const Shape = struct { os: std.Target.Os.Tag, macos: ?[]const u8, libs: []const []const u8 };
    const shapes = [_]Shape{
        .{ .os = .macos, .macos = "/opt/x/lib", .libs = &.{"/n/one"} },
        .{ .os = .macos, .macos = null, .libs = &.{ "/n/one", "/n/two" } },
        .{ .os = .macos, .macos = "/opt/x/lib", .libs = &.{} },
        .{ .os = .macos, .macos = null, .libs = &.{} },
        .{ .os = .linux, .macos = null, .libs = &.{ "/n/one", "/n/two" } },
        .{ .os = .linux, .macos = null, .libs = &.{} },
    };
    for (shapes) |sh| {
        var i: usize = 0;
        var done = false;
        while (i < 60 and !done) : (i += 1) {
            var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = i });
            var env = std.process.EnvMap.init(t.allocator);
            defer env.deinit();
            rs.setLibraryEnvWith(failing.allocator(), &env, sh.os, "/rt/lib", sh.macos, sh.libs) catch |err| {
                try t.expectEqual(error.OutOfMemory, err);
                continue;
            };
            done = true;
        }
        try t.expect(done);
    }
}
