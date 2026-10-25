from std.sys.defines import get_defined_int, get_defined_string, is_defined
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from test_defines import FLAG_ON, defined_in_the_calling_build, flag_is_on


def test_a_bool_define_is_on_in_the_test_build() raises:
    # `test_defines = {"BR_TEST_FLAG": True, ...}` in BUCK is `-D BR_TEST_FLAG=true` on this test's build.
    assert_true(is_defined["BR_TEST_FLAG"]())
    assert_equal(String(get_defined_string["BR_TEST_FLAG"]()), String("true"))


def test_an_int_define_has_its_value() raises:
    assert_equal(get_defined_int["BR_TEST_LEVEL"](), 3)


def test_a_string_define_has_its_value() raises:
    assert_equal(String(get_defined_string["BR_TEST_NAME"]()), String("probe"))


def test_a_name_that_was_not_given_is_not_defined() raises:
    assert_false(is_defined["BR_NOT_GIVEN"]())


def test_the_library_reads_the_define_of_the_test_build() raises:
    # The library is imported as its `.mojoc`, which was compiled without any define; its declarations are compiled again by the build that imports it, with that
    # build's defines. A module-level `comptime` flag (the usual build gate), a function and a generic function all see the test's.
    assert_true(FLAG_ON)
    assert_true(flag_is_on())
    assert_true(defined_in_the_calling_build["BR_TEST_FLAG"]())
    assert_false(defined_in_the_calling_build["BR_NOT_GIVEN"]())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
