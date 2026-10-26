//! The beta stage (RELEASING.md): a hello-world repository per language consumes the candidate commit of buildrules as an external Buck2 cell,
//! the way a user does. `beta/<lang>/` holds the files a user writes and `STEPS` the commands a user types (steps.zig); this file copies the
//! directory to a fresh place outside the checkout, runs the steps with the `buildrules` built from the candidate, builds, runs what was
//! built, and (in local mode) builds again from nothing in a copy of the repository at another path, to see that the outputs are the same bytes.
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
    /// How many times a build is made again after it failed only because a download of a pin failed (`isDownloadFlake`). Never for any other failure.
    download_retries: u8 = 3,
    /// The wait before the first retry; each retry waits twice as long as the one before.
    retry_delay_ms: u64 = 20_000,
};

/// `buildrules.url_map`: the mirrors of the pinned downloads, each checked byte-identical to the primary (docs/pins.md, "Mirrors"). A pin with no
/// entry here (the rust tarballs, the github releases, the npm and crates.io packages) has no mirror and is fetched from its own host.
pub const mirror_map = "https://github.com/komira-ai/buildrules/releases/download/mirror-busybox-1.35.0/=https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/" ++
    " https://ziglang.org/download/=https://zig.linus.dev/zig/" ++
    " https://conda.anaconda.org/conda-forge/=https://repo.prefix.dev/conda-forge/" ++
    " https://nodejs.org/dist/=https://registry.npmmirror.com/-/binary/node/";

/// Whether the stderr of a failed `buck2 build` says that a pinned download did not arrive: buck2 names the failed step ("materializing HTTP
/// resource") and a transport cause (a timeout, a refused or reset connection, a server error). A wrong hash, a compile error, a test failure
/// and every other message are NOT a flake: they carry no such pair, so they stay fatal on the first run.
///
/// Matched without regard to case: buck2 writes its transport messages capitalised ("Error sending request", "No route to host"), the HTTP
/// client under it in lower case ("tcp connect error"), and a cause that is a chain of lines has both.
pub fn isDownloadFlake(stderr: []const u8) bool {
    if (std.ascii.indexOfIgnoreCase(stderr, "materializing HTTP resource") == null) return false;
    const causes = [_][]const u8{
        "Timed out",
        "Connection refused",
        "Connection reset",
        "Connection closed",
        "Error sending request",
        "tcp connect error",
        "No route to host",
        "Network is unreachable",
        "dns error",
        "HTTP status 5",
        "HTTP status 429",
        "Service Unavailable",
        "Bad Gateway",
        "Gateway Timeout",
    };
    for (causes) |c| {
        if (std.ascii.indexOfIgnoreCase(stderr, c) != null) return true;
    }
    return false;
}

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


/// The place of the second build: next to the first, under another name, so that its absolute path differs from the first's.
pub fn secondWorkDir(a: std.mem.Allocator, work: []const u8) ![]const u8 {
    const trimmed = std.mem.trimRight(u8, work, "/");
    return std.fmt.allocPrint(a, "{s}-second", .{trimmed});
}

/// Copies the repository at `src` to `dst` (made new: an existing `dst` is an error, since a stale one would hide what the build does) without
/// `buck-out`, symlinks as symlinks, files with their modes. Returns the number of files.
pub fn copyRepo(a: std.mem.Allocator, src: []const u8, dst: []const u8) !usize {
    var sd = try std.fs.cwd().openDir(src, .{ .iterate = true });
    defer sd.close();
    std.fs.cwd().makeDir(dst) catch |e| {
        if (e == error.PathAlreadyExists) std.debug.print("beta: {s} exists; the second build starts from an empty place\n", .{dst});
        return e;
    };
    var dd = try std.fs.cwd().openDir(dst, .{});
    defer dd.close();
    var w = try sd.walk(a);
    defer w.deinit();
    var n: usize = 0;
    while (try w.next()) |e| {
        if (std.mem.eql(u8, e.path, "buck-out") or std.mem.startsWith(u8, e.path, "buck-out/")) continue;
        switch (e.kind) {
            .directory => try dd.makePath(e.path),
            .file => {
                if (std.fs.path.dirname(e.path)) |d| try dd.makePath(d);
                try sd.copyFile(e.path, dd, e.path, .{});
                n += 1;
            },
            .sym_link => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const target = try sd.readLink(e.path, &buf);
                if (std.fs.path.dirname(e.path)) |d| try dd.makePath(d);
                try dd.symLink(target, e.path, .{});
                n += 1;
            },
            else => return error.UnexpectedFileKind,
        }
    }
    return n;
}

