//! zig_cc_launcher: runs `<zig_dir>/zig <subcommand> <args...>` for the C/C++
//! toolchain (mojo/cxx.bzl), after two adjustments zig needs inside a build
//! action:
//!
//!   * Response files are expanded, recursively. The prelude's C/C++ rules
//!     pass an argument file that names further argument files, and zig
//!     refuses a nested response file. Contents are tokenized like GNU/clang
//!     response files: whitespace separates arguments; single quotes, double
//!     quotes (with backslash escapes) and backslash escapes group them. An
//!     `@name` whose file does not exist is passed on unchanged, as clang does.
//!   * The environment is exactly ZIG_GLOBAL_CACHE_DIR and ZIG_LOCAL_CACHE_DIR,
//!     both under `.zig-cache/` in the working directory. Nothing is inherited.
//!
//!   * A compile that carries `--buildrules-split-semicolons` (asm_split.zig) is run as a preprocessing and an assembling command with the `;` of the text between turned into
//!     line breaks, for the assembly of a library whose macros join instructions with `;`.
//!
//! Exit status: zig's; 2 for a usage error, an unreadable response file, or a
//! failure to start zig.

const std = @import("std");
const split = @import("asm_split.zig");

const max_depth = 16;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zig_cc_launcher: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    const argv = try std.process.argsAlloc(arena);
    if (argv.len < 3) die("usage: zig_cc_launcher <zig_dir> <subcommand> [args...]", .{});

    var out = std.ArrayList([]const u8).init(arena);
    const zig_path = try std.fs.path.join(arena, &.{ argv[1], "zig" });
    try out.append(zig_path);
    try out.append(argv[2]);
    for (argv[3..]) |a| try expand(arena, &out, a, 0);

    var env = std.process.EnvMap.init(arena);
    try env.put("ZIG_GLOBAL_CACHE_DIR", ".zig-cache/global");
    try env.put("ZIG_LOCAL_CACHE_DIR", ".zig-cache/local");
    if (std.mem.eql(u8, argv[2], "cc")) try splitCompile(arena, zig_path, out.items[2..], &env);
    const err = std.process.execve(arena, out.items, &env);
    die("cannot run {s}: {s}", .{ zig_path, @errorName(err) });
}

fn expand(arena: std.mem.Allocator, out: *std.ArrayList([]const u8), arg: []const u8, depth: u32) !void {
    if (arg.len < 2 or arg[0] != '@') {
        try out.append(arg);
        return;
    }
    if (depth >= max_depth) die("response files nested deeper than {d} at {s}", .{ max_depth, arg });
    const data = std.fs.cwd().readFileAlloc(arena, arg[1..], 1 << 30) catch |e| switch (e) {
        error.FileNotFound => {
            try out.append(arg);
            return;
        },
        else => die("cannot read response file {s}: {s}", .{ arg[1..], @errorName(e) }),
    };
    var toks = std.ArrayList([]const u8).init(arena);
    try tokenize(arena, data, &toks);
    for (toks.items) |t| try expand(arena, out, t, depth + 1);
}

fn tokenize(arena: std.mem.Allocator, data: []const u8, toks: *std.ArrayList([]const u8)) !void {
    var cur = std.ArrayList(u8).init(arena);
    var in_tok = false;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        switch (c) {
            ' ', '\t', '\r', '\n' => {
                if (in_tok) {
                    try toks.append(try cur.toOwnedSlice());
                    in_tok = false;
                }
            },
            '\\' => {
                in_tok = true;
                if (i + 1 < data.len) {
                    i += 1;
                    try cur.append(data[i]);
                }
            },
            '\'', '"' => {
                in_tok = true;
                const q = c;
                i += 1;
                while (i < data.len and data[i] != q) : (i += 1) {
                    if (q == '"' and data[i] == '\\' and i + 1 < data.len) i += 1;
                    try cur.append(data[i]);
                }
                if (i >= data.len) die("unterminated quote in a response file", .{});
            },
            else => {
                in_tok = true;
                try cur.append(c);
            },
        }
    }
    if (in_tok) try toks.append(try cur.toOwnedSlice());
}

/// A compile marked for splitting (asm_split.zig) is run here, as two commands, and the launcher exits with the second's status. Anything else returns and is exec'd as it was.
fn splitCompile(arena: std.mem.Allocator, zig_path: []const u8, args: []const []const u8, env: *std.process.EnvMap) !void {
    // The text goes next to the object: its directory exists, the action may write it, and it is removed.
    var out_path: []const u8 = "";
    for (args, 0..) |x, i| {
        if (std.mem.eql(u8, x, "-o") and i + 1 < args.len) out_path = args[i + 1];
    }
    const tmp = try std.fmt.allocPrint(arena, "{s}.split.s", .{out_path});
    const p = (split.plan(arena, args, tmp) catch |e| die("a compile marked {s} is not a compile of one source to one object: {s}", .{ split.marker, @errorName(e) })) orelse return;

    var pre = std.ArrayList([]const u8).init(arena);
    try pre.appendSlice(&.{ zig_path, "cc" });
    try pre.appendSlice(p.pre);
    const r = try std.process.Child.run(.{ .allocator = arena, .argv = pre.items, .env_map = env, .max_output_bytes = 1 << 28 });
    switch (r.term) {
        .Exited => |code| if (code != 0) {
            std.io.getStdErr().writeAll(r.stderr) catch {};
            std.process.exit(code);
        },
        else => die("the preprocessing of a split source did not exit", .{}),
    }
    std.io.getStdErr().writeAll(r.stderr) catch {};
    const text = try split.splitSemicolons(arena, r.stdout);
    std.fs.cwd().writeFile(tmp, text) catch |e| die("cannot write {s}: {s}", .{ tmp, @errorName(e) });

    var post = std.ArrayList([]const u8).init(arena);
    try post.appendSlice(&.{ zig_path, "cc" });
    try post.appendSlice(p.post);
    // The second command assembles text that is no longer preprocessed: the preprocessor's flags are unused by it, which is not worth a warning.
    try post.append("-Wno-unused-command-line-argument");
    var child = std.process.Child.init(post.items, arena);
    child.env_map = env;
    const term = child.spawnAndWait() catch |e| die("cannot run {s}: {s}", .{ zig_path, @errorName(e) });
    std.fs.cwd().deleteFile(tmp) catch {};
    switch (term) {
        .Exited => |code| std.process.exit(code),
        else => die("the assembling of a split source did not exit", .{}),
    }
}
