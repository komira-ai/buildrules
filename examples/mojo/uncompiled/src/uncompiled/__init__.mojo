"""uncompiled: a library with three functions, one of which no test calls. Mojo compiles only the functions a test reaches, so the coverage
report has no line for `never_called`; `:coverage` counts its lines and its decisions as found and not hit all the same."""


def doubled(x: Int) -> Int:
    return x * 2


def clamped(x: Int, limit: Int) -> Int:
    if x > limit and limit > 0:
        return limit
    return x


def never_called(x: Int) raises -> Int:
    if x < 0 or x > 100:
        raise Error("out of range")
    return x
