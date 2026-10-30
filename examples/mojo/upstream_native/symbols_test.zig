//! What the renaming did to SQLite (BUCK, `native_build` of `mojo_package`): the three files below are the real outputs of the example's targets, under
//! BUILDRULES_TEST_WORK.
//!
//!   unprefixed.txt  the symbols `:native_sqlite_unprefixed` defines (SQLite's own names), as `archive_check` lists them
//!   header.h        `:native_sqlite_prefix`, the header that renames each of them
//!   renamed.txt     the symbols `:native_sqlite` defines, built with that header
//!
//! The cases hold the three to each other and to the contract of the prefix: nothing the library defines is outside `upsql_sqlite3_`, SQLite's public names are
//! among the renamed ones and not among the defined ones, and the header renames exactly the names the first build defined, each by the `strip` rule
//! (`sqlite3_X` to `upsql_sqlite3_X`, any other `X` to `upsql_sqlite3__X`).

const std = @import("std");
const t = std.testing;

const prefix = "upsql_sqlite3_";
const strip = "sqlite3_";

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 22);
}

fn lines(a: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (l.len != 0) try out.append(a, l);
    }
    return out.toOwnedSlice(a);
}

fn has(list: []const []const u8, name: []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, l, name)) return true;
    return false;
}

/// The name `sqlite3_X` is given in the `strip` style.
fn renamed(a: std.mem.Allocator, name: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, name, strip)) return std.fmt.allocPrint(a, "{s}{s}", .{ prefix, name[strip.len..] });
    return std.fmt.allocPrint(a, "{s}_{s}", .{ prefix, name });
}

test "the library defines SQLite's public names under the prefix, and none of them without it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const defined = try lines(a, try work(a, "renamed.txt"));
    try t.expect(defined.len >= 200);
    for (defined) |name| {
        if (!std.mem.startsWith(u8, name, prefix)) {
            std.debug.print("defined without the prefix: {s}\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "open_v2", "prepare_v2", "step", "finalize", "close_v2", "libversion_number", "threadsafe", "initialize" }) |api| {
        const full = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, api });
        try t.expect(has(defined, full));
        try t.expect(!has(defined, try std.fmt.allocPrint(a, "{s}{s}", .{ strip, api })));
    }
}

test "the first build has SQLite's own names, so the test above is not vacuous" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const own = try lines(a, try work(a, "unprefixed.txt"));
    try t.expect(has(own, "sqlite3_open_v2"));
    try t.expect(has(own, "sqlite3_libversion_number"));
    for (own) |name| try t.expect(!std.mem.startsWith(u8, name, prefix));
}

test "the header renames exactly the names the first build defined, and the second build defines exactly those" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const own = try lines(a, try work(a, "unprefixed.txt"));
    const defined = try lines(a, try work(a, "renamed.txt"));
    const header = try work(a, "header.h");
    try t.expectEqual(own.len, defined.len);
    for (own) |name| {
        const to = try renamed(a, name);
        const rule = try std.fmt.allocPrint(a, "#define {s} {s}\n", .{ name, to });
        if (std.mem.indexOf(u8, header, rule) == null) {
            std.debug.print("the header has no line: {s}", .{rule});
            return error.TestUnexpectedResult;
        }
        try t.expect(has(defined, to));
    }
    // One #define for each name and nothing else but the guard and the comment.
    var defines: usize = 0;
    var it = std.mem.splitScalar(u8, header, '\n');
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, "#define ") and !std.mem.startsWith(u8, l, "#define BUILDRULES_PREFIX_")) defines += 1;
    }
    try t.expectEqual(own.len, defines);
}
