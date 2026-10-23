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
        else
            return error.UnknownStep;
        if (self.fail_start) |f| if (std.mem.eql(u8, f, step)) return error.ForkFailed;
        var status: proc.Status = .{ .exited = 0 };
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
        };
    }

    fn link(self: *Case, fake: *Fake) !u8 {
        return l.linkAll(self.a(), self.args(), self.where(), fake.runner(), &self.err);
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
    const full = [_][]const u8{ "--compiler", "c", "--zig", "z", "--target", "t", "--lld", "l", "--runtime", "r", "--bitcode", "bc", "--out", "o" };
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
