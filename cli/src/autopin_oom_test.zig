//! Support for the allocation-failure sweeps of the autopin tests (not a test file itself). A call runs once for each
//! allocation it makes: that allocation fails, the call must then fail closed (an error, or a refusal in its result)
//! and never report success. This is how the `OutOfMemory` arm of every `try` is run, and what each promises: an
//! allocation that fails is never an accepted artifact, a table written, or a commit made.

const std = @import("std");
const kit = @import("testkit.zig");
const main = @import("main.zig");
const t = std.testing;

/// `run(a, args)` returns true when it failed closed (a refusal in its result) and false when it succeeded; an error
/// is failing closed too. It is called with an arena over an allocator that fails its n-th allocation, for n = 0, 1, ...
/// until a call makes fewer allocations than n (it then ran to the end with none failed).
pub fn sweep(comptime run: anytype, args: anytype) !void {
    var n: usize = 0;
    while (n < 200000) : (n += 1) {
        var fa = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = n });
        var ar = std.heap.ArenaAllocator.init(fa.allocator());
        const closed = run(ar.allocator(), args) catch true;
        ar.deinit();
        if (!fa.has_induced_failure) return;
        if (!closed) {
            std.debug.print("allocation {d} failed and the call reported success\n", .{n});
            return error.OutOfMemorySwallowed;
        }
    }
    return error.TooManyAllocations;
}

/// Runs the command line of `argv` in the harness's directory once for each allocation it makes (its context's allocator
/// fails the n-th), removing `cleanup` (what a completed run leaves) between runs. A run that had an allocation fail must
/// exit non-zero. The harness's own output buffers are not the allocator under test.
pub fn sweepCommand(h: *kit.Harness, argv: []const []const u8, cleanup: []const []const u8) !void {
    var n: usize = 0;
    const saved = h.ctx.a;
    defer h.ctx.a = saved;
    while (n < 200000) : (n += 1) {
        for (cleanup) |p| h.tmp.dir.deleteTree(p) catch {};
        var fa = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = n });
        var ar = std.heap.ArenaAllocator.init(fa.allocator());
        h.ctx.a = ar.allocator();
        h.out.clearRetainingCapacity();
        h.err.clearRetainingCapacity();
        const code = main.run(&h.ctx, argv);
        h.ctx.a = saved;
        ar.deinit();
        for (cleanup) |p| h.tmp.dir.deleteTree(p) catch {};
        if (!fa.has_induced_failure) return;
        if (code == 0) {
            std.debug.print("allocation {d} failed and `{s}` exited 0\n", .{ n, argv[1] });
            return error.OutOfMemorySwallowed;
        }
    }
    return error.TooManyAllocations;
}

test "sweep: a call that swallows an allocation failure is reported" {
    const swallow = struct {
        fn f(a: std.mem.Allocator, _: void) !bool {
            _ = a.alloc(u8, 1) catch return false;
            return false;
        }
    }.f;
    try t.expectError(error.OutOfMemorySwallowed, sweep(swallow, {}));
    const closed = struct {
        fn f(a: std.mem.Allocator, _: void) !bool {
            _ = try a.alloc(u8, 1);
            return false;
        }
    }.f;
    try sweep(closed, {});
}

/// `sweep` for a helper that cannot return an error: a swallowed failure is a panic that names it.
pub fn mustSweep(comptime run: anytype, args: anytype) void {
    sweep(run, args) catch |e| std.debug.panic("allocation-failure sweep: {s}", .{@errorName(e)});
}
