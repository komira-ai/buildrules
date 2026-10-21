//! `check run`, `check marker` and `check expect`: a program started as runspec.zig describes, and what each does with the result.

const std = @import("std");
const common = @import("common.zig");
const rs = @import("runspec.zig");
const Io = common.Io;
const Alloc = common.Alloc;
const Oom = common.Oom;

/// `check run [OPTIONS] -- PROGRAM [ARG]...`: starts the program and exits with its status (128 and the signal when a signal ended it).
/// `--refuse MESSAGE` instead starts nothing: it writes the message to stderr and exits 2, the stand-in for a tool a toolchain does not provide.
pub fn run(_: Alloc, io: Io, args: []const []const u8) Oom!u8 {
    const spec = (try rs.parse(io, "run", .run, args)) orelse return 2;
    if (spec.refuse) |message| {
        io.err.writeAll(try common.concat(io.a, &.{ message, "\n" })) catch {};
        return 2;
    }
    const prepared = switch (try rs.prepare(io, "run", spec)) {
        .ready => |p| p,
        .fail => |code| return code,
    };
    defer rs.cleanup(io, prepared);
    return rs.start(io, "run", prepared, .inherit).code;
}

/// `check marker --out FILE [--capture] [--stamp TEXT | --stamp-log] [OPTIONS] -- PROGRAM [ARG]...`: runs a test, and writes FILE only when it
/// passed (exit status 0): `passed` and a newline, or TEXT, or with --stamp-log what the test wrote. With --capture the test's stdout and
/// stderr are held back and, when it failed, written to stdout (stdout then stderr); without it they pass through. A test that failed is
/// `TEST FAILED: PROGRAM` on stderr and the test's own status.
pub fn marker(_: Alloc, io: Io, args: []const []const u8) Oom!u8 {
    const spec = (try rs.parse(io, "marker", .marker, args)) orelse return 2;
    const out = spec.out orelse {
        io.say("marker", &.{"--out is required"});
        return 2;
    };
    if (spec.stamp_log and (!spec.capture or spec.stamp != null)) {
        io.say("marker", &.{"--stamp-log needs --capture and takes no --stamp"});
        return 2;
    }
    const prepared = switch (try rs.prepare(io, "marker", spec)) {
        .ready => |p| p,
        .fail => |code| return code,
    };
    defer rs.cleanup(io, prepared);
    const outcome = rs.start(io, "marker", prepared, if (spec.capture) .capture else .inherit);
    if (outcome.code != 0) {
        io.out.writeAll(try common.concat(io.a, &.{ outcome.stdout, outcome.stderr })) catch {};
        io.say("marker", &.{ "TEST FAILED: ", prepared.argv[0] });
        return outcome.code;
    }
    const stamp = if (spec.stamp_log) try common.concat(io.a, &.{ outcome.stdout, outcome.stderr }) else spec.stamp orelse "passed\n";
    return if (common.writeFile(io, "marker", out, stamp)) 0 else 1;
}

/// `check expect --want TEXT --out FILE [--prefix] [--name NAME] [OPTIONS] -- PROGRAM [ARG]...`: runs the program and compares what it wrote to
/// stdout, without its trailing newlines, with TEXT: equal, or with --prefix beginning with it. When it is, writes FILE (what it wrote, and a
/// newline) and exits 0; FILE is not written otherwise. A program that exits non-zero, or whose output is not that, is exit 1 with a message
/// that starts with NAME (default `check expect`). What the program writes to stderr is passed on to stderr.
pub fn expect(_: Alloc, io: Io, args: []const []const u8) Oom!u8 {
    const spec = (try rs.parse(io, "expect", .expect, args)) orelse return 2;
    const want = spec.want orelse {
        io.say("expect", &.{"--want is required"});
        return 2;
    };
    const out = spec.out orelse {
        io.say("expect", &.{"--out is required"});
        return 2;
    };
    const label = spec.name orelse "check expect";
    const prepared = switch (try rs.prepare(io, "expect", spec)) {
        .ready => |p| p,
        .fail => |code| return code,
    };
    defer rs.cleanup(io, prepared);
    const outcome = rs.start(io, "expect", prepared, .capture);
    io.err.writeAll(outcome.stderr) catch {};
    const program = prepared.argv[0];
    if (outcome.code != 0) {
        return try complain(io, &.{ label, ": ", program, " exited with status ", try common.num(io.a, outcome.code), "\n" });
    }
    const got = std.mem.trimRight(u8, outcome.stdout, "\n");
    const matches = if (spec.prefix) std.mem.startsWith(u8, got, want) else std.mem.eql(u8, got, want);
    if (!matches) {
        const how = if (spec.prefix) "starting with" else "equal to";
        return try complain(io, &.{ label, ": expected output ", how, " '", want, "' but ", program, " printed '", got, "'\n" });
    }
    return if (common.writeFile(io, "expect", out, try common.concat(io.a, &.{ got, "\n" }))) 0 else 1;
}

/// Says the message (its parts, newline included) on stderr; the exit status 1.
fn complain(io: Io, parts: []const []const u8) Oom!u8 {
    io.err.writeAll(try common.concat(io.a, parts)) catch {};
    return 1;
}
