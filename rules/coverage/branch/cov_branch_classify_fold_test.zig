//! cov_branch_classify's cases for three valid constructs whose IR looks like a branch the classifier could not place (README.md,
//! "Bool to Int", "Unrolled loops", "Folded conditions"), numbered 13 to 15, on IR written here and the library source u.mojo below. Each
//! runs the shipped executable (cov_branch_classify_harness.zig) and says the defect it catches.

const std = @import("std");
const h = @import("cov_branch_classify_harness.zig");

// Lines: 2 `Int(f)`, 4 a ternary, 8 an `if` of an unrolled loop, 14 the same with an `elif` (16), 20 an `and` of two target queries, 22 an `if`.
const u_src =
    \\def flag(f: Bool) -> Int:
    \\    return Int(f)
    \\def tern(f: Bool) -> Int:
    \\    return 1 if f else 0
    \\def pick[N: Int](m: SIMD[DType.bool, N]) -> Int:
    \\    var c = 0
    \\    comptime for k in range(N):
    \\        if m[k]:
    \\            c = c + 1
    \\    return c
    \\def chain[N: Int](m: SIMD[DType.bool, N]) -> Int:
    \\    var c = 0
    \\    comptime for k in range(N):
    \\        if m[k]:
    \\            c = c + 1
    \\        elif k > 1:
    \\            c = c + 2
    \\    return c
    \\def gate() -> Bool:
    \\    return is_x86() and is_linux()
    \\def always(x: Int) -> Int:
    \\    if x > 0:
    \\        return 1
    \\    return 0
    \\
;

const head =
    \\; *** IR Dump After PGOInstrumentationUse on [module] ***
    \\
;

const tail =
    \\
    \\attributes #0 = { noinline }
    \\
    \\!llvm.dbg.cu = !{!3}
    \\
    \\!1 = !DIFile(filename: "buck-out/v2/art/cell/src/pkg/__pkg__/0123456789abcdef/src/pkg/u.mojo", directory: "")
    \\!2 = !DIFile(filename: "tests/test_a.mojo", directory: "")
    \\!3 = distinct !DICompileUnit(language: DW_LANG_Mojo, file: !2, producer: "Mojo", isOptimized: false, runtimeVersion: 0, emissionKind: LineTablesOnly, nameTableKind: None)
    \\!9 = !DISubroutineType(types: !{})
    \\!10 = distinct !DISubprogram(name: "u", linkageName: "pkg::u", scope: !1, file: !1, line: 1, type: !9, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !3)
    \\!20 = !DILocation(line: 2, column: 15, scope: !10)
    \\!21 = !DILocation(line: 4, column: 14, scope: !10)
    \\!22 = !DILocation(line: 8, column: 9, scope: !10)
    \\!23 = !DILocation(line: 14, column: 9, scope: !10)
    \\!24 = !DILocation(line: 20, column: 18, scope: !10)
    \\!25 = !DILocation(line: 20, column: 21, scope: !10)
    \\!26 = !DILocation(line: 22, column: 5, scope: !10)
    \\!27 = !DILocation(line: 20, column: 33, scope: !10)
    \\!50 = !{!"branch_weights", i32 2, i32 3}
    \\!51 = !{!"branch_weights", i32 1, i32 1}
    \\!52 = !{!"branch_weights", i32 3, i32 5}
    \\!60 = !{!"function_entry_count", i64 1}
    \\
;

const flag_fn =
    \\define internal i64 @"pkg::u::flag"(i1 %0) #0 !dbg !10 !prof !60 {
    \\  %2 = select i1 %0, SELECT, !dbg !20, !prof !52
    \\  ret i64 %2, !dbg !20
    \\}
    \\
;

const tern_fn =
    \\define internal i64 @"pkg::u::tern"(i1 %0) #0 !dbg !10 !prof !60 {
    \\  %2 = select i1 %0, i64 1, i64 0, !dbg !21, !prof !52
    \\  ret i64 %2, !dbg !21
    \\}
    \\
;

const gate_fn =
    \\define internal i1 @"pkg::u::gate"() #0 !dbg !10 !prof !60 {
    \\  %1 = tail call i1 @"FIRST"(), !dbg !24
    \\  br i1 %1, label %2, label %4, !dbg !25, !prof !52
    \\
    \\2:                                                ; preds = %0
    \\  %3 = tail call i1 @"std::sys::info::CompilationTarget::is_linux(),value=#kgen.target<triple = \22x86_64-unknown-linux-gnu\22>"(), !dbg !27
    \\  br label %5, !dbg !25
    \\
    \\4:                                                ; preds = %0
    \\  br label %5, !dbg !25
    \\
    \\5:                                                ; preds = %2, %4
    \\  %6 = phi i1 [ false, %4 ], [ %3, %2 ], !dbg !25
    \\  ret i1 %6, !dbg !25
    \\}
    \\
;

