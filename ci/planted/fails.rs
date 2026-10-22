// PLANTED DEFECT (ci/planted/BUCK): a test that fails.
#[test]
fn the_planted_failing_test() {
    assert_eq!(1 + 1, 3, "the planted failing test");
}
