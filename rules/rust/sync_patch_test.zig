//! sync_patch.zig: the patch (each expected text is what `git diff` writes for the same change, its `index` line left out), applying it,
//! the verdict, the summary and the command line. The run of `buildrules sync` itself is the farm's (rules/rust/tests:sync_patch_roundtrip).
const std = @import("std");
const P = @import("sync_patch.zig");
const t = std.testing;

const Arena = std.heap.ArenaAllocator;

fn patchOf(a: std.mem.Allocator, path: []const u8, before: ?[]const u8, after: ?[]const u8) ![]u8 {
    return P.patchText(a, &.{.{ .path = path, .before = before, .after = after }}, P.max_edits);
}

/// The numbers 1..last, one per line, each line `n` that `swap` names replaced by its text.
fn numbered(a: std.mem.Allocator, last: usize, swap: []const struct { usize, []const u8 }) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var n: usize = 1;
    while (n <= last) : (n += 1) {
        var text: []const u8 = try std.fmt.allocPrint(a, "{d}", .{n});
        for (swap) |s| {
            if (s[0] == n) text = s[1];
        }
        try out.appendSlice(a, text);
        try out.append(a, '\n');
    }
    return out.items;
}

test "the patch of a changed line is git's: three lines of context on each side" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings(
        \\diff --git a/mid b/mid
        \\--- a/mid
        \\+++ b/mid
        \\@@ -2,7 +2,7 @@
        \\ 2
        \\ 3
        \\ 4
        \\-5
        \\+five
        \\ 6
        \\ 7
        \\ 8
        \\
    , try patchOf(a, "mid", try numbered(a, 10, &.{}), try numbered(a, 10, &.{.{ 5, "five" }})));
}

test "two changes are two hunks when more than six unchanged lines are between them, and one hunk when six or fewer are" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings(
        \\diff --git a/far b/far
        \\--- a/far
        \\+++ b/far
        \\@@ -1,5 +1,5 @@
        \\ 1
        \\-2
        \\+two
        \\ 3
        \\ 4
        \\ 5
        \\@@ -15,6 +15,6 @@
        \\ 15
        \\ 16
        \\ 17
        \\-18
        \\+eighteen
        \\ 19
        \\ 20
        \\
    , try patchOf(a, "far", try numbered(a, 20, &.{}), try numbered(a, 20, &.{ .{ 2, "two" }, .{ 18, "eighteen" } })));
    // seven unchanged lines (3..9) between: two hunks
    try t.expectEqualStrings(
        \\diff --git a/seven b/seven
        \\--- a/seven
        \\+++ b/seven
        \\@@ -1,5 +1,5 @@
        \\ 1
        \\-2
        \\+two
        \\ 3
        \\ 4
        \\ 5
        \\@@ -7,7 +7,7 @@
        \\ 7
        \\ 8
        \\ 9
        \\-10
        \\+ten
        \\ 11
        \\ 12
        \\ 13
        \\
    , try patchOf(a, "seven", try numbered(a, 13, &.{}), try numbered(a, 13, &.{ .{ 2, "two" }, .{ 10, "ten" } })));
    // six (3..8): one
    try t.expectEqualStrings(
        \\diff --git a/six b/six
        \\--- a/six
        \\+++ b/six
        \\@@ -1,12 +1,12 @@
        \\ 1
        \\-2
        \\+two
        \\ 3
        \\ 4
        \\ 5
        \\ 6
        \\ 7
        \\ 8
        \\-9
        \\+nine
        \\ 10
        \\ 11
        \\ 12
        \\
    , try patchOf(a, "six", try numbered(a, 12, &.{}), try numbered(a, 12, &.{ .{ 2, "two" }, .{ 9, "nine" } })));
}

test "a file made, removed or emptied, a line added at the top, and a last line without a newline, as git writes them" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings(
        \\diff --git a/made b/made
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/made
        \\@@ -0,0 +1,2 @@
        \\+n1
        \\+n2
        \\
    , try patchOf(a, "made", null, "n1\nn2\n"));
    try t.expectEqualStrings(
        \\diff --git a/gone b/gone
        \\deleted file mode 100644
        \\--- a/gone
        \\+++ /dev/null
        \\@@ -1,2 +0,0 @@
        \\-a
        \\-b
        \\
    , try patchOf(a, "gone", "a\nb\n", null));
    try t.expectEqualStrings(
        \\diff --git a/emptied b/emptied
        \\--- a/emptied
        \\+++ b/emptied
        \\@@ -1,2 +0,0 @@
        \\-q
        \\-r
        \\
    , try patchOf(a, "emptied", "q\nr\n", ""));
    try t.expectEqualStrings(
        \\diff --git a/top b/top
        \\--- a/top
        \\+++ b/top
        \\@@ -1,3 +1,4 @@
        \\+zero
        \\ 1
        \\ 2
        \\ 3
        \\
    , try patchOf(a, "top", "1\n2\n3\n4\n5\n", "zero\n1\n2\n3\n4\n5\n"));
    try t.expectEqualStrings(
        \\diff --git a/nonl b/nonl
        \\--- a/nonl
        \\+++ b/nonl
        \\@@ -1,2 +1,2 @@
        \\ x
        \\-y
        \\+y
        \\\ No newline at end of file
        \\
    , try patchOf(a, "nonl", "x\ny\n", "x\ny"));
    try t.expectEqualStrings(
        \\diff --git a/lastadd b/lastadd
        \\--- a/lastadd
        \\+++ b/lastadd
        \\@@ -1 +1,2 @@
        \\ k
        \\+l
        \\\ No newline at end of file
        \\
    , try patchOf(a, "lastadd", "k\n", "k\nl"));
    // an empty file made or removed is its header alone; one that was empty and is not has a hunk from line 0
    try t.expectEqualStrings("diff --git a/e b/e\nnew file mode 100644\n", try patchOf(a, "e", null, ""));
    try t.expectEqualStrings("diff --git a/e b/e\ndeleted file mode 100644\n", try patchOf(a, "e", "", null));
    try t.expectEqualStrings("diff --git a/e b/e\n--- a/e\n+++ b/e\n@@ -0,0 +1 @@\n+x\n", try patchOf(a, "e", "", "x\n"));
    // several files, one after another, in the order given
    try t.expectEqualStrings("diff --git a/x b/x\nnew file mode 100644\ndiff --git a/y b/y\ndeleted file mode 100644\n", try P.patchText(a, &.{
        .{ .path = "x", .before = null, .after = "" },
        .{ .path = "y", .before = "", .after = null },
    }, P.max_edits));
}

