//! The tests of every file of the release tool.
test {
    _ = @import("version.zig");
    _ = @import("gz.zig");
    _ = @import("tar.zig");
    _ = @import("assets.zig");
    _ = @import("page.zig");
    _ = @import("cmds.zig");
    _ = @import("bump_test.zig");
    _ = @import("binhdr");
    _ = @import("debs_test.zig");
    _ = @import("binaries.zig");
    _ = @import("release.zig");
}
