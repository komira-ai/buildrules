//! Unit tests of branch_lcov.zig (the branch records of a Mojo package's tests, read and summed by id) and of the branch listing cov_summary
//! builds from them (`cov_summary --branch-lcov`). Each test says what it holds the code to.

const std = @import("std");
const L = @import("branch_lcov.zig");
const S = @import("cov_summary.zig");
const t = std.testing;

/// One file, two decisions: `if` at 3:5 (one arm taken once, the other never), and a `select` pair at 9:7 whose first decision ran once on
/// its first arm and whose second never ran (`-`).
const ONE =
    \\SF:src/p/a.mojo
    \\BRDA:3,5:br:0/1,0,0
    \\BRDA:3,5:br:0/1,1,2
    \\BRDA:9,7:select:0/2,0,1
    \\BRDA:9,7:select:0/2,1,0
    \\BRDA:9,7:select:1/2,0,-
    \\BRDA:9,7:select:1/2,1,-
    \\end_of_record
    \\
;

fn parseOk(a: std.mem.Allocator, text: []const u8) ![]L.File {
    var d = L.Diag{};
    return L.parse(a, &d, text, "t.info") catch |e| {
        std.debug.print("refused: {s}\n", .{d.msg});
        return e;
    };
}

fn refusedWith(text: []const u8, msg: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d = L.Diag{};
    if (L.parse(arena.allocator(), &d, text, "t.info")) |_| {
        std.debug.print("accepted, want a refusal holding '{s}':\n{s}\n", .{ msg, text });
        return error.TestUnexpectedResult;
    } else |e| {
        try t.expectEqual(error.Refused, e);
        if (std.mem.indexOf(u8, d.msg, msg) == null) {
            std.debug.print("refused with '{s}', want it to hold '{s}'\n", .{ d.msg, msg });
            return error.TestUnexpectedResult;
        }
    }
}

test "a record file is read: files by path, branches by key, `-` as 0, in the order written" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const files = try parseOk(arena.allocator(), ONE);
    try t.expectEqual(@as(usize, 1), files.len);
    try t.expectEqualStrings("src/p/a.mojo", files[0].path);
    const b = files[0].branches;
    try t.expectEqual(@as(usize, 6), b.count());
    try t.expectEqual(@as(u64, 0), b.get("3,5:br:0/1,0").?);
    try t.expectEqual(@as(u64, 2), b.get("3,5:br:0/1,1").?);
    try t.expectEqual(@as(u64, 1), b.get("9,7:select:0/2,0").?);
    try t.expectEqual(@as(u64, 0), b.get("9,7:select:1/2,1").?);
    try t.expectEqualStrings("3,5:br:0/1,0", b.keys()[0]);
}

test "numbers are keyed as numbers: leading zeros do not make a second key" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const files = try parseOk(arena.allocator(), "SF:a\nBRDA:03,05:br:00/01,00,1\nBRDA:3,5:br:0/1,1,1\nend_of_record\n");
    try t.expectEqual(@as(usize, 2), files[0].branches.count());
    try t.expect(files[0].branches.contains("3,5:br:0/1,0"));
}

test "an empty file holds no record; a file with a record and no decision names the file alone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(@as(usize, 0), (try parseOk(a, "")).len);
    const f = try parseOk(a, "SF:src/p/b.mojo\nend_of_record\n");
    try t.expectEqual(@as(usize, 1), f.len);
    try t.expectEqual(@as(usize, 0), f[0].branches.count());
    // The last newline is optional.
    try t.expectEqual(@as(usize, 1), (try parseOk(a, "SF:x\nend_of_record")).len);
}

