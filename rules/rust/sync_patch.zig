//! sync_patch: `buildrules sync` on the farm, as a patch to offer when a workspace's generated files are stale (rules/rust/sync.bzl,
//! the `:sync_patch` target of every cargo_workspace).
//!
//! usage: sync_patch make --src DIR --out DIR --buildrules EXE --cargo DIR --sysroot DIR --pins FILE [--sources DIR]
//!        sync_patch summary --dir DIR --run ID --repository OWNER/NAME --artifact NAME [--to FILE]
//!
//! `make` stages and syncs the workspace `--src` as sync_stage does (its `stage`, `syncArgv` and `collect`: the same copy, the same command
//! line, the same files collected), and writes into `--out`:
//!   verdict.txt        the verdict on its first line, then one line per file the sync changed: `M` (changed), `A` (made) or `D` (removed),
//!                      a space and the path;
//!   offer/sync.patch   every change as one patch `git apply` takes, its paths relative to the workspace root;
//!   offer/files/       the files the sync wrote or changed, at their paths (what `buck2 build //:sync --out .` writes).
//! There is no `offer/` when the verdict is `none`. The verdicts:
//!   none     the sync writes what the workspace holds: nothing to offer;
//!   tables   the sync changed only the files it generates: Cargo.toml and Cargo.lock are as cargo resolves them, and the generated table
//!            alone is stale (so the compile errors of a build that reads it follow from it);
//!   lock     cargo changed Cargo.lock as well, to resolve the manifests (the patch holds that Cargo.lock too).
//! When the sync fails, `make` exits with its status, its message is its own, and nothing is written.
//!
//! `summary` reads that directory (made by `buck2 build //:sync_patch --out DIR`) and says, as markdown, the verdict and, when there is a
//! patch, the two commands that fetch and apply it: `gh run download` of the artifact `--artifact` of the run `--run` of `--repository`
//! (the artifact holds `offer/`), and `git apply`. The text goes to standard output, and is appended to `--to` (a job summary) when given.
//! A directory without verdict.txt (the build of the patch failed) is said as such, and the status is 1.

const std = @import("std");
const stage = @import("sync_stage.zig");
const Allocator = std.mem.Allocator;

pub const usage =
    \\usage: sync_patch make --src DIR --out DIR --buildrules EXE --cargo DIR --sysroot DIR --pins FILE [--sources DIR]
    \\       sync_patch summary --dir DIR --run ID --repository OWNER/NAME --artifact NAME [--to FILE]
    \\
;

/// The files `make` writes, relative to `--out`.
pub const verdict_file = "verdict.txt";
pub const offer_dir = "offer";
pub const patch_file = "offer/sync.patch";
pub const files_dir = "offer/files";

/// The lines of context around each change, as `git diff` has them.
pub const context = 3;

/// The most edits the shortest edit script of one file is searched for; past it, the changed middle of the file is said as all of its old
/// lines removed and all of its new ones added (exact all the same, only longer). The search keeps about `d * d` positions (some 32 MB at the limit).
pub const max_edits = 2000;

pub const Verdict = enum { none, tables, lock };

/// One file the sync changed.
pub const Change = struct {
    path: []const u8,
    /// The workspace's bytes; null for a file the sync made.
    before: ?[]const u8,
    /// The sync's bytes; null for a file the sync removed.
    after: ?[]const u8,

    pub fn letter(c: Change) u8 {
        if (c.before == null) return 'A';
        if (c.after == null) return 'D';
        return 'M';
    }
};

/// `none` for no change; `lock` when Cargo.lock is among them; `tables` otherwise.
pub fn verdictOf(changes: []const Change) Verdict {
    if (changes.len == 0) return .none;
    for (changes) |c| {
        if (std.mem.eql(u8, std.fs.path.basename(c.path), "Cargo.lock")) return .lock;
    }
    return .tables;
}

// ---- lines and the edit script ----------------------------------------------------------------------------------------------

