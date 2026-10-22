// A test that always fails (ci/planted/BUCK): the run must leave no marker.
#[test]
fn this_test_fails_by_design() {
    assert_eq!(1 + 1, 3, "this test fails by design");
}
