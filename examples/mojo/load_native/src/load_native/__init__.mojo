"""load_native: a library with no dependency whose tests open shared libraries by their bare names. The libraries are not linked: the package says
`mode = "load"` for each in `[native-dependencies]`, and the unit graph pins them (`system_libs`) for the test runs (docs/contract.md, section 12.11)."""


def tripled(x: Int) -> Int:
    return x * 3
