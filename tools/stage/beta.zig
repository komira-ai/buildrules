//! The beta stage (RELEASING.md): a hello-world repository per language consumes the candidate commit of buildrules as an external Buck2 cell,
//! the way a user does. `beta/<lang>/` holds the files a user writes and `STEPS` the commands a user types (steps.zig); this file copies the
//! directory to a fresh place outside the checkout, runs the steps with the `buildrules` built from the candidate, builds, runs what was
//! built, and (in local mode) builds twice from nothing to see that the outputs are the same bytes.
//!
//! The pure pieces (which leg is planned, the copy rules, the hashing of an output) are functions of their input; the steps are driven through
//! an `Io`, so the tests run them against a fake that writes the files a build would.
const std = @import("std");
const steps_mod = @import("steps.zig");
const farm = @import("farm.zig");
const io_mod = @import("io.zig");

const Io = io_mod.Io;

pub const Exec = union(enum) {
    /// Every action runs on the machine running buck2 (a CI runner).
    local,
    /// A farm: the content of `.buckconfig.local`, from `farm.buildrulesConfig`. Every build must report `local: 0`.
    farm: []const u8,
};

pub const Options = struct {
    lang: []const u8,
    /// The checkout of the candidate (`beta/<lang>/` is read from it, and `rules/mopm/pins.bzl`).
    root: []const u8,
    /// Where the user-style repository is made; outside the checkout.
    work: []const u8,
    origin: []const u8,
    commit: []const u8,
    buck2: []const u8,
    buildrules: []const u8,
    exec: Exec,
};

pub const Output = struct { target: []const u8, path: []const u8, sha256: [64]u8 };

pub const Outcome = enum { passed, planned };

pub const Result = struct {
    outcome: Outcome,
    /// For a planned leg, why.
    reason: []const u8 = "",
    outputs: []const Output = &.{},
    /// Whether the second build, after a clean, gave the same bytes. Null when it was not made (farm: its cache answers).
    deterministic: ?bool = null,
};

pub const mopm_pins = "rules/mopm/pins.bzl";

/// Whether the leg waits for something that has not happened. `mopm-release`: the pinned mopm is still a stand-in (its row is marked
/// `release_pending`), so a Mojo repository cannot be built the way a user would.
pub fn plannedReason(a: std.mem.Allocator, root: []const u8, spec: steps_mod.Spec) !?[]const u8 {
    const cond = spec.planned_until orelse return null;
    if (std.mem.eql(u8, cond, "mopm-release")) {
        const path = try std.fs.path.join(a, &.{ root, mopm_pins });
        const text = try std.fs.cwd().readFileAlloc(a, path, 1 << 20);
        if (std.mem.indexOf(u8, text, "\"release_pending\": True") != null)
            return "planned until mopm's first release: the mopm that buildrules pins is a stand-in (rules/mopm/pins.bzl marks it release_pending), so a Mojo repository cannot be built the way a user would";
        return null;
    }
    return error.UnknownCondition;
}

/// Copies `beta/<lang>/` to `dst`: every file but STEPS, with `BUCK.beta` written as `BUCK` (the file is kept under another name in the
/// buildrules repository so that its own Buck2 graph does not read a user's repository as packages of its own).
pub fn copyTree(a: std.mem.Allocator, src: []const u8, dst: []const u8) !usize {
    var sd = try std.fs.cwd().openDir(src, .{ .iterate = true });
    defer sd.close();
    try std.fs.cwd().makePath(dst);
    var dd = try std.fs.cwd().openDir(dst, .{});
    defer dd.close();
    var w = try sd.walk(a);
    defer w.deinit();
    var n: usize = 0;
    while (try w.next()) |e| {
        switch (e.kind) {
            .directory => try dd.makePath(e.path),
            .file => {
                if (std.mem.eql(u8, e.path, "STEPS")) continue;
                var target: []const u8 = e.path;
                if (std.mem.eql(u8, e.basename, "BUCK.beta")) {
                    target = try std.fmt.allocPrint(a, "{s}BUCK", .{e.path[0 .. e.path.len - "BUCK.beta".len]});
                }
                if (std.fs.path.dirname(target)) |d| try dd.makePath(d);
                try sd.copyFile(e.path, dd, target, .{});
                n += 1;
            },
            else => return error.UnexpectedFileKind,
        }
    }
    return n;
}

