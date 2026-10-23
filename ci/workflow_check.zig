//! The public CI workflow (.github/workflows/ci.yml) is what docs/contract.md section 14 says it is. A pure function per rule, so each
//! rule is tested against planted text as well as against the real files (the zig_test's `data`, under BUILDRULES_TEST_WORK).
//!
//! What the rules catch:
//!  - an action referenced by a tag or branch (a moved tag changes what runs with the repository's token): every `uses:` is an
//!    owner/repo@<40 hex>;
//!  - a token with more than read access, or a trigger that runs fork code with secrets (`pull_request_target`);
//!  - a CI that stops building the target it promises (//ci:all), stops running the completeness check, runs in remote mode (every
//!    `./buck2` command that loads the graph, which is every one but `kill` and `--version`, build and bxl and audit and query and test
//!    alike, must pass `-c buildrules_re.mode=local`, because the execution platforms are analysed by all of them and fail without a mode;
//!    any other value of that key anywhere is refused; and buck2 is run only as the literal `./buck2`: a bare `buck2`, `/path/buck2`,
//!    `$BUCK2`, or a shell wrapper (`bash -c`, `eval`, `env`, `sudo`, ...) around one is refused, because a command this check cannot
//!    read as `./buck2 <subcommand> <args>` is a command whose mode it cannot check), or names a remote-execution endpoint;
//!  - a buck2 install that drifted from the release pinned in tools/buck2 (url or sha256).
//!  - a `push` trigger on ci.yml: a push to main is tested through release.yml (ci/release_check.zig), which calls this workflow.
//!
//! The pure checks that release.yml shares with this file (`pinnedUses`, `localMode`, `buck2Install`) are public here.
const std = @import("std");
const t = std.testing;

/// The one target the workflow builds: //ci:all covers the tree, and ci/completeness.bxl (run by the workflow) fails when it does not.
pub const targets = [_][]const u8{
    "//ci:all",
};

/// The workflow runs the completeness check before it builds.
const completeness = "./buck2 bxl -c buildrules_re.mode=local //ci:completeness.bxl:check";

pub const Findings = std.ArrayList([]const u8);

pub fn add(a: std.mem.Allocator, f: *Findings, comptime fmt: []const u8, args: anytype) !void {
    try f.append(try std.fmt.allocPrint(a, fmt, args));
}

pub fn isHex40(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

/// The value of `"digest": "..."` and the first provider url inside the `linux-x86_64` block of a dotslash file.
pub const DotslashPin = struct { digest: []const u8, url: []const u8 };

pub fn dotslashLinux(text: []const u8) ?DotslashPin {
    return dotslashPlatform(text, "linux-x86_64");
}

/// The same for the platform `name` (`linux-aarch64`): its block ends where the next platform's key begins.
pub fn dotslashPlatform(text: []const u8, name: []const u8) ?DotslashPin {
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "\"{s}\"", .{name}) catch return null;
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    var end = rest.len;
    for ([_][]const u8{ "\"linux-", "\"macos-" }) |next| {
        if (std.mem.indexOf(u8, rest, next)) |i| end = @min(end, i);
    }
    const block = rest[0..end];
    const digest = between(block, "\"digest\": \"", "\"") orelse return null;
    const url = between(block, "{\"url\": \"", "\"") orelse return null;
    return .{ .digest = digest, .url = url };
}

pub fn between(s: []const u8, open: []const u8, close: []const u8) ?[]const u8 {
    const i = std.mem.indexOf(u8, s, open) orelse return null;
    const from = i + open.len;
    const j = std.mem.indexOfPos(u8, s, from, close) orelse return null;
    return s[from..j];
}

pub fn hasLine(text: []const u8, exact: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trimRight(u8, line, " \r"), exact)) return true;
    }
    return false;
}

/// `s` without a trailing YAML comment and without surrounding blanks.
fn stripComment(s: []const u8) []const u8 {
    var end = s.len;
    for (s, 0..) |c, i| {
        if (c == '#' and (i == 0 or s[i - 1] == ' ' or s[i - 1] == '\t')) {
            end = i;
            break;
        }
    }
    return std.mem.trim(u8, s[0..end], " \t\r");
}

/// Why the `on:` block of `text` cannot be checked line by line, or null when it is plain block style with its triggers indented two spaces.
/// The trigger checks above compare whole lines (`  push:`), so `on: push`, `on: [push, pull_request]` and `  push: {branches: [main]}` would
/// slip past them; those spellings are refused rather than parsed.
pub fn triggerStyleProblem(text: []const u8) ?[]const u8 {
    var in_on = false;
    var base: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, " \t\r");
        const body = std.mem.trimLeft(u8, line, " ");
        if (body.len == 0 or body[0] == '#') continue;
        const indent = line.len - body.len;
        if (indent == 0) {
            in_on = false;
            for ([_][]const u8{ "on:", "\"on\":", "'on':" }) |key| {
                if (!std.mem.startsWith(u8, line, key)) continue;
                in_on = true;
                if (stripComment(line[key.len..]).len != 0) return "`on:` is written in flow or scalar form (`on: push`, `on: [push]`, `on: {push: {}}`): write one trigger per line, as a block";
            }
            if (!in_on and (std.mem.startsWith(u8, line, "on ") or std.mem.startsWith(u8, line, "on\t") or std.mem.startsWith(u8, line, "\"on\" ") or std.mem.startsWith(u8, line, "'on' "))) {
                return "`on` has blanks before its colon: write the key as `on:`, which is the spelling the trigger checks read";
            }
            continue;
        }
        if (!in_on) continue;
        if (base == null) {
            base = indent;
            if (indent != 2) return "the triggers under `on:` are not indented two spaces, which is the spelling the trigger checks read";
        }
        if (indent == base.?) {
            if (body[0] == '"' or body[0] == '\'') return "a trigger under `on:` is quoted: write the key bare, which is the spelling the trigger checks read";
            const colon = std.mem.indexOfScalar(u8, body, ':') orelse return "a line under `on:` is not a `trigger:` key (a list or flow form is refused): write one trigger per line, as a block";
            if (colon > 0 and (body[colon - 1] == ' ' or body[colon - 1] == '\t')) return "a trigger under `on:` has blanks before its colon: write `trigger:`, which is the spelling the trigger checks read";
            if (stripComment(body[colon + 1 ..]).len != 0) return "a trigger under `on:` has its value on the same line (`push: {branches: [main]}`, `push: null`): write the trigger alone and its settings as a block below it";
        } else if (indent > base.? and (body[0] == '{' or body[0] == '[')) {
            return "a trigger under `on:` is given a flow-style value: write its settings as a block";
        }
    }
    return null;
}

/// Whether a line of the workflow (not a comment) is the target `tg`, as a line of the build command: `//pkg:name \\` or `//pkg:name`.
fn hasTargetLine(text: []const u8, tg: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \r");
        if (std.mem.endsWith(u8, line, "\\")) line = std.mem.trimRight(u8, line[0 .. line.len - 1], " ");
        if (std.mem.eql(u8, line, tg)) return true;
    }
    return false;
}

/// The commands of the workflow's shell, one per logical line: a trailing `\` joins the next line, and a word that starts with `#` begins a
/// comment that runs to the end of its physical line (so the rest of that line is not part of any command).
pub fn commands(a: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var cur = std.ArrayList(u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \r");
        var comment = false;
        for (line, 0..) |c, i| {
            if (c == '#' and (i == 0 or line[i - 1] == ' ')) {
                line = std.mem.trimRight(u8, line[0..i], " ");
                comment = true;
                break;
            }
        }
        if (!comment and std.mem.endsWith(u8, line, "\\")) {
            try cur.appendSlice(std.mem.trimRight(u8, line[0 .. line.len - 1], " "));
            try cur.append(' ');
            continue;
        }
        try cur.appendSlice(line);
        if (cur.items.len > 0) try out.append(try cur.toOwnedSlice());
    }
    if (cur.items.len > 0) try out.append(try cur.toOwnedSlice());
    return out.toOwnedSlice();
}

const mode_key = "buildrules_re.mode";

