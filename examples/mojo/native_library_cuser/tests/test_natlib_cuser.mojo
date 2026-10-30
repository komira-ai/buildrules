from std.testing import TestSuite, assert_equal

from natlib_cuser import cuser_registered


def test_a_c_library_over_a_cxx_one_links_the_cxx_archive_and_runtime() raises:
    # cxxlib_registered() is 3 (a static initializer of the C++ library ran before main).
    assert_equal(cuser_registered(), 103)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
