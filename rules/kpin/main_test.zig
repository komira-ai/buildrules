//! The commands end to end: real files in a scratch directory, `main.run`,
//! and a registry on loopback for `update`. Every test is named for the
//! defect it catches.

const std = @import("std");
const fetch = @import("fetch.zig");
const fx = @import("fixtures.zig");
const main = @import("main.zig");
const registry = @import("registry.zig");
const t = std.testing;

const Run = struct { code: u8, out: []const u8, err: []const u8 };

const Env = struct {
    ar: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    dir: []const u8,
    reg: *registry.Registry,
    http: fetch.HttpFetcher,

    fn init(routes: []registry.Route) !*Env {
        const self = try t.allocator.create(Env);
        self.ar = std.heap.ArenaAllocator.init(t.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.dir = try self.tmp.dir.realpathAlloc(self.ar.allocator(), ".");
        self.reg = try registry.Registry.start(self.ar.allocator(), routes);
        self.http = .{ .allocator = self.ar.allocator() };
        return self;
    }

    fn deinit(self: *Env) void {
        self.reg.stop();
        self.tmp.cleanup();
        self.ar.deinit();
        t.allocator.destroy(self);
    }

    fn a(self: *Env) std.mem.Allocator {
        return self.ar.allocator();
    }

    fn path(self: *Env, name: []const u8) []const u8 {
        return std.fmt.allocPrint(self.a(), "{s}/{s}", .{ self.dir, name }) catch @panic("oom");
    }

    fn write(self: *Env, name: []const u8, data: []const u8) void {
        self.tmp.dir.writeFile(.{ .sub_path = name, .data = data }) catch @panic("write");
    }

    fn read(self: *Env, name: []const u8) []const u8 {
        return self.tmp.dir.readFileAlloc(self.a(), name, 1 << 20) catch @panic("read");
    }

    fn kpin(self: *Env, cmd: []const []const u8) Run {
        var argv = std.ArrayList([]const u8).empty;
        argv.appendSlice(self.a(), cmd) catch @panic("oom");
        argv.appendSlice(self.a(), &.{ "--pins", self.path("pins.toml"), "--lock", self.path("pins.lock.bzl"), "--npm", self.path("package-lock.json") }) catch @panic("oom");
        var out = std.Io.Writer.Allocating.init(self.a());
        var err = std.Io.Writer.Allocating.init(self.a());
        const code = main.run(self.a(), argv.items, &out.writer, &err.writer, &self.http);
        return .{ .code = code, .out = out.written(), .err = err.written() };
    }

    fn pkgLock(self: *Env, entries: []const fx.NpmEntry) void {
        self.write("package-lock.json", fx.packageLock(self.a(), entries) catch @panic("oom"));
    }

    fn entry(self: *Env, name: []const u8, sri: []const u8) fx.NpmEntry {
        const p = std.fmt.allocPrint(self.a(), "node_modules/{s}", .{name}) catch @panic("oom");
        const u = std.fmt.allocPrint(self.a(), "http://127.0.0.1:{d}/{s}.tgz", .{ self.reg.port, name }) catch @panic("oom");
        return .{ .path = p, .version = "1.0.0", .resolved = u, .integrity = sri };
    }
};

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

// package-lock.json entries must be https, which the loopback registry is not,
// so `update`'s npm side is tested in update_test.zig (it takes parsed packages)
// and here the npm cases start from a lock written by hand.

const tool_toml =
    \\[tool]
    \\version = "1.0.0"
    \\url = "http://127.0.0.1:PORT/tool-{version}-{platform}.bin"
    \\[tool.platform.linux-x86_64]
    \\
;

fn toolToml(e: *Env) []const u8 {
    return std.mem.replaceOwned(u8, e.a(), tool_toml, "PORT", std.fmt.allocPrint(e.a(), "{d}", .{e.reg.port}) catch @panic("oom")) catch @panic("oom");
}

const npm_entry = fx.NpmEntry{ .path = "node_modules/left-pad", .version = "1.3.0", .resolved = "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz", .integrity = fx.ABC_SRI512 };

/// A project with one pin, pinned by `update` from the registry.
fn project(e: *Env) !void {
    e.write("pins.toml", toolToml(e));
    e.pkgLock(&.{});
    const r = e.kpin(&.{ "update", "--allow-http-loopback" });
    try t.expectEqual(@as(u8, 0), r.code);
}

test "usage errors are exit 2 and print the usage" {
    var routes = [_]registry.Route{};
    const e = try Env.init(&routes);
    defer e.deinit();
    const none = e.kpin(&.{});
    try t.expectEqual(@as(u8, 2), none.code);
    try t.expect(contains(none.err, "usage: kpin"));
    try t.expectEqual(@as(u8, 2), e.kpin(&.{"frobnicate"}).code);
    try t.expectEqual(@as(u8, 2), e.kpin(&.{ "lock", "--bogus" }).code);
    try t.expectEqual(@as(u8, 2), e.kpin(&.{ "lock", "--verify" }).code);
    try t.expectEqual(@as(u8, 2), e.kpin(&.{ "check", "--only", "x" }).code);
    try t.expectEqual(@as(u8, 2), e.kpin(&.{ "update", "--max-bytes", "x" }).code);
}

test "lock and check are offline: no hash anywhere is exit 1, and nothing is written" {
    var routes = [_]registry.Route{};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", toolToml(e));
    e.pkgLock(&.{});
    const r = e.kpin(&.{"lock"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(contains(r.err, "kpin update"));
    try t.expectError(error.FileNotFound, e.tmp.dir.access("pins.lock.bzl", .{}));
    try t.expectEqual(@as(u8, 1), e.kpin(&.{"check"}).code);
    try t.expectEqual(@as(usize, 0), e.reg.hitsOf("/tool-1.0.0-linux-x86_64.bin"));
}

test "update, then lock and check agree; lock rewrites nothing" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", toolToml(e));
    e.pkgLock(&.{});
    const u = e.kpin(&.{ "update", "--allow-http-loopback" });
    try t.expectEqual(@as(u8, 0), u.code);
    try t.expect(contains(u.out, "fetched 1"));
    const first = e.read("pins.lock.bzl");
    try t.expect(contains(first, fx.ABC_SHA256));
    const l = e.kpin(&.{"lock"});
    try t.expectEqual(@as(u8, 0), l.code);
    try t.expect(contains(l.out, "up to date"));
    try t.expectEqualStrings(first, e.read("pins.lock.bzl"));
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"check"}).code);
    // check never touched the network.
    try t.expectEqual(@as(usize, 1), e.reg.hitsOf("/tool-1.0.0-linux-x86_64.bin"));
}

