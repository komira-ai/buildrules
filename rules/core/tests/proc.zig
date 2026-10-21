//! What the process tests of the refusals share (rules/*/tests/*_refuse_test.zig): run a built tool as a child, in a directory of the test's own, with an empty
//! environment, and hold its exit status and its stderr to what the tool must say when it refuses. A zig_module named `refusal_proc`.
//!
//! A refusal is only a test if it can be told apart from a crash or a pass: `expectRefusal` demands the exact exit status, every fragment of the message on stderr,
//! and nothing on stdout (a tool that refuses prints no result).

const std = @import("std");

pub const Run = struct { code: u8, stdout: []const u8, stderr: []const u8 };

/// The path of the tool under test: the environment variable `name`, which the zig_test's `env_tools` sets. Without it the test fails loudly; it never passes
/// unchecked.
pub fn tool(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    const v = std.process.getEnvVarOwned(a, name) catch {
        std.debug.print("the test target does not pass {s} (env_tools), so the tool cannot be run\n", .{name});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(a, v);
}

/// Runs `argv` in `dir` with an empty environment.
pub fn run(a: std.mem.Allocator, dir: std.fs.Dir, argv: []const []const u8) !Run {
    var env = std.process.EnvMap.init(a);
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv, .cwd_dir = dir, .env_map = &env, .max_output_bytes = 1 << 20 });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => {
            std.debug.print("{s} did not exit: {any}; stderr:\n{s}\n", .{ argv[0], r.term, r.stderr });
            return error.TestUnexpectedResult;
        },
    };
    return .{ .code = code, .stdout = r.stdout, .stderr = r.stderr };
}

/// `r` is a refusal of status `code` whose stderr holds every one of `msgs`, with nothing on stdout.
pub fn expectRefusal(name: []const u8, r: Run, code: u8, msgs: []const []const u8) !void {
    var ok = r.code == code and r.stdout.len == 0;
    for (msgs) |m| ok = ok and std.mem.indexOf(u8, r.stderr, m) != null;
    if (!ok) {
        std.debug.print("{s}: exit {d}, want {d} with stderr holding {any} and nothing on stdout; stdout:\n{s}\nstderr:\n{s}\n", .{ name, r.code, code, msgs, r.stdout, r.stderr });
        return error.TestUnexpectedResult;
    }
}

/// `r` is a success: status 0.
pub fn expectOk(name: []const u8, r: Run) !void {
    if (r.code != 0) {
        std.debug.print("{s}: exit {d}, want 0; stderr:\n{s}\n", .{ name, r.code, r.stderr });
        return error.TestUnexpectedResult;
    }
}

test "expectRefusal: the status, every fragment and an empty stdout are all required" {
    const r = Run{ .code = 1, .stdout = "", .stderr = "tool: the floor is bad\n" };
    try expectRefusal("ok", r, 1, &.{ "tool:", "floor is bad" });
    try std.testing.expectError(error.TestUnexpectedResult, expectRefusal("status", r, 2, &.{"tool:"}));
    try std.testing.expectError(error.TestUnexpectedResult, expectRefusal("fragment", r, 1, &.{ "tool:", "missing" }));
    try std.testing.expectError(error.TestUnexpectedResult, expectRefusal("stdout", .{ .code = 1, .stdout = "result", .stderr = r.stderr }, 1, &.{"tool:"}));
}
