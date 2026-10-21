//! mopm_pins.zig: the mopm versions a repository pins itself, buildrules-pins.toml's [mopm."V"] tables, rendered into toolchains/mopm_pins.bzl. A pin is a
//! download nobody reviewed unless every field is checked, so each refusal here is a field, a header or a line that is wrong in one way.

const std = @import("std");
const Diag = @import("diag.zig").Diag;
const kit = @import("testkit.zig");
const mopm_pins = @import("mopm_pins.zig");
const t = std.testing;

const h1 = "ab" ** 32;
const h2 = "cd" ** 32;
const url = "https://example.org/r/mopm-0.0.2-linux-x86_64.tar.gz";
const url3 = "https://example.org/r/mopm-0.0.3-linux-x86_64.tar.gz";

const good =
    "[mopm.\"0.0.3\"]\nurl = \"" ++ url3 ++ "\"\nsha256 = \"" ++ h2 ++ "\" # second\nsize = 20\n" ++
    "[rust.\"1.86.0\"]\nsha256 = \"anything, the rust reader's\"\n" ++
    "[mopm.\"0.0.2\"]\nurl = \"" ++ url ++ "\"\nsha256 = \"" ++ h1 ++ "\"\nsize = 10\n";

fn refused(text: []const u8, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d = Diag.init(arena.allocator());
    if (mopm_pins.render(arena.allocator(), text, &d)) |_| {
        std.debug.print("accepted:\n{s}\n", .{text});
        return error.AcceptedABadFile;
    } else |_| {}
    for (d.msgs.items) |m| if (std.mem.indexOf(u8, m, needle) != null) return;
    std.debug.print("no message names `{s}`; got:\n", .{needle});
    for (d.msgs.items) |m| std.debug.print("  {s}\n", .{m});
    return error.WrongMessage;
}

test "two pins render sorted by version, with the directory the tarball unpacks into; rust tables and comments are not read" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d = Diag.init(arena.allocator());
    const out = try mopm_pins.render(arena.allocator(), good, &d);
    const want = mopm_pins.header ++ "EXTRA_MOPM_VERSIONS = {\n" ++
        "    \"0.0.2\": {\n        \"url\": \"" ++ url ++ "\",\n        \"sha256\": \"" ++ h1 ++ "\",\n        \"size\": 10,\n        \"dir\": \"mopm-0.0.2-linux-x86_64\",\n    },\n" ++
        "    \"0.0.3\": {\n        \"url\": \"" ++ url3 ++ "\",\n        \"sha256\": \"" ++ h2 ++ "\",\n        \"size\": 20,\n        \"dir\": \"mopm-0.0.3-linux-x86_64\",\n    },\n}\n";
    try t.expectEqualStrings(want, out);
    try t.expectEqualStrings(mopm_pins.empty, try mopm_pins.render(arena.allocator(), "", &d));
    try t.expectEqualStrings(mopm_pins.empty, try mopm_pins.render(arena.allocator(), "# c\n[rust.\"1.86.0\"]\nx = 1\n", &d));
}

test "unpackDir is the file name without .tar.gz, and only for a URL with a path and that extension" {
    try t.expectEqualStrings("mopm-0.0.2-linux-x86_64", mopm_pins.unpackDir(url).?);
    try t.expectEqualStrings("a", mopm_pins.unpackDir("https://h/a.tar.gz").?);
    try t.expect(mopm_pins.unpackDir("mopm.tar.gz") == null);
    try t.expect(mopm_pins.unpackDir("https://h/a.zip") == null);
    try t.expect(mopm_pins.unpackDir("https://h/.tar.gz") == null);
    try t.expect(mopm_pins.unpackDir("https://h/") == null);
}

