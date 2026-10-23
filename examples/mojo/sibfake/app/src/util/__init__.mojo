"""util: one step above base."""

from base import add_one, triple


def scale_then_bump(x: Int) -> Int:
    return add_one(triple(x))
