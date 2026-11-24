//! sync_stage: run `buildrules sync` on the farm, in a copy of a workspace, against the sources Cargo.lock pins, fetched by hash.
//!
//! usage: sync_stage --src DIR --out DIR --buildrules EXE --cargo DIR --sysroot DIR --pins FILE [--sources DIR] [--check]
//!
//! A farm action has no network. rules/rust/sync.bzl downloads, before this action, every file `buildrules sync --list-sources` names
//! (each crates.io package of Cargo.lock by the sha256 Cargo.lock records, each git commit's archive by the record's sha256 and size) into
//! `--sources`, and `buildrules sync --sources` reads them in place of the network (cli/src/sources.zig). This tool:
//!   1. copies `--src` (a workspace: Cargo.toml, rust-toolchain.toml, the members, Cargo.lock and the generated files) into a work directory
//!      in the action's scratch directory (`$BUCK_SCRATCH_PATH`, which buck2 discards), and writes a `.buckconfig` there if there is none;
//!   2. runs `buildrules sync --dir <work> [--sources DIR] [--check]` with the pinned cargo, rustc and Rust version table;
//!   3. without `--check`, copies into `--out` every file sync wrote: each file of the work directory outside buck-out/ that `--src` does
//!      not have or has with other bytes (not the `.buckconfig` of step 1). So `--out` holds exactly what the sync changed, and
//!      `buck2 build //:sync --out .` puts it into the repository; a file the sync removed is named on standard error, to be deleted by hand.
//!      With `--check`, `--out` is empty and the exit code is sync's: 1 unless the generated files of `--src` are what a sync writes.

const std = @import("std");

pub const Args = struct {
    src: []const u8 = "",
    out: []const u8 = "",
    buildrules: []const u8 = "",
    cargo: []const u8 = "",
    sysroot: []const u8 = "",
    pins: []const u8 = "",
    sources: ?[]const u8 = null,
    check: bool = false,
};

pub fn parseArgs(argv: []const []const u8) !Args {
    var a = Args{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const k = argv[i];
        if (std.mem.eql(u8, k, "--check")) {
            a.check = true;
            continue;
        }
        if (i + 1 >= argv.len) return error.MissingValue;
        i += 1;
        const v = argv[i];
        if (std.mem.eql(u8, k, "--src")) a.src = v else if (std.mem.eql(u8, k, "--out")) a.out = v else if (std.mem.eql(u8, k, "--buildrules")) a.buildrules = v else if (std.mem.eql(u8, k, "--cargo")) a.cargo = v else if (std.mem.eql(u8, k, "--sysroot")) a.sysroot = v else if (std.mem.eql(u8, k, "--pins")) a.pins = v else if (std.mem.eql(u8, k, "--sources")) a.sources = v else return error.UnknownFlag;
    }
    if (a.src.len == 0 or a.out.len == 0 or a.buildrules.len == 0 or a.cargo.len == 0 or a.sysroot.len == 0 or a.pins.len == 0) return error.MissingFlag;
    return a;
}

/// Copies the tree at `from` (symlinks followed: a farm input directory may be made of them) to `to`, which is created.
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

/// Step 1: the workspace copied into `work` (created). Whether a `.buckconfig` was added.
pub fn stage(a: std.mem.Allocator, src: std.fs.Dir, work: std.fs.Dir) !bool {
    try copyTree(a, src, work);
    work.access(".buckconfig", .{}) catch {
        try work.writeFile(.{ .sub_path = ".buckconfig", .data = "[cells]\n" });
        return true;
    };
    return false;
}

/// The command line of step 2; every path absolute.
pub fn syncArgv(a: std.mem.Allocator, args: Args, work: []const u8, real: *const fn (std.mem.Allocator, []const u8) anyerror![]u8) ![]const []const u8 {
    var cmd = std.ArrayList([]const u8).empty;
    try cmd.appendSlice(a, &.{
        try real(a, args.buildrules), "sync",
        "--dir",                      work,
        "--cargo",                    try std.fmt.allocPrint(a, "{s}/bin/cargo", .{try real(a, args.cargo)}),
        "--rustc",                    try std.fmt.allocPrint(a, "{s}/bin/rustc", .{try real(a, args.sysroot)}),
        "--pins",                     try real(a, args.pins),
    });
    if (args.sources) |s| try cmd.appendSlice(a, &.{ "--sources", try real(a, s) });
    if (args.check) try cmd.append(a, "--check");
    return cmd.items;
}

/// Whether the file at `path` is one a sync may write: anything outside buck-out/ (its scratch).
fn generated(path: []const u8) bool {
    return !std.mem.startsWith(u8, path, "buck-out/");
}

/// Step 3: copies into `out` each file of `work` (outside buck-out/, and not the `.buckconfig` stage added) that `src` lacks or holds with
/// other bytes. Returns the files of `src` that `work` no longer has.
pub fn collect(a: std.mem.Allocator, src: std.fs.Dir, work: std.fs.Dir, out: std.fs.Dir, added_buckconfig: bool) ![]const []const u8 {
    var w = try work.walk(a);
    defer w.deinit();
    while (try w.next()) |e| {
        if (e.kind != .file or !generated(e.path)) continue;
        if (added_buckconfig and std.mem.eql(u8, e.path, ".buckconfig")) continue;
        const mine = try work.readFileAlloc(a, e.path, 1 << 30);
        const before = src.readFileAlloc(a, e.path, 1 << 30) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (before != null and std.mem.eql(u8, before.?, mine)) continue;
        if (std.fs.path.dirname(e.path)) |d| try out.makePath(d);
        try out.writeFile(.{ .sub_path = e.path, .data = mine });
    }
    var removed = std.ArrayList([]const u8).empty;
    var s = try src.walk(a);
    defer s.deinit();
    while (try s.next()) |e| {
        if (e.kind == .directory or !generated(e.path)) continue;
        work.access(e.path, .{}) catch try removed.append(a, try a.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, removed.items, {}, lessPath);
    return removed.items;
}

fn lessPath(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn realPath(a: std.mem.Allocator, p: []const u8) anyerror![]u8 {
    return std.fs.cwd().realpathAlloc(a, p);
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    const args = parseArgs(argv[1..]) catch |e| {
        std.debug.print("sync_stage: {s}\nusage: sync_stage --src DIR --out DIR --buildrules EXE --cargo DIR --sysroot DIR --pins FILE [--sources DIR] [--check]\n", .{@errorName(e)});
        return 2;
    };
    const scratch = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch ".br_scratch";
    const work_path = try std.fs.path.join(a, &.{ scratch, "workspace" });
    try std.fs.cwd().deleteTree(work_path);
    try std.fs.cwd().makePath(work_path);
    var work = try std.fs.cwd().openDir(work_path, .{ .iterate = true });
    defer work.close();
    var src = try std.fs.cwd().openDir(args.src, .{ .iterate = true });
    defer src.close();
    const added = try stage(a, src, work);
    try std.fs.cwd().makePath(args.out);
    var child = std.process.Child.init(try syncArgv(a, args, try realPath(a, work_path), &realPath), a);
    const code: u8 = switch (try child.spawnAndWait()) {
        .Exited => |c| c,
        else => 1,
    };
    if (code != 0 or args.check) return code;
    var out = try std.fs.cwd().openDir(args.out, .{});
    defer out.close();
    for (try collect(a, src, work, out, added)) |p| std.debug.print("sync_stage: the sync removed {s}: delete it from the repository\n", .{p});
    return 0;
}
