"""versions_app: imports the sibling ../util; built for the same Mojo versions as it."""

from versions_util import add_one


def add_two(x: Int) -> Int:
    return add_one(add_one(x))
