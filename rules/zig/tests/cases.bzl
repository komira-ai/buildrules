"""Inputs of the refusal tests of BUCK (a BUCK file cannot define functions)."""

load("@buildrules//rules/zig:checks.bzl", "check_optimize")

def every_mode(who, refuse = fail):
    """The four modes zig has, one after the other: all must be accepted."""
    for m in ["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"]:
        check_optimize(who, m, refuse = refuse)

def mod(name, label, below = []):
    """A `ZigModuleInfo` as the closure sees it: `below` are the (name, label) of the modules it reaches."""
    return struct(name = name, label = label, root = name + ".zig", inputs = [], deps = [], closure = [mod(n, l) for n, l in below])