test "MUTANT stale lock accepted: a lock with an entry the inputs no longer ask for fails check" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    try project(e);
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"check"}).code);
    // The input drops the pin; the lock still has it.
    e.write("pins.toml", "");
    const r = e.kpin(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(contains(r.err, "stale"));
    // A hand-added blank line is stale too: the lock is what kpin writes, byte for byte.
    e.write("pins.toml", toolToml(e));
    const lock = e.read("pins.lock.bzl");
    e.write("pins.lock.bzl", std.fmt.allocPrint(e.a(), "{s}\n", .{lock}) catch @panic("oom"));
    try t.expectEqual(@as(u8, 1), e.kpin(&.{"check"}).code);
    // `lock` repairs it.
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"lock"}).code);
    try t.expectEqualStrings(lock, e.read("pins.lock.bzl"));
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"check"}).code);
}

test "a version bump without update is stale, not silently re-hashed" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    try project(e);
    const bumped = std.mem.replaceOwned(u8, e.a(), toolToml(e), "1.0.0", "1.0.1") catch @panic("oom");
    e.write("pins.toml", bumped);
    const r = e.kpin(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(contains(r.err, "kpin update"));
}

test "MUTANT changed hash for an unchanged version accepted: a hash edited in the lock is exit 3 against the base" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    try project(e);
    const good = e.read("pins.lock.bzl");
    e.write("base.lock.bzl", good);
    const evil = try fx.sha256Hex(e.a(), "evil");
    const edited = std.mem.replaceOwned(u8, e.a(), good, fx.ABC_SHA256, evil) catch @panic("oom");
    e.write("pins.lock.bzl", edited);
    // On its own the edited lock is self-consistent: inputs and lock agree.
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"check"}).code);
    // Against the lock of the merge base it is an alarm.
    const r = e.kpin(&.{ "check", "--previous", e.path("base.lock.bzl") });
    try t.expectEqual(@as(u8, 3), r.code);
    try t.expect(contains(r.err, "ALARM"));
    try t.expect(contains(r.err, evil));
    // Regenerating does not make it go away.
    try t.expectEqual(@as(u8, 3), e.kpin(&.{ "check", "--previous", e.path("base.lock.bzl") }).code);
    // An honest bump (another version) against the same base is not an alarm.
    e.write("pins.lock.bzl", good);
    try t.expectEqual(@as(u8, 0), e.kpin(&.{ "check", "--previous", e.path("base.lock.bzl") }).code);
}

