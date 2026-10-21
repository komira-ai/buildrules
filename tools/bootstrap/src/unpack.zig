//! What the `unpack` executable is built from: the process's arguments and exit status around main.zig (which holds the program and is what the tests run).
const std = @import("std");
const main_ = @import("main.zig");

pub fn main() u8 {
    const a = std.heap.smp_allocator;
    const args = std.process.argsAlloc(a) catch return 2;
    defer std.process.argsFree(a, args);
    const rest = a.alloc([]const u8, args.len - 1) catch return 2;
    defer a.free(rest);
    for (args[1..], rest) |arg, *slot| slot.* = arg;
    return main_.mainWith(a, rest);
}
