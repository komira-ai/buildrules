//! table_check: is the committed table what the pinned mopm says now?
//!
//! usage: table_check [--workspace-root] [--subdir <subdir>]... [--also <mojo-version>[@<subdir>]]... <mopm> <workspace> <package-dir> <mojo-version> <buildrules.mojo.lock.bzl> <out>
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
//!
//! A package whose mopm.toml lists several Mojo versions has one block per other version: `GRAPH_JSON_MOJO_<V>` (`.` and `-` of the version
//! become `_`) for linux-64 and `GRAPH_JSON_MOJO_<V>_<SUBDIR>` for another subdir. `--also <v>` runs the same command with `--mojo <v>`, and
//! `--also <v>@<subdir>` with `--subdir <subdir>` as well, and compares the output, normalised the same way, with that block, byte for byte
//! with the same newline allowance; a refusal names the block and the version. Without `--also` the check is the one above.

const std = @import("std");
const norm = @import("mojo_graph_norm");

const graph_open = "GRAPH_JSON = r'''";
const graph_close = "'''\n";

pub const Error = error{ NoGraph, Differs, EmptyOutput };

/// The text of the graph in a table: what `sync` wrote between the markers.
pub fn graphOf(table: []const u8) error{NoGraph}![]const u8 {
    return graphAfter(table, graph_open);
}

fn graphAfter(table: []const u8, open: []const u8) error{NoGraph}![]const u8 {
    const gi = std.mem.indexOf(u8, table, open) orelse return error.NoGraph;
    const body = gi + open.len;
    const ge = std.mem.indexOfPos(u8, table, body, graph_close) orelse return error.NoGraph;
    return table[body..ge];
}

/// The text of the graph of another subdir in a table: the block `GRAPH_JSON_<SUBDIR> = r'''` (`linux-aarch64` -> `GRAPH_JSON_LINUX_AARCH64`).
pub fn graphOfSubdir(a: std.mem.Allocator, table: []const u8, subdir: []const u8) (error{NoGraph} || std.mem.Allocator.Error)![]const u8 {
    const prefix = "\nGRAPH_JSON_";
    const suffix = " = r'''";
    const open = try a.alloc(u8, prefix.len + subdir.len + suffix.len);
    @memcpy(open[0..prefix.len], prefix);
    for (subdir, 0..) |c, i| open[prefix.len + i] = if (c == '-') '_' else std.ascii.toUpper(c);
    @memcpy(open[prefix.len + subdir.len ..], suffix);
    return graphAfter(table, open);
}

/// The name of the block of Mojo version `version` for `subdir` (null: linux-64): `1.2.0` -> `GRAPH_JSON_MOJO_1_2_0`, with `osx-arm64`
/// `GRAPH_JSON_MOJO_1_2_0_OSX_ARM64`.
pub fn mojoBlockName(a: std.mem.Allocator, version: []const u8, subdir: ?[]const u8) std.mem.Allocator.Error![]const u8 {
    var name = std.ArrayList(u8).empty;
    try name.appendSlice(a, "GRAPH_JSON_MOJO_");
    for (version) |c| try name.append(a, if (c == '.' or c == '-') '_' else std.ascii.toUpper(c));
    if (subdir) |s| {
        try name.append(a, '_');
        for (s) |c| try name.append(a, if (c == '-') '_' else std.ascii.toUpper(c));
    }
    return name.items;
}

/// The text of the graph of another Mojo version in a table: the block named by `mojoBlockName`.
pub fn graphOfMojo(a: std.mem.Allocator, table: []const u8, version: []const u8, subdir: ?[]const u8) (error{NoGraph} || std.mem.Allocator.Error)![]const u8 {
    const open = try std.fmt.allocPrint(a, "\n{s} = r'''", .{try mojoBlockName(a, version, subdir)});
    return graphAfter(table, open);
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
    return checkIn(a, table, null, mopm_out, why);
}

/// `check` for the graph of `subdir` (null: the graph of linux-64, `GRAPH_JSON`).
pub fn checkIn(a: std.mem.Allocator, table: []const u8, subdir: ?[]const u8, mopm_out: []const u8, why: *[]const u8) (Error || std.mem.Allocator.Error)!void {
    // mopm printed nothing: there is no graph to be the same as, whatever the table holds (a blank block would pass the newline allowance).
    if (mopm_out.len == 0) return error.EmptyOutput;
    const graph = if (subdir) |s| try graphOfSubdir(a, table, s) else try graphOf(table);
    return differ(a, graph, mopm_out, why);
}

/// `check` for the block of Mojo version `version` (`graphOfMojo`).
pub fn checkMojo(a: std.mem.Allocator, table: []const u8, version: []const u8, subdir: ?[]const u8, mopm_out: []const u8, why: *[]const u8) (Error || std.mem.Allocator.Error)!void {
    if (mopm_out.len == 0) return error.EmptyOutput;
    return differ(a, try graphOfMojo(a, table, version, subdir), mopm_out, why);
}

