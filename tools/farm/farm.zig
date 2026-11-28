//! `farm`: the two steps a GitHub Actions job takes to build on the farm, shared by every repository that builds with buildrules.
//!
//!     farm connect ...   wait (bounded) until the farm answers, then write the buckconfig that sends builds there (connect.zig)
//!     farm run ...       run one buck2 command there, and once more after a cut connection when the farm answers again (run.zig)
//!
//! The farm-connect action (.github/actions/farm-connect/action.yml) builds this program on the runner and runs `farm connect`; a job's build
//! step runs `farm run`. tools/farm/README.md says how a repository uses them.
const std = @import("std");
const connect = @import("connect.zig");
const run = @import("run.zig");
const wait = @import("wait.zig");

pub const usage = "usage: farm connect|run --flag value ... (tools/farm/README.md)\n";

/// The real wait: TCP probes of the farm every 5 seconds on the system clock.
fn realWait(ctx: *anyopaque, target: wait.HostPort, limit_ms: u64, log: *std.Io.Writer) anyerror!wait.Waited {
    const a: *const std.mem.Allocator = @ptrCast(@alignCast(ctx));
    var probe = wait.TcpProbe{ .a = a.*, .target = target };
    return wait.wait(probe.probe(), wait.system_clock, wait.system_sleep, .{ .limit_ms = limit_ms }, log);
}

/// The verb in `args[0]` with the rest of `args`, run with `runner` and `waiter`. 2 for a missing or unknown verb.
pub fn dispatch(a: std.mem.Allocator, args: []const []const u8, runner: run.Runner, waiter: connect.Waiter, out: *std.Io.Writer, w: *std.Io.Writer) !u8 {
    if (args.len >= 1 and std.mem.eql(u8, args[0], "connect")) return connect.main(a, args[1..], waiter, out, w);
    if (args.len >= 1 and std.mem.eql(u8, args[0], "run")) return run.main(a, args[1..], runner, waiter, out, w);
    try w.writeAll(usage);
    try w.flush();
    return 2;
}

/// The real runner and wait, for `dispatch`.
pub fn realDispatch(a: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer, w: *std.Io.Writer) !u8 {
    var alloc = a;
    const runner = run.Runner{ .ctx = &alloc, .run_fn = run.runTee };
    const waiter = connect.Waiter{ .ctx = &alloc, .wait_fn = realWait };
    return dispatch(a, args, runner, waiter, out, w);
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);
    var err = std.fs.File.stderr().writer(&err_buf);
    const args = try a.alloc([]const u8, argv.len - 1);
    for (argv[1..], args) |arg, *slot| slot.* = arg;
    return realDispatch(a, args, &out.interface, &err.interface);
}
