//! The beta stage on the hosts that cannot build yet (linux-aarch64, macos-arm64; RELEASING.md, "The beta stage"). A user on one of them runs the
//! command line the release ships for it, so this runs that very file, natively, as far as a user can get today: it says the planned version, `init`
//! writes the same bytes into a repository at two different paths, and Buck2 loads the candidate commit as the external cell and finds the targets of
//! a hello-world repository. It stops before the build, and that is the point of this file, not an omission:
//!
//!   - every toolchain of the rules is `exec_compatible_with` linux x86_64 (rules/core/platform.bzl), and the local-mode execution platform of these
//!     hosts is `platforms:linux_aarch64` / `platforms:macos_aarch64`, so a build finds no execution platform for any action;
//!   - the `platforms/BUCK` that `init` writes passes no platform for these hosts, so Buck2 does not load it there in local mode (rules/platforms.bzl);
//!   - and nothing could unpack the pinned downloads there anyway: every unpack action runs under the pinned busybox, and there is none for these
//!     hosts (docs/pins.md, "Other hosts").
//!
//! The steps are those of `beta/<lang>/STEPS` up to its first `build`: the repository is made the way `stage beta` makes it, so the two cannot drift.
const std = @import("std");
const builtin = @import("builtin");
const beta = @import("beta.zig");
const steps_mod = @import("steps.zig");
const io_mod = @import("io.zig");

const Io = io_mod.Io;

/// The release target name of a machine, the spelling of the release tarballs (`linux-aarch64`, `macos-arm64`, `linux-x86_64`), or null for any
/// other machine.
pub fn hostName(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (os) {
        .linux => switch (arch) {
            .x86_64 => "linux-x86_64",
            .aarch64 => "linux-aarch64",
            else => null,
        },
        .macos => switch (arch) {
            .aarch64 => "macos-arm64",
            else => null,
        },
        else => null,
    };
}

/// The release target of the machine this program was built for.
pub const this_host = hostName(builtin.os.tag, builtin.cpu.arch) orelse "unsupported";

pub const Options = struct {
    /// The options of the beta leg this follows (`lang`, `root`, `work`, `origin`, `commit`, `buck2`, `buildrules`; `exec` is local).
    leg: beta.Options,
    /// The release target this leg is for; the machine must be it.
    host: []const u8,
    /// The machine this program runs on (`this_host`; a test names another).
    actual_host: []const u8,
    /// The version the release planned: `buildrules --version` prints `buildrules <version>`.
    version: []const u8,
};

/// The line the job summary gets.
pub fn summary(a: std.mem.Allocator, lang: []const u8, host: []const u8, version: []const u8, res: Result) ![]u8 {
    return std.fmt.allocPrint(a, "- native `{s}` on {s}: passed; `buildrules --version` says {s}, `init` wrote the same bytes (sha256 `{s}`) in two directories, Buck2 loaded the candidate and listed {d} target(s). Not built on this host: no toolchain of the rules runs there yet\n", .{ lang, host, version, res.digest, res.targets });
}

pub const Result = struct {
    /// The number of files copied from beta/<lang>/, and the sha256 of the repository after `init` (every file of it).
    files: usize,
    digest: [64]u8,
    /// The targets Buck2 printed for the repository.
    targets: usize,
};

fn trimNl(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, "\r\n");
}

/// The steps before the first `build`: the commands a user types and the config. The targets that first `build` names are what Buck2 must find.
fn prefix(a: std.mem.Allocator, spec: steps_mod.Spec) !struct { steps: []const steps_mod.Step, targets: []const []const u8 } {
    var head = std.ArrayList(steps_mod.Step).empty;
    for (spec.steps) |s| switch (s) {
        .run, .config => try head.append(a, s),
        .build => |ts| return .{ .steps = head.items, .targets = ts },
        else => return error.NoBuildStep,
    };
    return error.NoBuildStep;
}

