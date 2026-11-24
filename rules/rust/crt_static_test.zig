//! A static link (`-C target-feature=+crt-static`) for the glibc target, through the pinned rustc and the launcher (rustc_launch.zig) on the farm:
//! the compile of a binary and the `RUSTC` a build script runs both fail and name the flag, and nothing is written in place of the program. The
//! linker is `zig cc` for the glibc target, which cannot link glibc statically: without the refusal both runs succeed and give a dynamically
//! linked program (one with a program interpreter, PT_INTERP). The same runs without the static link, and a static library build, which links
//! nothing, succeed, so the refusal is for the static link and not for the compile around it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const t = std.testing;

/// The zig spelling of the glibc target the toolchain links for (rules/rust/pins.bzl, ZIG_CC_TARGET).
const glibc_target = "x86_64-linux-gnu.2.34";

/// What the launcher says, in full, when it refuses (rustc prints the linker's standard error in its own error).
const refusal = "rustc_launch: a static link (-static-pie, which rustc passes for -C target-feature=+crt-static) for the glibc target " ++
    glibc_target ++ " is refused: zig cc cannot link glibc statically, and the link would succeed with a dynamically linked program. " ++
    "Build without +crt-static.";

fn getenv(a: Allocator, name: []const u8) ![]u8 {
    return std.process.getEnvVarOwned(a, name) catch |e| {
        std.debug.print("{s} is not in the environment (the zig_test's exec_tools)\n", .{name});
        return e;
    };
}

/// Whether the ELF file at `path` asks for a program interpreter: a PT_INTERP program header, which a statically linked program has none of.
fn hasInterp(a: Allocator, path: []const u8) !bool {
    const elf = try std.fs.cwd().readFileAlloc(a, path, 1 << 28);
    if (elf.len < 64 or !std.mem.eql(u8, elf[0..4], "\x7fELF") or elf[4] != 2) return error.NotAnElf64;
    const phoff = std.mem.readInt(u64, elf[0x20..0x28], .little);
    const phentsize = std.mem.readInt(u16, elf[0x36..0x38], .little);
    const phnum = std.mem.readInt(u16, elf[0x38..0x3a], .little);
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const at: usize = @intCast(phoff + i * phentsize);
        if (std.mem.readInt(u32, elf[at..][0..4], .little) == 3) return true;
    }
    return false;
}

const Work = struct { dir: []const u8, main_rs: []const u8, out: []const u8 };

/// A directory of the test's own holding `fn main() {}` as main.rs; `out` is where a compile writes its program.
fn work(a: Allocator, tmp: *std.testing.TmpDir) !Work {
    const dir = try tmp.dir.realpathAlloc(a, ".");
    try tmp.dir.writeFile(.{ .sub_path = "main.rs", .data = "fn main() {}\n" });
    return .{ .dir = dir, .main_rs = try std.fs.path.join(a, &.{ dir, "main.rs" }), .out = try std.fs.path.join(a, &.{ dir, "out" }) };
}

const Ran = struct { code: u8, err: []const u8 };

/// Runs `argv` in `w.dir`, with the launcher's scratch directory inside it.
fn run(a: Allocator, w: Work, argv: []const []const u8) !Ran {
    var env = try std.process.getEnvMap(a);
    try env.put("BUCK_SCRATCH_PATH", try std.fs.path.join(a, &.{ w.dir, "scratch" }));
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv, .cwd = w.dir, .env_map = &env, .max_output_bytes = 16 << 20 });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .err = r.stderr };
}

/// The launcher as a compile action runs it: `rustc_launch <sysroot> <zig> <cc target> -- <rustc arguments>`.
fn compile(a: Allocator, w: Work, rustc_args: []const []const u8) !Ran {
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{ try getenv(a, "LAUNCH"), try getenv(a, "SYSROOT"), try getenv(a, "ZIG"), glibc_target, "--" });
    try argv.appendSlice(a, rustc_args);
    return run(a, w, argv.items);
}

