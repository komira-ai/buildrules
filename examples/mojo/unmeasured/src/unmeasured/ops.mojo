def add(a: Int, b: Int) -> Int:
    return a + b


def clamp(x: Int, limit: Int) -> Int:
    if x > limit:
        return limit
    return x
