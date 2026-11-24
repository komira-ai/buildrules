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

// A test that binds a Unix socket below TMPDIR, as tests that start a server on a socket in a directory of their own do. A socket path holds 107 bytes, so
// this needs a TMPDIR as short as cargo's (`/tmp`): the action's scratch path, about 98 bytes deep on the farm, leaves no room for these names.
#[test]
fn a_unix_socket_binds_below_tmpdir() {
    use std::os::unix::net::{UnixListener, UnixStream};
    let dir = std::env::temp_dir().join("cargo-run-socket-test/nested-a/nested-b");
    std::fs::create_dir_all(&dir).unwrap_or_else(|e| panic!("cannot make {dir:?}: {e}"));
    let path = dir.join("listener.sock");
    let listener = UnixListener::bind(&path).unwrap_or_else(|e| panic!("cannot bind {path:?} ({} bytes): {e}", path.as_os_str().len()));
    let _client = UnixStream::connect(&path).unwrap_or_else(|e| panic!("cannot connect to {path:?}: {e}"));
    let (_server, _) = listener.accept().expect("the listener accepts the connection");
}

// A test that writes a program below TMPDIR and runs it, as tests that stage a helper binary do: TMPDIR must be a directory programs can be run from
// (not a file system mounted `noexec`). The program is a copy of this test binary, asked only for its list of tests.
#[test]
fn a_program_copied_below_tmpdir_runs() {
    let exe = std::env::current_exe().expect("the test binary's path");
    let dir = std::env::temp_dir().join("cargo-run-exec-test");
    std::fs::create_dir_all(&dir).unwrap_or_else(|e| panic!("cannot make {dir:?}: {e}"));
    let copy = dir.join("env-copy");
    std::fs::copy(&exe, &copy).unwrap_or_else(|e| panic!("cannot copy {exe:?} to {copy:?}: {e}"));
    let out = std::process::Command::new(&copy)
        .args(["--list", "--format", "terse"])
        .output()
        .unwrap_or_else(|e| panic!("cannot run {copy:?}: {e}"));
    assert!(out.status.success(), "{copy:?} --list exited {:?}: {}", out.status, String::from_utf8_lossy(&out.stderr));
    let listing = String::from_utf8_lossy(&out.stdout);
    assert!(listing.lines().any(|l| l == "a_program_copied_below_tmpdir_runs: test"), "{copy:?} --list printed {listing:?}");
}