/// Runs `argv`; when it fails only because a pinned download failed (`isDownloadFlake`) it is run again, up to `download_retries` times, with a wait
/// that doubles. Any other failure is returned on the first run. The retried command is the same, so what it does is unchanged. From the second
/// retry on, when `mirror_at` is set, `-c buildrules.url_map=<mirror_map>` is inserted at that index of the argv so the pins are fetched from
/// their mirrors (the sha256 and size of every download are still checked). A command that cannot take that flag passes null and is run unchanged.
fn runRetrying(a: std.mem.Allocator, io: Io, o: Options, cwd: []const u8, argv: []const []const u8, mirror_at: ?usize) !io_mod.Out {
    var r = try io.run(a, cwd, argv);
    // The second build starts with no buck-out, so every pin is downloaded again; an upstream server that drops it must not block a release.
    var wait_ms = o.retry_delay_ms;
    var left = o.download_retries;
    while (r.code != 0 and left > 0 and isDownloadFlake(r.stderr)) : (left -= 1) {
        io_mod.say("beta {s}: a pinned download failed ({d} retries left); waiting {d} ms\n{s}\n", .{ o.lang, left, wait_ms, io_mod.tail(r.stderr, 6) });
        if (wait_ms > 0) io.sleep(wait_ms);
        wait_ms *= 2;
        // The first retry asks the same host again (a throttle ends); from the second on the pins are fetched from their mirrors
        // (`mirror_map`, rules/core/url_map.bzl).
        if (left <= 2 and mirror_at != null) {
            const at = mirror_at.?;
            var m = std.ArrayList([]const u8).empty;
            try m.appendSlice(a, argv[0..at]);
            try m.appendSlice(a, &.{ "-c", "buildrules.url_map=" ++ mirror_map });
            try m.appendSlice(a, argv[at..]);
            r = try io.run(a, cwd, m.items);
        } else {
            r = try io.run(a, cwd, argv);
        }
    }
    return r;
}

/// `buck2 build` of the targets, with their outputs. Local mode passes the mode on the command; a farm run must report no local command.
fn build(a: std.mem.Allocator, io: Io, o: Options, cwd: []const u8, targets: []const []const u8) ![]const Output {
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{ o.buck2, "build", "--console", "simple" });
    if (o.exec == .local) try argv.appendSlice(a, &.{ "-c", "buildrules_re.mode=local" });
    const show_at = argv.items.len;
    try argv.append(a, "--show-output");
    try argv.appendSlice(a, targets);
    const r = try runRetrying(a, io, o, cwd, argv.items, show_at);
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

