//! buildrules: the command line of the buildrules build rules. Written in Zig
//! because the rules themselves build it; it grows from kpin
//! (kpin), whose Cargo.lock reader it carries. docs/contract.md (in the buildrules
//! repository) is the contract these commands write and read.

const std = @import("std");
const cargo_cmd = @import("cargo_cmd.zig");
const check = @import("check.zig");
const ctxm = @import("ctx.zig");
const init = @import("init.zig");
const npm_cmd = @import("npm_cmd.zig");
const mojo_cmd = @import("mojo_cmd.zig");
const sync = @import("sync.zig");
const Ctx = ctxm.Ctx;

pub const version = "0.0.3-poc";

pub const usage_text =
    \\usage: buildrules <command> [flags]
    \\
    \\commands
    \\  init    write the buildrules cell, toolchains/, platforms/, .gitignore lines, rust-toolchain.toml
    \\          and a virtual Cargo workspace into a repository
    \\  cargo   `cargo new PATH` / `cargo init [PATH]` / `cargo adopt [PATH...]`: a Cargo package the build
    \\          knows about (BUCK file, [package.metadata.buildrules], a workspace member)
    \\  sync    cargo's files to the generated table (buildrules.lock.bzl), the macro wrapper
    \\          (buildrules.bzl) and third_party/buildrules; runs the pinned cargo and the generator
    \\  npm     `npm sync [PATH...]` / `npm check [PATH...]`: package.json and package-lock.json to the generated
    \\          table (buildrules.lock.bzl) and glue (buildrules.bzl) of an npm_package; check is offline
    \\  check   offline: exit 1 unless the generated files still match cargo's files (and, for Mojo packages, mopm's files)
    \\  mojo    `mojo sync` / `mojo check`: mopm's unit graph of each Mojo package to buildrules.mojo.lock.bzl, and the offline gate
    \\
    \\`buildrules <command> --help` prints the flags. Exit codes: 0 ok, 1 failed or stale, 2 usage.
    \\The contract (files, schema, metadata, exit codes) is docs/contract.md in the buildrules repository.
    \\
;

pub fn run(ctx: *Ctx, argv: []const []const u8) u8 {
    if (argv.len == 0) return ctx.usage("{s}", .{usage_text});
    const cmd = argv[0];
    const rest = argv[1..];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        ctx.say("{s}", .{usage_text});
        return ctxm.exit_ok;
    }
    if (std.mem.eql(u8, cmd, "--version")) {
        ctx.say("buildrules {s}", .{version});
        return ctxm.exit_ok;
    }
    if (rest.len == 1 and (std.mem.eql(u8, rest[0], "--help") or std.mem.eql(u8, rest[0], "-h"))) {
        const text: ?[]const u8 = if (std.mem.eql(u8, cmd, "init")) init.usage_text else if (std.mem.eql(u8, cmd, "cargo")) cargo_cmd.usage_text else if (std.mem.eql(u8, cmd, "sync")) sync.usage_text else if (std.mem.eql(u8, cmd, "check")) check.usage_text else if (std.mem.eql(u8, cmd, "npm")) npm_cmd.usage_text else if (std.mem.eql(u8, cmd, "mojo")) mojo_cmd.usage_text else null;
        if (text) |t| {
            ctx.say("{s}", .{t});
            return ctxm.exit_ok;
        }
    }
    if (std.mem.eql(u8, cmd, "init")) return init.run(ctx, rest);
    if (std.mem.eql(u8, cmd, "cargo")) return cargo_cmd.run(ctx, rest);
    if (std.mem.eql(u8, cmd, "sync")) return sync.run(ctx, rest);
    if (std.mem.eql(u8, cmd, "check")) return check.run(ctx, rest);
    if (std.mem.eql(u8, cmd, "npm")) return npm_cmd.run(ctx, rest);
    if (std.mem.eql(u8, cmd, "mojo")) return mojo_cmd.run(ctx, rest);
    return ctx.usage("unknown command {s}\n{s}", .{ cmd, usage_text });
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);
    var err = std.fs.File.stderr().writer(&err_buf);
    var ctx = Ctx{ .a = a, .dir = std.fs.cwd(), .out = &out.interface, .err = &err.interface };
    const code = run(&ctx, args[1..]);
    out.interface.flush() catch {};
    err.interface.flush() catch {};
    std.process.exit(code);
}
