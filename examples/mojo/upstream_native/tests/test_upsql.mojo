from std.testing import TestSuite, assert_equal, assert_true

from upsql import initialize, threadsafe, version_number


def test_the_library_is_the_pinned_release() raises:
    # sqlite-autoconf-3530400 is SQLite 3.53.4.
    assert_equal(version_number(), 3053004)


def test_the_manifests_flags_reach_the_compile() raises:
    # -DSQLITE_THREADSAFE=1 is in the manifest's cflags; the amalgamation's default would be the same, so the library reports what it was built with.
    assert_equal(threadsafe(), 1)


def test_the_library_initializes() raises:
    assert_equal(initialize(), 0)
    assert_true(version_number() > 3000000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
