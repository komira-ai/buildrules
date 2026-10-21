//! `check isa`: the machine code of a binary against the ISA level it was built for (what rules/rust/isa_audit.bzl is for).
//!
//!   check isa --objdump PROGRAM --binary FILE --expect avx2|none --label TEXT --out REPORT
//!
//! It runs `PROGRAM -d --no-show-raw-insn FILE` (llvm-objdump) and counts the lines of its output: the instructions, those that name `ymm`
//! (256-bit, AVX2 width), those that name `xmm`, and those that are a `vpaddd` on a `ymm`. With `avx2` the binary must hold a `ymm`
//! instruction (a flag that never reached the compiler leaves none), with `none` it must hold none (it would die with SIGILL on a worker
//! without AVX2). When that holds REPORT is written; otherwise it is not, the reason is said and the status is 1. An `--expect` that is neither
//! is status 2.

const std = @import("std");
const common = @import("common.zig");
const Io = common.Io;
const Alloc = common.Alloc;

/// The first lines that name ymm are kept, to show.
const shown = 5;

/// What the lines of a disassembly hold. Fed chunks of the output in order, so a line may be split between two.
pub const Counts = struct {
    instructions: u64 = 0,
    ymm: u64 = 0,
    xmm: u64 = 0,
    vpaddd_ymm: u64 = 0,
    /// The first lines that name ymm (at most `shown`), each cut at the length of the line buffer.
    first_ymm: [shown][]const u8 = undefined,
    first_ymm_count: usize = 0,
    /// The line being read: its start, when a chunk ended in the middle of it.
    pending: std.ArrayList(u8) = .empty,

    /// Counts the lines of `chunk`, and keeps what follows its last newline for the next.
    pub fn feed(self: *Counts, a: Alloc, chunk: []const u8) void {
        var rest = chunk;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            if (self.pending.items.len == 0) {
                self.line(a, rest[0..nl]);
            } else {
                self.pending.appendSlice(a, rest[0..nl]) catch common.oom();
                self.line(a, self.pending.items);
                self.pending.clearRetainingCapacity();
            }
            rest = rest[nl + 1 ..];
        }
        self.pending.appendSlice(a, rest) catch common.oom();
    }

    /// The last line, when the output did not end with a newline.
    pub fn finish(self: *Counts, a: Alloc) void {
        if (self.pending.items.len > 0) self.line(a, self.pending.items);
        self.pending.clearRetainingCapacity();
    }

    fn line(self: *Counts, a: Alloc, text: []const u8) void {
        if (isInstruction(text)) self.instructions += 1;
        if (std.mem.indexOf(u8, text, "ymm") != null) {
            self.ymm += 1;
            if (self.first_ymm_count < shown) {
                self.first_ymm[self.first_ymm_count] = a.dupe(u8, text) catch common.oom();
                self.first_ymm_count += 1;
            }
            if (std.mem.indexOf(u8, text, "vpaddd")) |at| {
                if (std.mem.indexOf(u8, text[at..], "ymm") != null) self.vpaddd_ymm += 1;
            }
        }
        if (std.mem.indexOf(u8, text, "xmm") != null) self.xmm += 1;
    }
};

/// A line of a disassembly that is an instruction: some spaces, hex digits (maybe none) and a colon, as `  401000: pushq %rbp`.
fn isInstruction(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len and text[i] == ' ') i += 1;
    while (i < text.len and ((text[i] >= '0' and text[i] <= '9') or (text[i] >= 'a' and text[i] <= 'f'))) i += 1;
    return i < text.len and text[i] == ':';
}

const usage = "usage: check isa --objdump PROGRAM --binary FILE --expect avx2|none --label TEXT --out REPORT";

