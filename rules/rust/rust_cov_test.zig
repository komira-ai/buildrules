//! rust_cov (rust_cov.zig): llvm-cov's lcov read, the files of a member kept, the text cov_floor reads written; the command lines of the merge and
//! the export; and the whole run, with busybox applets of the test's PATH (`true`, `false`, `echo`) standing in for llvm-profdata and llvm-cov.

const std = @import("std");
const cov = @import("rust_cov.zig");
const t = std.testing;

/// The shape of what `llvm-cov export -format=lcov` writes: a test name, then per file its functions, branches and lines with their sums.
const report =
    \\TN:
    \\SF:./crates/demo/src/lib.rs
    \\FN:3,_RNvCs1_4demo4sign
    \\FNDA:2,_RNvCs1_4demo4sign
    \\FNF:1
    \\FNH:1
    \\BRDA:4,0,0,1
    \\BRDA:4,0,1,0
    \\BRDA:9,1,0,-
    \\BRDA:9,1,1,-
    \\BRF:4
    \\BRH:1
    \\DA:3,2
    \\DA:4,2
    \\DA:5,1
    \\DA:7,1,ab12
    \\DA:9,0
    \\LF:5
    \\LH:4
    \\end_of_record
    \\TN:
    \\SF:crates/demo/tests/use.rs
    \\DA:1,1
    \\DA:2,1
    \\end_of_record
    \\SF:crates/other/src/lib.rs
    \\DA:1,0
    \\end_of_record
    \\SF:/worker/out/OUT_DIR/generated.rs
    \\DA:1,1
    \\end_of_record
    \\SF:crates/demo/src/a.rs
    \\DA:1,0
    \\DA:2,0
    \\DA:3,1
    \\end_of_record
    \\
;

const scope = cov.Scope{ .package = "crates/demo" };

test "llvm-cov's lcov is read per file: every line with its count and every branch arm with its count, an arm never reached as none" {
    const a = std.heap.page_allocator;
    const files = try cov.parseLcov(a, report);
    try t.expectEqual(@as(usize, 5), files.len);
    try t.expectEqualStrings("./crates/demo/src/lib.rs", files[0].path);
    try t.expectEqual(@as(usize, 5), files[0].lines.items.len);
    try t.expectEqual(cov.Line{ .line = 7, .count = 1 }, files[0].lines.items[3]);
    try t.expectEqual(cov.Branch{ .line = 4, .block = 0, .branch = 1, .taken = 0 }, files[0].branches.items[1]);
    try t.expectEqual(cov.Branch{ .line = 9, .block = 1, .branch = 0, .taken = null }, files[0].branches.items[2]);
    try t.expectEqual(cov.Measure{ .hit = 4, .total = 5 }, files[0].lineFigure());
    try t.expectEqual(cov.Measure{ .hit = 1, .total = 4 }, files[0].branchFigure());
    try t.expectEqual(@as(usize, 0), files[1].branches.items.len);
    try t.expectEqual(@as(usize, 0), (try cov.parseLcov(a, "")).len);
}

test "a report that is not llvm-cov's lcov is refused: a record outside a file, a file not closed or opened twice, a malformed record, a line of another kind" {
    const a = std.heap.page_allocator;
    const bad = [_][]const u8{
        "DA:1,1\n",
        "BRDA:1,0,0,1\n",
        "FNF:1\n",
        "end_of_record\n",
        "SF:a.rs\nDA:1,1\n",
        "SF:a.rs\nSF:b.rs\nend_of_record\n",
        "SF:\nend_of_record\n",
        "SF:a.rs\nDA:1\nend_of_record\n",
        "SF:a.rs\nDA:x,1\nend_of_record\n",
        "SF:a.rs\nDA:1,-1\nend_of_record\n",
        "SF:a.rs\nBRDA:1,0,0\nend_of_record\n",
        "SF:a.rs\nBRDA:1,0\nend_of_record\n",
        "SF:a.rs\nBRDA:1\nend_of_record\n",
        "SF:a.rs\nBRDA:1,0,0,1,2\nend_of_record\n",
        "SF:a.rs\nBRDA:1,0,0,x\nend_of_record\n",
        "SF:a.rs\nVER:2\nend_of_record\n",
    };
    for (bad) |text| try t.expectError(error.BadLcov, cov.parseLcov(a, text));
}

