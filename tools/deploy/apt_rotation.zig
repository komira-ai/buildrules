//! apt_rotation: the proof that an apt repository can be signed by two keys at once, which a keyring rotation depends on. It is the driver of the hosted workflow
//! .github/workflows/apt-rotation.yml (the apt tests of this repository use a fake `gpg`; this uses the real gpg, gpgv and apt, with keys made for the run and thrown away).
//!
//!   apt_rotation make --work <dir> --out <dir> --channels <path> --apt-publish <path> --packaging <dir> [--gpg <path>] [--gpgv <path>]
//!       <packaging> is the directory `channels deb-data` reads the control fields and the copyright from (the workflow gives packaging/deb).
//!       Makes three throwaway keys (a, b and an unrelated one: a signing subkey each, under a passphrase), then
//!         1. builds an apt repository with the `channels` program (a data package of Architecture all, so the repository has a binary-all index) and signs its Release
//!            with the keys a and b together, with `apt_publish sign` (one `--local-user <fingerprint>!` each): InRelease and Release.gpg;
//!         2. shows with `gpg --list-packets` that both files carry exactly two signatures, one by each key;
//!         3. shows with `gpgv` that either key alone in the keyring verifies both files (the signature of the other key is reported as unverifiable and the file is good), that the
//!            unrelated key verifies neither, and that a Release changed by one byte is not verified by either key.
//!       Writes <out>/repo (the repository), <out>/keys/{a,b,other}.gpg (the public keyrings, one key each) and <out>/apt_rotation (this program, for the containers).
//!       Any failed expectation is an exit 1 that says which.
//!   apt_rotation apt-check --repo <dir> --keyring <file> --package <name> --installed-file <path> --work <dir> --expect ok|refused [--apt-get <path>] [--dpkg-query <path>]
//!       Run as root in a container (the work directory must be an absolute path): copies the repository and the keyring below <work> with modes any user can read, gives apt
//!       that repository alone (a deb822 source with `Signed-By: <keyring>`) and runs `apt-get update` and `apt-get install`.
//!         ok:      update succeeds with no `W:` or `E:` line, the binary-all index was fetched, the package installs and dpkg says it is installed and its file is there;
//!         refused: update fails and apt's words say the signature is why, the package does not install, and dpkg does not have it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const parse = @import("apt_rotation/parse.zig");

fn die(comptime f: []const u8, args: anytype) noreturn {
    std.debug.print("apt_rotation: " ++ f ++ "\n", args);
    std.process.exit(1);
}

fn usage() noreturn {
    std.debug.print("usage: apt_rotation make|apt-check ... (see tools/deploy/apt_rotation.zig)\n", .{});
    std.process.exit(2);
}

fn oom() noreturn {
    @panic("oom");
}

const Flag = struct { name: []const u8, value: []const u8 };

fn parseFlags(a: Allocator, args: []const []const u8, with_value: []const []const u8) []Flag {
    var out = std.ArrayList(Flag).init(a);
    var i: usize = 0;
    outer: while (i < args.len) : (i += 1) {
        for (with_value) |w| {
            if (std.mem.eql(u8, args[i], w)) {
                if (i + 1 >= args.len) die("{s} needs a value", .{args[i]});
                out.append(.{ .name = args[i], .value = args[i + 1] }) catch oom();
                i += 1;
                continue :outer;
            }
        }
        die("unknown argument '{s}'", .{args[i]});
    }
    return out.items;
}

fn one(flags: []const Flag, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (flags) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            if (found != null) die("{s} given twice", .{name});
            found = f.value;
        }
    }
    return found;
}

fn need(flags: []const Flag, name: []const u8) []const u8 {
    return one(flags, name) orelse die("{s} is required", .{name});
}

fn say(comptime f: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(f, args) catch {};
}

fn fmt(a: Allocator, comptime f: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(a, f, args) catch oom();
}

fn join(a: Allocator, parts: []const []const u8) []u8 {
    return std.fs.path.join(a, parts) catch oom();
}

