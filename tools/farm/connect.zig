//! `farm connect`: waits, for a bounded time, until the farm answers on its port, then writes the buckconfig that sends a build there.
//!
//!     farm connect --address <url> --instance <name> --properties <set> --out <file> --summary <file> [--tls true|false] [--wait-minutes N]
//!
//! The farm-connect action (.github/actions/farm-connect) runs it right after the job joined the farm's network. Every value is checked
//! first: an empty one (a fork's job gets no repository variables) or one with a line break is refused, because a buckconfig without the farm
//! makes buck2 build on the runner. Its address is masked in the job log (`::add-mask::`) before anything else is printed. Then the farm is
//! probed (wait.zig) every 5 seconds for `--wait-minutes` (20 by default): a connection to the farm can be gone for minutes at a time, and a
//! job that gave up after one minute had to be re-run by hand. When the farm answered after a wait, the job summary says how long. When it
//! does not answer within the limit, nothing is written and the step fails saying so.
//!
//! The buckconfig goes to `--out`, which must not exist yet (it is the checkout's `.buckconfig.local`, which overrides the repository's
//! `.buckconfig`): the remote-execution addresses, instance name and `tls`, the worker property set under `[buildrules_re]`, and three keys for
//! a slow connection to the farm (`execution_concurrency_limit`, and `grpc_keepalive_timeout_secs = 60` with
//! `max_concurrent_uploads_per_action = 4`, so a PING queued behind upload data is not taken for a dead connection).
const std = @import("std");
const wait = @import("wait.zig");
const args_mod = @import("args.zig");

pub const usage = "usage: farm connect --address <url> --instance <name> --properties <set> --out <file> --summary <file> [--tls true|false] [--wait-minutes N]\n";

/// What `farm connect` reads from its command line.
pub const Options = struct {
    address: []const u8,
    instance: []const u8,
    properties: []const u8,
    tls: []const u8,
    out: []const u8,
    summary: []const u8,
    wait_ms: u64,
};

/// The wait for the farm, given its host and port: the real one probes it (farm.zig), the tests' return what the case needs.
pub const Waiter = struct {
    ctx: *anyopaque,
    wait_fn: *const fn (ctx: *anyopaque, target: wait.HostPort, limit_ms: u64, log: *std.Io.Writer) anyerror!wait.Waited,

    pub fn untilAnswers(self: Waiter, target: wait.HostPort, limit_ms: u64, log: *std.Io.Writer) !wait.Waited {
        return self.wait_fn(self.ctx, target, limit_ms, log);
    }
};

pub const flags = [_][]const u8{ "address", "instance", "properties", "tls", "out", "summary", "wait-minutes" };

/// The options of `args`, or null after the reason is on `w`.
pub fn parse(args: []const []const u8, w: *std.Io.Writer) !?Options {
    var got = args_mod.Flags(flags.len).init(&flags);
    if (!try got.parse(args, w)) {
        try w.writeAll(usage);
        return null;
    }
    const required = [_][]const u8{ "address", "instance", "properties", "out", "summary" };
    var missing = false;
    for (required) |name| {
        if (got.get(name) == null) {
            try w.print("farm connect: --{s} is required\n", .{name});
            missing = true;
        }
    }
    if (missing) {
        try w.writeAll(usage);
        return null;
    }
    const wait_ms = (try args_mod.waitMs(got.get("wait-minutes"), "farm connect", w)) orelse {
        try w.writeAll(usage);
        return null;
    };
    return .{
        .address = got.get("address").?,
        .instance = got.get("instance").?,
        .properties = got.get("properties").?,
        .tls = got.get("tls") orelse "false",
        .out = got.get("out").?,
        .summary = got.get("summary").?,
        .wait_ms = wait_ms,
    };
}

/// Why the values cannot make a buckconfig, or null when they can.
pub fn refusal(o: Options) ?[]const u8 {
    const values = [_][]const u8{ o.address, o.instance, o.properties };
    for (values) |v| {
        if (v.len == 0) return "the farm's address, instance name or worker property set is empty (a job of a fork's pull request gets no repository variables); refusing, because buck2 would build on the runner instead of the farm";
    }
    const lines = [_][]const u8{ o.address, o.instance, o.properties, o.tls };
    for (lines) |v| {
        if (std.mem.indexOfAny(u8, v, "\r\n") != null) return "a value holds a line break; each value must be one line of the buckconfig";
    }
    if (!std.mem.eql(u8, o.tls, "true") and !std.mem.eql(u8, o.tls, "false")) return "--tls is neither true nor false";
    if (wait.hostPort(o.address) == null) return "the farm's address has no host and port (host:port, after an optional scheme)";
    return null;
}

