//! cov_run: runs one Mojo test's coverage binary under kcov in a build action and writes its Cobertura report in repository paths.
//!
//! The approach is reduced to what a mopm unit needs: no gate
//! runner, no shared-library drivers. The test binary was built at -O0 with line tables by `mopm unit build`, so its line tables
//! name sources by relative paths (`tests/test_x.mojo`, `<import>/file.mojo`); kcov resolves those against its working directory,
//! so it is run in a tree where they resolve to copies of the sources, and measures only what `--include-path` names.
//!
//!   cov_run --kcov <dir> --normalize <exe> --compiler <dir> --binary <file> --share <dir> --out <report.xml>
//!           [--map <share-relative dir>=<repository dir>]... --must-contain <repository path>
//!           [--include <share-relative path>]... [--refuse-in-binary <text>]... [--env NAME=VALUE]... [--data-env NAME]
//!           [--private-scratch [--installed [--data <dir>]]] [--lib-dir <dir>]...
//!
//!   --kcov      the kcov distribution (bin/kcov, lib/libgcc_s.so.1); it is run in place
//!   --compiler  the compiler closure; its lib/ is on LD_LIBRARY_PATH (the test binary loads libKGENCompilerRTShared.so from it)
//!   --lib-dir   a directory of shared libraries the test opens by their bare names (a `system_libs` pin of the unit graph); each is made absolute and follows the
//!               compiler's lib/ on LD_LIBRARY_PATH, in the order given. Without one the variable is the compiler's lib/ alone
//!   --binary    the test, with its native libraries in lib/ beside it (its runpath is $ORIGIN/lib)
//!   --share     the tree of copies the line tables' names resolve in; kcov's working directory
//!   --map       a directory of the tree and the repository directory it copies (both end in `/`): the report's absolute names are
//!               rewritten with them (cov_normalize --map)
//!   --include   what kcov measures, by path in the tree (comma and colon are refused: kcov's option splits on them)
//!   --refuse-in-binary  fail before kcov runs when the binary holds this text: a binary that names the sources by the directory they
//!               were staged in (`.stage/src/`) would have kcov drop them without an error
//!   --env       a variable the test is given (the test's own, `test_env` of mojo_package); the names the runner sets itself are refused
//!   --data-env  the variable that names the tree (`--share`, made absolute): the directory the test is given its staged data in, which is
//!               also its working directory under kcov
//!   --private-scratch  the run gets a fresh directory of its own (install_root.zig, the one `check --private-scratch` makes for the test run): TMPDIR and
//!               TEST_TMPDIR are an empty directory in it, HOME another, and all of it is removed after the run
//!   --installed the test is run from an installed layout, the same one the test run has (`check --installed`): the directory of the binary is copied to `<root>/bin`,
//!               the tree of `--share` (the sources the line tables name) is copied into `<root>`, `--data` is copied to `<root>/share`, and `<root>` is
//!               kcov's and the test's working directory; `--data-env` then names `<root>/share`. A tree that holds a `bin` or a `share` is refused
//!   --data      the tree copied to `<root>/share` (with --installed only)
//!
//! Exit status: the test's under kcov when it fails (128+N for signal N); 1 when the binary names staged paths, kcov wrote no report,
//! or the report was refused; 2 for a usage error.

const std = @import("std");
const ir = @import("install_root");

pub const Map = struct { share_rel: []const u8, repo: []const u8 };

pub const Args = struct {
    kcov: []const u8 = "",
    normalize: []const u8 = "",
    compiler: []const u8 = "",
    binary: []const u8 = "",
    share: []const u8 = "",
    out: []const u8 = "",
    must_contain: []const u8 = "",
    maps: []const Map = &.{},
    includes: []const []const u8 = &.{},
    refuse: []const []const u8 = &.{},
    /// Each --lib-dir, in order (as given by `parse`; absolute by the time `testEnv` is given them).
    lib_dirs: []const []const u8 = &.{},
    /// `NAME=VALUE` entries of the test's environment.
    env: []const []const u8 = &.{},
    /// The variable that holds the absolute path of `share`, or empty.
    data_env: []const u8 = "",
    /// A directory of the run's own for TMPDIR, TEST_TMPDIR and HOME.
    private_scratch: bool = false,
    /// The installed layout (`<root>/bin/<name>`, `<root>/share`); needs `private_scratch`.
    installed: bool = false,
    /// The tree that becomes `<root>/share`, or empty; needs `installed`.
    data: []const u8 = "",
    /// Arguments of the test binary (zig_cover.zig gives the runner its report path); cov_run's own command line has none.
    binary_args: []const []const u8 = &.{},
};

