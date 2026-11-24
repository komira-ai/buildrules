//! The tests of every file of the stage tool.
test {
    _ = @import("steps.zig");
    _ = @import("farm.zig");
    _ = @import("io.zig");
    _ = @import("bounded.zig");
    _ = @import("beta.zig");
    _ = @import("gamma.zig");
    _ = @import("native.zig");
    _ = @import("macos_farm.zig");
    _ = @import("stage.zig");
}

// ---- a cut connection to the farm -------------------------------------------------------------------------------------------------------
//
// A farm build whose every failure is buck2's `Error:` line with `RE channel error: code:` (farm.onlyCuts) runs once more; these drive the beta
// leg through `stage beta` and its summary, and gamma, with the stand-in buck2 of each (beta.Fake, gamma.GFake).

const std = @import("std");
const t = std.testing;
const beta = @import("beta.zig");
const gamma = @import("gamma.zig");
const farm = @import("farm.zig");
const stage = @import("stage.zig");
const io_mod = @import("io.zig");

const farm_cfg = "[buck2_re_client]\n  engine_address = grpc://example.invalid:1\n[buildrules_re]\n  linux_x86_64_properties = a=b\n";
const built = beta.okOut("root//app:bin " ++ beta.out_path ++ "\n", beta.farm_stderr);
const built_files = &[_]beta.Fake.File{.{ .path = beta.out_path, .bytes = "ELF" }};
const cut = beta.failOut(farm.sample_cut);
const compile_error = beta.failOut(farm.sample_compile_error);
const flake = beta.failOut("Error materializing HTTP resource declared by target toolchains//:zig_pin\n\nCaused by:\n    Timed out while making request\nBUILD FAILED\n");

/// `stage beta --exec farm` of the leg in `env`, with the farm's config and the summary written in `env`'s directory. Returns the summary.
fn betaFarm(a: std.mem.Allocator, env: beta.Env, fake: *beta.Fake, err: ?anyerror) ![]const u8 {
    const base = std.fs.path.dirname(env.work).?;
    const cfg_path = try std.fs.path.join(a, &.{ base, "farm.buckconfig" });
    const summary = try std.fs.path.join(a, &.{ base, "summary.md" });
    try std.fs.cwd().writeFile(.{ .sub_path = cfg_path, .data = farm_cfg });
    try std.fs.cwd().writeFile(.{ .sub_path = summary, .data = "" });
    const o = env.opts(.local);
    const argv = [_][]const u8{
        "--root",  o.root,  "--lang",       o.lang,       "--work", o.work, "--origin",      o.origin, "--commit",  o.commit,
        "--buck2", o.buck2, "--buildrules", o.buildrules, "--exec", "farm", "--farm-config", cfg_path, "--summary", summary,
    };
    const g = try stage.parseArgs(a, &argv, &stage.beta_flags);
    if (err) |e| {
        try t.expectError(e, stage.betaCommand(a, fake.io(), g));
    } else {
        try t.expectEqual(@as(u8, 0), try stage.betaCommand(a, fake.io(), g));
    }
    return std.fs.cwd().readFileAlloc(a, summary, 1 << 16);
}

/// The `buck2 build` calls the fake saw, in order.
fn builds(a: std.mem.Allocator, fake: *const beta.Fake) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (fake.calls.items) |c| {
        if (std.mem.indexOf(u8, c, "build --console simple") != null) try out.append(a, c);
    }
    return out.items;
}

test "beta farm: a build cut once runs again at once with the same argv and passes, and the summary says so" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try beta.Env.make(a, beta.demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = cut, .times = 1 },
        .{ .needle = "build --console simple", .out = built, .files = built_files },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = beta.okOut("Hello, world!\n", "") },
        .{ .needle = "buck2 kill" },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    const md = try betaFarm(a, env, &fake, null);
    try t.expectEqualStrings("- beta `demo`: passed, 1 output(s); determinism not checked on a farm; 1 command(s) ran again after a cut connection to the farm\n", md[0 .. std.mem.indexOfScalar(u8, md, '\n').? + 1]);
    const b = try builds(a, &fake);
    // the step's build twice (cut, then passed), the expect's and the final one once each
    try t.expectEqual(@as(usize, 4), b.len);
    try t.expectEqualStrings(b[0], b[1]);
    // no wait: the rerun is not a download retry
    try t.expectEqual(@as(usize, 0), fake.waited().len);
}

