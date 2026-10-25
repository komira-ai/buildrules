//! mojo_sync: `buildrules mojo sync` as a farm action, and the copy of its files back into a working tree.
//!
//! usage: mojo_sync stage --src DIR --work DIR --out DIR --buildrules EXE --mopm EXE --mopm-version V
//!                        [--toolchains DIR] [--committed DIR] [--hint TEXT] PACKAGE...
//!        mojo_sync apply --from DIR [--to DIR]
//!
//! A machine that may not run a built binary cannot run `buildrules mojo sync`, the only writer of buildrules.mojo.lock.bzl,
//! toolchains/mojo_pins.bzl and toolchains/mopm_pins.bzl. `stage` is that command as a build action:
//!   1. copies `--src` (the packages, their path dependencies and mopm-toolchain.toml, at their repository paths) into `--work`, which is a scratch
//!      directory of the action, writes a `.buckconfig` there if there is none (`[cells] toolchains = <--toolchains>`) and makes the toolchains directory;
//!   2. refuses a package whose mopm-toolchain.toml names another mopm than `--mopm-version` (the mopm given is the one the file pins, or the files
//!      would say a version they were not made with);
//!   3. runs `buildrules mojo sync --dir <work> --mopm <mopm> PACKAGE...` (the pinned mopm, offline: it plans from the locks);
//!   4. copies the files the sync writes, and only those, to `--out` at the paths the repository has them: for each package its
//!      buildrules.mojo.lock.bzl and buildrules.mojo.bzl, and <toolchains>/mojo_pins.bzl and <toolchains>/mopm_pins.bzl;
//!   5. with `--committed DIR` (the committed copies of some of those files, at the same paths): exits 1, naming the first differing line, unless
//!      every file there is what the sync wrote. Nothing is written to the tree: the check is the build failing.
//! `apply` writes the files of a `stage` output into a working tree (the current directory unless `--to`), the files that differ only.

const std = @import("std");

pub const lock_name = "buildrules.mojo.lock.bzl";
pub const glue_name = "buildrules.mojo.bzl";
pub const pins_names = [_][]const u8{ "mojo_pins.bzl", "mopm_pins.bzl" };
pub const toolchain_file = "mopm-toolchain.toml";

pub const Mode = enum { stage, apply };

pub const Args = struct {
    mode: Mode = .stage,
    src: []const u8 = "",
    work: []const u8 = "",
    out: []const u8 = "",
    buildrules: []const u8 = "",
    mopm: []const u8 = "",
    mopm_version: []const u8 = "",
    toolchains: []const u8 = "toolchains",
    committed: ?[]const u8 = null,
    hint: []const u8 = "",
    packages: []const []const u8 = &.{},
    from: []const u8 = "",
    to: []const u8 = ".",
};

pub const ArgError = error{ MissingValue, MissingFlag, UnknownFlag, UnknownMode, BadPath, NoPackage, OutOfMemory };

/// A repository path that is a path below the root: not empty, not absolute, no `.` or `..` part. "." and "" are the root itself and are returned as "".
pub fn cleanRel(a: std.mem.Allocator, p: []const u8) ArgError![]const u8 {
    if (p.len > 0 and p[0] == '/') return error.BadPath;
    var parts = std.ArrayList([]const u8).empty;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.BadPath;
        try parts.append(a, part);
    }
    return std.mem.join(a, "/", parts.items);
}

