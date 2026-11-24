//! `stage farm-macos`: the targets labelled `macos-farm` (tools/bootstrap/macos.bzl), built on a farm whose macOS arm64 workers run the actions placed on a Mac
//! (.github/workflows/farm-macos.yml). The farm's machine buckconfig, which the farm-connect action wrote, becomes the checkout's `.buckconfig.local` with the
//! macOS worker set under the key buildrules reads (`macos_aarch64_properties`, rules/platforms.bzl); the labelled targets are found with a query, built, and the
//! build must say `local: 0`. A build whose every failure is a cut connection to the farm runs once more (`farm.onlyCuts`), as a beta leg's does.
const std = @import("std");
const farm = @import("farm.zig");
const io_mod = @import("io.zig");
const Io = io_mod.Io;

/// The label of the targets this builds, and the query that finds them. A query builds nothing: only the targets it names are built.
pub const label = "macos-farm";
pub const query = "attrfilter(labels, " ++ label ++ ", //...)";

/// The key the farm-connect action writes the macOS worker set under, and the one buildrules reads.
const connect_key = "darwin_arm64_properties";
const rules_key = "macos_aarch64_properties";

/// Said when the farm's machine buckconfig has no macOS worker set: the job cannot run a Mac's action.
pub const no_macos_message =
    \\farm-macos: the farm's machine buckconfig names no macOS worker set, so no action can run on a Mac. Set the repository variables
    \\FARM_DARWIN_ARM64_PROPERTIES and FARM_DARWIN_MACOS_HOSTS (RELEASING.md), which the farm-connect action is given.
    \\
;

/// `farm.buildrulesConfig` of the farm's machine buckconfig, with the macOS worker set under the key buildrules reads. Nothing else changes.
pub fn macosConfig(a: std.mem.Allocator, farm_text: []const u8) ![]u8 {
    const cfg = try farm.buildrulesConfig(a, farm_text);
    var out = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, cfg, '\n');
    var first = true;
    while (lines.next()) |raw| {
        if (!first) try out.append(a, '\n');
        first = false;
        const body = std.mem.trimLeft(u8, raw, " \t");
        const indent = raw[0 .. raw.len - body.len];
        if (std.mem.startsWith(u8, body, connect_key) and std.mem.startsWith(u8, std.mem.trimLeft(u8, body[connect_key.len..], " \t"), "=")) {
            try out.print(a, "{s}{s}{s}", .{ indent, rules_key, body[connect_key.len..] });
        } else {
            try out.appendSlice(a, raw);
        }
    }
    return out.toOwnedSlice(a);
}

/// Whether `cfg` names the farm, its linux worker set and a macOS worker set with a value.
pub fn macosConfigured(cfg: []const u8) bool {
    if (!farm.farmConfigured(cfg)) return false;
    var lines = std.mem.splitScalar(u8, cfg, '\n');
    while (lines.next()) |raw| {
        const body = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, body, rules_key)) continue;
        const rest = std.mem.trimLeft(u8, body[rules_key.len..], " \t");
        if (rest.len > 0 and rest[0] == '=' and std.mem.trim(u8, rest[1..], " \t").len > 0) return true;
    }
    return false;
}

pub const Options = struct {
    /// The checkout: where `.buckconfig.local` is written and buck2 runs.
    root: []const u8,
    buck2: []const u8,
    /// The `.buckconfig.local` to write (`macosConfig`).
    config: []const u8,
};

pub const Result = struct {
    targets: []const []const u8,
    summary: farm.Summary,
    /// 1 when the build ran a second time after a cut connection to the farm.
    cut_reruns: usize,
};

/// The target labels of a query's output: one per line, blank lines left out.
pub fn targetsOf(a: std.mem.Allocator, stdout: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len != 0) try out.append(a, l);
    }
    return out.toOwnedSlice(a);
}

