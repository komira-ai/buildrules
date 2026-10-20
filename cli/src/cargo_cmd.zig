//! `buildrules cargo new|init|adopt`: a Cargo package the build knows about (docs/contract.md, "What
//! cargo new/init/adopt write"). `new` and `init` run the pinned cargo (`--cargo`); all three then make
//! the package buildable: a BUCK file calling `cargo_package`, the `[package.metadata.buildrules]`
//! table, and a place in the root workspace's `members`. Every edit is idempotent, and nothing is
//! changed unless the repository root is a virtual Cargo workspace (v0).

const std = @import("std");
const contract = @import("contract.zig");
const ctxm = @import("ctx.zig");
const valid = @import("valid.zig");
const ws = @import("workspace.zig");
const Ctx = ctxm.Ctx;

pub const usage_text =
    \\usage: buildrules cargo new PATH [--cargo CARGO] [--lib]
    \\       buildrules cargo init [PATH] [--cargo CARGO] [--lib]
    \\       buildrules cargo adopt [PATH...]
    \\
    \\  new, init       run the pinned cargo (`cargo new|init --vcs none`), then adopt the package
    \\  adopt           a package that already builds with cargo: add its BUCK file and metadata table and
    \\                  make sure the workspace lists it; no PATH means every member of the workspace
    \\  --cargo CARGO   the pinned cargo binary to run. Without it the cargo step is skipped and a
    \\                  minimal manifest and source are written instead.
    \\  --lib           a library (default: a binary)
    \\
    \\The repository root must hold a Cargo.toml with a [workspace] and no [package] (`buildrules init`
    \\writes one); packages live in subdirectories.
    \\
;

pub const metadata_header = contract.metadata_header;

// ---- the three text edits (pure) -----------------------------------------------------

/// BUCK text with the load and the `cargo_package` call, or null when it has the call.
pub fn ensureBuck(a: std.mem.Allocator, text: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, text, "cargo_package(") != null) return null;
    var o = std.ArrayList(u8).empty;
    if (std.mem.indexOf(u8, text, "\"cargo_package\"") == null) {
        try o.appendSlice(a, contract.member_load);
        if (text.len > 0) try o.append(a, '\n');
    }
    try o.appendSlice(a, text);
    if (text.len > 0) {
        if (text[text.len - 1] != '\n') try o.append(a, '\n');
        try o.append(a, '\n');
    } else {
        try o.append(a, '\n');
    }
    try o.appendSlice(a, contract.member_call);
    return try o.toOwnedSlice(a);
}

pub const MetadataError = error{NoPackageTable};

