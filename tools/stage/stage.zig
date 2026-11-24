//! `stage`: the beta and gamma stages of the automatic release (RELEASING.md). The logic is in beta.zig and gamma.zig, each tested against a fake
//! `Io`; this file reads the command line and runs the real programs.
//!
//!   stage plan   --root DIR [--output FILE]
//!   stage beta   --root DIR --lang L --work DIR --origin URL --commit SHA --buck2 PATH --buildrules PATH
//!                (--exec local | --exec farm --farm-config FILE) [--summary FILE]
//!   stage native --root DIR --lang L --work DIR --origin URL --commit SHA --buck2 PATH --buildrules PATH --host H --version V [--summary FILE]
//!                (the hosts that cannot build yet: linux-aarch64, macos-arm64; native.zig says what it runs and why it stops before the build)
//!   stage version --buildrules PATH [--output FILE]
//!   stage action-ref --dir DIR --ref SHA
//!   stage gamma-vars (--farm-address V --farm-instance V --farm-properties V --ts-client-id V --ts-audience V --connect-repo V --connect-ref V --repos V)
//!   stage gamma  --work DIR --candidate SHA --repos "owner/name ..." --targets "//..." --buck2 PATH --farm-config FILE
//!   stage farm-macos --root DIR --buck2 PATH --farm-config FILE [--summary FILE]
//!                (the targets labelled `macos-farm` built on a farm with macOS workers; macos_farm.zig)
//!
//! Exit 0 when the stage passed (`beta` also for a planned leg), 1 when it failed, 2 on a bad command line.
//!
//! Every command a stage starts runs under `command_limit` (bounded.zig): one still running after 30 minutes is stopped with its process group
//! (what it started), and the stage fails with `CommandHung` and a line naming it. A line says each 5 minutes that a command is still running.
const std = @import("std");
const beta = @import("beta.zig");
const gamma = @import("gamma.zig");
const native = @import("native.zig");
const farm = @import("farm.zig");
const macos_farm = @import("macos_farm.zig");
const steps_mod = @import("steps.zig");
const io_mod = @import("io.zig");
const bounded = @import("bounded.zig");

/// The limit of one command. A beta leg took 1 to 5 minutes from start to end and the whole gamma job under 20 (release runs of main);
/// a farm build whose connection stopped answering ran without end. 30 minutes is far above the first and ends the second well inside the job's
/// 120: a cut command and its one rerun take 60 at most.
pub const command_limit = bounded.Limit{ .limit_ms = 30 * std.time.ms_per_min, .note_ms = 5 * std.time.ms_per_min };

pub const Args = struct {
    names: []const []const u8,
    values: []const []const u8,

    pub fn get(self: Args, name: []const u8) ?[]const u8 {
        for (self.names, self.values) |n, v| {
            if (std.mem.eql(u8, n, name)) return v;
        }
        return null;
    }

    pub fn need(self: Args, name: []const u8) ![]const u8 {
        return self.get(name) orelse {
            std.debug.print("stage: --{s} is required\n", .{name});
            return error.Usage;
        };
    }
};

pub fn parseArgs(a: std.mem.Allocator, argv: []const []const u8, allowed: []const []const u8) !Args {
    var names = std.ArrayList([]const u8).empty;
    var values = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        const flag = argv[i];
        if (!std.mem.startsWith(u8, flag, "--") or i + 1 >= argv.len) {
            std.debug.print("stage: expected --flag VALUE, got `{s}`\n", .{flag});
            return error.Usage;
        }
        var known = false;
        for (allowed) |n| {
            if (std.mem.eql(u8, flag[2..], n)) known = true;
        }
        if (!known) {
            std.debug.print("stage: unknown flag {s}\n", .{flag});
            return error.Usage;
        }
        try names.append(a, flag[2..]);
        try values.append(a, argv[i + 1]);
    }
    return .{ .names = names.items, .values = values.items };
}

const State = struct {
    /// Directory put first on PATH: the `buildrules` command line starts `buck2` by that name.
    path_prefix: []const u8,
};

