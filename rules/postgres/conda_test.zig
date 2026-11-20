//! Unit tests of conda.zig: what is read of the zip, the shape of a member path, the links that stay inside the tree, and the placeholder of
//! `info/paths.json`.

const std = @import("std");
const conda = @import("conda.zig");
const fx = @import("conda_fixture.zig");
const t = std.testing;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

test "payload and infoPayload pick the pkg- and the info- member of a zip of stored members, whatever the order" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const bytes = try fx.conda(a, &.{.{ .name = "bin/x", .body = "x" }}, &.{.{ .name = "info/index.json", .body = "{}" }});
    const pkg = try conda.payload(bytes);
    const inf = try conda.infoPayload(bytes);
    try t.expect(pkg.ptr != inf.ptr);
    // the other order
    const swapped = try std.mem.concat(a, u8, &.{ try fx.zipStored(a, "pkg-p-1.0-0.tar.zst", pkg), try fx.zipStored(a, "info-p-1.0-0.tar.zst", inf), try fx.zipStored(a, "metadata.json", "{}") });
    try t.expectEqualSlices(u8, pkg, try conda.payload(swapped));
    try t.expectEqualSlices(u8, inf, try conda.infoPayload(swapped));
}

test "a zip that is not a stored zip of one payload is refused by name: none, two, a data descriptor, a compressed member, a member past the end" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectError(error.NoPayload, conda.payload(""));
    try t.expectError(error.NoPayload, conda.payload(try fx.zipStored(a, "info-p.tar.zst", "x")));
    try t.expectError(error.NoPayload, conda.payload(try fx.zipStored(a, "pkg-p.tar", "x")));
    const two = try std.mem.concat(a, u8, &.{ try fx.zipStored(a, "pkg-a.tar.zst", "x"), try fx.zipStored(a, "pkg-b.tar.zst", "y") });
    try t.expectError(error.DuplicatePayload, conda.payload(two));
    try t.expectError(error.BadZip, conda.payload(try fx.zipEntry(a, "pkg-a.tar.zst", "x", .{ .flags = 8 })));
    try t.expectError(error.BadZip, conda.payload(try fx.zipEntry(a, "pkg-a.tar.zst", "x", .{ .method = 8 })));
    try t.expectError(error.BadZip, conda.payload(try fx.zipEntry(a, "pkg-a.tar.zst", "x", .{ .csize = 99 })));
    const whole = try fx.zipStored(a, "pkg-a.tar.zst", "xyz");
    try t.expectError(error.BadZip, conda.payload(try fx.zipEntry(a, "pkg-a.tar.zst", "x", .{ .name_len = 4000 })));
    try t.expectEqualStrings("xyz", try conda.payload(whole));
}

test "a zip64 member gives its size in the extra field, and a malformed extra field is refused" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // id 0x0001, 8 bytes: the compressed size (the uncompressed size is 32 bits)
    const sized = [_]u8{ 1, 0, 8, 0, 3, 0, 0, 0, 0, 0, 0, 0 };
    try t.expectEqualStrings("xyz", try conda.payload(try fx.zipEntry(a, "pkg-a.tar.zst", "xyz", .{ .csize = 0xffffffff, .extra = &sized })));
    // both sizes 64 bit: 16 bytes, the compressed one second
    const both = [_]u8{ 1, 0, 16, 0, 9, 9, 9, 9, 9, 9, 9, 9, 3, 0, 0, 0, 0, 0, 0, 0 };
    try t.expectEqualStrings("xyz", try conda.payload(try fx.zipEntry(a, "pkg-a.tar.zst", "xyz", .{ .csize = 0xffffffff, .usize32 = 0xffffffff, .extra = &both })));
    // another field first, then the zip64 one
    const second = [_]u8{ 7, 0, 2, 0, 0, 0 } ++ sized;
    try t.expectEqualStrings("xyz", try conda.payload(try fx.zipEntry(a, "pkg-a.tar.zst", "xyz", .{ .csize = 0xffffffff, .extra = &second })));
    // no zip64 field, one that is too short, one that runs past the extra field
    try t.expectError(error.BadZip, conda.payload(try fx.zipEntry(a, "pkg-a.tar.zst", "xyz", .{ .csize = 0xffffffff })));
    try t.expectError(error.BadZip, conda.payload(try fx.zipEntry(a, "pkg-a.tar.zst", "xyz", .{ .csize = 0xffffffff, .extra = &.{ 1, 0, 4, 0, 1, 2, 3, 4 } })));
    try t.expectError(error.BadZip, conda.payload(try fx.zipEntry(a, "pkg-a.tar.zst", "xyz", .{ .csize = 0xffffffff, .extra = &.{ 1, 0, 40, 0, 1, 2, 3, 4 } })));
    try t.expectError(error.BadZip, conda.payload(try fx.zipEntry(a, "pkg-a.tar.zst", "xyz", .{ .csize = 0xffffffff, .extra = &.{ 7, 0, 0, 0 } })));
}

