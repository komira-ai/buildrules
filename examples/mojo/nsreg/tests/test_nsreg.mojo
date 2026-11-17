from std.testing import TestSuite, assert_equal

from nsreg import tripled_sum


def test_tripled_sum() raises:
    # (4 + 3) * 3 = 21: the scaling is the C shim inside the registry package's `.conda`.
    assert_equal(tripled_sum(4, 3), 21)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