/// Writes the config, finds the labelled targets, builds them on the farm, and stops buck2 at the end whatever happened.
pub fn run(a: std.mem.Allocator, io: Io, o: Options) !Result {
    if (!macosConfigured(o.config)) {
        std.debug.print("{s}", .{no_macos_message});
        return error.MacosNotConfigured;
    }
    var root = try std.fs.cwd().openDir(o.root, .{});
    defer root.close();
    // A checkout has no .buckconfig.local: one that is there is someone's, and replacing it would build with other settings than theirs.
    if (root.access(".buckconfig.local", .{})) |_| {
        std.debug.print("farm-macos: {s}/.buckconfig.local exists; this writes the farm's, and runs in a fresh checkout only\n", .{o.root});
        return error.ConfigExists;
    } else |_| {}
    try root.writeFile(.{ .sub_path = ".buckconfig.local", .data = o.config });
    io_mod.say("farm-macos: wrote .buckconfig.local (the farm, with its linux and macOS worker sets)\n", .{});
    defer {
        const k = io.run(a, o.root, &.{ o.buck2, "kill" }) catch null;
        if (k) |r| {
            if (r.code != 0) std.debug.print("farm-macos: buck2 kill exited {d}\n", .{r.code});
        }
    }

    const q = try io.run(a, o.root, &.{ o.buck2, "uquery", query });
    if (q.code != 0) {
        std.debug.print("farm-macos: the query `{s}` failed\n{s}\n", .{ query, io_mod.tail(q.stderr, 30) });
        return error.QueryFailed;
    }
    const targets = try targetsOf(a, q.stdout);
    if (targets.len == 0) {
        std.debug.print("farm-macos: no target is labelled `{s}`: there is nothing to run on a Mac, and an empty build would pass\n", .{label});
        return error.NoTargets;
    }
    for (targets) |x| io_mod.say("farm-macos: {s}\n", .{x});

    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{ o.buck2, "build", "--console", "simple" });
    try argv.appendSlice(a, targets);
    var cut_reruns: usize = 0;
    var r = try io.run(a, o.root, argv.items);
    if (r.code != 0 and farm.onlyCuts(r.stderr)) {
        io_mod.say("farm-macos: the connection to the farm was cut (every failure is buck2's `{s}`); running the same build once more\n{s}\n", .{ farm.cut_marker, io_mod.tail(r.stderr, 6) });
        cut_reruns = 1;
        r = try io.run(a, o.root, argv.items);
        if (r.code != 0 and farm.onlyCuts(r.stderr)) {
            std.debug.print("farm-macos: the connection to the farm was cut again when the build ran a second time (buck2: `{s}`), and a cut build is run only once more: re-run the job\n{s}\n", .{ farm.cut_marker, io_mod.tail(r.stderr, 12) });
            return error.FarmConnectionCut;
        }
    }
    if (r.code != 0) {
        std.debug.print("farm-macos: the build failed\n{s}\n", .{io_mod.tail(r.stderr, 60)});
        return error.BuildFailed;
    }
    const s = farm.parseSummary(r.stderr) orelse blk: {
        if (farm.idleBuild(r.stderr)) break :blk farm.Summary{ .total = 0, .cached = 0, .remote = 0, .local = 0 };
        std.debug.print("farm-macos: the build printed no `Commands:` summary, so it cannot be shown to have run on the farm\n{s}\n", .{io_mod.tail(r.stderr, 30)});
        return error.NoSummary;
    };
    if (s.local != 0) {
        std.debug.print("farm-macos: {d} action(s) ran on this machine; a farm run must say `local: 0`\n", .{s.local});
        return error.RanLocally;
    }
    return .{ .targets = targets, .summary = s, .cut_reruns = cut_reruns };
}

/// The line of the job's summary, and one line per target.
pub fn summary(a: std.mem.Allocator, res: Result) ![]u8 {
    var md = std.ArrayList(u8).empty;
    try md.print(a, "- farm-macos: {d} target(s) built on the farm; `Commands: {d} (cached: {d}, remote: {d}, local: {d})`", .{ res.targets.len, res.summary.total, res.summary.cached, res.summary.remote, res.summary.local });
    if (res.cut_reruns != 0) try md.appendSlice(a, "; the build ran again after a cut connection to the farm");
    try md.append(a, '\n');
    for (res.targets) |x| try md.print(a, "  - `{s}`\n", .{x});
    return md.toOwnedSlice(a);
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;
const beta = @import("beta.zig");

const k_re = "[" ++ "kom" ++ "ira_re]";
/// What the farm-connect action writes with the macOS inputs given.
const farm_with_mac = "[buck2_re_client]\n  engine_address = grpc://example.invalid:1\n" ++ k_re ++ "\n  linux_x86_64_properties = a=b\n  darwin_arm64_properties = os=macos\n  darwin_macos_hosts = h1 h2\n";
const farm_linux_only = "[buck2_re_client]\n  engine_address = grpc://example.invalid:1\n" ++ k_re ++ "\n  linux_x86_64_properties = a=b\n";

test "the macOS worker set is handed to buildrules under the key it reads, and nothing else changes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try macosConfig(a, farm_with_mac);
    try t.expectEqualStrings("[buck2_re_client]\n  engine_address = grpc://example.invalid:1\n[buildrules_re]\n  linux_x86_64_properties = a=b\n  macos_aarch64_properties = os=macos\n  darwin_macos_hosts = h1 h2\n", got);
    try t.expect(macosConfigured(got));
    // with no space before the `=`, and a key that only starts with the name, which is left as it is
    try t.expectEqualStrings("  macos_aarch64_properties=x\n  darwin_arm64_properties_extra = y", try macosConfig(a, "  darwin_arm64_properties=x\n  darwin_arm64_properties_extra = y"));
}