fn differ(a: std.mem.Allocator, graph: []const u8, mopm_out: []const u8, why: *[]const u8) (Error || std.mem.Allocator.Error)!void {
    const at = firstDifference(graph, mopm_out) orelse return;
    const t = lineAt(graph, at);
    const m = lineAt(mopm_out, at);
    why.* = try std.fmt.allocPrint(a, "the committed graph is not what mopm says: first difference at line {d}\n  table: {s}\n  mopm:  {s}\nrun `buildrules mojo sync` and commit the result", .{ t.no, t.text, m.text });
    return error.Differs;
}

const usage = "usage: table_check [--workspace-root] [--subdir <subdir>]... [--also <mojo-version>[@<subdir>]]... <mopm> <workspace> <package-dir> <mojo-version> <buildrules.mojo.lock.bzl> <out>";

/// What running mopm gave: how it ended, and what it printed.
pub const Ran = struct { exited: bool, code: u8 = 0, stdout: []const u8 = "", stderr: []const u8 = "" };

/// Runs `<mopm> plan --unit-graph --locked --mojo <mojo>` in `project`, followed by `--workspace-root <root>` when `root` is given. A test
/// passes its own.
pub const Spawn = *const fn (a: std.mem.Allocator, mopm: []const u8, project: []const u8, mojo: []const u8, root: ?[]const u8) anyerror!Ran;

/// The same for another subdir: `... --subdir <subdir>` follows.
pub const SpawnSubdir = *const fn (a: std.mem.Allocator, mopm: []const u8, project: []const u8, mojo: []const u8, root: ?[]const u8, subdir: []const u8) anyerror!Ran;

pub fn spawnMopm(a: std.mem.Allocator, mopm: []const u8, project: []const u8, mojo: []const u8, root: ?[]const u8) anyerror!Ran {
    return spawnWith(a, mopm, project, mojo, root, null);
}

pub fn spawnMopmSubdir(a: std.mem.Allocator, mopm: []const u8, project: []const u8, mojo: []const u8, root: ?[]const u8, subdir: []const u8) anyerror!Ran {
    return spawnWith(a, mopm, project, mojo, root, subdir);
}

fn spawnWith(a: std.mem.Allocator, mopm: []const u8, project: []const u8, mojo: []const u8, root: ?[]const u8, subdir: ?[]const u8) anyerror!Ran {
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{ mopm, "plan", "--unit-graph", "--locked", "--mojo", mojo });
    if (root) |r| try argv.appendSlice(a, &.{ "--workspace-root", r });
    if (subdir) |s| try argv.appendSlice(a, &.{ "--subdir", s });
    const r = try std.process.Child.run(.{
        .allocator = a,
        .argv = argv.items,
        .cwd = project,
        .max_output_bytes = 64 << 20,
    });
    return switch (r.term) {
        .Exited => |code| .{ .exited = true, .code = code, .stdout = r.stdout, .stderr = r.stderr },
        else => .{ .exited = false, .stdout = r.stdout, .stderr = r.stderr },
    };
}

/// The seam of a run that has none for the other subdirs (a test of the linux-64 graph alone): any `--subdir` is then a run that cannot start.
pub fn noSubdirSpawn(_: std.mem.Allocator, _: []const u8, _: []const u8, _: []const u8, _: ?[]const u8, _: []const u8) anyerror!Ran {
    return error.NoSpawnForSubdirs;
}

/// The whole program: `args` are the arguments after the program's name. Every refusal is `error.Refused` with the words in `msg.*`.
pub fn run(a: std.mem.Allocator, cwd: std.fs.Dir, all_args: []const []const u8, spawn: Spawn, msg: *[]const u8) !void {
    return runWith(a, cwd, all_args, spawn, noSubdirSpawn, msg);
}

