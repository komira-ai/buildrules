//! Which manifest of a git checkout cargo takes for a package, when the checkout holds the package's manifest more than once (a
//! test fixture that copies a crate, say). cargo reads a git source by walking the whole checkout: `RecursivePathSource` in
//! src/cargo/sources/path.rs of cargo 0.96.0 (Rust 1.95.0, rust-toolchain.toml), functions `read_packages`, `walk`,
//! `read_nested_packages` and `first_package`:
//!   - the walk is depth first, a directory before the directories below it, and the entries of a directory in the order of their
//!     names (bytes, `sort_unstable_by_key(file_name)`); it does not enter a directory whose name starts with `.` (the root aside),
//!     one that holds `.git`, a `target` beside a Cargo.toml, or a symbolic link (`file_type().is_dir()` does not follow it);
//!   - at a directory with a Cargo.toml it reads the manifest (one it cannot read is skipped, a virtual one has no package) and
//!     then, before the walk goes on, the manifests of the package's `path` dependencies, each directory once
//!     (`dependencies`, `build-dependencies`, `dev-dependencies`, then the same of each `target`, each table in name order,
//!     a dependency inherited from the workspace with the workspace's path);
//!   - the packages of one name and version are kept in the order they were met, and cargo takes the first, warning about the
//!     others ("skipping duplicate package ... in favor of ..."). It never refuses a duplicate.
//! `pick` gives the directory of the manifest cargo takes. buildrules does not run cargo's whole manifest reader, so it takes the
//! first manifest only when it can show cargo reads it (`judge`); when two manifests of the package remain and it cannot, `pick`
//! says so (`unsure`) and the caller refuses by name rather than guess.

const std = @import("std");
const toml = @import("toml.zig");
const val = @import("val.zig");
const Entry = @import("sources.zig").Entry;

const Value = val.Value;
const Allocator = std.mem.Allocator;

/// The directory of the package's manifest ("" for the checkout's root); `missing` when no manifest of the checkout is the package;
/// `unsure` with the directories of every manifest of it, in cargo's order, when there are several and buildrules cannot show that
/// cargo reads the first.
pub const Pick = union(enum) { dir: []const u8, missing, unsure: []const []const u8 };

/// The longest chain of symbolic links followed to a file (the kernel's own limit is 40).
const max_hops = 40;

/// The dependency tables of a manifest or of one of its targets, in the order cargo follows their `path` entries; cargo reads the
/// older underscore spelling of a table only when the manifest has no table of the hyphen spelling.
const dep_tables = [_][2][]const u8{ .{ "dependencies", "dependencies" }, .{ "build-dependencies", "build_dependencies" }, .{ "dev-dependencies", "dev_dependencies" } };

