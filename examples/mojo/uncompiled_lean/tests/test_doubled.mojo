from std.testing import TestSuite, assert_equal

from uncompiled_lean import doubled


def test_doubled_doubles() raises:
    assert_equal(doubled(21), 42)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
