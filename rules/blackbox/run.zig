//! `blackbox_run run`: one black-box test (README.md, defs.bzl): packages put onto an image, then a driver run in it.
//!
//!   blackbox_run run --image REF --root DIR --package FILE [--sha256 HEX --size N] [--package FILE [--sha256 HEX --size N]]... --driver PROGRAM
//!                    [--farm]
//!
//! In order: with `--farm`, it requires to be a farm job whose frontend received REF as `container-image`, and prints the job's action digest
//! (farm.zig). It reads every package and refuses one whose size and sha256 are given and are not its own (nothing is written before every package is
//! checked), and refuses two packages that ship the same file, naming the path and both. It unpacks each package's files (deb.zig: the data member, not
//! the maintainer scripts) over DIR, so each file is at the path its package ships it, replacing the image's own file there. It runs PROGRAM with DIR, made absolute, as its one argument, with this process's environment and streams, and waits
//! for it: what the test does (start the service and the fakes the packages hold, drive them, stop them, print what they said) is the driver's.
//!
//! The status is the driver's when it failed, 1 when anything else failed (a package that is not the pinned one or cannot be unpacked, a driver that
//! cannot be started, a farm job that is not the test's), 2 for a wrong command line, and 0 when the driver passed.

const std = @import("std");
const io_mod = @import("io.zig");
const deb = @import("deb.zig");
const farm = @import("farm.zig");
const probe = @import("probe.zig");

const Alloc = io_mod.Alloc;
const Oom = io_mod.Oom;
const Io = io_mod.Io;

/// The largest package read (a service's package is tens of MiB).
pub const max_package: usize = 1 << 31;

pub const Package = struct { path: []const u8, sha256: ?[]const u8 = null, size: ?u64 = null };

pub const Options = struct {
    image: []const u8 = "",
    root: []const u8 = "",
    packages: std.ArrayList(Package) = .empty,
    driver: []const u8 = "",
    farm: bool = false,
};

fn usage(io: Io, comptime fmt: []const u8, args: anytype) ?Options {
    io.say("run: " ++ fmt, args);
    return null;
}

/// The options of `args`, or null when they are wrong (said on stderr).
pub fn parse(a: Alloc, io: Io, args: []const []const u8) Oom!?Options {
    var o = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const opt = args[i];
        if (std.mem.eql(u8, opt, "--farm")) {
            o.farm = true;
            continue;
        }
        if (i + 1 == args.len) return usage(io, "`{s}` is not an option, or it has no value", .{opt});
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, opt, "--image")) {
            o.image = v;
        } else if (std.mem.eql(u8, opt, "--root")) {
            o.root = v;
        } else if (std.mem.eql(u8, opt, "--package")) {
            try o.packages.append(a, .{ .path = v });
        } else if (std.mem.eql(u8, opt, "--sha256") or std.mem.eql(u8, opt, "--size")) {
            // The pin of the package given just before it.
            if (o.packages.items.len == 0) return usage(io, "`{s}` comes before any `--package`: it pins the package given before it", .{opt});
            const p = &o.packages.items[o.packages.items.len - 1];
            if (std.mem.eql(u8, opt, "--sha256")) {
                if (p.sha256 != null) return usage(io, "the package {s} is given two sha256", .{p.path});
                p.sha256 = v;
            } else {
                if (p.size != null) return usage(io, "the package {s} is given two sizes", .{p.path});
                p.size = std.fmt.parseInt(u64, v, 10) catch return usage(io, "`--size {s}` is not a number of bytes", .{v});
            }
        } else if (std.mem.eql(u8, opt, "--driver")) {
            o.driver = v;
        } else {
            return usage(io, "`{s}` is not an option", .{opt});
        }
    }
    for ([_]struct { []const u8, []const u8 }{ .{ "--image", o.image }, .{ "--root", o.root }, .{ "--driver", o.driver } }) |req| {
        if (req[1].len == 0) return usage(io, "`{s}` is required", .{req[0]});
    }
    if (o.packages.items.len == 0) return usage(io, "no `--package`: a test puts at least one package onto its image", .{});
    for (o.packages.items) |p| {
        if ((p.sha256 == null) != (p.size == null)) return usage(io, "the package {s}: `--sha256` and `--size` go together, it is pinned by both or by neither", .{p.path});
    }
    return o;
}