/// The launcher as a build script's `RUSTC` (what bs_runner.zig hands the script): a link named `rustc` beside `rustc.cfg`.
fn buildScriptRustc(a: Allocator, w: Work, rustc_args: []const []const u8) !Ran {
    const bin = try std.fs.path.join(a, &.{ w.dir, "bin" });
    try std.fs.cwd().makePath(bin);
    try std.fs.cwd().symLink(try getenv(a, "LAUNCH"), try std.fs.path.join(a, &.{ bin, "rustc" }), .{});
    const cfg = try std.fmt.allocPrint(a, "{s}\n{s}\n{s}\n", .{ try getenv(a, "SYSROOT"), try getenv(a, "ZIG"), glibc_target });
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(a, &.{ bin, "rustc.cfg" }), .data = cfg });
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(a, try std.fs.path.join(a, &.{ bin, "rustc" }));
    try argv.appendSlice(a, rustc_args);
    return run(a, w, argv.items);
}

/// A run that must be refused: it failed, its standard error holds the refusal, and it wrote no program. A run that succeeded instead is
/// reported with what it linked.
fn expectRefused(a: Allocator, w: Work, r: Ran) !void {
    if (r.code == 0) {
        const dynamic = hasInterp(a, w.out) catch |e| {
            std.debug.print("the static link succeeded and its output is not a program ({s})\n", .{@errorName(e)});
            return error.TestUnexpectedResult;
        };
        std.debug.print("the static link succeeded and linked a {s} program\n", .{if (dynamic) "DYNAMICALLY linked (PT_INTERP)" else "static"});
        return error.TestUnexpectedResult;
    }
    if (std.mem.indexOf(u8, r.err, refusal) == null) {
        std.debug.print("the run failed ({d}) without the refusal:\n{s}\n", .{ r.code, r.err });
        return error.TestUnexpectedResult;
    }
    std.fs.cwd().access(w.out, .{}) catch return;
    std.debug.print("the refused link left a file at {s}\n", .{w.out});
    return error.TestUnexpectedResult;
}

test "a binary compiled with -C target-feature=+crt-static for the glibc target is refused, naming the flag, and no program is written" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const w = try work(a, &tmp);
    try expectRefused(a, w, try compile(a, w, &.{ "--edition", "2021", "--crate-type", "bin", "-C", "target-feature=+crt-static", "-o", w.out, w.main_rs }));
}

test "the static link is refused however the flag is spelled: one argument, and among other target features" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const w = try work(a, &tmp);
    try expectRefused(a, w, try compile(a, w, &.{ "--edition", "2021", "--crate-type", "bin", "-Ctarget-feature=+sse2,+crt-static", "-o", w.out, w.main_rs }));
}

test "a build script's RUSTC linking a small static program with +crt-static, -C panic=abort and -C strip=symbols is refused naming the flag" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const w = try work(a, &tmp);
    try expectRefused(a, w, try buildScriptRustc(a, w, &.{
        "--edition", "2021", "--crate-type", "bin", "--target", "x86_64-unknown-linux-gnu", "-C", "target-feature=+crt-static",
        "-C", "panic=abort", "-C", "opt-level=s", "-C", "strip=symbols", "-o", w.out, w.main_rs,
    }));
}

test "the same compile without the static link succeeds and gives the dynamically linked program asked for" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const w = try work(a, &tmp);
    for ([_][]const u8{ "target-feature=-crt-static", "opt-level=0" }) |c| {
        const r = try compile(a, w, &.{ "--edition", "2021", "--crate-type", "bin", "-C", c, "-o", w.out, w.main_rs });
        if (r.code != 0) std.debug.print("-C {s} failed ({d}):\n{s}\n", .{ c, r.code, r.err });
        try t.expectEqual(@as(u8, 0), r.code);
        try t.expect(try hasInterp(a, w.out));
        try std.fs.cwd().deleteFile(w.out);
    }
    const r = try buildScriptRustc(a, w, &.{ "--edition", "2021", "--crate-type", "bin", "--target", "x86_64-unknown-linux-gnu", "-o", w.out, w.main_rs });
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(try hasInterp(a, w.out));
}

test "a library compiled with +crt-static links nothing and is not refused" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const w = try work(a, &tmp);
    try tmp.dir.writeFile(.{ .sub_path = "lib.rs", .data = "pub fn f() -> u8 { 1 }\n" });
    const r = try compile(a, w, &.{ "--edition", "2021", "--crate-type", "rlib", "-C", "target-feature=+crt-static", "-o", w.out, try std.fs.path.join(a, &.{ w.dir, "lib.rs" }) });
    if (r.code != 0) std.debug.print("the library compile failed ({d}):\n{s}\n", .{ r.code, r.err });
    try t.expectEqual(@as(u8, 0), r.code);
}
