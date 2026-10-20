//! hermetic: an ELF64 little-endian executable or library built by the C/C++ toolchain depends on nothing about the checkout it was built in.
//!
//!   hermetic <elf> <result.json>
//!
//! Two defects make a binary depend on the absolute path of the action's working directory (the exec root of a farm worker, the runner's
//! workspace on GitHub, a home directory on a laptop):
//!
//!  - a `.debug_*` section. zig cc assembles the C runtime's start-up objects (crti, crtn, start) at LINK time with default debug info, whatever
//!    `-g0` said for the compiles, and the DWARF stamps DW_AT_comp_dir with the working directory;
//!  - the working directory itself, as bytes anywhere in the file (a path in a string table, in a section, in `.comment`).
//!
//! The directory the tool runs in is the one the build action ran in (an action's working directory is the exec root), so "this directory's path
//! occurs in the file" is "the file depends on where it was built". Writes a validation result and exits 0 when neither is found, 1 after writing
//! "failure" when one is (or the file is not an ELF it can read).

const std = @import("std");

pub const Error = error{ NotElf64, Truncated };

fn rd(comptime T: type, b: []const u8, off: usize) Error!T {
    const n = @sizeOf(T);
    if (off > b.len or b.len - off < n) return error.Truncated;
    return std.mem.readInt(T, b[off..][0..n], .little);
}

/// The names of the sections of `b` that start with `.debug` (`.debug_info`, `.debug_line`, ...), in section order.
pub fn debugSections(a: std.mem.Allocator, b: []const u8) (Error || std.mem.Allocator.Error)![]const []const u8 {
    if (b.len < 64 or !std.mem.eql(u8, b[0..4], "\x7fELF") or b[4] != 2 or b[5] != 1) return error.NotElf64;
    const shoff: usize = @intCast(try rd(u64, b, 0x28));
    const shentsize: usize = try rd(u16, b, 0x3A);
    const shnum: usize = try rd(u16, b, 0x3C);
    const shstrndx: usize = try rd(u16, b, 0x3E);
    var out = std.ArrayList([]const u8).empty;
    if (shnum == 0) return out.toOwnedSlice(a);
    const str_sh = shoff + shstrndx * shentsize;
    const str_off: usize = @intCast(try rd(u64, b, str_sh + 0x18));
    const str_size: usize = @intCast(try rd(u64, b, str_sh + 0x20));
    if (str_off > b.len or b.len - str_off < str_size) return error.Truncated;
    const strs = b[str_off .. str_off + str_size];
    var i: usize = 0;
    while (i < shnum) : (i += 1) {
        const name_off: usize = try rd(u32, b, shoff + i * shentsize);
        if (name_off >= strs.len) continue;
        const name = std.mem.sliceTo(strs[name_off..], 0);
        if (std.mem.startsWith(u8, name, ".debug")) try out.append(a, name);
    }
    return out.toOwnedSlice(a);
}

/// Whether `dir` (an absolute path longer than "/") occurs in `b`.
pub fn mentions(b: []const u8, dir: []const u8) bool {
    if (dir.len < 2) return false;
    return std.mem.indexOf(u8, b, dir) != null;
}

/// Every reason `b` depends on `dir`; empty when none.
pub fn findings(a: std.mem.Allocator, b: []const u8, dir: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    const dbg = try debugSections(a, b);
    if (dbg.len != 0)
        try out.append(a, try std.fmt.allocPrint(a, "it has {d} debug section(s), first {s}: the compile directory is in them (link with -Wl,--strip-debug)", .{ dbg.len, dbg[0] }));
    if (mentions(b, dir)) try out.append(a, try std.fmt.allocPrint(a, "it contains the absolute path of the directory it was built in ({s})", .{dir}));
    return out.toOwnedSlice(a);
}

fn writeResult(path: []const u8, ok: bool, msg: []const u8) !void {
    var buf: [2048]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"version\": 1, \"data\": {{\"status\": \"{s}\", \"message\": \"{s}\"}}}}\n", .{ if (ok) "success" else "failure", msg });
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = body });
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len != 3) {
        std.debug.print("usage: hermetic <elf> <result.json>\n", .{});
        std.process.exit(2);
    }
    const bytes = try std.fs.cwd().readFileAlloc(a, argv[1], 1 << 30);
    const dir = try std.fs.cwd().realpathAlloc(a, ".");
    const name = std.fs.path.basename(argv[1]);
    const found = findings(a, bytes, dir) catch |e| {
        const msg = try std.fmt.allocPrint(a, "hermetic: cannot read {s}: {s}", .{ name, @errorName(e) });
        try writeResult(argv[2], false, msg);
        std.debug.print("{s}\n", .{msg});
        std.process.exit(1);
    };
    if (found.len != 0) {
        const msg = try std.fmt.allocPrint(a, "hermetic: {s} depends on where it was built: {s}", .{ name, found[0] });
        try writeResult(argv[2], false, msg);
        for (found) |f| std.debug.print("hermetic: {s}: {s}\n", .{ name, f });
        std.process.exit(1);
    }
    try writeResult(argv[2], true, "no debug section and no path of the build directory");
}

test {
    _ = @import("hermetic_test.zig");
}