/// Whether the `./buck2` invocation `inv` has `-c buildrules_re.mode=local` as whole arguments.
fn inLocalMode(inv: []const u8) bool {
    return hasArgs(inv, "-c buildrules_re.mode=local");
}

const buck2 = "./buck2 ";

/// `./buck2` subcommands that load no graph, so no execution platform is analysed and no mode is needed. Everything else is held to
/// local mode (an allow-list of the exempt, so a subcommand this parser has not heard of, or a global flag before it, is not exempt).
const no_graph = [_][]const u8{ "kill", "--version" };

/// The text of `cmd` up to the first shell separator (`&&`, `||`, `;`, `|`, `&`, a parenthesis or a backtick): one command.
fn untilSeparator(cmd: []const u8) []const u8 {
    for (cmd, 0..) |c, i| {
        if (isSep(c)) return cmd[0..i];
    }
    return cmd;
}

fn isSep(c: u8) bool {
    return c == ';' or c == '&' or c == '|' or c == '(' or c == ')' or c == '`';
}

/// Whether the `./buck2` invocation `inv` (the text after `./buck2 `, up to the next invocation) loads the graph. It does not only when the
/// command is exactly `kill` or `--version`, each alone (redirections aside): `./buck2 kill build //x` is a build.
fn loadsGraph(inv: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, untilSeparator(inv), " \t");
    const first = words.next() orelse return true;
    var exempt = false;
    for (no_graph) |n| {
        if (std.mem.eql(u8, first, n)) exempt = true;
    }
    if (!exempt) return true;
    while (words.next()) |w| {
        if (std.mem.indexOfScalar(u8, w, '>') == null) return true;
    }
    return false;
}

const shells = [_][]const u8{ "bash", "sh", "zsh", "dash", "eval" };
const wrappers = [_][]const u8{ "sudo", "exec", "env", "command", "nohup", "time", "xargs", "then", "do", "else", "if", "while", "until", "!", "run:", "-", "export", "declare", "local", "readonly" };

fn inList(list: []const []const u8, w: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, w)) return true;
    }
    return false;
}

fn namesBuck2(w: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(w, "buck2") != null;
}

/// Every buck2 that is run as anything but the literal `./buck2`, in the commands of `line`: the command word (after env assignments and
/// wrappers such as `sudo`, `env`, `exec`, `xargs`; and, inside `bash -c '...'`/`sh -c`/`eval`, the commands of the quoted text) that
/// names buck2 and is not `./buck2` (`buck2`, `/path/buck2`, `$BUCK2`, `"${BUCK2}"`), and an assignment whose value names buck2 (a
/// variable that is then run as a command). A `buck2` that is an argument (`chmod +x buck2`, `-o buck2`) is not a command.
fn nonLiteralBuck2(a: std.mem.Allocator, f: *Findings, line: []const u8) error{OutOfMemory}!void {
    // A YAML key (`key: ...`, `name: ...`, `uses: ...`, `if: ...`) is not a shell command; `run:` is the one whose value is.
    const lead = std.mem.trimLeft(u8, std.mem.trim(u8, line, " \t"), "- ");
    const key = lead[0 .. std.mem.indexOfAny(u8, lead, " \t") orelse lead.len];
    if (std.mem.endsWith(u8, key, ":") and !std.mem.eql(u8, key, "run:")) return;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= line.len) : (i += 1) {
        if (i < line.len and !isSep(line[i])) continue;
        try oneCommand(a, f, line[start..i], line);
        start = i + 1;
    }
}

fn oneCommand(a: std.mem.Allocator, f: *Findings, seg: []const u8, line: []const u8) error{OutOfMemory}!void {
    var rest = std.mem.trim(u8, seg, " \t");
    var after_wrapper = false;
    while (rest.len > 0) {
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const word = std.mem.trim(u8, rest[0..end], "'\"");
        const next = std.mem.trimLeft(u8, rest[end..], " \t");
        if (word.len == 0) {
            rest = next;
            continue;
        }
        if (after_wrapper and word[0] == '-') {
            rest = next;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, word, '=');
        if (eq != null and word[0] != '-' and word[0] != '$' and std.mem.indexOfScalar(u8, word[0..eq.?], '/') == null) {
            if (namesBuck2(word[eq.? + 1 ..])) try add(a, f, "a variable is set to buck2, which is then run through the variable (run `./buck2` itself): {s}", .{line});
            rest = next;
            continue;
        }
        if (inList(&wrappers, word)) {
            after_wrapper = true;
            rest = next;
            continue;
        }
        if (inList(&shells, word)) {
            // `bash -c '...'`: the quoted text is a command line of its own.
            var r = next;
            while (r.len > 0 and r[0] == '-') r = std.mem.trimLeft(u8, r[std.mem.indexOfAny(u8, r, " \t") orelse r.len ..], " \t");
            const unq = try a.dupe(u8, r);
            for (unq) |*c| {
                if (c.* == '\'' or c.* == '"') c.* = ' ';
            }
            try nonLiteralBuck2(a, f, unq);
            return;
        }
        if (namesBuck2(word) and !std.mem.eql(u8, word, "./buck2"))
            try add(a, f, "buck2 is run as `{s}`, not the literal `./buck2` (its mode cannot be checked): {s}", .{ word, line });
        return;
    }
}

/// Whether `args` occurs in `cmd` as whole space-separated words.
fn hasArgs(cmd: []const u8, args: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, cmd, from, args)) |i| : (from = i + 1) {
        const before_ok = i == 0 or cmd[i - 1] == ' ';
        const e = i + args.len;
        if (before_ok and (e == cmd.len or cmd[e] == ' ')) return true;
    }
    return false;
}

/// Every `uses:` line of `workflow` is `owner/repo@<40 hex>`; returns how many there are. `local_ok` lists the values that
/// may stand without a pin (a local reusable workflow, `./.github/workflows/ci.yml`; a local action checked out from a pinned commit).
pub fn pinnedUses(a: std.mem.Allocator, f: *Findings, workflow: []const u8, local_ok: []const []const u8) !usize {
    var uses: usize = 0;
    var it = std.mem.splitScalar(u8, workflow, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " -");
        if (std.mem.startsWith(u8, line, "#")) continue;
        if (!std.mem.startsWith(u8, line, "uses:")) continue;
        uses += 1;
        var v = std.mem.trim(u8, line["uses:".len..], " ");
        if (std.mem.indexOfScalar(u8, v, '#')) |h| v = std.mem.trim(u8, v[0..h], " ");
        var local = false;
        for (local_ok) |ok| {
            if (std.mem.eql(u8, v, ok)) local = true;
        }
        if (local) continue;
        const at = std.mem.indexOfScalar(u8, v, '@');
        if (at == null or !isHex40(v[at.? + 1 ..])) try add(a, f, "`uses: {s}` is not pinned to a full commit sha", .{v});
    }
    return uses;
}

/// The local-mode rules for every `./buck2` command of `workflow`: the flag on each command that loads the graph (not on an echo, a comment
/// or another command), no other value of the key anywhere (comments included), no buck2 run any way but the literal `./buck2`, and no
/// remote-execution endpoint. Returns the number of `./buck2 build` commands.
pub fn localMode(a: std.mem.Allocator, f: *Findings, workflow: []const u8) !usize {
    var builds: usize = 0;
    var mode_uses: usize = 0;
    var mode_on_graph: usize = 0;
    for (try commands(a, workflow)) |cmd| {
        mode_uses += std.mem.count(u8, cmd, mode_key);
        try nonLiteralBuck2(a, f, cmd);
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, cmd, from, buck2)) |i| {
            const start = i + buck2.len;
            const end = std.mem.indexOfPos(u8, cmd, start, buck2) orelse cmd.len;
            const inv = untilSeparator(cmd[start..end]);
            from = start;
            if (!loadsGraph(inv)) continue;
            if (std.mem.startsWith(u8, inv, "build ")) builds += 1;
            mode_on_graph += std.mem.count(u8, inv, mode_key);
            if (!inLocalMode(inv)) try add(a, f, "a `./buck2` command that loads the graph does not pass `-c buildrules_re.mode=local`: {s}", .{cmd});
        }
    }
    if (mode_uses != mode_on_graph) try add(a, f, "`{s}` appears outside a `./buck2` command that loads the graph", .{mode_key});
    var mit = std.mem.splitScalar(u8, workflow, '\n');
    while (mit.next()) |line| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, line, from, mode_key)) |i| : (from = i + mode_key.len) {
            const rest = line[i + mode_key.len ..];
            const ok = std.mem.startsWith(u8, rest, "=local") and (rest.len == "=local".len or rest["=local".len] == ' ' or rest["=local".len] == '`' or rest["=local".len] == ',' or rest["=local".len] == ')' or rest["=local".len] == '.');
            if (!ok) try add(a, f, "`{s}` is set to something other than `local`: {s}", .{ mode_key, std.mem.trim(u8, line, " ") });
        }
    }
    for ([_][]const u8{ "engine_address", "cas_address", "action_cache_address", "linux_x86_64_properties", "--no-remote-cache" }) |bad| {
        if (std.mem.indexOf(u8, workflow, bad) != null) try add(a, f, "the workflow mentions `{s}`", .{bad});
    }
    return builds;
}