pub fn parseArgs(a: std.mem.Allocator, argv: []const []const u8) ArgError!Args {
    var r = Args{};
    if (argv.len == 0) return error.UnknownMode;
    if (std.mem.eql(u8, argv[0], "stage")) r.mode = .stage else if (std.mem.eql(u8, argv[0], "apply")) r.mode = .apply else return error.UnknownMode;
    var pkgs = std.ArrayList([]const u8).empty;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const k = argv[i];
        if (!std.mem.startsWith(u8, k, "--")) {
            if (r.mode != .stage) return error.UnknownFlag;
            try pkgs.append(a, try cleanRel(a, k));
            continue;
        }
        if (i + 1 >= argv.len) return error.MissingValue;
        i += 1;
        const v = argv[i];
        const eq = std.mem.eql;
        if (r.mode == .stage and eq(u8, k, "--src")) r.src = v else if (r.mode == .stage and eq(u8, k, "--work")) r.work = v else if (r.mode == .stage and eq(u8, k, "--out")) r.out = v else if (r.mode == .stage and eq(u8, k, "--buildrules")) r.buildrules = v else if (r.mode == .stage and eq(u8, k, "--mopm")) r.mopm = v else if (r.mode == .stage and eq(u8, k, "--mopm-version")) r.mopm_version = v else if (r.mode == .stage and eq(u8, k, "--toolchains")) r.toolchains = try cleanRel(a, v) else if (r.mode == .stage and eq(u8, k, "--committed")) r.committed = v else if (r.mode == .stage and eq(u8, k, "--hint")) r.hint = v else if (r.mode == .apply and eq(u8, k, "--from")) r.from = v else if (r.mode == .apply and eq(u8, k, "--to")) r.to = v else return error.UnknownFlag;
    }
    r.packages = pkgs.items;
    switch (r.mode) {
        .stage => {
            if (r.src.len == 0 or r.work.len == 0 or r.out.len == 0 or r.buildrules.len == 0 or r.mopm.len == 0 or r.mopm_version.len == 0) return error.MissingFlag;
            if (r.toolchains.len == 0) return error.BadPath;
            if (pkgs.items.len == 0) return error.NoPackage;
        },
        .apply => if (r.from.len == 0) return error.MissingFlag,
    }
    return r;
}

/// Copies the tree at `from` (symlinks followed: a farm input directory may be made of them) to `to`.
pub fn copyTree(a: std.mem.Allocator, from: std.fs.Dir, to: std.fs.Dir) !void {
    var w = try from.walk(a);
    defer w.deinit();
    while (try w.next()) |e| {
        switch (e.kind) {
            .directory => try to.makePath(e.path),
            .file, .sym_link => {
                if (std.fs.path.dirname(e.path)) |d| try to.makePath(d);
                try from.copyFile(e.path, to, e.path, .{});
            },
            else => {},
        }
    }
}

pub fn buckconfig(a: std.mem.Allocator, toolchains: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "[cells]\n  toolchains = {s}\n", .{toolchains});
}

/// Step 1: the staged workspace.
pub fn stage(a: std.mem.Allocator, args: Args) !void {
    var src = try std.fs.cwd().openDir(args.src, .{ .iterate = true });
    defer src.close();
    try std.fs.cwd().makePath(args.work);
    var work = try std.fs.cwd().openDir(args.work, .{});
    defer work.close();
    try copyTree(a, src, work);
    work.access(".buckconfig", .{}) catch try work.writeFile(.{ .sub_path = ".buckconfig", .data = try buckconfig(a, args.toolchains) });
    try work.makePath(args.toolchains);
}

/// The value of `mopm` in the `[toolchain]` table of a mopm-toolchain.toml (`mopm = "0.0.48"`, either quote, a trailing comment allowed), or null.
pub fn mopmVersionOf(text: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "mopm")) continue;
        const rest = std.mem.trim(u8, line[4..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        const v = std.mem.trim(u8, rest[1..], " \t");
        if (v.len < 2 or (v[0] != '"' and v[0] != '\'')) return null;
        const close = std.mem.indexOfScalarPos(u8, v, 1, v[0]) orelse return null;
        return v[1..close];
    }
    return null;
}

/// The mopm version the mopm-toolchain.toml that governs `pkg` (the nearest one at or above it, the way `mojo sync` finds it) pins, read from `work`;
/// null when there is no such file or it pins none.
pub fn pinnedMopm(a: std.mem.Allocator, work: std.fs.Dir, pkg: []const u8) !?[]const u8 {
    var here: ?[]const u8 = pkg;
    while (here) |h| {
        const p = if (h.len == 0) toolchain_file else try std.fmt.allocPrint(a, "{s}/{s}", .{ h, toolchain_file });
        if (work.readFileAlloc(a, p, 1 << 20)) |text| {
            return mopmVersionOf(text);
        } else |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        }
        here = if (h.len == 0) null else (std.fs.path.dirname(h) orelse "");
    }
    return null;
}

/// Step 2: the first package whose mopm-toolchain.toml pins a mopm other than `version`, with the words that refuse it.
pub fn toolchainMismatch(a: std.mem.Allocator, work: std.fs.Dir, packages: []const []const u8, version: []const u8) !?[]const u8 {
    for (packages) |pkg| {
        const got = (try pinnedMopm(a, work, pkg)) orelse continue;
        if (!std.mem.eql(u8, got, version)) {
            return try std.fmt.allocPrint(a, "{s}: mopm-toolchain.toml pins mopm {s}, and this sync is given mopm {s}: the target's `mopm` must be the version the file names, or the files it writes would record a mopm that did not make them", .{ if (pkg.len == 0) "." else pkg, got, version });
        }
    }
    return null;
}

