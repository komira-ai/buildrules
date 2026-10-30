from std.sys import CompilationTarget
from std.testing import TestSuite, assert_equal

from natlib import (
    adler32_combine,
    asm_add,
    asm_isa,
    asm_twice,
    prefixed_asm_add,
    prefixed_asm_isa,
    prefixed_asm_twice,
    caught,
    compile_flags,
    compress_bound,
    crc32_combine,
    greeting_len,
    registered,
    scaled_sum,
)


def test_zlib_adler32_combine() raises:
    # adler32("a") = 0x00620062, adler32("b") = 0x00630063, adler32("ab") = 0x012600C4.
    assert_equal(adler32_combine(0x00620062, 0x00630063, 1), UInt64(0x012600C4))


def test_zlib_crc32_combine() raises:
    # crc32("a") = 0xE8B7BE43, crc32("b") = 0x71BEEFF9, crc32("ab") = 0x9E83486D.
    assert_equal(crc32_combine(0xE8B7BE43, 0x71BEEFF9, 1), UInt64(0x9E83486D))


def test_zlib_compress_bound() raises:
    # compress.c: n + (n >> 12) + (n >> 14) + (n >> 25) + 13.
    assert_equal(compress_bound(1000), 1013)


def test_zlib_compile_flags_say_four_byte_ints() raises:
    # zutil.c: bits 0-1 are the size of uInt (1: 32 bits).
    assert_equal(compile_flags() & 3, UInt64(1))


def test_cxxlib_static_initializer_ran() raises:
    assert_equal(registered(), 3)


def test_cxxlib_std_string() raises:
    assert_equal(greeting_len(5), 12)


def test_cxxlib_virtual_call_and_dynamic_cast() raises:
    assert_equal(scaled_sum(5), 20)


def test_cxxlib_exception_thrown_and_caught_in_the_library() raises:
    assert_equal(caught(True), 1)
    assert_equal(caught(False), 0)


def test_asm_add_is_the_assembly_with_the_flag() raises:
    # a + b + ASM_BIAS, ASM_BIAS=7 (asm_flags).
    assert_equal(asm_add(20, 22), 49)
    assert_equal(asm_twice(10), 27)


def test_asm_is_the_one_of_the_cpu() raises:
    comptime if CompilationTarget.is_x86():
        assert_equal(asm_isa(), 1)
    else:
        assert_equal(asm_isa(), 2)


def test_prefixed_asm_is_renamed_and_links_beside_the_unprefixed_one() raises:
    assert_equal(prefixed_asm_add(20, 22), 49)
    assert_equal(prefixed_asm_twice(10), 27)
    assert_equal(prefixed_asm_isa(), asm_isa())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