/// The buck2 the workflow downloads is the release pinned in tools/buck2 (url and sha256).
pub fn buck2Install(a: std.mem.Allocator, f: *Findings, workflow: []const u8, dotslash: []const u8) !void {
    if (dotslashLinux(dotslash)) |p| {
        if (std.mem.indexOf(u8, workflow, p.url) == null) try add(a, f, "the workflow does not download the url pinned in tools/buck2", .{});
        const line = try std.fmt.allocPrint(a, "{s}  buck2.zst", .{p.digest});
        if (std.mem.indexOf(u8, workflow, line) == null) try add(a, f, "the workflow does not check the sha256 pinned in tools/buck2", .{});
    } else try add(a, f, "tools/buck2 has no linux-x86_64 digest and url (this parser is blind)", .{});
}

/// The aarch64 leg's install: tools/buck2 pins a linux-aarch64 release, and the workflow downloads that url and checks that sha256 (the same
/// `buck2.zst` line as the x86 install, with the aarch64 digest).
pub fn buck2InstallArm(a: std.mem.Allocator, f: *Findings, workflow: []const u8, dotslash: []const u8) !void {
    const p = dotslashPlatform(dotslash, "linux-aarch64") orelse {
        try add(a, f, "tools/buck2 has no linux-aarch64 digest and url (the host_arm job installs it)", .{});
        return;
    };
    if (std.mem.indexOf(u8, workflow, p.url) == null) try add(a, f, "the workflow does not download the linux-aarch64 url pinned in tools/buck2", .{});
    const line = try std.fmt.allocPrint(a, "{s}  buck2.zst", .{p.digest});
    if (std.mem.indexOf(u8, workflow, line) == null) try add(a, f, "the workflow does not check the linux-aarch64 sha256 pinned in tools/buck2", .{});
    if (std.mem.indexOf(u8, workflow, "runs-on: ubuntu-24.04-arm") == null) try add(a, f, "`runs-on: ubuntu-24.04-arm` is missing (the host_arm job)", .{});
}

/// The lines of job `name` (`host_arm`): from its `  name:` line to the next job key (two spaces, then a name).
fn jobBlock(workflow: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const key = std.fmt.bufPrint(buf, "\n  {s}:\n", .{name}) catch return null;
    const at = std.mem.indexOf(u8, workflow, key) orelse return null;
    const body = workflow[at + 1 ..];
    var end = body.len;
    var pos: usize = key.len - 1;
    while (std.mem.indexOfPos(u8, body, pos, "\n  ")) |i| {
        const c = if (i + 3 < body.len) body[i + 3] else ' ';
        if (c != ' ' and c != '#' and c != '\n') {
            end = i;
            break;
        }
        pos = i + 1;
    }
    return body[0..end];
}

/// Whether one of `cmds` is exactly `want` (the line of a `run: |` block) or `run: ` and `want` (a one-line step).
fn hasCommand(cmds: []const []const u8, want: []const u8) bool {
    for (cmds) |c| {
        if (std.mem.eql(u8, c, want)) return true;
        if (std.mem.startsWith(u8, c, "run: ") and std.mem.eql(u8, std.mem.trim(u8, c["run: ".len..], " "), want)) return true;
    }
    return false;
}

const arm_platform = "buildrules//platforms:linux_aarch64";
const arm_target = "//rules/pins:host_downloads";
const arm_grep = "grep --fixed-strings --quiet \"Execution platform: " ++ arm_platform ++ "\"";

/// What the `host_arm` job must do besides installing buck2, each as a command of that job (a comment that names it does not count):
/// assert the machine is aarch64, assert the execution platform local mode resolves to is `platforms:linux_aarch64`, and build the pinned
/// downloads of the aarch64 hosts for that target platform in local mode. A job without these still goes green on an x86 machine or with a
/// platform that was not chosen, and checks nothing.
pub fn hostArm(a: std.mem.Allocator, f: *Findings, workflow: []const u8) !void {
    var buf: [64]u8 = undefined;
    const job = jobBlock(workflow, "host_arm", &buf) orelse {
        try add(a, f, "the `host_arm` job is missing (ubuntu-24.04-arm: the machine, its execution platform and the pinned downloads of the aarch64 hosts)", .{});
        return;
    };
    const cmds = try commands(a, job);
    if (!hasCommand(cmds, "test \"$(uname -m)\" = aarch64")) try add(a, f, "the host_arm job does not assert `uname -m` is aarch64 (`test \"$(uname -m)\" = aarch64`)", .{});
    var resolved = false;
    var built = false;
    for (cmds) |c| {
        const body = if (std.mem.startsWith(u8, c, "run: ")) c["run: ".len..] else c;
        if (std.mem.startsWith(u8, body, "./buck2 audit execution-platform-resolution ")) {
            const bar = std.mem.indexOfScalar(u8, body, '|') orelse continue;
            const left = std.mem.trim(u8, body[0..bar], " ");
            const right = std.mem.trim(u8, body[bar + 1 ..], " ");
            if (hasArgs(left, arm_target) and inLocalMode(left) and std.mem.eql(u8, right, arm_grep)) resolved = true;
        }
        if (std.mem.startsWith(u8, body, "./buck2 build ")) {
            if (hasArgs(body, arm_target) and inLocalMode(body) and hasArgs(body, "--target-platforms " ++ arm_platform)) built = true;
        }
    }
    if (!resolved) try add(a, f, "the host_arm job does not assert the execution platform: `./buck2 audit execution-platform-resolution -c buildrules_re.mode=local {s} | {s}`", .{ arm_target, arm_grep });
    if (!built) try add(a, f, "the host_arm job does not build {s} with `--target-platforms {s}` in local mode", .{ arm_target, arm_platform });
}

/// `continue-on-error` lets a red job or step pass: a workflow that gates a release has none, at job or step level, unless it is `false`. Any other
/// value (`true`, an expression, a quoted string) is a finding, wherever the key is (a flow mapping included).
pub fn noContinueOnError(a: std.mem.Allocator, f: *Findings, workflow: []const u8) !void {
    var it = std.mem.splitScalar(u8, workflow, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len > 0 and line[0] == '#') continue;
        const key = "continue-on-error:";
        const i = std.mem.indexOf(u8, line, key) orelse continue;
        var v = std.mem.trim(u8, line[i + key.len ..], " ");
        if (std.mem.indexOf(u8, v, " #")) |h| v = std.mem.trim(u8, v[0..h], " ");
        if (!std.mem.eql(u8, v, "false"))
            try add(a, f, "`continue-on-error` is set to `{s}`: a red job or step would pass (only `false` is allowed)", .{v});
    }
}

