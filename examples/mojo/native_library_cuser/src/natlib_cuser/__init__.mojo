"""natlib_cuser: Mojo over a C library whose dependency is C++ (examples/native/cxx:cuser)."""

from std.ffi import external_call


def cuser_registered() -> Int:
    return Int(external_call["cuser_registered", Int32]())
