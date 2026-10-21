//! Two small guards for text that came from a pull request.
//!
//! `oneLine`: a runner treats a line of output that starts with `::` as a workflow command, and the log of a
//! compute run is read by the runner. Every string from a lock, a package.json, a file list or an event that is
//! printed is printed through `oneLine`: every byte outside printable ASCII (a newline above all, a carriage
//! return, the escape byte, the bytes of a multi-byte character) becomes `?`, and a long string is cut, so a
//! message always begins with the program's own words and ends on its own line.
//!
//! `jsonDepthOk`: the JSON readers of the standard library recurse once per level of nesting, so a lock of
//! 300000 opening brackets would overflow the stack. A file with deeper nesting than a real lock or package.json
//! ever has is refused before it is parsed.

const std = @import("std");

pub const max_line: usize = 600;

pub fn oneLine(a: std.mem.Allocator, s: []const u8) ![]u8 {
    const cut = s[0..@min(s.len, max_line)];
    const out = try a.alloc(u8, cut.len + (if (s.len > cut.len) @as(usize, 3) else 0));
    for (cut, 0..) |c, i| out[i] = if (c >= 0x20 and c <= 0x7e) c else '?';
    if (s.len > cut.len) @memcpy(out[cut.len..], "...");
    return out;
}

/// The deepest nesting `{`/`[` a real file has is under ten; this is the bound.
pub const max_json_depth: usize = 32;

/// True when `text` nests objects and arrays no deeper than `max_json_depth` (strings and their escapes skipped).
pub fn jsonDepthOk(text: []const u8) bool {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (text) |c| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                if (depth > max_json_depth) return false;
            },
            '}', ']' => depth -|= 1,
            else => {},
        }
    }
    return true;
}