test "a switch has two arms or more; the other kinds have two" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try parseOk(a, "SF:a\nBRDA:1,1:switch:0/1,0,1\nBRDA:1,1:switch:0/1,1,0\nBRDA:1,1:switch:0/1,2,0\nend_of_record\n");
    for ([_][]const u8{ "br", "select", "try", "rhs" }) |kind| {
        const ok = try std.fmt.allocPrint(a, "SF:a\nBRDA:1,1:{s}:0/1,0,1\nBRDA:1,1:{s}:0/1,1,0\nend_of_record\n", .{ kind, kind });
        _ = try parseOk(a, ok);
        const three = try std.fmt.allocPrint(a, "SF:a\nBRDA:1,1:{s}:0/1,0,1\nBRDA:1,1:{s}:0/1,1,0\nBRDA:1,1:{s}:0/1,2,0\nend_of_record\n", .{ kind, kind, kind });
        try refusedWith(three, "has 3 arms, not 2");
    }
    try refusedWith("SF:a\nBRDA:1,1:switch:0/1,0,1\nend_of_record\n", "has 1 arms, not 2 or more");
}

test "each malformed record is refused, naming the file and line and the fault" {
    const cases = [_]struct { text: []const u8, msg: []const u8 }{
        .{ .text = "SF:a\r\nend_of_record\r\n", .msg = "t.info:1: carriage return" },
        .{ .text = "SF:a\n\nend_of_record\n", .msg = "t.info:2: not a record: ''" },
        .{ .text = "\n", .msg = "t.info:1: not a record" },
        .{ .text = "nocolon\n", .msg = "t.info:1: not a record: 'nocolon'" },
        .{ .text = ":x\n", .msg = "not a record" },
        .{ .text = "SF:a\nDA:1,1\nend_of_record\n", .msg = "t.info:2: 'DA' record in a branch record file" },
        .{ .text = "SF:a\nLF:1\nend_of_record\n", .msg = "'LF' record" },
        .{ .text = "BRDA:1,1:br:0/1,0,1\n", .msg = "t.info:1: BRDA outside SF .. end_of_record" },
        .{ .text = "end_of_record\n", .msg = "t.info:1: end_of_record outside a record" },
        .{ .text = "SF:a\nend_of_record\nBRDA:1,1:br:0/1,0,1\n", .msg = "t.info:3: BRDA outside SF" },
        .{ .text = "SF:a\nSF:b\n", .msg = "t.info:2: SF before the end_of_record of the previous file" },
        .{ .text = "SF:\nend_of_record\n", .msg = "t.info:1: SF names no file" },
        .{ .text = "SF:a\nend_of_record\nSF:a\nend_of_record\n", .msg = "t.info:3: SF a is named a second time" },
        .{ .text = "SF:a\nBRDA:1,1:br:0/1,0,1\n", .msg = "t.info:2: the last record has no end_of_record" },
        .{ .text = "SF:a\n", .msg = "t.info:1: the last record has no end_of_record" },
        .{ .text = "SF:a\nBRDA:1,1:br:0/1,0\nend_of_record\n", .msg = "BRDA needs <line>,<col>:<kind>:<n>/<N>,<arm>,<taken|-> (4 fields), not 3" },
        .{ .text = "SF:a\nBRDA:1,1:br:0/1,0,1,9\nend_of_record\n", .msg = "(4 fields), not 5" },
        .{ .text = "SF:a\nBRDA:1,1:br,0,1\nend_of_record\n", .msg = "block '1:br' is not <col>:<kind>:<n>/<N>" },
        .{ .text = "SF:a\nBRDA:1,1-br:0/1,0,1\nend_of_record\n", .msg = "block '1-br:0/1' is not <col>:<kind>:<n>/<N>" },
        .{ .text = "SF:a\nBRDA:1,br:0/1,0,1\nend_of_record\n", .msg = "block 'br:0/1' is not <col>:<kind>:<n>/<N>" },
        .{ .text = "SF:a\nBRDA:1,1:br:0/1:x,0,1\nend_of_record\n", .msg = "is not <col>:<kind>:<n>/<N>" },
        .{ .text = "SF:a\nBRDA:1,1:loop:0/1,0,1\nend_of_record\n", .msg = "kind 'loop' is not br, select, switch, try or rhs" },
        .{ .text = "SF:a\nBRDA:1,1:br:01,0,1\nend_of_record\n", .msg = "decision '01' is not <n>/<N>" },
        .{ .text = "SF:a\nBRDA:1,1:br:0/1/2,0,1\nend_of_record\n", .msg = "decision '0/1/2' is not <n>/<N>" },
        .{ .text = "SF:a\nBRDA:0,1:br:0/1,0,1\nend_of_record\n", .msg = "BRDA line 0 is below 1" },
        .{ .text = "SF:a\nBRDA:1,0:br:0/1,0,1\nend_of_record\n", .msg = "BRDA column 0 is below 1" },
        .{ .text = "SF:a\nBRDA:1000000001,1:br:0/1,0,1\nend_of_record\n", .msg = "BRDA line 1000000001 is above 10^9" },
        .{ .text = "SF:a\nBRDA:1,1000000001:br:0/1,0,1\nend_of_record\n", .msg = "BRDA column 1000000001 is above 10^9" },
        .{ .text = "SF:a\nBRDA:x,1:br:0/1,0,1\nend_of_record\n", .msg = "BRDA line 'x' is not a decimal number" },
        .{ .text = "SF:a\nBRDA:-1,1:br:0/1,0,1\nend_of_record\n", .msg = "BRDA line '-1' is not a decimal number" },
        .{ .text = "SF:a\nBRDA:1234567890123456789,1:br:0/1,0,1\nend_of_record\n", .msg = "is not a decimal number" },
        .{ .text = "SF:a\nBRDA:1,1:br:1/1,0,1\nend_of_record\n", .msg = "BRDA decision 1/1: <n> must be below <N>" },
        .{ .text = "SF:a\nBRDA:1,1:br:0/0,0,1\nend_of_record\n", .msg = "BRDA decision count 0 is below 1" },
        .{ .text = "SF:a\nBRDA:1,1:br:0/1,x,1\nend_of_record\n", .msg = "BRDA arm 'x' is not a decimal number" },
        .{ .text = "SF:a\nBRDA:1,1:br:0/1,0,x\nend_of_record\n", .msg = "BRDA taken 'x' is not a decimal number or -" },
        .{ .text = "SF:a\nBRDA:1,1:br:0/1,0,\nend_of_record\n", .msg = "BRDA taken '' is not a decimal number or -" },
        .{ .text = "SF:a\nBRDA:1,1:br:0/1,0,1\nBRDA:1,1:br:0/1,0,1\nend_of_record\n", .msg = "BRDA 1,1:br:0/1,0 is given twice in one record" },
        .{ .text = "SF:a\nBRDA:1,1:br:0/2,0,1\nBRDA:1,1:br:1/3,0,1\nend_of_record\n", .msg = "the location 1,1:br has 2 decisions in an earlier record line, not 3" },
        .{ .text = "SF:a\nBRDA:1,1:br:0/1,0,1\nBRDA:1,1:br:0/1,2,1\nend_of_record\n", .msg = "the arms of 1,1:br:0/1 are not 0 to 1 (highest 2)" },
        .{ .text = "SF:a\nBRDA:1,1:br:0/1,0,1\nend_of_record\n", .msg = "1,1:br:0/1 has 1 arms, not 2" },
        .{ .text = "SF:a\nBRDA:1,1:br:0/2,0,1\nBRDA:1,1:br:0/2,1,1\nend_of_record\n", .msg = "the location 1,1:br has 1 of its 2 decisions" },
    };
    for (cases) |cs| try refusedWith(cs.text, cs.msg);
}

