//! table_check: is the committed table what the pinned mopm says now?
//!
//! usage: table_check <mopm> <project-dir> <mojo-version> <buildrules.mojo.lock.bzl> <out>
//!
//! `buildrules mojo sync` commits mopm's `plan --unit-graph --locked` output, verbatim, between `GRAPH_JSON = r'''` and
//! `'''` in buildrules.mojo.lock.bzl. This is the build's copy of that comparison (the `:table` validation of a package,
//! rules/mojo/check.bzl): it runs the same command, offline, in `<project-dir>` (the package and its workspace members laid out as
//! they are in the repository) and writes `<out>` (a JSON validation result) only if the committed text is byte for byte mopm's
//! output. Everything the rules read from the graph (the keys, the order of units, natives and dependencies, the `needs` of a
//! native, the sha256 of every source and archive) is in that text, so a table edited by hand, or left behind by a change to
//! a source, a lock or the pinned mopm, is red. The one difference from the committed text that is allowed is the newline
//! `sync` adds when mopm's output does not end with one.

const std = @import("std");

const graph_open = "GRAPH_JSON = r'''";
const graph_close = "'''\n";

pub const Error = error{ NoGraph, Differs };

/// The text of the graph in a table: what `sync` wrote between the markers.
pub fn graphOf(table: []const u8) error{NoGraph}![]const u8 {
    const gi = std.mem.indexOf(u8, table, graph_open) orelse return error.NoGraph;
    const body = gi + graph_open.len;
    const ge = std.mem.indexOfPos(u8, table, body, graph_close) orelse return error.NoGraph;
    return table[body..ge];
}

/// The offset of the first byte at which the table's graph and mopm's output differ, or null when they are the same text.
pub fn firstDifference(table_graph: []const u8, mopm_out: []const u8) ?usize {
    const added = mopm_out.len == 0 or mopm_out[mopm_out.len - 1] != '\n';
    const n = @min(table_graph.len, mopm_out.len);
    var i: usize = 0;
    while (i < n) : (i += 1) if (table_graph[i] != mopm_out[i]) return i;
    if (table_graph.len != mopm_out.len + @intFromBool(added)) return n;
    if (added and table_graph[n] != '\n') return n;
    return null;
}

/// 1-based line and the line's text at `offset` of `text`.
pub fn lineAt(text: []const u8, offset: usize) struct { no: usize, text: []const u8 } {
    const at = @min(offset, text.len);
    const start = if (std.mem.lastIndexOfScalar(u8, text[0..at], '\n')) |p| p + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
    return .{ .no = std.mem.count(u8, text[0..start], "\n") + 1, .text = text[start..end] };
}

/// The comparison, with the reason in the error message when the two differ.
pub fn check(a: std.mem.Allocator, table: []const u8, mopm_out: []const u8, why: *[]const u8) (Error || std.mem.Allocator.Error)!void {
    const graph = try graphOf(table);
    const at = firstDifference(graph, mopm_out) orelse return;
    const t = lineAt(graph, at);
    const m = lineAt(mopm_out, at);
    why.* = try std.fmt.allocPrint(a, "the committed graph is not what mopm says: first difference at line {d}\n  table: {s}\n  mopm:  {s}\nrun `buildrules mojo sync` and commit the result", .{ t.no, t.text, m.text });
    return error.Differs;
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("table_check: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len != 6) die("usage: table_check <mopm> <project-dir> <mojo-version> <buildrules.mojo.lock.bzl> <out>", .{});
    const cwd = std.fs.cwd();
    const mopm = try cwd.realpathAlloc(a, args[1]);
    const project = try cwd.realpathAlloc(a, args[2]);
    const table = cwd.readFileAlloc(a, args[4], 64 << 20) catch |e| die("cannot read {s}: {s}", .{ args[4], @errorName(e) });
    const r = std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ mopm, "plan", "--unit-graph", "--locked", "--mojo", args[3] },
        .cwd = project,
        .max_output_bytes = 64 << 20,
    }) catch |e| die("cannot run {s}: {s}", .{ mopm, @errorName(e) });
    switch (r.term) {
        .Exited => |code| if (code != 0) die("`mopm plan --unit-graph --locked --mojo {s}` exited {d}: {s}", .{ args[3], code, r.stderr }),
        else => die("mopm did not exit: {s}", .{r.stderr}),
    }
    var why: []const u8 = "";
    check(a, table, r.stdout, &why) catch |e| switch (e) {
        error.NoGraph => die("{s} has no GRAPH_JSON = r'''...''' block", .{args[4]}),
        error.Differs => die("{s}: {s}", .{ args[4], why }),
        error.OutOfMemory => return e,
    };
    // A validation result is JSON (Buck2 rejects any other content).
    try cwd.writeFile(.{ .sub_path = args[5], .data = "{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"the committed graph is what the pinned mopm says\"}}\n" });
}
