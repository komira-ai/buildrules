//! cov_branch_classify's cases for copies of one function holding different numbers of branches of a kind at one location (README.md,
//! "Copies of unequal size"), on case.ll (fixtures/case.ll): at a.mojo 3,5 its copies hold one branch each, and the edits here give
//! one copy (`pick[T=Float]`) more. Each runs the shipped executable (cov_branch_classify_harness.zig) and says the defect it catches.

const std = @import("std");
const h = @import("cov_branch_classify_harness.zig");

const second_branch = "!dbg !40, !prof !70";

/// case.ll where the copy `pick[T=Float]` holds a second branch at a.mojo 3,5, with the weights `w0` and `w1` (metadata names, or null for
/// a branch that never ran: no `!prof`). The other copies of 3,5 keep one branch each.
fn bigger(c: *h.Case, w0: ?[]const u8, w1: ?[]const u8) !h.Ir {
    var e = try h.Ir.of(c.a(), h.case_ll);
    var i: usize = 0;
    var n: usize = 0;
    while (i < e.lines.items.len) : (i += 1) {
        const l = e.lines.items[i];
        if (!std.mem.endsWith(u8, l, ", " ++ second_branch)) continue;
        const stem = l[0 .. l.len - second_branch.len];
        const first = if (w0) |w| try std.mem.concat(c.a(), u8, &.{ stem, "!dbg !40, !prof ", w }) else try std.mem.concat(c.a(), u8, &.{ stem, "!dbg !40" });
        // On another condition: two branches on one value without weights would be one decision tested twice.
        const stem2 = try std.mem.replaceOwned(u8, c.a(), stem, "br i1 %3,", "br i1 %1,");
        const second = if (w1) |w| try std.mem.concat(c.a(), u8, &.{ stem2, "!dbg !40, !prof ", w }) else try std.mem.concat(c.a(), u8, &.{ stem2, "!dbg !40" });
        e.lines.items[i] = first;
        try e.lines.insert(c.a(), i + 1, second);
        i += 1;
        n += 1;
    }
    try std.testing.expect(n > 0);
    return e;
}

// U1. A copy holding two branches at a location where the others hold one is classified, not refused: its two are the location's
// decisions, with its own counts (1,1 and 9,9). Catches: the refusal "cannot be matched to be summed" of a package whose
// `@always_inline` method has one inlined copy that kept a branch the others folded.
test "U1 copies of unequal size: the copy with the most branches is the location's" {
    var c = try h.Case.init("unequal");
    defer c.deinit();
    var e = try bigger(&c, "!70", "!72");
    const r = try c.run(try e.text());
    try r.exits(0);
    try r.silent("cannot be matched");
    try r.has("BRDA:3,5:br:0/2,0,1", "the larger copy's first branch, arm 0, is not its own 1");
    try r.has("BRDA:3,5:br:0/2,1,1", "the larger copy's first branch, arm 1, is not its own 1");
    try r.has("BRDA:3,5:br:1/2,0,9", "the larger copy's second branch, arm 0, is not its own 9");
    try r.has("BRDA:3,5:br:1/2,1,9", "the larger copy's second branch, arm 1, is not its own 9");
}

// U2. The hits of the smaller copies are dropped: the larger copy's branches never ran here, the smaller copies' (3,12 in all) did, and
// every arm is `-`, none covered. Catches: the smaller copies' counts added to the larger copy's arms, or to the one of the same
// number (an arm reported covered by a copy it cannot be identified with).
test "U2 copies of unequal size: a hit only in a smaller copy covers no arm" {
    var c = try h.Case.init("unequal");
    defer c.deinit();
    var e = try bigger(&c, null, null);
    const r = try c.run(try e.text());
    try r.exits(0);
    try r.has("BRDA:3,5:br:0/2,0,-", "arm 0 of the first branch is not '-' (a smaller copy's hits counted)");
    try r.has("BRDA:3,5:br:0/2,1,-", "arm 1 of the first branch is not '-' (a smaller copy's hits counted)");
    try r.has("BRDA:3,5:br:1/2,0,-", "arm 0 of the second branch is not '-' (a smaller copy's hits counted)");
    try r.has("BRDA:3,5:br:1/2,1,-", "arm 1 of the second branch is not '-' (a smaller copy's hits counted)");
}