const Ran = struct { ok: bool, code: u8, out: []const u8, err: []const u8 };

fn run(a: Allocator, argv: []const []const u8, env: ?*const std.process.EnvMap) Ran {
    const r = std.process.Child.run(.{ .allocator = a, .argv = argv, .env_map = env, .max_output_bytes = 1 << 26 }) catch |err| {
        die("could not run {s}: {s}", .{ argv[0], @errorName(err) });
    };
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .ok = code == 0, .code = code, .out = r.stdout, .err = r.stderr };
}

fn show(argv: []const []const u8, r: Ran) void {
    std.debug.print("--- {s} (exit {d})\n{s}{s}---\n", .{ argv[0], r.code, r.out, r.err });
}

/// A step that must succeed; its words are printed when it does not.
fn must(a: Allocator, what: []const u8, argv: []const []const u8, env: ?*const std.process.EnvMap) Ran {
    const r = run(a, argv, env);
    if (!r.ok) {
        show(argv, r);
        die("{s} failed", .{what});
    }
    return r;
}

fn concat(a: Allocator, x: []const u8, y: []const u8) []u8 {
    return std.mem.concat(a, u8, &.{ x, y }) catch oom();
}

fn writeFileMode(path: []const u8, data: []const u8, mode: std.fs.File.Mode) void {
    const cwd = std.fs.cwd();
    if (std.fs.path.dirname(path)) |d| cwd.makePath(d) catch |err| die("cannot create {s}: {s}", .{ d, @errorName(err) });
    var f = cwd.createFile(path, .{ .mode = mode }) catch |err| die("cannot write {s}: {s}", .{ path, @errorName(err) });
    defer f.close();
    f.writeAll(data) catch |err| die("cannot write {s}: {s}", .{ path, @errorName(err) });
}

fn readFile(a: Allocator, path: []const u8) []u8 {
    return std.fs.cwd().readFileAlloc(a, path, 1 << 28) catch |err| die("cannot read {s}: {s}", .{ path, @errorName(err) });
}

/// A directory (0700) that did not exist before: gpg refuses a home that others can read.
fn freshPrivateDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch |err| die("cannot create {s}: {s}", .{ d, @errorName(err) });
    std.posix.mkdir(path, 0o700) catch |err| die("cannot create {s}: {s}", .{ path, @errorName(err) });
}

// ---- make --------------------------------------------------------------------------------------------------------

const passphrase = "throwaway-passphrase-of-a-key-made-for-this-run";

const Key = struct { name: []const u8, keys: parse.Keys };

const Gpg = struct {
    exe: []const u8,
    home: []const u8,
    pass_file: []const u8,

    /// `gpg --homedir <home> --batch ... <rest>`, with the passphrase as a file and the loopback pinentry (never an argument).
    fn cmd(self: Gpg, a: Allocator, rest: []const []const u8) []const []const u8 {
        var v = std.ArrayList([]const u8).init(a);
        v.appendSlice(&.{ self.exe, "--homedir", self.home, "--batch", "--no-tty", "--yes", "--pinentry-mode", "loopback", "--passphrase-file", self.pass_file }) catch oom();
        v.appendSlice(rest) catch oom();
        return v.items;
    }
};

fn genKey(a: Allocator, gpg: Gpg, name: []const u8) Key {
    const uid = fmt(a, "apt-rotation-key-{s}", .{name});
    _ = must(a, "generating a key", gpg.cmd(a, &.{ "--quick-generate-key", uid, "ed25519", "cert", "never" }), null);
    const first = must(a, "listing the new key", gpg.cmd(a, &.{ "--list-secret-keys", "--with-colons", uid }), null);
    const primary = parse.primaryFpr(first.out) orelse die("the new key {s} is not in the listing: {s}", .{ uid, first.out });
    _ = must(a, "adding a signing subkey", gpg.cmd(a, &.{ "--quick-add-key", primary, "ed25519", "sign", "never" }), null);
    const second = must(a, "listing the key with its subkey", gpg.cmd(a, &.{ "--list-secret-keys", "--with-colons", primary }), null);
    const keys = parse.parseKeys(second.out) catch |err| die("the listing of {s} has no signing subkey ({s}): {s}", .{ uid, @errorName(err), second.out });
    return .{ .name = name, .keys = keys };
}