test "beta farm: a build cut on both runs is red, names the cut in the summary, and is never run a third time" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try beta.Env.make(a, beta.demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = cut },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    const md = try betaFarm(a, env, &fake, error.FarmConnectionCut);
    try t.expectEqualStrings("- beta `demo`: **failed**: the connection to the farm was cut, and cut again when the command ran a second time (buck2: `RE channel error: code:`)\n", md);
    try t.expectEqual(@as(usize, 2), (try builds(a, &fake)).len);
}

test "beta farm: a compile error, and a log that mixes a compile error with cuts, are red at once and not run again" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]io_mod.Out{ compile_error, beta.failOut(farm.sample_cut ++ farm.sample_compile_error) }) |out| {
        var env = try beta.Env.make(a, beta.demo_steps);
        defer env.tmp.cleanup();
        var rules = [_]beta.Fake.Rule{
            .{ .needle = "init" },
            .{ .needle = "build --console simple", .out = out, .times = 1 },
            // a second run would pass: the test sees that it is not made
            .{ .needle = "build --console simple", .out = built, .files = built_files },
        };
        var fake = beta.Fake{ .a = a, .rules = &rules };
        // a failure that is not a cut writes no summary line (as before)
        try t.expectEqualStrings("", try betaFarm(a, env, &fake, error.StepFailed));
        try t.expectEqual(@as(usize, 1), (try builds(a, &fake)).len);
    }
}

test "beta farm: a cut and then a compile error on the rerun is a compile error, not a cut" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try beta.Env.make(a, beta.demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = cut, .times = 1 },
        .{ .needle = "build --console simple", .out = compile_error },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    try t.expectEqualStrings("", try betaFarm(a, env, &fake, error.StepFailed));
    try t.expectEqual(@as(usize, 2), (try builds(a, &fake)).len);
}

test "a local leg never reruns a build on a cut: there is no farm to cut" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try beta.Env.make(a, beta.demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = cut },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    try t.expectError(error.StepFailed, beta.run(a, fake.io(), env.opts(.local)));
    try t.expectEqual(@as(usize, 1), (try builds(a, &fake)).len);
}