// U3. Equal numbers are as before: case.ll itself still gives 3,12 at a.mojo 3,5 (2,10 + 1,1 + 0,1 of three copies) as one record, and
// the b.mojo 3,5 (two branches in every copy) is unchanged. Catches: a drop applied to copies of equal size.
test "U3 copies of equal size are still summed" {
    var c = try h.Case.init("unequal");
    defer c.deinit();
    const r = try c.run(h.case_ll);
    try r.exits(0);
    try r.golden(h.case_golden, "the output differs from fixtures/case.golden.info");
}

// U4. Two copies holding the same most (two branches each) with different hits are summed, as before: the bigger copy (1,1 and 9,9) and a
// second one (2,3 and 4,5) give 3,4 and 13,14, and the one-branch copies add nothing. Catches: only one of the largest copies kept.
test "U4 two largest copies with different hits are summed" {
    var c = try h.Case.init("unequal");
    defer c.deinit();
    var e = try bigger(&c, "!70", "!72");
    const f = try e.function("pick[T=Float]");
    var copy = std.ArrayList([]const u8).empty;
    try copy.append(c.a(), "");
    for (e.lines.items[f[0] .. f[1] + 1]) |l| try copy.append(c.a(), l);
    // The second copy: another name, its branches on the weights `!80` and `!81`.
    copy.items[1] = try std.mem.replaceOwned(u8, c.a(), copy.items[1], "pick[T=Float]", "pick[T=Int]");
    var seen: usize = 0;
    for (copy.items) |*l| {
        if (std.mem.endsWith(u8, l.*, "!prof !70")) {
            l.* = try std.mem.concat(c.a(), u8, &.{ l.*[0 .. l.len - 2], "80" });
            seen += 1;
        } else if (std.mem.endsWith(u8, l.*, "!prof !72")) {
            l.* = try std.mem.concat(c.a(), u8, &.{ l.*[0 .. l.len - 2], "81" });
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
    try e.insertBefore("attributes #0", copy.items);
    try e.append(&.{ "!80 = !{!\"branch_weights\", i32 2, i32 3}", "!81 = !{!\"branch_weights\", i32 4, i32 5}" });
    const r = try c.run(try e.text());
    try r.exits(0);
    try r.has("BRDA:3,5:br:0/2,0,3", "first branch, arm 0, is not 1+2");
    try r.has("BRDA:3,5:br:0/2,1,4", "first branch, arm 1, is not 1+3");
    try r.has("BRDA:3,5:br:1/2,0,13", "second branch, arm 0, is not 9+4");
    try r.has("BRDA:3,5:br:1/2,1,14", "second branch, arm 1, is not 9+5");
}

// U5. Copies of 1, 2 and 4 branches at 3,5 (the 1-branch copies of case.ll, `pick[T=Float]` made 2 and a copy `pick[T=Big]` added with 4):
// only the 4-branch copy is the location's. Its first branch ran 7 and 0 times, its others never ran (`-`); the smaller copies' hits (3,12
// in the 1-branch copies, 1,1 and 9,9 in the 2-branch one) cover no arm and are not added to the 7. Catches: the largest copy not the one
// kept (a 2-branch or 1-branch record written); a smaller copy's hits added to an arm of the same number (the 7 becoming 8 or more, a `-`
// becoming a count).
test "U5 copies of 1, 2 and 4 branches: only the 4-branch copy is kept" {
    var c = try h.Case.init("unequal");
    defer c.deinit();
    var e = try bigger(&c, "!70", "!72");
    const big = [_][]const u8{
        "",
        "define internal void @\"pkg::a::pick[T=Big]\"(i64 %0, i1 %1) #0 !dbg !11 !prof !73 {",
        "2:",
        "  br i1 %3, label %4, label %5, !dbg !40, !prof !90",
        "  br i1 %1, label %4, label %5, !dbg !40",
        "  br i1 %4, label %4, label %5, !dbg !40",
        "  br i1 %5, label %4, label %5, !dbg !40",
        "  ret void, !dbg !41",
        "}",
    };
    try e.insertBefore("attributes #0", &big);
    try e.append(&.{"!90 = !{!\"branch_weights\", i32 7, i32 0}"});
    const r = try c.run(try e.text());
    try r.exits(0);
    try r.has("BRDA:3,5:br:0/4,0,7", "the 4-branch copy's first branch, arm 0, is not its own 7");
    try r.has("BRDA:3,5:br:0/4,1,0", "the 4-branch copy's first branch, arm 1, is not its own 0");
    try r.has("BRDA:3,5:br:1/4,0,-", "second branch of 4, arm 0, is not '-' (a smaller copy's hits counted)");
    try r.has("BRDA:3,5:br:2/4,1,-", "third branch of 4, arm 1, is not '-' (a smaller copy's hits counted)");
    try r.has("BRDA:3,5:br:3/4,0,-", "fourth branch of 4, arm 0, is not '-' (a smaller copy's hits counted)");
    try r.counts("BRDA:3,5:br:0/4,", 2, "a.mojo 3,5 is not one record of 4 branches");
    try r.lacks("BRDA:3,5:br:1/2,0,9", "the 2-branch copy's second branch (9,9) was written");
    try r.lacks("BRDA:3,5:br:0/1,1,12", "the 1-branch copies' summed record (3,12) was written");
}

// U6. A right operand follows its and/or: `both` (c.mojo 7,14, an `and` with its right operand) holds one decision at 7,14 and a copy
// `pkg::c::both2` holds two `and`s there whose results no test reads (so it has no right operand), so `both`'s `br` at 7,14 is dropped and
// its `rhs` with it, though the `rhs` is a record of its own whose total is its parent's. The larger copy's records stay. Catches: the
// `rhs` kept when its parent is dropped (a 0/1 right operand with counts and no decision beside it).
test "U6 a right operand whose and/or is in a dropped copy is dropped too" {
    var c = try h.Case.init("unequal");
    defer c.deinit();
    var e = try h.Ir.of(c.a(), h.case_ll);
    const both2 = [_][]const u8{
        "",
        "define internal i1 @\"pkg::c::both2\"(i64 %0, i64 %1) #0 !dbg !102 !prof !73 {",
        "2:",
        "  %3 = icmp sgt i64 %0, 0, !dbg !116",
        "  br i1 %3, label %4, label %6, !dbg !117, !prof !132",
        "4:                                                ; preds = %2",
        "  %5 = icmp sgt i64 %1, 0, !dbg !118",
        "  br label %7, !dbg !117",
        "6:                                                ; preds = %2",
        "  br label %7, !dbg !117",
        "7:                                                ; preds = %4, %6",
        "  %8 = phi i1 [ %5, %4 ], [ false, %6 ], !dbg !117",
        "  %11 = icmp sgt i64 %0, 1, !dbg !116",
        "  br i1 %11, label %12, label %14, !dbg !117, !prof !132",
        "12:                                               ; preds = %7",
        "  %13 = icmp sgt i64 %1, 1, !dbg !118",
        "  br label %15, !dbg !117",
        "14:                                               ; preds = %7",
        "  br label %15, !dbg !117",
        "15:                                               ; preds = %12, %14",
        "  %16 = phi i1 [ %13, %12 ], [ false, %14 ], !dbg !117",
        "  %17 = xor i1 %8, %16, !dbg !121",
        "  ret i1 %17, !dbg !121",
        "}",
    };
    try e.insertBefore("attributes #0", &both2);
    const r = try c.run(try e.text());
    try r.exits(0);
    try r.has("BRDA:7,14:br:0/2,0,4", "the 2-`and` copy's first branch at 7,14, arm 0, is not its own 4");
    try r.has("BRDA:7,14:br:1/2,1,2", "the 2-`and` copy's second branch at 7,14, arm 1, is not its own 2");
    try r.counts("BRDA:7,14:br:", 4, "7,14 is not 2 branches of 2 arms (the 1-branch copy's record written)");
    try r.lacks("BRDA:7,14:rhs:0/1", "the right operand of the dropped copy's `and` was written");
    try r.lacks("BRDA:7,14:rhs", "a right operand at 7,14 was written (the larger copy's results are read by no test, so it has none)");
}
