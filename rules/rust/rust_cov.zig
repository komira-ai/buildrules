//! rust_cov: the coverage of one cargo member, from the profiles its instrumented tests wrote (a member's `:coverage`, rules/rust/coverage.bzl).
//!
//! usage: rust_cov --profdata <llvm-profdata> --llvm-cov <llvm-cov> --package <dir> --out <coverage.txt> --lcov <file>
//!                 [--branches yes|no] [--exclude <dir>]... [--extra <file>]... [--profiles <dir>]... [--object <file>]...
//!
//! The `.profraw` files of every `--profiles` directory (one per test run) are merged (`llvm-profdata merge -sparse`), and `llvm-cov export
//! -format=lcov` reads the merged profile against every `--object` (the instrumented test binaries and the package's binaries they ran). Of the
//! files llvm-cov names, those of the package are kept:
//!
//!   counted       a file under `--package` (the member's directory, from the project root; `.` or empty is the root) and not under an
//!                 `--exclude` directory (a member nested in it, relative to `--package`), or an `--extra` file (a source outside the package
//!                 the member compiles, `extra_srcs`);
//!   not counted   a file of the package under its `tests/`, `benches/` or `examples/`: the code of the test targets, shown and left out of
//!                 the totals;
//!   left out      everything else: other members, generated code under OUT_DIR, the standard library.
//!
//! `--out` is the text cov_summary writes and cov_floor reads (rules/coverage/README.md): `<path> <hit>/<total> <n>%` per file (sorted), then
//! `total <hit>/<total> <n>%` over the counted files; then the same rows of branches, each with `branches ` in front. A line is hit when its
//! count is not 0; a branch (one arm of a decision, llvm-cov's `BRDA`) is hit when it was taken. With `--branches no` (the tests were built
//! without branch counters) there are no `branches` rows, so the figure is lines only, as cov_floor reads a package that has no branch figure. `--lcov` is llvm-cov's report of the kept
//! files, paths as in `--out`, sorted, every line and branch record as llvm-cov wrote it.
//!
//! A run whose directory holds no `.profraw` fails, naming it: its program was not built with coverage counters. With no `--object` (a member
//! with no test) nothing is run and every total is 0/0. A path llvm-cov writes as `./<path>` is `<path>`.
//!
//! Exit status: 0 written; 1 a run without profiles, a tool that failed, or a report that is not llvm-cov's lcov; 2 a usage error.

const std = @import("std");

pub const Error = error{ BadLcov, NoProfile, ToolFailed, Usage } || std.mem.Allocator.Error;

pub const Branch = struct { line: u32, block: u32, branch: u32, taken: ?u64 };

pub const Line = struct { line: u32, count: u64 };

pub const File = struct {
    path: []const u8,
    /// line number -> count, in the order llvm-cov wrote them.
    lines: std.ArrayList(Line) = .empty,
    branches: std.ArrayList(Branch) = .empty,

    pub fn lineFigure(f: File) Measure {
        var m = Measure{};
        for (f.lines.items) |l| {
            m.total += 1;
            if (l.count != 0) m.hit += 1;
        }
        return m;
    }

    pub fn branchFigure(f: File) Measure {
        var m = Measure{};
        for (f.branches.items) |b| {
            m.total += 1;
            if (b.taken) |n| {
                if (n != 0) m.hit += 1;
            }
        }
        return m;
    }
};

pub const Measure = struct { hit: u64 = 0, total: u64 = 0 };

fn number(comptime T: type, text: []const u8) Error!T {
    return std.fmt.parseInt(T, text, 10) catch error.BadLcov;
}

/// llvm-cov's lcov: `SF:` opens a file, `DA:<line>,<count>[,<checksum>]` and `BRDA:<line>,<block>,<branch>,<count or ->` are its records,
/// `end_of_record` closes it. `TN:`, `FN`, `FNDA`, `FNF`, `FNH`, `LF`, `LH`, `BRF` and `BRH` (names and sums of what is listed) are read past.
/// A record outside a file, a file not closed, a malformed number and any other line are refused.
pub fn parseLcov(a: std.mem.Allocator, text: []const u8) Error![]File {
    var files = std.ArrayList(File).empty;
    var open: ?File = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |row| {
        if (row.len == 0) continue;
        if (std.mem.startsWith(u8, row, "SF:")) {
            if (open != null or row.len == 3) return error.BadLcov;
            open = .{ .path = row[3..] };
        } else if (std.mem.eql(u8, row, "end_of_record")) {
            try files.append(a, open orelse return error.BadLcov);
            open = null;
        } else if (std.mem.startsWith(u8, row, "DA:")) {
            const f = if (open) |*x| x else return error.BadLcov;
            var p = std.mem.splitScalar(u8, row[3..], ',');
            const line = try number(u32, p.next().?);
            const count = try number(u64, p.next() orelse return error.BadLcov);
            try f.lines.append(a, .{ .line = line, .count = count });
        } else if (std.mem.startsWith(u8, row, "BRDA:")) {
            const f = if (open) |*x| x else return error.BadLcov;
            var p = std.mem.splitScalar(u8, row[5..], ',');
            const line = try number(u32, p.next().?);
            const block = try number(u32, p.next() orelse return error.BadLcov);
            const branch = try number(u32, p.next() orelse return error.BadLcov);
            const c = p.next() orelse return error.BadLcov;
            if (p.next() != null) return error.BadLcov;
            const taken: ?u64 = if (std.mem.eql(u8, c, "-")) null else try number(u64, c);
            try f.branches.append(a, .{ .line = line, .block = block, .branch = branch, .taken = taken });
        } else if (ignored(row)) {
            if (!std.mem.startsWith(u8, row, "TN:") and open == null) return error.BadLcov;
        } else return error.BadLcov;
    }
    if (open != null) return error.BadLcov;
    return files.items;
}