/// The lines of `text`, each with its newline; the last one has none when the text does not end in one.
pub fn lines(a: Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var start: usize = 0;
    while (start < text.len) {
        const end = if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |i| i + 1 else text.len;
        try out.append(a, text[start..end]);
        start = end;
    }
    return out.items;
}

pub const Op = enum { same, del, ins };

pub const Edit = struct { op: Op, line: []const u8 };

/// A shortest edit script from `old` to `new`: the common head and tail, and between them Myers' greedy search for the fewest lines
/// removed and added. When that middle needs more than `max_d` edits, it is said as all of its old lines removed and all of its new ones
/// added. Lines are compared with their newlines, so a last line that gains or loses one is a change.
pub fn editScript(a: Allocator, old: []const []const u8, new: []const []const u8, max_d: usize) ![]const Edit {
    var head: usize = 0;
    while (head < old.len and head < new.len and std.mem.eql(u8, old[head], new[head])) head += 1;
    var tail: usize = 0;
    while (tail < old.len - head and tail < new.len - head and std.mem.eql(u8, old[old.len - 1 - tail], new[new.len - 1 - tail])) tail += 1;
    var out = std.ArrayList(Edit).empty;
    for (old[0..head]) |l| try out.append(a, .{ .op = .same, .line = l });
    try middle(a, &out, old[head .. old.len - tail], new[head .. new.len - tail], max_d);
    for (old[old.len - tail ..]) |l| try out.append(a, .{ .op = .same, .line = l });
    return out.items;
}

fn at(off: isize, k: isize) usize {
    return @intCast(off + k);
}

