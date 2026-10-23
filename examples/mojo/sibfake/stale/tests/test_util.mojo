from std.testing import TestSuite, assert_equal

from util import scale_then_bump


def test_scale_then_bump() raises:
    assert_equal(scale_then_bump(0), 1)
    assert_equal(scale_then_bump(5), 16)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