test "every field, header and line that is wrong is refused with its own message" {
    const head = "[mopm.\"0.0.2\"]\n";
    const full = "url = \"" ++ url ++ "\"\nsha256 = \"" ++ h1 ++ "\"\nsize = 10\n";
    try refused("[mopm.\"0.0.2]\n" ++ full, "the version in [mopm.\"0.0.2] is not quoted");
    try refused("[mopm.\"0.0.2\".x]\n" ++ full, "a mopm table has no sub-tables");
    try refused("[mopm.\"1.0\"]\n" ++ full, "mopm \"1.0\" is not an exact release");
    try refused(head ++ full ++ head ++ full, "appears twice");
    try refused(full, "is outside any table");
    try refused(head ++ "no equals here\n", "not `key = value`");
    try refused(head ++ "colour = \"red\"\n" ++ full, "unknown key `colour`");
    try refused(head ++ "url = https://example.org/a.tar.gz\nsha256 = \"" ++ h1 ++ "\"\nsize = 1\n", "url must be a quoted https URL of a .tar.gz");
    try refused(head ++ "url = \"https://example.org/a.zip\"\nsha256 = \"" ++ h1 ++ "\"\nsize = 1\n", "url must be a quoted https URL of a .tar.gz");
    try refused(head ++ "url = \"" ++ url ++ "\"\nsha256 = \"" ++ h1[1..] ++ "\"\nsize = 1\n", "sha256 must be 64 lower-case hex digits in quotes");
    try refused(head ++ "url = \"" ++ url ++ "\"\nsha256 = " ++ h1 ++ "\nsize = 1\n", "sha256 must be 64 lower-case hex digits in quotes");
    try refused(head ++ "url = \"" ++ url ++ "\"\nsha256 = \"" ++ h1 ++ "\"\nsize = abc\n", "size must be the tarball's length");
    try refused(head ++ "url = \"" ++ url ++ "\"\nsha256 = \"" ++ h1 ++ "\"\nsize = 0\n", "size must be the tarball's length");
    try refused(head ++ "url = \"" ++ url ++ "\"\nsha256 = \"" ++ h1 ++ "\"\n", "needs url, sha256 and size");
    try refused(head ++ "url = \"" ++ url ++ "\"\nsize = 1\n", "needs url, sha256 and size");
    try refused(head ++ "sha256 = \"" ++ h1 ++ "\"\nsize = 1\n", "needs url, sha256 and size");
    // The quote and the backslash are the characters that would end the Starlark string they are written into.
    try refused(head ++ "url = \"https://example.org/a\\\".tar.gz\"\nsha256 = \"" ++ h1 ++ "\"\nsize = 1\n", "url must be a quoted https URL");
    try refused(head ++ "url = \"https://example.org/a\"b.tar.gz\"\nsha256 = \"" ++ h1 ++ "\"\nsize = 1\n", "url must be a quoted https URL");
    try refused(head ++ "url = \"\n" ++ "sha256 = \"" ++ h1 ++ "\"\nsize = 1\n", "url must be a quoted https URL");
    try refused(head ++ "url = u\nsha256 = \"" ++ h1 ++ "\"\nsize = 1\n", "url must be a quoted https URL");
}

test "a header with no closing bracket is not this reader's to report (pins_toml.zig does), and the lines under it are outside a table" {
    try refused("[mopm.\"0.0.2\"\nurl = \"" ++ url ++ "\"\n", "is outside any table");
}

/// `good` with a third pin whose URL has a path of `pad` more characters, which is in the output twice (as the URL and in the directory name).
fn paddedPins(a: std.mem.Allocator, pad: usize) ![]u8 {
    const path = try a.alloc(u8, pad);
    @memset(path, 'x');
    return std.fmt.allocPrint(a, "{s}[mopm.\"0.0.4\"]\nurl = \"https://example.org/{s}/mopm-0.0.4.tar.gz\"\nsha256 = \"{s}\"\nsize = 30\n", .{ good, path, h1 });
}

const PinsCall = struct {
    text: []const u8,
    rows: usize,
    pub fn call(self: @This(), a: std.mem.Allocator) !bool {
        var d = Diag.init(a);
        const out = try mopm_pins.render(a, self.text, &d);
        return std.mem.count(u8, out, "\"dir\"") == self.rows;
    }
};

test "out of memory: a failing allocation ends the rendering with an error, never with a shorter file (at every size of the output)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try kit.sweepOom(PinsCall{ .text = "", .rows = 0 }, true);
    var pad: usize = 0;
    while (pad < 400) : (pad += 1) {
        _ = arena.reset(.retain_capacity);
        try kit.sweepOom(PinsCall{ .text = try paddedPins(arena.allocator(), pad), .rows = 3 }, true);
    }
}
