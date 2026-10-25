"""test_defines: a library whose code reads compile-time defines, and tests that are built with some (`mojo_package(test_defines = ...)` in BUCK)."""

from std.sys.defines import is_defined

comptime FLAG_ON: Bool = is_defined["BR_TEST_FLAG"]()
"""True when `-D BR_TEST_FLAG=...` is on the build that imports this library. The `.mojoc` is compiled without it; the build of an importing test compiles this declaration with its own defines."""


def flag_is_on() -> Bool:
    """The same question asked in a function that is not generic."""
    return is_defined["BR_TEST_FLAG"]()


def defined_in_the_calling_build[name: StaticString]() -> Bool:
    """Whether `name` is defined in the build that instantiates this function: a test that calls it asks about its own build."""
    return is_defined[name]()