/// The sha256 of an output: of a file's bytes, or of a directory's entries (each relative path and its bytes, in the order of the paths).
pub fn hashOutput(a: std.mem.Allocator, dir: std.fs.Dir, path: []const u8) ![64]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    const st = try dir.statFile(path);
    if (st.kind == .directory) {
        var od = try dir.openDir(path, .{ .iterate = true });
        defer od.close();
        var names = std.ArrayList([]const u8).empty;
        var w = try od.walk(a);
        defer w.deinit();
        while (try w.next()) |e| {
            if ((e.kind == .file or e.kind == .sym_link)) try names.append(a, try a.dupe(u8, e.path));
        }
        std.mem.sort([]const u8, names.items, {}, lessThan);
        for (names.items) |n| {
            const bytes = try od.readFileAlloc(a, n, 1 << 30);
            var len: [8]u8 = undefined;
            std.mem.writeInt(u64, &len, bytes.len, .little);
            h.update(n);
            h.update("\x00");
            h.update(&len);
            h.update(bytes);
        }
        h.update("dir");
    } else {
        const bytes = try dir.readFileAlloc(a, path, 1 << 30);
        h.update(bytes);
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}


/// `buck2 build` of the targets, with their outputs. Local mode passes the mode on the command; a farm run must report no local command.
fn build(a: std.mem.Allocator, io: Io, o: Options, targets: []const []const u8) ![]const Output {
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{ o.buck2, "build", "--console", "simple" });
    if (o.exec == .local) try argv.appendSlice(a, &.{ "-c", "buildrules_re.mode=local" });
    try argv.append(a, "--show-output");
    try argv.appendSlice(a, targets);
    const r = try io.run(a, o.work, argv.items);
    if (r.code != 0) {
        std.debug.print("beta {s}: `{s}` exited {d}\n{s}\n{s}\n", .{ o.lang, try std.mem.join(a, " ", argv.items), r.code, io_mod.tail(r.stderr, 60), io_mod.tail(r.stdout, 20) });
        return error.StepFailed;
    }
    if (o.exec == .farm) {
        const s = farm.parseSummary(r.stderr) orelse blk: {
            if (farm.idleBuild(r.stderr)) break :blk farm.Summary{ .total = 0, .cached = 0, .remote = 0, .local = 0 };
            std.debug.print("beta {s}: the build printed no `Commands:` summary, so it cannot be shown to have run on the farm\n{s}\n", .{ o.lang, io_mod.tail(r.stderr, 30) });
            return error.NoSummary;
        };
        if (s.local != 0) {
            std.debug.print("beta {s}: {d} action(s) ran on this machine; a farm run must say `local: 0`\n", .{ o.lang, s.local });
            return error.FarmRanLocally;
        }
    }
    var outs = std.ArrayList(Output).empty;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |l| {
        const line = std.mem.trimRight(u8, l, "\r");
        if (line.len == 0) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const path = std.mem.trim(u8, line[@min(sp + 1, line.len)..], " ");
        try outs.append(a, .{ .target = try a.dupe(u8, line[0..sp]), .path = try a.dupe(u8, path), .sha256 = undefined });
    }
    return outs.items;
}

fn outputOf(outs: []const Output, target: []const u8) ?[]const u8 {
    // buck2 prints the full label (`root//crates/hello:bin`); a step names it `//crates/hello:bin`
    for (outs) |x| {
        if (x.path.len != 0 and std.mem.endsWith(u8, x.target, target)) return x.path;
    }
    return null;
}

fn trimNl(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, "\r\n");
}

