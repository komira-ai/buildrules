//! The command line of `farm connect` and `farm run`: `--name value` flags, each at most once, and the wait both take.
const std = @import("std");

/// The default bounded wait for the farm, in minutes: the connection between a runner and the farm has been seen gone for 2 to 24 minutes
/// at a time, and 20 covers most of those while a job's own timeout still leaves room for the build.
pub const default_wait_minutes: u64 = 20;
/// The longest wait a command line may ask for: past it the job's own timeout ends the job first.
pub const max_wait_minutes: u64 = 120;

/// The values of the flags named in `names`, from a command line.
pub fn Flags(comptime n: usize) type {
    return struct {
        names: *const [n][]const u8,
        values: [n]?[]const u8 = [_]?[]const u8{null} ** n,

        const Self = @This();

        pub fn init(names: *const [n][]const u8) Self {
            return .{ .names = names };
        }

        /// Reads `args` (all of them flags with a value); false after the reason is on `w`.
        pub fn parse(self: *Self, args: []const []const u8, w: *std.Io.Writer) !bool {
            var i: usize = 0;
            while (i < args.len) : (i += 2) {
                const arg = args[i];
                if (!std.mem.startsWith(u8, arg, "--")) {
                    try w.print("farm: {s} is not a flag\n", .{arg});
                    return false;
                }
                const slot = self.index(arg[2..]) orelse {
                    try w.print("farm: {s} is not a flag of this command\n", .{arg});
                    return false;
                };
                if (i + 1 >= args.len) {
                    try w.print("farm: {s} has no value\n", .{arg});
                    return false;
                }
                if (self.values[slot] != null) {
                    try w.print("farm: {s} is given twice\n", .{arg});
                    return false;
                }
                self.values[slot] = args[i + 1];
            }
            return true;
        }

        fn index(self: *const Self, name: []const u8) ?usize {
            for (self.names, 0..) |known, i| {
                if (std.mem.eql(u8, known, name)) return i;
            }
            return null;
        }

        pub fn get(self: *const Self, name: []const u8) ?[]const u8 {
            return self.values[self.index(name).?];
        }
    };
}

/// `--wait-minutes` as milliseconds (the default when it is not given), or null after the reason is on `w`.
pub fn waitMs(value: ?[]const u8, command: []const u8, w: *std.Io.Writer) !?u64 {
    const text = value orelse return default_wait_minutes * std.time.ms_per_min;
    const minutes = std.fmt.parseInt(u64, text, 10) catch {
        try w.print("{s}: --wait-minutes is {s}, not a whole number of minutes\n", .{ command, text });
        return null;
    };
    if (minutes > max_wait_minutes) {
        try w.print("{s}: --wait-minutes is {d}, more than {d}: the job's own timeout would end it first\n", .{ command, minutes, max_wait_minutes });
        return null;
    }
    return minutes * std.time.ms_per_min;
}
