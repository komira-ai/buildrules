//! Where `mojo sync` and `mojo check` keep the two pins tables (mojo_pins.bzl, mopm_pins.bzl): `toolchains/` by default, else the directory named by
//! `--toolchains` or by `toolchains` under `[buildrules]` in .buckconfig. Every test is named for the defect it catches. (mojo_cmd_test.zig holds the
//! rest of the two commands; the fake below is the smallest one that still checks the tables are where the test says before buck2 is asked.)

const std = @import("std");
const kit = @import("testkit.zig");
const ctxm = @import("ctx.zig");
const t = std.testing;

const fx = struct {
    const graph = @embedFile("fixture/mojo.graph.json");
    const manifest = @embedFile("fixture/mojo.mopm.toml");
    const mopm_lock = @embedFile("fixture/mojo.mopm.lock");
    const lib = @embedFile("fixture/mojo.lib.mojo");
    const test_src = @embedFile("fixture/mojo.test.mojo");
    const toolchain = "[toolchain]\nmopm = \"0.0.1\"\nmojo = \"1.0.0\"\n";
    const buck = "load(\":buildrules.mojo.bzl\", \"mojo_package\")\n\nmojo_package(path = \".\")\n";
};

const custom = "tools/build/cells/toolchains";

/// The directory the fake buck2 expects the two tables in: the build of the pinned mopm loads them, so they must be written before it is asked.
var tables_in: []const u8 = "toolchains";

fn fakeExec(ctx: *ctxm.Ctx, spec: ctxm.Exec) anyerror!ctxm.ExecResult {
    if (std.mem.endsWith(u8, spec.argv[0], "buck2")) {
        const mopm = try std.fmt.allocPrint(ctx.a, "{s}/mopm_pins.bzl", .{tables_in});
        const mojo = try std.fmt.allocPrint(ctx.a, "{s}/mojo_pins.bzl", .{tables_in});
        if (!ctx.exists(mopm) or !ctx.exists(mojo)) return .{ .code = 9 };
        return .{ .code = 0, .stdout = try std.fmt.allocPrint(ctx.a, "{s} /fake/mopm\n", .{spec.argv[2]}) };
    }
    return .{ .code = 0, .stdout = fx.graph };
}

/// A Mojo package before any sync, with `buckconfig` as the root .buckconfig and the custom toolchains directory (and `alt`, another one) in place.
fn repo(buckconfig: []const u8, expect_tables_in: []const u8) !*kit.Harness {
    const h = try kit.Harness.create();
    h.ctx.execer = &fakeExec;
    tables_in = expect_tables_in;
    try h.put(".buckconfig", buckconfig);
    try h.put("mopm-toolchain.toml", fx.toolchain);
    try h.put(custom ++ "/BUCK", "# toolchains\n");
    try h.put("alt/tc/BUCK", "# toolchains\n");
    try h.put("pkgs/base/mopm.toml", fx.manifest);
    try h.put("pkgs/base/mopm.lock", fx.mopm_lock);
    try h.put("pkgs/base/src/base/__init__.mojo", fx.lib);
    try h.put("pkgs/base/tests/test_base.mojo", fx.test_src);
    try h.put("pkgs/base/BUCK", fx.buck);
    return h;
}

fn expectTables(h: *kit.Harness, dir: []const u8, present: bool) !void {
    const a = h.a();
    for ([_][]const u8{ "mojo_pins.bzl", "mopm_pins.bzl" }) |name| {
        const p = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
        if (h.has(p) != present) {
            std.debug.print("{s}: expected {s}\n", .{ p, if (present) "written" else "absent" });
            return error.TablesInTheWrongPlace;
        }
    }
}

const sync_args = [_][]const u8{ "mojo", "sync", "--buck2", "./buck2" };

/// `base` and `--toolchains value`, for a value that is not known at compile time.
fn withTc(h: *kit.Harness, base: []const []const u8, value: []const u8) []const []const u8 {
    const out = h.a().alloc([]const u8, base.len + 2) catch @panic("out of memory");
    @memcpy(out[0..base.len], base);
    out[base.len] = "--toolchains";
    out[base.len + 1] = value;
    return out;
}

// ---- the default --------------------------------------------------------------------------------------

test "default: with neither the flag nor the setting, the tables are toolchains/mojo_pins.bzl and toolchains/mopm_pins.bzl (nothing changes for a repository that has no setting)" {
    const h = try repo("[cells]\n", "toolchains");
    defer h.destroy();
    const s = h.run(&sync_args);
    try t.expectEqual(@as(u8, 0), s.code);
    try expectTables(h, "toolchains", true);
    try expectTables(h, custom, false);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check" }).code);
}

