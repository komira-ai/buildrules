//! `buildrules autopin`: regenerate the pin tables of a Dependabot pull request (and, in the commit half, check
//! and commit what was regenerated). Two programs' worth of trust in one binary: `compute` runs on the pull
//! request's checkout with no secrets and writes an artifact; nothing it writes is believed by anything that
//! comes after it.

const std = @import("std");
const compute = @import("autopin_compute.zig");
const ctxm = @import("ctx.zig");
const Ctx = ctxm.Ctx;

pub const usage_text =
    \\usage: buildrules autopin compute --event FILE --out DIR --set DIR=KIND [--set DIR=KIND ...] [--dir DIR]
    \\
    \\  compute   regenerate the pin tables (buildrules.lock.bzl, pins.lock.bzl) of the directories named by --set from their
    \\            package-lock.json, downloading what the table lacks from registry.npmjs.org, and write the tables that changed and
    \\            a manifest.json under --out (its usage text: `autopin compute -h`)
    \\
    \\Exit codes: 0 ok, 1 refused or failed, 2 usage.
    \\
;

pub fn run(ctx: *Ctx, args: []const []const u8) u8 {
    if (args.len == 0) return ctx.usage("autopin: a subcommand is needed\n{s}", .{usage_text});
    const sub = args[0];
    if (std.mem.eql(u8, sub, "compute")) {
        if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
            ctx.say("{s}", .{compute.usage_text});
            return ctxm.exit_ok;
        }
        return compute.run(ctx, args[1..]);
    }
    return ctx.usage("autopin: unknown subcommand {s}\n{s}", .{ sub, usage_text });
}
