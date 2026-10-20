//! node_tools: the program the node_modules rules run (modules.bzl).
//!
//!   node_tools assemble <spec.json> <out>   node_modules from package-lock.json and pinned tarballs
//!   node_tools run <spec.json> <out>        a program (or a package.json script) of node_modules over a copy of a source tree
//!   node_tools unpack <spec.json> <out>     one npm tarball: sha512 checked, unpacked as npm does
//!   node_tools tree <spec.json> <out>       node_modules from package-lock.json and the unpacked packages
//!   node_tools check <spec.json> <out>      the table against package.json and package-lock.json
//!   node_tools manifest <package.json> <out>  package.json without its "buildrules" key
//!
//! Paths in the spec are relative to the working directory (the action's
//! root). Everything is the Zig standard library: no shell, no npm, no network.
const std = @import("std");
const check = @import("check.zig");
const layout = @import("layout.zig");
const runner = @import("runner.zig");

fn die(comptime fmt: []const u8, args: anytype) u8 {
    std.fs.File.stderr().deprecatedWriter().print("node_modules: " ++ fmt ++ "\n", args) catch {};
    return 1;
}

fn field(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn text(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn abs(a: std.mem.Allocator, cwd: []const u8, p: []const u8) ![]u8 {
    return std.fs.path.resolve(a, &.{ cwd, p });
}

fn doAssemble(a: std.mem.Allocator, cwd: []const u8, spec_json: std.json.Value, out: []const u8) !void {
    const lock_path = text(field(spec_json, "lockfile")) orelse return error.BadSpec;
    var spec = layout.Spec{
        .lockfile = try std.fs.cwd().readFileAlloc(a, lock_path, 1 << 30),
        .tarballs = std.StringHashMap([]const u8).init(a),
        .sri512 = std.StringHashMap([]const u8).init(a),
    };
    const tb = field(spec_json, "tarballs") orelse return error.BadSpec;
    const sr = field(spec_json, "sri512") orelse return error.BadSpec;
    if (tb != .object or sr != .object) return error.BadSpec;
    for (tb.object.keys(), tb.object.values()) |k, v| {
        if (v != .string) return error.BadSpec;
        try spec.tarballs.put(k, try abs(a, cwd, v.string));
    }
    for (sr.object.keys(), sr.object.values()) |k, v| {
        if (v != .string) return error.BadSpec;
        try spec.sri512.put(k, v.string);
    }
    const out_abs = try abs(a, cwd, out);
    try std.fs.cwd().makePath(out_abs);
    var dir = try std.fs.cwd().openDir(out_abs, .{});
    defer dir.close();
    try layout.assemble(a, spec, dir, out_abs, std.fs.File.stderr().deprecatedWriter());
}

fn strMap(a: std.mem.Allocator, v: ?std.json.Value, base: ?[]const u8) !std.StringHashMap([]const u8) {
    var m = std.StringHashMap([]const u8).init(a);
    const o = v orelse return error.BadSpec;
    if (o != .object) return error.BadSpec;
    for (o.object.keys(), o.object.values()) |k, x| {
        if (x != .string) return error.BadSpec;
        try m.put(k, if (base) |b| try abs(a, b, x.string) else x.string);
    }
    return m;
}

fn doTree(a: std.mem.Allocator, cwd: []const u8, spec_json: std.json.Value, out: []const u8) !void {
    const lock_path = text(field(spec_json, "lockfile")) orelse return error.BadSpec;
    const spec = layout.Spec{
        .lockfile = try std.fs.cwd().readFileAlloc(a, lock_path, 1 << 30),
        .tarballs = std.StringHashMap([]const u8).init(a),
        .sri512 = try strMap(a, field(spec_json, "sri512"), null),
        .dirs = try strMap(a, field(spec_json, "dirs"), cwd),
    };
    const out_abs = try abs(a, cwd, out);
    try std.fs.cwd().makePath(out_abs);
    var dir = try std.fs.cwd().openDir(out_abs, .{});
    defer dir.close();
    try layout.assemble(a, spec, dir, out_abs, std.fs.File.stderr().deprecatedWriter());
}

fn doUnpack(a: std.mem.Allocator, cwd: []const u8, j: std.json.Value, out: []const u8) !void {
    const tarball = text(field(j, "tarball")) orelse return error.BadSpec;
    const bytes = std.fs.cwd().readFileAlloc(a, tarball, 1 << 30) catch |e| return die2("cannot read {s}: {s}", .{ tarball, @errorName(e) });
    const out_abs = try abs(a, cwd, out);
    try std.fs.cwd().makePath(out_abs);
    var dir = try std.fs.cwd().openDir(out_abs, .{});
    defer dir.close();
    try layout.unpackOne(a, bytes, text(field(j, "sri512")) orelse return error.BadSpec, text(field(j, "name")) orelse return error.BadSpec, text(field(j, "version")) orelse return error.BadSpec, dir, std.fs.File.stderr().deprecatedWriter());
}

fn die2(comptime fmt: []const u8, args: anytype) error{Failed} {
    _ = die(fmt, args);
    return error.Failed;
}

fn doCheck(a: std.mem.Allocator, cwd: []const u8, j: std.json.Value, out: []const u8) !void {
    _ = cwd;
    const pj = text(field(j, "packageJson")) orelse return error.BadSpec;
    const lk = text(field(j, "lockfile")) orelse return error.BadSpec;
    var table = std.StringArrayHashMap([]const u8).init(a);
    const tv = field(j, "table") orelse return error.BadSpec;
    if (tv != .object) return error.BadSpec;
    for (tv.object.keys(), tv.object.values()) |k, x| {
        if (x != .string) return error.BadSpec;
        try table.put(k, x.string);
    }
    try check.check(a, .{
        .package_json = std.fs.cwd().readFileAlloc(a, pj, 64 << 20) catch |e| return die2("cannot read {s}: {s}", .{ pj, @errorName(e) }),
        .lockfile = std.fs.cwd().readFileAlloc(a, lk, 1 << 30) catch |e| return die2("cannot read {s}: {s}", .{ lk, @errorName(e) }),
        .package_json_sha256 = text(field(j, "packageJsonSha256")) orelse return error.BadSpec,
        .lockfile_sha256 = text(field(j, "lockfileSha256")) orelse return error.BadSpec,
        .table = table,
    }, std.fs.File.stderr().deprecatedWriter());
    // Buck2 reads this file as a validation result: JSON, not an empty marker.
    const f = try std.fs.cwd().createFile(out, .{});
    defer f.close();
    try f.writeAll("{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"the table matches package.json and package-lock.json\"}}\n");
}

/// `manifest`: argv[2] is package.json itself, not a spec.
fn doManifest(a: std.mem.Allocator, in_path: []const u8, out: []const u8) !void {
    const bytes = std.fs.cwd().readFileAlloc(a, in_path, 64 << 20) catch |e| return die2("cannot read {s}: {s}", .{ in_path, @errorName(e) });
    const text_out = check.withoutPolicy(a, bytes) catch |e| return die2("{s}: {s}", .{ in_path, @errorName(e) });
    try std.fs.cwd().writeFile(.{ .sub_path = out, .data = try std.fmt.allocPrint(a, "{s}\n", .{text_out}) });
}

fn doRun(a: std.mem.Allocator, cwd: []const u8, j: std.json.Value, out: []const u8) !void {
    const args_v = field(j, "args") orelse return error.BadSpec;
    const env_v = field(j, "env") orelse return error.BadSpec;
    if (args_v != .array or env_v != .object) return error.BadSpec;
    var args = std.ArrayList([]const u8).empty;
    for (args_v.array.items) |x| {
        if (x != .string) return error.BadSpec;
        try args.append(a, x.string);
    }
    var env = std.ArrayList([2][]const u8).empty;
    for (env_v.object.keys(), env_v.object.values()) |k, v| {
        if (v != .string) return error.BadSpec;
        try env.append(a, .{ k, v.string });
    }
    var tools = std.ArrayList([2][]const u8).empty;
    if (field(j, "pathTools")) |pt| {
        if (pt != .object) return error.BadSpec;
        for (pt.object.keys(), pt.object.values()) |k, v| {
            if (v != .string) return error.BadSpec;
            try tools.append(a, .{ k, try abs(a, cwd, v.string) });
        }
    }
    const out_dir_v = field(j, "outDir");
    const scratch = try runner.scratchDir(a, cwd, std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch null);
    const spec = runner.Spec{
        .tree = try abs(a, cwd, text(field(j, "tree")) orelse return error.BadSpec),
        .modules = try abs(a, cwd, text(field(j, "modules")) orelse return error.BadSpec),
        .node = try abs(a, cwd, text(field(j, "node")) orelse return error.BadSpec),
        .libs = try abs(a, cwd, text(field(j, "libs")) orelse return error.BadSpec),
        .package = text(field(j, "package")) orelse return error.BadSpec,
        .program = text(field(j, "program")) orelse "",
        .script = text(field(j, "script")),
        .args = args.items,
        .env = env.items,
        .tools = tools.items,
        .out_dir = if (out_dir_v) |v| (if (v == .string) v.string else null) else null,
        .scratch = scratch,
    };
    try runner.run(a, spec, try abs(a, cwd, out), std.fs.File.stderr().deprecatedWriter());
}

pub fn main() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = std.process.argsAlloc(a) catch return die("out of memory", .{});
    const modes = [_][]const u8{ "assemble", "run", "unpack", "tree", "check", "manifest" };
    var known = false;
    if (argv.len == 4) for (modes) |m| {
        if (std.mem.eql(u8, argv[1], m)) known = true;
    };
    if (!known) return die("usage: node_tools assemble|run|unpack|tree|check <spec.json> <out> | manifest <package.json> <out>", .{});
    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch return die("no working directory", .{});
    if (std.mem.eql(u8, argv[1], "manifest")) {
        doManifest(a, argv[2], argv[3]) catch |e| switch (e) {
            error.Failed => return 1,
            else => return die("{s}", .{@errorName(e)}),
        };
        return 0;
    }
    const spec_text = std.fs.cwd().readFileAlloc(a, argv[2], 1 << 30) catch |e| return die("cannot read {s}: {s}", .{ argv[2], @errorName(e) });
    const parsed = std.json.parseFromSlice(std.json.Value, a, spec_text, .{}) catch return die("{s} is not JSON", .{argv[2]});
    const mode = argv[1];
    const result = if (std.mem.eql(u8, mode, "assemble"))
        doAssemble(a, cwd, parsed.value, argv[3])
    else if (std.mem.eql(u8, mode, "unpack"))
        doUnpack(a, cwd, parsed.value, argv[3])
    else if (std.mem.eql(u8, mode, "tree"))
        doTree(a, cwd, parsed.value, argv[3])
    else if (std.mem.eql(u8, mode, "check"))
        doCheck(a, cwd, parsed.value, argv[3])
    else
        doRun(a, cwd, parsed.value, argv[3]);
    result catch |e| switch (e) {
        error.Failed => return 1,
        else => return die("{s}", .{@errorName(e)}),
    };
    return 0;
}
