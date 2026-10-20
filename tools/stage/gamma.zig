//! The gamma stage (RELEASING.md): our own repositories build with the candidate on the farm, one after the other. Each repository is cloned,
//! its pin of buildrules in `.buckconfig` is set to the candidate commit in the working copy (nothing is committed), the farm's settings are
//! written as its `.buckconfig.local`, and its targets are built by buck2. The build must succeed and must report `local: 0`.
//!
//! The farm is never optional here: with no farm configured the stage fails and says which repository variables to set. The repositories are
//! named by a repository variable, so no repository is named in this file.
const std = @import("std");
const farm = @import("farm.zig");
const io_mod = @import("io.zig");

const Io = io_mod.Io;

pub const Options = struct {
    /// Space-separated `owner/name`, in build order.
    repos: []const u8,
    candidate: []const u8,
    targets: []const u8,
    work: []const u8,
    buck2: []const u8,
    /// The content of `.buckconfig.local` for the farm (`farm.buildrulesConfig` of the farm-connect file); empty when the file is missing.
    farm_config: []const u8,
    git_base: []const u8 = "https://github.com/",
};

pub const not_configured_message =
    \\gamma: the farm is not configured, so our own repositories were not built with this candidate. A release is not made without it.
    \\Set these repository variables (Settings, Secrets and variables, Actions, Variables):
    \\  FARM_ADDRESS, FARM_INSTANCE, FARM_LINUX_X86_64_PROPERTIES   the remote-execution service, its instance name and the worker property set
    \\  TS_CLIENT_ID, TS_AUDIENCE                                   the workload-identity credential that lets this repository join the farm's network
    \\  FARM_CONNECT_REPO, FARM_CONNECT_REF                         the repository of the farm-connect action and the full commit of it to use
    \\  GAMMA_REPOS                                                 the repositories to build, in order, as `owner/name owner/name`
    \\and, optionally, FARM_TLS (default false) and GAMMA_TARGETS (default //...). RELEASING.md describes each.
    \\
;

pub const Error = error{ NoRepos, BadRepo, NoCandidate, FarmNotConfigured, NoBuildrulesCell, StepFailed, FarmRanLocally, NoSummary, BadRef };

fn isHex40(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

fn repoNameOk(s: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, s, '/') orelse return false;
    if (slash == 0 or slash + 1 == s.len or std.mem.indexOfScalarPos(u8, s, slash + 1, '/') != null) return false;
    for (s) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '/';
        if (!ok) return false;
    }
    return !std.mem.startsWith(u8, s, ".") and !std.mem.endsWith(u8, s, ".") and std.mem.indexOf(u8, s, "..") == null;
}

/// The repositories of the variable, in order. An empty list, or a name that is not `owner/name`, is refused: nothing is cloned from a string
/// this function has not read as a plain repository name.
pub fn parseRepos(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |w| {
        if (!repoNameOk(w)) {
            std.debug.print("gamma: `{s}` is not a repository name (owner/name)\n", .{w});
            return error.BadRepo;
        }
        try out.append(a, w);
    }
    if (out.items.len == 0) return error.NoRepos;
    return out.items;
}

/// `.buckconfig` with the `commit_hash` of `[external_cell_buildrules]` set to `candidate`. A repository with no such section does not use
/// buildrules, and building it proves nothing about the candidate: that is refused.
pub fn pinCandidate(a: std.mem.Allocator, buckconfig: []const u8, candidate: []const u8) ![]u8 {
    if (!isHex40(candidate)) return error.NoCandidate;
    var out = std.ArrayList(u8).empty;
    var in_section = false;
    var replaced: usize = 0;
    var lines = std.mem.splitScalar(u8, buckconfig, '\n');
    var first = true;
    while (lines.next()) |raw| {
        if (!first) try out.append(a, '\n');
        first = false;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') in_section = std.mem.eql(u8, line, "[external_cell_buildrules]");
        if (in_section and std.mem.startsWith(u8, line, "commit_hash")) {
            const indent = raw[0 .. raw.len - std.mem.trimLeft(u8, raw, " \t").len];
            try out.print(a, "{s}commit_hash = {s}", .{ indent, candidate });
            replaced += 1;
        } else {
            try out.appendSlice(a, raw);
        }
    }
    if (replaced != 1) return error.NoBuildrulesCell;
    return out.toOwnedSlice(a);
}

