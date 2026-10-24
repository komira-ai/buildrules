from std.testing import TestSuite, assert_equal

from dia_bottom import inc


def test_inc() raises:
    assert_equal(inc(41), 42)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
