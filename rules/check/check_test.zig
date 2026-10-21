//! The cases of check.zig: the command is chosen by the first argument, and an unknown or missing one is refused.

const std = @import("std");
const t = std.testing;
const kit = @import("checkkit.zig");

const USAGE = "usage: check run|expect|marker|digest|same|copy|isa [ARGUMENT]...\n";

test "no command is usage on stderr, status 2; --help is usage on stdout, status 0; another word is refused with the usage" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try c.run(&.{}), 2, "", USAGE);
    try kit.expectResult(try c.run(&.{"--help"}), 0, USAGE, "");
    try kit.expectResult(try c.run(&.{"frobnicate"}), 2, "", "check: unknown command frobnicate\n" ++ USAGE);
    try kit.expectResult(try c.run(&.{""}), 2, "", "check: unknown command \n" ++ USAGE);
    // a command name is exact
    try kit.expectResult(try c.run(&.{"Run"}), 2, "", "check: unknown command Run\n" ++ USAGE);
    try kit.expectResult(try c.run(&.{"runs"}), 2, "", "check: unknown command runs\n" ++ USAGE);
    // --help is only the first word
    try kit.expectFailure(try c.run(&.{ "same", "--help" }), 2, "check same: ");
    c.stdout_closed = true;
    try kit.expectResult(try c.run(&.{"--help"}), 1, "", "");
}

test "each command is its own: given nothing, each says what it needs (its own message, status 2)" {
    var c = try kit.Case.init();
    defer c.deinit();
    const cases = [_][2][]const u8{
        .{ "run", "check run: no program: it follows `--`\n" },
        .{ "expect", "check expect: --want is required\n" },
        .{ "marker", "check marker: --out is required\n" },
        .{ "digest", "check digest: usage: check digest [--out FILE] [--stamp TEXT] (EXPECTED FILE NAME)...\n" },
        .{ "same", "check same: usage: check same --out FILE [--stamp TEXT] A B\n" },
        .{ "copy", "check copy: usage: check copy SOURCE DESTINATION\n" },
        .{ "isa", "check isa: usage: check isa --objdump PROGRAM --binary FILE --expect avx2|none --label TEXT --out REPORT\n" },
    };
    for (cases) |case| try kit.expectResult(try c.run(&.{case[0]}), 2, "", case[1]);
}
