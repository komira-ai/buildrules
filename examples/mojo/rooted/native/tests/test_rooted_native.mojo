from std.testing import TestSuite, assert_equal

from rooted_native import add, scale


def test_add() raises:
    assert_equal(add(40, 2), 42)


def test_scale() raises:
    assert_equal(scale(5), 30)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
