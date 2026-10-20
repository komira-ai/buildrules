//! `links = "p4probe"`: emits metadata (`cargo:KEY=VALUE` and `cargo::metadata=KEY=VALUE`) that a dependent's
//! build script reads as `DEP_P4PROBE_*`, including a path into this script's OUT_DIR.
use std::{env, fs, path::PathBuf};

fn main() {
    assert_eq!(env::var("CARGO_MANIFEST_LINKS").unwrap(), "p4probe");
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    fs::write(out.join("data.txt"), "from-links-a").unwrap();
    println!("cargo:answer=42");
    println!("cargo::metadata=greeting=hello world");
    println!("cargo:root={}", out.display());
    println!("cargo:rustc-cfg=p4_links_a");
    println!("cargo:rustc-check-cfg=cfg(p4_links_a)");
}