test "default: the [cells] toolchains line of .buckconfig is not the setting (only [buildrules] toolchains is)" {
    // The cell of a Buck repository is named `toolchains` there and a section-blind reader would take its path for ours.
    const h = try repo("[cells]\n  toolchains = " ++ custom ++ "\n", "toolchains");
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&sync_args).code);
    try expectTables(h, "toolchains", true);
    try expectTables(h, custom, false);
}

// ---- a custom directory -------------------------------------------------------------------------------

test "flag: --toolchains moves both tables, sync --check and check agree, and without the flag check finds them stale" {
    const h = try repo("[cells]\n", custom);
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&(sync_args ++ [_][]const u8{ "--toolchains", custom })).code);
    try expectTables(h, custom, true);
    try expectTables(h, "toolchains", false);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check", "--toolchains", custom }).code);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--check", "--toolchains", custom }).code);
    // The default directory does not hold them: the gate of a consumer that forgot the setting is red, not green.
    const r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "STALE: toolchains/mojo_pins.bzl"));
    try t.expect(kit.contains(r.err, "STALE: toolchains/mopm_pins.bzl"));
}

test "flag: the path is normalized, so ./dir/ and dir name the same files" {
    const h = try repo("[cells]\n", custom);
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&(sync_args ++ [_][]const u8{ "--toolchains", "./" ++ custom ++ "/" })).code);
    const r = h.run(&.{ "mojo", "sync", "--check", "--toolchains", "alt/../" ++ custom });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, custom ++ "/mojo_pins.bzl is up to date"));
    try t.expect(kit.contains(r.out, custom ++ "/mopm_pins.bzl is up to date"));
}

test "setting: [buildrules] toolchains in .buckconfig moves the tables for sync and check alike; the last assignment wins; other sections and comments are ignored" {
    const bc = "[cells]\n  toolchains = decoy\n\n[buildrules]\n  # toolchains = comment\n  toolchains = alt/tc\n  toolchains =  " ++ custom ++ "  \n\n[other]\n  toolchains = other\n";
    const h = try repo(bc, custom);
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&sync_args).code);
    try expectTables(h, custom, true);
    try expectTables(h, "alt/tc", false);
    try expectTables(h, "toolchains", false);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check" }).code);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--check" }).code);
}

test "setting: the flag wins over the setting" {
    const h = try repo("[buildrules]\ntoolchains = " ++ custom ++ "\n", "alt/tc");
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&(sync_args ++ [_][]const u8{ "--toolchains", "alt/tc" })).code);
    try expectTables(h, "alt/tc", true);
    try expectTables(h, custom, false);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check", "--toolchains", "alt/tc" }).code);
}

test "a stale table is named by its custom path" {
    const h = try repo("[buildrules]\ntoolchains = " ++ custom ++ "\n", custom);
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&sync_args).code);
    try h.put(custom ++ "/mojo_pins.bzl", "# edited by hand\n");
    try h.put(custom ++ "/mopm_pins.bzl", "# edited by hand\n");
    const r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "STALE: " ++ custom ++ "/mojo_pins.bzl"));
    try t.expect(kit.contains(r.err, "STALE: " ++ custom ++ "/mopm_pins.bzl"));
}

test "a symbolic link that stays inside the repository is a toolchains directory" {
    const h = try repo("[cells]\n", custom);
    defer h.destroy();
    try h.tmp.dir.symLink(custom, "alias", .{});
    try t.expectEqual(@as(u8, 0), h.run(&(sync_args ++ [_][]const u8{ "--toolchains", "alias" })).code);
    try expectTables(h, custom, true);
}

// ---- refused ------------------------------------------------------------------------------------------

const Refusal = struct { value: []const u8, message: []const u8 };

const refusals = [_]Refusal{
    // Not there: a name that is nothing, and a name that is a file.
    .{ .value = "no/such/dir", .message = "no such directory" },
    .{ .value = "mopm-toolchain.toml", .message = "no such directory" },
    // Outside, by a path that exists (alt/ is there, so only the escape can be what is refused) and by the bare parent.
    .{ .value = "alt/../../elsewhere", .message = "is outside the repository" },
    .{ .value = "..", .message = "is outside the repository" },
    .{ .value = "../" ++ custom, .message = "is outside the repository" },
    .{ .value = "/usr", .message = "is an absolute path" },
    .{ .value = "", .message = "is empty" },
    .{ .value = ".", .message = "is the repository root itself" },
    .{ .value = "alt/..", .message = "is the repository root itself" },
};

