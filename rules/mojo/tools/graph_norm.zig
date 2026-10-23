//! The committed form of a unit graph (docs/contract.md, section 12.3).
//!
//! mopm's `plan --unit-graph` lists every library of the workspace the package imports by path (a *member*) with its sources and its key. A member's
//! sources are proven by the member's own table (its own `:table`, its own `:check`), so a table that repeated their hashes would turn red in every
//! package that imports the member as soon as the member's source changed, until each of them was synced again. The committed graph therefore holds a
//! member by identity only (id, package, version, root, dependencies, outputs): `identityOnly` takes its `srcs` out, and takes the `key` out of the
//! member and of every unit that imports it, because mopm's key hashes the keys of the units below it and moves with any edit there.
//!
//! Everything else is mopm's text, byte for byte. A graph without a member is returned as it is, so a package that imports nothing by path
//! keeps the table it has. `buildrules mojo sync` writes this form and `:table` (rules/mojo/tools/table_check.zig) compares mopm's output, put
//! into it by the same function, with the committed text.
//!
//! The edit is made on the lines of mopm's layout (a unit is a block opened by `    {` and closed by `    }`, its fields at six spaces), and the result is
//! parsed again: a layout this function does not know is an error, never a graph that quietly keeps what it should have dropped.

const std = @import("std");

pub const Error = error{Broken} || std.mem.Allocator.Error;

const unit_open = "    {";
const unit_close = "    }";
const id_prefix = "      \"id\": \"";
const srcs_prefix = "      \"srcs\": [";
const key_prefix = "      \"key\": ";
const srcs_end = "      ]";

fn str(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return switch (x) {
        .string => |s| s,
        else => null,
    };
}

/// The package name of `name@version`.
fn nameOf(package: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, package, '@')) |at| package[0..at] else package;
}

const Sets = struct {
    /// Units that are members: a library of another package that mopm read from a directory (it has a `root`).
    members: std.StringHashMap(void),
    /// Members, and every unit that imports one, directly or not.
    keyless: std.StringHashMap(void),
};

/// The members of a parsed graph and the units whose key depends on them; null when the graph has no member.
fn classify(a: std.mem.Allocator, units: []const std.json.Value, root_name: []const u8) Error!?Sets {
    var s = Sets{ .members = std.StringHashMap(void).init(a), .keyless = std.StringHashMap(void).init(a) };
    for (units) |uv| {
        if (uv != .object) continue;
        const uo = uv.object;
        const id = str(uo.get("id")) orelse continue;
        const kind = str(uo.get("kind")) orelse continue;
        const package = str(uo.get("package")) orelse continue;
        const root = str(uo.get("root")) orelse continue;
        if (!std.mem.eql(u8, kind, "lib") or std.mem.eql(u8, package, root_name) or root.len == 0) continue;
        try s.members.put(id, {});
        try s.keyless.put(id, {});
    }
    if (s.members.count() == 0) return null;
    // A unit imports a keyless unit: its key is gone as well. Each round adds at least one unit or ends the loop.
    var changed = true;
    while (changed) {
        changed = false;
        for (units) |uv| {
            if (uv != .object) continue;
            const id = str(uv.object.get("id")) orelse continue;
            if (s.keyless.contains(id)) continue;
            const deps = switch (uv.object.get("deps") orelse continue) {
                .array => |x| x.items,
                else => continue,
            };
            for (deps) |d| {
                const dn = str(d) orelse continue;
                if (s.keyless.contains(dn)) {
                    try s.keyless.put(id, {});
                    changed = true;
                    break;
                }
            }
        }
    }
    return s;
}

/// The id a unit block's second line names, or null when the line is not `      "id": "<id>",`.
fn idOf(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, id_prefix)) return null;
    const rest = line[id_prefix.len..];
    const q = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..q];
}

/// `graph` in its committed form (see the top of this file). A text that is not a JSON graph is returned as it is: the caller that needs a graph
/// says so, and `:table` then shows the difference.
pub fn identityOnly(a: std.mem.Allocator, graph: []const u8) Error![]const u8 {
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, graph, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return graph,
    };
    if (root != .object) return graph;
    const package = str(root.object.get("package")) orelse return graph;
    const units = switch (root.object.get("units") orelse return graph) {
        .array => |x| x.items,
        else => return graph,
    };
    const sets = (try classify(a, units, nameOf(package))) orelse return graph;

    var lines = std.ArrayList([]const u8).empty;
    var split = std.mem.splitScalar(u8, graph, '\n');
    while (split.next()) |l| try lines.append(a, l);
    const all = lines.items;

    var out = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < all.len) {
        if (!std.mem.eql(u8, all[i], unit_open)) {
            try out.append(a, all[i]);
            i += 1;
            continue;
        }
        var e = i + 1;
        while (e < all.len and !std.mem.startsWith(u8, all[e], unit_close)) e += 1;
        if (e >= all.len) return error.Broken;
        const id = idOf(all[i + 1]) orelse return error.Broken;
        const drop_srcs = sets.members.contains(id);
        const drop_key = sets.keyless.contains(id);
        try out.append(a, all[i]);
        const first = out.items.len;
        var j = i + 1;
        while (j < e) : (j += 1) {
            const l = all[j];
            if (drop_srcs and std.mem.startsWith(u8, l, srcs_prefix)) {
                // `"srcs": [],` on one line, or the entries on the lines up to the closing bracket
                if (std.mem.endsWith(u8, l, "],") or std.mem.endsWith(u8, l, "]")) continue;
                while (j < e and !std.mem.startsWith(u8, all[j], srcs_end)) j += 1;
                if (j >= e) return error.Broken;
                continue;
            }
            if (drop_key and std.mem.startsWith(u8, l, key_prefix)) continue;
            try out.append(a, l);
        }
        // The last field of an object has no comma: take it off the line that became last when `key` went.
        if (out.items.len > first) {
            const last = &out.items[out.items.len - 1];
            if (std.mem.endsWith(u8, last.*, ",")) last.* = last.*[0 .. last.len - 1];
        }
        try out.append(a, all[e]);
        i = e + 1;
    }

    const text = try std.mem.join(a, "\n", out.items);
    // The result is JSON, and nothing that was to go is left: a block written in another layout than the one edited above keeps its lines.
    const edited = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.Broken;
    for (edited.object.get("units").?.array.items) |uv| {
        if (uv != .object) continue;
        const id = str(uv.object.get("id")) orelse continue;
        if (sets.members.contains(id) and uv.object.contains("srcs")) return error.Broken;
        if (sets.keyless.contains(id) and uv.object.contains("key")) return error.Broken;
    }
    return text;
}