/// The buckconfig that sends a build to the farm.
pub fn config(a: std.mem.Allocator, o: Options) ![]u8 {
    return std.fmt.allocPrint(a,
        \\# Written by `farm connect` (buildrules, tools/farm): the farm this job builds on.
        \\[buck2_re_client]
        \\  engine_address = {s}
        \\  action_cache_address = {s}
        \\  cas_address = {s}
        \\  instance_name = {s}
        \\  tls = {s}
        \\  execution_concurrency_limit = 256
        \\  grpc_keepalive_timeout_secs = 60
        \\  max_concurrent_uploads_per_action = 4
        \\[buildrules_re]
        \\  linux_x86_64_properties = {s}
        \\
    , .{ o.address, o.address, o.address, o.instance, o.tls, o.properties });
}

/// Appends `line` and a newline to the file at `path`, creating it if needed.
pub fn appendLine(path: []const u8, line: []const u8) !void {
    var f = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(line);
    try f.writeAll("\n");
}

/// `farm connect <args>`: the header says what it does. `out` is the job log (stdout), `w` gets the errors (stderr). 0 when the buckconfig
/// is written, 1 when the farm did not answer or a value is refused, 2 for a wrong command line or a file that cannot be written.
pub fn main(a: std.mem.Allocator, args: []const []const u8, waiter: Waiter, out: *std.Io.Writer, w: *std.Io.Writer) !u8 {
    const o = (try parse(args, w)) orelse {
        try w.flush();
        return 2;
    };
    // The logs of a public repository are public: the farm's address is masked before anything could print it.
    if (o.address.len > 0 and std.mem.indexOfAny(u8, o.address, "\r\n") == null) {
        try out.print("::add-mask::{s}\n", .{o.address});
        if (wait.hostPort(o.address)) |hp| try out.print("::add-mask::{s}\n", .{hp.host});
        try out.flush();
    }
    if (refusal(o)) |why| {
        try w.print("::error title=farm connect::{s}\n", .{why});
        try w.flush();
        return 1;
    }
    if (std.fs.cwd().access(o.out, .{})) |_| {
        try w.print("farm connect: {s} exists already; it is written here and nowhere else, so nothing of the farm's is mixed with another configuration\n", .{o.out});
        try w.flush();
        return 2;
    } else |_| {}

    const target = wait.hostPort(o.address).?;
    switch (try waiter.untilAnswers(target, o.wait_ms, out)) {
        .gave_up => |spent| {
            try w.writeAll("::error title=farm connect::the farm did not answer on its port within ");
            try wait.duration(w, spent);
            try w.writeAll(" of joining its network. Not building: with no farm buck2 would build on this runner. Look at whether the farm is up, the network policy between this job and the farm, and the trust of this job's token.\n");
            try w.flush();
            return 1;
        },
        .answered => |spent| {
            const text = try config(a, o);
            defer a.free(text);
            std.fs.cwd().writeFile(.{ .sub_path = o.out, .data = text, .flags = .{ .exclusive = true } }) catch |e| {
                try w.print("farm connect: cannot write {s}: {s}\n", .{ o.out, @errorName(e) });
                try w.flush();
                return 2;
            };
            var line = std.Io.Writer.Allocating.init(a);
            defer line.deinit();
            if (spent >= std.time.ms_per_s) {
                try line.writer.writeAll("farm connect: the farm answered after a wait of ");
                try wait.duration(&line.writer, spent);
                try line.writer.writeAll(" (the connection to it was down when the job joined its network)");
                appendLine(o.summary, line.written()) catch |e| {
                    try w.print("farm connect: cannot write the job summary {s}: {s}\n", .{ o.summary, @errorName(e) });
                    try w.flush();
                    return 2;
                };
                try out.print("{s}\n", .{line.written()});
            }
            try out.print("farm connect: the farm answers; wrote {s}\n", .{o.out});
            try out.flush();
            return 0;
        },
    }
}
