//! The integer builtins of the compiler runtime (compiler-rt, 128-bit arithmetic) that a native library may define itself so that the link does not need the runtime.
//! The compiler calls them by these names, so a header of macros cannot rename them: `prefix_tool` leaves them out of the header and `archive_check --prefix` does not
//! count a definition of one against the prefix. One list for both, as a module.

const std = @import("std");

pub const names = [_][]const u8{ "__divti3", "__modti3", "__udivti3", "__umodti3", "__multi3", "__udivmodti4", "__ashlti3", "__ashrti3", "__lshrti3" };

/// Whether `name` is one of `names` (the whole name).
pub fn isBuiltin(name: []const u8) bool {
    for (names) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

test {
    _ = @import("builtins_test.zig");
}
