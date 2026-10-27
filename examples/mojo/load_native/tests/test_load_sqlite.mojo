from std.ffi import OwnedDLHandle
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true

from load_native import tripled

# The native library the test opens by its bare name: SQLite. The package declares it `mode = "load"`, so nothing links it and the compile never needs it; the unit
# graph pins conda-forge's `libsqlite` (and `libzlib`, which it needs) as `system_libs` of the graph, and the test run puts them on its library path. A Linux worker
# of the farm has no libsqlite3 of its own, so this passes only when the run is given the pinned one.
comptime _SQLITE: StaticString = (
    "libsqlite3.dylib" if CompilationTarget.is_macos() else "libsqlite3.so.0"
)


def test_sqlite_is_found_by_its_bare_name() raises:
    var lib = OwnedDLHandle(_SQLITE)
    assert_true(lib.check_symbol("sqlite3_libversion_number"))


def test_the_library_still_works() raises:
    assert_equal(tripled(14), 42)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