/// Myers' search over `o` -> `n`, whose first and last lines differ (the caller took the common ones off).
fn middle(a: Allocator, out: *std.ArrayList(Edit), o: []const []const u8, n: []const []const u8, max_d: usize) !void {
    const len_o: isize = @intCast(o.len);
    const len_n: isize = @intCast(n.len);
    const most = len_o + len_n;
    if (most == 0) return;
    // v[at(off, k)]: the furthest x reached on diagonal k (y = x - k). trace.items[d]: v over k = -d..d as it was before step d.
    const off = most + 1;
    const v = try a.alloc(isize, @intCast(2 * most + 3));
    @memset(v, 0);
    var trace = std.ArrayList([]const isize).empty;
    var d: isize = 0;
    while (true) : (d += 1) {
        if (d > @as(isize, @intCast(max_d))) {
            for (o) |l| try out.append(a, .{ .op = .del, .line = l });
            for (n) |l| try out.append(a, .{ .op = .ins, .line = l });
            return;
        }
        const snap = try a.dupe(isize, v[at(off, -d)..at(off, d + 1)]);
        try trace.append(a, snap);
        var k: isize = -d;
        while (k <= d) : (k += 2) {
            var x = if (k == -d or (k != d and v[at(off, k - 1)] < v[at(off, k + 1)])) v[at(off, k + 1)] else v[at(off, k - 1)] + 1;
            var y = x - k;
            while (x < len_o and y < len_n and std.mem.eql(u8, o[@intCast(x)], n[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[at(off, k)] = x;
            if (x >= len_o and y >= len_n) return backtrack(a, out, o, n, trace.items, d);
        }
    }
}

/// The edits of the path Myers' search found in `d` steps, from its trace, in order.
fn backtrack(a: Allocator, out: *std.ArrayList(Edit), o: []const []const u8, n: []const []const u8, trace: []const []const isize, d: isize) !void {
    var rev = std.ArrayList(Edit).empty;
    var x: isize = @intCast(o.len);
    var y: isize = @intCast(n.len);
    var step = d;
    while (step > 0) : (step -= 1) {
        const snap = trace[@intCast(step)];
        const k = x - y;
        const down = k == -step or (k != step and snap[at(step, k - 1)] < snap[at(step, k + 1)]);
        const pk = if (down) k + 1 else k - 1;
        const px = snap[at(step, pk)];
        const py = px - pk;
        while (x > px and y > py) {
            x -= 1;
            y -= 1;
            try rev.append(a, .{ .op = .same, .line = o[@intCast(x)] });
        }
        if (down) {
            try rev.append(a, .{ .op = .ins, .line = n[@intCast(py)] });
        } else {
            try rev.append(a, .{ .op = .del, .line = o[@intCast(px)] });
        }
        x = px;
        y = py;
    }
    // The first lines of `o` and `n` differ (the caller took the common head off), so step 0 had no snake: the path is back at (0, 0).
    var i = rev.items.len;
    while (i > 0) {
        i -= 1;
        try out.append(a, rev.items[i]);
    }
}

// ---- the patch --------------------------------------------------------------------------------------------------------------

/// `start,count` of a hunk header as git writes it: the count left out when it is 1, and the start of an empty range the line before it.
fn range(a: Allocator, before: usize, count: usize) ![]u8 {
    if (count == 1) return std.fmt.allocPrint(a, "{d}", .{before + 1});
    return std.fmt.allocPrint(a, "{d},{d}", .{ if (count == 0) before else before + 1, count });
}

fn line(a: Allocator, out: *std.ArrayList(u8), mark: u8, text: []const u8) !void {
    try out.append(a, mark);
    try out.appendSlice(a, text);
    if (!std.mem.endsWith(u8, text, "\n")) try out.appendSlice(a, "\n\\ No newline at end of file\n");
}

/// The hunks of `edits` with `ctx` lines of context: two changes are one hunk when at most `2 * ctx` unchanged lines are between them.
pub fn hunks(a: Allocator, out: *std.ArrayList(u8), edits: []const Edit, ctx: usize) !void {
    // old_at[i], new_at[i]: the old and the new lines before edits[i]
    const old_at = try a.alloc(usize, edits.len + 1);
    const new_at = try a.alloc(usize, edits.len + 1);
    old_at[0] = 0;
    new_at[0] = 0;
    for (edits, 0..) |e, i| {
        old_at[i + 1] = old_at[i] + @intFromBool(e.op != .ins);
        new_at[i + 1] = new_at[i] + @intFromBool(e.op != .del);
    }
    var i: usize = 0;
    while (true) {
        while (i < edits.len and edits[i].op == .same) i += 1;
        if (i == edits.len) return;
        var last = i;
        var j = i + 1;
        while (j < edits.len and j - last <= 2 * ctx + 1) : (j += 1) {
            if (edits[j].op != .same) last = j;
        }
        const start = i - @min(i, ctx);
        const end = @min(edits.len, last + 1 + ctx);
        const old_n = old_at[end] - old_at[start];
        const new_n = new_at[end] - new_at[start];
        const head = try std.fmt.allocPrint(a, "@@ -{s} +{s} @@\n", .{ try range(a, old_at[start], old_n), try range(a, new_at[start], new_n) });
        try out.appendSlice(a, head);
        for (edits[start..end]) |e| try line(a, out, switch (e.op) {
            .same => ' ',
            .del => '-',
            .ins => '+',
        }, e.line);
        i = end;
    }
}

pub const PatchError = error{
    /// A path git would quote (a space, a quote, a backslash, a control or a non-ASCII byte): the patch would need its quoting rules.
    PathNeedsQuoting,
    /// A file with a NUL byte, which a text patch cannot carry.
    BinaryFile,
};

/// Whether `path` is written as it is in a patch: no byte git would quote, and not empty.
pub fn plainPath(path: []const u8) bool {
    if (path.len == 0) return false;
    for (path) |c| {
        if (c <= ' ' or c >= 0x7f or c == '"' or c == '\\') return false;
    }
    return true;
}

/// The part of the patch for one file, in git's form (without the `index` line and the function context after a hunk's `@@`, which
/// `git apply` does not need).
pub fn filePatch(a: Allocator, out: *std.ArrayList(u8), c: Change, max_d: usize) !void {
    if (!plainPath(c.path)) return PatchError.PathNeedsQuoting;
    const old = c.before orelse "";
    const new = c.after orelse "";
    if (std.mem.indexOfScalar(u8, old, 0) != null or std.mem.indexOfScalar(u8, new, 0) != null) return PatchError.BinaryFile;
    try out.appendSlice(a, try std.fmt.allocPrint(a, "diff --git a/{s} b/{s}\n", .{ c.path, c.path }));
    if (c.before == null) try out.appendSlice(a, "new file mode 100644\n");
    if (c.after == null) try out.appendSlice(a, "deleted file mode 100644\n");
    // An empty file made or removed: the header is all of it.
    if (old.len == 0 and new.len == 0) return;
    const from = if (c.before == null) "/dev/null" else try std.fmt.allocPrint(a, "a/{s}", .{c.path});
    const to = if (c.after == null) "/dev/null" else try std.fmt.allocPrint(a, "b/{s}", .{c.path});
    try out.appendSlice(a, try std.fmt.allocPrint(a, "--- {s}\n+++ {s}\n", .{ from, to }));
    try hunks(a, out, try editScript(a, try lines(a, old), try lines(a, new), max_d), context);
}

/// Every change, in the order given (`gather` sorts them by path), as one patch.
pub fn patchText(a: Allocator, changes: []const Change, max_d: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (changes) |c| try filePatch(a, &out, c, max_d);
    return out.items;
}

// ---- applying a patch -------------------------------------------------------------------------------------------------------

pub const ApplyError = error{
    /// Not the form `filePatch` writes.
    PatchMalformed,
    /// A line the patch keeps or removes is not the file's line there, a file it makes is there already, or one it changes is not.
    PatchDoesNotApply,
};

const Hunk = struct { old_start: usize, old_count: usize, new_start: usize, new_count: usize, body: []const Edit };

const FilePatch = struct { path: []const u8, made: bool, removed: bool, hunks: []const Hunk };

/// `N` or `N,M` of a hunk header (`M` is 1 when left out).
fn parseRange(text: []const u8) ApplyError![2]usize {
    var it = std.mem.splitScalar(u8, text, ',');
    const s = it.next().?;
    const c = it.next();
    if (it.next() != null) return ApplyError.PatchMalformed;
    const start = std.fmt.parseUnsigned(usize, s, 10) catch return ApplyError.PatchMalformed;
    const count = if (c) |t| std.fmt.parseUnsigned(usize, t, 10) catch return ApplyError.PatchMalformed else 1;
    return .{ start, count };
}

fn parseHeader(h: []const u8) ApplyError!Hunk {
    if (!std.mem.startsWith(u8, h, "@@ -") or !std.mem.endsWith(u8, h, " @@\n")) return ApplyError.PatchMalformed;
    const mid = h["@@ -".len .. h.len - " @@\n".len];
    const sp = std.mem.indexOf(u8, mid, " +") orelse return ApplyError.PatchMalformed;
    const o = try parseRange(mid[0..sp]);
    const n = try parseRange(mid[sp + 2 ..]);
    return .{ .old_start = o[0], .old_count = o[1], .new_start = n[0], .new_count = n[1], .body = &.{} };
}

const no_newline = "\\ No newline at end of file\n";

/// The file patches of `patch`, which must be of the form `patchText` writes.
fn parse(a: Allocator, patch: []const u8) ![]const FilePatch {
    const pl = try lines(a, patch);
    var files = std.ArrayList(FilePatch).empty;
    var i: usize = 0;
    while (i < pl.len) {
        const prefix = "diff --git a/";
        const h = pl[i];
        if (!std.mem.startsWith(u8, h, prefix) or !std.mem.endsWith(u8, h, "\n")) return ApplyError.PatchMalformed;
        const both = h[prefix.len .. h.len - 1];
        // `P b/P`: P is the first (len - 3) / 2 bytes
        if (both.len < 4 or (both.len - 3) % 2 != 0) return ApplyError.PatchMalformed;
        const path = both[0 .. (both.len - 3) / 2];
        if (!std.mem.eql(u8, both[path.len..], try std.fmt.allocPrint(a, " b/{s}", .{path})) or !plainPath(path)) return ApplyError.PatchMalformed;
        i += 1;
        var fp = FilePatch{ .path = path, .made = false, .removed = false, .hunks = &.{} };
        if (i < pl.len and std.mem.eql(u8, pl[i], "new file mode 100644\n")) {
            fp.made = true;
            i += 1;
        } else if (i < pl.len and std.mem.eql(u8, pl[i], "deleted file mode 100644\n")) {
            fp.removed = true;
            i += 1;
        }
        if (i < pl.len and std.mem.startsWith(u8, pl[i], "--- ")) {
            const from = if (fp.made) "--- /dev/null\n" else try std.fmt.allocPrint(a, "--- a/{s}\n", .{path});
            const to = if (fp.removed) "+++ /dev/null\n" else try std.fmt.allocPrint(a, "+++ b/{s}\n", .{path});
            if (!std.mem.eql(u8, pl[i], from) or i + 1 >= pl.len or !std.mem.eql(u8, pl[i + 1], to)) return ApplyError.PatchMalformed;
            i += 2;
            var hs = std.ArrayList(Hunk).empty;
            while (i < pl.len and std.mem.startsWith(u8, pl[i], "@@ ")) {
                var hunk = try parseHeader(pl[i]);
                i += 1;
                var body = std.ArrayList(Edit).empty;
                var olds: usize = 0;
                var news: usize = 0;
                while (olds < hunk.old_count or news < hunk.new_count) {
                    if (i >= pl.len or pl[i].len < 2 or !std.mem.endsWith(u8, pl[i], "\n")) return ApplyError.PatchMalformed;
                    const op: Op = switch (pl[i][0]) {
                        ' ' => .same,
                        '-' => .del,
                        '+' => .ins,
                        else => return ApplyError.PatchMalformed,
                    };
                    var text = pl[i][1..];
                    i += 1;
                    if (i < pl.len and std.mem.eql(u8, pl[i], no_newline)) {
                        text = text[0 .. text.len - 1];
                        i += 1;
                    }
                    olds += @intFromBool(op != .ins);
                    news += @intFromBool(op != .del);
                    try body.append(a, .{ .op = op, .line = text });
                }
                if (olds != hunk.old_count or news != hunk.new_count) return ApplyError.PatchMalformed;
                hunk.body = body.items;
                try hs.append(a, hunk);
            }
            if (hs.items.len == 0) return ApplyError.PatchMalformed;
            fp.hunks = hs.items;
        } else if (!fp.made and !fp.removed) {
            return ApplyError.PatchMalformed;
        }
        try files.append(a, fp);
    }
    return files.items;
}

/// The file `fp` makes of `before` (null: there is no such file); empty when it removes the file. Strict: every line it keeps or removes
/// must be the file's line at the place its hunk header says.
fn applyOne(a: Allocator, before: ?[]const u8, fp: FilePatch) ![]const u8 {
    if (fp.made != (before == null)) return ApplyError.PatchDoesNotApply;
    const old = try lines(a, before orelse "");
    var out = std.ArrayList(u8).empty;
    var cursor: usize = 0;
    for (fp.hunks) |h| {
        const at_line = if (h.old_count == 0) h.old_start else h.old_start -| 1;
        if (at_line < cursor or at_line > old.len) return ApplyError.PatchDoesNotApply;
        for (old[cursor..at_line]) |l| try out.appendSlice(a, l);
        cursor = at_line;
        for (h.body) |e| {
            if (e.op != .ins) {
                if (cursor >= old.len or !std.mem.eql(u8, old[cursor], e.line)) return ApplyError.PatchDoesNotApply;
                cursor += 1;
            }
            if (e.op != .del) try out.appendSlice(a, e.line);
        }
    }
    for (old[cursor..]) |l| try out.appendSlice(a, l);
    if (fp.removed and out.items.len != 0) return ApplyError.PatchDoesNotApply;
    return out.items;
}

/// Applies `patch` to the tree `dir`, as `git apply` does with a patch of this form; `failed` names the file of an error. Nothing is
/// written unless every file applies.
pub fn apply(a: Allocator, dir: std.fs.Dir, patch: []const u8, failed: *[]const u8) !void {
    const fps = try parse(a, patch);
    var results = std.ArrayList([]const u8).empty;
    for (fps) |fp| {
        failed.* = fp.path;
        const before = dir.readFileAlloc(a, fp.path, 1 << 30) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        try results.append(a, try applyOne(a, before, fp));
    }
    for (fps, results.items) |fp, r| {
        failed.* = fp.path;
        if (fp.removed) {
            try dir.deleteFile(fp.path);
        } else {
            if (std.fs.path.dirname(fp.path)) |p| try dir.makePath(p);
            try dir.writeFile(.{ .sub_path = fp.path, .data = r });
        }
    }
    failed.* = "";
}

// ---- make -------------------------------------------------------------------------------------------------------------------

/// What `make` needs of the process: where a path really is (sync_stage's `syncArgv` makes every path absolute) and a run of the sync.
pub const Hooks = struct {
    scratch: []const u8,
    real: *const fn (Allocator, []const u8) anyerror![]u8,
    /// Runs `argv` with standard error the process's own; its exit status.
    run: *const fn (Allocator, []const []const u8) anyerror!u8,
};

/// Every file of `files` (the sync's, as `collect` wrote them) with its bytes in `src`, and every file of `removed` with its bytes in
/// `src`, sorted by path.
pub fn gather(a: Allocator, src: std.fs.Dir, files: std.fs.Dir, removed: []const []const u8) ![]const Change {
    var list = std.ArrayList(Change).empty;
    var w = try files.walk(a);
    defer w.deinit();
    while (try w.next()) |e| {
        if (e.kind != .file) continue;
        const p = try a.dupe(u8, e.path);
        const before = src.readFileAlloc(a, p, 1 << 30) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        try list.append(a, .{ .path = p, .before = before, .after = try files.readFileAlloc(a, p, 1 << 30) });
    }
    for (removed) |p| try list.append(a, .{ .path = p, .before = try src.readFileAlloc(a, p, 1 << 30), .after = null });
    std.mem.sort(Change, list.items, {}, struct {
        fn less(_: void, x: Change, y: Change) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.less);
    return list.items;
}

/// verdict.txt: the verdict, then `<letter> <path>` per change.
pub fn verdictText(a: Allocator, v: Verdict, changes: []const Change) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, @tagName(v));
    try out.append(a, '\n');
    for (changes) |c| try out.appendSlice(a, try std.fmt.allocPrint(a, "{c} {s}\n", .{ c.letter(), c.path }));
    return out.items;
}

/// `make` in `cwd`, with the work directory `work_path`: the sync's status when it failed (nothing is written then), else 0.
pub fn make(a: Allocator, cwd: std.fs.Dir, args: stage.Args, work_path: []const u8, hooks: Hooks) !u8 {
    try cwd.deleteTree(work_path);
    var work = try cwd.makeOpenPath(work_path, .{ .iterate = true });
    defer work.close();
    var src = try cwd.openDir(args.src, .{ .iterate = true });
    defer src.close();
    const added = try stage.stage(a, src, work);
    const code = try hooks.run(a, try stage.syncArgv(a, args, try hooks.real(a, work_path), hooks.real));
    if (code != 0) return code;
    var out = try cwd.makeOpenPath(args.out, .{});
    defer out.close();
    // `collect` writes into an empty directory: what is there is the sync's alone
    try out.deleteTree(offer_dir);
    var files = try out.makeOpenPath(files_dir, .{ .iterate = true });
    defer files.close();
    const changes = try gather(a, src, files, try stage.collect(a, src, work, files, added));
    const v = verdictOf(changes);
    if (v == .none) {
        try out.deleteTree(offer_dir);
    } else {
        try out.writeFile(.{ .sub_path = patch_file, .data = try patchText(a, changes, max_edits) });
    }
    try out.writeFile(.{ .sub_path = verdict_file, .data = try verdictText(a, v, changes) });
    return 0;
}

// ---- summary ----------------------------------------------------------------------------------------------------------------

pub const Entry = struct { letter: u8, path: []const u8 };

pub const Report = struct { verdict: Verdict, entries: []const Entry };

/// verdict.txt read back; null for text that is not of its form.
pub fn parseVerdict(a: Allocator, text: []const u8) !?Report {
    if (!std.mem.endsWith(u8, text, "\n")) return null;
    var it = std.mem.splitScalar(u8, text[0 .. text.len - 1], '\n');
    const v = std.meta.stringToEnum(Verdict, it.next().?) orelse return null;
    var entries = std.ArrayList(Entry).empty;
    while (it.next()) |l| {
        if (l.len < 3 or l[1] != ' ' or std.mem.indexOfScalar(u8, "MAD", l[0]) == null or !plainPath(l[2..])) return null;
        try entries.append(a, .{ .letter = l[0], .path = l[2..] });
    }
    if ((v == .none) != (entries.items.len == 0)) return null;
    return .{ .verdict = v, .entries = entries.items };
}

/// Where the patch is: the run, its repository and the name of its artifact.
pub const Where = struct { run: []const u8, repository: []const u8, artifact: []const u8 };

fn nameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.';
}

fn isName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!nameChar(c)) return false;
    return true;
}

