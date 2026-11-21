//! covdemo: the fixture of a member's `:coverage` (rules/rust/coverage.bzl), code whose figures under its tests are known.
//!
//! `sign` has three arms: the unit test below takes two and the integration test (tests/runs.rs) the third, so all of them are hit only when
//! the integration test links the instrumented library. `greet` is reached only through the binary (src/main.rs), which the integration test
//! runs: it is hit only when the binary's own profile is read. `untested` is run by nothing: its lines and both of its arms are counted as not run.

/// The sign of `n` as a word.
pub fn sign(n: i64) -> &'static str {
    if n < 0 {
        "negative"
    } else if n == 0 {
        "zero"
    } else {
        "positive"
    }
}

/// The greeting the binary prints.
pub fn greet(name: &str) -> String {
    format!("hello, {name}")
}

/// What no test runs.
pub fn untested(n: u32) -> u32 {
    if n > 10 { n - 10 } else { n + 10 }
}

#[cfg(test)]
mod tests {
    #[test]
    fn negative_and_zero() {
        assert_eq!(super::sign(-3), "negative");
        assert_eq!(super::sign(0), "zero");
    }
}