fn realRun(ctx: *anyopaque, a: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) anyerror!io_mod.Out {
    const st: *State = @ptrCast(@alignCast(ctx));
    var env = try std.process.getEnvMap(a);
    if (st.path_prefix.len != 0) {
        const old = env.get("PATH") orelse "/usr/bin:/bin";
        try env.put("PATH", try std.fmt.allocPrint(a, "{s}:{s}", .{ st.path_prefix, old }));
    }
    // the shell variable PWD names the directory the stage was started in; a program that trusts it would work there
    try env.put("PWD", cwd);
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    return bounded.run(a, argv, cwd, &env, command_limit, bounded.system_clock, &w.interface);
}

fn appendFile(path: []const u8, bytes: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(bytes);
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) {
        std.debug.print("usage: stage plan|beta|native|version|action-ref|gamma|farm-macos --flag value ...\n", .{});
        return 2;
    }
    return run(a, argv[1], argv[2..]) catch |e| switch (e) {
        error.Usage => 2,
        else => {
            std.debug.print("stage {s}: {s}\n", .{ argv[1], @errorName(e) });
            return 1;
        },
    };
}

fn dirOf(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

fn run(a: std.mem.Allocator, cmd: []const u8, rest: []const []const u8) !u8 {
    if (std.mem.eql(u8, cmd, "plan")) {
        const g = try parseArgs(a, rest, &.{ "root", "output" });
        return plan(a, try g.need("root"), g.get("output"));
    }
    if (std.mem.eql(u8, cmd, "beta")) {
        const g = try parseArgs(a, rest, &beta_flags);
        const buck2 = try g.need("buck2");
        var st = State{ .path_prefix = if (std.mem.eql(u8, std.fs.path.basename(buck2), "buck2")) dirOf(buck2) else "" };
        return betaCommand(a, .{ .ctx = &st, .run_fn = realRun }, g);
    }
    if (std.mem.eql(u8, cmd, "native")) {
        const g = try parseArgs(a, rest, &native_flags);
        const buck2 = try g.need("buck2");
        var st = State{ .path_prefix = if (std.mem.eql(u8, std.fs.path.basename(buck2), "buck2")) dirOf(buck2) else "" };
        return nativeCommand(a, .{ .ctx = &st, .run_fn = realRun }, g, native.this_host);
    }
    if (std.mem.eql(u8, cmd, "version")) {
        const g = try parseArgs(a, rest, &.{ "buildrules", "output" });
        var st = State{ .path_prefix = "" };
        return versionCommand(a, .{ .ctx = &st, .run_fn = realRun }, g);
    }
    if (std.mem.eql(u8, cmd, "action-ref")) {
        const g = try parseArgs(a, rest, &.{ "dir", "ref" });
        var st = State{ .path_prefix = "" };
        const io = io_mod.Io{ .ctx = &st, .run_fn = realRun };
        try gamma.checkActionRef(a, io, try g.need("dir"), try g.need("ref"));
        io_mod.say("stage: the farm-connect action is at the commit FARM_CONNECT_REF names\n", .{});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "gamma-vars")) {
        var allowed: [gamma.required_vars.len][]const u8 = undefined;
        for (gamma.required_vars, 0..) |rv, i| allowed[i] = rv[0];
        const g = try parseArgs(a, rest, &allowed);
        var values: [gamma.required_vars.len][]const u8 = undefined;
        for (gamma.required_vars, 0..) |rv, i| values[i] = g.get(rv[0]) orelse "";
        const missing = try gamma.emptyVariables(a, &values);
        if (missing.len == 0) {
            io_mod.say("gamma: every repository variable it needs is set\n", .{});
            return 0;
        }
        std.debug.print("gamma: these repository variables are empty:", .{});
        for (missing) |m| std.debug.print(" {s}", .{m});
        std.debug.print("\n{s}", .{gamma.not_configured_message});
        return 1;
    }
    if (std.mem.eql(u8, cmd, "gamma")) {
        const g = try parseArgs(a, rest, &gamma_flags);
        const buck2 = try g.need("buck2");
        var st = State{ .path_prefix = if (std.mem.eql(u8, std.fs.path.basename(buck2), "buck2")) dirOf(buck2) else "" };
        return gammaCommand(a, .{ .ctx = &st, .run_fn = realRun }, g);
    }
    if (std.mem.eql(u8, cmd, "farm-macos")) {
        const g = try parseArgs(a, rest, &farm_macos_flags);
        var st = State{ .path_prefix = "" };
        return farmMacosCommand(a, .{ .ctx = &st, .run_fn = realRun }, g);
    }
    std.debug.print("stage: unknown command `{s}`\n", .{cmd});
    return error.Usage;
}