test "MUTANT changed hash for an unchanged version accepted: package-lock.json with new integrity for a locked version is exit 3, from lock and from check" {
    var routes = [_]registry.Route{};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", "");
    e.pkgLock(&.{npm_entry});
    const sha = fx.ABC_SHA256;
    const lock = std.fmt.allocPrint(e.a(),
        \\KPIN_LOCK_VERSION = 1
        \\
        \\PINS = {{}}
        \\
        \\NPM = {{
        \\    "left-pad@1.3.0": {{
        \\        "name": "left-pad",
        \\        "version": "1.3.0",
        \\        "url": "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz",
        \\        "sri512": "{s}",
        \\        "sha256": "{s}",
        \\        "size": 3,
        \\    }},
        \\}}
        \\
    , .{ fx.ABC_SRI512, sha }) catch @panic("oom");
    e.write("pins.lock.bzl", lock);
    // Not byte-identical to what kpin writes (no header), so check says stale, but
    // `lock` accepts the inputs and rewrites it with the header.
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"lock"}).code);
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"check"}).code);
    // The registry now claims other bytes for 1.3.0.
    var changed = npm_entry;
    changed.integrity = try fx.sri512(e.a(), fx.ABD);
    e.pkgLock(&.{changed});
    const l = e.kpin(&.{"lock"});
    try t.expectEqual(@as(u8, 3), l.code);
    try t.expectEqual(@as(u8, 3), e.kpin(&.{"check"}).code);
    // The lock was not rewritten to the new bytes.
    try t.expect(contains(e.read("pins.lock.bzl"), fx.ABC_SRI512));
}

test "MUTANT non-deterministic output: the order of the package-lock.json entries never reaches the lock" {
    var routes = [_]registry.Route{};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", "");
    const names = [_][]const u8{ "delta", "alpha", "charlie", "bravo" };
    // Seed a lock that holds them all (as update would have written it).
    var seed = std.ArrayList(u8).empty;
    try seed.appendSlice(e.a(), "KPIN_LOCK_VERSION = 1\n\nPINS = {}\n\nNPM = {\n");
    for (names) |n| try seed.print(e.a(), "    \"{s}@1.0.0\": {{\"name\": \"{s}\", \"version\": \"1.0.0\", \"url\": \"https://r.example/{s}.tgz\", \"sri512\": \"{s}\", \"sha256\": \"{s}\", \"size\": 3}},\n", .{ n, n, n, fx.ABC_SRI512, fx.ABC_SHA256 });
    try seed.appendSlice(e.a(), "}\n");
    e.write("pins.lock.bzl", seed.items);

    var entries: [4]fx.NpmEntry = undefined;
    for (names, 0..) |n, i| entries[i] = .{ .path = std.fmt.allocPrint(e.a(), "node_modules/{s}", .{n}) catch @panic("oom"), .version = "1.0.0", .resolved = std.fmt.allocPrint(e.a(), "https://r.example/{s}.tgz", .{n}) catch @panic("oom"), .integrity = fx.ABC_SRI512 };
    e.pkgLock(&entries);
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"lock"}).code);
    const forward = e.read("pins.lock.bzl");
    // Same inputs in another order, from another starting lock.
    std.mem.reverse(fx.NpmEntry, &entries);
    e.pkgLock(&entries);
    e.write("pins.lock.bzl", seed.items);
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"lock"}).code);
    try t.expectEqualStrings(forward, e.read("pins.lock.bzl"));
    // And the lock lists them sorted.
    const a_at = std.mem.indexOf(u8, forward, "alpha@1.0.0").?;
    const b_at = std.mem.indexOf(u8, forward, "bravo@1.0.0").?;
    const c_at = std.mem.indexOf(u8, forward, "charlie@1.0.0").?;
    const d_at = std.mem.indexOf(u8, forward, "delta@1.0.0").?;
    try t.expect(a_at < b_at and b_at < c_at and c_at < d_at);
}