test "cleanPath makes a relative path of plain components and refuses an absolute path and a .. component" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("bin/postgres", try conda.cleanPath(a, "bin/postgres"));
    try t.expectEqualStrings("bin/postgres", try conda.cleanPath(a, "./bin//postgres/"));
    try t.expectEqualStrings("", try conda.cleanPath(a, "./"));
    try t.expectEqualStrings("", try conda.cleanPath(a, ""));
    try t.expectEqualStrings("a/b..c/.d", try conda.cleanPath(a, "a/b..c/.d"));
    try t.expectError(error.BadPath, conda.cleanPath(a, "/etc/passwd"));
    try t.expectError(error.BadPath, conda.cleanPath(a, "a/../b"));
    try t.expectError(error.BadPath, conda.cleanPath(a, ".."));
    var fail = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    try t.expectError(error.OutOfMemory, conda.cleanPath(fail.allocator(), "a/b"));
}

test "dropped names the directories and files a server never reads, and only those" {
    for ([_][]const u8{ "info", "info/licenses/COPYING", "include", "include/pg.h", "share/doc", "share/doc/x/y", "share/man/man1/psql.1", "share/info/dir", "share/locale/de/x.mo", "lib/pkgconfig", "lib/pkgconfig/libpq.pc", "lib/cmake/x/y.cmake", "lib/pgxs/src/Makefile.global", "lib/libpq.a", "libx.a" }) |p| {
        try t.expect(conda.dropped(p));
    }
    for ([_][]const u8{ "bin/postgres", "infos/x", "information", "includes/x", "include.txt", "share/documentation", "share/postgres.bki", "share/mandb", "lib/pkgconfigs", "lib/libpq.so.5", "lib/liba.a.so", "lib/pgxsx", "share" }) |p| {
        try t.expect(!conda.dropped(p));
    }
}

test "linkEscapes holds a link to a target inside the tree and refuses an absolute target or one that climbs above the root" {
    try t.expect(!conda.linkEscapes("lib/libpq.so.5", "libpq.so.5.17"));
    try t.expect(!conda.linkEscapes("lib/libpq.so", "../lib/libpq.so.5"));
    try t.expect(!conda.linkEscapes("lib/x/y", "../../bin/./postgres"));
    try t.expect(!conda.linkEscapes("lib64", "lib"));
    try t.expect(!conda.linkEscapes("a/b/c", "..//d"));
    try t.expect(conda.linkEscapes("lib/x", "/usr/lib/x"));
    try t.expect(conda.linkEscapes("lib/x", "../../x"));
    try t.expect(conda.linkEscapes("x", ".."));
    try t.expect(conda.linkEscapes("lib/x", "a/../../../y"));
}

fn refusal(a: std.mem.Allocator, json: []const u8) ![]const u8 {
    var why: []const u8 = "";
    try t.expectError(error.Refused, conda.placeholder(a, json, &why));
    return why;
}

test "placeholder reads the one placeholder of bin/postgres and bin/initdb, and says what is wrong otherwise" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    try t.expectEqualStrings("/opt/cbuild/xyz", try conda.placeholder(a, try fx.pathsJson(a, "/opt/cbuild/xyz"), &why));
    try t.expectEqualStrings("is not JSON", try refusal(a, "{"));
    try t.expectEqualStrings("has no paths list", try refusal(a, "[]"));
    try t.expectEqualStrings("has no paths list", try refusal(a, "{}"));
    try t.expectEqualStrings("has no paths list", try refusal(a, "{\"paths\": 3}"));
    try t.expectEqualStrings("does not list bin/postgres", try refusal(a, "{\"paths\": []}"));
    // entries that are not objects, have no _path, or a _path that is not text, or another one, are passed over
    const noise = "{\"paths\": [3, {}, {\"_path\": 4}, {\"_path\": \"bin/other\"}";
    try t.expectEqualStrings("does not list bin/postgres", try refusal(a, noise ++ "]}"));
    try t.expectEqualStrings("does not list bin/initdb", try refusal(a, noise ++ ", {\"_path\": \"bin/postgres\", \"file_mode\": \"binary\", \"prefix_placeholder\": \"/p\"}]}"));
    try t.expectEqualStrings("lists bin/postgres with a file_mode that is not \"binary\"", try refusal(a, "{\"paths\": [{\"_path\": \"bin/postgres\", \"file_mode\": \"text\", \"prefix_placeholder\": \"/p\"}]}"));
    try t.expectEqualStrings("lists bin/postgres with a file_mode that is not \"binary\"", try refusal(a, "{\"paths\": [{\"_path\": \"bin/postgres\", \"prefix_placeholder\": \"/p\"}]}"));
    try t.expectEqualStrings("lists bin/postgres without a prefix_placeholder", try refusal(a, "{\"paths\": [{\"_path\": \"bin/postgres\", \"file_mode\": \"binary\"}]}"));
    try t.expectEqualStrings("lists bin/postgres without a prefix_placeholder", try refusal(a, "{\"paths\": [{\"_path\": \"bin/postgres\", \"file_mode\": \"binary\", \"prefix_placeholder\": \"\"}]}"));
    try t.expectEqualStrings("gives bin/postgres and bin/initdb different prefix placeholders", try refusal(a, "{\"paths\": [{\"_path\": \"bin/postgres\", \"file_mode\": \"binary\", \"prefix_placeholder\": \"/p\"}, {\"_path\": \"bin/initdb\", \"file_mode\": \"binary\", \"prefix_placeholder\": \"/q\"}]}"));
}