/// A `${{ }}` expression that reads `vars.` or `github.event.` inside the text of a `run:` (the one line, or the block scalar under it) is expanded into the
/// script before the shell parses it, so a value with a quote or a `;` becomes code. The value goes through `env:` and the script reads `"$NAME"`.
pub fn noInlineContext(a: std.mem.Allocator, f: *Findings, workflow: []const u8) !void {
    var it = std.mem.splitScalar(u8, workflow, '\n');
    var block_indent: ?usize = null;
    while (it.next()) |raw| {
        const trimmed = std.mem.trimLeft(u8, raw, " ");
        const indent = raw.len - trimmed.len;
        if (block_indent) |bi| {
            if (trimmed.len == 0 or indent > bi) {
                try inlineExprs(a, f, trimmed);
                continue;
            }
            block_indent = null;
        }
        if (trimmed.len > 0 and trimmed[0] == '#') continue;
        var rest = trimmed;
        if (std.mem.startsWith(u8, rest, "- ")) rest = std.mem.trimLeft(u8, rest[2..], " ");
        if (!std.mem.startsWith(u8, rest, "run:")) continue;
        const v = std.mem.trim(u8, rest["run:".len..], " \r");
        if (v.len > 0 and (v[0] == '|' or v[0] == '>')) {
            block_indent = indent;
        } else try inlineExprs(a, f, v);
    }
}

fn inlineExprs(a: std.mem.Allocator, f: *Findings, text: []const u8) !void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, text, pos, "${{")) |s| {
        const e = std.mem.indexOfPos(u8, text, s, "}}") orelse text.len;
        const expr = text[s..e];
        for ([_][]const u8{ "vars.", "github.event." }) |ctx| {
            if (std.mem.indexOf(u8, expr, ctx) != null)
                try add(a, f, "a `run:` line expands `{s}` inline ({s}): pass it through `env:` and read it as \"$NAME\"", .{ ctx, text });
        }
        pos = e;
    }
}

/// `text` without its comment-only lines.
fn withoutComments(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " "), "#")) continue;
        try out.appendSlice(line);
        try out.append('\n');
    }
    return out.toOwnedSlice();
}

/// Everything wrong with `workflow`, given the dotslash file of the pinned buck2 and ci/BUCK.
pub fn check(a: std.mem.Allocator, workflow: []const u8, dotslash: []const u8, ci_buck: []const u8) !Findings {
    var f = Findings.init(a);

    try noContinueOnError(a, &f, workflow);
    try noInlineContext(a, &f, workflow);

    // Every `uses:` is pinned to a full commit.
    const uses = try pinnedUses(a, &f, workflow, &.{});
    if (uses == 0) try add(a, &f, "no `uses:` line found (the checkout step is missing, or this parser is blind)", .{});

    // Permissions: contents: read at the top level, nothing broader anywhere.
    if (!hasLine(workflow, "permissions:") or !hasLine(workflow, "  contents: read")) try add(a, &f, "top-level `permissions:` with `contents: read` is missing", .{});
    if (std.mem.indexOf(u8, workflow, ": write") != null) try add(a, &f, "a `: write` permission is granted", .{});
    if (std.mem.indexOf(u8, workflow, "write-all") != null) try add(a, &f, "`write-all` is granted", .{});
    if (std.mem.indexOf(u8, workflow, "pull_request_target") != null) try add(a, &f, "`pull_request_target` runs fork code with the base repository's token", .{});
    if (std.mem.indexOf(u8, workflow, "secrets.") != null) try add(a, &f, "the workflow reads a secret", .{});
    // This workflow runs for every pull request and as the gate of release.yml: no job of it declares an environment. The only environment of the
    // repository, `release`, holds the release bot's key and belongs to the jobs of release.yml that read it (ci/release_check.zig).
    var lines = std.mem.splitScalar(u8, workflow, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trimLeft(u8, line, " ");
        if (std.mem.startsWith(u8, l, "environment:")) try add(a, &f, "a job declares an `environment:` (only the jobs of release.yml that read the release bot's key do)", .{});
    }

    // Triggers and runner.
    if (triggerStyleProblem(workflow)) |why| try add(a, &f, "{s}", .{why});
    if (!hasLine(workflow, "  pull_request:")) try add(a, &f, "`on: pull_request` is missing", .{});
    // A push to main is tested by release.yml (its gate stage calls this workflow), not twice.
    if (!hasLine(workflow, "  workflow_call:")) try add(a, &f, "`on: workflow_call` is missing (release.yml calls this workflow as its gate stage)", .{});
    if (hasLine(workflow, "  push:")) try add(a, &f, "`on: push` is present: a push to main is tested through release.yml, and would run this workflow twice", .{});
    if (std.mem.indexOf(u8, workflow, "runs-on: ubuntu-latest") == null) try add(a, &f, "`runs-on: ubuntu-latest` is missing", .{});

    // The tiers (RELEASING.md): a pull request runs build and unit tests (with coverage, where there is coverage) and nothing else. The beta, the gamma, the
    // signing, the attestation and the verification are the release's, after the merge (release.yml). So this workflow, which is the pull-request check, is
    // triggered by a pull request and by the release's call alone, never calls the beta, never builds or runs the stage tool or the release tool, and holds
    // no signing identity.
    for ([_][]const u8{ "  workflow_dispatch:", "  schedule:", "  workflow_run:" }) |trigger| {
        if (hasLine(workflow, trigger)) try add(a, &f, "`{s}` triggers the pull-request checks: only a pull request and the release's call do", .{std.mem.trim(u8, trigger, " :")});
    }
    const live = try withoutComments(a, workflow);
    for ([_][]const u8{ "./.github/workflows/beta.yml", "tools/stage", "tool/stage", "tools/release", "tool/release", "id-token", "cosign", "sigstore", "attest-build-provenance" }) |later| {
        if (std.mem.indexOf(u8, live, later) != null) try add(a, &f, "the pull-request checks name `{s}`: a pull request runs build and unit tests only; the beta, the gamma and the signing belong to the release (release.yml)", .{later});
    }

    // The cancel group. release.yml calls this workflow for every push to main: a group shared by all of them, with cancelling on, lets a
    // re-run of an old main run cancel the gate of the newest commit. So the group of a non-pull-request event holds the commit, and only
    // a pull request cancels.
    if (std.mem.indexOf(u8, workflow, "github.event.pull_request.number || github.sha }}") == null)
        try add(a, &f, "the concurrency group is not per-commit for events other than a pull request (it must end `github.event.pull_request.number || github.sha`)", .{});
    if (!hasLine(workflow, "  cancel-in-progress: ${{ github.event_name == 'pull_request' }}"))
        try add(a, &f, "`cancel-in-progress` is not `${{{{ github.event_name == 'pull_request' }}}}`: only a pull request may cancel a run", .{});

    // Local mode, never a remote-execution endpoint, every promised target.
    const builds = try localMode(a, &f, workflow);
    if (builds == 0) try add(a, &f, "no `./buck2 build` command found (the build does not pass `-c buildrules_re.mode=local`; or this parser is blind)", .{});
    for (targets) |tg| {
        if (!hasTargetLine(workflow, tg)) try add(a, &f, "target {s} is not built", .{tg});
    }
    var ran_completeness = false;
    for (try commands(a, workflow)) |cmd| {
        if (std.mem.indexOf(u8, cmd, completeness) != null) ran_completeness = true;
    }
    if (!ran_completeness) try add(a, &f, "the workflow does not run `{s}`", .{completeness});
    // `//ci:` targets exist in ci/BUCK.
    for (targets) |tg| {
        if (!std.mem.startsWith(u8, tg, "//ci:")) continue;
        const want = try std.fmt.allocPrint(a, "name = \"{s}\"", .{tg["//ci:".len..]});
        if (std.mem.indexOf(u8, ci_buck, want) == null) try add(a, &f, "{s} is not declared in ci/BUCK", .{tg});
    }
    if (hasTargetLine(workflow, "//ci:mojo")) try add(a, &f, "//ci:mojo is built, and it needs a mirror a public runner does not have", .{});
    if (std.mem.indexOf(u8, workflow, "# //ci:mojo is not built") == null) try add(a, &f, "the comment that says why //ci:mojo is not built is missing", .{});

    // The buck2 install is the release pinned in tools/buck2.
    try buck2Install(a, &f, workflow, dotslash);
    try buck2InstallArm(a, &f, workflow, dotslash);
    try hostArm(a, &f, workflow);

    // The cache is keyed on lock files.
    const key = std.mem.indexOf(u8, workflow, "key: buck-out-");
    if (key == null or std.mem.indexOf(u8, workflow, "hashFiles(") == null or std.mem.indexOf(u8, workflow, "package-lock.json") == null or std.mem.indexOf(u8, workflow, "Cargo.lock") == null)
        try add(a, &f, "the cache key is not derived from the lock files", .{});
    return f;
}