test "a config with no macOS worker set, an empty one, or no farm at all is not configured for a Mac" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(!macosConfigured(try macosConfig(a, farm_linux_only)));
    try t.expect(!macosConfigured(try macosConfig(a, farm_linux_only ++ "  darwin_arm64_properties = \n")));
    try t.expect(!macosConfigured(try macosConfig(a, farm_linux_only ++ "  darwin_arm64_properties\n")));
    try t.expect(!macosConfigured("[buildrules_re]\n  macos_aarch64_properties = os=macos\n"));
    try t.expect(!macosConfigured(""));
}

test "query output: one target per line, blank lines left out" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try targetsOf(a, "root//a:b\n\n  root//c:d \r\n");
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("root//a:b", got[0]);
    try t.expectEqualStrings("root//c:d", got[1]);
    try t.expectEqual(@as(usize, 0), (try targetsOf(a, "\n \n")).len);
}

/// A checkout with no .buckconfig.local, and the macOS config.
const Env = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    cfg: []u8,

    fn make(a: std.mem.Allocator) !Env {
        var tmp = t.tmpDir(.{});
        return .{ .root = try tmp.dir.realpathAlloc(a, "."), .cfg = try macosConfig(a, farm_with_mac), .tmp = tmp };
    }

    fn opts(self: Env) Options {
        return .{ .root = self.root, .buck2 = "/b/buck2", .config = self.cfg };
    }
};

const found = beta.okOut("root//tools/bootstrap:paths_macos\nroot//tools/bootstrap:darwin_integration\n", "");
const on_farm = beta.okOut("", "Commands: 24 (cached: 3, remote: 21, local: 0)\nBUILD SUCCEEDED\n");

test "farm-macos: writes the farm's config, builds every labelled target on the farm, says local: 0, and stops buck2" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a);
    defer env.tmp.cleanup();
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "uquery " ++ query, .out = found },
        .{ .needle = "build --console simple root//tools/bootstrap:paths_macos root//tools/bootstrap:darwin_integration", .out = on_farm },
        .{ .needle = "/b/buck2 kill" },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    const res = try run(a, fake.io(), env.opts());
    try t.expectEqual(@as(usize, 2), res.targets.len);
    try t.expectEqual(farm.Summary{ .total = 24, .cached = 3, .remote = 21, .local = 0 }, res.summary);
    try t.expectEqual(@as(usize, 0), res.cut_reruns);
    try t.expectEqualStrings(env.cfg, try env.tmp.dir.readFileAlloc(a, ".buckconfig.local", 1 << 12));
    // every command ran in the checkout, and buck2 was stopped last
    for (fake.cwds.items) |c| try t.expectEqualStrings(env.root, c);
    try t.expectEqual(@as(usize, 3), fake.calls.items.len);
    try t.expectEqualStrings("/b/buck2 kill", fake.calls.items[2]);
    try t.expectEqualStrings(
        "- farm-macos: 2 target(s) built on the farm; `Commands: 24 (cached: 3, remote: 21, local: 0)`\n  - `root//tools/bootstrap:paths_macos`\n  - `root//tools/bootstrap:darwin_integration`\n",
        try summary(a, res),
    );
}

test "farm-macos: a target built a moment ago (no command ran, no summary) passes; a build with no summary otherwise is red" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a);
    defer env.tmp.cleanup();
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "uquery", .out = found },
        .{ .needle = " build ", .out = beta.okOut("", "Network: up 0B  down 0B\nBUILD SUCCEEDED\n") },
        .{ .needle = " kill" },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    try t.expectEqual(@as(u64, 0), (try run(a, fake.io(), env.opts())).summary.total);

    var env2 = try Env.make(a);
    defer env2.tmp.cleanup();
    var rules2 = [_]beta.Fake.Rule{
        .{ .needle = "uquery", .out = found },
        .{ .needle = " build ", .out = beta.okOut("", "Cache hits: 100%\nBUILD SUCCEEDED\n") },
        .{ .needle = " kill" },
    };
    var fake2 = beta.Fake{ .a = a, .rules = &rules2 };
    try t.expectError(error.NoSummary, run(a, fake2.io(), env2.opts()));
    try t.expectEqual(@as(usize, 1), fake2.count(" kill"));
}

test "farm-macos: an action that ran on the runner is red, and buck2 is still stopped" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a);
    defer env.tmp.cleanup();
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "uquery", .out = found },
        .{ .needle = " build ", .out = beta.okOut("", "Commands: 24 (cached: 3, remote: 20, local: 1)\nBUILD SUCCEEDED\n") },
        .{ .needle = " kill", .out = beta.failOut("no daemon") },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    try t.expectError(error.RanLocally, run(a, fake.io(), env.opts()));
    try t.expectEqual(@as(usize, 1), fake.count(" kill"));
}

