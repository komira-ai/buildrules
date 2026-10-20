//! bs_runner: runs one build script (`build.rs`, compiled for the exec platform) as a Buck2 action and captures
//! what cargo would: the directives, `OUT_DIR`, and the metadata dependents read as `DEP_<LINKS>_<KEY>`.
//! The contract is decision.md 6.1; `rules/rust/cargo_unit.bzl` builds this program's command line.
//!
//!   bs_runner --exe E --out DIR --manifest DIR --sysroot DIR --launcher FILE --zig DIR --cc-target T --triple T
//!             [--links NAME] [--env K=V]... [--dep LINKS=RUNDIR=MANIFEST]... [--stamp-env NAME=FILE]...
//!             [--stamp-rustc-env NAME=FILE]...
//!
//! The script runs in the manifest directory with an environment built from nothing: the `--env` pairs, then what
//! this program computes (CARGO_MANIFEST_DIR, CARGO_MANIFEST_LINKS, OUT_DIR, TARGET, HOST, RUSTC, CC and AR and their
//! `_<triple>` forms, CARGO_CFG_* from `rustc --print=cfg`, DEP_*, TMPDIR, an empty-directory PATH). A variable the
//! script reads and none of these defines is unset: the script fails or takes its default, as in a clean cargo run.
//! `CC`, `CXX`, `AR` are the pinned zig behind the `rustc_launch` shims (see its header).
//!
//! Outputs under --out: OUT_DIR/ (the script's), rustc_args (one argument per line), rustc_env (KEY=VALUE),
//! metadata (KEY=VALUE, for dependents), rerun_if (the script's rerun-if-* lines, for the record), directives (its
//! stdout). Absolute worker paths never reach an output: this action's OUT_DIR and manifest directory are written as
//! `{OUT_DIR}` and `{MANIFEST_DIR}`, and the consumers (rustc_launch, and the DEP_ expansion here) put theirs back.
//!
//! Directives honored: rustc-cfg, rustc-check-cfg, rustc-link-lib, rustc-link-search, rustc-flags (-l, -L), rustc-env,
//! warning, error (fails the run), rerun-if-changed, rerun-if-env-changed, metadata=K=V and the old `cargo:K=V`.
//! Refused, loudly: rustc-link-arg*, rustc-cdylib-link-arg, and any other `cargo::`/`cargo:rustc-` key.
//! Exit status: the script's if it failed (stdout and stderr are printed), 1 for a refusal, 2 for this program's own.

const std = @import("std");

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("bs_runner: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn refuse(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("bs_runner: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn oom() noreturn {
    die("out of memory", .{});
}

fn absPath(a: std.mem.Allocator, cwd: []const u8, p: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(p)) return p;
    return std.fs.path.join(a, &.{ cwd, p }) catch oom();
}

fn join(a: std.mem.Allocator, parts: []const []const u8) []const u8 {
    return std.fs.path.join(a, parts) catch oom();
}

fn pf(a: std.mem.Allocator, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(a, f, args) catch oom();
}

const Pair = struct { name: []const u8, value: []const u8 };

const Dep = struct { links: []const u8, run_dir: []const u8, manifest: []const u8 };

const Config = struct {
    exe: []const u8 = "",
    out: []const u8 = "",
    manifest: []const u8 = "",
    sysroot: []const u8 = "",
    launcher: []const u8 = "",
    zig: []const u8 = "",
    cc_target: []const u8 = "",
    triple: []const u8 = "",
    links: ?[]const u8 = null,
    envs: std.ArrayList(Pair) = .empty,
    deps: std.ArrayList(Dep) = .empty,
    stamp_env: std.ArrayList(Pair) = .empty,
    stamp_rustc_env: std.ArrayList(Pair) = .empty,
};

fn splitPair(s: []const u8, what: []const u8) Pair {
    const i = std.mem.indexOfScalar(u8, s, '=') orelse die("{s}: expected NAME=VALUE, got '{s}'", .{ what, s });
    return .{ .name = s[0..i], .value = s[i + 1 ..] };
}