fn ignored(row: []const u8) bool {
    for ([_][]const u8{ "TN:", "FN:", "FNDA:", "FNF:", "FNH:", "LF:", "LH:", "BRF:", "BRH:" }) |p| {
        if (std.mem.startsWith(u8, row, p)) return true;
    }
    return false;
}

pub const Kind = enum { counted, not_counted, outside };

/// Where a path llvm-cov named belongs (see the header).
pub const Scope = struct {
    package: []const u8,
    exclude: []const []const u8 = &.{},
    extra: []const []const u8 = &.{},

    pub fn kind(s: Scope, path: []const u8) Kind {
        for (s.extra) |e| {
            if (std.mem.eql(u8, e, path)) return .counted;
        }
        const rest = under(s.package, path) orelse return .outside;
        for (s.exclude) |d| {
            if (under(d, path) != null) return .outside;
        }
        for ([_][]const u8{ "tests", "benches", "examples" }) |d| {
            if (under(d, rest) != null) return .not_counted;
        }
        return .counted;
    }
};

/// The part of `path` below directory `dir` ("" is the project root, which holds every relative path), or null.
fn under(dir: []const u8, path: []const u8) ?[]const u8 {
    if (std.fs.path.isAbsolute(path)) return null;
    if (dir.len == 0) return path;
    if (path.len <= dir.len + 1 or !std.mem.startsWith(u8, path, dir) or path[dir.len] != '/') return null;
    return path[dir.len + 1 ..];
}

/// A path as llvm-cov wrote it, as it is reported: without its leading `./`.
pub fn normalize(path: []const u8) []const u8 {
    var p = path;
    while (std.mem.startsWith(u8, p, "./")) p = p[2..];
    return p;
}

/// A directory as `--package` gives it, as Scope holds it: without a leading `./`, and `.` as the root (empty).
pub fn root(dir: []const u8) []const u8 {
    const d = normalize(dir);
    return if (std.mem.eql(u8, d, ".")) "" else d;
}

/// The files of the package (counted or not), paths normalized, sorted by path; a file named twice is refused.
pub fn select(a: std.mem.Allocator, files: []const File, scope: Scope) Error![]File {
    var kept = std.ArrayList(File).empty;
    for (files) |f| {
        var g = f;
        g.path = normalize(f.path);
        if (scope.kind(g.path) == .outside) continue;
        for (kept.items) |k| {
            if (std.mem.eql(u8, k.path, g.path)) return error.BadLcov;
        }
        try kept.append(a, g);
    }
    std.mem.sort(File, kept.items, {}, struct {
        fn lt(_: void, x: File, y: File) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    return kept.items;
}

fn pct(m: Measure) u64 {
    return if (m.total == 0) 0 else m.hit * 100 / m.total;
}

/// The text of `--out` (see the header) for the kept files: lines, then (with `branches`) branch arms.
pub fn render(a: std.mem.Allocator, files: []const File, scope: Scope, branches: bool) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    const blocks = [_][]const u8{ "", "branches " };
    for (blocks[0..if (branches) 2 else 1]) |prefix| {
        var sum = Measure{};
        for (files) |f| {
            const m = if (prefix.len == 0) f.lineFigure() else f.branchFigure();
            const counted = scope.kind(f.path) == .counted;
            if (counted) {
                sum.hit += m.hit;
                sum.total += m.total;
            }
            try out.appendSlice(a, try std.fmt.allocPrint(a, "{s}{s} {d}/{d} {d}%{s}\n", .{ prefix, f.path, m.hit, m.total, pct(m), if (counted) "" else " (not counted)" }));
        }
        try out.appendSlice(a, try std.fmt.allocPrint(a, "{s}total {d}/{d} {d}%\n", .{ prefix, sum.hit, sum.total, pct(sum) }));
    }
    return out.items;
}

/// The lcov of the kept files: `SF:`, the `DA` and `BRDA` records in llvm-cov's order, `end_of_record`.
pub fn renderLcov(a: std.mem.Allocator, files: []const File) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (files) |f| {
        try out.appendSlice(a, try std.fmt.allocPrint(a, "SF:{s}\n", .{f.path}));
        for (f.lines.items) |l| try out.appendSlice(a, try std.fmt.allocPrint(a, "DA:{d},{d}\n", .{ l.line, l.count }));
        for (f.branches.items) |b| {
            if (b.taken) |n| {
                try out.appendSlice(a, try std.fmt.allocPrint(a, "BRDA:{d},{d},{d},{d}\n", .{ b.line, b.block, b.branch, n }));
            } else {
                try out.appendSlice(a, try std.fmt.allocPrint(a, "BRDA:{d},{d},{d},-\n", .{ b.line, b.block, b.branch }));
            }
        }
        try out.appendSlice(a, "end_of_record\n");
    }
    return out.items;
}