/// The version a command line says (`buildrules <version>`), for the legs that follow it: the planned version of the release, or `<major>.<minor>-dev` of a build
/// that is not one.
pub fn versionOf(a: std.mem.Allocator, io: Io, buildrules: []const u8) ![]const u8 {
    const v = try io.run(a, ".", &.{ buildrules, "--version" });
    const text = trimNl(v.stdout);
    const head = "buildrules ";
    if (v.code != 0 or !std.mem.startsWith(u8, text, head) or text.len == head.len or std.mem.indexOfScalar(u8, text, ' ') != head.len - 1 or std.mem.indexOfScalarPos(u8, text, head.len, ' ') != null) {
        std.debug.print("native: `{s} --version` exited {d} and printed `{s}`, not `buildrules <version>`\n", .{ buildrules, v.code, text });
        return error.WrongVersion;
    }
    return a.dupe(u8, text[head.len..]);
}

fn prepare(a: std.mem.Allocator, io: Io, o: beta.Options, steps: []const steps_mod.Step) !usize {
    const n = try beta.copyTree(a, try std.fs.path.join(a, &.{ o.root, "beta", o.lang }), o.work);
    for (steps) |s| switch (s) {
        .run => |words| try beta.runCommand(a, io, o, words),
        .config => try beta.writeConfig(a, o),
        else => unreachable,
    };
    return n;
}

