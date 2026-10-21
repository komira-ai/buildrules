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
