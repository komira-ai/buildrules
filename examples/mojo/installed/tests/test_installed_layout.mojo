from std.os import getenv
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from layout import current_dir, executable_path, install_root, parent_of, share_dir


def test_the_executable_is_in_the_bin_directory_of_the_root() raises:
    # `/proc/self/exe` is `<root>/bin/<exe>`: the test was run from a copy of its binary in a fresh root, not from where the build left it.
    var exe = executable_path()
    var root = install_root()
    assert_equal(parent_of(exe), root + "/bin")
    assert_true(exe.byte_length() > (root + "/bin/").byte_length(), "no file name follows bin/ in " + exe)


def test_the_working_directory_is_the_root() raises:
    assert_equal(current_dir(), install_root())


def test_share_holds_the_staged_data() raises:
    assert_equal(share_dir(), install_root() + "/share")
    # `test_data` keys are relative to share/: `golden/greeting.txt` is share/golden/greeting.txt, by the finder, by the variable and by a relative path.
    var by_finder = Path(share_dir() + "/golden/greeting.txt").read_text()
    assert_equal(by_finder, String("hello, installed"))
    assert_equal(getenv("BUILDRULES_TEST_DATA"), share_dir())
    assert_equal(Path(getenv("BUILDRULES_TEST_DATA") + "/golden/greeting.txt").read_text(), by_finder)
    assert_equal(Path("share/golden/greeting.txt").read_text(), by_finder)


def test_a_variable_of_the_package_reaches_the_test() raises:
    assert_equal(getenv("LAYOUT_MODE"), String("installed"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