test "a file under the package counts, one under its tests, benches or examples is shown and not counted, anything else is left out" {
    const s = cov.Scope{ .package = "crates/demo", .exclude = &.{"crates/demo/nested"}, .extra = &.{"shared/stamp.rs"} };
    const cases = [_]struct { []const u8, cov.Kind }{
        .{ "crates/demo/src/lib.rs", .counted },
        .{ "crates/demo/build.rs", .counted },
        .{ "crates/demo/tools/main.rs", .counted },
        .{ "crates/demo/tests/use.rs", .not_counted },
        .{ "crates/demo/benches/b.rs", .not_counted },
        .{ "crates/demo/examples/e.rs", .not_counted },
        .{ "crates/demo/src/tests/inner.rs", .counted },
        .{ "crates/demo/testsuite.rs", .counted },
        .{ "crates/demo/nested/src/lib.rs", .outside },
        .{ "crates/demo_two/src/lib.rs", .outside },
        .{ "crates/demo", .outside },
        .{ "crates/demo/", .outside },
        .{ "crates/other/src/lib.rs", .outside },
        .{ "/abs/crates/demo/src/lib.rs", .outside },
        .{ "shared/stamp.rs", .counted },
        .{ "shared/other.rs", .outside },
    };
    for (cases) |c| try t.expectEqual(c[1], s.kind(c[0]));
}

test "the workspace root as the package holds every relative path but the members nested in it" {
    const s = cov.Scope{ .package = "", .exclude = &.{"crates/b"} };
    try t.expectEqual(cov.Kind.counted, s.kind("src/lib.rs"));
    try t.expectEqual(cov.Kind.not_counted, s.kind("tests/it.rs"));
    try t.expectEqual(cov.Kind.outside, s.kind("crates/b/src/lib.rs"));
    try t.expectEqual(cov.Kind.outside, s.kind("/usr/src/lib.rs"));
}

test "a path written ./<path> is <path>" {
    try t.expectEqualStrings("a/b.rs", cov.normalize("./a/b.rs"));
    try t.expectEqualStrings("a/b.rs", cov.normalize("././a/b.rs"));
    try t.expectEqualStrings("a/b.rs", cov.normalize("a/b.rs"));
    try t.expectEqualStrings(".hidden/b.rs", cov.normalize(".hidden/b.rs"));
}

test "the files of the package are kept, paths normalized and sorted; one file named twice is refused" {
    const a = std.heap.page_allocator;
    const kept = try cov.select(a, try cov.parseLcov(a, report), scope);
    try t.expectEqual(@as(usize, 3), kept.len);
    try t.expectEqualStrings("crates/demo/src/a.rs", kept[0].path);
    try t.expectEqualStrings("crates/demo/src/lib.rs", kept[1].path);
    try t.expectEqualStrings("crates/demo/tests/use.rs", kept[2].path);
    const twice = try cov.parseLcov(a, "SF:crates/demo/src/a.rs\nend_of_record\nSF:./crates/demo/src/a.rs\nend_of_record\n");
    try t.expectError(error.BadLcov, cov.select(a, twice, scope));
}

test "the summary is cov_summary's text: rows per file, the test files not counted, a total of lines and one of branches, percentages rounded down" {
    const a = std.heap.page_allocator;
    const kept = try cov.select(a, try cov.parseLcov(a, report), scope);
    try t.expectEqualStrings(
        \\crates/demo/src/a.rs 1/3 33%
        \\crates/demo/src/lib.rs 4/5 80%
        \\crates/demo/tests/use.rs 2/2 100% (not counted)
        \\total 5/8 62%
        \\branches crates/demo/src/a.rs 0/0 0%
        \\branches crates/demo/src/lib.rs 1/4 25%
        \\branches crates/demo/tests/use.rs 0/0 0% (not counted)
        \\branches total 1/4 25%
        \\
    , try cov.render(a, kept, scope, true));
    try t.expectEqualStrings("total 0/0 0%\nbranches total 0/0 0%\n", try cov.render(a, &.{}, scope, true));
}

test "tests built without branch counters have lines only: no branches rows, so cov_floor reads no branch figure" {
    const a = std.heap.page_allocator;
    const kept = try cov.select(a, try cov.parseLcov(a, report), scope);
    try t.expectEqualStrings(
        \\crates/demo/src/a.rs 1/3 33%
        \\crates/demo/src/lib.rs 4/5 80%
        \\crates/demo/tests/use.rs 2/2 100% (not counted)
        \\total 5/8 62%
        \\
    , try cov.render(a, kept, scope, false));
}

