//! Unit tests of table_check.zig: the comparison of a committed table's graph with mopm's output. (The run of mopm itself is the farm build of
//! every package's `:table`; the planted differences of the examples' tables are in the PR that added it.)
const std = @import("std");
const T = @import("table_check.zig");
const t = std.testing;

const head = "# Generated\nSCHEMA = 1\nMANIFEST_SHA256 = {\n}\n";
const tail = "GRAPH = json.decode(GRAPH_JSON)\n";
const graph = "{\n  \"unit_graph\": 1,\n  \"units\": [\n    {\"id\": \"a\", \"natives\": [\"x\", \"y\"]}\n  ]\n}\n";

fn table(a: std.mem.Allocator, g: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}GRAPH_JSON = r'''{s}'''\n{s}", .{ head, g, tail });
}

fn expectDiffers(a: std.mem.Allocator, g: []const u8, m: []const u8, line: []const u8) !void {
    var why: []const u8 = "";
    try t.expectError(error.Differs, T.check(a, try table(a, g), m, &why));
    try t.expect(std.mem.indexOf(u8, why, line) != null);
}

test "the table's graph is found between the markers, and a table without one is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(graph, try T.graphOf(try table(a, graph)));
    try t.expectError(error.NoGraph, T.graphOf("SCHEMA = 1\n"));
    try t.expectError(error.NoGraph, T.graphOf("GRAPH_JSON = r'''{}"));
    var why: []const u8 = "";
    try t.expectError(error.NoGraph, T.check(a, "nothing", graph, &why));
}

test "the same text is the same, with or without the newline sync adds" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    try T.check(a, try table(a, graph), graph, &why);
    // mopm's output without a final newline: sync wrote one
    try T.check(a, try table(a, graph), graph[0 .. graph.len - 1], &why);
}

test "mopm printing nothing is refused, even against a blank block" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    try t.expectError(error.EmptyOutput, T.check(a, try table(a, "\n"), "", &why));
    try t.expectError(error.EmptyOutput, T.check(a, try table(a, graph), "", &why));
    // and not for a table that has no block either: nothing to compare is the first thing said
    try t.expectError(error.EmptyOutput, T.check(a, "nothing", "", &why));
}

test "any other difference is one, and names the line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // a byte changed (a key, a sha256), two natives swapped, a field dropped, a line missing, text added, the extra newline missing
    try expectDiffers(a, graph, "{\n  \"unit_graph\": 2,\n  \"units\": [\n    {\"id\": \"a\", \"natives\": [\"x\", \"y\"]}\n  ]\n}\n", "line 2");
    try expectDiffers(a, graph, "{\n  \"unit_graph\": 1,\n  \"units\": [\n    {\"id\": \"a\", \"natives\": [\"y\", \"x\"]}\n  ]\n}\n", "line 4");
    try expectDiffers(a, graph, "{\n  \"unit_graph\": 1,\n  \"units\": [\n    {\"id\": \"a\"}\n  ]\n}\n", "line 4");
    try expectDiffers(a, graph, graph[0 .. graph.len - 2], "line 6");
    try expectDiffers(a, graph, graph ++ "\n", "line 7");
    try expectDiffers(a, graph, graph ++ "x", "line 7");
    // the table lacks the newline sync adds after output that has none
    var why: []const u8 = "";
    try t.expectError(error.Differs, T.check(a, try std.fmt.allocPrint(a, "{s}GRAPH_JSON = r'''{s}'''\n{s}", .{ head, graph[0 .. graph.len - 1], tail }), graph[0 .. graph.len - 1], &why));
    // a table that is empty where mopm said something
    try expectDiffers(a, "\n", graph, "line 1");
}

test "a failing allocator is an error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const text = try table(arena.allocator(), graph);
    var fa = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    var why: []const u8 = "";
    try t.expectError(error.OutOfMemory, T.check(fa.allocator(), text, "{}\n", &why));
}

fn okSpawn(_: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) anyerror!T.Ran {
    return .{ .exited = true, .stdout = graph };
}
fn emptySpawn(_: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) anyerror!T.Ran {
    return .{ .exited = true };
}
fn otherSpawn(_: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) anyerror!T.Ran {
    return .{ .exited = true, .stdout = "{}\n" };
}
fn failSpawn(_: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) anyerror!T.Ran {
    return .{ .exited = true, .code = 4, .stderr = "no graph from this lock" };
}
fn killedSpawn(_: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) anyerror!T.Ran {
    return .{ .exited = false, .stderr = "signal" };
}
fn missingSpawn(_: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8) anyerror!T.Ran {
    return error.FileNotFound;
}

/// The program in a directory that holds a table, a stand-in mopm and a workspace; its refusal, or null when it wrote the result.
fn drive(a: std.mem.Allocator, dir: std.fs.Dir, table_text: []const u8, spawn: T.Spawn, args_len: usize) !?[]const u8 {
    try dir.writeFile(.{ .sub_path = "table.bzl", .data = table_text });
    try dir.writeFile(.{ .sub_path = "mopm", .data = "" });
    try dir.makePath("ws");
    const all = [_][]const u8{ "mopm", "ws", "1.0.0", "table.bzl", "out" };
    var msg: []const u8 = "";
    T.run(a, dir, all[0..args_len], spawn, &msg) catch |e| {
        try t.expectEqual(error.Refused, e);
        return msg;
    };
    return null;
}