pub const farm_macos_flags = [_][]const u8{ "root", "buck2", "farm-config", "summary" };

/// `stage farm-macos`: see macos_farm.zig. A farm config that is missing or names no farm is red as a farm leg's is; one with no macOS worker set says which
/// variables to set.
pub fn farmMacosCommand(a: std.mem.Allocator, io: io_mod.Io, g: Args) !u8 {
    const root = try g.need("root");
    const buck2 = try g.need("buck2");
    const raw = std.fs.cwd().readFileAlloc(a, try g.need("farm-config"), 1 << 20) catch {
        std.debug.print("{s}", .{gamma.not_configured_message});
        return error.FarmNotConfigured;
    };
    const cfg = try macos_farm.macosConfig(a, raw);
    if (!farm.farmConfigured(cfg)) {
        std.debug.print("{s}", .{gamma.not_configured_message});
        return error.FarmNotConfigured;
    }
    const res = try macos_farm.run(a, io, .{ .root = root, .buck2 = buck2, .config = cfg });
    io_mod.say("farm-macos: passed: {d} target(s) built on the farm, Commands: {d} (cached: {d}, remote: {d}, local: {d})\n", .{ res.targets.len, res.summary.total, res.summary.cached, res.summary.remote, res.summary.local });
    if (g.get("summary")) |p| try appendFile(p, try macos_farm.summary(a, res));
    return 0;
}

pub const gamma_flags = [_][]const u8{ "work", "candidate", "repos", "targets", "buck2", "farm-config" };

/// `stage gamma`: see gamma.zig.
pub fn gammaCommand(a: std.mem.Allocator, io: io_mod.Io, g: Args) !u8 {
    const raw = std.fs.cwd().readFileAlloc(a, try g.need("farm-config"), 1 << 20) catch "";
    try std.fs.cwd().makePath(try g.need("work"));
    try gamma.run(a, io, .{
        .repos = try g.need("repos"),
        .candidate = try g.need("candidate"),
        .targets = g.get("targets") orelse "//...",
        .work = try g.need("work"),
        .buck2 = try g.need("buck2"),
        .farm_config = try farm.buildrulesConfig(a, raw),
    });
    io_mod.say("gamma: every repository built on the farm with the candidate\n", .{});
    return 0;
}

pub const beta_flags = [_][]const u8{ "root", "lang", "work", "origin", "commit", "buck2", "buildrules", "exec", "farm-config", "summary" };