test "placeholder under allocation failures is OutOfMemory, never a refusal" {
    const json = try fx.pathsJson(t.allocator, "/opt/cbuild/xyz");
    defer t.allocator.free(json);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var ar = arena();
        defer ar.deinit();
        var fail = t.FailingAllocator.init(ar.allocator(), .{ .fail_index = i });
        var why: []const u8 = "";
        if (conda.placeholder(fail.allocator(), json, &why)) |ph| {
            try t.expectEqualStrings("/opt/cbuild/xyz", ph);
            try t.expect(!fail.has_induced_failure);
            break;
        } else |e| try t.expectEqual(error.OutOfMemory, e);
    }
    // the refusals that build their text
    i = 0;
    while (i < 200) : (i += 1) {
        var ar = arena();
        defer ar.deinit();
        var fail = t.FailingAllocator.init(ar.allocator(), .{ .fail_index = i });
        var why: []const u8 = "";
        if (conda.placeholder(fail.allocator(), "{\"paths\": []}", &why)) |_| {
            return error.TestUnexpectedResult;
        } else |e| {
            if (!fail.has_induced_failure) {
                try t.expectEqual(error.Refused, e);
                break;
            }
            try t.expectEqual(error.OutOfMemory, e);
        }
    }
}

/// The allocation failing at each index in turn: every failure is OutOfMemory, never a refusal or a wrong answer; the sweep ends at the first run no
/// failure reached, which ends with `end` (null: an answer).
fn sweep(comptime call: anytype, end: ?anyerror) !void {
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var ar = arena();
        defer ar.deinit();
        var fail = t.FailingAllocator.init(ar.allocator(), .{ .fail_index = i });
        const result = call(fail.allocator());
        if (!fail.has_induced_failure) {
            if (end) |want| return t.expectError(want, result);
            return result;
        }
        try t.expectError(error.OutOfMemory, result);
    }
    return error.SweepDidNotEnd;
}

fn refusedWith(comptime json: []const u8) fn (std.mem.Allocator) anyerror!void {
    return struct {
        fn call(a: std.mem.Allocator) anyerror!void {
            var why: []const u8 = "";
            _ = try conda.placeholder(a, json, &why);
        }
    }.call;
}

test "cleanPath and the refusals of placeholder that build their text fail with OutOfMemory at every allocation, never with another error" {
    // a first component of every length up to past the capacity the list grows to, so the `/` after it is the allocation that fails once
    var name: [140]u8 = undefined;
    @memset(&name, 'a');
    for (1..131) |n| {
        name[n] = '/';
        name[n + 1] = 'b';
        var i: usize = 0;
        while (true) : (i += 1) {
            var ar = arena();
            defer ar.deinit();
            var fail = t.FailingAllocator.init(ar.allocator(), .{ .fail_index = i });
            if (conda.cleanPath(fail.allocator(), name[0 .. n + 2])) |clean| {
                try t.expect(!fail.has_induced_failure);
                try t.expectEqual(n + 2, clean.len);
                break;
            } else |e| try t.expectEqual(error.OutOfMemory, e);
        }
        name[n] = 'a';
        name[n + 1] = 'a';
    }
    const mode = "{\"paths\": [{\"_path\": \"bin/postgres\", \"file_mode\": \"text\", \"prefix_placeholder\": \"/p\"}]}";
    const none = "{\"paths\": [{\"_path\": \"bin/postgres\", \"file_mode\": \"binary\"}]}";
    try sweep(refusedWith(mode), error.Refused);
    try sweep(refusedWith(none), error.Refused);
}