test "update: a newer version moves pins.toml and the lock together" {
    var routes = [_]registry.Route{
        .{ .path = "/latest", .body = "{\"version\":\"1.1.0\"}" },
        .{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC },
        .{ .path = "/tool-1.1.0-linux-x86_64.bin", .body = fx.ABD },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    const with_latest = std.fmt.allocPrint(e.a(), "{s}", .{toolToml(e)}) catch @panic("oom");
    const extra = std.fmt.allocPrint(e.a(), "latest_url = \"http://127.0.0.1:{d}/latest\"\nlatest_field = \"version\"\n", .{e.reg.port}) catch @panic("oom");
    const src = std.mem.replaceOwned(u8, e.a(), with_latest, "[tool.platform", std.fmt.allocPrint(e.a(), "{s}[tool.platform", .{extra}) catch @panic("oom")) catch @panic("oom");
    e.write("pins.toml", src);
    e.pkgLock(&.{});
    try t.expectEqual(@as(u8, 0), e.kpin(&.{ "update", "--allow-http-loopback" }).code);
    try t.expect(contains(e.read("pins.toml"), "version = \"1.1.0\""));
    try t.expect(contains(e.read("pins.lock.bzl"), try fx.sha256Hex(e.a(), fx.ABD)));
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"check"}).code);
}

test "update that finds an alarm exits 3 and leaves pins.toml and the lock as they were" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    try project(e);
    const lock = e.read("pins.lock.bzl");
    const toml = e.read("pins.toml");
    routes[0].body = fx.ABD;
    const r = e.kpin(&.{ "update", "--allow-http-loopback", "--verify" });
    try t.expectEqual(@as(u8, 3), r.code);
    try t.expectEqualStrings(lock, e.read("pins.lock.bzl"));
    try t.expectEqualStrings(toml, e.read("pins.toml"));
}