test "a path git would quote, and a file with a NUL byte, are refused: a text patch without quoting cannot carry them" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for ([_][]const u8{ "", "a b", "a\"b", "a\\b", "a\tb", "caf\xc3\xa9", "del\x7f" }) |p| {
        try t.expect(!P.plainPath(p));
        try t.expectError(P.PatchError.PathNeedsQuoting, patchOf(a, p, "x\n", "y\n"));
    }
    try t.expect(P.plainPath("third_party/buildrules/crate_sizes.tsv"));
    try t.expectError(P.PatchError.BinaryFile, patchOf(a, "b", "x\x00\n", "y\n"));
    try t.expectError(P.PatchError.BinaryFile, patchOf(a, "b", "x\n", "\x00"));
}

test "past the edit limit the changed middle is said as removed and added whole, and the patch still makes the new file" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const old = try P.lines(a, "h\na\nb\nc\nt\n");
    const new = try P.lines(a, "h\nb\nx\nt\n");
    // the shortest script: a removed, b kept, c removed and x added (3 edits)
    const best = try P.editScript(a, old, new, P.max_edits);
    try t.expectEqual(@as(usize, 6), best.len);
    const ops = [_]P.Op{ .same, .del, .same, .del, .ins, .same };
    for (ops, best) |o, e| try t.expectEqual(o, e.op);
    // with a limit of 1, the middle (a b c -> b x) whole
    const capped = try P.editScript(a, old, new, 1);
    const capped_ops = [_]P.Op{ .same, .del, .del, .del, .ins, .ins, .same };
    try t.expectEqual(capped_ops.len, capped.len);
    for (capped_ops, capped) |o, e| try t.expectEqual(o, e.op);
    try t.expectEqualStrings("@@ -1,5 +1,4 @@\n h\n-a\n-b\n-c\n+b\n+x\n t\n", try P.hunks(a, capped, P.context));
    // no change, no hunk
    try t.expectEqualStrings("", try P.hunks(a, try P.editScript(a, old, old, P.max_edits), P.context));
    try t.expectEqualStrings("", try P.hunks(a, &.{}, P.context));
}

test "lines keep their newlines, and the last one has none when the text does not end in one" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqual(@as(usize, 0), (try P.lines(a, "")).len);
    const l = try P.lines(a, "a\n\nb");
    try t.expectEqual(@as(usize, 3), l.len);
    try t.expectEqualStrings("a\n", l[0]);
    try t.expectEqualStrings("\n", l[1]);
    try t.expectEqualStrings("b", l[2]);
}

/// A tree of files under `tmp`, path -> bytes.
fn put(dir: std.fs.Dir, files: []const [2][]const u8) !void {
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |d| try dir.makePath(d);
        try dir.writeFile(.{ .sub_path = f[0], .data = f[1] });
    }
}

test "every patch applies to the old files and makes the new ones: a sweep of edits, each with and without the edit limit" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const r = prng.random();
    const alphabet = [_][]const u8{ "a\n", "b\n", "c\n", "\n", "d" };
    var case: usize = 0;
    while (case < 300) : (case += 1) {
        var bufs: [2]std.ArrayList(u8) = .{ .empty, .empty };
        for (&bufs) |*b| {
            const n = r.uintLessThan(usize, 40);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const piece = alphabet[r.uintLessThan(usize, alphabet.len)];
                // a line without its newline only last
                if (!std.mem.endsWith(u8, piece, "\n") and i + 1 != n) continue;
                try b.appendSlice(a, piece);
            }
        }
        const old = bufs[0].items;
        const new = bufs[1].items;
        if (std.mem.eql(u8, old, new)) continue;
        for ([_]usize{ P.max_edits, 2 }) |limit| {
            var tmp = std.testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            try put(tmp.dir, &.{.{ "d/f", old }});
            const patch = try P.patchText(a, &.{.{ .path = "d/f", .before = old, .after = new }}, limit);
            var failed: []const u8 = "";
            P.apply(a, tmp.dir, patch, &failed) catch |e| {
                std.debug.print("case {d} (limit {d}): {s} on {s}\nold:\n{s}\nnew:\n{s}\npatch:\n{s}\n", .{ case, limit, @errorName(e), failed, old, new, patch });
                return e;
            };
            try t.expectEqualStrings(new, try tmp.dir.readFileAlloc(a, "d/f", 1 << 20));
            try t.expectEqualStrings("", failed);
        }
    }
}

