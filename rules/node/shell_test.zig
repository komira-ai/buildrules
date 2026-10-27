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

const tartest = @import("tartest.zig");

test "an empty command name is refused where it stands; an empty later word is an argument" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const why = "an empty command name (`''` or `\"\"` where the program goes)";
    const cases = [_]struct { script: []const u8, at: usize }{
        .{ .script = "'' x", .at = 0 },
        .{ .script = "\"\" x", .at = 0 },
        .{ .script = "''", .at = 0 },
        .{ .script = "  '' x", .at = 2 },
        .{ .script = "A=1 '' x", .at = 4 },
        .{ .script = "a && \"\" x", .at = 5 },
    };
    for (cases) |c| {
        const bad = try refused(a, c.script);
        try std.testing.expectEqual(c.at, bad.at);
        try std.testing.expectEqualStrings(why, bad.why);
    }
    const good = try ok(a, "x '' y");
    try std.testing.expectEqual(@as(usize, 1), good.len);
    try std.testing.expectEqual(@as(usize, 3), good[0].argv.len);
    try std.testing.expectEqualStrings("x", good[0].argv[0]);
    try std.testing.expectEqualStrings("", good[0].argv[1]);
    try std.testing.expectEqualStrings("y", good[0].argv[2]);
    const env_empty = try ok(a, "A='' x");
    try std.testing.expectEqualStrings("", env_empty[0].env[0][1]);
    try std.testing.expectEqualStrings("x", env_empty[0].argv[0]);
}

test "each refusal says what the shell would have done" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const glob = "a glob or brace pattern (quote it to pass it to the program)";
    const cases = [_]struct { script: []const u8, at: usize, why: []const u8 }{
        .{ .script = "a | b", .at = 2, .why = "a pipe or `||`" },
        .{ .script = "a ; b", .at = 2, .why = "`;`" },
        .{ .script = "a > b", .at = 2, .why = "a redirection" },
        .{ .script = "a < b", .at = 2, .why = "a redirection" },
        .{ .script = "a (b)", .at = 2, .why = "a subshell" },
        .{ .script = "a b)", .at = 3, .why = "a subshell" },
        .{ .script = "a $b", .at = 2, .why = "a variable or command substitution" },
        .{ .script = "a `b`", .at = 2, .why = "a command substitution" },
        .{ .script = "a *", .at = 2, .why = glob },
        .{ .script = "a ?", .at = 2, .why = glob },
        .{ .script = "a [b]", .at = 2, .why = glob },
        .{ .script = "a b]", .at = 3, .why = glob },
        .{ .script = "a {b,c}", .at = 2, .why = glob },
        .{ .script = "a b}", .at = 3, .why = glob },
        .{ .script = "cd ~", .at = 3, .why = "`~`" },
        .{ .script = "a !b", .at = 2, .why = "`!`" },
        .{ .script = "a #b", .at = 2, .why = "a comment" },
        .{ .script = "a\nb", .at = 1, .why = "a newline" },
        .{ .script = "a\r", .at = 1, .why = "a newline" },
        .{ .script = "a & b", .at = 2, .why = "`&` (a background job)" },
        .{ .script = "a &", .at = 2, .why = "`&` (a background job)" },
        .{ .script = "a x&", .at = 3, .why = "`&` (a background job)" },
        .{ .script = "echo \"$HOME\"", .at = 6, .why = "a variable or command substitution (there is no shell to expand it)" },
        .{ .script = "echo \"`x`\"", .at = 6, .why = "a variable or command substitution (there is no shell to expand it)" },
        .{ .script = "echo \"a", .at = 7, .why = "an unterminated double quote" },
        .{ .script = "echo \"", .at = 6, .why = "an unterminated double quote" },
        .{ .script = "echo \"a\\", .at = 7, .why = "a backslash at the end" },
        .{ .script = "echo a\\", .at = 6, .why = "a backslash at the end" },
        .{ .script = "echo \"a\nb\"", .at = 7, .why = "a newline" },
        .{ .script = "echo 'a", .at = 5, .why = "an unterminated single quote" },
        .{ .script = "a && B=1", .at = 8, .why = "an empty command (or only assignments) around `&&`" },
        .{ .script = "a &&  && b", .at = 6, .why = "an empty command (or only assignments) around `&&`" },
    };
    for (cases) |c| {
        const bad = refused(a, c.script) catch |e| {
            std.debug.print("not refused: {s}\n", .{c.script});
            return e;
        };
        if (bad.at != c.at or !std.mem.eql(u8, bad.why, c.why)) std.debug.print("{s}: at {d} ({s}), want {d} ({s})\n", .{ c.script, bad.at, bad.why, c.at, c.why });
        try std.testing.expectEqual(c.at, bad.at);
        try std.testing.expectEqualStrings(c.why, bad.why);
    }
}

