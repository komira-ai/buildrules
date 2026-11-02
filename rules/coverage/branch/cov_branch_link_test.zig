//! Unit tests of `cov_branch link` (cov_branch_link.zig), run by `zig test` as a build action (`:cov_branch_unit`). Each process step is a
//! stand-in (`Fake`, a Runner) that writes what the real program would (lld's object and log, zig's binary and log), so every decision of
//! the subcommand is reached without LLVM or zig. The shipped executable is run as a process by cov_branch_link_exe_test.zig; what a real
//! link does end to end is the branch records of examples/mojo/branches.

const std = @import("std");
const proc = @import("proc.zig");
const common = @import("cov_branch_common.zig");
const l = @import("cov_branch_link.zig");
const testing = std.testing;

const ELF = "\x7fELF\x02\x01\x01\x00instrumented";

const Fake = struct {
    lld_status: proc.Status = .{ .exited = 0 },
    lld_log: []const u8 = "",
    zig_status: proc.Status = .{ .exited = 0 },
    zig_log: []const u8 = "",
    /// What zig writes to its -o; null: nothing.
    zig_out: ?[]const u8 = ELF,
    /// The step whose start fails (error.ForkFailed), or none.
    fail_start: ?[]const u8 = null,
    /// What llvm-nm prints for a file: the first row whose suffix ends the file's path (the object is `pg.o`); nothing for any other.
    nm_lists: []const [2][]const u8 = &.{},
    /// The file llvm-nm fails on (a suffix of its path), with what it says on stderr; none: it never fails.
    nm_fails_on: ?[]const u8 = null,
    nm_stderr: []const u8 = "",
    calls: std.ArrayList(proc.Spec),

    fn init() Fake {
        return .{ .calls = std.ArrayList(proc.Spec).empty };
    }

    fn runner(self: *Fake) common.Runner {
        return .{ .ptr = self, .runFn = &run };
    }

    fn write(path: []const u8, data: []const u8) !void {
        var f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(data);
    }

    fn outOf(argv: []const []const u8) []const u8 {
        for (argv, 0..) |a, i| if (std.mem.eql(u8, a, "-o")) return argv[i + 1];
        unreachable;
    }

    fn run(ptr: *anyopaque, alloc: std.mem.Allocator, spec: proc.Spec) anyerror!proc.Outcome {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        var copy = spec;
        copy.argv = try alloc.dupe([]const u8, spec.argv);
        copy.env = try alloc.dupe([]const u8, spec.env);
        try self.calls.append(alloc, copy);
        const step: []const u8 = if (std.mem.eql(u8, spec.argv[1], "-flavor"))
            "lld"
        else if (std.mem.eql(u8, spec.argv[1], "cc"))
            "zig"
        else if (std.mem.eql(u8, spec.argv[1], "--format=posix"))
            "nm"
        else
            return error.UnknownStep;
        if (self.fail_start) |f| if (std.mem.eql(u8, f, step)) return error.ForkFailed;
        var status: proc.Status = .{ .exited = 0 };
        if (std.mem.eql(u8, step, "nm")) {
            const file = spec.argv[spec.argv.len - 1];
            var text: []const u8 = "";
            for (self.nm_lists) |row| {
                if (std.mem.endsWith(u8, file, row[0])) {
                    text = row[1];
                    break;
                }
            }
            try write(spec.stdout_path.?, text);
            const failing = if (self.nm_fails_on) |f| std.mem.endsWith(u8, file, f) else false;
            try write(spec.stderr_path.?, if (failing) self.nm_stderr else "");
            return .{ .status = .{ .exited = if (failing) 1 else 0 } };
        }
        if (std.mem.eql(u8, step, "lld")) {
            try write(spec.stdout_path.?, self.lld_log);
            try write(outOf(spec.argv), "relocatable");
            status = self.lld_status;
        } else {
            try write(spec.stdout_path.?, self.zig_log);
            if (self.zig_out) |o| try write(outOf(spec.argv), o);
            status = self.zig_status;
        }
        return .{ .status = status };
    }
};

