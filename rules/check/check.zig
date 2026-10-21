//! check: what a rule's build action runs instead of a shell script (README.md).
//!
//!   check run     [OPTIONS] -- PROGRAM [ARG]...   start a program: scratch directory, environment, working directory; exit with its status
//!   check expect  --want TEXT --out FILE [OPTIONS] -- PROGRAM [ARG]...   the program's stdout is TEXT (or starts with it); write FILE
//!   check marker  --out FILE [OPTIONS] -- PROGRAM [ARG]...   run a test; write FILE only if it passed
//!   check digest  [--out FILE] (EXPECTED FILE NAME)...        files hash to the digests they should (sha256, sha512, integrity strings)
//!   check same    --out FILE A B                  two files are the same bytes
//!   check copy    SOURCE DESTINATION              a file copied, whole or not at all
//!   check isa     --objdump P --binary F --expect avx2|none --label L --out R   machine code against the ISA level
//!
//! Exit status: 0 done; 1 the check failed; 2 the command line is wrong; for `run` and `marker` the program's own status (127 not there, 126
//! not runnable). Every command writes its output file only when it succeeded. The options and what each does are in README.md and at the
//! head of runspec.zig.
//!
//! `main` only gathers the process's own streams, arguments and environment and calls `entry`, which holds everything else; the tests call
//! `entry` as main does.

const std = @import("std");
const common = @import("common.zig");
const cmds = @import("cmds.zig");
const files = @import("files.zig");
const isa = @import("isa.zig");
const Io = common.Io;
const Alloc = common.Alloc;

const Command = struct {
    name: []const u8,
    run: *const fn (Alloc, Io, []const []const u8) u8,
};

pub const commands = [_]Command{
    .{ .name = "run", .run = cmds.run },
    .{ .name = "expect", .run = cmds.expect },
    .{ .name = "marker", .run = cmds.marker },
    .{ .name = "digest", .run = files.digest },
    .{ .name = "same", .run = files.same },
    .{ .name = "copy", .run = files.copy },
    .{ .name = "isa", .run = isa.run },
};

const usage = "usage: check run|expect|marker|digest|same|copy|isa [ARGUMENT]...";

/// `args` is the command line after the program's name.
pub fn entry(a: Alloc, io: Io, args: []const []const u8) u8 {
    if (args.len == 0) {
        io.err.writeAll(usage ++ "\n") catch {};
        return 2;
    }
    if (std.mem.eql(u8, args[0], "--help")) {
        io.out.writeAll(usage ++ "\n") catch return 1;
        return 0;
    }
    for (commands) |command| {
        if (std.mem.eql(u8, command.name, args[0])) return command.run(a, io, args[1..]);
    }
    io.err.writeAll(common.concat(a, &.{ "check: unknown command ", args[0], "\n", usage, "\n" })) catch {};
    return 2;
}

pub fn main() u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = std.process.argsAlloc(a) catch common.oom();
    const environ = a.alloc([]const u8, std.os.environ.len) catch common.oom();
    for (std.os.environ, 0..) |entry_z, k| environ[k] = std.mem.span(entry_z);
    var out_buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);
    var err_buf: [0]u8 = undefined;
    var err = std.fs.File.stderr().writer(&err_buf);
    const io = Io{ .a = a, .out = &out.interface, .err = &err.interface, .cwd = std.fs.cwd(), .environ = environ };
    const status = entry(a, io, argv[1..]);
    io.out.flush() catch return 1;
    return status;
}
