"""reexport_unused: PLANTED DEFECT. The __init__ of ../reexport plus a function nothing calls: the report omits the file, and it has a statement."""

from .ops import add, double


def unused() -> Int:
    return 7
