//! asm_split: the text step of `asm_split` (rules/native/asm_split.bzl).
//!
//! A `.S` file of a library such as s2n-bignum builds its routines out of macros whose instructions are joined with `;`. The assembler of Mach-O arm64 reads `;` as the start of
//! a comment, so each macro keeps its first instruction: the file assembles and computes the wrong thing. The fix (aws-lc's CMake does the same, `s2n_asm_cpreprocess`) is to run
//! the C preprocessor on the file, turn every `;` of its output into a line break, and assemble that.
//!
//!   asm_split --out <file> -- <compiler> <args...>
//!
//! runs the compiler command (the preprocessor: `-E` is among its arguments), takes what it prints, writes it to `<file>` with every `;` a line break. Its standard error is
//! passed on and its exit status is the tool's.

const std = @import("std");

/// `text` with every `;` a line break.
pub fn splitSemicolons(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try a.dupe(u8, text);
    for (out) |*c| {
        if (c.* == ';') c.* = '\n';
    }
    return out;
}

pub const Command = struct {
    out: []const u8,
    argv: []const []const u8,
};

pub const parse_usage = "usage: asm_split --out <file> -- <compiler> [args...]";

/// The command line, or null when it is not `--out <file> -- <command...>` with a command.
pub fn parseArgs(args: []const []const u8) ?Command {
    if (args.len < 4) return null;
    if (!std.mem.eql(u8, args[0], "--out")) return null;
    if (!std.mem.eql(u8, args[2], "--")) return null;
    return .{ .out = args[1], .argv = args[3..] };
}

/// What the compiler did.
pub const Result = struct {
    term: std.process.Child.Term,
    stdout: []const u8,
    stderr: []const u8,
};

/// The tool's end: the compiler's standard error is passed on; when it exited 0 its output is written split to `out` and the status is 0, when it exited otherwise that
/// status is returned and nothing is written, when it did not exit the status is 2.
pub fn finish(a: std.mem.Allocator, out: []const u8, r: Result, stderr: anytype) !u8 {
    stderr.writeAll(r.stderr) catch {};
    switch (r.term) {
        .Exited => |code| if (code != 0) return code,
        else => {
            stderr.writeAll("asm_split: the compiler did not exit\n") catch {};
            return 2;
        },
    }
    const text = try splitSemicolons(a, r.stdout);
    std.fs.cwd().writeFile(out, text) catch |e| {
        stderr.print("asm_split: cannot write {s}: {s}\n", .{ out, @errorName(e) }) catch {};
        return 2;
    };
    return 0;
}

/// Runs the command and finishes with what it did.
pub fn run(a: std.mem.Allocator, cmd: Command, stderr: anytype) !u8 {
    const r = std.process.Child.run(.{ .allocator = a, .argv = cmd.argv, .max_output_bytes = 1 << 28 }) catch |e| {
        stderr.print("asm_split: cannot run {s}: {s}\n", .{ cmd.argv[0], @errorName(e) }) catch {};
        return 2;
    };
    return finish(a, cmd.out, .{ .term = r.term, .stdout = r.stdout, .stderr = r.stderr }, stderr);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    const cmd = parseArgs(args[1..]) orelse {
        std.io.getStdErr().writeAll(parse_usage ++ "\n") catch {};
        std.process.exit(2);
    };
    const code = run(a, cmd, std.io.getStdErr().writer()) catch |e| {
        std.io.getStdErr().writer().print("asm_split: {s}\n", .{@errorName(e)}) catch {};
        std.process.exit(2);
    };
    std.process.exit(code);
}
