from std.testing import TestSuite, assert_equal

from gen_user import add_one_then_triple


def test_add_one_then_triple() raises:
    assert_equal(add_one_then_triple(1), 6)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
