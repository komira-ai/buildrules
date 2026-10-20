//! The contract (docs/contract.md in the buildrules repository), tested from the CLI's side: the
//! generated table parses against its schema version, the files this CLI writes are what the rules
//! load, and the metadata and exit codes are the ones the document names. The fixture is a real
//! generator run (init, cargo new crates/hello, sync). Every test is named for the defect it catches.

const std = @import("std");
const contract = @import("contract.zig");
const ctxm = @import("ctx.zig");
const kit = @import("testkit.zig");
const lockfile = @import("lockfile.zig");
const toolchain = @import("toolchain.zig");
const Diag = @import("diag.zig").Diag;
const t = std.testing;

const table = @embedFile("fixture/buildrules.lock.bzl");
const cargo_lock = @embedFile("fixture/Cargo.lock");
const root_cargo = @embedFile("fixture/root.Cargo.toml");
const hello_cargo = @embedFile("fixture/hello.Cargo.toml");
const rust_toolchain = @embedFile("fixture/rust-toolchain.toml");

fn parseOk(a: std.mem.Allocator, text: []const u8) !lockfile.Lock {
    var d = Diag.init(a);
    return lockfile.parse(a, "t.bzl", text, &d);
}

fn parseMsgs(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var d = Diag.init(a);
    _ = lockfile.parse(a, "t.bzl", text, &d) catch {};
    return std.mem.join(a, "\n", d.msgs.items);
}

// ---- the table ----------------------------------------------------------------------------------

test "the table a real sync produced parses against schema 2, and its hashes are the hashes of the files" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const l = try parseOk(a, table);
    try t.expectEqual(contract.schema, l.schema);
    try t.expectEqualStrings("1.95.0", l.rustc);
    try t.expectEqualStrings(contract.target, l.target);
    // Python's sha256 and Zig's agree: the check the Zig CLI makes is the one the generator recorded.
    try t.expectEqualStrings(try ctxm.sha256Hex(a, cargo_lock), l.lock_sha256);
    try t.expectEqual(@as(usize, 3), l.manifests.len);
    try t.expectEqualStrings(try ctxm.sha256Hex(a, root_cargo), lockfile.manifestHash(l, "Cargo.toml").?);
    try t.expectEqualStrings(try ctxm.sha256Hex(a, hello_cargo), lockfile.manifestHash(l, "crates/hello/Cargo.toml").?);
    try t.expectEqualStrings(try ctxm.sha256Hex(a, rust_toolchain), lockfile.manifestHash(l, "rust-toolchain.toml").?);
}

test "a table of another schema version is refused with both numbers" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for ([_][]const u8{ "1", "3", "20" }) |v| {
        const text = try std.mem.replaceOwned(u8, a, table, "SCHEMA = 2\n", try std.fmt.allocPrint(a, "SCHEMA = {s}\n", .{v}));
        const msgs = try parseMsgs(a, text);
        try t.expect(kit.contains(msgs, try std.fmt.allocPrint(a, "SCHEMA = {s}, but this buildrules reads schema 2", .{v})));
    }
    // No SCHEMA line at all is not schema 2 by default.
    const none = try std.mem.replaceOwned(u8, a, table, "SCHEMA = 2\n", "");
    try t.expect(kit.contains(try parseMsgs(a, none), "no `SCHEMA = N` line"));
}

test "every key check relies on is required, and a malformed one is named" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const lock_line = std.mem.indexOf(u8, table, "CARGO_LOCK_SHA256 = \"").?;
    const lock_end = std.mem.indexOfScalarPos(u8, table, lock_line, '\n').?;
    const without_lock = try std.mem.concat(a, u8, &.{ table[0..lock_line], table[lock_end + 1 ..] });
    try t.expect(kit.contains(try parseMsgs(a, without_lock), "no valid CARGO_LOCK_SHA256 line"));
    const bad_hash = try std.mem.replaceOwned(u8, a, table, "\"Cargo.toml\": \"", "\"Cargo.toml\": \"zz");
    try t.expect(kit.contains(try parseMsgs(a, bad_hash), "bad path or hash"));
    const no_rustc = try std.mem.replaceOwned(u8, a, table, "RUSTC = ", "RUSTCX = ");
    try t.expect(kit.contains(try parseMsgs(a, no_rustc), "no RUSTC line"));
    const no_target = try std.mem.replaceOwned(u8, a, table, "TARGET = ", "TARGETX = ");
    try t.expect(kit.contains(try parseMsgs(a, no_target), "no TARGET line"));
    // The block is one entry per line: the one-line dict form python's repr would give is refused.
    const one_line = try std.mem.replaceOwned(u8, a, table, "MANIFEST_SHA256 = {", "MANIFEST_SHA256 = {\"a\": \"b\"}\nX = {");
    try t.expect(kit.contains(try parseMsgs(a, one_line), "one entry per line"));
    const unclosed = try std.mem.replaceOwned(u8, a, table, "\n}\n\n# The Rust toolchain", "\n\n# The Rust toolchain");
    try t.expect(kit.contains(try parseMsgs(a, unclosed), "not closed") or kit.contains(try parseMsgs(a, unclosed), "not `    \"path\""));
}

