//! pins.zig: the agreement of the pin rows with the built programs, against planted text: each way the table can be wrong is found, and an agreeing table is not.
const std = @import("std");
const pins = @import("pins.zig");
const t = std.testing;
const a = t.allocator;

const sha_x86 = "1111111111111111111111111111111111111111111111111111111111111111";
const sha_arm = "2222222222222222222222222222222222222222222222222222222222222222";
const sha_mac = "3333333333333333333333333333333333333333333333333333333333333333";

const table =
    \\# comments are not read: UNPACK_TAG = "unpack-99"
    \\UNPACK_TAG = "unpack-7"
    \\
    \\UNPACK_PINS = {
    \\    "linux-x86_64": {
    \\        "url": "https://github.com/komira-ai/buildrules/releases/download/unpack-7/unpack-linux-x86_64",
    \\        "sha256": "1111111111111111111111111111111111111111111111111111111111111111",
    \\        "size": 1000,
    \\    },
    \\    "linux-aarch64": {
    \\        "url": "https://github.com/komira-ai/buildrules/releases/download/unpack-7/unpack-linux-aarch64",
    \\        "sha256": "2222222222222222222222222222222222222222222222222222222222222222",
    \\        "size": 2000,
    \\    },
    \\    "macos-aarch64": {
    \\        "url": "https://github.com/komira-ai/buildrules/releases/download/unpack-7/unpack-macos-aarch64",
    \\        "sha256": "3333333333333333333333333333333333333333333333333333333333333333",
    \\        "size": 3000,
    \\    },
    \\}
    \\
;

fn built() [3]pins.Built {
    return .{
        .{ .host = "linux-x86_64", .sha256 = sha_x86[0..64].*, .size = 1000 },
        .{ .host = "linux-aarch64", .sha256 = sha_arm[0..64].*, .size = 2000 },
        .{ .host = "macos-aarch64", .sha256 = sha_mac[0..64].*, .size = 3000 },
    };
}

fn mutate(text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, text, from) orelse return error.MutantAnchorMissing;
    return std.mem.concat(a, u8, &.{ text[0..at], to, text[at + from.len ..] });
}

fn expectFinding(text: []const u8, b: []const pins.Built, want: []const u8) !void {
    var f = try pins.check(a, text, b);
    defer {
        for (f.items) |x| a.free(x);
        f.deinit(a);
    }
    for (f.items) |x| {
        if (std.mem.indexOf(u8, x, want) != null) return;
    }
    std.debug.print("no finding with `{s}`; got {d}:\n", .{ want, f.items.len });
    for (f.items) |x| std.debug.print("  {s}\n", .{x});
    return error.TestExpectedFinding;
}

