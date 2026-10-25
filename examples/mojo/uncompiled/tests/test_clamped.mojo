from std.testing import TestSuite, assert_equal

from uncompiled import clamped


def test_clamped_stops_at_the_limit() raises:
    assert_equal(clamped(5, 3), 3)


def test_clamped_leaves_a_smaller_number() raises:
    assert_equal(clamped(2, 3), 2)


def test_clamped_ignores_a_limit_of_zero() raises:
    assert_equal(clamped(5, 0), 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
