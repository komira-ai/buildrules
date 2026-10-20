//! Reads what links_a's script published. Cargo hands `DEP_P4PROBE_*` to the build script of a direct dependent only.
use std::{env, fs, path::PathBuf};

fn main() {
    let answer = env::var("DEP_P4PROBE_ANSWER").expect("DEP_P4PROBE_ANSWER");
    let greeting = env::var("DEP_P4PROBE_GREETING").expect("DEP_P4PROBE_GREETING");
    let root = PathBuf::from(env::var_os("DEP_P4PROBE_ROOT").expect("DEP_P4PROBE_ROOT"));
    let data = fs::read_to_string(root.join("data.txt")).expect("links_a OUT_DIR is readable");
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    fs::write(out.join("seen.txt"), format!("{answer}|{greeting}|{data}")).unwrap();
    println!("cargo:rustc-env=P4_SEEN={answer}|{greeting}|{data}");
    // not `links_b`'s own `links`: a dependent of a dependent would see nothing.
    assert!(env::var_os("CARGO_MANIFEST_LINKS").is_none());
}
