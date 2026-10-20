from std.testing import TestSuite, assert_equal

from hello import greeting


def test_greeting() raises:
    assert_equal(greeting(), "Hello, world!")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
