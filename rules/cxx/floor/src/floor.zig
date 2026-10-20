//! glibc_floor: the newest glibc symbol version an ELF64 little-endian executable or library needs.
//!
//!   glibc_floor <elf> <max, e.g. 2.34> <result.json>
//!
//! Reads the .gnu.version_r section (SHT_GNU_verneed): every version a Vernaux names as `GLIBC_<major>.<minor>[.<patch>]`
//! (`GLIBC_PRIVATE` is not a version). Writes a validation result (`{"version":1,"data":{"status",...}}`) and exits 0 when
//! the newest is at most `max`, and exits 1 (after writing "failure") when it is newer or the file is not an ELF the tool
//! can read. A binary the toolchain builds for x86_64-linux-gnu.2.34 must not need anything newer, wherever it was built.

const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(s: []const u8) ?Version {
        var it = std.mem.splitScalar(u8, s, '.');
        const major = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const minor = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const patch = if (it.next()) |p| (std.fmt.parseInt(u32, p, 10) catch return null) else 0;
        if (it.next() != null) return null;
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }
};

pub const Error = error{ NotElf64, Truncated };

fn rd(comptime T: type, b: []const u8, off: usize) Error!T {
    const n = @sizeOf(T);
    if (off > b.len or b.len - off < n) return error.Truncated;
    return std.mem.readInt(T, b[off..][0..n], .little);
}

/// The newest GLIBC_x.y a Vernaux of `b` names, or null when it names none.
pub fn newest(b: []const u8) Error!?Version {
    if (b.len < 64 or !std.mem.eql(u8, b[0..4], "\x7fELF") or b[4] != 2 or b[5] != 1) return error.NotElf64;
    const shoff: usize = @intCast(try rd(u64, b, 0x28));
    const shentsize: usize = try rd(u16, b, 0x3A);
    const shnum: usize = try rd(u16, b, 0x3C);
    var best: ?Version = null;
    var i: usize = 0;
    while (i < shnum) : (i += 1) {
        const sh = shoff + i * shentsize;
        if (try rd(u32, b, sh + 4) != 0x6ffffffe) continue; // SHT_GNU_verneed
        const off: usize = @intCast(try rd(u64, b, sh + 0x18));
        const link: usize = @intCast(try rd(u32, b, sh + 0x28));
        const count: usize = try rd(u32, b, sh + 0x2C);
        const str_sh = shoff + link * shentsize;
        const str_off: usize = @intCast(try rd(u64, b, str_sh + 0x18));
        const str_size: usize = @intCast(try rd(u64, b, str_sh + 0x20));
        if (str_off > b.len or b.len - str_off < str_size) return error.Truncated;
        const strs = b[str_off .. str_off + str_size];
        var vn = off;
        var n: usize = 0;
        while (n < count) : (n += 1) {
            const cnt: usize = try rd(u16, b, vn + 2);
            var aux = vn + @as(usize, try rd(u32, b, vn + 8));
            var k: usize = 0;
            while (k < cnt) : (k += 1) {
                const name_off: usize = try rd(u32, b, aux + 8);
                if (name_off < strs.len) {
                    const name = std.mem.sliceTo(strs[name_off..], 0);
                    if (std.mem.startsWith(u8, name, "GLIBC_")) {
                        if (Version.parse(name["GLIBC_".len..])) |v| {
                            if (best == null or Version.order(v, best.?) == .gt) best = v;
                        }
                    }
                }
                aux += try rd(u32, b, aux + 12);
            }
            vn += try rd(u32, b, vn + 12);
        }
    }
    return best;
}

fn writeResult(path: []const u8, ok: bool, msg: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"version\": 1, \"data\": {{\"status\": \"{s}\", \"message\": \"{s}\"}}}}\n", .{ if (ok) "success" else "failure", msg });
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = body });
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len != 4) {
        std.debug.print("usage: glibc_floor <elf> <max> <result.json>\n", .{});
        std.process.exit(2);
    }
    const max = Version.parse(argv[2]) orelse {
        std.debug.print("glibc_floor: {s} is not a version\n", .{argv[2]});
        std.process.exit(2);
    };
    const bytes = try std.fs.cwd().readFileAlloc(a, argv[1], 1 << 30);
    var msg_buf: [256]u8 = undefined;
    const got = newest(bytes) catch |e| {
        const msg = try std.fmt.bufPrint(&msg_buf, "glibc_floor: cannot read {s}: {s}", .{ std.fs.path.basename(argv[1]), @errorName(e) });
        try writeResult(argv[3], false, msg);
        std.debug.print("{s}\n", .{msg});
        std.process.exit(1);
    };
    if (got) |v| {
        if (Version.order(v, max) == .gt) {
            const msg = try std.fmt.bufPrint(&msg_buf, "glibc_floor: needs GLIBC_{d}.{d}.{d}, newer than the floor {s}", .{ v.major, v.minor, v.patch, argv[2] });
            try writeResult(argv[3], false, msg);
            std.debug.print("{s}\n", .{msg});
            std.process.exit(1);
        }
        const msg = try std.fmt.bufPrint(&msg_buf, "needs GLIBC_{d}.{d} at most; floor {s}", .{ v.major, v.minor, argv[2] });
        try writeResult(argv[3], true, msg);
    } else {
        try writeResult(argv[3], true, "needs no glibc symbol version");
    }
}

test {
    _ = @import("floor_test.zig");
}
