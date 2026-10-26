from std.testing import TestSuite, assert_equal

from subdirs import midpoint, tripled


def test_tripled_triples() raises:
    assert_equal(tripled(14), 42)


def test_midpoint_is_between() raises:
    assert_equal(midpoint(10, 20), 15)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