const always_fn =
    \\define internal i64 @"pkg::u::always"(i64 %0) #0 !dbg !10 !prof !60 {
    \\  br i1 COND, label %2, label %3, !dbg !26, !prof !52
    \\
    \\2:                                                ; preds = %1
    \\  ret i64 1, !dbg !26
    \\
    \\3:                                                ; preds = %1
    \\  ret i64 0, !dbg !26
    \\}
    \\
;

const is_x86 = "std::sys::info::CompilationTarget::is_x86(),value=#kgen.target<triple = \\22x86_64-unknown-linux-gnu\\22>";

fn sub(c: *h.Case, text: []const u8, old: []const u8, new: []const u8) ![]const u8 {
    const out = try std.mem.replaceOwned(u8, c.a(), text, old, new);
    try std.testing.expect(!std.mem.eql(u8, out, text));
    return out;
}

/// A function of `lanes` unrolled iterations whose `if` (location `loc`) tests a lane each: `extra` more brs at `loc2` (an `elif` of each).
fn lanesFn(c: *h.Case, name: []const u8, lanes: usize, loc: []const u8, prof: []const u8, loc2: ?[]const u8) ![]const u8 {
    var b = std.ArrayList(u8).empty;
    const al = c.a();
    try b.writer(al).print("define internal i64 @\"pkg::u::{s}\"(i64 %0) #0 !dbg !10 !prof !60 {{\n", .{name});
    const per: usize = if (loc2 == null) 1 else 2;
    for (0..lanes * per) |i| {
        const l = if (i % per == 0) loc else loc2.?;
        try b.writer(al).print("  %c{d} = icmp ne i64 %0, {d}, !dbg !{s}\n", .{ i, i, l });
        try b.writer(al).print("  br i1 %c{d}, label %t{d}, label %j{d}, !dbg !{s}, !prof !{s}\n\n", .{ i, i, i, l, prof });
        try b.writer(al).print("t{d}:                                               ; preds = %e{d}\n  br label %j{d}, !dbg !{s}\n\n", .{ i, i, i, l });
        try b.writer(al).print("j{d}:                                               ; preds = %t{d}\n", .{ i, i });
    }
    try b.writer(al).print("  ret i64 0, !dbg !{s}\n}}\n\n", .{loc});
    return b.items;
}

fn module(c: *h.Case, funcs: []const []const u8) ![]const u8 {
    var parts = std.ArrayList([]const u8).empty;
    try parts.append(c.a(), head);
    for (funcs) |f| {
        try parts.append(c.a(), "\n");
        try parts.append(c.a(), f);
    }
    try parts.append(c.a(), tail);
    return std.mem.concat(c.a(), u8, parts.items);
}

fn flagIr(c: *h.Case, select: []const u8) ![]const u8 {
    return module(c, &.{try std.mem.replaceOwned(u8, c.a(), flag_fn, "SELECT", select)});
}

// 13. A Bool converted to an Int (`Int(flag)`, line 2) is a select between 0 and 1 at the call's `(`: no source decision, so no record at
// the line and no refusal; the same select the other way round (`flag == False`) likewise; and a ternary `1 if f else 0` is a select at its
// `if`, a decision still (4,14). Catches: the select at a call refused as "not on a raising call's error flag" (the downstream failure); the
// rule widened to any select at a call (2 and 0 are no conversion of a Bool, a value is not a constant: refused as before); the ternary
// taken for a conversion (no 4,14 record).
test "13 a Bool converted to an Int: no decision, no refusal" {
    var c = try h.Case.init("bool to int");
    defer c.deinit();
    try c.source("u", u_src);
    var r = try c.accepted("Int(flag)", try flagIr(&c, "i64 1, i64 0"), "call( 1,");
    try r.has("SF:src/pkg/u.mojo", "Int(flag): the file is not named");
    try r.lacks("BRDA:", "Int(flag): a branch of the conversion was recorded as a decision");
    r = try c.accepted("not flag", try flagIr(&c, "i64 0, i64 1"), "call( 1,");
    try r.lacks("BRDA:", "not flag: a branch of the conversion was recorded as a decision");
    r = try c.accepted("ternary", try module(&c, &.{tern_fn}), "if 1,");
    try r.has("BRDA:4,14:select:0/1,0,3", "ternary: 1 if f else 0 is not a select decision with its true arm first");
    try r.has("BRDA:4,14:select:0/1,1,5", "ternary: 1 if f else 0 is not a select decision with its false arm second");
    _ = try c.refused("a select of 2 and 0", "a select at 'Int(' that is not on a raising call's error flag", try flagIr(&c, "i64 2, i64 0"));
    _ = try c.refused("a select of a value and 0", "a select at 'Int(' that is not on a raising call's error flag", try flagIr(&c, "i64 %0, i64 0"));

    _ = try c.refused("a select of 1 and 1", "a select at 'Int(' that is not on a raising call's error flag", try flagIr(&c, "i64 1, i64 1"));
}

