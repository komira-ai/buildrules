//! Unit tests of `--holds` of prebuilt_unpack.zig, run by //rules/mojo:prebuilt_unpack_unit (prebuilt_unpack_test.zig imports this file) (rules/mojo/pack.bzl, `mojo_conda_holds(holds = ...)`), on a `.conda` built in memory
//! (prebuilt_unpack_fixture.zig).
//!
//! What is held, and the defect each test would catch:
//!   - each held member (the source of a program) is the bytes of the caller's file, whatever the order of the request and of the archive;
//!   - a member that is missing or differs, or a file not there, is refused naming that member or file, also when it comes after members that match, and
//!     nothing is written;
//!   - a member named twice (by `--holds`, as the `.mojoc` or as a native) or whose path is not relative plain names is refused;
//!   - `--holds` with `--natives`, `--depends` and `--sole`: each check still holds, the natives are written only when everything passes, and `--sole` takes
//!     the package's own programs (`lib/mojo/<name>.bins/`) and still refuses another package's;
//!   - every allocation failing in turn is an error, and every refusal stays one when its wording cannot be allocated.
const std = @import("std");
const U = @import("prebuilt_unpack.zig");
const F = @import("prebuilt_unpack_fixture.zig");
const t = std.testing;
const absent = F.absent;
const conda = F.conda;
const condaIndexed = F.condaIndexed;
const idx_q = F.idx_q;
const libb = F.libb;
const m1 = F.m1;
const nativeArg = F.nativeArg;
const read = F.read;
const runWith = F.runWith;
const sha = F.sha;
const sweepError = F.sweepError;

const prog = "def main():\n    print(\"hello\")\n";
const prog_member = "lib/mojo/p.bins/hello.mojo";

test "run --holds: the package carries each member with exactly the file's bytes; a member it lacks, other bytes, or a file not there are refused, writing nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const c = try conda(a, &.{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = prog_member, .body = prog }, .{ .name = "lib/mojo/p.bins/b.mojo", .body = "b" } });
    try tmp.dir.writeFile(.{ .sub_path = "hello.mojo", .data = prog });
    try tmp.dir.writeFile(.{ .sub_path = "b.mojo", .data = "b" });
    try tmp.dir.writeFile(.{ .sub_path = "edited.mojo", .data = prog ++ "#" });
    try t.expect((try runWith(a, tmp.dir, c, &.{ "--holds", prog_member ++ "=hello.mojo", "--holds", "lib/mojo/p.bins/b.mojo=b.mojo" })).err == null);
    try t.expectEqualStrings(m1, try read(a, tmp.dir, "out.mojoc"));
    try tmp.dir.deleteFile("out.mojoc");
    const lacks = try runWith(a, tmp.dir, try conda(a, &.{.{ .name = "lib/mojo/p.mojoc", .body = m1 }}), &.{ "--holds", prog_member ++ "=hello.mojo" });
    try t.expect(lacks.err.? == error.NoMember);
    try t.expectEqualStrings("p.conda: " ++ prog_member ++ ": NoMember", lacks.why);
    const other = try runWith(a, tmp.dir, c, &.{ "--holds", prog_member ++ "=edited.mojo" });
    try t.expect(other.err.? == error.HeldMismatch);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "p.conda: {s} hashes to {s}, edited.mojo to {s}", .{ prog_member, sha(prog), sha(prog ++ "#") }), other.why);
    const gone = try runWith(a, tmp.dir, c, &.{ "--holds", prog_member ++ "=missing.mojo" });
    try t.expect(gone.err.? == error.FileNotFound);
    try t.expectEqualStrings("cannot read missing.mojo: FileNotFound", gone.why);
    // A member named twice, by --holds or as the `.mojoc` the package is unpacked for, is refused: the second would never be found.
    const twice = try runWith(a, tmp.dir, c, &.{ "--holds", prog_member ++ "=hello.mojo", "--holds", prog_member ++ "=hello.mojo" });
    try t.expect(twice.err.? == error.BadHolds);
    try t.expectEqualStrings("--holds names " ++ prog_member ++ ", which is already checked", twice.why);
    try t.expect((try runWith(a, tmp.dir, c, &.{ "--holds", "lib/mojo/p.mojoc=hello.mojo" })).err.? == error.BadHolds);
    try t.expect(absent(tmp.dir, "out.mojoc"));
}