test "farm-macos: a failing test on the Mac is red at once and not built again" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a);
    defer env.tmp.cleanup();
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "uquery", .out = found },
        .{ .needle = " build ", .out = beta.failOut("Action failed: root//tools/bootstrap:paths_macos (host_run)\nRemote command returned non-zero exit code 1\nBUILD FAILED\n") },
        .{ .needle = " kill" },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    try t.expectError(error.BuildFailed, run(a, fake.io(), env.opts()));
    try t.expectEqual(@as(usize, 1), fake.count(" build "));
}

test "farm-macos: a build cut once runs again and passes; cut twice it is red and not run a third time; cut then a failure is that failure" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cut = beta.failOut(farm.sample_cut);

    var env = try Env.make(a);
    defer env.tmp.cleanup();
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "uquery", .out = found },
        .{ .needle = " build ", .out = cut, .times = 1 },
        .{ .needle = " build ", .out = on_farm },
        .{ .needle = " kill" },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    const res = try run(a, fake.io(), env.opts());
    try t.expectEqual(@as(usize, 1), res.cut_reruns);
    try t.expectEqual(@as(usize, 2), fake.count(" build "));
    try t.expect(std.mem.indexOf(u8, try summary(a, res), "ran again after a cut connection") != null);

    var env2 = try Env.make(a);
    defer env2.tmp.cleanup();
    var rules2 = [_]beta.Fake.Rule{
        .{ .needle = "uquery", .out = found },
        .{ .needle = " build ", .out = cut },
        .{ .needle = " kill" },
    };
    var fake2 = beta.Fake{ .a = a, .rules = &rules2 };
    try t.expectError(error.FarmConnectionCut, run(a, fake2.io(), env2.opts()));
    try t.expectEqual(@as(usize, 2), fake2.count(" build "));

    var env3 = try Env.make(a);
    defer env3.tmp.cleanup();
    var rules3 = [_]beta.Fake.Rule{
        .{ .needle = "uquery", .out = found },
        .{ .needle = " build ", .out = cut, .times = 1 },
        .{ .needle = " build ", .out = beta.failOut(farm.sample_compile_error) },
        .{ .needle = " kill" },
    };
    var fake3 = beta.Fake{ .a = a, .rules = &rules3 };
    try t.expectError(error.BuildFailed, run(a, fake3.io(), env3.opts()));
    try t.expectEqual(@as(usize, 2), fake3.count(" build "));
}

test "farm-macos: no labelled target, or a query that fails, is red before anything is built" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a);
    defer env.tmp.cleanup();
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "uquery", .out = beta.okOut("\n", "") },
        .{ .needle = " kill" },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    try t.expectError(error.NoTargets, run(a, fake.io(), env.opts()));
    try t.expectEqual(@as(usize, 0), fake.count(" build "));
    try t.expectEqual(@as(usize, 1), fake.count(" kill"));

    var env2 = try Env.make(a);
    defer env2.tmp.cleanup();
    var rules2 = [_]beta.Fake.Rule{
        .{ .needle = "uquery", .out = beta.failOut("Error evaluating build file") },
        .{ .needle = " kill" },
    };
    var fake2 = beta.Fake{ .a = a, .rules = &rules2 };
    try t.expectError(error.QueryFailed, run(a, fake2.io(), env2.opts()));
    try t.expectEqual(@as(usize, 0), fake2.count(" build "));
}

test "farm-macos: no macOS worker set, or a .buckconfig.local already there, is red before anything runs and writes nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a);
    defer env.tmp.cleanup();
    var rules = [_]beta.Fake.Rule{};
    var fake = beta.Fake{ .a = a, .rules = &rules };
    var o = env.opts();
    o.config = try macosConfig(a, farm_linux_only);
    try t.expectError(error.MacosNotConfigured, run(a, fake.io(), o));
    try t.expectError(error.FileNotFound, env.tmp.dir.access(".buckconfig.local", .{}));

    try env.tmp.dir.writeFile(.{ .sub_path = ".buckconfig.local", .data = "mine\n" });
    try t.expectError(error.ConfigExists, run(a, fake.io(), env.opts()));
    try t.expectEqualStrings("mine\n", try env.tmp.dir.readFileAlloc(a, ".buckconfig.local", 1 << 10));
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
}

test "farm-macos: a buck2 kill that cannot start is not the build's failure" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a);
    defer env.tmp.cleanup();
    // no rule answers `kill`: the fake returns an error for it, as a program that cannot be started does
    var rules = [_]beta.Fake.Rule{
        .{ .needle = "uquery", .out = found },
        .{ .needle = " build ", .out = on_farm },
    };
    var fake = beta.Fake{ .a = a, .rules = &rules };
    _ = try run(a, fake.io(), env.opts());
    try t.expectEqual(@as(usize, 1), fake.count(" kill"));
}
