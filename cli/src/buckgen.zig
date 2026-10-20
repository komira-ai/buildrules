//! The table to Buck2 targets: one `cargo_unit` target per registry unit of the table, named by the entry's content id,
//! and one `crate_src` per registry crate (a sha256-pinned download from static.crates.io plus an unpack), all in the one
//! package `third_party/buildrules`. Member units are not written here: `cargo_package` makes them from the table.
//!
//! Nothing here reads cargo, the workspace or (but for `sizesFile`) the network: table and sizes in, one BUCK file out, byte
//! for byte the same on a rerun. The sizes file (`name version bytes` per line) is what a registry download needs besides
//! its sha256; `sizesFile` writes it and checks every sha256 against the table.
//!
//! Overrides (`third_party/buildrules/overrides.json`): the one place a registry crate is told apart from what its build
//! script would do. Per "name version": `why` (required), `drop_build_script` (the crate's build script and its run are not
//! emitted, and nothing may depend on them), `cfgs` (added to the crate's units), `native_deps` (labels of static archives a
//! binary or test links) and `patch` (copy / sub / add on the unpacked crate, rules/rust/crate_patch.zig). An override that
//! matches no unit of the table is an error (a version bump that left it behind); registry units nothing reaches after the
//! drops are not emitted.

const std = @import("std");
const fetch = @import("fetch.zig");
const val = @import("val.zig");
const Diag = @import("diag.zig").Diag;
const Value = val.Value;

pub const Error = anyerror;

const load_line = "load(\"@buildrules//rules/rust:cargo_unit.bzl\", \"cargo_unit\", \"crate_src\")\n";

/// The package's own files as a target, for `cargo_sync` (rules/rust/sync.bzl): a glob cannot cross into this package from the root's.
fn filesTarget(a: std.mem.Allocator, overrides: bool) ![]const u8 {
    return std.fmt.allocPrint(a, "filegroup(\n    name = \"files\",\n    srcs = [\"BUCK\", \"crate_sizes.tsv\"{s}],\n    visibility = [\"PUBLIC\"],\n)\n", .{if (overrides) ", \"overrides.json\"" else ""});
}

fn die(d: *Diag, comptime fmt: []const u8, args: anytype) error{Refused} {
    d.add("buckgen: " ++ fmt, args);
    return error.Refused;
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// `tname`: a unit id as a target name.
fn tname(a: std.mem.Allocator, uid: []const u8) ![]u8 {
    const out = try a.dupe(u8, uid);
    std.mem.replaceScalar(u8, out, ':', '_');
    return out;
}

/// A Starlark string literal: quotes and backslashes escaped, nothing else.
fn q(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.append(a, '"');
    for (s) |c| {
        if (c == '\\' or c == '"') try out.append(a, '\\');
        try out.append(a, c);
    }
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

/// A list one item per line (`indent` is the items', the closing bracket is four columns left of it).
fn qlist(a: std.mem.Allocator, xs: []const []const u8, indent: []const u8) ![]u8 {
    if (xs.len == 0) return a.dupe(u8, "[]");
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, "[\n");
    for (xs) |x| try out.print(a, "{s}{s},\n", .{ indent, try q(a, x) });
    try out.appendSlice(a, indent[0 .. indent.len - 4]);
    try out.append(a, ']');
    return out.toOwnedSlice(a);
}

fn strField(u: Value, key: []const u8) []const u8 {
    return val.getStr(u, key) orelse "";
}

fn strings(a: std.mem.Allocator, v: ?Value) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (val.items(v)) |x| if (x == .string) try out.append(a, x.string);
    return out.toOwnedSlice(a);
}

/// The `strip` of a cargo profile as the label rustc takes it, or null for none.
fn stripOf(d: *Diag, p: Value) Error!?[]const u8 {
    const s = val.get(p, "strip") orelse return null;
    switch (s) {
        .null => return null,
        .string => |x| {
            if (std.mem.eql(u8, x, "none") or std.mem.eql(u8, x, "None")) return null;
        },
        .object => {
            if (val.get(s, "deferred") != null) return null;
            if (val.get(s, "resolved")) |r| {
                if (r == .string) {
                    if (std.mem.eql(u8, r.string, "None")) return null;
                    return r.string; // (lower-cased by the caller)
                }
                if (r == .object) {
                    if (val.get(r, "Named")) |n| if (n == .string) return n.string;
                }
            }
        },
        else => {},
    }
    return die(d, "unrecognized strip value", .{});
}

