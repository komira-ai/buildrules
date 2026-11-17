"""nsreg: a package named `example/nsreg` over the registry package `example/nsshim`, imported as `nsshim` from its `.conda`."""

from nsshim import scale


def tripled_sum(a: Int, b: Int) -> Int:
    return scale(a + b)
