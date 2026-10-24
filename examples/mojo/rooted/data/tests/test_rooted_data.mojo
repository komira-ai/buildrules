from std.pathlib import Path
from std.testing import TestSuite, assert_equal

from rooted_data import shout


def test_the_staged_file_is_read_from_the_working_directory() raises:
    assert_equal(shout(Path("golden/word.txt").read_text()), String("rooted!"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