fn join(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return if (dir.len == 0) a.dupe(u8, name) else std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

/// The files a sync of `packages` writes, as repository paths.
pub fn generatedPaths(a: std.mem.Allocator, packages: []const []const u8, toolchains: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (packages) |p| {
        try out.append(a, try join(a, p, lock_name));
        try out.append(a, try join(a, p, glue_name));
    }
    for (pins_names) |n| try out.append(a, try join(a, toolchains, n));
    return out.items;
}

/// Step 4: copies exactly `generatedPaths` from `work` to `out`; a file the sync did not write is an error that names it.
pub fn harvest(a: std.mem.Allocator, work: std.fs.Dir, out: std.fs.Dir, packages: []const []const u8, toolchains: []const u8, missing: *[]const u8) !void {
    for (try generatedPaths(a, packages, toolchains)) |p| {
        if (std.fs.path.dirname(p)) |d| try out.makePath(d);
        work.copyFile(p, out, p, .{}) catch |e| switch (e) {
            error.FileNotFound => {
                missing.* = p;
                return error.NotWritten;
            },
            else => return e,
        };
    }
}

/// The first line at which two texts differ: its number and the line of each (empty past the end of a text).
pub const LineDiff = struct { no: usize, have: []const u8, want: []const u8 };

pub fn firstDifference(have: []const u8, want: []const u8) ?LineDiff {
    if (std.mem.eql(u8, have, want)) return null;
    var h = std.mem.splitScalar(u8, have, '\n');
    var w = std.mem.splitScalar(u8, want, '\n');
    var no: usize = 1;
    while (true) : (no += 1) {
        const hl = h.next();
        const wl = w.next();
        if (hl == null and wl == null) return .{ .no = no, .have = "", .want = "" };
        const hs = hl orelse "";
        const ws = wl orelse "";
        if (hl == null or wl == null or !std.mem.eql(u8, hs, ws)) return .{ .no = no, .have = hs, .want = ws };
    }
}

/// Step 5: every file under `committed` against the file of the same path under `out`. Returns the refusals, one per file that is missing or differs.
pub fn compare(a: std.mem.Allocator, out: std.fs.Dir, committed: std.fs.Dir, hint: []const u8) ![]const []const u8 {
    var bad = std.ArrayList([]const u8).empty;
    var w = try committed.walk(a);
    defer w.deinit();
    while (try w.next()) |e| {
        if (e.kind != .file and e.kind != .sym_link) continue;
        const have = try committed.readFileAlloc(a, e.path, 64 << 20);
        const want = out.readFileAlloc(a, e.path, 64 << 20) catch |err| switch (err) {
            error.FileNotFound => {
                try bad.append(a, try std.fmt.allocPrint(a, "STALE: {s} is committed, and a sync does not write a file of that name{s}", .{ e.path, hint }));
                continue;
            },
            else => return err,
        };
        if (firstDifference(have, want)) |d| {
            try bad.append(a, try std.fmt.allocPrint(a, "STALE: {s} is not what a sync writes now: first difference at line {d}\n  committed: {s}\n  sync:      {s}{s}", .{ e.path, d.no, d.have, d.want, hint }));
        }
    }
    return bad.items;
}

/// `apply`: the files under `from` into `to`, only where the bytes differ; `wrote` gets the path of each one written. `error.NotARoot` when `to` has no
/// .buckconfig (it is not a repository root, and nothing is written).
pub fn apply(a: std.mem.Allocator, from: std.fs.Dir, to: std.fs.Dir, wrote: *std.ArrayList([]const u8)) !void {
    to.access(".buckconfig", .{}) catch return error.NotARoot;
    var w = try from.walk(a);
    defer w.deinit();
    while (try w.next()) |e| {
        if (e.kind != .file and e.kind != .sym_link) continue;
        const bytes = try from.readFileAlloc(a, e.path, 64 << 20);
        if (to.readFileAlloc(a, e.path, 64 << 20)) |have| {
            if (std.mem.eql(u8, have, bytes)) continue;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        if (std.fs.path.dirname(e.path)) |d| try to.makePath(d);
        try to.writeFile(.{ .sub_path = e.path, .data = bytes });
        try wrote.append(a, try a.dupe(u8, e.path));
    }
}

