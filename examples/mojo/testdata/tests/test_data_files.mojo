from std.os import getenv
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from testdata import greeting


def test_a_golden_file_is_read_from_the_working_directory() raises:
    # `golden/greeting.txt` is staged for every test; the path is relative, so the working directory is the staged tree.
    assert_equal(greeting(String("world")), Path("golden/greeting.txt").read_text())


def test_the_data_variable_names_the_working_directory() raises:
    var dir = getenv("BUILDRULES_TEST_DATA")
    assert_true(dir.byte_length() > 0)
    assert_equal(Path(dir + "/golden/greeting.txt").read_text(), Path("golden/greeting.txt").read_text())


def test_a_third_party_file_is_staged_whole() raises:
    var spec = Path("third_party/example.thrift").read_text()
    assert_true(String("struct Example") in spec)
    assert_true(String("2: optional string label") in spec)


def test_a_library_source_is_staged_as_data() raises:
    assert_true(String("def greeting(") in Path("lib/__init__.mojo").read_text())


def test_a_variable_of_the_package_reaches_the_test() raises:
    assert_equal(getenv("TESTDATA_MODE"), String("strict"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