/// Why `w` cannot go into a command line as it is; null when it can: the run is a number, the repository OWNER/NAME and the artifact a name,
/// of letters, digits, `-`, `_` and `.`.
pub fn badWhere(w: Where) ?[]const u8 {
    if (w.run.len == 0) return "--run must be the number of the run";
    for (w.run) |c| if (!std.ascii.isDigit(c)) return "--run must be the number of the run";
    const slash = std.mem.indexOfScalar(u8, w.repository, '/') orelse return "--repository must be OWNER/NAME";
    if (!isName(w.repository[0..slash]) or !isName(w.repository[slash + 1 ..])) return "--repository must be OWNER/NAME";
    if (!isName(w.artifact)) return "--artifact must be a name of letters, digits, '-', '_' and '.'";
    return null;
}

const failed_text =
    \\### Generated tables: no patch
    \\
    \\The build of `//:sync_patch` (`buildrules sync` on the farm, at this commit) did not finish, so there is no patch to offer: its message
    \\is in the log of the step that built it. A sync on the farm resolves only the packages Cargo.lock names; a crate or a git commit
    \\Cargo.lock does not name yet is added by `buildrules sync` where there is a network.
    \\
;

const none_text =
    \\### Generated tables: up to date
    \\
    \\`buildrules sync` at this commit writes exactly the files it generates as they are committed: there is no patch to offer, and a
    \\failure of the farm build is not a stale table.
    \\