test "the lcov written is the kept files' records as llvm-cov wrote them, under the paths of the summary" {
    const a = std.heap.page_allocator;
    const kept = try cov.select(a, try cov.parseLcov(a, report), scope);
    try t.expectEqualStrings(
        \\SF:crates/demo/src/a.rs
        \\DA:1,0
        \\DA:2,0
        \\DA:3,1
        \\end_of_record
        \\SF:crates/demo/src/lib.rs
        \\DA:3,2
        \\DA:4,2
        \\DA:5,1
        \\DA:7,1
        \\DA:9,0
        \\BRDA:4,0,0,1
        \\BRDA:4,0,1,0
        \\BRDA:9,1,0,-
        \\BRDA:9,1,1,-
        \\end_of_record
        \\SF:crates/demo/tests/use.rs
        \\DA:1,1
        \\DA:2,1
        \\end_of_record
        \\
    , try cov.renderLcov(a, kept));
}

test "the command line: every option lands in its field, repeated ones in order; a missing required option, a dangling or unknown one is a usage error" {
    const a = std.heap.page_allocator;
    const full = [_][]const u8{
        "--profdata", "pd",      "--llvm-cov", "lc",   "--out",     "o.txt", "--lcov",    "o.lcov", "--package", "crates/x",
        "--exclude",  "./n", "--extra", "./s.rs", "--profiles", "p1",  "--profiles", "p2",    "--object",  "t1",
        "--object",   "b1",
    };
    const o = try cov.parseArgs(a, &full);
    try t.expectEqualStrings("pd", o.profdata);
    try t.expectEqualStrings("lc", o.llvm_cov);
    try t.expectEqualStrings("o.txt", o.out);
    try t.expectEqualStrings("o.lcov", o.lcov);
    try t.expectEqualStrings("crates/x", o.scope.package);
    try t.expectEqualStrings("crates/x/n", o.scope.exclude[0]);
    try t.expectEqualStrings("s.rs", o.scope.extra[0]);
    try t.expectEqual(@as(usize, 2), o.profiles.len);
    try t.expectEqualStrings("p2", o.profiles[1]);
    try t.expectEqualStrings("b1", o.objects[1]);
    try t.expect(o.branches);
    const no = try cov.parseArgs(a, &.{ "--profdata", "pd", "--llvm-cov", "lc", "--out", "o", "--lcov", "l", "--package", "p", "--branches", "no" });
    try t.expect(!no.branches);
    try t.expect((try cov.parseArgs(a, &.{ "--profdata", "pd", "--llvm-cov", "lc", "--out", "o", "--lcov", "l", "--package", "p", "--branches", "yes" })).branches);
    try t.expectError(error.Usage, cov.parseArgs(a, &.{ "--profdata", "pd", "--llvm-cov", "lc", "--out", "o", "--lcov", "l", "--package", "p", "--branches", "maybe" }));
    // The root package is the empty directory, which is given.
    const root = try cov.parseArgs(a, &.{ "--profdata", "pd", "--llvm-cov", "lc", "--out", "o", "--lcov", "l", "--package", "" });
    try t.expectEqualStrings("", root.scope.package);
    try t.expectEqual(@as(usize, 0), root.objects.len);
    // The root package as `.`: its nested members are relative to the root.
    const dot = try cov.parseArgs(a, &.{ "--profdata", "pd", "--llvm-cov", "lc", "--out", "o", "--lcov", "l", "--package", ".", "--exclude", "crates/b" });
    try t.expectEqualStrings("", dot.scope.package);
    try t.expectEqualStrings("crates/b", dot.scope.exclude[0]);
    try t.expectEqualStrings("crates/x", (try cov.parseArgs(a, &.{ "--profdata", "pd", "--llvm-cov", "lc", "--out", "o", "--lcov", "l", "--package", "./crates/x" })).scope.package);
    // Each required option left out in turn.
    var skip: usize = 0;
    while (skip < 5) : (skip += 1) {
        var args = std.ArrayList([]const u8).empty;
        for (0..5) |i| {
            if (i != skip) try args.appendSlice(a, full[i * 2 .. i * 2 + 2]);
        }
        try t.expectError(error.Usage, cov.parseArgs(a, args.items));
    }
    try t.expectError(error.Usage, cov.parseArgs(a, &.{ "--profdata", "pd", "--out" }));
    try t.expectError(error.Usage, cov.parseArgs(a, &.{ "--profdata", "pd", "--color", "x" }));
}

