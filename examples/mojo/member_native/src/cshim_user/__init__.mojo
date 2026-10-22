"""cshim_user: a member that depends on the member cshim, whose C shim it links through cshim's archive."""

from cshim import add, scale


def combine(a: Int, b: Int) -> Int:
    return scale(add(a, b))