test "the decisions of a location may be written in any order and the arms of a decision apart" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const f = try parseOk(arena.allocator(), "SF:a\nBRDA:1,1:br:1/2,1,1\nBRDA:1,1:br:0/2,0,1\nBRDA:1,1:br:1/2,0,1\nBRDA:1,1:br:0/2,1,1\nend_of_record\n");
    try t.expectEqual(@as(usize, 4), f[0].branches.count());
}

fn sumOf(a: std.mem.Allocator, d: *L.Diag, texts: []const []const u8) !L.Sum {
    var sum = L.Sum{};
    for (texts, 0..) |text, i| try sum.add(a, d, text, try std.fmt.allocPrint(a, "test{d}.info", .{i}));
    return sum;
}

test "the records of several tests are summed by id: an arm is hit when any test took it, `-` adds nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = L.Diag{};
    // Test 1 is ONE. Test 2 takes the br's first arm and the second select decision's second arm, and has a file test 1 lacks.
    const two =
        \\SF:src/p/a.mojo
        \\BRDA:3,5:br:0/1,0,4
        \\BRDA:3,5:br:0/1,1,0
        \\BRDA:9,7:select:0/2,0,-
        \\BRDA:9,7:select:0/2,1,-
        \\BRDA:9,7:select:1/2,0,0
        \\BRDA:9,7:select:1/2,1,5
        \\end_of_record
        \\SF:src/p/b.mojo
        \\BRDA:2,3:br:0/1,0,0
        \\BRDA:2,3:br:0/1,1,0
        \\end_of_record
        \\
    ;
    const sum = try sumOf(a, &d, &.{ ONE, two });
    const counts = try sum.counts(a);
    try t.expectEqual(@as(usize, 2), counts.len);
    // a.mojo: br arm 0 (0+4) and arm 1 (2+0), select 0/2 arm 0 (1+-) and select 1/2 arm 1 (-+5) are hit; six arms in all, four hit.
    try t.expectEqualStrings("src/p/a.mojo", counts[0].path);
    try t.expectEqual(@as(usize, 4), counts[0].hit);
    try t.expectEqual(@as(usize, 6), counts[0].total);
    try t.expectEqualStrings("src/p/b.mojo", counts[1].path);
    try t.expectEqual(@as(usize, 0), counts[1].hit);
    try t.expectEqual(@as(usize, 2), counts[1].total);
}

