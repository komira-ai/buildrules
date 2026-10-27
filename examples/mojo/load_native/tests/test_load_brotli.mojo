from std.ffi import OwnedDLHandle
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_true

# The native libraries the test opens by their bare names: Brotli's decoder, which needs `libbrotlicommon` (so the run is given both, the second as a run dependency of
# the first). Neither is on a Linux worker of the farm, and a macOS worker has them only in a directory of `[buildrules_re] macos_library_dirs` (a Homebrew prefix), so
# with that key unset this passes on macOS only when the run is given the pinned libraries as well.
comptime _BROTLI: StaticString = (
    "libbrotlidec.1.dylib" if CompilationTarget.is_macos() else "libbrotlidec.so.1"
)


def test_brotli_is_found_by_its_bare_name() raises:
    var lib = OwnedDLHandle(_BROTLI)
    assert_true(lib.check_symbol("BrotliDecoderVersion"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
