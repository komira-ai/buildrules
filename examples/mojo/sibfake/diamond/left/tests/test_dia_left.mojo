from std.testing import TestSuite, assert_equal

from dia_left import via_left


def test_via_left() raises:
    assert_equal(via_left(0), 2)
    assert_equal(via_left(4), 10)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
