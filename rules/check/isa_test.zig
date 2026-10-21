//! The cases of isa.zig: the counting of a disassembly (fed in pieces, split anywhere), the report, and `check isa` end to end with a program that
//! stands in for llvm-objdump: the toolbox's `echo` prints its arguments, so the text given as the binary comes back as the disassembly (its first
//! line is the arguments `-d --no-show-raw-insn` and then the text).

const std = @import("std");
const t = std.testing;
const kit = @import("checkkit.zig");
const isa = @import("isa.zig");

const SAMPLE =
    "0000000000401000 <main>:\n" ++
    "  401000:\tpushq\t%rbp\n" ++
    "  401001:\tvpaddd\t%ymm0, %ymm1, %ymm2\n" ++
    "  401005:\tmovaps\t%xmm0, %xmm1\n" ++
    "  401009:\tvmovdqa\t%ymm3, %xmm4\n" ++
    "  40100d:\tvpaddd\t%xmm0, %xmm1, %xmm2\n" ++
    "  401011:\tvpaddd\t%xmm0, %xmm1, %xmm2 # then ymm\n";

fn counted(c: *kit.Case, pieces: []const []const u8) !isa.Counts {
    var counts = isa.Counts{};
    for (pieces) |p| try counts.feed(c.alloc(), p);
    try counts.finish(c.alloc());
    return counts;
}

fn expectSample(counts: isa.Counts) !void {
    // instructions: the six lines with an address; the label line has none
    try t.expectEqual(@as(u64, 6), counts.instructions);
    // ymm: vpaddd, vmovdqa, and the comment of the last
    try t.expectEqual(@as(u64, 3), counts.ymm);
    // xmm: movaps, vmovdqa, and the two vpaddd on xmm
    try t.expectEqual(@as(u64, 4), counts.xmm);
    // vpaddd with ymm after it on the line: the first, and the last (in its comment)
    try t.expectEqual(@as(u64, 2), counts.vpaddd_ymm);
    try t.expectEqual(@as(usize, 3), counts.first_ymm_count);
    try t.expectEqualStrings("  401001:\tvpaddd\t%ymm0, %ymm1, %ymm2", counts.first_ymm[0]);
}

test "Counts: instructions, ymm, xmm and vpaddd-on-ymm lines of a disassembly" {
    var c = try kit.Case.init();
    defer c.deinit();
    try expectSample(try counted(&c, &.{SAMPLE}));
}

test "Counts: the same wherever the text is cut, a cut in the middle of a line or exactly at a newline included; a last line without its newline is counted" {
    var c = try kit.Case.init();
    defer c.deinit();
    var cut: usize = 0;
    while (cut <= SAMPLE.len) : (cut += 1) {
        try expectSample(try counted(&c, &.{ SAMPLE[0..cut], SAMPLE[cut..] }));
    }
    // three pieces, and a piece of a single byte
    try expectSample(try counted(&c, &.{ SAMPLE[0..30], SAMPLE[30..31], SAMPLE[31..] }));
    // no final newline
    const trimmed = SAMPLE[0 .. SAMPLE.len - 1];
    try expectSample(try counted(&c, &.{trimmed}));
    try expectSample(try counted(&c, &.{ trimmed[0..10], trimmed[10..] }));
    // nothing at all
    const none = try counted(&c, &.{});
    try t.expectEqual(@as(u64, 0), none.instructions + none.ymm + none.xmm + none.vpaddd_ymm);
    const empty_pieces = try counted(&c, &.{ "", "" });
    try t.expectEqual(@as(u64, 0), empty_pieces.instructions);
}