fn lastName(repo: []const u8) []const u8 {
    return repo[std.mem.indexOfScalar(u8, repo, '/').? + 1 ..];
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("gamma: " ++ fmt ++ "\n", args);
}

pub fn run(a: std.mem.Allocator, io: Io, o: Options) !void {
    if (!farm.farmConfigured(o.farm_config)) {
        std.debug.print("{s}", .{not_configured_message});
        return error.FarmNotConfigured;
    }
    const repos = parseRepos(a, o.repos) catch |e| {
        if (e == error.NoRepos) std.debug.print("gamma: GAMMA_REPOS is empty: name the repositories to build, `owner/name owner/name`\n{s}", .{not_configured_message});
        return e;
    };
    if (!isHex40(o.candidate)) {
        fail("the candidate `{s}` is not a full commit", .{o.candidate});
        return error.NoCandidate;
    }
    for (repos, 0..) |repo, i| {
        const dir = try std.fmt.allocPrint(a, "{s}/{d}-{s}", .{ o.work, i + 1, lastName(repo) });
        io_mod.say("gamma: {s} ({d} of {d})\n", .{ repo, i + 1, repos.len });
        const url = try std.fmt.allocPrint(a, "{s}{s}", .{ o.git_base, repo });
        const clone = try io.run(a, o.work, &.{ "git", "clone", "--quiet", "--depth", "1", url, dir });
        if (clone.code != 0) {
            fail("cannot clone {s}: {s}", .{ repo, io_mod.tail(clone.stderr, 10) });
            return error.StepFailed;
        }
        const bc_path = try std.fs.path.join(a, &.{ dir, ".buckconfig" });
        const bc = std.fs.cwd().readFileAlloc(a, bc_path, 1 << 20) catch {
            fail("{s} has no .buckconfig, so it is not a Buck2 repository", .{repo});
            return error.StepFailed;
        };
        const pinned = pinCandidate(a, bc, o.candidate) catch |e| {
            if (e == error.NoBuildrulesCell) fail("{s} has no `commit_hash` in `[external_cell_buildrules]`: it does not use buildrules, so building it says nothing about the candidate. Remove it from GAMMA_REPOS until it does", .{repo});
            return e;
        };
        try std.fs.cwd().writeFile(.{ .sub_path = bc_path, .data = pinned });
        try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(a, &.{ dir, ".buckconfig.local" }), .data = o.farm_config });
        io_mod.say("gamma: {s} pinned to the candidate {s} (in the working copy only)\n", .{ repo, o.candidate });

        var argv = std.ArrayList([]const u8).empty;
        try argv.appendSlice(a, &.{ o.buck2, "build", "--console", "simple" });
        var ts = std.mem.tokenizeScalar(u8, o.targets, ' ');
        while (ts.next()) |tg| try argv.append(a, tg);
        const b = try io.run(a, dir, argv.items);
        _ = try io.run(a, dir, &.{ o.buck2, "kill" });
        if (b.code != 0) {
            fail("`buck2 build {s}` of {s} exited {d}\n{s}", .{ o.targets, repo, b.code, io_mod.tail(b.stderr, 60) });
            return error.StepFailed;
        }
        const s = farm.parseSummary(b.stderr) orelse {
            fail("the build of {s} printed no `Commands:` summary, so it cannot be shown to have run on the farm", .{repo});
            return error.NoSummary;
        };
        if (s.local != 0) {
            fail("{d} action(s) of {s} ran on this machine; the build must say `local: 0`", .{ s.local, repo });
            return error.FarmRanLocally;
        }
        io_mod.say("gamma: {s} built on the farm: Commands: {d} (cached: {d}, remote: {d}, local: 0)\n", .{ repo, s.total, s.cached, s.remote });
    }
}