test "an arm a test did not give is never a pass: the total is the union of the arms the tests give" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = L.Diag{};
    // The second test gives an `rhs` decision at the same line the first does not, taken once.
    const first = "SF:a\nBRDA:1,1:br:0/1,0,1\nBRDA:1,1:br:0/1,1,0\nend_of_record\n";
    const second = "SF:a\nBRDA:1,1:br:0/1,0,1\nBRDA:1,1:br:0/1,1,0\nBRDA:1,1:rhs:0/1,0,0\nBRDA:1,1:rhs:0/1,1,0\nend_of_record\n";
    const counts = try (try sumOf(a, &d, &.{ first, second })).counts(a);
    try t.expectEqual(@as(usize, 1), counts[0].hit);
    try t.expectEqual(@as(usize, 4), counts[0].total);
}

test "a count is saturated, never wrapped, when tests are summed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = L.Diag{};
    const big = "SF:a\nBRDA:1,1:br:0/1,0,999999999999999999\nBRDA:1,1:br:0/1,1,0\nend_of_record\n";
    const sum = try sumOf(a, &d, &.{ big, big, big, big, big, big, big, big, big, big, big, big, big, big, big, big, big, big, big, big });
    try t.expectEqual(@as(usize, 1), (try sum.counts(a))[0].hit);
    try t.expect(sum.files.get("a").?.get("1,1:br:0/1,0").? >= 999999999999999999);
}