test "quotes and backslashes: what a shell would pass on is passed on, a metacharacter in quotes is a letter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // inside double quotes a backslash escapes only a quote, a backslash, a dollar and a backtick
    const dq = try ok(a, "echo \"a\\\"b\\\\c\\$d\\`e\\f\"");
    try std.testing.expectEqual(@as(usize, 2), dq[0].argv.len);
    try std.testing.expectEqualStrings("a\"b\\c$d`e\\f", dq[0].argv[1]);
    // quoted pieces and bare ones make one word; an empty pair of quotes is an empty argument
    const mixed = try ok(a, "x a'b c'd \"e f\"g ''");
    try std.testing.expectEqual(@as(usize, 4), mixed[0].argv.len);
    try std.testing.expectEqualStrings("ab cd", mixed[0].argv[1]);
    try std.testing.expectEqualStrings("e fg", mixed[0].argv[2]);
    try std.testing.expectEqualStrings("", mixed[0].argv[3]);
    // everything a shell acts on is only text in quotes
    const quoted = try ok(a, "x '|;<>()$*?[]{}~!#&\\' \"|;<>()*?[]{}~!#&'\"");
    try std.testing.expectEqualStrings("|;<>()$*?[]{}~!#&\\", quoted[0].argv[1]);
    try std.testing.expectEqualStrings("|;<>()*?[]{}~!#&'", quoted[0].argv[2]);
    // an escaped blank and an escaped metacharacter outside quotes
    const esc = try ok(a, "x a\\ b c\\;d");
    try std.testing.expectEqual(@as(usize, 3), esc[0].argv.len);
    try std.testing.expectEqualStrings("a b", esc[0].argv[1]);
    try std.testing.expectEqualStrings("c;d", esc[0].argv[2]);
    // tabs separate words as blanks do
    const tabs = try ok(a, "x\ta\t\tb");
    try std.testing.expectEqual(@as(usize, 3), tabs[0].argv.len);
}

test "&& needs no blanks around it, and each command has its own assignments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try ok(a, "a x&&b y &&c&& A=1 B= d");
    try std.testing.expectEqual(@as(usize, 4), c.len);
    try std.testing.expectEqualStrings("a", c[0].argv[0]);
    try std.testing.expectEqualStrings("x", c[0].argv[1]);
    try std.testing.expectEqualStrings("b", c[1].argv[0]);
    try std.testing.expectEqualStrings("y", c[1].argv[1]);
    try std.testing.expectEqualStrings("c", c[2].argv[0]);
    try std.testing.expectEqual(@as(usize, 0), c[2].env.len);
    try std.testing.expectEqualStrings("d", c[3].argv[0]);
    try std.testing.expectEqual(@as(usize, 2), c[3].env.len);
    try std.testing.expectEqualStrings("A", c[3].env[0][0]);
    try std.testing.expectEqualStrings("1", c[3].env[0][1]);
    try std.testing.expectEqualStrings("B", c[3].env[1][0]);
    try std.testing.expectEqualStrings("", c[3].env[1][1]);
}

test "a word that looks like an assignment but is not a name is the command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const words = [_][]const u8{ "1A=b", "A-B=c", "=x", "a.b=c" };
    for (words) |w| {
        const c = try ok(a, try std.fmt.allocPrint(a, "{s} arg", .{w}));
        try std.testing.expectEqual(@as(usize, 0), c[0].env.len);
        try std.testing.expectEqualStrings(w, c[0].argv[0]);
        try std.testing.expectEqualStrings("arg", c[0].argv[1]);
    }
    // a name with a digit after its first character, and an underscore, is one
    const c = try ok(a, "_A1=v run");
    try std.testing.expectEqual(@as(usize, 1), c[0].env.len);
    try std.testing.expectEqualStrings("_A1", c[0].env[0][0]);
    try std.testing.expectEqualStrings("run", c[0].argv[0]);
}

fn parsesClean(a: std.mem.Allocator, script: *const []const u8) !void {
    const r = try shell.parse(a, script.*);
    switch (r) {
        .ok => {},
        .refused => return error.Refused,
    }
}

test "an allocation that fails while a script is read is an error, not a shorter script" {
    // every kind of word begins a word, as the first byte of a word is the one that allocates
    const script: []const u8 = "A=1 node -e \"x\\\"y\" 'q r' z\\ w && B=2 tsc -p . && c \"\\\"\" \"b\" \\x 'q' z && d";
    try tartest.allocSweep(parsesClean, &script);
}
