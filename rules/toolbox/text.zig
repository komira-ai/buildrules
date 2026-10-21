//! The applets that write text: `echo`, `cat`, and `sleep`.

const std = @import("std");
const io_mod = @import("io.zig");
const Io = io_mod.Io;
const Alloc = io_mod.Alloc;
const describe = io_mod.describe;
const Buf = io_mod.Buf;
const Oom = io_mod.Oom;

// ---- echo -------------------------------------------------------------------------------------------------------

/// Whether `arg` is a run of echo's flags: `-` and then only `n`, `e` and `E`.
fn isEchoFlags(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;
    for (arg[1..]) |c| {
        if (std.mem.indexOfScalar(u8, "neE", c) == null) return false;
    }
    return true;
}

const escape_names = "\\abefnrtv";
const escape_bytes = "\\\x07\x08\x1b\x0c\n\r\t\x0b";

/// Appends `arg` with its backslash escapes replaced (`\\ \a \b \e \f \n \r \t \v`, `\0` and up to three octal digits, `\x` and up to two
/// hex digits); another backslash stays as it is. Returns false at `\c`, which ends all output.
fn unescape(out: *Buf, arg: []const u8) Oom!bool {
    var i: usize = 0;
    while (i < arg.len) : (i += 1) {
        if (arg[i] != '\\' or i + 1 == arg.len) {
            try out.byte(arg[i]);
            continue;
        }
        i += 1;
        const c = arg[i];
        if (c == 'c') return false;
        if (std.mem.indexOfScalar(u8, escape_names, c)) |k| {
            try out.byte(escape_bytes[k]);
        } else if (c == '0' or c == 'x') {
            // `\0` takes up to three more octal digits, `\x` up to two hex digits.
            const base: u8 = if (c == '0') 8 else 16;
            const most: usize = if (c == '0') 3 else 2;
            var value: u32 = 0;
            var n: usize = 0;
            while (n < most and i + 1 < arg.len) : (n += 1) {
                const digit = std.fmt.charToDigit(arg[i + 1], base) catch break;
                value = value * base + digit;
                i += 1;
            }
            if (n == 0 and c == 'x') {
                try out.add("\\x");
            } else {
                try out.byte(@truncate(value));
            }
        } else {
            try out.byte('\\');
            try out.byte(c);
        }
    }
    return true;
}


/// `echo [-n] [-e] [-E] [ARG...]`: the arguments, separated by a space, then a newline unless -n. -e replaces backslash escapes, -E (the
/// default) does not. A first argument that is not made of those flags is text, so `echo --plan` writes `--plan`.
pub fn echo(a: Alloc, io: Io, args: []const []const u8) Oom!u8 {
    var newline = true;
    var escapes = false;
    var i: usize = 0;
    while (i < args.len and isEchoFlags(args[i])) : (i += 1) {
        for (args[i][1..]) |c| {
            if (c == 'n') {
                newline = false;
            } else {
                escapes = c == 'e';
            }
        }
    }
    var out = Buf{ .a = a };
    for (args[i..], 0..) |arg, k| {
        if (k > 0) try out.byte(' ');
        if (!escapes) {
            try out.add(arg);
        } else if (!try unescape(&out, arg)) {
            newline = false;
            break;
        }
    }
    if (newline) try out.byte('\n');
    return if (io.put(out.items)) 0 else 1;
}

// ---- cat --------------------------------------------------------------------------------------------------------

/// `cat [FILE...]`: the files, in order, to stdout; `-` and no operand at all read stdin. A file that cannot be read is an error, and the
/// rest are still written.
pub fn cat(_: Alloc, io: Io, args: []const []const u8) Oom!u8 {
    if (args.len == 0) return if (copyStdin(io)) 0 else 1;
    var status: u8 = 0;
    for (args) |name| {
        if (std.mem.eql(u8, name, "-")) {
            if (!copyStdin(io)) return 1;
            continue;
        }
        switch (copyFile(io, name)) {
            .done => {},
            .failed => status = 1,
            .closed => return 1,
        }
    }
    return status;
}

fn copyStdin(io: Io) bool {
    _ = io.in.streamRemaining(io.out) catch return false;
    return true;
}

const Copied = enum { done, failed, closed };

/// Writes one file to stdout. `failed`: it could not be read (said on stderr). `closed`: stdout could not be written.
fn copyFile(io: Io, name: []const u8) Copied {
    var file = io.cwd.openFile(name, .{}) catch |err| {
        io.say("cat", &.{ name, ": ", describe(err) });
        return .failed;
    };
    defer file.close();
    var buf: [16384]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch |err| {
            io.say("cat", &.{ name, ": ", describe(err) });
            return .failed;
        };
        if (n == 0) return .done;
        if (!io.put(buf[0..n])) return .closed;
    }
}

// ---- sleep ------------------------------------------------------------------------------------------------------

const unit_scale = [_]u64{ 1, 60, 3600, 86400 };

/// The nanoseconds in `text`: a decimal number (`30`, `0.3`, `.5`, `2.`), then optionally `s`, `m`, `h` or `d`. Null when it is anything
/// else. A figure too large for 64 bits of nanoseconds is the largest; a fraction is kept to the nanosecond.
pub fn parseInterval(text: []const u8) ?u64 {
    var unit: u64 = 1;
    var number = text;
    if (text.len > 0) {
        if (std.mem.indexOfScalar(u8, "smhd", text[text.len - 1])) |k| {
            unit = unit_scale[k];
            number = text[0 .. text.len - 1];
        }
    }
    var whole: u64 = 0;
    var frac: u64 = 0;
    var frac_digits: u32 = 0;
    var digits: usize = 0;
    var after_point = false;
    for (number) |c| {
        if (c == '.' and !after_point) {
            after_point = true;
        } else if (c >= '0' and c <= '9') {
            digits += 1;
            if (!after_point) {
                whole = whole *| 10 +| (c - '0');
            } else if (frac_digits < 9) {
                frac = frac * 10 + (c - '0');
                frac_digits += 1;
            }
        } else {
            return null;
        }
    }
    if (digits == 0) return null;
    while (frac_digits < 9) : (frac_digits += 1) frac *= 10;
    return (whole *| std.time.ns_per_s +| frac) *| unit;
}

/// `sleep TIME...`: waits for the sum of the times, each as `parseInterval` reads it. Nothing is waited for unless every one is valid.
pub fn sleep(_: Alloc, io: Io, args: []const []const u8) Oom!u8 {
    if (args.len == 0) {
        io.say("sleep", &.{"missing operand"});
        return 1;
    }
    var total: u64 = 0;
    for (args) |arg| {
        const ns = parseInterval(arg) orelse {
            io.say("sleep", &.{ "invalid time interval '", arg, "'" });
            return 1;
        };
        total +|= ns;
    }
    io.sleep(total);
    return 0;
}