test "update without --allow-http-loopback refuses the plain-http registry" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", toolToml(e));
    e.pkgLock(&.{});
    const r = e.kpin(&.{"update"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(contains(r.err, "UrlNotAllowed"));
    try t.expectEqual(@as(usize, 0), e.reg.hitsOf("/tool-1.0.0-linux-x86_64.bin"));
}

/// The tool pin with its hash written in pins.toml, so `lock` and `check` need no network.
fn hashedToml(e: *Env) []const u8 {
    return std.fmt.allocPrint(e.a(), "{s}sha256 = \"{s}\"\nsize = 3\n", .{ toolToml(e), fx.ABC_SHA256 }) catch @panic("oom");
}

fn exists(e: *Env, name: []const u8) bool {
    e.tmp.dir.access(name, .{}) catch return false;
    return true;
}

test "lock that cannot write the lock says so, and leaves no lock behind" {
    var routes = [_]registry.Route{};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", hashedToml(e));
    e.pkgLock(&.{});
    // The file the lock is written through is a directory: the write fails, the rename never happens.
    try e.tmp.dir.makeDir("pins.lock.bzl.kpin-tmp");
    const r = e.kpin(&.{"lock"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(contains(r.err, "error: cannot write "));
    try t.expect(contains(r.err, "pins.lock.bzl: IsDir"));
    try t.expectEqual(@as(usize, 0), r.out.len);
    try t.expect(!exists(e, "pins.lock.bzl"));
}

test "a size no lock can hold is refused when the lock is rendered, by lock and by check, and nothing is written" {
    var routes = [_]registry.Route{};
    const e = try Env.init(&routes);
    defer e.deinit();
    // 2^64-1 is what the lock reader stores for a size that is not an integer, so it is never written.
    const toml = std.fmt.allocPrint(e.a(), "{s}sha256 = \"{s}\"\nsize = 18446744073709551615\n", .{ toolToml(e), fx.ABC_SHA256 }) catch @panic("oom");
    e.write("pins.toml", toml);
    e.pkgLock(&.{});
    const r = e.kpin(&.{"lock"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(contains(r.err, "error: cannot render the lock: UnsafeValue"));
    try t.expect(!exists(e, "pins.lock.bzl"));
    try t.expect(!exists(e, "pins.lock.bzl.kpin-tmp"));
    const empty_lock = "KPIN_LOCK_VERSION = 1\n\nPINS = {}\n\nNPM = {}\n";
    e.write("pins.lock.bzl", empty_lock);
    const c = e.kpin(&.{"check"});
    try t.expectEqual(@as(u8, 1), c.code);
    try t.expect(contains(c.err, "error: cannot render the lock: UnsafeValue"));
    try t.expect(!contains(c.err, "stale"));
    try t.expectEqualStrings(empty_lock, e.read("pins.lock.bzl"));
}

test "update that cannot write pins.toml or the lock says so, and the lock is not written after pins.toml failed" {
    var routes = [_]registry.Route{
        .{ .path = "/latest", .body = "{\"version\":\"1.1.0\"}" },
        .{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC },
        .{ .path = "/tool-1.1.0-linux-x86_64.bin", .body = fx.ABD },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    const extra = std.fmt.allocPrint(e.a(), "latest_url = \"http://127.0.0.1:{d}/latest\"\nlatest_field = \"version\"\n", .{e.reg.port}) catch @panic("oom");
    const src = std.mem.replaceOwned(u8, e.a(), toolToml(e), "[tool.platform", std.fmt.allocPrint(e.a(), "{s}[tool.platform", .{extra}) catch @panic("oom")) catch @panic("oom");
    e.write("pins.toml", src);
    e.pkgLock(&.{});
    // pins.toml moves to 1.1.0, but it cannot be written: neither file changes.
    try e.tmp.dir.makeDir("pins.toml.kpin-tmp");
    const r = e.kpin(&.{ "update", "--allow-http-loopback" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(contains(r.err, "error: cannot write "));
    try t.expect(contains(r.err, "pins.toml: IsDir"));
    try t.expectEqualStrings(src, e.read("pins.toml"));
    try t.expect(!exists(e, "pins.lock.bzl"));
    // The note about the move was printed before the write failed.
    try t.expect(contains(r.out, "tool: 1.0.0 -> 1.1.0"));
    // Now pins.toml can be written but the lock cannot.
    try e.tmp.dir.deleteDir("pins.toml.kpin-tmp");
    try e.tmp.dir.makeDir("pins.lock.bzl.kpin-tmp");
    const r2 = e.kpin(&.{ "update", "--allow-http-loopback" });
    try t.expectEqual(@as(u8, 1), r2.code);
    try t.expect(contains(r2.err, "pins.lock.bzl: IsDir"));
    try t.expect(!exists(e, "pins.lock.bzl"));
}

test "inputs that cannot be read stop every command with exit 1 before it writes or fetches anything" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const Case = struct { what: []const u8, file: []const u8, text: ?[]const u8, say: []const u8 };
    const cases = [_]Case{
        .{ .what = "no pins.toml", .file = "pins.toml", .text = null, .say = "error: cannot read " },
        .{ .what = "a pins.toml that is not TOML", .file = "pins.toml", .text = "[tool\n", .say = "malformed table header" },
        .{ .what = "no package-lock.json", .file = "package-lock.json", .text = null, .say = "package-lock.json: FileNotFound" },
        .{ .what = "a package-lock.json that is not JSON", .file = "package-lock.json", .text = "{", .say = "not valid JSON" },
        .{ .what = "a lock that is not a lock", .file = "pins.lock.bzl", .text = "nonsense\n", .say = "error: lock: " },
    };
    for ([_][]const []const u8{ &.{"lock"}, &.{"check"}, &.{ "update", "--allow-http-loopback" } }) |cmd| {
        for (cases) |c| {
            const e = try Env.init(&routes);
            defer e.deinit();
            e.write("pins.toml", hashedToml(e));
            e.pkgLock(&.{});
            // `check` needs a lock to read; the other two start without one.
            if (std.mem.eql(u8, cmd[0], "check")) e.write("pins.lock.bzl", "KPIN_LOCK_VERSION = 1\n\nPINS = {}\n\nNPM = {}\n");
            if (c.text) |text| e.write(c.file, text) else try e.tmp.dir.deleteFile(c.file);
            const r = e.kpin(cmd);
            if (r.code != 1 or !contains(r.err, c.say) or r.out.len != 0 or exists(e, "pins.lock.bzl.kpin-tmp") or e.reg.hitsOf("/tool-1.0.0-linux-x86_64.bin") != 0) {
                std.debug.print("{s} with {s}: exit {d}, stdout `{s}`, stderr:\n{s}\n", .{ cmd[0], c.what, r.code, r.out, r.err });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "check --previous names a base lock that cannot be read or is not a lock" {
    var routes = [_]registry.Route{};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", hashedToml(e));
    e.pkgLock(&.{});
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"lock"}).code);
    const missing = e.kpin(&.{ "check", "--previous", e.path("no-base.lock.bzl") });
    try t.expectEqual(@as(u8, 1), missing.code);
    try t.expect(contains(missing.err, "error: cannot read the lock "));
    try t.expect(contains(missing.err, "no-base.lock.bzl: FileNotFound"));
    e.write("base.lock.bzl", "nonsense\n");
    const bad = e.kpin(&.{ "check", "--previous", e.path("base.lock.bzl") });
    try t.expectEqual(@as(u8, 1), bad.code);
    try t.expect(contains(bad.err, "error: lock: "));
    try t.expectEqual(@as(usize, 0), bad.out.len);
}

test "update --only A fetches A alone: a change under B goes unseen, and is an alarm without --only" {
    var routes = [_]registry.Route{
        .{ .path = "/a-1.0.0-any.bin", .body = fx.ABC },
        .{ .path = "/b-1.0.0-any.bin", .body = fx.ABC },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    const toml = std.fmt.allocPrint(e.a(),
        \\[a]
        \\version = "1.0.0"
        \\url = "http://127.0.0.1:{d}/a-{{version}}-{{platform}}.bin"
        \\[a.platform.any]
        \\[b]
        \\version = "1.0.0"
        \\url = "http://127.0.0.1:{d}/b-{{version}}-{{platform}}.bin"
        \\[b.platform.any]
        \\
    , .{ e.reg.port, e.reg.port }) catch @panic("oom");
    e.write("pins.toml", toml);
    e.pkgLock(&.{});
    const first = e.kpin(&.{ "update", "--allow-http-loopback" });
    try t.expectEqual(@as(u8, 0), first.code);
    try t.expect(contains(first.out, "fetched 2"));
    // Both registries now serve other bytes.
    routes[0].body = fx.ABD;
    routes[1].body = fx.ABD;
    const only = e.kpin(&.{ "update", "--allow-http-loopback", "--verify", "--only", "b" });
    try t.expectEqual(@as(u8, 3), only.code);
    try t.expect(contains(only.err, "ALARM: b 1.0.0 (any)"));
    try t.expect(!contains(only.err, "ALARM: a 1.0.0"));
    try t.expectEqual(@as(usize, 1), e.reg.hitsOf("/a-1.0.0-any.bin"));
    try t.expectEqual(@as(usize, 2), e.reg.hitsOf("/b-1.0.0-any.bin"));
    const both = e.kpin(&.{ "update", "--allow-http-loopback", "--verify" });
    try t.expectEqual(@as(u8, 3), both.code);
    try t.expect(contains(both.err, "ALARM: a 1.0.0 (any)"));
    try t.expect(contains(both.err, "ALARM: b 1.0.0 (any)"));
    // The lock is still the one the first update wrote.
    try t.expect(contains(e.read("pins.lock.bzl"), fx.ABC_SHA256));
}

test "--max-bytes N refuses a download of more than N bytes, and takes one of exactly N" {
    var routes = [_]registry.Route{.{ .path = "/tool-1.0.0-linux-x86_64.bin", .body = fx.ABC }};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", toolToml(e));
    e.pkgLock(&.{});
    const small = e.kpin(&.{ "update", "--allow-http-loopback", "--max-bytes", "2" });
    try t.expectEqual(@as(u8, 1), small.code);
    try t.expect(contains(small.err, "ResponseTooLarge"));
    try t.expect(!exists(e, "pins.lock.bzl"));
    const exact = e.kpin(&.{ "update", "--allow-http-loopback", "--max-bytes", "3" });
    try t.expectEqual(@as(u8, 0), exact.code);
    try t.expect(contains(e.read("pins.lock.bzl"), fx.ABC_SHA256));
}

/// `kpin <cmd>` as `Env.kpin` runs it, but over output streams that refuse every byte (a closed pipe).
fn kpinMute(e: *Env, cmd: []const []const u8) u8 {
    var argv = std.ArrayList([]const u8).empty;
    argv.appendSlice(e.a(), cmd) catch @panic("oom");
    argv.appendSlice(e.a(), &.{ "--pins", e.path("pins.toml"), "--lock", e.path("pins.lock.bzl"), "--npm", e.path("package-lock.json") }) catch @panic("oom");
    var none: [0]u8 = undefined;
    var out = std.Io.Writer.fixed(&none);
    var err = std.Io.Writer.fixed(&none);
    return main.run(e.a(), argv.items, &out, &err, &e.http);
}

test "a stdout or stderr that cannot be written to changes no exit status and no file" {
    var routes = [_]registry.Route{
        .{ .path = "/latest", .body = "{\"version\":\"1.1.0\"}" },
        .{ .path = "/tool-1.1.0-linux-x86_64.bin", .body = fx.ABC },
    };
    const e = try Env.init(&routes);
    defer e.deinit();
    const extra = std.fmt.allocPrint(e.a(), "latest_url = \"http://127.0.0.1:{d}/latest\"\nlatest_field = \"version\"\n", .{e.reg.port}) catch @panic("oom");
    e.write("pins.toml", std.mem.replaceOwned(u8, e.a(), toolToml(e), "[tool.platform", std.fmt.allocPrint(e.a(), "{s}[tool.platform", .{extra}) catch @panic("oom")) catch @panic("oom"));
    e.pkgLock(&.{});
    // update prints the version it moved to and what it fetched; pins.toml and the lock are written all the same.
    try t.expectEqual(@as(u8, 0), kpinMute(e, &.{ "update", "--allow-http-loopback" }));
    const pins_now = e.read("pins.toml");
    try t.expect(contains(pins_now, "version = \"1.1.0\""));
    const good = e.read("pins.lock.bzl");
    try t.expect(contains(good, fx.ABC_SHA256));
    // "up to date" and the check's confirmation are lost; the status is still 0.
    try t.expectEqual(@as(u8, 0), kpinMute(e, &.{"lock"}));
    try t.expectEqual(@as(u8, 0), kpinMute(e, &.{"check"}));
    // "wrote" is lost too, and the repaired lock is written.
    e.write("pins.lock.bzl", std.fmt.allocPrint(e.a(), "{s}\n", .{good}) catch @panic("oom"));
    try t.expectEqual(@as(u8, 0), kpinMute(e, &.{"lock"}));
    try t.expectEqualStrings(good, e.read("pins.lock.bzl"));
    // An error nobody can read is still exit 1, an alarm still 3, a usage error still 2.
    e.write("pins.toml", "");
    try t.expectEqual(@as(u8, 1), kpinMute(e, &.{"check"}));
    e.write("pins.toml", pins_now);
    e.write("base.lock.bzl", good);
    const evil = try fx.sha256Hex(e.a(), "evil");
    e.write("pins.lock.bzl", std.mem.replaceOwned(u8, e.a(), good, fx.ABC_SHA256, evil) catch @panic("oom"));
    try t.expectEqual(@as(u8, 3), kpinMute(e, &.{ "check", "--previous", e.path("base.lock.bzl") }));
    try t.expectEqual(@as(u8, 2), kpinMute(e, &.{"frobnicate"}));
}

test "--npm is repeatable: the lockfiles are one set, and two that disagree about a version's bytes are refused" {
    var routes = [_]registry.Route{};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", "");
    e.pkgLock(&.{npm_entry});
    const other = fx.NpmEntry{ .path = "node_modules/other", .version = "2.0.0", .resolved = "https://registry.npmjs.org/other/-/other-2.0.0.tgz", .integrity = fx.ABC_SRI512 };
    e.write("second-lock.json", fx.packageLock(e.a(), &.{other}) catch @panic("oom"));
    const seed = std.fmt.allocPrint(e.a(),
        \\KPIN_LOCK_VERSION = 1
        \\
        \\PINS = {{}}
        \\
        \\NPM = {{
        \\    "left-pad@1.3.0": {{"name": "left-pad", "version": "1.3.0", "url": "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz", "sri512": "{s}", "sha256": "{s}", "size": 3}},
        \\    "other@2.0.0": {{"name": "other", "version": "2.0.0", "url": "https://registry.npmjs.org/other/-/other-2.0.0.tgz", "sri512": "{s}", "sha256": "{s}", "size": 3}},
        \\}}
        \\
    , .{ fx.ABC_SRI512, fx.ABC_SHA256, fx.ABC_SRI512, fx.ABC_SHA256 }) catch @panic("oom");
    e.write("pins.lock.bzl", seed);
    const both = e.kpin(&.{ "lock", "--npm", e.path("second-lock.json") });
    try t.expectEqual(@as(u8, 0), both.code);
    try t.expect(contains(both.out, "2 npm packages"));
    try t.expect(contains(e.read("pins.lock.bzl"), "other@2.0.0"));
    // Only the first lockfile: `other` is no longer wanted, and the lock is stale.
    try t.expectEqual(@as(u8, 1), e.kpin(&.{"check"}).code);
    // The same version with other bytes in the second file.
    var changed = npm_entry;
    changed.integrity = try fx.sri512(e.a(), fx.ABD);
    e.write("second-lock.json", fx.packageLock(e.a(), &.{changed}) catch @panic("oom"));
    const clash = e.kpin(&.{ "lock", "--npm", e.path("second-lock.json") });
    try t.expectEqual(@as(u8, 1), clash.code);
    try t.expect(contains(clash.err, "left-pad@1.3.0 appears with two different integrities"));
}

test "flags that belong to update are usage errors for lock and check, a number that does not fit is a usage error, and a lock path that is a directory is a read error" {
    var routes = [_]registry.Route{};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", hashedToml(e));
    e.pkgLock(&.{});
    for ([_][]const u8{ "lock", "check" }) |cmd| {
        const r = e.kpin(&.{ cmd, "--allow-http-loopback" });
        try t.expectEqual(@as(u8, 2), r.code);
        try t.expect(contains(r.err, "kpin: WrongCommand"));
    }
    for ([_][]const u8{ "99999999999999999999999", "-1", "" }) |n| {
        const r = e.kpin(&.{ "update", "--max-bytes", n });
        try t.expectEqual(@as(u8, 2), r.code);
        try t.expect(contains(r.err, "kpin: BadNumber"));
    }
    // A lock path that exists but is not a file is not "no lock yet": it is an error, whatever the command.
    try e.tmp.dir.makeDir("pins.lock.bzl");
    for ([_][]const []const u8{ &.{"lock"}, &.{"check"}, &.{ "update", "--allow-http-loopback" } }) |cmd| {
        const r = e.kpin(cmd);
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(contains(r.err, "error: cannot read the lock "));
        try t.expect(contains(r.err, "IsDir"));
    }
}

test "a lock without the sections render writes is stale, not accepted" {
    var routes = [_]registry.Route{};
    const e = try Env.init(&routes);
    defer e.deinit();
    e.write("pins.toml", "");
    e.pkgLock(&.{});
    e.write("pins.lock.bzl", "KPIN_LOCK_VERSION = 1\n");
    const r = e.kpin(&.{"check"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(contains(r.err, "is stale"));
    // `lock` writes the sections.
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"lock"}).code);
    try t.expect(contains(e.read("pins.lock.bzl"), "PINS = {}"));
    try t.expectEqual(@as(u8, 0), e.kpin(&.{"check"}).code);
}