// ---- tests ------------------------------------------------------------------------------------------------------------------------------

fn work(a: std.mem.Allocator, sub: []const u8) ![]u8 {
    const w = try std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK");
    const p = try std.fs.path.join(a, &.{ w, sub });
    return std.fs.cwd().readFileAlloc(a, p, 1 << 20);
}

const Real = struct { wf: []const u8, ds: []const u8, cb: []const u8 };

fn real(a: std.mem.Allocator) !Real {
    return .{ .wf = try work(a, ".github/workflows/ci.yml"), .ds = try work(a, "tools/buck2"), .cb = try work(a, "ci/BUCK") };
}

/// `wf` with the first `from` replaced by `to`; fails the test if `from` is absent (a mutant that changes nothing proves nothing).
fn mutate(a: std.mem.Allocator, wf: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const i = std.mem.indexOf(u8, wf, from) orelse return error.MutantDidNotApply;
    return std.mem.concat(a, u8, &.{ wf[0..i], to, wf[i + from.len ..] });
}

/// As `mutate`, at the last occurrence (the code, where a comment above also names the text).
fn mutateLast(a: std.mem.Allocator, wf: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const i = std.mem.lastIndexOf(u8, wf, from) orelse return error.MutantDidNotApply;
    return std.mem.concat(a, u8, &.{ wf[0..i], to, wf[i + from.len ..] });
}

fn expectFinding(a: std.mem.Allocator, r: Real, wf: []const u8, needle: []const u8) !void {
    const f = try check(a, wf, r.ds, r.cb);
    for (f.items) |m| {
        if (std.mem.indexOf(u8, m, needle) != null) return;
    }
    std.debug.print("expected a finding with `{s}`, got {d}:\n", .{ needle, f.items.len });
    for (f.items) |m| std.debug.print("  {s}\n", .{m});
    return error.MutantSurvived;
}


// ---- synthetic fixtures -------------------------------------------------------------------------------------------------------------------
//
// The planted-defect tests below run on this text and not on the real ci.yml: every mutant anchors on text this file itself holds, so it cannot fail
// with `MutantDidNotApply` because the real workflow was reworded, and each red run is the rule under test (the test of the unmutated fixture
// first requires that it has no finding at all). The real workflow is checked by "the real workflow has no findings" alone.

const fixture_wf =
    \\name: ci
    \\
    \\on:
    \\  pull_request:
    \\  workflow_call:
    \\
    \\permissions:
    \\  contents: read
    \\
    \\concurrency:
    \\  group: ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.sha }}
    \\  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
    \\
    \\jobs:
    \\  build:
    \\    runs-on: ubuntu-latest
    \\    steps:
    \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
    \\        with:
    \\          persist-credentials: false
    \\      - name: Install buck2
    \\        run: |
    \\          curl --output buck2.zst https://example.invalid/2026-09-15/buck2-x86_64-unknown-linux-gnu.zst
    \\          echo "1268fce33fb600000000000000000000000000000000000000000000000000ff  buck2.zst" | sha256sum --check --strict -
    \\          ./buck2 --version
    \\      - name: Restore the buck2 output cache
    \\        uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
    \\        with:
    \\          path: buck-out
    \\          key: buck-out-${{ runner.os }}-${{ hashFiles('tools/buck2', '**/package-lock.json', '**/Cargo.lock') }}
    \\      - name: Every target of the tree is covered
    \\        run: ./buck2 bxl -c buildrules_re.mode=local //ci:completeness.bxl:check
    \\      # //ci:mojo is not built: its packages need a mirror.
    \\      - name: Build and test
    \\        run: |
    \\          ./buck2 build --console simple -c buildrules_re.mode=local \
    \\            //ci:all
    \\      - name: Stop buck2
    \\        if: always()
    \\        run: ./buck2 kill
    \\  host_arm:
    \\    runs-on: ubuntu-24.04-arm
    \\    steps:
    \\      - name: Install buck2
    \\        run: |
    \\          curl --output buck2.zst https://example.invalid/2026-09-15/buck2-aarch64-unknown-linux-gnu.zst
    \\          echo "e35027a8e3f700000000000000000000000000000000000000000000000000ff  buck2.zst" | sha256sum --check --strict -
    \\      - name: The machine is aarch64
    \\        run: test "$(uname -m)" = aarch64
    \\      - name: The execution platform of this machine is platforms:linux_aarch64
    \\        run: |
    \\          ./buck2 audit execution-platform-resolution -c buildrules_re.mode=local //rules/pins:host_downloads \
    \\            | grep --fixed-strings --quiet "Execution platform: buildrules//platforms:linux_aarch64"
    \\      - name: Download and verify the pins of the aarch64 hosts
    \\        run: |
    \\          ./buck2 build --console simple -c buildrules_re.mode=local \
    \\            --target-platforms buildrules//platforms:linux_aarch64 \
    \\            //rules/pins:host_downloads
    \\
;

const fixture_ds =
    \\{
    \\  "platform": {
    \\    "linux-x86_64": {
    \\      "digest": "1268fce33fb600000000000000000000000000000000000000000000000000ff",
    \\      "providers": [{"url": "https://example.invalid/2026-09-15/buck2-x86_64-unknown-linux-gnu.zst"}]
    \\    },
    \\    "linux-aarch64": {
    \\      "digest": "e35027a8e3f700000000000000000000000000000000000000000000000000ff",
    \\      "providers": [{"url": "https://example.invalid/2026-09-15/buck2-aarch64-unknown-linux-gnu.zst"}]
    \\    },
    \\    "macos-aarch64": {}
    \\  }
    \\}
    \\
;

const fixture_cb = "group(name = \"all\", deps = [])\n";

/// The synthetic fixture; the real files are `real`.
fn fx(a: std.mem.Allocator) !Real {
    _ = a;
    return .{ .wf = fixture_wf, .ds = fixture_ds, .cb = fixture_cb };
}

test "the synthetic fixture has no finding, so every mutant below is red for its own rule" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const f = try check(a, r.wf, r.ds, r.cb);
    for (f.items) |m| std.debug.print("finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "the cancel group of a called workflow is per commit, and only a pull request cancels" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    // the shape that let a re-run of an old main run cancel the newest commit's gate: one group for every push, and cancelling
    try expectFinding(a, r, try mutate(a, r.wf, "github.event.pull_request.number || github.sha", "github.event.pull_request.number || github.ref"), "per-commit");
    try expectFinding(a, r, try mutate(a, r.wf, "cancel-in-progress: ${{ github.event_name == 'pull_request' }}", "cancel-in-progress: true"), "only a pull request");
    try expectFinding(a, r, try mutate(a, r.wf, "concurrency:\n  group: ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.sha }}\n  cancel-in-progress: ${{ github.event_name == 'pull_request' }}\n\n", ""), "per-commit");
}

test "the real workflow has no findings" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try real(a);
    const f = try check(a, r.wf, r.ds, r.cb);
    for (f.items) |m| std.debug.print("finding: {s}\n", .{m});
    try t.expectEqual(@as(usize, 0), f.items.len);
}

test "an action pinned by tag, by branch or by a short sha is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const sha = "3d3c42e5aac5ba805825da76410c181273ba90b1";
    try expectFinding(a, r, try mutate(a, r.wf, "actions/checkout@" ++ sha, "actions/checkout@v7"), "not pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "actions/checkout@" ++ sha, "actions/checkout@main"), "not pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "actions/checkout@" ++ sha, "actions/checkout@3d3c42e"), "not pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "actions/checkout@" ++ sha, "actions/checkout"), "not pinned");
    // a 40-character value that is not hex
    try expectFinding(a, r, try mutate(a, r.wf, "actions/checkout@" ++ sha, "actions/checkout@" ++ "z" ** 40), "not pinned");
}

