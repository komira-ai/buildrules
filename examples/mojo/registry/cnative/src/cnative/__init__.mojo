"""cnative: Mojo over a C library. The library itself ships beside the package (a native library), not in the .mojoc."""

from std.ffi import external_call


def answer() -> Int:
    return Int(external_call["cnative_answer", Int32]())
