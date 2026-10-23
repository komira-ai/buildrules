const std = @import("std");
const runner = @import("runner.zig");

const base = runner.Spec{
    .tree = "/t",
    .modules = "/m",
    .node = "/n",
    .libs = "/l",
    .package = "p",
    .program = "node_modules/.bin/x",
    .args = &.{},
    .env = &.{},
    .out_dir = null,
    .scratch = "/s",
};

test "buildEnv: the fixed environment and nothing else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = try runner.buildEnv(arena.allocator(), base);
    try std.testing.expectEqual(@as(u32, 6), env.count());
    try std.testing.expectEqualStrings("C", env.get("LC_ALL").?);
    try std.testing.expectEqualStrings("UTC0", env.get("TZ").?);
    try std.testing.expectEqualStrings("/s/home", env.get("HOME").?);
    try std.testing.expectEqualStrings("/s/tmp", env.get("TMPDIR").?);
    try std.testing.expectEqualStrings("/n/bin:/s/bin", env.get("PATH").?);
    try std.testing.expectEqualStrings("/l/lib", env.get("LD_LIBRARY_PATH").?);
    // The host's environment never reaches node: this process has a PATH of its own.
    try std.testing.expect(env.get("NODE_OPTIONS") == null and env.get("NODE_PATH") == null and env.get("AWS_ACCESS_KEY_ID") == null);
}

test "buildEnv: the target's variables are added and may not be inherited from anywhere" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var spec = base;
    spec.env = &.{ .{ "CDK_DEFAULT_REGION", "us-east-1" }, .{ "TZ", "Europe/Paris" } };
    var env = try runner.buildEnv(arena.allocator(), spec);
    try std.testing.expectEqualStrings("us-east-1", env.get("CDK_DEFAULT_REGION").?);
    try std.testing.expectEqualStrings("Europe/Paris", env.get("TZ").?);
    try std.testing.expectEqual(@as(u32, 7), env.count());
}

test "scratchDir: buck2's private directory, relative or absolute, or one of the working directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/root/.buildrules_action", try runner.scratchDir(a, "/root", null));
    try std.testing.expectEqualStrings("/root/.buildrules_action", try runner.scratchDir(a, "/root", ""));
    try std.testing.expectEqualStrings("/root/buck-out/tmp/x/buildrules", try runner.scratchDir(a, "/root", "buck-out/tmp/x"));
    try std.testing.expectEqualStrings("/abs/tmp/buildrules", try runner.scratchDir(a, "/root", "/abs/tmp"));
}

test "copyTree: files writable in the copy, executable only where the source was" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src/lib/deep");
    try tmp.dir.makePath("dst");
    {
        const f = try tmp.dir.createFile("src/lib/deep/a.txt", .{ .mode = 0o444 });
        f.close();
        const g = try tmp.dir.createFile("src/run.sh", .{ .mode = 0o555 });
        g.close();
    }
    var src = try tmp.dir.openDir("src", .{ .iterate = true });
    defer src.close();
    var dst = try tmp.dir.openDir("dst", .{});
    defer dst.close();
    try runner.copyTree(a, src, dst);
    const st1 = try dst.statFile("lib/deep/a.txt");
    const st2 = try dst.statFile("run.sh");
    try std.testing.expectEqual(@as(u32, 0o644), @as(u32, @intCast(st1.mode & 0o777)));
    try std.testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(st2.mode & 0o777)));
}

test "tools: the links are in the directory PATH names after node's, and only they" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var spec = base;
    spec.tools = &.{.{ "bzip2", "/pinned/busybox" }};
    var env = try runner.buildEnv(arena.allocator(), spec);
    try std.testing.expectEqualStrings("/n/bin:/s/bin", env.get("PATH").?);
}

const tartest = @import("tartest.zig");

test "copyTree: a link in the tree is refused, not copied and not followed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.makePath("dst");
    try tmp.dir.writeFile(.{ .sub_path = "src/real", .data = "x" });
    try tmp.dir.symLink("real", "src/link", .{});
    var src = try tmp.dir.openDir("src", .{ .iterate = true });
    defer src.close();
    var dst = try tmp.dir.openDir("dst", .{});
    defer dst.close();
    try std.testing.expectError(error.UnsupportedFileKind, runner.copyTree(arena.allocator(), src, dst));
    try std.testing.expectError(error.FileNotFound, dst.statFile("link"));
}

