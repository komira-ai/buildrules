from std.testing import TestSuite, assert_equal

from uncompiled_gate import entry


def test_entry_doubles() raises:
    assert_equal(entry(4), 8)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