// 14. An `if` in a `comptime for` body (line 8) is unrolled: one br per iteration, all at 8,9, and a different number in each instance of
// the function (4 lanes, 8 lanes). They are one decision of two arms, every iteration's counts summed: 4 lanes of 2/3 and 8 lanes of 1/1 are
// 16 true and 20 false. With an `elif` (line 14, 16) the copies are told apart by their order, so two instances of another number of
// lanes are still refused. Catches: the instances refused as "one copy of its function has 4 branch(es) of this kind here and another 8"
// (the downstream failure); one record per lane (4/4 and 0/8 ordinals); only the first iteration or only the largest instance counted
// (not 16/20); the rule applied to a chain with an `elif`, whose records would be summed crosswise (no refusal); the rule applied outside
// a `comptime for` (the same IR on a source without it is refused as before).
test "14 an unrolled loop's branches are one decision, however many iterations" {
    var c = try h.Case.init("unrolled");
    defer c.deinit();
    try c.source("u", u_src);
    const four = try lanesFn(&c, "pick4", 4, "22", "50", null);
    const eight = try lanesFn(&c, "pick8", 8, "22", "51", null);
    const r = try c.accepted("pick", try module(&c, &.{ four, eight }), "if 12,");
    try r.has("BRDA:8,9:br:0/1,0,16", "pick: the true arms of 4 lanes of 2 and 8 lanes of 1 are not summed to 16");
    try r.has("BRDA:8,9:br:0/1,1,20", "pick: the false arms of 4 lanes of 3 and 8 lanes of 1 are not summed to 20");
    try r.counts("BRDA:8,9:", 2, "pick: the iterations are not one decision of two arms");
    const one = try c.accepted("pick, one instance", try module(&c, &.{four}), "if 4,");
    try one.has("BRDA:8,9:br:0/1,0,8", "pick, one instance: 4 lanes of 2 are not 8 true");
    try one.counts("BRDA:8,9:", 2, "pick, one instance: the lanes are not one decision of two arms");
    // The same IR where the source has no `comptime for`: the copies are told apart by their order, and two instances disagree.
    var plain = try h.Case.init("not unrolled");
    defer plain.deinit();
    try plain.source("u", try sub(&plain, u_src, "comptime for k in range(N):", "for k in range(N):"));
    _ = try plain.refused("pick without comptime", "one copy of its function has 4 branch(es) of this kind here and another 8", try module(&plain, &.{ four, eight }));
    // An `if` with an `elif`: not one decision.
    const c2 = try lanesFn(&c, "chain2", 2, "23", "50", "23");
    const c3 = try lanesFn(&c, "chain3", 3, "23", "50", "23");
    _ = try c.refused("chain with elif", "one copy of its function has 4 branch(es) of this kind here and another 6", try module(&c, &.{ c2, c3 }));
}

// 15. A br or select on a condition the build decided is no decision of the run: the literal `true` or `false`, or the result of a call of
// the standard library's target queries (`std::sys::info::...,value=#kgen.target<...>`: `CompilationTarget.is_x86()`). `is_x86() and
// is_linux()` (line 20) keeps the call and a br on its result at the `and`; no record, no refusal. Catches: the br kept as an `and` decision
// (a record at 20,21 whose second arm can never be covered); a call of any other function taken for a query (a runtime flag: the `and`
// is a decision as before, 3 true and 5 false); a query's name without the specialisation taken for one; a literal condition kept
// (a record at 22,5).
test "15 a condition the build decided: no decision" {
    var c = try h.Case.init("folded");
    defer c.deinit();
    try c.source("u", u_src);
    var r = try c.accepted("is_x86() and is_linux()", try module(&c, &.{try sub(&c, gate_fn, "FIRST", is_x86)}), "1 branch(es) or select(s) on a condition the build decided");
    try r.lacks("BRDA:", "is_x86() and is_linux(): a branch on a target query was recorded as a decision");
    r = try c.accepted("a runtime flag", try module(&c, &.{try sub(&c, gate_fn, "FIRST", "pkg::u::runtime_flag")}), "and 1, or 0");
    try r.silent("on a condition the build decided");
    try r.has("BRDA:20,21:br:0/1,0,3", "a runtime flag: the and is not a decision with its left operand true 3 times");
    try r.has("BRDA:20,21:br:0/1,1,5", "a runtime flag: the and is not a decision with its left operand false 5 times");
    r = try c.accepted("a query not specialised", try module(&c, &.{try sub(&c, gate_fn, "FIRST", "std::sys::info::CompilationTarget::is_x86()")}), "and 1, or 0");
    try r.silent("on a condition the build decided");
    try r.has("BRDA:20,21:br:0/1,0,3", "a query without the specialisation: the and is not a decision");
    r = try c.accepted("br i1 true", try module(&c, &.{try sub(&c, always_fn, "COND", "true")}), "1 branch(es) or select(s) on a condition the build decided");
    try r.lacks("BRDA:", "br i1 true: a branch on a literal was recorded as a decision");
    r = try c.accepted("br i1 %0", try module(&c, &.{try sub(&c, always_fn, "COND", "%1")}), "if 1,");
    try r.has("BRDA:22,5:br:0/1,0,3", "br on a value: the if is not a decision");
}