test "the symbols the wrapper loads are all defined by the table, and the names the rules read are all exported" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const prefix = "load(\":" ++ contract.lock_file ++ "\", ";
    const at = std.mem.indexOf(u8, contract.bzl_text, prefix).?;
    const end = std.mem.indexOfScalarPos(u8, contract.bzl_text, at, ')').?;
    var it = std.mem.splitSequence(u8, contract.bzl_text[at + prefix.len .. end], ", ");
    var n: usize = 0;
    while (it.next()) |q| : (n += 1) {
        const name = std.mem.trim(u8, q, "\"");
        const def = try std.fmt.allocPrint(a, "\n{s} = ", .{name});
        try t.expect(kit.contains(table, def));
        // and the wrapper puts it in CARGO, which is what cargo_package reads
        try t.expect(kit.contains(contract.bzl_text, try std.fmt.allocPrint(a, "\"{s}\": {s},", .{ name, name })));
    }
    try t.expectEqual(@as(usize, 8), n);
}

// ---- the glue this CLI writes is what a real sync wrote ------------------------------------------------

test "golden: the Zig constants are byte for byte what the first real sync and cargo new wrote" {
    try t.expectEqualStrings(@embedFile("fixture/buildrules.bzl"), contract.bzl_text);
    try t.expectEqualStrings(@embedFile("fixture/root.BUCK"), contract.workspace_buck);
    try t.expectEqualStrings(@embedFile("fixture/hello.BUCK"), contract.member_buck);
    // The member manifest ends with the table cargo new adds; the root is what init wrote plus cargo's member.
    try t.expect(std.mem.endsWith(u8, hello_cargo, contract.member_metadata));
    try t.expect(kit.contains(root_cargo, "members = [\"crates/hello\"]"));
    try t.expect(kit.contains(root_cargo, contract.workspace_metadata_header));
}

test "the public load path in the wrapper and the BUCK files is the one the rules export" {
    try t.expect(kit.contains(contract.bzl_text, "load(\"@buildrules//rules/rust:defs.bzl\", _cargo_package = \"cargo_package\", _cargo_workspace = \"cargo_workspace\")"));
    try t.expect(kit.contains(contract.member_buck, "load(\"//:buildrules.bzl\", \"cargo_package\")"));
    try t.expect(kit.contains(contract.workspace_buck, "load(\"//:buildrules.bzl\", \"cargo_workspace\")"));
    try t.expect(kit.contains(contract.bzl_text, "THIRD_PARTY = \"//third_party/buildrules\""));
}

// ---- init's .buckconfig against the contract -----------------------------------------------------------

fn ini(text: []const u8, section: []const u8, key: []const u8) ?[]const u8 {
    var cur: []const u8 = "";
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            cur = line[1 .. line.len - 1];
            continue;
        }
        if (!std.mem.eql(u8, cur, section)) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) return std.mem.trim(u8, line[eq + 1 ..], " \t");
    }
    return null;
}

const commit = "0123456789abcdef0123456789abcdef01234567";

test "init's .buckconfig has every entry the contract lists, with the values it lists (git cell)" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&.{ "init", ".", "--git", "file:///srv/br", "--commit", commit, "--cell", "app" }).code);
    const c = h.read(".buckconfig");
    try t.expectEqualStrings(".", ini(c, "cells", "app").?);
    try t.expectEqualStrings("prelude", ini(c, "cells", "prelude").?);
    try t.expectEqualStrings("toolchains", ini(c, "cells", "toolchains").?);
    try t.expectEqualStrings("none", ini(c, "cells", "none").?);
    try t.expectEqualStrings("buildrules-ext", ini(c, "cells", "buildrules").?);
    try t.expectEqualStrings("prelude", ini(c, "cell_aliases", "config").?);
    try t.expectEqualStrings("bundled", ini(c, "external_cells", "prelude").?);
    try t.expectEqualStrings("git", ini(c, "external_cells", "buildrules").?);
    try t.expectEqualStrings("file:///srv/br", ini(c, "external_cell_buildrules", "git_origin").?);
    try t.expectEqualStrings(commit, ini(c, "external_cell_buildrules", "commit_hash").?);
    try t.expectEqualStrings("BUCK", ini(c, "buildfile", "name").?);
    try t.expectEqualStrings("app//platforms:exec", ini(c, "build", "execution_platforms").?);
    const spec = ini(c, "parser", "target_platform_detector_spec").?;
    inline for ([_][]const u8{ "target:app//...", "target:toolchains//...", "target:buildrules//..." }) |p| {
        try t.expect(kit.contains(spec, p ++ "->buildrules//platforms:linux_x86_64"));
    }
    try t.expectEqualStrings("deferred", ini(c, "buck2", "materializations").?);
    try t.expect(ini(c, "project", "ignore") != null);
}

