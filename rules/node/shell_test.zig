const std = @import("std");
const shell = @import("shell.zig");

fn ok(a: std.mem.Allocator, script: []const u8) ![]const shell.Command {
    const r = try shell.parse(a, script);
    return switch (r) {
        .ok => |c| c,
        .refused => |bad| {
            std.debug.print("refused at {d}: {s}\n", .{ bad.at, bad.why });
            return error.Refused;
        },
    };
}

fn refused(a: std.mem.Allocator, script: []const u8) !shell.Refusal {
    const r = try shell.parse(a, script);
    return switch (r) {
        .ok => error.NotRefused,
        .refused => |bad| bad,
    };
}

test "one command with arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try ok(arena.allocator(), "  jest --ci  --maxWorkers=2 ");
    try std.testing.expectEqual(@as(usize, 1), c.len);
    try std.testing.expectEqual(@as(usize, 3), c[0].argv.len);
    try std.testing.expectEqualStrings("jest", c[0].argv[0]);
    try std.testing.expectEqualStrings("--maxWorkers=2", c[0].argv[2]);
}

test "quotes keep blanks and metacharacters; a double quote keeps single quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try ok(arena.allocator(), "esbuild 'src/a b.ts' \"--external:@aws-sdk/*\" x\\ y \"it's\"");
    try std.testing.expectEqual(@as(usize, 5), c[0].argv.len);
    try std.testing.expectEqualStrings("src/a b.ts", c[0].argv[1]);
    try std.testing.expectEqualStrings("--external:@aws-sdk/*", c[0].argv[2]);
    try std.testing.expectEqualStrings("x y", c[0].argv[3]);
    try std.testing.expectEqualStrings("it's", c[0].argv[4]);
}

test "the mopm site build script: four commands joined by &&, node -e with a quoted program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try ok(arena.allocator(), "node -e \"require('fs').rmSync('build',{recursive:true,force:true})\" && tsc -p tsconfig.browser.json && tsc -p tsconfig.tools.json && node build/tools/tools/build.js");
    try std.testing.expectEqual(@as(usize, 4), c.len);
    try std.testing.expectEqualStrings("-e", c[0].argv[1]);
    try std.testing.expectEqualStrings("require('fs').rmSync('build',{recursive:true,force:true})", c[0].argv[2]);
    try std.testing.expectEqualStrings("tsc", c[2].argv[0]);
    try std.testing.expectEqualStrings("build/tools/tools/build.js", c[3].argv[1]);
}

test "leading assignments are the command's environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try ok(arena.allocator(), "CI=1 FOO=a=b jest x=y");
    try std.testing.expectEqual(@as(usize, 2), c[0].env.len);
    try std.testing.expectEqualStrings("FOO", c[0].env[1][0]);
    try std.testing.expectEqualStrings("a=b", c[0].env[1][1]);
    try std.testing.expectEqualStrings("jest", c[0].argv[0]);
    try std.testing.expectEqualStrings("x=y", c[0].argv[1]);
}

test "what a shell would act on is refused, with where" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { script: []const u8, at: usize }{
        .{ .script = "a | b", .at = 2 },
        .{ .script = "a ; b", .at = 2 },
        .{ .script = "a || b", .at = 2 },
        .{ .script = "a > out", .at = 2 },
        .{ .script = "a < in", .at = 2 },
        .{ .script = "a &", .at = 2 },
        .{ .script = "echo $HOME", .at = 5 },
        .{ .script = "echo \"$HOME\"", .at = 6 },
        .{ .script = "echo `x`", .at = 5 },
        .{ .script = "rm *.js", .at = 3 },
        .{ .script = "(a)", .at = 0 },
        .{ .script = "a # c", .at = 2 },
        .{ .script = "'abc", .at = 0 },
        .{ .script = "a\nb", .at = 1 },
        .{ .script = "a && && b", .at = 5 },
        .{ .script = "&& a", .at = 0 },
        .{ .script = "a &&", .at = 4 },
        .{ .script = "", .at = 0 },
        .{ .script = "FOO=1", .at = 5 },
    };
    for (cases) |c| {
        const bad = refused(a, c.script) catch |e| {
            std.debug.print("not refused: {s}\n", .{c.script});
            return e;
        };
        if (bad.at != c.at) std.debug.print("{s}: at {d}, want {d} ({s})\n", .{ c.script, bad.at, c.at, bad.why });
        try std.testing.expectEqual(c.at, bad.at);
    }
}
