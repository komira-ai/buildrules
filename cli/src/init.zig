//! `buildrules init`: the files a repository needs to build with buildrules (docs/contract.md,
//! "What init writes"). It writes what is absent and never overwrites; running it twice changes
//! nothing. Nothing it writes names an endpoint.

const std = @import("std");
const ctxm = @import("ctx.zig");
const contract = @import("contract.zig");
const toolchain = @import("toolchain.zig");
const pins_toml = @import("pins_toml.zig");
const valid = @import("valid.zig");
const Ctx = ctxm.Ctx;

/// The compiler an `init` pins when `--rust-version` is not given: the
/// release the buildrules toolchain (rules/rust/pins.bzl) downloads.
pub const default_rust = "1.95.0";

pub const usage_text =
    \\usage: buildrules init [DIR] (--path RELPATH | --git ORIGIN --commit SHA) [flags]
    \\
    \\  DIR                   the repository to set up (default .); created if absent
    \\  --path RELPATH        buildrules is a local cell at RELPATH inside DIR (a submodule or a vendored copy; Buck2 refuses ..)
    \\  --git ORIGIN          buildrules is a git external cell at ORIGIN (an https URL, or file:///abs/path for a local clone) ...
    \\  --commit SHA          ... pinned at this full 40-hex commit
    \\  --cell NAME           the name of DIR's own cell (default root)
    \\  --rust-version N.N.N  the compiler rust-toolchain.toml pins if it is absent (default 1.95.0)
    \\
;

const Source = union(enum) {
    path: []const u8,
    git: struct { origin: []const u8, commit: []const u8 },
};

fn isCommit(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

/// A cell path Buck2 accepts: inside the repository, normalized (it refuses `..` and
/// absolute paths: "expected a normalized path").
fn pathOk(s: []const u8) bool {
    if (s.len == 0 or s.len > 256 or s[0] == '/' or s[s.len - 1] == '/') return false;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return false;
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '-' or c == '_' or c == '.' or c == '/' or c == '+';
        if (!ok) return false;
    }
    return true;
}

fn buckconfig(a: std.mem.Allocator, cell: []const u8, src: Source) ![]u8 {
    var o = std.ArrayList(u8).empty;
    try o.print(a,
        \\# Written by `buildrules init`. buildrules is the cell `buildrules`; the cell name is
        \\# part of every output path, so it is not renamed. Where actions run is NOT here: a
        \\# remote-execution endpoint lives in .buckconfig.local (gitignored); see
        \\# .buckconfig.local.example.
        \\
        \\[cells]
        \\  {s} = .
        \\  prelude = prelude
        \\  toolchains = toolchains
        \\  none = none
        \\
    , .{cell});
    switch (src) {
        .path => |p| try o.print(a, "  buildrules = {s}\n", .{p}),
        .git => try o.appendSlice(a, "  # A git external cell needs no directory; nothing is checked out at this path.\n  buildrules = buildrules-ext\n"),
    }
    try o.appendSlice(a,
        \\
        \\[cell_aliases]
        \\  config = prelude
        \\  ovr_config = prelude
        \\  fbcode = none
        \\  fbsource = none
        \\  fbcode_macros = none
        \\  buck = none
        \\
        \\[external_cells]
        \\  prelude = bundled
        \\
    );
    switch (src) {
        .path => {},
        .git => |g| {
            try o.appendSlice(a, "  buildrules = git\n\n[external_cell_buildrules]\n");
            try o.print(a, "  git_origin = {s}\n  commit_hash = {s}\n", .{ g.origin, g.commit });
        },
    }
    try o.print(a,
        \\
        \\[buildfile]
        \\  name = BUCK
        \\
        \\[parser]
        \\  target_platform_detector_spec = target:{s}//...->buildrules//platforms:linux_x86_64 target:toolchains//...->buildrules//platforms:linux_x86_64 target:buildrules//...->buildrules//platforms:linux_x86_64
        \\
        \\[build]
        \\  execution_platforms = {s}//platforms:exec
        \\
        \\[buck2]
        \\  materializations = deferred
        \\  sqlite_materializer_state = true
        \\  defer_write_actions = true
        \\
        \\[project]
        \\  ignore = buck-out, .git
        \\
    , .{ cell, cell });
    return o.toOwnedSlice(a);
}

const toolchains_buck =
    \\# Written by `buildrules init`. One call: the pinned toolchains (everything by sha256).
    \\load("@buildrules//rules/rust:toolchain.bzl", "rust_toolchains")
    \\load(":rust_pins.bzl", "EXTRA_RUST_VERSIONS")
    \\
    \\# Every Rust version buildrules pins, plus the ones buildrules-pins.toml adds (rust_pins.bzl, written by `buildrules sync`).
    \\rust_toolchains(extra = EXTRA_RUST_VERSIONS)
    \\
;

const platforms_buck =
    \\# Written by `buildrules init`. Remote-only execution platform: the worker properties come
    \\# from `[buildrules_re]` in .buckconfig.local, so none is committed.
    \\load("@buildrules//rules:platforms.bzl", "buildrules_execution_platforms")
    \\
    \\buildrules_execution_platforms(
    \\    name = "exec",
    \\    linux_x86_64 = "buildrules//platforms:linux_x86_64",
    \\    visibility = ["PUBLIC"],
    \\)
    \\
;

const local_example =
    \\# Copy to .buckconfig.local (gitignored). Without a [buck2_re_client] endpoint no action
    \\# can run: the execution platform is remote-only, there is no local fallback.
    \\[buck2_re_client]
    \\  # engine_address = grpc://re.example.invalid:8980
    \\  # action_cache_address = grpc://re.example.invalid:8980
    \\  # cas_address = grpc://re.example.invalid:8980
    \\  # instance_name = main
    \\  # tls = true
    \\
    \\[buildrules_re]
    \\  # The exact REAPI property set of linux-x86_64 workers (key=value, comma separated).
    \\  # linux_x86_64_properties = OSFamily=Linux,ISA=x86-64,container-image=docker://<image>@sha256:<digest>
    \\
;

const ignore_lines = contract.ignore_lines;

/// Writes `path` when it is absent; says what it did.
fn putNew(ctx: *Ctx, path: []const u8, data: []const u8) !void {
    if (ctx.exists(path)) {
        ctx.say("kept    {s} (exists)", .{path});
        return;
    }
    try ctx.write(path, data);
    ctx.say("wrote   {s}", .{path});
}

pub fn run(root: *Ctx, args: []const []const u8) u8 {
    var dir: []const u8 = ".";
    var path: ?[]const u8 = null;
    var git: ?[]const u8 = null;
    var commit: ?[]const u8 = null;
    var cell: []const u8 = "root";
    var rust: []const u8 = default_rust;
    var have_dir = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--path")) {
            path = ctxm.flagValue(args, &i) orelse return root.usage("init: --path needs a value", .{});
        } else if (std.mem.eql(u8, arg, "--git")) {
            git = ctxm.flagValue(args, &i) orelse return root.usage("init: --git needs a value", .{});
        } else if (std.mem.eql(u8, arg, "--commit")) {
            commit = ctxm.flagValue(args, &i) orelse return root.usage("init: --commit needs a value", .{});
        } else if (std.mem.eql(u8, arg, "--cell")) {
            cell = ctxm.flagValue(args, &i) orelse return root.usage("init: --cell needs a value", .{});
        } else if (std.mem.eql(u8, arg, "--rust-version")) {
            rust = ctxm.flagValue(args, &i) orelse return root.usage("init: --rust-version needs a value", .{});
        } else if (arg.len > 0 and arg[0] == '-') {
            return root.usage("init: unknown flag {s}\n{s}", .{ arg, usage_text });
        } else if (!have_dir) {
            dir = arg;
            have_dir = true;
        } else {
            return root.usage("init: more than one directory\n{s}", .{usage_text});
        }
    }
    var src: Source = undefined;
    if (path != null and git == null and commit == null) {
        if (!pathOk(path.?)) return root.usage("init: --path {s} must be a normalized path inside the repository (no .., no leading or trailing /; letters, digits and -_./+ only): Buck2 refuses any other cell path", .{path.?});
        src = .{ .path = path.? };
    } else if (git != null and commit != null and path == null) {
        if (!valid.isGitOrigin(git.?)) return root.usage("init: --git {s} is not an http(s) URL or a file:///absolute/path", .{git.?});
        if (!isCommit(commit.?)) return root.usage("init: --commit must be the full 40 lower-case hex digits of a commit (a branch or tag is not a pin)", .{});
        src = .{ .git = .{ .origin = git.?, .commit = commit.? } };
    } else {
        return root.usage("init: give --path RELPATH, or --git ORIGIN with --commit SHA\n{s}", .{usage_text});
    }
    if (!valid.isPinName(cell)) return root.usage("init: --cell {s} is not a cell name (lower-case letters, digits, - and _)", .{cell});
    if (!toolchain.isExactRelease(rust)) return root.usage("init: --rust-version {s} is not an exact release N.N.N", .{rust});

    root.dir.makePath(dir) catch |e| return root.fail("cannot create {s}: {s}", .{ dir, @errorName(e) });
    var ctx = root.into(dir) catch |e| return root.fail("cannot open {s}: {s}", .{ dir, @errorName(e) });
    defer ctx.dir.close();
    return write(&ctx, cell, src, rust) catch |e| root.fail("init in {s}: {s}", .{ dir, @errorName(e) });
}

