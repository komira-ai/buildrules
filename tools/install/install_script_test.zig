//! Runs site/static/install.sh (under the busybox `sh` this test runs beside: it is the one shell script of the project, because `curl | sh` needs one)
//! against fake releases served over loopback, and then plants defects in copies of the script and requires the same checks to go red for each.
//!
//! The script runs the way a user's does, on a PATH this test builds for it: the busybox applets it needs (awk, tar, mktemp, mkdir, cp, chmod, mv, rm,
//! sha256sum) and the stand-ins of fakes.zig (`curl`, a `uname` that reports a chosen platform, a `shasum`, a `cosign`). The server is this file's: it
//! answers the paths GitHub's release pages do (`/latest` redirects to `/tag/v<newest>`, `/download/v<version>/<file>`) and logs every request path.
//! Nothing here reaches the network.
//!
//! What it proves of the script under test:
//!   - the success path installs a runnable program: from an explicit version (with and without v), from /latest, into --prefix, with the script on stdin as
//!     in `curl | sh`; it creates no file but <prefix>/bin/buildrules, leaves no temporary directory, and prints the PATH line;
//!   - each uname -s / -m pair the script maps fetches that platform's tarball (`buildrules-cli-<V>-<target>.tar.gz`) and SHA256SUMS;
//!   - an unsupported platform, and Intel macOS by name, are refused before any request, and so is a version that is not one, an unknown option, an option
//!     without a value, and a missing curl or sha256 tool; --help prints the options and installs nothing;
//!   - a tarball whose sha256 is not the one in SHA256SUMS is refused and an existing install survives (also through the shasum fallback); a SHA256SUMS that
//!     lacks the tarball, lists it twice, has a short or non-hex entry, or is missing is refused with the reason; a tarball without the program is refused; a
//!     program that does not report the version it was released as is refused; no release at all is refused;
//!   - --verify runs `cosign verify-blob` on the tarball with its bundle, the release workflow's identity and the issuer; a cosign that refuses stops the
//!     install, a missing cosign or a missing bundle stops it, and without --verify cosign is never run.
//! The standing step then plants defects in copies of the script (a skipped sha check, any platform accepted, Intel Macs sent to the Apple silicon file or to a
//! file that is not released, a skipped version check, wrong platform mappings, "latest" not resolved, a verification that is skipped, ignored or aimed at
//! the wrong identity, ...) and requires a failing check for every one of them.
//!
//! The standing limit: the real curl is not on the PATH of a build action, so the HTTP client is fakes.zig's. What it leaves untested is curl itself and the
//! TLS to GitHub; the release workflow's own steps and the live smoke test of the site are where a real curl meets the real URL.

const std = @import("std");
const Allocator = std.mem.Allocator;

const targets = [_][]const u8{ "linux-x86_64", "linux-aarch64", "macos-arm64" };
const signer = "https://github.com/komira-ai/buildrules/.github/workflows/release.yml@refs/heads/main";
const issuer = "https://token.actions.githubusercontent.com";

// ---- small helpers --------------------------------------------------------------------------------------------------------------------------------------

fn getenv(a: Allocator, name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(a, name) catch |e| {
        std.debug.print("{s} is not in the environment (the zig_test's data / exec_tools)\n", .{name});
        return e;
    };
}

