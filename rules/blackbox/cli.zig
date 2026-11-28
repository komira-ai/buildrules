//! The command line of blackbox_run: `run` (run.zig), the black-box test, and `probe` (probe.zig), the proof that a run is a farm job and of the
//! property set its frontend received. An allocation that fails ends the command with a message and status 1.

const std = @import("std");
const io_mod = @import("io.zig");
const probe = @import("probe.zig");
const run = @import("run.zig");

pub fn entry(a: std.mem.Allocator, io: io_mod.Io) u8 {
    const args = io.argv[1..];
    const command = if (args.len > 0) args[0] else "";
    const status = if (std.mem.eql(u8, command, "run"))
        run.run(a, io, args[1..])
    else if (std.mem.eql(u8, command, "probe"))
        probe.probe(a, io, args[1..])
    else {
        io.say("the commands are `run` and `probe` (README.md), not `{s}`", .{command});
        return 2;
    };
    return status catch {
        io.say("out of memory", .{});
        return 1;
    };
}