pub const Options = struct {
    profdata: []const u8 = "",
    llvm_cov: []const u8 = "",
    out: []const u8 = "",
    lcov: []const u8 = "",
    scope: Scope = .{ .package = "" },
    branches: bool = true,
    profiles: []const []const u8 = &.{},
    objects: []const []const u8 = &.{},
};

/// The options of the command line (`args` without the program's name). Every option takes a value; the five single ones are required.
pub fn parseArgs(a: std.mem.Allocator, args: []const []const u8) Error!Options {
    var o = Options{};
    var package: ?[]const u8 = null;
    var exclude = std.ArrayList([]const u8).empty;
    var extra = std.ArrayList([]const u8).empty;
    var profiles = std.ArrayList([]const u8).empty;
    var objects = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.Usage;
        const k = args[i];
        const v = args[i + 1];
        if (std.mem.eql(u8, k, "--profdata")) {
            o.profdata = v;
        } else if (std.mem.eql(u8, k, "--llvm-cov")) {
            o.llvm_cov = v;
        } else if (std.mem.eql(u8, k, "--out")) {
            o.out = v;
        } else if (std.mem.eql(u8, k, "--lcov")) {
            o.lcov = v;
        } else if (std.mem.eql(u8, k, "--branches")) {
            if (std.mem.eql(u8, v, "yes")) {
                o.branches = true;
            } else if (std.mem.eql(u8, v, "no")) {
                o.branches = false;
            } else return error.Usage;
        } else if (std.mem.eql(u8, k, "--package")) {
            package = v;
        } else if (std.mem.eql(u8, k, "--exclude")) {
            try exclude.append(a, v);
        } else if (std.mem.eql(u8, k, "--extra")) {
            try extra.append(a, v);
        } else if (std.mem.eql(u8, k, "--profiles")) {
            try profiles.append(a, v);
        } else if (std.mem.eql(u8, k, "--object")) {
            try objects.append(a, v);
        } else return error.Usage;
    }
    if (package == null or o.profdata.len == 0 or o.llvm_cov.len == 0 or o.out.len == 0 or o.lcov.len == 0) return error.Usage;
    const dir = root(package.?);
    for (exclude.items) |*d| d.* = if (dir.len == 0) normalize(d.*) else try std.fs.path.join(a, &.{ dir, normalize(d.*) });
    for (extra.items) |*e| e.* = normalize(e.*);
    o.scope = .{ .package = dir, .exclude = exclude.items, .extra = extra.items };
    o.profiles = profiles.items;
    o.objects = objects.items;
    return o;
}

/// The `.profraw` files of a run's directory, sorted; none is an error naming the directory (`why` holds the sentence).
pub fn profilesOf(a: std.mem.Allocator, dir: []const u8, why: *[]const u8) ![]const []const u8 {
    var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer d.close();
    var names = std.ArrayList([]const u8).empty;
    var it = d.iterate();
    while (try it.next()) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".profraw")) try names.append(a, try std.fs.path.join(a, &.{ dir, e.name }));
    }
    if (names.items.len == 0) {
        why.* = try std.fmt.allocPrint(a, "{s}: the run wrote no profile: its program was not built with coverage counters (-C instrument-coverage)", .{dir});
        return error.NoProfile;
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return names.items;
}