fn join(a: Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(a, parts);
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn readFile(a: Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(a, path, 1 << 28);
}

fn writeFileMode(path: []const u8, bytes: []const u8, mode: std.fs.File.Mode) !void {
    if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
    const f = try std.fs.cwd().createFile(path, .{ .mode = mode });
    defer f.close();
    try f.writeAll(bytes);
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    try writeFileMode(path, bytes, 0o644);
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn sha256Hex(a: Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(a, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// The first directory of this process's PATH that holds `name`, as `<dir>/<name>`.
fn findInPath(a: Allocator, name: []const u8) ![]u8 {
    const path = try getenv(a, "PATH");
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try join(a, &.{ dir, name });
        if (exists(candidate)) return candidate;
    }
    std.debug.print("{s} is not on the PATH of this test ({s})\n", .{ name, path });
    return error.ToolMissing;
}

const Ran = struct { code: i32, text: []const u8 };

/// Runs `argv` with exactly `env`, optionally feeding `stdin_bytes`; the text is stdout then stderr.
fn runProc(a: Allocator, argv: []const []const u8, env: *const std.process.EnvMap, stdin_bytes: ?[]const u8) !Ran {
    var child = std.process.Child.init(argv, a);
    child.env_map = env;
    child.stdin_behavior = if (stdin_bytes != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    if (stdin_bytes) |b| {
        child.stdin.?.writeAll(b) catch {};
        child.stdin.?.close();
        child.stdin = null;
    }
    var so = std.ArrayList(u8).init(a);
    var se = std.ArrayList(u8).init(a);
    // A script that loops and prints for ever is a failed run, not a crashed test.
    child.collectOutput(&so, &se, 1 << 20) catch {
        _ = child.kill() catch {};
        return .{ .code = -2, .text = "the output was longer than 1 MiB" };
    };
    const term = try child.wait();
    const code: i32 = switch (term) {
        .Exited => |c| c,
        else => -1,
    };
    return .{ .code = code, .text = try std.mem.concat(a, u8, &.{ so.items, se.items }) };
}

// ---- a loopback stand-in for GitHub releases ------------------------------------------------------------------------------------------------------------

/// GET /latest redirects to /tag/v<newest directory name under root>; GET /download/v<version>/<file> serves root/<version>/<file>; GET /tag/* is an
/// empty 200; anything else is 404. Every request path is logged.
const Server = struct {
    root: []const u8,
    listener: std.net.Server,
    thread: std.Thread,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Thread.Mutex = .{},
    log: std.ArrayList([]const u8),

    fn start(a: Allocator, root: []const u8) !*Server {
        const s = try a.create(Server);
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        s.* = .{
            .root = root,
            .listener = try addr.listen(.{ .reuse_address = true }),
            .thread = undefined,
            .log = std.ArrayList([]const u8).init(std.heap.page_allocator),
        };
        s.thread = try std.Thread.spawn(.{}, loop, .{s});
        return s;
    }

    fn base(s: *Server, a: Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}", .{s.listener.listen_address.getPort()});
    }

    fn stop(s: *Server) void {
        s.stopping.store(true, .release);
        if (std.net.tcpConnectToAddress(s.listener.listen_address)) |c| c.close() else |_| {}
        s.thread.join();
        s.listener.deinit();
    }

    fn clear(s: *Server) void {
        s.mutex.lock();
        defer s.mutex.unlock();
        s.log.clearRetainingCapacity();
    }

    fn requested(s: *Server, path: []const u8) bool {
        s.mutex.lock();
        defer s.mutex.unlock();
        for (s.log.items) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    fn requestCount(s: *Server) usize {
        s.mutex.lock();
        defer s.mutex.unlock();
        return s.log.items.len;
    }

    fn loop(s: *Server) void {
        while (true) {
            const conn = s.listener.accept() catch return;
            if (s.stopping.load(.acquire)) {
                conn.stream.close();
                return;
            }
            s.handle(conn.stream) catch {};
            conn.stream.close();
        }
    }

    fn send(stream: std.net.Stream, status: []const u8, extra: []const u8, body: []const u8) !void {
        var buf: [512]u8 = undefined;
        const head = try std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\n{s}Content-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, extra, body.len });
        try stream.writeAll(head);
        try stream.writeAll(body);
    }

    fn handle(s: *Server, stream: std.net.Stream) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var buf: [8192]u8 = undefined;
        var n: usize = 0;
        while (std.mem.indexOf(u8, buf[0..n], "\r\n\r\n") == null) {
            if (n == buf.len) return;
            const k = try stream.read(buf[n..]);
            if (k == 0) return;
            n += k;
        }
        const line_end = std.mem.indexOf(u8, buf[0..n], "\r\n").?;
        var parts = std.mem.splitScalar(u8, buf[0..line_end], ' ');
        _ = parts.next();
        const path = parts.next() orelse return;
        {
            s.mutex.lock();
            defer s.mutex.unlock();
            try s.log.append(try std.heap.page_allocator.dupe(u8, path));
        }

        if (std.mem.eql(u8, path, "/latest")) {
            var dir = std.fs.cwd().openDir(s.root, .{ .iterate = true }) catch return send(stream, "404 Not Found", "", "");
            defer dir.close();
            var newest: ?[]const u8 = null;
            var it = dir.iterate();
            while (try it.next()) |e| {
                if (e.kind != .directory) continue;
                if (newest == null or std.mem.lessThan(u8, newest.?, e.name)) newest = try a.dupe(u8, e.name);
            }
            const v = newest orelse return send(stream, "404 Not Found", "", "");
            const loc = try std.fmt.allocPrint(a, "Location: /tag/v{s}\r\n", .{v});
            return send(stream, "302 Found", loc, "");
        }
        if (std.mem.startsWith(u8, path, "/tag/")) return send(stream, "200 OK", "", "");
        var segs = std.mem.splitScalar(u8, path, '/');
        _ = segs.next();
        const dl = segs.next() orelse "";
        const tag = segs.next() orelse "";
        const file = segs.next() orelse "";
        if (std.mem.eql(u8, dl, "download") and tag.len > 1 and tag[0] == 'v' and file.len > 0 and segs.next() == null and
            std.mem.indexOf(u8, tag, "..") == null and std.mem.indexOf(u8, file, "..") == null)
        {
            const p = try join(a, &.{ s.root, tag[1..], file });
            if (std.fs.cwd().readFileAlloc(a, p, 64 << 20)) |bytes| {
                return send(stream, "200 OK", "", bytes);
            } else |_| {}
        }
        return send(stream, "404 Not Found", "", "");
    }
};

// ---- the fake releases and the PATHs, built once ---------------------------------------------------------------------------------------------------------

const TarKind = enum { honest, tampered, no_program };
const SumsMode = enum { honest, no_tarball, twice, short, non_hex, none };
const PathKind = enum { base, no_curl, no_sum, shasum, cosign };

const Release = struct { root: []const u8, srv: *Server, base: []const u8 };

const Fx = struct {
    a: Allocator,
    work: []const u8, // BUILDRULES_TEST_WORK
    fakes: []const u8, // the fakes.zig program, executable, in work
    fakes_bytes: []const u8,
    sh: []const u8, // an absolute path to a POSIX sh
    seq: usize = 0,
    paths: [5][]const u8 = undefined, // by PathKind

    main: Release = undefined, // 1.2.3 and 1.0.0, honest, with bundles
    tampered: Release = undefined, // 1.2.3: tarballs whose bytes are not the ones SHA256SUMS lists
    no_program: Release = undefined, // 1.2.3: tarballs that hold no program
    no_tarball: Release = undefined, // SHA256SUMS lists the source archive only
    twice: Release = undefined, // SHA256SUMS lists every file twice
    short: Release = undefined, // an entry of 63 digits
    non_hex: Release = undefined, // an entry with a character that is not a hex digit
    no_sums: Release = undefined, // no SHA256SUMS
    no_bundle: Release = undefined, // honest, no .sigstore.json
    empty: Release = undefined, // no release at all

    fn tarballs(fx: *Fx, dir: []const u8, ver: []const u8, kind: TarKind) !void {
        const a = fx.a;
        for (targets) |t| {
            fx.seq += 1;
            const name = try std.fmt.allocPrint(a, "buildrules-cli-{s}-{s}", .{ ver, t });
            const stage = try join(a, &.{ fx.work, "stage", try std.fmt.allocPrint(a, "{d}", .{fx.seq}) });
            const pkg = try join(a, &.{ stage, name });
            try std.fs.cwd().makePath(pkg);
            try writeFile(try join(a, &.{ pkg, "LICENSE" }), "license\n");
            switch (kind) {
                .honest => try writeFileMode(try join(a, &.{ pkg, "buildrules" }), fx.fakes_bytes, 0o755),
                .tampered => try writeFileMode(try join(a, &.{ pkg, "buildrules" }), try std.mem.concat(a, u8, &.{ fx.fakes_bytes, "tampered" }), 0o755),
                .no_program => {},
            }
            const out = try join(a, &.{ dir, try std.fmt.allocPrint(a, "{s}.tar.gz", .{name}) });
            try std.fs.cwd().makePath(dir);
            var env = std.process.EnvMap.init(a);
            try env.put("PATH", try getenv(a, "PATH"));
            const tar = try findInPath(a, "tar");
            const r = try runProc(a, &.{ tar, "-czf", out, "-C", stage, name }, &env, null);
            if (r.code != 0) {
                std.debug.print("tar -czf failed: {s}\n", .{r.text});
                return error.ToolFailed;
            }
        }
    }

    /// SHA256SUMS over the files of `dir` that are not bundles, the way the release writes it: `<sha256>  <name>`, in name order.
    fn sums(fx: *Fx, dir: []const u8, mode: SumsMode) !void {
        const a = fx.a;
        const path = try join(a, &.{ dir, "SHA256SUMS" });
        std.fs.cwd().deleteFile(path) catch {};
        if (mode == .none) return;
        var names = std.ArrayList([]const u8).init(a);
        var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
        defer d.close();
        var it = d.iterate();
        while (try it.next()) |e| {
            if (e.kind != .file or contains(e.name, ".sigstore.json") or std.mem.eql(u8, e.name, "SHA256SUMS")) continue;
            try names.append(try a.dupe(u8, e.name));
        }
        std.mem.sort([]const u8, names.items, {}, lessThan);
        var text = std.ArrayList(u8).init(a);
        for (names.items) |n| {
            const is_source = !contains(n, "-cli-");
            if (mode == .no_tarball and !is_source) continue;
            var hex = try sha256Hex(a, try readFile(a, try join(a, &.{ dir, n })));
            if (mode == .short and !is_source) hex = hex[0..63];
            if (mode == .non_hex and !is_source) hex = try std.fmt.allocPrint(a, "z{s}", .{hex[1..]});
            const line = try std.fmt.allocPrint(a, "{s}  {s}\n", .{ hex, n });
            try text.appendSlice(line);
            if (mode == .twice) try text.appendSlice(line);
        }
        try writeFile(path, text.items);
    }

    /// <root>/<ver>/ with the three tarballs copied from `from` (a directory of tarballs), a source archive, the bundles, and SHA256SUMS.
    fn release(fx: *Fx, root: []const u8, ver: []const u8, from: []const u8, mode: SumsMode, bundles: bool) !void {
        const a = fx.a;
        const dir = try join(a, &.{ root, ver });
        try std.fs.cwd().makePath(dir);
        for (targets) |t| {
            const name = try std.fmt.allocPrint(a, "buildrules-cli-{s}-{s}.tar.gz", .{ ver, t });
            const dst = try join(a, &.{ dir, name });
            try writeFile(dst, try readFile(a, try join(a, &.{ from, name })));
            if (bundles) try writeFile(try std.fmt.allocPrint(a, "{s}.sigstore.json", .{dst}), "{\"fake\": true}\n");
        }
        // The source archive, which the release's SHA256SUMS lists beside the tarballs and whose name is a prefix of theirs.
        const source = try std.fmt.allocPrint(a, "buildrules-{s}.tar.gz", .{ver});
        try writeFile(try join(a, &.{ dir, source }), "source archive\n");
        try fx.sums(dir, mode);
    }

    fn serve(fx: *Fx, name: []const u8) !Release {
        const root = try join(fx.a, &.{ fx.work, "releases", name });
        try std.fs.cwd().makePath(root);
        const srv = try Server.start(fx.a, root);
        return .{ .root = root, .srv = srv, .base = try srv.base(fx.a) };
    }

    fn init(a: Allocator) !*Fx {
        const fx = try a.create(Fx);
        const work = try getenv(a, "BUILDRULES_TEST_WORK");
        const fakes_src = try getenv(a, "FAKES");
        const bytes = try readFile(a, fakes_src);
        fx.* = .{
            .a = a,
            .work = work,
            .fakes = try join(a, &.{ work, "bin", "fakes" }),
            .fakes_bytes = bytes,
            .sh = try findInPath(a, "sh"),
        };
        try writeFileMode(fx.fakes, bytes, 0o755);

        const good = try join(a, &.{ work, "tarballs", "honest" });
        const bad = try join(a, &.{ work, "tarballs", "tampered" });
        const hollow = try join(a, &.{ work, "tarballs", "no_program" });
        try fx.tarballs(try join(a, &.{ good, "1.2.3" }), "1.2.3", .honest);
        try fx.tarballs(try join(a, &.{ good, "1.0.0" }), "1.0.0", .honest);
        try fx.tarballs(bad, "1.2.3", .tampered);
        try fx.tarballs(hollow, "1.2.3", .no_program);
        const good_123 = try join(a, &.{ good, "1.2.3" });

        fx.main = try fx.serve("main");
        try fx.release(fx.main.root, "1.2.3", good_123, .honest, true);
        try fx.release(fx.main.root, "1.0.0", try join(a, &.{ good, "1.0.0" }), .honest, true);

        fx.tampered = try fx.serve("tampered");
        try fx.release(fx.tampered.root, "1.2.3", bad, .honest, true);
        // The honest sums over the tampered files' names: the sha256 of the honest tarballs.
        try writeFile(try join(a, &.{ fx.tampered.root, "1.2.3", "SHA256SUMS" }), try readFile(a, try join(a, &.{ fx.main.root, "1.2.3", "SHA256SUMS" })));

        fx.no_program = try fx.serve("no_program");
        try fx.release(fx.no_program.root, "1.2.3", hollow, .honest, true);

        fx.no_tarball = try fx.serve("no_tarball");
        try fx.release(fx.no_tarball.root, "1.2.3", good_123, .no_tarball, true);
        fx.twice = try fx.serve("twice");
        try fx.release(fx.twice.root, "1.2.3", good_123, .twice, true);
        fx.short = try fx.serve("short");
        try fx.release(fx.short.root, "1.2.3", good_123, .short, true);
        fx.non_hex = try fx.serve("non_hex");
        try fx.release(fx.non_hex.root, "1.2.3", good_123, .non_hex, true);
        fx.no_sums = try fx.serve("no_sums");
        try fx.release(fx.no_sums.root, "1.2.3", good_123, .none, true);
        fx.no_bundle = try fx.serve("no_bundle");
        try fx.release(fx.no_bundle.root, "1.2.3", good_123, .honest, false);
        fx.empty = try fx.serve("empty");

        // The PATHs: busybox applets by link, the stand-ins by link to the one program.
        const applets = [_][]const u8{ "awk", "tar", "mktemp", "mkdir", "cp", "chmod", "mv", "rm" };
        const kinds = [_]PathKind{ .base, .no_curl, .no_sum, .shasum, .cosign };
        for (kinds) |k| {
            const dir = try join(a, &.{ work, "path", @tagName(k) });
            try std.fs.cwd().makePath(dir);
            for (applets) |n| try std.fs.cwd().symLink(try findInPath(a, n), try join(a, &.{ dir, n }), .{});
            var shims = std.ArrayList([]const u8).init(a);
            try shims.append("uname");
            if (k != .no_curl) try shims.append("curl");
            if (k == .cosign) try shims.append("cosign");
            if (k == .shasum) try shims.append("shasum") else if (k != .no_sum) try std.fs.cwd().symLink(try findInPath(a, "sha256sum"), try join(a, &.{ dir, "sha256sum" }), .{});
            for (shims.items) |n| try std.fs.cwd().symLink(fx.fakes, try join(a, &.{ dir, n }), .{});
            fx.paths[@intFromEnum(k)] = dir;
        }
        return fx;
    }

    fn stop(fx: *Fx) void {
        for ([_]*Release{ &fx.main, &fx.tampered, &fx.no_program, &fx.no_tarball, &fx.twice, &fx.short, &fx.non_hex, &fx.no_sums, &fx.no_bundle, &fx.empty }) |r| r.srv.stop();
    }
};

// ---- one pass over every case, against one script -------------------------------------------------------------------------------------------------------

const Rep = struct {
    verbose: bool,
    failures: usize = 0,
    first: []const u8 = "",

    fn check(self: *Rep, name: []const u8, ok: bool, detail: []const u8) void {
        if (ok) {
            if (self.verbose) std.debug.print("ok   {s}\n", .{name});
        } else {
            if (self.failures == 0) self.first = name;
            self.failures += 1;
            if (self.verbose) std.debug.print("FAIL {s}: {s}\n", .{ name, detail[0..@min(detail.len, 600)] });
        }
    }
};

const Opt = struct {
    rel: *Release,
    args: []const []const u8 = &.{},
    path: PathKind = .base,
    os: []const u8 = "Linux",
    arch: []const u8 = "x86_64",
    program_version: []const u8 = "1.2.3",
    stdin: bool = false,
    keep_home: bool = false,
    cosign_exit: ?[]const u8 = null,
    url: bool = true,
};

const Pass = struct {
    a: Allocator,
    fx: *Fx,
    script: []const u8, // absolute path of the script under test
    work: []const u8, // this pass's scratch directory
    rep: *Rep,

    fn p(self: *Pass, parts: []const []const u8) ![]u8 {
        return join(self.a, parts);
    }

    /// Runs the script in a fresh home, with the arguments `--releases-url <server>` and `o.args`. Returns what it printed and its exit code.
    fn install(self: *Pass, o: Opt) !Ran {
        const a = self.a;
        o.rel.srv.clear();
        const home = try self.p(&.{ self.work, "home" });
        const tmp = try self.p(&.{ self.work, "tmp" });
        if (!o.keep_home) {
            try std.fs.cwd().deleteTree(home);
            try std.fs.cwd().makePath(home);
        }
        try std.fs.cwd().deleteTree(tmp);
        try std.fs.cwd().makePath(tmp);
        std.fs.cwd().deleteFile(try self.p(&.{ self.work, "cosign.log" })) catch {};
        var env = std.process.EnvMap.init(a);
        try env.put("PATH", self.fx.paths[@intFromEnum(o.path)]);
        try env.put("HOME", home);
        try env.put("TMPDIR", tmp);
        try env.put("FAKE_OS", o.os);
        try env.put("FAKE_ARCH", o.arch);
        try env.put("FAKE_BUILDRULES_VERSION", o.program_version);
        try env.put("FAKE_COSIGN_LOG", try self.p(&.{ self.work, "cosign.log" }));
        if (o.cosign_exit) |c| try env.put("FAKE_COSIGN_EXIT", c);
        var argv = std.ArrayList([]const u8).init(a);
        try argv.append(self.fx.sh);
        if (o.stdin) {
            try argv.append("-s");
            try argv.append("--");
        } else try argv.append(self.script);
        if (o.url) {
            try argv.append("--releases-url");
            try argv.append(o.rel.base);
        }
        for (o.args) |x| try argv.append(x);
        return runProc(a, argv.items, &env, if (o.stdin) try readFile(a, self.script) else null);
    }

    fn homeBin(self: *Pass) ![]u8 {
        return self.p(&.{ self.work, "home", ".buildrules", "bin", "buildrules" });
    }

    /// What `<program> --version` prints, the program being the fake (FAKE_BUILDRULES_VERSION says what it reports).
    fn reported(self: *Pass, bin: []const u8) ![]const u8 {
        var env = std.process.EnvMap.init(self.a);
        try env.put("FAKE_BUILDRULES_VERSION", "1.2.3");
        const r = runProc(self.a, &.{ bin, "--version" }, &env, null) catch return "";
        return std.mem.trim(u8, r.text, "\n");
    }

    /// The files under the home directory, sorted, one per line.
    fn homeTree(self: *Pass) ![]u8 {
        const a = self.a;
        var dir = try std.fs.cwd().openDir(try self.p(&.{ self.work, "home" }), .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(a);
        defer walker.deinit();
        var names = std.ArrayList([]const u8).init(a);
        while (try walker.next()) |e| try names.append(try a.dupe(u8, e.path));
        std.mem.sort([]const u8, names.items, {}, lessThan);
        return std.mem.join(a, "\n", names.items);
    }

    fn tmpEmpty(self: *Pass) !bool {
        var dir = try std.fs.cwd().openDir(try self.p(&.{ self.work, "tmp" }), .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        return (try it.next()) == null;
    }

    fn installed(self: *Pass) !bool {
        return exists(try self.homeBin());
    }

    /// Refused: a non-zero exit, `why` in what it printed, nothing installed, no temporary directory left; and `requests` requests were made.
    fn refused(self: *Pass, name: []const u8, o: Opt, why: []const u8, requests: ?usize) !void {
        const r = try self.install(o);
        const n = o.rel.srv.requestCount();
        const reqs_ok = if (requests) |want| n == want else true;
        const detail = try std.fmt.allocPrint(self.a, "exit {d}, {d} requests: {s}", .{ r.code, n, r.text });
        self.rep.check(name, r.code != 0 and contains(r.text, why) and reqs_ok and !(try self.installed()) and (try self.tmpEmpty()), detail);
    }

    fn run(self: *Pass) !void {
        const a = self.a;
        const rep = self.rep;
        const fx = self.fx;
        const main = &fx.main;

        // 1. Success with an explicit version, with and without the v.
        for ([_][]const u8{ "1.2.3", "v1.2.3" }) |v| {
            const r = try self.install(.{ .rel = main, .args = &.{ "--version", v } });
            const name = try std.fmt.allocPrint(a, "install --version {s}", .{v});
            const tree = try self.homeTree();
            const detail = try std.fmt.allocPrint(a, "exit {d}, tree [{s}]: {s}", .{ r.code, tree, r.text });
            rep.check(name, r.code == 0 and std.mem.eql(u8, try self.reported(try self.homeBin()), "buildrules 1.2.3"), detail);
            rep.check("the PATH line is printed", contains(r.text, "export PATH="), r.text);
            rep.check("install creates only <prefix>/bin/buildrules", std.mem.eql(u8, tree, ".buildrules\n.buildrules/bin\n.buildrules/bin/buildrules"), tree);
            rep.check("install leaves no temporary directory", try self.tmpEmpty(), r.text);
        }

        // 2. Latest (the newest directory is 1.2.3), into --prefix.
        {
            const custom = try self.p(&.{ self.work, "custom" });
            try std.fs.cwd().deleteTree(custom);
            const r = try self.install(.{ .rel = main, .args = &.{ "--prefix", custom } });
            const bin = try self.p(&.{ custom, "bin", "buildrules" });
            rep.check("install latest into --prefix", r.code == 0 and std.mem.eql(u8, try self.reported(bin), "buildrules 1.2.3") and main.srv.requested("/latest"), r.text);
            rep.check("--prefix is honoured: nothing is written under ~/.buildrules", !(try self.installed()), r.text);
        }

        // 3. The script on stdin, as in curl | sh -s --.
        {
            const r = try self.install(.{ .rel = main, .args = &.{ "--version", "1.0.0" }, .program_version = "1.0.0", .stdin = true });
            rep.check("install with the script on stdin and options after -s --", r.code == 0 and try self.installed() and main.srv.requested("/download/v1.0.0/buildrules-cli-1.0.0-linux-x86_64.tar.gz"), r.text);
        }

        // 4. Each platform fetches its own file.
        const Row = struct { os: []const u8, arch: []const u8, want: []const u8 };
        const rows = [_]Row{
            .{ .os = "Linux", .arch = "x86_64", .want = "linux-x86_64" },
            .{ .os = "Linux", .arch = "amd64", .want = "linux-x86_64" },
            .{ .os = "Linux", .arch = "aarch64", .want = "linux-aarch64" },
            .{ .os = "Linux", .arch = "arm64", .want = "linux-aarch64" },
            .{ .os = "Darwin", .arch = "arm64", .want = "macos-arm64" },
        };
        for (rows) |row| {
            const r = try self.install(.{ .rel = main, .args = &.{ "--version", "1.2.3" }, .os = row.os, .arch = row.arch });
            const want = try std.fmt.allocPrint(a, "/download/v1.2.3/buildrules-cli-1.2.3-{s}.tar.gz", .{row.want});
            const name = try std.fmt.allocPrint(a, "{s} {s} fetches {s}", .{ row.os, row.arch, row.want });
            rep.check(name, r.code == 0 and main.srv.requested(want) and main.srv.requested("/download/v1.2.3/SHA256SUMS") and main.srv.requestCount() == 2, r.text);
        }

        // 5. Unsupported platforms are refused before any request; an Intel Mac by name.
        const bad = [_][2][]const u8{ .{ "Linux", "riscv64" }, .{ "Linux", "i686" }, .{ "Darwin", "ppc64" }, .{ "FreeBSD", "amd64" }, .{ "Linux", "armv7l" } };
        for (bad) |row| {
            const name = try std.fmt.allocPrint(a, "{s} {s} is refused before any request", .{ row[0], row[1] });
            try self.refused(name, .{ .rel = main, .args = &.{ "--version", "1.2.3" }, .os = row[0], .arch = row[1] }, "no buildrules release for", 0);
        }
        try self.refused("Darwin x86_64 (an Intel Mac) is refused by name, before any request", .{ .rel = main, .args = &.{ "--version", "1.2.3" }, .os = "Darwin", .arch = "x86_64" }, "no buildrules release for Intel Macs", 0);

        // 6. A tampered tarball is refused; an existing install survives, with the shasum fallback too.
        for ([_]PathKind{ .base, .shasum }) |kind| {
            const home_bin_dir = try self.p(&.{ self.work, "home", ".buildrules", "bin" });
            try std.fs.cwd().deleteTree(try self.p(&.{ self.work, "home" }));
            try std.fs.cwd().makePath(home_bin_dir);
            try writeFile(try self.homeBin(), "previous\n");
            const r = try self.install(.{ .rel = &fx.tampered, .args = &.{ "--version", "1.2.3" }, .path = kind, .keep_home = true });
            const kept = try readFile(a, try self.homeBin());
            const name = try std.fmt.allocPrint(a, "a tampered tarball is refused and the previous install is kept ({s})", .{@tagName(kind)});
            rep.check(name, r.code != 0 and contains(r.text, "sha256 mismatch") and std.mem.eql(u8, kept, "previous\n") and try self.tmpEmpty(), r.text);
        }
        {
            const r = try self.install(.{ .rel = main, .args = &.{ "--version", "1.2.3" }, .path = .shasum });
            rep.check("the shasum fallback installs when there is no sha256sum", r.code == 0 and try self.installed(), r.text);
        }

        // 7. SHA256SUMS that lacks the tarball, lists it twice, has a short or a non-hex entry, or is missing.
        try self.refused("SHA256SUMS without the tarball is refused", .{ .rel = &fx.no_tarball, .args = &.{ "--version", "1.2.3" } }, "does not list buildrules-cli-1.2.3-linux-x86_64.tar.gz exactly once", null);
        try self.refused("SHA256SUMS listing the tarball twice is refused", .{ .rel = &fx.twice, .args = &.{ "--version", "1.2.3" } }, "does not list buildrules-cli-1.2.3-linux-x86_64.tar.gz exactly once", null);
        try self.refused("SHA256SUMS with a non-hex entry is refused", .{ .rel = &fx.non_hex, .args = &.{ "--version", "1.2.3" } }, "does not list buildrules-cli-1.2.3-linux-x86_64.tar.gz exactly once", null);
        try self.refused("SHA256SUMS with a short entry is refused", .{ .rel = &fx.short, .args = &.{ "--version", "1.2.3" } }, "has a malformed entry", null);
        try self.refused("a missing SHA256SUMS is refused", .{ .rel = &fx.no_sums, .args = &.{ "--version", "1.2.3" } }, "could not download", null);

        // 8. A program that reports another version than the release is refused; a tarball without the program is refused.
        try self.refused("a program reporting another version is refused", .{ .rel = main, .args = &.{ "--version", "1.2.3" }, .program_version = "9.9.9" }, "did not report 'buildrules 1.2.3'", null);
        try self.refused("a tarball without the program is refused", .{ .rel = &fx.no_program, .args = &.{ "--version", "1.2.3" } }, "does not contain buildrules-cli-1.2.3-linux-x86_64/buildrules", null);

        // 9. No release at all.
        try self.refused("no release at all is refused", .{ .rel = &fx.empty }, "could not look up the latest release", null);

        // 10. A version that is not one is refused before any request.
        for ([_][]const u8{ "1.2.3;rm", "latest", "v", "1/../2" }) |v| {
            const name = try std.fmt.allocPrint(a, "--version '{s}' is refused before any request", .{v});
            try self.refused(name, .{ .rel = main, .args = &.{ "--version", v } }, "is not a version", 0);
        }

        // 11. Options.
        try self.refused("an unknown option is refused before any request", .{ .rel = main, .args = &.{ "--bogus" }, .url = true }, "unknown option '--bogus'", 0);
        try self.refused("--prefix without a value is refused", .{ .rel = main, .args = &.{"--prefix"} }, "needs a value", 0);
        try self.refused("--prefix followed by an option is refused", .{ .rel = main, .args = &.{ "--prefix", "--verify" } }, "needs a value", 0);
        try self.refused("--version with an empty value is refused", .{ .rel = main, .args = &.{ "--version", "" } }, "needs a value", 0);
        {
            const r = try self.install(.{ .rel = main, .args = &.{"--help"} });
            const usage_ok = contains(r.text, "--version") and contains(r.text, "--prefix") and contains(r.text, "--verify") and contains(r.text, "--releases-url");
            rep.check("--help prints the options, makes no request and installs nothing", r.code == 0 and usage_ok and main.srv.requestCount() == 0 and !(try self.installed()), r.text);
        }

        // 12. Tools that are missing.
        try self.refused("a missing curl is refused", .{ .rel = main, .args = &.{ "--version", "1.2.3" }, .path = .no_curl }, "curl is required", 0);
        try self.refused("a missing sha256sum and shasum is refused before any request", .{ .rel = main, .args = &.{ "--version", "1.2.3" }, .path = .no_sum }, "sha256sum or shasum is required", 0);

        // 13. --verify.
        {
            const r = try self.install(.{ .rel = main, .args = &.{ "--version", "1.2.3", "--verify" }, .path = .cosign });
            const log = readFile(a, try self.p(&.{ self.work, "cosign.log" })) catch "";
            const line = std.mem.trim(u8, log, "\n");
            const ident = try std.fmt.allocPrint(a, "buildrules-cli-1.2.3-linux-x86_64.tar.gz.sigstore.json --certificate-identity {s} --certificate-oidc-issuer {s} ", .{ signer, issuer });
            const shape = std.mem.startsWith(u8, line, "verify-blob --bundle ") and contains(line, ident) and std.mem.endsWith(u8, line, "/buildrules-cli-1.2.3-linux-x86_64.tar.gz") and std.mem.count(u8, log, "\n") == 1;
            rep.check("--verify runs cosign verify-blob on the tarball with its bundle, the release workflow's identity and the issuer, once", r.code == 0 and shape and try self.installed(), log);
            rep.check("--verify says it verified", contains(r.text, "Verified the signature of buildrules-cli-1.2.3-linux-x86_64.tar.gz"), r.text);
        }
        try self.refused("a cosign that refuses stops the install", .{ .rel = main, .args = &.{ "--version", "1.2.3", "--verify" }, .path = .cosign, .cosign_exit = "1" }, "cosign did not verify the signature", null);
        try self.refused("--verify without cosign is refused before any request", .{ .rel = main, .args = &.{ "--version", "1.2.3", "--verify" } }, "--verify needs cosign", 0);
        try self.refused("--verify with no bundle in the release is refused", .{ .rel = &fx.no_bundle, .args = &.{ "--version", "1.2.3", "--verify" }, .path = .cosign }, "could not download", null);
        {
            const r = try self.install(.{ .rel = main, .args = &.{ "--version", "1.2.3" }, .path = .cosign });
            rep.check("without --verify cosign is never run", r.code == 0 and !exists(try self.p(&.{ self.work, "cosign.log" })) and !main.srv.requested("/download/v1.2.3/buildrules-cli-1.2.3-linux-x86_64.tar.gz.sigstore.json"), r.text);
        }
    }
};

// ---- the planted defects --------------------------------------------------------------------------------------------------------------------------------

const Mutant = struct { name: []const u8, from: []const u8, to: []const u8 };

const darwin_intel = "    Darwin-x86_64) die \"no buildrules release for Intel Macs (Darwin x86_64); buildrules is released for Apple silicon Macs (arm64) and for Linux on x86_64 and arm64. On an Apple silicon Mac, run this from a native shell, not one running under Rosetta\" ;;";

const mutants = [_]Mutant{
    .{ .name = "skip-sha-compare", .from = "[ \"$got\" = \"$want\" ] || die \"sha256 mismatch for $asset: got $got, SHA256SUMS says $want; nothing was installed\"", .to = "true" },
    .{ .name = "shasum-result-ignored", .from = "got=$(shasum -a 256 \"$tmp/$asset\" | awk '{ print $1 }')", .to = "got=$want" },
    .{ .name = "any-platform-accepted", .from = "    *) die \"no buildrules release for $(uname -s) $(uname -m); there are releases for Linux on x86_64 and arm64 and for macOS on arm64\" ;;", .to = "    *) target=linux-x86_64 ;;" },
    .{ .name = "skip-binary-version-check", .from = "if [ \"$(\"$prefix/bin/.buildrules.new.$$\" --version 2>/dev/null)\" != \"buildrules $version\" ]; then", .to = "if false; then" },
    .{ .name = "intel-mac-gets-the-arm-program", .from = darwin_intel, .to = "    Darwin-x86_64) target=macos-arm64 ;;" },
    .{ .name = "intel-mac-sent-to-a-missing-file", .from = darwin_intel, .to = "    Darwin-x86_64) target=macos-x86_64 ;;" },
    .{ .name = "macos-arm-maps-to-linux", .from = "Darwin-arm64) target=macos-arm64 ;;", .to = "Darwin-arm64) target=linux-aarch64 ;;" },
    .{ .name = "aarch64-maps-to-x86", .from = "Linux-aarch64|Linux-arm64) target=linux-aarch64 ;;", .to = "Linux-aarch64|Linux-arm64) target=linux-x86_64 ;;" },
    .{ .name = "amd64-not-mapped", .from = "Linux-x86_64|Linux-amd64) target=linux-x86_64 ;;", .to = "Linux-x86_64) target=linux-x86_64 ;;" },
    .{ .name = "arm64-linux-not-mapped", .from = "Linux-aarch64|Linux-arm64) target=linux-aarch64 ;;", .to = "Linux-aarch64) target=linux-aarch64 ;;" },
    .{ .name = "latest-not-resolved", .from = "    tag=${url##*/}", .to = "    tag=v1.0.0" },
    .{ .name = "version-chars-unchecked", .from = "*[!0-9A-Za-z.+_-]*) die \"'$tag' is not a version\" ;;", .to = "*[!0-9A-Za-z.+_-]*) : ;;" },
    .{ .name = "version-prefix-unchecked", .from = "*) die \"'$want_version' is not a version\" ;;", .to = "*) ;;" },
    .{ .name = "sums-list-guard-removed", .from = "    \"\"|*[!0-9a-f]*) die \"SHA256SUMS does not list $asset exactly once\" ;;", .to = "    \"\") ;;" },
    .{ .name = "sums-length-guard-removed", .from = "[ \"${#want}\" -eq 64 ] || die \"SHA256SUMS has a malformed entry for $asset\"", .to = "true" },
    .{ .name = "binary-presence-unchecked", .from = "[ -f \"$tmp/x/$name/buildrules\" ] || die \"$asset does not contain $name/buildrules\"", .to = "true" },
    .{ .name = "prefix-ignored", .from = "--prefix) prefix=$2 ;;", .to = "--prefix) : ;;" },
    .{ .name = "option-value-dash-accepted", .from = "\"\"|-*) die \"$1 needs a value, not '$2' (see --help)\" ;;", .to = "\"\"|-*) : ;;" },
    .{ .name = "unknown-option-ignored", .from = "*) die \"unknown option '$1' (see --help)\" ;;", .to = "*) shift ;;" },
    .{ .name = "help-installs", .from = "-h|--help) usage; exit 0 ;;", .to = "-h|--help) usage; shift ;;" },
    .{ .name = "temp-dir-not-cleaned", .from = "trap 'rm -rf \"$tmp\"' EXIT HUP INT TERM", .to = "true" },
    .{ .name = "verify-skipped", .from = "cosign_out=$(cosign verify-blob", .to = "cosign_out=$(true verify-blob" },
    .{ .name = "cosign-refusal-ignored", .from = "die \"cosign did not verify the signature of $asset: $cosign_out; nothing was installed\"", .to = "true" },
    .{ .name = "wrong-identity", .from = "--certificate-identity \"$signer\"", .to = "--certificate-identity \"$issuer\"" },
    .{ .name = "wrong-file-verified", .from = "\"$issuer\" \"$tmp/$asset\" 2>&1)", .to = "\"$issuer\" \"$tmp/SHA256SUMS\" 2>&1)" },
    .{ .name = "missing-cosign-tolerated", .from = "command -v cosign >/dev/null 2>&1 || die \"--verify needs cosign, which was not found; install it (https://docs.sigstore.dev) or leave --verify out\"", .to = "true" },
    .{ .name = "bundle-not-downloaded", .from = "curl -fsSL --retry 3 -o \"$tmp/$asset.sigstore.json\" \"$releases/download/$tag/$asset.sigstore.json\" ||", .to = "true ||" },
    .{ .name = "verify-always", .from = "if [ \"$verify\" = 1 ]; then", .to = "if true; then" },
};

test "install.sh against fake releases, and the planted defects are caught" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fx = try Fx.init(a);
    defer fx.stop();
    const script = try join(a, &.{ fx.work, "site", "static", "install.sh" });

    // The script as it is: every check passes.
    var rep = Rep{ .verbose = true };
    var pass = Pass{ .a = a, .fx = fx, .script = script, .work = try join(a, &.{ fx.work, "pass-clean" }), .rep = &rep };
    try pass.run();
    try std.testing.expectEqual(@as(usize, 0), rep.failures);

    // Each planted defect must turn at least one check red.
    const text = try readFile(a, script);
    var survived: usize = 0;
    for (mutants) |m| {
        if (std.mem.indexOf(u8, text, m.from) == null) {
            std.debug.print("MUTANT {s}: the text it replaces is not in install.sh\n", .{m.name});
            survived += 1;
            continue;
        }
        const mutated = try std.mem.replaceOwned(u8, a, text, m.from, m.to);
        const mscript = try join(a, &.{ fx.work, "mutants", try std.fmt.allocPrint(a, "install-{s}.sh", .{m.name}) });
        try writeFile(mscript, mutated);
        var mrep = Rep{ .verbose = false };
        var mpass = Pass{ .a = a, .fx = fx, .script = mscript, .work = try join(a, &.{ fx.work, try std.fmt.allocPrint(a, "pass-{s}", .{m.name}) }), .rep = &mrep };
        try mpass.run();
        if (mrep.failures == 0) {
            std.debug.print("MUTANT {s} SURVIVED: every check still passed\n", .{m.name});
            survived += 1;
        } else {
            std.debug.print("mutant {s} killed by {d} checks, the first: {s}\n", .{ m.name, mrep.failures, mrep.first });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), survived);
}