/// A fresh directory with its absolute path.
const Tmp = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,

    fn init() !Tmp {
        const tmp = t.tmpDir(.{});
        return .{ .root = try tmp.dir.realpathAlloc(std.heap.page_allocator, "."), .tmp = tmp };
    }

    fn path(self: Tmp, name: []const u8) ![]const u8 {
        return std.fs.path.join(std.heap.page_allocator, &.{ self.root, name });
    }
};

test "a run's profiles are its .profraw files, sorted; a run that wrote none fails naming its directory" {
    const a = std.heap.page_allocator;
    var d = try Tmp.init();
    defer d.tmp.cleanup();
    try d.tmp.dir.makePath("run/sub.profraw");
    for ([_][]const u8{ "run/2-1.profraw", "run/1-1.profraw", "run/notes.txt" }) |n| try d.tmp.dir.writeFile(.{ .sub_path = n, .data = "" });
    var why: []const u8 = "";
    const got = try cov.profilesOf(a, try d.path("run"), &why);
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings(try d.path("run/1-1.profraw"), got[0]);
    try t.expectEqualStrings(try d.path("run/2-1.profraw"), got[1]);
    try d.tmp.dir.makePath("empty");
    try t.expectError(error.NoProfile, cov.profilesOf(a, try d.path("empty"), &why));
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}: the run wrote no profile: its program was not built with coverage counters (-C instrument-coverage)", .{try d.path("empty")}), why);
    try t.expectError(error.FileNotFound, cov.profilesOf(a, try d.path("absent"), &why));
}

/// The options of a run in `d`: one run directory holding one profile, the programs given (busybox applets of the test's PATH stand in for the
/// llvm tools), two objects.
fn options(d: Tmp, profdata: []const u8, llvm_cov: []const u8) !cov.Options {
    try d.tmp.dir.makePath("run");
    try d.tmp.dir.writeFile(.{ .sub_path = "run/7-1.profraw", .data = "" });
    const a = std.heap.page_allocator;
    const profiles = try a.alloc([]const u8, 1);
    profiles[0] = try d.path("run");
    const objects = try a.alloc([]const u8, 2);
    objects[0] = "test-bin";
    objects[1] = "pkg-bin";
    return .{ .profdata = profdata, .llvm_cov = llvm_cov, .out = try d.path("coverage.txt"), .lcov = try d.path("coverage.lcov"), .scope = scope, .profiles = profiles, .objects = objects };
}

test "the merge takes every profile of every run, and the export reads the merged profile against every object, the test binary first" {
    const a = std.heap.page_allocator;
    var d = try Tmp.init();
    defer d.tmp.cleanup();
    const o = try options(d, "pd", "lc");
    var why: []const u8 = "";
    const merge = try cov.mergeArgv(a, o, "m.profdata", &why);
    const want_merge = [_][]const u8{ "pd", "merge", "-sparse", "-o", "m.profdata", try d.path("run/7-1.profraw") };
    try t.expectEqual(want_merge.len, merge.len);
    for (want_merge, merge) |w, g| try t.expectEqualStrings(w, g);
    const exp = try cov.exportArgv(a, o, "m.profdata");
    const want_export = [_][]const u8{ "lc", "export", "-format=lcov", "-instr-profile=m.profdata", "test-bin", "-object", "pkg-bin" };
    try t.expectEqual(want_export.len, exp.len);
    for (want_export, exp) |w, g| try t.expectEqualStrings(w, g);
}

test "the report read writes the summary and the lcov of the package" {
    const a = std.heap.page_allocator;
    var d = try Tmp.init();
    defer d.tmp.cleanup();
    const o = try options(d, "pd", "lc");
    var why: []const u8 = "";
    const text = try cov.finish(a, o, report, &why);
    try t.expectEqualStrings(text, try d.tmp.dir.readFileAlloc(a, "coverage.txt", 1 << 16));
    try t.expect(std.mem.startsWith(u8, text, "crates/demo/src/a.rs 1/3 33%\n"));
    try t.expectEqualStrings(try cov.renderLcov(a, try cov.select(a, try cov.parseLcov(a, report), scope)), try d.tmp.dir.readFileAlloc(a, "coverage.lcov", 1 << 16));
}

