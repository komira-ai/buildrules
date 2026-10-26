//! FAULTY: reads a host path. Must fail on the farm (the worker's /usr is not an input).
fn main() {
    let s = std::fs::read("/usr/include/stdio.h").expect("host path /usr/include/stdio.h");
    println!("cargo:rustc-env=P4_LEN={}", s.len());
}
