"""natlib: Mojo over three static libraries that `native_library` targets build (examples/native): zlib from a pinned tarball, a C++ library behind a C ABI, and a library with
assembly chosen by the CPU. Nothing crosses the C ABI but integers."""

from std.ffi import external_call


# zlib 1.3.1
def adler32_combine(adler1: UInt64, adler2: UInt64, len2: Int) -> UInt64:
    return external_call["adler32_combine", UInt64](adler1, adler2, Int64(len2))


def crc32_combine(crc1: UInt64, crc2: UInt64, len2: Int) -> UInt64:
    return external_call["crc32_combine", UInt64](crc1, crc2, Int64(len2))


def compress_bound(source_len: Int) -> Int:
    return Int(external_call["compressBound", UInt64](UInt64(source_len)))


def compile_flags() -> UInt64:
    return external_call["zlibCompileFlags", UInt64]()


# cxxlib
def registered() -> Int:
    return Int(external_call["cxxlib_registered", Int32]())


def greeting_len(n: Int) -> Int:
    return Int(external_call["cxxlib_greeting_len", UInt32](Int32(n)))


def scaled_sum(n: Int) -> Int:
    return Int(external_call["cxxlib_scaled_sum", Int32](Int32(n)))


def caught(do_throw: Bool) -> Int:
    return Int(external_call["cxxlib_caught", Int32](Int32(1 if do_throw else 0)))


# asm_add: asm_add is assembly (x86-64 or AArch64), asm_twice is C that calls it, asm_isa says which assembly was built.
def asm_add(a: Int, b: Int) -> Int:
    return Int(external_call["asm_add", Int64](Int64(a), Int64(b)))


def asm_twice(x: Int) -> Int:
    return Int(external_call["asm_twice", Int64](Int64(x)))


def asm_isa() -> Int:
    return Int(external_call["asm_isa", Int32]())


# asm_prefixed: the same library with every symbol it defines renamed to start with `natlib_` (`prefix`), assembly included, so it links beside the unprefixed one.
def prefixed_asm_add(a: Int, b: Int) -> Int:
    return Int(external_call["natlib_asm_add", Int64](Int64(a), Int64(b)))


def prefixed_asm_twice(x: Int) -> Int:
    return Int(external_call["natlib_asm_twice", Int64](Int64(x)))


def prefixed_asm_isa() -> Int:
    return Int(external_call["natlib_asm_isa", Int32]())