test "a run runs the merge, then the export with its standard output kept as the report, and reads that report" {
    const a = std.heap.page_allocator;
    var d = try Tmp.init();
    defer d.tmp.cleanup();
    // `true` merges nothing and succeeds; `echo` prints its arguments, which is the export's command line and not lcov.
    const o = try options(d, "true", "echo");
    var why: []const u8 = "";
    try t.expectError(error.BadLcov, cov.run(a, o, try d.path("scratch"), &why));
    try t.expectEqualStrings("llvm-cov's report is not the lcov this tool reads (SF, DA, BRDA, end_of_record and the sums)", why);
    const merged = try d.path("scratch/merged.profdata");
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "export -format=lcov -instr-profile={s} test-bin -object pkg-bin\n", .{merged}), try d.tmp.dir.readFileAlloc(a, "scratch/export.lcov", 1 << 16));
}

test "a member with no test runs nothing and every total is 0/0" {
    const a = std.heap.page_allocator;
    var d = try Tmp.init();
    defer d.tmp.cleanup();
    var o = try options(d, "/no/such/profdata", "/no/such/llvm-cov");
    o.profiles = &.{};
    o.objects = &.{};
    var why: []const u8 = "";
    try t.expectEqualStrings("total 0/0 0%\nbranches total 0/0 0%\n", try cov.run(a, o, try d.path("scratch"), &why));
    try t.expectEqualStrings("", try d.tmp.dir.readFileAlloc(a, "coverage.lcov", 1 << 16));
}

test "a tool that fails, a run without profiles, a program that is not there and a report naming a file twice each fail the run" {
    const a = std.heap.page_allocator;
    var d = try Tmp.init();
    defer d.tmp.cleanup();
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "false", "echo", "llvm-profdata merge failed (its own message is above)" },
        .{ "true", "false", "llvm-cov export failed (its own message is above)" },
    };
    for (cases) |c| {
        var why: []const u8 = "";
        try t.expectError(error.ToolFailed, cov.run(a, try options(d, c[0], c[1]), try d.path("scratch"), &why));
        try t.expectEqualStrings(c[2], why);
    }
    var why: []const u8 = "";
    try t.expectError(error.FileNotFound, cov.run(a, try options(d, "/no/such/profdata", "echo"), try d.path("scratch"), &why));
    const o = try options(d, "true", "echo");
    try d.tmp.dir.deleteFile("run/7-1.profraw");
    try t.expectError(error.NoProfile, cov.run(a, o, try d.path("scratch"), &why));
    try t.expectError(error.BadLcov, cov.finish(a, o, "SF:crates/demo/a.rs\nend_of_record\nSF:./crates/demo/a.rs\nend_of_record\n", &why));
    try t.expectEqualStrings("llvm-cov's report names one file twice", why);
}

test "a child's end is its status, 128 + N for a signal, and 1 for anything else; a program that is not there is an error" {
    const got = [_]u8{ cov.codeOf(.{ .Exited = 3 }), cov.codeOf(.{ .Signal = 9 }), cov.codeOf(.{ .Stopped = 19 }), cov.codeOf(.{ .Unknown = 7 }) };
    try t.expectEqualSlices(u8, &.{ 3, 137, 1, 1 }, &got);
    try t.expectError(error.FileNotFound, cov.spawn(std.heap.page_allocator, &.{"/no/such/program"}, null));
}

test "every allocation that fails is an error of the run, never a crash" {
    var d = try Tmp.init();
    defer d.tmp.cleanup();
    const a0 = std.heap.page_allocator;
    const o = try options(d, "true", "echo");
    var fail_at: usize = 0;
    var failed: usize = 0;
    while (fail_at < 4096) : (fail_at += 1) {
        var arena = std.heap.ArenaAllocator.init(a0);
        defer arena.deinit();
        var failing = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = fail_at });
        var why: []const u8 = "";
        // The run ends at the report `echo` printed (not lcov), and the report read alone ends written: both, every allocation failing in turn.
        const ran = cov.run(failing.allocator(), o, try d.path("scratch"), &why);
        if (ran) |_| {} else |e| try t.expect(e == error.OutOfMemory or e == error.BadLcov);
        const done = cov.finish(failing.allocator(), o, report, &why);
        if (done) |_| {
            if (!failing.has_induced_failure) break;
        } else |e| {
            try t.expectEqual(error.OutOfMemory, e);
            failed += 1;
        }
    }
    try t.expect(failed > 0 and fail_at < 4096);
}