pub const Overrides = std.StringArrayHashMap(Value);

const override_keys = [_][]const u8{ "why", "drop_build_script", "cfgs", "native_deps", "patch" };

/// `overrides.json`: `{"crates": {"name version": {...}}}`. `label` names the file in messages.
pub fn loadOverrides(a: std.mem.Allocator, d: *Diag, label: []const u8, text: []const u8) Error!Overrides {
    var out = Overrides.init(a);
    const data = std.json.parseFromSliceLeaky(Value, a, text, .{}) catch |e| return die(d, "{s}: {s}", .{ label, @errorName(e) });
    if (data != .object or data.object.count() != 1 or !data.object.contains("crates")) {
        return die(d, "{s}: the top level is {{\"crates\": {{...}}}}", .{label});
    }
    const crates = data.object.get("crates").?;
    if (crates != .object) return die(d, "{s}: \"crates\" is not an object", .{label});
    var it = crates.object.iterator();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        const o = e.value_ptr.*;
        if (o != .object) return die(d, "{s}: {s}: is not an object", .{ label, key });
        var parts = std.mem.splitScalar(u8, key, ' ');
        _ = parts.next();
        const second = parts.next();
        if (second == null or parts.next() != null) return die(d, "{s}: {s}: the key is `name version`", .{ label, key });
        var bad = std.ArrayList([]const u8).empty;
        for (o.object.keys()) |k| {
            var known = false;
            for (override_keys) |ok| if (std.mem.eql(u8, ok, k)) {
                known = true;
            };
            if (!known) try bad.append(a, k);
        }
        if (bad.items.len != 0) {
            std.mem.sort([]const u8, bad.items, {}, lessStr);
            const allowed = try std.mem.join(a, ", ", &[_][]const u8{ "cfgs", "drop_build_script", "native_deps", "patch", "why" });
            return die(d, "{s}: {s}: unknown key {s} (allowed: {s})", .{ label, key, bad.items[0], allowed });
        }
        if (!val.truthy(o.object.get("why"))) return die(d, "{s}: {s}: `why` is required: say what the build script did and what replaces it", .{ label, key });
        try out.put(key, o);
    }
    return out;
}

fn unitKey(a: std.mem.Allocator, u: Value) ![]u8 {
    return std.fmt.allocPrint(a, "{s} {s}", .{ strField(u, "crate"), strField(u, "version") });
}

fn isCustomBuild(a: std.mem.Allocator, u: Value) !bool {
    const kinds = try strings(a, val.get(u, "target_kind"));
    return kinds.len == 1 and std.mem.eql(u8, kinds[0], "custom-build");
}

const Applied = struct { dropped: std.StringHashMap(void), reach: std.StringHashMap(void) };