fn hashAll(a: std.mem.Allocator, cwd: []const u8, outs: []const Output) ![]Output {
    var dir = try std.fs.cwd().openDir(cwd, .{});
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

/// A `run` step: the command a user types, with `{origin}` and `{commit}` filled in and `buildrules` the candidate's command line, in the work directory.
pub fn runCommand(a: std.mem.Allocator, io: Io, o: Options, words: []const []const u8) !void {
    var argv = std.ArrayList([]const u8).empty;
    for (words) |w| {
        const s = try steps_mod.substitute(a, w, o.origin, o.commit);
        try argv.append(a, if (std.mem.eql(u8, s, "buildrules")) o.buildrules else s);
    }
    io_mod.say("beta {s}: $ {s}\n", .{ o.lang, try std.mem.join(a, " ", words) });
    // `buildrules sync` and `mojo sync` run buck2 inside to fetch the pinned tools, and the CLI does not forward `-c`, so the same argv is run again
    const r = try runRetrying(a, io, o, o.work, argv.items, null);
    if (r.code != 0) {
        std.debug.print("beta {s}: `{s}` exited {d}\n{s}\n{s}\n", .{ o.lang, try std.mem.join(a, " ", words), r.code, io_mod.tail(r.stderr, 40), io_mod.tail(r.stdout, 20) });
        return error.StepFailed;
    }
}

/// The `config` step: `.buckconfig.local` of the work directory says where actions run.
pub fn writeConfig(a: std.mem.Allocator, o: Options) !void {
    const text = switch (o.exec) {
        .local => farm.local_config,
        .farm => |c| c,
    };
    const p = try std.fs.path.join(a, &.{ o.work, ".buckconfig.local" });
    try std.fs.cwd().writeFile(.{ .sub_path = p, .data = text });
    io_mod.say("beta {s}: wrote .buckconfig.local ({s})\n", .{ o.lang, if (o.exec == .local) "local mode" else "the farm" });
}

fn runSteps(a: std.mem.Allocator, io: Io, o: Options, spec: steps_mod.Spec) !Result {
    var targets = std.ArrayList([]const u8).empty;
    for (spec.steps) |step| switch (step) {
        .run => |words| try runCommand(a, io, o, words),
        .config => try writeConfig(a, o),
        .build => |ts| {
            io_mod.say("beta {s}: build {s}\n", .{ o.lang, try std.mem.join(a, " ", ts) });
            _ = try build(a, io, o, o.work, ts);
            for (ts) |x| {
                var dup = false;
                for (targets.items) |y| {
                    if (std.mem.eql(u8, x, y)) dup = true;
                }
                if (!dup) try targets.append(a, x);
            }
        },
        .expect => |e| {
            const outs = try build(a, io, o, o.work, &.{e.target});
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
            const outs = try build(a, io, o, o.work, &.{e.target});
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

    const first = try hashAll(a, o.work, try build(a, io, o, o.work, targets.items));
    // A leg whose targets have no output at all would pass the comparison below having compared nothing: two empty lists are equal. That is a
    // vacuous determinism check, so it is red (on a farm too: the same STEPS would be vacuous on the runner). Name a target that makes a file.
    if (first.len == 0) {
        std.debug.print("beta {s}: the build of {s} declares no output, so there is nothing to compare between two builds (a vacuous determinism check); build a target that makes a file, such as a library or an executable\n", .{ o.lang, try std.mem.join(a, " ", targets.items) });
        _ = try io.run(a, o.work, &.{ o.buck2, "kill" });
        return error.NoOutputsToCompare;
    }
    var res = Result{ .outcome = .passed, .outputs = first };
    if (o.exec == .farm) {
        io_mod.say("beta {s}: determinism not checked on a farm: its cache would answer the second build\n", .{o.lang});
        _ = try io.run(a, o.work, &.{ o.buck2, "kill" });
        return res;
    }
    // From nothing, and from ANOTHER directory: the repository (without buck-out) is copied to a second place and built there, so the toolchains
    // are fetched again, every action runs again, and an output that depends on the absolute path of the work directory (a compile directory in
    // debug info, a path in a manifest) differs between the two builds and is found. A second build in the same directory could not see that.
    _ = try io.run(a, o.work, &.{ o.buck2, "kill" });
    const work2 = try secondWorkDir(a, o.work);
    const copied = try copyRepo(a, o.work, work2);
    io_mod.say("beta {s}: second build in {s} ({d} file(s) copied, no buck-out)\n", .{ o.lang, work2, copied });
    const second = hashAll(a, work2, try build(a, io, o, work2, targets.items)) catch |e| {
        _ = try io.run(a, work2, &.{ o.buck2, "kill" });
        return e;
    };
    var same = first.len == second.len;
    if (same) {
        for (first, second) |x, y| {
            if (!std.mem.eql(u8, x.target, y.target) or !std.mem.eql(u8, x.path, y.path) or !std.mem.eql(u8, &x.sha256, &y.sha256)) {
                std.debug.print("beta {s}: NOT DETERMINISTIC: {s} {s}\n  first build  ({s})  sha256 {s}\n  second build ({s})  sha256 {s}\n", .{ o.lang, x.target, x.path, o.work, x.sha256, work2, y.sha256 });
                same = false;
            }
        }
    } else {
        std.debug.print("beta {s}: NOT DETERMINISTIC: the first build had {d} output(s) and the second {d}\n", .{ o.lang, first.len, second.len });
    }
    res.deterministic = same;
    _ = try io.run(a, work2, &.{ o.buck2, "kill" });
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
    cwds: std.ArrayList([]const u8) = .empty,
    /// Every wait the code under test asked for, in order (milliseconds). Nothing really waits.
    sleep_log: [8]u64 = undefined,
    sleep_n: usize = 0,

    const File = struct {
        path: []const u8,
        bytes: []const u8,
        /// The directory the command ran in is appended to the bytes: an output that depends on the checkout path.
        embed_cwd: bool = false,
    };
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
        try self.cwds.append(self.a, try self.a.dupe(u8, cwd));
        for (self.rules) |*r| {
            if (r.times != 0 and r.used >= r.times) continue;
            if (std.mem.indexOf(u8, line, r.needle) == null) continue;
            r.used += 1;
            var d = try std.fs.cwd().openDir(cwd, .{});
            defer d.close();
            for (r.files) |f| {
                if (std.fs.path.dirname(f.path)) |p| try d.makePath(p);
                const data = if (f.embed_cwd) try std.mem.concat(a, u8, &.{ f.bytes, cwd }) else f.bytes;
                try d.writeFile(.{ .sub_path = f.path, .data = data });
            }
            return r.out;
        }
        std.debug.print("unscripted command: {s}\n", .{line});
        return error.UnscriptedCommand;
    }

    fn io(self: *Fake) Io {
        return .{ .ctx = self, .run_fn = runCmd, .sleep_fn = sleepCmd };
    }

    fn sleepCmd(ctx: *anyopaque, ms: u64) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.sleep_log[self.sleep_n] = ms;
        self.sleep_n += 1;
    }

    fn waited(self: *const Fake) []const u64 {
        return self.sleep_log[0..self.sleep_n];
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

test "a local beta: copies the user's files, runs the steps, builds, runs the output, and builds again in another directory to the same bytes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]Fake.Rule{
        .{ .needle = "/bin/buildrules init . --git https://example.invalid/r --commit " ++ "c" ** 40 },
        .{ .needle = "build --console simple -c buildrules_re.mode=local --show-output //app:bin", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr), .files = &.{.{ .path = out_path, .bytes = "ELF" }} },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = okOut("Hello, world!\n", "") },
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
    // built three times (the step's build, the expect's, the first hash) in the work directory and once more in a second one
    try t.expectEqual(@as(usize, 4), fake.count("build --console simple"));
    try t.expectEqual(@as(usize, 0), fake.count("buildrules.url_map="));
    try t.expectEqual(@as(usize, 0), fake.count("buck2 clea" ++ "n"));
    const second = try secondWorkDir(a, env.work);
    try t.expect(!std.mem.eql(u8, second, env.work));
    var in_first: usize = 0;
    var in_second: usize = 0;
    for (fake.calls.items, fake.cwds.items) |line, cwd| {
        if (std.mem.indexOf(u8, line, "build --console simple") == null) continue;
        if (std.mem.eql(u8, cwd, env.work)) in_first += 1;
        if (std.mem.eql(u8, cwd, second)) in_second += 1;
    }
    try t.expectEqual(@as(usize, 3), in_first);
    try t.expectEqual(@as(usize, 1), in_second);
    // the second place holds the repository's files (the config too), and was not made from the first's build output
    try t.expectEqualStrings("# the user's BUCK\n", try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ second, "app/BUCK" }), 1 << 10));
    try t.expect(std.mem.indexOf(u8, try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ second, ".buckconfig.local" }), 1 << 10), "mode = local") != null);
}