pub const Checkout = struct {
    a: Allocator,
    /// Every path of the archive, with the directories that are only implied by deeper entries; "" is the root.
    kinds: std.StringHashMap(@FieldType(Entry, "kind")),
    files: std.StringHashMap([]const u8),
    links: std.StringHashMap([]const u8),
    /// A directory's subdirectories, by name, sorted once the archive is read.
    subdirs: std.StringHashMap(std.ArrayList([]const u8)),
    /// The parsed manifest of a directory; null when it has none or it does not parse.
    docs: std.StringHashMap(?Value),
    visited: std.StringHashMap(void),
    /// The directories of the packages, in the order cargo's walk meets them.
    order: std.ArrayList([]const u8),

    /// Reads the entries of an archive (below its top directory) and walks them as cargo walks the checkout.
    pub fn init(a: Allocator, entries: []const Entry) error{OutOfMemory}!Checkout {
        var c: Checkout = .{
            .a = a,
            .kinds = .init(a),
            .files = .init(a),
            .links = .init(a),
            .subdirs = .init(a),
            .docs = .init(a),
            .visited = .init(a),
            .order = .empty,
        };
        try c.kinds.put("", .dir);
        for (entries) |e| switch (e.kind) {
            .dir => try c.noteDir(e.rel),
            .file, .link => {
                try c.noteDir(parentOf(e.rel));
                try c.kinds.put(e.rel, e.kind);
                try (if (e.kind == .file) &c.files else &c.links).put(e.rel, e.data);
            },
        };
        var it = c.subdirs.valueIterator();
        while (it.next()) |names| std.mem.sort([]const u8, names.items, {}, lessName);
        try c.walk("");
        return c;
    }

    fn noteDir(c: *Checkout, rel: []const u8) error{OutOfMemory}!void {
        if (c.kinds.contains(rel)) return;
        try c.kinds.put(rel, .dir);
        const parent = parentOf(rel);
        try c.noteDir(parent);
        const slot = try c.subdirs.getOrPut(parent);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(c.a, std.fs.path.basename(rel));
    }

    /// The bytes of the file at `rel`, through symbolic links that stay in the archive; null for anything else.
    fn resolve(c: *Checkout, rel: []const u8) error{OutOfMemory}!?[]const u8 {
        var p = rel;
        for (0..max_hops) |_| {
            if (c.files.get(p)) |bytes| return bytes;
            const target = c.links.get(p) orelse return null;
            p = (try normalize(c.a, parentOf(p), target)) orelse return null;
        }
        return null;
    }

    /// The manifest of the directory `dir`, parsed; null when it has none or cargo could not parse it.
    fn manifest(c: *Checkout, dir: []const u8) error{OutOfMemory}!?Value {
        if (c.docs.get(dir)) |doc| return doc;
        const text = try c.resolve(try join(c.a, dir, "Cargo.toml"));
        const doc: ?Value = if (text) |s| blk: {
            const parsed = toml.parse(c.a, s);
            // toml.parse reports a failed allocation as a message; it is not a manifest cargo cannot read.
            if (std.mem.eql(u8, parsed.msg, "out of memory")) return error.OutOfMemory;
            break :blk if (parsed.msg.len == 0) parsed.value else null;
        } else null;
        try c.docs.put(dir, doc);
        return doc;
    }

    /// cargo's `walk` with the callback of `read_packages`.
    fn walk(c: *Checkout, dir: []const u8) error{OutOfMemory}!void {
        if (dir.len != 0) {
            const name = std.fs.path.basename(dir);
            if (name[0] == '.') return;
            if (c.kinds.contains(try join(c.a, dir, ".git"))) return;
            if (std.mem.eql(u8, name, "target") and try c.resolve(try join(c.a, parentOf(dir), "Cargo.toml")) != null) return;
        }
        if (try c.resolve(try join(c.a, dir, "Cargo.toml")) != null) try c.nested(dir);
        const names: []const []const u8 = if (c.subdirs.get(dir)) |l| l.items else &.{};
        for (names) |n| try c.walk(try join(c.a, dir, n));
    }

    /// cargo's `read_nested_packages`.
    fn nested(c: *Checkout, dir: []const u8) error{OutOfMemory}!void {
        if ((try c.visited.getOrPut(dir)).found_existing) return;
        const doc = (try c.manifest(dir)) orelse return;
        const pkg = val.get(doc, "package") orelse return; // a virtual manifest
        if (val.getStr(pkg, "name") == null) return; // cargo cannot read it (not a table, or no name)
        try c.order.append(c.a, dir);
        for (try c.pathDeps(dir, doc)) |p| try c.nested(p);
    }

    /// The directories of the manifest's `path` dependencies, in cargo's order (`nested_paths`), that lie in the archive.
    fn pathDeps(c: *Checkout, dir: []const u8, doc: Value) error{OutOfMemory}![]const []const u8 {
        var out = std.ArrayList([]const u8).empty;
        for (try depTables(c.a, doc)) |table| {
            if (table != .object) continue;
            for (try sortedKeys(c.a, table)) |name| {
                const d = table.object.get(name).?;
                const p = if (val.getStr(d, "path")) |rel|
                    try normalize(c.a, dir, rel)
                else if (isInherited(d)) blk: {
                    const ws = (try c.workspaceRoot(dir, doc)) orelse break :blk null;
                    const rel = val.asStr(toml.at((try c.manifest(ws)).?, &.{ "workspace", "dependencies", name, "path" })) orelse break :blk null;
                    break :blk try normalize(c.a, ws, rel);
                } else null;
                if (p) |q| try out.append(c.a, q);
            }
        }
        return out.items;
    }

    /// The directory of the workspace the package at `dir` belongs to, as cargo finds it (`find_workspace_root` and
    /// `WorkspaceConfig::get_ws_root` in src/cargo/core/workspace.rs): its own manifest when that has a [workspace], the directory
    /// its `package.workspace` names, or else the nearest directory above with a manifest that has a [workspace] that does not
    /// exclude the package, or that names its workspace by `package.workspace`. Null when there is none in the archive.
    fn workspaceRoot(c: *Checkout, dir: []const u8, doc: Value) error{OutOfMemory}!?[]const u8 {
        if (val.get(doc, "workspace") != null) return dir;
        if (val.asStr(toml.at(doc, &.{ "package", "workspace" }))) |rel| return c.pointer(dir, rel);
        var cur = dir;
        while (cur.len != 0) {
            cur = parentOf(cur);
            const m = (try c.manifest(cur)) orelse continue;
            if (val.get(m, "workspace")) |w| {
                if (!excludes(w, if (cur.len == 0) dir else dir[cur.len + 1 ..])) return cur;
                continue;
            }
            if (val.asStr(toml.at(m, &.{ "package", "workspace" }))) |rel| return c.pointer(cur, rel);
        }
        return null;
    }

    /// The workspace a `package.workspace = rel` of the manifest in `dir` names: null when it is not a workspace in the archive.
    fn pointer(c: *Checkout, dir: []const u8, rel: []const u8) error{OutOfMemory}!?[]const u8 {
        const ws = (try normalize(c.a, dir, rel)) orelse return null;
        const m = (try c.manifest(ws)) orelse return null;
        return if (val.get(m, "workspace") != null) ws else null;
    }

    /// The version of the package at `dir` (null when buildrules cannot tell it), and whether buildrules can show that cargo
    /// reads the manifest: every key and dependency it inherits is in its workspace, and it has a library or binary whose file is
    /// in the archive (cargo refuses a package with no target).
    fn judge(c: *Checkout, dir: []const u8, doc: Value) error{OutOfMemory}!struct { version: ?[]const u8, sure: bool } {
        const pkg = val.get(doc, "package").?;
        const ws_dir = try c.workspaceRoot(dir, doc);
        const ws: ?Value = if (ws_dir) |w| (try c.manifest(w)).? else null;
        var sure = try c.hasTarget(dir, doc);
        var version: ?[]const u8 = null;
        var it_pkg = pkg.object.iterator();
        while (it_pkg.next()) |kv| if (isInherited(kv.value_ptr.*)) {
            const got = if (ws) |w| toml.at(w, &.{ "workspace", "package", kv.key_ptr.* }) else null;
            if (got == null) sure = false;
            if (std.mem.eql(u8, kv.key_ptr.*, "version")) version = val.asStr(got);
        };
        if (pkg.object.get("version")) |v| {
            if (v == .string) version = v.string;
        } else version = "0.0.0"; // cargo's default for a manifest without a version
        if (version == null) sure = false;
        for (try depTables(c.a, doc)) |table| {
            if (table != .object) continue;
            var it = table.object.iterator();
            while (it.next()) |kv| if (isInherited(kv.value_ptr.*)) {
                const got = if (ws) |w| toml.at(w, &.{ "workspace", "dependencies", kv.key_ptr.* }) else null;
                if (got == null) sure = false;
            };
        }
        return .{ .version = version, .sure = sure };
    }

    /// Whether the package at `dir` plainly has a target: src/lib.rs or src/main.rs, or a [lib] or [[bin]] path, in the archive.
    fn hasTarget(c: *Checkout, dir: []const u8, doc: Value) error{OutOfMemory}!bool {
        for ([_][]const u8{ "src/lib.rs", "src/main.rs" }) |f| if (try c.resolve(try join(c.a, dir, f)) != null) return true;
        var paths = std.ArrayList([]const u8).empty;
        if (val.asStr(toml.at(doc, &.{ "lib", "path" }))) |p| try paths.append(c.a, p);
        for (val.items(val.get(doc, "bin"))) |b| if (val.getStr(b, "path")) |p| try paths.append(c.a, p);
        for (paths.items) |p| {
            const rel = (try normalize(c.a, dir, p)) orelse continue;
            if (try c.resolve(rel) != null) return true;
        }
        return false;
    }

    /// The manifest cargo takes for the package `name` at `version` (Cargo.lock's), as `Pick` says.
    pub fn pick(c: *Checkout, name: []const u8, version: []const u8) error{OutOfMemory}!Pick {
        var dirs = std.ArrayList([]const u8).empty;
        var first_sure = false;
        for (c.order.items) |dir| {
            const doc = (try c.manifest(dir)).?;
            if (!std.mem.eql(u8, val.asStr(toml.at(doc, &.{ "package", "name" })) orelse continue, name)) continue;
            const j = try c.judge(dir, doc);
            if (j.version) |v| if (!std.mem.eql(u8, v, version)) continue;
            if (dirs.items.len == 0) first_sure = j.sure;
            try dirs.append(c.a, dir);
        }
        return switch (dirs.items.len) {
            0 => .missing,
            1 => .{ .dir = dirs.items[0] },
            else => if (first_sure) .{ .dir = dirs.items[0] } else .{ .unsure = dirs.items },
        };
    }
};

