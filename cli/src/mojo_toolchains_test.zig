//! Where `mojo sync` and `mojo check` keep the two pins tables (mojo_pins.bzl, mopm_pins.bzl): `toolchains/` by default, else the directory the
//! `toolchains` cell has in the root .buckconfig (`[cells] toolchains = DIR`); `--toolchains` only asserts that directory. Every test is named for the
//! defect it catches. (mojo_cmd_test.zig holds the
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

test "default: a [buildrules] toolchains line is not read (the cell is the one place the path is configured)" {
    // The setting of the first version of this option: a repository that still has it, with the cell elsewhere, must get the tables where the cell is.
    const h = try repo("[cells]\n  toolchains = " ++ custom ++ "\n[buildrules]\n  toolchains = alt/tc\n", custom);
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&sync_args).code);
    try expectTables(h, custom, true);
    try expectTables(h, "alt/tc", false);
    try expectTables(h, "toolchains", false);
}

// ---- the cell ------------------------------------------------------------------------------------------

test "cell: [cells] toolchains moves both tables for sync, sync --check and check alike, and a stale table there is found" {
    const h = try repo("[cells]\n  toolchains = " ++ custom ++ "\n", custom);
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&sync_args).code);
    try expectTables(h, custom, true);
    try expectTables(h, "toolchains", false);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check" }).code);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "sync", "--check" }).code);
    try h.put(custom ++ "/mopm_pins.bzl", "# stale\n");
    const r = h.run(&.{ "mojo", "check" });
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(kit.contains(r.err, "STALE: " ++ custom ++ "/mopm_pins.bzl"));
}

test "cell: the last assignment wins; other sections, comments, near-miss keys and near-miss sections are ignored" {
    // Every near miss comes after the real line, so a reader that takes it for the key (by prefix) ends with the wrong directory.
    const bc = "[cells]\n  toolchains = decoy\n  # toolchains = comment\n  ; toolchains = comment\n  toolchains =  " ++ custom ++ "  \n" ++
        "  toolchains_extra = alt/tc\n  toolchain = alt/tc\n  xtoolchains = alt/tc\n\n" ++
        "[cells_extra]\n  toolchains = alt/tc\n[xcells]\n  toolchains = alt/tc\n[cell]\n  toolchains = alt/tc\n[other]\n  toolchains = alt/tc\n";
    const h = try repo(bc, custom);
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&sync_args).code);
    try expectTables(h, custom, true);
    try expectTables(h, "alt/tc", false);
    try expectTables(h, "toolchains", false);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check" }).code);
}

test "cell: a section header with a trailing comment is still the section, and a header with other text after it is not" {
    const h = try repo("[cells] # the cells\n  toolchains = " ++ custom ++ "\n", custom);
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&sync_args).code);
    try expectTables(h, custom, true);
    const g = try repo("[cells] extra\n  toolchains = alt/tc\n", "toolchains");
    defer g.destroy();
    try t.expectEqual(@as(u8, 0), g.run(&sync_args).code);
    try expectTables(g, "toolchains", true);
    try expectTables(g, "alt/tc", false);
}

test "cell: a .buckconfig with CRLF line ends is read the same (the carriage return is not part of the section or the path)" {
    const h = try repo("[cells]\r\n  toolchains = " ++ custom ++ "\r\n  other = x\r\n", custom);
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&sync_args).code);
    try expectTables(h, custom, true);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check" }).code);
}

test "include: a root .buckconfig with an include line is refused (it is not followed, so the cell's path might be missed), and nothing is written" {
    for ([_][]const u8{ "<file:.buckconfig.farm>\n[cells]\n  toolchains = " ++ custom ++ "\n", "[cells]\n  toolchains = " ++ custom ++ "\n  <?file:.buckconfig.local>\n" }) |bc| {
        const h = try repo(bc, custom);
        defer h.destroy();
        for ([_][]const []const u8{ &sync_args, &.{ "mojo", "check" }, &.{ "mojo", "check", "--toolchains", custom } }) |argv| {
            const r = h.run(argv);
            try t.expectEqual(@as(u8, 1), r.code);
            try t.expect(kit.contains(r.err, "include line"));
            try t.expect(kit.contains(r.err, "<"));
        }
        try expectNothingWritten(h);
    }
}

// ---- --toolchains is an assertion ---------------------------------------------------------------------

test "flag: the flag that names the cell's directory is accepted, however it is spelled, by sync, sync --check and check" {
    const h = try repo("[cells]\n  toolchains = " ++ custom ++ "\n", custom);
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&(sync_args ++ [_][]const u8{ "--toolchains", custom })).code);
    try expectTables(h, custom, true);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check", "--toolchains", custom }).code);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check", "--toolchains", "./" ++ custom ++ "/" }).code);
    const r = h.run(&.{ "mojo", "sync", "--check", "--toolchains", "alt/../" ++ custom });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, custom ++ "/mojo_pins.bzl is up to date"));
    try t.expect(kit.contains(r.out, custom ++ "/mopm_pins.bzl is up to date"));
}

test "flag: with no [cells] toolchains line the flag may only name toolchains" {
    const h = try repo("[cells]\n", "toolchains");
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&(sync_args ++ [_][]const u8{ "--toolchains", "toolchains" })).code);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check", "--toolchains", "toolchains/" }).code);
}

