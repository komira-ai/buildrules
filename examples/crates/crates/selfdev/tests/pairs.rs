//! The library through its dev-dependency on itself: `pairs` exists only with `test-support`, which that dependency turns on.

#[test]
fn every_pair_of_a_text_is_read_in_order() {
    assert_eq!(selfdev::pairs("a=1\nb=2"), vec![("a", "1"), ("b", "2")]);
}

#[test]
fn lines_that_are_no_pair_are_left_out() {
    assert_eq!(selfdev::pairs("plain\n=1\nc="), vec![("c", "")]);
}

#[test]
fn an_empty_text_has_no_pairs() {
    assert_eq!(selfdev::pairs(""), Vec::<(&str, &str)>::new());
}
