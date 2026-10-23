from std.sys import CompilationTarget, simd_width_of
from std.testing import TestSuite, assert_equal

from branch_shapes import Stamp, compress, dst_flag, x86_linux
from branch_shapes.folded import wide_x86


def test_a_bool_converted_to_an_int_is_its_digit() raises:
    assert_equal(dst_flag(Stamp(True)), "1")
    assert_equal(dst_flag(Stamp(False)), "0")


def test_each_lane_of_an_unrolled_loop_keeps_or_drops_its_value() raises:
    var out = List[UInt32](length=8, fill=0)
    var vec = SIMD[DType.uint32, 4](10, 20, 30, 40)
    var mask = SIMD[DType.bool, 4](True, False, True, False)
    assert_equal(compress[4](vec, mask, out), 2)
    assert_equal(out[0], 10)
    assert_equal(out[1], 30)
    var none = SIMD[DType.bool, 4](False, False, False, False)
    assert_equal(compress[4](vec, none, out), 0)


def test_the_same_loop_unrolled_to_another_width_is_the_same_decision() raises:
    var out = List[UInt32](length=8, fill=0)
    var vec = SIMD[DType.uint32, 8](1, 2, 3, 4, 5, 6, 7, 8)
    var mask = vec.gt(SIMD[DType.uint32, 8](4, 4, 4, 4, 4, 4, 4, 4))
    assert_equal(compress[8](vec, mask, out), 4)
    assert_equal(out[0], 5)
    assert_equal(out[3], 8)


def test_an_and_of_build_constants_has_the_value_of_the_build() raises:
    assert_equal(wide_x86(), CompilationTarget.is_x86() and simd_width_of[DType.uint32]() == 16)
    assert_equal(x86_linux(), CompilationTarget.is_x86() and CompilationTarget.is_linux())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
