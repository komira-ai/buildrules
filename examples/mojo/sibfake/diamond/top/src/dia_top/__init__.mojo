"""dia_top: the top of the diamond; dia_bottom reaches it by two paths."""

from dia_left import via_left
from dia_right import via_right


def both(x: Int) -> Int:
    return via_left(x) + via_right(x)