const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: []const u8 = "",
    err: std.ArrayList(u8) = undefined,

    fn init() !Case {
        var c = Case{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .tmp = testing.tmpDir(.{}) };
        c.root = try c.tmp.dir.realpathAlloc(c.arena.allocator(), ".");
        c.err = std.ArrayList(u8).empty;
        // The inputs, each a file that is not empty.
        for ([_][2][]const u8{
            .{ "lld/bin/lld", "lld" },
            .{ "rt/libclang_rt.profile-x86_64.a", "!<arch>\n" },
            .{ "tc/compiler/lib/libKGENCompilerRTShared.so", "\x7fELF" },
            .{ "tc/zig/zig", "zig" },
            .{ "cov/test_one.bc", "BC\xc0\xde\x35\x14" },
            .{ "nm/bin/llvm-nm", "nm" },
            // The native libraries of a unit: two static archives (the first needs the second) and a shared object.
            .{ "nat/libprobe_sys.a", "!<arch>\nprobe" },
            .{ "nat/libbase_sys.a", "!<arch>\nbase" },
            .{ "nat/libcnative.so.1", "\x7fELF\x02\x01\x01\x00shared" },
        }) |f| try c.put(f[0], f[1]);
        return c;
    }

    fn put(self: *Case, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |d| try self.tmp.dir.makePath(d);
        try self.tmp.dir.writeFile(.{ .sub_path = path, .data = data });
    }

    fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn a(self: *Case) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn p(self: *Case, rel: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a(), "{s}/{s}", .{ self.root, rel }) catch unreachable;
    }

    fn where(self: *Case) common.Where {
        return .{
            .cwd = self.root,
            .k = self.p("scratch/cov_branch_link"),
            .env = &.{ "HOME=/h/user", "HOMEDIR=/keep", "LC_ALL=fr_FR.UTF-8", "PATH=/usr/bin:/bin", "TMPDIR=/tmp", "ZED=1", "ZIG_GLOBAL_CACHE_DIR=/z", "ZIG_LOCAL_CACHE_DIR=/zl" },
        };
    }

    fn args(_: *Case) l.Args {
        return .{
            .compiler = "tc/compiler",
            .zig = "tc/zig",
            .target = "x86_64-linux-gnu.2.28",
            .lld = "lld/bin/lld",
            .runtime = "rt/libclang_rt.profile-x86_64.a",
            .bitcode = "cov/test_one.bc",
            .out = "cov/test_one",
            .nm = "nm/bin/llvm-nm",
        };
    }

    /// The arguments with the unit's three native libraries, in the order of its graph.
    fn argsWithNatives(self: *Case) l.Args {
        var with = self.args();
        with.natives = &.{ "nat/libprobe_sys.a", "nat/libbase_sys.a", "nat/libcnative.so.1" };
        return with;
    }

    fn link(self: *Case, fake: *Fake) !u8 {
        return l.linkAll(self.a(), self.args(), self.where(), fake.runner(), &self.err);
    }

    fn linkWithNatives(self: *Case, fake: *Fake) !u8 {
        return l.linkAll(self.a(), self.argsWithNatives(), self.where(), fake.runner(), &self.err);
    }

    fn has(self: *Case, s: []const u8) !void {
        if (std.mem.indexOf(u8, self.err.items, s) == null) {
            std.debug.print("message does not hold '{s}':\n{s}\n", .{ s, self.err.items });
            return error.TestUnexpectedResult;
        }
    }

    fn exists(self: *Case, rel: []const u8) bool {
        self.tmp.dir.access(rel, .{}) catch return false;
        return true;
    }
};

fn expectArgv(want: []const []const u8, got: []const []const u8) !void {
    testing.expectEqual(want.len, got.len) catch |e| {
        std.debug.print("want {d} entries, got {d}:\n", .{ want.len, got.len });
        for (got) |g| std.debug.print("  {s}\n", .{g});
        return e;
    };
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "a link: lld's and zig's command lines and environments, the binary, no message, the scratch removed" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    try testing.expectEqual(@as(u8, 0), try c.link(&fake));
    try testing.expectEqualStrings("", c.err.items);
    try testing.expectEqual(@as(usize, 2), fake.calls.items.len);
    const k = c.p("scratch/cov_branch_link");

    const lld = fake.calls.items[0];
    try expectArgv(&.{
        c.p("lld/bin/lld"), "-flavor",  "gnu",                                                    "-r", "-m", "elf_x86_64", c.p("cov/test_one.bc"), "-o",
        c.p("scratch/cov_branch_link/pg.o"), "--lto-O0", "--lto-newpm-passes=pgo-instr-gen,instrprof,default<O0>",
        "-mllvm",                            "-instrprof-atomic-counter-update-all",
    }, lld.argv);
    try testing.expectEqualStrings(c.p("scratch/cov_branch_link/log"), lld.stdout_path.?);
    try testing.expect(lld.stderr_to_stdout);

    const zig = fake.calls.items[1];
    try expectArgv(&.{
        c.p("tc/zig/zig"),                   "cc",                                              "-target", "x86_64-linux-gnu.2.28", "-Wl,--strip-debug", "-Wl,--enable-new-dtags", "-Wl,-rpath,$ORIGIN/lib",
        c.p("scratch/cov_branch_link/pg.o"), c.p("tc/compiler/lib/libKGENCompilerRTShared.so"), "-o",     c.p("cov/test_one"),     "-Wl,--gc-sections", "-lm",
        "-Wl,--whole-archive",               c.p("rt/libclang_rt.profile-x86_64.a"),            "-Wl,--no-whole-archive",
    }, zig.argv);
    try testing.expectEqualStrings(c.p("scratch/cov_branch_link/log"), zig.stdout_path.?);
    try testing.expect(zig.stderr_to_stdout);

    // lld and zig: the scratch's PATH, HOME, TMPDIR and zig caches, LC_ALL=C; the rest as given (HOMEDIR is not HOME).
    const want_env = [_][]const u8{
        "HOMEDIR=/keep",
        "ZED=1",
        try std.fmt.allocPrint(c.a(), "PATH={s}/bin", .{k}),
        try std.fmt.allocPrint(c.a(), "HOME={s}/home", .{k}),
        try std.fmt.allocPrint(c.a(), "TMPDIR={s}/tmp", .{k}),
        try std.fmt.allocPrint(c.a(), "ZIG_GLOBAL_CACHE_DIR={s}/zig-global", .{k}),
        try std.fmt.allocPrint(c.a(), "ZIG_LOCAL_CACHE_DIR={s}/zig-local", .{k}),
        "LC_ALL=C",
    };
    try expectArgv(&want_env, lld.env);
    try expectArgv(&want_env, zig.env);

    try testing.expectEqualStrings(ELF, try c.tmp.dir.readFileAlloc(c.a(), "cov/test_one", 1 << 20));
    try testing.expect(!c.exists("scratch/cov_branch_link"));
}