test "apply: files made (in a new directory), removed and changed, every one checked before any is written" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, &.{ .{ "keep", "1\n2\n3\n" }, .{ "gone", "x\n" }, .{ "empty", "" } });
    const patch = try P.patchText(a, &.{
        .{ .path = "empty", .before = "", .after = null },
        .{ .path = "gone", .before = "x\n", .after = null },
        .{ .path = "keep", .before = "1\n2\n3\n", .after = "1\ntwo\n3\n" },
        .{ .path = "new/dir/made", .before = null, .after = "m\n" },
        .{ .path = "top", .before = null, .after = "" },
    }, P.max_edits);
    var failed: []const u8 = "";
    try P.apply(a, tmp.dir, patch, &failed);
    try t.expectEqualStrings("1\ntwo\n3\n", try tmp.dir.readFileAlloc(a, "keep", 1 << 10));
    try t.expectEqualStrings("m\n", try tmp.dir.readFileAlloc(a, "new/dir/made", 1 << 10));
    try t.expectEqualStrings("", try tmp.dir.readFileAlloc(a, "top", 1 << 10));
    try t.expectError(error.FileNotFound, tmp.dir.access("gone", .{}));
    try t.expectError(error.FileNotFound, tmp.dir.access("empty", .{}));

    // the same patch again: `keep` no longer has the line it removes, and nothing is written, not even the files before it
    try put(tmp.dir, &.{ .{ "gone", "x\n" }, .{ "empty", "" } });
    try tmp.dir.deleteTree("new");
    try tmp.dir.deleteFile("top");
    try t.expectError(P.ApplyError.PatchDoesNotApply, P.apply(a, tmp.dir, patch, &failed));
    try t.expectEqualStrings("keep", failed);
    try tmp.dir.access("gone", .{});
    try tmp.dir.access("empty", .{});
}

test "apply refuses what does not fit: a file made that is there, a file changed or removed that is not, other lines, a removal that leaves lines" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, &.{ .{ "there", "t\n" }, .{ "long", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n" } });
    var failed: []const u8 = "";
    const cases = [_][]const u8{
        // made, but there
        "diff --git a/there b/there\nnew file mode 100644\n--- /dev/null\n+++ b/there\n@@ -0,0 +1 @@\n+t\n",
        // changed, but not there
        "diff --git a/absent b/absent\n--- a/absent\n+++ b/absent\n@@ -1 +1 @@\n-a\n+b\n",
        // removed, but not there
        "diff --git a/absent b/absent\ndeleted file mode 100644\n",
        // another line where the hunk says
        "diff --git a/there b/there\n--- a/there\n+++ b/there\n@@ -1 +1 @@\n-u\n+v\n",
        // a hunk past the end of the file
        "diff --git a/there b/there\n--- a/there\n+++ b/there\n@@ -3,0 +3 @@\n+v\n",
        // a hunk whose lines run past the end
        "diff --git a/there b/there\n--- a/there\n+++ b/there\n@@ -1,2 +1 @@\n t\n-u\n",
        // a hunk before the one ahead of it
        "diff --git a/long b/long\n--- a/long\n+++ b/long\n@@ -5 +5 @@\n-5\n+five\n@@ -2 +2 @@\n-2\n+two\n",
        // removed, but the file has more than the patch removes
        "diff --git a/long b/long\ndeleted file mode 100644\n--- a/long\n+++ /dev/null\n@@ -1 +0,0 @@\n-1\n",
    };
    for (cases) |c| {
        P.apply(a, tmp.dir, c, &failed) catch |e| {
            try t.expectEqual(P.ApplyError.PatchDoesNotApply, e);
            continue;
        };
        std.debug.print("applied, but should not have:\n{s}\n", .{c});
        return error.TestUnexpectedResult;
    }
    try t.expectEqualStrings("t\n", try tmp.dir.readFileAlloc(a, "there", 1 << 10));
    // a path that is a directory cannot be read, and the error is the read's
    try tmp.dir.makePath("adir");
    try t.expectError(error.IsDir, P.apply(a, tmp.dir, "diff --git a/adir b/adir\ndeleted file mode 100644\n", &failed));
    try t.expectEqualStrings("adir", failed);
}

test "apply refuses a patch not of the form the patch is written in" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, &.{.{ "f", "a\n" }});
    var failed: []const u8 = "";
    const cases = [_][]const u8{
        "not a patch\n",
        "diff --git a/f b/f",
        "diff --git a/ b/\n",
        "diff --git a/f b/gg\n",
        "diff --git a/f b/g\n",
        "diff --git a/f g b/f g\n",
        // a header alone, for a file neither made nor removed
        "diff --git a/f b/f\n",
        // the old name, then nothing
        "diff --git a/f b/f\n--- a/f\n",
        "diff --git a/f b/f\n--- a/g\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n",
        "diff --git a/f b/f\n--- a/f\n+++ b/g\n@@ -1 +1 @@\n-a\n+b\n",
        "diff --git a/f b/f\nnew file mode 100644\n--- a/f\n+++ b/f\n@@ -0,0 +1 @@\n+b\n",
        "diff --git a/f b/f\ndeleted file mode 100644\n--- a/f\n+++ b/f\n@@ -1 +0,0 @@\n-a\n",
        // no hunk
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n",
        // headers that are not `@@ -N[,M] +N[,M] @@`
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@ f()\n-a\n+b\n",
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 1 @@\n-a\n+b\n",
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -x +1 @@\n-a\n+b\n",
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,y +1 @@\n-a\n+b\n",
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,1,1 +1 @@\n-a\n+b\n",
        // a body shorter than its header, a line of no kind, an empty line, a last line without its newline
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n",
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n*a\n+b\n",
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n\n+b\n",
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b",
        // a body that removes more lines than its header says
        "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n-b\n+c\n",
    };
    for (cases) |c| {
        P.apply(a, tmp.dir, c, &failed) catch |e| {
            if (e != P.ApplyError.PatchMalformed) {
                std.debug.print("{s} for:\n{s}\n", .{ @errorName(e), c });
                return error.TestUnexpectedResult;
            }
            continue;
        };
        std.debug.print("applied, but should not have:\n{s}\n", .{c});
        return error.TestUnexpectedResult;
    }
    try t.expectEqualStrings("a\n", try tmp.dir.readFileAlloc(a, "f", 1 << 10));
    // the marker of a last line without a newline takes the newline off the line before it
    try P.apply(a, tmp.dir, "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file\n", &failed);
    try t.expectEqualStrings("b", try tmp.dir.readFileAlloc(a, "f", 1 << 10));
}