test "a workflow with no uses lines is found, not passed" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, "name: x\n", "no `uses:`");
}

test "a broader token, a fork-code trigger or a secret is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, try mutate(a, r.wf, "  contents: read", "  contents: write"), "permissions");
    try expectFinding(a, r, try mutate(a, r.wf, "  contents: read", "  contents: read\n  packages: write"), "write");
    try expectFinding(a, r, try mutate(a, r.wf, "permissions:\n  contents: read\n", ""), "permissions");
    try expectFinding(a, r, try mutate(a, r.wf, "  pull_request:", "  pull_request_target:"), "pull_request_target");
    try expectFinding(a, r, try mutate(a, r.wf, "persist-credentials: false", "token: ${{ secrets.X }}"), "secret");
    // mutants: this workflow declares an environment, the release one or another
    try expectFinding(a, r, try mutate(a, r.wf, "runs-on: ubuntu-latest", "runs-on: ubuntu-latest\n    environment: release"), "declares an `environment:`");
    try expectFinding(a, r, try mutate(a, r.wf, "runs-on: ubuntu-latest", "runs-on: ubuntu-latest\n    environment: prod"), "declares an `environment:`");
}

test "a missing trigger or runner is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, try mutate(a, r.wf, "  pull_request:\n", ""), "pull_request");
    try expectFinding(a, r, try mutate(a, r.wf, "  workflow_call:\n", ""), "workflow_call");
    try expectFinding(a, r, try mutate(a, r.wf, "  workflow_call:\n", "  push:\n    branches: [main]\n"), "`on: push` is present");
    try expectFinding(a, r, try mutate(a, r.wf, "runs-on: ubuntu-latest", "runs-on: self-hosted"), "ubuntu-latest");
}

test "a trigger spelled in flow or scalar style is refused, whichever trigger it names" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const on_block = "on:\n  pull_request:\n  workflow_call:\n";
    // the whole `on:` in one line
    try expectFinding(a, r, try mutate(a, r.wf, on_block, "on: push\n"), "flow or scalar");
    try expectFinding(a, r, try mutate(a, r.wf, on_block, "on: [push, pull_request, workflow_call]\n"), "flow or scalar");
    try expectFinding(a, r, try mutate(a, r.wf, on_block, "on: {pull_request: {}, workflow_call: {}, push: {branches: [main]}}\n"), "flow or scalar");
    try expectFinding(a, r, try mutate(a, r.wf, on_block, "\"on\": [push, pull_request]\n"), "flow or scalar");
    try expectFinding(a, r, try mutate(a, r.wf, on_block, "on: [pull_request, workflow_call] # not a block\n"), "flow or scalar");
    // one trigger with its value on its own line
    try expectFinding(a, r, try mutate(a, r.wf, "  workflow_call:\n", "  workflow_call:\n  push: {branches: [main]}\n"), "same line");
    try expectFinding(a, r, try mutate(a, r.wf, "  workflow_call:\n", "  workflow_call:\n  workflow_dispatch: {}\n"), "same line");
    try expectFinding(a, r, try mutate(a, r.wf, "  workflow_call:\n", "  workflow_call:\n  schedule: [{cron: '0 3 * * *'}]\n"), "same line");
    try expectFinding(a, r, try mutate(a, r.wf, "  pull_request:\n", "  pull_request: {branches: [main]}\n"), "same line");
    // a flow value on the line below its trigger, a list under `on:`, and a trigger indented four spaces
    try expectFinding(a, r, try mutate(a, r.wf, "  workflow_call:\n", "  workflow_call:\n  push:\n    {branches: [main]}\n"), "flow-style value");
    try expectFinding(a, r, try mutate(a, r.wf, on_block, "on:\n  - push\n  - pull_request\n"), "not a `trigger:` key");
    try expectFinding(a, r, try mutate(a, r.wf, on_block, "on:\n    pull_request:\n    workflow_call:\n    push:\n"), "indented two spaces");
    // a flow sequence on the line below its trigger
    try expectFinding(a, r, try mutate(a, r.wf, "  workflow_call:\n", "  workflow_call:\n  push:\n    [main]\n"), "flow-style value");
    // a `#` with no blank before it is part of the value, not a comment
    try expectFinding(a, r, try mutate(a, r.wf, "  workflow_call:\n", "  workflow_call:\n  push: main#branch\n"), "same line");
    try expectFinding(a, r, try mutate(a, r.wf, on_block, "on: push#not-a-comment\n"), "flow or scalar");
    // a quoted trigger key, and blanks before a colon
    try expectFinding(a, r, try mutate(a, r.wf, "  workflow_call:\n", "  workflow_call:\n  \"push\":\n"), "quoted");
    try expectFinding(a, r, try mutate(a, r.wf, "  workflow_call:\n", "  workflow_call:\n  push :\n"), "blanks before its colon");
    try expectFinding(a, r, try mutate(a, r.wf, on_block, "on :\n  pull_request:\n  workflow_call:\n  push:\n"), "blanks before its colon");
    // block style with settings below a trigger, and a comment after a key, stay accepted
    const ok = try mutate(a, r.wf, "  workflow_call:\n", "  workflow_call: # the release's gate\n    inputs:\n      x:\n        type: string\n");
    const f = try check(a, ok, r.ds, r.cb);
    for (f.items) |m| try t.expect(std.mem.indexOf(u8, m, "`on:`") == null and std.mem.indexOf(u8, m, "same line") == null);
    try t.expect(triggerStyleProblem(r.wf) == null);
}

test "a pull-request check that runs more than build and unit tests is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    // the other triggers
    try expectFinding(a, r, try mutate(a, r.wf, "  workflow_call:\n", "  workflow_call:\n  workflow_dispatch:\n"), "`workflow_dispatch` triggers");
    try expectFinding(a, r, try mutate(a, r.wf, "  workflow_call:\n", "  workflow_call:\n  schedule:\n    - cron: '0 3 * * *'\n"), "`schedule` triggers");
    try expectFinding(a, r, try mutate(a, r.wf, "  workflow_call:\n", "  workflow_call:\n  workflow_run:\n    workflows: [release]\n"), "`workflow_run` triggers");
    // a later tier among the pull-request checks
    try expectFinding(a, r, try mutate(a, r.wf, "    steps:\n", "    steps:\n      - uses: ./.github/workflows/beta.yml\n"), "name `./.github/workflows/beta.yml`");
    try expectFinding(a, r, try mutate(a, r.wf, "      - name: Stop buck2\n", "      - name: Beta\n        run: ./buck2 build -c buildrules_re.mode=local //tools/stage:stage\n      - name: Stop buck2\n"), "name `tools/stage`");
    try expectFinding(a, r, try mutate(a, r.wf, "      - name: Stop buck2\n", "      - name: Sign\n        run: tool/release sign --dist dist --dry false\n      - name: Stop buck2\n"), "name `tool/release`");
    try expectFinding(a, r, try mutate(a, r.wf, "    runs-on: ubuntu-latest\n", "    runs-on: ubuntu-latest\n    permissions:\n      id-token: write\n"), "name `id-token`");
    // a comment that names a later tier is not a job that runs it
    const noted = try mutate(a, r.wf, "    steps:\n", "    # the beta (tool/stage) runs in release.yml\n    steps:\n");
    const f = try check(a, noted, r.ds, r.cb);
    for (f.items) |m| try t.expect(std.mem.indexOf(u8, m, "pull-request checks name") == null);
}

test "a build in remote mode, an endpoint, or a dropped target is found (also when only a comment names it)" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, try mutateLast(a, r.wf, "-c buildrules_re.mode=local", "-c buildrules_re.mode=remote"), "mode=local");
    try expectFinding(a, r, try mutate(a, r.wf, "--console simple", "--console simple -c buck2_re_client.engine_address=x"), "engine_address");
    try expectFinding(a, r, try mutate(a, r.wf, "--console simple", "--console simple --no-remote-cache"), "--no-remote-cache");
    // each target, dropped on its own, is named: the line holding it is rewritten to another target's name
    for (targets) |tg| {
        const wf = try std.mem.replaceOwned(u8, a, r.wf, tg, "//elsewhere:x");
        try expectFinding(a, r, wf, tg);
    }
}

