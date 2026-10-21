//! A `gh` for tap_test.zig. Its state is the directory $FAKE_GH_DIR: the files below say what GitHub would answer, and `log` gets one line per call
//! (the arguments, space-joined); the pull-request calls change the files, so a test can read what the tool did. Vendored from the sibling tool's
//! fake `gh`, cut down to the calls the tap makes.
//!
//!   tags           one line per tag, `<name> <commit>`: `api repos/<repo>/commits/<tag>` answers with the commit (HTTP 404 for a tag not in the file)
//!   tap_main_formula   the text `api repos/<tap>/contents/Formula/<name>.rb?ref=main` answers with (else HTTP 404: the tap has no formula yet)
//!   tap_branch_formula the text it answers with for any other ref, i.e. a pushed bump branch (else HTTP 404)
//!   tap_read_error reading the tap's formula fails with HTTP 500 (not a 404)
//!   prs            one line per pull request, `<number> <OPEN|CLOSED|MERGED> <head branch> <auto-merge 0|1>`;
//!                  `pr create` appends one (number 100 + the count, OPEN, 0), `pr merge` sets the last field (not with auto_noop), `pr close` sets CLOSED
//!   create_fail, merge_fail, close_fail, auto_noop   `pr create` / `pr merge` / `pr close` fail; `pr merge` succeeds but leaves auto-merge off
//!   merge_clean    `pr merge` fails as GitHub does for a pull request with no required checks (HTTP 200, GraphQL: Pull request is in clean status)
//!   `pr merge` takes --merge or --squash.
//! A missing file means: no tag, no pull request, no refusal.

const std = @import("std");

fn failWith(comptime msg: []const u8) noreturn {
    std.io.getStdErr().writer().print("gh: " ++ msg ++ "\n", .{}) catch {};
    std.process.exit(1);
}

fn fileText(a: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ?[]u8 {
    return dir.readFileAlloc(a, name, 1 << 20) catch null;
}

/// The commit of tag `name` in the `tags` file, if it is there.
fn tagCommit(a: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) ?[]const u8 {
    const text = fileText(a, dir, "tags") orelse return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const sp = std.mem.indexOfScalar(u8, l, ' ') orelse continue;
        if (std.mem.eql(u8, l[0..sp], name)) return l[sp + 1 ..];
    }
    return null;
}

