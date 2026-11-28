//! The farm-connect action (.github/actions/farm-connect/action.yml, given to the test as `data`) held to the tool it runs: every step is
//! one command; it uses no other action; the tool is built from the action's own commit on the runner, in local
//! mode, to the path the connect step runs; the connect step passes every flag `farm connect` requires and no flag it does not know; and the
//! input's default wait is the tool's. Each rule is tested against an edited copy of the file that breaks it.
const std = @import("std");
const t = std.testing;
const connect = @import("connect.zig");
const args_mod = @import("args.zig");

const tool = "\"$RUNNER_TEMP/buildrules-farm\"";
const build_line = "run: '\"$BUCK2\" build --console simple -c buildrules_re.mode=local --out \"$RUNNER_TEMP/buildrules-farm\" //tools/farm:farm'";

/// The `run:` value of a line (`run: '<command>'`), or null.
fn runOf(line: []const u8) ?[]const u8 {
    const l = std.mem.trim(u8, line, " ");
    if (!std.mem.startsWith(u8, l, "run:")) return null;
    return std.mem.trim(u8, l["run:".len..], " ");
}

/// Why the action breaks a rule of the header, or null when it keeps them all.
pub fn problem(a: std.mem.Allocator, text: []const u8) !?[]const u8 {
    var connects: usize = 0;
    var built = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trim(u8, line, " ");
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, l, "- "), "uses:")) return "the action uses another action";
        const cmd = runOf(line) orelse continue;
        if (std.mem.eql(u8, cmd, "|") or std.mem.eql(u8, cmd, ">")) return "a `run:` is a script of several lines";
        if (std.mem.indexOf(u8, cmd, "&&") != null or std.mem.indexOfAny(u8, cmd, ";|") != null) return "a `run:` is more than one command";
        if (std.mem.eql(u8, l, build_line)) built = true;
        if (std.mem.startsWith(u8, cmd, "'" ++ tool ++ " connect ")) {
            connects += 1;
            if (try flagProblem(a, cmd)) |p| return p;
        }
    }
    if (!built) return "the tool is not built from the action's commit, in local mode, to the path the connect step runs";
    if (connects != 1) return "no step, or more than one, runs `farm connect`";
    const default_wait = try std.fmt.allocPrint(a, "default: \"{d}\"", .{args_mod.default_wait_minutes});
    const at = std.mem.indexOf(u8, text, "  wait-minutes:") orelse return "the action has no wait-minutes input";
    const next = std.mem.indexOfPos(u8, text, at, "    default:") orelse return "the wait-minutes input has no default";
    if (!std.mem.startsWith(u8, text[next + 4 ..], default_wait)) return "the wait-minutes input's default is not the tool's";
    return null;
}

/// Why the flags of the connect step's command are not the tool's, or null.
fn flagProblem(a: std.mem.Allocator, cmd: []const u8) !?[]const u8 {
    var seen = std.ArrayList([]const u8).empty;
    var words = std.mem.tokenizeScalar(u8, cmd, ' ');
    while (words.next()) |word| {
        if (!std.mem.startsWith(u8, word, "--")) continue;
        const name = word[2..];
        for (connect.flags) |known| {
            if (std.mem.eql(u8, known, name)) break;
        } else return "the connect step passes a flag `farm connect` does not know";
        try seen.append(a, name);
    }
    for (connect.flags) |known| {
        for (seen.items) |name| {
            if (std.mem.eql(u8, known, name)) break;
        } else return "the connect step leaves out a flag of `farm connect`";
    }
    return null;
}

fn actionText(a: std.mem.Allocator) ![]u8 {
    const work = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ work, ".github/actions/farm-connect/action.yml" });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

fn broken(a: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]u8 {
    try t.expect(std.mem.indexOf(u8, text, from) != null); // the file has the text the case changes
    return std.mem.replaceOwned(u8, a, text, from, to);
}

test "the farm-connect action keeps every rule, and an edited copy that breaks one is refused naming it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try actionText(a);
    try t.expectEqual(@as(?[]const u8, null), try problem(a, text));

    const cases = [_]struct { from: []const u8, to: []const u8, says: []const u8 }{
        .{ .from = "    - name: stop the buck2 of that build\n", .to = "    - uses: actions/cache@0123456789abcdef0123456789abcdef01234567\n    - name: stop the buck2 of that build\n", .says = "the action uses another action" },
        .{ .from = "run: '\"$BUCK2\" kill'", .to = "run: '\"$BUCK2\" kill; true'", .says = "a `run:` is more than one command" },
        .{ .from = "run: '\"$BUCK2\" kill'", .to = "run: '\"$BUCK2\" kill && true'", .says = "a `run:` is more than one command" },
        .{ .from = "run: '\"$BUCK2\" kill'", .to = "run: |\n        \"$BUCK2\" kill", .says = "a `run:` is a script of several lines" },
        .{ .from = "run: '\"$BUCK2\" kill'", .to = "run: >\n        \"$BUCK2\" kill", .says = "a `run:` is a script of several lines" },
        .{ .from = "-c buildrules_re.mode=local ", .to = "", .says = "the tool is not built from the action's commit, in local mode, to the path the connect step runs" },
        .{ .from = " --summary \"$GITHUB_STEP_SUMMARY\"", .to = "", .says = "the connect step leaves out a flag of `farm connect`" },
        .{ .from = " --summary \"$GITHUB_STEP_SUMMARY\"", .to = " --summary \"$GITHUB_STEP_SUMMARY\" --port 1", .says = "the connect step passes a flag `farm connect` does not know" },
        .{ .from = "'\"$RUNNER_TEMP/buildrules-farm\" connect ", .to = "'\"$RUNNER_TEMP/farm\" connect ", .says = "no step, or more than one, runs `farm connect`" },
        .{ .from = "    default: \"20\"", .to = "    default: \"5\"", .says = "the wait-minutes input's default is not the tool's" },
        .{ .from = "  wait-minutes:", .to = "  wait-for:", .says = "the action has no wait-minutes input" },
    };
    for (cases) |c| {
        const p = try problem(a, try broken(a, text, c.from, c.to));
        try t.expect(p != null);
        try t.expectEqualStrings(c.says, p.?);
    }
    // a wait-minutes input with no default after it
    try t.expectEqualStrings("the wait-minutes input has no default", (try problem(a, build_line ++ "\nrun: '" ++ tool ++ " connect --address a --instance i --properties p --tls t --wait-minutes w --out o --summary s'\n  wait-minutes:\n")).?);
}
