//! The integration test of covdemo: the third arm of `sign` through the library, and `greet` through the binary.

#[test]
fn positive() {
    assert_eq!(covdemo::sign(5), "positive");
}

#[test]
fn the_binary_greets() {
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_covdemo")).arg("farm").output().expect("the binary runs");
    assert!(out.status.success());
    assert_eq!(String::from_utf8_lossy(&out.stdout), "hello, farm\n");
}
