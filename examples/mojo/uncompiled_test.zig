//! What `:coverage` does with code no test compiled (rules/coverage/tools/mojo_src.zig), held to the real outputs of two example packages.
//!
//! `uncompiled` has three functions and two tests; `never_called` is called by none. `uncompiled_lean` is the same library with the test of `clamped`
//! deleted. Mojo compiles only the functions a test reaches, so the coverage report has no line and the IR no branch for a function nobody calls; a figure counted
//! from the reports alone would lose the denominator of `clamped` when its test goes and read higher for it. The cases hold: the function nobody calls is
//! found and not hit; deleting the test takes hits away and leaves the denominator where it was (the branch arms) or raises it (the lines: the source has more
//! lines of `clamped` than the compiler gave it records for); the source marked `@generated` is not counted; and the extra files of `:coverage[reports]` and
//! `:coverage[branches]` hold what the summary counted, so a consumer that takes the reports gets the same figure.

const std = @import("std");
const t = std.testing;

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

const Fraction = struct { hit: usize, total: usize };

/// The `<hit>/<total>` of the row that starts with `prefix` (a path, or `total`, or `branches total`...).
fn fractionOf(text: []const u8, prefix: []const u8) !Fraction {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];
        if (rest.len == 0 or rest[0] != ' ') continue;
        const frac = rest[1 .. std.mem.indexOfScalarPos(u8, rest, 1, ' ') orelse rest.len];
        const slash = std.mem.indexOfScalar(u8, frac, '/') orelse continue;
        return .{ .hit = try std.fmt.parseInt(usize, frac[0..slash], 10), .total = try std.fmt.parseInt(usize, frac[slash + 1 ..], 10) };
    }
    return error.NoRow;
}

/// The percentage as parts per ten thousand, so two figures compare without rounding.
fn ratio(f: Fraction) usize {
    return f.hit * 10000 / f.total;
}

const full_src = "examples/mojo/uncompiled/src/uncompiled/__init__.mojo";
const lean_src = "examples/mojo/uncompiled_lean/src/uncompiled_lean/__init__.mojo";

test "the exact figures of both packages: the function nobody calls is found and not hit" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Lines of `uncompiled`: `doubled` 2 and `clamped` 2 are the compiler's records, all hit; `never_called` is 4 lines the source has (the `def`, the `if`, the
    // `raise`, the `return`), none hit. Branches: `clamped`'s `if`, `and` and the right operand of the `and` are the compiler's 6 arms, all taken; `never_called` has an
    // `if`, an `or` and the right operand of the `or`: 6 arms the source has, none taken.
    try t.expectEqualStrings(
        "examples/mojo/uncompiled/src/uncompiled/__init__.mojo 4/8 50%\n" ++
            "examples/mojo/uncompiled/tests/test_clamped.mojo 8/8 100% (not counted)\n" ++
            "examples/mojo/uncompiled/tests/test_doubled.mojo 4/4 100% (not counted)\n" ++
            "total 4/8 50%\n" ++
            "branches examples/mojo/uncompiled/src/uncompiled/__init__.mojo 6/12 50%\n" ++
            "branches total 6/12 50%\n",
        try work(a, "full/coverage.txt"),
    );
    // `uncompiled_lean`: only `doubled` is compiled (2 lines hit); `clamped` and `never_called` are 8 lines and 12 arms the source has, none hit.
    try t.expectEqualStrings(
        "examples/mojo/uncompiled_lean/src/uncompiled_lean/__init__.mojo 2/10 20%\n" ++
            "examples/mojo/uncompiled_lean/tests/test_doubled.mojo 4/4 100% (not counted)\n" ++
            "total 2/10 20%\n" ++
            "branches examples/mojo/uncompiled_lean/src/uncompiled_lean/__init__.mojo 0/12 0%\n" ++
            "branches total 0/12 0%\n",
        try work(a, "lean/coverage.txt"),
    );
}

test "deleting a test lowers the line and branch percentages, and the branch denominator does not move" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const full = try work(a, "full/coverage.txt");
    const lean = try work(a, "lean/coverage.txt");
    const full_lines = try fractionOf(full, "total");
    const lean_lines = try fractionOf(lean, "total");
    const full_branches = try fractionOf(full, "branches total");
    const lean_branches = try fractionOf(lean, "branches total");
    // fewer hits, a percentage that fell: before the lines of a function nobody calls were counted it read the other way round (the deleted test took its
    // lines out of the denominator and the percentage rose)
    try t.expect(lean_lines.hit < full_lines.hit);
    try t.expect(ratio(lean_lines) < ratio(full_lines));
    try t.expect(lean_branches.hit < full_branches.hit);
    try t.expect(ratio(lean_branches) < ratio(full_branches));
    // the denominators: no line is lost (there are lines of `clamped` the compiler gave no record for, so there are more); the branch arms are the same
    try t.expect(lean_lines.total >= full_lines.total);
    try t.expectEqual(full_branches.total, lean_branches.total);
}