/// Which units are not emitted, and which are reachable from a member once they are gone. Checks that every override matches. A
/// unit that depended on a dropped script (a library, or another script that would have read its DEP_* variables) simply loses
/// that edge: the override's `why` says what replaces it.
fn applyOverrides(a: std.mem.Allocator, d: *Diag, units: Value, overrides: Overrides) Error!Applied {
    var seen = std.StringHashMap(void).init(a);
    var dropped = std.StringHashMap(void).init(a);
    var it = units.object.iterator();
    while (it.next()) |e| {
        const u = e.value_ptr.*;
        const k = try unitKey(a, u);
        if (overrides.get(k)) |o| if (std.mem.eql(u8, strField(u, "source"), "registry")) {
            try seen.put(k, {});
            if (val.truthy(o.object.get("drop_build_script")) and try isCustomBuild(a, u)) try dropped.put(e.key_ptr.*, {});
        };
    }
    for (overrides.keys()) |k| {
        if (!seen.contains(k)) {
            const sp = std.mem.indexOfScalar(u8, k, ' ').?;
            return die(d, "override {s} {s}: no unit of the table is that crate (a version bump left it behind?)", .{ k[0..sp], k[sp + 1 ..] });
        }
    }
    var reach = std.StringHashMap(void).init(a);
    var todo = std.ArrayList([]const u8).empty;
    var it2 = units.object.iterator();
    while (it2.next()) |e| {
        const u = e.value_ptr.*;
        if (!std.mem.eql(u8, strField(u, "source"), "registry") and !std.mem.eql(u8, strField(u, "mode"), "doctest")) try todo.append(a, e.key_ptr.*);
    }
    while (todo.pop()) |k| {
        if (reach.contains(k) or dropped.contains(k)) continue;
        try reach.put(k, {});
        const u = units.object.get(k) orelse return die(d, "{s}: a dependency is not in the table", .{k});
        for (val.items(val.get(u, "deps"))) |dep| {
            if (dep != .array) continue;
            const pair = dep.array.items;
            if (pair.len == 2 and pair[1] == .string) try todo.append(a, pair[1].string);
        }
    }
    return .{ .dropped = dropped, .reach = reach };
}

fn requireStr(d: *Diag, uid: []const u8, u: Value, key: []const u8) Error![]const u8 {
    return val.getStr(u, key) orelse die(d, "{s}: the table entry has no `{s}`", .{ uid, key });
}

