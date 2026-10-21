//! HELD: builds the three `unpack` programs, checks them against the pins, and publishes them as the assets of a release of this repository. Run by the repository
//! owner (or on their go); never by CI. Nothing in the default build uses the assets: until they exist, the rows of rules/pins/bootstrap.bzl cannot be fetched on a
//! machine whose cache lacks them.
//!
//!     publish_unpack             dry run: builds the programs, checks them against rules/pins/bootstrap.bzl, reads the release, says what --apply would do.
//!                                Changes nothing on GitHub (it reads the release's asset names with a GET).
//!     publish_unpack --apply --work DIR
//!                                the same, then creates the release (if absent), uploads the assets it does not hold, downloads each asset again and checks it
//!                                against the pin.
//!
//! Options: --root DIR (the repository root, default .), --buck2 PATH (default `buck2`), --gh PATH (default `gh`), --work DIR (scratch for --apply: it must exist,
//! and is where the uploaded copies and the downloads go).
//!
//! It never replaces an asset and never deletes a release or an asset: an asset that is already there is only verified, a stray asset is reported with the command
//! that would remove it (which the owner runs), and the flags that replace or force are never passed. If the programs the tree builds are not the pinned ones (the
//! source changed without new rows, or the rows were typed wrong) nothing is uploaded: the text says which values to write, and the new programs go under the next tag.
const std = @import("std");
const pins = @import("bootstrap_pins");

pub const repo = "komira-ai/buildrules";

/// What running a program gave: its exit status and what it wrote to standard output.
pub const Ran = struct { code: u8, out: []u8 };

/// How programs are run; the tests replace it with a recorder.
pub const Runner = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, a: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) anyerror!Ran,

    pub fn run(self: Runner, a: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !Ran {
        return self.runFn(self.ctx, a, argv, cwd);
    }
};

/// Where the text for the owner goes; the tests replace it with a buffer.
pub const Say = struct {
    ctx: *anyopaque,
    sayFn: *const fn (ctx: *anyopaque, line: []const u8) void,

    fn say(self: Say, a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
        const line = std.fmt.allocPrint(a, fmt, args) catch return;
        defer a.free(line);
        self.sayFn(self.ctx, line);
    }
};

pub const Options = struct {
    apply: bool = false,
    root: []const u8 = ".",
    buck2: []const u8 = "buck2",
    gh: []const u8 = "gh",
    work: ?[]const u8 = null,
};

pub fn parse(args: []const []const u8, diag: *[]const u8) !Options {
    var o = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--apply")) {
            o.apply = true;
            continue;
        }
        i += 1;
        if (i >= args.len) return fail(diag, "an option has no value");
        if (std.mem.eql(u8, arg, "--root")) {
            o.root = args[i];
        } else if (std.mem.eql(u8, arg, "--buck2")) {
            o.buck2 = args[i];
        } else if (std.mem.eql(u8, arg, "--gh")) {
            o.gh = args[i];
        } else if (std.mem.eql(u8, arg, "--work")) {
            o.work = args[i];
        } else {
            return fail(diag, "unknown argument (only --apply, --root, --buck2, --gh, --work)");
        }
    }
    if (o.apply and o.work == null) return fail(diag, "--apply needs --work DIR (an existing directory for the copies and the downloads)");
    return o;
}

fn fail(diag: *[]const u8, text: []const u8) error{Usage} {
    diag.* = text;
    return error.Usage;
}

fn target(a: std.mem.Allocator, host: []const u8) ![]u8 {
    const t = try a.dupe(u8, host);
    for (t) |*c| {
        if (c.* == '-') c.* = '_';
    }
    defer a.free(t);
    return std.fmt.allocPrint(a, "//tools/bootstrap:unpack_{s}", .{t});
}

fn assetName(a: std.mem.Allocator, host: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "unpack-{s}", .{host});
}

/// The path `buck2 build --show-full-output` printed for `label`: its lines are `<label> <path>`.
fn builtPath(out: []const u8, label: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        const l = std.mem.trimRight(u8, line, "\r");
        const at = std.mem.indexOf(u8, l, label) orelse continue;
        const rest = l[at + label.len ..];
        if (rest.len < 2 or rest[0] != ' ') continue;
        return std.mem.trim(u8, rest, " ");
    }
    return null;
}

fn hashFile(path: []const u8) !struct { sha256: [64]u8, size: u64 } {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var size: u64 = 0;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        h.update(buf[0..n]);
        size += n;
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    return .{ .sha256 = std.fmt.bytesToHex(d, .lower), .size = size };
}

/// The asset names the release holds, one per line of `out`.
fn contains(out: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \r"), name)) return true;
    }
    return false;
}