test "the mode flag must be on the build command, and no other mode may appear" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const flag = " -c buildrules_re.mode=local \\\n";
    // the flag moves from the build command to an echo line: the old substring check passed this
    const moved = try mutateLast(a, r.wf, "./buck2 build --console simple" ++ flag, "echo -c buildrules_re.mode=local\n          ./buck2 build --console simple \\\n");
    try expectFinding(a, r, moved, "does not pass `-c buildrules_re.mode=local`");
    try expectFinding(a, r, moved, "appears outside a `./buck2` command that loads the graph");
    // a later build in remote mode, after the local one: the old check passed this too
    const later = try std.mem.concat(a, u8, &.{ r.wf, "      - run: ./buck2 build -c buildrules_re.mode=remote //x:y\n" });
    try expectFinding(a, r, later, "something other than `local`");
    try expectFinding(a, r, later, "does not pass `-c buildrules_re.mode=local`");
    // the other value on its own line, in the same command, or in a comment
    try expectFinding(a, r, try mutateLast(a, r.wf, " -c buildrules_re.mode=local \\\n", " -c buildrules_re.mode=local -c buildrules_re.mode=remote \\\n"), "something other than `local`");
    try expectFinding(a, r, try std.mem.concat(a, u8, &.{ r.wf, "# -c buildrules_re.mode=remote\n" }), "something other than `local`");
    try expectFinding(a, r, try mutateLast(a, r.wf, "buildrules_re.mode=local \\\n", "buildrules_re.mode=localx \\\n"), "does not pass");
    // the flag dropped altogether; and a workflow with no build command
    try expectFinding(a, r, try mutateLast(a, r.wf, flag, " \\\n"), "does not pass");
    try expectFinding(a, r, "name: x\nuses: a/b@" ++ "0" ** 40 ++ "\n", "no `./buck2 build` command");
    // the flag in a comment above the build does not count
    try expectFinding(a, r, try mutateLast(a, r.wf, flag, " \\\n          # -c buildrules_re.mode=local\n"), "does not pass");
}

test "every buck2 command that loads the graph must run in local mode" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const need = "does not pass `-c buildrules_re.mode=local`";
    // the shape of the first public CI run: the completeness bxl without the flag (its platforms failed to analyse), the build with it
    const old = try mutate(a, r.wf, "./buck2 bxl -c buildrules_re.mode=local //ci:completeness", "./buck2 bxl //ci:completeness");
    try expectFinding(a, r, old, need);
    // every other graph-loading command is held to the same
    const cmds = [_][]const u8{ "audit providers //ci:all", "cquery //ci:all", "uquery //ci:all", "aquery //ci:all", "test //ci:all", "targets //...", "run //x:y" };
    for (cmds) |c| {
        const extra = try std.fmt.allocPrint(a, "      - run: ./buck2 {s}\n", .{c});
        try expectFinding(a, r, try std.mem.concat(a, u8, &.{ r.wf, extra }), need);
        // and with the flag it is green
        const ok = try std.fmt.allocPrint(a, "      - run: ./buck2 {s} -c buildrules_re.mode=local\n", .{c});
        const f = try check(a, try std.mem.concat(a, u8, &.{ r.wf, ok }), r.ds, r.cb);
        try t.expectEqual(@as(usize, 0), f.items.len);
    }
    // a global flag before the subcommand does not exempt it, nor does a second invocation on the same line
    try expectFinding(a, r, try std.mem.concat(a, u8, &.{ r.wf, "      - run: ./buck2 --console simple bxl //x:y\n" }), need);
    try expectFinding(a, r, try std.mem.concat(a, u8, &.{ r.wf, "      - run: ./buck2 build -c buildrules_re.mode=local //x:y && ./buck2 bxl //x:y\n" }), need);
    // the flag on one command does not cover the next
    try expectFinding(a, r, try std.mem.concat(a, u8, &.{ r.wf, "      - run: ./buck2 build -c buildrules_re.mode=local //x:y && ./buck2 audit providers //x:y\n" }), need);
    // the commands that load no graph need no mode (the real workflow has both)
    try t.expect(std.mem.indexOf(u8, r.wf, "./buck2 kill") != null and std.mem.indexOf(u8, r.wf, "./buck2 --version") != null);
    // another value is refused on any of them
    try expectFinding(a, r, try mutate(a, r.wf, "bxl -c buildrules_re.mode=local", "bxl -c buildrules_re.mode=remote"), "something other than `local`");
    try expectFinding(a, r, try mutate(a, r.wf, "bxl -c buildrules_re.mode=local", "bxl -c buildrules_re.mode=remote"), need);
}

test "the completeness check must run" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, try mutate(a, r.wf, "run: ./buck2 bxl -c buildrules_re.mode=local //ci:completeness.bxl:check", "run: echo ./buck2 bxl -c buildrules_re.mode=local //ci:completeness.bxl:chec"), "completeness");
}

test "a target named only in a comment is not built" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    // a comment names //ci:all; the build line is removed
    try t.expect(std.mem.indexOf(u8, r.wf, "//ci:all") != null);
    try expectFinding(a, r, try mutate(a, r.wf, "            //ci:all\n", "            #//ci:all\n"), "//ci:all is not built");
}

test "mojo may only appear with its reason" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, try mutate(a, r.wf, "            //ci:all\n", "            //ci:all \\\n            //ci:mojo\n"), "//ci:mojo is built");
    try expectFinding(a, r, try mutate(a, r.wf, "# //ci:mojo is not built", "# //ci:mojo is built"), "comment that says why");
}

test "a buck2 install that drifted from tools/buck2 is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, try mutate(a, r.wf, "2026-09-15/buck2-x86_64", "2026-09-16/buck2-x86_64"), "url pinned");
    try expectFinding(a, r, try mutate(a, r.wf, "1268fce33fb6", "0268fce33fb6"), "sha256 pinned");
    // the pin moves and the workflow does not
    try expectFinding(a, .{ .wf = r.wf, .ds = try mutate(a, r.ds, "1268fce33fb6", "9999fce33fb6"), .cb = r.cb }, r.wf, "sha256 pinned");
    try expectFinding(a, .{ .wf = r.wf, .ds = "{}", .cb = r.cb }, r.wf, "blind");
}

test "an aarch64 buck2 install that drifted from tools/buck2 is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, try mutate(a, r.wf, "2026-09-15/buck2-aarch64", "2026-09-16/buck2-aarch64"), "linux-aarch64 url");
    try expectFinding(a, r, try mutate(a, r.wf, "e35027a8e3f7", "f35027a8e3f7"), "linux-aarch64 sha256");
    // the pin moves and the workflow does not
    try expectFinding(a, .{ .wf = r.wf, .ds = try mutate(a, r.ds, "e35027a8e3f7", "9999fce33fb6"), .cb = r.cb }, r.wf, "linux-aarch64 sha256");
    // the job runs on the wrong machine, or the pin is dropped
    try expectFinding(a, r, try mutate(a, r.wf, "runs-on: ubuntu-24.04-arm", "runs-on: ubuntu-24.04"), "ubuntu-24.04-arm");
    try expectFinding(a, .{ .wf = r.wf, .ds = try mutate(a, r.ds, "\"linux-aarch64\"", "\"linux-arm\""), .cb = r.cb }, r.wf, "no linux-aarch64");
    // the x86 digest is not read from the aarch64 block, nor the reverse
    const ds = dotslashPlatform(r.ds, "linux-aarch64").?;
    try t.expect(std.mem.startsWith(u8, ds.digest, "e35027a8e3f7"));
    try t.expect(std.mem.startsWith(u8, dotslashLinux(r.ds).?.digest, "1268fce33fb6"));
}