/// One registry unit as a `cargo_unit` call.
fn emitUnit(a: std.mem.Allocator, d: *Diag, units: Value, uid: []const u8, u: Value, override: ?Value, dropped: *const std.StringHashMap(void), rustc: ?[]const u8) Error![]const u8 {
    const p = val.get(u, "profile") orelse return die(d, "{s}: the table entry has no profile", .{uid});
    const lto = try val.pyStr(a, val.get(p, "lto") orelse .null);
    if (!std.mem.eql(u8, lto, "false")) return die(d, "{s}: lto={s}: not in v0", .{ uid, lto });
    if ((val.get(p, "codegen_backend") orelse .null) != .null) return die(d, "{s}: codegen_backend {s}", .{ uid, try val.pyStr(a, val.get(p, "codegen_backend").?) });
    if (val.truthy(val.get(p, "rpath")) or val.truthy(val.get(p, "incremental")) or val.truthy(val.get(p, "split_debuginfo"))) {
        return die(d, "{s}: rpath/incremental/split_debuginfo not supported", .{uid});
    }
    const mode = try requireStr(d, uid, u, "mode");
    const custom = try isCustomBuild(a, u);
    // A dependency is built as the library cargo links (a package that also declares cdylib / staticlib, like crc-fast, has
    // them in its unit graph entry, but only an rlib is what dependents take).
    const cts = try strings(a, val.get(u, "crate_types"));
    if (cts.len == 0) return die(d, "{s}: no crate types", .{uid});
    var ct: []const u8 = cts[0];
    for (cts) |c| if (std.mem.eql(u8, c, "rlib") or std.mem.eql(u8, c, "lib")) {
        ct = "rlib";
        break;
    };
    const ctype: []const u8 = if (std.mem.eql(u8, ct, "lib") or std.mem.eql(u8, ct, "rlib")) "rlib" else if (std.mem.eql(u8, ct, "proc-macro")) "proc-macro" else if (std.mem.eql(u8, ct, "bin")) "bin" else
        return die(d, "{s}: crate type {s} not in v0", .{ uid, ct });

    var dep_names = std.ArrayList([]const u8).empty;
    var dep_ids = std.ArrayList([]const u8).empty;
    var link_deps = std.ArrayList([]const u8).empty;
    for (val.items(val.get(u, "deps"))) |dep| {
        if (dep != .array or dep.array.items.len != 2 or dep.array.items[0] != .string or dep.array.items[1] != .string) return die(d, "{s}: a dependency is not [name, id]", .{uid});
        const ext = dep.array.items[0].string;
        const did = dep.array.items[1].string;
        if (dropped.contains(did)) continue; // an override replaces this crate's build script
        const du = units.object.get(did) orelse return die(d, "{s}: depends on {s}, which is not in the table", .{ uid, did });
        if (std.mem.eql(u8, strField(du, "mode"), "run-custom-build") and std.mem.eql(u8, mode, "run-custom-build")) {
            // the run unit of a dependency that has `links`: its metadata reaches this script as DEP_<LINKS>_<KEY>
            if (!val.truthy(val.get(du, "links"))) return die(d, "{s}: depends on the run of {s}, which has no links", .{ uid, did });
            try link_deps.append(a, try std.fmt.allocPrint(a, ":{s}", .{try tname(a, did)}));
            continue;
        }
        var same = false;
        var clash = false;
        for (dep_names.items, dep_ids.items) |n, i| {
            if (std.mem.eql(u8, n, ext)) {
                if (std.mem.eql(u8, i, did)) same = true else clash = true;
            }
        }
        if (same) continue; // cargo lists the same edge twice when a package names itself as a dev-dependency
        if (clash) return die(d, "{s}: two dependencies named {s}", .{ uid, ext });
        try dep_names.append(a, ext);
        try dep_ids.append(a, did);
    }

    const crate = try requireStr(d, uid, u, "crate");
    const target_name = try requireStr(d, uid, u, "target_name");
    var lines = std.ArrayList([]const u8).empty;
    try lines.append(a, "cargo_unit(");
    try lines.append(a, try std.fmt.allocPrint(a, "    name = {s},", .{try q(a, try tname(a, uid))}));
    if (rustc) |r| try lines.append(a, try std.fmt.allocPrint(a, "    rustc = {s},", .{try q(a, r)}));
    try lines.append(a, try std.fmt.allocPrint(a, "    pkg = {s},", .{try q(a, crate)}));
    try lines.append(a, try std.fmt.allocPrint(a, "    version = {s},", .{try q(a, try requireStr(d, uid, u, "version"))}));
    const crate_name = try a.dupe(u8, if (custom) crate else target_name);
    std.mem.replaceScalar(u8, crate_name, '-', '_');
    try lines.append(a, try std.fmt.allocPrint(a, "    crate_name = {s},", .{try q(a, crate_name)}));
    if (custom) {
        const bs = try a.dupe(u8, target_name);
        std.mem.replaceScalar(u8, bs, '-', '_');
        try lines.append(a, try std.fmt.allocPrint(a, "    build_script_name = {s},", .{try q(a, bs)}));
    }
    const colon = std.mem.indexOfScalar(u8, uid, ':') orelse return die(d, "{s}: not a unit id", .{uid});
    try lines.append(a, try std.fmt.allocPrint(a, "    mode = {s},", .{try q(a, mode)}));
    try lines.append(a, try std.fmt.allocPrint(a, "    crate_type = {s},", .{try q(a, ctype)}));
    try lines.append(a, try std.fmt.allocPrint(a, "    side = {s},", .{try q(a, try requireStr(d, uid, u, "side"))}));
    try lines.append(a, try std.fmt.allocPrint(a, "    edition = {s},", .{try q(a, try requireStr(d, uid, u, "edition"))}));
    try lines.append(a, try std.fmt.allocPrint(a, "    root = {s},", .{try q(a, try requireStr(d, uid, u, "crate_root"))}));
    try lines.append(a, try std.fmt.allocPrint(a, "    crate_hash = {s},", .{try q(a, uid[colon + 1 ..])}));
    try lines.append(a, try std.fmt.allocPrint(a, "    opt_level = {s},", .{try q(a, try val.pyStr(a, val.get(p, "opt_level") orelse .null))}));
    try lines.append(a, try std.fmt.allocPrint(a, "    debuginfo = {s},", .{try q(a, try val.pyStr(a, val.get(p, "debuginfo") orelse .null))}));
    try lines.append(a, try std.fmt.allocPrint(a, "    debug_assertions = {s},", .{try val.pyStr(a, val.get(p, "debug_assertions") orelse .null)}));
    try lines.append(a, try std.fmt.allocPrint(a, "    overflow_checks = {s},", .{try val.pyStr(a, val.get(p, "overflow_checks") orelse .null)}));
    if (val.get(u, "links")) |l| if (std.mem.eql(u8, mode, "run-custom-build") and val.truthy(l) and l == .string) {
        try lines.append(a, try std.fmt.allocPrint(a, "    links = {s},", .{try q(a, l.string)}));
    };
    if (link_deps.items.len != 0) try lines.append(a, try std.fmt.allocPrint(a, "    link_deps = {s},", .{try qlist(a, link_deps.items, "        ")}));
    const panic = try val.pyStr(a, val.get(p, "panic") orelse .null);
    if (!std.mem.eql(u8, panic, "unwind")) try lines.append(a, try std.fmt.allocPrint(a, "    panic = {s},", .{try q(a, panic)}));
    if (try stripOf(d, p)) |s| {
        const low = try std.ascii.allocLowerString(a, s);
        const named = if (val.get(p, "strip")) |sv| (sv == .object and (val.get(sv, "resolved") orelse .null) == .object) else false;
        try lines.append(a, try std.fmt.allocPrint(a, "    strip = {s},", .{try q(a, if (named) s else low)}));
    }
    if ((val.get(p, "codegen_units") orelse .null) != .null) {
        try lines.append(a, try std.fmt.allocPrint(a, "    codegen_units = {s},", .{try q(a, try val.pyStr(a, val.get(p, "codegen_units").?))}));
    }
    var cfgs = std.ArrayList([]const u8).empty;
    try cfgs.appendSlice(a, try strings(a, val.get(u, "cfgs")));
    if (override != null and !custom) try cfgs.appendSlice(a, try strings(a, val.get(override.?, "cfgs")));
    if (cfgs.items.len != 0) try lines.append(a, try std.fmt.allocPrint(a, "    cfgs = {s},", .{try qlist(a, cfgs.items, "        ")}));
    if (override) |o| if (val.truthy(val.get(o, "native_deps")) and !custom and std.mem.eql(u8, mode, "build")) {
        try lines.append(a, try std.fmt.allocPrint(a, "    native_deps = {s},", .{try qlist(a, try strings(a, val.get(o, "native_deps")), "        ")}));
    };
    try lines.append(a, "    cap_lints = True,");
    try lines.append(a, try std.fmt.allocPrint(a, "    src = {s},", .{try q(a, try std.fmt.allocPrint(a, ":src-{s}-{s}", .{ crate, strField(u, "version") }))}));
    if (dep_names.items.len != 0) {
        try lines.append(a, "    deps = {");
        for (dep_names.items, dep_ids.items) |n, i| {
            try lines.append(a, try std.fmt.allocPrint(a, "        {s}: {s},", .{ try q(a, n), try q(a, try std.fmt.allocPrint(a, ":{s}", .{try tname(a, i)})) }));
        }
        try lines.append(a, "    },");
    }
    try lines.append(a, "    visibility = [\"PUBLIC\"],");
    try lines.append(a, ")\n");
    return std.mem.join(a, "\n", lines.items);
}