const flake_stderr = "Error materializing HTTP resource declared by target toolchains//:busybox_pin\n\nCaused by:\n    Timed out while making request to URI: https://busybox.net/downloads/busybox after 5 seconds\nBUILD FAILED\n";

fn failOut(stderr: []const u8) io_mod.Out {
    return .{ .code = 1, .stdout = "", .stderr = stderr };
}

test "a build that failed only because a pinned download timed out is made again, and then passes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]Fake.Rule{
        .{ .needle = "init" },
        // the very first build fails twice with the download error; the third try succeeds
        .{ .needle = "build --console simple", .out = failOut(flake_stderr), .times = 2 },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr), .files = &.{.{ .path = out_path, .bytes = "ELF" }} },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = okOut("Hello, world!\n", "") },
        .{ .needle = "buck2 kill" },
    };
    var fake = Fake{ .a = a, .rules = &rules };
    const r = try run(a, fake.io(), env.opts(.local));
    try t.expectEqual(Outcome.passed, r.outcome);
    try t.expectEqual(@as(?bool, true), r.deterministic);
    // 2 failed + 4 good ones (the step's build, the expect's, the first hash, the second directory's)
    try t.expectEqual(@as(usize, 6), fake.count("build --console simple"));
    // two retries waited the default delay, then twice it: read from the fake sleeper, never measured
    try t.expectEqualSlices(u64, &.{ 20_000, 40_000 }, fake.waited());
    // the first retry asks the same host, the second goes to the mirrors
    try t.expectEqual(@as(usize, 1), fake.count("buildrules.url_map=https://github.com/komira-ai/buildrules/releases/download/mirror-busybox-1.35.0/=https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/"));
}

