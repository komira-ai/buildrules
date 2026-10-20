//! What a command-line binary of the release must be, read from its file header: an ELF of the machine the target names (static, with no
//! interpreter), or a 64-bit Mach-O executable of the cpu the target names. Used by `release package` (it refuses a binary labelled for a
//! target it was not built for) and by cli/header_test.zig (it checks the four built binaries). The module is `binhdr`.
const std = @import("std");

/// The release targets, as the asset names spell them (`buildrules-cli-<V>-<target>.tar.gz`).
pub const targets = [_][]const u8{ "linux-x86_64", "linux-aarch64", "macos-arm64", "macos-x86_64" };

const Want = struct { elf_machine: u16 = 0, macho_cputype: u32 = 0 };

fn want(target: []const u8) ?Want {
    if (std.mem.eql(u8, target, "linux-x86_64")) return .{ .elf_machine = 62 }; // EM_X86_64
    if (std.mem.eql(u8, target, "linux-aarch64")) return .{ .elf_machine = 183 }; // EM_AARCH64
    if (std.mem.eql(u8, target, "macos-arm64")) return .{ .macho_cputype = 0x0100000c }; // CPU_TYPE_ARM64
    if (std.mem.eql(u8, target, "macos-x86_64")) return .{ .macho_cputype = 0x01000007 }; // CPU_TYPE_X86_64
    return null;
}

fn u16le(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}
fn u32le(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}
fn u64le(b: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, b[at..][0..8], .little);
}

/// Why `bytes` is not the binary of `target`; null when it is.
pub fn problem(bytes: []const u8, target: []const u8) ?[]const u8 {
    const w = want(target) orelse return "not a release target";
    if (bytes.len < 64) return "too short to be an executable";
    if (std.mem.eql(u8, bytes[0..4], "\x7fELF")) {
        if (w.elf_machine == 0) return "an ELF file, but the target is macOS";
        if (bytes[4] != 2) return "an ELF file that is not 64-bit";
        if (bytes[5] != 1) return "an ELF file that is not little-endian";
        const e_type = u16le(bytes, 16);
        if (e_type != 2 and e_type != 3) return "an ELF file that is not an executable";
        const machine = u16le(bytes, 18);
        if (machine != w.elf_machine) return "an ELF file of another machine than the target's";
        // Static: no PT_INTERP (type 3) among the program headers.
        const phoff = u64le(bytes, 32);
        const phentsize = u16le(bytes, 54);
        const phnum = u16le(bytes, 56);
        if (phentsize < 56) return "an ELF file with a malformed program header table";
        var i: usize = 0;
        while (i < phnum) : (i += 1) {
            const at = std.math.add(u64, phoff, i * phentsize) catch return "an ELF file with a program header table past its end";
            if (at + 4 > bytes.len) return "an ELF file with a program header table past its end";
            if (u32le(bytes, @intCast(at)) == 3) return "an ELF file that asks for a dynamic loader (not static)";
        }
        return null;
    }
    if (std.mem.eql(u8, bytes[0..4], "\xcf\xfa\xed\xfe")) {
        if (w.macho_cputype == 0) return "a Mach-O file, but the target is Linux";
        if (u32le(bytes, 4) != w.macho_cputype) return "a Mach-O file of another cpu than the target's";
        if (u32le(bytes, 12) != 2) return "a Mach-O file that is not an executable";
        return null;
    }
    return "neither an ELF nor a 64-bit little-endian Mach-O file";
}

// ---- tests ----------------------------------------------------------------------------------------------------------------------------

const t = std.testing;

/// A 64-byte-plus ELF header of `machine`, with `phnum` program headers of type `ptype`.
fn elf(machine: u16, ptype: u32) [64 + 56]u8 {
    var b = [_]u8{0} ** (64 + 56);
    @memcpy(b[0..4], "\x7fELF");
    b[4] = 2;
    b[5] = 1;
    std.mem.writeInt(u16, b[16..18], 2, .little);
    std.mem.writeInt(u16, b[18..20], machine, .little);
    std.mem.writeInt(u64, b[32..40], 64, .little);
    std.mem.writeInt(u16, b[54..56], 56, .little);
    std.mem.writeInt(u16, b[56..58], 1, .little);
    std.mem.writeInt(u32, b[64..68], ptype, .little);
    return b;
}

fn macho(cputype: u32, filetype: u32) [64]u8 {
    var b = [_]u8{0} ** 64;
    @memcpy(b[0..4], "\xcf\xfa\xed\xfe");
    std.mem.writeInt(u32, b[4..8], cputype, .little);
    std.mem.writeInt(u32, b[12..16], filetype, .little);
    return b;
}

test "each target accepts its own header and refuses every other target's" {
    // The defect: a binary built for one target packaged under another's name (the x86_64 tarball holding an arm64 program).
    const files = [_]struct { target: []const u8, bytes: []const u8 }{
        .{ .target = "linux-x86_64", .bytes = &elf(62, 1) },
        .{ .target = "linux-aarch64", .bytes = &elf(183, 1) },
        .{ .target = "macos-arm64", .bytes = &macho(0x0100000c, 2) },
        .{ .target = "macos-x86_64", .bytes = &macho(0x01000007, 2) },
    };
    for (files) |f| {
        for (targets) |tgt| {
            const got = problem(f.bytes, tgt);
            if (std.mem.eql(u8, tgt, f.target)) {
                try t.expect(got == null);
            } else {
                try t.expect(got != null);
            }
        }
    }
}

test "a dynamically linked ELF is refused: the musl targets are static" {
    // The defect: a glibc build (PT_INTERP) shipped as the static linux binary, which fails on a host without that loader.
    const dynamic = elf(62, 3);
    try t.expect(problem(&dynamic, "linux-x86_64") != null);
    try t.expect(std.mem.indexOf(u8, problem(&dynamic, "linux-x86_64").?, "dynamic loader") != null);
}

test "a header that is not an executable of the right class is refused" {
    var big = elf(62, 1);
    big[4] = 1; // 32-bit
    try t.expect(problem(&big, "linux-x86_64") != null);
    var be = elf(62, 1);
    be[5] = 2; // big-endian
    try t.expect(problem(&be, "linux-x86_64") != null);
    var rel = elf(62, 1);
    std.mem.writeInt(u16, rel[16..18], 1, .little); // ET_REL: an object file
    try t.expect(problem(&rel, "linux-x86_64") != null);
    const dylib = macho(0x0100000c, 6); // MH_DYLIB
    try t.expect(problem(&dylib, "macos-arm64") != null);
    try t.expect(problem("#!/bin/sh\necho hello, this is a script and not an executable of any target at all\n", "linux-x86_64") != null);
    try t.expect(problem("", "linux-x86_64") != null);
    try t.expect(problem(&elf(62, 1), "windows-x86_64") != null);
}

test "an ELF is not a macOS binary, nor a Mach-O a Linux one" {
    try t.expect(problem(&elf(183, 1), "macos-arm64") != null);
    try t.expect(problem(&macho(0x0100000c, 2), "linux-aarch64") != null);
}

test "a program header table past the end of the file is refused, not read" {
    var b = elf(62, 1);
    std.mem.writeInt(u64, b[32..40], 1 << 40, .little);
    try t.expect(problem(&b, "linux-x86_64") != null);
}