test "lldArgv asks LLVM for atomic counter updates: -mllvm and the option, adjacent, once" {
    // Without it the counters are a load, an add and a store (an `incq` or `addq` with no `lock`), and two threads incrementing one
    // counter lose increments; README.md, "Atomic counters".
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try l.lldArgv(arena.allocator(), "/l/lld", "/b/t.bc", "/k");
    var at: ?usize = null;
    for (v, 0..) |a, i| {
        if (std.mem.eql(u8, a, "-instrprof-atomic-counter-update-all")) {
            try testing.expect(at == null);
            at = i;
        }
    }
    try testing.expect(at != null);
    try testing.expect(at.? >= 1);
    try testing.expectEqualStrings("-mllvm", v[at.? - 1]);
}

test "zig's line ends with the profile runtime, taken whole" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    try testing.expectEqual(@as(u8, 0), try c.link(&fake));
    const argv = fake.calls.items[1].argv;
    try testing.expectEqualStrings("-Wl,--no-whole-archive", argv[argv.len - 1]);
    try testing.expectEqualStrings("-Wl,--whole-archive", argv[argv.len - 3]);
}

test "each input missing or empty is a usage error naming it, before lld runs" {
    const inputs = [_][]const u8{
        "lld/bin/lld",
        "rt/libclang_rt.profile-x86_64.a",
        "tc/compiler/lib/libKGENCompilerRTShared.so",
        "tc/zig/zig",
        "cov/test_one.bc",
        "nm/bin/llvm-nm",
    };
    for (inputs) |f| {
        for ([_]bool{ false, true }) |empty| {
            var c = try Case.init();
            defer c.deinit();
            if (empty) try c.put(f, "") else try c.tmp.dir.deleteFile(f);
            var fake = Fake.init();
            try testing.expectEqual(@as(u8, 2), try c.link(&fake));
            try c.has(try std.fmt.allocPrint(c.a(), "cov_branch link: {s} is missing or empty", .{c.p(f)}));
            try testing.expectEqual(@as(usize, 0), fake.calls.items.len);
        }
    }
}

test "an input given as a symbolic link is read through it; a dangling one is missing" {
    var c = try Case.init();
    defer c.deinit();
    try c.tmp.dir.rename("tc/zig/zig", "tc/zig/zig.real");
    try c.tmp.dir.symLink("zig.real", "tc/zig/zig", .{});
    var fake = Fake.init();
    try testing.expectEqual(@as(u8, 0), try c.link(&fake));
    var d = try Case.init();
    defer d.deinit();
    try d.tmp.dir.deleteFile("tc/zig/zig");
    try d.tmp.dir.symLink("nowhere", "tc/zig/zig", .{});
    var fake2 = Fake.init();
    try testing.expectEqual(@as(u8, 2), try d.link(&fake2));
    try d.has("tc/zig/zig is missing or empty");
}

test "a bitcode without the bitcode magic is refused before lld runs, named as given" {
    // Each of the 4 magic bytes wrong on its own, as well as a short file: all 4 bytes are compared.
    for ([_][]const u8{ "BC\xc0", "AC\xc0\xde", "BD\xc0\xde", "BC\xc1\xde", "BC\xc0\xdf", "\xde\xc0CB", "\x7fELF\x02\x01" }) |bytes| {
        var c = try Case.init();
        defer c.deinit();
        try c.put("cov/test_one.bc", bytes);
        var fake = Fake.init();
        try testing.expectEqual(@as(u8, 1), try c.link(&fake));
        try c.has("BRANCH COVERAGE LINK FAILED: cov/test_one.bc is not LLVM bitcode\n");
        // No step has run, so there is no log, and no log header.
        try testing.expect(std.mem.indexOf(u8, c.err.items, "--- log:") == null);
        try testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    }
}

