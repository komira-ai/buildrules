"""Inputs of the stamp tests of cli/BUCK (a BUCK file cannot define functions)."""

load(":version.bzl", "version_stamp")

def stamps(content, want, refuse = fail):
    """Accepts only if `version_stamp(content)` is exactly `want`: the bytes of version.zig are pinned."""
    got = version_stamp(content, refuse = refuse)
    if got != want:
        refuse("the stamp of {} is {}, not {}".format(repr(content), repr(got), repr(want)))
