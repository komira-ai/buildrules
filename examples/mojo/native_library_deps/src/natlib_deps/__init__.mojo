"""natlib_deps: Mojo over native_library targets that have dependencies of their own (examples/native/deps, examples/native/shared). Nothing crosses the C ABI but integers."""

from std.ffi import external_call


def base_value() -> Int:
    return Int(external_call["base_value", Int32]())


def top_value() -> Int:
    return Int(external_call["top_value", Int32]())


def left_value() -> Int:
    return Int(external_call["left_value", Int32]())


def right_value() -> Int:
    return Int(external_call["right_value", Int32]())


def shared_base_value() -> Int:
    return Int(external_call["shared_base_value", Int32]())


def shared_init_count() -> Int:
    return Int(external_call["shared_init_count", Int32]())
