"""partial: a package whose test takes one arm of `checked`. The lines of the other arm are recorded and never run, so the package's line coverage is below 100%."""


def checked(x: Int) raises -> Int:
    if x < 0:
        var message = String("negative: ") + String(x)
        raise Error(message)
    return x
