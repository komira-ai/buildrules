"""uncompiled_lean: the library of ../uncompiled, with the test of `clamped` deleted. `clamped` is a function no test calls here, so the compiler emits nothing
for it; `:coverage` still finds the lines and decisions it has and hits fewer of them."""


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