fn expectNothingWritten(h: *kit.Harness) !void {
    try expectTables(h, "toolchains", false);
    try expectTables(h, custom, false);
    if (h.has("pkgs/base/buildrules.mojo.lock.bzl") or h.has("pkgs/base/buildrules.mojo.bzl")) return error.ARefusedRunWrote;
}

test "flag: a directory that does not exist, is outside the repository, is absolute, is empty or is the root is refused by sync and check, and nothing is written" {
    for (refusals) |rf| {
        const h = try repo("[cells]\n", "toolchains");
        defer h.destroy();
        for ([_][]const []const u8{ withTc(h, &sync_args, rf.value), withTc(h, &.{ "mojo", "check" }, rf.value) }) |argv| {
            const r = h.run(argv);
            if (r.code != 1 or !kit.contains(r.err, rf.message) or !kit.contains(r.err, "--toolchains")) {
                std.debug.print("`--toolchains {s}` with {s}: exit {d}, wanted 1 and `{s}`; stderr: {s}\n", .{ rf.value, argv[1], r.code, rf.message, r.err });
                return error.NotRefused;
            }
        }
        try expectNothingWritten(h);
    }
}

test "setting: the same refusals for [buildrules] toolchains, naming the .buckconfig line" {
    for (refusals) |rf| {
        const bc = try std.fmt.allocPrint(t.allocator, "[buildrules]\ntoolchains = {s}\n", .{rf.value});
        defer t.allocator.free(bc);
        const h = try repo(bc, "toolchains");
        defer h.destroy();
        for ([_][]const []const u8{ &sync_args, &.{ "mojo", "check" } }) |argv| {
            const r = h.run(argv);
            if (r.code != 1 or !kit.contains(r.err, rf.message) or !kit.contains(r.err, ".buckconfig [buildrules] toolchains")) {
                std.debug.print("setting `{s}` with {s}: exit {d}, wanted 1 and `{s}`; stderr: {s}\n", .{ rf.value, argv[1], r.code, rf.message, r.err });
                return error.NotRefused;
            }
        }
        try expectNothingWritten(h);
    }
}

test "a symbolic link that leads out of the repository is refused, also when the other directory's name starts with the root's" {
    const h = try repo("[cells]\n", "toolchains");
    defer h.destroy();
    var other = std.testing.tmpDir(.{});
    defer other.cleanup();
    const abs = try other.dir.realpathAlloc(t.allocator, ".");
    defer t.allocator.free(abs);
    try h.tmp.dir.symLink(abs, "linkout", .{});
    // A sibling of the root whose path begins with the root's path: a prefix test without the separator takes it for a directory inside.
    const sibling = try std.fmt.allocPrint(t.allocator, "{s}-sibling", .{h.tmp.sub_path});
    defer t.allocator.free(sibling);
    try h.tmp.parent_dir.makeDir(sibling);
    defer h.tmp.parent_dir.deleteDir(sibling) catch {};
    const rel = try std.fmt.allocPrint(t.allocator, "../{s}", .{sibling});
    defer t.allocator.free(rel);
    try h.tmp.dir.symLink(rel, "linksibling", .{});
    // And a link to the root itself, which is not below it.
    try h.tmp.dir.symLink(".", "linkroot", .{});
    for ([_][]const u8{ "linkout", "linksibling", "linkroot" }) |link| {
        const r = h.run(withTc(h, &sync_args, link));
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, "does not lead to a directory below the repository root"));
        const c = h.run(withTc(h, &.{ "mojo", "check" }, link));
        try t.expectEqual(@as(u8, 1), c.code);
        try t.expect(kit.contains(c.err, "a symbolic link takes it out"));
    }
    try expectNothingWritten(h);
}

test "flag: --toolchains without a value is a usage error for sync and check" {
    const h = try repo("[cells]\n", "toolchains");
    defer h.destroy();
    for ([_][]const []const u8{ &.{ "mojo", "sync", "--toolchains" }, &.{ "mojo", "check", "--toolchains" } }) |argv| {
        const r = h.run(argv);
        try t.expectEqual(@as(u8, 2), r.code);
        try t.expect(kit.contains(r.err, "--toolchains needs a value"));
    }
}

test "the usage text names --toolchains and the setting" {
    const h = try repo("[cells]\n", "toolchains");
    defer h.destroy();
    const r = h.run(&.{ "mojo", "--help" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, "[--toolchains TC_DIR]"));
    try t.expect(kit.contains(r.out, "toolchains = TC_DIR"));
}
