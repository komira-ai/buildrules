from std.testing import TestSuite, assert_equal

from partial import checked


def test_checked_returns_a_non_negative_number() raises:
    assert_equal(checked(5), 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
