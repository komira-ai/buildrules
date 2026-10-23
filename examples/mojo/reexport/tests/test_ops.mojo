from std.testing import TestSuite, assert_equal

from reexport import Count, Ints, LIMIT, add, clamp, double, total


def test_add() raises:
    assert_equal(add(40, 2), 42)


def test_double() raises:
    assert_equal(double(21), 42)


def test_clamp() raises:
    assert_equal(clamp(3), 3)
    assert_equal(clamp(LIMIT + 5), LIMIT)


def test_total() raises:
    var xs = Ints()
    xs.append(1)
    xs.append(2)
    xs.append(3)
    var n: Count = total(xs)
    assert_equal(n, 6)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
