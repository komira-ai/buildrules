from std.testing import TestSuite, assert_equal

from chain_c import add_one, triple


def test_add_one() raises:
    assert_equal(add_one(41), 42)


def test_triple() raises:
    assert_equal(triple(4), 12)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