test "init's .buckconfig for a path cell names the directory and has no external cell for buildrules" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&.{ "init", ".", "--path", "vendor/buildrules" }).code);
    const c = h.read(".buckconfig");
    try t.expectEqualStrings("vendor/buildrules", ini(c, "cells", "buildrules").?);
    try t.expect(ini(c, "external_cells", "buildrules") == null);
    try t.expect(ini(c, "external_cell_buildrules", "git_origin") == null);
}

test "no file init writes carries an endpoint, and the local-config example has the two sections the platform reads" {
    const h = try kit.Harness.create();
    defer h.destroy();
    try t.expectEqual(@as(u8, 0), h.run(&.{ "init", ".", "--path", "bu" }).code);
    const ex = h.read(".buckconfig.local.example");
    try t.expect(kit.contains(ex, "\n[buck2_re_client]\n"));
    try t.expect(kit.contains(ex, "\n[buildrules_re]\n"));
    // every value line is commented out
    var it = std.mem.splitScalar(u8, ex, '\n');
    while (it.next()) |l| {
        const tl = std.mem.trim(u8, l, " ");
        if (tl.len == 0 or tl[0] == '#' or tl[0] == '[') continue;
        return error.UncommentedValue;
    }
    try t.expect(kit.contains(h.read("platforms/BUCK"), "linux_x86_64 = \"buildrules//platforms:linux_x86_64\""));
    try t.expect(kit.contains(h.read("toolchains/BUCK"), "rust_toolchains(extra = EXTRA_RUST_VERSIONS)"));
}

// ---- metadata ------------------------------------------------------------------------------------------

fn knownKey(k: []const u8) bool {
    for (contract.policy_keys) |p| if (std.mem.eql(u8, p, k)) return true;
    return false;
}

test "the policy init writes uses only keys, steps and tables the contract names" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    _ = a;
    var table_name: []const u8 = "";
    var it = std.mem.splitScalar(u8, contract.workspace_manifest, '\n');
    var saw_actions = false;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            table_name = line;
            const meta = "[workspace.metadata.buildrules";
            if (std.mem.startsWith(u8, line, meta)) {
                const rest = line[meta.len..];
                if (rest.len > 1) try t.expect(knownKey(rest[1 .. rest.len - 1]));
            }
            continue;
        }
        if (!std.mem.startsWith(u8, table_name, "[workspace.metadata.buildrules")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=').?;
        const key = std.mem.trim(u8, line[0..eq], " ");
        if (std.mem.eql(u8, table_name, "[workspace.metadata.buildrules]")) {
            try t.expect(knownKey(key));
        } else if (std.mem.eql(u8, table_name, "[workspace.metadata.buildrules.actions]")) {
            saw_actions = true;
            // an action may not take a step's name, and chains only steps
            for (contract.steps) |s| try t.expect(!std.mem.eql(u8, key, s));
            for (contract.steps) |_| {}
            var chain = std.mem.splitScalar(u8, std.mem.trim(u8, line[eq + 1 ..], " []"), ',');
            while (chain.next()) |step| {
                const name = std.mem.trim(u8, step, " \"");
                var ok = false;
                for (contract.steps) |s| if (std.mem.eql(u8, s, name)) {
                    ok = true;
                };
                try t.expect(ok);
            }
        } else if (std.mem.eql(u8, table_name, "[workspace.metadata.buildrules.lint]")) {
            try t.expectEqualStrings(contract.lint_keys[0], key);
        }
    }
    try t.expect(saw_actions);
}

// ---- rust-toolchain.toml -------------------------------------------------------------------------------

test "rust-toolchain.toml: an exact release is the only channel; the fixture's is accepted" {
    try t.expectEqualStrings("1.95.0", toolchain.judge(rust_toolchain).ok);
    for ([_][]const u8{ "stable", "beta", "1.95", "1.95.0-beta.1", "1..0", "1.95.0.1.2", "", "01.95" }) |bad| {
        const text = try std.fmt.allocPrint(t.allocator, "[toolchain]\nchannel = \"{s}\"\n", .{bad});
        defer t.allocator.free(text);
        try t.expect(toolchain.judge(text) == .bad);
    }
    try t.expect(toolchain.judge(null) == .bad);
}

// ---- exit codes ----------------------------------------------------------------------------------------

test "the exit codes are the contract's: 0 ok, 1 failed or stale, 2 usage" {
    try t.expectEqual(contract.exit_ok, ctxm.exit_ok);
    try t.expectEqual(contract.exit_fail, ctxm.exit_fail);
    try t.expectEqual(contract.exit_usage, ctxm.exit_usage);
    const h = try kit.Harness.create();
    defer h.destroy();
    try t.expectEqual(@as(u8, 2), h.run(&.{}).code);
    try t.expectEqual(@as(u8, 2), h.run(&.{"frob"}).code);
    try t.expectEqual(@as(u8, 0), h.run(&.{"--help"}).code);
    // check on an empty directory: failed (1), not a crash
    try t.expectEqual(@as(u8, 1), h.run(&.{"check"}).code);
}