pub fn run(a: std.mem.Allocator, io: Io, o: Options) !Result {
    const leg = o.leg;
    if (!std.mem.eql(u8, o.host, o.actual_host)) {
        std.debug.print("native {s}: this machine is {s}, not {s}; the leg would prove nothing about {s}\n", .{ leg.lang, o.actual_host, o.host, o.host });
        return error.WrongHost;
    }
    const steps_path = try std.fs.path.join(a, &.{ leg.root, "beta", leg.lang, "STEPS" });
    const steps_text = std.fs.cwd().readFileAlloc(a, steps_path, 1 << 20) catch |e| {
        std.debug.print("native {s}: cannot read {s}: {s}\n", .{ leg.lang, steps_path, @errorName(e) });
        return error.NoSuchLanguage;
    };
    const spec = try steps_mod.parse(a, steps_text);
    const pre = try prefix(a, spec);

    // The command line says the version the release planned.
    const v = try io.run(a, leg.root, &.{ leg.buildrules, "--version" });
    const want = try std.fmt.allocPrint(a, "buildrules {s}", .{o.version});
    if (v.code != 0 or !std.mem.eql(u8, trimNl(v.stdout), want)) {
        std.debug.print("native {s}: `{s} --version` exited {d} and printed `{s}`, expected `{s}`\n", .{ leg.lang, leg.buildrules, v.code, trimNl(v.stdout), want });
        return error.WrongVersion;
    }
    io_mod.say("native {s}: {s} says `{s}` on {s}\n", .{ leg.lang, leg.buildrules, want, o.actual_host });

    // A fresh repository, outside the checkout, and the same steps in a second one at another path: what `init` writes must not depend on where.
    std.fs.cwd().access(try std.fs.path.join(a, &.{ leg.work, ".buckconfig" }), .{}) catch {
        const files = try prepare(a, io, leg, pre.steps);
        var second = leg;
        second.work = try beta.secondWorkDir(a, leg.work);
        _ = try prepare(a, io, second, pre.steps);
        const first_digest = try beta.hashOutput(a, std.fs.cwd(), leg.work);
        const second_digest = try beta.hashOutput(a, std.fs.cwd(), second.work);
        if (!std.mem.eql(u8, &first_digest, &second_digest)) {
            std.debug.print("native {s}: DIFFERENT BYTES: the repository `init` made in {s} (sha256 {s}) is not the one it made in {s} (sha256 {s})\n", .{ leg.lang, leg.work, first_digest, second.work, second_digest });
            return error.NotDeterministic;
        }
        io_mod.say("native {s}: the same files in two directories, sha256 {s}\n", .{ leg.lang, first_digest });

        // Buck2 reads the candidate as the external cell and the hello-world BUCK file against it: the targets it names exist.
        // Only the targets the leg names, not `//...`: the `platforms/BUCK` that `init` writes passes no platform for these hosts, so Buck2 refuses to load it in local mode
        // there (rules/platforms.bzl: "buildrules knows linux-x86_64 and no other host"), which is another reason nothing builds.
        var targets_argv = std.ArrayList([]const u8).empty;
        try targets_argv.appendSlice(a, &.{ leg.buck2, "targets", "-c", "buildrules_re.mode=local" });
        try targets_argv.appendSlice(a, pre.targets);
        const tg = try io.run(a, leg.work, targets_argv.items);
        _ = try io.run(a, leg.work, &.{ leg.buck2, "kill" });
        if (tg.code != 0) {
            std.debug.print("native {s}: `{s} targets //...` exited {d}\n{s}\n{s}\n", .{ leg.lang, leg.buck2, tg.code, io_mod.tail(tg.stderr, 40), io_mod.tail(tg.stdout, 20) });
            return error.StepFailed;
        }
        var seen: usize = 0;
        var lines = std.mem.splitScalar(u8, tg.stdout, '\n');
        while (lines.next()) |l| {
            if (trimNl(l).len != 0) seen += 1;
        }
        for (pre.targets) |want_t| {
            var found = false;
            var it = std.mem.splitScalar(u8, tg.stdout, '\n');
            while (it.next()) |l| {
                // buck2 prints the full label (`root//:hello`); a step names it `//:hello`
                if (std.mem.endsWith(u8, trimNl(l), want_t)) found = true;
            }
            if (!found) {
                std.debug.print("native {s}: Buck2 does not list {s} in the repository `init` made:\n{s}\n", .{ leg.lang, want_t, io_mod.tail(tg.stdout, 20) });
                return error.TargetMissing;
            }
        }
        io_mod.say("native {s}: Buck2 lists {d} target(s), among them {s}\n", .{ leg.lang, seen, try std.mem.join(a, " ", pre.targets) });
        return .{ .files = files, .digest = first_digest, .targets = seen };
    };
    std.debug.print("native {s}: {s} already holds a repository (.buckconfig); the leg starts from an empty directory\n", .{ leg.lang, leg.work });
    return error.WorkNotFresh;
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

const t = std.testing;

/// A fake `Io` answering by the needle in `argv...`; a file it is told to write goes under the cwd, with the cwd appended when `embed_cwd`.
pub const Fake = struct {
    a: std.mem.Allocator,
    version_out: []const u8 = "buildrules 1.2.3\n",
    init_embeds_cwd: bool = false,
    init_code: u8 = 0,
    targets_out: []const u8 = "root//:hello_unit\nroot//:hello\n",
    targets_code: u8 = 0,
    calls: std.ArrayList([]const u8) = .empty,

    fn runCmd(ctx: *anyopaque, a: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) anyerror!io_mod.Out {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const line = try std.mem.join(a, " ", argv);
        try self.calls.append(self.a, line);
        if (std.mem.indexOf(u8, line, "--version") != null) return .{ .code = 0, .stdout = self.version_out, .stderr = "" };
        if (std.mem.indexOf(u8, line, " init ") != null) {
            if (self.init_code != 0) return .{ .code = self.init_code, .stdout = "", .stderr = "init failed" };
            var d = try std.fs.cwd().openDir(cwd, .{});
            defer d.close();
            const bytes = if (self.init_embeds_cwd) try std.mem.concat(a, u8, &.{ "[cells]\n", cwd }) else "[cells]\n";
            try d.writeFile(.{ .sub_path = ".buckconfig", .data = bytes });
            return .{ .code = 0, .stdout = "", .stderr = "" };
        }
        if (std.mem.indexOf(u8, line, " targets ") != null) return .{ .code = self.targets_code, .stdout = self.targets_out, .stderr = "load failed" };
        if (std.mem.indexOf(u8, line, " kill") != null) return .{ .code = 0, .stdout = "", .stderr = "" };
        return error.UnscriptedCommand;
    }

    pub fn io(self: *Fake) Io {
        return .{ .ctx = self, .run_fn = runCmd };
    }

    fn count(self: Fake, needle: []const u8) usize {
        var n: usize = 0;
        for (self.calls.items) |c| {
            if (std.mem.indexOf(u8, c, needle) != null) n += 1;
        }
        return n;
    }
};

pub const Env = struct {
    tmp: std.testing.TmpDir,
    opts: Options,

    pub fn make(a: std.mem.Allocator, steps_text: []const u8) !Env {
        var tmp = t.tmpDir(.{});
        try tmp.dir.makePath("cand/beta/demo");
        try tmp.dir.writeFile(.{ .sub_path = "cand/beta/demo/STEPS", .data = steps_text });
        try tmp.dir.writeFile(.{ .sub_path = "cand/beta/demo/BUCK.beta", .data = "# the user's BUCK\n" });
        try tmp.dir.writeFile(.{ .sub_path = "cand/beta/demo/main.c", .data = "int main(void){return 0;}\n" });
        const base = try tmp.dir.realpathAlloc(a, ".");
        const leg = beta.Options{
            .lang = "demo",
            .root = try std.fs.path.join(a, &.{ base, "cand" }),
            .work = try std.fs.path.join(a, &.{ base, "work" }),
            .origin = "https://example.invalid/r",
            .commit = "c" ** 40,
            .buck2 = "/bin/buck2",
            .buildrules = "/bin/buildrules",
            .exec = .local,
        };
        return .{ .tmp = tmp, .opts = .{ .leg = leg, .host = "linux-aarch64", .actual_host = "linux-aarch64", .version = "1.2.3" } };
    }
};

pub const demo_steps =
    \\run buildrules init . --git {origin} --commit {commit}
    \\config
    \\build //:hello_unit //:hello
    \\expect //:hello => Hello, world!
    \\
;

test "a native leg: the version, the same files in two directories, and the targets Buck2 finds, without a build" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    var fake = Fake{ .a = a };
    const r = try run(a, fake.io(), env.opts);
    try t.expectEqual(@as(usize, 2), r.targets);
    // BUCK.beta and main.c, copied; `init` ran once in each of two directories, and nothing built
    try t.expectEqual(@as(usize, 2), r.files);
    try t.expectEqual(@as(usize, 2), fake.count("/bin/buildrules init . --git https://example.invalid/r --commit " ++ "c" ** 40));
    try t.expectEqual(@as(usize, 1), fake.count("/bin/buck2 targets -c buildrules_re.mode=local //:hello_unit //:hello"));
    try t.expectEqual(@as(usize, 0), fake.count("buck2 build"));
    try t.expectEqual(@as(usize, 1), fake.count("/bin/buck2 kill"));
    // the second directory is another path
    try t.expect(std.mem.indexOf(u8, try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ env.opts.leg.work, ".buckconfig.local" }), 1 << 10), "mode = local") != null);
    const second = try beta.secondWorkDir(a, env.opts.leg.work);
    try std.fs.cwd().access(try std.fs.path.join(a, &.{ second, ".buckconfig" }), .{});
}