fn envOnce(a: std.mem.Allocator, spec: *const runner.Spec) !void {
    var env = try runner.buildEnv(a, spec.*);
    if (env.count() == 0) return error.Empty;
}

fn scratchOnce(a: std.mem.Allocator, buck_scratch: *const ?[]const u8) !void {
    _ = try runner.scratchDir(a, "/root", buck_scratch.*);
}

test "an allocation that fails is an error: the environment and the scratch directory are never half-made" {
    var spec = base;
    spec.env = &.{ .{ "CDK_DEFAULT_REGION", "us-east-1" }, .{ "TZ", "Europe/Paris" } };
    try tartest.allocSweep(envOnce, &spec);
    const relative: ?[]const u8 = "buck-out/tmp/x";
    try tartest.allocSweep(scratchOnce, &relative);
    const none: ?[]const u8 = null;
    try tartest.allocSweep(scratchOnce, &none);
}

test "copyTree: a file whose place in the destination is taken by a directory is an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.makePath("dst/f");
    try tmp.dir.writeFile(.{ .sub_path = "src/f", .data = "x" });
    var src = try tmp.dir.openDir("src", .{ .iterate = true });
    defer src.close();
    var dst = try tmp.dir.openDir("dst", .{});
    defer dst.close();
    try std.testing.expect(std.meta.isError(runner.copyTree(arena.allocator(), src, dst)));
}

const Dirs = struct { src: std.fs.Dir, dst: std.fs.Dir };

fn copyOnce(a: std.mem.Allocator, d: *const Dirs) !void {
    try runner.copyTree(a, d.src, d.dst);
}

test "an allocation that fails while a tree is copied is an error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src/lib/deep");
    try tmp.dir.makePath("dst");
    try tmp.dir.writeFile(.{ .sub_path = "src/lib/deep/a.txt", .data = "a" });
    try tmp.dir.writeFile(.{ .sub_path = "src/run.sh", .data = "b", .flags = .{ .mode = 0o755 } });
    var src = try tmp.dir.openDir("src", .{ .iterate = true });
    defer src.close();
    var dst = try tmp.dir.openDir("dst", .{});
    defer dst.close();
    try tartest.allocSweep(copyOnce, &Dirs{ .src = src, .dst = dst });
}

// ---- run: node is node_stub (a tool of this test, node_stub.zig), so that what `run` does around it can be seen ----

const Fx = struct {
    tmp: std.testing.TmpDir,
    /// The absolute path of the temporary directory; the fixture's directories are below it.
    root: []const u8,
    /// The absolute path of node_stub.
    stub: []const u8,

    fn deinit(f: *Fx) void {
        f.tmp.cleanup();
    }

    /// A path below the temporary directory.
    fn at(f: *const Fx, a: std.mem.Allocator, rel: []const u8) ![]const u8 {
        return std.fs.path.join(a, &.{ f.root, rel });
    }
};

/// A source tree with package `p` holding a read-only main.js, a modules directory with the bin `tsc`, and a node with no bin/node.
fn fixture(a: std.mem.Allocator) !Fx {
    const stub = try std.process.getEnvVarOwned(a, "NODE_STUB");
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    errdefer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    try tmp.dir.makePath("tree/p");
    try tmp.dir.makePath("modules/.bin");
    try tmp.dir.makePath("node/bin");
    try tmp.dir.makePath("libs/lib");
    try tmp.dir.writeFile(.{ .sub_path = "tree/p/main.js", .data = "// the program\n", .flags = .{ .mode = 0o444 } });
    try tmp.dir.writeFile(.{ .sub_path = "modules/.bin/tsc", .data = "// a bin\n" });
    return .{ .tmp = tmp, .root = root, .stub = stub };
}

/// bin/node of the pinned node becomes the stand-in.
fn installNode(fx: *const Fx) !void {
    fx.tmp.dir.deleteFile("node/bin/node") catch {};
    try fx.tmp.dir.symLink(fx.stub, "node/bin/node", .{});
}