/// `stage beta`: see beta.zig. The summary line says when a command of a farm leg ran again after a cut connection to the farm, and a leg that
/// fails because the connection was cut on both runs, or because a command was stopped at `command_limit`, says so there too.
pub fn betaCommand(a: std.mem.Allocator, io: io_mod.Io, g: Args) !u8 {
    const mode = try g.need("exec");
    var exec: beta.Exec = .local;
    if (std.mem.eql(u8, mode, "farm")) {
        const cfg_path = try g.need("farm-config");
        const raw = std.fs.cwd().readFileAlloc(a, cfg_path, 1 << 20) catch {
            std.debug.print("{s}", .{gamma.not_configured_message});
            return error.FarmNotConfigured;
        };
        const cfg = try farm.buildrulesConfig(a, raw);
        if (!farm.farmConfigured(cfg)) {
            std.debug.print("{s}", .{gamma.not_configured_message});
            return error.FarmNotConfigured;
        }
        exec = .{ .farm = cfg };
    } else if (!std.mem.eql(u8, mode, "local")) {
        std.debug.print("stage: --exec is local or farm\n", .{});
        return error.Usage;
    }
    const lang = try g.need("lang");
    const res = beta.run(a, io, .{
        .lang = lang,
        .root = try g.need("root"),
        .work = try g.need("work"),
        .origin = try g.need("origin"),
        .commit = try g.need("commit"),
        .buck2 = try g.need("buck2"),
        .buildrules = try g.need("buildrules"),
        .exec = exec,
    }) catch |e| {
        if (e == error.FarmConnectionCut) {
            if (g.get("summary")) |p| try appendFile(p, try std.fmt.allocPrint(a, "- beta `{s}`: **failed**: the connection to the farm was cut, and cut again when the command ran a second time (buck2: `{s}`)\n", .{ lang, farm.cut_marker }));
        }
        if (e == error.CommandHung) {
            if (g.get("summary")) |p| try appendFile(p, try std.fmt.allocPrint(a, "- beta `{s}`: **failed**: a command was still running after {d} min and was stopped; the log names it and shows the last lines it wrote\n", .{ lang, command_limit.limit_ms / std.time.ms_per_min }));
        }
        return e;
    };
    var md = std.ArrayList(u8).empty;
    switch (res.outcome) {
        .planned => {
            io_mod.say("beta {s}: PLANNED (skipped): {s}\n", .{ lang, res.reason });
            try md.print(a, "- beta `{s}`: **planned**, skipped: {s}\n", .{ lang, res.reason });
        },
        .passed => {
            for (res.outputs) |x| io_mod.say("beta {s}: {s} {s} sha256 {s}\n", .{ lang, x.target, x.path, x.sha256 });
            if (res.deterministic) |d| {
                io_mod.say("beta {s}: {d} output(s), {s} after a rebuild in another directory\n", .{ lang, res.outputs.len, if (d) "identical bytes" else "DIFFERENT" });
            }
            if (res.cut_reruns != 0) io_mod.say("beta {s}: passed; {d} command(s) ran again after a cut connection to the farm\n", .{ lang, res.cut_reruns });
            try md.print(a, "- beta `{s}`: passed, {d} output(s); {s}", .{ lang, res.outputs.len, if (res.deterministic == null) "determinism not checked on a farm" else "identical bytes after a clean rebuild" });
            if (res.cut_reruns != 0) try md.print(a, "; {d} command(s) ran again after a cut connection to the farm", .{res.cut_reruns});
            try md.append(a, '\n');
            for (res.outputs) |x| try md.print(a, "  - `{s}` sha256 `{s}`\n", .{ x.target, x.sha256 });
        },
    }
    if (g.get("summary")) |p| try appendFile(p, md.items);
    return 0;
}

const native_flags = [_][]const u8{ "root", "lang", "work", "origin", "commit", "buck2", "buildrules", "host", "version", "summary" };

/// The flags `stage native` cannot do without, in the order `nativeCommand` reads them.
const native_required = [_][]const u8{ "root", "lang", "work", "origin", "commit", "buck2", "buildrules", "host", "version" };

/// `stage native`: see native.zig. `machine` is the release target of the machine this program runs on.
fn nativeCommand(a: std.mem.Allocator, io: io_mod.Io, g: Args, machine: []const u8) !u8 {
    var v: [native_required.len][]const u8 = undefined;
    for (native_required, 0..) |name, i| v[i] = try g.need(name);
    const lang = v[1];
    const host = v[7];
    const res = try native.run(a, io, .{
        .leg = .{ .lang = lang, .root = v[0], .work = v[2], .origin = v[3], .commit = v[4], .buck2 = v[5], .buildrules = v[6], .exec = .local },
        .host = host,
        .actual_host = machine,
        .version = v[8],
    });
    io_mod.say("native {s}: passed on {s}: {d} file(s) copied, the same bytes in two directories, {d} target(s) loaded; the build is not run on this host (native.zig)\n", .{ lang, host, res.files, res.targets });
    if (g.get("summary")) |p| try appendFile(p, try native.summary(a, lang, host, v[8], res));
    return 0;
}

