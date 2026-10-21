//! `buildrules autopin`: keep the pin tables of a Dependabot pull request current without a person. Three
//! subcommands, split by what they may be trusted with:
//!
//!   compute       runs on the pull request's checkout, with no secrets, and writes an artifact;
//!   commit-check  runs on the default branch's copy of the workflow, reads the artifact as hostile bytes and the
//!                 pull request from the API with a read-only token, and writes the tables it will vouch for;
//!   commit-push   holds the write token, and only turns the checked tables into one commit on the pull request's
//!                 branch, which it moves with `force: false`.
//!
//! Nothing a later stage believes comes from an earlier one except values it checks again.

const std = @import("std");
const api_mod = @import("autopin_api.zig");
const check = @import("autopin_check.zig");
const compute = @import("autopin_compute.zig");
const ctxm = @import("ctx.zig");
const push = @import("autopin_push.zig");
const Ctx = ctxm.Ctx;

pub const usage_text =
    \\usage: buildrules autopin compute      --event FILE --out DIR --set DIR=KIND [--set DIR=KIND ...] [--dir DIR]
    \\       buildrules autopin commit-check --event FILE --out DIR --set DIR=KIND [--set DIR=KIND ...] --app-login LOGIN [--github-output FILE]
    \\       buildrules autopin commit-push  --plan DIR --set DIR=KIND [--set DIR=KIND ...] --author-name NAME --author-email EMAIL
    \\
    \\  compute       regenerate the pin tables (buildrules.lock.bzl, pins.lock.bzl) of the directories named by --set from their
    \\                package-lock.json, downloading what the table lacks from registry.npmjs.org, and write the tables that changed and
    \\                a manifest.json under --out (its usage text: `autopin compute -h`)
    \\  commit-check  read the artifact of a compute run as untrusted bytes and the pull request from the GitHub API (GH_TOKEN,
    \\                read access), and write under --out the tables that may be committed and plan.json (`autopin commit-check -h`)
    \\  commit-push   commit the checked tables on the pull request's branch with the Git Data API (GH_TOKEN, write access); the branch
    \\                is moved with force false (`autopin commit-push -h`)
    \\
    \\Exit codes: 0 ok, 1 refused or failed, 2 usage.
    \\
;

/// Tests give a fake API; the program gives `Http` with the token in GH_TOKEN.
pub var api_override: ?api_mod.Api = null;

/// Tests only: stands in for GH_TOKEN, so that the construction of the real client can be run without a token in the environment.
pub var token_override: ?[]const u8 = null;

pub fn realApi(ctx: *Ctx) ?api_mod.Api {
    const token = token_override orelse (std.process.getEnvVarOwned(ctx.a, "GH_TOKEN") catch return null);
    if (token.len == 0) return null;
    const h = ctx.a.create(api_mod.Http) catch return null;
    h.* = .{ .allocator = ctx.a, .token = token };
    return h.api();
}

fn wantsHelp(args: []const []const u8) bool {
    return args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"));
}

pub fn run(ctx: *Ctx, args: []const []const u8) u8 {
    if (args.len == 0) return ctx.usage("autopin: a subcommand is needed\n{s}", .{usage_text});
    const sub = args[0];
    if (std.mem.eql(u8, sub, "compute")) {
        if (wantsHelp(args)) {
            ctx.say("{s}", .{compute.usage_text});
            return ctxm.exit_ok;
        }
        return compute.run(ctx, args[1..]);
    }
    const is_check = std.mem.eql(u8, sub, "commit-check");
    if (is_check or std.mem.eql(u8, sub, "commit-push")) {
        if (wantsHelp(args)) {
            ctx.say("{s}", .{if (is_check) check.usage_text else push.usage_text});
            return ctxm.exit_ok;
        }
        const api = api_override orelse realApi(ctx) orelse return ctx.fail("autopin {s}: GH_TOKEN is not set", .{sub});
        return if (is_check) check.run(ctx, args[1..], api) else push.run(ctx, args[1..], api);
    }
    return ctx.usage("autopin: unknown subcommand {s}\n{s}", .{ sub, usage_text });
}