fn hashAll(a: std.mem.Allocator, o: Options, outs: []const Output) ![]Output {
    var dir = try std.fs.cwd().openDir(o.work, .{});
    defer dir.close();
    var res = std.ArrayList(Output).empty;
    for (outs) |x| {
        if (x.path.len == 0) continue;
        try res.append(a, .{ .target = x.target, .path = x.path, .sha256 = try hashOutput(a, dir, x.path) });
    }
    return res.items;
}

pub fn run(a: std.mem.Allocator, io: Io, o: Options) !Result {
    const steps_path = try std.fs.path.join(a, &.{ o.root, "beta", o.lang, "STEPS" });
    const steps_text = std.fs.cwd().readFileAlloc(a, steps_path, 1 << 20) catch |e| {
        std.debug.print("beta {s}: cannot read {s}: {s}\n", .{ o.lang, steps_path, @errorName(e) });
        return error.NoSuchLanguage;
    };
    const spec = try steps_mod.parse(a, steps_text);
    if (try plannedReason(a, o.root, spec)) |why| return .{ .outcome = .planned, .reason = why };

    // A fresh repository, outside the checkout: a stale one would hide what `init` and the commands do.
    std.fs.cwd().access(try std.fs.path.join(a, &.{ o.work, ".buckconfig" }), .{}) catch {
        const n = try copyTree(a, try std.fs.path.join(a, &.{ o.root, "beta", o.lang }), o.work);
        io_mod.say("beta {s}: copied {d} file(s) of beta/{s} to a fresh repository\n", .{ o.lang, n, o.lang });
        return runSteps(a, io, o, spec);
    };
    std.debug.print("beta {s}: {s} already holds a repository (.buckconfig); the beta starts from an empty directory\n", .{ o.lang, o.work });
    return error.WorkNotFresh;
}

