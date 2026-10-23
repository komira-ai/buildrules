from .aliases import Count, Ints, LIMIT


def add(a: Int, b: Int) -> Int:
    return a + b


def double(x: Int) -> Int:
    return add(x, x)


def clamp(x: Count) -> Count:
    if x > LIMIT:
        return LIMIT
    return x


def total(xs: Ints) -> Count:
    var sum: Count = 0
    for i in range(len(xs)):
        sum += xs[i]
    return sum