fn appendFile(dir: std.fs.Dir, name: []const u8, line: []const u8) !void {
    var f = try dir.createFile(name, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writer().print("{s}\n", .{line});
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(a);
    const dir_path = std.posix.getenv("FAKE_GH_DIR") orelse @panic("FAKE_GH_DIR");
    var dir = try std.fs.cwd().openDir(dir_path, .{});
    defer dir.close();
    const line = try std.mem.join(a, " ", argv[1..]);
    try appendFile(dir, "log", line);
    const w = std.io.getStdOut().writer();
    const args = argv[1..];

    if (std.mem.eql(u8, args[0], "api")) {
        var path: []const u8 = "";
        for (args) |x| {
            if (std.mem.startsWith(u8, x, "repos/")) path = x;
        }
        // repos/<owner>/<name>/<rest>
        var slashes: usize = 0;
        var at_rest: usize = path.len;
        for (path, 0..) |ch, k| {
            if (ch == '/') slashes += 1;
            if (slashes == 3) {
                at_rest = k + 1;
                break;
            }
        }
        const rest = path[at_rest..];
        if (std.mem.startsWith(u8, rest, "commits/v")) {
            const name = rest["commits/".len..];
            if (tagCommit(a, dir, name)) |c| {
                try w.print("{s}\n", .{c});
            } else failWith("Not Found (HTTP 404)");
        } else if (std.mem.startsWith(u8, rest, "contents/Formula/")) {
            if (fileText(a, dir, "tap_read_error") != null) failWith("Server Error (HTTP 500)");
            const at = std.mem.indexOf(u8, rest, "?ref=") orelse @panic("no ref");
            const file = if (std.mem.eql(u8, rest[at + 5 ..], "main")) "tap_main_formula" else "tap_branch_formula";
            try w.writeAll(fileText(a, dir, file) orelse failWith("Not Found (HTTP 404)"));
        } else {
            std.debug.print("fake gh: unexpected api call: {s}\n", .{line});
            std.process.exit(3);
        }
    } else if (std.mem.eql(u8, args[0], "pr")) {
        try pr(a, dir, args, w);
    } else {
        std.debug.print("fake gh: unexpected call: {s}\n", .{line});
        std.process.exit(3);
    }
}

/// The value after `flag` in `args`, or "".
fn flagValue(args: []const []const u8, flag: []const u8) []const u8 {
    for (args, 0..) |x, i| {
        if (std.mem.eql(u8, x, flag) and i + 1 < args.len) return args[i + 1];
    }
    return "";
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |x| {
        if (std.mem.eql(u8, x, flag)) return true;
    }
    return false;
}

/// `gh pr list|create|merge|view|close` over the file `prs` (see the header).
fn pr(a: std.mem.Allocator, dir: std.fs.Dir, args: []const []const u8, w: anytype) !void {
    const url_head = try std.fmt.allocPrint(a, "https://github.com/{s}/pull/", .{flagValue(args, "-R")});
    var lines = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, fileText(a, dir, "prs") orelse "", '\n');
    while (it.next()) |l| {
        if (l.len != 0) try lines.append(l);
    }
    const verb = args[1];
    if (std.mem.eql(u8, verb, "list")) {
        try w.writeAll("[");
        for (lines.items, 0..) |l, i| {
            var f = std.mem.splitScalar(u8, l, ' ');
            const n = f.next().?;
            const state = f.next().?;
            const head = f.next().?;
            const auto = f.next().?;
            const am = if (std.mem.eql(u8, auto, "1")) "{\"mergeMethod\":\"MERGE\"}" else "null";
            try w.print("{s}{{\"number\":{s},\"state\":\"{s}\",\"headRefName\":\"{s}\",\"url\":\"{s}{s}\",\"autoMergeRequest\":{s}}}", .{ if (i == 0) "" else ",", n, state, head, url_head, n, am });
        }
        try w.writeAll("]\n");
        return;
    }
    if (std.mem.eql(u8, verb, "create")) {
        if (fileText(a, dir, "create_fail") != null) failWith("pull request create failed");
        const n = 100 + lines.items.len;
        try appendFile(dir, "prs", try std.fmt.allocPrint(a, "{d} OPEN {s} 0", .{ n, flagValue(args, "--head") }));
        try w.print("{s}{d}\n", .{ url_head, n });
        return;
    }
    // merge, view and close name the pull request by number or url.
    const ref = args[2];
    const number = ref[if (std.mem.lastIndexOfScalar(u8, ref, '/')) |s| s + 1 else 0..];
    var found = false;
    var next = std.ArrayList(u8).init(a);
    for (lines.items) |l| {
        var f = std.mem.splitScalar(u8, l, ' ');
        const n = f.next().?;
        var state = f.next().?;
        const head = f.next().?;
        var auto = f.next().?;
        if (std.mem.eql(u8, n, number)) {
            found = true;
            if (std.mem.eql(u8, verb, "merge")) {
                if (fileText(a, dir, "merge_fail") != null) failWith("auto-merge cannot be enabled (GraphQL)");
                if (fileText(a, dir, "merge_clean") != null) failWith("GraphQL: Pull request is in clean status (enablePullRequestAutoMerge)");
                if (!hasFlag(args, "--auto") or !(hasFlag(args, "--merge") or hasFlag(args, "--squash"))) failWith("this fake wants gh pr merge --auto --merge|--squash");
                if (fileText(a, dir, "auto_noop") == null) auto = "1";
            } else if (std.mem.eql(u8, verb, "close")) {
                if (fileText(a, dir, "close_fail") != null) failWith("cannot close");
                state = "CLOSED";
            } else if (std.mem.eql(u8, verb, "view")) {
                try w.print("{s}\n", .{if (std.mem.eql(u8, auto, "1")) "true" else "false"});
            }
        }
        try next.writer().print("{s} {s} {s} {s}\n", .{ n, state, head, auto });
    }
    if (!found) failWith("no pull request found");
    try dir.writeFile("prs", next.items);
}
