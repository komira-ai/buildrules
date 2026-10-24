"""chain_stale: a package whose table names chain_c at a version the checkout does not have."""

from chain_c import add_one, triple


def scale_then_bump(x: Int) -> Int:
    return add_one(triple(x))