pub const UsageError = error{Usage};

fn hasAny(s: []const u8, set: []const u8) bool {
    return std.mem.indexOfAny(u8, s, set) != null;
}

pub fn parse(a: std.mem.Allocator, argv: []const []const u8, diag: *[]const u8) (UsageError || std.mem.Allocator.Error)!Args {
    var r = Args{};
    var maps = std.ArrayList(Map).empty;
    var includes = std.ArrayList([]const u8).empty;
    var refuse = std.ArrayList([]const u8).empty;
    var envs = std.ArrayList([]const u8).empty;
    var lib_dirs = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < argv.len) {
        const flag = argv[i];
        // The two options that take no value: the next argument is another option.
        if (std.mem.eql(u8, flag, "--private-scratch") or std.mem.eql(u8, flag, "--installed")) {
            if (std.mem.eql(u8, flag, "--installed")) r.installed = true else r.private_scratch = true;
            i += 1;
            continue;
        }
        if (i + 1 >= argv.len) {
            diag.* = try std.fmt.allocPrint(a, "{s} needs a value", .{flag});
            return error.Usage;
        }
        const v = argv[i + 1];
        if (std.mem.eql(u8, flag, "--kcov")) {
            r.kcov = v;
        } else if (std.mem.eql(u8, flag, "--normalize")) {
            r.normalize = v;
        } else if (std.mem.eql(u8, flag, "--compiler")) {
            r.compiler = v;
        } else if (std.mem.eql(u8, flag, "--binary")) {
            r.binary = v;
        } else if (std.mem.eql(u8, flag, "--share")) {
            r.share = v;
        } else if (std.mem.eql(u8, flag, "--out")) {
            r.out = v;
        } else if (std.mem.eql(u8, flag, "--must-contain")) {
            r.must_contain = v;
        } else if (std.mem.eql(u8, flag, "--map")) {
            const eq = std.mem.indexOfScalar(u8, v, '=') orelse {
                diag.* = try std.fmt.allocPrint(a, "--map {s} is not <share dir>=<repository dir>", .{v});
                return error.Usage;
            };
            const s = v[0..eq];
            const repo = v[eq + 1 ..];
            if (s.len == 0 or s[0] == '/' or s[s.len - 1] != '/' or (repo.len > 0 and (repo[0] == '/' or repo[repo.len - 1] != '/'))) {
                diag.* = try std.fmt.allocPrint(a, "--map {s}: both sides are relative directories ending in /", .{v});
                return error.Usage;
            }
            try maps.append(a, .{ .share_rel = s, .repo = repo });
        } else if (std.mem.eql(u8, flag, "--include")) {
            if (v.len == 0 or v[0] == '/' or hasAny(v, ",: ")) {
                diag.* = try std.fmt.allocPrint(a, "--include {s} must be a relative path without a space, , or :", .{v});
                return error.Usage;
            }
            try includes.append(a, v);
        } else if (std.mem.eql(u8, flag, "--refuse-in-binary")) {
            if (v.len == 0) {
                diag.* = "--refuse-in-binary needs text";
                return error.Usage;
            }
            try refuse.append(a, v);
        } else if (std.mem.eql(u8, flag, "--env")) {
            const eq = std.mem.indexOfScalar(u8, v, '=') orelse 0;
            if (eq == 0) {
                diag.* = try std.fmt.allocPrint(a, "--env {s} is not NAME=VALUE", .{v});
                return error.Usage;
            }
            if (ownEnv(v[0..eq])) {
                diag.* = try std.fmt.allocPrint(a, "--env {s}: cov_run sets {s} itself", .{ v, v[0..eq] });
                return error.Usage;
            }
            try envs.append(a, v);
        } else if (std.mem.eql(u8, flag, "--lib-dir")) {
            if (v.len == 0) {
                diag.* = "--lib-dir needs a directory";
                return error.Usage;
            }
            try lib_dirs.append(a, v);
        } else if (std.mem.eql(u8, flag, "--data-env")) {
            if (v.len == 0 or std.mem.indexOfScalar(u8, v, '=') != null or ownEnv(v)) {
                diag.* = try std.fmt.allocPrint(a, "--data-env {s} is not a variable name cov_run may set", .{v});
                return error.Usage;
            }
            r.data_env = v;
        } else if (std.mem.eql(u8, flag, "--data")) {
            if (v.len == 0) {
                diag.* = "--data needs a directory";
                return error.Usage;
            }
            r.data = v;
        } else {
            diag.* = try std.fmt.allocPrint(a, "unknown option {s}", .{flag});
            return error.Usage;
        }
        i += 2;
    }
    if (r.installed and !r.private_scratch) {
        diag.* = "--installed needs --private-scratch: the installed layout is made in it";
        return error.Usage;
    }
    if (r.data.len > 0 and !r.installed) {
        diag.* = "--data needs --installed";
        return error.Usage;
    }
    inline for (.{ "kcov", "normalize", "compiler", "binary", "share", "out", "must_contain" }) |k| {
        if (@field(r, k).len == 0) {
            diag.* = try std.fmt.allocPrint(a, "--{s} is required", .{k});
            return error.Usage;
        }
    }
    if (includes.items.len == 0) {
        diag.* = "at least one --include is required: kcov measures nothing else";
        return error.Usage;
    }
    r.maps = try maps.toOwnedSlice(a);
    r.includes = try includes.toOwnedSlice(a);
    r.refuse = try refuse.toOwnedSlice(a);
    r.env = try envs.toOwnedSlice(a);
    r.lib_dirs = try lib_dirs.toOwnedSlice(a);
    return r;
}

