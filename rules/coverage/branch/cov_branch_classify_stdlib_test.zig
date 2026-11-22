//! cov_branch_classify's --stdlib cases (README.md#tests), S1 to S5: the
//! standard library's sources named in either of the two layouts a Mojo
//! toolchain uses (`oss/modular/mojo/stdlib/std/...` in Mojo 1.0,
//! `Mojo/stdlib/std/...` in Mojo 1.1), on fixtures/rules.ll and
//! fixtures/rules_mojo11.ll, which differ only in the standard library
//! file's name. Each runs the shipped executable
//! (cov_branch_classify_harness.zig).

const std = @import("std");
const h = @import("cov_branch_classify_harness.zig");

const OSS = [_][]const u8{ "--stdlib", "oss/modular/", "--exclude", "oss/modular/" };
const MOJO = [_][]const u8{ "--stdlib", "Mojo/stdlib/", "--exclude", "Mojo/stdlib/" };
const REST = [_][]const u8{ "--exclude", "buck-out/", "--exclude-file", "tests/test_a.mojo", "--exclude-file", "<unknown>", "--gen", "gen.mojo" };

/// rules.golden.info's summary line, the same for both layouts.
const SUMMARY = "1 measured file(s): 33 source decision(s) (if 15, elif 0, while 0, and 6, or 2, for-in 10, try 0; 8 right operand(s) derived, 0 and/or result(s) no test reads, 1 a second test of one decision), 26 compiler-made (String lifetime 15, + 0, call( 9, [ 1, // 1, % 0) not written; 0 branch(es) outside the measured sources";

/// rules.ll with the second String last-reference test (d.mojo 6,11)
/// inlined from `Mojo/stdlib/std/os/atomic.mojo`, the first still from
/// `oss/modular/mojo/stdlib/std/os/atomic.mojo`.
fn mixed(c: *h.Case) ![]const u8 {
    var e = try h.Ir.of(c.a(), h.rules_ll);
    try e.insertBefore("!209 = ", &.{
        "!900 = !DIFile(filename: \"Mojo/stdlib/std/os/atomic.mojo\", directory: \"\")",
        "!901 = distinct !DISubprogram(name: \"fetch_sub\", linkageName: \"std::os::atomic::Atomic::fetch_sub\", scope: !900, file: !900, line: 490, type: !238, scopeLine: 490, spFlags: DISPFlagDefinition, unit: !200)",
    });
    try e.subStart("!217 = !DILocation(line: 492, column: 10, scope: !208,", "!217 = !DILocation(line: 492, column: 10, scope: !901,");
    return e.text();
}

// S1. A branch whose String last-reference test is inlined from a
// `Mojo/stdlib/...` file is classified exactly as the same branch inlined
// from `oss/modular/...`: rules_mojo11.ll gives rules.golden.info byte for
// byte, with the summary of rules.ll's run.
test "S1 Mojo 1.1 layout: the same output as the Mojo 1.0 layout" {
    var c = try h.Case.init("Mojo 1.1 layout");
    defer c.deinit();
    try c.write("v.ll", h.rules_mojo11_ll);
    const r = try c.exec(&(h.IO ++ h.MAP ++ MOJO ++ REST));
    try r.exits(0);
    try r.golden(h.rules_golden, "the Mojo 1.1 layout's output differs from fixtures/rules.golden.info");
    try r.says(SUMMARY);
}

// S2. With both prefixes given, both layouts are the standard library in
// one run: one last-reference test from each gives rules.golden.info.
test "S2 both layouts in one run: each taken as the standard library" {
    var c = try h.Case.init("both layouts");
    defer c.deinit();
    try c.write("v.ll", try mixed(&c));
    const r = try c.exec(&(h.IO ++ h.MAP ++ OSS ++ MOJO ++ REST));
    try r.exits(0);
    try r.golden(h.rules_golden, "a layout of the two was not taken as the standard library");
    try r.says(SUMMARY);
}

// S3. A second --stdlib is accepted, in either order, and each prefix
// still gives the output of its own layout's fixture.
test "S3 two --stdlib flags, in either order, on either layout" {
    var c = try h.Case.init("two --stdlib");
    defer c.deinit();
    const both = [_][]const u8{ "--stdlib", "Mojo/stdlib/", "--stdlib", "oss/modular/", "--exclude", "oss/modular/", "--exclude", "Mojo/stdlib/" };
    for ([_][]const u8{ h.rules_ll, h.rules_mojo11_ll }) |ir| {
        try c.write("v.ll", ir);
        const r = try c.exec(&(h.IO ++ h.MAP ++ both ++ REST));
        try r.exits(0);
        try r.golden(h.rules_golden, "two --stdlib flags changed the output");
    }
}

// S4. Only the prefix given is the standard library: with just
// `--stdlib oss/modular/`, a `Mojo/stdlib/` file is not (its String
// last-reference test is refused as it is outside --stdlib), with just
// `--stdlib Mojo/stdlib/` an `oss/modular/` file is not either, and with
// just `--stdlib oss/modular/` the Mojo 1.1 file of a mixed run is not.
test "S4 a layout not given is not the standard library: refused" {
    var c = try h.Case.init("layout not given");
    defer c.deinit();
    const refusal = "src/pkg/d.mojo:6:11: a br at '+=' is neither";
    const only_oss = [_][]const u8{ "--stdlib", "oss/modular/" };
    const only_mojo = [_][]const u8{ "--stdlib", "Mojo/stdlib/" };
    const excl = [_][]const u8{ "--exclude", "oss/modular/", "--exclude", "Mojo/stdlib/" };
    const Run = struct { ir: []const u8, std_args: []const []const u8 };
    const runs = [_]Run{
        .{ .ir = h.rules_mojo11_ll, .std_args = &only_oss },
        .{ .ir = h.rules_ll, .std_args = &only_mojo },
        .{ .ir = try mixed(&c), .std_args = &only_oss },
    };
    for (runs) |x| {
        try c.write("v.ll", x.ir);
        const r = try c.exec(try std.mem.concat(c.a(), []const u8, &.{ &h.IO, &h.MAP, x.std_args, &excl, &REST }));
        try r.exits(1);
        try r.says(refusal);
        try r.nothing_written();
    }
}

// S5. Each --stdlib must end with '/', a second one too; an empty set is
// still refused.
test "S5 a second --stdlib without the trailing '/': exit 2" {
    var c = try h.Case.init("second --stdlib without '/'");
    defer c.deinit();
    try c.write("v.ll", h.rules_ll);
    const r = try c.exec(&(h.IO ++ h.MAP ++ OSS ++ [_][]const u8{ "--stdlib", "Mojo/stdlib" }));
    try r.exits(2);
    try r.says("--stdlib 'Mojo/stdlib' must end with '/'");
    try r.nothing_written();
}