test "a table that agrees with the built programs has no finding" {
    var f = try pins.check(a, table, &built());
    defer f.deinit(a);
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "the tag and the rows are read from the text, and comments are not" {
    try t.expectEqualStrings("unpack-7", pins.tag(table).?);
    const r = pins.row(table, "linux-aarch64").?;
    try t.expectEqualStrings("2222222222222222222222222222222222222222222222222222222222222222", r.sha256);
    try t.expectEqualStrings("2000", r.size);
    try t.expect(pins.row(table, "freebsd-x86_64") == null);
    try t.expect(pins.tag("no tag here") == null);
}

test "a built program that is not the pinned one is found, naming both" {
    var b = built();
    b[0].sha256[0] = '9';
    try expectFinding(table, &b, "linux-x86_64: this tree builds unpack with sha256 9111");
    var c = built();
    c[2].size = 3001;
    try expectFinding(table, &c, "macos-aarch64: this tree builds unpack");
    const m = try mutate(table, sha_arm, "4" ** 64);
    defer a.free(m);
    try expectFinding(m, &built(), "linux-aarch64: this tree builds unpack");
    const sz = try mutate(table, "\"size\": 2000", "\"size\": 2002");
    defer a.free(sz);
    try expectFinding(sz, &built(), "linux-aarch64: this tree builds unpack");
}

test "a host with no built program to compare is found" {
    const b = built();
    try expectFinding(table, b[0..2], "macos-aarch64: no program was built");
}

test "a malformed table is found" {
    const no_tag = try mutate(table, "UNPACK_TAG = \"unpack-7\"", "UNPACK_TAG = \"v7\"");
    defer a.free(no_tag);
    try expectFinding(no_tag, &built(), "UNPACK_TAG is \"v7\"");
    const empty_tag = try mutate(table, "UNPACK_TAG = \"unpack-7\"", "UNPACK_TAG = \"unpack-\"");
    defer a.free(empty_tag);
    try expectFinding(empty_tag, &built(), "UNPACK_TAG is \"unpack-\"");
    const tag_letters = try mutate(table, "UNPACK_TAG = \"unpack-7\"", "UNPACK_TAG = \"unpack-7a\"");
    defer a.free(tag_letters);
    try expectFinding(tag_letters, &built(), "UNPACK_TAG is \"unpack-7a\"");
    const missing_row = try mutate(table, "\"macos-aarch64\": {", "\"macos-arm64\": {");
    defer a.free(missing_row);
    try expectFinding(missing_row, &built(), "no row for macos-aarch64");
    // a url that is not the tag's asset of the host
    const wrong_host = try mutate(table, "unpack-7/unpack-linux-aarch64", "unpack-7/unpack-linux-x86_64");
    defer a.free(wrong_host);
    try expectFinding(wrong_host, &built(), "the url of linux-aarch64 is");
    const old_tag = try mutate(table, "download/unpack-7/unpack-macos-aarch64", "download/unpack-6/unpack-macos-aarch64");
    defer a.free(old_tag);
    try expectFinding(old_tag, &built(), "the url of macos-aarch64 is");
    const off_github = try mutate(table, "https://github.com/komira-ai/buildrules/releases", "https://example.invalid/releases");
    defer a.free(off_github);
    try expectFinding(off_github, &built(), "the url of linux-x86_64 is");
    const upper = try mutate(table, sha_x86, "A" ** 64);
    defer a.free(upper);
    try expectFinding(upper, &built(), "the sha256 of linux-x86_64 is not 64 lower-case hex digits");
    const short = try mutate(table, sha_arm, "22");
    defer a.free(short);
    try expectFinding(short, &built(), "the sha256 of linux-aarch64 is not 64");
    const zero = try mutate(table, "\"size\": 3000", "\"size\": 0");
    defer a.free(zero);
    try expectFinding(zero, &built(), "the size of macos-aarch64 is not a positive number");
    const words = try mutate(table, "\"size\": 1000", "\"size\": big");
    defer a.free(words);
    try expectFinding(words, &built(), "the size of linux-x86_64 is not a positive number");
    const nosize = try mutate(table, "        \"size\": 2000,\n", "");
    defer a.free(nosize);
    try expectFinding(nosize, &built(), "the size of linux-aarch64 is not a positive number");
}

test "reading the table: comments, blank lines, a key with no value, a host name too long to look up, a last row with no closing line" {
    try t.expect(pins.row(table, "x" ** 100) == null);
    try t.expect(pins.tag("# UNPACK_TAG = \"unpack-1\"\n\nUNPACK_TAG = unpack-1\n") == null);
    try t.expectEqualStrings("unpack-2", pins.tag("\n\n  # UNPACK_TAG = \"unpack-1\"\nUNPACK_TAG = \"unpack-2\"\n").?);
    const open = "UNPACK_PINS = {\n    \"linux-x86_64\": {\n        \"url\": \"u\",\n        \"sha256\": \"s\",\n        \"size\": 7";
    const r = pins.row(open, "linux-x86_64").?;
    try t.expectEqualStrings("7", r.size);
    try t.expectEqualStrings("u", r.url);
    // a row with no url, sha256 or size line reads as empty values
    const bare = pins.row("    \"linux-x86_64\": {\n    },\n", "linux-x86_64").?;
    try t.expectEqualStrings("", bare.url);
    try t.expectEqualStrings("", bare.sha256);
    try t.expectEqualStrings("", bare.size);
    // a quoted key with an opening quote and no closing one has no value
    try t.expect(pins.row("    \"linux-x86_64\": {\n        \"url\": \"unterminated,\n    },\n", "linux-x86_64").?.url.len == 0);
}

test "a host whose table row is missing is found once, and does not also report a missing program" {
    const without = try mutate(table, "\"linux-aarch64\": {", "\"linux-arm\": {");
    defer a.free(without);
    var f = try pins.check(a, without, &built());
    defer {
        for (f.items) |x| a.free(x);
        f.deinit(a);
    }
    var rows: usize = 0;
    for (f.items) |x| {
        if (std.mem.indexOf(u8, x, "no row for linux-aarch64") != null) rows += 1;
        try t.expect(std.mem.indexOf(u8, x, "no program was built") == null);
    }
    try t.expectEqual(@as(usize, 1), rows);
}