/// The variables cov_run sets for the test itself; a test's own `--env` may not replace them. TMPDIR, TEST_TMPDIR and HOME are the run's private
/// directories (`--private-scratch`), which only the runner makes.
fn ownEnv(name: []const u8) bool {
    inline for (.{ "LD_LIBRARY_PATH", "PATH", "TMPDIR", "TEST_TMPDIR", "HOME" }) |own| {
        if (std.mem.eql(u8, name, own)) return true;
    }
    return false;
}

/// The environment kcov, and the test under it, get: the compiler's `lib/` for the library path, a fixed PATH, each `--env`, `--data-env` naming `data` (the
/// directory the test finds its staged data in: the tree, which is also the test's working directory, so a relative path and the variable reach the
/// same files; with `--installed` the tree's `share/`), and, with a private scratch directory, TMPDIR and TEST_TMPDIR (its `tmp`) and HOME (its `home`).
pub fn testEnv(a: std.mem.Allocator, r: Args, compiler: []const u8, data: []const u8, scratch: ?ir.Scratch) !std.process.EnvMap {
    var env = std.process.EnvMap.init(a);
    var ld = try std.fs.path.join(a, &.{ compiler, "lib" });
    for (r.lib_dirs) |d| ld = try std.fmt.allocPrint(a, "{s}:{s}", .{ ld, d });
    try env.put("LD_LIBRARY_PATH", ld);
    try env.put("PATH", "/usr/bin:/bin");
    for (r.env) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        try env.put(entry[0..eq], entry[eq + 1 ..]);
    }
    if (r.data_env.len > 0) try env.put(r.data_env, data);
    if (scratch) |s| {
        try env.put("TMPDIR", s.tmp);
        try env.put("TEST_TMPDIR", s.tmp);
        try env.put("HOME", s.home);
    }
    return env;
}