test "the command line: --holds needs a member that is a relative path of plain names, and a file" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    for ([_][]const u8{ "lib/x", "=f", "lib/x=", "/lib/x=f", "lib//x=f", "lib/./x=f", "lib/../x=f", "../x=f", "lib/x/=f" }) |arg| {
        try t.expectError(error.BadHolds, U.parseArgs(a, &.{ "p.conda", "p", "o", "--holds", arg }, &why));
        try t.expect(std.mem.startsWith(u8, why, "--holds "));
    }
    try t.expectError(error.BadUsage, U.parseArgs(a, &.{ "p.conda", "p", "o", "--holds" }, &why));
    const ok = try U.parseArgs(a, &.{ "p.conda", "p", "o", "--holds", "lib/mojo/p.bins/run.mojo=dir/run=1.mojo" }, &why);
    try t.expectEqual(@as(usize, 1), ok.holds.len);
    try t.expectEqualStrings("lib/mojo/p.bins/run.mojo", ok.holds[0].member);
    try t.expectEqualStrings("dir/run=1.mojo", ok.holds[0].path);
}

test "run --holds: every allocation failing in turn is an error, and every refusal stays one when its wording cannot be allocated" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "p.conda", .data = try conda(a, &.{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = prog_member, .body = prog } }) });
    try tmp.dir.writeFile(.{ .sub_path = "hello.mojo", .data = prog });
    try tmp.dir.writeFile(.{ .sub_path = "edited.mojo", .data = "x" });
    const args = [_][]const u8{ "p.conda", "p", "out.mojoc", "--holds", prog_member ++ "=hello.mojo" };
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var inner = std.heap.ArenaAllocator.init(t.allocator);
        defer inner.deinit();
        var fa = t.FailingAllocator.init(inner.allocator(), .{ .fail_index = i });
        var why: []const u8 = "";
        if (U.run(fa.allocator(), tmp.dir, &args, &why)) |_| {
            try t.expect(!fa.has_induced_failure);
            break;
        } else |e| try t.expectEqual(error.OutOfMemory, e);
    } else return error.SweepDidNotEnd;
    try sweepError(tmp.dir, &.{ "p.conda", "p", "o.mojoc", "--holds", "lib/x" }, error.BadHolds);
    try sweepError(tmp.dir, &.{ "p.conda", "p", "o.mojoc", "--holds", "../x=f" }, error.BadHolds);
    try sweepError(tmp.dir, &.{ "p.conda", "p", "o.mojoc", "--holds", "lib/x=" }, error.BadHolds);
    try sweepError(tmp.dir, &.{ "p.conda", "p", "o.mojoc", "--holds", "lib/mojo/p.mojoc=hello.mojo" }, error.BadHolds);
    try sweepError(tmp.dir, &.{ "p.conda", "p", "o.mojoc", "--holds", prog_member ++ "=missing.mojo" }, error.FileNotFound);
    try sweepError(tmp.dir, &.{ "p.conda", "p", "o.mojoc", "--holds", prog_member ++ "=edited.mojo" }, error.HeldMismatch);
}

test "run --holds: members asked for against the archive's order are each held; a later one that is missing, differs or cannot be read is refused by name, writing nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // The archive holds a, b, c; the request is c, b, a.
    const c = try conda(a, &.{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/mojo/p.bins/a.mojo", .body = "A" }, .{ .name = "lib/mojo/p.bins/b.mojo", .body = "B" }, .{ .name = "lib/mojo/p.bins/c.mojo", .body = "C" } });
    try tmp.dir.writeFile(.{ .sub_path = "a", .data = "A" });
    try tmp.dir.writeFile(.{ .sub_path = "b", .data = "B" });
    try tmp.dir.writeFile(.{ .sub_path = "c", .data = "C" });
    try tmp.dir.writeFile(.{ .sub_path = "x", .data = "X" });
    try t.expect((try runWith(a, tmp.dir, c, &.{ "--holds", "lib/mojo/p.bins/c.mojo=c", "--holds", "lib/mojo/p.bins/b.mojo=b", "--holds", "lib/mojo/p.bins/a.mojo=a" })).err == null);
    try tmp.dir.deleteFile("out.mojoc");
    // After two that match: the third is not in the package.
    const lacks = try runWith(a, tmp.dir, c, &.{ "--holds", "lib/mojo/p.bins/c.mojo=c", "--holds", "lib/mojo/p.bins/b.mojo=b", "--holds", "lib/mojo/p.bins/d.mojo=a" });
    try t.expect(lacks.err.? == error.NoMember);
    try t.expectEqualStrings("p.conda: lib/mojo/p.bins/d.mojo: NoMember", lacks.why);
    // After two that match: the third is other bytes.
    const differs = try runWith(a, tmp.dir, c, &.{ "--holds", "lib/mojo/p.bins/c.mojo=c", "--holds", "lib/mojo/p.bins/b.mojo=b", "--holds", "lib/mojo/p.bins/a.mojo=x" });
    try t.expect(differs.err.? == error.HeldMismatch);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "p.conda: lib/mojo/p.bins/a.mojo hashes to {s}, x to {s}", .{ sha("A"), sha("X") }), differs.why);
    // After two that match: the third file is not there.
    const gone = try runWith(a, tmp.dir, c, &.{ "--holds", "lib/mojo/p.bins/c.mojo=c", "--holds", "lib/mojo/p.bins/b.mojo=b", "--holds", "lib/mojo/p.bins/a.mojo=nothing" });
    try t.expect(gone.err.? == error.FileNotFound);
    try t.expectEqualStrings("cannot read nothing: FileNotFound", gone.why);
    try t.expect(absent(tmp.dir, "out.mojoc"));
}