pub const Sizes = std.StringHashMap(u64);

/// `name version bytes` per line; blank lines and `#` comments skipped.
pub fn parseSizes(a: std.mem.Allocator, d: *Diag, text: []const u8) Error!Sizes {
    var out = Sizes.init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.tokenizeAny(u8, line, " \t");
        const n = f.next();
        const v = f.next();
        const b = f.next();
        if (n == null or v == null or b == null or f.next() != null) return die(d, "the sizes file has a line that is not `name version bytes`: {s}", .{line});
        const bytes = std.fmt.parseInt(u64, b.?, 10) catch return die(d, "the sizes file: `{s}` is not a number", .{b.?});
        try out.put(try std.fmt.allocPrint(a, "{s} {s}", .{ n.?, v.? }), bytes);
    }
    return out;
}

const Src = struct { name: []const u8, version: []const u8, sha: []const u8 };

fn lessSrc(_: void, x: Src, y: Src) bool {
    var c = std.mem.order(u8, x.name, y.name);
    if (c == .eq) c = std.mem.order(u8, x.version, y.version);
    if (c == .eq) c = std.mem.order(u8, x.sha, y.sha);
    return c == .lt;
}

pub const Options = struct {
    /// The Rust version every unit names, when it is not buildrules' default (a proc-macro must load into the rustc that builds its user).
    non_default_rustc: ?[]const u8 = null,
};