/// Cargo.toml text with the buildrules metadata table, or null when it has one.
pub fn ensureMetadata(a: std.mem.Allocator, text: []const u8) (MetadataError || std.mem.Allocator.Error)!?[]u8 {
    if (ws.hasLine(text, metadata_header)) return null;
    if (!ws.hasLine(text, "[package]")) return error.NoPackageTable;
    var o = std.ArrayList(u8).empty;
    try o.appendSlice(a, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try o.append(a, '\n');
    try o.append(a, '\n');
    try o.appendSlice(a, contract.member_metadata);
    return try o.toOwnedSlice(a);
}

pub const Member = union(enum) {
    not_workspace,
    present,
    edited: []u8,
};

fn globCovers(pattern: []const u8, rel: []const u8) bool {
    if (std.mem.eql(u8, pattern, rel)) return true;
    if (std.mem.endsWith(u8, pattern, "/*")) {
        const prefix = pattern[0 .. pattern.len - 2];
        const d = std.fs.path.dirname(rel) orelse return false;
        return std.mem.eql(u8, prefix, d);
    }
    return false;
}

/// Adds `rel` to the `members` of the `[workspace]` of `text`.
pub fn ensureMember(a: std.mem.Allocator, text: []const u8, rel: []const u8) !Member {
    const sec = ws.workspaceSection(text) orelse return .not_workspace;
    const body = text[sec.start..sec.end];
    // The `members = [` line.
    var at: ?usize = null;
    var pos: usize = 0;
    while (pos < body.len) {
        const nl = std.mem.indexOfScalarPos(u8, body, pos, '\n');
        const line = body[pos .. nl orelse body.len];
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "members")) {
            const rest = std.mem.trim(u8, t["members".len..], " \t");
            if (rest.len > 0 and rest[0] == '=') {
                at = pos;
                break;
            }
        }
        pos = if (nl) |n| n + 1 else body.len;
    }
    if (at == null) {
        var o = std.ArrayList(u8).empty;
        try o.appendSlice(a, text[0..sec.start]);
        try o.print(a, "members = [\"{s}\"]\n", .{rel});
        try o.appendSlice(a, text[sec.start..]);
        return .{ .edited = try o.toOwnedSlice(a) };
    }
    const open = std.mem.indexOfScalarPos(u8, body, at.?, '[') orelse return error.BadMembers;
    // The closing bracket, skipping quoted strings.
    var j = open + 1;
    var in_str = false;
    var close: ?usize = null;
    while (j < body.len) : (j += 1) {
        const c = body[j];
        if (c == '"') {
            in_str = !in_str;
        } else if (c == ']' and !in_str) {
            close = j;
            break;
        }
    }
    const cl = close orelse return error.BadMembers;
    // Present?
    var k = open + 1;
    while (k < cl) {
        const q = std.mem.indexOfScalarPos(u8, body, k, '"') orelse break;
        if (q >= cl) break;
        const q2 = std.mem.indexOfScalarPos(u8, body, q + 1, '"') orelse break;
        if (globCovers(body[q + 1 .. q2], rel)) return .present;
        k = q2 + 1;
    }
    var last = cl;
    while (last > open + 1 and (body[last - 1] == ' ' or body[last - 1] == '\t' or body[last - 1] == '\n' or body[last - 1] == '\r')) last -= 1;
    const empty = last == open + 1;
    const multi = std.mem.indexOfScalar(u8, body[last..cl], '\n') != null;
    var ins = std.ArrayList(u8).empty;
    if (empty) {
        try ins.print(a, "\"{s}\"", .{rel});
    } else if (multi) {
        if (body[last - 1] != ',') try ins.append(a, ',');
        try ins.print(a, "\n    \"{s}\",", .{rel});
    } else {
        if (body[last - 1] != ',') try ins.append(a, ',');
        try ins.print(a, " \"{s}\"", .{rel});
    }
    const abs = sec.start + last;
    return .{ .edited = try std.mem.concat(a, u8, &.{ text[0..abs], ins.items, text[abs..] }) };
}

// ---- the command ----------------------------------------------------------------------

/// A relative path inside the working directory, without `./` or a trailing `/`.
fn normalize(a: std.mem.Allocator, p: []const u8) ![]const u8 {
    var s = p;
    while (std.mem.startsWith(u8, s, "./")) s = s[2..];
    while (s.len > 1 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];
    if (s.len == 0) return ".";
    if (s[0] == '/') return error.NotRelative;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |part| if (std.mem.eql(u8, part, "..") or part.len == 0) return error.NotRelative;
    return try a.dupe(u8, s);
}