test "beta farm: the cut rerun is apart from the download retries, takes the argv of the run that was cut, and is made once per command" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // two download failures (the second retry takes the mirrors), then a cut: the rerun keeps the mirrors, and the download budget is untouched
    {
        var env = try beta.Env.make(a, beta.demo_steps);
        defer env.tmp.cleanup();
        var rules = [_]beta.Fake.Rule{
            .{ .needle = "init" },
            .{ .needle = "build --console simple", .out = flake, .times = 2 },
            .{ .needle = "build --console simple", .out = cut, .times = 1 },
            .{ .needle = "build --console simple", .out = built, .files = built_files },
            .{ .needle = "/buck-out/v2/art/root/app/bin", .out = beta.okOut("Hello, world!\n", "") },
            .{ .needle = "buck2 kill" },
        };
        var fake = beta.Fake{ .a = a, .rules = &rules };
        const r = try beta.run(a, fake.io(), env.opts(.{ .farm = farm_cfg }));
        try t.expectEqual(@as(usize, 1), r.cut_reruns);
        const b = try builds(a, &fake);
        try t.expect(std.mem.indexOf(u8, b[2], "buildrules.url_map=") != null);
        try t.expectEqualStrings(b[2], b[3]);
        try t.expectEqualSlices(u64, &.{ 20_000, 40_000 }, fake.waited());
    }
    // a cut, a download failure, a cut: the second cut is final, even with a download retry between
    {
        var env = try beta.Env.make(a, beta.demo_steps);
        defer env.tmp.cleanup();
        var rules = [_]beta.Fake.Rule{
            .{ .needle = "init" },
            .{ .needle = "build --console simple", .out = cut, .times = 1 },
            .{ .needle = "build --console simple", .out = flake, .times = 1 },
            .{ .needle = "build --console simple", .out = cut, .times = 1 },
            .{ .needle = "build --console simple", .out = built, .files = built_files },
        };
        var fake = beta.Fake{ .a = a, .rules = &rules };
        try t.expectError(error.FarmConnectionCut, beta.run(a, fake.io(), env.opts(.{ .farm = farm_cfg })));
        try t.expectEqual(@as(usize, 3), (try builds(a, &fake)).len);
    }
    // two different builds each cut once: each runs once more, and the leg passes
    {
        var env = try beta.Env.make(a, beta.demo_steps);
        defer env.tmp.cleanup();
        var rules = [_]beta.Fake.Rule{
            .{ .needle = "init" },
            .{ .needle = "build --console simple", .out = cut, .times = 1 },
            .{ .needle = "build --console simple", .out = built, .files = built_files, .times = 1 },
            .{ .needle = "build --console simple", .out = cut, .times = 1 },
            .{ .needle = "build --console simple", .out = built, .files = built_files },
            .{ .needle = "/buck-out/v2/art/root/app/bin", .out = beta.okOut("Hello, world!\n", "") },
            .{ .needle = "buck2 kill" },
        };
        var fake = beta.Fake{ .a = a, .rules = &rules };
        const r = try beta.run(a, fake.io(), env.opts(.{ .farm = farm_cfg }));
        try t.expectEqual(@as(usize, 2), r.cut_reruns);
        try t.expectEqual(@as(usize, 5), (try builds(a, &fake)).len);
    }
}

test "beta farm: a sync step whose buck2 is cut runs once more, the same command" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try beta.Env.make(a, "run buildrules init . --git {origin} --commit {commit}\nconfig\nrun buildrules sync\nbuild //app:bin\nexpect //app:bin => Hello, world!\n");
    defer env.tmp.cleanup();
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "/bin/buildrules sync", .out = cut, .times = 1 },
        .{ .needle = "/bin/buildrules sync" },
        .{ .needle = "build --console simple", .out = built, .files = built_files },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = beta.okOut("Hello, world!\n", "") },
        .{ .needle = "buck2 kill" },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    const r = try beta.run(a, fake.io(), env.opts(.{ .farm = farm_cfg }));
    try t.expectEqual(@as(usize, 1), r.cut_reruns);
    try t.expectEqual(@as(usize, 2), fake.count("/bin/buildrules sync"));
}

test "stage beta: a local leg's summary line is as before, and a mode that is neither local nor farm runs nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try beta.Env.make(a, beta.demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = beta.okOut("root//app:bin " ++ beta.out_path ++ "\n", "Commands: 3 (cached: 0, remote: 0, local: 3)\n"), .files = built_files },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = beta.okOut("Hello, world!\n", "") },
        .{ .needle = "buck2 kill" },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    const summary = try std.fs.path.join(a, &.{ std.fs.path.dirname(env.work).?, "summary.md" });
    try std.fs.cwd().writeFile(.{ .sub_path = summary, .data = "" });
    const o = env.opts(.local);
    var argv = [_][]const u8{
        "--root",  o.root,  "--lang",       o.lang,       "--work", o.work,  "--origin",  o.origin, "--commit", o.commit,
        "--buck2", o.buck2, "--buildrules", o.buildrules, "--exec", "local", "--summary", summary,
    };
    try t.expectEqual(@as(u8, 0), try stage.betaCommand(a, fake.io(), try stage.parseArgs(a, &argv, &stage.beta_flags)));
    const md = try std.fs.cwd().readFileAlloc(a, summary, 1 << 16);
    try t.expectEqualStrings("- beta `demo`: passed, 1 output(s); identical bytes after a clean rebuild\n", md[0 .. std.mem.indexOfScalar(u8, md, '\n').? + 1]);

    argv[15] = "remote";
    var none = [_]beta.Fake.Rule{};
    var idle = beta.Fake{ .a = a, .rules = &none };
    try t.expectError(error.Usage, stage.betaCommand(a, idle.io(), try stage.parseArgs(a, &argv, &stage.beta_flags)));
    try t.expectEqual(@as(usize, 0), idle.calls.items.len);
}