/// The image reference without `docker://`.
fn dockerRef(image: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, image, "docker://")) image["docker://".len..] else image;
}

/// The status of `blackbox_run run ARGS`.
pub fn run(a: Alloc, io: Io, args: []const []const u8) Oom!u8 {
    const o = (try parse(a, io, args)) orelse return 2;
    if (o.farm) {
        if (!(try onFarm(a, io, o.image))) return 1;
    }
    // Every package is read and checked before anything is written: a package that is not the pinned one leaves the image as it was.
    const bytes = try a.alloc([]const u8, o.packages.items.len);
    for (o.packages.items, bytes) |p, *b| {
        b.* = std.fs.cwd().readFileAlloc(a, p.path, max_package) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                io.say("run: cannot read the package {s}: {s}", .{ p.path, @errorName(e) });
                return 1;
            },
        };
        const want = p.sha256 orelse continue;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(b.*, &digest, .{});
        const got = std.fmt.bytesToHex(digest, .lower);
        if (b.len != p.size.? or !std.mem.eql(u8, &got, want)) {
            io.say("run: the package {s} is {d} bytes of sha256 {s}, not the pinned {d} bytes of sha256 {s}", .{ p.path, b.len, &got, p.size.?, want });
            return 1;
        }
    }
    const root = try std.fs.path.resolve(a, &.{ io.cwd, o.root });
    // Two packages that ship the same file is a test that could not say which one the driver ran: refused, naming the path and both, before anything
    // is written.
    var owner = std.StringHashMap(usize).init(a);
    for (o.packages.items, bytes, 0..) |p, b, k| {
        const listing = try deb.files(a, b);
        if (listing.why) |why| {
            io.say("run: the package {s} cannot be put onto {s}: {s}", .{ p.path, root, why });
            return 1;
        }
        for (listing.paths) |path| {
            const got = try owner.getOrPut(path);
            if (got.found_existing) {
                io.say("run: the packages {s} and {s} both ship /{s}: a test puts each file onto the image from one package", .{ o.packages.items[got.value_ptr.*].path, p.path, path });
                return 1;
            }
            got.value_ptr.* = k;
        }
    }
    var dir = std.fs.cwd().openDir(root, .{}) catch |e| {
        io.say("run: cannot open the root {s}: {s}", .{ root, @errorName(e) });
        return 1;
    };
    defer dir.close();
    for (o.packages.items, bytes) |p, b| {
        if (try deb.unpack(a, b, dir)) |why| {
            io.say("run: the package {s} cannot be put onto {s}: {s}", .{ p.path, root, why });
            return 1;
        }
    }
    var env = std.process.EnvMap.init(a);
    for (io.environ) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        try env.put(entry[0..eq], entry[eq + 1 ..]);
    }
    const status = io.plat.runInherit(io.plat.ctx, a, &.{ o.driver, root }, &env) catch |e| {
        io.say("run: cannot run the driver {s}: {s}", .{ o.driver, @errorName(e) });
        return 1;
    };
    if (status != 0) {
        io.say("run: the driver exited {d}", .{status});
        return status;
    }
    io.say("run: passed: {d} package(s) put onto {s}, and the driver exited 0", .{ o.packages.items.len, root });
    return 0;
}

/// True when this is a farm job whose frontend received `image` as the job's `container-image` (said, with the job's action digest); false, said, when
/// it is not.
fn onFarm(a: Alloc, io: Io, image: []const u8) Oom!bool {
    const job = (farm.read(a, io.root) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            io.say("run: the farm job's Action or Command cannot be read: {s}", .{@errorName(e)});
            return false;
        },
    }) orelse {
        io.say("run: `--farm`, but this is not a farm job: the root holds no {s}; a black-box test runs on a farm only", .{farm.job_dir});
        return false;
    };
    try probe.report(a, io, job);
    const want = try std.fmt.allocPrint(a, "docker://{s}", .{dockerRef(image)});
    const got: []const u8 = if (farm.value(job.properties, "container-image")) |v| v else "";
    if (!std.mem.eql(u8, got, want)) {
        io.say("run: the job's container-image is `{s}`, not the test's `{s}`", .{ got, want });
        return false;
    }
    return true;
}
