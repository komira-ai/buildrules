//! sync_stage: run `buildrules sync` on the farm, in a copy of a workspace, against a local copy of the registry.
//!
//! usage: sync_stage --src DIR --out DIR --buildrules EXE --cargo DIR --sysroot DIR --pins FILE [--registry DIR] [--check]
//!
//! A farm action has no network, so cargo cannot resolve against crates.io there. A cargo "local registry" is a directory of
//! `index/<aa>/<bb>/<name>` files (the lines crates.io's index holds) and the `.crate` files; cargo reads it in place of crates.io
//! (`[source.crates-io] replace-with`) and every id it prints is still crates.io's. This tool:
//!   1. copies `--src` (a workspace: Cargo.toml, rust-toolchain.toml, the members, optionally Cargo.lock and the generated files)
//!      into `--out`, which is the action's output directory, and writes a `.buckconfig` there if there is none;
//!   2. with `--registry`: copies it to `<out>/registry`, writes `<out>/.cargo/config.toml` pointing cargo at it, and puts its crates
//!      where `buildrules sync` looks for the sizes of the registry crates (cargo's own cache), so nothing is downloaded;
//!   3. runs `buildrules sync --dir <out> [--check]` with the pinned cargo, rustc and Rust version table.
//! With `--check` nothing under `<out>` changes but buck-out/: sync exits 1 unless the generated files in the copy are what it would write.
//! Without it, `<out>` holds the files a sync writes, to be copied into the repository by whoever ran the action.

const std = @import("std");

pub const Args = struct {
    src: []const u8 = "",
    out: []const u8 = "",
    buildrules: []const u8 = "",
    cargo: []const u8 = "",
    sysroot: []const u8 = "",
    pins: []const u8 = "",
    registry: ?[]const u8 = null,
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
        if (std.mem.eql(u8, k, "--src")) a.src = v else if (std.mem.eql(u8, k, "--out")) a.out = v else if (std.mem.eql(u8, k, "--buildrules")) a.buildrules = v else if (std.mem.eql(u8, k, "--cargo")) a.cargo = v else if (std.mem.eql(u8, k, "--sysroot")) a.sysroot = v else if (std.mem.eql(u8, k, "--pins")) a.pins = v else if (std.mem.eql(u8, k, "--registry")) a.registry = v else return error.UnknownFlag;
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

pub const config_toml =
    "[source.crates-io]\n" ++
    "replace-with = \"local\"\n\n" ++
    "[source.local]\n" ++
    "local-registry = \"registry\"\n";

/// Where `buildrules sync` looks for the `.crate` files before it downloads any (`<cargo home>/registry/cache/<index>/`).
pub const cache_dir = "buck-out/buildrules/cargo-home/registry/cache/local";

/// Steps 1 and 2: the staged workspace.
pub fn stage(a: std.mem.Allocator, args: Args) !void {
    var src = try std.fs.cwd().openDir(args.src, .{ .iterate = true });
    defer src.close();
    try std.fs.cwd().makePath(args.out);
    var out = try std.fs.cwd().openDir(args.out, .{});
    defer out.close();
    try copyTree(a, src, out);
    out.access(".buckconfig", .{}) catch try out.writeFile(.{ .sub_path = ".buckconfig", .data = "[cells]\n" });
    if (args.registry) |r| {
        var reg = try std.fs.cwd().openDir(r, .{ .iterate = true });
        defer reg.close();
        try out.makePath("registry");
        var dst = try out.openDir("registry", .{});
        defer dst.close();
        try copyTree(a, reg, dst);
        try out.makePath(".cargo");
        try out.writeFile(.{ .sub_path = ".cargo/config.toml", .data = config_toml });
        try out.makePath(cache_dir);
        var cache = try out.openDir(cache_dir, .{});
        defer cache.close();
        var it = reg.iterate();
        while (try it.next()) |e| {
            if (e.kind != .file and e.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, e.name, ".crate")) continue;
            try reg.copyFile(e.name, cache, e.name, .{});
        }
    }
}

fn real(a: std.mem.Allocator, p: []const u8) ![]u8 {
    return std.fs.cwd().realpathAlloc(a, p);
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    const args = parseArgs(argv[1..]) catch |e| {
        std.debug.print("sync_stage: {s}\nusage: sync_stage --src DIR --out DIR --buildrules EXE --cargo DIR --sysroot DIR --pins FILE [--registry DIR] [--check]\n", .{@errorName(e)});
        return 2;
    };
    try stage(a, args);
    const out = try real(a, args.out);
    const cargo = try std.fmt.allocPrint(a, "{s}/bin/cargo", .{try real(a, args.cargo)});
    const rustc = try std.fmt.allocPrint(a, "{s}/bin/rustc", .{try real(a, args.sysroot)});
    var cmd = std.ArrayList([]const u8).empty;
    try cmd.appendSlice(a, &.{ try real(a, args.buildrules), "sync", "--dir", out, "--cargo", cargo, "--rustc", rustc, "--pins", try real(a, args.pins) });
    if (args.check) try cmd.append(a, "--check");
    var child = std.process.Child.init(cmd.items, a);
    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |c| c,
        else => 1,
    };
}
