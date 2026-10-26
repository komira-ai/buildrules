from std.ffi import OwnedDLHandle
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_true

# The native library a test opens by its bare name: the system's liblz4, which no graph of this package lists (a `mode = "load"` library is not linked). The
# loader finds it in the system directories on Linux and, on macOS, in the directories of `[buildrules_re] macos_library_dirs` or dyld's defaults.
comptime _LZ4: StaticString = (
    "liblz4.dylib" if CompilationTarget.is_macos() else "liblz4.so.1"
)


def test_native_library_is_found_by_its_bare_name() raises:
    var lib = OwnedDLHandle(_LZ4)
    assert_true(lib.check_symbol("LZ4_versionNumber"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
