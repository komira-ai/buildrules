from std.testing import TestSuite, assert_equal

from versions_app import add_two


def test_add_two() raises:
    assert_equal(add_two(40), 42)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
