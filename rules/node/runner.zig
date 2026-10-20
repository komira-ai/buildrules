//! `run`: a program of node_modules run by the pinned node over a copy of a
//! source tree (modules.bzl, node_tree_test).
//!
//! The copy is made in the action's scratch directory, `node_modules` linked
//! into the package directory, and node run there with an environment of its
//! own: the host's is never inherited.
const std = @import("std");
const shell = @import("shell.zig");
const unpack = @import("unpack.zig");

pub const Spec = struct {
    /// The staged source tree (a directory), the laid-out node_modules, the
    /// pinned node's root (bin/node) and the directory whose lib/ holds the
    /// C++ runtime node links: all absolute.
    tree: []const u8,
    modules: []const u8,
    node: []const u8,
    libs: []const u8,
    /// The package's directory below the tree, and the program (a path in
    /// it) with its arguments.
    package: []const u8,
    program: []const u8,
    args: []const []const u8,
    /// A package.json script (shell.zig): when set, `program` and `args` are not used and the
    /// script's commands run in order, each only if the one before exited 0.
    script: ?[]const u8 = null,
    /// Variables of the target, added to the fixed ones.
    env: []const [2][]const u8,
    /// Commands the program may run: name and the absolute path of the
    /// executable they link to (a multi-call binary such as busybox runs the
    /// applet of the name it is linked as). They are the only ones on PATH
    /// besides node.
    tools: []const [2][]const u8 = &.{},
    /// A directory of the package to export, or null for a pass marker.
    out_dir: ?[]const u8,
    scratch: []const u8,
};

/// The scratch directory of an action: buck2 names a private one in
/// BUCK_SCRATCH_PATH (relative to the working directory, or absolute); where
/// there is none, a directory of the working directory.
pub fn scratchDir(a: std.mem.Allocator, cwd: []const u8, buck_scratch: ?[]const u8) ![]u8 {
    const s = buck_scratch orelse "";
    if (s.len == 0) return std.fs.path.join(a, &.{ cwd, ".buildrules_action" });
    return std.fs.path.resolve(a, &.{ cwd, s, "buildrules" });
}

/// The environment node runs in, and nothing else.
pub fn buildEnv(a: std.mem.Allocator, spec: Spec) !std.process.EnvMap {
    var env = std.process.EnvMap.init(a);
    const home = try std.fs.path.join(a, &.{ spec.scratch, "home" });
    const tmp = try std.fs.path.join(a, &.{ spec.scratch, "tmp" });
    try env.put("LC_ALL", "C");
    try env.put("TZ", "UTC0");
    try env.put("HOME", home);
    try env.put("TMPDIR", tmp);
    const node_bin = try std.fs.path.join(a, &.{ spec.node, "bin" });
    const tools_bin = try std.fs.path.join(a, &.{ spec.scratch, "bin" });
    try env.put("PATH", try std.fmt.allocPrint(a, "{s}:{s}", .{ node_bin, tools_bin }));
    try env.put("LD_LIBRARY_PATH", try std.fs.path.join(a, &.{ spec.libs, "lib" }));
    for (spec.env) |kv| try env.put(kv[0], kv[1]);
    return env;
}

/// Copies the tree below `src` to `dst`: files 0644, or 0755 if the source is
/// executable (a source's mode may be read-only; the copy is to be written).
pub fn copyTree(a: std.mem.Allocator, src: std.fs.Dir, dst: std.fs.Dir) !void {
    var walker = try src.walk(a);
    defer walker.deinit();
    while (try walker.next()) |e| {
        switch (e.kind) {
            .directory => try dst.makePath(e.path),
            .file => {
                if (std.fs.path.dirname(e.path)) |d| try dst.makePath(d);
                const st = try src.statFile(e.path);
                try src.copyFile(e.path, dst, e.path, .{});
                const f = try dst.openFile(e.path, .{});
                defer f.close();
                try f.chmod(unpack.modeOf(@intCast(st.mode)));
            },
            else => return error.UnsupportedFileKind,
        }
    }
}

const Exec = struct { argv: []const []const u8, env: []const [2][]const u8, shown: []const u8 };

fn isTool(spec: Spec, name: []const u8) bool {
    for (spec.tools) |t| if (std.mem.eql(u8, t[0], name)) return true;
    return false;
}

fn say(w: anytype, comptime fmt: []const u8, args: anytype) error{Failed} {
    w.print("node_modules: " ++ fmt ++ "\n", args) catch {};
    return error.Failed;
}