fn runSteps(a: std.mem.Allocator, io: Io, o: Options, spec: steps_mod.Spec) !Result {
    var targets = std.ArrayList([]const u8).empty;
    for (spec.steps) |step| switch (step) {
        .run => |words| {
            var argv = std.ArrayList([]const u8).empty;
            for (words) |w| {
                const s = try steps_mod.substitute(a, w, o.origin, o.commit);
                try argv.append(a, if (std.mem.eql(u8, s, "buildrules")) o.buildrules else s);
            }
            io_mod.say("beta {s}: $ {s}\n", .{ o.lang, try std.mem.join(a, " ", words) });
            const r = try io.run(a, o.work, argv.items);
            if (r.code != 0) {
                std.debug.print("beta {s}: `{s}` exited {d}\n{s}\n{s}\n", .{ o.lang, try std.mem.join(a, " ", words), r.code, io_mod.tail(r.stderr, 40), io_mod.tail(r.stdout, 20) });
                return error.StepFailed;
            }
        },
        .config => {
            const text = switch (o.exec) {
                .local => farm.local_config,
                .farm => |c| c,
            };
            const p = try std.fs.path.join(a, &.{ o.work, ".buckconfig.local" });
            try std.fs.cwd().writeFile(.{ .sub_path = p, .data = text });
            io_mod.say("beta {s}: wrote .buckconfig.local ({s})\n", .{ o.lang, if (o.exec == .local) "local mode" else "the farm" });
        },
        .build => |ts| {
            io_mod.say("beta {s}: build {s}\n", .{ o.lang, try std.mem.join(a, " ", ts) });
            _ = try build(a, io, o, ts);
            for (ts) |x| {
                var dup = false;
                for (targets.items) |y| {
                    if (std.mem.eql(u8, x, y)) dup = true;
                }
                if (!dup) try targets.append(a, x);
            }
        },
        .expect => |e| {
            const outs = try build(a, io, o, &.{e.target});
            const rel = outputOf(outs, e.target) orelse {
                std.debug.print("beta {s}: {s} has no output to run\n", .{ o.lang, e.target });
                return error.NoOutput;
            };
            const abs = try std.fs.path.join(a, &.{ o.work, rel });
            const r = try io.run(a, o.work, &.{abs});
            if (r.code != 0 or !std.mem.eql(u8, trimNl(r.stdout), e.text)) {
                std.debug.print("beta {s}: {s} exited {d} and printed `{s}`, expected `{s}`\n", .{ o.lang, e.target, r.code, trimNl(r.stdout), e.text });
                return error.WrongOutput;
            }
            io_mod.say("beta {s}: {s} printed `{s}`\n", .{ o.lang, e.target, e.text });
        },
        .expect_file => |e| {
            const outs = try build(a, io, o, &.{e.target});
            const rel = outputOf(outs, e.target) orelse {
                std.debug.print("beta {s}: {s} has no output\n", .{ o.lang, e.target });
                return error.NoOutput;
            };
            const p = try std.fs.path.join(a, &.{ o.work, rel, e.path });
            const bytes = std.fs.cwd().readFileAlloc(a, p, 1 << 20) catch |err| {
                std.debug.print("beta {s}: cannot read {s} of {s}: {s}\n", .{ o.lang, e.path, e.target, @errorName(err) });
                return error.WrongOutput;
            };
            if (!std.mem.eql(u8, trimNl(bytes), e.text)) {
                std.debug.print("beta {s}: {s}/{s} holds `{s}`, expected `{s}`\n", .{ o.lang, e.target, e.path, trimNl(bytes), e.text });
                return error.WrongOutput;
            }
            io_mod.say("beta {s}: {s} holds `{s}`\n", .{ o.lang, e.path, e.text });
        },
    };

    const first = try hashAll(a, o, try build(a, io, o, targets.items));
    var res = Result{ .outcome = .passed, .outputs = first };
    if (o.exec == .farm) {
        io_mod.say("beta {s}: determinism not checked on a farm: its cache would answer the second build\n", .{o.lang});
        _ = try io.run(a, o.work, &.{ o.buck2, "kill" });
        return res;
    }
    // From nothing: `buck2 clean` removes buck-out, so the toolchains are fetched and every action runs again.
    const clean = try io.run(a, o.work, &.{ o.buck2, "clean" });
    if (clean.code != 0) {
        std.debug.print("beta {s}: `buck2 clean` exited {d}: {s}\n", .{ o.lang, clean.code, io_mod.tail(clean.stderr, 20) });
        return error.StepFailed;
    }
    const second = try hashAll(a, o, try build(a, io, o, targets.items));
    var same = first.len == second.len;
    if (same) {
        for (first, second) |x, y| {
            if (!std.mem.eql(u8, x.target, y.target) or !std.mem.eql(u8, x.path, y.path) or !std.mem.eql(u8, &x.sha256, &y.sha256)) {
                std.debug.print("beta {s}: NOT DETERMINISTIC: {s} {s}\n  first build  sha256 {s}\n  after clean  sha256 {s}\n", .{ o.lang, x.target, x.path, x.sha256, y.sha256 });
                same = false;
            }
        }
    } else {
        std.debug.print("beta {s}: NOT DETERMINISTIC: the first build had {d} output(s) and the second {d}\n", .{ o.lang, first.len, second.len });
    }
    res.deterministic = same;
    _ = try io.run(a, o.work, &.{ o.buck2, "kill" });
    if (!same) return error.NotDeterministic;
    return res;
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;

/// A fake `Io`. The first rule whose needle occurs in `cwd argv...` and that has uses left answers, and writes its files (under the cwd) first.
const Fake = struct {
    a: std.mem.Allocator,
    rules: []Rule,
    calls: std.ArrayList([]const u8) = .empty,

    const File = struct { path: []const u8, bytes: []const u8 };
    const Rule = struct {
        needle: []const u8,
        out: io_mod.Out = .{ .code = 0, .stdout = "", .stderr = "" },
        files: []const File = &.{},
        /// How many times the rule answers; 0 = always.
        times: usize = 0,
        used: usize = 0,
    };

    fn runCmd(ctx: *anyopaque, a: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) anyerror!io_mod.Out {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const line = try std.mem.join(a, " ", argv);
        try self.calls.append(self.a, line);
        for (self.rules) |*r| {
            if (r.times != 0 and r.used >= r.times) continue;
            if (std.mem.indexOf(u8, line, r.needle) == null) continue;
            r.used += 1;
            var d = try std.fs.cwd().openDir(cwd, .{});
            defer d.close();
            for (r.files) |f| {
                if (std.fs.path.dirname(f.path)) |p| try d.makePath(p);
                try d.writeFile(.{ .sub_path = f.path, .data = f.bytes });
            }
            return r.out;
        }
        std.debug.print("unscripted command: {s}\n", .{line});
        return error.UnscriptedCommand;
    }

    fn io(self: *Fake) Io {
        return .{ .ctx = self, .run_fn = runCmd };
    }

    fn count(self: *const Fake, needle: []const u8) usize {
        var n: usize = 0;
        for (self.calls.items) |c| {
            if (std.mem.indexOf(u8, c, needle) != null) n += 1;
        }
        return n;
    }
};

fn okOut(stdout: []const u8, stderr: []const u8) io_mod.Out {
    return .{ .code = 0, .stdout = stdout, .stderr = stderr };
}

const farm_stderr = "Commands: 3 (cached: 1, remote: 2, local: 0)\nBUILD SUCCEEDED\n";
const local_stderr = "Commands: 3 (cached: 0, remote: 0, local: 3)\nBUILD SUCCEEDED\n";

const demo_steps =
    \\run buildrules init . --git {origin} --commit {commit}
    \\config
    \\build //app:bin
    \\expect //app:bin => Hello, world!
    \\
;

/// A candidate checkout with one language `demo` (and the files of its repository), and an empty place for the repository.
const Env = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    work: []u8,

    fn make(a: std.mem.Allocator, steps_text: []const u8) !Env {
        var tmp = t.tmpDir(.{});
        try tmp.dir.makePath("cand/beta/demo/app");
        try tmp.dir.makePath("cand/rules/mopm");
        try tmp.dir.writeFile(.{ .sub_path = "cand/beta/demo/STEPS", .data = steps_text });
        try tmp.dir.writeFile(.{ .sub_path = "cand/beta/demo/app/BUCK.beta", .data = "# the user's BUCK\n" });
        try tmp.dir.writeFile(.{ .sub_path = "cand/beta/demo/app/main.c", .data = "int main(void){return 0;}\n" });
        try tmp.dir.writeFile(.{ .sub_path = "cand/rules/mopm/pins.bzl", .data = "MOPM_VERSIONS = {}\n" });
        try tmp.dir.makePath("work");
        const base = try tmp.dir.realpathAlloc(a, ".");
        return .{ .tmp = tmp, .root = try std.fs.path.join(a, &.{ base, "cand" }), .work = try std.fs.path.join(a, &.{ base, "work" }) };
    }

    fn opts(self: Env, exec: Exec) Options {
        return .{ .lang = "demo", .root = self.root, .work = self.work, .origin = "https://example.invalid/r", .commit = "c" ** 40, .buck2 = "/bin/buck2", .buildrules = "/bin/buildrules", .exec = exec };
    }
};

