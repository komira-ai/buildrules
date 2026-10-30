from std.testing import TestSuite, assert_equal

from conda_bins import add_one


def test_add_one() raises:
    assert_equal(add_one(41), 42)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
