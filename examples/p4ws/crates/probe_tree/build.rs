//! PLANTED: reads a file in the tree outside this package (a sibling). Must fail: it is not a declared input.
fn main() {
    let s = std::fs::read("../links_a/Cargo.toml").expect("sibling package file ../links_a/Cargo.toml");
    println!("cargo:rustc-env=P4_LEN={}", s.len());
}