fn parseArgs(a: std.mem.Allocator, args: []const []const u8) Config {
    var c = Config{};
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) die("{s} needs a value", .{args[i]});
        const k = args[i];
        const v = args[i + 1];
        if (std.mem.eql(u8, k, "--exe")) {
            c.exe = v;
        } else if (std.mem.eql(u8, k, "--out")) {
            c.out = v;
        } else if (std.mem.eql(u8, k, "--manifest")) {
            c.manifest = v;
        } else if (std.mem.eql(u8, k, "--sysroot")) {
            c.sysroot = v;
        } else if (std.mem.eql(u8, k, "--launcher")) {
            c.launcher = v;
        } else if (std.mem.eql(u8, k, "--zig")) {
            c.zig = v;
        } else if (std.mem.eql(u8, k, "--cc-target")) {
            c.cc_target = v;
        } else if (std.mem.eql(u8, k, "--triple")) {
            c.triple = v;
        } else if (std.mem.eql(u8, k, "--links")) {
            c.links = v;
        } else if (std.mem.eql(u8, k, "--env")) {
            c.envs.append(a, splitPair(v, "--env")) catch oom();
        } else if (std.mem.eql(u8, k, "--stamp-env")) {
            c.stamp_env.append(a, splitPair(v, "--stamp-env")) catch oom();
        } else if (std.mem.eql(u8, k, "--stamp-rustc-env")) {
            c.stamp_rustc_env.append(a, splitPair(v, "--stamp-rustc-env")) catch oom();
        } else if (std.mem.eql(u8, k, "--dep")) {
            const p = splitPair(v, "--dep");
            const j = std.mem.indexOfScalar(u8, p.value, '=') orelse die("--dep LINKS=RUNDIR=MANIFEST, got '{s}'", .{v});
            c.deps.append(a, .{ .links = p.name, .run_dir = p.value[0..j], .manifest = p.value[j + 1 ..] }) catch oom();
        } else {
            die("unknown argument {s}", .{k});
        }
    }
    inline for (.{ "exe", "out", "manifest", "sysroot", "launcher", "zig", "cc_target", "triple" }) |f| {
        if (@field(c, f).len == 0) die("--{s} is required", .{f});
    }
    return c;
}

/// cargo's `envify`: upper case, `-` becomes `_`.
fn envify(a: std.mem.Allocator, s: []const u8) []const u8 {
    const out = a.alloc(u8, s.len) catch oom();
    for (s, 0..) |ch, i| out[i] = if (ch == '-') '_' else std.ascii.toUpper(ch);
    return out;
}

fn readTrim(a: std.mem.Allocator, path: []const u8) []const u8 {
    const t = std.fs.cwd().readFileAlloc(a, path, 1 << 20) catch |e| die("cannot read {s}: {s}", .{ path, @errorName(e) });
    return std.mem.trim(u8, t, " \t\r\n");
}

fn replaceAll(a: std.mem.Allocator, hay: []const u8, needle: []const u8, repl: []const u8) []const u8 {
    if (needle.len == 0) return hay;
    return std.mem.replaceOwned(u8, a, hay, needle, repl) catch oom();
}

/// `manifest_rel` is the manifest directory as the action names it (relative to the execution root), which is what a
/// script that read `env!("CARGO_MANIFEST_DIR")` when it was compiled has (libsqlite3-sys's `cargo:include=`).
const Paths = struct { out_dir: []const u8, manifest: []const u8, manifest_rel: []const u8 };

/// This action's directories become tokens: nothing worker-specific is written to an output.
fn tokenize(a: std.mem.Allocator, s: []const u8, p: Paths) []const u8 {
    const x = replaceAll(a, replaceAll(a, s, p.out_dir, "{OUT_DIR}"), p.manifest, "{MANIFEST_DIR}");
    return replaceAll(a, x, p.manifest_rel, "{MANIFEST_DIR}");
}

fn writeFile(path: []const u8, data: []const u8) void {
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = data }) catch |e| die("cannot write {s}: {s}", .{ path, @errorName(e) });
}

