//! Every case of every part, in one test program: the coverage of the package is the blocks that ran in it, so a block that one part's cases run and
//! another's do not is counted once (rules/coverage/README.md, "Zig coverage").
test {
    _ = @import("conda_test.zig");
    _ = @import("pg_plat_test.zig");
    _ = @import("pg_prefix_test.zig");
    _ = @import("pg_run_test.zig");
}