test "lld failing fails the link with the last 40 lines of its log; zig does not run; the scratch is kept" {
    var c = try Case.init();
    defer c.deinit();
    var log = std.ArrayList(u8).empty;
    for (1..51) |i| try log.writer(c.a()).print("lld line {d}\n", .{i});
    var fake = Fake.init();
    fake.lld_status = .{ .exited = 1 };
    fake.lld_log = log.items;
    try testing.expectEqual(@as(u8, 1), try c.link(&fake));
    try c.has("BRANCH COVERAGE LINK FAILED: lld could not instrument cov/test_one.bc (pgo-instr-gen)\n--- log:\nlld line 11\n");
    try c.has("lld line 50\n");
    try testing.expect(std.mem.indexOf(u8, c.err.items, "lld line 10\n") == null);
    // The log's own last newline ends the message: no blank line is added.
    try testing.expect(std.mem.endsWith(u8, c.err.items, "lld line 49\nlld line 50\n"));
    try testing.expectEqual(@as(usize, 1), fake.calls.items.len);
    try testing.expect(c.exists("scratch/cov_branch_link/log"));
}

test "lld killed by a signal fails the link; an empty log still prints its header" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    fake.lld_status = .{ .signaled = 9 };
    try testing.expectEqual(@as(u8, 1), try c.link(&fake));
    try testing.expectEqualStrings("BRANCH COVERAGE LINK FAILED: lld could not instrument cov/test_one.bc (pgo-instr-gen)\n--- log:\n", c.err.items);
}

test "zig failing fails the link with its log, the last line without a newline kept" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    fake.zig_status = .{ .exited = 1 };
    fake.zig_log = "ld.lld: error: undefined symbol: example_add";
    fake.zig_out = null;
    try testing.expectEqual(@as(u8, 1), try c.link(&fake));
    try c.has("BRANCH COVERAGE LINK FAILED: zig could not link the instrumented test with the profile runtime\n--- log:\nld.lld: error: undefined symbol: example_add\n");
    // A failed link keeps the scratch directory, its log included.
    try testing.expect(c.exists("scratch/cov_branch_link/log"));
}

test "zig killed by a signal fails the link; the scratch is kept" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    fake.zig_status = .{ .signaled = 9 };
    try testing.expectEqual(@as(u8, 1), try c.link(&fake));
    try c.has("BRANCH COVERAGE LINK FAILED: zig could not link the instrumented test with the profile runtime\n");
    try testing.expect(c.exists("scratch/cov_branch_link/log"));
}

test "a link that writes no ELF file, or nothing, fails; the scratch is kept" {
    // Each of the 4 magic bytes wrong on its own, as well as short and missing outputs.
    for ([_]?[]const u8{ null, "", "\x7fEL", "text, not a program\n", "\x7eELF\x02", "\x7fXLF\x02", "\x7fEXF\x02", "\x7fELG\x02" }) |out| {
        var c = try Case.init();
        defer c.deinit();
        var fake = Fake.init();
        fake.zig_out = out;
        try testing.expectEqual(@as(u8, 1), try c.link(&fake));
        try c.has("BRANCH COVERAGE LINK FAILED: the link wrote no ELF file\n");
        try testing.expect(c.exists("scratch/cov_branch_link/log"));
    }
}

test "a binary holding the working directory or the scratch directory fails, quoting where" {
    for ([_][]const u8{ "", "/scratch/cov_branch_link" }) |under| {
        var c = try Case.init();
        defer c.deinit();
        var fake = Fake.init();
        const d = try std.fmt.allocPrint(c.a(), "{s}{s}", .{ c.root, under });
        fake.zig_out = try std.fmt.allocPrint(c.a(), "{s}\x00\x01ab\x00{s}/x.c\x00\x02{s}\x00", .{ ELF, d, d });
        try testing.expectEqual(@as(u8, 1), try c.link(&fake));
        // The scratch directory holds the working directory: the first one found is the working directory.
        try c.has(try std.fmt.allocPrint(c.a(), "BRANCH COVERAGE LINK FAILED: the binary holds this action's directory {s}: {s}/x.c {s} \n", .{ c.root, d, d }));
        try testing.expect(c.exists("scratch/cov_branch_link/log"));
    }
}

test "the scratch directory is checked on its own: a binary holding it and not the working directory" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    var w = c.where();
    // A scratch directory outside the working directory.
    w.k = c.p("k");
    fake.zig_out = try std.fmt.allocPrint(c.a(), "{s}\x00{s}/pg.o\x00", .{ ELF, w.k });
    w.cwd = c.p("cov");
    var a = c.args();
    a.compiler = c.p("tc/compiler");
    a.zig = c.p("tc/zig");
    a.lld = c.p("lld/bin/lld");
    a.runtime = c.p("rt/libclang_rt.profile-x86_64.a");
    a.bitcode = c.p("cov/test_one.bc");
    a.nm = c.p("nm/bin/llvm-nm");
    a.out = c.p("out");
    try testing.expectEqual(@as(u8, 1), try l.linkAll(c.a(), a, w, fake.runner(), &c.err));
    try c.has(try std.fmt.allocPrint(c.a(), "the binary holds this action's directory {s}: {s}/pg.o \n", .{ w.k, w.k }));
}

