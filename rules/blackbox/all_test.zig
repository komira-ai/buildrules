//! Every case of every part, in one test program: the coverage of the package is the blocks that ran in it, so a block that one part's cases run and
//! another's do not is counted once (rules/coverage/README.md, "Zig coverage").
test {
    // First: the sweeps run the common blocks hundreds of times, and every case after them runs those blocks again (sweeps_test.zig).
    _ = @import("sweeps_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("deb_test.zig");
    _ = @import("farm_test.zig");
    _ = @import("plat_test.zig");
    _ = @import("probe_test.zig");
    _ = @import("run_test.zig");
}