const out_path = "buck-out/v2/art/root/app/bin";

test "a local beta: copies the user's files, runs the steps, builds, runs the output, and builds again after a clean to the same bytes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]Fake.Rule{
        .{ .needle = "/bin/buildrules init . --git https://example.invalid/r --commit " ++ "c" ** 40 },
        .{ .needle = "build --console simple -c buildrules_re.mode=local --show-output //app:bin", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr), .files = &.{.{ .path = out_path, .bytes = "ELF" }} },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = okOut("Hello, world!\n", "") },
        .{ .needle = "/bin/buck2 clean" },
        .{ .needle = "/bin/buck2 kill" },
    };
    var fake = Fake{ .a = a, .rules = &rules };
    const r = try run(a, fake.io(), env.opts(.local));
    try t.expectEqual(Outcome.passed, r.outcome);
    try t.expectEqual(@as(?bool, true), r.deterministic);
    try t.expectEqual(@as(usize, 1), r.outputs.len);
    try t.expectEqualStrings("root//app:bin", r.outputs[0].target);
    // the user's files, with BUCK.beta as BUCK and no STEPS
    try t.expectEqualStrings("# the user's BUCK\n", try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ env.work, "app/BUCK" }), 1 << 10));
    try t.expectError(error.FileNotFound, std.fs.cwd().access(try std.fs.path.join(a, &.{ env.work, "STEPS" }), .{}));
    try t.expectError(error.FileNotFound, std.fs.cwd().access(try std.fs.path.join(a, &.{ env.work, "app/BUCK.beta" }), .{}));
    // local mode is written for the repository and passed on every build
    const cfg = try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ env.work, ".buckconfig.local" }), 1 << 10);
    try t.expect(std.mem.indexOf(u8, cfg, "mode = local") != null);
    try t.expectEqual(fake.count("simple "), fake.count("-c buildrules_re.mode=local"));
    // built three times (the step's build, the expect's, the first hash) and once more after the clean
    try t.expectEqual(@as(usize, 4), fake.count("build --console simple"));
    try t.expectEqual(@as(usize, 1), fake.count("buck2 clean"));
}