/// Runs the steps and returns the exit status: 0 done (or, in a dry run, ready), 1 the programs are not the pinned ones or an asset does not verify, 2 the
/// repository or the tools are not as expected.
pub fn publish(a: std.mem.Allocator, o: Options, r: Runner, say: Say) !u8 {
    const table_path = try std.fs.path.join(a, &.{ o.root, "rules/pins/bootstrap.bzl" });
    defer a.free(table_path);
    const table = std.fs.cwd().readFileAlloc(a, table_path, 1 << 20) catch {
        say.say(a, "cannot read {s}", .{table_path});
        return 2;
    };
    defer a.free(table);
    const tag = pins.tag(table) orelse {
        say.say(a, "{s} has no UNPACK_TAG", .{table_path});
        return 2;
    };

    // 1. build
    const host_text = try std.mem.join(a, ", ", &pins.hosts);
    defer a.free(host_text);
    say.say(a, "1. build the programs for {s} (the farm builds them; the same bytes on every worker)", .{host_text});
    var labels = std.ArrayList([]u8).empty;
    defer {
        for (labels.items) |s| a.free(s);
        labels.deinit(a);
    }
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ o.buck2, "build", "--show-full-output", "--" });
    for (pins.hosts) |h| {
        try labels.append(a, try target(a, h));
        try argv.append(a, labels.items[labels.items.len - 1]);
    }
    const built_run = try r.run(a, argv.items, o.root);
    defer a.free(built_run.out);
    if (built_run.code != 0) {
        say.say(a, "the build failed (exit {d}); nothing was changed", .{built_run.code});
        return 2;
    }

    // 2. verify against the pins
    say.say(a, "2. hash them and compare with rules/pins/bootstrap.bzl", .{});
    var builts = std.ArrayList(pins.Built).empty;
    defer builts.deinit(a);
    var paths = std.ArrayList([]u8).empty;
    defer {
        for (paths.items) |p| a.free(p);
        paths.deinit(a);
    }
    for (pins.hosts, 0..) |h, i| {
        const label = labels.items[i];
        const rel = builtPath(built_run.out, label) orelse {
            say.say(a, "the build printed no path for {s}", .{label});
            return 2;
        };
        const abs = if (std.fs.path.isAbsolute(rel)) try a.dupe(u8, rel) else try std.fs.path.join(a, &.{ o.root, rel });
        try paths.append(a, abs);
        const hf = hashFile(abs) catch {
            say.say(a, "cannot read {s}", .{abs});
            return 2;
        };
        try builts.append(a, .{ .host = h, .sha256 = hf.sha256, .size = hf.size });
        say.say(a, "   {s}: {d} bytes, sha256 {s}", .{ h, hf.size, &hf.sha256 });
    }
    var findings = try pins.check(a, table, builts.items);
    defer {
        for (findings.items) |f| a.free(f);
        findings.deinit(a);
    }
    if (findings.items.len > 0) {
        for (findings.items) |f| say.say(a, "   {s}", .{f});
        say.say(a, "the programs this tree builds are not the pinned ones. Nothing was uploaded.", .{});
        return 1;
    }

    // 3. the release
    say.say(a, "3. the release {s} on {s}", .{ tag, repo });
    const api = try std.fmt.allocPrint(a, "repos/{s}/releases/tags/{s}", .{ repo, tag });
    defer a.free(api);
    const names_run = try r.run(a, &.{ o.gh, "api", api, "--jq", ".assets[].name" }, o.root);
    defer a.free(names_run.out);
    const exists = names_run.code == 0;
    if (exists) {
        say.say(a, "   it exists; its assets: {s}", .{if (std.mem.trim(u8, names_run.out, " \r\n").len == 0) "none" else std.mem.trim(u8, names_run.out, " \r\n")});
    } else {
        say.say(a, "   it could not be read (it may not exist yet, or gh is not logged in)", .{});
    }
    if (exists) {
        var it = std.mem.splitScalar(u8, names_run.out, '\n');
        while (it.next()) |line| {
            const name = std.mem.trim(u8, line, " \r");
            if (name.len == 0) continue;
            var expected = false;
            for (pins.hosts) |h| {
                const want = try assetName(a, h);
                defer a.free(want);
                if (std.mem.eql(u8, want, name)) expected = true;
            }
            if (!expected) {
                say.say(a, "WARNING: the release {s} holds an asset named '{s}', which no pin names. This tool never deletes. To remove it, run:", .{ tag, name });
                say.say(a, "  gh release delete-asset {s} '{s}' --repo {s}", .{ tag, name, repo });
            }
        }
    }

    if (!o.apply) {
        say.say(a, "dry run: with --apply this would {s}upload the assets the release lacks (never replacing one), then download each asset again and verify it against the pin. Nothing was changed.", .{if (exists) "" else "create the release, "});
        return 0;
    }

    const work = o.work.?;
    if (!exists) {
        say.say(a, "   creating the release (not marked latest)", .{});
        const notes = try std.fmt.allocPrint(a, "The unpack programs pinned by rules/pins/bootstrap.bzl, one per host. Do not replace an asset: a new program goes under the next tag.", .{});
        defer a.free(notes);
        const c = try r.run(a, &.{ o.gh, "release", "create", tag, "--repo", repo, "--target", "main", "--latest=false", "--title", "unpack programs", "--notes", notes }, o.root);
        defer a.free(c.out);
        if (c.code != 0) {
            say.say(a, "gh release create failed (exit {d}); nothing was uploaded", .{c.code});
            return 2;
        }
    }
    say.say(a, "4. the assets", .{});
    for (pins.hosts, 0..) |h, i| {
        const name = try assetName(a, h);
        defer a.free(name);
        if (exists and contains(names_run.out, name)) {
            say.say(a, "   {s} is already there; it is not replaced, only verified below", .{name});
            continue;
        }
        const copy = try std.fs.path.join(a, &.{ work, name });
        defer a.free(copy);
        std.fs.cwd().copyFile(paths.items[i], std.fs.cwd(), copy, .{}) catch {
            say.say(a, "cannot copy {s} to {s} (does --work exist?)", .{ paths.items[i], copy });
            return 2;
        };
        const u = try r.run(a, &.{ o.gh, "release", "upload", tag, copy, "--repo", repo }, o.root);
        defer a.free(u.out);
        if (u.code != 0) {
            say.say(a, "gh release upload of {s} failed (exit {d})", .{ name, u.code });
            return 2;
        }
        say.say(a, "   uploaded {s}", .{name});
    }

    say.say(a, "5. download each asset again and verify it (the gate)", .{});
    for (pins.hosts, 0..) |h, i| {
        const name = try assetName(a, h);
        defer a.free(name);
        const dir = try std.fs.path.join(a, &.{ work, "verify", name });
        defer a.free(dir);
        std.fs.cwd().makePath(dir) catch {
            say.say(a, "cannot make {s}", .{dir});
            return 2;
        };
        const d = try r.run(a, &.{ o.gh, "release", "download", tag, "--repo", repo, "--pattern", name, "--dir", dir }, o.root);
        defer a.free(d.out);
        if (d.code != 0) {
            say.say(a, "the asset {s} cannot be downloaded (exit {d}); the pinned url does not resolve", .{ name, d.code });
            return 1;
        }
        const got_path = try std.fs.path.join(a, &.{ dir, name });
        defer a.free(got_path);
        const got = hashFile(got_path) catch {
            say.say(a, "the download of {s} left no file", .{name});
            return 1;
        };
        if (!std.mem.eql(u8, &got.sha256, &builts.items[i].sha256) or got.size != builts.items[i].size) {
            say.say(a, "the asset {s} does not match the pin: {d} bytes, sha256 {s}", .{ name, got.size, &got.sha256 });
            return 1;
        }
        say.say(a, "   {s} matches the pin: {d} bytes, sha256 {s}", .{ name, got.size, &got.sha256 });
    }
    say.say(a, "done: the urls of rules/pins/bootstrap.bzl now resolve.", .{});
    return 0;
}