/// `stage version`: the version a command line says, for the `version` output of the tools job.
fn versionCommand(a: std.mem.Allocator, io: io_mod.Io, g: Args) !u8 {
    const v = try native.versionOf(a, io, try g.need("buildrules"));
    io_mod.say("stage: the command line says version {s}\n", .{v});
    if (g.get("output")) |p| try appendFile(p, try std.fmt.allocPrint(a, "version={s}\n", .{v}));
    return 0;
}

/// Which beta legs are ready and which are planned, from the checkout.
fn plan(a: std.mem.Allocator, root: []const u8, output: ?[]const u8) !u8 {
    const bdir = try std.fs.path.join(a, &.{ root, "beta" });
    var d = try std.fs.cwd().openDir(bdir, .{ .iterate = true });
    defer d.close();
    var langs = std.ArrayList([]const u8).empty;
    var it = d.iterate();
    while (try it.next()) |e| {
        if (e.kind == .directory) try langs.append(a, try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, langs.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var out = std.ArrayList(u8).empty;
    for (langs.items) |lang| {
        const text = std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ bdir, lang, "STEPS" }), 1 << 20) catch {
            std.debug.print("stage plan: beta/{s} has no STEPS\n", .{lang});
            return 1;
        };
        const spec = try steps_mod.parse(a, text);
        if (try beta.plannedReason(a, root, spec)) |why| {
            io_mod.say("beta {s}: planned: {s}\n", .{ lang, why });
            try out.print(a, "{s}=planned\n", .{lang});
        } else {
            io_mod.say("beta {s}: ready\n", .{lang});
            try out.print(a, "{s}=ready\n", .{lang});
        }
    }
    if (output) |p| try appendFile(p, out.items);
    return 0;
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;

test "flags are --name VALUE pairs of a known name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const g = try parseArgs(a, &.{ "--root", "/w", "--lang", "rust" }, &.{ "root", "lang", "work" });
    try t.expectEqualStrings("/w", g.get("root").?);
    try t.expect(g.get("work") == null);
    try t.expectError(error.Usage, g.need("work"));
    try t.expectError(error.Usage, parseArgs(a, &.{ "--bogus", "x" }, &.{"root"}));
    try t.expectError(error.Usage, parseArgs(a, &.{"--root"}, &.{"root"}));
    try t.expectError(error.Usage, parseArgs(a, &.{ "root", "x" }, &.{"root"}));
}

test "an unknown command, and a beta with a bad mode or a missing flag, are usage errors that run nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.Usage, run(a, "frobnicate", &.{}));
    try t.expectError(error.Usage, run(a, "beta", &.{ "--exec", "remote" }));
    try t.expectError(error.Usage, run(a, "beta", &.{ "--root", "/w" }));
    try t.expectError(error.Usage, run(a, "gamma", &.{ "--work", "/w" }));
    try t.expectError(error.Usage, run(a, "native", &.{ "--root", "/w" }));
    try t.expectError(error.Usage, run(a, "version", &.{}));
    try t.expectError(error.Usage, run(a, "version", &.{ "--output", "/w" }));
}

test "the commands through the real runner: version runs the program it is named, action-ref and farm-macos refuse before they run anything" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `true` (an applet on the PATH the test is given) exits 0 and prints no version: the program was started, and its answer is refused
    try t.expectError(error.WrongVersion, run(a, "version", &.{ "--buildrules", "true" }));
    // a ref that is not a full commit sha is refused before git is asked
    try t.expectError(error.BadRef, run(a, "action-ref", &.{ "--dir", ".", "--ref", "main" }));
    // with no farm file there is nothing to build, and nothing is started
    try t.expectError(error.FarmNotConfigured, run(a, "farm-macos", &.{ "--root", ".", "--buck2", "/b/buck2", "--farm-config", "/nonexistent/farm.buckconfig" }));
}

