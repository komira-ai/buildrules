//! buildrules-pins.toml -> toolchains/rust_pins.bzl. Each test names the defect it catches: a pin that is accepted
//! with a missing or malformed hash (the toolchain would download something nobody reviewed, or fail late), and a
//! rendering that depends on the order of the file (the generated file must be byte-stable).

const std = @import("std");
const pins_toml = @import("pins_toml.zig");
const Diag = @import("diag.zig").Diag;
const t = std.testing;

const h1 = "1111111111111111111111111111111111111111111111111111111111111111";
const h2 = "2222222222222222222222222222222222222222222222222222222222222222";
const h3 = "3333333333333333333333333333333333333333333333333333333333333333";
const h4 = "4444444444444444444444444444444444444444444444444444444444444444";

const good =
    "# a pin of my own\n" ++
    "[rust.\"1.86.0\"]\n" ++
    "[rust.\"1.86.0\".rustc]\n" ++
    "sha256 = \"" ++ h1 ++ "\"\n" ++
    "size = 100\n" ++
    "[rust.\"1.86.0\".rust-std]\n" ++
    "sha256 = \"" ++ h2 ++ "\"\n" ++
    "size = 200\n" ++
    "[rust.\"1.86.0\".cargo]\n" ++
    "sha256 = \"" ++ h3 ++ "\"\n" ++
    "size = 300\n" ++
    "[rust.\"1.86.0\".clippy]\n" ++
    "sha256 = \"" ++ h4 ++ "\"\n" ++
    "size = 400\n";

fn refused(text: []const u8, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d = Diag.init(arena.allocator());
    if (pins_toml.render(arena.allocator(), text, &d)) |_| {
        return error.AcceptedABadFile;
    } else |_| {}
    for (d.msgs.items) |m| if (std.mem.indexOf(u8, m, needle) != null) return;
    std.debug.print("no message names `{s}`; got:\n", .{needle});
    for (d.msgs.items) |m| std.debug.print("  {s}\n", .{m});
    return error.WrongMessage;
}

test "a complete pin renders as the data rust_toolchains(extra = ...) and the generator read" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d = Diag.init(arena.allocator());
    const out = try pins_toml.render(arena.allocator(), good, &d);
    const want = pins_toml.header ++
        "EXTRA_RUST_VERSIONS = {\n" ++
        "    \"1.86.0\": {\n" ++
        "        \"rustc\": {\"sha256\": \"" ++ h1 ++ "\", \"size\": 100},\n" ++
        "        \"rust_std\": {\"sha256\": \"" ++ h2 ++ "\", \"size\": 200},\n" ++
        "        \"cargo\": {\"sha256\": \"" ++ h3 ++ "\", \"size\": 300},\n" ++
        "        \"clippy\": {\"sha256\": \"" ++ h4 ++ "\", \"size\": 400},\n" ++
        "    },\n" ++
        "}\n";
    try t.expectEqualStrings(want, out);
}

test "no file renders the empty table, so a repository without pins has a stable rust_pins.bzl" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d = Diag.init(arena.allocator());
    try t.expectEqualStrings(pins_toml.empty, try pins_toml.render(arena.allocator(), "", &d));
    try t.expectEqualStrings(pins_toml.empty, try pins_toml.render(arena.allocator(), "# only a comment\n\n", &d));
}

test "versions come out sorted whatever the file's order (the generated file is byte-stable)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d = Diag.init(arena.allocator());
    const second = try std.mem.replaceOwned(u8, arena.allocator(), good, "1.86.0", "1.80.1");
    const both = try std.mem.concat(arena.allocator(), u8, &.{ good, second });
    const out = try pins_toml.render(arena.allocator(), both, &d);
    const at_80 = std.mem.indexOf(u8, out, "\"1.80.1\"").?;
    const at_86 = std.mem.indexOf(u8, out, "\"1.86.0\"").?;
    try t.expect(at_80 < at_86);
}

test "a component without its hash or size is refused (a pin is all four tarballs, each by sha256 and size)" {
    const no_clippy = good[0 .. std.mem.indexOf(u8, good, "[rust.\"1.86.0\".clippy]").?];
    try refused(no_clippy, "component clippy needs both sha256 and size");
    const no_size = try std.mem.replaceOwned(u8, t.allocator, good, "size = 300\n", "");
    defer t.allocator.free(no_size);
    try refused(no_size, "component cargo needs both sha256 and size");
}

test "a malformed hash or size is refused" {
    const bad_hash = try std.mem.replaceOwned(u8, t.allocator, good, h1, "ABCDEF");
    defer t.allocator.free(bad_hash);
    try refused(bad_hash, "sha256 is not 64 lower-case hex digits");
    const zero = try std.mem.replaceOwned(u8, t.allocator, good, "size = 100", "size = 0");
    defer t.allocator.free(zero);
    try refused(zero, "size must be");
}

test "a floating version, an unknown table, key or component is refused" {
    const floating = try std.mem.replaceOwned(u8, t.allocator, good, "1.86.0", "stable");
    defer t.allocator.free(floating);
    try refused(floating, "is not an exact release");
    try refused("[zig.\"0.14.0\"]\n", "unknown table");
    try refused("[rust.\"1.86.0\"]\nchannel = \"x\"\n", "unknown key `channel`");
    try refused("[rust.\"1.86.0\"]\n[rust.\"1.86.0\".llvm-tools]\n", "unknown component");
    try refused("sha256 = \"x\"\n", "outside any");
}

test "the same version twice is refused (which hashes would win?)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const twice = try std.mem.concat(arena.allocator(), u8, &.{ good, "[rust.\"1.86.0\"]\n" });
    try refused(twice, "appears twice");
}

test "a quote or backslash in a value cannot reach the generated Starlark" {
    // the hash check rejects it before it is written into the file.
    try refused("[rust.\"1.86.0\"]\n[rust.\"1.86.0\".rustc]\nsha256 = \"a\\\" + x\"\n", "sha256 must be a quoted string");
}

test "a date key is refused: the tarballs are fetched from versioned URLs, and a pin file that still carries a date is out of date" {
    try refused("[rust.\"1.86.0\"]\ndate = \"d\"\n", "unknown key `date`");
}