test "a retry delay of zero makes the build again with no wait at all" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = failOut(flake_stderr) },
    };
    var fake = Fake{ .a = a, .rules = &rules };
    var o = env.opts(.local);
    o.retry_delay_ms = 0;
    try t.expectError(error.StepFailed, run(a, fake.io(), o));
    // still 1 + download_retries tries, and nothing waited
    try t.expectEqual(@as(usize, 4), fake.count("build --console simple"));
    try t.expectEqual(@as(usize, 0), fake.waited().len);
}

test "a download that keeps failing is red after the retries, and a compile or hash failure is not made again" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // always failing: 1 + download_retries tries, then the failure
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = failOut(flake_stderr) },
    };
    var fake = Fake{ .a = a, .rules = &rules };
    try t.expectError(error.StepFailed, run(a, fake.io(), env.opts(.local)));
    try t.expectEqual(@as(usize, 4), fake.count("build --console simple"));
    try t.expectEqual(@as(usize, 2), fake.count("buildrules.url_map="));
    // one wait before each retry, each twice the one before
    try t.expectEqualSlices(u64, &.{ 20_000, 40_000, 80_000 }, fake.waited());

    // a compile failure: one try
    var env2 = try Env.make(a, demo_steps);
    defer env2.tmp.cleanup();
    var rules2 = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = failOut("error: expected ';' after statement\nBUILD FAILED\n") },
    };
    var fake2 = Fake{ .a = a, .rules = &rules2 };
    try t.expectError(error.StepFailed, run(a, fake2.io(), env2.opts(.local)));
    try t.expectEqual(@as(usize, 1), fake2.count("build --console simple"));
    try t.expectEqual(@as(usize, 0), fake2.waited().len);

    // a test failure whose output mentions a timeout: one try (the message names no download)
    var env3 = try Env.make(a, demo_steps);
    defer env3.tmp.cleanup();
    var rules3 = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = failOut("test_net: Timed out waiting for the server\nBUILD FAILED\n") },
    };
    var fake3 = Fake{ .a = a, .rules = &rules3 };
    try t.expectError(error.StepFailed, run(a, fake3.io(), env3.opts(.local)));
    try t.expectEqual(@as(usize, 1), fake3.count("build --console simple"));

    // a wrong hash on a pin: the step is named but the cause is not the transport
    var env4 = try Env.make(a, demo_steps);
    defer env4.tmp.cleanup();
    var rules4 = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = failOut("Error materializing HTTP resource declared by target toolchains//:busybox_pin\n\nCaused by:\n    Invalid hash: expected 6e12, got 0000\n") },
    };
    var fake4 = Fake{ .a = a, .rules = &rules4 };
    try t.expectError(error.StepFailed, run(a, fake4.io(), env4.opts(.local)));
    try t.expectEqual(@as(usize, 1), fake4.count("build --console simple"));
}

