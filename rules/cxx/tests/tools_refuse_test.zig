//! The refusals of the C/C++ tools as a user meets them: `zig test` of this file, run as a build action by `:cxx_tools_refuse`. prefix_tool, glibc_floor, hermetic,
//! elfsyms and zig_cc_launcher are run as the processes the public targets hand out (their paths in the environment, the zig_test's `env_tools`), over files the
//! test writes, and each case holds the exit status and the message on stderr to what the tool must say. The unit tests of each tool call its parts in-process and
//! read error codes; these read the sentence a person is shown.
//!
//! glibc_floor and hermetic are also run on an ELF that passes (the hermetic tool itself: a static musl executable, stripped), so a tool that refuses everything is red.

const std = @import("std");
const proc = @import("refusal_proc");

fn exe(a: std.mem.Allocator, name: []const u8, rest: []const []const u8) ![]const []const u8 {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(a, try proc.tool(a, name));
    try argv.appendSlice(a, rest);
    return argv.items;
}

const Case = struct { name: []const u8, args: []const []const u8, code: u8, msgs: []const []const u8 };

fn runCases(a: std.mem.Allocator, tool_env: []const u8, cases: []const Case) !void {
    for (cases) |c| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "notes.txt", .data = "this is not an archive\n" });
        try proc.expectRefusal(c.name, try proc.run(a, tmp.dir, try exe(a, tool_env, c.args)), c.code, c.msgs);
    }
}

// ---- prefix_tool -------------------------------------------------------------------------------------------------------------------------

const HEADER_OK = [_][]const u8{ "--archive", "notes.txt", "--header", "h.h", "--symbols", "s.txt", "--style", "boringssl", "--prefix", "p_", "--min", "1" };

test "prefix_tool: a bad command line is a usage error that says which flag, and prints the usage" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const usage = "usage: prefix_tool header --elfsyms <exe> --archive <lib.a>";
    try runCases(a, "PREFIX_TOOL", &.{
        .{ .name = "no mode", .args = &.{}, .code = 2, .msgs = &.{ "prefix_tool: no mode", usage } },
        .{ .name = "an unknown mode", .args = &.{"frob"}, .code = 2, .msgs = &.{ "prefix_tool: unknown mode frob", usage } },
        .{ .name = "a flag with no value", .args = &.{ "header", "--archive" }, .code = 2, .msgs = &.{"prefix_tool: --archive needs a value"} },
        .{ .name = "an unknown flag", .args = &.{ "header", "--bogus", "x" }, .code = 2, .msgs = &.{"prefix_tool header: unknown flag --bogus"} },
        .{ .name = "a flag of the other mode", .args = &.{ "check", "--header", "h.h" }, .code = 2, .msgs = &.{"prefix_tool check: unknown flag --header"} },
        .{ .name = "a flag given twice", .args = &.{ "check", "--prefix", "a_", "--prefix", "b_" }, .code = 2, .msgs = &.{"prefix_tool: --prefix given twice"} },
        .{ .name = "a required flag left out of header", .args = &.{ "header", "--elfsyms", "e", "--archive", "a.a", "--header", "h", "--symbols", "s", "--style", "strip", "--prefix", "p_" }, .code = 2, .msgs = &.{"prefix_tool header: --min is required"} },
        .{ .name = "a required flag left out of check", .args = &.{ "check", "--elfsyms", "e", "--archive", "a.a", "--prefix", "p_", "--min", "1" }, .code = 2, .msgs = &.{"prefix_tool check: --result is required"} },
    });
}