test "the working directory anywhere in the binary fails: alone, after other bytes, before other bytes" {
    for ([_][2][]const u8{ .{ "", "" }, .{ "-I", "/inc" }, .{ "", "X" } }) |around| {
        var c = try Case.init();
        defer c.deinit();
        var fake = Fake.init();
        const s = try std.fmt.allocPrint(c.a(), "{s}{s}{s}", .{ around[0], c.root, around[1] });
        fake.zig_out = try std.fmt.allocPrint(c.a(), "{s}\x00{s}\x00", .{ ELF, s });
        try testing.expectEqual(@as(u8, 1), try c.link(&fake));
        try c.has(try std.fmt.allocPrint(c.a(), "BRANCH COVERAGE LINK FAILED: the binary holds this action's directory {s}: {s} \n", .{ c.root, s }));
    }
}

test "a program that cannot start is exit 2, naming it and not another step's" {
    for ([_]struct { step: []const u8, path: []const u8 }{
        .{ .step = "lld", .path = "lld/bin/lld" },
        .{ .step = "zig", .path = "tc/zig/zig" },
    }) |cs| {
        var c = try Case.init();
        defer c.deinit();
        var fake = Fake.init();
        fake.fail_start = cs.step;
        try testing.expectEqual(@as(u8, 2), try c.link(&fake));
        try testing.expectEqualStrings(try std.fmt.allocPrint(c.a(), "cov_branch link: cannot run {s}: ForkFailed\n", .{c.p(cs.path)}), c.err.items);
    }
}

test "a scratch directory that cannot be made is exit 2, the first one named, nothing run" {
    const names = [_][]const u8{ "bin", "home", "tmp" };
    for (names) |blocked| {
        var c = try Case.init();
        defer c.deinit();
        try c.put(try std.fmt.allocPrint(c.a(), "scratch/cov_branch_link/{s}", .{blocked}), "a file");
        var fake = Fake.init();
        try testing.expectEqual(@as(u8, 2), try c.link(&fake));
        try testing.expectEqualStrings(try std.fmt.allocPrint(c.a(), "cov_branch link: cannot make {s}/{s}: NotDir\n", .{ c.p("scratch/cov_branch_link"), blocked }), c.err.items);
        try testing.expectEqual(@as(usize, 0), fake.calls.items.len);
    }
}

test "usage errors: a missing, repeated, empty, unknown or valueless flag" {
    const full = [_][]const u8{ "--compiler", "c", "--zig", "z", "--target", "t", "--lld", "l", "--runtime", "r", "--bitcode", "bc", "--out", "o", "--nm", "n" };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    // Each flag left out.
    var i: usize = 0;
    while (i < full.len) : (i += 2) {
        var v = std.ArrayList([]const u8).empty;
        try v.appendSlice(a, full[0..i]);
        try v.appendSlice(a, full[i + 2 ..]);
        try testing.expect((try l.parseArgs(a, v.items, &why)) == null);
        try testing.expectEqualStrings(try std.fmt.allocPrint(a, "{s} is missing", .{full[i]}), why);
    }
    const cases = [_]struct { argv: []const []const u8, why: []const u8 }{
        .{ .argv = &(full ++ [_][]const u8{ "--out", "p" }), .why = "--out given twice" },
        .{ .argv = &([_][]const u8{ "--compiler", "" } ++ full[2..].*), .why = "--compiler is empty" },
        .{ .argv = &(full ++ [_][]const u8{ "--env", "A=1" }), .why = "unknown argument --env" },
        .{ .argv = &(full ++ [_][]const u8{ "--gate", "g" }), .why = "unknown argument --gate" },
        .{ .argv = &(full ++ [_][]const u8{"--target"}), .why = "--target needs a value" },
        .{ .argv = &(full ++ [_][]const u8{"stray"}), .why = "unknown argument stray" },
        // A flag is named in full: a longer or a shorter name is unknown.
        .{ .argv = &(full ++ [_][]const u8{ "--outx", "p" }), .why = "unknown argument --outx" },
        .{ .argv = &(full ++ [_][]const u8{ "--ou", "p" }), .why = "unknown argument --ou" },
    };
    for (cases) |cs| {
        try testing.expect((try l.parseArgs(a, cs.argv, &why)) == null);
        try testing.expectEqualStrings(cs.why, why);
    }
    // Through cli: the message and the usage line, exit 2, nothing run.
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    try testing.expectEqual(@as(u8, 2), try l.cli(c.a(), &.{ "--zig", "z" }, c.where(), fake.runner(), &c.err));
    try c.has("cov_branch link: usage error: --compiler is missing\n" ++ l.USAGE ++ "\n");
    try testing.expectEqual(@as(usize, 0), fake.calls.items.len);
}

// ---- native libraries -------------------------------------------------------------------------------------------------------------------------

const CLASH_MSG_TAIL = ", which the instrumented test object defines too: the linker keeps one of the two definitions and says nothing, so the binary would not be the program the test links\n";

