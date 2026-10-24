"""cshim: Mojo over a C shim that the package builds itself (its `[native.shim]`, native/cshim.c)."""

from std.ffi import external_call


def add(a: Int, b: Int) -> Int:
    return Int(external_call["cshim_add", Int32](Int32(a), Int32(b)))


def scale(x: Int) -> Int:
    return Int(external_call["cshim_scale", Int32](Int32(x)))