fn gammaWork(a: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    return tmp.dir.realpathAlloc(a, ".");
}

const g_built = io_mod.Out{ .code = 0, .stdout = "", .stderr = "Commands: 9 (cached: 4, remote: 5, local: 0)\nBUILD SUCCEEDED\n" };

test "gamma: a build cut once is built again and passes; each repository's build has its own rerun" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const work = try gammaWork(a, &tmp);
    var fake = gamma.GFake{ .a = a, .build_out = g_built, .build_first = &.{ cut, g_built, cut } };
    try gamma.run(a, fake.io(), gamma.gammaOpts(work, "org/first org/second"));
    try t.expectEqual(@as(usize, 4), fake.count("buck2 build"));
    try t.expectEqual(@as(usize, 2), fake.count("1-first :: /bin/buck2 build --console simple //..."));
    try t.expectEqual(@as(usize, 2), fake.count("2-second :: /bin/buck2 build --console simple //..."));
    try t.expectEqual(@as(usize, 2), fake.count("buck2 kill"));
}

test "gamma: a build cut on both runs is red naming the cut, is not built a third time, and the next repository is not tried" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const work = try gammaWork(a, &tmp);
    var fake = gamma.GFake{ .a = a, .build_out = cut };
    try t.expectError(error.FarmConnectionCut, gamma.run(a, fake.io(), gamma.gammaOpts(work, "org/first org/second")));
    try t.expectEqual(@as(usize, 2), fake.count("buck2 build"));
    try t.expectEqual(@as(usize, 1), fake.count("git clone"));
}

test "gamma: a compile error, a mixed log, and a compile error after a cut are red as a failed build, with no further run" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const work = try gammaWork(a, &tmp);
    var compile = gamma.GFake{ .a = a, .build_out = g_built, .build_first = &.{compile_error} };
    try t.expectError(error.StepFailed, gamma.run(a, compile.io(), gamma.gammaOpts(work, "org/first")));
    try t.expectEqual(@as(usize, 1), compile.count("buck2 build"));

    var tmp2 = t.tmpDir(.{});
    defer tmp2.cleanup();
    var mixed = gamma.GFake{ .a = a, .build_out = g_built, .build_first = &.{beta.failOut(farm.sample_compile_error ++ farm.sample_cut)} };
    try t.expectError(error.StepFailed, gamma.run(a, mixed.io(), gamma.gammaOpts(try gammaWork(a, &tmp2), "org/first")));
    try t.expectEqual(@as(usize, 1), mixed.count("buck2 build"));

    var tmp3 = t.tmpDir(.{});
    defer tmp3.cleanup();
    var then_compile = gamma.GFake{ .a = a, .build_out = g_built, .build_first = &.{ cut, compile_error } };
    try t.expectError(error.StepFailed, gamma.run(a, then_compile.io(), gamma.gammaOpts(try gammaWork(a, &tmp3), "org/first")));
    try t.expectEqual(@as(usize, 2), then_compile.count("buck2 build"));
}

/// `stage gamma` of `org/first org/second` with the farm's config, parsed from its command line, against `fake`.
fn gammaCli(a: std.mem.Allocator, base: []const u8, fake: *gamma.GFake) !u8 {
    const cfg_path = try std.fs.path.join(a, &.{ base, "farm.buckconfig" });
    try std.fs.cwd().writeFile(.{ .sub_path = cfg_path, .data = farm_cfg });
    const argv = [_][]const u8{
        "--work",  try std.fs.path.join(a, &.{ base, "gamma" }), "--candidate",   "d" ** 40, "--repos", "org/first org/second",
        "--buck2", "/bin/buck2",                                 "--farm-config", cfg_path,
    };
    return stage.gammaCommand(a, fake.io(), try stage.parseArgs(a, &argv, &stage.gamma_flags));
}