test "natives: llvm-nm lists the object and each library, then zig links the libraries after the object, by path, in the order given" {
    // Defect caught: an instrumented link without the unit's libraries (it cannot link), or with them in another order (a static archive
    // resolves only what the libraries before it left undefined), or before the object (nothing is undefined yet, so nothing is taken).
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    fake.nm_lists = &.{
        .{ "pg.o", "main T 0 0\nmojo_entry T 0 0\n" },
        .{ "libprobe_sys.a", "libprobe_sys.a[probe.o]:\nprobe_sys_answer T 0 4\n\nlibprobe_sys.a[more.o]:\nprobe_more T 0 4\n" },
        .{ "libcnative.so.1", "cnative_answer T 0 4\n" },
    };
    try testing.expectEqual(@as(u8, 0), try c.linkWithNatives(&fake));
    try testing.expectEqualStrings("", c.err.items);
    try testing.expectEqual(@as(usize, 6), fake.calls.items.len);
    const nm = c.p("nm/bin/llvm-nm");
    const pg = c.p("scratch/cov_branch_link/pg.o");

    // The archives are listed as archives, the shared object by its dynamic table (-D), and the object first.
    try expectArgv(&.{ nm, "--format=posix", "--defined-only", "--extern-only", "--no-weak", pg }, fake.calls.items[1].argv);
    try expectArgv(&.{ nm, "--format=posix", "--defined-only", "--extern-only", "--no-weak", c.p("nat/libprobe_sys.a") }, fake.calls.items[2].argv);
    try expectArgv(&.{ nm, "--format=posix", "--defined-only", "--extern-only", "--no-weak", c.p("nat/libbase_sys.a") }, fake.calls.items[3].argv);
    try expectArgv(&.{ nm, "--format=posix", "--defined-only", "--extern-only", "--no-weak", "-D", c.p("nat/libcnative.so.1") }, fake.calls.items[4].argv);
    for (fake.calls.items[1..5]) |call| {
        try testing.expectEqualStrings(c.p("scratch/cov_branch_link/nm.out"), call.stdout_path.?);
        try testing.expectEqualStrings(c.p("scratch/cov_branch_link/log"), call.stderr_path.?);
        try expectArgv(fake.calls.items[0].env, call.env);
    }

    try expectArgv(&.{
        c.p("tc/zig/zig"),                   "cc",                                  "-target",               "x86_64-linux-gnu.2.28", "-Wl,--strip-debug", "-Wl,--enable-new-dtags", "-Wl,-rpath,$ORIGIN/lib",
        pg,                                  c.p("nat/libprobe_sys.a"),             c.p("nat/libbase_sys.a"), c.p("nat/libcnative.so.1"),
        c.p("tc/compiler/lib/libKGENCompilerRTShared.so"), "-o", c.p("cov/test_one"), "-Wl,--gc-sections", "-lm", "-Wl,--whole-archive", c.p("rt/libclang_rt.profile-x86_64.a"), "-Wl,--no-whole-archive",
    }, fake.calls.items[5].argv);
    try testing.expect(!c.exists("scratch/cov_branch_link"));
}

test "natives: a library that defines a symbol the instrumented object defines fails the link, naming the library and the symbols; zig does not run" {
    // Defect caught: a library whose definition the linker would silently pass over (an archive member is taken only for a symbol still
    // undefined), so the binary is not the program the test links.
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    fake.nm_lists = &.{
        .{ "pg.o", "main T 0 0\nshared_one T 0 0\nshared_two D 0 8\nonly_mine T 0 0\n" },
        .{ "libprobe_sys.a", "libprobe_sys.a[probe.o]:\nprobe_sys_answer T 0 4\n" },
        .{ "libbase_sys.a", "libbase_sys.a[b.o]:\nbase_sys_value T 0 4\nshared_one T 0 0\n\nlibbase_sys.a[c.o]:\nshared_two D 0 4\n" },
    };
    try testing.expectEqual(@as(u8, 1), try c.linkWithNatives(&fake));
    try testing.expectEqualStrings("BRANCH COVERAGE LINK FAILED: the native library libbase_sys.a defines shared_one, shared_two" ++ CLASH_MSG_TAIL, c.err.items);
    // lld, the object, the first library (clean), the second (clashing): the libraries after it are not listed, zig does not run, the scratch is kept.
    try testing.expectEqual(@as(usize, 4), fake.calls.items.len);
    try testing.expect(c.exists("scratch/cov_branch_link"));
}

test "natives: a shared object that defines a symbol of the object fails the link too" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    fake.nm_lists = &.{ .{ "pg.o", "main T 0 0\ncnative_answer T 0 4\n" }, .{ "libcnative.so.1", "cnative_answer T 0 4\n" } };
    try testing.expectEqual(@as(u8, 1), try c.linkWithNatives(&fake));
    try testing.expectEqualStrings("BRANCH COVERAGE LINK FAILED: the native library libcnative.so.1 defines cnative_answer" ++ CLASH_MSG_TAIL, c.err.items);
    try testing.expectEqual(@as(usize, 5), fake.calls.items.len);
}

