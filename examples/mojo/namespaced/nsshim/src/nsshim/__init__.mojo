"""nsshim: a package named `example/nsshim`, imported as `nsshim`, over a C shim it builds itself (its `[native.nsshim]`, native/nsshim.c)."""

from std.ffi import external_call


def add(a: Int, b: Int) -> Int:
    return Int(external_call["nsshim_add", Int32](Int32(a), Int32(b)))


def scale(x: Int) -> Int:
    return Int(external_call["nsshim_scale", Int32](Int32(x)))
