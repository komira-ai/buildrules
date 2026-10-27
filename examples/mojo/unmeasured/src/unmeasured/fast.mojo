@always_inline("nodebug")
def bump(x: Int) -> Int:
    return x + 1


@always_inline("nodebug")
def halve(x: Int) -> Int:
    return x >> 1