test "the verdict: none with no change, lock when Cargo.lock is among them, tables otherwise; each change by letter" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const m = P.Change{ .path = "buildrules.lock.bzl", .before = "1", .after = "2" };
    const n = P.Change{ .path = "third_party/buildrules/x", .before = null, .after = "x" };
    const d = P.Change{ .path = "third_party/buildrules/git_archives.tsv", .before = "x", .after = null };
    const l = P.Change{ .path = "Cargo.lock", .before = "1", .after = "2" };
    try t.expectEqual(P.Verdict.none, P.verdictOf(&.{}));
    try t.expectEqual(P.Verdict.tables, P.verdictOf(&.{ m, n, d }));
    try t.expectEqual(P.Verdict.lock, P.verdictOf(&.{ l, m }));
    try t.expectEqualStrings("tables\nM buildrules.lock.bzl\nA third_party/buildrules/x\nD third_party/buildrules/git_archives.tsv\n", try P.verdictText(a, .tables, &.{ m, n, d }));
    try t.expectEqualStrings("none\n", try P.verdictText(a, .none, &.{}));
}

test "verdict.txt read back, and every text not of its form refused" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = (try P.parseVerdict(a, "lock\nM Cargo.lock\nA x/y\nD z\n")).?;
    try t.expectEqual(P.Verdict.lock, r.verdict);
    try t.expectEqual(@as(usize, 3), r.entries.len);
    try t.expectEqual(@as(u8, 'A'), r.entries[1].letter);
    try t.expectEqualStrings("x/y", r.entries[1].path);
    try t.expectEqual(P.Verdict.none, (try P.parseVerdict(a, "none\n")).?.verdict);
    for ([_][]const u8{ "none", "\n", "maybe\n", "none\nM x\n", "tables\n", "tables\n\n", "tables\nMx\n", "tables\nM\n", "tables\nX x\n", "tables\nM a b\n", "tables\nM-x\n" }) |bad| {
        if (try P.parseVerdict(a, bad)) |_| {
            std.debug.print("read, but should not have: {s}\n", .{bad});
            return error.TestUnexpectedResult;
        }
    }
}

test "the place of the patch goes into a command line only as a run number, OWNER/NAME and a plain name" {
    const ok = P.Where{ .run = "123", .repository = "own-er/re_po.x", .artifact = "sync-patch" };
    try t.expect(P.badWhere(ok) == null);
    const cases = [_]struct { P.Where, []const u8 }{
        .{ .{ .run = "", .repository = "o/r", .artifact = "x" }, "--run must be the number of the run" },
        .{ .{ .run = "12a", .repository = "o/r", .artifact = "x" }, "--run must be the number of the run" },
        .{ .{ .run = "1", .repository = "or", .artifact = "x" }, "--repository must be OWNER/NAME" },
        .{ .{ .run = "1", .repository = "/r", .artifact = "x" }, "--repository must be OWNER/NAME" },
        .{ .{ .run = "1", .repository = "o/", .artifact = "x" }, "--repository must be OWNER/NAME" },
        .{ .{ .run = "1", .repository = "o/r/s", .artifact = "x" }, "--repository must be OWNER/NAME" },
        .{ .{ .run = "1", .repository = "o;rm/r", .artifact = "x" }, "--repository must be OWNER/NAME" },
        .{ .{ .run = "1", .repository = "o/r", .artifact = "" }, "--artifact must be a name of letters, digits, '-', '_' and '.'" },
        .{ .{ .run = "1", .repository = "o/r", .artifact = "a b" }, "--artifact must be a name of letters, digits, '-', '_' and '.'" },
    };
    for (cases) |c| try t.expectEqualStrings(c[1], P.badWhere(c[0]).?);
}

const where = P.Where{ .run = "77", .repository = "owner/repo", .artifact = "sync-patch" };

const commands =
    \\
    \\CI ran `buildrules sync` on the farm at this commit and made the patch; it is offered, never pushed. At the root of a checkout
    \\of this commit, fetch it and apply it, then commit and push:
    \\
    \\```sh
    \\gh run download 77 -R owner/repo -n sync-patch -D ../sync-patch-77
    \\git apply ../sync-patch-77/sync.patch
    \\```
    \\
    \\The patch:
    \\
    \\
;

test "the summary of stale tables only: the plain statement, the two commands, and the files" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const report = (try P.parseVerdict(a, "tables\nM buildrules.lock.bzl\nA third_party/buildrules/new\nD third_party/buildrules/git_archives.tsv\n")).?;
    try t.expectEqualStrings(
        \\### Generated tables: STALE, and only they
        \\
        \\Cargo.toml and Cargo.lock are as cargo resolves them; only the files `buildrules sync` generates lag behind them. Compile errors
        \\of the farm build in code that uses a dependency added since the last sync (an unresolved import, a crate that cannot be found)
        \\follow from the stale table, and go when it is regenerated.
        \\
    ++ commands ++
        \\- `buildrules.lock.bzl`
        \\- `third_party/buildrules/new` (new)
        \\- `third_party/buildrules/git_archives.tsv` (removed)
        \\
    , try P.summary(a, report, where));
}

test "the summary when Cargo.lock changed too, when nothing is stale, and when the patch could not be made" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings(
        \\### Generated tables: STALE, and Cargo.lock with them
        \\
        \\cargo changed Cargo.lock to resolve the manifests of this commit (the patch holds that Cargo.lock too), and the files
        \\`buildrules sync` generates lag behind both. Compile errors of the farm build in code that uses a dependency added since the last
        \\sync follow from the stale table; read the Cargo.lock part of the patch before you commit it.
        \\
    ++ commands ++
        \\- `Cargo.lock`
        \\- `buildrules.lock.bzl`
        \\
    , try P.summary(a, (try P.parseVerdict(a, "lock\nM Cargo.lock\nM buildrules.lock.bzl\n")).?, where));
    try t.expectEqualStrings(
        \\### Generated tables: up to date
        \\
        \\`buildrules sync` at this commit writes exactly the files it generates as they are committed: there is no patch to offer, and a
        \\failure of the farm build is not a stale table.
        \\
    , try P.summary(a, (try P.parseVerdict(a, "none\n")).?, where));
    try t.expectEqualStrings(
        \\### Generated tables: no patch
        \\
        \\The build of `//:sync_patch` (`buildrules sync` on the farm, at this commit) did not finish, so there is no patch to offer: its message
        \\is in the log of the step that built it. A sync on the farm resolves only the packages Cargo.lock names; a crate or a git commit
        \\Cargo.lock does not name yet is added by `buildrules sync` where there is a network.
        \\
    , try P.summary(a, null, where));
}