test "prefix_tool: input that is not what it claims to be is refused, naming the file" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const elfsyms = try proc.tool(a, "ELFSYMS");
    const Run = struct { name: []const u8, args: []const []const u8, msgs: []const []const u8 };
    const cases = [_]Run{
        .{ .name = "a style that is not one", .args = &.{ "header", "--elfsyms", elfsyms, "--archive", "notes.txt", "--header", "h.h", "--symbols", "s.txt", "--style", "gnu", "--prefix", "p_", "--min", "1" }, .msgs = &.{"prefix_tool: unknown style gnu"} },
        .{ .name = "a minimum that is not a number", .args = &.{ "header", "--elfsyms", elfsyms, "--archive", "notes.txt", "--header", "h.h", "--symbols", "s.txt", "--style", "strip", "--prefix", "p_", "--min", "many" }, .msgs = &.{"prefix_tool: --min many is not a number"} },
        .{ .name = "an elfsyms that is not there", .args = &.{ "header", "--elfsyms", "/nonexistent/elfsyms", "--archive", "notes.txt", "--header", "h.h", "--symbols", "s.txt", "--style", "strip", "--prefix", "p_", "--min", "1" }, .msgs = &.{"prefix_tool: cannot run /nonexistent/elfsyms: FileNotFound"} },
        .{ .name = "an archive that is not an archive (header)", .args = &.{ "header", "--elfsyms", elfsyms, "--archive", "notes.txt", "--header", "h.h", "--symbols", "s.txt", "--style", "strip", "--prefix", "p_", "--min", "1" }, .msgs = &.{ "elfsyms: notes.txt is not an ar archive", "prefix_tool: elfsyms armap notes.txt failed" } },
        .{ .name = "an archive that is not an archive (check)", .args = &.{ "check", "--elfsyms", elfsyms, "--archive", "notes.txt", "--result", "r.json", "--prefix", "p_", "--min", "1" }, .msgs = &.{ "elfsyms: notes.txt is not an ar archive", "prefix_tool: elfsyms symtab notes.txt failed" } },
        .{ .name = "an archive that is not there", .args = &.{ "check", "--elfsyms", elfsyms, "--archive", "missing.a", "--result", "r.json", "--prefix", "p_", "--min", "1" }, .msgs = &.{ "missing.a: No such file or directory", "prefix_tool: elfsyms symtab missing.a failed" } },
    };
    for (cases) |c| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "notes.txt", .data = "this is not an archive\n" });
        const r = try proc.run(a, tmp.dir, try exe(a, "PREFIX_TOOL", c.args));
        try proc.expectRefusal(c.name, r, 1, c.msgs);
        // a refused header or check leaves no output behind
        for ([_][]const u8{ "h.h", "s.txt", "r.json" }) |out| try std.testing.expectError(error.FileNotFound, tmp.dir.access(out, .{}));
    }
}

test "elfsyms: the usage, a file that is not an archive, a file that is not there" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try runCases(a, "ELFSYMS", &.{
        .{ .name = "no arguments", .args = &.{}, .code = 2, .msgs = &.{"usage: elfsyms armap <lib.a> | elfsyms symtab <lib.a>"} },
        .{ .name = "a mode that is not one", .args = &.{ "dump", "notes.txt" }, .code = 2, .msgs = &.{"usage: elfsyms armap"} },
        .{ .name = "text for an archive", .args = &.{ "armap", "notes.txt" }, .code = 2, .msgs = &.{"elfsyms: notes.txt is not an ar archive"} },
        .{ .name = "a missing archive", .args = &.{ "symtab", "missing.a" }, .code = 2, .msgs = &.{"missing.a: No such file or directory"} },
    });
}

// ---- glibc_floor and hermetic: an ELF that passes, and what they refuse -----------------------------------------------------------------

/// A copy of the hermetic tool (an ELF with no debug section, no glibc symbol version and no path of the directory of the test) in `dir` as `name`.
fn copyElf(a: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) !void {
    try std.fs.cwd().copyFile(try proc.tool(a, "HERMETIC"), dir, name, .{});
}

test "glibc_floor: an ELF within the floor is accepted; a usage error, a floor that is not a version and a file that is not an ELF are refused" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try copyElf(a, tmp.dir, "elf");
        try proc.expectOk("a static binary needs no glibc", try proc.run(a, tmp.dir, try exe(a, "GLIBC_FLOOR", &.{ "elf", "2.34", "result.json" })));
        const result = try tmp.dir.readFileAlloc(a, "result.json", 1 << 16);
        try std.testing.expect(std.mem.indexOf(u8, result, "\"status\": \"success\"") != null);
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "notes.txt", .data = "not an elf\n" });
        try proc.expectRefusal("text for an ELF", try proc.run(a, tmp.dir, try exe(a, "GLIBC_FLOOR", &.{ "notes.txt", "2.34", "result.json" })), 1, &.{"glibc_floor: cannot read notes.txt: NotElf64"});
        // The message names the file by its basename, and is the whole of stderr: a file in a directory is not named with the directory.
        try tmp.dir.makeDir("sub");
        try tmp.dir.writeFile(.{ .sub_path = "sub/notes.txt", .data = "not an elf\n" });
        const nested = try proc.run(a, tmp.dir, try exe(a, "GLIBC_FLOOR", &.{ "sub/notes.txt", "2.34", "result.json" }));
        try proc.expectRefusal("text for an ELF in a directory", nested, 1, &.{"glibc_floor: cannot read notes.txt: NotElf64"});
        try std.testing.expectEqualStrings("glibc_floor: cannot read notes.txt: NotElf64\n", nested.stderr);
        // the validation result says so too: a build that reads it is red
        const result = try tmp.dir.readFileAlloc(a, "result.json", 1 << 16);
        try std.testing.expect(std.mem.indexOf(u8, result, "\"status\": \"failure\"") != null);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try copyElf(a, tmp.dir, "elf");
    try proc.expectRefusal("no arguments", try proc.run(a, tmp.dir, try exe(a, "GLIBC_FLOOR", &.{})), 2, &.{"usage: glibc_floor <elf> <max> <result.json>"});
    try proc.expectRefusal("too many arguments", try proc.run(a, tmp.dir, try exe(a, "GLIBC_FLOOR", &.{ "elf", "2.34", "r.json", "x" })), 2, &.{"usage: glibc_floor"});
    for ([_][]const u8{ "2", "two.thirty", "2.34.1.x", "2.x", "" }) |bad| {
        const msg = try std.fmt.allocPrint(a, "glibc_floor: {s} is not a version", .{bad});
        try proc.expectRefusal(bad, try proc.run(a, tmp.dir, try exe(a, "GLIBC_FLOOR", &.{ "elf", bad, "result.json" })), 2, &.{msg});
    }
}