test "isDownloadFlake needs both the failed download step and a transport cause" {
    try t.expect(isDownloadFlake(flake_stderr));
    try t.expect(isDownloadFlake("Error materializing HTTP resource x\nCaused by: HTTP status 503 Service Unavailable"));
    try t.expect(!isDownloadFlake("Timed out while making request"));
    try t.expect(!isDownloadFlake("Error materializing HTTP resource x\nCaused by: Invalid hash"));
    try t.expect(!isDownloadFlake(""));
}

/// What buck2 printed when a pinned download could not connect (copied from a failed run: the cause is a chain of lines, the transport
/// message is capitalised, and none of the words of the first list of causes is in it).
const connect_stderr = "Error materializing HTTP resource declared by target toolchains//:busybox_pin\n\nCaused by:\n    0: HTTP: Error sending request for url (https://busybox.net/downloads/busybox)\n    1: client error (Connect)\n    2: tcp connect error\n    3: No route to host (os error 113)\nBUILD FAILED\n";

test "isDownloadFlake reads buck2's real transport messages, whatever their case, and keeps every other failure fatal" {
    try t.expect(isDownloadFlake(connect_stderr));
    // one cause at a time, in the case buck2 writes it and in another
    const causes = [_][]const u8{ "Error sending request", "tcp connect error", "No route to host (os error 113)", "Network is unreachable (os error 101)", "Connection reset by peer", "Timed out while making request", "TIMED OUT", "connection refused" };
    for (causes) |c| {
        var buf: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "Error materializing HTTP resource x\n\nCaused by:\n    {s}\n", .{c});
        try t.expect(isDownloadFlake(text));
        var lower: [256]u8 = undefined;
        try t.expect(isDownloadFlake(std.ascii.lowerString(&lower, text)));
    }
    // the cause alone is not a download: a test that cannot connect, or a message with no failed download step
    try t.expect(!isDownloadFlake("test_net: tcp connect error\nBUILD FAILED\n"));
    try t.expect(!isDownloadFlake("Caused by:\n    3: No route to host (os error 113)\n"));
    // the failed download step with a cause that is the pin's fault stays fatal
    try t.expect(!isDownloadFlake("Error materializing HTTP resource x\n\nCaused by:\n    HTTP status 404 Not Found\n"));
    try t.expect(!isDownloadFlake("Error materializing HTTP resource x\n\nCaused by:\n    Invalid hash: expected 6e12, got 0000\n"));
}

test "a build that failed with buck2's real connect error is made again" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = failOut(connect_stderr), .times = 1 },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr), .files = &.{.{ .path = out_path, .bytes = "ELF" }} },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = okOut("Hello, world!\n", "") },
        .{ .needle = "buck2 kill" },
    };
    var fake = Fake{ .a = a, .rules = &rules };
    const r = try run(a, fake.io(), env.opts(.local));
    try t.expectEqual(Outcome.passed, r.outcome);
    // 1 failed + 4 good ones (the step's build, the expect's, the first hash, the second directory's)
    try t.expectEqual(@as(usize, 5), fake.count("build --console simple"));
}

const sync_flake_stderr = "Error materializing HTTP resource declared by target toolchains//:busybox_pin\n\nCaused by:\n    Timed out while making request to URI: https://busybox.net/downloads/busybox after 30 seconds\nbuildrules mojo sync exited 1\n";

const sync_steps =
    \\run buildrules init . --git {origin} --commit {commit}
    \\config
    \\run buildrules mojo sync
    \\build //app:bin
    \\expect //app:bin => Hello, world!
    \\
;

test "a sync step that failed only because a pinned download timed out is run again, the same command, and then passes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, sync_steps);
    defer env.tmp.cleanup();
    var rules = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "/bin/buildrules mojo sync", .out = failOut(sync_flake_stderr), .times = 2 },
        .{ .needle = "/bin/buildrules mojo sync" },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr), .files = &.{.{ .path = out_path, .bytes = "ELF" }} },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = okOut("Hello, world!\n", "") },
        .{ .needle = "buck2 kill" },
    };
    var fake = Fake{ .a = a, .rules = &rules };
    const r = try run(a, fake.io(), env.opts(.local));
    try t.expectEqual(Outcome.passed, r.outcome);
    // 2 failed + 1 good
    try t.expectEqual(@as(usize, 3), fake.count("/bin/buildrules mojo sync"));
    try t.expectEqualSlices(u64, &.{ 20_000, 40_000 }, fake.waited());
    // the CLI takes no `-c`, so every try is the same argv and no mirror flag is passed to it
    for (fake.calls.items) |c| {
        if (std.mem.indexOf(u8, c, "mojo sync") != null) try t.expectEqualStrings("/bin/buildrules mojo sync", c);
    }
    try t.expectEqual(@as(usize, 0), fake.count("buildrules.url_map="));
}

