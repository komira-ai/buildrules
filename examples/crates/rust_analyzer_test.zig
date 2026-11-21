//! rust-analyzer on this workspace, the way an editor gets it: `buildrules rust-project develop` writes rust-project.json from the table and
//! the inputs `//:rust_analyzer_inputs` built (here downloaded by the test's own action, `RA_INPUTS`), and the pinned rust-analyzer of those
//! inputs runs `diagnostics` on it. It reports, and exits 1 for, every error it finds in a member: a derive or an attribute whose proc-macro
//! it cannot expand, an `include!` of a file the build script wrote that it cannot find, a path or a module it cannot resolve.
//!
//! The members it reads: `macros` derives serde's and clap's traits and calls `#[tokio::main]` functions (proc-macros, as shared objects the
//! farm compiled); `protos` includes the modules its build script generated from `proto/` (OUT_DIR); `stamped` reads `env!` values its build
//! script printed, and so does `linkuser`, whose script read them from two dependencies with `links`; `selfdev`'s tests call a function only its
//! dev-dependency on itself turns on; `zdemo` calls a registry crate whose build script compiled C. So a clean run is the proof that each resolves, and the same
//! run with one input taken out of rust-project.json is red where that input is needed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

fn getenv(a: Allocator, name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(a, name) catch |e| {
        std.debug.print("{s} is not in the environment (the zig_test's data / exec_tools / env_tools)\n", .{name});
        return e;
    };
}

const Ran = struct { code: u8, out: []const u8 };

/// Runs `argv` in `cwd`; standard output and standard error together, as rust-analyzer prints its findings on one and its summary on the other.
fn run(a: Allocator, argv: []const []const u8, cwd: []const u8) !Ran {
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv, .cwd = cwd, .max_output_bytes = 256 << 20 });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .out = try std.fmt.allocPrint(a, "{s}{s}", .{ r.stdout, r.stderr }) };
}

const Setup = struct { work: []const u8, inputs: []const u8, ra: []const u8, project: []const u8 };

/// The workspace (the test's data) and a rust-project.json of the test's own (`name`), written by the program under test.
fn setup(a: Allocator, name: []const u8) !Setup {
    const work = try getenv(a, "BUILDRULES_TEST_WORK");
    const cwd = try std.process.getCwdAlloc(a);
    const inputs = try std.fs.path.resolve(a, &.{ cwd, try getenv(a, "RA_INPUTS") });
    const buildrules = try getenv(a, "BUILDRULES");
    const dir = try std.fs.path.join(a, &.{ work, name });
    try std.fs.cwd().makePath(dir);
    const project = try std.fs.path.join(a, &.{ dir, "rust-project.json" });
    const r = try run(a, &.{ buildrules, "rust-project", "develop", "--dir", work, "--inputs", inputs, "--project", project }, work);
    if (r.code != 0) {
        std.debug.print("buildrules rust-project develop exited {d}:\n{s}\n", .{ r.code, r.out });
        return error.DevelopFailed;
    }
    return .{ .work = work, .inputs = inputs, .ra = try std.fs.path.join(a, &.{ inputs, "sysroot/bin/rust-analyzer" }), .project = project };
}

fn diagnostics(a: Allocator, s: Setup, project: []const u8) !Ran {
    return run(a, &.{ s.ra, "diagnostics", project }, s.work);
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// The test's rust-project.json with `edit` applied to every crate row, written in its place.
fn variant(a: Allocator, s: Setup, edit: *const fn (row: *Value) void) ![]const u8 {
    const text = try std.fs.cwd().readFileAlloc(a, s.project, 1 << 28);
    var v = try std.json.parseFromSliceLeaky(Value, a, text, .{});
    for (v.object.getPtr("crates").?.array.items) |*row| edit(row);
    try std.fs.cwd().writeFile(.{ .sub_path = s.project, .data = try std.json.Stringify.valueAlloc(a, v, .{}) });
    return s.project;
}

fn dropDylib(row: *Value) void {
    _ = row.object.orderedRemove("proc_macro_dylib_path");
}

fn dropOutDir(row: *Value) void {
    if (row.object.getPtr("env")) |env| _ = env.object.orderedRemove("OUT_DIR");
}

fn expectClean(r: Ran) !void {
    if (r.code != 0 or contains(r.out, ": Error ")) {
        std.debug.print("rust-analyzer diagnostics exited {d}:\n{s}\n", .{ r.code, r.out });
        return error.NotClean;
    }
}

/// rust-analyzer found an error in `crate` saying `what`.
fn expectError(r: Ran, crate: []const u8, what: []const u8) !void {
    var found = false;
    var lines = std.mem.splitScalar(u8, r.out, '\n');
    const at = try std.fmt.allocPrint(std.heap.page_allocator, "at crate {s},", .{crate});
    while (lines.next()) |l| {
        if (contains(l, at) and contains(l, ": Error ") and contains(l, what)) found = true;
    }
    if (r.code != 1 or !found) {
        std.debug.print("expected exit 1 and an error in {s} naming `{s}`; rust-analyzer diagnostics exited {d}:\n{s}\n", .{ crate, what, r.code, r.out });
        return error.NoSuchError;
    }
}

test "rust-analyzer resolves every member: the proc-macros expand and the generated modules are found" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try setup(a, "all");
    try expectClean(try diagnostics(a, s, s.project));
}

test "without the proc-macros' shared objects, the derives and attributes of macros do not expand" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try setup(a, "no_dylibs");
    try expectError(try diagnostics(a, s, try variant(a, s, &dropDylib)), "macros", "macro-error");
}

test "without the build scripts' OUT_DIR, the modules protos includes are not found" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try setup(a, "no_out_dir");
    try expectError(try diagnostics(a, s, try variant(a, s, &dropOutDir)), "protos", "OUT_DIR");
}

fn visit(crates: []const Value, state: []u8, i: usize) !void {
    if (state[i] == 2) return;
    if (state[i] == 1) return error.Cycle;
    state[i] = 1;
    for (crates[i].object.get("deps").?.array.items) |d| {
        const n: usize = @intCast(d.object.get("crate").?.integer);
        if (n >= crates.len) return error.NoSuchCrate;
        try visit(crates, state, n);
    }
    state[i] = 2;
}

test "the crate graph of the workspace's rust-project.json has no cycles, and every edge names a crate of the file" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s = try setup(a, "graph");
    const v = try std.json.parseFromSliceLeaky(Value, a, try std.fs.cwd().readFileAlloc(a, s.project, 1 << 28), .{});
    const crates = v.object.get("crates").?.array.items;
    const state = try a.alloc(u8, crates.len);
    @memset(state, 0);
    for (0..crates.len) |i| try visit(crates, state, i);
}