test "the lines and arms of the function nobody calls are in the extra files, not hit" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `never_called` is lines 15 to 18 of the library.
    const lines = try work(a, "full/uncompiled.cobertura.xml");
    try t.expect(std.mem.indexOf(u8, lines, "<class name=\"" ++ full_src ++ "\" filename=\"" ++ full_src ++ "\">") != null);
    for ([_][]const u8{ "15", "16", "17", "18" }) |n| {
        const row = try std.fmt.allocPrint(a, "<line number=\"{s}\" hits=\"0\"/>", .{n});
        try t.expect(std.mem.indexOf(u8, lines, row) != null);
    }
    try t.expectEqual(@as(usize, 4), std.mem.count(u8, lines, "<line "));
    // line 16, `    if x < 0 or x > 100:`: the `if` at column 5, the `or` at column 14, and the right operand of the `or`: three decisions of two arms, none taken
    try t.expectEqualStrings(
        "SF:" ++ full_src ++ "\n" ++
            "BRDA:16,5:br:0/1,0,-\n" ++
            "BRDA:16,5:br:0/1,1,-\n" ++
            "BRDA:16,14:br:0/1,0,-\n" ++
            "BRDA:16,14:br:0/1,1,-\n" ++
            "BRDA:16,14:rhs:0/1,0,-\n" ++
            "BRDA:16,14:rhs:0/1,1,-\n" ++
            "end_of_record\n",
        try work(a, "full/uncompiled.branches.info"),
    );
}

test "the source marked @generated is neither asked for in a report nor counted" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `gen.mojo` has a function with an `if` and no test imports it; the package's :coverage is green all the same and says nothing of it.
    for ([_][]const u8{ "full/coverage.txt", "full/uncompiled.cobertura.xml", "full/uncompiled.branches.info", "lean/coverage.txt", "lean/uncompiled.cobertura.xml", "lean/uncompiled.branches.info" }) |f| {
        try t.expect(std.mem.indexOf(u8, try work(a, f), "gen.mojo") == null);
    }
}

/// How many `<line>` records the class for `path` has in `xml`, and how many have hits.
fn classLines(xml: []const u8, path: []const u8, buf: []u8) !Fraction {
    const open = try std.fmt.bufPrint(buf, "<class name=\"{s}\" filename=\"{s}\">", .{ path, path });
    const at = std.mem.indexOf(u8, xml, open) orelse return .{ .hit = 0, .total = 0 };
    const end = std.mem.indexOfPos(u8, xml, at, "</class>") orelse return error.BadRecords;
    var c = Fraction{ .hit = 0, .total = 0 };
    var it = std.mem.splitScalar(u8, xml[at..end], '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "<line ")) continue;
        c.total += 1;
        if (std.mem.indexOf(u8, line, "hits=\"0\"") == null) c.hit += 1;
    }
    return c;
}

fn armsOf(text: []const u8, path: []const u8) !Fraction {
    var c = Fraction{ .hit = 0, .total = 0 };
    var inside = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "SF:")) {
            inside = std.mem.eql(u8, line[3..], path);
        } else if (inside and std.mem.startsWith(u8, line, "BRDA:")) {
            const taken = line[std.mem.lastIndexOfScalar(u8, line, ',').? + 1 ..];
            c.total += 1;
            if (!std.mem.eql(u8, taken, "-") and !std.mem.eql(u8, taken, "0")) c.hit += 1;
        }
    }
    return c;
}

test "a consumer of the reports gets the figure the summary has: the tests' records plus the extra file" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [512]u8 = undefined;
    const summary = try work(a, "lean/coverage.txt");
    const tests = try classLines(try work(a, "lean/reports_of_tests.xml"), lean_src, &buf);
    const extra = try classLines(try work(a, "lean/uncompiled.cobertura.xml"), lean_src, &buf);
    const lines = try fractionOf(summary, lean_src);
    try t.expectEqual(lines.total, tests.total + extra.total);
    try t.expectEqual(lines.hit, tests.hit + extra.hit);
    // and the extra file holds nothing that is hit: what it adds is what no test compiled
    try t.expectEqual(@as(usize, 0), extra.hit);
    const branches = try fractionOf(summary, "branches " ++ lean_src);
    const of_tests = try armsOf(try work(a, "lean/branches_of_tests.info"), lean_src);
    const more = try armsOf(try work(a, "lean/uncompiled.branches.info"), lean_src);
    try t.expectEqual(branches.total, of_tests.total + more.total);
    try t.expectEqual(branches.hit, of_tests.hit + more.hit);
    try t.expectEqual(@as(usize, 0), more.hit);
}
