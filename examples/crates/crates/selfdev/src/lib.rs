//! `name=value` lines. The feature `test-support` adds `pairs`, which only this package's own tests use (through the dev-dependency on
//! the package itself, Cargo.toml).

/// The pair in `line`, split at its first `=`; `None` when it has no `=` or the name before it is empty.
pub fn pair(line: &str) -> Option<(&str, &str)> {
    let (name, value) = line.split_once('=')?;
    (!name.is_empty()).then_some((name, value))
}

/// Every line of `text` that is a pair, in order (`test-support` only).
#[cfg(feature = "test-support")]
pub fn pairs(text: &str) -> Vec<(&str, &str)> {
    text.lines().filter_map(pair).collect()
}

#[cfg(test)]
mod tests {
    use super::pair;

    #[test]
    fn a_pair_is_split_at_its_first_separator() {
        assert_eq!(pair("a=b=c"), Some(("a", "b=c")));
    }

    #[test]
    fn a_line_without_a_separator_is_no_pair() {
        assert_eq!(pair("plain"), None);
    }

    #[test]
    fn a_line_with_an_empty_name_is_no_pair() {
        assert_eq!(pair("=1"), None);
    }

    #[test]
    fn the_library_under_test_has_the_feature_its_dev_dependency_turns_on() {
        // The library's own test binary is compiled with the features of its dev-dependency on itself, as cargo does: without
        // `test-support`, `pairs` does not exist and this does not compile.
        assert_eq!(super::pairs("a=1\nplain"), vec![("a", "1")]);
    }
}
