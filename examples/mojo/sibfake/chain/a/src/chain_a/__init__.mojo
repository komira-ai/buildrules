"""chain_a: the top of the chain a -> b -> c."""

from chain_b import scale_then_bump


def twice(x: Int) -> Int:
    return scale_then_bump(scale_then_bump(x))