fn join(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (std.mem.eql(u8, dir, ".")) return a.dupe(u8, name);
    return std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

const Verb = enum { new, init, adopt };

pub fn run(ctx: *Ctx, args: []const []const u8) u8 {
    if (args.len == 0) return ctx.usage("cargo: new, init or adopt?\n{s}", .{usage_text});
    const verb: Verb = if (std.mem.eql(u8, args[0], "new")) .new else if (std.mem.eql(u8, args[0], "init")) .init else if (std.mem.eql(u8, args[0], "adopt")) .adopt else return ctx.usage("cargo: unknown verb {s}\n{s}", .{ args[0], usage_text });
    var cargo: ?[]const u8 = null;
    var lib = false;
    var paths = std.ArrayList([]const u8).empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--cargo")) {
            if (verb == .adopt) return ctx.usage("cargo adopt: --cargo does not apply (adopt runs no cargo)", .{});
            cargo = ctxm.flagValue(args, &i) orelse return ctx.usage("cargo: --cargo needs a value", .{});
        } else if (std.mem.eql(u8, arg, "--lib")) {
            if (verb == .adopt) return ctx.usage("cargo adopt: --lib does not apply (adopt runs no cargo)", .{});
            lib = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            return ctx.usage("cargo: unknown flag {s}\n{s}", .{ arg, usage_text });
        } else {
            const p = normalize(ctx.a, arg) catch return ctx.usage("cargo: {s} is not a relative path inside the working directory", .{arg});
            paths.append(ctx.a, p) catch return ctx.fail("out of memory", .{});
        }
    }
    if (verb == .new and paths.items.len != 1) return ctx.usage("cargo new: exactly one PATH is required\n{s}", .{usage_text});
    if (verb == .init and paths.items.len > 1) return ctx.usage("cargo init: more than one path\n{s}", .{usage_text});
    return doRun(ctx, verb, paths.items, cargo, lib) catch |e| ctx.fail("cargo {s}: {s}", .{ @tagName(verb), @errorName(e) });
}

/// The root manifest, when it is a virtual workspace; otherwise the failure is printed and null returned.
fn rootManifest(ctx: *Ctx) !?[]const u8 {
    const text = (try ctx.readOpt("Cargo.toml")) orelse {
        _ = ctx.fail("no Cargo.toml at the repository root: run `buildrules init` (it writes a virtual workspace) and run this from the repository root", .{});
        return null;
    };
    if (ws.workspaceSection(text) == null) {
        _ = ctx.fail("the root Cargo.toml has no [workspace]: v0 builds a Cargo workspace whose root is the repository root", .{});
        return null;
    }
    if (ws.isPackage(text)) {
        _ = ctx.fail("the root Cargo.toml is a package ([package]): v0 wants a virtual workspace at the root and packages in subdirectories (crates/NAME)", .{});
        return null;
    }
    return text;
}

fn doRun(ctx: *Ctx, verb: Verb, paths: []const []const u8, cargo_arg: ?[]const u8, lib: bool) !u8 {
    const a = ctx.a;
    const root = (try rootManifest(ctx)) orelse return ctxm.exit_fail;
    switch (verb) {
        .adopt => {
            var targets: []const []const u8 = paths;
            if (paths.len == 0) {
                targets = ws.memberDirs(ctx, root) catch |e| switch (e) {
                    error.UnsupportedMemberPattern => return ctx.fail("a `members` entry is a glob buildrules does not expand (only `dir/*`): list the packages as PATH arguments", .{}),
                    else => return e,
                };
                if (targets.len == 0) {
                    ctx.say("adopt  no member packages in the workspace", .{});
                    return ctxm.exit_ok;
                }
            }
            for (targets) |pkg| {
                if (std.mem.eql(u8, pkg, ".")) return ctx.fail("cargo adopt: . is the workspace root, not a package", .{});
                const manifest = try join(a, pkg, "Cargo.toml");
                if (!ctx.exists(manifest)) return ctx.fail("cargo adopt: {s} is not a Cargo package (no Cargo.toml)", .{pkg});
                const code = try finish(ctx, pkg, manifest);
                if (code != 0) return code;
            }
            return ctxm.exit_ok;
        },
        .new, .init => {
            const is_new = verb == .new;
            const pkg: []const u8 = if (paths.len == 0) "." else paths[0];
            if (std.mem.eql(u8, pkg, ".")) return ctx.fail("cargo init: . is the workspace root; packages live in subdirectories (crates/NAME)", .{});
            const manifest = try join(a, pkg, "Cargo.toml");
            if (is_new) {
                if (ctx.exists(pkg)) return ctx.fail("cargo new: {s} already exists (use `buildrules cargo init` or `adopt`)", .{pkg});
            } else if (!ctx.exists(pkg)) {
                return ctx.fail("cargo init: {s} does not exist", .{pkg});
            }
            const have_manifest = ctx.exists(manifest);
            if (!is_new and have_manifest) {
                ctx.say("cargo   skipped: {s} is already a Cargo package", .{pkg});
            } else if (cargo_arg) |c| {
                const real = ctx.dir.realpathAlloc(a, c) catch return ctx.fail("--cargo {s}: {s}", .{ c, "not found" });
                var argv = std.ArrayList([]const u8).empty;
                try argv.appendSlice(a, &.{ real, if (is_new) "new" else "init", "--vcs", "none" });
                if (lib) try argv.append(a, "--lib");
                try argv.append(a, pkg);
                const code = try ctx.runner(ctx, argv.items);
                if (code != 0) return ctx.fail("cargo {s} {s} exited {d}; nothing else was changed", .{ if (is_new) "new" else "init", pkg, code });
                ctx.say("cargo   ran {s} {s}", .{ real, if (is_new) "new" else "init" });
            } else {
                ctx.say("cargo   skipped: --cargo (the pinned cargo) was not given; wrote a minimal manifest and source instead", .{});
                try scaffold(ctx, pkg, lib);
            }
            return finish(ctx, pkg, manifest);
        },
    }
}

