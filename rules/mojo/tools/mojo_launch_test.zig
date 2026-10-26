//! Unit tests of mojo_launch.zig: the toolchain.cfg reader and the wrapper command line. The process behaviour
//! (mopm executing the launcher, the launcher executing the wrapper) is held by the unit actions of the examples.
const std = @import("std");
const L = @import("mojo_launch.zig");
const t = std.testing;

const cfg_text =
    \\# a comment
    \\wrapper=wrapper
    \\compiler=compiler
    \\zig=zig
    \\cc_target=x86_64-linux-gnu.2.34
    \\
    \\build_arg=--target-cpu
    \\build_arg=x86-64-v3
    \\
;

test "cfg: every key, and the repeated build_arg in order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    const c = try L.parseCfg(arena.allocator(), cfg_text, &why);
    try t.expectEqualStrings("wrapper", c.wrapper);
    try t.expectEqualStrings("x86_64-linux-gnu.2.34", c.cc_target);
    try t.expectEqualStrings("300", c.watchdog_idle_secs);
    try t.expectEqual(@as(usize, 2), c.build_args.len);
    try t.expectEqualStrings("x86-64-v3", c.build_args[1]);
}

test "cfg: a missing key, an unknown key and a line without `=` are refused with the reason" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Missing, L.parseCfg(arena.allocator(), "wrapper=w\ncompiler=c\nzig=z\n", &why));
    try t.expectEqualStrings("cc_target is not set", why);
    try t.expectError(error.UnknownKey, L.parseCfg(arena.allocator(), "colour=red\n", &why));
    try t.expectEqualStrings("unknown key colour", why);
    try t.expectError(error.BadLine, L.parseCfg(arena.allocator(), "oops\n", &why));
    try t.expectEqualStrings("not `key=value`: oops", why);
}

test "argv: the wrapper's options come first, mopm's arguments follow for a precompile (its source root aside, see below)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const c = try L.parseCfg(a, cfg_text, &why);
    const argv = try L.buildArgv(a, "/tc", c, &.{ "--source-root=/s/src", "--", "precompile", "-I/s/deps/x", "/s/src/p", "-o", "/o/p.mojoc" });
    try t.expectEqualStrings("/tc/wrapper", argv[0]);
    try t.expectEqualStrings("--compiler=/tc/compiler", argv[1]);
    try t.expectEqualStrings("--zig=/tc/zig", argv[2]);
    try t.expectEqualStrings("--cc-target=x86_64-linux-gnu.2.34", argv[3]);
    try t.expectEqualStrings("--source-root=/s/src/p", argv[6]);
    try t.expectEqualStrings("precompile", argv[8]);
    // No ISA flags on a precompile: a .mojoc is shared by every ISA level.
    try t.expectEqual(@as(usize, 6 + 7), argv.len);
}

test "argv: the ISA flags of the cfg go right after `build`, before mopm's own options" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const c = try L.parseCfg(a, cfg_text, &why);
    const argv = try L.buildArgv(a, "/tc", c, &.{ "--runpath=$ORIGIN/lib", "--source-root=/s/src", "--", "build", "-D", "ASSERT=all", "/s/src/t.mojo", "-o", "/o/t" });
    try t.expectEqualStrings("build", argv[9]);
    try t.expectEqualStrings("--target-cpu", argv[10]);
    try t.expectEqualStrings("x86-64-v3", argv[11]);
    try t.expectEqualStrings("-D", argv[12]);
}

test "argv: a `build` that is an argument of the compiler's other options is not mistaken for the subcommand" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const c = try L.parseCfg(a, cfg_text, &why);
    // `build` appears before the `--` (a path component): only the argument right after `--` counts.
    const argv = try L.buildArgv(a, "/tc", c, &.{ "--source-root=/build", "--", "precompile", "build" });
    try t.expectEqual(@as(usize, 6 + 4), argv.len);
}