test "Counts: a line is an instruction when spaces, lowercase hex digits (maybe none) and a colon begin it" {
    var c = try kit.Case.init();
    defer c.deinit();
    const yes = [_][]const u8{ "  401000: nop", "401000:", ":", "  :", "a:", "   deadbeef:\tnop", "0: x" };
    const no = [_][]const u8{ "", "   ", "  401000", " 4A: nop", "main:", "0000000000401000 <main>:", "\tnop:", "g1:", "x 1:" };
    for (yes) |line| {
        const n = try counted(&c, &.{ line, "\n" });
        if (n.instructions != 1) {
            std.debug.print("'{s}' should be an instruction\n", .{line});
            return error.TestUnexpectedResult;
        }
    }
    for (no) |line| {
        const n = try counted(&c, &.{ line, "\n" });
        if (n.instructions != 0) {
            std.debug.print("'{s}' should not be an instruction\n", .{line});
            return error.TestUnexpectedResult;
        }
    }
}

test "Counts: ymm, xmm and vpaddd are counted wherever on a line they are, once a line; vpaddd counts only when ymm comes after it" {
    var c = try kit.Case.init();
    defer c.deinit();
    const n = try counted(&c, &.{
        "ymm ymm ymm\n", // one ymm line, three mentions
        "xmm\n",
        "ymm xmm\n", // both
        "vpaddd ymm\n", // vpaddd then ymm
        "ymm vpaddd\n", // ymm before vpaddd: not a vpaddd on ymm
        "vpaddd vpaddd ymm\n",
        "vpaddd xmm\n",
    });
    try t.expectEqual(@as(u64, 5), n.ymm);
    try t.expectEqual(@as(u64, 3), n.xmm);
    try t.expectEqual(@as(u64, 2), n.vpaddd_ymm);
}

test "Counts: only the first five lines that name ymm are kept, whole, in order" {
    var c = try kit.Case.init();
    defer c.deinit();
    const n = try counted(&c, &.{ "a ymm\nb\nc ymm\nd ymm\ne ymm\nf ymm\ng ymm\nh ymm\n", "i ymm\n" });
    try t.expectEqual(@as(u64, 8), n.ymm);
    try t.expectEqual(@as(usize, 5), n.first_ymm_count);
    for ([_][]const u8{ "a ymm", "c ymm", "d ymm", "e ymm", "f ymm" }, 0..) |want, i| try t.expectEqualStrings(want, n.first_ymm[i]);
}

test "report: the counts and the first ymm lines, in the form isa_audit wrote them" {
    var c = try kit.Case.init();
    defer c.deinit();
    const n = try counted(&c, &.{SAMPLE});
    const want =
        "target: //x:y\n" ++
        "expect: avx2\n" ++
        "instructions: 6\n" ++
        "instructions naming ymm (AVX2 width): 3\n" ++
        "instructions naming xmm (SSE width): 4\n" ++
        "vpaddd on ymm (the vectorized sum, AVX2-only): 2\n" ++
        "first ymm lines:\n" ++
        "  401001:\tvpaddd\t%ymm0, %ymm1, %ymm2\n" ++
        "  401009:\tvmovdqa\t%ymm3, %xmm4\n" ++
        "  401011:\tvpaddd\t%xmm0, %xmm1, %xmm2 # then ymm\n";
    try t.expectEqualStrings(want, try isa.report(c.alloc(), "//x:y", "avx2", n));
    const zero = isa.Counts{};
    try t.expectEqualStrings("target: t\nexpect: none\ninstructions: 0\ninstructions naming ymm (AVX2 width): 0\ninstructions naming xmm (SSE width): 0\nvpaddd on ymm (the vectorized sum, AVX2-only): 0\nfirst ymm lines:\n", try isa.report(c.alloc(), "t", "none", zero));
}

// ---- check isa --------------------------------------------------------------------------------------------------

/// `isa --objdump ./echo ...` with the text of a disassembly as the binary.
fn isaRun(c: *kit.Case, text: []const u8, expect: []const u8) !kit.Result {
    c.tmp.dir.symLink(c.toolbox, "echo", .{}) catch {};
    return c.run(&.{ "isa", "--objdump", "./echo", "--binary", text, "--expect", expect, "--label", "//x:y", "--out", "report" });
}

const WITH_YMM = "x\n  401000:\tvpaddd\t%ymm1, %ymm1, %ymm1\n  401004:\tmovaps\t%xmm0, %xmm1";
const WITHOUT_YMM = "x\n  401000:\tpushq\t%rbp\n  401004:\tmovaps\t%xmm0, %xmm1";