pub fn run(a: Alloc, io: Io, args: []const []const u8) u8 {
    var objdump: ?[]const u8 = null;
    var binary: ?[]const u8 = null;
    var expect: ?[]const u8 = null;
    var label: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 2) {
        const slot: *?[]const u8 = if (std.mem.eql(u8, args[i], "--objdump")) &objdump else if (std.mem.eql(u8, args[i], "--binary")) &binary else if (std.mem.eql(u8, args[i], "--expect")) &expect else if (std.mem.eql(u8, args[i], "--label")) &label else if (std.mem.eql(u8, args[i], "--out")) &out else {
            io.say("isa", &.{ "unknown option ", args[i] });
            return 2;
        };
        slot.* = args[i + 1];
    }
    if (i != args.len or objdump == null or binary == null or expect == null or label == null or out == null) {
        io.say("isa", &.{usage});
        return 2;
    }
    const want_avx2 = std.mem.eql(u8, expect.?, "avx2");
    if (!want_avx2 and !std.mem.eql(u8, expect.?, "none")) {
        return complain(io, 2, &.{ "isa_audit: expect must be avx2 or none, got '", expect.?, "'\n" });
    }
    var counts = Counts{};
    if (!disassemble(a, io, objdump.?, binary.?, &counts)) return 1;
    const lbl = label.?;
    if (want_avx2 and counts.ymm == 0) {
        return complain(io, 1, &.{ "isa_audit: ", lbl, " was built for a level with AVX2 but its machine code has no ymm instruction: the ISA flags never reached the compiler\n" });
    }
    if (!want_avx2 and counts.ymm != 0) {
        const shown_lines = common.concat(a, &.{ "isa_audit: ", lbl, " was built for a level without AVX2 but ", common.num(a, counts.ymm), " instructions name ymm: it would die with SIGILL on a baseline worker\n" });
        io.err.writeAll(shown_lines) catch {};
        for (counts.first_ymm[0..counts.first_ymm_count]) |l| io.err.writeAll(common.concat(a, &.{ l, "\n" })) catch {};
        return 1;
    }
    return if (common.writeFile(io, "isa", out.?, report(a, lbl, expect.?, counts))) 0 else 1;
}

/// Says the message (its parts, newline included) on stderr; returns `status`.
fn complain(io: Io, status: u8, parts: []const []const u8) u8 {
    io.err.writeAll(common.concat(io.a, parts)) catch {};
    return status;
}


/// The text of the report: the counts, and the first lines that name ymm.
pub fn report(a: Alloc, label: []const u8, expect: []const u8, c: Counts) []const u8 {
    var text = common.Buf{ .a = a };
    text.add(common.concat(a, &.{ "target: ", label, "\nexpect: ", expect, "\ninstructions: ", common.num(a, c.instructions), "\n" }));
    text.add(common.concat(a, &.{ "instructions naming ymm (AVX2 width): ", common.num(a, c.ymm), "\n" }));
    text.add(common.concat(a, &.{ "instructions naming xmm (SSE width): ", common.num(a, c.xmm), "\n" }));
    text.add(common.concat(a, &.{ "vpaddd on ymm (the vectorized sum, AVX2-only): ", common.num(a, c.vpaddd_ymm), "\nfirst ymm lines:\n" }));
    for (c.first_ymm[0..c.first_ymm_count]) |l| text.add(common.concat(a, &.{ l, "\n" }));
    return text.list.items;
}

/// Runs the disassembler on the binary and counts its output as it arrives. False, with the reason said, when it cannot be run or fails.
fn disassemble(a: Alloc, io: Io, objdump: []const u8, binary: []const u8, counts: *Counts) bool {
    const here = io.cwd.realpathAlloc(a, ".") catch |err| {
        io.say("isa", &.{ "cannot find the working directory: ", @errorName(err) });
        return false;
    };
    var child = std.process.Child.init(&.{ common.absolute(a, here, objdump), "-d", "--no-show-raw-insn", binary }, a);
    child.stdout_behavior = .Pipe;
    child.stdin_behavior = .Ignore;
    child.cwd = here;
    child.spawn() catch |err| return cannotRun(io, objdump, err);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = child.stdout.?.read(&buf) catch |err| {
            _ = child.kill() catch {};
            io.say("isa", &.{ "cannot read the output of ", objdump, ": ", @errorName(err) });
            return false;
        };
        if (n == 0) break;
        counts.feed(a, buf[0..n]);
    }
    counts.finish(a);
    const term = child.wait() catch |err| return cannotRun(io, objdump, err);
    const status = common.statusOf(term);
    if (status != 0) {
        io.say("isa", &.{ objdump, " failed with status ", common.num(a, status) });
        return false;
    }
    return true;
}

fn cannotRun(io: Io, objdump: []const u8, err: anyerror) bool {
    io.say("isa", &.{ "cannot run ", objdump, ": ", @errorName(err) });
    return false;
}