test "plan lists the legs, planned ones with the reason, from the checkout" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("beta/zig");
    try tmp.dir.makePath("beta/mojo");
    try tmp.dir.makePath("rules/mopm");
    try tmp.dir.writeFile(.{ .sub_path = "beta/zig/STEPS", .data = "config\nbuild //:a\n" });
    try tmp.dir.writeFile(.{ .sub_path = "beta/mojo/STEPS", .data = "planned-until mopm-release\nconfig\nbuild //:a\n" });
    try tmp.dir.writeFile(.{ .sub_path = "rules/mopm/pins.bzl", .data = "X = {\"release_pending\": True}\n" });
    try tmp.dir.writeFile(.{ .sub_path = "out", .data = "" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    const outp = try std.fs.path.join(a, &.{ root, "out" });
    try t.expectEqual(@as(u8, 0), try run(a, "plan", &.{ "--root", root, "--output", outp }));
    try t.expectEqualStrings("mojo=planned\nzig=ready\n", try tmp.dir.readFileAlloc(a, "out", 1 << 10));
    // the pin loses its marker: mojo is ready
    try tmp.dir.writeFile(.{ .sub_path = "rules/mopm/pins.bzl", .data = "X = {\"sha256\": \"a\"}\n" });
    try tmp.dir.writeFile(.{ .sub_path = "out", .data = "" });
    try t.expectEqual(@as(u8, 0), try plan(a, root, outp));
    try t.expectEqualStrings("mojo=ready\nzig=ready\n", try tmp.dir.readFileAlloc(a, "out", 1 << 10));
    // a leg with no STEPS is red
    try tmp.dir.makePath("beta/empty");
    try t.expectEqual(@as(u8, 1), try plan(a, root, null));
}


test "native and version run through an Io: the summary line, the version output, and a machine that is not the host" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try native.Env.make(a, native.demo_steps);
    defer env.tmp.cleanup();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "summary", .data = "" });
    try tmp.dir.writeFile(.{ .sub_path = "out", .data = "" });
    const base = try tmp.dir.realpathAlloc(a, ".");
    const summary = try std.fs.path.join(a, &.{ base, "summary" });
    const outp = try std.fs.path.join(a, &.{ base, "out" });
    const o = env.opts.leg;
    const argv = [_][]const u8{
        "--root",       o.root,   "--lang",   o.lang,        "--work",    o.work,        "--origin", o.origin,       "--commit",  o.commit,
        "--buck2",      o.buck2,  "--buildrules", o.buildrules, "--host", "linux-aarch64", "--version", "1.2.3",   "--summary", summary,
    };
    const g = try parseArgs(a, &argv, &native_flags);
    var fake = native.Fake{ .a = a };
    try t.expectEqual(@as(u8, 0), try nativeCommand(a, fake.io(), g, "linux-aarch64"));
    const md = try tmp.dir.readFileAlloc(a, "summary", 1 << 12);
    try t.expect(std.mem.indexOf(u8, md, "native `demo` on linux-aarch64: passed") != null);
    try t.expect(std.mem.indexOf(u8, md, "Not built on this host") != null);
    // another machine than the host the job names is red and writes no summary line
    var env2 = try native.Env.make(a, native.demo_steps);
    defer env2.tmp.cleanup();
    const o2 = env2.opts.leg;
    const argv2 = [_][]const u8{
        "--root",       o2.root,  "--lang",   o2.lang,       "--work",    o2.work,       "--origin", o2.origin,      "--commit",  o2.commit,
        "--buck2",      o2.buck2, "--buildrules", o2.buildrules, "--host", "macos-arm64", "--version", "1.2.3",
    };
    try t.expectError(error.WrongHost, nativeCommand(a, fake.io(), try parseArgs(a, &argv2, &native_flags), "linux-aarch64"));
    // a flag that is missing is a usage error
    try t.expectError(error.Usage, nativeCommand(a, fake.io(), try parseArgs(a, argv2[0..4], &native_flags), "linux-aarch64"));

    const vg = try parseArgs(a, &.{ "--buildrules", "/bin/buildrules", "--output", outp }, &.{ "buildrules", "output" });
    try t.expectEqual(@as(u8, 0), try versionCommand(a, fake.io(), vg));
    try t.expectEqualStrings("version=1.2.3\n", try tmp.dir.readFileAlloc(a, "out", 1 << 10));
    // with no output file it only says it
    try t.expectEqual(@as(u8, 0), try versionCommand(a, fake.io(), try parseArgs(a, &.{ "--buildrules", "/bin/buildrules" }, &.{ "buildrules", "output" })));
    var odd = native.Fake{ .a = a, .version_out = "hello\n" };
    try t.expectError(error.WrongVersion, versionCommand(a, odd.io(), vg));
}