;

const tables_text =
    \\### Generated tables: STALE, and only they
    \\
    \\Cargo.toml and Cargo.lock are as cargo resolves them; only the files `buildrules sync` generates lag behind them. Compile errors
    \\of the farm build in code that uses a dependency added since the last sync (an unresolved import, a crate that cannot be found)
    \\follow from the stale table, and go when it is regenerated.
    \\
;

const lock_text =
    \\### Generated tables: STALE, and Cargo.lock with them
    \\
    \\cargo changed Cargo.lock to resolve the manifests of this commit (the patch holds that Cargo.lock too), and the files
    \\`buildrules sync` generates lag behind both. Compile errors of the farm build in code that uses a dependency added since the last
    \\sync follow from the stale table; read the Cargo.lock part of the patch before you commit it.
    \\
;

/// The summary of `report` (null: the build of the patch failed).
pub fn summary(a: Allocator, report: ?Report, w: Where) ![]u8 {
    const r = report orelse return a.dupe(u8, failed_text);
    if (r.verdict == .none) return a.dupe(u8, none_text);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, if (r.verdict == .tables) tables_text else lock_text);
    const dir = try std.fmt.allocPrint(a, "../{s}-{s}", .{ w.artifact, w.run });
    try out.appendSlice(a, try std.fmt.allocPrint(a,
        \\
        \\CI ran `buildrules sync` on the farm at this commit and made the patch; it is offered, never pushed. At the root of a checkout
        \\of this commit, fetch it and apply it, then commit and push:
        \\
        \\```sh
        \\gh run download {s} -R {s} -n {s} -D {s}
        \\git apply {s}/sync.patch
        \\```
        \\
        \\The patch:
        \\
        \\
    , .{ w.run, w.repository, w.artifact, dir, dir }));
    for (r.entries) |e| {
        const what = switch (e.letter) {
            'A' => " (new)",
            'D' => " (removed)",
            else => "",
        };
        try out.appendSlice(a, try std.fmt.allocPrint(a, "- `{s}`{s}\n", .{ e.path, what }));
    }
    return out.items;
}

