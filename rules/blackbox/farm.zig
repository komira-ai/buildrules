//! What a run on a farm job can show and a run anywhere else cannot: the job's own Action and Command.
//!
//! A job of the farm's executor holds, at the top of its root, a directory whose name starts with `.` and which holds `action` and `command`: the
//! serialized REAPI `Action` the frontend was sent and the `Command` it names. The sha256 of the Action's bytes and their length are the action digest Buck2 asked for (`buck2 log what-ran` prints the same
//! `hash:size`), and the Action's platform (or, when it has none, the Command's) is exactly the property set the frontend received. A run on a machine,
//! inside docker or as a local action has no such files, and writing them takes root on that machine and the exact bytes of an Action whose Command is
//! this run's own argument list, which `matchesArgv` checks.
//!
//! Only the fields read here are decoded: Action.command_digest (1) and Action.platform (10); Command.arguments (1) and Command.platform (5);
//! Platform.properties (1); Property.name (1) and Property.value (2). Every other field is skipped by its wire type.

const std = @import("std");

pub const Alloc = std.mem.Allocator;

/// What a farm job's directory holds: its Action and its Command. The directory is found by that, not by its name (the frontend's own), so the
/// runner does not depend on what the frontend calls it.
pub const action_file = "action";
pub const command_file = "command";

/// What is said of the job directory, in a message that finds none.
pub const job_dir = "job directory (a top-level `.<name>/` holding `action` and `command`)";

/// The largest Action or Command read (both are a few KiB; a bigger file is not one).
pub const max_message = 4 << 20;

pub const Property = struct { name: []const u8, value: []const u8 };

/// Which message the property set was read from: the Action's, or the Command's when the Action has none (REAPI before 2.2 puts it there).
pub const From = enum { action, command };

pub const Job = struct {
    /// The action digest: the sha256 of the Action's bytes, in lower-case hex, and their length.
    hash: [64]u8,
    size: u64,
    properties: []const Property,
    from: From,
    /// Command.arguments: the argument list the job ran.
    arguments: []const []const u8,
};

pub const Error = error{ Malformed, OutOfMemory };

/// A protobuf field: its number and either its varint or its length-delimited bytes (fixed-width values are skipped, never returned).
const Field = struct { num: u64, varint: u64 = 0, bytes: []const u8 = "", delimited: bool };

const Fields = struct {
    buf: []const u8,
    at: usize = 0,

    fn varint(self: *Fields) Error!u64 {
        var v: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            if (self.at >= self.buf.len or shift > 63) return error.Malformed;
            const b = self.buf[self.at];
            self.at += 1;
            v |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return v;
            shift += 7;
        }
    }

    fn skip(self: *Fields, n: u64) Error!void {
        if (n > self.buf.len - self.at) return error.Malformed;
        self.at += @intCast(n);
    }

    /// The next field the walk returns, or null at the end. Fixed-width fields (wire types 1 and 5) are stepped over; groups (3, 4) are refused.
    fn next(self: *Fields) Error!?Field {
        while (self.at < self.buf.len) {
            const key = try self.varint();
            const num = key >> 3;
            const wire = key & 7;
            if (wire == 0) return .{ .num = num, .varint = try self.varint(), .delimited = false };
            if (wire == 2) {
                const len = try self.varint();
                const start = self.at;
                try self.skip(len);
                return .{ .num = num, .bytes = self.buf[start..self.at], .delimited = true };
            }
            if (wire != 1 and wire != 5) return error.Malformed;
            try self.skip(if (wire == 1) 8 else 4);
        }
        return null;
    }
};

/// The length-delimited values of field `num` of `msg`, in order. Allocated once: a length-delimited field takes at least two bytes.
fn repeated(a: Alloc, msg: []const u8, num: u64) Error![]const []const u8 {
    var out = try std.ArrayList([]const u8).initCapacity(a, msg.len / 2);
    var f = Fields{ .buf = msg };
    while (try f.next()) |field| {
        if (field.num == num and field.delimited) out.appendAssumeCapacity(field.bytes);
    }
    return out.items;
}

/// The last length-delimited value of field `num` (protobuf: the last one of a non-repeated field wins), or null.
fn single(msg: []const u8, num: u64) Error!?[]const u8 {
    var last: ?[]const u8 = null;
    var f = Fields{ .buf = msg };
    while (try f.next()) |field| {
        if (field.num == num and field.delimited) last = field.bytes;
    }
    return last;
}

