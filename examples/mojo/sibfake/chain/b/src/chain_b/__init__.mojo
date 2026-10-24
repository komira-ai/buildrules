"""chain_b: the middle of the chain a -> b -> c."""

from chain_c import add_one, triple


def scale_then_bump(x: Int) -> Int:
    return add_one(triple(x))