test "two tests that give one location another number of decisions are refused, naming both" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = L.Diag{};
    var sum = L.Sum{};
    try sum.add(a, &d, "SF:src/p/a.mojo\nBRDA:7,3:br:0/1,0,1\nBRDA:7,3:br:0/1,1,0\nend_of_record\n", "one.info");
    try t.expectError(error.Refused, sum.add(a, &d, "SF:src/p/a.mojo\nBRDA:7,3:br:0/2,0,1\nBRDA:7,3:br:0/2,1,0\nBRDA:7,3:br:1/2,0,1\nBRDA:7,3:br:1/2,1,0\nend_of_record\n", "two.info"));
    try t.expectEqualStrings("src/p/a.mojo:7: one.info gives 1 decision(s) at 3:br and two.info gives 2: the tests' copies of this code hold different decisions at one location, so their branch records cannot be summed by id", d.msg);
}

test "two tests that give one decision another number of arms are refused, naming both" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = L.Diag{};
    var sum = L.Sum{};
    try sum.add(a, &d, "SF:a\nBRDA:7,3:switch:0/1,0,1\nBRDA:7,3:switch:0/1,1,0\nend_of_record\n", "one.info");
    try t.expectError(error.Refused, sum.add(a, &d, "SF:a\nBRDA:7,3:switch:0/1,0,1\nBRDA:7,3:switch:0/1,1,0\nBRDA:7,3:switch:0/1,2,0\nend_of_record\n", "two.info"));
    try t.expectEqualStrings("a:7: one.info gives the decision 7,3:switch:0/1 2 arms and two.info gives it 3: its branch records cannot be summed by id", d.msg);
}

test "the same shape in two tests, and the same location in two files, are not a disagreement" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = L.Diag{};
    // The same line and column in another file has its own count of decisions.
    const sum = try sumOf(a, &d, &.{
        "SF:a\nBRDA:7,3:br:0/1,0,1\nBRDA:7,3:br:0/1,1,0\nend_of_record\nSF:b\nBRDA:7,3:br:0/2,0,1\nBRDA:7,3:br:0/2,1,0\nBRDA:7,3:br:1/2,0,1\nBRDA:7,3:br:1/2,1,0\nend_of_record\n",
        "SF:a\nBRDA:7,3:br:0/1,0,1\nBRDA:7,3:br:0/1,1,1\nend_of_record\n",
    });
    try t.expectEqual(@as(usize, 2), sum.files.count());
}

test "a refused file leaves its reason in the diagnostic and reads no further" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d = L.Diag{};
    var sum = L.Sum{};
    try t.expectError(error.Refused, sum.add(arena.allocator(), &d, "SF:a\nDA:1,1\nend_of_record\n", "bad.info"));
    try t.expect(std.mem.startsWith(u8, d.msg, "bad.info:2: "));
    try t.expectEqual(@as(usize, 0), sum.files.count());
}

/// Reads two record files, counts, then reads one that is refused (the refusal allocates its message too).
fn sweepRun(a: std.mem.Allocator, d: *L.Diag, sum: *L.Sum) L.Error!void {
    try sum.add(a, d, ONE, "one.info");
    try sum.add(a, d, "SF:b\nBRDA:2,3:br:0/1,0,0\nBRDA:2,3:br:0/1,1,0\nend_of_record\n", "two.info");
    _ = try sum.counts(a);
    try sum.add(a, d, "SF:a\nDA:1\nend_of_record\n", "bad.info");
}

test "every allocation of reading, summing and counting may fail, and fails as OutOfMemory" {
    var i: usize = 0;
    var finished = false;
    while (i < 4000 and !finished) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var fa = t.FailingAllocator.init(arena.allocator(), .{ .fail_index = i });
        var d = L.Diag{};
        var sum = L.Sum{};
        // Every run ends in the refusal unless an allocation failed first.
        sweepRun(fa.allocator(), &d, &sum) catch |e| {
            if (e == error.Refused) finished = true else try t.expectEqual(error.OutOfMemory, e);
        };
    }
    try t.expect(finished);
}

// ---- the branch listing cov_summary builds ----------------------------------------------------------------------------------------------

const Row = struct { []const u8, usize, usize };