/// What the test and kcov run on: `tree` is kcov's working directory and what the include paths and the report's names are under, `binary` the test
/// kcov starts, `data` what `--data-env` names, and `scratch` the private directories (null without `--private-scratch`).
pub const Staged = struct {
    tree: []const u8,
    binary: []const u8,
    data: []const u8,
    scratch: ?ir.Scratch,
};

/// Makes the run's directories in `parent` and, with `--installed`, the layout: the directory of the test binary copied to `<root>/bin`, the tree `share` (the
/// sources) copied into `<root>`, `r.data` (or nothing) as `<root>/share`. Without `--private-scratch` nothing is made and the run is on `share` and `binary` as
/// they are. A tree that holds a `bin` or a `share` would be merged into the layout, so it is refused. The run's directories are removed when staging fails.
pub fn stage(a: std.mem.Allocator, r: Args, share: []const u8, binary: []const u8, parent: []const u8) !Staged {
    if (!r.private_scratch) return .{ .tree = share, .binary = binary, .data = share, .scratch = null };
    const s = try ir.make(a, parent);
    errdefer ir.remove(s);
    if (!r.installed) return .{ .tree = share, .binary = binary, .data = share, .scratch = s };
    // The layout is `install_root`'s `installTree`, the one `cov_branch run` makes its installed run with.
    const installed = try ir.installTree(a, s, share, binary, if (r.data.len > 0) r.data else null);
    return .{ .tree = s.root, .binary = installed, .data = s.share, .scratch = s };
}

/// kcov's command line. `share` is the absolute (real) path of the tree, `work` where the report goes.
pub fn kcovArgv(a: std.mem.Allocator, r: Args, share: []const u8, work: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    try out.append(a, try std.fs.path.join(a, &.{ r.kcov, "bin", "kcov" }));
    try out.append(a, "--cobertura-only");
    try out.append(a, "--skip-solibs");
    try out.append(a, "--configure=cobertura-full-paths=1");
    var inc = std.ArrayList(u8).empty;
    try inc.appendSlice(a, "--include-path=");
    for (r.includes, 0..) |p, i| {
        if (i != 0) try inc.append(a, ',');
        try inc.appendSlice(a, try std.fs.path.join(a, &.{ share, p }));
    }
    try out.append(a, try inc.toOwnedSlice(a));
    try out.append(a, work);
    try out.append(a, r.binary);
    try out.appendSlice(a, r.binary_args);
    return out.toOwnedSlice(a);
}

/// cov_normalize's command line for the raw report `raw`.
pub fn normalizeArgv(a: std.mem.Allocator, r: Args, share: []const u8, raw: []const u8, cwd: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    try out.appendSlice(a, &.{ r.normalize, "--in", raw, "--out", r.out });
    for (r.maps) |m| {
        try out.append(a, "--map");
        try out.append(a, try std.fmt.allocPrint(a, "{s}/{s}={s}", .{ share, m.share_rel, m.repo }));
    }
    try out.appendSlice(a, &.{ "--must-contain", r.must_contain, "--forbid", cwd });
    return out.toOwnedSlice(a);
}

/// The first of `refuse` that `binary` holds, or null.
pub fn heldText(binary: []const u8, refuse: []const []const u8) ?[]const u8 {
    for (refuse) |t| {
        if (std.mem.indexOf(u8, binary, t) != null) return t;
    }
    return null;
}

/// The run's private directories, for `die` to take away: the process ends there, so nothing else would.
var held_scratch: ?ir.Scratch = null;

fn die(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cov_run: " ++ fmt ++ "\n", args);
    if (held_scratch) |s| ir.remove(s);
    std.process.exit(code);
}

fn run(a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, env: *std.process.EnvMap) !u8 {
    var child = std.process.Child.init(argv, a);
    child.cwd = cwd;
    child.env_map = env;
    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |c| c,
        .Signal => |s| @intCast(128 + (s & 0x7f)),
        else => 255,
    };
}

