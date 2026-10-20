"""app: the top of the chain app -> util -> base, plus the native answer of the registry package cnative."""

from util import scale_then_bump
from cnative import answer


def compute(x: Int) -> Int:
    """`scale_then_bump(x)` plus the answer the native library gives."""
    return scale_then_bump(x) + answer()
