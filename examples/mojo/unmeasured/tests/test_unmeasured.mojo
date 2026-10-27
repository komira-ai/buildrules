from std.testing import TestSuite, assert_equal

from unmeasured import add, bump, clamp, halve


def test_add() raises:
    assert_equal(add(40, 2), 42)


def test_clamp() raises:
    assert_equal(clamp(3, 5), 3)
    assert_equal(clamp(9, 5), 5)


def test_fast_functions_run() raises:
    assert_equal(bump(41), 42)
    assert_equal(halve(84), 42)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
