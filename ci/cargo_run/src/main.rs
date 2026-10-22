// A binary target with a unit test of its own: the third kind of cargo test run (ci/cargo_run/BUCK).
fn main() {}

#[test]
fn the_binary_test_runs() {
    assert!(std::env::var("CARGO_MANIFEST_DIR").is_ok());
}