test "isa: avx2 is met by a binary with a ymm instruction; the report is written" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try isaRun(&c, WITH_YMM, "avx2"), 0, "", "");
    try t.expectEqualStrings(
        "target: //x:y\nexpect: avx2\ninstructions: 2\ninstructions naming ymm (AVX2 width): 1\ninstructions naming xmm (SSE width): 1\n" ++
            "vpaddd on ymm (the vectorized sum, AVX2-only): 1\nfirst ymm lines:\n  401000:\tvpaddd\t%ymm1, %ymm1, %ymm1\n",
        try c.read("report"),
    );
}

test "isa: avx2 is not met by a binary without one; none is met by that binary" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try isaRun(&c, WITHOUT_YMM, "avx2"), 1, "", "isa_audit: //x:y was built for a level with AVX2 but its machine code has no ymm instruction: the ISA flags never reached the compiler\n");
    try t.expect(!c.exists("report"));
    try kit.expectResult(try isaRun(&c, WITHOUT_YMM, "none"), 0, "", "");
    try t.expectEqualStrings(
        "target: //x:y\nexpect: none\ninstructions: 2\ninstructions naming ymm (AVX2 width): 0\ninstructions naming xmm (SSE width): 1\n" ++
            "vpaddd on ymm (the vectorized sum, AVX2-only): 0\nfirst ymm lines:\n",
        try c.read("report"),
    );
}

test "isa: none is not met by a binary with ymm instructions: the count and the lines are said, and no report is written" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(
        try isaRun(&c, WITH_YMM, "none"),
        1,
        "",
        "isa_audit: //x:y was built for a level without AVX2 but 1 instructions name ymm: it would die with SIGILL on a baseline worker\n  401000:\tvpaddd\t%ymm1, %ymm1, %ymm1\n",
    );
    try t.expect(!c.exists("report"));
}

test "isa: an expectation that is neither avx2 nor none is status 2" {
    var c = try kit.Case.init();
    defer c.deinit();
    try kit.expectResult(try isaRun(&c, WITH_YMM, "sse"), 2, "", "isa_audit: expect must be avx2 or none, got 'sse'\n");
    try kit.expectResult(try isaRun(&c, WITH_YMM, ""), 2, "", "isa_audit: expect must be avx2 or none, got ''\n");
    try kit.expectResult(try isaRun(&c, WITH_YMM, "AVX2"), 2, "", "isa_audit: expect must be avx2 or none, got 'AVX2'\n");
}

test "isa: a disassembler that fails, or is not there, fails the check with the reason" {
    var c = try kit.Case.init();
    defer c.deinit();
    // the toolbox itself, called with `-d`, finds no applet of that name and exits 127
    const r = try c.run(&.{ "isa", "--objdump", c.toolbox, "--binary", "b", "--expect", "none", "--label", "l", "--out", "report" });
    try kit.expectFailure(r, 1, try std.fmt.allocPrint(c.alloc(), "check isa: {s} failed with status 127", .{c.toolbox}));
    try kit.expectResult(try c.run(&.{ "isa", "--objdump", "/no/such/objdump", "--binary", "b", "--expect", "none", "--label", "l", "--out", "report" }), 1, "", "check isa: cannot run /no/such/objdump: FileNotFound\n");
    try t.expect(!c.exists("report"));
}

test "isa: a report that cannot be written is status 1 with the reason" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.tmp.dir.symLink(c.toolbox, "echo", .{}) catch {};
    const r = try c.run(&.{ "isa", "--objdump", "./echo", "--binary", "b", "--expect", "none", "--label", "l", "--out", "no-dir/report" });
    try kit.expectFailure(r, 1, "check isa: cannot write no-dir/report: temporary file: FileNotFound");
}

