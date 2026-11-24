//! `CARGO`, which cargo sets for every crate it compiles and for every test it runs: the path of the cargo binary, here the pinned one (the
//! version of the workspace's rust-toolchain.toml). A test that runs cargo starts it from there.

use std::path::Path;
use std::process::{Command, Output};

/// Runs the cargo at `path` with `args`. cargo needs a home directory, and reads `.cargo/config.toml` up from where it runs: the test's scratch
/// directory is both, so neither the host's home nor the checkout is read.
fn cargo(path: &str, args: &[&str]) -> Output {
    let scratch = env!("CARGO_TARGET_TMPDIR");
    Command::new(path).args(args).env("CARGO_HOME", scratch).current_dir(scratch).output().expect("cargo runs")
}

fn version(path: &str) -> String {
    let out = cargo(path, &["--version"]);
    assert_eq!(out.status.code(), Some(0), "{path} --version: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).into_owned()
}

#[test]
fn cargo_at_compile_time_is_the_pinned_cargo_by_an_absolute_path() {
    assert!(Path::new(env!("CARGO")).is_absolute(), "env!(\"CARGO\") is {}, not an absolute path", env!("CARGO"));
    let v = version(env!("CARGO"));
    // The pinned version: examples/crates/rust-toolchain.toml names it, and a bump of the pin changes this line with it.
    assert!(v.starts_with("cargo 1.95.0 ("), "{} --version says {v:?}", env!("CARGO"));
}

#[test]
fn cargo_at_run_time_is_the_same_cargo() {
    let run = std::env::var("CARGO").expect("CARGO is set when the test runs");
    assert!(Path::new(&run).is_absolute(), "CARGO is {run}, not an absolute path");
    assert_eq!(version(&run), version(env!("CARGO")));
}

#[test]
fn cargo_refuses_a_command_it_does_not_have() {
    let out = cargo(env!("CARGO"), &["no-such-command"]);
    assert_eq!(out.status.code(), Some(101));
    assert!(String::from_utf8_lossy(&out.stderr).contains("no such command: `no-such-command`"), "{}", String::from_utf8_lossy(&out.stderr));
}