test "a sync step that keeps timing out is red after the retries, and a wrong hash, a 404 or a refused pin is not run again" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fatal = [_][]const u8{
        "Error materializing HTTP resource declared by target toolchains//:busybox_pin\n\nCaused by:\n    Invalid hash: expected 6e12, got 0000\n",
        "Error materializing HTTP resource declared by target toolchains//:busybox_pin\n\nCaused by:\n    HTTP status 404 Not Found\n",
        "buildrules: mojo sync: the pin for mopm 9.9.9 is refused: no sha256\n",
    };
    for (fatal) |text| {
        var env = try Env.make(a, sync_steps);
        defer env.tmp.cleanup();
        var rules = [_]Fake.Rule{
            .{ .needle = "init" },
            .{ .needle = "/bin/buildrules mojo sync", .out = failOut(text) },
        };
        var fake = Fake{ .a = a, .rules = &rules };
        try t.expectError(error.StepFailed, run(a, fake.io(), env.opts(.local)));
        try t.expectEqual(@as(usize, 1), fake.count("/bin/buildrules mojo sync"));
    }

    // a download that never arrives: 1 + download_retries tries, then the failure
    var env = try Env.make(a, sync_steps);
    defer env.tmp.cleanup();
    var rules = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "/bin/buildrules mojo sync", .out = failOut(sync_flake_stderr) },
    };
    var fake = Fake{ .a = a, .rules = &rules };
    try t.expectError(error.StepFailed, run(a, fake.io(), env.opts(.local)));
    try t.expectEqual(@as(usize, 4), fake.count("/bin/buildrules mojo sync"));
    try t.expectEqualSlices(u64, &.{ 20_000, 40_000, 80_000 }, fake.waited());
}

test "an output that depends on the directory it was built in is red: the second build is in another directory" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    // every build writes the directory it ran in into the binary (what a compile directory in debug info does)
    var rules = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr), .files = &.{.{ .path = out_path, .bytes = "ELF@", .embed_cwd = true }} },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = okOut("Hello, world!\n", "") },
        .{ .needle = "buck2 kill" },
    };
    var fake = Fake{ .a = a, .rules = &rules };
    try t.expectError(error.NotDeterministic, run(a, fake.io(), env.opts(.local)));
    // the same directory twice could not have seen it: the same bytes in both places is green
    var env2 = try Env.make(a, demo_steps);
    defer env2.tmp.cleanup();
    var rules2 = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr), .files = &.{.{ .path = out_path, .bytes = "ELF" }} },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = okOut("Hello, world!\n", "") },
        .{ .needle = "buck2 kill" },
    };
    var fake2 = Fake{ .a = a, .rules = &rules2 };
    const r = try run(a, fake2.io(), env2.opts(.local));
    try t.expectEqual(@as(?bool, true), r.deterministic);
}