test "natives: the message names five symbols and counts the rest" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    fake.nm_lists = &.{
        .{ "pg.o", "s1 T 0 0\ns2 T 0 0\ns3 T 0 0\ns4 T 0 0\ns5 T 0 0\ns6 T 0 0\ns7 T 0 0\n" },
        .{ "libprobe_sys.a", "s7 T 0 0\ns6 T 0 0\ns5 T 0 0\ns4 T 0 0\ns3 T 0 0\ns2 T 0 0\ns1 T 0 0\n" },
    };
    try testing.expectEqual(@as(u8, 1), try c.linkWithNatives(&fake));
    // In the order the library lists them: the first five, and 2 more.
    try testing.expectEqualStrings("BRANCH COVERAGE LINK FAILED: the native library libprobe_sys.a defines s7, s6, s5, s4, s3 and 2 more" ++ CLASH_MSG_TAIL, c.err.items);
}

test "natives: llvm-nm failing on the object or on a library fails the link with its errors in the log; zig does not run" {
    for ([_]struct { on: []const u8, named: []const u8, calls: usize }{
        .{ .on = "pg.o", .named = "pg.o", .calls = 2 },
        .{ .on = "libbase_sys.a", .named = "libbase_sys.a", .calls = 4 },
    }) |cs| {
        var c = try Case.init();
        defer c.deinit();
        var fake = Fake.init();
        fake.nm_fails_on = cs.on;
        fake.nm_stderr = "llvm-nm: error: file format not recognized\n";
        try testing.expectEqual(@as(u8, 1), try c.linkWithNatives(&fake));
        try testing.expectEqualStrings(try std.fmt.allocPrint(c.a(), "BRANCH COVERAGE LINK FAILED: llvm-nm could not list the symbols of {s}\n--- log:\nllvm-nm: error: file format not recognized\n", .{cs.named}), c.err.items);
        try testing.expectEqual(cs.calls, fake.calls.items.len);
    }
}

test "natives: an llvm-nm that cannot start is exit 2, naming it" {
    var c = try Case.init();
    defer c.deinit();
    var fake = Fake.init();
    fake.fail_start = "nm";
    try testing.expectEqual(@as(u8, 2), try c.linkWithNatives(&fake));
    try testing.expectEqualStrings(try std.fmt.allocPrint(c.a(), "cov_branch link: cannot run {s}: ForkFailed\n", .{c.p("nm/bin/llvm-nm")}), c.err.items);
    // Without a library llvm-nm is never started.
    var d = try Case.init();
    defer d.deinit();
    var fake2 = Fake.init();
    fake2.fail_start = "nm";
    try testing.expectEqual(@as(u8, 0), try d.link(&fake2));
}

test "natives: each library missing or empty is a usage error naming it, before lld runs" {
    for ([_][]const u8{ "nat/libprobe_sys.a", "nat/libbase_sys.a", "nat/libcnative.so.1" }) |f| {
        for ([_]bool{ false, true }) |empty| {
            var c = try Case.init();
            defer c.deinit();
            if (empty) try c.put(f, "") else try c.tmp.dir.deleteFile(f);
            var fake = Fake.init();
            try testing.expectEqual(@as(u8, 2), try c.linkWithNatives(&fake));
            try c.has(try std.fmt.allocPrint(c.a(), "cov_branch link: {s} is missing or empty\n", .{c.p(f)}));
            try testing.expectEqual(@as(usize, 0), fake.calls.items.len);
        }
    }
}

test "natives: --native repeats and keeps the order of the flags, wherever they stand; a valueless or empty one is a usage error" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const full = [_][]const u8{ "--compiler", "c", "--zig", "z", "--target", "t", "--lld", "l", "--runtime", "r", "--bitcode", "bc", "--out", "o", "--nm", "n" };
    var why: []const u8 = "";
    const none = (try l.parseArgs(a, &full, &why)).?;
    try testing.expectEqual(@as(usize, 0), none.natives.len);
    const got = (try l.parseArgs(a, &([_][]const u8{ "--native", "b.a" } ++ full ++ [_][]const u8{ "--native", "a.so.1", "--native", "c.a" }), &why)).?;
    try expectArgv(&.{ "b.a", "a.so.1", "c.a" }, got.natives);
    try testing.expectEqualStrings("n", got.nm);
    try testing.expectEqualStrings("c", got.compiler);
    try testing.expect((try l.parseArgs(a, &(full ++ [_][]const u8{"--native"}), &why)) == null);
    try testing.expectEqualStrings("--native needs a value", why);
    try testing.expect((try l.parseArgs(a, &(full ++ [_][]const u8{ "--native", "" }), &why)) == null);
    try testing.expectEqualStrings("--native is empty", why);
}

test "the symbols llvm-nm lists: the first field of each line, archive member headers and blank lines left out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectArgv(&.{}, try l.definedSymbols(a, ""));
    try expectArgv(&.{ "a", "b", "c" }, try l.definedSymbols(a, "libx.a[one.o]:\na T 0 4\nb D 10 8\n\nlibx.a[two.o]:\nc T 0\n"));
    // A line with one field is a name; a header of the other spelling, `(member):`, is a header too.
    try expectArgv(&.{"d"}, try l.definedSymbols(a, "libx.a(three.o):\nd\n"));
    // Without the final newline the last symbol is read.
    try expectArgv(&.{ "e", "f" }, try l.definedSymbols(a, "e T 0 0\nf T 0 0"));
}