fn spawnCfg(a: std.mem.Allocator, rustc: []const u8, scratch: []const u8) []const u8 {
    var env = std.process.EnvMap.init(a);
    env.put("PATH", "") catch oom();
    env.put("BUCK_SCRATCH_PATH", join(a, &.{ scratch, "rc0" })) catch oom();
    const r = std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ rustc, "--print=cfg" },
        .env_map = &env,
        .max_output_bytes = 1 << 20,
    }) catch |e| die("cannot run {s}: {s}", .{ rustc, @errorName(e) });
    switch (r.term) {
        .Exited => |code| if (code != 0) die("rustc --print=cfg failed ({d}): {s}", .{ code, r.stderr }),
        else => die("rustc --print=cfg did not exit: {s}", .{r.stderr}),
    }
    return r.stdout;
}

/// `CARGO_CFG_<NAME>` for every cfg of the target: `key="a"` and `key="b"` become `a,b`; a bare `unix` is empty.
fn putCfgEnv(a: std.mem.Allocator, env: *std.process.EnvMap, text: []const u8) void {
    var names = std.ArrayList([]const u8).empty;
    var values = std.StringHashMap(std.ArrayList(u8)).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0) continue;
        var key = line;
        var val: []const u8 = "";
        if (std.mem.indexOfScalar(u8, line, '=')) |i| {
            key = line[0..i];
            val = std.mem.trim(u8, line[i + 1 ..], "\"");
        }
        const name = pf(a, "CARGO_CFG_{s}", .{envify(a, key)});
        const e = values.getOrPut(name) catch oom();
        if (!e.found_existing) {
            e.value_ptr.* = .empty;
            names.append(a, name) catch oom();
        } else {
            e.value_ptr.append(a, ',') catch oom();
        }
        e.value_ptr.appendSlice(a, val) catch oom();
    }
    for (names.items) |n| env.put(n, values.get(n).?.items) catch oom();
}

fn linkSearch(a: std.mem.Allocator, v: []const u8) []const u8 {
    // `KIND=PATH` or `PATH`; a relative path is relative to the package root.
    var kind: []const u8 = "";
    var path = v;
    if (std.mem.indexOfScalar(u8, v, '=')) |i| {
        kind = v[0 .. i + 1];
        path = v[i + 1 ..];
    }
    if (path.len > 0 and path[0] != '/' and path[0] != '{') path = pf(a, "{{MANIFEST_DIR}}/{s}", .{path});
    return pf(a, "{s}{s}", .{ kind, path });
}

const Outputs = struct {
    rustc_args: std.ArrayList(u8) = .empty,
    rustc_env: std.ArrayList(Pair) = .empty,
    metadata: std.ArrayList(u8) = .empty,
    rerun: std.ArrayList(u8) = .empty,
};

fn addArg(a: std.mem.Allocator, o: *Outputs, flag: []const u8, val: []const u8) void {
    o.rustc_args.appendSlice(a, flag) catch oom();
    o.rustc_args.append(a, '\n') catch oom();
    o.rustc_args.appendSlice(a, val) catch oom();
    o.rustc_args.append(a, '\n') catch oom();
}

fn setRustcEnv(a: std.mem.Allocator, o: *Outputs, name: []const u8, value: []const u8) void {
    for (o.rustc_env.items) |*p| {
        if (std.mem.eql(u8, p.name, name)) {
            p.value = value;
            return;
        }
    }
    o.rustc_env.append(a, .{ .name = name, .value = value }) catch oom();
}

