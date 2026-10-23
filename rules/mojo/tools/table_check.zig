//! table_check: is the committed table what the pinned mopm says now?
//!
//! usage: table_check [--workspace-root] <mopm> <workspace> <package-dir> <mojo-version> <buildrules.mojo.lock.bzl> <out>
//!
//! `buildrules mojo sync` commits mopm's `plan --unit-graph --locked` output between `GRAPH_JSON = r'''` and `'''` in
//! buildrules.mojo.lock.bzl, with the path dependencies reduced to their identity (graph_norm.zig). This is the build's copy of that
//! comparison (the `:table` validation of a package, rules/mojo/check.bzl): it runs the same command, offline, in `<workspace>/<package-dir>`
//! (`<workspace>` holds the package and every path dependency at the paths the repository has them; `<package-dir>` is the package's
//! directory below it, `.` for the root) and writes `<out>` (a JSON validation result) only if the committed text is byte for byte mopm's
//! output in the same form. With `--workspace-root` mopm is told the workspace is `<workspace>` (a mopm that has the flag; the graph's paths
//! are then relative to it), else the paths are relative to the package. Everything the rules read from the graph (the order of units, natives
//! and dependencies, the `needs` of a native, the sha256 of every source and archive of the package itself) is in that text, so a table edited
//! by hand, or left behind by a change to a source, a lock or the pinned mopm, is red. The one difference from the committed text that is
//! allowed is the newline `sync` adds when mopm's output does not end with one.

const std = @import("std");
const norm = @import("mojo_graph_norm");

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

const usage = "usage: table_check [--workspace-root] <mopm> <workspace> <package-dir> <mojo-version> <buildrules.mojo.lock.bzl> <out>";

/// What running mopm gave: how it ended, and what it printed.
pub const Ran = struct { exited: bool, code: u8 = 0, stdout: []const u8 = "", stderr: []const u8 = "" };

/// Runs `<mopm> plan --unit-graph --locked --mojo <mojo>` in `project`, followed by `--workspace-root <root>` when `root` is given. A test
/// passes its own.
pub const Spawn = *const fn (a: std.mem.Allocator, mopm: []const u8, project: []const u8, mojo: []const u8, root: ?[]const u8) anyerror!Ran;

pub fn spawnMopm(a: std.mem.Allocator, mopm: []const u8, project: []const u8, mojo: []const u8, root: ?[]const u8) anyerror!Ran {
    const base = [_][]const u8{ mopm, "plan", "--unit-graph", "--locked", "--mojo", mojo };
    const argv = if (root) |r| try std.mem.concat(a, []const u8, &.{ &base, &.{ "--workspace-root", r } }) else try a.dupe([]const u8, &base);
    const r = try std.process.Child.run(.{
        .allocator = a,
        .argv = argv,
        .cwd = project,
        .max_output_bytes = 64 << 20,
    });
    return switch (r.term) {
        .Exited => |code| .{ .exited = true, .code = code, .stdout = r.stdout, .stderr = r.stderr },
        else => .{ .exited = false, .stdout = r.stdout, .stderr = r.stderr },
    };
}

/// The whole program: `args` are the arguments after the program's name. Every refusal is `error.Refused` with the words in `msg.*`.
pub fn run(a: std.mem.Allocator, cwd: std.fs.Dir, all_args: []const []const u8, spawn: Spawn, msg: *[]const u8) !void {
    const with_root = all_args.len > 0 and std.mem.eql(u8, all_args[0], "--workspace-root");
    const args = if (with_root) all_args[1..] else all_args;
    if (args.len != 6) {
        msg.* = usage;
        return error.Refused;
    }
    const mopm = try cwd.realpathAlloc(a, args[0]);
    const workspace = try cwd.realpathAlloc(a, args[1]);
    const project = cwd.realpathAlloc(a, try std.fs.path.join(a, &.{ args[1], args[2] })) catch |e| {
        msg.* = try std.fmt.allocPrint(a, "the package directory {s} is not in the workspace {s}: {s}", .{ args[2], args[1], @errorName(e) });
        return error.Refused;
    };
    const table = cwd.readFileAlloc(a, args[4], 64 << 20) catch |e| {
        msg.* = try std.fmt.allocPrint(a, "cannot read {s}: {s}", .{ args[4], @errorName(e) });
        return error.Refused;
    };
    const r = spawn(a, mopm, project, args[3], if (with_root) workspace else null) catch |e| {
        msg.* = try std.fmt.allocPrint(a, "cannot run {s}: {s}", .{ mopm, @errorName(e) });
        return error.Refused;
    };
    if (!r.exited or r.code != 0) {
        msg.* = try std.fmt.allocPrint(a, "`mopm plan --unit-graph --locked --mojo {s}` did not succeed (exit {d}): {s}", .{ args[3], r.code, r.stderr });
        return error.Refused;
    }
    // The committed form: the path dependencies by identity only (graph_norm.zig).
    const printed = norm.identityOnly(a, r.stdout) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.Broken => {
            msg.* = "mopm's unit graph is not in the layout this check reads (a unit block it cannot edit): the pinned mopm and buildrules disagree";
            return error.Refused;
        },
    };
    var why: []const u8 = "";
    check(a, table, printed, &why) catch |e| switch (e) {
        error.NoGraph => {
            msg.* = try std.fmt.allocPrint(a, "{s} has no GRAPH_JSON = r'''...''' block", .{args[4]});
            return error.Refused;
        },
        error.EmptyOutput => {
            msg.* = "`mopm plan --unit-graph --locked` printed nothing";
            return error.Refused;
        },
        error.Differs => {
            msg.* = try std.fmt.allocPrint(a, "{s}: {s}", .{ args[4], why });
            return error.Refused;
        },
        error.OutOfMemory => return e,
    };
    // A validation result is JSON (Buck2 rejects any other content).
    try cwd.writeFile(.{ .sub_path = args[5], .data = "{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"the committed graph is what the pinned mopm says\"}}\n" });
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