test "the names two lists share are the second list's, in its order, and nothing when they share none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectArgv(&.{ "z", "a" }, try l.namesInBoth(a, &.{ "a", "m", "z" }, &.{ "z", "q", "a" }));
    try expectArgv(&.{}, try l.namesInBoth(a, &.{ "a", "b" }, &.{ "c", "d" }));
    try expectArgv(&.{}, try l.namesInBoth(a, &.{}, &.{"a"}));
    // A name is whole: one that is a prefix of another is not shared.
    try expectArgv(&.{}, try l.namesInBoth(a, &.{"abc"}, &.{ "ab", "abcd" }));
}

test "every allocation of a link with native libraries may fail, and fails cleanly" {
    var i: usize = 0;
    var finished = false;
    while (i < 3000 and !finished) : (i += 1) {
        var c = try Case.init();
        defer c.deinit();
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var fa = testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = i });
        var fake = Fake.init();
        fake.nm_lists = &.{ .{ "pg.o", "main T 0 0\n" }, .{ "libprobe_sys.a", "libprobe_sys.a[p.o]:\nprobe_sys_answer T 0 4\n" } };
        if (l.linkAll(fa.allocator(), c.argsWithNatives(), c.where(), fake.runner(), &c.err)) |code| {
            if (code == 0) {
                finished = true;
            } else {
                // A step that could not be started, or a file that could not be read, because the allocation for it failed: said so.
                try testing.expect(code == 1 or code == 2);
                try c.has("OutOfMemory");
            }
        } else |e| try testing.expectEqual(error.OutOfMemory, e);
    }
    try testing.expect(finished);
}

test "childEnv replaces a variable by its exact name: one whose value names it is kept" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = [_][]const u8{ "HOMX=HOME", "PATH=/k/bin", "HOME=/k/home", "TMPDIR=/k/tmp", "ZIG_GLOBAL_CACHE_DIR=/k/zig-global", "ZIG_LOCAL_CACHE_DIR=/k/zig-local", "LC_ALL=C" };
    try expectArgv(&want, try l.childEnv(a, &.{ "HOMX=HOME", "HOME=/h" }, "/k"));
}

test "stringsWith is the first three runs of four printable bytes that hold the needle" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("", try l.stringsWith(a, "abc", "abc"));
    try testing.expectEqualStrings("/w/x\t1 ", try l.stringsWith(a, "\x00/w/x\t1\x01/w", "/w"));
    try testing.expectEqualStrings("a/w1 b/w2 c/w3 ", try l.stringsWith(a, "a/w1\x00b/w2\x00zzzz\x00c/w3\x00d/w4", "/w"));
    try testing.expectEqualStrings("tail/w ", try l.stringsWith(a, "\xfftail/w", "/w"));
    // Printable is 0x20 (space) to 0x7e and tab: 0x1f, 0x7f and a newline end a run.
    try testing.expectEqualStrings("a /w b ", try l.stringsWith(a, "a /w b", "/w"));
    try testing.expectEqualStrings("/w12 ", try l.stringsWith(a, "x\x1f/w12", "/w"));
    try testing.expectEqualStrings("/w12 ", try l.stringsWith(a, "x\x7f/w12", "/w"));
    try testing.expectEqualStrings("/w12 ", try l.stringsWith(a, "x\n/w12", "/w"));
}

test "link tail: --link-tail repeats in order, ends the zig line after the profile runtime, and a link without one is the line it was" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const full = [_][]const u8{ "--compiler", "c", "--zig", "z", "--target", "t", "--lld", "l", "--runtime", "r", "--bitcode", "bc", "--out", "o", "--nm", "n" };
    var why: []const u8 = "";
    const none = (try l.parseArgs(a, &full, &why)).?;
    try testing.expectEqual(@as(usize, 0), none.link_tail.len);
    const got = (try l.parseArgs(a, &(full ++ [_][]const u8{ "--link-tail", "-lc++", "--link-tail", "-lm" }), &why)).?;
    try expectArgv(&.{ "-lc++", "-lm" }, got.link_tail);
    try testing.expect((try l.parseArgs(a, &(full ++ [_][]const u8{"--link-tail"}), &why)) == null);
    try testing.expectEqualStrings("--link-tail needs a value", why);
    const plain = try l.zigArgv(a, "/z", "t", "/k", "/kgen.so", "/o", "/rt.a", &.{"/n.a"}, &.{});
    const withtail = try l.zigArgv(a, "/z", "t", "/k", "/kgen.so", "/o", "/rt.a", &.{"/n.a"}, &.{"-lc++"});
    try testing.expectEqual(plain.len + 1, withtail.len);
    try testing.expectEqualStrings("-Wl,--no-whole-archive", plain[plain.len - 1]);
    try testing.expectEqualStrings("-lc++", withtail[withtail.len - 1]);
    try testing.expectEqualStrings("/n.a", withtail[8]);
}
