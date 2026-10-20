//! files_check: are the files a Mojo table was made from still those files?
//!
//! usage: files_check <out> (<sha256> <file> <name>)...
//!
//! `buildrules mojo sync` records the sha256 of every file its unit graph was made from that the graph does not hash itself
//! (`MANIFEST_SHA256`: mopm.toml, mopm.lock, mopm-toolchain.toml, the mopm.toml of every member). This is the build's copy of
//! that comparison, the `:check` validation of every step of a package (rules/mojo/check.bzl): it writes `<out>` (a JSON validation result) only if every
//! file hashes to what the table says, and otherwise names each file that does not, with the fix. `<name>` is the file's path
//! as the repository spells it.

const std = @import("std");

pub const Mismatch = struct { name: []const u8, want: []const u8, got: []const u8 };

fn hex(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
}

/// Every triple of `args` (hash, file, name) whose file does not hash to `hash`; a file that cannot be read is a mismatch whose
/// `got` says why.
pub fn check(a: std.mem.Allocator, args: []const []const u8) !std.ArrayList(Mismatch) {
    var bad = std.ArrayList(Mismatch).empty;
    if (args.len % 3 != 0) return error.BadArguments;
    var i: usize = 0;
    while (i < args.len) : (i += 3) {
        const want = args[i];
        const path = args[i + 1];
        const name = args[i + 2];
        const bytes = std.fs.cwd().readFileAlloc(a, path, 64 << 20) catch |e| {
            try bad.append(a, .{ .name = name, .want = want, .got = try std.fmt.allocPrint(a, "unreadable ({s})", .{@errorName(e)}) });
            continue;
        };
        const got = try hex(a, bytes);
        if (!std.mem.eql(u8, got, want)) try bad.append(a, .{ .name = name, .want = want, .got = got });
    }
    return bad;
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 2) {
        std.debug.print("usage: files_check <out> (<sha256> <file> <name>)...\n", .{});
        return 2;
    }
    const bad = check(a, argv[2..]) catch {
        std.debug.print("files_check: the arguments after <out> are triples of <sha256> <file> <name>\n", .{});
        return 2;
    };
    if (bad.items.len != 0) {
        for (bad.items) |m| {
            std.debug.print("{s} is not what the Mojo table was made from (sha256 {s}, the table says {s}): run `buildrules mojo sync` and commit the result\n", .{ m.name, m.got, m.want });
        }
        return 1;
    }
    // A validation result is JSON (Buck2 rejects any other content).
    try std.fs.cwd().writeFile(.{ .sub_path = argv[1], .data = "{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"the files the Mojo table was made from are unchanged\"}}\n" });
    return 0;
}
