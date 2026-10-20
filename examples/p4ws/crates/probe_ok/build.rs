//! The control: a script that declares nothing it does not get. It records its whole environment in OUT_DIR/env.txt
//! (sorted, so the file is the contract's env table as the farm ran it).
use std::{env, fs, path::PathBuf};

fn main() {
    let mut vars: Vec<(String, String)> = env::vars().collect();
    vars.sort();
    let text: String = vars.iter().map(|(k, v)| format!("{k}={v}\n")).collect();
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    fs::write(out.join("env.txt"), text).unwrap();
    println!("cargo:rustc-env=P4_OK=yes");
}