fn specOf(a: std.mem.Allocator, fx: *const Fx) !runner.Spec {
    return .{
        .tree = try fx.at(a, "tree"),
        .modules = try fx.at(a, "modules"),
        .node = try fx.at(a, "node"),
        .libs = try fx.at(a, "libs"),
        .package = "p",
        .program = "main.js",
        .args = &.{},
        .env = &.{},
        .out_dir = null,
        .scratch = try fx.at(a, "scratch"),
    };
}

const Ran = struct { failed: bool, msg: []const u8 };

fn go(a: std.mem.Allocator, fx: *const Fx, spec: runner.Spec) !Ran {
    var msg = tartest.Sink{ .a = a };
    const out = try fx.at(a, "out");
    runner.run(a, spec, out, &msg) catch |e| switch (e) {
        error.Failed => return .{ .failed = true, .msg = msg.text.items },
        else => return e,
    };
    return .{ .failed = false, .msg = msg.text.items };
}

fn expectRefused(r: Ran, want: []const u8) !void {
    if (!r.failed or !std.mem.eql(u8, r.msg, want)) {
        std.debug.print("failed: {}\nmessage: {s}\nwant:    {s}\n", .{ r.failed, r.msg, want });
        return error.TestExpectedMessage;
    }
}

fn slurp(a: std.mem.Allocator, fx: *const Fx, path: []const u8) ![]u8 {
    return fx.tmp.dir.readFileAlloc(a, path, 1 << 20);
}

test "run: a program the package does not hold is refused, and the scratch directory is gone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try fixture(a);
    defer fx.deinit();
    var spec = try specOf(a, &fx);
    spec.program = "node_modules/.bin/absent";
    try expectRefused(try go(a, &fx, spec), "node_modules: node_modules/.bin/absent is not in p/ (a package missing from node_modules, or a bin it does not declare)\n");
    try std.testing.expectError(error.FileNotFound, fx.tmp.dir.statFile("scratch"));
    // the same program is found where the modules directory holds it
    spec.program = "node_modules/.bin/tsc";
    try installNode(&fx);
    try std.testing.expect(!(try go(a, &fx, spec)).failed);
}

test "run: a tool whose name is not a command name is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try fixture(a);
    defer fx.deinit();
    var spec = try specOf(a, &fx);
    spec.script = "node x";
    spec.tools = &.{.{ "a/b", "/pinned/tool" }};
    try expectRefused(try go(a, &fx, spec), "node_modules: tool name a/b is not a command name\n");
    spec.tools = &.{.{ "", "/pinned/tool" }};
    try expectRefused(try go(a, &fx, spec), "node_modules: tool name  is not a command name\n");
}

test "run: a script is read in full before its first command runs, and what cannot run is named" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try fixture(a);
    defer fx.deinit();
    try installNode(&fx);
    const cases = [_]struct { script: []const u8, want: []const u8 }{
        .{ .script = "node ok.js && a | b", .want = "node_modules: the script `node ok.js && a | b` cannot be run without a shell: a pipe or `||` at byte 16\n" },
        .{ .script = "node ok.js && npm run x", .want = "node_modules: `npm` in the script `node ok.js && npm run x`: there is no npm in a build action; write what it runs (`npm run x` is the script x)\n" },
        .{ .script = "npx jest", .want = "node_modules: `npx` in the script `npx jest`: there is no npm in a build action; write what it runs (`npm run x` is the script x)\n" },
        .{ .script = "node ok.js && eslint .", .want = "node_modules: `eslint` in the script `node ok.js && eslint .` is not node, a tool of this target or a bin of node_modules\n" },
    };
    for (cases) |c| {
        var spec = try specOf(a, &fx);
        spec.script = c.script;
        spec.env = &.{.{ "STUB_LOG", try fx.at(a, "ran") }};
        try expectRefused(try go(a, &fx, spec), c.want);
        // the first command, which would have run, did not
        try std.testing.expectError(error.FileNotFound, fx.tmp.dir.statFile("ran"));
    }
}

test "run: a program or a command that cannot be started is named with the reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try fixture(a);
    defer fx.deinit();
    // there is no bin/node in the pinned node
    var spec = try specOf(a, &fx);
    try expectRefused(try go(a, &fx, spec), "node_modules: main.js: cannot run: FileNotFound\n");
    spec.script = "FOO=1 tsc -p .";
    try expectRefused(try go(a, &fx, spec), "node_modules: tsc: cannot run: FileNotFound\n");
    spec.script = "node x";
    try expectRefused(try go(a, &fx, spec), "node_modules: node: cannot run: FileNotFound\n");
    // a tool whose executable is not there
    spec.script = "gone a";
    spec.tools = &.{.{ "gone", "/nowhere/gone" }};
    try expectRefused(try go(a, &fx, spec), "node_modules: gone: cannot run: FileNotFound\n");
}

