//! What the decoders share: where decoded bytes go (a `Sink`), and the errors a cut-off or corrupt archive raises.
const std = @import("std");

/// Somewhere decoded bytes are written, as a function and the state it works on, so a decoder does not know whether its output is a tar parser, a file,
/// or a test's buffer.
pub const Sink = struct {
    ctx: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, bytes: []const u8) anyerror!void,

    pub fn write(self: Sink, bytes: []const u8) anyerror!void {
        return self.writeFn(self.ctx, bytes);
    }
};

/// A `Sink` over `ptr`, whose type has `fn write(*T, []const u8) !void`.
pub fn sinkOf(comptime T: type, ptr: *T) Sink {
    const wrap = struct {
        fn call(ctx: *anyopaque, bytes: []const u8) anyerror!void {
            const self: *T = @ptrCast(@alignCast(ctx));
            return self.write(bytes);
        }
    };
    return .{ .ctx = ptr, .writeFn = wrap.call };
}
