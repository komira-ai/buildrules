//! A Zig test that fails by design: the input of `//ci/faulty:host_run_of_a_failing_test` (ci/faulty/BUCK), whose run must be red.
test "this zig test fails by design" {
    return error.FailsByDesign;
}
