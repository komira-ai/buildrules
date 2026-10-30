from std.testing import TestSuite, assert_equal

from natlib_deps import left_value, right_value, shared_base_value, shared_init_count, top_value


def test_top_is_linked_with_the_libraries_it_needs_through_deps() raises:
    # top -> mid -> base, only top is named in `natives`: 41 + 40 - 40 + 1.
    assert_equal(top_value(), 42)


def test_left_and_right_over_one_base() raises:
    assert_equal(left_value(), 11)
    assert_equal(right_value(), 12)
    assert_equal(shared_base_value(), 10)


def test_the_base_two_libraries_share_is_linked_once() raises:
    # One copy of the base: its constructor ran once. Two copies would be a duplicate symbol at the link, or a count of 2.
    assert_equal(shared_init_count(), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