fn expect(ok: bool, comptime what: []const u8, args: anytype) void {
    if (!ok) die("EXPECTATION FAILED: " ++ what, args);
    say("ok: " ++ what ++ "\n", args);
}

fn signersOf(a: Allocator, gpg: []const u8, home: []const u8, file: []const u8) []const []const u8 {
    const argv = [_][]const u8{ gpg, "--homedir", home, "--batch", "--no-tty", "--list-packets", file };
    const r = must(a, "gpg --list-packets", &argv, null);
    say("{s}{s}", .{ r.out, r.err });
    return parse.signers(a, concat(a, r.out, r.err)) catch oom();
}

const Checked = struct { ran: Ran, v: parse.Verdict };

fn gpgvOf(a: Allocator, gpgv: []const u8, home: []const u8, keyring: []const u8, files: []const []const u8) Checked {
    var v = std.ArrayList([]const u8).init(a);
    v.appendSlice(&.{ gpgv, "--homedir", home, "--status-fd", "1", "--keyring", keyring }) catch oom();
    v.appendSlice(files) catch oom();
    const r = run(a, v.items, null);
    say("gpgv --keyring {s} {s} (exit {d})\n{s}{s}", .{ std.fs.path.basename(keyring), files[files.len - 1], r.code, r.out, r.err });
    return .{ .ran = r, .v = parse.verdict(a, r.out) catch oom() };
}

