//! asm_split: what zig_cc_launcher does to a source marked `--buildrules-split-semicolons` (rules/native/defs.bzl, `asm_split`).
//!
//! A `.S` file of a library such as s2n-bignum builds its routines out of macros whose instructions are joined with `;`. The assembler of Mach-O arm64 reads `;` as the start of a
//! comment, so each macro keeps its first instruction: the file assembles and computes the wrong thing. The fix (aws-lc's CMake does the same, `s2n_asm_cpreprocess`) is to run the
//! C preprocessor on the file, turn every `;` of its output into a line break, and assemble that. The launcher does it for the sources that carry the marker: one command
//! preprocesses (the compile's own flags, `-E`), the text is split here, and a second command assembles it as assembly (`-x assembler`).

const std = @import("std");

/// The flag that marks a source; the launcher removes it before zig sees the command.
pub const marker = "--buildrules-split-semicolons";

/// `text` with every `;` a line break.
pub fn splitSemicolons(a: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try a.dupe(u8, text);
    for (out) |*c| {
        if (c.* == ';') c.* = '\n';
    }
    return out;
}

pub const Plan = struct {
    /// The arguments of the preprocessing command (after `zig cc`): the compile's, with `-c` and `-o` replaced by `-E`.
    pre: []const []const u8,
    /// The arguments of the assembling command: the compile's, with the source replaced by `tmp` read as assembly.
    post: []const []const u8,
};

pub const PlanError = error{ NoSource, NoOutput, OutOfMemory };

/// The two commands for a compile `args` (the arguments after `zig cc`) that carries the marker, or null when it does not. `tmp` is where the split text is written.
pub fn plan(a: std.mem.Allocator, args: []const []const u8, tmp: []const u8) PlanError!?Plan {
    var marked = false;
    for (args) |x| {
        if (std.mem.eql(u8, x, marker)) marked = true;
    }
    if (!marked) return null;
    var pre = std.ArrayList([]const u8).init(a);
    var post = std.ArrayList([]const u8).init(a);
    var src_seen = false;
    var out_seen = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (std.mem.eql(u8, x, marker)) continue;
        if (std.mem.eql(u8, x, "-c") and i + 1 < args.len) {
            src_seen = true;
            try pre.append("-E");
            try pre.append(args[i + 1]);
            try post.append(x);
            try post.append("-x");
            try post.append("assembler");
            try post.append(tmp);
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, x, "-o") and i + 1 < args.len) {
            out_seen = true;
            try post.append(x);
            try post.append(args[i + 1]);
            i += 1;
            continue;
        }
        try pre.append(x);
        try post.append(x);
    }
    if (!src_seen) return error.NoSource;
    if (!out_seen) return error.NoOutput;
    return .{ .pre = try pre.toOwnedSlice(), .post = try post.toOwnedSlice() };
}
