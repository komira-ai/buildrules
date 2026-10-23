//! What the parsers, the resolver and the renderer do when an allocation fails. Each case runs one function over valid input once with a normal allocator
//! (the answer), then again with an allocator that fails from its n-th allocation on, for every n up to the number the function makes. A run that fails
//! must be an error and a run that does not must give the answer: a lock, a pin list or a package list is never half of what the inputs say, and never
//! a different one. (A function that cannot get memory has no message to say so with: the message list is allocated too. So the inputs are valid, and
//! the answer is the only thing to check.)

const std = @import("std");
const fx = @import("fixtures.zig");
const lockfmt = @import("lockfmt.zig");
const npm = @import("npm.zig");
const pins = @import("pins.zig");
const resolve = @import("resolve.zig");
const toml = @import("toml.zig");
const Diag = @import("diag.zig").Diag;
const Report = @import("diag.zig").Report;
const t = std.testing;

/// An allocator that never grows or shrinks a block in place, over `child`: a list that outgrows its block asks for a new one, which the failing allocator
/// can refuse (an arena would extend its last block in place, and the allocation that would have failed is never made).
const NoResize = struct {
    child: std.mem.Allocator,

    const vtable = std.mem.Allocator.VTable{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn allocator(self: *NoResize) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *NoResize = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
};

fn sweep(comptime run: fn (std.mem.Allocator) anyerror![]const u8) !void {
    var base = std.heap.ArenaAllocator.init(t.allocator);
    defer base.deinit();
    const want = try run(base.allocator());
    var failed_runs: usize = 0;
    var n: usize = 0;
    while (true) : (n += 1) {
        var ar = std.heap.ArenaAllocator.init(t.allocator);
        defer ar.deinit();
        var no_resize = NoResize{ .child = ar.allocator() };
        var fa = std.testing.FailingAllocator.init(no_resize.allocator(), .{ .fail_index = n });
        if (run(fa.allocator())) |got| {
            if (!std.mem.eql(u8, got, want)) {
                std.debug.print("allocation {d} failed and the answer changed. got:\n{s}\nwant:\n{s}\n", .{ n, got, want });
                return error.AnswerChangedAfterAllocationFailure;
            }
        } else |e| {
            if (!fa.has_induced_failure) {
                std.debug.print("{s} without any allocation failing\n", .{@errorName(e)});
                return e;
            }
        }
        if (!fa.has_induced_failure) break;
        failed_runs += 1;
    }
    // The function allocates more than a couple of times, or the sweep tested nothing.
    try t.expect(failed_runs > 2);
}

const pins_text =
    \\# toolchains
    \\[zig]
    \\version = "0.12.0"
    \\url = "https://ziglang.org/download/{version}/zig-{platform}-{version}.tar.xz"
    \\latest_url = "https://api.example.org/zig/latest"
    \\latest_field = "tag_name"
    \\version_prefix = "v"
    \\
    \\[zig.platform.macos-aarch64]
    \\token = "macos-aarch64"
    \\sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    \\size = 3
    \\
    \\[zig.platform.linux-x86_64]
    \\sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    \\size = 3
    \\
    \\[archiver]
    \\version = "1.35.0"
    \\url = "https://tools.example/downloads/{version}/archiver"
    \\[archiver.platform.any]
    \\sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    \\size = 3
    \\
;

fn tomlAnswer(a: std.mem.Allocator) anyerror![]const u8 {
    var d = Diag.init(a);
    const tables = try toml.parse(a, pins_text, &d);
    var out = std.ArrayList(u8).empty;
    for (tables) |tb| {
        try out.print(a, "[{s}] line {d}\n", .{ tb.path, tb.line });
        for (tb.entries.items) |e| switch (e.value) {
            .string => |s| try out.print(a, "  {s} = \"{s}\" line {d}\n", .{ e.key, s, e.line }),
            .int => |n| try out.print(a, "  {s} = {d} line {d}\n", .{ e.key, n, e.line }),
        };
    }
    return out.items;
}

test "toml.parse: an allocation that fails is an error, never a shorter list of tables" {
    try sweep(tomlAnswer);
}

fn pinsAnswer(a: std.mem.Allocator) anyerror![]const u8 {
    var d = Diag.init(a);
    const list = try pins.load(a, pins_text, &d);
    var out = std.ArrayList(u8).empty;
    for (list) |p| {
        try out.print(a, "{s} {s} {s} {?s} {?s} `{s}`\n", .{ p.name, p.version, p.url, p.latest_url, p.latest_field, p.version_prefix });
        for (p.platforms) |pf| try out.print(a, "  {s} {s} {?s} {?d}\n", .{ pf.id, pf.token, pf.sha256, pf.size });
    }
    return out.items;
}

test "pins.load: an allocation that fails is an error, never a pin without a platform or a platform without its hash" {
    try sweep(pinsAnswer);
}

const entries = [_]fx.NpmEntry{
    .{ .path = "node_modules/zeta", .version = "1.0.0", .resolved = "https://registry.npmjs.org/zeta/-/zeta-1.0.0.tgz", .integrity = fx.ABC_SRI512 },
    .{ .path = "node_modules/@scope/pkg", .version = "2.0.1", .resolved = "https://registry.npmjs.org/@scope/pkg/-/pkg-2.0.1.tgz", .integrity = fx.ABC_SRI512 },
    .{ .path = "node_modules/a/node_modules/zeta", .version = "1.0.0", .resolved = "https://mirror.example/zeta-1.0.0.tgz", .integrity = fx.ABC_SRI512 },
    .{ .path = "node_modules/alias", .name = "real", .version = "3.0.0", .resolved = "https://registry.npmjs.org/real/-/real-3.0.0.tgz", .integrity = fx.ABC_SRI512 },
};

fn pkgText(a: std.mem.Allocator, pkgs: []const npm.Pkg) anyerror![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (pkgs) |p| try out.print(a, "{s} {s} {s} {s} {s}\n", .{ p.key, p.name, p.version, p.url, p.sri512 });
    return out.items;
}

fn npmAnswer(a: std.mem.Allocator) anyerror![]const u8 {
    const json = try fx.packageLock(a, &entries);
    var d = Diag.init(a);
    return pkgText(a, try npm.read(a, "package-lock.json", json, &d));
}

test "npm.read: an allocation that fails is an error, never a lockfile with a package missing" {
    try sweep(npmAnswer);
}

fn mergeAnswer(a: std.mem.Allocator) anyerror![]const u8 {
    const l1 = [_]npm.Pkg{
        .{ .key = "a@1.0.0", .name = "a", .version = "1.0.0", .url = "https://r.example/a.tgz", .sri512 = fx.ABC_SRI512 },
        .{ .key = "b@1.0.0", .name = "b", .version = "1.0.0", .url = "https://r.example/b.tgz", .sri512 = fx.ABC_SRI512 },
    };
    const l2 = [_]npm.Pkg{.{ .key = "a@1.0.0", .name = "a", .version = "1.0.0", .url = "https://m.example/a.tgz", .sri512 = fx.ABC_SRI512 }};
    var d = Diag.init(a);
    return pkgText(a, try npm.merge(a, &.{ &l1, &l2 }, &d));
}

test "npm.merge: an allocation that fails is an error, never a list that lost the smaller URL" {
    try sweep(mergeAnswer);
}

const golden = @embedFile("example.lock.bzl");

fn exampleLock() lockfmt.Lock {
    const Files = struct {
        const list = [_]lockfmt.File{
            .{ .platform = "linux-x86_64", .url = "https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz", .sha256 = "c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad", .size = 45480516 },
            .{ .platform = "linux-aarch64", .url = "https://ziglang.org/download/0.12.0/zig-linux-aarch64-0.12.0.tar.xz", .sha256 = fx.ABC_SHA256, .size = 3 },
        };
        const pin_list = [_]lockfmt.LockPin{.{ .name = "zig", .version = "0.12.0", .files = &list }};
        const npm_list = [_]lockfmt.Npm{
            .{ .key = "left-pad@1.3.0", .name = "left-pad", .version = "1.3.0", .url = "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz", .sri512 = fx.ABC_SRI512, .sha256 = fx.ABC_SHA256, .size = 3 },
            .{ .key = "@scope/pkg@2.0.1", .name = "@scope/pkg", .version = "2.0.1", .url = "https://registry.npmjs.org/@scope/pkg/-/pkg-2.0.1.tgz", .sri512 = fx.ABC_SRI512, .sha256 = fx.ABC_SHA256, .size = 3 },
        };
    };
    return .{ .pins = &Files.pin_list, .npm = &Files.npm_list };
}

fn renderAnswer(a: std.mem.Allocator) anyerror![]const u8 {
    return lockfmt.render(a, exampleLock());
}

test "lockfmt.render: an allocation that fails is an error, never a truncated lock" {
    try sweep(renderAnswer);
    const whole = try lockfmt.render(t.allocator, exampleLock());
    defer t.allocator.free(whole);
    try t.expectEqualStrings(golden, whole);
}

fn parseAnswer(a: std.mem.Allocator) anyerror![]const u8 {
    var d = Diag.init(a);
    const lock = try lockfmt.parse(a, golden, &d);
    return lockfmt.render(a, lock);
}

test "lockfmt.parse: an allocation that fails is an error, never a lock with an entry missing" {
    try sweep(parseAnswer);
}

fn computeAnswer(a: std.mem.Allocator) anyerror![]const u8 {
    var d = Diag.init(a);
    const list = try pins.load(a, pins_text, &d);
    var rep = Report.init(a);
    const pkgs = [_]npm.Pkg{
        .{ .key = "left-pad@1.3.0", .name = "left-pad", .version = "1.3.0", .url = "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz", .sri512 = fx.ABC_SRI512 },
        .{ .key = "@scope/pkg@2.0.1", .name = "@scope/pkg", .version = "2.0.1", .url = "https://registry.npmjs.org/@scope/pkg/-/pkg-2.0.1.tgz", .sri512 = fx.ABC_SRI512 },
    };
    const prev = lockfmt.Lock{ .npm = exampleLock().npm };
    const lock = try resolve.compute(a, .{ .pins = list, .npm = &pkgs }, prev, &rep);
    if (!rep.clean()) return error.ReportNotClean;
    return lockfmt.render(a, lock);
}

test "resolve.compute: an allocation that fails is an error, never a lock with a file or a package missing" {
    try sweep(computeAnswer);
}
