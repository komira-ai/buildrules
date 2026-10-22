from std.testing import TestSuite, assert_equal

from sys_app import answer


def test_answer() raises:
    # Only the C code can produce this: base_sys_value() is 1000 and probe_sys_answer() adds 243. A link without either archive fails on a symbol.
    assert_equal(answer(), 1243)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
