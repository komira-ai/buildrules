from std.testing import TestSuite, assert_equal

from reexport import add, double


def test_add() raises:
    assert_equal(add(40, 2), 42)


def test_double() raises:
    assert_equal(double(21), 42)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