// ---- the command line, with a sync of the test's own ------------------------------------------------------------------------

/// The directory the fake sync and `real` resolve in (a test's tmpDir), and what the fake sync does.
var root: std.fs.Dir = undefined;
const Sync = enum { fails, errs, nothing, tables, lock, quoted, clash };
var sync_does: Sync = .nothing;
var sync_argv: []const []const u8 = &.{};
/// A path `fakeReal` cannot resolve.
var unreal: []const u8 = "";

fn fakeReal(a: std.mem.Allocator, p: []const u8) anyerror![]u8 {
    if (std.mem.eql(u8, p, unreal)) return error.Unreal;
    return root.realpathAlloc(a, p);
}

fn fakeSync(a: std.mem.Allocator, argv: []const []const u8) anyerror!u8 {
    sync_argv = try a.dupe([]const u8, argv);
    // argv: buildrules sync --dir WORK ...
    var work = try root.openDir(argv[3], .{});
    defer work.close();
    switch (sync_does) {
        .fails => return 1,
        .errs => return error.SyncDidNotStart,
        .nothing => {},
        .quoted => try work.writeFile(.{ .sub_path = "a b", .data = "x\n" }),
        // a file where the workspace has a directory: `collect` cannot compare them
        .clash => {
            try work.deleteTree("crates");
            try work.writeFile(.{ .sub_path = "crates", .data = "x\n" });
        },
        .tables => {
            try work.writeFile(.{ .sub_path = "buildrules.lock.bzl", .data = "table 2\n" });
            try work.writeFile(.{ .sub_path = "third_party/buildrules/crate_sizes.tsv", .data = "fnv 1.0.7 11266\n" });
            try work.deleteFile("third_party/buildrules/git_archives.tsv");
        },
        .lock => {
            try work.writeFile(.{ .sub_path = "Cargo.lock", .data = "lock 2\n" });
            try work.writeFile(.{ .sub_path = "buildrules.lock.bzl", .data = "table 2\n" });
        },
    }
    return 0;
}

const Ran = struct { code: u8, out: []const u8, err: []const u8 };

fn runIn(a: std.mem.Allocator, argv: []const []const u8) !Ran {
    var out = std.ArrayList(u8).empty;
    var err = std.ArrayList(u8).empty;
    const code = try P.run(a, root, argv, .{ .scratch = "scratch", .real = &fakeReal, .run = &fakeSync }, &out, &err);
    return .{ .code = code, .out = out.items, .err = err.items };
}

const make_argv = [_][]const u8{ "make", "--src", "ws", "--out", "out", "--buildrules", "tools/buildrules", "--cargo", "tools/cargo", "--sysroot", "tools/sysroot", "--pins", "tools/pins.bzl", "--sources", "tools/sources" };

fn workspace() !void {
    try put(root, &.{
        .{ "ws/Cargo.toml", "[workspace]\n" },
        .{ "ws/Cargo.lock", "lock 1\n" },
        .{ "ws/buildrules.lock.bzl", "table 1\n" },
        .{ "ws/third_party/buildrules/git_archives.tsv", "# record\n" },
        .{ "ws/third_party/buildrules/BUCK", "# units\n" },
        .{ "ws/crates/m/Cargo.toml", "[package]\n" },
        .{ "tools/buildrules", "" },
        .{ "tools/cargo/bin/cargo", "" },
        .{ "tools/sysroot/bin/rustc", "" },
        .{ "tools/pins.bzl", "" },
        .{ "tools/sources/x.crate", "" },
    });
}