// ---- the command line -------------------------------------------------------------------------------------------------------

const SummaryArgs = struct { dir: []const u8 = "", where: Where = .{ .run = "", .repository = "", .artifact = "" }, to: ?[]const u8 = null };

fn parseSummary(argv: []const []const u8) !SummaryArgs {
    var s = SummaryArgs{};
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) return error.MissingValue;
        const k = argv[i];
        const v = argv[i + 1];
        if (std.mem.eql(u8, k, "--dir")) s.dir = v else if (std.mem.eql(u8, k, "--run")) s.where.run = v else if (std.mem.eql(u8, k, "--repository")) s.where.repository = v else if (std.mem.eql(u8, k, "--artifact")) s.where.artifact = v else if (std.mem.eql(u8, k, "--to")) s.to = v else return error.UnknownFlag;
    }
    if (s.dir.len == 0) return error.MissingFlag;
    return s;
}

fn appendTo(cwd: std.fs.Dir, path: []const u8, text: []const u8) !void {
    var f = try cwd.createFile(path, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(text);
}

fn summaryCmd(a: Allocator, cwd: std.fs.Dir, argv: []const []const u8, out: *std.ArrayList(u8), err: *std.ArrayList(u8)) !u8 {
    const s = parseSummary(argv) catch |e| {
        try err.appendSlice(a, try std.fmt.allocPrint(a, "sync_patch summary: {s}\n{s}", .{ @errorName(e), usage }));
        return 2;
    };
    if (badWhere(s.where)) |why| {
        try err.appendSlice(a, try std.fmt.allocPrint(a, "sync_patch summary: {s}\n", .{why}));
        return 2;
    }
    const path = try std.fs.path.join(a, &.{ s.dir, verdict_file });
    const text = cwd.readFileAlloc(a, path, 1 << 24) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    const report = if (text) |t| (try parseVerdict(a, t)) orelse {
        try err.appendSlice(a, try std.fmt.allocPrint(a, "sync_patch summary: {s} is not what `sync_patch make` writes\n", .{path}));
        return 2;
    } else null;
    const md = try summary(a, report, s.where);
    try out.appendSlice(a, md);
    if (s.to) |to| try appendTo(cwd, to, md);
    return if (report == null) 1 else 0;
}

fn makeCmd(a: Allocator, cwd: std.fs.Dir, argv: []const []const u8, hooks: Hooks, err: *std.ArrayList(u8)) !u8 {
    const args = stage.parseArgs(argv) catch |e| {
        try err.appendSlice(a, try std.fmt.allocPrint(a, "sync_patch make: {s}\n{s}", .{ @errorName(e), usage }));
        return 2;
    };
    if (args.check) {
        try err.appendSlice(a, "sync_patch make: --check is sync_stage's (the patch is the comparison)\n" ++ usage);
        return 2;
    }
    const code = try make(a, cwd, args, try std.fs.path.join(a, &.{ hooks.scratch, "workspace" }), hooks);
    if (code != 0) try err.appendSlice(a, try std.fmt.allocPrint(a, "sync_patch: `buildrules sync` exited {d}: there is no patch to offer (its message is above)\n", .{code}));
    return code;
}

/// The command line `argv` (without the program name): the exit status. What it says goes to `out` and `err`.
pub fn run(a: Allocator, cwd: std.fs.Dir, argv: []const []const u8, hooks: Hooks, out: *std.ArrayList(u8), err: *std.ArrayList(u8)) !u8 {
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "make")) return makeCmd(a, cwd, argv[1..], hooks, err);
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "summary")) return summaryCmd(a, cwd, argv[1..], out, err);
    try err.appendSlice(a, usage);
    return 2;
}
