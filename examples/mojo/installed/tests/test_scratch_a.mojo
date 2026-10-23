from std.os import getenv
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from layout import entry_count, is_absolute

# test_scratch_b.mojo is this file with another WHO. The runner gives each test its own TMPDIR, TEST_TMPDIR and HOME, so neither finds what the other (or an
# earlier run) left: both check that theirs are empty before they write.
comptime WHO = "a"


def _private(name: String) raises:
    var dir = getenv(name)
    assert_true(dir.byte_length() > 0, name + " is not set")
    assert_true(is_absolute(dir), name + " is not absolute: " + dir)
    assert_equal(entry_count(dir), 0, name + " is not empty at the start: " + dir)


def test_tmpdir_test_tmpdir_and_home_are_private_absolute_and_empty() raises:
    _private("TMPDIR")
    _private("TEST_TMPDIR")
    _private("HOME")
    assert_equal(getenv("TMPDIR"), getenv("TEST_TMPDIR"))
    assert_false(getenv("HOME") == getenv("TMPDIR"), "HOME and TMPDIR are the same directory")
    # They can be written, and what is written is this test's own.
    Path(getenv("TMPDIR") + "/who").write_text(String(WHO))
    Path(getenv("HOME") + "/who").write_text(String(WHO))
    assert_equal(Path(getenv("TEST_TMPDIR") + "/who").read_text(), String(WHO))
    assert_equal(Path(getenv("HOME") + "/who").read_text(), String(WHO))
    assert_equal(entry_count(getenv("TMPDIR")), 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