/// Runs `argv`; its standard output goes to `stdout_file` when one is given. Returns its status (128 + N for signal N).
pub fn spawn(a: std.mem.Allocator, argv: []const []const u8, stdout_file: ?[]const u8) !u8 {
    var child = std.process.Child.init(argv, a);
    if (stdout_file == null) return codeOf(try child.spawnAndWait());
    const f = try std.fs.cwd().createFile(stdout_file.?, .{});
    defer f.close();
    child.stdout_behavior = .Pipe;
    try child.spawn();
    var rbuf: [4096]u8 = undefined;
    var r = child.stdout.?.reader(&rbuf);
    var wbuf: [4096]u8 = undefined;
    var w = f.writer(&wbuf);
    _ = try r.interface.streamRemaining(&w.interface);
    try w.interface.flush();
    return codeOf(try child.wait());
}

/// A finished child as an exit status: its own, 128 + N for signal N, 1 for anything else.
pub fn codeOf(term: std.process.Child.Term) u8 {
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| @truncate(128 +% s),
        else => 1,
    };
}

/// The command that merges every run's profiles into `merged`: `llvm-profdata merge -sparse -o <merged> <profile>...` (profilesOf: a run
/// without one fails, `why` naming it).
pub fn mergeArgv(a: std.mem.Allocator, o: Options, merged: []const u8, why: *[]const u8) ![]const []const u8 {
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{ o.profdata, "merge", "-sparse", "-o", merged });
    for (o.profiles) |d| try argv.appendSlice(a, try profilesOf(a, d, why));
    return argv.items;
}

/// The command that reads `merged` against every object: `llvm-cov export -format=lcov -instr-profile=<merged> <first> -object <other>...`.
pub fn exportArgv(a: std.mem.Allocator, o: Options, merged: []const u8) ![]const []const u8 {
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{ o.llvm_cov, "export", "-format=lcov", try std.fmt.allocPrint(a, "-instr-profile={s}", .{merged}), o.objects[0] });
    for (o.objects[1..]) |obj| try argv.appendSlice(a, &.{ "-object", obj });
    return argv.items;
}

/// llvm-cov's report read, the package's files kept, `--out` and `--lcov` written; returns the text of `--out`.
pub fn finish(a: std.mem.Allocator, o: Options, lcov_text: []const u8, why: *[]const u8) ![]const u8 {
    const files = parseLcov(a, lcov_text) catch |e| {
        if (e == error.BadLcov) why.* = "llvm-cov's report is not the lcov this tool reads (SF, DA, BRDA, end_of_record and the sums)";
        return e;
    };
    const kept = select(a, files, o.scope) catch |e| {
        if (e == error.BadLcov) why.* = "llvm-cov's report names one file twice";
        return e;
    };
    const text = try render(a, kept, o.scope, o.branches);
    try std.fs.cwd().writeFile(.{ .sub_path = o.out, .data = text });
    try std.fs.cwd().writeFile(.{ .sub_path = o.lcov, .data = try renderLcov(a, kept) });
    return text;
}

/// The whole command: merge, export, then `finish`. `scratch` holds the merged profile and llvm-cov's report (`export.lcov`); `why` the sentence of a
/// failure.
pub fn run(a: std.mem.Allocator, o: Options, scratch: []const u8, why: *[]const u8) ![]const u8 {
    var lcov_text: []const u8 = "";
    if (o.objects.len > 0) {
        try std.fs.cwd().makePath(scratch);
        const merged = try std.fs.path.join(a, &.{ scratch, "merged.profdata" });
        if (try spawn(a, try mergeArgv(a, o, merged, why), null) != 0) {
            why.* = "llvm-profdata merge failed (its own message is above)";
            return error.ToolFailed;
        }
        const raw = try std.fs.path.join(a, &.{ scratch, "export.lcov" });
        if (try spawn(a, try exportArgv(a, o, merged), raw) != 0) {
            why.* = "llvm-cov export failed (its own message is above)";
            return error.ToolFailed;
        }
        lcov_text = try std.fs.cwd().readFileAlloc(a, raw, 1 << 30);
    }
    return finish(a, o, lcov_text, why);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    const o = parseArgs(a, args[1..]) catch {
        std.debug.print("usage: rust_cov --profdata <llvm-profdata> --llvm-cov <llvm-cov> --package <dir> --out <coverage.txt> --lcov <file> [--branches yes|no] [--exclude <dir>]... [--extra <file>]... [--profiles <dir>]... [--object <file>]...\n", .{});
        std.process.exit(2);
    };
    const scratch_env = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch "";
    const scratch = try std.fs.path.join(a, &.{ if (scratch_env.len == 0) ".br_scratch" else scratch_env, "rust_cov" });
    var why: []const u8 = "";
    _ = run(a, o, scratch, &why) catch |e| {
        std.debug.print("rust_cov: {s}\n", .{if (why.len > 0) why else @errorName(e)});
        std.process.exit(1);
    };
}
