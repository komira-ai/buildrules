//! Shared by the tests that run the built `unpack` on the real pinned archives: the process helpers, and the tree of a directory as text, so two extractions are
//! compared entry by entry (kind, executable bit, size, content digest, link target).
const std = @import("std");

pub const a = std.testing.allocator;

/// An absolute path from the environment (the BUCK target gives the built tools and the work directory).
pub fn envPath(name: []const u8) ![]u8 {
    const v = std.process.getEnvVarOwned(a, name) catch {
        std.debug.print("the environment variable {s} is not set (BUCK gives it with exec_tools)\n", .{name});
        return error.MissingEnvironment;
    };
    defer a.free(v);
    return std.fs.cwd().realpathAlloc(a, v);
}

pub fn work() ![]u8 {
    return envPath("BUILDRULES_TEST_WORK");
}

pub fn join(parts: []const []const u8) ![]u8 {
    return std.fs.path.join(a, parts);
}

/// Runs the program and returns its exit status; its output is passed through on failure.
pub fn run(argv: []const []const u8) !u8 {
    const r = try std.process.Child.run(.{ .allocator = a, .argv = argv, .max_output_bytes = 1 << 20 });
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    };
    if (code != 0) std.debug.print("{s} exited {d}:\n{s}{s}\n", .{ argv[0], code, r.stdout, r.stderr });
    return code;
}

/// Seconds the program takes (its output thrown away), the fastest of `times` runs.
pub fn timeIt(argv: []const []const u8, times: usize) !f64 {
    var best: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < times) : (i += 1) {
        var c = std.process.Child.init(argv, a);
        c.stdout_behavior = .Ignore;
        c.stderr_behavior = .Inherit;
        var timer = try std.time.Timer.start();
        try c.spawn();
        const term = try c.wait();
        const ns = timer.read();
        if (term != .Exited or term.Exited != 0) return error.ProgramFailed;
        best = @min(best, ns);
    }
    return @as(f64, @floatFromInt(best)) / 1e9;
}

/// The tree below `dir` as sorted lines: `d path`, `f path x|- size sha256`, `l path -> target`. A file's executable bit is the one mode bit compared (the umask
/// of the extracting process decides the others).
pub fn tree(dir: []const u8) ![]u8 {
    var root = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer root.close();
    var lines = std.ArrayList([]u8).empty;
    defer {
        for (lines.items) |l| a.free(l);
        lines.deinit(a);
    }
    var w = try root.walk(a);
    defer w.deinit();
    while (try w.next()) |e| {
        const line = switch (e.kind) {
            .directory => try std.fmt.allocPrint(a, "d {s}", .{e.path}),
            .sym_link => blk: {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const target = try root.readLink(e.path, &buf);
                break :blk try std.fmt.allocPrint(a, "l {s} -> {s}", .{ e.path, target });
            },
            .file => blk: {
                const f = try root.openFile(e.path, .{});
                defer f.close();
                const st = try f.stat();
                var h = std.crypto.hash.sha2.Sha256.init(.{});
                var buf: [64 * 1024]u8 = undefined;
                while (true) {
                    const n = try f.read(&buf);
                    if (n == 0) break;
                    h.update(buf[0..n]);
                }
                var digest: [32]u8 = undefined;
                h.final(&digest);
                const hex = std.fmt.bytesToHex(digest, .lower);
                break :blk try std.fmt.allocPrint(a, "f {s} {s} {d} {s}", .{ e.path, if (st.mode & 0o111 != 0) "x" else "-", st.size, hex });
            },
            else => try std.fmt.allocPrint(a, "? {s}", .{e.path}),
        };
        try lines.append(a, line);
    }
    std.mem.sort([]u8, lines.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var out = std.ArrayList(u8).empty;
    for (lines.items) |l| {
        try out.appendSlice(a, l);
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

/// The hex sha256 of a file.
pub fn sha256(path: []const u8) ![64]u8 {
    const bytes = try std.fs.cwd().readFileAlloc(a, path, 1 << 30);
    defer a.free(bytes);
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

/// Extracts `archive` (in the work directory) with unpack into `<work>/<name>_unpack`, and requires its tree equal to the one in `reference` (an absolute path).
pub fn sameAsDirectory(name: []const u8, archive: []const u8, strip: u8, reference: []const u8) !void {
    const w = try work();
    defer a.free(w);
    const unpack = try envPath("UNPACK");
    defer a.free(unpack);
    const arch = try join(&.{ w, archive });
    defer a.free(arch);
    const mine = try std.fmt.allocPrint(a, "{s}/{s}_unpack", .{ w, name });
    defer a.free(mine);
    const digest = try sha256(arch);
    var strip_text: [4]u8 = undefined;
    const strip_arg = try std.fmt.bufPrint(&strip_text, "{d}", .{strip});
    try std.testing.expectEqual(@as(u8, 0), try run(&.{ unpack, "--strip-components", strip_arg, "--sha256", &digest, arch, mine }));
    const m = try tree(mine);
    defer a.free(m);
    const b = try tree(reference);
    defer a.free(b);
    try std.testing.expect(m.len > 0);
    try std.testing.expectEqualStrings(b, m);
}

/// The same, with the reference made by busybox's `tar <flag> archive -C dir`.
pub fn sameAsBusyboxTar(name: []const u8, archive: []const u8, flag: []const u8) !void {
    const w = try work();
    defer a.free(w);
    const bb = try envPath("BUSYBOX");
    defer a.free(bb);
    const arch = try join(&.{ w, archive });
    defer a.free(arch);
    const theirs = try std.fmt.allocPrint(a, "{s}/{s}_busybox", .{ w, name });
    defer a.free(theirs);
    try std.fs.cwd().makePath(theirs);
    try std.testing.expectEqual(@as(u8, 0), try run(&.{ bb, "tar", flag, arch, "-C", theirs }));
    try sameAsDirectory(name, archive, 0, theirs);
}
