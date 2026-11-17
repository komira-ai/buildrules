"""nsuser: a package named `example/nsuser`, imported as `nsuser`, over the member `example/nsshim` (imported as `nsshim`)."""

from nsshim import scale


def combine(a: Int, b: Int) -> Int:
    return scale(a + b) * 2