/// Runs the program; the result is `out` (a directory or a pass marker).
/// Every refusal is written to `w` and is error.Failed.
pub fn run(a: std.mem.Allocator, spec: Spec, out_path: []const u8, w: anytype) !void {
    const cwd = std.fs.cwd();
    cwd.deleteTree(spec.scratch) catch {};
    defer cwd.deleteTree(spec.scratch) catch {};
    const work_path = try std.fs.path.join(a, &.{ spec.scratch, "work" });
    try cwd.makePath(work_path);
    {
        var src = try cwd.openDir(spec.tree, .{ .iterate = true });
        defer src.close();
        var dst = try cwd.openDir(work_path, .{});
        defer dst.close();
        try copyTree(a, src, dst);
    }
    const pkg_path = try std.fs.path.join(a, &.{ work_path, spec.package });
    try cwd.makePath(pkg_path);
    var pkg = try cwd.openDir(pkg_path, .{});
    defer pkg.close();
    try pkg.symLink(spec.modules, "node_modules", .{ .is_directory = true });
    if (spec.script == null) pkg.access(spec.program, .{}) catch {
        return say(w, "{s} is not in {s}/ (a package missing from node_modules, or a bin it does not declare)", .{ spec.program, spec.package });
    };
    const home = try std.fs.path.join(a, &.{ spec.scratch, "home" });
    const tmp = try std.fs.path.join(a, &.{ spec.scratch, "tmp" });
    try cwd.makePath(home);
    try cwd.makePath(tmp);

    const bin = try std.fs.path.join(a, &.{ spec.scratch, "bin" });
    try cwd.makePath(bin);
    var bin_dir = try cwd.openDir(bin, .{});
    defer bin_dir.close();
    for (spec.tools) |t| {
        if (t[0].len == 0 or std.mem.indexOfScalar(u8, t[0], '/') != null) return say(w, "tool name {s} is not a command name", .{t[0]});
        try bin_dir.symLink(t[1], t[0], .{});
    }

    var execs = std.ArrayList(Exec).empty;
    if (spec.script) |text| {
        const parsed = try shell.parse(a, text);
        const cmds = switch (parsed) {
            .ok => |c| c,
            .refused => |bad| return say(w, "the script `{s}` cannot be run without a shell: {s} at byte {d}", .{ text, bad.why, bad.at }),
        };
        for (cmds) |c| {
            const name = c.argv[0];
            var argv = std.ArrayList([]const u8).empty;
            const node_exe = try std.fs.path.join(a, &.{ spec.node, "bin", "node" });
            if (std.mem.eql(u8, name, "node")) {
                try argv.append(a, node_exe);
            } else if (isTool(spec, name)) {
                try argv.append(a, try std.fs.path.join(a, &.{ bin, name }));
            } else if (std.mem.eql(u8, name, "npm") or std.mem.eql(u8, name, "npx")) {
                return say(w, "`{s}` in the script `{s}`: there is no npm in a build action; write what it runs (`npm run x` is the script x)", .{ name, text });
            } else {
                const rel = try std.fmt.allocPrint(a, "node_modules/.bin/{s}", .{name});
                pkg.access(rel, .{}) catch return say(w, "`{s}` in the script `{s}` is not node, a tool of this target or a bin of node_modules", .{ name, text });
                try argv.append(a, node_exe);
                try argv.append(a, try std.fs.path.join(a, &.{ pkg_path, rel }));
            }
            try argv.appendSlice(a, c.argv[1..]);
            try execs.append(a, .{ .argv = argv.items, .env = c.env, .shown = name });
        }
    } else {
        var argv = std.ArrayList([]const u8).empty;
        try argv.append(a, try std.fs.path.join(a, &.{ spec.node, "bin", "node" }));
        try argv.append(a, try std.fs.path.join(a, &.{ pkg_path, spec.program }));
        try argv.appendSlice(a, spec.args);
        try execs.append(a, .{ .argv = argv.items, .env = &.{}, .shown = spec.program });
    }
    for (execs.items) |x| {
        var env = try buildEnv(a, spec);
        for (x.env) |kv| try env.put(kv[0], kv[1]);
        var child = std.process.Child.init(x.argv, a);
        child.cwd = pkg_path;
        child.env_map = &env;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        const shown = x.shown;
        const term = child.spawnAndWait() catch |err| return say(w, "{s}: cannot run: {s}", .{ shown, @errorName(err) });
        switch (term) {
            .Exited => |code| if (code != 0) return say(w, "{s} exited {d}", .{ shown, code }),
            .Signal => |sig| return say(w, "{s} was killed by signal {d}", .{ shown, sig }),
            else => return say(w, "{s} did not exit normally", .{shown}),
        }
    }

    if (spec.out_dir) |od| {
        var from = pkg.openDir(od, .{ .iterate = true }) catch return say(w, "the program passed but wrote no {s}/", .{od});
        defer from.close();
        try cwd.makePath(out_path);
        var to = try cwd.openDir(out_path, .{});
        defer to.close();
        try copyTree(a, from, to);
    } else {
        const f = try cwd.createFile(out_path, .{});
        f.close();
    }
}