test "a build that is not the same bytes after a clean is red, and names both digests" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    // the first three builds write one content, the build after the clean another
    var rules = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "buck2 clean", .out = okOut("", ""), .files = &.{.{ .path = out_path, .bytes = "SECOND" }} },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr), .files = &.{.{ .path = out_path, .bytes = "FIRST" }}, .times = 3 },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr) },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = okOut("Hello, world!\n", "") },
        .{ .needle = "buck2 kill" },
    };
    var fake = Fake{ .a = a, .rules = &rules };
    try t.expectError(error.NotDeterministic, run(a, fake.io(), env.opts(.local)));
}

test "a build that makes a different number of outputs after a clean is red" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "buck2 clean" },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr), .files = &.{.{ .path = out_path, .bytes = "A" }}, .times = 3 },
        .{ .needle = "build --console simple", .out = okOut("", local_stderr) },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = okOut("Hello, world!\n", "") },
        .{ .needle = "buck2 kill" },
    };
    var fake = Fake{ .a = a, .rules = &rules };
    try t.expectError(error.NotDeterministic, run(a, fake.io(), env.opts(.local)));
}

test "a farm beta: the farm's settings are the repository's, no mode is passed, and a build that ran on this machine is red" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    const cfg = "[buck2_re_client]\n  engine_address = grpc://example.invalid:1\n[buildrules_re]\n  linux_x86_64_properties = a=b\n";
    var rules = [_]Fake.Rule{
        .{ .needle = "init" },
        // the first build runs on the farm; the later ones find the target built and run nothing, which prints no summary
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", farm_stderr), .files = &.{.{ .path = out_path, .bytes = "ELF" }}, .times = 1 },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", "Network: up 0B  down 0B\nBUILD SUCCEEDED\n") },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = okOut("Hello, world!\n", "") },
        .{ .needle = "buck2 kill" },
    };
    var fake = Fake{ .a = a, .rules = &rules };
    const r = try run(a, fake.io(), env.opts(.{ .farm = cfg }));
    try t.expectEqual(@as(?bool, null), r.deterministic);
    try t.expectEqual(@as(usize, 0), fake.count("buildrules_re.mode"));
    try t.expectEqual(@as(usize, 0), fake.count("buck2 clean"));
    try t.expectEqualStrings(cfg, try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ env.work, ".buckconfig.local" }), 1 << 10));

    // the same on a run whose summary says local: 3
    var env2 = try Env.make(a, demo_steps);
    defer env2.tmp.cleanup();
    var rules2 = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr) },
    };
    var fake2 = Fake{ .a = a, .rules = &rules2 };
    try t.expectError(error.FarmRanLocally, run(a, fake2.io(), env2.opts(.{ .farm = cfg })));

    // and on one that printed no summary at all
    var env3 = try Env.make(a, demo_steps);
    defer env3.tmp.cleanup();
    var rules3 = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", "Cache hits: 100%\nBUILD SUCCEEDED\n") },
    };
    var fake3 = Fake{ .a = a, .rules = &rules3 };
    try t.expectError(error.NoSummary, run(a, fake3.io(), env3.opts(.{ .farm = cfg })));
}