/// The line rows of a package: path, lines hit, lines recorded.
fn lineRows(a: std.mem.Allocator, rows: []const Row) ![]const S.FileCov {
    const out = try a.alloc(S.FileCov, rows.len);
    for (rows, out) |r, *o| o.* = .{ .path = r[0], .hit = r[1], .total = r[2] };
    return out;
}

test "the listing: branch rows by path, the total over the expected sources, the others marked not counted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try lineRows(a, &.{ .{ "src/p/a.mojo", 3, 4 }, .{ "tests/test_a.mojo", 5, 5 } });
    const got = try S.branchListing(a, &.{"one.info"}, &.{ONE}, lines, &.{"src/p/a.mojo"});
    try t.expectEqualStrings("branches src/p/a.mojo 2/6 33%\nbranches total 2/6 33%\n", got.text);
}

test "an expected source with no line and no record is 0/0; one with lines and no record is refused, naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try lineRows(a, &.{ .{ "src/p/__init__.mojo", 0, 0 }, .{ "src/p/a.mojo", 3, 4 }, .{ "src/p/b.mojo", 2, 2 } });
    const ok = try S.branchListing(a, &.{"one.info"}, &.{ONE}, lines[0..2], &.{ "src/p/__init__.mojo", "src/p/a.mojo" });
    try t.expectEqualStrings("branches src/p/__init__.mojo 0/0 0%\nbranches src/p/a.mojo 2/6 33%\nbranches total 2/6 33%\n", ok.text);
    const bad = try S.branchListing(a, &.{"one.info"}, &.{ONE}, lines, &.{ "src/p/a.mojo", "src/p/b.mojo" });
    try t.expectEqualStrings("src/p/b.mojo is in no branch record: its tests ran no code of it, or the classifier found none", bad.refused);
}

test "records of no test at all give every expected source 0/0 when none has a line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try lineRows(a, &.{.{ "src/p/a.mojo", 0, 0 }});
    const got = try S.branchListing(a, &.{ "one.info", "two.info" }, &.{ "", "" }, lines, &.{"src/p/a.mojo"});
    try t.expectEqualStrings("branches src/p/a.mojo 0/0 0%\nbranches total 0/0 0%\n", got.text);
}

test "a file the records name that is not expected is listed and not counted; rows are sorted by path" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lines = try lineRows(a, &.{.{ "src/p/a.mojo", 3, 4 }});
    const text = "SF:src/p/z.mojo\nBRDA:1,1:br:0/1,0,1\nBRDA:1,1:br:0/1,1,1\nend_of_record\n" ++ ONE;
    const got = try S.branchListing(a, &.{"one.info"}, &.{text}, lines, &.{"src/p/a.mojo"});
    try t.expectEqualStrings("branches src/p/a.mojo 2/6 33%\nbranches src/p/z.mojo 2/2 100% (not counted)\nbranches total 2/6 33%\n", got.text);
}

test "a record file that is refused is refused with its reason, not an error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const lines = try lineRows(arena.allocator(), &.{.{ "a", 1, 1 }});
    const got = try S.branchListing(arena.allocator(), &.{"bad.info"}, &.{"SF:a\nBRDA:1\nend_of_record\n"}, lines, &.{"a"});
    try t.expect(std.mem.startsWith(u8, got.refused, "bad.info:2: BRDA needs"));
}

test "branchListing and branchRows fail as OutOfMemory when an allocation fails" {
    var i: usize = 0;
    var finished = false;
    while (i < 4000 and !finished) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        var fa = t.FailingAllocator.init(arena.allocator(), .{ .fail_index = i });
        const lines = try lineRows(arena.allocator(), &.{ .{ "src/p/a.mojo", 3, 4 }, .{ "src/p/c.mojo", 0, 0 } });
        if (S.branchListing(fa.allocator(), &.{"one.info"}, &.{ONE}, lines, &.{ "src/p/a.mojo", "src/p/c.mojo" })) |_| {
            finished = true;
        } else |e| try t.expectEqual(error.OutOfMemory, e);
    }
    try t.expect(finished);
}
