//! Every case of every part, in one test program: the coverage of the package is the blocks that ran in it, so a block that one part's cases run and
//! another's do not is counted once (README.md, "Zig coverage").
test {
    _ = @import("check_test.zig");
    _ = @import("cmds_test.zig");
    _ = @import("files_test.zig");
    _ = @import("hang_test.zig");
    _ = @import("isa_test.zig");
    _ = @import("oom_test.zig");
    _ = @import("runspec_libdir_test.zig");
    _ = @import("runspec_test.zig");
}