test "a command line that says another version is red, and so is one that fails" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    var fake = Fake{ .a = a, .version_out = "buildrules 1.2.3-dev\n" };
    try t.expectError(error.WrongVersion, run(a, fake.io(), env.opts));
    // nothing ran after the version
    try t.expectEqual(@as(usize, 1), fake.calls.items.len);
    var other = Fake{ .a = a, .version_out = "buildrules 1.2.4\n" };
    try t.expectError(error.WrongVersion, run(a, other.io(), env.opts));
    var empty = Fake{ .a = a, .version_out = "" };
    try t.expectError(error.WrongVersion, run(a, empty.io(), env.opts));
}

test "files that depend on the directory they were made in are red" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    var fake = Fake{ .a = a, .init_embeds_cwd = true };
    try t.expectError(error.NotDeterministic, run(a, fake.io(), env.opts));
    // Buck2 was never asked: the files were already wrong
    try t.expectEqual(@as(usize, 0), fake.count("targets"));
}

test "a failed init, a failed load and a target that is not listed are red; the daemon is stopped after a load" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    var bad_init = Fake{ .a = a, .init_code = 1 };
    try t.expectError(error.StepFailed, run(a, bad_init.io(), env.opts));

    var env2 = try Env.make(a, demo_steps);
    defer env2.tmp.cleanup();
    var bad_load = Fake{ .a = a, .targets_code = 1 };
    try t.expectError(error.StepFailed, run(a, bad_load.io(), env2.opts));
    try t.expectEqual(@as(usize, 1), bad_load.count("/bin/buck2 kill"));

    var env3 = try Env.make(a, demo_steps);
    defer env3.tmp.cleanup();
    var missing = Fake{ .a = a, .targets_out = "root//:hello_unit\n" };
    try t.expectError(error.TargetMissing, run(a, missing.io(), env3.opts));
    // an empty listing finds nothing either
    var env4 = try Env.make(a, demo_steps);
    defer env4.tmp.cleanup();
    var nothing = Fake{ .a = a, .targets_out = "" };
    try t.expectError(error.TargetMissing, run(a, nothing.io(), env4.opts));
}