/// The action repository the workflow checked out is the commit the variable names (a ref that moved, or a branch, is not a pin).
pub fn checkActionRef(a: std.mem.Allocator, io: Io, dir: []const u8, ref: []const u8) !void {
    if (!isHex40(ref)) {
        fail("FARM_CONNECT_REF `{s}` is not a full commit sha: the action that joins the farm is pinned by commit like every other action", .{ref});
        return error.BadRef;
    }
    const r = try io.run(a, dir, &.{ "git", "rev-parse", "HEAD" });
    const head = std.mem.trim(u8, r.stdout, " \r\n");
    if (r.code != 0 or !std.mem.eql(u8, head, ref)) {
        fail("the checked-out action is at `{s}`, not at FARM_CONNECT_REF {s}", .{ head, ref });
        return error.BadRef;
    }
}


/// The repository variables gamma needs, as `(flag, variable)`: the flag of `stage gamma-vars` and the variable the repository owner sets.
pub const required_vars = [_][2][]const u8{
    .{ "farm-address", "FARM_ADDRESS" },
    .{ "farm-instance", "FARM_INSTANCE" },
    .{ "farm-properties", "FARM_LINUX_X86_64_PROPERTIES" },
    .{ "ts-client-id", "TS_CLIENT_ID" },
    .{ "ts-audience", "TS_AUDIENCE" },
    .{ "connect-repo", "FARM_CONNECT_REPO" },
    .{ "connect-ref", "FARM_CONNECT_REF" },
    .{ "repos", "GAMMA_REPOS" },
};

/// The variables (by name) whose value is empty, only white space, or `false`. An unset repository variable reads as the empty string. The workflow passes the
/// farm's own variables as `${{ vars.X != '' }}`, so that no address or property set is written into the log; `false` is such a variable being empty.
pub fn emptyVariables(a: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (required_vars, 0..) |rv, i| {
        const v = if (i < values.len) values[i] else "";
        const t_v = std.mem.trim(u8, v, " \t\r\n");
        if (t_v.len == 0 or std.mem.eql(u8, t_v, "false")) try out.append(a, rv[1]);
    }
    return out.items;
}
// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;

const cand = "d" ** 40;
const old = "a" ** 40;
const cfg = "[buck2_re_client]\n  engine_address = grpc://example.invalid:1\n[buildrules_re]\n  linux_x86_64_properties = a=b\n";
const sample_buckconfig =
    \\[cells]
    \\  app = .
    \\
    \\[external_cell_other]
    \\  commit_hash = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    \\
    \\[external_cell_buildrules]
    \\  # a comment
    \\  git_origin = https://example.invalid/b.git
    \\  commit_hash = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    \\
    \\[buildfile]
    \\  name = BUCK
    \\
;

test "the candidate replaces the pin of buildrules and nothing else" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try pinCandidate(a, sample_buckconfig, cand);
    const want = try std.mem.replaceOwned(u8, a, sample_buckconfig, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", cand);
    try t.expectEqualStrings(want, got);
    // the other cell's pin is untouched
    try t.expect(std.mem.indexOf(u8, got, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") != null);
}

test "a repository that does not use buildrules, or has two pins, or a candidate that is no commit, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.NoBuildrulesCell, pinCandidate(a, "[cells]\n  app = .\n", cand));
    try t.expectError(error.NoBuildrulesCell, pinCandidate(a, "[external_cell_other]\n  commit_hash = x\n", cand));
    try t.expectError(error.NoBuildrulesCell, pinCandidate(a, sample_buckconfig ++ "[external_cell_buildrules]\n  commit_hash = x\n", cand));
    try t.expectError(error.NoCandidate, pinCandidate(a, sample_buckconfig, "main"));
    try t.expectError(error.NoCandidate, pinCandidate(a, sample_buckconfig, "D" ** 40));
}

test "the repository variable is read as plain names, in order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseRepos(a, " org/first   org/second\n");
    try t.expectEqual(@as(usize, 2), r.len);
    try t.expectEqualStrings("org/first", r[0]);
    try t.expectEqualStrings("org/second", r[1]);
    try t.expectError(error.NoRepos, parseRepos(a, ""));
    try t.expectError(error.NoRepos, parseRepos(a, "  \n"));
    for ([_][]const u8{ "noslash", "a/b/c", "/b", "a/", "a/b;rm", "a/$(x)", "../x", "a/..", "a/b c/../d", "-x/y z" }) |bad| {
        if (parseRepos(a, bad)) |_| {
            if (std.mem.indexOfScalar(u8, bad, ' ') == null) return error.AcceptedABadName;
        } else |e| try t.expect(e == error.BadRepo);
    }
}