test "a failed step, a wrong output, or a repository that is not fresh is red" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // buildrules init fails
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]Fake.Rule{.{ .needle = "init", .out = .{ .code = 1, .stdout = "", .stderr = "refused" } }};
    var fake = Fake{ .a = a, .rules = &rules };
    try t.expectError(error.StepFailed, run(a, fake.io(), env.opts(.local)));

    // the built program prints something else
    var env2 = try Env.make(a, demo_steps);
    defer env2.tmp.cleanup();
    var rules2 = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr), .files = &.{.{ .path = out_path, .bytes = "ELF" }} },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = okOut("Goodbye\n", "") },
    };
    var fake2 = Fake{ .a = a, .rules = &rules2 };
    try t.expectError(error.WrongOutput, run(a, fake2.io(), env2.opts(.local)));

    // the built program exits non-zero while printing the right text
    var env2b = try Env.make(a, demo_steps);
    defer env2b.tmp.cleanup();
    var rules2b = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr), .files = &.{.{ .path = out_path, .bytes = "ELF" }} },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = .{ .code = 3, .stdout = "Hello, world!\n", .stderr = "" } },
    };
    var fake2b = Fake{ .a = a, .rules = &rules2b };
    try t.expectError(error.WrongOutput, run(a, fake2b.io(), env2b.opts(.local)));

    // a build that fails
    var env3 = try Env.make(a, demo_steps);
    defer env3.tmp.cleanup();
    var rules3 = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = .{ .code = 1, .stdout = "", .stderr = "BUILD FAILED" } },
    };
    var fake3 = Fake{ .a = a, .rules = &rules3 };
    try t.expectError(error.StepFailed, run(a, fake3.io(), env3.opts(.local)));

    // a repository already there
    var env4 = try Env.make(a, demo_steps);
    defer env4.tmp.cleanup();
    try env4.tmp.dir.writeFile(.{ .sub_path = "work/.buckconfig", .data = "" });
    var rules4 = [_]Fake.Rule{};
    var fake4 = Fake{ .a = a, .rules = &rules4 };
    try t.expectError(error.WorkNotFresh, run(a, fake4.io(), env4.opts(.local)));
    try t.expectEqual(@as(usize, 0), fake4.calls.items.len);

    // a language with no STEPS
    var env5 = try Env.make(a, demo_steps);
    defer env5.tmp.cleanup();
    var o5 = env5.opts(.local);
    o5.lang = "nothing";
    try t.expectError(error.NoSuchLanguage, run(a, fake4.io(), o5));
}

test "a file in the output of a target is checked, and a missing one is red" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const steps_text = "config\nbuild //web:dist\nexpect-file //web:dist hello.txt => Hello, world!\n";
    var env = try Env.make(a, steps_text);
    defer env.tmp.cleanup();
    var rules = [_]Fake.Rule{
        .{ .needle = "build --console simple", .out = okOut("root//web:dist buck-out/dist\n", local_stderr), .files = &.{.{ .path = "buck-out/dist/hello.txt", .bytes = "Hello, world!\n" }} },
        .{ .needle = "buck2 clean" },
        .{ .needle = "buck2 kill" },
    };
    var fake = Fake{ .a = a, .rules = &rules };
    const r = try run(a, fake.io(), env.opts(.local));
    try t.expectEqual(@as(?bool, true), r.deterministic);
    // a directory output is hashed with the names inside it
    try t.expectEqual(@as(usize, 1), r.outputs.len);

    var env2 = try Env.make(a, steps_text);
    defer env2.tmp.cleanup();
    var rules2 = [_]Fake.Rule{
        .{ .needle = "build --console simple", .out = okOut("root//web:dist buck-out/dist\n", local_stderr), .files = &.{.{ .path = "buck-out/dist/other.txt", .bytes = "x" }} },
    };
    var fake2 = Fake{ .a = a, .rules = &rules2 };
    try t.expectError(error.WrongOutput, run(a, fake2.io(), env2.opts(.local)));

    var env3 = try Env.make(a, steps_text);
    defer env3.tmp.cleanup();
    var rules3 = [_]Fake.Rule{
        .{ .needle = "build --console simple", .out = okOut("root//web:dist buck-out/dist\n", local_stderr), .files = &.{.{ .path = "buck-out/dist/hello.txt", .bytes = "Hello, there\n" }} },
    };
    var fake3 = Fake{ .a = a, .rules = &rules3 };
    try t.expectError(error.WrongOutput, run(a, fake3.io(), env3.opts(.local)));
}