test "run: the program runs in a copy of the tree with the modules linked, in the environment of the target and nothing of the host's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try fixture(a);
    defer fx.deinit();
    try installNode(&fx);
    var spec = try specOf(a, &fx);
    spec.args = &.{ "--flag", "v" };
    spec.env = &.{
        .{ "FOO", "bar" },
        .{ "TZ", "Europe/Paris" },
        .{ "STUB_LOG", try fx.at(a, "calls") },
        .{ "STUB_SHOW", "FOO,TZ,HOME,TMPDIR,LD_LIBRARY_PATH,PATH,NODE_OPTIONS" },
        .{ "STUB_SEEN", "main.js,node_modules/.bin/tsc" },
        .{ "STUB_CHANGE", "main.js" },
        .{ "STUB_WRITE", "dist/sub/out.txt" },
    };
    spec.out_dir = "dist";
    const r = try go(a, &fx, spec);
    try std.testing.expect(!r.failed);
    try std.testing.expectEqualStrings("", r.msg);
    const want = try std.fmt.allocPrint(a, "node {s}/scratch/work/p/main.js --flag v FOO=bar TZ=Europe/Paris HOME={s}/scratch/home TMPDIR={s}/scratch/tmp " ++
        "LD_LIBRARY_PATH={s}/libs/lib PATH={s}/node/bin:{s}/scratch/bin NODE_OPTIONS=unset seen=yes\n", .{ fx.root, fx.root, fx.root, fx.root, fx.root, fx.root });
    try std.testing.expectEqualStrings(want, try slurp(a, &fx, "calls"));
    // the result is the directory the program wrote, below out/
    try std.testing.expectEqualStrings("built\n", try slurp(a, &fx, "out/sub/out.txt"));
    // the source tree is not the program's to change, and the scratch directory is gone
    try std.testing.expectEqualStrings("// the program\n", try slurp(a, &fx, "tree/p/main.js"));
    try std.testing.expectError(error.FileNotFound, fx.tmp.dir.statFile("scratch"));
}

test "run: without an out directory the result is an empty pass marker; a scratch directory left behind is cleared first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try fixture(a);
    defer fx.deinit();
    try installNode(&fx);
    // an earlier action's work, with the link `run` is about to make already there
    try fx.tmp.dir.makePath("scratch/work/p/node_modules");
    const spec = try specOf(a, &fx);
    try std.testing.expect(!(try go(a, &fx, spec)).failed);
    const st = try fx.tmp.dir.statFile("out");
    try std.testing.expectEqual(std.fs.File.Kind.file, st.kind);
    try std.testing.expectEqual(@as(u64, 0), st.size);
}

test "run: a program that fails, is killed or writes no out directory fails the action with the reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try fixture(a);
    defer fx.deinit();
    try installNode(&fx);
    var spec = try specOf(a, &fx);
    spec.env = &.{.{ "STUB_EXIT", "3" }};
    try expectRefused(try go(a, &fx, spec), "node_modules: main.js exited 3\n");
    try std.testing.expectError(error.FileNotFound, fx.tmp.dir.statFile("out"));
    spec.env = &.{.{ "STUB_KILL", "1" }};
    try expectRefused(try go(a, &fx, spec), "node_modules: main.js was killed by signal 9\n");
    spec.env = &.{};
    spec.out_dir = "dist";
    try expectRefused(try go(a, &fx, spec), "node_modules: the program passed but wrote no dist/\n");
}

test "run: a script's commands run in order, each only if the one before exited 0, with their own variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try fixture(a);
    defer fx.deinit();
    try installNode(&fx);
    var spec = try specOf(a, &fx);
    spec.script = "A=1 node ok.js && node show.js && node fail.js && node never.js";
    spec.env = &.{ .{ "STUB_LOG", try fx.at(a, "calls") }, .{ "STUB_SHOW", "A" }, .{ "STUB_EXIT_ON", "fail.js:5" } };
    try expectRefused(try go(a, &fx, spec), "node_modules: node exited 5\n");
    try std.testing.expectEqualStrings("node ok.js A=1\nnode show.js A=unset\nnode fail.js A=unset\n", try slurp(a, &fx, "calls"));
}