/// `run` with the seam for the graphs of the other subdirs (`--subdir <s>` before the positional arguments, once for each): each is compared with its own
/// `GRAPH_JSON_<SUBDIR>` block, so a table whose graph for one subdir is stale is red whichever the others are.
pub fn runWith(a: std.mem.Allocator, cwd: std.fs.Dir, all_args: []const []const u8, spawn: Spawn, spawn_subdir: SpawnSubdir, msg: *[]const u8) !void {
    var with_root = false;
    var subdirs = std.ArrayList([]const u8).empty;
    var alsos = std.ArrayList(Also).empty;
    var at: usize = 0;
    while (at < all_args.len) {
        if (std.mem.eql(u8, all_args[at], "--workspace-root")) {
            with_root = true;
            at += 1;
        } else if (std.mem.eql(u8, all_args[at], "--subdir") and at + 1 < all_args.len) {
            try subdirs.append(a, all_args[at + 1]);
            at += 2;
        } else if (std.mem.eql(u8, all_args[at], "--also") and at + 1 < all_args.len) {
            const v = all_args[at + 1];
            const sep = std.mem.indexOfScalar(u8, v, '@');
            const version = if (sep) |i| v[0..i] else v;
            const sub: ?[]const u8 = if (sep) |i| v[i + 1 ..] else null;
            if (version.len == 0 or (sub != null and sub.?.len == 0)) {
                msg.* = try std.fmt.allocPrint(a, "--also {s}: expected <mojo-version> or <mojo-version>@<subdir>", .{v});
                return error.Refused;
            }
            try alsos.append(a, .{ .version = version, .subdir = sub });
            at += 2;
        } else break;
    }
    const args = all_args[at..];
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
    const root: ?[]const u8 = if (with_root) workspace else null;
    try compareOne(a, table, args, mopm, project, root, .{ .mojo = args[3] }, spawn, spawn_subdir, msg);
    for (subdirs.items) |s| try compareOne(a, table, args, mopm, project, root, .{ .mojo = args[3], .subdir = s }, spawn, spawn_subdir, msg);
    for (alsos.items) |al| try compareOne(a, table, args, mopm, project, root, .{ .mojo = al.version, .subdir = al.subdir, .also = true }, spawn, spawn_subdir, msg);
    // A validation result is JSON (Buck2 rejects any other content).
    try cwd.writeFile(.{ .sub_path = args[5], .data = "{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"the committed graph is what the pinned mopm says\"}}\n" });
}

/// One `--also <version>[@<subdir>]`.
const Also = struct { version: []const u8, subdir: ?[]const u8 };

/// One graph to compare: the Mojo version asked of mopm, the subdir (null: linux-64), and whether it is the block of another version (`--also`).
const Graph = struct { mojo: []const u8, subdir: ?[]const u8 = null, also: bool = false };

/// One graph of the table against what mopm prints for it now (`subdir` null: the linux-64 graph, `GRAPH_JSON`; `also`: the block of that Mojo version).
fn compareOne(a: std.mem.Allocator, table: []const u8, args: []const []const u8, mopm: []const u8, project: []const u8, root: ?[]const u8, g: Graph, spawn: Spawn, spawn_subdir: SpawnSubdir, msg: *[]const u8) !void {
    const subdir = g.subdir;
    const what: []const u8 = if (subdir) |s| try std.fmt.allocPrint(a, " --subdir {s}", .{s}) else "";
    const r = (if (subdir) |s| spawn_subdir(a, mopm, project, g.mojo, root, s) else spawn(a, mopm, project, g.mojo, root)) catch |e| {
        msg.* = try std.fmt.allocPrint(a, "cannot run {s}: {s}", .{ mopm, @errorName(e) });
        return error.Refused;
    };
    if (!r.exited or r.code != 0) {
        msg.* = try std.fmt.allocPrint(a, "`mopm plan --unit-graph --locked --mojo {s}{s}` did not succeed (exit {d}): {s}", .{ g.mojo, what, r.code, r.stderr });
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
    const checked = if (g.also) checkMojo(a, table, g.mojo, subdir, printed, &why) else checkIn(a, table, subdir, printed, &why);
    checked catch |e| switch (e) {
        error.NoGraph => {
            msg.* = if (g.also)
                try std.fmt.allocPrint(a, "{s} has no {s} block: the pinned mopm prints a graph for Mojo {s}{s} and the table holds none; run `buildrules mojo sync`", .{ args[4], try mojoBlockName(a, g.mojo, subdir), g.mojo, what })
            else if (subdir) |s|
                try std.fmt.allocPrint(a, "{s} has no GRAPH_JSON_ block for {s}: the pinned mopm prints a graph for it and the table holds none; run `buildrules mojo sync`", .{ args[4], s })
            else
                try std.fmt.allocPrint(a, "{s} has no GRAPH_JSON = r'''...''' block", .{args[4]});
            return error.Refused;
        },
        error.EmptyOutput => {
            msg.* = if (g.also)
                try std.fmt.allocPrint(a, "`mopm plan --unit-graph --locked --mojo {s}{s}` printed nothing", .{ g.mojo, what })
            else
                try std.fmt.allocPrint(a, "`mopm plan --unit-graph --locked{s}` printed nothing", .{what});
            return error.Refused;
        },
        error.Differs => {
            msg.* = if (g.also)
                try std.fmt.allocPrint(a, "{s}: the {s} graph (Mojo {s}): {s}", .{ args[4], try mojoBlockName(a, g.mojo, subdir), g.mojo, why })
            else if (subdir) |s| try std.fmt.allocPrint(a, "{s}: the {s} graph: {s}", .{ args[4], s, why }) else try std.fmt.allocPrint(a, "{s}: {s}", .{ args[4], why });
            return error.Refused;
        },
        error.OutOfMemory => return e,
    };
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    var msg: []const u8 = "";
    runWith(a, std.fs.cwd(), args[1..], spawnMopm, spawnMopmSubdir, &msg) catch |e| {
        if (e != error.Refused) return e;
        std.debug.print("table_check: {s}\n", .{msg});
        std.process.exit(1);
    };
}