test "the second place is made new, without buck-out, with symlinks kept, and an existing one is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("one/sub");
    try tmp.dir.makePath("one/buck-out/v2");
    try tmp.dir.writeFile(.{ .sub_path = "one/.buckconfig", .data = "x" });
    try tmp.dir.writeFile(.{ .sub_path = "one/sub/f.txt", .data = "f" });
    try tmp.dir.writeFile(.{ .sub_path = "one/buck-out/v2/out", .data = "stale" });
    try tmp.dir.symLink("sub/f.txt", "one/link", .{});
    const base = try tmp.dir.realpathAlloc(a, ".");
    const src = try std.fs.path.join(a, &.{ base, "one" });
    const dst = try secondWorkDir(a, src);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "{s}-second", .{src}), dst);
    try t.expectEqual(@as(usize, 3), try copyRepo(a, src, dst));
    try t.expectEqualStrings("f", try std.fs.cwd().readFileAlloc(a, try std.fs.path.join(a, &.{ dst, "sub/f.txt" }), 16));
    try t.expectError(error.FileNotFound, std.fs.cwd().access(try std.fs.path.join(a, &.{ dst, "buck-out" }), .{}));
    var buf: [64]u8 = undefined;
    var dd = try std.fs.cwd().openDir(dst, .{});
    defer dd.close();
    try t.expectEqualStrings("sub/f.txt", try dd.readLink("link", &buf));
    try t.expectError(error.PathAlreadyExists, copyRepo(a, src, dst));
}

test "a build that is not the same bytes in the second directory is red, and names both digests" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    // the first three builds write one content, the build in the second directory another
    var rules = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr), .files = &.{.{ .path = out_path, .bytes = "FIRST" }}, .times = 3 },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr), .files = &.{.{ .path = out_path, .bytes = "SECOND" }} },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = okOut("Hello, world!\n", "") },
        .{ .needle = "buck2 kill" },
    };
    var fake = Fake{ .a = a, .rules = &rules };
    try t.expectError(error.NotDeterministic, run(a, fake.io(), env.opts(.local)));
}

test "a build that makes a different number of outputs in the second directory is red" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try Env.make(a, demo_steps);
    defer env.tmp.cleanup();
    var rules = [_]Fake.Rule{
        .{ .needle = "init" },
        .{ .needle = "build --console simple", .out = okOut("root//app:bin " ++ out_path ++ "\n", local_stderr), .files = &.{.{ .path = out_path, .bytes = "A" }}, .times = 3 },
        .{ .needle = "build --console simple", .out = okOut("", local_stderr) },
        .{ .needle = "/buck-out/v2/art/root/app/bin", .out = okOut("Hello, world!\n", "") },
        .{ .needle = "buck2 kill" },
    };
    var fake = Fake{ .a = a, .rules = &rules };
    try t.expectError(error.NotDeterministic, run(a, fake.io(), env.opts(.local)));
}

const no_output_steps =
    \\run buildrules init . --git {origin} --commit {commit}
    \\config
    \\build //app:ci
    \\
;

test "a leg whose build declares no output is red: two empty lists would compare equal and prove nothing" {
    // The defect: the Mojo leg built `//hello:ci`, a group with no output, and its build-twice check passed having compared zero files.
    for ([_][]const u8{ "root//app:ci\n", "" }) |printed| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var env = try Env.make(a, no_output_steps);
        defer env.tmp.cleanup();
        var rules = [_]Fake.Rule{
            .{ .needle = "init" },
            .{ .needle = "build --console simple", .out = okOut(printed, local_stderr) },
            .{ .needle = "buck2 kill" },
        };
        var fake = Fake{ .a = a, .rules = &rules };
        try t.expectError(error.NoOutputsToCompare, run(a, fake.io(), env.opts(.local)));
        // it stops after the build step and the build that is hashed: no second directory was made
        try t.expectEqual(@as(usize, 2), fake.count("build --console simple"));
        try t.expectEqual(@as(usize, 0), fake.count("-second"));
        // and the same on a farm, where no second build is made at all
        var rules2 = [_]Fake.Rule{
            .{ .needle = "init" },
            .{ .needle = "build --console simple", .out = okOut(printed, farm_stderr) },
            .{ .needle = "buck2 kill" },
        };
        var fake2 = Fake{ .a = a, .rules = &rules2 };
        var env2 = try Env.make(a, no_output_steps);
        defer env2.tmp.cleanup();
        try t.expectError(error.NoOutputsToCompare, run(a, fake2.io(), env2.opts(.{ .farm = "[buildrules_re]\n" })));
    }
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
        .{ .needle = "buck2 kill" },
    };
    var fake2 = Fake{ .a = a, .rules = &rules2 };
    const r2 = try run(a, fake2.io(), env.opts(.local));
    try t.expectEqual(Outcome.passed, r2.outcome);
}