test "the program: the same graph writes the result; every refusal is a message and writes nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const good = try table(a, graph);
    try t.expect((try drive(a, tmp.dir, good, okSpawn, 5)) == null);
    const out = try tmp.dir.readFileAlloc(a, "out", 1 << 16);
    try t.expect(std.mem.indexOf(u8, out, "\"status\": \"success\"") != null);
    try tmp.dir.deleteFile("out");

    // mopm printing nothing is reported through the program, against a table with a blank block as well as a full one
    const blank = try table(a, "\n");
    for ([_][]const u8{ good, blank }) |tab| {
        const m = (try drive(a, tmp.dir, tab, emptySpawn, 5)).?;
        try t.expectEqualStrings("`mopm plan --unit-graph --locked` printed nothing", m);
    }
    try t.expect((try drive(a, tmp.dir, good, otherSpawn, 5)).?.len > 0);
    try t.expect(std.mem.indexOf(u8, (try drive(a, tmp.dir, good, otherSpawn, 5)).?, "first difference at line 1") != null);
    try t.expect(std.mem.indexOf(u8, (try drive(a, tmp.dir, "no block", okSpawn, 5)).?, "has no GRAPH_JSON") != null);
    try t.expect(std.mem.indexOf(u8, (try drive(a, tmp.dir, good, failSpawn, 5)).?, "exit 4): no graph from this lock") != null);
    try t.expect(std.mem.indexOf(u8, (try drive(a, tmp.dir, good, killedSpawn, 5)).?, "did not succeed") != null);
    try t.expect(std.mem.indexOf(u8, (try drive(a, tmp.dir, good, missingSpawn, 5)).?, "FileNotFound") != null);
    try t.expectEqualStrings("usage: table_check <mopm> <project-dir> <mojo-version> <buildrules.mojo.lock.bzl> <out>", (try drive(a, tmp.dir, good, okSpawn, 4)).?);
    try t.expect(absent(tmp.dir, "out"));

    var msg: []const u8 = "";
    try t.expectError(error.Refused, T.run(a, tmp.dir, &.{ "mopm", "ws", "1.0.0", "no_such_table.bzl", "out" }, okSpawn, &msg));
    try t.expect(std.mem.indexOf(u8, msg, "cannot read no_such_table.bzl") != null);
    try t.expect(absent(tmp.dir, "out"));
}

fn absent(dir: std.fs.Dir, path: []const u8) bool {
    dir.access(path, .{}) catch return true;
    return false;
}

test "the program: every allocation failing in turn is an error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const good = try table(a, graph);
    try tmp.dir.writeFile(.{ .sub_path = "table.bzl", .data = good });
    try tmp.dir.writeFile(.{ .sub_path = "mopm", .data = "" });
    try tmp.dir.makePath("ws");
    const args = [_][]const u8{ "mopm", "ws", "1.0.0", "table.bzl", "out" };
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var inner = std.heap.ArenaAllocator.init(t.allocator);
        defer inner.deinit();
        var fa = t.FailingAllocator.init(inner.allocator(), .{ .fail_index = i });
        var msg: []const u8 = "";
        if (T.run(fa.allocator(), tmp.dir, &args, okSpawn, &msg)) |_| {
            try t.expect(!fa.has_induced_failure);
            return;
        } else |e| try t.expectEqual(error.OutOfMemory, e);
    }
    return error.SweepDidNotEnd;
}

/// `run` with every allocation failing in turn, until it fails for `want` with none having failed: the arm that words each refusal is then also
/// reached with its own allocation failing, which is `OutOfMemory` and nothing else.
fn sweep(dir: std.fs.Dir, spawn: T.Spawn, table_name: []const u8, out_name: []const u8, want: anyerror) !void {
    const args = [_][]const u8{ "mopm", "ws", "1.0.0", table_name, out_name };
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var inner = std.heap.ArenaAllocator.init(t.allocator);
        defer inner.deinit();
        var fa = t.FailingAllocator.init(inner.allocator(), .{ .fail_index = i });
        var msg: []const u8 = "";
        if (T.run(fa.allocator(), dir, &args, spawn, &msg)) |_| {
            return error.ShouldHaveFailed;
        } else |e| {
            if (!fa.has_induced_failure) {
                try t.expectEqual(want, e);
                return;
            }
            try t.expectEqual(error.OutOfMemory, e);
        }
    }
    return error.SweepDidNotEnd;
}

test "every refusal of the program is still one when the allocation that words it fails, and a result that cannot be written is an error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "good.bzl", .data = try table(a, graph) });
    try tmp.dir.writeFile(.{ .sub_path = "none.bzl", .data = "no block" });
    try tmp.dir.writeFile(.{ .sub_path = "mopm", .data = "" });
    try tmp.dir.makePath("ws");
    try tmp.dir.makePath("isdir");
    try sweep(tmp.dir, missingSpawn, "good.bzl", "out", error.Refused);
    try sweep(tmp.dir, failSpawn, "good.bzl", "out", error.Refused);
    try sweep(tmp.dir, okSpawn, "none.bzl", "out", error.Refused);
    try sweep(tmp.dir, otherSpawn, "good.bzl", "out", error.Refused);
    try sweep(tmp.dir, okSpawn, "no_such.bzl", "out", error.Refused);
    try sweep(tmp.dir, okSpawn, "good.bzl", "isdir", error.IsDir);
}