test "run --holds with --natives: both are held and the natives written; a held member that differs, or one that is a native's member, is refused with no native written" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const c = try conda(a, &.{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/libbase_sys.a", .body = libb }, .{ .name = prog_member, .body = prog } });
    try tmp.dir.writeFile(.{ .sub_path = "hello.mojo", .data = prog });
    try tmp.dir.writeFile(.{ .sub_path = "edited.mojo", .data = "x" });
    const native = try nativeArg(a, "libbase_sys.a", libb);
    try t.expect((try runWith(a, tmp.dir, c, &.{ "--natives", "n", "--native", native, "--holds", prog_member ++ "=hello.mojo" })).err == null);
    try t.expectEqualStrings(libb, try read(a, tmp.dir, "n/libbase_sys.a"));
    try t.expectEqualStrings(m1, try read(a, tmp.dir, "out.mojoc"));
    var fresh = t.tmpDir(.{});
    defer fresh.cleanup();
    try fresh.dir.writeFile(.{ .sub_path = "edited.mojo", .data = "x" });
    try fresh.dir.writeFile(.{ .sub_path = "hello.mojo", .data = prog });
    const differs = try runWith(a, fresh.dir, c, &.{ "--natives", "n", "--native", native, "--holds", prog_member ++ "=edited.mojo" });
    try t.expect(differs.err.? == error.HeldMismatch);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "p.conda: {s} hashes to {s}, edited.mojo to {s}", .{ prog_member, sha(prog), sha("x") }), differs.why);
    const on_native = try runWith(a, fresh.dir, c, &.{ "--natives", "n", "--native", native, "--holds", "lib/libbase_sys.a=hello.mojo" });
    try t.expect(on_native.err.? == error.BadHolds);
    try t.expectEqualStrings("--holds names lib/libbase_sys.a, which is already checked", on_native.why);
    try t.expect(absent(fresh.dir, "out.mojoc"));
    try t.expect(absent(fresh.dir, "n"));
}

test "run --holds with --depends and --sole: the package's own programs are itself; another package's program, or wrong dependencies, are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "hello.mojo", .data = prog });
    const own = [_]F.Ent{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = "lib/mojo/p.mopm.json", .body = "{}" }, .{ .name = prog_member, .body = prog } };
    try tmp.dir.writeFile(.{ .sub_path = "p.conda", .data = try condaIndexed(a, &own, idx_q) });
    var why: []const u8 = "";
    try U.run(a, tmp.dir, &.{ "p.conda", "p", "out.mojoc", "--sole", "--depends", "mojo-q >=0.1,<0.2", "--holds", prog_member ++ "=hello.mojo" }, &why);
    try tmp.dir.deleteFile("out.mojoc");
    // Dependencies other than the package records.
    try t.expectError(error.WrongDepends, U.run(a, tmp.dir, &.{ "p.conda", "p", "out.mojoc", "--sole", "--depends", "mojo-r >=0.1", "--holds", prog_member ++ "=hello.mojo" }, &why));
    // A program of another package (`q`), and one at a name that only starts like the package's (`pp.bins`).
    for ([_][]const u8{ "lib/mojo/q.bins/hello.mojo", "lib/mojo/pp.bins/hello.mojo" }) |foreign| {
        const files = [_]F.Ent{ .{ .name = "lib/mojo/p.mojoc", .body = m1 }, .{ .name = prog_member, .body = prog }, .{ .name = foreign, .body = prog } };
        try tmp.dir.writeFile(.{ .sub_path = "p.conda", .data = try condaIndexed(a, &files, idx_q) });
        try t.expectError(error.ForeignMember, U.run(a, tmp.dir, &.{ "p.conda", "p", "out.mojoc", "--sole", "--holds", prog_member ++ "=hello.mojo" }, &why));
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "p.conda holds {s}, which is not the package p itself", .{foreign}), why);
    }
    try t.expect(absent(tmp.dir, "out.mojoc"));
}