fn write(ctx: *Ctx, cell: []const u8, src: Source, rust: []const u8) !u8 {
    const a = ctx.a;
    var code: u8 = ctxm.exit_ok;
    const want = try buckconfig(a, cell, src);
    if (try ctx.readOpt(".buckconfig")) |have| {
        if (std.mem.eql(u8, have, want)) {
            ctx.say("kept    .buckconfig (exists, is what init writes)", .{});
        } else {
            // Merging into someone's config is guesswork; say what is needed instead.
            code = ctx.fail(".buckconfig exists and is left alone; the cells buildrules needs are in this one:\n{s}", .{want});
        }
    } else {
        try putNew(ctx, ".buckconfig", want);
    }
    try putNew(ctx, "toolchains/BUCK", toolchains_buck);
    try putNew(ctx, contract.rust_pins_file, pins_toml.empty);
    try putNew(ctx, "platforms/BUCK", platforms_buck);
    try putNew(ctx, ".buckconfig.local.example", local_example);
    const tc = try std.fmt.allocPrint(a, "# The compiler of every build and of plain `cargo`: an exact release, never a channel.\n[toolchain]\nchannel = \"{s}\"\ncomponents = [\"clippy\", \"rustfmt\"]\nprofile = \"minimal\"\n", .{rust});
    try putNew(ctx, "rust-toolchain.toml", tc);
    try putNew(ctx, "Cargo.toml", contract.workspace_manifest);

    const have = (try ctx.readOpt(".gitignore")) orelse "";
    const add = try ctxm.missingLines(a, have, &ignore_lines);
    if (add.len == 0) {
        ctx.say("kept    .gitignore (has the buildrules lines)", .{});
    } else {
        var o = std.ArrayList(u8).empty;
        try o.appendSlice(a, have);
        if (have.len > 0 and have[have.len - 1] != '\n') try o.append(a, '\n');
        for (add) |l| try o.print(a, "{s}\n", .{l});
        try ctx.write(".gitignore", o.items);
        ctx.say("{s} .gitignore (+{d} line{s})", .{ if (have.len == 0) "wrote  " else "appended", add.len, if (add.len == 1) "" else "s" });
    }
    return code;
}