const GFake = struct {
    a: std.mem.Allocator,
    calls: std.ArrayList([]const u8) = .empty,
    build_out: io_mod.Out,
    /// The .buckconfig each clone makes.
    buckconfig: []const u8 = sample_buckconfig,
    clone_code: u8 = 0,

    fn runCmd(ctx: *anyopaque, a: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) anyerror!io_mod.Out {
        const self: *GFake = @ptrCast(@alignCast(ctx));
        const line = try std.mem.join(a, " ", argv);
        try self.calls.append(self.a, try std.fmt.allocPrint(self.a, "{s} :: {s}", .{ cwd, line }));
        if (std.mem.startsWith(u8, line, "git clone")) {
            if (self.clone_code != 0) return .{ .code = self.clone_code, .stdout = "", .stderr = "fatal" };
            const dir = argv[argv.len - 1];
            try std.fs.cwd().makePath(dir);
            try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(a, &.{ dir, ".buckconfig" }), .data = self.buckconfig });
            return .{ .code = 0, .stdout = "", .stderr = "" };
        }
        if (std.mem.indexOf(u8, line, "buck2 build") != null) return self.build_out;
        if (std.mem.indexOf(u8, line, "buck2 kill") != null) return .{ .code = 0, .stdout = "", .stderr = "" };
        return error.UnscriptedCommand;
    }

    fn io(self: *GFake) Io {
        return .{ .ctx = self, .run_fn = runCmd };
    }

    fn count(self: *const GFake, needle: []const u8) usize {
        var n: usize = 0;
        for (self.calls.items) |c| {
            if (std.mem.indexOf(u8, c, needle) != null) n += 1;
        }
        return n;
    }
};

fn gammaOpts(work: []const u8, repos: []const u8) Options {
    return .{ .repos = repos, .candidate = cand, .targets = "//...", .work = work, .buck2 = "/bin/buck2", .farm_config = cfg };
}

test "gamma builds each repository in order with the candidate pinned and the farm's settings, and each must say local: 0" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const work = try tmp.dir.realpathAlloc(a, ".");
    var fake = GFake{ .a = a, .build_out = .{ .code = 0, .stdout = "", .stderr = "Commands: 9 (cached: 4, remote: 5, local: 0)\nBUILD SUCCEEDED\n" } };
    try run(a, fake.io(), gammaOpts(work, "org/first org/second"));
    try t.expectEqual(@as(usize, 2), fake.count("git clone --quiet --depth 1 https://github.com/org/"));
    // the order of the variable is the order of the builds
    var first_at: usize = 0;
    var second_at: usize = 0;
    for (fake.calls.items, 0..) |c, i| {
        if (std.mem.indexOf(u8, c, "1-first :: /bin/buck2 build") != null) first_at = i;
        if (std.mem.indexOf(u8, c, "2-second :: /bin/buck2 build") != null) second_at = i;
    }
    try t.expect(first_at != 0 and second_at > first_at);
    // the working copies hold the candidate and the farm's settings
    const bc = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ work, "1-first/.buckconfig" }), 1 << 16);
    try t.expect(std.mem.indexOf(u8, bc, "commit_hash = " ++ cand) != null);
    try t.expect(std.mem.indexOf(u8, bc, "aaaaaaaa") == null);
    try t.expectEqualStrings(cfg, try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ work, "2-second/.buckconfig.local" }), 1 << 16));
    // buck2 is stopped after each
    try t.expectEqual(@as(usize, 2), fake.count("buck2 kill"));
}

