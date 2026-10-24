from std.testing import TestSuite, assert_equal

from dia_top import both


def test_both() raises:
    assert_equal(both(0), 5)
    assert_equal(both(1), 10)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