test "precompile: mopm's source root (the staged src/) becomes the package directory, which is what the wrapper's contract means" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const c = try L.parseCfg(a, cfg_text, &why);
    const argv = try L.buildArgv(a, "/tc", c, &.{ "--source-root=/s/src", "--", "precompile", "-I/s/deps/x", "/s/src/pkg", "-o", "/o/pkg.mojoc" });
    try t.expectEqualStrings("--source-root=/s/src/pkg", argv[6]);
    // Nothing else moved.
    try t.expectEqualStrings("-I/s/deps/x", argv[9]);
    try t.expectEqualStrings("/s/src/pkg", argv[10]);
}

test "precompile: the package is found among options, -o and -I <dir> values, and a root that is already the package is left alone" {
    try t.expectEqualStrings("/s/src/p", L.precompilePackage(&.{ "--source-root=/s/src", "--", "precompile", "-I", "/s/src/other", "-I/x", "/s/src/p", "-o", "/s/src/o.mojoc" }).?);
    try t.expect(L.precompilePackage(&.{ "--source-root=/s/src/p", "--", "precompile", "/s/src/p", "-o", "/o" }) == null);
    try t.expect(L.precompilePackage(&.{ "--source-root=/s/src", "--", "build", "/s/src/t.mojo", "-o", "/o" }) == null);
    try t.expect(L.precompilePackage(&.{ "--", "precompile", "/s/src/p" }) == null);
    try t.expect(L.precompilePackage(&.{ "--source-root=/s/src", "--" }) == null);
}

const macos_cfg_text =
    \\wrapper=wrapper
    \\compiler=compiler
    \\deployment_target=11.0
    \\macos_host=27.0-0123456789abcdef
    \\macos_host=26.5-fedcba9876543210
    \\
;

// Defect caught: a macOS toolchain given the Linux wrapper's options (--zig, --cc-target), which the macOS wrapper refuses, or the host list cut to its
// first entry (a compile on the second worker would be refused).
test "argv: a macOS toolchain gives the wrapper its deployment target and every host, and no zig and no cc target" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    const c = try L.parseCfg(a, macos_cfg_text, &why);
    try t.expectEqual(@as(usize, 2), c.macos_hosts.len);
    const argv = try L.buildArgv(a, "/tc", c, &.{ "--source-root=/s/src", "--", "precompile", "-I/s/deps/x", "/s/src/p", "-o", "/o/p.mojoc" });
    try t.expectEqualStrings("/tc/wrapper", argv[0]);
    try t.expectEqualStrings("--compiler=/tc/compiler", argv[1]);
    try t.expectEqualStrings("--deployment-target=11.0", argv[2]);
    try t.expectEqualStrings("--macos-host=27.0-0123456789abcdef", argv[3]);
    try t.expectEqualStrings("--macos-host=26.5-fedcba9876543210", argv[4]);
    try t.expectEqualStrings("--watchdog-idle-secs=300", argv[5]);
    for (argv) |arg| {
        try t.expect(!std.mem.startsWith(u8, arg, "--zig="));
        try t.expect(!std.mem.startsWith(u8, arg, "--cc-target="));
    }
}

test "cfg: a macOS toolchain with no host, or with the Linux keys beside its own, is refused with the reason" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    try t.expectError(error.Missing, L.parseCfg(arena.allocator(), "wrapper=w\ncompiler=c\ndeployment_target=11.0\n", &why));
    try t.expectEqualStrings("macos_host is not set: a macOS compile names the hosts it may run on", why);
    try t.expectError(error.Missing, L.parseCfg(arena.allocator(), "wrapper=w\ncompiler=c\nmacos_host=1-2\n", &why));
    try t.expectEqualStrings("deployment_target is not set", why);
    try t.expectError(error.BadLine, L.parseCfg(arena.allocator(), "wrapper=w\ncompiler=c\nzig=z\ncc_target=t\ndeployment_target=11.0\nmacos_host=1-2\n", &why));
    try t.expectEqualStrings("a macOS toolchain (deployment_target, macos_host) names no zig and no cc_target", why);
}