/// The BUCK file of the registry package.
pub fn generate(a: std.mem.Allocator, d: *Diag, units: Value, sizes: Sizes, overrides: ?Overrides, opts: Options) Error![]const u8 {
    var reg = std.ArrayList([]const u8).empty;
    for (units.object.keys(), units.object.values()) |k, u| {
        if (std.mem.eql(u8, strField(u, "source"), "registry") and !std.mem.eql(u8, strField(u, "mode"), "doctest")) try reg.append(a, k);
    }
    std.mem.sort([]const u8, reg.items, {}, lessStr);
    var dropped = std.StringHashMap(void).init(a);
    if (overrides) |o| if (o.count() != 0) {
        const ap = try applyOverrides(a, d, units, o);
        dropped = ap.dropped;
        var kept = std.ArrayList([]const u8).empty;
        for (reg.items) |k| if (ap.reach.contains(k)) try kept.append(a, k);
        reg = kept;
    };
    var srcs = std.ArrayList(Src).empty;
    for (reg.items) |k| {
        const u = units.object.get(k).?;
        try srcs.append(a, .{ .name = strField(u, "crate"), .version = strField(u, "version"), .sha = strField(u, "sha256") });
    }
    std.mem.sort(Src, srcs.items, {}, lessSrc);
    var uniq = std.ArrayList(Src).empty;
    for (srcs.items) |s| {
        if (uniq.items.len != 0) {
            const l = uniq.items[uniq.items.len - 1];
            if (std.mem.eql(u8, l.name, s.name) and std.mem.eql(u8, l.version, s.version) and std.mem.eql(u8, l.sha, s.sha)) continue;
        }
        try uniq.append(a, s);
    }
    var missing = std.ArrayList(u8).empty;
    for (uniq.items) |s| {
        if (!sizes.contains(try std.fmt.allocPrint(a, "{s} {s}", .{ s.name, s.version }))) {
            if (missing.items.len != 0) try missing.appendSlice(a, ", ");
            try missing.print(a, "{s} {s}", .{ s.name, s.version });
        }
    }
    if (missing.items.len != 0) return die(d, "sizes file lacks: {s} (run `buildrules sync`)", .{missing.items});

    var out = std.ArrayList([]const u8).empty;
    try out.append(a, "# Generated by `buildrules sync` from the unit table. Do not edit.");
    try out.append(a, try std.fmt.allocPrint(a, "# {d} cargo units, {d} registry crates (sha256 from Cargo.lock, size from the crate_sizes file).", .{ reg.items.len, uniq.items.len }));
    try out.append(a, load_line);
    try out.append(a, try filesTarget(a, overrides != null));
    for (uniq.items) |s| {
        const bytes = sizes.get(try std.fmt.allocPrint(a, "{s} {s}", .{ s.name, s.version })).?;
        var b = std.ArrayList(u8).empty;
        try b.print(a, "crate_src(\n    name = {s},\n    pkg = {s},\n    version = {s},\n", .{ try q(a, try std.fmt.allocPrint(a, "src-{s}-{s}", .{ s.name, s.version })), try q(a, s.name), try q(a, s.version) });
        try b.print(a, "    url = {s},\n", .{try q(a, try std.fmt.allocPrint(a, "https://static.crates.io/crates/{s}/{s}-{s}.crate", .{ s.name, s.name, s.version }))});
        try b.print(a, "    sha256 = {s},\n    size_bytes = {d},\n", .{ try q(a, s.sha), bytes });
        if (overrides) |o| if (o.get(try std.fmt.allocPrint(a, "{s} {s}", .{ s.name, s.version }))) |ov| {
            if (val.truthy(ov.object.get("patch"))) {
                var aw = std.Io.Writer.Allocating.init(a);
                try val.oneline(&aw.writer, a, ov.object.get("patch").?);
                try b.print(a, "    patch = {s},\n", .{aw.written()});
            }
        };
        try b.appendSlice(a, ")\n");
        try out.append(a, b.items);
    }
    for (reg.items) |k| {
        const u = units.object.get(k).?;
        const ov: ?Value = if (overrides) |o| o.get(try unitKey(a, u)) else null;
        try out.append(a, try emitUnit(a, d, units, k, u, ov, &dropped, opts.non_default_rustc));
    }
    return std.mem.join(a, "\n", out.items);
}