/// The properties of a Platform message.
pub fn platformOf(a: Alloc, platform: []const u8) Error![]const Property {
    const props = try repeated(a, platform, 1);
    const out = try a.alloc(Property, props.len);
    for (props, out) |prop, *p| {
        // A Property's name is its field 1 and its value its field 2; one absent reads as empty, the last of each wins.
        p.* = .{ .name = "", .value = "" };
        var f = Fields{ .buf = prop };
        while (try f.next()) |field| {
            if (field.num == 1 and field.delimited) p.name = field.bytes;
            if (field.num == 2 and field.delimited) p.value = field.bytes;
        }
    }
    return out;
}

/// The job that `action` and `command` (the two files' bytes) describe.
pub fn decode(a: Alloc, action: []const u8, command: []const u8) Error!Job {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(action, &hash, .{});
    // One walk of the Action: its platform (field 10, the last wins) and whether it names a command digest (field 1); an Action that names none is not
    // one a frontend runs.
    var platform: []const u8 = "";
    var has_command = false;
    var f = Fields{ .buf = action };
    while (try f.next()) |field| {
        if (field.num == 1 and field.delimited) has_command = true;
        if (field.num == 10 and field.delimited) platform = field.bytes;
    }
    if (!has_command) return error.Malformed;
    var props = try platformOf(a, platform);
    var from: From = .action;
    if (props.len == 0) {
        props = try platformOf(a, (try single(command, 5)) orelse "");
        from = .command;
    }
    return .{
        .hash = std.fmt.bytesToHex(hash, .lower),
        .size = action.len,
        .properties = props,
        .from = from,
        .arguments = try repeated(a, command, 1),
    };
}

/// The job whose root is `root` (opened to be iterated), or null when `root` holds no job directory: a directory at its top whose name starts with
/// `.` and which holds a file `action`. Two such, or one whose Command is not there or that cannot be read or decoded, is an error.
pub fn read(a: Alloc, root: std.fs.Dir) (Error || ReadError)!?Job {
    // The name found so far (a name is at most `max_name_bytes`), empty for none.
    var name_buf: [std.fs.max_name_bytes]u8 = undefined;
    var found: []const u8 = "";
    var it = root.iterate();
    while (it.next() catch return error.Unreadable) |entry| {
        if (entry.kind != .directory or entry.name.len < 2 or entry.name[0] != '.') continue;
        root.access(try std.fs.path.join(a, &.{ entry.name, action_file }), .{}) catch continue;
        // A job has one: a root with two is not one this reads.
        if (found.len > 0) return error.TwoJobDirectories;
        @memcpy(name_buf[0..entry.name.len], entry.name);
        found = name_buf[0..entry.name.len];
    }
    if (found.len == 0) return null;
    const dir = found;
    const action = root.readFileAlloc(a, try std.fs.path.join(a, &.{ dir, action_file }), max_message) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unreadable,
    };
    const command = root.readFileAlloc(a, try std.fs.path.join(a, &.{ dir, command_file }), max_message) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unreadable,
    };
    return try decode(a, action, command);
}

pub const ReadError = error{ Unreadable, TwoJobDirectories };

/// The value of `name` in `props` (the exact spelling; the farm reads `container-image` in that spelling only), or null.
pub fn value(props: []const Property, name: []const u8) ?[]const u8 {
    for (props) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.value;
    }
    return null;
}

/// True when the job ran `argv` after its first element: Buck2 writes the program as a path relative to the exec root, and the process sees whatever
/// path it was started by, so only the arguments after it are compared, and the program's base names.
pub fn matchesArgv(job: Job, argv: []const []const u8) bool {
    if (job.arguments.len != argv.len or argv.len == 0) return false;
    if (!std.mem.eql(u8, std.fs.path.basename(job.arguments[0]), std.fs.path.basename(argv[0]))) return false;
    for (job.arguments[1..], argv[1..]) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// `name=value,name=value,...` in the order the message holds them: the form of `[buildrules_re] linux_x86_64_properties` and of `buck2 log what-ran`.
pub fn render(a: Alloc, props: []const Property) error{OutOfMemory}![]const u8 {
    var len: usize = 0;
    for (props) |p| len += p.name.len + p.value.len + 2;
    var out = try std.ArrayList(u8).initCapacity(a, len);
    for (props, 0..) |p, i| {
        if (i > 0) out.appendAssumeCapacity(',');
        out.appendSliceAssumeCapacity(p.name);
        out.appendAssumeCapacity('=');
        out.appendSliceAssumeCapacity(p.value);
    }
    return out.items;
}
