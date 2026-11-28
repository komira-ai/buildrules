//! Test support: REAPI messages encoded by hand, field by field from the schema (an Action, a Command, a Platform), for the cases of farm.zig and of
//! what reads a farm job's root.

const std = @import("std");

/// Protobuf by hand: a varint, a length-delimited field, a varint field, and the fixed-width fields the walk steps over.
pub const Pb = struct {
    a: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    pub fn varint(p: *Pb, v_in: u64) void {
        var v = v_in;
        while (v >= 0x80) : (v >>= 7) p.out.append(p.a, @as(u8, @truncate(v)) | 0x80) catch @panic("oom");
        p.out.append(p.a, @truncate(v)) catch @panic("oom");
    }

    pub fn bytes(p: *Pb, num: u64, data: []const u8) *Pb {
        p.varint(num << 3 | 2);
        p.varint(data.len);
        p.out.appendSlice(p.a, data) catch @panic("oom");
        return p;
    }

    pub fn number(p: *Pb, num: u64, v: u64) *Pb {
        p.varint(num << 3);
        p.varint(v);
        return p;
    }

    pub fn fixed64(p: *Pb, num: u64) *Pb {
        p.varint(num << 3 | 1);
        p.out.appendSlice(p.a, &[_]u8{0} ** 8) catch @panic("oom");
        return p;
    }

    pub fn fixed32(p: *Pb, num: u64) *Pb {
        p.varint(num << 3 | 5);
        p.out.appendSlice(p.a, &[_]u8{0} ** 4) catch @panic("oom");
        return p;
    }

    pub fn done(p: *Pb) []const u8 {
        return p.out.items;
    }
};

/// A Platform message of `props` (`name=value` each).
pub fn platform(a: std.mem.Allocator, props: []const [2][]const u8) []const u8 {
    var p = Pb{ .a = a };
    for (props) |kv| {
        var prop = Pb{ .a = a };
        _ = p.bytes(1, prop.bytes(1, kv[0]).bytes(2, kv[1]).done());
    }
    return p.done();
}

/// An Action naming a command digest, with `props` as its platform (none when empty), and a timeout and do_not_cache the walk must step over.
pub fn action(a: std.mem.Allocator, props: []const [2][]const u8) []const u8 {
    var digest = Pb{ .a = a };
    var p = Pb{ .a = a };
    _ = p.bytes(1, digest.bytes(1, "ab" ** 32).number(2, 146).done()).bytes(2, "root").number(7, 1);
    if (props.len > 0) _ = p.bytes(10, platform(a, props));
    return p.done();
}

/// A Command of `args`, with `props` as its (deprecated) platform field and an environment variable and working directory beside them.
pub fn command(a: std.mem.Allocator, args: []const []const u8, props: []const [2][]const u8) []const u8 {
    var p = Pb{ .a = a };
    for (args) |arg| _ = p.bytes(1, arg);
    var env = Pb{ .a = a };
    _ = p.bytes(2, env.bytes(1, "HOME").bytes(2, "/h").done());
    if (props.len > 0) _ = p.bytes(5, platform(a, props));
    _ = p.bytes(6, "");
    return p.done();
}