/// The dependency tables of a manifest in cargo's order (`nested_paths`): its own, then those of each `target`, by name.
fn depTables(a: Allocator, doc: Value) error{OutOfMemory}![]const Value {
    var out = std.ArrayList(Value).empty;
    try appendDepTables(a, &out, doc);
    if (val.get(doc, "target")) |targets| if (targets == .object) {
        for (try sortedKeys(a, targets)) |k| try appendDepTables(a, &out, targets.object.get(k).?);
    };
    return out.items;
}

fn appendDepTables(a: Allocator, out: *std.ArrayList(Value), v: Value) error{OutOfMemory}!void {
    for (dep_tables) |names| if (val.get(v, names[0]) orelse val.get(v, names[1])) |t| try out.append(a, t);
}

/// `{ workspace = true }`.
fn isInherited(v: Value) bool {
    const w = val.get(v, "workspace") orelse return false;
    return w == .bool and w.bool;
}

/// Whether a [workspace] excludes the member at `rel` below its root (cargo's `is_excluded`: below an `exclude` entry and below
/// no `members` entry, each taken as a path, not a pattern).
fn excludes(ws: Value, rel: []const u8) bool {
    var excluded = false;
    for (val.items(val.get(ws, "exclude"))) |e| if (e == .string and below(rel, e.string)) {
        excluded = true;
    };
    for (val.items(val.get(ws, "members"))) |m| if (m == .string and below(rel, m.string)) return false;
    return excluded;
}

