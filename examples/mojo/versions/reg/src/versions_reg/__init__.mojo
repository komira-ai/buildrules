"""versions_reg: a package of examples/mojo/versions over the registry package `example/nsshim`, whose `.conda` is another file for each Mojo version."""

from nsshim import scale


def tripled_sum(a: Int, b: Int) -> Int:
    return scale(a + b)