fn cmdMake(a: Allocator, args: []const []const u8) void {
    const flags = parseFlags(a, args, &.{ "--work", "--out", "--channels", "--apt-publish", "--packaging", "--gpg", "--gpgv" });
    const work = need(flags, "--work");
    const out = need(flags, "--out");
    const channels = need(flags, "--channels");
    const apt_publish = need(flags, "--apt-publish");
    const packaging = need(flags, "--packaging");
    const gpg_exe = one(flags, "--gpg") orelse "gpg";
    const gpgv_exe = one(flags, "--gpgv") orelse "gpgv";

    // The keys: a and b sign together; `other` signs nothing and is what a keyring that lacks both looks like.
    const home = join(a, &.{ work, "keygen" });
    freshPrivateDir(home);
    const pass_file = join(a, &.{ home, "pass" });
    writeFileMode(pass_file, passphrase, 0o600);
    const gpg = Gpg{ .exe = gpg_exe, .home = home, .pass_file = pass_file };
    const ka = genKey(a, gpg, "a");
    const kb = genKey(a, gpg, "b");
    const ko = genKey(a, gpg, "other");
    const id_a = parse.keyId(ka.keys.signing);
    const id_b = parse.keyId(kb.keys.signing);
    const id_o = parse.keyId(ko.keys.signing);
    say("signing subkeys: a {s}, b {s}, other {s}\n", .{ id_a, id_b, id_o });
    expect(!std.mem.eql(u8, id_a, id_b) and !std.mem.eql(u8, id_a, id_o) and !std.mem.eql(u8, id_b, id_o), "the three signing subkeys are three keys", .{});

    const keys_dir = join(a, &.{ out, "keys" });
    std.fs.cwd().makePath(keys_dir) catch |err| die("cannot create {s}: {s}", .{ keys_dir, @errorName(err) });
    const ring_a = join(a, &.{ keys_dir, "a.gpg" });
    const ring_b = join(a, &.{ keys_dir, "b.gpg" });
    const ring_o = join(a, &.{ keys_dir, "other.gpg" });
    for ([_]struct { k: Key, ring: []const u8 }{ .{ .k = ka, .ring = ring_a }, .{ .k = kb, .ring = ring_b }, .{ .k = ko, .ring = ring_o } }) |e| {
        _ = must(a, "exporting a public keyring", gpg.cmd(a, &.{ "--output", e.ring, "--export", e.k.keys.primary }), null);
    }

    // The repository: a data package of Architecture all, indexed by the repository's own tool.
    const hello = join(a, &.{ work, "hello" });
    writeFileMode(hello, "installed from a repository signed by two keys\n", 0o644);
    const deb = join(a, &.{ work, "debs", "rotation-test_1.0.0_all.deb" });
    std.fs.cwd().makePath(join(a, &.{ work, "debs" })) catch |err| die("cannot create the debs directory: {s}", .{@errorName(err)});
    _ = must(a, "channels deb-data", &.{ channels, "deb-data", "--name", "rotation-test", "--version", "1.0.0", "--packaging", packaging, "--file", fmt(a, "644:usr/share/rotation-test/hello:{s}", .{hello}), "--mtime", "1700000000", "--out", deb }, null);
    const repo = join(a, &.{ out, "repo" });
    std.fs.cwd().deleteTree(repo) catch {};
    const idx = must(a, "channels apt-index", &.{ channels, "apt-index", "--repo", join(a, &.{ work, "no-such-repository" }), "--out", repo, "--deb", deb, "--date", fmt(a, "{d}", .{std.time.timestamp()}), "--origin", "rotation-test", "--label", "rotation-test", "--description", "a repository for the keyring rotation proof" }, null);
    say("{s}", .{idx.out});
    const dists = join(a, &.{ repo, "dists", "stable" });
    const release = join(a, &.{ dists, "Release" });
    expect(std.mem.indexOf(u8, readFile(a, release), "main/binary-all/Packages") != null, "the Release lists the binary-all index", .{});

    // Signed with both keys by the repository's own signing command.
    const secret = must(a, "exporting the secret keys", gpg.cmd(a, &.{ "--armor", "--export-secret-keys", ka.keys.primary, kb.keys.primary }), null);
    var env = std.process.getEnvMap(a) catch oom();
    env.put("APT_GPG_PRIVATE_KEY", secret.out) catch oom();
    env.put("APT_GPG_PASSPHRASE", passphrase) catch oom();
    const fprs = fmt(a, "{s},{s}", .{ ka.keys.signing, kb.keys.signing });
    const signed = must(a, "apt_publish sign", &.{ apt_publish, "sign", "--dir", dists, "--work", join(a, &.{ work, "sign" }), "--fingerprint", fprs, "--gpg", gpg_exe }, &env);
    say("{s}", .{signed.out});

    // (1) Two signatures, one by each key.
    const vhome = join(a, &.{ work, "verify-home" });
    freshPrivateDir(vhome);
    const in_release = join(a, &.{ dists, "InRelease" });
    const detached = join(a, &.{ dists, "Release.gpg" });
    expect(parse.sameTwo(signersOf(a, gpg_exe, vhome, detached), id_a, id_b), "Release.gpg carries exactly two signatures, by the subkeys of a and b", .{});
    expect(parse.sameTwo(signersOf(a, gpg_exe, vhome, in_release), id_a, id_b), "InRelease carries exactly two signatures, by the subkeys of a and b", .{});

    // (2) Either key alone verifies; the other key's signature is unverifiable, not bad.
    const sets = [_][]const []const u8{ &.{ detached, release }, &.{in_release} };
    for (sets) |files| {
        const only_a = gpgvOf(a, gpgv_exe, vhome, ring_a, files);
        expect(parse.onlyId(only_a.v.good, id_a) and parse.hasId(only_a.v.missing, id_b) and only_a.v.bad == 0, "gpgv with the keyring of a alone: a's signature is good, b's cannot be checked ({s})", .{std.fs.path.basename(files[0])});
        const only_b = gpgvOf(a, gpgv_exe, vhome, ring_b, files);
        expect(parse.onlyId(only_b.v.good, id_b) and parse.hasId(only_b.v.missing, id_a) and only_b.v.bad == 0, "gpgv with the keyring of b alone: b's signature is good, a's cannot be checked ({s})", .{std.fs.path.basename(files[0])});
        const none = gpgvOf(a, gpgv_exe, vhome, ring_o, files);
        expect(none.v.good.len == 0 and !none.ran.ok, "gpgv with an unrelated keyring verifies nothing and fails ({s})", .{std.fs.path.basename(files[0])});
    }

    // (3) A Release changed by one byte is verified by neither key.
    const tampered = join(a, &.{ work, "Release" });
    writeFileMode(tampered, concat(a, readFile(a, release), "\n"), 0o644);
    for ([_]struct { ring: []const u8, who: []const u8 }{ .{ .ring = ring_a, .who = "a" }, .{ .ring = ring_b, .who = "b" } }) |e| {
        const r = gpgvOf(a, gpgv_exe, vhome, e.ring, &.{ detached, tampered });
        expect(r.v.good.len == 0 and r.v.bad >= 1 and !r.ran.ok, "a Release changed by one byte is not verified by the keyring of {s}", .{e.who});
    }

    // For the containers: the program itself.
    const self = std.fs.selfExePathAlloc(a) catch |err| die("cannot find this program: {s}", .{@errorName(err)});
    std.fs.cwd().copyFile(self, std.fs.cwd(), join(a, &.{ out, "apt_rotation" }), .{}) catch |err| die("cannot copy this program: {s}", .{@errorName(err)});
    say("made {s}\n", .{out});
}

