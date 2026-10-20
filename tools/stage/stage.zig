//! `stage`: the beta and gamma stages of the automatic release (RELEASING.md). The logic is in beta.zig and gamma.zig, each tested against a fake
//! `Io`; this file reads the command line and runs the real programs.
//!
//!   stage plan   --root DIR [--output FILE]
//!   stage beta   --root DIR --lang L --work DIR --origin URL --commit SHA --buck2 PATH --buildrules PATH
//!                (--exec local | --exec farm --farm-config FILE) [--summary FILE]
//!   stage action-ref --dir DIR --ref SHA
//!   stage gamma-vars (--farm-address V --farm-instance V --farm-properties V --ts-client-id V --ts-audience V --connect-repo V --connect-ref V --repos V)
//!   stage gamma  --work DIR --candidate SHA --repos "owner/name ..." --targets "//..." --buck2 PATH --farm-config FILE
//!
//! Exit 0 when the stage passed (`beta` also for a planned leg), 1 when it failed, 2 on a bad command line.
const std = @import("std");
const beta = @import("beta.zig");
const gamma = @import("gamma.zig");
const farm = @import("farm.zig");
const steps_mod = @import("steps.zig");
const io_mod = @import("io.zig");

const Args = struct {
    names: []const []const u8,
    values: []const []const u8,

    fn get(self: Args, name: []const u8) ?[]const u8 {
        for (self.names, self.values) |n, v| {
            if (std.mem.eql(u8, n, name)) return v;
        }
        return null;
    }

    fn need(self: Args, name: []const u8) ![]const u8 {
        return self.get(name) orelse {
            std.debug.print("stage: --{s} is required\n", .{name});
            return error.Usage;
        };
    }
};

fn parseArgs(a: std.mem.Allocator, argv: []const []const u8, allowed: []const []const u8) !Args {
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
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv, .cwd = cwd, .env_map = &env, .max_output_bytes = 1 << 28 });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
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
        std.debug.print("usage: stage plan|beta|action-ref|gamma --flag value ...\n", .{});
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
        const g = try parseArgs(a, rest, &.{ "root", "lang", "work", "origin", "commit", "buck2", "buildrules", "exec", "farm-config", "summary" });
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
        const buck2 = try g.need("buck2");
        var st = State{ .path_prefix = if (std.mem.eql(u8, std.fs.path.basename(buck2), "buck2")) dirOf(buck2) else "" };
        const io = io_mod.Io{ .ctx = &st, .run_fn = realRun };
        const lang = try g.need("lang");
        const res = try beta.run(a, io, .{
            .lang = lang,
            .root = try g.need("root"),
            .work = try g.need("work"),
            .origin = try g.need("origin"),
            .commit = try g.need("commit"),
            .buck2 = buck2,
            .buildrules = try g.need("buildrules"),
            .exec = exec,
        });
        var md = std.ArrayList(u8).empty;
        switch (res.outcome) {
            .planned => {
                io_mod.say("beta {s}: PLANNED (skipped): {s}\n", .{ lang, res.reason });
                try md.print(a, "- beta `{s}`: **planned**, skipped: {s}\n", .{ lang, res.reason });
            },
            .passed => {
                for (res.outputs) |x| io_mod.say("beta {s}: {s} {s} sha256 {s}\n", .{ lang, x.target, x.path, x.sha256 });
                if (res.deterministic) |d| {
                    io_mod.say("beta {s}: {d} output(s), {s} after buck2 clean and a rebuild\n", .{ lang, res.outputs.len, if (d) "identical bytes" else "DIFFERENT" });
                }
                try md.print(a, "- beta `{s}`: passed, {d} output(s); {s}\n", .{ lang, res.outputs.len, if (res.deterministic == null) "determinism not checked on a farm" else "identical bytes after a clean rebuild" });
                for (res.outputs) |x| try md.print(a, "  - `{s}` sha256 `{s}`\n", .{ x.target, x.sha256 });
            },
        }
        if (g.get("summary")) |p| try appendFile(p, md.items);
        return 0;
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
        const g = try parseArgs(a, rest, &.{ "work", "candidate", "repos", "targets", "buck2", "farm-config" });
        const raw = std.fs.cwd().readFileAlloc(a, try g.need("farm-config"), 1 << 20) catch "";
        const buck2 = try g.need("buck2");
        var st = State{ .path_prefix = if (std.mem.eql(u8, std.fs.path.basename(buck2), "buck2")) dirOf(buck2) else "" };
        const io = io_mod.Io{ .ctx = &st, .run_fn = realRun };
        try std.fs.cwd().makePath(try g.need("work"));
        try gamma.run(a, io, .{
            .repos = try g.need("repos"),
            .candidate = try g.need("candidate"),
            .targets = g.get("targets") orelse "//...",
            .work = try g.need("work"),
            .buck2 = buck2,
            .farm_config = try farm.buildrulesConfig(a, raw),
        });
        io_mod.say("gamma: every repository built on the farm with the candidate\n", .{});
        return 0;
    }
    std.debug.print("stage: unknown command `{s}`\n", .{cmd});
    return error.Usage;
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
    try t.expectEqual(@as(u8, 0), try plan(a, root, outp));
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
