from std.testing import TestSuite, assert_equal

from dia_right import via_right


def test_via_right() raises:
    assert_equal(via_right(0), 3)
    assert_equal(via_right(4), 15)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