// ---- apt-check ---------------------------------------------------------------------------------------------------

/// Copies the tree below `from` to `to`, every directory 0755 and every file 0644: the user apt downloads as can read it.
fn copyTree(a: Allocator, from: []const u8, to: []const u8) void {
    const cwd = std.fs.cwd();
    var dir = cwd.openDir(from, .{ .iterate = true }) catch |err| die("cannot read {s}: {s}", .{ from, @errorName(err) });
    defer dir.close();
    cwd.makePath(to) catch |err| die("cannot create {s}: {s}", .{ to, @errorName(err) });
    var walker = dir.walk(a) catch oom();
    defer walker.deinit();
    while (walker.next() catch |err| die("cannot read {s}: {s}", .{ from, @errorName(err) })) |e| {
        const dst = join(a, &.{ to, e.path });
        switch (e.kind) {
            .directory => cwd.makePath(dst) catch |err| die("cannot create {s}: {s}", .{ dst, @errorName(err) }),
            .file => {
                dir.copyFile(e.path, cwd, dst, .{}) catch |err| die("cannot copy {s}: {s}", .{ e.path, @errorName(err) });
                var f = cwd.openFile(dst, .{}) catch |err| die("cannot open {s}: {s}", .{ dst, @errorName(err) });
                defer f.close();
                f.chmod(0o644) catch |err| die("cannot chmod {s}: {s}", .{ dst, @errorName(err) });
            },
            else => {},
        }
    }
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn cmdAptCheck(a: Allocator, args: []const []const u8) void {
    const flags = parseFlags(a, args, &.{ "--repo", "--keyring", "--package", "--installed-file", "--work", "--expect", "--apt-get", "--dpkg-query" });
    const repo = need(flags, "--repo");
    const keyring = need(flags, "--keyring");
    const package = need(flags, "--package");
    const installed_file = need(flags, "--installed-file");
    const work = need(flags, "--work");
    const expect_word = need(flags, "--expect");
    const apt_get = one(flags, "--apt-get") orelse "apt-get";
    const dpkg_query = one(flags, "--dpkg-query") orelse "dpkg-query";
    if (!std.mem.eql(u8, expect_word, "ok") and !std.mem.eql(u8, expect_word, "refused")) die("--expect is ok or refused", .{});
    const want_ok = std.mem.eql(u8, expect_word, "ok");
    if (!std.fs.path.isAbsolute(work)) die("--work must be an absolute path (it becomes part of the source's address)", .{});

    std.fs.cwd().deleteTree(work) catch {};
    const sources = join(a, &.{ work, "sources" });
    const lists = join(a, &.{ work, "lists" });
    std.fs.cwd().makePath(sources) catch |err| die("cannot create {s}: {s}", .{ sources, @errorName(err) });
    std.fs.cwd().makePath(lists) catch |err| die("cannot create {s}: {s}", .{ lists, @errorName(err) });
    copyTree(a, repo, join(a, &.{ work, "repo" }));
    const key_copy = join(a, &.{ work, "key.gpg" });
    writeFileMode(key_copy, readFile(a, keyring), 0o644);
    const uri = fmt(a, "file://{s}/repo", .{work});
    const source = parse.sourcesFile(a, uri, key_copy) catch oom();
    writeFileMode(join(a, &.{ sources, "rotation.sources" }), source, 0o644);
    say("source:\n{s}", .{source});

    var env = std.process.getEnvMap(a) catch oom();
    env.put("DEBIAN_FRONTEND", "noninteractive") catch oom();
    env.put("LC_ALL", "C") catch oom();
    env.put("LANG", "C") catch oom();
    // apt is given this repository and no other, and a list directory of its own.
    const opts = [_][]const u8{ "-o", "Dir::Etc::sourcelist=/dev/null", "-o", fmt(a, "Dir::Etc::sourceparts={s}", .{sources}), "-o", fmt(a, "Dir::State::lists={s}", .{lists}) };

    const update_argv = concat2(a, &.{ apt_get, "update" }, &opts);
    const update = run(a, update_argv, &env);
    show(update_argv, update);
    const update_words = concat(a, update.out, update.err);
    const install_argv = concat2(a, &.{ apt_get, "install", "-y", "--no-install-recommends", package }, &opts);
    const query_argv = [_][]const u8{ dpkg_query, "-W", "-f=${Status}", package };

    if (want_ok) {
        expect(update.ok, "apt-get update succeeds with the repository signed by two keys and Signed-By one of them", .{});
        const problems = parse.problems(a, update_words) catch oom();
        for (problems) |p| std.debug.print("{s}\n", .{p});
        expect(problems.len == 0, "apt-get update prints no warning and no error", .{});
        var dir = std.fs.cwd().openDir(lists, .{ .iterate = true }) catch |err| die("cannot read {s}: {s}", .{ lists, @errorName(err) });
        defer dir.close();
        var all_index = false;
        var it = dir.iterate();
        while (it.next() catch |err| die("cannot read {s}: {s}", .{ lists, @errorName(err) })) |e| {
            say("list: {s}\n", .{e.name});
            if (parse.isAllIndex(e.name)) all_index = true;
        }
        expect(all_index, "apt fetched the binary-all index", .{});
        const install = run(a, install_argv, &env);
        show(install_argv, install);
        expect(install.ok, "apt-get install of the all package succeeds", .{});
        const q = run(a, &query_argv, &env);
        expect(q.ok and std.mem.eql(u8, std.mem.trim(u8, q.out, " \r\n"), "install ok installed"), "dpkg says the package is installed", .{});
        expect(exists(installed_file), "the package's file is on the disk", .{});
    } else {
        expect(!update.ok, "apt-get update fails when Signed-By holds a key that signed nothing", .{});
        expect(parse.refusedForSignature(update_words), "and apt says the signature is why", .{});
        const install = run(a, install_argv, &env);
        show(install_argv, install);
        expect(!install.ok, "the package does not install from the refused repository", .{});
        const q = run(a, &query_argv, &env);
        expect(!(q.ok and std.mem.eql(u8, std.mem.trim(u8, q.out, " \r\n"), "install ok installed")), "and dpkg does not have it", .{});
    }
}

fn concat2(a: Allocator, x: []const []const u8, y: []const []const u8) []const []const u8 {
    return std.mem.concat(a, []const u8, &.{ x, y }) catch oom();
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = std.process.argsAlloc(a) catch oom();
    if (argv.len < 2) usage();
    if (std.mem.eql(u8, argv[1], "make")) return cmdMake(a, argv[2..]);
    if (std.mem.eql(u8, argv[1], "apt-check")) return cmdAptCheck(a, argv[2..]);
    usage();
}
