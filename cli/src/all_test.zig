//! Every test file of the package in one program, for the coverage figure. Coverage keeps, for a source position that the compiler emits several blocks
//! for (the instantiations of a generic function: `Diag.add`, `Ctx.say`, `Ctx.fail`, one per call site), the largest count of blocks that ran in any
//! one test program, so the tests that each run some of the call sites count together only when they are one program. The files are also each a test
//! program of their own (BUCK), which is what gates the build.

test {
    _ = @import("autopin_check_test.zig");
    _ = @import("autopin_gh_test.zig");
    _ = @import("autopin_http_test.zig");
    _ = @import("autopin_push_test.zig");
    _ = @import("autopin_api_test.zig");
    _ = @import("autopin_compute_test.zig");
    _ = @import("autopin_inflate_test.zig");
    _ = @import("autopin_manifest_test.zig");
    _ = @import("autopin_oom_test.zig");
    _ = @import("autopin_safe_test.zig");
    _ = @import("autopin_verify_test.zig");
    _ = @import("autopin_table_test.zig");
    _ = @import("autopin_zip_test.zig");
    _ = @import("buckgen_test.zig");
    _ = @import("cargo_cmd_test.zig");
    _ = @import("contract_test.zig");
    _ = @import("ctx_test.zig");
    _ = @import("failclosed_test.zig");
    _ = @import("fetch_test.zig");
    _ = @import("growth_test.zig");
    _ = @import("init_test.zig");
    _ = @import("lockreaders_test.zig");
    _ = @import("mojo_cmd_test.zig");
    _ = @import("mojo_lock_test.zig");
    _ = @import("mojo_toolchains_test.zig");
    _ = @import("mopm_pins_test.zig");
    _ = @import("npm_cmd_test.zig");
    _ = @import("pins_toml_test.zig");
    _ = @import("sync_check_test.zig");
    _ = @import("toml_test.zig");
    _ = @import("unitgen_test.zig");
    _ = @import("val_test.zig");
    _ = @import("valid_test.zig");
}