/// `dirs` as absolute paths of existing directories, in order; on an error `bad.*` is the one that could not be resolved.
pub fn realDirs(a: std.mem.Allocator, cwd: std.fs.Dir, dirs: []const []const u8, bad: *[]const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, dirs.len);
    for (dirs, out) |d, *o| o.* = cwd.realpathAlloc(a, d) catch |e| {
        bad.* = d;
        return e;
    };
    return out;
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    var diag: []const u8 = "";
    const r = parse(a, argv[1..], &diag) catch |e| switch (e) {
        error.Usage => die(2, "{s}", .{diag}),
        else => return e,
    };
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    const share = std.fs.cwd().realpathAlloc(a, r.share) catch |e| die(2, "cannot resolve --share {s}: {s}", .{ r.share, @errorName(e) });
    const binary = std.fs.cwd().realpathAlloc(a, r.binary) catch |e| die(2, "cannot resolve --binary {s}: {s}", .{ r.binary, @errorName(e) });
    const compiler = std.fs.cwd().realpathAlloc(a, r.compiler) catch |e| die(2, "cannot resolve --compiler {s}: {s}", .{ r.compiler, @errorName(e) });
    const kcov_dir = std.fs.cwd().realpathAlloc(a, r.kcov) catch |e| die(2, "cannot resolve --kcov {s}: {s}", .{ r.kcov, @errorName(e) });
    const normalize = std.fs.cwd().realpathAlloc(a, r.normalize) catch |e| die(2, "cannot resolve --normalize {s}: {s}", .{ r.normalize, @errorName(e) });

    // The binary names its sources by relative paths, or kcov drops them without an error.
    const bytes = try std.fs.cwd().readFileAlloc(a, binary, 1 << 30);
    if (heldText(bytes, r.refuse)) |t| {
        die(1, "the test binary holds `{s}`: it names a library's sources by the directory they were staged in, which kcov cannot open here and would drop without an error; the library was compiled with a source root that is not its package directory", .{t});
    }

    const work = try std.fmt.allocPrint(a, "{s}.work", .{r.out});
    std.fs.cwd().makePath(work) catch |e| die(1, "cannot create {s}: {s}", .{ work, @errorName(e) });
    const work_abs = try std.fs.cwd().realpathAlloc(a, work);
    var rr = r;
    var bad_dir: []const u8 = "";
    rr.lib_dirs = realDirs(a, std.fs.cwd(), r.lib_dirs, &bad_dir) catch |e| die(2, "cannot resolve --lib-dir {s}: {s}", .{ bad_dir, @errorName(e) });
    rr.kcov = kcov_dir;
    if (r.data.len > 0) rr.data = std.fs.cwd().realpathAlloc(a, r.data) catch |e| die(2, "cannot resolve --data {s}: {s}", .{ r.data, @errorName(e) });
    // The private directories go in the action's scratch path, else TMPDIR, else /tmp (the one rule `check` has).
    const scratch_parent = try ir.parent(a, cwd, std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch null, std.process.getEnvVarOwned(a, "TMPDIR") catch null);
    const staged = stage(a, rr, share, binary, scratch_parent) catch |e| die(1, "cannot stage the run in {s}: {s}", .{ scratch_parent, @errorName(e) });
    held_scratch = staged.scratch;
    rr.binary = staged.binary;
    const kargv = try kcovArgv(a, rr, staged.tree, work_abs);
    var env = try testEnv(a, rr, compiler, staged.data, staged.scratch);
    const code = try run(a, kargv, staged.tree, &env);
    if (code != 0) die(code, "kcov (or the test under it) exited {d}", .{code});

    // kcov's report: cov.xml with --cobertura-only.
    const raw = try std.fs.path.join(a, &.{ work_abs, "cov.xml" });
    std.fs.cwd().access(raw, .{}) catch die(1, "kcov wrote no {s}", .{raw});
    rr.normalize = normalize;
    rr.out = try std.fs.path.join(a, &.{ cwd, r.out });
    const nargv = try normalizeArgv(a, rr, staged.tree, raw, cwd);
    var nenv = std.process.EnvMap.init(a);
    const ncode = try run(a, nargv, null, &nenv);
    if (ncode != 0) die(1, "cov_normalize refused the report (exit {d})", .{ncode});
    if (staged.scratch) |s| ir.remove(s);
    std.fs.cwd().deleteTree(work) catch {};
}
