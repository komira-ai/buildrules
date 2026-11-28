//! `blackbox_run probe [--expect NAME=VALUE]...`: the proof that a test ran as a farm job, and of the property set the farm's frontend received.
//!
//! It reads the job's Action and Command (farm.zig) from the root of the file system, prints the action digest and the property set, and fails unless
//! the Command is this process's own argument list and the property set is exactly the `--expect` pairs (none more, none fewer, each value equal). Off
//! the farm there is no Action to read, and it fails saying so.

const std = @import("std");
const farm = @import("farm.zig");

const Io = @import("io.zig").Io;
const Alloc = @import("io.zig").Alloc;

fn say(io: Io, comptime fmt: []const u8, args: anytype) void {
    io.say("probe: " ++ fmt, args);
}

/// The status of the probe: 0 when every check held, 1 when one did not, 2 for a wrong command line.
pub fn probe(a: Alloc, io: Io, args: []const []const u8) error{OutOfMemory}!u8 {
    var expect: std.ArrayList(farm.Property) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--expect") or i + 1 == args.len) {
            say(io, "unknown argument `{s}`: the arguments are `--expect NAME=VALUE`, any number of times", .{args[i]});
            return 2;
        }
        i += 1;
        const eq = std.mem.indexOfScalar(u8, args[i], '=') orelse {
            say(io, "`--expect {s}` is not NAME=VALUE", .{args[i]});
            return 2;
        };
        try expect.append(a, .{ .name = args[i][0..eq], .value = args[i][eq + 1 ..] });
    }
    const job = (farm.read(a, io.root) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            say(io, "the farm job's Action or Command cannot be read: {s}", .{@errorName(e)});
            return 1;
        },
    }) orelse {
        say(io, "not a farm job: the root holds no {s}, so this run is not a job of the farm's executor", .{farm.job_dir});
        return 1;
    };
    try report(a, io, job);
    if (!farm.matchesArgv(job, io.argv)) {
        say(io, "the job's Command is not this run: it ran {d} arguments, starting `{s}`", .{ job.arguments.len, if (job.arguments.len > 0) job.arguments[0] else "" });
        return 1;
    }
    var bad = false;
    for (expect.items) |want| {
        const got = farm.value(job.properties, want.name) orelse {
            say(io, "the property `{s}` did not reach the frontend", .{want.name});
            bad = true;
            continue;
        };
        if (!std.mem.eql(u8, got, want.value)) {
            say(io, "the property `{s}` reached the frontend as `{s}`, not `{s}`", .{ want.name, got, want.value });
            bad = true;
        }
    }
    for (job.properties) |p| {
        if (farm.value(expect.items, p.name) == null) {
            say(io, "the frontend received the property `{s}={s}`, which the test did not set", .{ p.name, p.value });
            bad = true;
        }
    }
    return if (bad) 1 else 0;
}

/// The two lines that say which farm job this is: its action digest (`buck2 log what-ran` prints the same) and the property set its frontend received.
pub fn report(a: Alloc, io: Io, job: farm.Job) error{OutOfMemory}!void {
    const rendered = try farm.render(a, job.properties);
    io.put(try std.fmt.allocPrint(a, "farm job: action {s}:{d}\nproperties the frontend received (from the {s}): {s}\n", .{ job.hash, job.size, @tagName(job.from), rendered }));
}