test "run: a script runs a bin of node_modules under node, and a tool of the target by its own name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try fixture(a);
    defer fx.deinit();
    try installNode(&fx);
    var spec = try specOf(a, &fx);
    spec.script = "tsc -p . && mytool a b";
    spec.env = &.{.{ "STUB_LOG", try fx.at(a, "calls") }};
    // the tool is linked into the directory after node's on PATH, under its own name
    spec.tools = &.{.{ "mytool", fx.stub }};
    const r = try go(a, &fx, spec);
    try std.testing.expect(!r.failed);
    const want = try std.fmt.allocPrint(a, "node {s}/scratch/work/p/node_modules/.bin/tsc -p .\nmytool a b\n", .{fx.root});
    try std.testing.expectEqualStrings(want, try slurp(a, &fx, "calls"));
}

const RunCase = struct { spec: runner.Spec, out: []const u8 };

fn runOnce(a: std.mem.Allocator, c: *const RunCase) !void {
    var msg = tartest.Sink{ .a = a };
    try runner.run(a, c.spec, c.out, &msg);
}

test "an allocation that fails while a program runs is an error, never a result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // a program that writes an out directory
    var fx = try fixture(a);
    defer fx.deinit();
    try installNode(&fx);
    var spec = try specOf(a, &fx);
    spec.args = &.{"--flag"};
    spec.env = &.{ .{ "FOO", "bar" }, .{ "STUB_WRITE", "dist/out.txt" } };
    spec.out_dir = "dist";
    try tartest.allocSweep(runOnce, &RunCase{ .spec = spec, .out = try fx.at(a, "out") });
    // a script of a bin, a tool and the node, with a variable of its own, to a pass marker
    var fx2 = try fixture(a);
    defer fx2.deinit();
    try installNode(&fx2);
    var spec2 = try specOf(a, &fx2);
    spec2.script = "A=1 node a.js 1 2 3 4 5 6 7 8 9 && tsc -p . 1 2 3 4 5 6 7 8 9 && mytool x";
    spec2.tools = &.{.{ "mytool", fx2.stub }};
    try tartest.allocSweep(runOnce, &RunCase{ .spec = spec2, .out = try fx2.at(a, "out") });
}

fn runWriting(w: *tartest.Sink, c: *const RunCase) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try runner.run(arena.allocator(), c.spec, c.out, w);
}

test "a refusal whose line cannot be written is still a refusal: the action fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try fixture(a);
    defer fx.deinit();
    const out = try fx.at(a, "out");
    // there is no bin/node yet: the program cannot be started
    var spec = try specOf(a, &fx);
    try tartest.writerSweep(runWriting, &RunCase{ .spec = spec, .out = out });
    spec.script = "node x";
    try tartest.writerSweep(runWriting, &RunCase{ .spec = spec, .out = out });
    // refused before anything runs
    spec.program = "absent.js";
    spec.script = null;
    try tartest.writerSweep(runWriting, &RunCase{ .spec = spec, .out = out });
    const scripts = [_][]const u8{ "a | b", "npm run x", "eslint ." };
    for (scripts) |s| {
        spec.script = s;
        try tartest.writerSweep(runWriting, &RunCase{ .spec = spec, .out = out });
    }
    spec.script = "node x";
    spec.tools = &.{.{ "a/b", "/pinned/tool" }};
    try tartest.writerSweep(runWriting, &RunCase{ .spec = spec, .out = out });
    // and the ways a program that was started fails
    try installNode(&fx);
    var s = try specOf(a, &fx);
    s.env = &.{.{ "STUB_EXIT", "3" }};
    try tartest.writerSweep(runWriting, &RunCase{ .spec = s, .out = out });
    s.env = &.{.{ "STUB_KILL", "1" }};
    try tartest.writerSweep(runWriting, &RunCase{ .spec = s, .out = out });
    s.env = &.{};
    s.out_dir = "dist";
    try tartest.writerSweep(runWriting, &RunCase{ .spec = s, .out = out });
}

