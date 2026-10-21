//! tap: the command line over tap.zig, the `tap` job of release.yml.
//!
//!   tap --repo <owner/name> --version <X.Y.Z> --formula-file <path> --tap-repo <owner/name> --formula <name> [--asset <stem>]
//!       --workdir <dir> [--gh <path>] [--git <path>]
//!
//! Opens (or finds, or finishes) the pull request that adds Formula/<name>.rb to the tap repository; see tap.zig for the steps and for what it refuses.
//! The token is the environment variable GH_TOKEN (the release bot's, minted for the tap repository alone), never an argument. `--gh` and `--git` name other
//! programs for the tests (a `gh` and a `git` whose answers are files).
//!
//! The deploy half of the formula channel; the build half is tools/channels (`channels formula`). Vendored from the sibling tool's release, whose
//! `cut_release tap` this is (tools/tap.zig, tools/ghtool.zig and the tap flags of tools/cut_release.zig at its main, commit 3ace214, with the head of its pull
//! request 150, commit ccac8e0, which makes the formula carry no version line). Its tests are drivers/tap_test.zig.

const std = @import("std");
const tap = @import("tap.zig");

fn usage() noreturn {
    std.debug.print("usage: tap --repo <owner/name> --version <X.Y.Z> --formula-file <path> --tap-repo <owner/name> --formula <name> [--asset <stem>] --workdir <dir> [--gh <path>] [--git <path>]\n", .{});
    std.process.exit(2);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    var repo: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var formula_file: ?[]const u8 = null;
    var tap_repo: ?[]const u8 = null;
    var formula: ?[]const u8 = null;
    var workdir: ?[]const u8 = null;
    var asset: []const u8 = "";
    var gh: []const u8 = "gh";
    var git: []const u8 = "git";
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) usage();
        const name = argv[i];
        const value = argv[i + 1];
        if (std.mem.eql(u8, name, "--repo")) {
            repo = value;
        } else if (std.mem.eql(u8, name, "--version")) {
            version = value;
        } else if (std.mem.eql(u8, name, "--formula-file")) {
            formula_file = value;
        } else if (std.mem.eql(u8, name, "--tap-repo")) {
            tap_repo = value;
        } else if (std.mem.eql(u8, name, "--formula")) {
            formula = value;
        } else if (std.mem.eql(u8, name, "--workdir")) {
            workdir = value;
        } else if (std.mem.eql(u8, name, "--asset")) {
            asset = value;
        } else if (std.mem.eql(u8, name, "--gh")) {
            gh = value;
        } else if (std.mem.eql(u8, name, "--git")) {
            git = value;
        } else usage();
    }
    tap.run(a, .{
        .gh = gh,
        .git = git,
        .repo = repo orelse usage(),
        .tap_repo = tap_repo orelse usage(),
        .formula = formula orelse usage(),
        .asset = asset,
        .version = version orelse usage(),
        .formula_file = formula_file orelse usage(),
        .workdir = workdir orelse usage(),
    });
}
