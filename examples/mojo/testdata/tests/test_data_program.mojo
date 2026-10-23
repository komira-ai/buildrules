from std.os import getenv
from std.pathlib import Path
from std.subprocess import run
from std.testing import TestSuite, assert_equal, assert_true


def test_a_program_staged_as_data_starts_and_prints() raises:
    # `bin/hello` is another target's output, staged with its executable bit; this test alone is given it.
    # The program prints one line; what `run` returns is that output (its last newline may be dropped).
    assert_true(String("hello from zig") in run(String("bin/hello")))


def test_the_data_for_every_test_and_the_variable_are_here_too() raises:
    assert_equal(Path("golden/greeting.txt").read_text(), String("hello, world"))
    assert_equal(getenv("TESTDATA_MODE"), String("strict"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