test "a farm leg and gamma with no farm configured are red before anything runs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "empty.buckconfig", .data = "[buildrules_re]\n" });
    try tmp.dir.makePath("work");
    const base = try tmp.dir.realpathAlloc(a, ".");
    const none = try std.fs.path.join(a, &.{ base, "missing.buckconfig" });
    const empty = try std.fs.path.join(a, &.{ base, "empty.buckconfig" });
    const work = try std.fs.path.join(a, &.{ base, "work" });
    const common = [_][]const u8{ "--root", "/r", "--lang", "zig", "--work", "/w", "--origin", "o", "--commit", "c", "--buck2", "/b/buck2", "--buildrules", "/b/buildrules", "--exec", "farm", "--farm-config" };
    // the file is not there, and the file is there but names no farm
    try t.expectError(error.FarmNotConfigured, run(a, "beta", &(common ++ [_][]const u8{none})));
    try t.expectError(error.FarmNotConfigured, run(a, "beta", &(common ++ [_][]const u8{empty})));
    const g = [_][]const u8{ "--work", work, "--candidate", "c", "--repos", "o/r", "--buck2", "/b/buck2", "--farm-config" };
    try t.expectError(error.FarmNotConfigured, run(a, "gamma", &(g ++ [_][]const u8{none})));
    try t.expectEqualStrings(".", dirOf("buck2"));
    try t.expectEqualStrings("/b", dirOf("/b/buck2"));
}

test "a planned leg is skipped by beta with its reason in the summary, and nothing is run" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("beta/mojo");
    try tmp.dir.makePath("rules/mopm");
    try tmp.dir.writeFile(.{ .sub_path = "beta/mojo/STEPS", .data = "planned-until mopm-release\nconfig\nbuild //:a\n" });
    try tmp.dir.writeFile(.{ .sub_path = "rules/mopm/pins.bzl", .data = "X = {\"release_pending\": True}\n" });
    try tmp.dir.writeFile(.{ .sub_path = "summary", .data = "" });
    const base = try tmp.dir.realpathAlloc(a, ".");
    const summary = try std.fs.path.join(a, &.{ base, "summary" });
    const args = [_][]const u8{ "--root", base, "--lang", "mojo", "--work", "/nowhere", "--origin", "o", "--commit", "c", "--buck2", "/b/buck2", "--buildrules", "/b/buildrules", "--exec", "local", "--summary", summary };
    try t.expectEqual(@as(u8, 0), try run(a, "beta", &args));
    try t.expect(std.mem.indexOf(u8, try tmp.dir.readFileAlloc(a, "summary", 1 << 12), "beta `mojo`: **planned**, skipped: planned until mopm's first release") != null);
}

test "gamma-vars is red, naming them, while a variable is empty" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const full = [_][]const u8{ "--farm-address", "true", "--farm-instance", "true", "--farm-properties", "true", "--ts-client-id", "true", "--ts-audience", "true", "--connect-repo", "o/r", "--connect-ref", "f", "--repos", "o/m" };
    try t.expectEqual(@as(u8, 0), try run(a, "gamma-vars", &full));
    var one_empty = full;
    one_empty[1] = "false";
    try t.expectEqual(@as(u8, 1), try run(a, "gamma-vars", &one_empty));
    // a flag not given at all is empty too
    try t.expectEqual(@as(u8, 1), try run(a, "gamma-vars", full[0..14]));
    try t.expectEqual(@as(u8, 1), try run(a, "gamma-vars", &.{}));
}
