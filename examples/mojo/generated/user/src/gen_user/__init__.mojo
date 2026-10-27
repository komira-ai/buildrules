"""gen_user: imports the sibling ../lib, whose library is in generated/gen_lib."""

from gen_lib import add_one, triple


def add_one_then_triple(x: Int) -> Int:
    return triple(add_one(x))