test "make: stale tables only, as a patch that applies to the workspace, the files themselves, and the verdict; the sync ran as sync_stage runs it" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    root = tmp.dir;
    try workspace();
    sync_does = .tables;
    const r = try runIn(a, &make_argv);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("", r.err);
    try t.expectEqualStrings("tables\nM buildrules.lock.bzl\nA third_party/buildrules/crate_sizes.tsv\nD third_party/buildrules/git_archives.tsv\n", try root.readFileAlloc(a, "out/verdict.txt", 1 << 10));
    try t.expectEqualStrings(
        \\diff --git a/buildrules.lock.bzl b/buildrules.lock.bzl
        \\--- a/buildrules.lock.bzl
        \\+++ b/buildrules.lock.bzl
        \\@@ -1 +1 @@
        \\-table 1
        \\+table 2
        \\diff --git a/third_party/buildrules/crate_sizes.tsv b/third_party/buildrules/crate_sizes.tsv
        \\new file mode 100644
        \\--- /dev/null
        \\+++ b/third_party/buildrules/crate_sizes.tsv
        \\@@ -0,0 +1 @@
        \\+fnv 1.0.7 11266
        \\diff --git a/third_party/buildrules/git_archives.tsv b/third_party/buildrules/git_archives.tsv
        \\deleted file mode 100644
        \\--- a/third_party/buildrules/git_archives.tsv
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-# record
        \\
    , try root.readFileAlloc(a, "out/offer/sync.patch", 1 << 16));
    try t.expectEqualStrings("table 2\n", try root.readFileAlloc(a, "out/offer/files/buildrules.lock.bzl", 1 << 10));
    try t.expectEqualStrings("fnv 1.0.7 11266\n", try root.readFileAlloc(a, "out/offer/files/third_party/buildrules/crate_sizes.tsv", 1 << 10));
    // the patch, applied to the workspace, is the workspace the sync left
    var ws = try root.openDir("ws", .{ .iterate = true });
    defer ws.close();
    var failed: []const u8 = "";
    try P.apply(a, ws, try root.readFileAlloc(a, "out/offer/sync.patch", 1 << 16), &failed);
    try t.expectEqualStrings("table 2\n", try ws.readFileAlloc(a, "buildrules.lock.bzl", 1 << 10));
    try t.expectError(error.FileNotFound, ws.access("third_party/buildrules/git_archives.tsv", .{}));
    // sync_stage's command line, in the work directory under the scratch path
    try t.expectEqualStrings("sync", sync_argv[1]);
    try t.expectEqualStrings("--dir", sync_argv[2]);
    try t.expect(std.mem.endsWith(u8, sync_argv[3], "/scratch/workspace"));
    try t.expectEqualStrings("--sources", sync_argv[sync_argv.len - 2]);
    // a run on the synced workspace (into a new --out, as an action's is) offers nothing: offer/ is empty, and the verdict says so
    sync_does = .nothing;
    try root.deleteTree("ws");
    try root.rename("scratch/workspace", "ws");
    try root.deleteFile("ws/.buckconfig");
    var second = std.ArrayList([]const u8).empty;
    try second.appendSlice(a, &make_argv);
    second.items[4] = "out2";
    const again = try runIn(a, second.items);
    try t.expectEqual(@as(u8, 0), again.code);
    try t.expectEqualStrings("none\n", try root.readFileAlloc(a, "out2/verdict.txt", 1 << 10));
    try t.expectError(error.FileNotFound, root.access("out2/offer/sync.patch", .{}));
    var offered = try root.openDir("out2/offer/files", .{ .iterate = true });
    defer offered.close();
    var it = offered.iterate();
    const first_entry = try it.next();
    try t.expect(first_entry == null);
}

test "make: a Cargo.lock the sync changed is the verdict lock, and in the patch" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    root = tmp.dir;
    try workspace();
    sync_does = .lock;
    try t.expectEqual(@as(u8, 0), (try runIn(a, &make_argv)).code);
    try t.expectEqualStrings("lock\nM Cargo.lock\nM buildrules.lock.bzl\n", try root.readFileAlloc(a, "out/verdict.txt", 1 << 10));
    try t.expect(std.mem.startsWith(u8, try root.readFileAlloc(a, "out/offer/sync.patch", 1 << 16), "diff --git a/Cargo.lock b/Cargo.lock\n"));
}

test "make: a sync that fails is its status, said, with nothing written; bad command lines are status 2 with the usage" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    root = tmp.dir;
    try workspace();
    sync_does = .fails;
    const r = try runIn(a, &make_argv);
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("sync_patch: `buildrules sync` exited 1: there is no patch to offer (its message is above)\n", r.err);
    try t.expectError(error.FileNotFound, root.access("out", .{}));

    const missing = try runIn(a, &.{ "make", "--src", "ws" });
    try t.expectEqual(@as(u8, 2), missing.code);
    try t.expectEqualStrings("sync_patch make: MissingFlag\n" ++ P.usage, missing.err);
    var checked = std.ArrayList([]const u8).empty;
    try checked.appendSlice(a, &make_argv);
    try checked.append(a, "--check");
    const check = try runIn(a, checked.items);
    try t.expectEqual(@as(u8, 2), check.code);
    try t.expectEqualStrings("sync_patch make: --check is sync_stage's (the patch is the comparison)\n" ++ P.usage, check.err);
    for ([_][]const []const u8{ &.{}, &.{"patch"} }) |argv| {
        const u = try runIn(a, argv);
        try t.expectEqual(@as(u8, 2), u.code);
        try t.expectEqualStrings(P.usage, u.err);
    }
}

test "summary: to standard output and appended to the job summary; a missing verdict is status 1 and said; bad input is status 2" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    root = tmp.dir;
    try put(root, &.{ .{ "p/verdict.txt", "none\n" }, .{ "summary.md", "earlier\n" }, .{ "bad/verdict.txt", "nonsense\n" } });
    const args = [_][]const u8{ "summary", "--dir", "p", "--run", "77", "--repository", "owner/repo", "--artifact", "sync-patch", "--to", "summary.md" };
    const r = try runIn(a, &args);
    try t.expectEqual(@as(u8, 0), r.code);
    const none = try P.summary(a, (try P.parseVerdict(a, "none\n")).?, where);
    try t.expectEqualStrings(none, r.out);
    try t.expectEqualStrings(try std.mem.concat(a, u8, &.{ "earlier\n", none }), try root.readFileAlloc(a, "summary.md", 1 << 16));
    // no verdict (the build of the patch failed, so `--out` wrote nothing): said, status 1; without --to, standard output only
    const gone = try runIn(a, &.{ "summary", "--dir", "absent", "--run", "77", "--repository", "owner/repo", "--artifact", "sync-patch" });
    try t.expectEqual(@as(u8, 1), gone.code);
    try t.expectEqualStrings(try P.summary(a, null, where), gone.out);
    // a verdict not of its form
    const bad = try runIn(a, &.{ "summary", "--dir", "bad", "--run", "77", "--repository", "owner/repo", "--artifact", "sync-patch" });
    try t.expectEqual(@as(u8, 2), bad.code);
    try t.expectEqualStrings("sync_patch summary: bad/verdict.txt is not what `sync_patch make` writes\n", bad.err);
    // a value that cannot go into the commands
    const run_bad = try runIn(a, &.{ "summary", "--dir", "p", "--run", "x", "--repository", "owner/repo", "--artifact", "sync-patch" });
    try t.expectEqual(@as(u8, 2), run_bad.code);
    try t.expectEqualStrings("sync_patch summary: --run must be the number of the run\n", run_bad.err);
    // flags
    for ([_]struct { []const []const u8, []const u8 }{
        .{ &.{ "summary", "--dir" }, "MissingValue" },
        .{ &.{ "summary", "--nope", "x" }, "UnknownFlag" },
        .{ &.{ "summary", "--run", "1" }, "MissingFlag" },
    }) |c| {
        const u = try runIn(a, c[0]);
        try t.expectEqual(@as(u8, 2), u.code);
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "sync_patch summary: {s}\n{s}", .{ c[1], P.usage }), u.err);
    }
    // a --dir that is a file cannot be read into, and the error is the read's
    try t.expectError(error.NotDir, runIn(a, &.{ "summary", "--dir", "summary.md", "--run", "77", "--repository", "owner/repo", "--artifact", "sync-patch" }));
}