test "the host_arm job must assert the machine, the execution platform and build the aarch64 pins" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const uname = "      - name: The machine is aarch64\n        run: test \"$(uname -m)\" = aarch64\n";
    const grep = " \\\n            | grep --fixed-strings --quiet \"Execution platform: buildrules//platforms:linux_aarch64\"";
    // the machine check
    try expectFinding(a, r, try mutate(a, r.wf, uname, ""), "uname -m");
    try expectFinding(a, r, try mutate(a, r.wf, "= aarch64\n", "= x86_64\n"), "uname -m");
    try expectFinding(a, r, try mutate(a, r.wf, "run: test \"$(uname -m)\" = aarch64", "run: echo ok # test \"$(uname -m)\" = aarch64"), "uname -m");
    // the execution-platform check: dropped, loosened, aimed at another platform or another target, or without the mode
    try expectFinding(a, r, try mutate(a, r.wf, grep, ""), "execution platform");
    try expectFinding(a, r, try mutate(a, r.wf, " \\\n            | grep --fixed-strings --quiet \"Execution platform: buildrules//platforms:linux_aarch64\"", " \\\n            | grep --quiet \"Execution platform: buildrules//platforms:linux_aarch64\""), "execution platform");
    try expectFinding(a, r, try mutate(a, r.wf, "Execution platform: buildrules//platforms:linux_aarch64", "Execution platform: buildrules//platforms:linux_x86_64"), "execution platform");
    try expectFinding(a, r, try mutate(a, r.wf, "-c buildrules_re.mode=local //rules/pins:host_downloads \\\n", "-c buildrules_re.mode=local //rules/pins:zig \\\n"), "execution platform");
    try expectFinding(a, r, try mutate(a, r.wf, "audit execution-platform-resolution", "audit configurations"), "execution platform");
    // the build: not for the aarch64 target platform, not the downloads, or gone
    try expectFinding(a, r, try mutate(a, r.wf, "            --target-platforms buildrules//platforms:linux_aarch64 \\\n", ""), "--target-platforms");
    try expectFinding(a, r, try mutate(a, r.wf, "--target-platforms buildrules//platforms:linux_aarch64", "--target-platforms buildrules//platforms:linux_x86_64"), "--target-platforms");
    try expectFinding(a, r, try mutate(a, r.wf, "            //rules/pins:host_downloads\n", "            //rules/pins:zig\n"), "--target-platforms");
    try expectFinding(a, r, try mutate(a, r.wf, "      - name: Download and verify the pins of the aarch64 hosts\n        run: |\n          ./buck2 build --console simple -c buildrules_re.mode=local \\\n            --target-platforms buildrules//platforms:linux_aarch64 \\\n            //rules/pins:host_downloads\n", ""), "--target-platforms");
    // the job itself, or its steps under another job
    try expectFinding(a, r, try mutate(a, r.wf, "\n  host_arm:\n", "\n  host_x:\n"), "`host_arm` job is missing");
    try expectFinding(a, r, try mutate(a, r.wf, "      - name: The machine is aarch64\n", "  other:\n    runs-on: ubuntu-latest\n    steps:\n      - name: The machine is aarch64\n"), "uname -m");
}

test "a cache key that does not follow the lock files is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, try mutate(a, r.wf, "key: buck-out-${{ runner.os }}-${{ hashFiles(", "key: buck-out-${{ runner.os }}-${{ github.sha }}${{ x("), "lock files");
}

test "a //ci: target missing from ci/BUCK is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, .{ .wf = r.wf, .ds = r.ds, .cb = "name = \"matrix\"\n" }, r.wf, "//ci:all is not declared");
}

test "buck2 run any way but the literal ./buck2 is found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const not_literal = "not the literal `./buck2`";
    // each of these ran the graph in remote mode, past the check, before: with the flag and without it
    const slips = [_][]const u8{
        "$BUCK2 bxl //x:y",
        "${BUCK2} bxl //x:y",
        "\"$BUCK2\" bxl //x:y",
        "buck2 bxl //x:y",
        "/usr/local/bin/buck2 bxl //x:y",
        "~/bin/buck2 bxl //x:y",
        "bash -c 'buck2 bxl //x:y'",
        "sh -c \"/opt/buck2 bxl //x:y\"",
        "eval buck2 bxl //x:y",
        "sudo buck2 bxl //x:y",
        "env FOO=1 buck2 bxl //x:y",
        "exec buck2 bxl //x:y",
        "echo hi && buck2 bxl //x:y",
        "echo $(buck2 bxl //x:y)",
        "FOO=1 buck2 bxl //x:y",
        "./buck2 build -c buildrules_re.mode=local //x:y && buck2 bxl //x:y",
        "buck2 bxl -c buildrules_re.mode=local //x:y",
    };
    for (slips) |c| {
        const wf = try std.mem.concat(a, u8, &.{ r.wf, "      - run: ", c, "\n" });
        try expectFinding(a, r, wf, not_literal);
    }
    // a variable that holds buck2 and is run through the variable
    try expectFinding(a, r, try std.mem.concat(a, u8, &.{ r.wf, "      - run: B=./buck2; $B bxl //x:y\n" }), "variable is set to buck2");
    try expectFinding(a, r, try std.mem.concat(a, u8, &.{ r.wf, "      - run: export BUCK2=buck2\n" }), "variable is set to buck2");
    // what stays allowed: buck2 as an argument or in prose, and the literal form in a wrapper with the flag
    const fine = [_][]const u8{
        "chmod +x buck2",
        "echo installing buck2",
        "echo \"buck2 is ready\"",
        "zstd --decompress buck2.zst -o buck2",
        "bash -c './buck2 build -c buildrules_re.mode=local //ci:all'",
        "env FOO=1 ./buck2 build -c buildrules_re.mode=local //ci:all",
    };
    for (fine) |c| {
        const wf = try std.mem.concat(a, u8, &.{ r.wf, "      - run: ", c, "\n" });
        const f = try check(a, wf, r.ds, r.cb);
        for (f.items) |m| std.debug.print("unexpected: {s}\n", .{m});
        try t.expectEqual(@as(usize, 0), f.items.len);
    }
}

test "kill and --version are exempt only alone, not when more words follow" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    const need = "does not pass `-c buildrules_re.mode=local`";
    for ([_][]const u8{ "kill build //x:y", "kill bxl //x:y", "--version build //x:y", "kill && ./buck2 build //x:y", "kill; ./buck2 test //x:y" }) |c| {
        const wf = try std.mem.concat(a, u8, &.{ r.wf, "      - run: ./buck2 ", c, "\n" });
        try expectFinding(a, r, wf, need);
    }
    // alone, with a redirection, or chained to a command that has the flag, they are exempt
    for ([_][]const u8{ "kill", "kill 2>/dev/null", "--version", "kill && ./buck2 build -c buildrules_re.mode=local //x:y" }) |c| {
        const wf = try std.mem.concat(a, u8, &.{ r.wf, "      - run: ./buck2 ", c, "\n" });
        const f = try check(a, wf, r.ds, r.cb);
        for (f.items) |m| std.debug.print("unexpected: {s}\n", .{m});
        try t.expectEqual(@as(usize, 0), f.items.len);
    }
    // the flag after a separator belongs to the next command, not to the build before it
    try expectFinding(a, r, try std.mem.concat(a, u8, &.{ r.wf, "      - run: ./buck2 build //x:y && echo -c buildrules_re.mode=local\n" }), need);
}

test "ci.yml: continue-on-error and an inline vars or github.event expansion in a run line are found" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const r = try fx(a);
    try expectFinding(a, r, try mutate(a, r.wf, "    runs-on: ubuntu-latest\n", "    runs-on: ubuntu-latest\n    continue-on-error: true\n"), "`continue-on-error` is set to");
    try expectFinding(a, r, try mutate(a, r.wf, "        run: ./buck2 bxl -c buildrules_re.mode=local //ci:completeness.bxl:check\n", "        run: ./buck2 bxl -c buildrules_re.mode=local //ci:completeness.bxl:check ${{ vars.X }}\n"), "expands `vars.` inline");
    try expectFinding(a, r, try mutate(a, r.wf, "          ./buck2 --version\n", "          ./buck2 --version ${{ github.event.pull_request.title }}\n"), "expands `github.event.` inline");
}
