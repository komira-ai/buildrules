//! The program under tests/bin/ (a `[[bin]]` whose path is in tests/), run as cargo runs a package's binary for its integration test.

use std::process::{Command, Output};

fn hook(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_example_hook")).args(args).output().expect("the hook runs")
}

#[test]
fn the_hook_handles_an_event() {
    let out = hook(&["push"]);
    assert_eq!(out.status.code(), Some(0));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "handled push\n");
    assert_eq!(String::from_utf8_lossy(&out.stderr), "");
}

#[test]
fn the_hook_without_an_event_says_how_to_call_it() {
    let out = hook(&[]);
    assert_eq!(out.status.code(), Some(2));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "");
    assert_eq!(String::from_utf8_lossy(&out.stderr), "usage: example_hook <event>\n");
}

#[test]
fn the_hook_given_an_empty_event_says_how_to_call_it() {
    let out = hook(&[""]);
    assert_eq!(out.status.code(), Some(2));
    assert_eq!(String::from_utf8_lossy(&out.stderr), "usage: example_hook <event>\n");
}
