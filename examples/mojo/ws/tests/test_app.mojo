from std.testing import TestSuite, assert_equal

from app import compute


def test_compute() raises:
    # util: 2 * 3 + 1 = 7; the native library answers 4242.
    assert_equal(compute(2), 7 + 4242)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
