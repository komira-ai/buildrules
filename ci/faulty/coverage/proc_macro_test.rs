//! The test target of a proc-macro crate built with coverage counters (ci/faulty/BUCK, `coverage_of_a_proc_macro_test`): a test binary on the target.

/// What the test runs.
pub fn twice(n: u32) -> u32 {
    n * 2
}

#[cfg(test)]
mod tests {
    #[test]
    fn doubles() {
        assert_eq!(super::twice(21), 42);
    }
}
