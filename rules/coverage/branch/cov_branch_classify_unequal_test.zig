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
