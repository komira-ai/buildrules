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


# asm_split: assembly whose macro joins two instructions with `;` (a comment in Mach-O arm64 assembly): 42 only if the preprocessed text was split.
def split_value() -> Int:
    return Int(external_call["split_value", Int32]())


# hooks: a library renamed with `prefix` (hk_) that calls a weak hook a program may define. The prefix names the hook in `extra_symbols`, so the library asks for hk_hook_alloc, which
# hooks_provider defines. `provider_alloc` calls the provider directly: nothing else would pull its member out of the archive (a weak reference does not).
def hooks_alloc(n: Int) -> Int:
    return Int(external_call["hk_hooks_alloc", Int64](Int64(n)))


def provider_alloc(n: Int) -> Int:
    return Int(external_call["hk_hook_alloc", Int64](Int64(n)))
