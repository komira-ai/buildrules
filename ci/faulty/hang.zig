//! A program that never finishes: it reads from a pipe whose write end it holds itself and never writes, so the read blocks until the process is killed.
//! Nothing in it waits for a time to pass; the stand-in for a Mojo test that hangs (`mojo_test_that_hangs`, ci/faulty/BUCK).

const std = @import("std");

pub fn main() !void {
    const fds = try std.posix.pipe();
    var byte: [1]u8 = undefined;
    _ = try std.posix.read(fds[0], &byte);
}