test "gamma is red with no farm, no repositories, a build that failed or ran locally, or a repository that does not use buildrules" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const work = try tmp.dir.realpathAlloc(a, ".");
    const good = io_mod.Out{ .code = 0, .stdout = "", .stderr = "Commands: 9 (cached: 4, remote: 5, local: 0)\n" };

    // no farm: nothing is cloned, and the message names the variables
    var fake = GFake{ .a = a, .build_out = good };
    var o = gammaOpts(work, "org/first");
    o.farm_config = "";
    try t.expectError(error.FarmNotConfigured, run(a, fake.io(), o));
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
    o.farm_config = "[buck2_re_client]\n  tls = false\n";
    try t.expectError(error.FarmNotConfigured, run(a, fake.io(), o));
    try t.expect(std.mem.indexOf(u8, not_configured_message, "FARM_ADDRESS") != null);
    try t.expect(std.mem.indexOf(u8, not_configured_message, "GAMMA_REPOS") != null);

    // no repositories, a bad name: nothing is cloned
    try t.expectError(error.NoRepos, run(a, fake.io(), gammaOpts(work, "")));
    try t.expectError(error.BadRepo, run(a, fake.io(), gammaOpts(work, "org/ok bad;name")));
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);

    // a candidate that is not a commit
    var oc = gammaOpts(work, "org/first");
    oc.candidate = "main";
    try t.expectError(error.NoCandidate, run(a, fake.io(), oc));

    // the build ran something on this machine
    var local = GFake{ .a = a, .build_out = .{ .code = 0, .stdout = "", .stderr = "Commands: 9 (cached: 0, remote: 5, local: 4)\n" } };
    try t.expectError(error.FarmRanLocally, run(a, local.io(), gammaOpts(work, "org/first")));
    // no summary line
    var nosum = GFake{ .a = a, .build_out = .{ .code = 0, .stdout = "", .stderr = "BUILD SUCCEEDED\n" } };
    try t.expectError(error.NoSummary, run(a, nosum.io(), gammaOpts(work, "org/first")));
    // the build failed: the second repository is not tried
    var failed = GFake{ .a = a, .build_out = .{ .code = 1, .stdout = "", .stderr = "BUILD FAILED\n" } };
    try t.expectError(error.StepFailed, run(a, failed.io(), gammaOpts(work, "org/first org/second")));
    try t.expectEqual(@as(usize, 1), failed.count("git clone"));
    // the clone failed
    var noclone = GFake{ .a = a, .build_out = good, .clone_code = 128 };
    try t.expectError(error.StepFailed, run(a, noclone.io(), gammaOpts(work, "org/first")));
    // a repository with no buildrules cell is refused, and nothing is built
    var nocell = GFake{ .a = a, .build_out = good, .buckconfig = "[cells]\n  app = .\n" };
    try t.expectError(error.NoBuildrulesCell, run(a, nocell.io(), gammaOpts(work, "org/first")));
    try t.expectEqual(@as(usize, 0), nocell.count("buck2 build"));
}

test "the action the workflow checked out must be the commit the variable names" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = GFake{ .a = a, .build_out = undefined };
    const Head = struct {
        fn run(ctx: *anyopaque, al: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) anyerror!io_mod.Out {
            _ = al;
            _ = cwd;
            _ = argv;
            const which: *[]const u8 = @ptrCast(@alignCast(ctx));
            return .{ .code = 0, .stdout = which.*, .stderr = "" };
        }
    };
    var head: []const u8 = old ++ "\n";
    const io = Io{ .ctx = @ptrCast(&head), .run_fn = Head.run };
    try checkActionRef(a, io, "/x", old);
    try t.expectError(error.BadRef, checkActionRef(a, io, "/x", cand));
    try t.expectError(error.BadRef, checkActionRef(a, io, "/x", "main"));
    try t.expectError(error.BadRef, checkActionRef(a, io, "/x", ""));
    _ = &fake;
}

test "the variables gamma needs are found empty one by one" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = [_][]const u8{ "grpc://example.invalid:1", "main", "a=b", "id", "aud", "org/connect", old, "org/first" };
    try t.expectEqual(@as(usize, 0), (try emptyVariables(a, &all)).len);
    // each one, emptied alone, is the one named
    for (required_vars, 0..) |rv, i| {
        var vals = all;
        vals[i] = "";
        const missing = try emptyVariables(a, &vals);
        try t.expectEqual(@as(usize, 1), missing.len);
        try t.expectEqualStrings(rv[1], missing[0]);
    }
    // white space is empty; nothing given is everything missing
    var ws = all;
    ws[7] = " \n";
    ws[0] = "false";
    const both = try emptyVariables(a, &ws);
    try t.expectEqualStrings("FARM_ADDRESS", both[0]);
    try t.expectEqualStrings("GAMMA_REPOS", both[1]);
    try t.expectEqual(required_vars.len, (try emptyVariables(a, &.{})).len);
}