test "stage gamma: from its command line, a build cut once passes after one rerun, and a build cut twice is red with the cut named" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var once = gamma.GFake{ .a = a, .build_out = g_built, .build_first = &.{cut} };
    try t.expectEqual(@as(u8, 0), try gammaCli(a, try gammaWork(a, &tmp), &once));
    // the first repository twice (cut, then built), the second once
    try t.expectEqual(@as(usize, 3), once.count("buck2 build"));
    try t.expectEqual(@as(usize, 2), once.count("1-first :: /bin/buck2 build --console simple //..."));

    var tmp2 = t.tmpDir(.{});
    defer tmp2.cleanup();
    var twice = gamma.GFake{ .a = a, .build_out = g_built, .build_first = &.{ cut, cut } };
    try t.expectError(error.FarmConnectionCut, gammaCli(a, try gammaWork(a, &tmp2), &twice));
    try t.expectEqual(@as(usize, 2), twice.count("buck2 build"));
    try t.expectEqual(@as(usize, 1), twice.count("git clone"));
}

// ---- a command stopped at its limit -----------------------------------------------------------------------------------------------------
//
// The real runner stops a command still running at `stage.command_limit` (bounded.zig) and says so in its `Out`; these hold what the stages do
// with that: the leg or the repository fails with CommandHung at once, and the command is never run again, even when what it wrote before the
// stop reads as a cut connection to the farm.

/// What the runner returns for a build it stopped: the cut lines it had written, so a stage that read it as a result would run it again.
const stopped = io_mod.Out{ .code = 255, .stdout = "", .stderr = farm.sample_cut, .stopped_ms = stage.command_limit.limit_ms };

test "beta farm: a build stopped at the limit is red at once, is not run again, and the summary says it was stopped" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try beta.Env.make(a, beta.demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = stopped, .times = 1 },
        // a second run would pass: the test sees that it is not made
        .{ .needle = "build --console simple", .out = built, .files = built_files },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    const md = try betaFarm(a, env, &fake, error.CommandHung);
    try t.expectEqualStrings("- beta `demo`: **failed**: a command was still running after 30 min and was stopped; the log names it and shows the last lines it wrote\n", md);
    try t.expectEqual(@as(usize, 1), (try builds(a, &fake)).len);
    try t.expectEqual(@as(usize, 0), fake.waited().len);
}

test "beta farm: the rerun after a cut, stopped at the limit, is red with the stop and not run a third time" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try beta.Env.make(a, beta.demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = cut, .times = 1 },
        .{ .needle = "build --console simple", .out = stopped, .times = 1 },
        .{ .needle = "build --console simple", .out = built, .files = built_files },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    const md = try betaFarm(a, env, &fake, error.CommandHung);
    try t.expectEqualStrings("- beta `demo`: **failed**: a command was still running after 30 min and was stopped; the log names it and shows the last lines it wrote\n", md);
    try t.expectEqual(@as(usize, 2), (try builds(a, &fake)).len);
}

test "beta: a step command stopped at the limit fails the leg before any build, on a farm and off it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]beta.Exec{ .local, .{ .farm = farm_cfg } }) |exec| {
        var env = try beta.Env.make(a, beta.demo_steps);
        defer env.tmp.cleanup();
        var rules = [_]beta.Fake.Rule{
            .{ .needle = "init", .out = .{ .code = 255, .stdout = "", .stderr = "", .stopped_ms = stage.command_limit.limit_ms } },
            .{ .needle = "init" },
        };
        var fake = beta.Fake{ .a = a, .rules = &rules };
        try t.expectError(error.CommandHung, beta.run(a, fake.io(), env.opts(exec)));
        try t.expectEqual(@as(usize, 1), fake.count("init"));
        try t.expectEqual(@as(usize, 0), (try builds(a, &fake)).len);
    }
}