test "isa: every option is required, each has a value, and no other is known" {
    var c = try kit.Case.init();
    defer c.deinit();
    const usage = "check isa: usage: check isa --objdump PROGRAM --binary FILE --expect avx2|none --label TEXT --out REPORT\n";
    try kit.expectResult(try c.run(&.{"isa"}), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "isa", "--objdump", "p", "--binary", "b", "--expect", "none", "--label", "l" }), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "isa", "--binary", "b", "--expect", "none", "--label", "l", "--out", "o" }), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "isa", "--objdump", "p", "--expect", "none", "--label", "l", "--out", "o" }), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "isa", "--objdump", "p", "--binary", "b", "--label", "l", "--out", "o" }), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "isa", "--objdump", "p", "--binary", "b", "--expect", "none", "--out", "o" }), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "isa", "--objdump", "p", "--binary", "b", "--expect", "none", "--label", "l", "--out" }), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "isa", "--objdump", "p", "--binary", "b", "--expect", "none", "--label", "l", "--out", "o", "extra" }), 2, "", usage);
    try kit.expectResult(try c.run(&.{ "isa", "--bogus", "x" }), 2, "", "check isa: unknown option --bogus\n");
}

test "Counts: an allocation that fails while a line is joined from two chunks, or kept, is an error and never a count" {
    var c = try kit.Case.init();
    defer c.deinit();
    var i: usize = 0;
    var failed: usize = 0;
    while (i < 40) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(c.alloc(), .{ .fail_index = i });
        var counts = isa.Counts{};
        const ok = blk: {
            counts.feed(fa.allocator(), "  401000:\tvpaddd %ym") catch break :blk false;
            counts.feed(fa.allocator(), "m1\n  401004:\tnop\n  40") catch break :blk false;
            counts.feed(fa.allocator(), "1008:\tnop") catch break :blk false;
            counts.finish(fa.allocator()) catch break :blk false;
            break :blk true;
        };
        if (fa.has_induced_failure) {
            failed += 1;
            try t.expect(!ok);
        } else {
            try t.expect(ok);
            try t.expectEqual(@as(u64, 3), counts.instructions);
            try t.expectEqual(@as(u64, 1), counts.ymm);
        }
    }
    try t.expect(failed > 3);
}

test "Counts.finish: an allocation that fails while the last line, which has no newline, is kept, is an error" {
    var c = try kit.Case.init();
    defer c.deinit();
    var i: usize = 0;
    var failed: usize = 0;
    while (i < 20) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(c.alloc(), .{ .fail_index = i });
        var counts = isa.Counts{};
        const ok = blk: {
            counts.feed(fa.allocator(), "  401000:\tvpaddd %ymm1") catch break :blk false;
            counts.finish(fa.allocator()) catch break :blk false;
            break :blk true;
        };
        if (fa.has_induced_failure) {
            failed += 1;
            try t.expect(!ok);
        } else {
            try t.expect(ok);
            try t.expectEqual(@as(u64, 1), counts.ymm);
        }
    }
    try t.expect(failed >= 2);
}

test "isa: the failure of a binary that has ymm instructions where none are allowed is the same when stderr cannot be written" {
    var c = try kit.Case.init();
    defer c.deinit();
    c.stderr_closed = true;
    try kit.expectResult(try isaRun(&c, WITH_YMM, "none"), 1, "", "");
    try kit.expectResult(try isaRun(&c, WITHOUT_YMM, "avx2"), 1, "", "");
    try kit.expectResult(try isaRun(&c, WITH_YMM, "sse"), 2, "", "");
}

test "report: an allocation that fails while the report is built is an error, at each of its allocations" {
    var c = try kit.Case.init();
    defer c.deinit();
    const n = try counted(&c, &.{SAMPLE});
    var i: usize = 0;
    var failed: usize = 0;
    while (i < 200) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(c.alloc(), .{ .fail_index = i });
        if (isa.report(fa.allocator(), "//x:y", "avx2", n)) |text| {
            try t.expect(!fa.has_induced_failure);
            try t.expect(std.mem.startsWith(u8, text, "target: //x:y\n"));
            break;
        } else |err| {
            try t.expectEqual(error.OutOfMemory, err);
            try t.expect(fa.has_induced_failure);
            failed += 1;
        }
    }
    try t.expect(failed > 10);
}
