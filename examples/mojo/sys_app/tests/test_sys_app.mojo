from std.testing import TestSuite, assert_equal

from sys_app import answer, clamped_answer


def test_answer() raises:
    # Only the C code can produce this: base_sys_value() is 1000 and probe_sys_answer() adds 243. A link without either archive fails on a symbol.
    assert_equal(answer(), 1243)


def test_clamped_answer() raises:
    # Both arms of the decision in `clamped_answer`: the answer below the limit, and the answer above it.
    assert_equal(clamped_answer(5000), 1243)
    assert_equal(clamped_answer(1000), 1000)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
