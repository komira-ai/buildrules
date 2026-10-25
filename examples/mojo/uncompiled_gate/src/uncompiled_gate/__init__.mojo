"""uncompiled_gate: a library with the shapes `:coverage` tells apart among the functions no test compiled. Mojo compiles only what a test
reaches, so every function here but `entry` may have no line in the coverage report; only some of them are uncovered code."""


@always_inline
def twice(x: Int) -> Int:
    return x + x


@always_inline
def inlined_nobody_calls(x: Int) -> Int:
    return x + 1


def only_here(x: Int) -> Int:
    return x * 3


def zero_callers(x: Int) -> Int:
    return x - 1


def entry(x: Int) -> Int:
    comptime if False:
        return only_here(x)
    return twice(x)