test "hermetic: an ELF that does not depend on its directory is accepted; one that does, and a bad command line, are refused" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try copyElf(a, tmp.dir, "elf");
        try proc.expectOk("a stripped binary", try proc.run(a, tmp.dir, try exe(a, "HERMETIC", &.{ "elf", "result.json" })));
    }
    {
        // The directory the tool runs in occurs in the bytes: the binary would differ when built in another directory.
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realpathAlloc(a, ".");
        const elf = try std.fs.cwd().readFileAlloc(a, try proc.tool(a, "HERMETIC"), 1 << 28);
        try tmp.dir.writeFile(.{ .sub_path = "elf", .data = try std.mem.concat(a, u8, &.{ elf, dir }) });
        const msg = try std.fmt.allocPrint(a, "hermetic: elf: it contains the absolute path of the directory it was built in ({s})", .{dir});
        try proc.expectRefusal("a path in the bytes", try proc.run(a, tmp.dir, try exe(a, "HERMETIC", &.{ "elf", "result.json" })), 1, &.{msg});
        const result = try tmp.dir.readFileAlloc(a, "result.json", 1 << 16);
        try std.testing.expect(std.mem.indexOf(u8, result, "\"status\": \"failure\"") != null);
    }
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(.{ .sub_path = "notes.txt", .data = "not an elf\n" });
        try proc.expectRefusal("text for an ELF", try proc.run(a, tmp.dir, try exe(a, "HERMETIC", &.{ "notes.txt", "result.json" })), 1, &.{"hermetic: cannot read notes.txt: NotElf64"});
        try proc.expectRefusal("no arguments", try proc.run(a, tmp.dir, try exe(a, "HERMETIC", &.{})), 2, &.{"usage: hermetic <elf> <result.json>"});
    }
}

// ---- zig_cc_launcher -----------------------------------------------------------------------------------------------------------------------

test "zig_cc_launcher: a usage error, a response file that cannot be read or does not end, a zig that is not there" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "loop.rsp", .data = "@loop.rsp\n" });
    try tmp.dir.writeFile(.{ .sub_path = "open.rsp", .data = "-DNAME=\"unclosed\n" });
    try tmp.dir.makePath("dir.rsp");
    const cases = [_]struct { name: []const u8, args: []const []const u8, msgs: []const []const u8 }{
        .{ .name = "no arguments", .args = &.{}, .msgs = &.{"zig_cc_launcher: usage: zig_cc_launcher <zig_dir> <subcommand> [args...]"} },
        .{ .name = "a directory and no subcommand", .args = &.{"zigdir"}, .msgs = &.{"usage: zig_cc_launcher <zig_dir> <subcommand>"} },
        .{ .name = "a response file that names itself", .args = &.{ "zigdir", "cc", "@loop.rsp" }, .msgs = &.{"zig_cc_launcher: response files nested deeper than 16 at @loop.rsp"} },
        .{ .name = "a quote that is never closed", .args = &.{ "zigdir", "cc", "@open.rsp" }, .msgs = &.{"zig_cc_launcher: unterminated quote in a response file"} },
        .{ .name = "a response file that is a directory", .args = &.{ "zigdir", "cc", "@dir.rsp" }, .msgs = &.{"zig_cc_launcher: cannot read response file dir.rsp: IsDir"} },
        .{ .name = "a zig that is not there", .args = &.{ "zigdir", "cc", "-c", "x.c" }, .msgs = &.{ "zig_cc_launcher: cannot run zigdir/zig: FileNotFound" } },
    };
    for (cases) |c| try proc.expectRefusal(c.name, try proc.run(a, tmp.dir, try exe(a, "ZIG_CC_LAUNCHER", c.args)), 2, c.msgs);
}
