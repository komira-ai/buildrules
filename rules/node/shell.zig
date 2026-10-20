//! The command line of a package.json script, read without a shell.
//!
//! A script is `command args && command args`: words separated by blanks, single and double
//! quotes, a backslash, leading `NAME=value` assignments, and `&&` between commands. Anything
//! else a shell would act on (pipes, redirections, `;`, `||`, `&`, `$`, backticks, globs,
//! subshells, `~`, comments, a newline) is refused with the position, so a script never means
//! something different here than under `npm run`. No shell runs in a build action.
const std = @import("std");

pub const Command = struct {
    /// `NAME=value` words in front of the command.
    env: []const [2][]const u8,
    /// The command and its arguments: `argv[0]` is never empty.
    argv: []const []const u8,
};

pub const Refusal = struct { at: usize, why: []const u8 };

pub const Result = union(enum) {
    ok: []const Command,
    refused: Refusal,
};

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isName(s: []const u8) bool {
    if (s.len == 0 or std.ascii.isDigit(s[0])) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// Parses `script`; the commands are in order, each run only if the one before exited 0.
pub fn parse(a: std.mem.Allocator, script: []const u8) !Result {
    var cmds = std.ArrayList(Command).empty;
    var words = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (true) {
        while (i < script.len and isBlank(script[i])) i += 1;
        if (i >= script.len or (script[i] == '&' and i + 1 < script.len and script[i + 1] == '&')) {
            const is_and = i < script.len;
            const r = try finish(a, &words, &cmds, i);
            if (r) |bad| return .{ .refused = bad };
            if (!is_and) break;
            i += 2;
            continue;
        }
        // one word
        var w = std.ArrayList(u8).empty;
        while (i < script.len and !isBlank(script[i])) {
            const c = script[i];
            switch (c) {
                '\'' => {
                    const end = std.mem.indexOfScalarPos(u8, script, i + 1, '\'') orelse return .{ .refused = .{ .at = i, .why = "an unterminated single quote" } };
                    try w.appendSlice(a, script[i + 1 .. end]);
                    i = end + 1;
                },
                '"' => {
                    i += 1;
                    while (true) {
                        if (i >= script.len) return .{ .refused = .{ .at = i, .why = "an unterminated double quote" } };
                        const d = script[i];
                        if (d == '"') {
                            i += 1;
                            break;
                        }
                        if (d == '$' or d == '`') return .{ .refused = .{ .at = i, .why = "a variable or command substitution (there is no shell to expand it)" } };
                        if (d == '\\') {
                            if (i + 1 >= script.len) return .{ .refused = .{ .at = i, .why = "a backslash at the end" } };
                            const n = script[i + 1];
                            if (n == '"' or n == '\\' or n == '$' or n == '`') {
                                try w.append(a, n);
                                i += 2;
                                continue;
                            }
                        }
                        if (d == '\n') return .{ .refused = .{ .at = i, .why = "a newline" } };
                        try w.append(a, d);
                        i += 1;
                    }
                },
                '\\' => {
                    if (i + 1 >= script.len) return .{ .refused = .{ .at = i, .why = "a backslash at the end" } };
                    try w.append(a, script[i + 1]);
                    i += 2;
                },
                '|', ';', '<', '>', '(', ')', '$', '`', '*', '?', '[', ']', '{', '}', '~', '!', '#', '\n', '\r' => {
                    return .{ .refused = .{ .at = i, .why = refusal(c) } };
                },
                '&' => {
                    if (i + 1 < script.len and script[i + 1] == '&') break;
                    return .{ .refused = .{ .at = i, .why = "`&` (a background job)" } };
                },
                else => {
                    try w.append(a, c);
                    i += 1;
                },
            }
        }
        try words.append(a, try w.toOwnedSlice(a));
    }
    return .{ .ok = try cmds.toOwnedSlice(a) };
}

fn refusal(c: u8) []const u8 {
    return switch (c) {
        '|' => "a pipe or `||`",
        ';' => "`;`",
        '<', '>' => "a redirection",
        '(', ')' => "a subshell",
        '$' => "a variable or command substitution",
        '`' => "a command substitution",
        '*', '?', '[', ']', '{', '}' => "a glob or brace pattern (quote it to pass it to the program)",
        '~' => "`~`",
        '!' => "`!`",
        '#' => "a comment",
        else => "a newline",
    };
}

/// Turns the words collected so far into a command (leading assignments split off); a refusal
/// when there is no command.
fn finish(a: std.mem.Allocator, words: *std.ArrayList([]const u8), cmds: *std.ArrayList(Command), at: usize) !?Refusal {
    var env = std.ArrayList([2][]const u8).empty;
    var n: usize = 0;
    while (n < words.items.len) : (n += 1) {
        const w = words.items[n];
        const eq = std.mem.indexOfScalar(u8, w, '=') orelse break;
        if (!isName(w[0..eq])) break;
        try env.append(a, .{ w[0..eq], w[eq + 1 ..] });
    }
    if (n == words.items.len) return .{ .at = at, .why = "an empty command (or only assignments) around `&&`" };
    try cmds.append(a, .{ .env = try env.toOwnedSlice(a), .argv = try a.dupe([]const u8, words.items[n..]) });
    words.clearRetainingCapacity();
    return null;
}
