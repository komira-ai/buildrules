// How the run of a cargo test starts it (rules/rust/cargo_unit.bzl, `check marker` / `check run`): the way cargo does. Each assertion is a flag of that
// command line; the test fails when one is dropped.
use std::path::PathBuf;

fn var(name: &str) -> PathBuf {
    PathBuf::from(std::env::var(name).unwrap_or_else(|_| panic!("{name} is not set")))
}

#[test]
fn the_manifest_directory_is_absolute_and_is_where_the_test_runs() {
    let manifest = var("CARGO_MANIFEST_DIR");
    assert!(manifest.is_absolute(), "CARGO_MANIFEST_DIR is {manifest:?}, not an absolute path");
    let here = std::env::current_dir().expect("the working directory");
    assert_eq!(
        here.canonicalize().expect("canonical working directory"),
        manifest.canonicalize().expect("canonical manifest directory"),
        "the test runs in {here:?}, not in its package directory"
    );
}

#[test]
fn the_scratch_directories_are_absolute_and_there() {
    let tmp = var("TMPDIR");
    assert!(tmp.is_absolute(), "TMPDIR is {tmp:?}, not an absolute path");
    let target_tmp = var("CARGO_TARGET_TMPDIR");
    assert!(target_tmp.is_absolute(), "CARGO_TARGET_TMPDIR is {target_tmp:?}, not an absolute path");
    assert!(target_tmp.is_dir(), "CARGO_TARGET_TMPDIR {target_tmp:?} was not made");
}