fn scaffold(ctx: *Ctx, pkg: []const u8, lib: bool) !void {
    const a = ctx.a;
    const name: []const u8 = std.fs.path.basename(pkg);
    if (!valid.isCrateName(name)) return error.BadPackageName;
    try ctx.dir.makePath(pkg);
    const manifest = try join(a, pkg, "Cargo.toml");
    const body = try std.fmt.allocPrint(a, "[package]\nname = \"{s}\"\nversion = \"0.1.0\"\nedition = \"2024\"\n\n[dependencies]\n", .{name});
    try ctx.write(manifest, body);
    const src = try join(a, pkg, if (lib) "src/lib.rs" else "src/main.rs");
    if (!ctx.exists(src)) {
        const code = if (lib)
            "pub fn hello() -> &'static str {\n    \"hello\"\n}\n\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn says_hello() {\n        assert_eq!(super::hello(), \"hello\");\n    }\n}\n"
        else
            "fn main() {\n    println!(\"Hello, world!\");\n}\n";
        try ctx.write(src, code);
    }
}

fn finish(ctx: *Ctx, pkg: []const u8, manifest: []const u8) !u8 {
    const a = ctx.a;
    // [package.metadata.buildrules]
    const mtext = try ctx.read(manifest);
    const medit = ensureMetadata(a, mtext) catch |e| switch (e) {
        error.NoPackageTable => return ctx.fail("{s} has no [package] table (a virtual workspace manifest is not a package)", .{manifest}),
        else => return e,
    };
    if (medit) |t| {
        try ctx.write(manifest, t);
        ctx.say("edited  {s}: added {s}", .{ manifest, metadata_header });
    } else {
        ctx.say("kept    {s}: has {s}", .{ manifest, metadata_header });
    }
    // BUCK
    const buck = try join(a, pkg, "BUCK");
    const btext = (try ctx.readOpt(buck)) orelse "";
    if (try ensureBuck(a, btext)) |t| {
        try ctx.write(buck, t);
        ctx.say("{s} {s}: cargo_package(path = \".\")", .{ if (btext.len == 0) "wrote  " else "edited ", buck });
    } else {
        ctx.say("kept    {s}: has cargo_package", .{buck});
    }
    // The workspace: the root manifest's `members`.
    const wtext = try ctx.read("Cargo.toml");
    switch (try ensureMember(a, wtext, pkg)) {
        .not_workspace => unreachable,
        .present => ctx.say("kept    Cargo.toml: members already cover {s}", .{pkg}),
        .edited => |t| {
            try ctx.write("Cargo.toml", t);
            ctx.say("edited  Cargo.toml: members += \"{s}\"", .{pkg});
        },
    }
    return ctxm.exit_ok;
}
