"""subdirs: a library with no dependency, committed with one unit graph per conda subdir (linux-64, linux-aarch64, osx-arm64). Which graph a
build uses follows its target platform (rules/mojo/subdirs.bzl); the source is the same for all of them."""


def tripled(x: Int) -> Int:
    return x * 3


def midpoint(low: Int, high: Int) -> Int:
    return low + (high - low) // 2