// ---- the sizes file ----------------------------------------------------------------------------------------------

/// The seam to the network: the sha256 and size of the body at `url`. Tests replace it.
pub const Fetch = *const fn (a: std.mem.Allocator, url: []const u8) anyerror!fetch.Digest.Result;
pub var fetcher: Fetch = &httpDigest;

fn httpDigest(a: std.mem.Allocator, url: []const u8) anyerror!fetch.Digest.Result {
    var http = fetch.HttpFetcher{ .allocator = a };
    var dg = fetch.Digest{ .max = 1 << 30 };
    try http.fetcher().get(url, dg.sink());
    return dg.finish(a);
}

const sizes_header = "# name version bytes; every sha256 was checked against the table by `buildrules sync`\n";

/// The sizes file for the registry crates of the table, and a proof that every sha256 in it is the crate's: each crate is read
/// from `cache` (a cargo registry cache: `<cache>/<index>/<name>-<version>.crate`, an absolute path or one under the current
/// directory) when it is there, else downloaded from static.crates.io.
pub fn sizesFile(a: std.mem.Allocator, d: *Diag, units: Value, cache: ?[]const u8) Error![]const u8 {
    var crates = std.ArrayList(Src).empty;
    for (units.object.values()) |u| {
        if (!std.mem.eql(u8, strField(u, "source"), "registry")) continue;
        try crates.append(a, .{ .name = strField(u, "crate"), .version = strField(u, "version"), .sha = strField(u, "sha256") });
    }
    std.mem.sort(Src, crates.items, {}, lessSrc);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, sizes_header);
    var first = true;
    var prev: ?Src = null;
    for (crates.items) |c| {
        if (prev) |p| if (std.mem.eql(u8, p.name, c.name) and std.mem.eql(u8, p.version, c.version) and std.mem.eql(u8, p.sha, c.sha)) continue;
        prev = c;
        var got_sha: []const u8 = undefined;
        var size: u64 = undefined;
        if (try fromCache(a, cache, c)) |bytes| {
            var dg: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &dg, .{});
            got_sha = try a.dupe(u8, &std.fmt.bytesToHex(dg, .lower));
            size = bytes.len;
        } else {
            const url = try std.fmt.allocPrint(a, "https://static.crates.io/crates/{s}/{s}-{s}.crate", .{ c.name, c.name, c.version });
            const r = fetcher(a, url) catch |e| return die(d, "{s} {s}: cannot download {s}: {s}", .{ c.name, c.version, url, @errorName(e) });
            got_sha = r.sha256;
            size = r.size;
        }
        if (!std.mem.eql(u8, got_sha, c.sha)) return die(d, "{s} {s}: sha256 {s} but the table (Cargo.lock) says {s}", .{ c.name, c.version, got_sha, c.sha });
        if (!first) try out.append(a, '\n');
        first = false;
        try out.print(a, "{s} {s} {d}", .{ c.name, c.version, size });
    }
    try out.append(a, '\n');
    return out.toOwnedSlice(a);
}

fn fromCache(a: std.mem.Allocator, cache: ?[]const u8, c: Src) Error!?[]const u8 {
    const dir_path = cache orelse return null;
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |e| {
        if (e.kind != .directory) continue;
        const rel = try std.fmt.allocPrint(a, "{s}/{s}-{s}.crate", .{ e.name, c.name, c.version });
        return dir.readFileAlloc(a, rel, 256 << 20) catch continue;
    }
    return null;
}
