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

pub const Error = error{ NoGraph, Differs, EmptyOutput };

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
    // mopm printed nothing: there is no graph to be the same as, whatever the table holds (a blank block would pass the newline allowance).
    if (mopm_out.len == 0) return error.EmptyOutput;
    const graph = try graphOf(table);
    const at = firstDifference(graph, mopm_out) orelse return;
    const t = lineAt(graph, at);
    const m = lineAt(mopm_out, at);
    why.* = try std.fmt.allocPrint(a, "the committed graph is not what mopm says: first difference at line {d}\n  table: {s}\n  mopm:  {s}\nrun `buildrules mojo sync` and commit the result", .{ t.no, t.text, m.text });
    return error.Differs;
}

const usage = "usage: table_check <mopm> <project-dir> <mojo-version> <buildrules.mojo.lock.bzl> <out>";

/// What running mopm gave: how it ended, and what it printed.
pub const Ran = struct { exited: bool, code: u8 = 0, stdout: []const u8 = "", stderr: []const u8 = "" };

/// Runs `<mopm> plan --unit-graph --locked --mojo <mojo>` in `project`. A test passes its own.
pub const Spawn = *const fn (a: std.mem.Allocator, mopm: []const u8, project: []const u8, mojo: []const u8) anyerror!Ran;

pub fn spawnMopm(a: std.mem.Allocator, mopm: []const u8, project: []const u8, mojo: []const u8) anyerror!Ran {
    const r = try std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ mopm, "plan", "--unit-graph", "--locked", "--mojo", mojo },
        .cwd = project,
        .max_output_bytes = 64 << 20,
    });
    return switch (r.term) {
        .Exited => |code| .{ .exited = true, .code = code, .stdout = r.stdout, .stderr = r.stderr },
        else => .{ .exited = false, .stdout = r.stdout, .stderr = r.stderr },
    };
}

/// The whole program: `args` are the five arguments after the program's name. Every refusal is `error.Refused` with the words in `msg.*`.
pub fn run(a: std.mem.Allocator, cwd: std.fs.Dir, args: []const []const u8, spawn: Spawn, msg: *[]const u8) !void {
    if (args.len != 5) {
        msg.* = usage;
        return error.Refused;
    }
    const mopm = try cwd.realpathAlloc(a, args[0]);
    const project = try cwd.realpathAlloc(a, args[1]);
    const table = cwd.readFileAlloc(a, args[3], 64 << 20) catch |e| {
        msg.* = try std.fmt.allocPrint(a, "cannot read {s}: {s}", .{ args[3], @errorName(e) });
        return error.Refused;
    };
    const r = spawn(a, mopm, project, args[2]) catch |e| {
        msg.* = try std.fmt.allocPrint(a, "cannot run {s}: {s}", .{ mopm, @errorName(e) });
        return error.Refused;
    };
    if (!r.exited or r.code != 0) {
        msg.* = try std.fmt.allocPrint(a, "`mopm plan --unit-graph --locked --mojo {s}` did not succeed (exit {d}): {s}", .{ args[2], r.code, r.stderr });
        return error.Refused;
    }
    var why: []const u8 = "";
    check(a, table, r.stdout, &why) catch |e| switch (e) {
        error.NoGraph => {
            msg.* = try std.fmt.allocPrint(a, "{s} has no GRAPH_JSON = r'''...''' block", .{args[3]});
            return error.Refused;
        },
        error.EmptyOutput => {
            msg.* = "`mopm plan --unit-graph --locked` printed nothing";
            return error.Refused;
        },
        error.Differs => {
            msg.* = try std.fmt.allocPrint(a, "{s}: {s}", .{ args[3], why });
            return error.Refused;
        },
        error.OutOfMemory => return e,
    };
    // A validation result is JSON (Buck2 rejects any other content).
    try cwd.writeFile(.{ .sub_path = args[4], .data = "{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"the committed graph is what the pinned mopm says\"}}\n" });
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    var msg: []const u8 = "";
    run(a, std.fs.cwd(), args[1..], spawnMopm, &msg) catch |e| {
        if (e != error.Refused) return e;
        std.debug.print("table_check: {s}\n", .{msg});
        std.process.exit(1);
    };
}