/// Whether the path `rel` is `prefix` or below it, by whole components.
fn below(rel: []const u8, prefix: []const u8) bool {
    const p = std.mem.trimRight(u8, prefix, "/");
    if (p.len == 0 or std.mem.eql(u8, p, ".")) return true;
    return std.mem.startsWith(u8, rel, p) and (rel.len == p.len or rel[p.len] == '/');
}

fn lessName(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn sortedKeys(a: Allocator, obj: Value) error{OutOfMemory}![]const []const u8 {
    const keys = try a.dupe([]const u8, obj.object.keys());
    std.mem.sort([]const u8, keys, {}, lessName);
    return keys;
}

fn parentOf(rel: []const u8) []const u8 {
    return std.fs.path.dirname(rel) orelse "";
}

fn join(a: Allocator, dir: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    return if (dir.len == 0) a.dupe(u8, name) else std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

/// `rel` taken from the directory `base` of the archive, `.` and `..` resolved by name as cargo's `normalize_path` does; null for
/// an absolute path or one that leaves the archive.
pub fn normalize(a: Allocator, base: []const u8, rel: []const u8) error{OutOfMemory}!?[]const u8 {
    if (std.mem.startsWith(u8, rel, "/")) return null;
    var parts = std.ArrayList([]const u8).empty;
    var it_base = std.mem.tokenizeScalar(u8, base, '/');
    while (it_base.next()) |p| try parts.append(a, p);
    var it = std.mem.tokenizeScalar(u8, rel, '/');
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.pop() == null) return null;
            continue;
        }
        try parts.append(a, p);
    }
    return try std.mem.join(a, "/", parts.items);
}