fn directive(a: std.mem.Allocator, o: *Outputs, p: Paths, line: []const u8) void {
    var double = false;
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, line, "cargo::")) {
        double = true;
        rest = line[7..];
    } else if (std.mem.startsWith(u8, line, "cargo:")) {
        rest = line[6..];
    } else return;
    const eq = std.mem.indexOfScalar(u8, rest, '=') orelse {
        std.debug.print("bs_runner: ignoring a directive with no '=': {s}\n", .{line});
        return;
    };
    const key = rest[0..eq];
    const val = tokenize(a, rest[eq + 1 ..], p);
    if (std.mem.eql(u8, key, "rustc-cfg")) {
        addArg(a, o, "--cfg", val);
    } else if (std.mem.eql(u8, key, "rustc-check-cfg")) {
        addArg(a, o, "--check-cfg", val);
    } else if (std.mem.eql(u8, key, "rustc-link-lib")) {
        addArg(a, o, "-l", val);
    } else if (std.mem.eql(u8, key, "rustc-link-search")) {
        addArg(a, o, "-L", linkSearch(a, val));
    } else if (std.mem.eql(u8, key, "rustc-flags")) {
        // cargo accepts only -l and -L here, as `-l NAME` / `-lNAME` words.
        var words = std.mem.tokenizeScalar(u8, val, ' ');
        while (words.next()) |w| {
            if (std.mem.startsWith(u8, w, "-l") or std.mem.startsWith(u8, w, "-L")) {
                const flag = w[0..2];
                const arg = if (w.len > 2) w[2..] else words.next() orelse refuse("rustc-flags: {s} without a value", .{w});
                addArg(a, o, flag, if (w[1] == 'L') linkSearch(a, arg) else arg);
            } else refuse("rustc-flags: only -l and -L are accepted, got '{s}'", .{w});
        }
    } else if (std.mem.eql(u8, key, "rustc-env")) {
        const pr = splitPair(val, "rustc-env");
        setRustcEnv(a, o, pr.name, pr.value);
    } else if (std.mem.eql(u8, key, "warning")) {
        std.debug.print("build script warning: {s}\n", .{val});
    } else if (std.mem.eql(u8, key, "error")) {
        refuse("build script error: {s}", .{val});
    } else if (std.mem.eql(u8, key, "rerun-if-changed") or std.mem.eql(u8, key, "rerun-if-env-changed")) {
        o.rerun.appendSlice(a, pf(a, "{s}={s}\n", .{ key, val })) catch oom();
    } else if (std.mem.eql(u8, key, "metadata")) {
        _ = splitPair(val, "metadata");
        o.metadata.appendSlice(a, val) catch oom();
        o.metadata.append(a, '\n') catch oom();
    } else if (std.mem.startsWith(u8, key, "rustc-")) {
        refuse("directive not supported by buildrules v0: {s}", .{line});
    } else if (double) {
        refuse("unknown directive {s} (cargo:: takes only rustc-*, warning, error, rerun-if-*, metadata)", .{line});
    } else {
        // the old form: `cargo:KEY=VALUE` is metadata
        o.metadata.appendSlice(a, pf(a, "{s}={s}\n", .{ key, val })) catch oom();
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    const c = parseArgs(a, args);

    const cwd = try std.process.getCwdAlloc(a);
    const exe = absPath(a, cwd, c.exe);
    const out = absPath(a, cwd, c.out);
    const manifest = absPath(a, cwd, c.manifest);
    const launcher = absPath(a, cwd, c.launcher);
    const sysroot = absPath(a, cwd, c.sysroot);
    const zig = absPath(a, cwd, c.zig);
    const scratch_env = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch die("BUCK_SCRATCH_PATH is not set", .{});
    const s = join(a, &.{ absPath(a, cwd, scratch_env), "bs" });
    const out_dir = join(a, &.{ out, "OUT_DIR" });
    const paths = Paths{ .out_dir = out_dir, .manifest = manifest, .manifest_rel = if (std.fs.path.isAbsolute(c.manifest)) manifest else c.manifest };

    for ([_][]const u8{ out_dir, s, join(a, &.{ s, "home" }), join(a, &.{ s, "tmp" }), join(a, &.{ s, "emptybin" }), join(a, &.{ s, "rc" }) }) |d| {
        try std.fs.cwd().makePath(d);
    }
    // RUSTC, CC, CXX, AR, RANLIB: the launcher under those names, configured by the files beside the links.
    for ([_][]const u8{ "rustc", "cc", "c++", "ar", "ranlib" }) |n| {
        const link = join(a, &.{ s, n });
        std.fs.cwd().deleteFile(link) catch {};
        try std.fs.cwd().symLink(launcher, link, .{});
    }
    writeFile(join(a, &.{ s, "rustc.cfg" }), pf(a, "{s}\n{s}\n{s}\n", .{ sysroot, zig, c.cc_target }));
    writeFile(join(a, &.{ s, "cc.cfg" }), pf(a, "{s}\n{s}\n{s}\n{s}\n", .{ zig, c.cc_target, join(a, &.{ s, "home" }), cwd }));

    var env = std.process.EnvMap.init(a);
    for (c.envs.items) |p| try env.put(p.name, p.value);
    putCfgEnv(a, &env, spawnCfg(a, join(a, &.{ s, "rustc" }), s));
    const triple_us = replaceAll(a, c.triple, "-", "_");
    try env.put("CARGO_MANIFEST_DIR", manifest);
    if (c.links) |l| try env.put("CARGO_MANIFEST_LINKS", l);
    try env.put("OUT_DIR", out_dir);
    try env.put("TARGET", c.triple);
    try env.put("HOST", c.triple);
    try env.put("RUSTC", join(a, &.{ s, "rustc" }));
    try env.put("CC", join(a, &.{ s, "cc" }));
    try env.put("CXX", join(a, &.{ s, "c++" }));
    try env.put("AR", join(a, &.{ s, "ar" }));
    try env.put(pf(a, "CC_{s}", .{triple_us}), join(a, &.{ s, "cc" }));
    try env.put(pf(a, "CXX_{s}", .{triple_us}), join(a, &.{ s, "c++" }));
    try env.put(pf(a, "AR_{s}", .{triple_us}), join(a, &.{ s, "ar" }));
    try env.put("PATH", join(a, &.{ s, "emptybin" }));
    try env.put("TMPDIR", join(a, &.{ s, "tmp" }));
    try env.put("BUCK_SCRATCH_PATH", join(a, &.{ s, "rc" }));
    for (c.stamp_env.items) |p| try env.put(p.name, readTrim(a, absPath(a, cwd, p.value)));
    // DEP_<LINKS>_<KEY> from each direct dependency that has `links`.
    for (c.deps.items) |d| {
        const dir = absPath(a, cwd, d.run_dir);
        const dpaths = Paths{ .out_dir = join(a, &.{ dir, "OUT_DIR" }), .manifest = absPath(a, cwd, d.manifest), .manifest_rel = d.manifest };
        const text = std.fs.cwd().readFileAlloc(a, join(a, &.{ dir, "metadata" }), 1 << 22) catch |e| die("cannot read {s}/metadata: {s}", .{ dir, @errorName(e) });
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| {
            if (l.len == 0) continue;
            const pr = splitPair(l, "metadata line");
            const v = replaceAll(a, replaceAll(a, pr.value, "{OUT_DIR}", dpaths.out_dir), "{MANIFEST_DIR}", dpaths.manifest);
            try env.put(pf(a, "DEP_{s}_{s}", .{ envify(a, d.links), envify(a, pr.name) }), v);
        }
    }

    const r = std.process.Child.run(.{
        .allocator = a,
        .argv = &.{exe},
        .cwd = manifest,
        .env_map = &env,
        .max_output_bytes = 1 << 26,
    }) catch |e| die("cannot run the build script {s}: {s}", .{ exe, @errorName(e) });
    std.debug.print("{s}", .{r.stderr});
    const ok = switch (r.term) {
        .Exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        std.debug.print("{s}\nbs_runner: the build script failed: {any}\n", .{ r.stdout, r.term });
        std.process.exit(1);
    }

    var o = Outputs{};
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |raw| directive(a, &o, paths, std.mem.trimRight(u8, raw, "\r"));
    for (c.stamp_rustc_env.items) |p| setRustcEnv(a, &o, p.name, readTrim(a, absPath(a, cwd, p.value)));

    var env_text = std.ArrayList(u8).empty;
    for (o.rustc_env.items) |p| try env_text.appendSlice(a, pf(a, "{s}={s}\n", .{ p.name, p.value }));
    writeFile(join(a, &.{ out, "rustc_args" }), o.rustc_args.items);
    writeFile(join(a, &.{ out, "rustc_env" }), env_text.items);
    writeFile(join(a, &.{ out, "metadata" }), o.metadata.items);
    writeFile(join(a, &.{ out, "rerun_if" }), o.rerun.items);
    writeFile(join(a, &.{ out, "directives" }), tokenize(a, r.stdout, paths));
}
