from std.testing import TestSuite, assert_equal

from chain_a import twice


def test_twice() raises:
    assert_equal(twice(0), 4)
    assert_equal(twice(1), 13)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