const RealRunner = struct {
    fn run(_: *anyopaque, a: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) anyerror!Ran {
        const res = try std.process.Child.run(.{ .allocator = a, .argv = argv, .cwd = cwd, .max_output_bytes = 1 << 24 });
        defer a.free(res.stderr);
        if (res.stderr.len > 0) std.debug.print("{s}", .{res.stderr});
        const code: u8 = switch (res.term) {
            .Exited => |c| c,
            else => 255,
        };
        return .{ .code = code, .out = res.stdout };
    }
};

const Stdout = struct {
    fn say(_: *anyopaque, line: []const u8) void {
        std.debug.print("{s}\n", .{line});
    }
};

pub fn main() u8 {
    const a = std.heap.smp_allocator;
    const args = std.process.argsAlloc(a) catch return 2;
    defer std.process.argsFree(a, args);
    const rest = a.alloc([]const u8, args.len - 1) catch return 2;
    defer a.free(rest);
    for (args[1..], rest) |arg, *slot| slot.* = arg;
    var diag: []const u8 = "";
    const o = parse(rest, &diag) catch {
        std.debug.print("publish_unpack: {s}\n", .{diag});
        return 2;
    };
    var unused: u8 = 0;
    const runner = Runner{ .ctx = &unused, .runFn = RealRunner.run };
    const say = Say{ .ctx = &unused, .sayFn = Stdout.say };
    return publish(a, o, runner, say) catch |e| {
        std.debug.print("publish_unpack: {s}\n", .{@errorName(e)});
        return 2;
    };
}
