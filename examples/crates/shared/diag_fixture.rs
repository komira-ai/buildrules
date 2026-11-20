//! A crate with a finding of each kind for a diagnostics run (`:flycheck`, flycheck_test.zig): an error rustc stops at and a warning.

pub fn mismatched() -> u32 {
    "not a number"
}

pub fn unused() -> u32 {
    let unused = 3;
    1
}