test "gamma: a build stopped at the limit is red at once, is not built again, and the next repository is not tried" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var fake = gamma.GFake{ .a = a, .build_out = g_built, .build_first = &.{stopped} };
    try t.expectError(error.CommandHung, gammaCli(a, try gammaWork(a, &tmp), &fake));
    try t.expectEqual(@as(usize, 1), fake.count("buck2 build"));
    try t.expectEqual(@as(usize, 1), fake.count("git clone"));
}

// ---- stage farm-macos ---------------------------------------------------------------------------------------------------------------------

test "stage farm-macos: the farm's config with its macOS set is written, the labelled targets built, and the summary line appended" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("root");
    try tmp.dir.writeFile(.{ .sub_path = "farm.buckconfig", .data = "[buck2_re_client]\n  engine_address = grpc://example.invalid:1\n[" ++ "kom" ++ "ira_re]\n  linux_x86_64_properties = a=b\n  darwin_arm64_properties = os=macos\n  darwin_macos_hosts = h1\n" });
    try tmp.dir.writeFile(.{ .sub_path = "summary", .data = "" });
    const base = try tmp.dir.realpathAlloc(a, ".");
    const p = struct {
        fn at(al: std.mem.Allocator, b: []const u8, n: []const u8) ![]const u8 {
            return std.fs.path.join(al, &.{ b, n });
        }
    };
    const args = [_][]const u8{ "--root", try p.at(a, base, "root"), "--buck2", "/b/buck2", "--farm-config", try p.at(a, base, "farm.buckconfig"), "--summary", try p.at(a, base, "summary") };
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "uquery", .out = beta.okOut("root//tools/bootstrap:paths_macos\n", "") },
        .{ .needle = " build ", .out = beta.okOut("", "Commands: 5 (cached: 0, remote: 5, local: 0)\nBUILD SUCCEEDED\n") },
        .{ .needle = " kill" },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    try t.expectEqual(@as(u8, 0), try stage.farmMacosCommand(a, fake.io(), try stage.parseArgs(a, &args, &stage.farm_macos_flags)));
    try t.expectEqualStrings(
        "- farm-macos: 1 target(s) built on the farm; `Commands: 5 (cached: 0, remote: 5, local: 0)`\n  - `root//tools/bootstrap:paths_macos`\n",
        try tmp.dir.readFileAlloc(a, "summary", 1 << 12),
    );
    try t.expect(std.mem.indexOf(u8, try tmp.dir.readFileAlloc(a, "root/.buckconfig.local", 1 << 12), "  macos_aarch64_properties = os=macos\n") != null);
}

test "stage farm-macos: no farm config, one that names no farm, or a missing flag is red before anything runs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "empty.buckconfig", .data = "[buildrules_re]\n  darwin_arm64_properties = os=macos\n" });
    const base = try tmp.dir.realpathAlloc(a, ".");
    const none = try std.fs.path.join(a, &.{ base, "missing.buckconfig" });
    const empty = try std.fs.path.join(a, &.{ base, "empty.buckconfig" });
    try t.expectError(error.FarmNotConfigured, stage_run(a, &.{ "--root", base, "--buck2", "/b/buck2", "--farm-config", none }));
    try t.expectError(error.FarmNotConfigured, stage_run(a, &.{ "--root", base, "--buck2", "/b/buck2", "--farm-config", empty }));
    try t.expectError(error.Usage, stage_run(a, &.{ "--root", base, "--buck2", "/b/buck2" }));
    try t.expectError(error.Usage, stage_run(a, &.{ "--root", base, "--farm-config", empty }));
    try t.expectError(error.Usage, stage_run(a, &.{ "--root", base, "--exec", "farm" }));
    // nothing was written in the checkout
    try t.expectError(error.FileNotFound, tmp.dir.access(".buckconfig.local", .{}));
}

/// `stage farm-macos` through the parser, with an Io that runs nothing: each case is red before a command.
fn stage_run(a: std.mem.Allocator, argv: []const []const u8) !u8 {
    var rules = [_]beta.Fake.Rule{};
    var fake = beta.Fake{ .a = a, .rules = &rules };
    return stage.farmMacosCommand(a, fake.io(), try stage.parseArgs(a, argv, &stage.farm_macos_flags));
}