test "gather: the sync's files with the workspace's bytes, a removed file with its bytes, in path order, directories skipped" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, &.{ .{ "src/b", "b1\n" }, .{ "src/z", "z\n" }, .{ "files/b", "b2\n" }, .{ "files/d/a", "new\n" } });
    var src = try tmp.dir.openDir("src", .{ .iterate = true });
    defer src.close();
    var files = try tmp.dir.openDir("files", .{ .iterate = true });
    defer files.close();
    const c = try P.gather(a, src, files, &.{"z"});
    try t.expectEqual(@as(usize, 3), c.len);
    try t.expectEqualStrings("b", c[0].path);
    try t.expectEqualStrings("b1\n", c[0].before.?);
    try t.expectEqualStrings("b2\n", c[0].after.?);
    try t.expectEqualStrings("d/a", c[1].path);
    try t.expect(c[1].before == null);
    try t.expectEqual(@as(u8, 'A'), c[1].letter());
    try t.expectEqualStrings("z", c[2].path);
    try t.expect(c[2].after == null);
    try t.expectEqual(@as(u8, 'D'), c[2].letter());
    try t.expectEqual(@as(u8, 'M'), c[0].letter());
    // a path of the sync's that is a directory in the workspace cannot be read, and the error is the read's
    try tmp.dir.makePath("src/q");
    try tmp.dir.writeFile(.{ .sub_path = "files/q", .data = "file\n" });
    try t.expectError(error.IsDir, P.gather(a, src, files, &.{}));
}

/// A new work directory and a new --out for the next run.
fn fresh() !void {
    try root.deleteTree("scratch");
    try root.deleteTree("out");
}

test "make: every error of the file system, of the sync and of the patch is the caller's, and the command line says nothing of its own" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    root = tmp.dir;
    try workspace();
    // each run with a new work directory and a new --out, as an action has them
    // the sync cannot start
    sync_does = .errs;
    try t.expectError(error.SyncDidNotStart, runIn(a, &make_argv));
    try fresh();
    // a path of a pinned tool, or the work directory, that does not resolve
    sync_does = .nothing;
    unreal = "tools/pins.bzl";
    try t.expectError(error.Unreal, runIn(a, &make_argv));
    try fresh();
    unreal = "scratch/workspace";
    try t.expectError(error.Unreal, runIn(a, &make_argv));
    try fresh();
    unreal = "";
    // a file the sync wrote whose path a patch cannot carry
    sync_does = .quoted;
    try t.expectError(P.PatchError.PathNeedsQuoting, runIn(a, &make_argv));
    try fresh();
    // a file of the sync's where the workspace has a directory
    sync_does = .clash;
    try t.expectError(error.IsDir, runIn(a, &make_argv));
    try fresh();
    // offer/ of --out is a file: offer/files cannot be made
    sync_does = .nothing;
    try put(root, &.{.{ "out/offer", "" }});
    if (runIn(a, &make_argv)) |_| return error.TestUnexpectedResult else |_| {}
    try fresh();
    // the patch cannot be written (a directory is where it goes)
    sync_does = .tables;
    try root.makePath("out/offer/sync.patch");
    try t.expectError(error.IsDir, runIn(a, &make_argv));
    try fresh();
    // the verdict cannot be written (a directory is where it goes)
    sync_does = .nothing;
    try root.makePath("out/verdict.txt");
    try t.expectError(error.IsDir, runIn(a, &make_argv));
    try fresh();
    // --out is a file
    try root.writeFile(.{ .sub_path = "outfile", .data = "" });
    var to_file = std.ArrayList([]const u8).empty;
    try to_file.appendSlice(a, &make_argv);
    to_file.items[4] = "outfile";
    if (runIn(a, to_file.items)) |_| return error.TestUnexpectedResult else |_| {}
    // --src is not there
    var no_src = std.ArrayList([]const u8).empty;
    try no_src.appendSlice(a, &make_argv);
    no_src.items[2] = "absent";
    try t.expectError(error.FileNotFound, runIn(a, no_src.items));
    // a link in the workspace to nothing: the copy of the workspace fails
    try root.symLink("nowhere", "ws/dangling", .{});
    try t.expectError(error.FileNotFound, runIn(a, &make_argv));
    try root.deleteFile("ws/dangling");
    try fresh();
    // the scratch path is a file: the work directory cannot be made
    try root.writeFile(.{ .sub_path = "scratch", .data = "" });
    if (runIn(a, &make_argv)) |_| return error.TestUnexpectedResult else |_| {}
}

test "apply: a patch that names one file twice fails at the write, the error is the file system's, and `failed` names the file" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, &.{.{ "x", "" }});
    var failed: []const u8 = "";
    // removed twice: the second removal finds nothing
    const twice = "diff --git a/x b/x\ndeleted file mode 100644\ndiff --git a/x b/x\ndeleted file mode 100644\n";
    try t.expectError(error.FileNotFound, P.apply(a, tmp.dir, twice, &failed));
    try t.expectEqualStrings("x", failed);
    // a file made in a directory q, then a file made at q: the second write finds a directory
    const q = "diff --git a/q/r b/q/r\nnew file mode 100644\ndiff --git a/q b/q\nnew file mode 100644\n";
    try t.expectError(error.IsDir, P.apply(a, tmp.dir, q, &failed));
    try t.expectEqualStrings("q", failed);
    // a file made at s, then one in a directory s: the directory cannot be made
    const s2 = "diff --git a/s b/s\nnew file mode 100644\ndiff --git a/s/t b/s/t\nnew file mode 100644\n";
    if (P.apply(a, tmp.dir, s2, &failed)) |_| return error.TestUnexpectedResult else |_| {}
    try t.expectEqualStrings("s/t", failed);
}