test "the machine must be the host the leg is for, and the work directory must be fresh" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    var fake = Fake{ .a = a };
    var wrong = env.opts;
    wrong.actual_host = "linux-x86_64";
    try t.expectError(error.WrongHost, run(a, fake.io(), wrong));
    try t.expectEqual(@as(usize, 0), fake.calls.items.len);
    // a repository that is already there is not started over
    try env.tmp.dir.makePath("work");
    try env.tmp.dir.writeFile(.{ .sub_path = "work/.buckconfig", .data = "x" });
    try t.expectError(error.WorkNotFresh, run(a, fake.io(), env.opts));
    // no such language
    var env2 = try Env.make(a, demo_steps);
    defer env2.tmp.cleanup();
    var nolang = env2.opts;
    nolang.leg.lang = "nothing";
    try t.expectError(error.NoSuchLanguage, run(a, fake.io(), nolang));
}

test "a STEPS file with nothing to find, or one that builds before it loads, has no native leg" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = try steps_mod.parse(a, "config\nbuild //:a\nexpect //:a => x\n");
    const p = try prefix(a, spec);
    try t.expectEqual(@as(usize, 1), p.steps.len);
    try t.expectEqualStrings("//:a", p.targets[0]);
    // a step other than run and config before the first build
    const odd = steps_mod.Spec{ .steps = &.{ .config, .{ .expect = .{ .target = "//:a", .text = "x" } }, .{ .build = &.{"//:a"} } } };
    try t.expectError(error.NoBuildStep, prefix(a, odd));
    const none = steps_mod.Spec{ .steps = &.{.config} };
    try t.expectError(error.NoBuildStep, prefix(a, none));
}

test "versionOf is what follows `buildrules `, and nothing else is a version" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake = Fake{ .a = a, .version_out = "buildrules 0.3.7\n" };
    try t.expectEqualStrings("0.3.7", try versionOf(a, fake.io(), "/bin/buildrules"));
    var dev = Fake{ .a = a, .version_out = "buildrules 0.3-dev\n" };
    try t.expectEqualStrings("0.3-dev", try versionOf(a, dev.io(), "/bin/buildrules"));
    for ([_][]const u8{ "", "buildrules\n", "buildrules \n", "buildrules 1 2\n", "other 1.2.3\n", "buildrules  1.2.3\n" }) |bad| {
        var f = Fake{ .a = a, .version_out = bad };
        try t.expectError(error.WrongVersion, versionOf(a, f.io(), "/bin/buildrules"));
    }
}

test "the host names are the release targets" {
    try t.expectEqualStrings("linux-x86_64", hostName(.linux, .x86_64).?);
    try t.expectEqualStrings("linux-aarch64", hostName(.linux, .aarch64).?);
    try t.expectEqualStrings("macos-arm64", hostName(.macos, .aarch64).?);
    try t.expect(hostName(.macos, .x86_64) == null);
    try t.expect(hostName(.linux, .riscv64) == null);
    try t.expect(hostName(.windows, .x86_64) == null);
}