test "the hash of a directory covers the names and the bytes inside it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("d1/sub");
    try tmp.dir.makePath("d2/sub");
    try tmp.dir.makePath("d3/sub");
    try tmp.dir.makePath("d4/sub");
    try tmp.dir.writeFile(.{ .sub_path = "d1/a", .data = "1" });
    try tmp.dir.writeFile(.{ .sub_path = "d1/sub/b", .data = "2" });
    try tmp.dir.writeFile(.{ .sub_path = "d2/sub/b", .data = "2" });
    try tmp.dir.writeFile(.{ .sub_path = "d2/a", .data = "1" });
    try tmp.dir.writeFile(.{ .sub_path = "d3/a", .data = "1" });
    try tmp.dir.writeFile(.{ .sub_path = "d3/sub/b", .data = "3" });
    try tmp.dir.writeFile(.{ .sub_path = "d4/a2", .data = "1" });
    try tmp.dir.writeFile(.{ .sub_path = "d4/sub/b", .data = "2" });
    try tmp.dir.writeFile(.{ .sub_path = "f", .data = "abc" });
    const h1 = try hashOutput(a, tmp.dir, "d1");
    try t.expectEqualSlices(u8, &h1, &(try hashOutput(a, tmp.dir, "d2")));
    // other bytes, another name
    try t.expect(!std.mem.eql(u8, &h1, &(try hashOutput(a, tmp.dir, "d3"))));
    try t.expect(!std.mem.eql(u8, &h1, &(try hashOutput(a, tmp.dir, "d4"))));
    // a file is the sha256 of its bytes
    const want = std.fmt.bytesToHex(blk: {
        var d: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("abc", &d, .{});
        break :blk d;
    }, .lower);
    try t.expectEqualSlices(u8, &want, &(try hashOutput(a, tmp.dir, "f")));
}

test "a leg that waits for mopm's release is planned while the pin is a stand-in, and runs when it is not" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, "planned-until mopm-release\n" ++ demo_steps);
    defer env.tmp.cleanup();
    try env.tmp.dir.writeFile(.{ .sub_path = "cand/rules/mopm/pins.bzl", .data = "MOPM_VERSIONS = {\"0.0.1\": {\"release_pending\": True}}\n" });
    var rules = [_]Fake.Rule{};
    var fake = Fake{ .a = a, .rules = &rules };
    const r = try run(a, fake.io(), env.opts(.local));
    try t.expectEqual(Outcome.planned, r.outcome);
    try t.expect(std.mem.indexOf(u8, r.reason, "first release") != null);
    // nothing was copied or run
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
    try t.expectError(error.FileNotFound, std.fs.cwd().access(try std.fs.path.join(a, &.{ env.work, "app" }), .{}));

    // the pin has lost its marker: the leg runs
    try env.tmp.dir.writeFile(.{ .sub_path = "cand/rules/mopm/pins.bzl", .data = "MOPM_VERSIONS = {\"0.0.1\": {\"sha256\": \"x\"}}\n" });
    var rules2 = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr), .files = &.{.{ .path = out_path, .bytes = "ELF" }} },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = okOut("Hello, world!\n", "") },
        .{ .needle = "buck2 clean" },
        .{ .needle = "buck2 kill" },
    };
    var fake2 = Fake{ .a = a, .rules = &rules2 };
    const r2 = try run(a, fake2.io(), env.opts(.local));
    try t.expectEqual(Outcome.passed, r2.outcome);
}