test "summary: a job summary that cannot be opened is the caller's error" {
    var ar = Arena.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    root = tmp.dir;
    try put(root, &.{.{ "p/verdict.txt", "none\n" }});
    try t.expectError(error.FileNotFound, runIn(a, &.{ "summary", "--dir", "p", "--run", "1", "--repository", "o/r", "--artifact", "x", "--to", "no/such/dir/summary.md" }));
    // a job summary that is a directory cannot be read to append to
    try root.makePath("adir");
    try t.expectError(error.IsDir, runIn(a, &.{ "summary", "--dir", "p", "--run", "1", "--repository", "o/r", "--artifact", "x", "--to", "adir" }));
}

// ---- every allocation that fails is an error of the caller's ----------------------------------------------------------------

/// Runs `f` with an allocator whose n-th allocation fails, for n = 0, 1, ... until `f` succeeds: every allocation `f` makes fails once,
/// and each failure must come back as error.OutOfMemory.
fn everyAllocationFails(f: *const fn (std.mem.Allocator) anyerror!void) !void {
    var backing = Arena.init(std.heap.page_allocator);
    defer backing.deinit();
    var n: usize = 0;
    while (n < 1_000_000) : (n += 1) {
        _ = backing.reset(.retain_capacity);
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = n });
        f(failing.allocator()) catch |e| {
            if (e == error.OutOfMemory) continue;
            return e;
        };
        return;
    }
    return error.TestUnexpectedResult;
}

fn patchAndApply(a: std.mem.Allocator) anyerror!void {
    const changes = [_]P.Change{
        .{ .path = "e", .before = null, .after = "" },
        .{ .path = "far", .before = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n", .after = "1\ntwo\n3\n4\n5\n6\n7\n8\n9\n10\n11\ntwelve" },
        .{ .path = "gone", .before = "a\n", .after = null },
        .{ .path = "made/f", .before = null, .after = "m\n" },
    };
    // the empty file first: each way of adding a file's part to the patch adds it to an empty patch once
    const patch = try P.patchText(a, &changes, P.max_edits);
    const capped = try P.patchText(a, changes[1..2], 1);
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, &.{ .{ "far", changes[1].before.? }, .{ "gone", "a\n" } });
    var failed: []const u8 = "";
    try P.apply(a, tmp.dir, patch, &failed);
    try put(tmp.dir, &.{.{ "far", changes[1].before.? }});
    try P.apply(a, tmp.dir, capped, &failed);
}

fn verdictAndSummaries(a: std.mem.Allocator) anyerror!void {
    for ([_][]const u8{ "none\n", "tables\nM x\nA y\nD z\n", "lock\nM Cargo.lock\n" }) |text| {
        _ = try P.summary(a, (try P.parseVerdict(a, text)).?, where);
    }
    _ = try P.summary(a, null, where);
    _ = try P.verdictText(a, .tables, &.{.{ .path = "x", .before = "1", .after = "2" }});
}

fn commandLines(a: std.mem.Allocator) anyerror!void {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    root = tmp.dir;
    try workspace();
    sync_does = .tables;
    _ = try runIn(a, &make_argv);
    sync_does = .fails;
    _ = try runIn(a, &make_argv);
    _ = try runIn(a, &.{ "make", "--src" });
    var checked = std.ArrayList([]const u8).empty;
    try checked.appendSlice(a, &make_argv);
    try checked.append(a, "--check");
    _ = try runIn(a, checked.items);
    _ = try runIn(a, &.{});
    try put(root, &.{.{ "bad/verdict.txt", "?\n" }});
    for ([_][]const []const u8{
        &.{ "summary", "--dir", "out", "--run", "1", "--repository", "o/r", "--artifact", "x", "--to", "s.md" },
        // again: now appended to what the first wrote
        &.{ "summary", "--dir", "out", "--run", "1", "--repository", "o/r", "--artifact", "x", "--to", "s.md" },
        &.{ "summary", "--dir", "absent", "--run", "1", "--repository", "o/r", "--artifact", "x" },
        &.{ "summary", "--dir", "bad", "--run", "1", "--repository", "o/r", "--artifact", "x" },
        &.{ "summary", "--dir", "out", "--run", "x", "--repository", "o/r", "--artifact", "x" },
        &.{ "summary", "--nope", "x" },
    }) |argv| _ = try runIn(a, argv);
}

fn gathering(a: std.mem.Allocator) anyerror!void {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try put(tmp.dir, &.{ .{ "src/b", "1\n" }, .{ "src/z", "z\n" }, .{ "files/b", "2\n" }, .{ "files/d/a", "n\n" } });
    var src = try tmp.dir.openDir("src", .{ .iterate = true });
    defer src.close();
    var files = try tmp.dir.openDir("files", .{ .iterate = true });
    defer files.close();
    _ = try P.gather(a, src, files, &.{"z"});
    // removed files alone: the list of changes starts with them
    try tmp.dir.makePath("none");
    var nothing = try tmp.dir.openDir("none", .{ .iterate = true });
    defer nothing.close();
    _ = try P.gather(a, src, nothing, &.{"z"});
}

test "an allocation that fails anywhere is error.OutOfMemory: the patch, applying it, the verdict, the summaries, gather and both commands" {
    try everyAllocationFails(&patchAndApply);
    try everyAllocationFails(&verdictAndSummaries);
    try everyAllocationFails(&commandLines);
    try everyAllocationFails(&gathering);
}