test "flag: a flag that is not the cell's directory is refused by sync and check, naming both, and nothing is written" {
    const Case = struct { bc: []const u8, flag: []const u8, cell: []const u8 };
    const cases = [_]Case{
        // The cell is moved and the flag is the old (or another) place.
        .{ .bc = "[cells]\n  toolchains = " ++ custom ++ "\n", .flag = "alt/tc", .cell = custom },
        .{ .bc = "[cells]\n  toolchains = " ++ custom ++ "\n", .flag = "toolchains", .cell = custom },
        // No cell line: the cell is toolchains/.
        .{ .bc = "[cells]\n", .flag = custom, .cell = "toolchains" },
        // Spellings that are not the same directory.
        .{ .bc = "[cells]\n  toolchains = " ++ custom ++ "\n", .flag = "/" ++ custom, .cell = custom },
        .{ .bc = "[cells]\n  toolchains = " ++ custom ++ "\n", .flag = "", .cell = custom },
        .{ .bc = "[cells]\n  toolchains = " ++ custom ++ "\n", .flag = ".", .cell = custom },
        .{ .bc = "[cells]\n  toolchains = " ++ custom ++ "\n", .flag = custom ++ "/..", .cell = custom },
    };
    for (cases) |c| {
        const h = try repo(c.bc, "toolchains");
        defer h.destroy();
        for ([_][]const []const u8{ withTc(h, &sync_args, c.flag), withTc(h, &.{ "mojo", "check" }, c.flag) }) |argv| {
            const r = h.run(argv);
            if (r.code != 1 or !kit.contains(r.err, "is not the toolchains cell") or !kit.contains(r.err, c.cell)) {
                std.debug.print("`--toolchains {s}` with {s}: exit {d}; stderr: {s}\n", .{ c.flag, argv[1], r.code, r.err });
                return error.NotRefused;
            }
        }
        try expectNothingWritten(h);
    }
}

test "a stale table is named by its custom path" {
    const h = try repo("[cells]\n  toolchains = " ++ custom ++ "\n", custom);
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
    const h = try repo("[cells]\n  toolchains = alias\n", custom);
    defer h.destroy();
    try h.tmp.dir.symLink(custom, "alias", .{});
    try t.expectEqual(@as(u8, 0), h.run(&sync_args).code);
    try expectTables(h, custom, true);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check" }).code);
}

// ---- inside a package ---------------------------------------------------------------------------------

test "a toolchains directory inside a Mojo package's tree is refused by sync and check, also through a symbolic link, and nothing is written" {
    const h = try repo("[cells]\n  toolchains = pkgs/base/tc\n", "toolchains");
    defer h.destroy();
    try h.put("pkgs/base/tc/BUCK", "# toolchains\n");
    try h.tmp.dir.symLink("pkgs/base", "viapkg", .{});
    try h.put("pkgs/base/sub/BUCK", "# in the package\n");
    for ([_][]const u8{ "pkgs/base/tc", "viapkg/sub", "viapkg", "pkgs/base" }) |dir| {
        try h.put(".buckconfig", try std.fmt.allocPrint(h.a(), "[cells]\n  toolchains = {s}\n", .{dir}));
        for ([_][]const []const u8{ &sync_args, &.{ "mojo", "check" } }) |argv| {
            const r = h.run(argv);
            if (r.code != 1 or !kit.contains(r.err, "inside the Mojo package pkgs/base")) {
                std.debug.print("cell {s} with {s}: exit {d}; stderr: {s}\n", .{ dir, argv[1], r.code, r.err });
                return error.NotRefused;
            }
        }
    }
    try expectNothingWritten(h);
    if (h.has("pkgs/base/tc/mopm_pins.bzl") or h.has("pkgs/base/mopm_pins.bzl")) return error.ARefusedRunWrote;
}

test "a toolchains directory next to a package whose name it starts with is not inside the package" {
    const h = try repo("[cells]\n  toolchains = pkgs/base2/tc\n", "pkgs/base2/tc");
    defer h.destroy();
    try h.put("pkgs/base2/tc/BUCK", "# toolchains\n");
    try t.expectEqual(@as(u8, 0), h.run(&sync_args).code);
    try expectTables(h, "pkgs/base2/tc", true);
    try t.expectEqual(@as(u8, 0), h.run(&.{ "mojo", "check" }).code);
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

test "cell: a directory that does not exist, is outside the repository, is absolute, is empty or is the root is refused by sync and check, naming the .buckconfig line, and nothing is written" {
    for (refusals) |rf| {
        const bc = try std.fmt.allocPrint(t.allocator, "[cells]\ntoolchains = {s}\n", .{rf.value});
        defer t.allocator.free(bc);
        const h = try repo(bc, "toolchains");
        defer h.destroy();
        for ([_][]const []const u8{ &sync_args, &.{ "mojo", "check" } }) |argv| {
            const r = h.run(argv);
            if (r.code != 1 or !kit.contains(r.err, rf.message) or !kit.contains(r.err, ".buckconfig [cells] toolchains")) {
                std.debug.print("cell `{s}` with {s}: exit {d}, wanted 1 and `{s}`; stderr: {s}\n", .{ rf.value, argv[1], r.code, rf.message, r.err });
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
        try h.put(".buckconfig", try std.fmt.allocPrint(h.a(), "[cells]\n  toolchains = {s}\n", .{link}));
        const r = h.run(&sync_args);
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(kit.contains(r.err, "does not lead to a directory below the repository root"));
        const c = h.run(&.{ "mojo", "check" });
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

test "the usage text names --toolchains and the cell" {
    const h = try repo("[cells]\n", "toolchains");
    defer h.destroy();
    const r = h.run(&.{ "mojo", "--help" });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(kit.contains(r.out, "[--toolchains TC_DIR]"));
    try t.expect(kit.contains(r.out, "`[cells] toolchains`"));
}
