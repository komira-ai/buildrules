from std.ffi import external_call
from std.testing import TestSuite, assert_equal

from cshim_user import combine


def test_combine() raises:
    # (1 + 2) * 3 * 2 = 18: both steps are in the C shim of cshim.
    assert_equal(combine(1, 2), 18)


def test_the_archive_of_cshim_is_in_this_link() raises:
    # This file names a symbol of the shim itself: the link of THIS test needs libshim.a, which cshim builds.
    assert_equal(Int(external_call["cshim_add", Int32](Int32(20), Int32(22))), 42)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
